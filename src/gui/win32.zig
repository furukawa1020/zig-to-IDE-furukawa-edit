const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const app_mod = @import("../core/app.zig");
const command_mod = @import("../core/command.zig");
const dispatcher = @import("../core/dispatcher.zig");
const types = @import("../core/types.zig");
const navigation = @import("../editor/navigation.zig");
const git_repository = @import("../git/repository.zig");
const zig_output = @import("../diagnostics/zig_output.zig");
const highlight = @import("../language/highlight.zig");
const modes = @import("../language/modes.zig");
const symbols_mod = @import("../language/symbols.zig");
const file_finder = @import("../search/file_finder.zig");
const workspace_search = @import("../search/workspace_search.zig");
const build_consent = @import("../security/build_consent.zig");
const findings_mod = @import("../security/findings.zig");
const console_mod = @import("../tasks/console.zig");
const task_registry = @import("../tasks/registry.zig");

const QuickPanelMode = enum {
    find_file,
    search_workspace,
    run_task,
    new_file,
    document_symbols,
};

const BottomPanel = enum {
    output,
    git,
    diagnostics,
    security,
};

const TaskMatch = struct {
    name: []u8,
    executable: []u8,

    fn deinit(self: *TaskMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.executable);
        self.* = undefined;
    }
};

const SymbolMatch = struct {
    name: []u8,
    kind: symbols_mod.SymbolKind,
    line: usize,
    column: usize,
    byte_offset: usize,

    fn deinit(self: *SymbolMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

const QuickPanel = struct {
    allocator: std.mem.Allocator,
    visible: bool = false,
    mode: QuickPanelMode = .find_file,
    query: std.array_list.Managed(u8),
    selected_index: usize = 0,
    file_matches: ?[]file_finder.Match = null,
    search_results: ?[]workspace_search.Result = null,
    task_matches: ?[]TaskMatch = null,
    symbol_matches: ?[]SymbolMatch = null,

    fn init(allocator: std.mem.Allocator) QuickPanel {
        return .{
            .allocator = allocator,
            .query = std.array_list.Managed(u8).init(allocator),
        };
    }

    fn deinit(self: *QuickPanel) void {
        self.clearResults();
        self.query.deinit();
        self.* = undefined;
    }

    fn open(self: *QuickPanel, mode: QuickPanelMode, app: *const app_mod.App) !void {
        self.visible = true;
        self.mode = mode;
        self.selected_index = 0;
        self.query.clearRetainingCapacity();
        try self.rebuild(app);
    }

    fn close(self: *QuickPanel) void {
        self.visible = false;
        self.clearResults();
        self.query.clearRetainingCapacity();
        self.selected_index = 0;
    }

    fn insertText(self: *QuickPanel, app: *const app_mod.App, bytes: []const u8) !void {
        try self.query.appendSlice(bytes);
        try self.rebuild(app);
    }

    fn deleteBackward(self: *QuickPanel, app: *const app_mod.App) !void {
        if (self.query.items.len == 0) return;
        var end = self.query.items.len - 1;
        while (end > 0 and isUtf8Continuation(self.query.items[end])) : (end -= 1) {}
        self.query.shrinkRetainingCapacity(end);
        try self.rebuild(app);
    }

    fn moveSelection(self: *QuickPanel, delta: isize) void {
        const count = self.itemCount();
        if (count == 0) {
            self.selected_index = 0;
            return;
        }

        const max_index = count - 1;
        if (delta < 0) {
            const amount = @as(usize, @intCast(-delta));
            self.selected_index = if (amount > self.selected_index) 0 else self.selected_index - amount;
        } else {
            self.selected_index = @min(max_index, self.selected_index + @as(usize, @intCast(delta)));
        }
    }

    fn itemCount(self: *const QuickPanel) usize {
        return switch (self.mode) {
            .find_file => if (self.file_matches) |items| items.len else 0,
            .search_workspace => if (self.search_results) |items| items.len else 0,
            .run_task => if (self.task_matches) |items| items.len else 0,
            .new_file => if (self.query.items.len > 0) 1 else 0,
            .document_symbols => if (self.symbol_matches) |items| items.len else 0,
        };
    }

    fn selectedFile(self: *const QuickPanel) ?file_finder.Match {
        const items = self.file_matches orelse return null;
        if (items.len == 0) return null;
        return items[@min(self.selected_index, items.len - 1)];
    }

    fn selectedSearchResult(self: *const QuickPanel) ?*const workspace_search.Result {
        const items = self.search_results orelse return null;
        if (items.len == 0) return null;
        return &items[@min(self.selected_index, items.len - 1)];
    }

    fn selectedTask(self: *const QuickPanel) ?*const TaskMatch {
        const items = self.task_matches orelse return null;
        if (items.len == 0) return null;
        return &items[@min(self.selected_index, items.len - 1)];
    }

    fn selectedSymbol(self: *const QuickPanel) ?*const SymbolMatch {
        const items = self.symbol_matches orelse return null;
        if (items.len == 0) return null;
        return &items[@min(self.selected_index, items.len - 1)];
    }

    fn rebuild(self: *QuickPanel, app: *const app_mod.App) !void {
        self.clearResults();
        switch (self.mode) {
            .find_file => {
                self.file_matches = try file_finder.find(self.allocator, &app.workspace, self.query.items, 64);
            },
            .search_workspace => {
                if (self.query.items.len > 0) {
                    self.search_results = try workspace_search.search(self.allocator, &app.workspace, self.query.items, .{
                        .max_file_bytes = 512 * 1024,
                        .max_results = 256,
                    });
                }
            },
            .run_task => {
                var registry = try task_registry.loadProjectTasks(self.allocator, app.workspace.root_path);
                defer registry.deinit();

                var matches = std.array_list.Managed(TaskMatch).init(self.allocator);
                errdefer {
                    for (matches.items) |*item| item.deinit(self.allocator);
                    matches.deinit();
                }

                for (registry.tasks.items) |task| {
                    const executable = task.executable orelse "";
                    const name_match = command_mod.fuzzyScore(self.query.items, task.name) != null;
                    const exe_match = command_mod.fuzzyScore(self.query.items, executable) != null;
                    if (self.query.items.len != 0 and !name_match and !exe_match) continue;
                    try matches.append(.{
                        .name = try self.allocator.dupe(u8, task.name),
                        .executable = try self.allocator.dupe(u8, executable),
                    });
                }

                self.task_matches = try matches.toOwnedSlice();
            },
            .new_file => {},
            .document_symbols => {
                const active_index = app.documents.activeIndex() orelse return;
                const doc = &app.documents.documents.items[active_index];
                const path = doc.path orelse "(scratch)";
                var index = try symbols_mod.collectTopLevel(self.allocator, doc.text.bytes, path);
                defer index.deinit();

                var matches = std.array_list.Managed(SymbolMatch).init(self.allocator);
                errdefer {
                    for (matches.items) |*item| item.deinit(self.allocator);
                    matches.deinit();
                }

                for (index.symbols) |symbol| {
                    const kind_name = @tagName(symbol.kind);
                    const name_match = command_mod.fuzzyScore(self.query.items, symbol.name) != null;
                    const kind_match = command_mod.fuzzyScore(self.query.items, kind_name) != null;
                    if (self.query.items.len != 0 and !name_match and !kind_match) continue;
                    try matches.append(.{
                        .name = try self.allocator.dupe(u8, symbol.name),
                        .kind = symbol.kind,
                        .line = symbol.range.start.line,
                        .column = symbol.range.start.column,
                        .byte_offset = symbol.range.start.byte_offset,
                    });
                }

                self.symbol_matches = try matches.toOwnedSlice();
            },
        }
        if (self.selected_index >= self.itemCount()) self.selected_index = 0;
    }

    fn clearResults(self: *QuickPanel) void {
        if (self.file_matches) |items| {
            self.allocator.free(items);
            self.file_matches = null;
        }
        if (self.search_results) |items| {
            for (items) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
            self.search_results = null;
        }
        if (self.task_matches) |items| {
            for (items) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
            self.task_matches = null;
        }
        if (self.symbol_matches) |items| {
            for (items) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
            self.symbol_matches = null;
        }
    }
};

const SearchPanel = struct {
    allocator: std.mem.Allocator,
    visible: bool = false,
    query: std.array_list.Managed(u8),
    selected_index: usize = 0,
    results: ?[]workspace_search.Result = null,

    fn init(allocator: std.mem.Allocator) SearchPanel {
        return .{
            .allocator = allocator,
            .query = std.array_list.Managed(u8).init(allocator),
        };
    }

    fn deinit(self: *SearchPanel) void {
        self.clearResults();
        self.query.deinit();
        self.* = undefined;
    }

    fn clear(self: *SearchPanel) void {
        self.clearResults();
        self.query.clearRetainingCapacity();
        self.selected_index = 0;
        self.visible = false;
    }

    fn refresh(self: *SearchPanel, app: *const app_mod.App, query: []const u8) !void {
        self.clearResults();
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(query);
        self.selected_index = 0;

        if (query.len == 0) {
            self.visible = false;
            return;
        }

        self.results = try workspace_search.search(self.allocator, &app.workspace, query, .{
            .max_file_bytes = 512 * 1024,
            .max_results = 512,
        });
        self.visible = true;
    }

    fn itemCount(self: *const SearchPanel) usize {
        return if (self.results) |items| items.len else 0;
    }

    fn selectedResult(self: *const SearchPanel) ?*const workspace_search.Result {
        const items = self.results orelse return null;
        if (items.len == 0) return null;
        return &items[@min(self.selected_index, items.len - 1)];
    }

    fn clearResults(self: *SearchPanel) void {
        if (self.results) |items| {
            for (items) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
            self.results = null;
        }
    }
};

pub fn run(allocator: std.mem.Allocator, root_path: []const u8) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    var state = try GuiState.init(allocator, root_path);
    defer state.deinit();
    global_state = &state;
    defer global_state = null;
    state.runZigSecurityAudit("startup");

    const hmodule = GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;
    const hinstance: windows.HINSTANCE = @ptrCast(hmodule);

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zide.gui.window");
    const title = std.unicode.utf8ToUtf16LeStringLiteral("zide");

    const window_class = WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = CS_HREDRAW | CS_VREDRAW,
        .lpfnWndProc = windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name.ptr,
        .hIconSm = null,
    };

    if (RegisterClassExW(&window_class) == 0) return error.RegisterClassFailed;

    const hwnd = CreateWindowExW(
        0,
        class_name.ptr,
        title.ptr,
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        1180,
        760,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    state.hwnd = hwnd;
    state.text_font = createTextFont();

    _ = SetWindowTextW(hwnd, title.ptr);
    _ = ShowWindow(hwnd, SW_SHOW);
    _ = UpdateWindow(hwnd);

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) != .FALSE) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

const GuiState = struct {
    allocator: std.mem.Allocator,
    app: app_mod.App,
    hwnd: ?windows.HWND = null,
    text_font: ?HFONT = null,
    last_error: ?[]u8 = null,
    collapsed_dirs: []bool,
    editor_scroll_line: usize = 0,
    editor_visible_rows: usize = 24,
    output_scroll_line: usize = 0,
    diagnostics_scroll_line: usize = 0,
    security_scroll_line: usize = 0,
    git_scroll_line: usize = 0,
    show_output: bool = true,
    bottom_panel: BottomPanel = .output,
    quick_panel: QuickPanel,
    search_panel: SearchPanel,
    git_overview: ?git_repository.Overview = null,

    fn init(allocator: std.mem.Allocator, root_path: []const u8) !GuiState {
        var app = try app_mod.App.init(allocator, root_path);
        errdefer app.deinit();

        const collapsed_dirs = try allocator.alloc(bool, app.workspace.entries.items.len);
        @memset(collapsed_dirs, false);

        return .{
            .allocator = allocator,
            .app = app,
            .collapsed_dirs = collapsed_dirs,
            .quick_panel = QuickPanel.init(allocator),
            .search_panel = SearchPanel.init(allocator),
        };
    }

    fn openWorkspace(self: *GuiState, root_path: []const u8) void {
        var next_app = app_mod.App.init(self.allocator, root_path) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "workspace open failed: {s}\n", .{@errorName(err)});
            return;
        };
        const next_collapsed = self.allocator.alloc(bool, next_app.workspace.entries.items.len) catch |err| {
            next_app.deinit();
            self.setError(err) catch {};
            self.appendOutput(.stderr, "workspace state allocation failed: {s}\n", .{@errorName(err)});
            return;
        };
        @memset(next_collapsed, false);

        self.app.deinit();
        self.allocator.free(self.collapsed_dirs);
        self.app = next_app;
        self.collapsed_dirs = next_collapsed;
        self.editor_scroll_line = 0;
        self.editor_visible_rows = 24;
        self.output_scroll_line = 0;
        self.diagnostics_scroll_line = 0;
        self.security_scroll_line = 0;
        self.git_scroll_line = 0;
        self.show_output = true;
        self.bottom_panel = .output;
        self.clearGitOverview();
        self.quick_panel.close();
        self.search_panel.clear();
        self.setMessage("Workspace opened") catch {};
        self.appendOutput(.stdout, "opened workspace: {s}\n", .{self.app.workspace.root_path});
        self.runZigSecurityAudit("workspace open");
    }

    fn syncCollapsedDirs(self: *GuiState) void {
        if (self.collapsed_dirs.len == self.app.workspace.entries.items.len) return;
        const next = self.allocator.alloc(bool, self.app.workspace.entries.items.len) catch |err| {
            self.setError(err) catch {};
            return;
        };
        @memset(next, false);
        const copy_len = @min(self.collapsed_dirs.len, next.len);
        if (copy_len > 0) @memcpy(next[0..copy_len], self.collapsed_dirs[0..copy_len]);
        self.allocator.free(self.collapsed_dirs);
        self.collapsed_dirs = next;
        if (self.app.file_cursor >= self.app.workspace.entries.items.len) {
            self.app.file_cursor = if (self.app.workspace.entries.items.len == 0) 0 else self.app.workspace.entries.items.len - 1;
        }
    }

    fn chooseAndOpenWorkspace(self: *GuiState, hwnd: windows.HWND) void {
        const chosen = chooseFolder(self.allocator, hwnd) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "folder picker failed: {s}\n", .{@errorName(err)});
            return;
        };
        const path = chosen orelse {
            self.setMessage("Open workspace cancelled") catch {};
            return;
        };
        defer self.allocator.free(path);
        self.openWorkspace(path);
    }

    fn runZigSecurityAudit(self: *GuiState, reason: []const u8) void {
        const result = dispatcher.dispatch(&self.app, .{ .id = "security.audit_workspace", .source = .startup }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "zig security audit failed: {s}\n", .{@errorName(err)});
            return;
        };
        switch (result) {
            .completed => {},
            .blocked => |message| self.appendOutput(.stderr, "zig security audit blocked: {s}\n", .{message}),
            .unknown_command => self.appendOutput(.stderr, "zig security audit command missing\n", .{}),
            .no_active_document => {},
            .external_command => {},
            .unsupported => |message| self.appendOutput(.stderr, "zig security audit unsupported: {s}\n", .{message}),
        }

        const counts = riskCounts(&self.app.security_findings);
        self.appendOutput(
            .stdout,
            "zig security audit ({s}): {d} findings critical={d} high={d} medium={d} low={d}\n",
            .{
                reason,
                self.app.security_findings.items.items.len,
                counts.critical,
                counts.high,
                counts.medium,
                counts.low,
            },
        );
        self.appendOutput(.stdout, "checks: build.zig firewall, build.zig.zon hashes, unsafe Zig/FFI/allocators, polyglot scripts/secrets/process boundaries, git config/hooks/submodules/attributes\n", .{});

        const limit: usize = 10;
        for (self.app.security_findings.items.items, 0..) |item, index| {
            if (index >= limit) break;
            self.appendOutput(
                if (riskRank(item.risk) >= riskRank(.high)) .stderr else .stdout,
                "{s}/{s} {s}:{d}:{d} {s}\n",
                .{ @tagName(item.risk), @tagName(item.category), item.path, item.line + 1, item.column + 1, item.message },
            );
        }
        if (self.app.security_findings.items.items.len > limit) {
            self.appendOutput(.stdout, "... {d} more findings\n", .{self.app.security_findings.items.items.len - limit});
        }
    }

    fn deinit(self: *GuiState) void {
        if (self.text_font) |font| _ = DeleteObject(@ptrCast(font));
        if (self.last_error) |message| self.allocator.free(message);
        self.clearGitOverview();
        self.search_panel.deinit();
        self.quick_panel.deinit();
        self.allocator.free(self.collapsed_dirs);
        self.app.deinit();
    }

    fn moveSelection(self: *GuiState, delta: isize) void {
        self.app.focus = .files;
        const visible_count = self.visibleEntryCount();
        if (visible_count == 0) {
            self.app.file_cursor = 0;
            return;
        }

        const selected_rank = self.visibleRankOfIndex(self.app.file_cursor) orelse 0;
        const max_rank = visible_count - 1;
        const next_rank = if (delta < 0) blk: {
            const amount = @as(usize, @intCast(-delta));
            break :blk if (amount > selected_rank) 0 else selected_rank - amount;
        } else blk: {
            const amount = @as(usize, @intCast(delta));
            break :blk @min(max_rank, selected_rank + amount);
        };

        if (self.entryIndexAtVisibleRank(next_rank)) |index| {
            self.app.file_cursor = index;
        }
    }

    fn openSelected(self: *GuiState) void {
        const index = if (self.app.workspace.entries.items.len == 0)
            null
        else
            @min(self.app.file_cursor, self.app.workspace.entries.items.len - 1);
        const selected_index = index orelse {
            self.setMessage("No workspace entry selected") catch {};
            return;
        };

        const entry = self.app.workspace.entries.items[selected_index];
        if (entry.kind == .directory) {
            self.toggleDirectory(selected_index);
            return;
        }

        const opened = self.app.openSelectedWorkspaceEntry() catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (!opened) {
            self.setMessage("Select a file to open") catch {};
            return;
        }

        self.app.mode = .insert;
        self.app.focus = .editor;
        self.ensureCursorVisible();
        self.setMessage("Opened file") catch {};
    }

    fn toggleDirectory(self: *GuiState, index: usize) void {
        if (index >= self.collapsed_dirs.len) return;
        if (self.app.workspace.entries.items[index].kind != .directory) return;
        self.collapsed_dirs[index] = !self.collapsed_dirs[index];
        self.app.focus = .files;
        self.setMessage(if (self.collapsed_dirs[index]) "Folder collapsed" else "Folder expanded") catch {};
    }

    fn openPalette(self: *GuiState) void {
        self.quick_panel.close();
        self.app.palette.open() catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.app.mode = .command;
        self.setMessage("Command palette") catch {};
    }

    fn closePalette(self: *GuiState) void {
        self.app.palette.close();
        if (self.app.mode == .command) self.app.mode = .normal;
    }

    fn executeSelectedPaletteCommand(self: *GuiState) void {
        const definition = self.app.palette.selected() orelse {
            self.setMessage("No command selected") catch {};
            return;
        };
        self.closePalette();
        self.executeCommand(definition.id);
    }

    fn switchDocument(self: *GuiState, index: usize) void {
        self.app.documents.switchTo(index) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.setMessage("Switched document") catch {};
    }

    fn switchDocumentByDelta(self: *GuiState, delta: isize) void {
        self.app.documents.moveActive(delta);
        self.app.focus = .editor;
        self.ensureCursorVisible();
        self.setMessage("Switched document") catch {};
    }

    fn executeCommand(self: *GuiState, id: []const u8) void {
        if (std.mem.eql(u8, id, "file.new")) {
            self.openNewFilePanel();
            return;
        }
        if (std.mem.eql(u8, id, "symbol.goto_symbol")) {
            self.openSymbolPanel();
            return;
        }
        if (std.mem.eql(u8, id, "symbol.goto_definition")) {
            self.gotoLocalDefinitionAtCursor();
            return;
        }
        if (std.mem.eql(u8, id, "workspace.find_file")) {
            self.openQuickPanel(.find_file);
            return;
        }
        if (std.mem.eql(u8, id, "workspace.search")) {
            self.openQuickPanel(.search_workspace);
            return;
        }
        if (std.mem.eql(u8, id, "git.overview") or std.mem.eql(u8, id, "github.overview")) {
            self.openGitPanel();
            return;
        }
        if (std.mem.eql(u8, id, "view.toggle_diagnostics")) {
            self.openDiagnosticsPanel();
            return;
        }

        const result = dispatcher.dispatch(&self.app, .{ .id = id, .source = .command_palette }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "command failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult(id, result);
        if (!std.mem.startsWith(u8, id, "editor.")) self.show_output = true;
    }

    fn runTaskByName(self: *GuiState, name: []const u8) void {
        const queued = dispatcher.dispatch(&self.app, .{ .id = "task.run", .argument = name, .source = .command_palette }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "task queue failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult("task.run", queued);
        if (std.meta.activeTag(queued) != .completed) return;

        const run_result = dispatcher.dispatch(&self.app, .{ .id = "task.run_next", .source = .task }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "task run failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult("task.run_next", run_result);
        self.show_output = true;
        self.bottom_panel = .output;
    }

    fn openTasksPanel(self: *GuiState) void {
        self.openQuickPanel(.run_task);
    }

    fn openNewFilePanel(self: *GuiState) void {
        self.openQuickPanel(.new_file);
    }

    fn openSymbolPanel(self: *GuiState) void {
        self.openQuickPanel(.document_symbols);
    }

    fn openDiagnosticsPanel(self: *GuiState) void {
        self.show_output = true;
        self.bottom_panel = .diagnostics;
        self.diagnostics_scroll_line = 0;
        self.setMessage("Diagnostics") catch {};
    }

    fn openSecurityPanel(self: *GuiState) void {
        self.show_output = true;
        self.bottom_panel = .security;
        self.security_scroll_line = 0;
        self.runZigSecurityAudit("manual");
        self.setMessage("Security findings") catch {};
    }

    fn openGitPanel(self: *GuiState) void {
        self.show_output = true;
        self.bottom_panel = .git;
        self.git_scroll_line = 0;
        self.refreshGitOverview();
    }

    fn refreshGitOverview(self: *GuiState) void {
        self.clearGitOverview();
        const overview = git_repository.inspect(self.allocator, &self.app.workspace, .{}) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "git overview failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.git_overview = overview;
        self.setMessage(if (overview.present) "Git overview" else "No Git repository") catch {};
    }

    fn clearGitOverview(self: *GuiState) void {
        if (self.git_overview) |*overview| {
            overview.deinit();
            self.git_overview = null;
        }
    }

    fn openQuickPanel(self: *GuiState, mode: QuickPanelMode) void {
        self.app.palette.close();
        self.quick_panel.open(mode, &self.app) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "quick panel failed: {s}\n", .{@errorName(err)});
            return;
        };
        if (mode == .search_workspace) {
            self.show_output = true;
            self.bottom_panel = .output;
        }
        self.setMessage(switch (mode) {
            .find_file => "Find file",
            .search_workspace => "Search workspace",
            .run_task => "Run task",
            .new_file => "New file",
            .document_symbols => "Document symbols",
        }) catch {};
    }

    fn quickPanelInsertText(self: *GuiState, bytes: []const u8) void {
        self.quick_panel.insertText(&self.app, bytes) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.refreshSearchPanelFromQuickPanel();
    }

    fn quickPanelDeleteBackward(self: *GuiState) void {
        self.quick_panel.deleteBackward(&self.app) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.refreshSearchPanelFromQuickPanel();
    }

    fn refreshSearchPanelFromQuickPanel(self: *GuiState) void {
        if (!self.quick_panel.visible or self.quick_panel.mode != .search_workspace) return;
        self.search_panel.refresh(&self.app, self.quick_panel.query.items) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "search refresh failed: {s}\n", .{@errorName(err)});
            return;
        };
    }

    fn executeSelectedQuickPanelItem(self: *GuiState) void {
        switch (self.quick_panel.mode) {
            .find_file => {
                const match = self.quick_panel.selectedFile() orelse {
                    self.setMessage("No file match") catch {};
                    return;
                };
                const path = match.path;
                self.quick_panel.close();
                self.openRelativeFile(path, null);
            },
            .search_workspace => {
                const item = self.quick_panel.selectedSearchResult() orelse {
                    self.setMessage("No search match") catch {};
                    return;
                };
                const path = self.allocator.dupe(u8, item.path) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(path);
                const offset = item.byte_offset;
                self.quick_panel.close();
                self.openRelativeFile(path, offset);
            },
            .run_task => {
                const item = self.quick_panel.selectedTask() orelse {
                    self.setMessage("No task selected") catch {};
                    return;
                };
                const name = self.allocator.dupe(u8, item.name) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(name);
                self.quick_panel.close();
                self.runTaskByName(name);
            },
            .new_file => {
                if (self.quick_panel.query.items.len == 0) {
                    self.setMessage("Type a workspace-relative path") catch {};
                    return;
                }
                const path = self.allocator.dupe(u8, self.quick_panel.query.items) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(path);
                self.quick_panel.close();
                const result = dispatcher.dispatch(&self.app, .{ .id = "file.new", .argument = path, .source = .command_palette }) catch |err| {
                    self.setError(err) catch {};
                    self.appendOutput(.stderr, "new file failed: {s}\n", .{@errorName(err)});
                    return;
                };
                self.handleDispatchResult("file.new", result);
                if (std.meta.activeTag(result) == .completed) {
                    self.syncCollapsedDirs();
                    self.app.mode = .insert;
                    self.app.focus = .editor;
                    self.ensureCursorVisible();
                }
            },
            .document_symbols => {
                const item = self.quick_panel.selectedSymbol() orelse {
                    self.setMessage("No symbol selected") catch {};
                    return;
                };
                const offset = item.byte_offset;
                self.quick_panel.close();
                self.jumpToActiveDocumentOffset(offset, "Opened symbol");
            },
        }
    }

    fn openSelectedSearchPanelItem(self: *GuiState) void {
        const item = self.search_panel.selectedResult() orelse {
            self.setMessage("No search result selected") catch {};
            return;
        };
        self.openRelativeFile(item.path, item.byte_offset);
    }

    fn openRelativeFile(self: *GuiState, relative: []const u8, offset: ?usize) void {
        const absolute = std.fs.path.join(self.allocator, &.{ self.app.workspace.root_path, relative }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer self.allocator.free(absolute);

        const index = self.app.documents.openFile(absolute) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "open failed: {s}: {s}\n", .{ relative, @errorName(err) });
            return;
        };

        const doc = &self.app.documents.documents.items[index];
        if (offset) |byte_offset| {
            const clamped = @min(byte_offset, doc.text.bytes.len);
            const position = doc.positionFromOffset(clamped) catch |err| {
                self.setError(err) catch {};
                return;
            };
            navigation.setCursor(doc, position);
        }

        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.setMessage("Opened file") catch {};
    }

    fn openRelativeLocation(self: *GuiState, relative: []const u8, line: usize, column: usize) void {
        const absolute = std.fs.path.join(self.allocator, &.{ self.app.workspace.root_path, relative }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer self.allocator.free(absolute);

        const index = self.app.documents.openFile(absolute) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "open failed: {s}: {s}\n", .{ relative, @errorName(err) });
            return;
        };
        const doc = &self.app.documents.documents.items[index];
        const offset = doc.text.lineColumnToOffset(line, column) catch |err| {
            self.setError(err) catch {};
            return;
        };
        const position = doc.positionFromOffset(offset) catch |err| {
            self.setError(err) catch {};
            return;
        };
        navigation.setCursor(doc, position);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.setMessage("Opened diagnostic") catch {};
    }

    fn jumpToActiveDocumentOffset(self: *GuiState, offset: usize, message: []const u8) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        const clamped = @min(offset, doc.text.bytes.len);
        const position = doc.positionFromOffset(clamped) catch |err| {
            self.setError(err) catch {};
            return;
        };
        navigation.setCursor(doc, position);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.setMessage(message) catch {};
    }

    fn gotoLocalDefinitionAtCursor(self: *GuiState) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        const name = identifierAtOffset(doc.text.bytes, doc.cursor.position.byte_offset) orelse {
            self.setMessage("No identifier under cursor") catch {};
            return;
        };
        const path = doc.path orelse "(scratch)";
        var index = symbols_mod.collectTopLevel(self.allocator, doc.text.bytes, path) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer index.deinit();

        for (index.symbols) |symbol| {
            if (!std.mem.eql(u8, symbol.name, name)) continue;
            navigation.setCursor(doc, symbol.range.start);
            self.app.focus = .editor;
            self.app.mode = .insert;
            self.ensureCursorVisible();
            self.setMessage("Jumped to definition") catch {};
            return;
        }

        self.setMessage("No local top-level definition") catch {};
    }

    fn jumpToNextDiagnostic(self: *GuiState) void {
        self.executeCommand("diagnostics.next");
        self.ensureCursorVisible();
    }

    fn jumpToDiagnostic(self: *GuiState, index: usize) void {
        if (index >= self.app.diagnostics.items.items.len) return;
        const diagnostic = self.app.diagnostics.items.items[index];
        self.openRelativeLocation(diagnostic.path, diagnostic.range.start.line, diagnostic.range.start.column);
    }

    fn jumpToSecurityFinding(self: *GuiState, index: usize) void {
        if (index >= self.app.security_findings.items.items.len) return;
        const finding = self.app.security_findings.items.items[index];
        if (finding.path.len == 0) {
            self.setMessage(finding.message) catch {};
            return;
        }
        self.openRelativeLocation(finding.path, finding.line, finding.column);
    }

    fn openConsoleLineAt(self: *GuiState, layout: Layout, y: c_int) void {
        const output = consoleOutputRect(layout, self);
        if (y < output.top + HEADER_HEIGHT or y >= output.bottom) {
            self.app.focus = .output;
            return;
        }

        const rows = @max(0, @divTrunc(output.bottom - output.top - HEADER_HEIGHT, ROW_HEIGHT));
        const lines = self.app.process_console.lines.items;
        const max_start = if (lines.len > @as(usize, @intCast(rows))) lines.len - @as(usize, @intCast(rows)) else 0;
        const start = @min(self.output_scroll_line, max_start);
        const row = @as(usize, @intCast(@divTrunc(y - output.top - HEADER_HEIGHT, ROW_HEIGHT)));
        if (start + row >= lines.len) {
            self.app.focus = .output;
            return;
        }

        const line = lines[start + row];
        const parsed = zig_output.parseLine(line.text) orelse {
            self.app.focus = .output;
            return;
        };
        self.openRelativeLocation(parsed.path, parsed.line, parsed.column);
    }

    fn openGitPanelRow(self: *GuiState, row: usize) void {
        const overview = self.git_overview orelse return;
        const workflow_start = gitPanelWorkflowStartRow(overview);
        if (row >= workflow_start and row < workflow_start + overview.workflow_paths.len) {
            self.openRelativeFile(overview.workflow_paths[row - workflow_start], null);
            return;
        }

        const change_row_start = gitPanelChangeStartRow(overview);
        if (row < change_row_start) return;
        const change_index = row - change_row_start;
        if (change_index >= overview.changes.len) return;
        const change = overview.changes[change_index];
        if (change.status == .deleted) {
            self.setMessage("Deleted file cannot be opened") catch {};
            return;
        }
        self.openRelativeFile(change.path, null);
    }

    fn handleDispatchResult(self: *GuiState, id: []const u8, result: dispatcher.Result) void {
        switch (result) {
            .completed => |message| {
                self.setMessage(message) catch {};
                self.appendOutput(.stdout, "{s}: {s}\n", .{ id, message });
                if (self.git_overview != null and (std.mem.eql(u8, id, "file.save") or std.mem.eql(u8, id, "file.new"))) {
                    self.refreshGitOverview();
                    self.setMessage(message) catch {};
                }
            },
            .blocked => |message| {
                self.setMessage(message) catch {};
                self.appendOutput(.stderr, "blocked {s}: {s}\n", .{ id, message });
                if (self.app.pending_build_consent) |preview| {
                    self.appendOutput(.stdout, "pending consent: {s}\n", .{preview.command});
                    self.appendOutput(.stdout, "run Security: Approve Build Consent after review, then Task: Run Approved Command\n", .{});
                }
            },
            .unknown_command => {
                self.setMessage("Unknown command") catch {};
                self.appendOutput(.stderr, "unknown command: {s}\n", .{id});
            },
            .no_active_document => {
                self.setMessage("No active document") catch {};
                self.appendOutput(.stderr, "{s}: no active document\n", .{id});
            },
            .unsupported => |message| {
                self.setMessage(message) catch {};
                self.appendOutput(.stderr, "unsupported {s}: {s}\n", .{ id, message });
            },
            .external_command => |spec| {
                var preview = build_consent.makePreview(self.allocator, spec, self.app.runtime.trust_state) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer preview.deinit();

                self.app.execution_queue.enqueueSpec(id, spec, preview.consent) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                self.appendOutput(.stdout, "queued external command: {s}\n", .{preview.command});

                const run_result = dispatcher.dispatch(&self.app, .{ .id = "task.run_next", .source = .task }) catch |err| {
                    self.setError(err) catch {};
                    self.appendOutput(.stderr, "run failed: {s}\n", .{@errorName(err)});
                    return;
                };
                self.handleDispatchResult("task.run_next", run_result);
            },
        }
    }

    fn appendOutput(self: *GuiState, stream: console_mod.Stream, comptime fmt: []const u8, args: anytype) void {
        var text: std.Io.Writer.Allocating = .init(self.allocator);
        defer text.deinit();
        text.writer.print(fmt, args) catch return;
        self.app.process_console.appendBytes(stream, text.written()) catch return;
    }

    fn setError(self: *GuiState, err: anyerror) !void {
        var buffer: [160]u8 = undefined;
        const message = try std.fmt.bufPrint(&buffer, "error: {s}", .{@errorName(err)});
        try self.setMessage(message);
    }

    fn setMessage(self: *GuiState, message: []const u8) !void {
        self.clearError();
        self.last_error = try self.allocator.dupe(u8, message);
    }

    fn clearError(self: *GuiState) void {
        if (self.last_error) |message| {
            self.allocator.free(message);
            self.last_error = null;
        }
    }

    fn insertText(self: *GuiState, bytes: []const u8) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("Open a file before typing") catch {};
            return;
        };
        doc.insert(doc.cursor.position.byte_offset, bytes) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.app.mode = .insert;
        self.app.focus = .editor;
        self.ensureCursorVisible();
    }

    fn undo(self: *GuiState) void {
        const doc = self.app.documents.active() orelse return;
        const changed = doc.undo() catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (changed) {
            const offset = @min(doc.cursor.position.byte_offset, doc.text.bytes.len);
            doc.cursor.position = doc.positionFromOffset(offset) catch doc.cursor.position;
            self.ensureCursorVisible();
            self.setMessage("Undo") catch {};
        } else {
            self.setMessage("Nothing to undo") catch {};
        }
    }

    fn redo(self: *GuiState) void {
        const doc = self.app.documents.active() orelse return;
        const changed = doc.redo() catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (changed) {
            const offset = @min(doc.cursor.position.byte_offset, doc.text.bytes.len);
            doc.cursor.position = doc.positionFromOffset(offset) catch doc.cursor.position;
            self.ensureCursorVisible();
            self.setMessage("Redo") catch {};
        } else {
            self.setMessage("Nothing to redo") catch {};
        }
    }

    fn closeActiveDocument(self: *GuiState) void {
        self.app.documents.closeActive(.deny_dirty) catch |err| {
            switch (err) {
                error.DirtyDocument => self.setMessage("Save before closing") catch {},
                else => self.setError(err) catch {},
            }
            return;
        };
        self.app.focus = if (self.app.documents.active() != null) .editor else .files;
        self.setMessage("Closed document") catch {};
    }

    fn deleteBackward(self: *GuiState) void {
        const doc = self.app.documents.active() orelse return;
        const current = doc.cursor.position.byte_offset;
        if (current == 0) return;
        const previous = doc.text.previousByteOffset(current) catch return;
        doc.deleteRange(previous, current) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.ensureCursorVisible();
    }

    fn deleteForward(self: *GuiState) void {
        const doc = self.app.documents.active() orelse return;
        const current = doc.cursor.position.byte_offset;
        const next = doc.text.nextByteOffset(current) catch return;
        if (next == current) return;
        doc.deleteRange(current, next) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.ensureCursorVisible();
    }

    fn moveCursor(self: *GuiState, move: navigation.Move) void {
        const doc = self.app.documents.active() orelse return;
        navigation.moveCursor(doc, move) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.app.focus = .editor;
        self.ensureCursorVisible();
    }

    fn setEditorCursorFromPoint(self: *GuiState, layout: Layout, x: c_int, y: c_int) void {
        const doc = self.app.documents.active() orelse return;
        if (!pointIn(layout.editor, x, y)) return;

        const text_x = layout.editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X;
        const text_y = layout.editor.top + HEADER_HEIGHT + EDITOR_TEXT_PADDING_Y;
        const rel_y = if (y <= text_y) 0 else y - text_y;
        const rel_x = if (x <= text_x) 0 else x - text_x;
        const line = self.editor_scroll_line + @as(usize, @intCast(@divTrunc(rel_y, ROW_HEIGHT)));
        const column = @as(usize, @intCast(@divTrunc(rel_x, CHAR_WIDTH)));
        const clamped_line = if (doc.text.lineCount() == 0) 0 else @min(line, doc.text.lineCount() - 1);
        const offset = doc.text.lineColumnToOffset(clamped_line, column) catch return;
        const position = doc.positionFromOffset(offset) catch return;
        navigation.setCursor(doc, position);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
    }

    fn ensureCursorVisible(self: *GuiState) void {
        const doc = self.app.documents.active() orelse return;
        if (doc.cursor.position.line < self.editor_scroll_line) {
            self.editor_scroll_line = doc.cursor.position.line;
        } else if (self.editor_visible_rows > 0 and doc.cursor.position.line >= self.editor_scroll_line + self.editor_visible_rows) {
            self.editor_scroll_line = doc.cursor.position.line - self.editor_visible_rows + 1;
        }
    }

    fn scrollEditor(self: *GuiState, delta: isize) void {
        const doc = self.app.documents.active() orelse return;
        if (delta < 0) {
            const amount = @as(usize, @intCast(-delta));
            self.editor_scroll_line = if (amount > self.editor_scroll_line) 0 else self.editor_scroll_line - amount;
        } else {
            const amount = @as(usize, @intCast(delta));
            const max_line = if (doc.text.lineCount() == 0) 0 else doc.text.lineCount() - 1;
            self.editor_scroll_line = @min(max_line, self.editor_scroll_line + amount);
        }
    }

    fn scrollOutput(self: *GuiState, delta: isize) void {
        const line_count = self.app.process_console.lines.items.len;
        if (delta < 0) {
            const amount = @as(usize, @intCast(-delta));
            self.output_scroll_line = if (amount > self.output_scroll_line) 0 else self.output_scroll_line - amount;
        } else {
            const amount = @as(usize, @intCast(delta));
            self.output_scroll_line = @min(line_count, self.output_scroll_line + amount);
        }
    }

    fn scrollBottomPanel(self: *GuiState, layout: Layout, delta: isize) void {
        switch (self.bottom_panel) {
            .output => self.scrollOutput(delta),
            .git => {
                const visible = bottomPanelVisibleRows(bottomPanelContentRect(layout.output));
                const total = if (self.git_overview) |overview| gitPanelRowCount(overview) else 0;
                scrollIndex(&self.git_scroll_line, total, visible, delta);
            },
            .diagnostics => {
                const visible = bottomPanelVisibleRows(bottomPanelContentRect(layout.output));
                scrollIndex(&self.diagnostics_scroll_line, self.app.diagnostics.items.items.len, visible, delta);
            },
            .security => {
                const visible = bottomPanelVisibleRows(bottomPanelContentRect(layout.output));
                scrollIndex(&self.security_scroll_line, self.app.security_findings.items.items.len, visible, delta);
            },
        }
    }

    fn visibleEntryCount(self: *const GuiState) usize {
        var count: usize = 0;
        for (self.app.workspace.entries.items, 0..) |_, index| {
            if (self.isEntryVisible(index)) count += 1;
        }
        return count;
    }

    fn visibleRankOfIndex(self: *const GuiState, target: usize) ?usize {
        var rank: usize = 0;
        for (self.app.workspace.entries.items, 0..) |_, index| {
            if (!self.isEntryVisible(index)) continue;
            if (index == target) return rank;
            rank += 1;
        }
        return null;
    }

    fn entryIndexAtVisibleRank(self: *const GuiState, target_rank: usize) ?usize {
        var rank: usize = 0;
        for (self.app.workspace.entries.items, 0..) |_, index| {
            if (!self.isEntryVisible(index)) continue;
            if (rank == target_rank) return index;
            rank += 1;
        }
        return null;
    }

    fn isEntryVisible(self: *const GuiState, index: usize) bool {
        if (index >= self.app.workspace.entries.items.len) return false;
        const entry = self.app.workspace.entries.items[index];
        if (entry.depth == 0) return true;

        var needed_depth = entry.depth;
        var i = index;
        while (i > 0) {
            i -= 1;
            const candidate = self.app.workspace.entries.items[i];
            if (candidate.depth >= needed_depth) continue;
            if (candidate.kind == .directory and i < self.collapsed_dirs.len and self.collapsed_dirs[i]) return false;
            needed_depth = candidate.depth;
            if (needed_depth == 0) break;
        }
        return true;
    }

    fn directoryHasChildren(self: *const GuiState, index: usize) bool {
        if (index + 1 >= self.app.workspace.entries.items.len) return false;
        const entry = self.app.workspace.entries.items[index];
        return self.app.workspace.entries.items[index + 1].depth > entry.depth;
    }

    fn click(self: *GuiState, hwnd: windows.HWND, x: c_int, y: c_int) void {
        _ = SetFocus(hwnd);
        const layout = layoutForWindow(hwnd, self);

        if (self.app.palette.visible) {
            const palette = paletteRect(layout.client);
            if (pointIn(palette, x, y)) {
                if (y >= palette.top + PALETTE_MATCH_TOP) {
                    const row = @as(usize, @intCast(@divTrunc(y - palette.top - PALETTE_MATCH_TOP, ROW_HEIGHT)));
                    if (row < @min(@as(usize, 10), self.app.palette.matches.items.len)) {
                        self.app.palette.selected_index = row;
                        self.executeSelectedPaletteCommand();
                    }
                }
                return;
            }
            self.closePalette();
            return;
        }

        if (self.quick_panel.visible) {
            const panel = paletteRect(layout.client);
            if (pointIn(panel, x, y)) {
                if (y >= panel.top + PALETTE_MATCH_TOP) {
                    const row = @as(usize, @intCast(@divTrunc(y - panel.top - PALETTE_MATCH_TOP, ROW_HEIGHT)));
                    if (row < @min(@as(usize, 10), self.quick_panel.itemCount())) {
                        self.quick_panel.selected_index = row;
                        self.executeSelectedQuickPanelItem();
                    }
                }
                return;
            }
            self.quick_panel.close();
            return;
        }

        if (pointIn(layout.sidebar, x, y)) {
            if (pointIn(newFileButtonRect(layout), x, y)) {
                self.openNewFilePanel();
                return;
            }
            if (pointIn(openWorkspaceButtonRect(layout), x, y)) {
                self.chooseAndOpenWorkspace(hwnd);
                return;
            }
            if (pointIn(gitAuditButtonRect(layout), x, y)) {
                self.executeCommand("git.overview");
                return;
            }

            self.app.focus = .files;
            const row = visibleFileRowAt(layout, self, y) orelse return;
            const index = self.entryIndexAtVisibleRank(row) orelse return;
            self.app.file_cursor = index;
            const entry = self.app.workspace.entries.items[index];
            if (entry.kind == .directory) {
                self.toggleDirectory(index);
            } else if (entry.kind == .file) {
                self.openSelected();
            }
            return;
        }

        if (pointIn(layout.editor, x, y)) {
            if (pointIn(saveButtonRect(layout), x, y)) {
                self.executeCommand("file.save");
                return;
            }
            if (pointIn(runButtonRect(layout), x, y)) {
                self.runTaskByName("run");
                return;
            }
            if (pointIn(testButtonRect(layout), x, y)) {
                self.runTaskByName("test");
                return;
            }
            if (pointIn(buildButtonRect(layout), x, y)) {
                self.runTaskByName("build");
                return;
            }
            if (pointIn(taskButtonRect(layout), x, y)) {
                self.openTasksPanel();
                return;
            }
            if (pointIn(diagButtonRect(layout), x, y)) {
                self.openDiagnosticsPanel();
                return;
            }
            if (pointIn(secButtonRect(layout), x, y)) {
                self.openSecurityPanel();
                return;
            }
            if (pointIn(symbolButtonRect(layout), x, y)) {
                self.openSymbolPanel();
                return;
            }
            if (documentTabAt(layout, self, x, y)) |index| {
                self.switchDocument(index);
                return;
            }
            if (y < HEADER_HEIGHT) return;
            self.setEditorCursorFromPoint(layout, x, y);
            return;
        }

        if (searchResultsRect(layout, self)) |rect| {
            if (pointIn(rect, x, y)) {
                const row = searchResultRowAt(rect, y) orelse return;
                if (row < self.search_panel.itemCount()) {
                    self.search_panel.selected_index = row;
                    self.openSelectedSearchPanelItem();
                }
                return;
            }
        }

        if (pointIn(layout.output, x, y)) {
            self.app.focus = .output;
            if (bottomPanelTabAt(layout.output, x, y)) |panel| {
                self.bottom_panel = panel;
                self.show_output = true;
                if (panel == .git and self.git_overview == null) self.refreshGitOverview();
                return;
            }
            switch (self.bottom_panel) {
                .output => self.openConsoleLineAt(layout, y),
                .git => if (bottomPanelRowAt(bottomPanelContentRect(layout.output), y)) |row| self.openGitPanelRow(self.git_scroll_line + row),
                .diagnostics => if (bottomPanelRowAt(bottomPanelContentRect(layout.output), y)) |row| self.jumpToDiagnostic(self.diagnostics_scroll_line + row),
                .security => if (bottomPanelRowAt(bottomPanelContentRect(layout.output), y)) |row| self.jumpToSecurityFinding(self.security_scroll_line + row),
            }
            return;
        }
    }
};

var global_state: ?*GuiState = null;

fn windowProc(hwnd: windows.HWND, msg: windows.UINT, wparam: WPARAM, lparam: windows.LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_KEYDOWN => {
            if (global_state) |state| {
                handleKeyDown(hwnd, state, wparam);
                _ = InvalidateRect(hwnd, null, .FALSE);
            }
            return 0;
        },
        WM_CHAR => {
            if (global_state) |state| {
                handleChar(state, wparam);
                _ = InvalidateRect(hwnd, null, .FALSE);
            }
            return 0;
        },
        WM_LBUTTONDOWN => {
            if (global_state) |state| {
                state.click(hwnd, mouseX(lparam), mouseY(lparam));
                _ = InvalidateRect(hwnd, null, .FALSE);
            }
            return 0;
        },
        WM_MOUSEWHEEL => {
            if (global_state) |state| {
                const delta = wheelDelta(wparam);
                if (state.app.focus == .output) {
                    state.scrollBottomPanel(layoutForWindow(hwnd, state), if (delta > 0) -3 else 3);
                } else if (state.app.focus == .editor) {
                    state.scrollEditor(if (delta > 0) -3 else 3);
                } else {
                    state.moveSelection(if (delta > 0) -3 else 3);
                }
                _ = InvalidateRect(hwnd, null, .FALSE);
            }
            return 0;
        },
        WM_SIZE => {
            _ = InvalidateRect(hwnd, null, .FALSE);
            return 0;
        },
        WM_PAINT => {
            paint(hwnd);
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn handleKeyDown(hwnd: windows.HWND, state: *GuiState, key: WPARAM) void {
    const ctrl = isKeyDown(VK_CONTROL);
    const shift = isKeyDown(VK_SHIFT);

    if (state.quick_panel.visible) {
        switch (key) {
            VK_ESCAPE => state.quick_panel.close(),
            VK_UP => state.quick_panel.moveSelection(-1),
            VK_DOWN => state.quick_panel.moveSelection(1),
            VK_RETURN => state.executeSelectedQuickPanelItem(),
            VK_BACK => state.quickPanelDeleteBackward(),
            else => {},
        }
        return;
    }

    if (state.app.palette.visible) {
        switch (key) {
            VK_ESCAPE => state.closePalette(),
            VK_UP => state.app.palette.moveSelection(-1),
            VK_DOWN => state.app.palette.moveSelection(1),
            VK_RETURN => state.executeSelectedPaletteCommand(),
            VK_BACK => state.app.palette.deleteBackward() catch |err| state.setError(err) catch {},
            else => {},
        }
        return;
    }

    if (ctrl and shift and key == 'P') {
        state.openPalette();
        return;
    }
    if (ctrl and shift and key == 'B') {
        state.openTasksPanel();
        return;
    }
    if (ctrl and shift and key == 'O') {
        state.openSymbolPanel();
        return;
    }
    if (ctrl and key == 'P') {
        state.openQuickPanel(.find_file);
        return;
    }
    if (ctrl and key == 'F') {
        state.openQuickPanel(.search_workspace);
        return;
    }
    if (key == VK_F1) {
        state.openPalette();
        return;
    }
    if (ctrl and key == 'S') {
        state.executeCommand("file.save");
        return;
    }
    if (ctrl and key == 'B') {
        state.runTaskByName("build");
        return;
    }
    if (ctrl and key == 'D') {
        state.openDiagnosticsPanel();
        return;
    }
    if (ctrl and key == 'T') {
        state.runTaskByName("test");
        return;
    }
    if (ctrl and key == 'R') {
        state.runTaskByName("run");
        return;
    }
    if (ctrl and key == 'G') {
        state.executeCommand("git.overview");
        return;
    }
    if (ctrl and key == 'O') {
        state.chooseAndOpenWorkspace(hwnd);
        return;
    }
    if (ctrl and key == 'N') {
        state.openNewFilePanel();
        return;
    }
    if (ctrl and key == 'W') {
        state.closeActiveDocument();
        return;
    }
    if (ctrl and key == 'Z') {
        state.undo();
        return;
    }
    if (ctrl and key == 'Y') {
        state.redo();
        return;
    }
    if (ctrl and key == VK_TAB) {
        state.switchDocumentByDelta(if (shift) -1 else 1);
        return;
    }
    if (key == VK_F8) {
        state.jumpToNextDiagnostic();
        return;
    }
    if (key == VK_F12) {
        state.executeCommand("symbol.goto_definition");
        return;
    }
    if (key == VK_F6) {
        state.show_output = !state.show_output;
        return;
    }

    switch (key) {
        VK_ESCAPE => {
            if (state.app.mode == .insert) {
                state.app.mode = .normal;
            } else {
                _ = DestroyWindow(hwnd);
            }
        },
        VK_RETURN => {
            if (state.app.focus == .files) {
                state.openSelected();
            } else if (state.app.mode == .insert) {
                state.insertText("\n");
            }
        },
        VK_TAB => {
            if (state.app.mode == .insert and state.app.focus == .editor) state.insertText("    ");
        },
        VK_BACK => {
            if (state.app.mode == .insert and state.app.focus == .editor) state.deleteBackward();
        },
        VK_DELETE => {
            if (state.app.mode == .insert and state.app.focus == .editor) state.deleteForward();
        },
        VK_LEFT => state.moveCursor(.left),
        VK_RIGHT => state.moveCursor(.right),
        VK_UP => if (state.app.focus == .files) state.moveSelection(-1) else state.moveCursor(.up),
        VK_DOWN => if (state.app.focus == .files) state.moveSelection(1) else state.moveCursor(.down),
        VK_HOME => state.moveCursor(.line_start),
        VK_END => state.moveCursor(.line_end),
        VK_PRIOR => if (state.app.focus == .editor) state.scrollEditor(-12) else state.moveSelection(-12),
        VK_NEXT => if (state.app.focus == .editor) state.scrollEditor(12) else state.moveSelection(12),
        'I' => {
            if (state.app.mode != .insert) {
                state.app.mode = .insert;
                state.app.focus = .editor;
            }
        },
        'J' => if (state.app.mode != .insert) state.moveSelection(1),
        'K' => if (state.app.mode != .insert) state.moveSelection(-1),
        'Q' => {
            if (state.app.mode != .insert) _ = DestroyWindow(hwnd);
        },
        else => {},
    }
}

fn handleChar(state: *GuiState, key: WPARAM) void {
    if (isKeyDown(VK_CONTROL)) return;
    const codepoint: u21 = @intCast(key);
    if (state.quick_panel.visible) {
        if (codepoint >= 0x20 and codepoint != 0x7f) {
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &buffer) catch return;
            state.quickPanelInsertText(buffer[0..len]);
        }
        return;
    }

    if (state.app.palette.visible) {
        if (codepoint >= 0x20 and codepoint != 0x7f) {
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &buffer) catch return;
            state.app.palette.insertText(buffer[0..len]) catch |err| state.setError(err) catch {};
        }
        return;
    }

    if (state.app.mode != .insert or state.app.focus != .editor) return;
    if (codepoint == '\r') {
        state.insertText("\n");
        return;
    }
    if (codepoint == '\t') {
        state.insertText("    ");
        return;
    }
    if (codepoint < 0x20 or codepoint == 0x7f) return;
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buffer) catch return;
    state.insertText(buffer[0..len]);
}

fn paint(hwnd: windows.HWND) void {
    var ps: PAINTSTRUCT = undefined;
    const hdc = BeginPaint(hwnd, &ps);
    defer _ = EndPaint(hwnd, &ps);

    const old_font = if (global_state) |state|
        if (state.text_font) |font| SelectObject(hdc, @ptrCast(font)) else null
    else
        null;
    defer {
        if (old_font) |font| _ = SelectObject(hdc, font);
    }

    var client: RECT = undefined;
    _ = GetClientRect(hwnd, &client);

    fillRect(hdc, client, rgb(12, 15, 18));

    if (global_state) |state| {
        const layout = layoutForClient(client, state);
        fillRect(hdc, layout.sidebar, rgb(15, 20, 24));
        fillRect(hdc, layout.editor, rgb(11, 13, 17));
        if (state.show_output) fillRect(hdc, layout.output, rgb(10, 12, 14));
        fillRect(hdc, layout.status, rgb(35, 142, 203));
        fillRect(hdc, RECT{ .left = layout.sidebar.right - 1, .top = 0, .right = layout.sidebar.right, .bottom = layout.status.top }, rgb(43, 53, 61));

        drawText(hdc, 18, 15, rgb(79, 230, 226), "FILES");
        drawButton(hdc, newFileButtonRect(layout), "NEW");
        drawButton(hdc, openWorkspaceButtonRect(layout), "OPEN");
        drawButton(hdc, gitAuditButtonRect(layout), "GIT");
        drawSecurityStrip(hdc, state, layout);
        drawFileList(hdc, state, layout);
        drawEditor(hdc, state, layout);
        if (state.show_output) drawOutput(hdc, state, layout);
        drawStatus(hdc, state, layout.status);
        if (state.app.palette.visible) drawCommandPalette(hdc, state, layout.client);
        if (state.quick_panel.visible) drawQuickPanel(hdc, state, layout.client);
    } else {
        drawText(hdc, 24, 24, rgb(235, 238, 242), "zide");
    }
}

fn drawFileList(hdc: windows.HDC, state: *GuiState, layout: Layout) void {
    const visible_rows = @max(0, @divTrunc(layout.sidebar.bottom - SIDEBAR_FILE_TOP - 10, ROW_HEIGHT));
    const visible_count = state.visibleEntryCount();
    const selected_rank = state.visibleRankOfIndex(state.app.file_cursor) orelse 0;
    const start = scrollStart(selected_rank, visible_count, @intCast(visible_rows));

    var y = SIDEBAR_FILE_TOP;
    var row: usize = 0;
    while (row < @as(usize, @intCast(visible_rows)) and start + row < visible_count) : (row += 1) {
        const index = state.entryIndexAtVisibleRank(start + row) orelse break;
        const entry = state.app.workspace.entries.items[index];
        const selected_row = index == state.app.file_cursor;
        if (selected_row) {
            fillRect(hdc, RECT{ .left = 0, .top = y - 1, .right = layout.sidebar.right - 1, .bottom = y + ROW_HEIGHT - 1 }, rgb(51, 153, 235));
        }

        const depth_px: usize = @min(entry.depth, @as(usize, 8)) * @as(usize, 16);
        const indent: c_int = @intCast(depth_px);
        const marker = switch (entry.kind) {
            .directory => if (state.directoryHasChildren(index) and !state.collapsed_dirs[index]) "- " else "+ ",
            .file => "  ",
            .other => "? ",
        };
        const color = if (selected_row)
            rgb(18, 20, 22)
        else switch (entry.kind) {
            .directory => rgb(229, 232, 236),
            .file => languageColor(entry.language),
            .other => rgb(121, 133, 145),
        };

        drawText(hdc, 16 + indent, y + 3, color, marker);
        drawTextClipped(hdc, 36 + indent, y + 3, layout.sidebar.right - 12, color, entry.path);
        if (gitMarkerForEntry(state, entry.path, entry.kind == .directory)) |git_marker| {
            drawTextRight(hdc, layout.sidebar.right - 34, y + 3, layout.sidebar.right - 12, gitChangeColor(git_marker.status), git_marker.label);
        }
        y += ROW_HEIGHT;
    }

    if (state.app.workspace.entries.items.len == 0) {
        drawText(hdc, 18, SIDEBAR_FILE_TOP + 4, rgb(140, 148, 158), "No files found");
    }
}

const GitMarker = struct {
    label: []const u8,
    status: git_repository.ChangeStatus,
};

fn gitMarkerForEntry(state: *const GuiState, entry_path: []const u8, is_directory: bool) ?GitMarker {
    const overview = state.git_overview orelse return null;
    if (!overview.present) return null;
    for (overview.changes) |change| {
        if (is_directory) {
            if (pathIsInsideDirectory(change.path, entry_path)) {
                return .{ .label = "*", .status = change.status };
            }
        } else if (pathMatches(entry_path, change.path)) {
            return .{ .label = gitChangeLabel(change.status), .status = change.status };
        }
    }
    return null;
}

fn pathIsInsideDirectory(path: []const u8, directory: []const u8) bool {
    if (directory.len == 0) return false;
    if (path.len <= directory.len) return false;
    var i: usize = 0;
    while (i < directory.len) : (i += 1) {
        if (!pathByteEqual(path[i], directory[i])) return false;
    }
    return path[directory.len] == '/' or path[directory.len] == '\\';
}

fn drawSecurityStrip(hdc: windows.HDC, state: *GuiState, layout: Layout) void {
    const rect = RECT{ .left = 10, .top = HEADER_HEIGHT, .right = layout.sidebar.right - 10, .bottom = SIDEBAR_FILE_TOP - 8 };
    fillRect(hdc, rect, rgb(18, 24, 29));
    const counts = riskCounts(&state.app.security_findings);
    const accent = if (counts.critical > 0)
        rgb(255, 90, 90)
    else if (counts.high > 0)
        rgb(255, 173, 82)
    else if (counts.medium > 0)
        rgb(255, 207, 92)
    else
        rgb(74, 222, 128);
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.left + 3, .bottom = rect.bottom }, accent);
    var buffer: [160]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buffer,
        "SEC c:{d} h:{d} m:{d}  diag:{d}",
        .{ counts.critical, counts.high, counts.medium, state.app.diagnostics.items.items.len },
    ) catch "SEC";
    drawTextClipped(hdc, rect.left + 10, rect.top + 7, rect.right - 8, rgb(210, 219, 228), text);
}

fn drawEditor(hdc: windows.HDC, state: *GuiState, layout: Layout) void {
    const editor = layout.editor;
    drawEditorHeader(hdc, state, layout);
    const active = state.app.documents.active();
    if (active) |doc| {
        fillRect(hdc, RECT{ .left = editor.left, .top = HEADER_HEIGHT, .right = editor.left + GUTTER_WIDTH, .bottom = editor.bottom }, rgb(14, 18, 23));

        const max_rows = @max(0, @divTrunc(editor.bottom - HEADER_HEIGHT - 8, ROW_HEIGHT));
        state.editor_visible_rows = @as(usize, @intCast(max_rows));
        var visible_line: usize = 0;
        var y = HEADER_HEIGHT + EDITOR_TEXT_PADDING_Y;
        while (visible_line < @as(usize, @intCast(max_rows)) and state.editor_scroll_line + visible_line < doc.text.lineCount()) : (visible_line += 1) {
            const line = state.editor_scroll_line + visible_line;
            var number_buf: [32]u8 = undefined;
            const number = std.fmt.bufPrint(&number_buf, "{d}", .{line + 1}) catch "";
            const current_line = line == doc.cursor.position.line;
            const marker = editorLineMarker(state, doc.path, line);
            if (marker.hasAny()) {
                fillRect(hdc, RECT{ .left = editor.left + GUTTER_WIDTH, .top = y - 2, .right = editor.right, .bottom = y + ROW_HEIGHT - 2 }, markerBackgroundColor(marker));
                fillRect(hdc, RECT{ .left = editor.left + GUTTER_WIDTH - 5, .top = y - 2, .right = editor.left + GUTTER_WIDTH - 1, .bottom = y + ROW_HEIGHT - 2 }, markerStripeColor(marker));
            }
            if (current_line) {
                fillRect(hdc, RECT{ .left = editor.left + GUTTER_WIDTH, .top = y - 2, .right = editor.right, .bottom = y + ROW_HEIGHT - 2 }, rgb(20, 27, 34));
            }
            drawTextRight(hdc, editor.left + 10, y, editor.left + GUTTER_WIDTH - 12, rgb(105, 116, 128), number);
            drawHighlightedLine(
                hdc,
                state,
                doc.language,
                editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X,
                y,
                editor.right - 20,
                doc.text.lineSlice(line),
            );
            if (current_line) {
                const caret_x = editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X + @as(c_int, @intCast(doc.cursor.position.column)) * CHAR_WIDTH;
                fillRect(hdc, RECT{ .left = caret_x, .top = y - 2, .right = caret_x + 2, .bottom = y + ROW_HEIGHT - 4 }, rgb(255, 255, 255));
            }
            y += ROW_HEIGHT;
        }
    } else {
        drawText(hdc, editor.left + 22, HEADER_HEIGHT + 10, rgb(199, 206, 214), "Click a file to open it.");
        drawText(hdc, editor.left + 22, HEADER_HEIGHT + 38, rgb(126, 138, 150), "F1 opens commands. Ctrl+S saves. Ctrl+B prepares build.");
    }
}

fn drawEditorHeader(hdc: windows.HDC, state: *GuiState, layout: Layout) void {
    drawButton(hdc, saveButtonRect(layout), "SAVE");
    drawButton(hdc, buildButtonRect(layout), "BUILD");
    drawButton(hdc, testButtonRect(layout), "TEST");
    drawButton(hdc, runButtonRect(layout), "RUN");
    drawButton(hdc, taskButtonRect(layout), "TASK");
    drawButton(hdc, diagButtonRect(layout), "DIAG");
    drawButton(hdc, secButtonRect(layout), "SEC");
    drawButton(hdc, symbolButtonRect(layout), "SYM");

    const active_index = state.app.documents.activeIndex();
    const max_right = documentTabMaxRight(layout);
    var index: usize = 0;
    while (index < state.app.documents.documents.items.len) : (index += 1) {
        const rect = documentTabRect(layout, index);
        if (rect.left >= max_right) break;
        const clipped = RECT{ .left = rect.left, .top = rect.top, .right = @min(rect.right, max_right), .bottom = rect.bottom };
        const active = active_index != null and active_index.? == index;
        fillRect(hdc, clipped, if (active) rgb(51, 153, 235) else rgb(27, 34, 41));
        if (active) fillRect(hdc, RECT{ .left = clipped.left, .top = clipped.top, .right = clipped.right, .bottom = clipped.top + 1 }, rgb(255, 207, 92));

        const doc = state.app.documents.documents.items[index];
        const path = doc.path orelse "untitled";
        var label_buf: [220]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "{s}{s}", .{ std.fs.path.basename(path), if (doc.dirty) "*" else "" }) catch path;
        drawTextClipped(hdc, clipped.left + 10, clipped.top + 5, clipped.right - 8, if (active) rgb(16, 19, 22) else rgb(220, 226, 232), label);
    }

    if (state.app.documents.documents.items.len == 0) {
        drawText(hdc, layout.editor.left + 22, 15, rgb(79, 230, 226), "zide workbench");
    }
}

const EditorLineMarker = struct {
    severity: ?types.Severity = null,
    risk: ?findings_mod.Risk = null,

    fn hasAny(self: EditorLineMarker) bool {
        return self.severity != null or self.risk != null;
    }
};

fn editorLineMarker(state: *const GuiState, document_path: ?[]const u8, line: usize) EditorLineMarker {
    const path = document_path orelse return .{};
    var marker = EditorLineMarker{};

    for (state.app.diagnostics.items.items) |item| {
        if (item.range.start.line != line) continue;
        if (!pathMatches(path, item.path)) continue;
        if (marker.severity == null or severityRank(item.severity) > severityRank(marker.severity.?)) {
            marker.severity = item.severity;
        }
    }

    for (state.app.security_findings.items.items) |item| {
        if (item.line != line) continue;
        if (!pathMatches(path, item.path)) continue;
        if (marker.risk == null or riskRank(item.risk) > riskRank(marker.risk.?)) {
            marker.risk = item.risk;
        }
    }

    return marker;
}

fn markerStripeColor(marker: EditorLineMarker) windows.COLORREF {
    if (marker.risk) |risk| return riskColor(risk);
    if (marker.severity) |severity| return severityColor(severity);
    return rgb(121, 133, 145);
}

fn markerBackgroundColor(marker: EditorLineMarker) windows.COLORREF {
    if (marker.risk) |risk| {
        return switch (risk) {
            .critical, .high => rgb(39, 19, 24),
            .medium => rgb(38, 30, 16),
            .low, .info => rgb(18, 28, 34),
        };
    }
    if (marker.severity) |severity| {
        return switch (severity) {
            .err => rgb(39, 19, 24),
            .warning => rgb(38, 30, 16),
            .info => rgb(18, 28, 34),
        };
    }
    return rgb(20, 27, 34);
}

fn drawHighlightedLine(hdc: windows.HDC, state: *GuiState, mode: modes.LanguageMode, x: c_int, y: c_int, right: c_int, line: []const u8) void {
    if (right <= x) return;
    if (!modes.isCode(mode) and mode != .json and mode != .yaml and mode != .toml and mode != .xml and mode != .sql) {
        drawTextClipped(hdc, x, y, right, rgb(224, 229, 235), line);
        return;
    }

    const spans = highlight.collectLine(state.allocator, line, mode) catch {
        drawTextClipped(hdc, x, y, right, rgb(224, 229, 235), line);
        return;
    };
    defer state.allocator.free(spans);

    if (spans.len == 0) {
        drawTextClipped(hdc, x, y, right, rgb(224, 229, 235), line);
        return;
    }

    for (spans) |span| {
        if (span.end <= span.start or span.start >= line.len) continue;
        const segment = line[span.start..@min(span.end, line.len)];
        const segment_x = x + @as(c_int, @intCast(displayCells(line[0..span.start]) * CHAR_WIDTH));
        if (segment_x >= right) break;
        drawTextClipped(hdc, segment_x, y, right, highlightColor(span.role), segment);
    }
}

fn highlightColor(role: highlight.Role) windows.COLORREF {
    return switch (role) {
        .plain => rgb(224, 229, 235),
        .keyword => rgb(119, 190, 255),
        .type_name => rgb(255, 207, 128),
        .string => rgb(165, 214, 167),
        .number => rgb(255, 190, 130),
        .comment => rgb(121, 133, 145),
        .doc_comment => rgb(145, 170, 150),
        .builtin => rgb(218, 169, 255),
        .operator, .punctuation => rgb(174, 184, 194),
        .unsafe_boundary => rgb(255, 118, 118),
    };
}

fn drawOutput(hdc: windows.HDC, state: *GuiState, layout: Layout) void {
    drawBottomPanelTabs(hdc, state, layout.output);
    const content = bottomPanelContentRect(layout.output);
    switch (state.bottom_panel) {
        .output => {
            if (searchResultsRect(layout, state)) |rect| {
                drawSearchResults(hdc, state, rect);
            }
            drawConsoleOutput(hdc, state, consoleOutputRect(layout, state));
        },
        .git => drawGitPanel(hdc, state, content),
        .diagnostics => drawDiagnosticsPanel(hdc, state, content),
        .security => drawSecurityPanel(hdc, state, content),
    }
}

fn drawBottomPanelTabs(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + HEADER_HEIGHT }, rgb(12, 16, 20));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));
    drawBottomPanelTab(hdc, rect, .output, state.bottom_panel == .output, "OUTPUT");
    drawBottomPanelTab(hdc, rect, .git, state.bottom_panel == .git, "GIT");
    drawBottomPanelTab(hdc, rect, .diagnostics, state.bottom_panel == .diagnostics, "DIAG");
    drawBottomPanelTab(hdc, rect, .security, state.bottom_panel == .security, "SEC");
}

fn drawBottomPanelTab(hdc: windows.HDC, rect: RECT, panel: BottomPanel, active: bool, label: []const u8) void {
    const tab = bottomPanelTabRect(rect, panel);
    fillRect(hdc, tab, if (active) rgb(51, 153, 235) else rgb(27, 34, 41));
    if (active) fillRect(hdc, RECT{ .left = tab.left, .top = tab.top, .right = tab.right, .bottom = tab.top + 1 }, rgb(255, 207, 92));
    drawTextClipped(hdc, tab.left + 10, tab.top + 5, tab.right - 8, if (active) rgb(16, 19, 22) else rgb(220, 226, 232), label);
}

fn drawConsoleOutput(hdc: windows.HDC, state: *GuiState, output: RECT) void {
    fillRect(hdc, RECT{ .left = output.left, .top = output.top, .right = output.right, .bottom = output.top + 1 }, rgb(43, 53, 61));
    drawText(hdc, output.left + 16, output.top + 10, rgb(79, 230, 226), "OUTPUT");

    const lines = state.app.process_console.lines.items;
    const rows = @max(0, @divTrunc(output.bottom - output.top - HEADER_HEIGHT, ROW_HEIGHT));
    const max_start = if (lines.len > @as(usize, @intCast(rows))) lines.len - @as(usize, @intCast(rows)) else 0;
    const start = @min(state.output_scroll_line, max_start);
    var y = output.top + HEADER_HEIGHT;
    var row: usize = 0;
    while (row < @as(usize, @intCast(rows)) and start + row < lines.len) : (row += 1) {
        const line = lines[start + row];
        const color = switch (line.stream) {
            .stdout => rgb(200, 207, 216),
            .stderr => rgb(255, 125, 125),
        };
        drawTextClipped(hdc, output.left + 16, y, output.right - 16, color, line.text);
        y += ROW_HEIGHT;
    }

    if (lines.len == 0) {
        drawText(hdc, output.left + 16, output.top + HEADER_HEIGHT, rgb(116, 128, 140), "No output yet");
    }
}

fn drawGitPanel(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, rect, rgb(10, 12, 14));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));

    const overview = state.git_overview orelse {
        drawText(hdc, rect.left + 16, rect.top + 10, rgb(79, 230, 226), "GIT");
        drawText(hdc, rect.left + 16, rect.top + HEADER_HEIGHT, rgb(116, 128, 140), "Click GIT or press Ctrl+G to inspect this workspace");
        return;
    };

    if (!overview.present) {
        drawText(hdc, rect.left + 16, rect.top + 10, rgb(79, 230, 226), "GIT");
        drawText(hdc, rect.left + 16, rect.top + HEADER_HEIGHT, rgb(116, 128, 140), "No Git metadata found");
        return;
    }

    var header_buf: [260]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "GIT  branch:{s} changes:{d} remotes:{d} workflows:{d}",
        .{ overview.branch orelse "(detached)", overview.changes.len, overview.remotes.len, overview.workflow_files },
    ) catch "GIT";
    drawTextClipped(hdc, rect.left + 16, rect.top + 10, rect.right - 16, rgb(79, 230, 226), header);

    const rows = @max(0, @divTrunc(rect.bottom - rect.top - HEADER_HEIGHT, ROW_HEIGHT));
    const total_rows = gitPanelRowCount(overview);
    const start = @min(state.git_scroll_line, if (total_rows > @as(usize, @intCast(rows))) total_rows - @as(usize, @intCast(rows)) else 0);
    var y = rect.top + HEADER_HEIGHT;
    var row: usize = 0;
    while (row < @as(usize, @intCast(rows)) and start + row < total_rows) : (row += 1) {
        drawGitPanelRow(hdc, rect, overview, start + row, y);
        y += ROW_HEIGHT;
    }
}

fn drawGitPanelRow(hdc: windows.HDC, rect: RECT, overview: git_repository.Overview, row: usize, y: c_int) void {
    if (row == 0) {
        if (overview.commit) |commit| {
            drawTextClipped(hdc, rect.left + 16, y, rect.right - 16, rgb(180, 190, 200), commit);
        } else {
            drawText(hdc, rect.left + 16, y, rgb(116, 128, 140), "No commit resolved");
        }
        return;
    }

    var current: usize = 1;
    for (overview.remotes) |remote| {
        if (row == current) {
            var remote_buf: [520]u8 = undefined;
            const text = std.fmt.bufPrint(&remote_buf, "remote {s}: {s}", .{ remote.name, remote.url }) catch remote.url;
            drawTextClipped(hdc, rect.left + 16, y, rect.right - 16, rgb(210, 218, 226), text);
            return;
        }
        current += 1;
        if (remote.github) |github| {
            if (row == current) {
                drawTextClipped(hdc, rect.left + 34, y, rect.right - 16, rgb(127, 211, 255), github.web_url);
                return;
            }
            current += 1;
            if (row == current) {
                drawTextClipped(hdc, rect.left + 34, y, rect.right - 16, rgb(127, 211, 255), github.actions_url);
                return;
            }
            current += 1;
        }
    }

    if (row == current) {
        var workflow_buf: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&workflow_buf, "GitHub Actions workflows: {d}", .{overview.workflow_paths.len}) catch "GitHub Actions workflows";
        drawText(hdc, rect.left + 16, y, rgb(255, 207, 92), text);
        return;
    }
    current += 1;

    for (overview.workflow_paths) |path| {
        if (row == current) {
            drawTextClipped(hdc, rect.left + 34, y, rect.right - 16, rgb(127, 211, 255), path);
            return;
        }
        current += 1;
    }

    if (row == current) {
        if (overview.changes.len == 0) {
            drawText(hdc, rect.left + 16, y, rgb(116, 128, 140), "Working tree appears clean against the Git index");
        } else {
            drawText(hdc, rect.left + 16, y, rgb(255, 207, 92), "Changes");
        }
        return;
    }
    current += 1;

    const change_index = row - current;
    if (change_index >= overview.changes.len) return;
    const change = overview.changes[change_index];
    const color = gitChangeColor(change.status);
    drawText(hdc, rect.left + 16, y, color, gitChangeLabel(change.status));
    var stats_buf: [48]u8 = undefined;
    const stats = if (change.diff_available)
        std.fmt.bufPrint(&stats_buf, "+{d} -{d}", .{ change.additions, change.deletions }) catch ""
    else
        "diff n/a";
    drawTextClipped(hdc, rect.left + 52, y, rect.right - 120, color, change.path);
    drawTextRight(hdc, rect.right - 112, y, rect.right - 16, color, stats);
}

fn gitPanelRowCount(overview: git_repository.Overview) usize {
    var count: usize = 1;
    for (overview.remotes) |remote| {
        count += 1;
        if (remote.github != null) count += 2;
    }
    count += 1 + overview.workflow_paths.len;
    count += 1 + overview.changes.len;
    return count;
}

fn gitPanelWorkflowStartRow(overview: git_repository.Overview) usize {
    var row: usize = 2;
    for (overview.remotes) |remote| {
        row += 1;
        if (remote.github != null) row += 2;
    }
    return row;
}

fn gitPanelChangeStartRow(overview: git_repository.Overview) usize {
    return gitPanelWorkflowStartRow(overview) + overview.workflow_paths.len + 1;
}

fn gitChangeLabel(status: git_repository.ChangeStatus) []const u8 {
    return switch (status) {
        .modified => "M ",
        .deleted => "D ",
        .untracked => "??",
    };
}

fn gitChangeColor(status: git_repository.ChangeStatus) windows.COLORREF {
    return switch (status) {
        .modified => rgb(255, 207, 92),
        .deleted => rgb(255, 118, 118),
        .untracked => rgb(127, 211, 255),
    };
}

fn drawDiagnosticsPanel(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, rect, rgb(10, 12, 14));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));

    var header_buf: [160]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "DIAGNOSTICS  total:{d}", .{state.app.diagnostics.items.items.len}) catch "DIAGNOSTICS";
    drawText(hdc, rect.left + 16, rect.top + 10, rgb(79, 230, 226), header);

    const rows = @max(0, @divTrunc(rect.bottom - rect.top - HEADER_HEIGHT, ROW_HEIGHT));
    const start = @min(state.diagnostics_scroll_line, if (state.app.diagnostics.items.items.len > @as(usize, @intCast(rows))) state.app.diagnostics.items.items.len - @as(usize, @intCast(rows)) else 0);
    var y = rect.top + HEADER_HEIGHT;
    var row: usize = 0;
    while (row < @as(usize, @intCast(rows)) and start + row < state.app.diagnostics.items.items.len) : (row += 1) {
        const item = state.app.diagnostics.items.items[start + row];
        const color = severityColor(item.severity);
        var location_buf: [360]u8 = undefined;
        const location = std.fmt.bufPrint(&location_buf, "{s}:{d}:{d} [{s}/{s}]", .{
            item.path,
            item.range.start.line + 1,
            item.range.start.column + 1,
            @tagName(item.severity),
            @tagName(item.source),
        }) catch item.path;
        drawTextClipped(hdc, rect.left + 16, y, rect.left + 390, color, location);
        drawTextClipped(hdc, rect.left + 400, y, rect.right - 16, rgb(210, 218, 226), item.message);
        y += ROW_HEIGHT;
    }

    if (state.app.diagnostics.items.items.len == 0) {
        drawText(hdc, rect.left + 16, rect.top + HEADER_HEIGHT, rgb(116, 128, 140), "No diagnostics yet");
    }
}

fn drawSecurityPanel(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, rect, rgb(10, 12, 14));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));

    const counts = riskCounts(&state.app.security_findings);
    var header_buf: [220]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "SECURITY  total:{d} critical:{d} high:{d} medium:{d} low:{d}",
        .{ state.app.security_findings.items.items.len, counts.critical, counts.high, counts.medium, counts.low },
    ) catch "SECURITY";
    drawText(hdc, rect.left + 16, rect.top + 10, rgb(79, 230, 226), header);

    const rows = @max(0, @divTrunc(rect.bottom - rect.top - HEADER_HEIGHT, ROW_HEIGHT));
    const start = @min(state.security_scroll_line, if (state.app.security_findings.items.items.len > @as(usize, @intCast(rows))) state.app.security_findings.items.items.len - @as(usize, @intCast(rows)) else 0);
    var y = rect.top + HEADER_HEIGHT;
    var row: usize = 0;
    while (row < @as(usize, @intCast(rows)) and start + row < state.app.security_findings.items.items.len) : (row += 1) {
        const item = state.app.security_findings.items.items[start + row];
        const color = riskColor(item.risk);
        var location_buf: [360]u8 = undefined;
        const location = std.fmt.bufPrint(&location_buf, "{s}:{d}:{d} [{s}/{s}]", .{
            item.path,
            item.line + 1,
            item.column + 1,
            @tagName(item.risk),
            @tagName(item.category),
        }) catch item.path;
        drawTextClipped(hdc, rect.left + 16, y, rect.left + 390, color, location);
        drawTextClipped(hdc, rect.left + 400, y, rect.right - 16, rgb(210, 218, 226), item.message);
        y += ROW_HEIGHT;
    }

    if (state.app.security_findings.items.items.len == 0) {
        drawText(hdc, rect.left + 16, rect.top + HEADER_HEIGHT, rgb(116, 128, 140), "No security findings");
    }
}

fn drawSearchResults(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, rect, rgb(13, 17, 21));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));
    drawText(hdc, rect.left + 16, rect.top + 10, rgb(79, 230, 226), "SEARCH RESULTS");
    drawTextClipped(hdc, rect.left + 150, rect.top + 10, rect.right - 16, rgb(180, 190, 200), state.search_panel.query.items);

    const items = state.search_panel.results orelse {
        drawText(hdc, rect.left + 16, rect.top + HEADER_HEIGHT, rgb(116, 128, 140), "No matches");
        return;
    };

    const rows = @max(0, @divTrunc(rect.bottom - rect.top - HEADER_HEIGHT, ROW_HEIGHT));
    var row: usize = 0;
    var y = rect.top + HEADER_HEIGHT;
    while (row < @as(usize, @intCast(rows)) and row < items.len) : (row += 1) {
        const selected = row == state.search_panel.selected_index;
        if (selected) {
            fillRect(hdc, RECT{ .left = rect.left + 8, .top = y - 2, .right = rect.right - 8, .bottom = y + ROW_HEIGHT - 2 }, rgb(51, 153, 235));
        }
        const color = if (selected) rgb(16, 19, 22) else rgb(205, 213, 222);
        const item = items[row];
        var location_buf: [320]u8 = undefined;
        const location = std.fmt.bufPrint(&location_buf, "{s}:{d}:{d}", .{ item.path, item.line + 1, item.column + 1 }) catch item.path;
        drawTextClipped(hdc, rect.left + 18, y, rect.left + 320, color, location);
        drawTextClipped(hdc, rect.left + 330, y, rect.right - 16, color, item.preview);
        y += ROW_HEIGHT;
    }
}

fn drawCommandPalette(hdc: windows.HDC, state: *GuiState, client: RECT) void {
    const palette = paletteRect(client);
    fillRect(hdc, palette, rgb(22, 26, 31));
    fillRect(hdc, RECT{ .left = palette.left, .top = palette.top, .right = palette.right, .bottom = palette.top + 1 }, rgb(79, 230, 226));
    drawText(hdc, palette.left + 16, palette.top + 14, rgb(79, 230, 226), "COMMAND");
    drawTextClipped(hdc, palette.left + 16, palette.top + 44, palette.right - 16, rgb(235, 239, 244), state.app.palette.query.items);

    var y = palette.top + PALETTE_MATCH_TOP;
    const max_matches: usize = 10;
    var row: usize = 0;
    while (row < max_matches and row < state.app.palette.matches.items.len) : (row += 1) {
        const match = state.app.palette.matches.items[row];
        const selected = row == state.app.palette.selected_index;
        if (selected) {
            fillRect(hdc, RECT{ .left = palette.left + 8, .top = y - 3, .right = palette.right - 8, .bottom = y + ROW_HEIGHT - 3 }, rgb(51, 153, 235));
        }
        const color = if (selected) rgb(16, 19, 22) else rgb(219, 225, 232);
        drawTextClipped(hdc, palette.left + 18, y, palette.right - 130, color, match.definition.title);
        drawTextClipped(hdc, palette.right - 124, y, palette.right - 16, color, match.definition.default_key);
        y += ROW_HEIGHT;
    }
}

fn drawQuickPanel(hdc: windows.HDC, state: *GuiState, client: RECT) void {
    const panel = paletteRect(client);
    fillRect(hdc, panel, rgb(22, 26, 31));
    fillRect(hdc, RECT{ .left = panel.left, .top = panel.top, .right = panel.right, .bottom = panel.top + 1 }, rgb(79, 230, 226));

    const title = switch (state.quick_panel.mode) {
        .find_file => "FIND FILE",
        .search_workspace => "SEARCH",
        .run_task => "TASKS",
        .new_file => "NEW FILE",
        .document_symbols => "SYMBOLS",
    };
    drawText(hdc, panel.left + 16, panel.top + 14, rgb(79, 230, 226), title);
    drawTextClipped(hdc, panel.left + 16, panel.top + 44, panel.right - 16, rgb(235, 239, 244), state.quick_panel.query.items);

    var y = panel.top + PALETTE_MATCH_TOP;
    const max_matches: usize = 10;
    const count = @min(max_matches, state.quick_panel.itemCount());
    var row: usize = 0;
    while (row < count) : (row += 1) {
        const selected = row == state.quick_panel.selected_index;
        if (selected) {
            fillRect(hdc, RECT{ .left = panel.left + 8, .top = y - 3, .right = panel.right - 8, .bottom = y + ROW_HEIGHT - 3 }, rgb(51, 153, 235));
        }
        const color = if (selected) rgb(16, 19, 22) else rgb(219, 225, 232);

        switch (state.quick_panel.mode) {
            .find_file => {
                const items = state.quick_panel.file_matches orelse break;
                const item = items[row];
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 112, color, item.path);
                drawTextClipped(hdc, panel.right - 106, y, panel.right - 16, color, modes.label(item.language));
            },
            .search_workspace => {
                const items = state.quick_panel.search_results orelse break;
                const item = items[row];
                var location_buf: [320]u8 = undefined;
                const location = std.fmt.bufPrint(&location_buf, "{s}:{d}:{d}", .{ item.path, item.line + 1, item.column + 1 }) catch item.path;
                drawTextClipped(hdc, panel.left + 18, y, panel.left + 300, color, location);
                drawTextClipped(hdc, panel.left + 310, y, panel.right - 16, color, item.preview);
            },
            .run_task => {
                const items = state.quick_panel.task_matches orelse break;
                const item = items[row];
                drawTextClipped(hdc, panel.left + 18, y, panel.left + 180, color, item.name);
                drawTextClipped(hdc, panel.left + 190, y, panel.right - 16, color, item.executable);
            },
            .new_file => {
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "Create inside workspace");
            },
            .document_symbols => {
                const items = state.quick_panel.symbol_matches orelse break;
                const item = items[row];
                var location_buf: [64]u8 = undefined;
                const location = std.fmt.bufPrint(&location_buf, "{d}:{d}", .{ item.line + 1, item.column + 1 }) catch "";
                drawTextClipped(hdc, panel.left + 18, y, panel.left + 240, color, item.name);
                drawTextClipped(hdc, panel.left + 250, y, panel.left + 390, color, @tagName(item.kind));
                drawTextClipped(hdc, panel.left + 400, y, panel.right - 16, color, location);
            },
        }
        y += ROW_HEIGHT;
    }

    if (state.quick_panel.itemCount() == 0) {
        drawText(hdc, panel.left + 18, y, rgb(126, 138, 150), "No matches");
    }
}

fn drawStatus(hdc: windows.HDC, state: *GuiState, status: RECT) void {
    var buffer: [512]u8 = undefined;
    const mode = @tagName(state.app.mode);
    const focus = @tagName(state.app.focus);
    const message = state.last_error orelse "ready";
    const cursor = if (state.app.documents.active()) |doc| doc.cursor.position else null;
    const dirty = if (state.app.documents.active()) |doc| doc.dirty else false;
    const language = if (state.app.documents.active()) |doc| modes.label(doc.language) else "none";
    const current_risk = currentDocumentRiskCounts(state);
    const git_changes = if (state.git_overview) |overview| overview.changes.len else 0;
    const text = std.fmt.bufPrint(
        &buffer,
        " {s}/{s}  |  line:{d} col:{d} {s} lang:{s} risk:{d}/{d}/{d} git:{d} | files:{d} code:{d} langs:{d} docs:{d} zig:{d} output:{s} | {s}",
        .{
            mode,
            focus,
            if (cursor) |position| position.line + 1 else 0,
            if (cursor) |position| position.column + 1 else 0,
            if (dirty) "dirty" else "clean",
            language,
            current_risk.critical,
            current_risk.high,
            current_risk.medium,
            git_changes,
            state.app.workspace.entries.items.len,
            state.app.workspace.countCodeFiles(),
            state.app.workspace.countRecognizedLanguages(),
            state.app.documents.documents.items.len,
            state.app.workspace.countZigFamily(),
            if (state.show_output) "on" else "off",
            message,
        },
    ) catch "zide";
    drawTextClipped(hdc, status.left + 8, status.top + 7, status.right - 8, rgb(22, 31, 38), text);
}

fn scrollStart(selected: usize, total: usize, visible: usize) usize {
    if (total <= visible or visible == 0) return 0;
    const half = visible / 2;
    if (selected <= half) return 0;
    const max_start = total - visible;
    return @min(selected - half, max_start);
}

fn scrollIndex(index: *usize, total: usize, visible: usize, delta: isize) void {
    const max_start = if (total > visible) total - visible else 0;
    if (delta < 0) {
        const amount = @as(usize, @intCast(-delta));
        index.* = if (amount > index.*) 0 else index.* - amount;
    } else {
        index.* = @min(max_start, index.* + @as(usize, @intCast(delta)));
    }
}

const Layout = struct {
    client: RECT,
    sidebar: RECT,
    editor: RECT,
    output: RECT,
    status: RECT,
};

fn layoutForWindow(hwnd: windows.HWND, state: *const GuiState) Layout {
    var client: RECT = undefined;
    _ = GetClientRect(hwnd, &client);
    return layoutForClient(client, state);
}

fn layoutForClient(client: RECT, state: *const GuiState) Layout {
    const width = client.right - client.left;
    const height = client.bottom - client.top;
    const sidebar_width = @min(@max(@divTrunc(width, 4), 280), 380);
    const output_height = if (state.show_output) @min(@max(@divTrunc(height, 4), 150), 240) else 0;
    const status_top = height - STATUS_HEIGHT;
    const editor_bottom = status_top - output_height;

    return .{
        .client = client,
        .sidebar = .{ .left = 0, .top = 0, .right = sidebar_width, .bottom = status_top },
        .editor = .{ .left = sidebar_width, .top = 0, .right = width, .bottom = editor_bottom },
        .output = .{ .left = sidebar_width, .top = editor_bottom, .right = width, .bottom = status_top },
        .status = .{ .left = 0, .top = status_top, .right = width, .bottom = height },
    };
}

fn visibleFileRowAt(layout: Layout, state: *const GuiState, y: c_int) ?usize {
    if (y < SIDEBAR_FILE_TOP or y >= layout.sidebar.bottom) return null;
    const visible_rows = @max(0, @divTrunc(layout.sidebar.bottom - SIDEBAR_FILE_TOP - 10, ROW_HEIGHT));
    const visible_count = state.visibleEntryCount();
    const selected_rank = state.visibleRankOfIndex(state.app.file_cursor) orelse 0;
    const start = scrollStart(selected_rank, visible_count, @intCast(visible_rows));
    const row = @as(usize, @intCast(@divTrunc(y - SIDEBAR_FILE_TOP, ROW_HEIGHT)));
    if (row >= @as(usize, @intCast(visible_rows))) return null;
    if (start + row >= visible_count) return null;
    return start + row;
}

fn openWorkspaceButtonRect(layout: Layout) RECT {
    return .{
        .left = layout.sidebar.right - 142,
        .top = 10,
        .right = layout.sidebar.right - 72,
        .bottom = 32,
    };
}

fn newFileButtonRect(layout: Layout) RECT {
    return .{
        .left = layout.sidebar.right - 204,
        .top = 10,
        .right = layout.sidebar.right - 148,
        .bottom = 32,
    };
}

fn gitAuditButtonRect(layout: Layout) RECT {
    return .{
        .left = layout.sidebar.right - 66,
        .top = 10,
        .right = layout.sidebar.right - 12,
        .bottom = 32,
    };
}

fn toolbarButtonRect(layout: Layout, slot_from_right: c_int) RECT {
    const width: c_int = 54;
    const gap: c_int = 8;
    const right = layout.editor.right - 12 - slot_from_right * (width + gap);
    return .{
        .left = right - width,
        .top = 10,
        .right = right,
        .bottom = 32,
    };
}

fn saveButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 0);
}

fn runButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 1);
}

fn testButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 2);
}

fn buildButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 3);
}

fn taskButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 4);
}

fn diagButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 5);
}

fn secButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 6);
}

fn symbolButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 7);
}

fn documentTabMaxRight(layout: Layout) c_int {
    return symbolButtonRect(layout).left - 10;
}

fn documentTabRect(layout: Layout, index: usize) RECT {
    const width: c_int = 150;
    const gap: c_int = 4;
    const left = layout.editor.left + 12 + @as(c_int, @intCast(index)) * (width + gap);
    return .{
        .left = left,
        .top = 9,
        .right = left + width,
        .bottom = 33,
    };
}

fn documentTabAt(layout: Layout, state: *const GuiState, x: c_int, y: c_int) ?usize {
    const max_right = documentTabMaxRight(layout);
    for (state.app.documents.documents.items, 0..) |_, index| {
        var rect = documentTabRect(layout, index);
        if (rect.left >= max_right) break;
        rect.right = @min(rect.right, max_right);
        if (pointIn(rect, x, y)) return index;
    }
    return null;
}

fn searchResultsRect(layout: Layout, state: *const GuiState) ?RECT {
    if (!state.show_output or !state.search_panel.visible) return null;
    if (state.bottom_panel != .output) return null;
    if (layout.output.bottom - layout.output.top < 160) return null;
    const content = bottomPanelContentRect(layout.output);
    const height = @min(@max(@divTrunc(content.bottom - content.top, 2), 110), 170);
    return .{
        .left = content.left,
        .top = content.top,
        .right = content.right,
        .bottom = content.top + height,
    };
}

fn consoleOutputRect(layout: Layout, state: *const GuiState) RECT {
    if (searchResultsRect(layout, state)) |search_rect| {
        return .{
            .left = layout.output.left,
            .top = search_rect.bottom,
            .right = layout.output.right,
            .bottom = layout.output.bottom,
        };
    }
    return bottomPanelContentRect(layout.output);
}

fn searchResultRowAt(rect: RECT, y: c_int) ?usize {
    if (y < rect.top + HEADER_HEIGHT or y >= rect.bottom) return null;
    return @as(usize, @intCast(@divTrunc(y - rect.top - HEADER_HEIGHT, ROW_HEIGHT)));
}

fn bottomPanelRowAt(rect: RECT, y: c_int) ?usize {
    if (y < rect.top + HEADER_HEIGHT or y >= rect.bottom) return null;
    return @as(usize, @intCast(@divTrunc(y - rect.top - HEADER_HEIGHT, ROW_HEIGHT)));
}

fn bottomPanelContentRect(rect: RECT) RECT {
    return .{ .left = rect.left, .top = rect.top + HEADER_HEIGHT, .right = rect.right, .bottom = rect.bottom };
}

fn bottomPanelVisibleRows(rect: RECT) usize {
    return @as(usize, @intCast(@max(0, @divTrunc(rect.bottom - rect.top - HEADER_HEIGHT, ROW_HEIGHT))));
}

fn bottomPanelTabRect(rect: RECT, panel: BottomPanel) RECT {
    const width: c_int = 82;
    const gap: c_int = 6;
    const index: c_int = switch (panel) {
        .output => 0,
        .git => 1,
        .diagnostics => 2,
        .security => 3,
    };
    const left = rect.left + 12 + index * (width + gap);
    return .{ .left = left, .top = rect.top + 9, .right = left + width, .bottom = rect.top + 33 };
}

fn bottomPanelTabAt(rect: RECT, x: c_int, y: c_int) ?BottomPanel {
    if (y < rect.top or y >= rect.top + HEADER_HEIGHT) return null;
    const panels = [_]BottomPanel{ .output, .git, .diagnostics, .security };
    for (panels) |panel| {
        if (pointIn(bottomPanelTabRect(rect, panel), x, y)) return panel;
    }
    return null;
}

fn pointIn(rect: RECT, x: c_int, y: c_int) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
}

fn paletteRect(client: RECT) RECT {
    const width = @min(@max(client.right - client.left - 220, 420), 760);
    const left = client.left + @divTrunc((client.right - client.left) - width, 2);
    const top: c_int = 70;
    return .{ .left = left, .top = top, .right = left + width, .bottom = top + 360 };
}

fn mouseX(lparam: windows.LPARAM) c_int {
    const bits: usize = @bitCast(lparam);
    return @as(c_int, @as(i16, @bitCast(@as(u16, @truncate(bits)))));
}

fn mouseY(lparam: windows.LPARAM) c_int {
    const bits: usize = @bitCast(lparam);
    return @as(c_int, @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))));
}

fn wheelDelta(wparam: WPARAM) i16 {
    return @as(i16, @bitCast(@as(u16, @truncate(wparam >> 16))));
}

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

fn identifierAtOffset(source: []const u8, offset: usize) ?[]const u8 {
    if (source.len == 0) return null;
    var at = @min(offset, source.len - 1);
    if (!isIdentifierByte(source[at])) {
        if (offset == 0) return null;
        at = @min(offset - 1, source.len - 1);
        if (!isIdentifierByte(source[at])) return null;
    }

    var start = at;
    while (start > 0 and isIdentifierByte(source[start - 1])) : (start -= 1) {}
    var end = at + 1;
    while (end < source.len and isIdentifierByte(source[end])) : (end += 1) {}
    if (start == end) return null;
    return source[start..end];
}

fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isKeyDown(vk: c_int) bool {
    return (@as(u16, @bitCast(GetKeyState(vk))) & 0x8000) != 0;
}

fn drawText(hdc: windows.HDC, x: c_int, y: c_int, color: windows.COLORREF, text: []const u8) void {
    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetTextColor(hdc, color);
    if (text.len == 0) return;

    const clipped = clipUtf8BytePrefix(text, MAX_DRAW_TEXT_BYTES);
    var utf16: [MAX_DRAW_TEXT_BYTES]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(&utf16, clipped) catch {
        drawAsciiFallback(hdc, x, y, clipped);
        return;
    };
    if (len == 0) return;
    _ = TextOutW(hdc, x, y, utf16[0..len].ptr, @intCast(len));
}

fn drawTextClipped(hdc: windows.HDC, x: c_int, y: c_int, right: c_int, color: windows.COLORREF, text: []const u8) void {
    if (right <= x) return;
    const available_columns: usize = @intCast(@max(@divTrunc(right - x, CHAR_WIDTH), 1));
    const clipped = clipTextCells(text, available_columns);
    drawText(hdc, x, y, color, clipped);
}

fn drawTextRight(hdc: windows.HDC, left: c_int, y: c_int, right: c_int, color: windows.COLORREF, text: []const u8) void {
    const width: c_int = @intCast(displayCells(text) * CHAR_WIDTH);
    drawText(hdc, @max(left, right - width), y, color, text);
}

fn drawButton(hdc: windows.HDC, rect: RECT, label: []const u8) void {
    fillRect(hdc, rect, rgb(32, 42, 50));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(79, 230, 226));
    drawTextClipped(hdc, rect.left + 10, rect.top + 5, rect.right - 6, rgb(226, 234, 242), label);
}

fn createTextFont() ?HFONT {
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
    return CreateFontW(
        -16,
        0,
        0,
        0,
        FW_NORMAL,
        0,
        0,
        0,
        DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY,
        FIXED_PITCH | FF_MODERN,
        face.ptr,
    );
}

fn drawAsciiFallback(hdc: windows.HDC, x: c_int, y: c_int, text: []const u8) void {
    var buffer: [MAX_DRAW_TEXT_BYTES]u16 = undefined;
    const len = @min(text.len, buffer.len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const byte = text[i];
        buffer[i] = if (byte >= 0x20 and byte < 0x7f) @as(u16, byte) else replacement_char;
    }
    if (len == 0) return;
    _ = TextOutW(hdc, x, y, buffer[0..len].ptr, @intCast(len));
}

fn clipTextCells(text: []const u8, max_cells: usize) []const u8 {
    if (max_cells == 0 or text.len == 0) return "";
    var view = std.unicode.Wtf8View.init(text) catch {
        return clipUtf8BytePrefix(text, max_cells);
    };
    var iter = view.iterator();
    var cells: usize = 0;
    var end: usize = 0;
    while (iter.nextCodepointSlice()) |slice| {
        const width: usize = if (slice.len == 1 and slice[0] < 0x80) 1 else 2;
        if (cells + width > max_cells) break;
        cells += width;
        end += slice.len;
        if (end >= MAX_DRAW_TEXT_BYTES) break;
    }
    return text[0..end];
}

fn clipUtf8BytePrefix(text: []const u8, max_bytes: usize) []const u8 {
    if (max_bytes == 0) return "";
    if (text.len <= max_bytes) return text;
    var end = max_bytes;
    while (end > 0 and isUtf8Continuation(text[end])) : (end -= 1) {}
    return text[0..end];
}

fn displayCells(text: []const u8) usize {
    var view = std.unicode.Wtf8View.init(text) catch return text.len;
    var iter = view.iterator();
    var cells: usize = 0;
    while (iter.nextCodepointSlice()) |slice| {
        cells += if (slice.len == 1 and slice[0] < 0x80) 1 else 2;
    }
    return cells;
}

fn fillRect(hdc: windows.HDC, rect: RECT, color: windows.COLORREF) void {
    const brush = CreateSolidBrush(color) orelse return;
    defer _ = DeleteObject(@ptrCast(brush));
    var mutable = rect;
    _ = FillRect(hdc, &mutable, brush);
}

fn rgb(r: u8, g: u8, b: u8) windows.COLORREF {
    return @as(windows.COLORREF, r) | (@as(windows.COLORREF, g) << 8) | (@as(windows.COLORREF, b) << 16);
}

fn severityColor(severity: @import("../core/types.zig").Severity) windows.COLORREF {
    return switch (severity) {
        .err => rgb(255, 118, 118),
        .warning => rgb(255, 207, 92),
        .info => rgb(127, 211, 255),
    };
}

fn severityRank(severity: types.Severity) u8 {
    return switch (severity) {
        .info => 0,
        .warning => 1,
        .err => 2,
    };
}

fn riskColor(risk: findings_mod.Risk) windows.COLORREF {
    return switch (risk) {
        .critical => rgb(255, 90, 90),
        .high => rgb(255, 148, 82),
        .medium => rgb(255, 207, 92),
        .low => rgb(127, 211, 255),
        .info => rgb(149, 163, 178),
    };
}

fn pathMatches(document_path: []const u8, candidate: []const u8) bool {
    if (candidate.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(document_path, candidate)) return true;
    return pathEndsWithNormalized(document_path, candidate);
}

fn pathEndsWithNormalized(path: []const u8, suffix: []const u8) bool {
    if (suffix.len > path.len) return false;
    var path_index = path.len;
    var suffix_index = suffix.len;
    while (suffix_index > 0) {
        if (path_index == 0) return false;
        path_index -= 1;
        suffix_index -= 1;
        if (!pathByteEqual(path[path_index], suffix[suffix_index])) return false;
    }
    if (path_index == 0) return true;
    return path[path_index - 1] == '/' or path[path_index - 1] == '\\';
}

fn pathByteEqual(left: u8, right: u8) bool {
    if ((left == '/' or left == '\\') and (right == '/' or right == '\\')) return true;
    return std.ascii.toLower(left) == std.ascii.toLower(right);
}

fn languageColor(mode: modes.LanguageMode) windows.COLORREF {
    return switch (modes.family(mode)) {
        .zig => rgb(63, 217, 84),
        .native => rgb(255, 183, 89),
        .script => rgb(233, 137, 255),
        .web => rgb(90, 196, 255),
        .data => rgb(151, 210, 143),
        .config => rgb(255, 207, 92),
        .prose => rgb(205, 211, 217),
        .unknown => rgb(121, 133, 145),
    };
}

fn chooseFolder(allocator: std.mem.Allocator, owner: windows.HWND) !?[]u8 {
    const hr = OleInitialize(null);
    const ole_initialized = hr >= 0;
    defer if (ole_initialized) OleUninitialize();

    const title = std.unicode.utf8ToUtf16LeStringLiteral("Open workspace folder");
    var display_name: [MAX_PATH]u16 = [_]u16{0} ** MAX_PATH;
    var info = BROWSEINFOW{
        .hwndOwner = owner,
        .pidlRoot = null,
        .pszDisplayName = display_name[0..].ptr,
        .lpszTitle = title.ptr,
        .ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE,
        .lpfn = null,
        .lParam = 0,
        .iImage = 0,
    };

    const pidl = SHBrowseForFolderW(&info) orelse return null;
    defer CoTaskMemFree(@ptrCast(pidl));

    var path: [MAX_PATH]u16 = [_]u16{0} ** MAX_PATH;
    if (SHGetPathFromIDListW(pidl, path[0..].ptr) == .FALSE) return error.FolderPathUnavailable;
    const len = utf16ZLen(&path);
    if (len == 0) return null;
    return try std.unicode.utf16LeToUtf8Alloc(allocator, path[0..len]);
}

fn utf16ZLen(buffer: []const u16) usize {
    for (buffer, 0..) |value, index| {
        if (value == 0) return index;
    }
    return buffer.len;
}

const RiskCounts = struct {
    info: usize = 0,
    low: usize = 0,
    medium: usize = 0,
    high: usize = 0,
    critical: usize = 0,
};

fn riskCounts(collection: *const findings_mod.Collection) RiskCounts {
    var counts = RiskCounts{};
    for (collection.items.items) |item| {
        switch (item.risk) {
            .info => counts.info += 1,
            .low => counts.low += 1,
            .medium => counts.medium += 1,
            .high => counts.high += 1,
            .critical => counts.critical += 1,
        }
    }
    return counts;
}

fn currentDocumentRiskCounts(state: *GuiState) RiskCounts {
    const doc = state.app.documents.active() orelse return .{};
    const path = doc.path orelse return .{};
    var counts = RiskCounts{};
    for (state.app.security_findings.items.items) |item| {
        if (!pathMatches(path, item.path)) continue;
        switch (item.risk) {
            .info => counts.info += 1,
            .low => counts.low += 1,
            .medium => counts.medium += 1,
            .high => counts.high += 1,
            .critical => counts.critical += 1,
        }
    }
    return counts;
}

fn riskRank(risk: findings_mod.Risk) u8 {
    return switch (risk) {
        .info => 0,
        .low => 1,
        .medium => 2,
        .high => 3,
        .critical => 4,
    };
}

const RECT = extern struct {
    left: c_int,
    top: c_int,
    right: c_int,
    bottom: c_int,
};

const POINT = extern struct {
    x: c_long,
    y: c_long,
};

const MSG = extern struct {
    hwnd: ?windows.HWND,
    message: windows.UINT,
    wParam: WPARAM,
    lParam: windows.LPARAM,
    time: windows.DWORD,
    pt: POINT,
};

const PAINTSTRUCT = extern struct {
    hdc: windows.HDC,
    fErase: windows.BOOL,
    rcPaint: RECT,
    fRestore: windows.BOOL,
    fIncUpdate: windows.BOOL,
    rgbReserved: [32]u8,
};

const WNDPROC = *const fn (windows.HWND, windows.UINT, WPARAM, windows.LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: windows.UINT,
    style: windows.UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: windows.HINSTANCE,
    hIcon: ?windows.HICON,
    hCursor: ?windows.HCURSOR,
    hbrBackground: ?windows.HBRUSH,
    lpszMenuName: ?windows.LPCWSTR,
    lpszClassName: windows.LPCWSTR,
    hIconSm: ?windows.HICON,
};

const ITEMIDLIST = opaque {};
const BFFCALLBACK = *const fn (?windows.HWND, windows.UINT, windows.LPARAM, windows.LPARAM) callconv(.winapi) c_int;

const BROWSEINFOW = extern struct {
    hwndOwner: ?windows.HWND,
    pidlRoot: ?*const ITEMIDLIST,
    pszDisplayName: [*]u16,
    lpszTitle: ?windows.LPCWSTR,
    ulFlags: windows.UINT,
    lpfn: ?BFFCALLBACK,
    lParam: windows.LPARAM,
    iImage: c_int,
};

const HGDIOBJ = *opaque {};
const HFONT = *opaque {};
const WPARAM = windows.ULONG_PTR;
const LRESULT = windows.LONG_PTR;
const HRESULT = c_long;

const STATUS_HEIGHT: c_int = 30;
const HEADER_HEIGHT: c_int = 42;
const SIDEBAR_FILE_TOP: c_int = 78;
const GUTTER_WIDTH: c_int = 58;
const ROW_HEIGHT: c_int = 22;
const CHAR_WIDTH: c_int = 8;
const EDITOR_TEXT_PADDING_X: c_int = 16;
const EDITOR_TEXT_PADDING_Y: c_int = 7;
const PALETTE_MATCH_TOP: c_int = 78;
const MAX_PATH: usize = 260;
const MAX_DRAW_TEXT_BYTES: usize = 4096;
const replacement_char: u16 = 0xFFFD;

const CS_HREDRAW: windows.UINT = 0x0002;
const CS_VREDRAW: windows.UINT = 0x0001;
const BIF_RETURNONLYFSDIRS: windows.UINT = 0x0001;
const BIF_NEWDIALOGSTYLE: windows.UINT = 0x0040;
const CW_USEDEFAULT: c_int = -2147483648;
const IDC_ARROW: windows.LPCWSTR = @ptrFromInt(32512);
const SW_SHOW: c_int = 5;
const TRANSPARENT: c_int = 1;
const WS_OVERLAPPEDWINDOW: windows.DWORD = 0x00CF0000;
const FW_NORMAL: c_int = 400;
const DEFAULT_CHARSET: windows.DWORD = 1;
const OUT_DEFAULT_PRECIS: windows.DWORD = 0;
const CLIP_DEFAULT_PRECIS: windows.DWORD = 0;
const CLEARTYPE_QUALITY: windows.DWORD = 5;
const FIXED_PITCH: windows.DWORD = 0x01;
const FF_MODERN: windows.DWORD = 0x30;

const WM_DESTROY: windows.UINT = 0x0002;
const WM_SIZE: windows.UINT = 0x0005;
const WM_PAINT: windows.UINT = 0x000F;
const WM_KEYDOWN: windows.UINT = 0x0100;
const WM_CHAR: windows.UINT = 0x0102;
const WM_LBUTTONDOWN: windows.UINT = 0x0201;
const WM_MOUSEWHEEL: windows.UINT = 0x020A;
const VK_BACK: WPARAM = 0x08;
const VK_TAB: WPARAM = 0x09;
const VK_RETURN: WPARAM = 0x0D;
const VK_SHIFT: c_int = 0x10;
const VK_CONTROL: c_int = 0x11;
const VK_ESCAPE: WPARAM = 0x1B;
const VK_PRIOR: WPARAM = 0x21;
const VK_NEXT: WPARAM = 0x22;
const VK_END: WPARAM = 0x23;
const VK_HOME: WPARAM = 0x24;
const VK_LEFT: WPARAM = 0x25;
const VK_UP: WPARAM = 0x26;
const VK_RIGHT: WPARAM = 0x27;
const VK_DOWN: WPARAM = 0x28;
const VK_DELETE: WPARAM = 0x2E;
const VK_F1: WPARAM = 0x70;
const VK_F6: WPARAM = 0x75;
const VK_F8: WPARAM = 0x77;
const VK_F12: WPARAM = 0x7B;

extern "kernel32" fn GetModuleHandleW(lpModuleName: ?windows.LPCWSTR) callconv(.winapi) ?windows.HMODULE;

extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) windows.ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: windows.DWORD,
    lpClassName: windows.LPCWSTR,
    lpWindowName: windows.LPCWSTR,
    dwStyle: windows.DWORD,
    x: c_int,
    y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?windows.HWND,
    hMenu: ?windows.HMENU,
    hInstance: windows.HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?windows.HWND;
extern "user32" fn DefWindowProcW(hWnd: windows.HWND, Msg: windows.UINT, wParam: WPARAM, lParam: windows.LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn DestroyWindow(hWnd: windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn SetWindowTextW(hWnd: windows.HWND, lpString: windows.LPCWSTR) callconv(.winapi) windows.BOOL;
extern "user32" fn SetFocus(hWnd: windows.HWND) callconv(.winapi) ?windows.HWND;
extern "user32" fn GetKeyState(nVirtKey: c_int) callconv(.winapi) c_short;
extern "user32" fn ShowWindow(hWnd: windows.HWND, nCmdShow: c_int) callconv(.winapi) windows.BOOL;
extern "user32" fn UpdateWindow(hWnd: windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?windows.HWND, wMsgFilterMin: windows.UINT, wMsgFilterMax: windows.UINT) callconv(.winapi) windows.BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) windows.BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
extern "user32" fn BeginPaint(hWnd: windows.HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) windows.HDC;
extern "user32" fn EndPaint(hWnd: windows.HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) windows.BOOL;
extern "user32" fn InvalidateRect(hWnd: windows.HWND, lpRect: ?*const RECT, bErase: windows.BOOL) callconv(.winapi) windows.BOOL;
extern "user32" fn GetClientRect(hWnd: windows.HWND, lpRect: *RECT) callconv(.winapi) windows.BOOL;
extern "user32" fn LoadCursorW(hInstance: ?windows.HINSTANCE, lpCursorName: windows.LPCWSTR) callconv(.winapi) ?windows.HCURSOR;
extern "user32" fn FillRect(hDC: windows.HDC, lprc: *const RECT, hbr: windows.HBRUSH) callconv(.winapi) c_int;

extern "shell32" fn SHBrowseForFolderW(lpbi: *BROWSEINFOW) callconv(.winapi) ?*ITEMIDLIST;
extern "shell32" fn SHGetPathFromIDListW(pidl: *const ITEMIDLIST, pszPath: [*]u16) callconv(.winapi) windows.BOOL;
extern "ole32" fn OleInitialize(pvReserved: ?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn OleUninitialize() callconv(.winapi) void;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

extern "gdi32" fn SetTextColor(hdc: windows.HDC, crColor: windows.COLORREF) callconv(.winapi) windows.COLORREF;
extern "gdi32" fn SetBkMode(hdc: windows.HDC, mode: c_int) callconv(.winapi) c_int;
extern "gdi32" fn TextOutW(hdc: windows.HDC, x: c_int, y: c_int, lpString: [*]const u16, c: c_int) callconv(.winapi) windows.BOOL;
extern "gdi32" fn CreateFontW(
    cHeight: c_int,
    cWidth: c_int,
    cEscapement: c_int,
    cOrientation: c_int,
    cWeight: c_int,
    bItalic: windows.DWORD,
    bUnderline: windows.DWORD,
    bStrikeOut: windows.DWORD,
    iCharSet: windows.DWORD,
    iOutPrecision: windows.DWORD,
    iClipPrecision: windows.DWORD,
    iQuality: windows.DWORD,
    iPitchAndFamily: windows.DWORD,
    pszFaceName: windows.LPCWSTR,
) callconv(.winapi) ?HFONT;
extern "gdi32" fn SelectObject(hdc: windows.HDC, h: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
extern "gdi32" fn CreateSolidBrush(color: windows.COLORREF) callconv(.winapi) ?windows.HBRUSH;
extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(.winapi) windows.BOOL;
