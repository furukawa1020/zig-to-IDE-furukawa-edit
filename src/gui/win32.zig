const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const app_mod = @import("../core/app.zig");
const command_mod = @import("../core/command.zig");
const dispatcher = @import("../core/dispatcher.zig");
const types = @import("../core/types.zig");
const document_mod = @import("../editor/document.zig");
const multi_cursor_mod = @import("../editor/multi_cursor.zig");
const navigation = @import("../editor/navigation.zig");
const extension_registry = @import("../extensions/registry.zig");
const git_repository = @import("../git/repository.zig");
const git_source_control = @import("../git/source_control.zig");
const github_state_mod = @import("../github/state.zig");
const zig_output = @import("../diagnostics/zig_output.zig");
const highlight = @import("../language/highlight.zig");
const lsp_responses = @import("../lsp/responses.zig");
const lsp_session = @import("../lsp/session.zig");
const modes = @import("../language/modes.zig");
const completion_mod = @import("../language/completion.zig");
const symbols_mod = @import("../language/symbols.zig");
const file_finder = @import("../search/file_finder.zig");
const literal_search = @import("../search/literal.zig");
const problems_search = @import("../search/problems.zig");
const workspace_search = @import("../search/workspace_search.zig");
const workspace_replace = @import("../search/workspace_replace.zig");
const workspace_symbols = @import("../search/workspace_symbols.zig");
const workspace_watcher = @import("../workspace/watcher.zig");
const build_consent = @import("../security/build_consent.zig");
const findings_mod = @import("../security/findings.zig");
const text_integrity = @import("../security/text_integrity.zig");
const console_mod = @import("../tasks/console.zig");
const task_registry = @import("../tasks/registry.zig");
const debug_session = @import("../debug/session.zig");
const goto_line = @import("goto_line.zig");

const QuickPanelMode = enum {
    find_file,
    find_document,
    replace_document,
    rename_symbol,
    goto_line,
    search_workspace,
    replace_workspace,
    run_task,
    new_file,
    new_folder,
    rename_path,
    delete_path,
    git_commit,
    git_branch_switch,
    git_branch_create,
    github_pr,
    document_symbols,
    workspace_symbols,
    lsp_actions,
    lsp_locations,
    problems,
    completion,
    lsp_hover,
    code_actions,
    language_mode,
    recovery,
    debug_watch,
    debug_breakpoint,
    debug_breakpoint_condition,
    debug_breakpoint_hit,
    debug_breakpoint_log,
    debug_functions,
    debug_data,
    debug_low_level,
    debug_exceptions,
};

const BottomPanel = enum {
    output,
    debug,
    git,
    extensions,
    diagnostics,
    security,
    settings,
    keybindings,
    tutorial,
    publish,
};

const DebugPanelAction = enum {
    configure,
    start,
    continue_execution,
    pause,
    step_over,
    step_into,
    step_out,
    breakpoint,
    advanced_breakpoint,
    low_level,
    watch,
    stop,
    status,
};

const PendingLspAction = enum {
    none,
    completion,
    goto_definition,
    goto_implementation,
    goto_type_definition,
    find_references,
    hover,
    rename_preview,
    formatting_preview,
    code_actions,
};

const GitPanelAction = enum {
    refresh,
    status,
    diff,
    stage_all,
    unstage_all,
    commit,
    branch_switch,
    branch_create,
    fetch,
    pull,
    push,
    publish,
    sync,
    live,
    issues,
    failures,
    draft_pr,
};

const GitChangeGroup = enum {
    staged,
    unstaged,
};

const GitSelection = struct {
    group: GitChangeGroup,
    index: usize,
};

const GitChangeLane = enum {
    staged,
    unstaged,
};

const GitPanelChangeTarget = struct {
    lane: GitChangeLane,
    index: usize,
    change: git_repository.Change,
};

const LspPanelAction = struct {
    id: []const u8,
    label: []const u8,
    hint: []const u8,
};

const lsp_panel_actions = [_]LspPanelAction{
    .{ .id = "lsp.ensure_active", .label = "Ensure active", .hint = "start when trusted, otherwise show launch/install guidance" },
    .{ .id = "lsp.status", .label = "Status", .hint = "session, pending requests, cached results" },
    .{ .id = "lsp.plan", .label = "Launch plan", .hint = "show server command without spawning it" },
    .{ .id = "lsp.start", .label = "Start server", .hint = "trust-gated language server process" },
    .{ .id = "lsp.stop", .label = "Stop server", .hint = "terminate the active language server" },
    .{ .id = "lsp.sync_current", .label = "Sync current file", .hint = "send didOpen/didChange for this buffer" },
    .{ .id = "lsp.drain", .label = "Drain frames", .hint = "process buffered server responses" },
    .{ .id = "lsp.request_hover", .label = "Hover", .hint = "show documentation for cursor symbol" },
    .{ .id = "editor.complete", .label = "Complete", .hint = "open local and cached LSP completions" },
    .{ .id = "editor.format_document", .label = "Format document", .hint = "preview WorkspaceEdit before applying" },
    .{ .id = "symbol.goto_definition", .label = "Go to definition", .hint = "LSP first, local fallback" },
    .{ .id = "symbol.goto_implementation", .label = "Go to implementation", .hint = "LSP implementation locations" },
    .{ .id = "symbol.goto_type_definition", .label = "Go to type definition", .hint = "LSP type definition locations" },
    .{ .id = "symbol.find_references", .label = "Find references", .hint = "LSP first, local fallback" },
    .{ .id = "symbol.rename", .label = "Rename symbol", .hint = "preview rename edits safely" },
    .{ .id = "lsp.request_code_action", .label = "Quick fixes", .hint = "request code actions for cursor diagnostics" },
    .{ .id = "lsp.apply_workspace_edit", .label = "Apply last edit", .hint = "apply cached LSP edit after boundary checks" },
};

const ExtensionPanelAction = enum {
    scan,
};

const SecurityPanelAction = enum {
    audit,
    lock,
    scan,
    lf,
    crlf,
    clean,
};

const TutorialLanguage = enum {
    ja,
    en,
};

const TutorialPanelAction = enum {
    ja,
    en,
};

const SettingsPanelAction = enum {
    toggle_file_tree,
    toggle_output,
    tutorial_ja,
    tutorial_en,
};

const PublishPanelAction = enum {
    checklist,
    assets,
    manifests,
    bundle,
    verify,
    preflight,
};

const SelectionRange = struct {
    start: usize,
    end: usize,
};

const ReplaceRequest = struct {
    find: []const u8,
    replace: []const u8,
};

const SearchDirection = enum {
    forward,
    backward,
};

const MultiCursorEdit = enum {
    insert,
    delete_backward,
    delete_forward,
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

fn appendTaskMatch(
    allocator: std.mem.Allocator,
    matches: *std.array_list.Managed(TaskMatch),
    name: []const u8,
    label: []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);
    try matches.append(.{ .name = owned_name, .executable = owned_label });
}

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

const DocumentMatch = struct {
    line: usize,
    column: usize,
    byte_offset: usize,
    end_offset: usize,
    preview: []u8,

    fn deinit(self: *DocumentMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.preview);
        self.* = undefined;
    }
};

const QuickPanel = struct {
    allocator: std.mem.Allocator,
    visible: bool = false,
    mode: QuickPanelMode = .find_file,
    search_options: literal_search.Options = .{},
    query: std.array_list.Managed(u8),
    selected_index: usize = 0,
    file_matches: ?[]file_finder.Match = null,
    document_matches: ?[]DocumentMatch = null,
    search_results: ?[]workspace_search.Result = null,
    replacement_preview: ?workspace_replace.Preview = null,
    task_matches: ?[]TaskMatch = null,
    symbol_matches: ?[]SymbolMatch = null,
    workspace_symbol_matches: ?[]workspace_symbols.Result = null,
    problem_matches: ?[]problems_search.Result = null,
    completion_matches: ?[]completion_mod.Item = null,
    language_matches: ?[]modes.LanguageMode = null,
    lsp_action_count: usize = 0,
    lsp_location_count: usize = 0,
    lsp_hover_line_count: usize = 0,
    code_action_count: usize = 0,
    recovery_count: usize = 0,
    recovery_invalid_count: usize = 0,
    debug_watch_count: usize = 0,
    debug_function_count: usize = 0,
    debug_data_commit_count: usize = 0,
    debug_data_variable_count: usize = 0,
    debug_data_breakpoint_count: usize = 0,
    debug_data_has_candidate: bool = false,
    debug_low_frame_count: usize = 0,
    debug_low_variable_count: usize = 0,
    debug_low_has_memory: bool = false,
    debug_low_memory_line_count: usize = 0,
    debug_low_instruction_count: usize = 0,
    debug_low_breakpoint_count: usize = 0,
    debug_exception_count: usize = 0,
    debug_exception_selected_count: usize = 0,
    completion_replace_start: usize = 0,
    completion_replace_end: usize = 0,

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
            .find_document => if (self.document_matches) |items| items.len else 0,
            .replace_document => if (self.document_matches) |items| items.len else 0,
            .rename_symbol => if (renameRequest(self.query.items)) |_| 1 else 0,
            .goto_line => if (goto_line.parse(self.query.items)) |_| 1 else 0,
            .search_workspace => if (self.search_results) |items| items.len else 0,
            .replace_workspace => if (self.replacement_preview) |preview| preview.files.len else 0,
            .run_task => if (self.task_matches) |items| items.len else 0,
            .new_file => if (self.query.items.len > 0) 1 else 0,
            .new_folder => if (self.query.items.len > 0) 1 else 0,
            .rename_path => if (pathMutationRequest(self.query.items)) |_| 1 else 0,
            .delete_path => if (confirmedDeletePath(self.query.items)) |_| 1 else 0,
            .git_commit, .github_pr => if (std.mem.trim(u8, self.query.items, " \t\r\n").len > 0) 1 else 0,
            .git_branch_switch => if (self.task_matches) |items| items.len else 0,
            .git_branch_create => @intFromBool(git_source_control.validateBranchName(std.mem.trim(u8, self.query.items, " \t\r\n"))),
            .document_symbols => if (self.symbol_matches) |items| items.len else 0,
            .workspace_symbols => if (self.workspace_symbol_matches) |items| items.len else 0,
            .lsp_actions => self.lsp_action_count,
            .lsp_locations => self.lsp_location_count,
            .problems => if (self.problem_matches) |items| items.len else 0,
            .completion => if (self.completion_matches) |items| items.len else 0,
            .lsp_hover => self.lsp_hover_line_count,
            .code_actions => self.code_action_count,
            .language_mode => if (self.language_matches) |items| items.len else 0,
            .recovery => self.recovery_count * 2 + @intFromBool(self.recovery_count > 0) + @intFromBool(self.recovery_invalid_count > 0),
            .debug_watch => if (std.mem.trim(u8, self.query.items, " \t\r\n").len > 0) 1 else self.debug_watch_count,
            .debug_breakpoint => 8,
            .debug_breakpoint_condition, .debug_breakpoint_hit, .debug_breakpoint_log => if (std.mem.trim(u8, self.query.items, " \t\r\n").len > 0) 1 else 0,
            .debug_functions => if (std.mem.trim(u8, self.query.items, " \t\r\n").len > 0) 1 else self.debug_function_count + @intFromBool(self.debug_function_count > 0),
            .debug_data => self.debug_data_commit_count +
                @intFromBool(self.debug_data_has_candidate) +
                self.debug_data_variable_count +
                self.debug_data_breakpoint_count +
                @intFromBool(self.debug_data_breakpoint_count > 0),
            .debug_low_level => self.debug_low_frame_count +
                self.debug_low_variable_count +
                @intFromBool(self.debug_low_has_memory) +
                self.debug_low_memory_line_count +
                self.debug_low_instruction_count +
                self.debug_low_breakpoint_count +
                @intFromBool(self.debug_low_breakpoint_count > 0),
            .debug_exceptions => self.debug_exception_count + @intFromBool(self.debug_exception_selected_count > 0),
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

    fn selectedReplacementFile(self: *const QuickPanel) ?*const workspace_replace.FilePreview {
        const preview = if (self.replacement_preview) |*value| value else return null;
        if (preview.files.len == 0) return null;
        return &preview.files[@min(self.selected_index, preview.files.len - 1)];
    }

    fn selectedDocumentMatch(self: *const QuickPanel) ?*const DocumentMatch {
        const items = self.document_matches orelse return null;
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

    fn selectedWorkspaceSymbol(self: *const QuickPanel) ?*const workspace_symbols.Result {
        const items = self.workspace_symbol_matches orelse return null;
        if (items.len == 0) return null;
        return &items[@min(self.selected_index, items.len - 1)];
    }

    fn selectedProblem(self: *const QuickPanel) ?*const problems_search.Result {
        const items = self.problem_matches orelse return null;
        if (items.len == 0) return null;
        return &items[@min(self.selected_index, items.len - 1)];
    }

    fn selectedCompletion(self: *const QuickPanel) ?*const completion_mod.Item {
        const items = self.completion_matches orelse return null;
        if (items.len == 0) return null;
        return &items[@min(self.selected_index, items.len - 1)];
    }

    fn selectedLanguageMode(self: *const QuickPanel) ?modes.LanguageMode {
        const items = self.language_matches orelse return null;
        if (items.len == 0) return null;
        return items[@min(self.selected_index, items.len - 1)];
    }

    fn rebuild(self: *QuickPanel, app: *const app_mod.App) !void {
        self.clearResults();
        switch (self.mode) {
            .find_file => {
                self.file_matches = try file_finder.find(self.allocator, &app.workspace, self.query.items, 64);
            },
            .find_document => {
                if (self.query.items.len > 0) {
                    const active_index = app.documents.activeIndex() orelse return;
                    const doc = &app.documents.documents.items[active_index];
                    self.document_matches = try findDocumentMatches(self.allocator, doc, self.query.items, self.search_options, 128);
                }
            },
            .replace_document => {
                const request = parseReplaceRequest(self.query.items) orelse return;
                if (request.find.len > 0) {
                    const active_index = app.documents.activeIndex() orelse return;
                    const doc = &app.documents.documents.items[active_index];
                    self.document_matches = try findDocumentMatches(self.allocator, doc, request.find, self.search_options, 128);
                }
            },
            .rename_symbol, .goto_line => {},
            .search_workspace => {
                if (self.query.items.len > 0) {
                    self.search_results = try workspace_search.search(self.allocator, &app.workspace, self.query.items, .{
                        .literal_options = self.search_options,
                        .max_file_bytes = 512 * 1024,
                        .max_results = 256,
                    });
                }
            },
            .replace_workspace => {
                var request = workspace_replace.parseQuery(self.query.items) orelse return;
                request.literal_options = self.search_options;
                self.replacement_preview = try workspace_replace.preview(self.allocator, &app.workspace, request, .{});
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
            .new_file, .new_folder, .rename_path, .delete_path, .git_commit, .git_branch_create, .github_pr => {},
            .git_branch_switch => {
                const snapshot = app.source_control_snapshot orelse return;
                var matches = std.array_list.Managed(TaskMatch).init(self.allocator);
                errdefer {
                    for (matches.items) |*item| item.deinit(self.allocator);
                    matches.deinit();
                }
                const query = std.mem.trim(u8, self.query.items, " \t\r\n");
                if (snapshot.branch) |current| {
                    if (query.len == 0 or command_mod.fuzzyScore(query, current) != null) {
                        try appendTaskMatch(self.allocator, &matches, current, "current branch");
                    }
                }
                for (snapshot.branches) |branch| {
                    if (snapshot.branch) |current| {
                        if (std.mem.eql(u8, current, branch)) continue;
                    }
                    if (query.len > 0 and command_mod.fuzzyScore(query, branch) == null) continue;
                    try appendTaskMatch(self.allocator, &matches, branch, "local branch");
                }
                self.task_matches = try matches.toOwnedSlice();
            },
            .debug_watch => self.debug_watch_count = app.debug_manager.session.watches.items.len,
            .debug_functions => self.debug_function_count = app.debug_manager.session.function_breakpoints.items.len,
            .debug_data => {
                const session = &app.debug_manager.session;
                self.debug_data_commit_count = session.dataBreakpointCandidateCommitChoiceCount();
                self.debug_data_has_candidate = session.data_breakpoint_candidate != null;
                self.debug_data_variable_count = if (session.state == .paused and session.dataBreakpointsSupported()) session.variables.items.len else 0;
                self.debug_data_breakpoint_count = session.data_breakpoints.items.len;
            },
            .debug_low_level => {
                const session = &app.debug_manager.session;
                self.debug_low_frame_count = if (session.state == .paused and session.capabilities.supports_disassemble_request) session.stackFrameInstructionReferenceCount() else 0;
                self.debug_low_variable_count = if (session.state == .paused and session.capabilities.supports_read_memory_request) session.variableMemoryReferenceCount() else 0;
                self.debug_low_has_memory = session.memory_snapshot != null;
                self.debug_low_memory_line_count = if (session.memory_snapshot) |snapshot| (snapshot.bytes.len + 15) / 16 else 0;
                self.debug_low_instruction_count = session.disassembled_instructions.items.len;
                self.debug_low_breakpoint_count = session.instruction_breakpoints.items.len;
            },
            .debug_breakpoint, .debug_breakpoint_condition, .debug_breakpoint_hit, .debug_breakpoint_log => {},
            .debug_exceptions => {
                self.debug_exception_count = app.debug_manager.session.exceptionFilterDisplayCount();
                self.debug_exception_selected_count = app.debug_manager.session.selectedExceptionFilterCount();
            },
            .document_symbols => {
                const active_index = app.documents.activeIndex() orelse return;
                const doc = &app.documents.documents.items[active_index];
                const path = doc.path orelse "(scratch)";
                var index = try symbols_mod.collectDocument(self.allocator, doc.text.bytes, path, doc.language);
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
            .workspace_symbols => {
                self.workspace_symbol_matches = try workspace_symbols.search(self.allocator, &app.workspace, self.query.items, .{
                    .max_file_bytes = 512 * 1024,
                    .max_files = 600,
                    .max_results = 512,
                });
            },
            .lsp_actions => {
                self.lsp_action_count = lspActionCount(self.query.items);
            },
            .lsp_locations => {
                self.lsp_location_count = if (app.activeLspSessionConst()) |session|
                    if (session.last_locations) |locations| locations.items.len else 0
                else
                    0;
            },
            .problems => {
                self.problem_matches = try problems_search.collect(self.allocator, &app.diagnostics, &app.security_findings, self.query.items, .{
                    .max_results = 512,
                });
            },
            .completion => {
                const active_index = app.documents.activeIndex() orelse return;
                const doc = &app.documents.documents.items[active_index];
                const prefix = completion_mod.prefixAt(doc.text.bytes, doc.cursor.position.byte_offset);
                self.completion_replace_start = prefix.start;
                self.completion_replace_end = prefix.end;
                const query = if (self.query.items.len > 0) self.query.items else prefix.text;
                self.completion_matches = try completion_mod.complete(self.allocator, .{
                    .source = doc.text.bytes,
                    .cursor_offset = doc.cursor.position.byte_offset,
                    .file_path = doc.path orelse "(scratch)",
                    .language = doc.language,
                    .query_override = query,
                    .max_items = 80,
                });
                if (app.activeLspSessionConst()) |session| {
                    if (session.last_completion) |lsp_items| {
                        self.completion_matches = try completion_mod.mergeLspItems(self.allocator, self.completion_matches.?, lsp_items.items, query, 120);
                    }
                }
            },
            .lsp_hover => {
                self.lsp_hover_line_count = if (app.activeLspSessionConst()) |session|
                    if (session.last_hover) |hover| hoverDisplayLineCount(hover.text) else 0
                else
                    0;
            },
            .code_actions => {
                self.code_action_count = if (app.activeLspSessionConst()) |session|
                    if (session.last_code_actions) |actions| actions.items.len else 0
                else
                    0;
            },
            .language_mode => {
                var matches = std.array_list.Managed(modes.LanguageMode).init(self.allocator);
                errdefer matches.deinit();

                for (modes.all()) |mode| {
                    const label = modes.label(mode);
                    const family = @tagName(modes.family(mode));
                    const focus = modes.securityFocus(mode);
                    const query = self.query.items;
                    if (query.len != 0 and
                        command_mod.fuzzyScore(query, label) == null and
                        command_mod.fuzzyScore(query, family) == null and
                        command_mod.fuzzyScore(query, focus) == null)
                    {
                        continue;
                    }
                    try matches.append(mode);
                }
                self.language_matches = try matches.toOwnedSlice();
            },
            .recovery => {
                self.recovery_count = app.recovery_manager.entries.items.len;
                self.recovery_invalid_count = app.recovery_manager.invalid_entries;
            },
        }
        if (self.selected_index >= self.itemCount()) self.selected_index = 0;
    }

    fn clearResults(self: *QuickPanel) void {
        if (self.file_matches) |items| {
            self.allocator.free(items);
            self.file_matches = null;
        }
        if (self.document_matches) |items| {
            for (items) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
            self.document_matches = null;
        }
        if (self.search_results) |items| {
            for (items) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
            self.search_results = null;
        }
        if (self.replacement_preview) |*preview| {
            preview.deinit();
            self.replacement_preview = null;
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
        if (self.workspace_symbol_matches) |items| {
            for (items) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
            self.workspace_symbol_matches = null;
        }
        if (self.problem_matches) |items| {
            problems_search.deinitResults(self.allocator, items);
            self.problem_matches = null;
        }
        if (self.completion_matches) |items| {
            completion_mod.deinitItems(self.allocator, items);
            self.completion_matches = null;
        }
        self.lsp_action_count = 0;
        self.lsp_location_count = 0;
        self.lsp_hover_line_count = 0;
        self.code_action_count = 0;
        self.recovery_count = 0;
        self.recovery_invalid_count = 0;
        self.debug_watch_count = 0;
        self.debug_function_count = 0;
        self.debug_data_commit_count = 0;
        self.debug_data_variable_count = 0;
        self.debug_data_breakpoint_count = 0;
        self.debug_data_has_candidate = false;
        self.debug_low_frame_count = 0;
        self.debug_low_variable_count = 0;
        self.debug_low_has_memory = false;
        self.debug_low_memory_line_count = 0;
        self.debug_low_instruction_count = 0;
        self.debug_low_breakpoint_count = 0;
        self.debug_exception_count = 0;
        self.debug_exception_selected_count = 0;
        if (self.language_matches) |items| {
            self.allocator.free(items);
            self.language_matches = null;
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
        try self.refreshWithOptions(app, query, .{});
    }

    fn refreshWithOptions(self: *SearchPanel, app: *const app_mod.App, query: []const u8, options: literal_search.Options) !void {
        self.clearResults();
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(query);
        self.selected_index = 0;

        if (query.len == 0) {
            self.visible = false;
            return;
        }

        self.results = try workspace_search.search(self.allocator, &app.workspace, query, .{
            .literal_options = options,
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

pub fn run(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    environ: std.process.Environ,
) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    var state = try GuiState.init(allocator, root_path, environ);
    defer state.deinit();
    global_state = &state;
    defer global_state = null;
    state.runZigSecurityAudit("startup");
    state.offerRecovery();

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

    _ = SetTimer(hwnd, LSP_PUMP_TIMER_ID, 120, null);
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
    tutorial_scroll_line: usize = 0,
    publish_scroll_line: usize = 0,
    git_scroll_line: usize = 0,
    extensions_scroll_line: usize = 0,
    keybindings_scroll_line: usize = 0,
    selection_anchor: ?usize = null,
    secondary_cursors: std.array_list.Managed(usize),
    suppressed_char: ?u21 = null,
    pending_high_surrogate: ?u16 = null,
    editor_dragging: bool = false,
    last_document_search_query: std.array_list.Managed(u8),
    last_document_search_options: literal_search.Options = .{},
    show_output: bool = true,
    show_file_tree: bool = true,
    bottom_panel: BottomPanel = .output,
    tutorial_language: TutorialLanguage = .ja,
    quick_panel: QuickPanel,
    search_panel: SearchPanel,
    git_overview: ?git_repository.Overview = null,
    git_selection: ?GitSelection = null,
    extensions_registry: ?extension_registry.Registry = null,
    pending_lsp_action: PendingLspAction = .none,
    deferred_lsp_action: PendingLspAction = .none,
    deferred_lsp_rename_name: std.array_list.Managed(u8),
    file_watcher: workspace_watcher.Poller,
    file_watch_ticks: u8 = 0,
    recovery_ticks: u8 = 0,
    recovery_error_reported: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        root_path: []const u8,
        environ: std.process.Environ,
    ) !GuiState {
        var app = try app_mod.App.initWithProcess(allocator, root_path, std.Options.debug_io, environ);
        errdefer app.deinit();

        const collapsed_dirs = try allocator.alloc(bool, app.workspace.entries.items.len);
        @memset(collapsed_dirs, false);

        return .{
            .allocator = allocator,
            .app = app,
            .collapsed_dirs = collapsed_dirs,
            .secondary_cursors = std.array_list.Managed(usize).init(allocator),
            .last_document_search_query = std.array_list.Managed(u8).init(allocator),
            .deferred_lsp_rename_name = std.array_list.Managed(u8).init(allocator),
            .file_watcher = workspace_watcher.Poller.init(allocator, .{}),
            .quick_panel = QuickPanel.init(allocator),
            .search_panel = SearchPanel.init(allocator),
        };
    }

    fn openWorkspace(self: *GuiState, root_path: []const u8) void {
        var next_app = app_mod.App.initWithProcess(
            self.allocator,
            root_path,
            std.Options.debug_io,
            self.app.environ,
        ) catch |err| {
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

        _ = self.checkpointRecovery();
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
        self.git_selection = null;
        self.extensions_scroll_line = 0;
        self.publish_scroll_line = 0;
        self.clearSelection();
        self.show_output = true;
        self.bottom_panel = .output;
        self.clearGitOverview();
        self.clearExtensionsRegistry();
        self.quick_panel.close();
        self.search_panel.clear();
        self.pending_lsp_action = .none;
        self.deferred_lsp_action = .none;
        self.deferred_lsp_rename_name.clearRetainingCapacity();
        self.file_watcher.clear();
        self.file_watch_ticks = 0;
        self.recovery_ticks = 0;
        self.recovery_error_reported = false;
        self.setMessage("Workspace opened") catch {};
        self.appendOutput(.stdout, "opened workspace: {s}\n", .{self.app.workspace.root_path});
        self.runZigSecurityAudit("workspace open");
        self.offerRecovery();
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
        self.appendOutput(.stdout, "checks: build.zig firewall, build.zig.zon package trust, unsafe Zig/FFI/allocators, polyglot scripts/secrets/process boundaries, IaC/CI/CD trust edges, git config/hooks/submodules/attributes\n", .{});

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
        _ = self.checkpointRecovery();
        if (self.text_font) |font| _ = DeleteObject(@ptrCast(font));
        if (self.last_error) |message| self.allocator.free(message);
        self.clearGitOverview();
        self.clearExtensionsRegistry();
        self.search_panel.deinit();
        self.quick_panel.deinit();
        self.deferred_lsp_rename_name.deinit();
        self.file_watcher.deinit();
        self.secondary_cursors.deinit();
        self.last_document_search_query.deinit();
        self.allocator.free(self.collapsed_dirs);
        self.app.deinit();
    }

    fn offerRecovery(self: *GuiState) void {
        const manager = &self.app.recovery_manager;
        if (manager.entries.items.len == 0 and manager.invalid_entries == 0 and !manager.scan_truncated) return;
        self.openQuickPanel(.recovery);
        self.appendOutput(.stdout, "recovery center: {d} integrity-valid snapshot(s), {d} rejected, scan-truncated:{}\n", .{
            manager.entries.items.len,
            manager.invalid_entries,
            manager.scan_truncated,
        });
    }

    fn checkpointRecovery(self: *GuiState) bool {
        const report = self.app.checkpointRecovery() catch |err| {
            if (!self.recovery_error_reported) {
                self.recovery_error_reported = true;
                self.appendOutput(.stderr, "recovery checkpoint failed: {s}\n", .{@errorName(err)});
            }
            return false;
        };
        self.recovery_error_reported = false;
        const changed = report.written > 0 or report.removed > 0;
        if (changed and self.quick_panel.visible and self.quick_panel.mode == .recovery) {
            self.quick_panel.rebuild(&self.app) catch |err| {
                self.setError(err) catch {};
                return true;
            };
        }
        return changed;
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

        self.clearSelection();
        self.app.mode = .insert;
        self.app.focus = .editor;
        self.ensureCursorVisible();
        self.syncActiveDocumentToLsp();
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
        self.clearSelection();
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.syncActiveDocumentToLsp();
        self.setMessage("Switched document") catch {};
    }

    fn switchDocumentByDelta(self: *GuiState, delta: isize) void {
        self.app.documents.moveActive(delta);
        self.clearSelection();
        self.app.focus = .editor;
        self.ensureCursorVisible();
        self.syncActiveDocumentToLsp();
        self.setMessage("Switched document") catch {};
    }

    fn executeCommand(self: *GuiState, id: []const u8) void {
        if (std.mem.eql(u8, id, "git.commit")) {
            if (self.git_overview == null) self.openGitPanel();
            self.executeGitPanelAction(.commit);
            return;
        }
        if (std.mem.eql(u8, id, "git.branch.switch")) {
            self.openQuickPanel(.git_branch_switch);
            return;
        }
        if (std.mem.eql(u8, id, "git.branch.create")) {
            self.openQuickPanel(.git_branch_create);
            return;
        }
        if (std.mem.eql(u8, id, "github.pr.create_draft")) {
            self.executeGitPanelAction(.draft_pr);
            return;
        }
        if (std.mem.startsWith(u8, id, "recovery.")) {
            self.openQuickPanel(.recovery);
            return;
        }
        if (std.mem.eql(u8, id, "debug.watch_add") or std.mem.eql(u8, id, "debug.watch_remove")) {
            self.openQuickPanel(.debug_watch);
            return;
        }
        if (std.mem.eql(u8, id, "debug.breakpoint_condition")) {
            self.openBreakpointValueEditor(.debug_breakpoint_condition);
            return;
        }
        if (std.mem.eql(u8, id, "debug.breakpoint_hit_condition")) {
            self.openBreakpointValueEditor(.debug_breakpoint_hit);
            return;
        }
        if (std.mem.eql(u8, id, "debug.breakpoint_log")) {
            self.openBreakpointValueEditor(.debug_breakpoint_log);
            return;
        }
        if (std.mem.eql(u8, id, "debug.function_add") or std.mem.eql(u8, id, "debug.function_remove")) {
            self.openQuickPanel(.debug_functions);
            return;
        }
        if (std.mem.startsWith(u8, id, "debug.data_")) {
            self.openQuickPanel(.debug_data);
            return;
        }
        if (std.mem.eql(u8, id, "debug.low_level") or
            std.mem.eql(u8, id, "debug.disassemble") or
            std.mem.startsWith(u8, id, "debug.memory_") or
            std.mem.startsWith(u8, id, "debug.instruction_"))
        {
            self.openQuickPanel(.debug_low_level);
            return;
        }
        if (std.mem.eql(u8, id, "debug.exception_toggle")) {
            self.openQuickPanel(.debug_exceptions);
            return;
        }
        if (std.mem.eql(u8, id, "file.new")) {
            self.openNewFilePanel();
            return;
        }
        if (std.mem.eql(u8, id, "file.new_folder")) {
            self.openWorkspaceMutationPanel(.new_folder);
            return;
        }
        if (std.mem.eql(u8, id, "file.rename")) {
            self.openWorkspaceMutationPanel(.rename_path);
            return;
        }
        if (std.mem.eql(u8, id, "file.delete")) {
            self.openWorkspaceMutationPanel(.delete_path);
            return;
        }
        if (std.mem.eql(u8, id, "symbol.goto_symbol")) {
            self.openSymbolPanel();
            return;
        }
        if (std.mem.eql(u8, id, "symbol.workspace_symbols")) {
            self.openQuickPanel(.workspace_symbols);
            return;
        }
        if (std.mem.eql(u8, id, "symbol.goto_definition")) {
            self.gotoLocalDefinitionAtCursor();
            return;
        }
        if (std.mem.eql(u8, id, "symbol.goto_implementation")) {
            self.gotoImplementationAtCursor();
            return;
        }
        if (std.mem.eql(u8, id, "symbol.goto_type_definition")) {
            self.gotoTypeDefinitionAtCursor();
            return;
        }
        if (std.mem.eql(u8, id, "symbol.find_references")) {
            self.findReferencesAtCursor();
            return;
        }
        if (std.mem.eql(u8, id, "symbol.rename")) {
            self.openRenamePanel();
            return;
        }
        if (std.mem.eql(u8, id, "lsp.actions")) {
            self.openQuickPanel(.lsp_actions);
            return;
        }
        if (std.mem.eql(u8, id, "lsp.request_code_action")) {
            if (self.requestCodeActionsFromLsp()) return;
            self.ensureLspForFeature("quick fixes", .code_actions);
            return;
        }
        if (std.mem.eql(u8, id, "lsp.request_hover")) {
            if (self.requestHoverFromLsp()) return;
            self.ensureLspForFeature("hover", .hover);
            return;
        }
        if (std.mem.eql(u8, id, "editor.format_document") or std.mem.eql(u8, id, "lsp.request_formatting")) {
            if (self.requestFormattingFromLsp()) return;
            self.ensureLspForFeature("formatting", .formatting_preview);
            return;
        }
        if (std.mem.eql(u8, id, "workspace.find_file")) {
            self.openQuickPanel(.find_file);
            return;
        }
        if (std.mem.eql(u8, id, "editor.find")) {
            self.openQuickPanel(.find_document);
            return;
        }
        if (std.mem.eql(u8, id, "editor.replace")) {
            self.openQuickPanel(.replace_document);
            return;
        }
        if (std.mem.eql(u8, id, "editor.complete")) {
            self.openQuickPanel(.completion);
            return;
        }
        if (std.mem.eql(u8, id, "editor.set_language")) {
            self.openQuickPanel(.language_mode);
            return;
        }
        if (std.mem.eql(u8, id, "editor.goto_line")) {
            self.openQuickPanel(.goto_line);
            return;
        }
        if (std.mem.eql(u8, id, "file.close")) {
            self.closeActiveDocument();
            return;
        }
        if (std.mem.eql(u8, id, "file.next_editor")) {
            self.switchDocumentByDelta(1);
            return;
        }
        if (std.mem.eql(u8, id, "file.previous_editor")) {
            self.switchDocumentByDelta(-1);
            return;
        }
        if (std.mem.eql(u8, id, "editor.find_next")) {
            self.findLastDocumentSearch(.forward);
            return;
        }
        if (std.mem.eql(u8, id, "editor.find_previous")) {
            self.findLastDocumentSearch(.backward);
            return;
        }
        if (std.mem.eql(u8, id, "editor.toggle_comment")) {
            self.toggleActiveDocumentComment();
            return;
        }
        if (std.mem.eql(u8, id, "editor.indent")) {
            self.changeIndentation(false);
            return;
        }
        if (std.mem.eql(u8, id, "editor.outdent")) {
            self.changeIndentation(true);
            return;
        }
        if (std.mem.eql(u8, id, "editor.add_cursor_above")) {
            self.addCursorVertically(-1);
            return;
        }
        if (std.mem.eql(u8, id, "editor.add_cursor_below")) {
            self.addCursorVertically(1);
            return;
        }
        if (std.mem.eql(u8, id, "editor.normalize_newlines_lf")) {
            self.normalizeActiveDocumentNewlines(.lf);
            return;
        }
        if (std.mem.eql(u8, id, "editor.normalize_newlines_crlf")) {
            self.normalizeActiveDocumentNewlines(.crlf);
            return;
        }
        if (std.mem.eql(u8, id, "editor.sanitize_hidden_controls")) {
            self.sanitizeActiveDocumentHiddenControls();
            return;
        }
        if (std.mem.eql(u8, id, "workspace.search")) {
            self.openQuickPanel(.search_workspace);
            return;
        }
        if (std.mem.eql(u8, id, "workspace.replace")) {
            self.openQuickPanel(.replace_workspace);
            return;
        }
        if (std.mem.eql(u8, id, "problems.open")) {
            self.openQuickPanel(.problems);
            return;
        }
        if (std.mem.eql(u8, id, "git.overview") or std.mem.eql(u8, id, "github.overview")) {
            self.openGitPanel();
            return;
        }
        if (std.mem.eql(u8, id, "view.toggle_file_tree")) {
            self.show_file_tree = !self.show_file_tree;
            if (!self.show_file_tree) self.app.focus = .editor;
            self.setMessage(if (self.show_file_tree) "File tree shown" else "File tree hidden") catch {};
            return;
        }
        if (std.mem.eql(u8, id, "view.toggle_diagnostics")) {
            self.openDiagnosticsPanel();
            return;
        }
        if (std.mem.eql(u8, id, "view.tutorial")) {
            self.openTutorialPanel();
            return;
        }
        if (std.mem.eql(u8, id, "view.extensions") or std.mem.eql(u8, id, "extensions.scan")) {
            self.openExtensionsPanel();
            return;
        }
        if (std.mem.eql(u8, id, "view.publish")) {
            self.openPublishPanel();
            return;
        }
        if (std.mem.eql(u8, id, "preferences.open_settings")) {
            self.show_output = true;
            self.bottom_panel = .settings;
            self.setMessage("Settings") catch {};
            return;
        }
        if (std.mem.eql(u8, id, "preferences.open_keybindings")) {
            self.show_output = true;
            self.bottom_panel = .keybindings;
            self.setMessage("Keyboard shortcuts") catch {};
            return;
        }

        const result = dispatcher.dispatch(&self.app, .{ .id = id, .source = .command_palette }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "command failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult(id, result);
        if (!std.mem.startsWith(u8, id, "editor.")) self.show_output = true;
        if (std.mem.eql(u8, id, "git.diff_current")) {
            self.bottom_panel = .output;
        }
        if (std.mem.startsWith(u8, id, "github.") and !std.mem.eql(u8, id, "github.overview")) {
            self.bottom_panel = .output;
        }
        if (std.mem.startsWith(u8, id, "release.")) {
            self.bottom_panel = .output;
        }
        if (std.mem.eql(u8, id, "demo.run")) {
            self.show_output = true;
            self.bottom_panel = .output;
        }
        if (std.mem.startsWith(u8, id, "debug.")) {
            self.show_output = true;
            self.bottom_panel = .debug;
        }
    }

    fn executeDebugPanelAction(self: *GuiState, action: DebugPanelAction) void {
        if (action == .watch) {
            self.openQuickPanel(.debug_watch);
            self.show_output = true;
            self.bottom_panel = .debug;
            return;
        }
        if (action == .advanced_breakpoint) {
            self.openQuickPanel(.debug_breakpoint);
            self.show_output = true;
            self.bottom_panel = .debug;
            return;
        }
        if (action == .low_level) {
            self.openQuickPanel(.debug_low_level);
            self.show_output = true;
            self.bottom_panel = .debug;
            return;
        }
        const id = switch (action) {
            .configure => "debug.create_config",
            .start => "debug.start",
            .continue_execution => "debug.continue",
            .pause => "debug.pause",
            .step_over => "debug.step_over",
            .step_into => "debug.step_into",
            .step_out => "debug.step_out",
            .breakpoint => "debug.toggle_breakpoint",
            .advanced_breakpoint => unreachable,
            .low_level => unreachable,
            .watch => unreachable,
            .stop => "debug.stop",
            .status => "debug.status",
        };
        self.executeCommand(id);
        self.show_output = true;
        self.bottom_panel = .debug;
    }

    fn currentLineBreakpoint(self: *const GuiState) ?*const debug_session.Breakpoint {
        const document_index = self.app.documents.activeIndex() orelse return null;
        const doc = &self.app.documents.documents.items[document_index];
        const path = doc.path orelse return null;
        const line = doc.cursor.position.line + 1;
        for (self.app.debug_manager.session.breakpoints.items) |*breakpoint| {
            if (breakpoint.line == line and pathMatches(path, breakpoint.path)) return breakpoint;
        }
        return null;
    }

    fn openBreakpointValueEditor(self: *GuiState, mode: QuickPanelMode) void {
        self.openQuickPanel(mode);
        if (!self.quick_panel.visible) return;
        const breakpoint = self.currentLineBreakpoint();
        const existing = if (breakpoint) |item| switch (mode) {
            .debug_breakpoint_condition => item.condition,
            .debug_breakpoint_hit => item.hit_condition,
            .debug_breakpoint_log => item.log_message,
            else => null,
        } else null;
        if (existing) |value| {
            self.quick_panel.query.appendSlice(value) catch |err| return self.setError(err) catch {};
            self.quick_panel.rebuild(&self.app) catch |err| self.setError(err) catch {};
        }
    }

    fn executeBreakpointMenuItem(self: *GuiState) void {
        switch (@min(self.quick_panel.selected_index, @as(usize, 7))) {
            0 => self.openBreakpointValueEditor(.debug_breakpoint_condition),
            1 => self.openBreakpointValueEditor(.debug_breakpoint_hit),
            2 => self.openBreakpointValueEditor(.debug_breakpoint_log),
            3 => {
                const result = dispatcher.dispatch(&self.app, .{
                    .id = "debug.breakpoint_clear_advanced",
                    .source = .command_palette,
                }) catch |err| return self.setError(err) catch {};
                self.handleDispatchResult("debug.breakpoint_clear_advanced", result);
                if (std.meta.activeTag(result) == .completed) self.quick_panel.close();
            },
            4 => self.openQuickPanel(.debug_exceptions),
            5 => self.openQuickPanel(.debug_functions),
            6 => self.openQuickPanel(.debug_data),
            7 => self.openQuickPanel(.debug_low_level),
        }
        self.show_output = true;
        self.bottom_panel = .debug;
    }

    fn executeExceptionFilterItem(self: *GuiState) void {
        const filter_count = self.quick_panel.debug_exception_count;
        const selected_index = self.quick_panel.selected_index;
        const command_id: []const u8 = if (selected_index >= filter_count) "debug.exception_clear" else "debug.exception_toggle";
        const owned_filter_id: ?[]u8 = if (selected_index < filter_count) blk: {
            const filter = self.app.debug_manager.session.exceptionFilterDisplayAt(selected_index) orelse {
                self.setMessage("No exception filter selected") catch {};
                return;
            };
            break :blk self.allocator.dupe(u8, filter.id) catch |err| {
                self.setError(err) catch {};
                return;
            };
        } else null;
        defer if (owned_filter_id) |filter_id| self.allocator.free(filter_id);

        const result = dispatcher.dispatch(&self.app, .{
            .id = command_id,
            .argument = owned_filter_id,
            .source = .command_palette,
        }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.handleDispatchResult(command_id, result);
        if (std.meta.activeTag(result) == .completed) {
            self.quick_panel.rebuild(&self.app) catch |err| {
                self.setError(err) catch {};
                return;
            };
            const count = self.quick_panel.itemCount();
            self.quick_panel.selected_index = if (count == 0) 0 else @min(selected_index, count - 1);
        }
        self.show_output = true;
        self.bottom_panel = .debug;
    }

    fn executeFunctionBreakpointItem(self: *GuiState) void {
        const name = std.mem.trim(u8, self.quick_panel.query.items, " \t\r\n");
        const function_count = self.quick_panel.debug_function_count;
        const selected_index = self.quick_panel.selected_index;
        var index_buf: [32]u8 = undefined;
        const command_id: []const u8 = if (name.len > 0)
            "debug.function_add"
        else if (selected_index >= function_count)
            "debug.function_clear"
        else
            "debug.function_remove";
        const argument: ?[]const u8 = if (name.len > 0)
            name
        else if (selected_index < function_count)
            std.fmt.bufPrint(&index_buf, "{d}", .{selected_index + 1}) catch return
        else
            null;
        if (name.len == 0 and function_count == 0) {
            self.setMessage("Type an explicit function symbol") catch {};
            return;
        }

        const owned_argument = if (argument) |value| self.allocator.dupe(u8, value) catch |err| {
            self.setError(err) catch {};
            return;
        } else null;
        defer if (owned_argument) |value| self.allocator.free(value);
        const result = dispatcher.dispatch(&self.app, .{
            .id = command_id,
            .argument = owned_argument,
            .source = .command_palette,
        }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.handleDispatchResult(command_id, result);
        if (std.meta.activeTag(result) == .completed) {
            if (name.len > 0) {
                self.quick_panel.close();
            } else {
                self.quick_panel.rebuild(&self.app) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                const count = self.quick_panel.itemCount();
                self.quick_panel.selected_index = if (count == 0) 0 else @min(selected_index, count - 1);
            }
        }
        self.show_output = true;
        self.bottom_panel = .debug;
    }

    fn executeDataBreakpointItem(self: *GuiState) void {
        const selected_index = self.quick_panel.selected_index;
        var relative = selected_index;
        var index_buf: [32]u8 = undefined;
        var command_id: []const u8 = "";
        var argument: ?[]const u8 = null;

        if (relative < self.quick_panel.debug_data_commit_count) {
            const choice = self.app.debug_manager.session.dataBreakpointCandidateCommitChoiceAt(relative) orelse return;
            command_id = "debug.data_commit";
            argument = choice.commandArgument();
        } else {
            relative -= self.quick_panel.debug_data_commit_count;
            if (self.quick_panel.debug_data_has_candidate) {
                if (relative == 0) {
                    command_id = "debug.data_cancel";
                } else {
                    relative -= 1;
                }
            }
            if (command_id.len == 0) {
                if (relative < self.quick_panel.debug_data_variable_count) {
                    command_id = "debug.data_inspect";
                    argument = std.fmt.bufPrint(&index_buf, "{d}", .{relative + 1}) catch return;
                } else {
                    relative -= self.quick_panel.debug_data_variable_count;
                    if (relative < self.quick_panel.debug_data_breakpoint_count) {
                        command_id = "debug.data_remove";
                        argument = std.fmt.bufPrint(&index_buf, "{d}", .{relative + 1}) catch return;
                    } else if (self.quick_panel.debug_data_breakpoint_count > 0 and relative == self.quick_panel.debug_data_breakpoint_count) {
                        command_id = "debug.data_clear";
                    } else {
                        return;
                    }
                }
            }
        }

        const result = dispatcher.dispatch(&self.app, .{
            .id = command_id,
            .argument = argument,
            .source = .command_palette,
        }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.handleDispatchResult(command_id, result);
        if (std.meta.activeTag(result) == .completed) {
            if (!std.mem.eql(u8, command_id, "debug.data_inspect")) {
                self.quick_panel.rebuild(&self.app) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                const count = self.quick_panel.itemCount();
                self.quick_panel.selected_index = if (count == 0) 0 else @min(selected_index, count - 1);
            }
        }
        self.show_output = true;
        self.bottom_panel = .debug;
    }

    fn executeLowLevelItem(self: *GuiState) void {
        const selected_index = self.quick_panel.selected_index;
        var relative = selected_index;
        var index_buf: [32]u8 = undefined;
        var command_id: []const u8 = "";
        var argument: ?[]const u8 = null;
        const session = &self.app.debug_manager.session;

        if (relative < self.quick_panel.debug_low_frame_count) {
            const frame_index = session.stackFrameInstructionReferenceIndexAt(relative) orelse return;
            command_id = "debug.disassemble";
            argument = std.fmt.bufPrint(&index_buf, "{d}", .{frame_index + 1}) catch return;
        } else {
            relative -= self.quick_panel.debug_low_frame_count;
            if (relative < self.quick_panel.debug_low_variable_count) {
                const variable_index = session.variableMemoryReferenceIndexAt(relative) orelse return;
                command_id = "debug.memory_read";
                argument = std.fmt.bufPrint(&index_buf, "{d}", .{variable_index + 1}) catch return;
            } else {
                relative -= self.quick_panel.debug_low_variable_count;
                if (self.quick_panel.debug_low_has_memory) {
                    if (relative == 0) {
                        command_id = "debug.memory_refresh";
                    } else {
                        relative -= 1;
                    }
                }
                if (command_id.len == 0) {
                    if (relative < self.quick_panel.debug_low_memory_line_count) {
                        self.setMessage("Read-only memory row; select REFRESH or another reference") catch {};
                        return;
                    }
                    relative -= self.quick_panel.debug_low_memory_line_count;
                    if (relative < self.quick_panel.debug_low_instruction_count) {
                        command_id = "debug.instruction_toggle";
                        argument = std.fmt.bufPrint(&index_buf, "{d}", .{relative + 1}) catch return;
                    } else {
                        relative -= self.quick_panel.debug_low_instruction_count;
                        if (relative < self.quick_panel.debug_low_breakpoint_count) {
                            command_id = "debug.instruction_remove";
                            argument = std.fmt.bufPrint(&index_buf, "{d}", .{relative + 1}) catch return;
                        } else if (self.quick_panel.debug_low_breakpoint_count > 0 and relative == self.quick_panel.debug_low_breakpoint_count) {
                            command_id = "debug.instruction_clear";
                        } else {
                            return;
                        }
                    }
                }
            }
        }

        const result = dispatcher.dispatch(&self.app, .{
            .id = command_id,
            .argument = argument,
            .source = .command_palette,
        }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.handleDispatchResult(command_id, result);
        if (std.meta.activeTag(result) == .completed) {
            self.quick_panel.rebuild(&self.app) catch |err| {
                self.setError(err) catch {};
                return;
            };
            const count = self.quick_panel.itemCount();
            self.quick_panel.selected_index = if (count == 0) 0 else @min(selected_index, count - 1);
        }
        self.show_output = true;
        self.bottom_panel = .debug;
    }

    fn applyBreakpointValueEditor(self: *GuiState, mode: QuickPanelMode) void {
        const value = std.mem.trim(u8, self.quick_panel.query.items, " \t\r\n");
        if (value.len == 0) {
            self.setMessage("Breakpoint value cannot be empty; use Clear advanced settings") catch {};
            return;
        }
        const id = switch (mode) {
            .debug_breakpoint_condition => "debug.breakpoint_condition",
            .debug_breakpoint_hit => "debug.breakpoint_hit_condition",
            .debug_breakpoint_log => "debug.breakpoint_log",
            else => return,
        };
        const result = dispatcher.dispatch(&self.app, .{
            .id = id,
            .argument = value,
            .source = .command_palette,
        }) catch |err| return self.setError(err) catch {};
        self.handleDispatchResult(id, result);
        if (std.meta.activeTag(result) == .completed) self.quick_panel.close();
        self.show_output = true;
        self.bottom_panel = .debug;
    }

    fn selectDebugFrameAt(self: *GuiState, index: usize) void {
        const session = &self.app.debug_manager.session;
        if (index >= session.stack_frames.items.len) return;
        const frame = session.stack_frames.items[index];
        const frame_id = frame.id;
        const line = if (frame.line > 0) frame.line - 1 else 0;
        const column = if (frame.column > 0) frame.column - 1 else 0;
        const path = if (frame.path) |value| self.allocator.dupe(u8, value) catch null else null;
        defer if (path) |value| self.allocator.free(value);

        var argument_buf: [48]u8 = undefined;
        const argument = std.fmt.bufPrint(&argument_buf, "{d}", .{frame_id}) catch return;
        const result = dispatcher.dispatch(&self.app, .{
            .id = "debug.select_frame",
            .argument = argument,
            .source = .command_palette,
        }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.handleDispatchResult("debug.select_frame", result);
        if (path) |value| self.openDebugSourceLocation(value, line, column);
        self.show_output = true;
        self.bottom_panel = .debug;
    }

    fn expandDebugVariableAt(self: *GuiState, index: usize) void {
        const variables = self.app.debug_manager.session.variables.items;
        if (index >= variables.len) return;
        const reference = variables[index].variables_reference;
        if (reference <= 0) {
            self.setMessage("Debug variable has no children") catch {};
            return;
        }
        var argument_buf: [48]u8 = undefined;
        const argument = std.fmt.bufPrint(&argument_buf, "{d}", .{reference}) catch return;
        const result = dispatcher.dispatch(&self.app, .{
            .id = "debug.variables",
            .argument = argument,
            .source = .command_palette,
        }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.handleDispatchResult("debug.variables", result);
    }

    fn activateDebugValueAt(self: *GuiState, row: usize) void {
        const session = &self.app.debug_manager.session;
        const visible_watches = @min(session.watches.items.len, @as(usize, 2));
        if (row >= visible_watches) {
            self.expandDebugVariableAt(row - visible_watches);
            return;
        }

        var argument_buf: [32]u8 = undefined;
        const argument = std.fmt.bufPrint(&argument_buf, "{d}", .{row + 1}) catch return;
        const result = dispatcher.dispatch(&self.app, .{
            .id = "debug.watch_refresh",
            .argument = argument,
            .source = .command_palette,
        }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.handleDispatchResult("debug.watch_refresh", result);
    }

    fn openDebugSourceLocation(self: *GuiState, path: []const u8, line: usize, column: usize) void {
        const index = (if (std.fs.path.isAbsolute(path))
            self.app.openWorkspacePath(path)
        else
            self.app.openWorkspaceFile(path)) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "debug source blocked: {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        const doc = &self.app.documents.documents.items[index];
        const safe_line = @min(line, if (doc.text.lineCount() == 0) 0 else doc.text.lineCount() - 1);
        const safe_column = @min(column, doc.text.lineSlice(safe_line).len);
        const offset = doc.text.lineColumnToOffset(safe_line, safe_column) catch 0;
        navigation.setCursor(doc, doc.positionFromOffset(offset) catch doc.cursor.position);
        self.clearSelection();
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.syncActiveDocumentToLsp();
        self.setMessage("Opened debug stack frame") catch {};
    }

    fn executeGitPanelAction(self: *GuiState, action: GitPanelAction) void {
        switch (action) {
            .refresh => {
                self.show_output = true;
                self.bottom_panel = .git;
                self.git_scroll_line = 0;
                self.refreshGitOverview();
                self.executeGitMutation("git.refresh_source_control", null);
            },
            .status => {
                self.executeCommand("git.status");
                self.show_output = true;
                self.bottom_panel = .output;
            },
            .diff => {
                self.executeCommand("git.diff_current");
                self.show_output = true;
                self.bottom_panel = .output;
            },
            .stage_all => self.executeGitMutation("git.stage_all", null),
            .unstage_all => self.executeGitMutation("git.unstage_all", null),
            .commit => {
                const overview = self.git_overview orelse return;
                const staged_count = if (self.app.source_control_snapshot) |snapshot|
                    snapshot.stagedCount()
                else
                    overview.staged_changes.len;
                if ((overview.staged_scan_available or self.app.source_control_snapshot != null) and staged_count == 0) {
                    self.setMessage("Stage at least one change before committing") catch {};
                    return;
                }
                self.openQuickPanel(.git_commit);
            },
            .branch_switch => self.openQuickPanel(.git_branch_switch),
            .branch_create => self.openQuickPanel(.git_branch_create),
            .fetch => self.executeGitMutation("git.fetch", null),
            .pull => {
                if (self.gitBranchNeedsPublish()) {
                    self.setMessage("Publish this branch before pulling") catch {};
                    return;
                }
                self.executeGitMutation("git.pull", null);
            },
            .push => self.executeGitMutation(
                if (self.gitBranchNeedsPublish()) "git.publish_branch" else "git.push",
                null,
            ),
            .sync => self.executeGitMutation(
                if (self.gitBranchNeedsPublish()) "git.publish_branch" else "git.sync",
                null,
            ),
            .publish => self.executeGitMutation("git.publish_branch", null),
            .draft_pr => {
                if (self.gitBranchNeedsPublish()) {
                    self.setMessage("Publish this branch before creating a pull request") catch {};
                    return;
                }
                self.openQuickPanel(.github_pr);
            },
            .live, .issues => {
                self.executeCommand(gitPanelActionCommand(action));
                self.show_output = true;
                self.bottom_panel = .git;
            },
            .failures => {
                self.executeCommand(gitPanelActionCommand(action));
                self.show_output = true;
                self.bottom_panel = .output;
            },
        }
    }

    fn gitBranchNeedsPublish(self: *const GuiState) bool {
        const snapshot = self.app.source_control_snapshot orelse return false;
        return !snapshot.detached and snapshot.branch != null and snapshot.upstream == null;
    }

    fn executeGitMutation(self: *GuiState, id: []const u8, argument: ?[]const u8) void {
        const result = dispatcher.dispatch(&self.app, .{
            .id = id,
            .argument = argument,
            .source = .command_palette,
        }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "{s} failed: {s}\n", .{ id, @errorName(err) });
            return;
        };
        self.handleDispatchResult(id, result);
        self.show_output = true;
        self.bottom_panel = .git;
        if (std.meta.activeTag(result) == .completed) {
            const message = result.completed;
            self.refreshGitOverview();
            self.setMessage(message) catch {};
        }
    }

    fn executeExtensionPanelAction(self: *GuiState, action: ExtensionPanelAction) void {
        switch (action) {
            .scan => {
                self.show_output = true;
                self.bottom_panel = .extensions;
                self.extensions_scroll_line = 0;
                self.refreshExtensionsRegistry();
            },
        }
    }

    fn executeSecurityPanelAction(self: *GuiState, action: SecurityPanelAction) void {
        self.show_output = true;
        self.bottom_panel = .security;
        switch (action) {
            .audit => self.runWorkspaceSecurityAudit("Security audit"),
            .lock => self.lockWorkspaceFromGui(),
            .scan => self.refreshActiveSecurityFindings("Current file security scan"),
            .lf => self.normalizeActiveDocumentNewlines(.lf),
            .crlf => self.normalizeActiveDocumentNewlines(.crlf),
            .clean => self.sanitizeActiveDocumentHiddenControls(),
        }
    }

    fn executeTutorialPanelAction(self: *GuiState, action: TutorialPanelAction) void {
        self.tutorial_language = switch (action) {
            .ja => .ja,
            .en => .en,
        };
        self.tutorial_scroll_line = 0;
        self.show_output = true;
        self.bottom_panel = .tutorial;
        self.setMessage(if (self.tutorial_language == .ja) "チュートリアル: 日本語" else "Tutorial: English") catch {};
    }

    fn executeSettingsPanelAction(self: *GuiState, action: SettingsPanelAction) void {
        switch (action) {
            .toggle_file_tree => {
                self.show_file_tree = !self.show_file_tree;
                if (!self.show_file_tree) self.app.focus = .editor;
                self.setMessage(if (self.show_file_tree) "File tree shown" else "File tree hidden") catch {};
            },
            .toggle_output => {
                self.show_output = !self.show_output;
                self.setMessage(if (self.show_output) "Bottom panel shown" else "Bottom panel hidden") catch {};
            },
            .tutorial_ja => self.executeTutorialPanelAction(.ja),
            .tutorial_en => self.executeTutorialPanelAction(.en),
        }
    }

    fn executePublishPanelAction(self: *GuiState, action: PublishPanelAction) void {
        const id = switch (action) {
            .checklist => "release.checklist",
            .assets => "release.assets",
            .manifests => "release.manifests",
            .bundle => "release.bundle",
            .verify => "release.verify",
            .preflight => "release.preflight",
        };
        const result = dispatcher.dispatch(&self.app, .{ .id = id, .source = .command_palette }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "publish action failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult(id, result);
        self.show_output = true;
        self.bottom_panel = .output;
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

    fn openRenamePanel(self: *GuiState) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        const name = identifierAtOffset(doc.text.bytes, doc.cursor.position.byte_offset) orelse {
            self.setMessage("No identifier under cursor") catch {};
            return;
        };
        self.openQuickPanel(.rename_symbol);
        self.quick_panel.query.clearRetainingCapacity();
        self.quick_panel.query.appendSlice(name) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.quick_panel.query.appendSlice("=>") catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.quick_panel.rebuild(&self.app) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.setMessage("Rename symbol: type new name after =>") catch {};
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

    fn openTutorialPanel(self: *GuiState) void {
        self.show_output = true;
        self.bottom_panel = .tutorial;
        self.tutorial_scroll_line = 0;
        self.setMessage("ZIDE tutorial") catch {};
    }

    fn openPublishPanel(self: *GuiState) void {
        self.show_output = true;
        self.bottom_panel = .publish;
        self.publish_scroll_line = 0;
        self.setMessage("Publish checklist") catch {};
    }

    fn openGitPanel(self: *GuiState) void {
        self.show_output = true;
        self.bottom_panel = .git;
        self.git_scroll_line = 0;
        self.refreshGitOverview();
        self.executeGitMutation("git.refresh_source_control", null);
    }

    fn openExtensionsPanel(self: *GuiState) void {
        self.show_output = true;
        self.bottom_panel = .extensions;
        self.extensions_scroll_line = 0;
        self.refreshExtensionsRegistry();
    }

    fn runWorkspaceSecurityAudit(self: *GuiState, message: []const u8) void {
        self.show_output = true;
        self.bottom_panel = .security;
        self.security_scroll_line = 0;
        const result = dispatcher.dispatch(&self.app, .{ .id = "security.audit_workspace", .source = .command_palette }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.handleDispatchResult("security.audit_workspace", result);
        self.setMessage(message) catch {};
    }

    fn lockWorkspaceFromGui(self: *GuiState) void {
        const result = dispatcher.dispatch(&self.app, .{ .id = "security.lock_workspace", .source = .command_palette }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.handleDispatchResult("security.lock_workspace", result);
        self.show_output = true;
        self.bottom_panel = .security;
        self.setMessage("Workspace locked") catch {};
    }

    fn refreshGitOverview(self: *GuiState) void {
        self.clearGitOverview();
        self.git_selection = null;
        var overview = git_repository.inspect(self.allocator, &self.app.workspace, .{}) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "git overview failed: {s}\n", .{@errorName(err)});
            return;
        };
        if (self.app.source_control_snapshot) |*snapshot| {
            git_repository.applySourceControlSnapshot(&overview, snapshot, 512) catch |err| {
                self.setError(err) catch {};
                overview.deinit();
                return;
            };
        }
        self.git_overview = overview;
        self.setMessage(if (overview.present) "Git overview" else "No Git repository") catch {};
    }

    fn clearGitOverview(self: *GuiState) void {
        if (self.git_overview) |*overview| {
            overview.deinit();
            self.git_overview = null;
        }
    }

    fn refreshExtensionsRegistry(self: *GuiState) void {
        self.clearExtensionsRegistry();
        const registry = extension_registry.Registry.scan(self.allocator, &self.app.workspace, .{}) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "extension scan failed: {s}\n", .{@errorName(err)});
            return;
        };
        const count = registry.items.items.len;
        self.extensions_registry = registry;
        self.setMessage(if (count == 0) "No extension manifests" else "Extension manifests") catch {};
    }

    fn clearExtensionsRegistry(self: *GuiState) void {
        if (self.extensions_registry) |*registry| {
            registry.deinit();
            self.extensions_registry = null;
        }
    }

    fn openQuickPanel(self: *GuiState, mode: QuickPanelMode) void {
        self.app.palette.close();
        self.quick_panel.open(mode, &self.app) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "quick panel failed: {s}\n", .{@errorName(err)});
            return;
        };
        if (!self.seedQuickPanelFromSelection(mode)) self.seedQuickPanelFromLastSearch(mode);
        if (mode == .search_workspace or mode == .replace_workspace) {
            self.show_output = true;
            self.bottom_panel = .output;
        }
        self.setMessage(switch (mode) {
            .find_file => "Find file",
            .find_document => "Find in file",
            .replace_document => "Replace in file",
            .goto_line => "Go to line",
            .search_workspace => "Search workspace",
            .replace_workspace => "Replace in workspace",
            .run_task => "Run task",
            .new_file => "New file",
            .new_folder => "New folder",
            .rename_path => "Rename file or folder",
            .delete_path => "Delete file or empty folder",
            .git_commit => "Commit staged changes",
            .git_branch_switch => "Switch Git branch",
            .git_branch_create => "Create Git branch",
            .github_pr => "Create draft pull request",
            .document_symbols => "Document symbols",
            .workspace_symbols => "Workspace symbols",
            .lsp_actions => "LSP actions",
            .lsp_locations => "LSP locations",
            .problems => "Problems",
            .rename_symbol => "Rename symbol",
            .completion => "Complete symbol",
            .lsp_hover => "LSP hover",
            .code_actions => "Quick Fix",
            .language_mode => "Language mode",
            .recovery => "Recovery center",
            .debug_watch => "Add restricted debug watch",
            .debug_breakpoint => "Advanced breakpoint",
            .debug_breakpoint_condition => "Restricted breakpoint condition",
            .debug_breakpoint_hit => "Breakpoint hit count",
            .debug_breakpoint_log => "Restricted logpoint",
            .debug_functions => "Function breakpoints",
            .debug_data => "Data breakpoints",
            .debug_low_level => "Read-only memory and disassembly",
            .debug_exceptions => "Exception breakpoints",
        }) catch {};
        if (mode == .completion and !self.requestCompletionFromLsp()) self.ensureLspForFeature("completion", .completion);
    }

    fn openWorkspaceMutationPanel(self: *GuiState, mode: QuickPanelMode) void {
        self.openQuickPanel(mode);
        if (!self.quick_panel.visible) return;
        const entry = self.app.selectedWorkspaceEntry() orelse return;

        self.quick_panel.query.clearRetainingCapacity();
        switch (mode) {
            .new_folder => {
                const parent = if (entry.kind == .directory) entry.path else std.fs.path.dirname(entry.path) orelse "";
                if (parent.len > 0) {
                    self.quick_panel.query.appendSlice(parent) catch |err| return self.setError(err) catch {};
                    self.quick_panel.query.appendSlice("\\") catch |err| return self.setError(err) catch {};
                }
            },
            .rename_path => {
                self.quick_panel.query.appendSlice(entry.path) catch |err| return self.setError(err) catch {};
                self.quick_panel.query.appendSlice("=>") catch |err| return self.setError(err) catch {};
            },
            .delete_path => {
                self.quick_panel.query.appendSlice(entry.path) catch |err| return self.setError(err) catch {};
                self.quick_panel.query.appendSlice("=>DELETE") catch |err| return self.setError(err) catch {};
            },
            else => return,
        }
        self.quick_panel.rebuild(&self.app) catch |err| self.setError(err) catch {};
    }

    fn seedQuickPanelFromSelection(self: *GuiState, mode: QuickPanelMode) bool {
        if (mode != .find_document and mode != .replace_document and mode != .replace_workspace) return false;
        const doc = self.app.documents.active() orelse return false;
        const range = self.selectedRange(doc) orelse return false;
        if (range.end <= range.start or range.end - range.start > 160) return false;

        self.quick_panel.query.clearRetainingCapacity();
        self.quick_panel.query.appendSlice(doc.text.bytes[range.start..range.end]) catch |err| {
            self.setError(err) catch {};
            return false;
        };
        if (mode == .replace_document or mode == .replace_workspace) {
            self.quick_panel.query.appendSlice("=>") catch |err| {
                self.setError(err) catch {};
                return false;
            };
        }
        self.quick_panel.rebuild(&self.app) catch |err| {
            self.setError(err) catch {};
            return false;
        };
        if (isDocumentSearchMode(mode)) self.rememberDocumentSearchFromQuickPanel();
        return true;
    }

    fn seedQuickPanelFromLastSearch(self: *GuiState, mode: QuickPanelMode) void {
        if (mode != .find_document and mode != .replace_document) return;
        if (self.last_document_search_query.items.len == 0) return;
        self.quick_panel.query.clearRetainingCapacity();
        self.quick_panel.query.appendSlice(self.last_document_search_query.items) catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (mode == .replace_document) {
            self.quick_panel.query.appendSlice("=>") catch |err| {
                self.setError(err) catch {};
                return;
            };
        }
        self.quick_panel.search_options = self.last_document_search_options;
        self.quick_panel.rebuild(&self.app) catch |err| {
            self.setError(err) catch {};
            return;
        };
    }

    fn quickPanelInsertText(self: *GuiState, bytes: []const u8) void {
        if (isReadOnlyQuickPanelMode(self.quick_panel.mode)) return;
        self.quick_panel.insertText(&self.app, bytes) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.rememberDocumentSearchFromQuickPanel();
        self.refreshSearchPanelFromQuickPanel();
        if (self.quick_panel.visible and self.quick_panel.mode == .completion) _ = self.requestCompletionFromLsp();
    }

    fn quickPanelDeleteBackward(self: *GuiState) void {
        if (isReadOnlyQuickPanelMode(self.quick_panel.mode)) return;
        self.quick_panel.deleteBackward(&self.app) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.rememberDocumentSearchFromQuickPanel();
        self.refreshSearchPanelFromQuickPanel();
        if (self.quick_panel.visible and self.quick_panel.mode == .completion) _ = self.requestCompletionFromLsp();
    }

    fn refreshSearchPanelFromQuickPanel(self: *GuiState) void {
        if (!self.quick_panel.visible or self.quick_panel.mode != .search_workspace) return;
        self.search_panel.refresh(&self.app, self.quick_panel.query.items) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "search refresh failed: {s}\n", .{@errorName(err)});
            return;
        };
    }

    fn toggleQuickPanelCaseSensitive(self: *GuiState) void {
        if (!supportsQuickPanelSearchOptions(self.quick_panel.mode)) return;
        self.quick_panel.search_options.case_sensitive = !self.quick_panel.search_options.case_sensitive;
        self.quick_panel.rebuild(&self.app) catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (isDocumentSearchMode(self.quick_panel.mode)) self.rememberDocumentSearchFromQuickPanel();
        self.setMessage(if (self.quick_panel.search_options.case_sensitive) "Find: case sensitive" else "Find: ignore case") catch {};
    }

    fn toggleQuickPanelWholeWord(self: *GuiState) void {
        if (!supportsQuickPanelSearchOptions(self.quick_panel.mode)) return;
        self.quick_panel.search_options.whole_word = !self.quick_panel.search_options.whole_word;
        self.quick_panel.rebuild(&self.app) catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (isDocumentSearchMode(self.quick_panel.mode)) self.rememberDocumentSearchFromQuickPanel();
        self.setMessage(if (self.quick_panel.search_options.whole_word) "Find: whole word" else "Find: partial word") catch {};
    }

    fn rememberDocumentSearchFromQuickPanel(self: *GuiState) void {
        if (!isDocumentSearchMode(self.quick_panel.mode)) return;
        const query = if (self.quick_panel.mode == .replace_document) blk: {
            const request = parseReplaceRequest(self.quick_panel.query.items) orelse return;
            break :blk request.find;
        } else self.quick_panel.query.items;
        if (query.len == 0) return;
        self.last_document_search_query.clearRetainingCapacity();
        self.last_document_search_query.appendSlice(query) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.last_document_search_options = self.quick_panel.search_options;
    }

    fn moveQuickPanelDocumentMatch(self: *GuiState, delta: isize) void {
        if (!isDocumentSearchMode(self.quick_panel.mode)) return;
        self.quick_panel.moveSelection(delta);
        const item = self.quick_panel.selectedDocumentMatch() orelse return;
        self.selectActiveDocumentRange(item.byte_offset, item.end_offset, "Selected search match");
        self.quick_panel.visible = true;
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
            .find_document => {
                const item = self.quick_panel.selectedDocumentMatch() orelse {
                    self.setMessage("No document match") catch {};
                    return;
                };
                const start = item.byte_offset;
                const end = item.end_offset;
                self.quick_panel.close();
                self.selectActiveDocumentRange(start, end, "Found match");
            },
            .replace_document => {
                const item = self.quick_panel.selectedDocumentMatch() orelse {
                    self.setMessage("No replacement target") catch {};
                    return;
                };
                const request = parseReplaceRequest(self.quick_panel.query.items) orelse {
                    self.setMessage("Type search=>replacement") catch {};
                    return;
                };
                const start = item.byte_offset;
                const end = item.end_offset;
                const replacement = self.allocator.dupe(u8, request.replace) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(replacement);
                self.quick_panel.close();
                self.replaceActiveDocumentRange(start, end, replacement);
            },
            .rename_symbol => {
                const request = renameRequest(self.quick_panel.query.items) orelse {
                    self.setMessage("Type old_name=>new_name") catch {};
                    return;
                };
                const old_name = self.allocator.dupe(u8, request.find) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(old_name);
                const new_name = self.allocator.dupe(u8, request.replace) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(new_name);
                self.quick_panel.close();
                if (self.requestRenameFromLsp(new_name)) return;
                self.deferred_lsp_rename_name.clearRetainingCapacity();
                self.deferred_lsp_rename_name.appendSlice(new_name) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                self.ensureLspForFeature("rename", .rename_preview);
                if (self.deferred_lsp_action == .rename_preview) return;
                self.deferred_lsp_rename_name.clearRetainingCapacity();
                self.renameWorkspaceSymbol(old_name, new_name);
            },
            .goto_line => self.gotoLineFromQuickPanel(),
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
            .replace_workspace => {
                const item = self.quick_panel.selectedReplacementFile() orelse {
                    self.setMessage("No replacement target") catch {};
                    return;
                };
                const path = self.allocator.dupe(u8, item.path) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(path);
                const line = item.first_line;
                const column = item.first_column;
                self.quick_panel.close();
                self.openRelativeLocation(path, line, column);
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
                    self.clearSelection();
                    self.syncCollapsedDirs();
                    self.app.mode = .insert;
                    self.app.focus = .editor;
                    self.ensureCursorVisible();
                }
            },
            .new_folder => self.dispatchQuickPanelFileMutation("file.new_folder", "new folder failed"),
            .rename_path => self.dispatchQuickPanelFileMutation("file.rename", "rename failed"),
            .delete_path => self.dispatchQuickPanelFileMutation("file.delete", "delete failed"),
            .git_commit => {
                const message = std.mem.trim(u8, self.quick_panel.query.items, " \t\r\n");
                if (message.len == 0) {
                    self.setMessage("Type a commit message") catch {};
                    return;
                }
                const owned = self.allocator.dupe(u8, message) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(owned);
                self.quick_panel.close();
                self.executeGitMutation("git.commit", owned);
            },
            .git_branch_switch => {
                const item = self.quick_panel.selectedTask() orelse {
                    self.setMessage("No local branch selected") catch {};
                    return;
                };
                const branch = item.name;
                const owned = self.allocator.dupe(u8, branch) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(owned);
                self.quick_panel.close();
                self.executeGitMutation("git.branch.switch", owned);
            },
            .git_branch_create => {
                const branch = std.mem.trim(u8, self.quick_panel.query.items, " \t\r\n");
                if (!git_source_control.validateBranchName(branch)) {
                    self.setMessage("Type a valid new branch name") catch {};
                    return;
                }
                const owned = self.allocator.dupe(u8, branch) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(owned);
                self.quick_panel.close();
                self.executeGitMutation("git.branch.create", owned);
            },
            .github_pr => {
                const title = std.mem.trim(u8, self.quick_panel.query.items, " \t\r\n");
                if (title.len == 0) {
                    self.setMessage("Type a pull request title") catch {};
                    return;
                }
                const owned = self.allocator.dupe(u8, title) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(owned);
                self.quick_panel.close();
                const result = dispatcher.dispatch(&self.app, .{
                    .id = "github.pr.create_draft",
                    .argument = owned,
                    .source = .command_palette,
                }) catch |err| {
                    self.setError(err) catch {};
                    self.appendOutput(.stderr, "draft PR failed: {s}\n", .{@errorName(err)});
                    return;
                };
                self.handleDispatchResult("github.pr.create_draft", result);
                self.show_output = true;
                self.bottom_panel = if (std.meta.activeTag(result) == .completed) .git else .output;
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
            .workspace_symbols => {
                const item = self.quick_panel.selectedWorkspaceSymbol() orelse {
                    self.setMessage("No workspace symbol selected") catch {};
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
            .lsp_actions => {
                const action = lspActionAt(self.quick_panel.query.items, self.quick_panel.selected_index) orelse {
                    self.setMessage("No LSP action selected") catch {};
                    return;
                };
                self.quick_panel.close();
                self.executeCommand(action.id);
            },
            .lsp_locations => {
                const session = self.app.activeLspSessionConst() orelse {
                    self.setMessage("No LSP session") catch {};
                    return;
                };
                const locations = session.last_locations orelse {
                    self.setMessage("No LSP locations") catch {};
                    return;
                };
                if (locations.items.len == 0) {
                    self.setMessage("No LSP locations") catch {};
                    return;
                }
                const selected = @min(self.quick_panel.selected_index, locations.items.len - 1);
                const location = locations.items[selected];
                const path = self.allocator.dupe(u8, location.path) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(path);
                const line = location.range.start.line;
                const column = location.range.start.column;
                self.quick_panel.close();
                self.openRelativeLocation(path, line, column);
                self.setMessage("Opened LSP location") catch {};
            },
            .problems => {
                const item = self.quick_panel.selectedProblem() orelse {
                    self.setMessage("No problem selected") catch {};
                    return;
                };
                if (item.path.len == 0) {
                    self.setMessage(item.message) catch {};
                    return;
                }
                const path = self.allocator.dupe(u8, item.path) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(path);
                const line = item.line;
                const column = item.column;
                const kind = item.kind;
                self.quick_panel.close();
                self.openRelativeLocation(path, line, column);
                self.bottom_panel = if (kind == .security) .security else .diagnostics;
            },
            .completion => {
                const item = self.quick_panel.selectedCompletion() orelse {
                    self.setMessage("No completion selected") catch {};
                    return;
                };
                const insert_text = self.allocator.dupe(u8, item.insert_text) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(insert_text);
                const start = self.quick_panel.completion_replace_start;
                const end = self.quick_panel.completion_replace_end;
                self.quick_panel.close();
                self.replaceActiveDocumentRange(start, end, insert_text);
                self.app.mode = .insert;
                self.app.focus = .editor;
                self.ensureCursorVisible();
                self.setMessage("Completed") catch {};
            },
            .lsp_hover => {
                self.quick_panel.close();
                self.app.focus = .editor;
                self.setMessage("Closed LSP hover") catch {};
            },
            .code_actions => {
                const count = self.quick_panel.itemCount();
                if (count == 0) {
                    self.setMessage("No code action selected") catch {};
                    return;
                }
                const selected = @min(self.quick_panel.selected_index, count - 1);
                var index_buf: [32]u8 = undefined;
                const argument = std.fmt.bufPrint(&index_buf, "{d}", .{selected + 1}) catch return;
                self.quick_panel.close();
                const result = dispatcher.dispatch(&self.app, .{ .id = "lsp.apply_code_action", .argument = argument, .source = .command_palette }) catch |err| {
                    self.setError(err) catch {};
                    self.appendOutput(.stderr, "code action failed: {s}\n", .{@errorName(err)});
                    return;
                };
                self.handleDispatchResult("lsp.apply_code_action", result);
                if (std.meta.activeTag(result) == .completed) {
                    self.clearSelection();
                    self.syncActiveDocumentToLsp();
                    self.app.focus = .editor;
                    self.ensureCursorVisible();
                }
            },
            .language_mode => {
                const mode = self.quick_panel.selectedLanguageMode() orelse {
                    self.setMessage("No language selected") catch {};
                    return;
                };
                self.quick_panel.close();
                self.setActiveDocumentLanguage(mode);
            },
            .recovery => self.executeRecoveryItem(),
            .debug_watch => {
                const expression = std.mem.trim(u8, self.quick_panel.query.items, " \t\r\n");
                if (expression.len == 0) {
                    if (self.quick_panel.debug_watch_count == 0) {
                        self.setMessage("Type an inspection expression") catch {};
                        return;
                    }
                    var index_buf: [32]u8 = undefined;
                    const argument = std.fmt.bufPrint(&index_buf, "{d}", .{self.quick_panel.selected_index + 1}) catch return;
                    self.quick_panel.close();
                    const result = dispatcher.dispatch(&self.app, .{
                        .id = "debug.watch_remove",
                        .argument = argument,
                        .source = .command_palette,
                    }) catch |err| {
                        self.setError(err) catch {};
                        return;
                    };
                    self.handleDispatchResult("debug.watch_remove", result);
                    if (std.meta.activeTag(result) == .completed) self.openQuickPanel(.debug_watch);
                    return;
                }
                const owned_expression = self.allocator.dupe(u8, expression) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                defer self.allocator.free(owned_expression);
                const result = dispatcher.dispatch(&self.app, .{
                    .id = "debug.watch_add",
                    .argument = owned_expression,
                    .source = .command_palette,
                }) catch |err| {
                    self.setError(err) catch {};
                    return;
                };
                self.handleDispatchResult("debug.watch_add", result);
                if (std.meta.activeTag(result) == .completed) self.quick_panel.close();
                self.show_output = true;
                self.bottom_panel = .debug;
            },
            .debug_breakpoint => self.executeBreakpointMenuItem(),
            .debug_breakpoint_condition, .debug_breakpoint_hit, .debug_breakpoint_log => self.applyBreakpointValueEditor(self.quick_panel.mode),
            .debug_functions => self.executeFunctionBreakpointItem(),
            .debug_data => self.executeDataBreakpointItem(),
            .debug_low_level => self.executeLowLevelItem(),
            .debug_exceptions => self.executeExceptionFilterItem(),
        }
    }

    fn executeRecoveryItem(self: *GuiState) void {
        const count = self.app.recovery_manager.entries.items.len;
        const invalid_count = self.app.recovery_manager.invalid_entries;
        const item_count = count * 2 + @intFromBool(count > 0) + @intFromBool(invalid_count > 0);
        if (item_count == 0) {
            self.setMessage(if (self.app.recovery_manager.invalid_entries > 0) "Invalid recovery envelopes were rejected" else "No recovery snapshots") catch {};
            return;
        }
        const selected = @min(self.quick_panel.selected_index, item_count - 1);
        var index_buffer: [32]u8 = undefined;
        var id: []const u8 = "recovery.discard_all";
        var argument: []const u8 = "DISCARD ALL";
        if (selected < count * 2) {
            const snapshot_index = selected / 2;
            argument = std.fmt.bufPrint(&index_buffer, "{d}", .{snapshot_index + 1}) catch return;
            id = if (selected % 2 == 0) "recovery.restore" else "recovery.discard";
        } else if (count == 0 or selected > count * 2) {
            id = "recovery.purge_rejected";
            argument = "PURGE REJECTED";
        }

        const result = dispatcher.dispatch(&self.app, .{
            .id = id,
            .argument = argument,
            .source = .command_palette,
        }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "recovery action failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult(id, result);
        if (std.meta.activeTag(result) != .completed) return;

        if (std.mem.eql(u8, id, "recovery.restore")) {
            self.quick_panel.close();
            self.clearSelection();
            self.app.focus = .editor;
            self.app.mode = .insert;
            self.ensureCursorVisible();
            self.refreshActiveSecurityFindings("Recovered unsaved buffer");
            return;
        }
        self.quick_panel.rebuild(&self.app) catch |err| self.setError(err) catch {};
        if (self.app.recovery_manager.entries.items.len == 0 and self.app.recovery_manager.invalid_entries == 0) self.quick_panel.close();
    }

    fn dispatchQuickPanelFileMutation(self: *GuiState, id: []const u8, error_label: []const u8) void {
        if (self.quick_panel.query.items.len == 0) {
            self.setMessage("Type a workspace-relative path") catch {};
            return;
        }
        const argument = self.allocator.dupe(u8, self.quick_panel.query.items) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer self.allocator.free(argument);
        self.quick_panel.close();

        const result = dispatcher.dispatch(&self.app, .{ .id = id, .argument = argument, .source = .command_palette }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "{s}: {s}\n", .{ error_label, @errorName(err) });
            return;
        };
        self.handleDispatchResult(id, result);
        if (std.meta.activeTag(result) == .completed) {
            self.clearSelection();
            self.syncCollapsedDirs();
            self.ensureCursorVisible();
        }
    }

    fn setActiveDocumentLanguage(self: *GuiState, mode: modes.LanguageMode) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        doc.language = mode;
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.syncActiveDocumentToLsp();
        self.refreshActiveSecurityFindings("Language mode changed");
        var message_buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "Language: {s}  family:{s}  security:{s}", .{
            modes.label(mode),
            @tagName(modes.family(mode)),
            modes.securityFocus(mode),
        }) catch "Language mode changed";
        self.setMessage(message) catch {};
    }

    fn openSelectedSearchPanelItem(self: *GuiState) void {
        const item = self.search_panel.selectedResult() orelse {
            self.setMessage("No search result selected") catch {};
            return;
        };
        self.openRelativeFile(item.path, item.byte_offset);
    }

    fn openRelativeFile(self: *GuiState, relative: []const u8, offset: ?usize) void {
        const index = self.app.openWorkspaceFile(relative) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "open failed: {s}: {s}\n", .{ relative, @errorName(err) });
            return;
        };

        const doc = &self.app.documents.documents.items[index];
        self.clearSelection();
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
        self.syncActiveDocumentToLsp();
        self.setMessage("Opened file") catch {};
    }

    fn openRelativeLocation(self: *GuiState, relative: []const u8, line: usize, column: usize) void {
        const index = self.app.openWorkspaceFile(relative) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "open failed: {s}: {s}\n", .{ relative, @errorName(err) });
            return;
        };
        const doc = &self.app.documents.documents.items[index];
        self.clearSelection();
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
        self.syncActiveDocumentToLsp();
        self.setMessage("Opened diagnostic") catch {};
    }

    fn jumpToActiveDocumentOffset(self: *GuiState, offset: usize, message: []const u8) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        self.clearSelection();
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

    fn selectActiveDocumentRange(self: *GuiState, start: usize, end: usize, message: []const u8) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        const clamped_start = @min(start, doc.text.bytes.len);
        const clamped_end = @min(end, doc.text.bytes.len);
        const position = doc.positionFromOffset(clamped_end) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.selection_anchor = clamped_start;
        navigation.setCursor(doc, position);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.setMessage(message) catch {};
    }

    fn replaceActiveDocumentRange(self: *GuiState, start: usize, end: usize, replacement: []const u8) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        const clamped_start = @min(start, doc.text.bytes.len);
        const clamped_end = @min(end, doc.text.bytes.len);
        if (clamped_start > clamped_end) {
            self.setMessage("Invalid replacement range") catch {};
            return;
        }
        doc.replaceRange(clamped_start, clamped_end, replacement) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.clearSelection();
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.setMessage("Replaced match") catch {};
    }

    fn replaceAllFromQuickPanel(self: *GuiState) void {
        if (self.quick_panel.mode != .replace_document) return;
        const request = parseReplaceRequest(self.quick_panel.query.items) orelse {
            self.setMessage("Type search=>replacement") catch {};
            return;
        };
        const find = self.allocator.dupe(u8, request.find) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer self.allocator.free(find);
        const replacement = self.allocator.dupe(u8, request.replace) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer self.allocator.free(replacement);
        const options = self.quick_panel.search_options;
        self.quick_panel.close();
        self.replaceAllActiveDocumentMatches(find, replacement, options);
    }

    fn applyWorkspaceReplacementFromQuickPanel(self: *GuiState) void {
        if (self.quick_panel.mode != .replace_workspace) return;
        const preview = if (self.quick_panel.replacement_preview) |*value| value else {
            self.setMessage("Type search=>replacement to build a preview") catch {};
            return;
        };
        if (preview.files.len == 0) {
            self.setMessage("Workspace replacement has no matches") catch {};
            return;
        }

        const argument = workspace_replace.formatApplyArgument(
            self.allocator,
            preview.token,
            self.quick_panel.query.items,
            self.quick_panel.search_options,
        ) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer self.allocator.free(argument);

        const result = dispatcher.dispatch(&self.app, .{
            .id = "workspace.replace_apply",
            .argument = argument,
            .source = .command_palette,
        }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "workspace replacement failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult("workspace.replace_apply", result);
        self.show_output = true;
        self.bottom_panel = .output;
        if (std.meta.activeTag(result) != .completed) return;

        self.quick_panel.close();
        self.file_watcher.clear();
        self.clearSelection();
        self.app.focus = .editor;
        self.ensureCursorVisible();
    }

    fn replaceAllActiveDocumentMatches(self: *GuiState, find: []const u8, replacement: []const u8, options: literal_search.Options) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        const matches = literal_search.findAll(self.allocator, doc.text.bytes, find, options) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer self.allocator.free(matches);
        if (matches.len == 0) {
            self.setMessage("No matches to replace") catch {};
            return;
        }

        var next: std.Io.Writer.Allocating = .init(self.allocator);
        defer next.deinit();
        var cursor: usize = 0;
        for (matches) |match| {
            next.writer.writeAll(doc.text.bytes[cursor..match.start]) catch |err| {
                self.setError(err) catch {};
                return;
            };
            next.writer.writeAll(replacement) catch |err| {
                self.setError(err) catch {};
                return;
            };
            cursor = match.end;
        }
        next.writer.writeAll(doc.text.bytes[cursor..]) catch |err| {
            self.setError(err) catch {};
            return;
        };

        const first_start = matches[0].start;
        doc.replaceRange(0, doc.text.bytes.len, next.written()) catch |err| {
            self.setError(err) catch {};
            return;
        };
        const target = @min(first_start + replacement.len, doc.text.bytes.len);
        const position = doc.positionFromOffset(target) catch doc.cursor.position;
        navigation.setCursor(doc, position);
        self.clearSelection();
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.setMessage("Replaced all matches") catch {};
    }

    fn findLastDocumentSearch(self: *GuiState, direction: SearchDirection) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        if (self.last_document_search_query.items.len == 0) {
            self.openQuickPanel(.find_document);
            return;
        }

        const matches = literal_search.findAll(self.allocator, doc.text.bytes, self.last_document_search_query.items, self.last_document_search_options) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer self.allocator.free(matches);
        if (matches.len == 0) {
            self.setMessage("No matches") catch {};
            return;
        }

        const cursor = doc.cursor.position.byte_offset;
        const selected = self.selectedRange(doc);
        const pivot = switch (direction) {
            .forward => if (selected) |range| range.end else cursor,
            .backward => if (selected) |range| range.start else cursor,
        };
        const index = switch (direction) {
            .forward => findNextMatchIndex(matches, pivot),
            .backward => findPreviousMatchIndex(matches, pivot),
        };
        const match = matches[index];
        self.selectActiveDocumentRange(match.start, match.end, "Found match");
    }

    fn openCachedLspLocationsForKind(self: *GuiState, kind: lsp_session.RequestKind, list_label: []const u8, opened_message: []const u8, empty_message: []const u8) bool {
        const session = self.app.activeLspSessionConst() orelse return false;
        if (session.last_locations_kind != kind) return false;
        const locations = session.last_locations orelse return false;
        if (locations.items.len == 0) {
            self.setMessage(empty_message) catch {};
            return true;
        }
        if (locations.items.len > 1) {
            self.showLspLocations(list_label);
            return true;
        }
        const location = locations.items[0];
        self.openRelativeLocation(location.path, location.range.start.line, location.range.start.column);
        self.setMessage(opened_message) catch {};
        return true;
    }

    fn gotoLocalDefinitionAtCursor(self: *GuiState) void {
        if (self.requestDefinitionFromLsp()) return;
        if (self.app.activeLspSessionConst()) |session| {
            if (session.last_locations_kind == .definition) {
                if (session.last_locations) |locations| {
                    if (locations.items.len > 0) {
                        const location = locations.items[0];
                        self.openRelativeLocation(location.path, location.range.start.line, location.range.start.column);
                        self.setMessage("Opened LSP definition") catch {};
                        return;
                    }
                }
            }
        }

        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        const name = identifierAtOffset(doc.text.bytes, doc.cursor.position.byte_offset) orelse {
            self.setMessage("No identifier under cursor") catch {};
            self.ensureLspForFeature("definition", .goto_definition);
            return;
        };
        const path = doc.path orelse "(scratch)";
        var index = symbols_mod.collectDocument(self.allocator, doc.text.bytes, path, doc.language) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer index.deinit();

        for (index.symbols) |symbol| {
            if (!std.mem.eql(u8, symbol.name, name)) continue;
            self.clearSelection();
            navigation.setCursor(doc, symbol.range.start);
            self.app.focus = .editor;
            self.app.mode = .insert;
            self.ensureCursorVisible();
            self.setMessage("Jumped to definition") catch {};
            return;
        }

        self.setMessage("No local top-level definition") catch {};
        self.ensureLspForFeature("definition", .goto_definition);
    }

    fn gotoImplementationAtCursor(self: *GuiState) void {
        if (self.requestImplementationFromLsp()) return;
        if (self.openCachedLspLocationsForKind(.implementation, "LSP implementations", "Opened LSP implementation", "No LSP implementation")) return;
        self.ensureLspForFeature("implementation", .goto_implementation);
    }

    fn gotoTypeDefinitionAtCursor(self: *GuiState) void {
        if (self.requestTypeDefinitionFromLsp()) return;
        if (self.openCachedLspLocationsForKind(.type_definition, "LSP type definitions", "Opened LSP type definition", "No LSP type definition")) return;
        self.ensureLspForFeature("type definition", .goto_type_definition);
    }

    fn findReferencesAtCursor(self: *GuiState) void {
        if (self.requestReferencesFromLsp()) return;
        if (self.app.activeLspSessionConst()) |session| {
            if (session.last_locations_kind == .references) {
                if (session.last_locations) |locations| {
                    if (locations.items.len > 0) {
                        self.showLspLocations("LSP locations");
                        return;
                    }
                }
            }
        }

        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        const name = identifierAtOffset(doc.text.bytes, doc.cursor.position.byte_offset) orelse {
            self.setMessage("No identifier under cursor") catch {};
            self.ensureLspForFeature("references", .find_references);
            return;
        };

        self.search_panel.refreshWithOptions(&self.app, name, .{ .whole_word = true }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.show_output = true;
        self.bottom_panel = .output;
        self.search_panel.selected_index = 0;
        var message_buf: [120]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "Found {d} reference{s}", .{
            self.search_panel.itemCount(),
            if (self.search_panel.itemCount() == 1) "" else "s",
        }) catch "References found";
        self.setMessage(message) catch {};
        if (self.search_panel.itemCount() == 0) self.ensureLspForFeature("references", .find_references);
    }

    fn renameWorkspaceSymbol(self: *GuiState, old_name: []const u8, new_name: []const u8) void {
        if (std.mem.eql(u8, old_name, new_name)) {
            self.setMessage("Rename target is unchanged") catch {};
            return;
        }

        const results = workspace_search.search(self.allocator, &self.app.workspace, old_name, .{
            .literal_options = .{ .whole_word = true },
            .max_file_bytes = 2 * 1024 * 1024,
            .max_results = 2048,
        }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer {
            for (results) |*item| item.deinit(self.allocator);
            self.allocator.free(results);
        }

        if (results.len == 0) {
            self.setMessage("No references to rename") catch {};
            return;
        }

        var replaced: usize = 0;
        var skipped: usize = 0;
        var index = results.len;
        while (index > 0) {
            index -= 1;
            const item = results[index];
            const doc_index = self.app.openWorkspaceFile(item.path) catch |err| {
                skipped += 1;
                self.appendOutput(.stderr, "rename skipped open failure: {s}: {s}\n", .{ item.path, @errorName(err) });
                continue;
            };
            const doc = &self.app.documents.documents.items[doc_index];
            const start = item.byte_offset;
            const end = start + old_name.len;
            if (end > doc.text.bytes.len or !std.mem.eql(u8, doc.text.bytes[start..end], old_name)) {
                skipped += 1;
                continue;
            }
            doc.replaceRange(start, end, new_name) catch |err| {
                skipped += 1;
                self.appendOutput(.stderr, "rename skipped edit failure: {s}: {s}\n", .{ item.path, @errorName(err) });
                continue;
            };
            replaced += 1;
        }

        self.clearSelection();
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.show_output = true;
        self.bottom_panel = .output;
        self.appendOutput(.stdout, "rename preview: {s} -> {s}, changed {d}, skipped {d}. Save changed tabs to write files.\n", .{ old_name, new_name, replaced, skipped });

        var message_buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "Rename preview changed {d} reference{s}", .{
            replaced,
            if (replaced == 1) "" else "s",
        }) catch "Rename preview complete";
        self.setMessage(message) catch {};
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
        const finding = &self.app.security_findings.items.items[index];
        if (finding.path.len == 0) {
            self.setMessage(finding.message) catch {};
            return;
        }
        self.openSecurityFindingLocation(finding);
    }

    fn openSecurityFindingLocation(self: *GuiState, finding: *const findings_mod.Finding) void {
        const index = self.app.openWorkspaceFile(finding.path) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "open failed: {s}: {s}\n", .{ finding.path, @errorName(err) });
            return;
        };
        const doc = &self.app.documents.documents.items[index];
        self.clearSelection();

        const offset = doc.text.lineColumnToOffset(finding.line, finding.column) catch |err| {
            self.setError(err) catch {};
            return;
        };
        const end = securityFindingSelectionEnd(doc, finding, offset);
        const target = if (end > offset) end else offset;
        const position = doc.positionFromOffset(@min(target, doc.text.bytes.len)) catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (end > offset) self.selection_anchor = offset;
        navigation.setCursor(doc, position);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
        self.setMessage(if (end > offset) "Selected security finding" else "Opened security finding") catch {};
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

    fn openGitPanelRow(self: *GuiState, rect: RECT, row: usize, x: c_int) void {
        const overview = if (self.git_overview) |*value| value else return;
        if (gitPanelUrlAtRow(self, overview.*, row)) |url| {
            self.openExternalUrl(url);
            return;
        }

        const workflow_start = gitPanelWorkflowStartRow(overview.*);
        if (row >= workflow_start and row < workflow_start + overview.workflow_paths.len) {
            self.openRelativeFile(overview.workflow_paths[row - workflow_start], null);
            return;
        }

        const target = gitPanelChangeTargetAtRow(overview, row) orelse return;
        const change = target.change;
        self.git_selection = .{
            .group = if (target.lane == .staged) .staged else .unstaged,
            .index = target.index,
        };
        if (x >= rect.right - 52) {
            self.executeGitMutation(
                if (target.lane == .staged) "git.unstage" else "git.stage",
                change.path,
            );
            return;
        }
        if (change.status == .deleted) {
            if (target.lane == .staged) {
                self.previewGitStagedDiffForPath(change.path);
            } else {
                self.previewGitDiffForPath(change.path);
            }
            self.setMessage("Deleted file diff preview") catch {};
            return;
        }
        self.openRelativeFile(change.path, null);
        if (target.lane == .staged) {
            self.previewGitStagedDiffForPath(change.path);
        } else {
            self.previewGitDiffForPath(change.path);
        }
    }

    fn openExtensionPanelRow(self: *GuiState, row: usize) void {
        const registry = self.extensions_registry orelse return;
        if (row >= registry.items.items.len) return;
        const extension = registry.items.items[row];
        self.openRelativeFile(extension.manifest_path, null);
    }

    fn previewGitDiffForPath(self: *GuiState, path: []const u8) void {
        self.previewGitDiff(path, false);
    }

    fn previewGitStagedDiffForPath(self: *GuiState, path: []const u8) void {
        self.previewGitDiff(path, true);
    }

    fn previewGitDiff(self: *GuiState, path: []const u8, staged: bool) void {
        const preview = (if (staged)
            git_repository.previewStagedFileDiff(self.allocator, &self.app.workspace, path, .{})
        else
            git_repository.previewFileDiff(self.allocator, &self.app.workspace, path, .{})) catch blk: {
            break :blk git_source_control.previewDiff(
                self.allocator,
                self.app.io,
                self.app.environ,
                self.app.workspace.root_path,
                path,
                staged,
            ) catch |err| {
                self.setError(err) catch {};
                self.appendOutput(.stderr, "{s} git diff preview failed: {s}\n", .{
                    if (staged) "staged" else "working-tree",
                    @errorName(err),
                });
                return;
            };
        };
        defer self.allocator.free(preview);
        self.app.process_console.appendBytes(.stdout, preview) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.show_output = true;
        self.bottom_panel = .output;
        self.setMessage(if (staged) "Staged Git diff preview" else "Git diff preview") catch {};
    }

    fn openExternalUrl(self: *GuiState, url: []const u8) void {
        if (!github_state_mod.isSafeGitHubWebUrl(url)) {
            self.setMessage("Blocked non-GitHub or malformed URL") catch {};
            self.appendOutput(.stderr, "blocked external URL outside https://github.com/\n", .{});
            return;
        }
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, url) catch |err| {
            self.setError(err) catch {};
            return;
        };
        defer self.allocator.free(wide);

        const operation = std.unicode.utf8ToUtf16LeStringLiteral("open");
        const result = ShellExecuteW(self.hwnd, operation.ptr, wide.ptr, null, null, SW_SHOWNORMAL);
        if (@intFromPtr(result) <= 32) {
            self.setMessage("Could not open GitHub URL") catch {};
            return;
        }
        self.setMessage("Opened GitHub URL") catch {};
    }

    fn handleDispatchResult(self: *GuiState, id: []const u8, result: dispatcher.Result) void {
        switch (result) {
            .completed => |message| {
                self.setMessage(message) catch {};
                self.appendOutput(.stdout, "{s}: {s}\n", .{ id, message });
                if (std.mem.eql(u8, id, "workspace.refresh")) self.syncCollapsedDirs();
                if (self.git_overview != null and (std.mem.eql(u8, id, "file.save") or std.mem.eql(u8, id, "file.save_all") or std.mem.eql(u8, id, "file.new") or std.mem.eql(u8, id, "file.new_folder") or std.mem.eql(u8, id, "file.rename") or std.mem.eql(u8, id, "file.delete"))) {
                    self.refreshGitOverview();
                    self.setMessage(message) catch {};
                }
                if (isEditorLineCommand(id)) {
                    self.clearSelection();
                    self.ensureCursorVisible();
                    self.syncActiveDocumentToLsp();
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

    fn hasCachedLspWorkspaceEdit(self: *const GuiState) bool {
        const session = self.app.activeLspSessionConst() orelse return false;
        const edit = session.last_workspace_edit orelse return false;
        return edit.edits.len > 0;
    }

    fn applyCachedLspWorkspaceEdit(self: *GuiState) void {
        const result = dispatcher.dispatch(&self.app, .{ .id = "lsp.apply_workspace_edit", .source = .command_palette }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "workspace edit apply failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult("lsp.apply_workspace_edit", result);
        if (std.meta.activeTag(result) == .completed) {
            self.clearSelection();
            self.syncActiveDocumentToLsp();
            self.app.focus = .editor;
            self.ensureCursorVisible();
        }
    }

    fn appendOutput(self: *GuiState, stream: console_mod.Stream, comptime fmt: []const u8, args: anytype) void {
        var text: std.Io.Writer.Allocating = .init(self.allocator);
        defer text.deinit();
        text.writer.print(fmt, args) catch return;
        self.app.process_console.appendBytes(stream, text.written()) catch return;
    }

    fn pumpLsp(self: *GuiState) bool {
        const result = dispatcher.pumpLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp pump failed: {s}\n", .{@errorName(err)});
            return true;
        };
        if (result.frames == 0 and result.stderr_bytes == 0) return false;
        if (self.quick_panel.visible) {
            self.quick_panel.rebuild(&self.app) catch |err| {
                self.appendOutput(.stderr, "quick panel refresh failed after lsp update: {s}\n", .{@errorName(err)});
            };
        }
        self.finishPendingLspAction();
        self.runDeferredLspActionIfReady();
        return true;
    }

    fn pumpDebug(self: *GuiState) bool {
        const result = dispatcher.pumpDebug(&self.app) catch |err| {
            self.appendOutput(.stderr, "debug pump failed: {s}\n", .{@errorName(err)});
            return true;
        };
        if (result.frames > 0 and self.quick_panel.visible and
            (self.quick_panel.mode == .debug_data or self.quick_panel.mode == .debug_low_level))
        {
            const selected = self.quick_panel.selected_index;
            self.quick_panel.rebuild(&self.app) catch |err| {
                self.setError(err) catch {};
                return true;
            };
            const count = self.quick_panel.itemCount();
            self.quick_panel.selected_index = if (count == 0) 0 else @min(selected, count - 1);
        }
        return result.frames > 0 or result.stderr_bytes > 0 or result.protocol_violation or result.adapter_closed;
    }

    fn pollExternalFileChanges(self: *GuiState) bool {
        var batch = self.file_watcher.poll(self.app.documents.documents.items) catch |err| {
            self.appendOutput(.stderr, "file watcher failed: {s}\n", .{@errorName(err)});
            return false;
        };
        defer batch.deinit();

        var changed = false;
        for (batch.items) |event| {
            if (event.document_index >= self.app.documents.documents.items.len) continue;
            const doc = &self.app.documents.documents.items[event.document_index];
            const path = doc.path orelse continue;
            switch (event.kind) {
                .deleted => {
                    doc.dirty = true;
                    self.appendOutput(.stderr, "external delete: {s}; editor buffer retained as unsaved\n", .{path});
                    self.setMessage("File deleted outside ZIDE; buffer retained") catch {};
                    changed = true;
                },
                .modified => {
                    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, self.allocator, .limited(32 * 1024 * 1024)) catch |err| {
                        self.appendOutput(.stderr, "external reload failed: {s}: {s}\n", .{ path, @errorName(err) });
                        continue;
                    };
                    defer self.allocator.free(bytes);
                    if (std.mem.eql(u8, bytes, doc.text.bytes)) continue;
                    if (doc.dirty) {
                        self.appendOutput(.stderr, "external edit conflict: {s}; unsaved editor buffer was not overwritten\n", .{path});
                        self.setMessage("External edit conflict; local buffer preserved") catch {};
                        changed = true;
                        continue;
                    }
                    doc.reloadFromBytes(bytes) catch |err| {
                        self.appendOutput(.stderr, "external reload failed: {s}: {s}\n", .{ path, @errorName(err) });
                        continue;
                    };
                    if (self.app.documents.activeIndex() == event.document_index) {
                        self.clearSelection();
                        self.ensureCursorVisible();
                        self.syncActiveDocumentToLsp();
                    }
                    self.appendOutput(.stdout, "reloaded external edit: {s}\n", .{path});
                    self.setMessage("Reloaded external file change") catch {};
                    changed = true;
                },
            }
        }
        return changed;
    }

    fn syncActiveDocumentToLsp(self: *GuiState) void {
        _ = dispatcher.syncActiveDocumentToRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp sync failed: {s}\n", .{@errorName(err)});
            return;
        };
    }

    fn requestCompletionFromLsp(self: *GuiState) bool {
        const sent = dispatcher.requestActiveCompletionFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp completion request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .completion;
        self.setMessage("LSP completion requested") catch {};
        return true;
    }

    fn ensureLspForFeature(self: *GuiState, feature: []const u8, action: PendingLspAction) void {
        const result = dispatcher.dispatch(&self.app, .{ .id = "lsp.ensure_active", .source = .command_palette }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "lsp ensure failed for {s}: {s}\n", .{ feature, @errorName(err) });
            return;
        };
        self.deferred_lsp_action = if (std.meta.activeTag(result) == .completed or self.app.hasRunningLspForActiveDocument()) action else .none;
        self.handleDispatchResult("lsp.ensure_active", result);
        self.show_output = true;
        self.bottom_panel = .output;
    }

    fn runDeferredLspActionIfReady(self: *GuiState) void {
        if (self.deferred_lsp_action == .none or self.pending_lsp_action != .none) return;
        const session = self.app.activeLspSessionConst() orelse return;
        if (session.state != .initialized) return;
        const action = self.deferred_lsp_action;
        self.deferred_lsp_action = .none;
        switch (action) {
            .completion => _ = self.requestCompletionFromLsp(),
            .goto_definition => _ = self.requestDefinitionFromLsp(),
            .goto_implementation => _ = self.requestImplementationFromLsp(),
            .goto_type_definition => _ = self.requestTypeDefinitionFromLsp(),
            .find_references => _ = self.requestReferencesFromLsp(),
            .hover => _ = self.requestHoverFromLsp(),
            .rename_preview => {
                if (self.deferred_lsp_rename_name.items.len == 0 or !self.requestRenameFromLsp(self.deferred_lsp_rename_name.items)) {
                    self.deferred_lsp_rename_name.clearRetainingCapacity();
                }
            },
            .formatting_preview => _ = self.requestFormattingFromLsp(),
            .code_actions => _ = self.requestCodeActionsFromLsp(),
            else => {},
        }
    }

    fn requestDefinitionFromLsp(self: *GuiState) bool {
        const sent = dispatcher.requestActiveDefinitionFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp definition request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .goto_definition;
        self.setMessage("LSP definition requested") catch {};
        return true;
    }

    fn requestImplementationFromLsp(self: *GuiState) bool {
        const sent = dispatcher.requestActiveImplementationFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp implementation request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .goto_implementation;
        self.setMessage("LSP implementation requested") catch {};
        return true;
    }

    fn requestTypeDefinitionFromLsp(self: *GuiState) bool {
        const sent = dispatcher.requestActiveTypeDefinitionFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp type definition request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .goto_type_definition;
        self.setMessage("LSP type definition requested") catch {};
        return true;
    }

    fn requestHoverFromLsp(self: *GuiState) bool {
        const sent = dispatcher.requestActiveHoverFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp hover request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .hover;
        self.setMessage("LSP hover requested") catch {};
        return true;
    }

    fn requestFormattingFromLsp(self: *GuiState) bool {
        const sent = dispatcher.requestActiveFormattingFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp formatting request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .formatting_preview;
        self.setMessage("LSP formatting requested") catch {};
        return true;
    }

    fn requestReferencesFromLsp(self: *GuiState) bool {
        const sent = dispatcher.requestActiveReferencesFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp references request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .find_references;
        self.setMessage("LSP references requested") catch {};
        return true;
    }

    fn requestCodeActionsFromLsp(self: *GuiState) bool {
        const sent = dispatcher.requestActiveCodeActionsFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp code action request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .code_actions;
        self.setMessage("LSP code actions requested") catch {};
        return true;
    }

    fn requestRenameFromLsp(self: *GuiState, new_name: []const u8) bool {
        const sent = dispatcher.requestActiveRenameFromRunningLsp(&self.app, new_name) catch |err| {
            self.appendOutput(.stderr, "lsp rename request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .rename_preview;
        self.setMessage("LSP rename requested") catch {};
        return true;
    }

    fn finishPendingLspAction(self: *GuiState) void {
        switch (self.pending_lsp_action) {
            .none => {},
            .completion => {
                if (self.app.activeLspSessionConst()) |session| {
                    if (session.last_completion != null) {
                        self.pending_lsp_action = .none;
                        if (self.quick_panel.visible and self.quick_panel.mode == .completion) {
                            self.quick_panel.rebuild(&self.app) catch |err| {
                                self.appendOutput(.stderr, "completion refresh failed: {s}\n", .{@errorName(err)});
                            };
                        }
                        self.setMessage("LSP completions updated") catch {};
                    }
                }
            },
            .goto_definition => {
                if (self.app.activeLspSessionConst()) |session| {
                    if (session.last_locations_kind == .definition) {
                        if (session.last_locations) |locations| {
                            self.pending_lsp_action = .none;
                            if (locations.items.len == 0) {
                                self.setMessage("No LSP definition") catch {};
                                return;
                            }
                            if (locations.items.len > 1) {
                                self.showLspLocations("LSP definitions");
                                return;
                            }
                            const location = locations.items[0];
                            self.openRelativeLocation(location.path, location.range.start.line, location.range.start.column);
                            self.setMessage("Opened LSP definition") catch {};
                        }
                    }
                }
            },
            .goto_implementation => {
                if (self.openCachedLspLocationsForKind(.implementation, "LSP implementations", "Opened LSP implementation", "No LSP implementation")) {
                    self.pending_lsp_action = .none;
                }
            },
            .goto_type_definition => {
                if (self.openCachedLspLocationsForKind(.type_definition, "LSP type definitions", "Opened LSP type definition", "No LSP type definition")) {
                    self.pending_lsp_action = .none;
                }
            },
            .find_references => {
                if (self.app.activeLspSessionConst()) |session| {
                    if (session.last_locations_kind == .references) {
                        if (session.last_locations) |locations| {
                            self.pending_lsp_action = .none;
                            if (locations.items.len == 0) {
                                self.setMessage("No LSP references") catch {};
                                return;
                            }
                            self.showLspLocations("LSP references");
                        }
                    }
                }
            },
            .hover => {
                if (self.app.activeLspSessionConst()) |session| {
                    if (session.last_hover) |hover| {
                        self.pending_lsp_action = .none;
                        self.showLspHover("LSP hover", &hover);
                    }
                }
            },
            .rename_preview => {
                if (self.app.activeLspSessionConst()) |session| {
                    if (session.last_workspace_edit_kind == .rename) {
                        if (session.last_workspace_edit) |edit| {
                            self.pending_lsp_action = .none;
                            self.deferred_lsp_rename_name.clearRetainingCapacity();
                            self.showLspWorkspaceEdit("LSP rename preview", &edit);
                        }
                    }
                }
            },
            .formatting_preview => {
                if (self.app.activeLspSessionConst()) |session| {
                    if (session.last_workspace_edit_kind == .formatting) {
                        if (session.last_workspace_edit) |edit| {
                            self.pending_lsp_action = .none;
                            self.showLspWorkspaceEdit("LSP formatting preview", &edit);
                        }
                    }
                }
            },
            .code_actions => {
                if (self.app.activeLspSessionConst()) |session| {
                    if (session.last_code_actions) |actions| {
                        self.pending_lsp_action = .none;
                        self.showLspCodeActions("LSP code actions", &actions);
                    }
                }
            },
        }
    }

    fn showLspLocations(self: *GuiState, label: []const u8) void {
        const session = self.app.activeLspSessionConst() orelse return;
        const locations = session.last_locations orelse return;
        self.show_output = true;
        self.bottom_panel = .output;
        self.appendOutput(.stdout, "{s}: {d}\n", .{ label, locations.items.len });
        for (locations.items[0..@min(locations.items.len, @as(usize, 80))]) |location| {
            self.appendOutput(.stdout, "{s}:{d}:{d}\n", .{ location.path, location.range.start.line + 1, location.range.start.column + 1 });
        }
        if (locations.items.len > 80) self.appendOutput(.stdout, "... {d} more LSP location(s)\n", .{locations.items.len - 80});
        self.setMessage("Showing LSP locations") catch {};
        if (locations.items.len > 0) {
            self.openQuickPanel(.lsp_locations);
            self.quick_panel.visible = true;
            self.setMessage("Select an LSP location and press Enter") catch {};
        }
    }

    fn showLspHover(self: *GuiState, label: []const u8, hover: *const lsp_responses.Hover) void {
        self.show_output = true;
        self.bottom_panel = .output;
        self.appendOutput(.stdout, "{s}: {d} bytes\n{s}\n", .{ label, hover.text.len, hover.text });
        if (hover.text.len == 0) {
            self.setMessage("Empty LSP hover") catch {};
            return;
        }
        self.openQuickPanel(.lsp_hover);
        self.quick_panel.visible = true;
        self.setMessage("LSP hover") catch {};
    }

    fn showLspWorkspaceEdit(self: *GuiState, label: []const u8, edit: *const lsp_responses.WorkspaceEdit) void {
        self.show_output = true;
        self.bottom_panel = .output;
        self.appendOutput(.stdout, "{s}: edits={d} skipped_resource_ops={d}\n", .{ label, edit.edits.len, edit.skipped_resource_ops });
        for (edit.edits[0..@min(edit.edits.len, @as(usize, 80))]) |item| {
            const preview_len = @min(item.new_text.len, @as(usize, 80));
            self.appendOutput(.stdout, "{s}:{d}:{d}-{d}:{d} -> \"{s}\"\n", .{
                item.path,
                item.range.start.line + 1,
                item.range.start.column + 1,
                item.range.end.line + 1,
                item.range.end.column + 1,
                item.new_text[0..preview_len],
            });
        }
        if (edit.edits.len > 80) self.appendOutput(.stdout, "... {d} more LSP edit(s)\n", .{edit.edits.len - 80});
        self.appendOutput(.stdout, "run lsp.apply_workspace_edit to apply these edits to dirty editor buffers; save afterwards to write files\n", .{});
        self.setMessage(label) catch {};
    }

    fn showLspCodeActions(self: *GuiState, label: []const u8, actions: *const lsp_responses.CodeActions) void {
        self.show_output = true;
        self.bottom_panel = .output;
        self.appendOutput(.stdout, "{s}: {d}\n", .{ label, actions.items.len });
        for (actions.items[0..@min(actions.items.len, @as(usize, 40))], 0..) |item, index| {
            self.appendOutput(.stdout, "{d}. [{s}] {s}", .{ index + 1, item.kind, item.title });
            if (item.workspace_edit) |edit| self.appendOutput(.stdout, " edits={d}", .{edit.edits.len});
            if (item.command_title.len > 0) self.appendOutput(.stdout, " command={s}", .{item.command_title});
            if (item.diagnostics > 0) self.appendOutput(.stdout, " diagnostics={d}", .{item.diagnostics});
            self.appendOutput(.stdout, "\n", .{});
        }
        if (actions.items.len > 40) self.appendOutput(.stdout, "... {d} more LSP code action(s)\n", .{actions.items.len - 40});
        self.appendOutput(.stdout, "run lsp.apply_first_code_action to apply the first editable action to dirty editor buffers\n", .{});
        self.setMessage("Showing LSP code actions") catch {};
        if (actions.items.len > 0) {
            self.openQuickPanel(.code_actions);
            self.quick_panel.visible = true;
            self.setMessage("Select a Quick Fix and press Enter") catch {};
        }
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

    fn editAtAllCursors(self: *GuiState, action: MultiCursorEdit, bytes: []const u8) bool {
        if (self.secondary_cursors.items.len == 0 or self.selection_anchor != null) return false;
        const doc = self.app.documents.active() orelse return false;
        const count = self.secondary_cursors.items.len + 1;
        const edits = self.allocator.alloc(multi_cursor_mod.Edit, count) catch |err| {
            self.setError(err) catch {};
            return true;
        };
        defer self.allocator.free(edits);

        var changed = false;
        for (edits, 0..) |*edit, index| {
            const raw_offset = if (index == 0) doc.cursor.position.byte_offset else self.secondary_cursors.items[index - 1];
            const offset = @min(raw_offset, doc.text.bytes.len);
            edit.* = switch (action) {
                .insert => .{
                    .start = offset,
                    .end = offset,
                    .replacement = bytes,
                    .cursor_in_replacement = bytes.len,
                },
                .delete_backward => blk: {
                    const previous = if (offset == 0) offset else doc.text.previousByteOffset(offset) catch offset;
                    break :blk .{ .start = previous, .end = offset, .replacement = "", .cursor_in_replacement = 0 };
                },
                .delete_forward => blk: {
                    const next = doc.text.nextByteOffset(offset) catch offset;
                    break :blk .{ .start = offset, .end = next, .replacement = "", .cursor_in_replacement = 0 };
                },
            };
            changed = changed or edit.start != edit.end or edit.replacement.len != 0;
        }

        self.secondary_cursors.ensureTotalCapacity(count - 1) catch |err| {
            self.setError(err) catch {};
            return true;
        };
        const mapped = doc.editAtCursors(edits) catch |err| {
            self.setError(err) catch {};
            return true;
        };
        defer self.allocator.free(mapped);

        self.secondary_cursors.clearRetainingCapacity();
        for (mapped[1..]) |offset| {
            if (offset == mapped[0] or containsOffset(self.secondary_cursors.items, offset)) continue;
            self.secondary_cursors.appendAssumeCapacity(offset);
        }
        std.mem.sort(usize, self.secondary_cursors.items, {}, offsetLessThan);
        self.selection_anchor = null;
        self.app.mode = .insert;
        self.app.focus = .editor;
        self.ensureCursorVisible();
        if (changed) self.syncActiveDocumentToLsp();
        return true;
    }

    fn toggleSecondaryCursor(self: *GuiState, offset_raw: usize) void {
        const doc = self.app.documents.active() orelse return;
        const offset = @min(offset_raw, doc.text.bytes.len);
        self.selection_anchor = null;
        if (offset == doc.cursor.position.byte_offset) {
            self.setMessage("Primary cursor already here") catch {};
            return;
        }
        for (self.secondary_cursors.items, 0..) |existing, index| {
            if (existing != offset) continue;
            _ = self.secondary_cursors.orderedRemove(index);
            self.setMultiCursorMessage();
            return;
        }
        self.secondary_cursors.append(offset) catch |err| {
            self.setError(err) catch {};
            return;
        };
        std.mem.sort(usize, self.secondary_cursors.items, {}, offsetLessThan);
        self.setMultiCursorMessage();
    }

    fn addCursorVertically(self: *GuiState, delta: isize) void {
        const doc = self.app.documents.active() orelse return;
        var edge = doc.cursor.position;
        for (self.secondary_cursors.items) |offset| {
            const position = doc.positionFromOffset(@min(offset, doc.text.bytes.len)) catch continue;
            if ((delta < 0 and position.line < edge.line) or (delta > 0 and position.line > edge.line)) edge = position;
        }
        const target_line = if (delta < 0) blk: {
            if (edge.line == 0) return self.setMultiCursorMessage();
            break :blk edge.line - 1;
        } else blk: {
            if (edge.line + 1 >= doc.text.lineCount()) return self.setMultiCursorMessage();
            break :blk edge.line + 1;
        };
        const target_column = @min(edge.column, doc.text.lineSlice(target_line).len);
        const target = doc.text.lineColumnToOffset(target_line, target_column) catch return;
        if (target == doc.cursor.position.byte_offset or containsOffset(self.secondary_cursors.items, target)) return;
        self.secondary_cursors.append(target) catch |err| {
            self.setError(err) catch {};
            return;
        };
        std.mem.sort(usize, self.secondary_cursors.items, {}, offsetLessThan);
        self.selection_anchor = null;
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.setMultiCursorMessage();
    }

    fn setMultiCursorMessage(self: *GuiState) void {
        var buffer: [64]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "{d} cursors", .{self.secondary_cursors.items.len + 1}) catch "Multiple cursors";
        self.setMessage(message) catch {};
    }

    fn insertText(self: *GuiState, bytes: []const u8) void {
        if (self.editAtAllCursors(.insert, bytes)) return;
        const doc = self.app.documents.active() orelse {
            self.setMessage("Open a file before typing") catch {};
            return;
        };
        if (self.selectedRange(doc)) |range| {
            doc.replaceRange(range.start, range.end, bytes) catch |err| {
                self.setError(err) catch {};
                return;
            };
            self.clearSelection();
        } else {
            doc.insert(doc.cursor.position.byte_offset, bytes) catch |err| {
                self.setError(err) catch {};
                return;
            };
        }
        self.app.mode = .insert;
        self.app.focus = .editor;
        self.ensureCursorVisible();
        self.syncActiveDocumentToLsp();
    }

    fn insertTypedText(self: *GuiState, bytes: []const u8) void {
        if (self.editAtAllCursors(.insert, bytes)) return;
        const doc = self.app.documents.active() orelse {
            self.setMessage("Open a file before typing") catch {};
            return;
        };
        const result = doc.typeText(self.selection_anchor, bytes) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.selection_anchor = result.selection_anchor;
        self.app.mode = .insert;
        self.app.focus = .editor;
        self.ensureCursorVisible();
        if (result.changed) self.syncActiveDocumentToLsp();
    }

    fn changeIndentation(self: *GuiState, outdent: bool) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("Open a file before indenting") catch {};
            return;
        };
        const cursor_offset = doc.cursor.position.byte_offset;
        const selected = self.selectedRange(doc) != null;
        if (!selected and !outdent) {
            const spaces = 4 - (doc.cursor.position.column % 4);
            self.insertText("    "[0..spaces]);
            return;
        }

        const anchor_offset = if (selected) self.selection_anchor.? else cursor_offset;
        const result = if (outdent)
            doc.outdentLines(anchor_offset, cursor_offset, 4)
        else
            doc.indentLines(anchor_offset, cursor_offset, "    ");
        const edit = result catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (selected) {
            self.selection_anchor = edit.anchor_offset;
        } else {
            self.clearSelection();
        }
        self.app.mode = .insert;
        self.app.focus = .editor;
        self.ensureCursorVisible();
        if (edit.changed) {
            self.syncActiveDocumentToLsp();
            self.setMessage(if (outdent) "Outdented lines" else "Indented lines") catch {};
        } else {
            self.setMessage("Line is already fully outdented") catch {};
        }
    }

    fn insertNewline(self: *GuiState) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("Open a file before typing") catch {};
            return;
        };
        if (self.secondary_cursors.items.len > 0 and self.selection_anchor == null) {
            _ = self.editAtAllCursors(.insert, doc.preferredNewline());
            return;
        }
        const result = doc.insertSmartNewline(self.selection_anchor, 4) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.selection_anchor = result.selection_anchor;
        self.app.mode = .insert;
        self.app.focus = .editor;
        self.ensureCursorVisible();
        if (result.changed) self.syncActiveDocumentToLsp();
    }

    fn normalizeActiveDocumentNewlines(self: *GuiState, newline: document_mod.Newline) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        const changed = doc.normalizeNewlines(newline) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.clearSelection();
        self.ensureCursorVisible();
        if (changed) {
            self.setMessage(switch (newline) {
                .lf => "Normalized line endings to LF",
                .crlf => "Normalized line endings to CRLF",
                else => "Normalized line endings",
            }) catch {};
            self.refreshActiveSecurityFindings(switch (newline) {
                .lf => "Normalized line endings to LF",
                .crlf => "Normalized line endings to CRLF",
                else => "Normalized line endings",
            });
            self.syncActiveDocumentToLsp();
        } else {
            self.setMessage("Line endings already normalized") catch {};
        }
    }

    fn toggleActiveDocumentComment(self: *GuiState) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        const range = self.selectedRange(doc);
        const start = if (range) |selected| selected.start else doc.cursor.position.byte_offset;
        const end = if (range) |selected| selected.end else doc.cursor.position.byte_offset;
        const result = (doc.toggleComment(start, end) catch |err| {
            self.setError(err) catch {};
            return;
        }) orelse {
            self.setMessage("No comment syntax for language") catch {};
            return;
        };
        self.clearSelection();
        self.ensureCursorVisible();
        self.syncActiveDocumentToLsp();
        self.setMessage(commentToggleMessage(result)) catch {};
    }

    fn sanitizeActiveDocumentHiddenControls(self: *GuiState) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };

        var sanitized: std.Io.Writer.Allocating = .init(self.allocator);
        defer sanitized.deinit();

        const before_cursor = doc.cursor.position;
        var removed: usize = 0;
        var index: usize = 0;
        while (index < doc.text.bytes.len) {
            if (text_integrity.hiddenControlLengthAt(doc.text.bytes, index)) |len| {
                removed += 1;
                index += len;
                continue;
            }
            sanitized.writer.writeByte(doc.text.bytes[index]) catch |err| {
                self.setError(err) catch {};
                return;
            };
            index += 1;
        }

        if (removed == 0) {
            self.setMessage("No hidden controls to clean") catch {};
            return;
        }

        doc.replaceRange(0, doc.text.bytes.len, sanitized.written()) catch |err| {
            self.setError(err) catch {};
            return;
        };
        const target_line = @min(before_cursor.line, doc.text.lineCount() - 1);
        const target_column = @min(before_cursor.column, doc.text.lineSlice(target_line).len);
        const target_offset = doc.text.lineColumnToOffset(target_line, target_column) catch @min(before_cursor.byte_offset, doc.text.bytes.len);
        doc.cursor.position = doc.positionFromOffset(target_offset) catch doc.cursor.position;
        self.clearSelection();
        self.ensureCursorVisible();
        self.syncActiveDocumentToLsp();

        var message_buf: [96]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "Removed {d} hidden control marker{s}", .{ removed, if (removed == 1) "" else "s" }) catch "Removed hidden controls";
        self.refreshActiveSecurityFindings(message);
    }

    fn refreshActiveSecurityFindings(self: *GuiState, message: []const u8) void {
        self.show_output = true;
        self.bottom_panel = .security;
        self.security_scroll_line = 0;
        const result = dispatcher.dispatch(&self.app, .{ .id = "security.scan_current", .source = .command_palette }) catch |err| {
            self.setError(err) catch {};
            return;
        };
        switch (result) {
            .completed => self.setMessage(message) catch {},
            .blocked => |reason| self.setMessage(reason) catch {},
            .unknown_command => self.setMessage("Security scan command missing") catch {},
            .no_active_document => self.setMessage("No active document") catch {},
            .external_command => {},
            .unsupported => |reason| self.setMessage(reason) catch {},
        }
    }

    fn undo(self: *GuiState) void {
        const doc = self.app.documents.active() orelse return;
        const changed = doc.undo() catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (changed) {
            self.clearSelection();
            const offset = @min(doc.cursor.position.byte_offset, doc.text.bytes.len);
            doc.cursor.position = doc.positionFromOffset(offset) catch doc.cursor.position;
            self.ensureCursorVisible();
            self.syncActiveDocumentToLsp();
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
            self.clearSelection();
            const offset = @min(doc.cursor.position.byte_offset, doc.text.bytes.len);
            doc.cursor.position = doc.positionFromOffset(offset) catch doc.cursor.position;
            self.ensureCursorVisible();
            self.syncActiveDocumentToLsp();
            self.setMessage("Redo") catch {};
        } else {
            self.setMessage("Nothing to redo") catch {};
        }
    }

    fn gotoLineFromQuickPanel(self: *GuiState) void {
        const doc = self.app.documents.active() orelse {
            self.setMessage("No active document") catch {};
            return;
        };
        const target = goto_line.parse(self.quick_panel.query.items) orelse {
            self.setMessage("Type line or line:column") catch {};
            return;
        };
        const last_line = if (doc.text.lineCount() == 0) 0 else doc.text.lineCount() - 1;
        const line = @min(target.line, last_line);
        const column = @min(target.column, doc.text.lineSlice(line).len);
        const offset = doc.text.lineColumnToOffset(line, column) catch |err| {
            self.setError(err) catch {};
            return;
        };
        navigation.setCursor(doc, doc.positionFromOffset(offset) catch doc.cursor.position);
        self.clearSelection();
        self.quick_panel.close();
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();

        var message_buf: [64]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "Line {d}:{d}", .{ line + 1, column + 1 }) catch "Line selected";
        self.setMessage(message) catch {};
    }

    fn closeActiveDocument(self: *GuiState) void {
        self.app.documents.closeActive(.deny_dirty) catch |err| {
            switch (err) {
                error.DirtyDocument => self.setMessage("Save before closing") catch {},
                else => self.setError(err) catch {},
            }
            return;
        };
        self.clearSelection();
        self.app.focus = if (self.app.documents.active() != null) .editor else .files;
        self.setMessage("Closed document") catch {};
    }

    fn deleteBackward(self: *GuiState) void {
        if (self.editAtAllCursors(.delete_backward, "")) return;
        const doc = self.app.documents.active() orelse return;
        if (self.deleteSelectedRange(doc)) {
            self.ensureCursorVisible();
            return;
        }
        const changed = doc.deleteBackwardSmart() catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (!changed) return;
        self.ensureCursorVisible();
        self.syncActiveDocumentToLsp();
    }

    fn deleteForward(self: *GuiState) void {
        if (self.editAtAllCursors(.delete_forward, "")) return;
        const doc = self.app.documents.active() orelse return;
        if (self.deleteSelectedRange(doc)) {
            self.ensureCursorVisible();
            return;
        }
        const current = doc.cursor.position.byte_offset;
        const next = doc.text.nextByteOffset(current) catch return;
        if (next == current) return;
        doc.deleteRange(current, next) catch |err| {
            self.setError(err) catch {};
            return;
        };
        self.ensureCursorVisible();
        self.syncActiveDocumentToLsp();
    }

    fn moveCursor(self: *GuiState, move: navigation.Move, extend_selection: bool) void {
        const doc = self.app.documents.active() orelse return;
        const anchor = doc.cursor.position.byte_offset;
        if (extend_selection) self.secondary_cursors.clearRetainingCapacity();
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = anchor;
        }
        navigation.moveCursor(doc, move) catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (!extend_selection) {
            self.clearSelection();
        } else if (self.selection_anchor) |selection_anchor| {
            if (selection_anchor == doc.cursor.position.byte_offset) self.clearSelection();
        }
        self.app.focus = .editor;
        self.ensureCursorVisible();
    }

    fn setEditorCursorFromPoint(self: *GuiState, layout: Layout, x: c_int, y: c_int) void {
        const doc = self.app.documents.active() orelse return;
        const anchor = doc.cursor.position.byte_offset;
        const position = self.editorPositionFromPoint(layout, x, y) orelse return;
        if (isKeyDown(VK_SHIFT)) self.secondary_cursors.clearRetainingCapacity();
        if (isKeyDown(VK_SHIFT)) {
            if (self.selection_anchor == null) self.selection_anchor = anchor;
        } else {
            self.clearSelection();
        }
        navigation.setCursor(doc, position);
        if (self.selection_anchor) |selection_anchor| {
            if (selection_anchor == doc.cursor.position.byte_offset) self.clearSelection();
        }
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
    }

    fn beginEditorDrag(self: *GuiState, layout: Layout, x: c_int, y: c_int) void {
        const doc = self.app.documents.active() orelse return;
        const previous = doc.cursor.position.byte_offset;
        const position = self.editorPositionFromPoint(layout, x, y) orelse return;
        if (isKeyDown(VK_SHIFT)) self.secondary_cursors.clearRetainingCapacity();
        if (isKeyDown(VK_SHIFT)) {
            if (self.selection_anchor == null) self.selection_anchor = previous;
        } else {
            self.secondary_cursors.clearRetainingCapacity();
            self.selection_anchor = position.byte_offset;
        }
        navigation.setCursor(doc, position);
        self.editor_dragging = true;
        if (self.hwnd) |window| _ = SetCapture(window);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureCursorVisible();
    }

    fn updateEditorDrag(self: *GuiState, layout: Layout, x: c_int, y: c_int) void {
        if (!self.editor_dragging) return;
        const doc = self.app.documents.active() orelse return;
        const position = self.editorPositionFromPoint(layout, x, y) orelse return;
        navigation.setCursor(doc, position);
        self.app.focus = .editor;
        self.ensureCursorVisible();
    }

    fn endEditorDrag(self: *GuiState) void {
        if (!self.editor_dragging) return;
        self.editor_dragging = false;
        _ = ReleaseCapture();
        if (self.app.documents.active()) |doc| {
            if (self.selectedRange(doc) == null) self.clearSelection();
        }
    }

    fn editorPositionFromPoint(self: *GuiState, layout: Layout, x: c_int, y: c_int) ?types.Position {
        const doc = self.app.documents.active() orelse return null;
        if (doc.text.lineCount() == 0) return types.Position.start();

        const text_x = layout.editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X;
        const text_y = layout.editor.top + HEADER_HEIGHT + EDITOR_TEXT_PADDING_Y;
        const clamped_y = @min(@max(y, text_y), @max(text_y, layout.editor.bottom - 1));
        const clamped_x = @max(x, text_x);
        const rel_y = clamped_y - text_y;
        const rel_x = clamped_x - text_x;
        const line = self.editor_scroll_line + @as(usize, @intCast(@divTrunc(rel_y, ROW_HEIGHT)));
        const column = @as(usize, @intCast(@divTrunc(rel_x, CHAR_WIDTH)));
        const clamped_line = @min(line, doc.text.lineCount() - 1);
        const offset = doc.text.lineColumnToOffset(clamped_line, column) catch return null;
        return doc.positionFromOffset(offset) catch null;
    }

    fn clearSelection(self: *GuiState) void {
        self.selection_anchor = null;
        self.secondary_cursors.clearRetainingCapacity();
    }

    fn selectedRange(self: *const GuiState, doc: *const document_mod.Document) ?SelectionRange {
        const anchor_raw = self.selection_anchor orelse return null;
        const cursor_raw = doc.cursor.position.byte_offset;
        const anchor = @min(anchor_raw, doc.text.bytes.len);
        const cursor = @min(cursor_raw, doc.text.bytes.len);
        if (anchor == cursor) return null;
        return if (anchor < cursor)
            .{ .start = anchor, .end = cursor }
        else
            .{ .start = cursor, .end = anchor };
    }

    fn deleteSelectedRange(self: *GuiState, doc: *document_mod.Document) bool {
        const range = self.selectedRange(doc) orelse return false;
        doc.deleteRange(range.start, range.end) catch |err| {
            self.setError(err) catch {};
            return false;
        };
        self.clearSelection();
        self.syncActiveDocumentToLsp();
        return true;
    }

    fn selectAll(self: *GuiState) void {
        const doc = self.app.documents.active() orelse return;
        self.secondary_cursors.clearRetainingCapacity();
        self.selection_anchor = 0;
        const position = doc.positionFromOffset(doc.text.bytes.len) catch return;
        navigation.setCursor(doc, position);
        self.app.focus = .editor;
        self.ensureCursorVisible();
        self.setMessage("Selected all") catch {};
    }

    fn copySelectionToClipboard(self: *GuiState) bool {
        const doc = self.app.documents.active() orelse return false;
        const range = self.selectedRange(doc) orelse {
            self.setMessage("No selection to copy") catch {};
            return false;
        };
        setClipboardUtf8(self.hwnd, doc.text.bytes[range.start..range.end]) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "clipboard copy failed: {s}\n", .{@errorName(err)});
            return false;
        };
        self.setMessage("Copied selection") catch {};
        return true;
    }

    fn cutSelectionToClipboard(self: *GuiState) void {
        const doc = self.app.documents.active() orelse return;
        if (!self.copySelectionToClipboard()) return;
        _ = self.deleteSelectedRange(doc);
        self.ensureCursorVisible();
        self.setMessage("Cut selection") catch {};
    }

    fn pasteFromClipboard(self: *GuiState) void {
        const text = getClipboardUtf8(self.allocator, self.hwnd) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "clipboard paste failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(text);
        if (text.len == 0) return;
        self.insertText(text);
        self.setMessage("Pasted") catch {};
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
            .debug => {},
            .git => {
                const visible = bottomPanelVisibleRows(bottomPanelContentRect(layout.output));
                const total = if (self.git_overview) |overview| gitPanelRowCount(overview) else 0;
                scrollIndex(&self.git_scroll_line, total, visible, delta);
            },
            .extensions => {
                const visible = bottomPanelVisibleRows(bottomPanelContentRect(layout.output));
                const total = if (self.extensions_registry) |registry| registry.items.items.len else 0;
                scrollIndex(&self.extensions_scroll_line, total, visible, delta);
            },
            .diagnostics => {
                const visible = bottomPanelVisibleRows(bottomPanelContentRect(layout.output));
                scrollIndex(&self.diagnostics_scroll_line, self.app.diagnostics.items.items.len, visible, delta);
            },
            .security => {
                const visible = securityPanelVisibleRows(bottomPanelContentRect(layout.output));
                scrollIndex(&self.security_scroll_line, self.app.security_findings.items.items.len, visible, delta);
            },
            .settings => {},
            .keybindings => {
                const visible = bottomPanelVisibleRows(bottomPanelContentRect(layout.output));
                scrollIndex(&self.keybindings_scroll_line, command_mod.all().len, visible, delta);
            },
            .tutorial => {
                const visible = bottomPanelVisibleRows(bottomPanelContentRect(layout.output));
                scrollIndex(&self.tutorial_scroll_line, tutorialLineCount(self.tutorial_language), visible, delta);
            },
            .publish => {
                const visible = bottomPanelVisibleRows(bottomPanelContentRect(layout.output));
                scrollIndex(&self.publish_scroll_line, publishLineCount(), visible, delta);
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
                if (self.quick_panel.mode == .replace_workspace and pointIn(quickPanelApplyButtonRect(panel), x, y)) {
                    self.applyWorkspaceReplacementFromQuickPanel();
                    return;
                }
                if (y >= panel.top + PALETTE_MATCH_TOP) {
                    const row = @as(usize, @intCast(@divTrunc(y - panel.top - PALETTE_MATCH_TOP, ROW_HEIGHT)));
                    if (row < @min(@as(usize, 10), self.quick_panel.itemCount())) {
                        self.quick_panel.selected_index = quickPanelVisibleStart(&self.quick_panel, 10) + row;
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
            if (pointIn(saveAllButtonRect(layout), x, y)) {
                self.executeCommand("file.save_all");
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
            if (x >= layout.editor.left and x < layout.editor.left + 18) {
                const position = self.editorPositionFromPoint(layout, x, y) orelse return;
                if (self.app.documents.active()) |doc| navigation.setCursor(doc, position);
                self.clearSelection();
                self.app.focus = .editor;
                self.app.mode = .insert;
                self.ensureCursorVisible();
                self.executeDebugPanelAction(.breakpoint);
                return;
            }
            if (isKeyDown(VK_MENU)) {
                const position = self.editorPositionFromPoint(layout, x, y) orelse return;
                self.toggleSecondaryCursor(position.byte_offset);
                self.app.focus = .editor;
                self.app.mode = .insert;
                self.ensureCursorVisible();
                return;
            }
            self.beginEditorDrag(layout, x, y);
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
                if (panel == .extensions and self.extensions_registry == null) self.refreshExtensionsRegistry();
                return;
            }
            if (self.bottom_panel == .debug) {
                const content = bottomPanelContentRect(layout.output);
                if (debugPanelActionAt(content, x, y)) |action| {
                    self.executeDebugPanelAction(action);
                    return;
                }
                if (debugPanelStackRowAt(content, x, y)) |row| {
                    self.selectDebugFrameAt(row);
                    return;
                }
                if (debugPanelVariableRowAt(content, x, y)) |row| {
                    self.activateDebugValueAt(row);
                    return;
                }
            }
            if (self.bottom_panel == .git) {
                const content = bottomPanelContentRect(layout.output);
                if (gitPanelActionAt(content, x, y)) |action| {
                    self.executeGitPanelAction(action);
                    return;
                }
            }
            if (self.bottom_panel == .security) {
                const content = bottomPanelContentRect(layout.output);
                if (securityPanelActionAt(content, x, y)) |action| {
                    self.executeSecurityPanelAction(action);
                    return;
                }
            }
            if (self.bottom_panel == .extensions) {
                const content = bottomPanelContentRect(layout.output);
                if (extensionPanelActionAt(content, x, y)) |action| {
                    self.executeExtensionPanelAction(action);
                    return;
                }
            }
            if (self.bottom_panel == .tutorial) {
                const content = bottomPanelContentRect(layout.output);
                if (tutorialPanelActionAt(content, x, y)) |action| {
                    self.executeTutorialPanelAction(action);
                    return;
                }
            }
            if (self.bottom_panel == .settings) {
                const content = bottomPanelContentRect(layout.output);
                if (settingsPanelActionAt(content, x, y)) |action| {
                    self.executeSettingsPanelAction(action);
                    return;
                }
            }
            if (self.bottom_panel == .publish) {
                const content = bottomPanelContentRect(layout.output);
                if (publishPanelActionAt(content, x, y)) |action| {
                    self.executePublishPanelAction(action);
                    return;
                }
            }
            if (self.bottom_panel == .output) {
                const output = consoleOutputRect(layout, self);
                if (self.hasCachedLspWorkspaceEdit() and pointIn(outputApplyButtonRect(output), x, y)) {
                    self.applyCachedLspWorkspaceEdit();
                    return;
                }
            }
            switch (self.bottom_panel) {
                .output => self.openConsoleLineAt(layout, y),
                .debug => {},
                .git => if (bottomPanelRowAt(bottomPanelContentRect(layout.output), y)) |row| {
                    const rect = bottomPanelContentRect(layout.output);
                    self.openGitPanelRow(rect, self.git_scroll_line + row, x);
                },
                .extensions => if (bottomPanelRowAt(bottomPanelContentRect(layout.output), y)) |row| self.openExtensionPanelRow(self.extensions_scroll_line + row),
                .diagnostics => if (bottomPanelRowAt(bottomPanelContentRect(layout.output), y)) |row| self.jumpToDiagnostic(self.diagnostics_scroll_line + row),
                .security => if (securityPanelFindingRowAt(bottomPanelContentRect(layout.output), y)) |row| self.jumpToSecurityFinding(self.security_scroll_line + row),
                .settings => {},
                .keybindings => if (bottomPanelRowAt(bottomPanelContentRect(layout.output), y)) |row| {
                    const definitions = command_mod.all();
                    const index = self.keybindings_scroll_line + row;
                    if (index < definitions.len) self.executeCommand(definitions[index].id);
                },
                .tutorial => {},
                .publish => {},
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
        WM_MOUSEMOVE => {
            if (global_state) |state| {
                if (state.editor_dragging) {
                    state.updateEditorDrag(layoutForWindow(hwnd, state), mouseX(lparam), mouseY(lparam));
                    _ = InvalidateRect(hwnd, null, .FALSE);
                }
            }
            return 0;
        },
        WM_LBUTTONUP => {
            if (global_state) |state| {
                state.endEditorDrag();
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
        WM_TIMER => {
            if (wparam == LSP_PUMP_TIMER_ID) {
                if (global_state) |state| {
                    var redraw = state.pumpLsp();
                    redraw = state.pumpDebug() or redraw;
                    state.file_watch_ticks +%= 1;
                    if (state.file_watch_ticks >= 8) {
                        state.file_watch_ticks = 0;
                        redraw = state.pollExternalFileChanges() or redraw;
                    }
                    state.recovery_ticks +%= 1;
                    if (state.recovery_ticks >= 17) {
                        state.recovery_ticks = 0;
                        redraw = state.checkpointRecovery() or redraw;
                    }
                    if (redraw) _ = InvalidateRect(hwnd, null, .FALSE);
                }
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_PAINT => {
            paint(hwnd);
            return 0;
        },
        WM_DESTROY => {
            _ = KillTimer(hwnd, LSP_PUMP_TIMER_ID);
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn handleKeyDown(hwnd: windows.HWND, state: *GuiState, key: WPARAM) void {
    const ctrl = isKeyDown(VK_CONTROL);
    const shift = isKeyDown(VK_SHIFT);
    const alt = isKeyDown(VK_MENU);

    if (state.quick_panel.visible) {
        switch (key) {
            VK_ESCAPE => state.quick_panel.close(),
            VK_UP => state.quick_panel.moveSelection(-1),
            VK_DOWN => state.quick_panel.moveSelection(1),
            VK_RETURN => {
                state.suppressed_char = '\r';
                if (ctrl and state.quick_panel.mode == .replace_document) {
                    state.replaceAllFromQuickPanel();
                } else if (ctrl and state.quick_panel.mode == .replace_workspace) {
                    state.applyWorkspaceReplacementFromQuickPanel();
                } else {
                    state.executeSelectedQuickPanelItem();
                }
            },
            VK_F3 => state.moveQuickPanelDocumentMatch(if (shift) -1 else 1),
            VK_F6 => state.toggleQuickPanelCaseSensitive(),
            VK_F7 => state.toggleQuickPanelWholeWord(),
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
            VK_RETURN => {
                state.suppressed_char = '\r';
                state.executeSelectedPaletteCommand();
            },
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
    if (ctrl and shift and key == 'X') {
        state.openExtensionsPanel();
        return;
    }
    if (ctrl and shift and key == 'L') {
        state.openPublishPanel();
        return;
    }
    if (ctrl and alt and key == 'L') {
        state.executeCommand("lsp.actions");
        return;
    }
    if (ctrl and alt and key == 'I') {
        state.executeCommand("lsp.ensure_active");
        return;
    }
    if (ctrl and shift and key == 'M') {
        state.openQuickPanel(.problems);
        return;
    }
    if (ctrl and key == VK_SPACE) {
        state.executeCommand("editor.complete");
        return;
    }
    if (ctrl and key == VK_OEM_PERIOD) {
        state.executeCommand("lsp.request_code_action");
        return;
    }
    if (ctrl and key == VK_RETURN and state.hasCachedLspWorkspaceEdit()) {
        state.applyCachedLspWorkspaceEdit();
        return;
    }
    if (ctrl and key == 'P') {
        state.openQuickPanel(.find_file);
        return;
    }
    if (ctrl and shift and key == 'F') {
        state.openQuickPanel(.search_workspace);
        return;
    }
    if (ctrl and shift and key == 'H') {
        state.openQuickPanel(.replace_workspace);
        return;
    }
    if (ctrl and key == 'F') {
        state.openQuickPanel(.find_document);
        return;
    }
    if (ctrl and key == 'H') {
        state.openQuickPanel(.replace_document);
        return;
    }
    if (key == VK_F5) {
        if (shift) {
            state.executeDebugPanelAction(.stop);
        } else if (state.app.debug_manager.session.state == .paused) {
            state.executeDebugPanelAction(.continue_execution);
        } else {
            state.executeDebugPanelAction(.start);
        }
        return;
    }
    if (key == VK_F9) {
        state.executeDebugPanelAction(.breakpoint);
        return;
    }
    if (key == VK_F10) {
        state.executeDebugPanelAction(.step_over);
        return;
    }
    if (key == VK_F11) {
        state.executeDebugPanelAction(if (shift) .step_out else .step_into);
        return;
    }
    if (key == VK_F1) {
        state.openTutorialPanel();
        return;
    }
    if (key == VK_F3) {
        state.findLastDocumentSearch(if (shift) .backward else .forward);
        return;
    }
    if (ctrl and shift and key == 'S') {
        state.executeCommand("file.save_all");
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
    if (ctrl and shift and key == 'D') {
        state.executeCommand("editor.duplicate_line");
        return;
    }
    if (ctrl and shift and key == 'K') {
        state.executeCommand("editor.delete_line");
        return;
    }
    if (ctrl and key == 'K') {
        state.executeCommand("preferences.open_keybindings");
        return;
    }
    if (ctrl and key == VK_OEM_COMMA) {
        state.executeCommand("preferences.open_settings");
        return;
    }
    if (ctrl and key == VK_OEM_2) {
        state.executeCommand("editor.toggle_comment");
        return;
    }
    if (ctrl and key == 'D') {
        state.openDiagnosticsPanel();
        return;
    }
    if (ctrl and alt and key == 'T') {
        state.runTaskByName("test");
        return;
    }
    if (ctrl and key == 'T') {
        state.openQuickPanel(.workspace_symbols);
        return;
    }
    if (ctrl and key == 'R') {
        state.runTaskByName("run");
        return;
    }
    if (ctrl and shift and key == 'G') {
        state.executeCommand("git.overview");
        return;
    }
    if (ctrl and key == 'G') {
        state.executeCommand("editor.goto_line");
        return;
    }
    if (ctrl and key == 'E') {
        state.executeCommand("view.toggle_file_tree");
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
    if (ctrl and key == 'A') {
        state.selectAll();
        return;
    }
    if (ctrl and key == 'C') {
        _ = state.copySelectionToClipboard();
        return;
    }
    if (ctrl and key == 'X') {
        state.cutSelectionToClipboard();
        return;
    }
    if (ctrl and key == 'V') {
        state.pasteFromClipboard();
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
    if (key == VK_F2) {
        state.executeCommand("symbol.rename");
        return;
    }
    if (key == VK_F12) {
        if (ctrl and alt) {
            state.executeCommand("symbol.goto_type_definition");
        } else if (ctrl) {
            state.executeCommand("symbol.goto_implementation");
        } else {
            state.executeCommand(if (shift) "symbol.find_references" else "symbol.goto_definition");
        }
        return;
    }
    if (key == VK_F6) {
        if (state.app.debug_manager.isRunning()) {
            state.executeDebugPanelAction(.pause);
        } else {
            state.show_output = !state.show_output;
        }
        return;
    }
    if (ctrl and alt and key == VK_UP and state.app.focus == .editor) {
        state.addCursorVertically(-1);
        return;
    }
    if (ctrl and alt and key == VK_DOWN and state.app.focus == .editor) {
        state.addCursorVertically(1);
        return;
    }
    if (alt and key == VK_UP and state.app.focus == .editor) {
        state.executeCommand("editor.move_line_up");
        return;
    }
    if (alt and key == VK_DOWN and state.app.focus == .editor) {
        state.executeCommand("editor.move_line_down");
        return;
    }

    switch (key) {
        VK_ESCAPE => {
            if (state.secondary_cursors.items.len > 0) {
                state.clearSelection();
                state.setMessage("Primary cursor only") catch {};
            } else if (state.app.mode == .insert) {
                state.app.mode = .normal;
            } else {
                _ = DestroyWindow(hwnd);
            }
        },
        VK_RETURN => {
            if (state.app.focus == .files) {
                state.suppressed_char = '\r';
                state.openSelected();
            }
        },
        VK_TAB => {
            if (state.app.mode == .insert and state.app.focus == .editor) {
                state.suppressed_char = '\t';
                state.changeIndentation(shift);
            }
        },
        VK_BACK => {
            if (state.app.mode == .insert and state.app.focus == .editor) state.deleteBackward();
        },
        VK_DELETE => {
            if (state.app.mode == .insert and state.app.focus == .editor) state.deleteForward();
        },
        VK_LEFT => state.moveCursor(if (ctrl) .word_left else .left, shift),
        VK_RIGHT => state.moveCursor(if (ctrl) .word_right else .right, shift),
        VK_UP => if (state.app.focus == .files) state.moveSelection(-1) else state.moveCursor(.up, shift),
        VK_DOWN => if (state.app.focus == .files) state.moveSelection(1) else state.moveCursor(.down, shift),
        VK_HOME => state.moveCursor(if (ctrl) .file_start else .line_start, shift),
        VK_END => state.moveCursor(if (ctrl) .file_end else .line_end, shift),
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
    if (isKeyDown(VK_CONTROL)) {
        state.suppressed_char = null;
        state.pending_high_surrogate = null;
        return;
    }
    const unit: u16 = @truncate(key);
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        state.pending_high_surrogate = unit;
        return;
    }
    const codepoint: u21 = if (unit >= 0xDC00 and unit <= 0xDFFF) decoded: {
        const high = state.pending_high_surrogate orelse return;
        state.pending_high_surrogate = null;
        const high_value: u21 = @as(u21, high) - 0xD800;
        const low_value: u21 = @as(u21, unit) - 0xDC00;
        break :decoded 0x10000 + (high_value << 10) + low_value;
    } else decoded: {
        state.pending_high_surrogate = null;
        break :decoded @as(u21, unit);
    };
    if (state.suppressed_char) |suppressed| {
        state.suppressed_char = null;
        if (suppressed == codepoint) return;
    }
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
        state.insertNewline();
        return;
    }
    if (codepoint == '\t') {
        return;
    }
    if (codepoint < 0x20 or codepoint == 0x7f) return;
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buffer) catch return;
    state.insertTypedText(buffer[0..len]);
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
        if (state.show_file_tree) fillRect(hdc, layout.sidebar, rgb(15, 20, 24));
        fillRect(hdc, layout.editor, rgb(11, 13, 17));
        if (state.show_output) fillRect(hdc, layout.output, rgb(10, 12, 14));
        fillRect(hdc, layout.status, rgb(35, 142, 203));
        if (state.show_file_tree) {
            fillRect(hdc, RECT{ .left = layout.sidebar.right - 1, .top = 0, .right = layout.sidebar.right, .bottom = layout.status.top }, rgb(43, 53, 61));
            drawText(hdc, 18, 15, rgb(79, 230, 226), "FILES");
            drawButton(hdc, newFileButtonRect(layout), "NEW");
            drawButton(hdc, openWorkspaceButtonRect(layout), "OPEN");
            drawButton(hdc, gitAuditButtonRect(layout), "GIT");
            drawSecurityStrip(hdc, state, layout);
            drawFileList(hdc, state, layout);
        }
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

        const risk_marker = riskMarkerForEntry(state, entry.path, entry.kind == .directory);
        const git_marker = gitMarkerForEntry(state, entry.path, entry.kind == .directory);
        const path_right = if (risk_marker != null or git_marker != null) layout.sidebar.right - 66 else layout.sidebar.right - 12;

        drawText(hdc, 16 + indent, y + 3, color, marker);
        drawTextClipped(hdc, 36 + indent, y + 3, path_right, color, entry.path);
        if (risk_marker) |security_marker| {
            drawTextRight(hdc, layout.sidebar.right - 62, y + 3, layout.sidebar.right - 40, riskColor(security_marker.risk), security_marker.label);
        }
        if (git_marker) |git_marker_value| {
            drawTextRight(hdc, layout.sidebar.right - 34, y + 3, layout.sidebar.right - 12, gitChangeColor(git_marker_value.status), git_marker_value.label);
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

const RiskMarker = struct {
    label: []const u8,
    risk: findings_mod.Risk,
};

fn riskMarkerForEntry(state: *const GuiState, entry_path: []const u8, is_directory: bool) ?RiskMarker {
    var best: ?findings_mod.Risk = null;
    for (state.app.security_findings.items.items) |item| {
        const matches = if (is_directory)
            pathIsInsideDirectory(item.path, entry_path)
        else
            pathMatches(entry_path, item.path);
        if (!matches) continue;
        if (best == null or riskRank(item.risk) > riskRank(best.?)) best = item.risk;
    }

    const risk = best orelse return null;
    return .{ .label = riskMarkerLabel(risk), .risk = risk };
}

fn riskMarkerLabel(risk: findings_mod.Risk) []const u8 {
    return switch (risk) {
        .critical => "C!",
        .high => "H!",
        .medium => "M!",
        .low => "L",
        .info => "i",
    };
}

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

        const selection = state.selectedRange(doc);
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
            if (current_line and !marker.active_execution) {
                fillRect(hdc, RECT{ .left = editor.left + GUTTER_WIDTH, .top = y - 2, .right = editor.right, .bottom = y + ROW_HEIGHT - 2 }, rgb(20, 27, 34));
            }
            if (marker.breakpoint_verified) |verified| {
                fillRect(hdc, RECT{
                    .left = editor.left + 5,
                    .top = y + 3,
                    .right = editor.left + 13,
                    .bottom = y + 11,
                }, breakpointMarkerColor(marker, verified));
            }
            drawSearchHighlightsForLine(hdc, state, editor, doc, line, y);
            if (selection) |range| {
                drawSelectionForLine(hdc, editor, doc, line, range, y);
            }
            drawTextRight(hdc, editor.left + 10, y, editor.left + GUTTER_WIDTH - 12, rgb(105, 116, 128), number);
            const line_text = doc.text.lineSlice(line);
            drawHighlightedLine(
                hdc,
                state,
                doc.language,
                editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X,
                y,
                editor.right - 20,
                line_text,
            );
            if (current_line) {
                drawCurrentLineLens(hdc, state, editor, doc, line, line_text, y);
            }
            if (current_line) {
                const caret_x = editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X + @as(c_int, @intCast(doc.cursor.position.column)) * CHAR_WIDTH;
                fillRect(hdc, RECT{ .left = caret_x, .top = y - 2, .right = caret_x + 2, .bottom = y + ROW_HEIGHT - 4 }, rgb(255, 255, 255));
            }
            drawSecondaryCaretsForLine(hdc, state, editor, doc, line, y);
            y += ROW_HEIGHT;
        }
    } else {
        drawText(hdc, editor.left + 22, HEADER_HEIGHT + 10, rgb(199, 206, 214), "Click a file to open it.");
        drawText(hdc, editor.left + 22, HEADER_HEIGHT + 38, rgb(126, 138, 150), "F1 opens commands. Ctrl+S saves. Ctrl+Shift+S saves all.");
    }
}

fn drawSecondaryCaretsForLine(
    hdc: windows.HDC,
    state: *const GuiState,
    editor: RECT,
    doc: *const document_mod.Document,
    line: usize,
    y: c_int,
) void {
    for (state.secondary_cursors.items) |offset| {
        const position = doc.positionFromOffset(@min(offset, doc.text.bytes.len)) catch continue;
        if (position.line != line) continue;
        const caret_x = editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X + @as(c_int, @intCast(position.column)) * CHAR_WIDTH;
        if (caret_x >= editor.right - 4) continue;
        fillRect(hdc, .{ .left = caret_x, .top = y - 2, .right = caret_x + 2, .bottom = y + ROW_HEIGHT - 4 }, rgb(79, 230, 226));
    }
}

fn drawSearchHighlightsForLine(
    hdc: windows.HDC,
    state: *const GuiState,
    editor: RECT,
    doc: *const document_mod.Document,
    line: usize,
    y: c_int,
) void {
    if (!state.quick_panel.visible or !isDocumentSearchMode(state.quick_panel.mode)) return;
    const items = state.quick_panel.document_matches orelse return;
    const line_start = doc.text.lineStart(line) orelse return;
    const line_end = line_start + doc.text.lineSlice(line).len;
    for (items) |item| {
        if (item.end_offset <= line_start or item.byte_offset > line_end) continue;
        const start_col = if (item.byte_offset <= line_start) 0 else item.byte_offset - line_start;
        var end_col = if (item.end_offset <= line_end) item.end_offset - line_start else line_end - line_start;
        if (end_col <= start_col) end_col = start_col + 1;
        const x = editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X + @as(c_int, @intCast(start_col)) * CHAR_WIDTH;
        const right = @min(editor.right - 20, x + @as(c_int, @intCast(end_col - start_col)) * CHAR_WIDTH);
        if (right <= x) continue;
        fillRect(hdc, .{ .left = x, .top = y - 2, .right = right, .bottom = y + ROW_HEIGHT - 4 }, rgb(70, 57, 28));
    }
}

fn drawSelectionForLine(
    hdc: windows.HDC,
    editor: RECT,
    doc: *const document_mod.Document,
    line: usize,
    range: SelectionRange,
    y: c_int,
) void {
    const line_start = doc.text.lineStart(line) orelse return;
    const line_text = doc.text.lineSlice(line);
    const line_end = line_start + line_text.len;
    if (range.end <= line_start or range.start > line_end) return;

    const start_col = if (range.start <= line_start) 0 else range.start - line_start;
    var end_col = if (range.end <= line_end) range.end - line_start else line_text.len + 1;
    if (end_col <= start_col) end_col = start_col + 1;

    const x = editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X + @as(c_int, @intCast(start_col)) * CHAR_WIDTH;
    const right = @min(editor.right - 20, x + @as(c_int, @intCast(end_col - start_col)) * CHAR_WIDTH);
    if (right <= x) return;
    fillRect(hdc, .{ .left = x, .top = y - 2, .right = right, .bottom = y + ROW_HEIGHT - 4 }, rgb(37, 74, 105));
}

fn drawCurrentLineLens(
    hdc: windows.HDC,
    state: *GuiState,
    editor: RECT,
    doc: *const document_mod.Document,
    line: usize,
    line_text: []const u8,
    y: c_int,
) void {
    const path = doc.path orelse return;
    const line_cells = @min(displayCells(line_text), @as(usize, 220));
    const x = editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X + @as(c_int, @intCast(line_cells)) * CHAR_WIDTH + 28;
    if (x > editor.right - 190) return;

    var text_buf: [300]u8 = undefined;
    var color = rgb(149, 163, 178);
    const text = currentSecurityLensText(state, path, line, &text_buf, &color) orelse
        currentDiagnosticLensText(state, path, line, &text_buf, &color) orelse
        return;

    fillRect(hdc, RECT{ .left = x - 8, .top = y - 3, .right = editor.right - 18, .bottom = y + ROW_HEIGHT - 3 }, rgb(13, 18, 23));
    fillRect(hdc, RECT{ .left = x - 8, .top = y - 3, .right = x - 5, .bottom = y + ROW_HEIGHT - 3 }, color);
    drawTextClipped(hdc, x, y, editor.right - 24, color, text);
}

fn currentSecurityLensText(state: *GuiState, path: []const u8, line: usize, buffer: []u8, color: *windows.COLORREF) ?[]const u8 {
    var best: ?*const findings_mod.Finding = null;
    for (state.app.security_findings.items.items) |*item| {
        if (item.line != line) continue;
        if (!pathMatches(path, item.path)) continue;
        if (best == null or riskRank(item.risk) > riskRank(best.?.risk)) best = item;
    }

    const finding = best orelse return null;
    color.* = riskColor(finding.risk);
    const boundary = findings_mod.boundaryFor(finding.category);
    return std.fmt.bufPrint(buffer, "SEC {s}/{s}: {s}", .{
        @tagName(finding.risk),
        findings_mod.boundaryLabel(boundary),
        finding.message,
    }) catch "SEC";
}

fn currentDiagnosticLensText(state: *GuiState, path: []const u8, line: usize, buffer: []u8, color: *windows.COLORREF) ?[]const u8 {
    var best: ?types.Severity = null;
    var message: []const u8 = "";
    for (state.app.diagnostics.items.items) |item| {
        if (item.range.start.line != line) continue;
        if (!pathMatches(path, item.path)) continue;
        if (best == null or severityRank(item.severity) > severityRank(best.?)) {
            best = item.severity;
            message = item.message;
        }
    }

    const severity = best orelse return null;
    color.* = severityColor(severity);
    return std.fmt.bufPrint(buffer, "DIAG {s}: {s}", .{ @tagName(severity), message }) catch "DIAG";
}

fn drawEditorHeader(hdc: windows.HDC, state: *GuiState, layout: Layout) void {
    drawButton(hdc, saveButtonRect(layout), "SAVE");
    drawButton(hdc, saveAllButtonRect(layout), "ALL");
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

const BreakpointVisualKind = enum { normal, hit, condition, log };

const EditorLineMarker = struct {
    severity: ?types.Severity = null,
    risk: ?findings_mod.Risk = null,
    breakpoint_verified: ?bool = null,
    breakpoint_kind: ?BreakpointVisualKind = null,
    active_execution: bool = false,

    fn hasAny(self: EditorLineMarker) bool {
        return self.severity != null or self.risk != null or self.breakpoint_verified != null or self.active_execution;
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

    for (state.app.debug_manager.session.breakpoints.items) |breakpoint| {
        if (!breakpoint.enabled or breakpoint.line != line + 1) continue;
        if (!pathMatches(path, breakpoint.path)) continue;
        marker.breakpoint_verified = breakpoint.verified;
        marker.breakpoint_kind = breakpointVisualKind(breakpoint);
        break;
    }

    if (state.app.debug_manager.session.active_frame_id) |active_id| {
        for (state.app.debug_manager.session.stack_frames.items) |frame| {
            if (frame.id != active_id or frame.line != line + 1) continue;
            const frame_path = frame.path orelse continue;
            if (!pathMatches(path, frame_path)) continue;
            marker.active_execution = true;
            break;
        }
    }

    return marker;
}

fn markerStripeColor(marker: EditorLineMarker) windows.COLORREF {
    if (marker.active_execution) return rgb(255, 207, 92);
    if (marker.breakpoint_verified) |verified| return breakpointMarkerColor(marker, verified);
    if (marker.risk) |risk| return riskColor(risk);
    if (marker.severity) |severity| return severityColor(severity);
    return rgb(121, 133, 145);
}

fn markerBackgroundColor(marker: EditorLineMarker) windows.COLORREF {
    if (marker.active_execution) return rgb(45, 39, 22);
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
    if (marker.breakpoint_kind) |kind| return switch (kind) {
        .normal => rgb(18, 34, 29),
        .hit => rgb(38, 30, 16),
        .condition => rgb(15, 34, 34),
        .log => rgb(15, 27, 39),
    };
    return rgb(20, 27, 34);
}

fn breakpointVisualKind(breakpoint: debug_session.Breakpoint) BreakpointVisualKind {
    if (breakpoint.log_message != null) return .log;
    if (breakpoint.condition != null) return .condition;
    if (breakpoint.hit_condition != null) return .hit;
    return .normal;
}

fn breakpointMarkerColor(marker: EditorLineMarker, verified: bool) windows.COLORREF {
    if (!verified) return rgb(255, 118, 118);
    return switch (marker.breakpoint_kind orelse .normal) {
        .normal => rgb(112, 220, 154),
        .hit => rgb(255, 207, 92),
        .condition => rgb(79, 230, 226),
        .log => rgb(95, 170, 255),
    };
}

fn drawHighlightedLine(hdc: windows.HDC, state: *GuiState, mode: modes.LanguageMode, x: c_int, y: c_int, right: c_int, line: []const u8) void {
    if (right <= x) return;
    if (!modes.isHighlightable(mode)) {
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
        .debug => drawDebugPanel(hdc, state, content),
        .git => drawGitPanel(hdc, state, content),
        .extensions => drawExtensionsPanel(hdc, state, content),
        .diagnostics => drawDiagnosticsPanel(hdc, state, content),
        .security => drawSecurityPanel(hdc, state, content),
        .settings => drawSettingsPanel(hdc, state, content),
        .keybindings => drawKeybindingsPanel(hdc, state, content),
        .tutorial => drawTutorialPanel(hdc, state, content),
        .publish => drawPublishPanel(hdc, state, content),
    }
}

fn drawBottomPanelTabs(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + HEADER_HEIGHT }, rgb(12, 16, 20));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));
    drawBottomPanelTab(hdc, rect, .output, state.bottom_panel == .output, "OUTPUT");
    drawBottomPanelTab(hdc, rect, .debug, state.bottom_panel == .debug, "DEBUG");
    drawBottomPanelTab(hdc, rect, .git, state.bottom_panel == .git, "GIT");
    drawBottomPanelTab(hdc, rect, .extensions, state.bottom_panel == .extensions, "EXT");
    drawBottomPanelTab(hdc, rect, .diagnostics, state.bottom_panel == .diagnostics, "DIAG");
    drawBottomPanelTab(hdc, rect, .security, state.bottom_panel == .security, "SEC");
    drawBottomPanelTab(hdc, rect, .settings, state.bottom_panel == .settings, "SET");
    drawBottomPanelTab(hdc, rect, .keybindings, state.bottom_panel == .keybindings, "KEYS");
    drawBottomPanelTab(hdc, rect, .tutorial, state.bottom_panel == .tutorial, "HELP");
    drawBottomPanelTab(hdc, rect, .publish, state.bottom_panel == .publish, "SHIP");
}

fn drawBottomPanelTab(hdc: windows.HDC, rect: RECT, panel: BottomPanel, active: bool, label: []const u8) void {
    const tab = bottomPanelTabRect(rect, panel);
    fillRect(hdc, tab, if (active) rgb(51, 153, 235) else rgb(27, 34, 41));
    if (active) fillRect(hdc, RECT{ .left = tab.left, .top = tab.top, .right = tab.right, .bottom = tab.top + 1 }, rgb(255, 207, 92));
    drawTextClipped(hdc, tab.left + 10, tab.top + 5, tab.right - 8, if (active) rgb(16, 19, 22) else rgb(220, 226, 232), label);
}

fn drawConsoleOutput(hdc: windows.HDC, state: *GuiState, output: RECT) void {
    fillRect(hdc, RECT{ .left = output.left, .top = output.top, .right = output.right, .bottom = output.top + 1 }, rgb(43, 53, 61));
    const can_apply = state.hasCachedLspWorkspaceEdit();
    const header_right = if (can_apply) outputApplyButtonRect(output).left - 10 else output.right - 16;
    drawTextClipped(hdc, output.left + 16, output.top + 10, header_right, rgb(79, 230, 226), "OUTPUT");
    if (can_apply) {
        drawButton(hdc, outputApplyButtonRect(output), "APPLY");
        drawTextClipped(hdc, outputApplyButtonRect(output).left - 104, output.top + 10, outputApplyButtonRect(output).left - 12, rgb(116, 128, 140), "Ctrl+Enter");
    }

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

fn drawDebugPanel(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, rect, rgb(10, 12, 14));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));
    const session = &state.app.debug_manager.session;
    const advanced = advancedBreakpointCounts(session);
    var header_buf: [420]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "DEBUG  {s}  store:{s}  pending:{d}  bp:{d}", .{
        @tagName(session.state),
        debugStoreLabel(&state.app.debug_manager),
        session.pendingCount(),
        session.breakpoints.items.len,
    }) catch "DEBUG";
    const header_right = if (debugPanelHasActionButtons(rect)) debugPanelActionButtonRect(rect, .start).left - 10 else rect.right - 16;
    drawTextClipped(hdc, rect.left + 16, rect.top + 10, header_right, debugStateColor(session.state), header);
    drawDebugPanelActions(hdc, rect);

    var policy_buf: [640]u8 = undefined;
    const policy = std.fmt.bufPrint(&policy_buf, "advanced c:{d} h:{d} log:{d}  fn:{d} cap:{s} withheld:{d}  data:{d} cap:{s} withheld:{d} candidate:{s}  exc:{d}/{d} withheld:{d}  threads:{d} watch:{d}  policy env:{s} fs:{s} net:{s} reverse-launch:deny frame:8MiB", .{
        advanced.conditions,
        advanced.hit_conditions,
        advanced.logpoints,
        session.function_breakpoints.items.len,
        @tagName(session.functionBreakpointCapability()),
        session.unsupportedFunctionBreakpointCount(),
        session.data_breakpoints.items.len,
        @tagName(session.dataBreakpointCapability()),
        session.withheldDataBreakpointCount(),
        if (session.data_breakpoint_candidate != null) "staged" else "none",
        session.selectedExceptionFilterCount(),
        session.exception_filters.items.len,
        session.withheldExceptionFilterCount(),
        session.threads.items.len,
        session.watches.items.len,
        @tagName(state.app.debug_manager.env_policy),
        @tagName(state.app.debug_manager.fs_policy),
        @tagName(state.app.debug_manager.network_policy),
    }) catch "debug policy";
    drawTextClipped(hdc, rect.left + 16, rect.top + 42, rect.right - 16, rgb(116, 128, 140), policy);

    var y = rect.top + 66;
    if (state.app.debug_manager.plan) |plan| {
        var plan_buf: [900]u8 = undefined;
        const plan_line = std.fmt.bufPrint(&plan_buf, "adapter {s}  program {s}", .{ plan.adapter_argv[0], plan.program }) catch plan.program;
        drawTextClipped(hdc, rect.left + 16, y, rect.right - 16, rgb(127, 211, 255), plan_line);
        y += ROW_HEIGHT;
    } else {
        drawTextClipped(hdc, rect.left + 16, y, rect.right - 16, rgb(116, 128, 140), "No active adapter. Add .zide/debug.json or select a Python file, then press START.");
        y += ROW_HEIGHT;
    }

    var state_buf: [420]u8 = undefined;
    const state_line = std.fmt.bufPrint(&state_buf, "stop:{s}  active thread:{any} frame:{any}  stack:{d} scopes:{d} vars:{d} watches:{d}", .{
        session.stop_reason orelse "-",
        session.active_thread_id,
        session.active_frame_id,
        session.stack_frames.items.len,
        session.scopes.items.len,
        session.variables.items.len,
        session.watches.items.len,
    }) catch "debug state";
    drawTextClipped(hdc, rect.left + 16, y, rect.right - 16, rgb(255, 207, 92), state_line);
    y += ROW_HEIGHT;

    y = debugPanelRowsTop(rect);
    const left_right = rect.left + @divTrunc(rect.right - rect.left, 2) - 8;
    var row: usize = 0;
    while (row < 4 and y + @as(c_int, @intCast(row * ROW_HEIGHT)) < rect.bottom) : (row += 1) {
        const row_y = y + @as(c_int, @intCast(row * ROW_HEIGHT));
        if (row < session.stack_frames.items.len) {
            const frame = session.stack_frames.items[row];
            var frame_buf: [520]u8 = undefined;
            const text = std.fmt.bufPrint(&frame_buf, "{s} #{d} {s}  {s}:{d}", .{
                if (session.active_frame_id == frame.id) ">" else " ",
                frame.id,
                frame.name,
                frame.path orelse "(no source)",
                frame.line,
            }) catch frame.name;
            drawTextClipped(hdc, rect.left + 16, row_y, left_right, if (session.active_frame_id == frame.id) rgb(255, 207, 92) else rgb(200, 207, 216), text);
        }
        const visible_watches = @min(session.watches.items.len, @as(usize, 2));
        if (row < visible_watches) {
            const watch = session.watches.items[row];
            var watch_buf: [720]u8 = undefined;
            const display_value = watch.result orelse watch.error_message orelse if (watch.pending_seq != null) "(pending)" else "(not evaluated)";
            const text = std.fmt.bufPrint(&watch_buf, "WATCH {d}  {s} = {s}  ({s})", .{
                row + 1,
                watch.expression,
                display_value,
                watch.type_name orelse "?",
            }) catch watch.expression;
            const color = if (watch.error_message != null)
                rgb(255, 118, 118)
            else if (watch.pending_seq != null)
                rgb(127, 211, 255)
            else
                rgb(165, 214, 167);
            drawTextClipped(hdc, left_right + 16, row_y, rect.right - 16, color, text);
        } else if (row - visible_watches < session.variables.items.len) {
            const variable = session.variables.items[row - visible_watches];
            var variable_buf: [520]u8 = undefined;
            const text = std.fmt.bufPrint(&variable_buf, "{s} {s}: {s}  ({s})", .{
                if (variable.variables_reference > 0) "+" else " ",
                variable.name,
                variable.value,
                variable.type_name orelse "?",
            }) catch variable.name;
            drawTextClipped(hdc, left_right + 16, row_y, rect.right - 16, rgb(165, 214, 167), text);
        }
    }
}

const AdvancedBreakpointCounts = struct {
    conditions: usize = 0,
    hit_conditions: usize = 0,
    logpoints: usize = 0,
};

fn advancedBreakpointCounts(session: *const debug_session.Session) AdvancedBreakpointCounts {
    var counts: AdvancedBreakpointCounts = .{};
    for (session.breakpoints.items) |breakpoint| {
        if (breakpoint.condition != null) counts.conditions += 1;
        if (breakpoint.hit_condition != null) counts.hit_conditions += 1;
        if (breakpoint.log_message != null) counts.logpoints += 1;
    }
    return counts;
}

fn debugStateColor(state: @import("../debug/session.zig").DebugState) windows.COLORREF {
    return switch (state) {
        .paused => rgb(255, 207, 92),
        .running, .launching, .configuring, .initializing => rgb(79, 230, 226),
        .failed => rgb(255, 118, 118),
        else => rgb(127, 211, 255),
    };
}

fn debugStoreLabel(manager: *const @import("../debug/manager.zig").Manager) []const u8 {
    if (manager.state_save_error != null) return "save-error";
    if (manager.state_dirty) return "dirty";
    if (manager.state_load_error != null) return "load-error";
    if (manager.state_save_report.bytes_written > 0 or manager.state_load_report.found) return "saved";
    return "new";
}

fn debugPanelRowsTop(rect: RECT) c_int {
    return rect.top + 66 + ROW_HEIGHT * 2;
}

fn debugPanelStackRowAt(rect: RECT, x: c_int, y: c_int) ?usize {
    const split = rect.left + @divTrunc(rect.right - rect.left, 2) - 8;
    if (x < rect.left + 8 or x >= split) return null;
    return debugPanelDataRowAt(rect, y);
}

fn debugPanelVariableRowAt(rect: RECT, x: c_int, y: c_int) ?usize {
    const split = rect.left + @divTrunc(rect.right - rect.left, 2) - 8;
    if (x < split or x >= rect.right - 8) return null;
    return debugPanelDataRowAt(rect, y);
}

fn debugPanelDataRowAt(rect: RECT, y: c_int) ?usize {
    const top = debugPanelRowsTop(rect) - 3;
    if (y < top or y >= top + ROW_HEIGHT * 4) return null;
    return @intCast(@divTrunc(y - top, ROW_HEIGHT));
}

fn drawDebugPanelActions(hdc: windows.HDC, rect: RECT) void {
    if (!debugPanelHasActionButtons(rect)) return;
    const actions = [_]DebugPanelAction{ .configure, .start, .continue_execution, .pause, .step_over, .step_into, .step_out, .watch, .low_level, .advanced_breakpoint, .breakpoint, .stop, .status };
    for (actions) |action| drawButton(hdc, debugPanelActionButtonRect(rect, action), debugPanelActionLabel(action));
}

fn debugPanelActionAt(rect: RECT, x: c_int, y: c_int) ?DebugPanelAction {
    if (!debugPanelHasActionButtons(rect) or y < rect.top or y >= rect.top + HEADER_HEIGHT) return null;
    const actions = [_]DebugPanelAction{ .configure, .start, .continue_execution, .pause, .step_over, .step_into, .step_out, .watch, .low_level, .advanced_breakpoint, .breakpoint, .stop, .status };
    for (actions) |action| if (pointIn(debugPanelActionButtonRect(rect, action), x, y)) return action;
    return null;
}

fn debugPanelHasActionButtons(rect: RECT) bool {
    return rect.right - rect.left >= 888;
}

fn debugPanelActionButtonRect(rect: RECT, action: DebugPanelAction) RECT {
    const width: c_int = 58;
    const gap: c_int = 6;
    const slot: c_int = switch (action) {
        .status => 0,
        .stop => 1,
        .breakpoint => 2,
        .advanced_breakpoint => 3,
        .low_level => 4,
        .watch => 5,
        .step_out => 6,
        .step_into => 7,
        .step_over => 8,
        .pause => 9,
        .continue_execution => 10,
        .start => 11,
        .configure => 12,
    };
    const right = rect.right - 12 - slot * (width + gap);
    return .{ .left = right - width, .top = rect.top + 7, .right = right, .bottom = rect.top + 31 };
}

fn debugPanelActionLabel(action: DebugPanelAction) []const u8 {
    return switch (action) {
        .configure => "CFG",
        .start => "START",
        .continue_execution => "CONT",
        .pause => "PAUSE",
        .step_over => "OVER",
        .step_into => "INTO",
        .step_out => "OUT",
        .breakpoint => "BP",
        .advanced_breakpoint => "ADV",
        .low_level => "ASM",
        .watch => "WATCH",
        .stop => "STOP",
        .status => "INFO",
    };
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

    const workflow_risk = workflowRiskCounts(state, overview);
    const snapshot = state.app.source_control_snapshot;
    const branch = if (snapshot) |value| value.branch orelse overview.branch orelse "(detached)" else overview.branch orelse "(detached)";
    const staged_count = if (snapshot) |value| value.stagedCount() else overview.staged_changes.len;
    const change_count = if (snapshot) |value| value.unstagedCount() else overview.changes.len;
    const upstream = if (snapshot) |value| value.upstream orelse "unpublished" else "not refreshed";
    const ahead = if (snapshot) |value| value.ahead else 0;
    const behind = if (snapshot) |value| value.behind else 0;
    const github_auth = githubTokenPresenceLabel(state.app.environ);
    var header_buf: [640]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "SOURCE CONTROL  {s} -> {s}  up:{d} down:{d}  staged:{d} changes:{d}  api:{s}  wf-risk:{d}/{d}/{d}",
        .{
            branch,
            upstream,
            ahead,
            behind,
            staged_count,
            change_count,
            github_auth,
            workflow_risk.critical,
            workflow_risk.high,
            workflow_risk.medium,
        },
    ) catch "GIT";
    const header_right = if (gitPanelHasActionButtons(rect)) gitPanelActionButtonRect(rect, .refresh).left - 12 else rect.right - 16;
    drawTextClipped(hdc, rect.left + 16, rect.top + 10, header_right, rgb(79, 230, 226), header);
    drawGitPanelActions(hdc, state, rect);

    const rows = @max(0, @divTrunc(rect.bottom - rect.top - HEADER_HEIGHT, ROW_HEIGHT));
    const total_rows = gitPanelRowCount(overview);
    const start = @min(state.git_scroll_line, if (total_rows > @as(usize, @intCast(rows))) total_rows - @as(usize, @intCast(rows)) else 0);
    var y = rect.top + HEADER_HEIGHT;
    var row: usize = 0;
    while (row < @as(usize, @intCast(rows)) and start + row < total_rows) : (row += 1) {
        drawGitPanelRow(hdc, state, rect, overview, start + row, y);
        y += ROW_HEIGHT;
    }
}

fn drawGitPanelRow(hdc: windows.HDC, state: *GuiState, rect: RECT, overview: git_repository.Overview, row: usize, y: c_int) void {
    if (row == 0) {
        if (overview.commit) |commit| {
            drawTextClipped(hdc, rect.left + 16, y, rect.right - 16, rgb(180, 190, 200), commit);
        } else {
            drawText(hdc, rect.left + 16, y, rgb(116, 128, 140), "No commit resolved");
        }
        return;
    }

    if (row == 1) {
        drawGitHubScmSummary(hdc, state, rect, y);
        return;
    }

    var current: usize = 2;
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
            const counts = pathRiskCounts(state, path);
            const worst = highestRisk(counts);
            const color = if (worst) |risk| riskColor(risk) else rgb(127, 211, 255);
            var risk_buf: [64]u8 = undefined;
            const risk_label = if (worst != null)
                std.fmt.bufPrint(&risk_buf, "risk {d}/{d}/{d}", .{ counts.critical, counts.high, counts.medium }) catch "risk"
            else
                "clear";
            drawTextClipped(hdc, rect.left + 34, y, rect.right - 132, color, path);
            drawTextRight(hdc, rect.right - 124, y, rect.right - 16, color, risk_label);
            return;
        }
        current += 1;
    }

    if (row == current) {
        var staged_buf: [96]u8 = undefined;
        const text = if (overview.staged_scan_available)
            std.fmt.bufPrint(&staged_buf, "STAGED CHANGES  {d}", .{overview.staged_changes.len}) catch "STAGED CHANGES"
        else
            "STAGED CHANGES  unavailable (packed HEAD)";
        drawText(hdc, rect.left + 16, y, if (overview.staged_changes.len > 0) rgb(102, 220, 150) else rgb(116, 128, 140), text);
        return;
    }
    current += 1;

    if (row < current + overview.staged_changes.len) {
        drawGitScmChangeRow(hdc, state, rect, overview.staged_changes[row - current], .staged, row - current, y);
        return;
    }
    current += overview.staged_changes.len;

    if (row == current) {
        if (overview.changes.len == 0 and overview.staged_changes.len == 0) {
            drawText(hdc, rect.left + 16, y, rgb(116, 128, 140), "No changes");
        } else {
            var changes_buf: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&changes_buf, "CHANGES  {d}", .{overview.changes.len}) catch "CHANGES";
            drawText(hdc, rect.left + 16, y, if (overview.changes.len > 0) rgb(255, 207, 92) else rgb(116, 128, 140), text);
        }
        return;
    }
    current += 1;

    const change_index = row - current;
    if (change_index >= overview.changes.len) return;
    drawGitScmChangeRow(hdc, state, rect, overview.changes[change_index], .unstaged, change_index, y);
}

fn drawGitHubScmSummary(hdc: windows.HDC, state: *const GuiState, rect: RECT, y: c_int) void {
    var summary_buf: [720]u8 = undefined;
    const summary = state.app.github_state.formatScmSummary(summary_buf[0..]);
    const color = if (state.app.github_state.hasFailure())
        rgb(255, 115, 124)
    else if (state.app.github_state.live != null)
        rgb(127, 211, 255)
    else
        rgb(116, 128, 140);
    drawTextClipped(hdc, rect.left + 16, y, rect.right - 72, color, summary);
    if (state.app.github_state.primaryUrl() != null) {
        drawTextRight(hdc, rect.right - 64, y, rect.right - 16, color, "OPEN");
    }
}

fn drawGitScmChangeRow(
    hdc: windows.HDC,
    state: *GuiState,
    rect: RECT,
    change: git_repository.Change,
    lane: GitChangeLane,
    index: usize,
    y: c_int,
) void {
    const selected = if (state.git_selection) |selection|
        selection.index == index and selection.group == (if (lane == .staged) GitChangeGroup.staged else GitChangeGroup.unstaged)
    else
        false;
    if (selected) {
        fillRect(hdc, .{ .left = rect.left + 8, .top = y - 2, .right = rect.right - 8, .bottom = y + ROW_HEIGHT - 2 }, rgb(28, 43, 50));
    }
    const counts = pathRiskCounts(state, change.path);
    const worst = highestRisk(counts);
    const color = if (worst) |risk| riskColor(risk) else gitChangeColor(change.status);
    drawText(hdc, rect.left + 16, y, color, gitChangeLabel(change.status));
    var stats_buf: [48]u8 = undefined;
    const stats = if (change.diff_available and worst != null)
        std.fmt.bufPrint(&stats_buf, "+{d} -{d} r{d}/{d}/{d}", .{ change.additions, change.deletions, counts.critical, counts.high, counts.medium }) catch ""
    else if (change.diff_available)
        std.fmt.bufPrint(&stats_buf, "+{d} -{d}", .{ change.additions, change.deletions }) catch ""
    else if (worst != null)
        std.fmt.bufPrint(&stats_buf, "r{d}/{d}/{d}", .{ counts.critical, counts.high, counts.medium }) catch "risk"
    else
        "diff n/a";
    drawTextClipped(hdc, rect.left + 52, y, rect.right - 226, color, change.path);
    drawTextRight(hdc, rect.right - 218, y, rect.right - 62, color, stats);
    drawButton(hdc, .{
        .left = rect.right - 50,
        .top = y - 3,
        .right = rect.right - 14,
        .bottom = y + ROW_HEIGHT - 3,
    }, if (lane == .staged) "-" else "+");
}

fn gitPanelRowCount(overview: git_repository.Overview) usize {
    var count: usize = 2;
    for (overview.remotes) |remote| {
        count += 1;
        if (remote.github != null) count += 2;
    }
    count += 1 + overview.workflow_paths.len;
    count += 1 + overview.staged_changes.len;
    count += 1 + overview.changes.len;
    return count;
}

fn gitPanelWorkflowStartRow(overview: git_repository.Overview) usize {
    var row: usize = 3;
    for (overview.remotes) |remote| {
        row += 1;
        if (remote.github != null) row += 2;
    }
    return row;
}

fn gitPanelStagedStartRow(overview: git_repository.Overview) usize {
    return gitPanelWorkflowStartRow(overview) + overview.workflow_paths.len + 1;
}

fn gitPanelChangeStartRow(overview: git_repository.Overview) usize {
    return gitPanelStagedStartRow(overview) + overview.staged_changes.len + 1;
}

fn gitPanelChangeTargetAtRow(overview: *const git_repository.Overview, row: usize) ?GitPanelChangeTarget {
    const staged_start = gitPanelStagedStartRow(overview.*);
    if (row >= staged_start and row < staged_start + overview.staged_changes.len) {
        const index = row - staged_start;
        return .{
            .lane = .staged,
            .index = index,
            .change = overview.staged_changes[index],
        };
    }

    const change_start = gitPanelChangeStartRow(overview.*);
    if (row >= change_start and row < change_start + overview.changes.len) {
        const index = row - change_start;
        return .{
            .lane = .unstaged,
            .index = index,
            .change = overview.changes[index],
        };
    }
    return null;
}

fn gitPanelUrlAtRow(state: *const GuiState, overview: git_repository.Overview, row: usize) ?[]const u8 {
    if (row == 1) return state.app.github_state.primaryUrl();

    var current: usize = 2;
    for (overview.remotes) |remote| {
        current += 1;
        if (remote.github) |github| {
            if (row == current) return github.web_url;
            current += 1;
            if (row == current) return github.actions_url;
            current += 1;
        }
    }
    return null;
}

const git_panel_compact_actions = [_]GitPanelAction{
    .refresh,
    .branch_switch,
    .stage_all,
    .unstage_all,
    .commit,
    .pull,
    .push,
    .sync,
    .draft_pr,
};

const git_panel_full_actions = [_]GitPanelAction{
    .refresh,
    .branch_switch,
    .branch_create,
    .stage_all,
    .unstage_all,
    .commit,
    .fetch,
    .pull,
    .push,
    .sync,
    .live,
    .issues,
    .failures,
    .draft_pr,
};

fn gitPanelActions(rect: RECT) []const GitPanelAction {
    return if (rect.right - rect.left >= 1060)
        git_panel_full_actions[0..]
    else
        git_panel_compact_actions[0..];
}

fn drawGitPanelActions(hdc: windows.HDC, state: *const GuiState, rect: RECT) void {
    if (!gitPanelHasActionButtons(rect)) return;
    for (gitPanelActions(rect)) |action| {
        const label = if (action == .push and state.gitBranchNeedsPublish()) "PUB" else gitPanelActionLabel(action);
        drawButton(hdc, gitPanelActionButtonRect(rect, action), label);
    }
}

fn gitPanelActionAt(rect: RECT, x: c_int, y: c_int) ?GitPanelAction {
    if (!gitPanelHasActionButtons(rect)) return null;
    if (y < rect.top or y >= rect.top + HEADER_HEIGHT) return null;
    for (gitPanelActions(rect)) |action| {
        if (pointIn(gitPanelActionButtonRect(rect, action), x, y)) return action;
    }
    return null;
}

fn gitPanelHasActionButtons(rect: RECT) bool {
    return rect.right - rect.left >= 700;
}

fn gitPanelActionButtonRect(rect: RECT, action: GitPanelAction) RECT {
    const width: c_int = 43;
    const gap: c_int = 4;
    const actions = gitPanelActions(rect);
    var index: usize = 0;
    for (actions, 0..) |candidate, candidate_index| {
        if (candidate == action) {
            index = candidate_index;
            break;
        }
    }
    const slot: c_int = @intCast(actions.len - 1 - index);
    const right = rect.right - 12 - slot * (width + gap);
    return .{
        .left = right - width,
        .top = rect.top + 8,
        .right = right,
        .bottom = rect.top + 32,
    };
}

fn gitPanelActionLabel(action: GitPanelAction) []const u8 {
    return switch (action) {
        .refresh => "REF",
        .status => "STAT",
        .diff => "DIFF",
        .stage_all => "+ALL",
        .unstage_all => "-ALL",
        .commit => "COMMIT",
        .branch_switch => "BR",
        .branch_create => "NEW",
        .fetch => "FETCH",
        .pull => "PULL",
        .push => "PUSH",
        .publish => "PUB",
        .sync => "SYNC",
        .live => "LIVE",
        .issues => "ISS",
        .failures => "FAIL",
        .draft_pr => "PR",
    };
}

fn gitPanelActionCommand(action: GitPanelAction) []const u8 {
    return switch (action) {
        .refresh => "git.overview",
        .status => "git.status",
        .diff => "git.diff_current",
        .stage_all => "git.stage_all",
        .unstage_all => "git.unstage_all",
        .commit => "git.commit",
        .branch_switch => "git.branch.switch",
        .branch_create => "git.branch.create",
        .fetch => "git.fetch",
        .pull => "git.pull",
        .push => "git.push",
        .publish => "git.publish_branch",
        .sync => "git.sync",
        .live => "github.fetch",
        .issues => "github.issues",
        .failures => "github.actions.failures",
        .draft_pr => "github.pr.create_draft",
    };
}

fn githubTokenPresenceLabel(environ: std.process.Environ) []const u8 {
    if (environ.containsUnemptyConstant("GITHUB_TOKEN")) return "GITHUB_TOKEN";
    if (environ.containsUnemptyConstant("GH_TOKEN")) return "GH_TOKEN";
    return "none";
}

fn gitChangeLabel(status: git_repository.ChangeStatus) []const u8 {
    return switch (status) {
        .added => "A ",
        .modified => "M ",
        .deleted => "D ",
        .untracked => "??",
    };
}

fn gitChangeColor(status: git_repository.ChangeStatus) windows.COLORREF {
    return switch (status) {
        .added => rgb(102, 220, 150),
        .modified => rgb(255, 207, 92),
        .deleted => rgb(255, 118, 118),
        .untracked => rgb(127, 211, 255),
    };
}

fn drawExtensionsPanel(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, rect, rgb(10, 12, 14));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));

    const registry = state.extensions_registry orelse {
        drawText(hdc, rect.left + 16, rect.top + 10, rgb(79, 230, 226), "EXTENSIONS");
        drawExtensionPanelActions(hdc, rect);
        drawText(hdc, rect.left + 16, rect.top + HEADER_HEIGHT, rgb(116, 128, 140), "Click EXT or press Ctrl+Shift+X to scan extension manifests");
        return;
    };

    var header_buf: [260]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "EXTENSIONS  manifests:{d} loaded:{d} invalid:{d} high:{d} medium:{d}",
        .{
            registry.items.items.len,
            registry.countStatus(.loaded),
            registry.countStatus(.invalid),
            registry.countRisk(.high),
            registry.countRisk(.medium),
        },
    ) catch "EXTENSIONS";
    const header_right = if (extensionPanelHasActionButtons(rect)) extensionPanelActionButtonRect(rect, .scan).left - 12 else rect.right - 16;
    drawTextClipped(hdc, rect.left + 16, rect.top + 10, header_right, rgb(79, 230, 226), header);
    drawExtensionPanelActions(hdc, rect);

    const rows = @max(0, @divTrunc(rect.bottom - rect.top - HEADER_HEIGHT, ROW_HEIGHT));
    const total = registry.items.items.len;
    const start = @min(state.extensions_scroll_line, if (total > @as(usize, @intCast(rows))) total - @as(usize, @intCast(rows)) else 0);
    var y = rect.top + HEADER_HEIGHT;
    var row: usize = 0;
    while (row < @as(usize, @intCast(rows)) and start + row < total) : (row += 1) {
        drawExtensionPanelRow(hdc, rect, registry.items.items[start + row], y);
        y += ROW_HEIGHT;
    }

    if (total == 0) {
        drawText(hdc, rect.left + 16, rect.top + HEADER_HEIGHT, rgb(116, 128, 140), "No zide-extension.json or zide.extension.json manifests found");
    }
}

fn drawExtensionPanelRow(hdc: windows.HDC, rect: RECT, extension: extension_registry.Extension, y: c_int) void {
    const risk = extension_registry.extensionRisk(extension);
    const color = extensionRiskColor(risk);
    var left_buf: [420]u8 = undefined;
    const left = std.fmt.bufPrint(&left_buf, "[{s}/{s}] {s} {s}", .{
        @tagName(extension.status),
        extension_registry.riskLabel(risk),
        extension.name,
        extension.version,
    }) catch extension.name;

    var right_buf: [240]u8 = undefined;
    const right = std.fmt.bufPrint(&right_buf, "cmd:{d} int:{d} {s}", .{ extension.commands, extension.integrations, extension.manifest_path }) catch extension.manifest_path;
    var capability_buf: [240]u8 = undefined;
    const capabilities = extensionCapabilitiesLabel(&capability_buf, extension);

    drawTextClipped(hdc, rect.left + 16, y, rect.left + 430, color, left);
    drawTextClipped(hdc, rect.left + 440, y, rect.right - 210, rgb(180, 190, 200), capabilities);
    drawTextRight(hdc, rect.right - 204, y, rect.right - 16, rgb(127, 211, 255), right);
}

fn extensionCapabilitiesLabel(buffer: []u8, extension: extension_registry.Extension) []const u8 {
    if (extension.capabilities.len == 0) return "cap:none";
    var len: usize = 0;
    appendBounded(buffer, &len, "cap:");
    for (extension.capabilities, 0..) |capability, index| {
        if (index >= 5) {
            appendBounded(buffer, &len, " ...");
            break;
        }
        if (index > 0) appendBounded(buffer, &len, ",");
        appendBounded(buffer, &len, extension_registry.capabilityLabel(capability));
    }
    return buffer[0..len];
}

fn appendBounded(buffer: []u8, len: *usize, text: []const u8) void {
    if (len.* >= buffer.len) return;
    const available = buffer.len - len.*;
    const copy_len = @min(available, text.len);
    if (copy_len == 0) return;
    @memcpy(buffer[len.* .. len.* + copy_len], text[0..copy_len]);
    len.* += copy_len;
}

fn extensionRiskColor(risk: extension_registry.Risk) windows.COLORREF {
    return switch (risk) {
        .high => rgb(255, 118, 118),
        .medium => rgb(255, 207, 92),
        .low => rgb(165, 214, 167),
    };
}

fn drawExtensionPanelActions(hdc: windows.HDC, rect: RECT) void {
    if (!extensionPanelHasActionButtons(rect)) return;
    drawButton(hdc, extensionPanelActionButtonRect(rect, .scan), "SCAN");
}

fn extensionPanelActionAt(rect: RECT, x: c_int, y: c_int) ?ExtensionPanelAction {
    if (!extensionPanelHasActionButtons(rect)) return null;
    if (y < rect.top or y >= rect.top + HEADER_HEIGHT) return null;
    if (pointIn(extensionPanelActionButtonRect(rect, .scan), x, y)) return .scan;
    return null;
}

fn extensionPanelHasActionButtons(rect: RECT) bool {
    return rect.right - rect.left >= 220;
}

fn extensionPanelActionButtonRect(rect: RECT, action: ExtensionPanelAction) RECT {
    _ = action;
    return .{
        .left = rect.right - 78,
        .top = rect.top + 8,
        .right = rect.right - 12,
        .bottom = rect.top + 32,
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
    const header_right = if (securityPanelHasActionButtons(rect)) rect.right - 460 else rect.right - 16;
    drawTextClipped(hdc, rect.left + 16, rect.top + 10, header_right, rgb(79, 230, 226), header);
    drawSecurityPanelActions(hdc, rect);

    drawBoundaryStrip(hdc, state, RECT{ .left = rect.left, .top = rect.top + HEADER_HEIGHT, .right = rect.right, .bottom = rect.top + HEADER_HEIGHT + ROW_HEIGHT });

    const rows = @max(0, @divTrunc(rect.bottom - rect.top - HEADER_HEIGHT - ROW_HEIGHT, ROW_HEIGHT));
    const start = @min(state.security_scroll_line, if (state.app.security_findings.items.items.len > @as(usize, @intCast(rows))) state.app.security_findings.items.items.len - @as(usize, @intCast(rows)) else 0);
    var y = rect.top + HEADER_HEIGHT + ROW_HEIGHT;
    var row: usize = 0;
    while (row < @as(usize, @intCast(rows)) and start + row < state.app.security_findings.items.items.len) : (row += 1) {
        const item = state.app.security_findings.items.items[start + row];
        const color = riskColor(item.risk);
        const boundary = findings_mod.boundaryFor(item.category);
        var location_buf: [420]u8 = undefined;
        const location = std.fmt.bufPrint(&location_buf, "{s}:{d}:{d} [{s}/{s}/{s}]", .{
            item.path,
            item.line + 1,
            item.column + 1,
            @tagName(item.risk),
            findings_mod.boundaryLabel(boundary),
            @tagName(item.category),
        }) catch item.path;
        drawTextClipped(hdc, rect.left + 16, y, rect.left + 470, color, location);
        drawTextClipped(hdc, rect.left + 480, y, rect.right - 16, rgb(210, 218, 226), item.message);
        y += ROW_HEIGHT;
    }

    if (state.app.security_findings.items.items.len == 0) {
        drawText(hdc, rect.left + 16, rect.top + HEADER_HEIGHT + ROW_HEIGHT, rgb(116, 128, 140), "No security findings");
    }
}

fn drawBoundaryStrip(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, rect, rgb(13, 18, 22));
    const counts = boundaryCounts(&state.app.security_findings);
    var buffer: [320]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buffer,
        "BOUNDARY  mem:{d} exec:{d} fs:{d} net:{d} deps:{d} secret:{d} text:{d} path:{d} git:{d}",
        .{
            counts.memory,
            counts.execution,
            counts.filesystem,
            counts.network,
            counts.dependency,
            counts.secret,
            counts.text,
            counts.path,
            counts.git,
        },
    ) catch "BOUNDARY";
    drawTextClipped(hdc, rect.left + 16, rect.top + 3, rect.right - 16, rgb(180, 190, 200), text);
}

fn drawSettingsPanel(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, rect, rgb(10, 12, 14));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));

    var header_buf: [320]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "SETTINGS  tree:{s}  panel:{s}  tutorial:{s}  trust:{s}", .{
        if (state.show_file_tree) "shown" else "hidden",
        if (state.show_output) "shown" else "hidden",
        @tagName(state.tutorial_language),
        @tagName(state.app.runtime.trust_state),
    }) catch "SETTINGS";
    drawTextClipped(hdc, rect.left + 16, rect.top + 10, rect.right - 16, rgb(79, 230, 226), header);

    const actions = [_]SettingsPanelAction{ .toggle_file_tree, .toggle_output, .tutorial_ja, .tutorial_en };
    for (actions) |action| {
        drawButton(hdc, settingsPanelActionButtonRect(rect, action), settingsPanelActionLabel(state, action));
    }

    drawTextClipped(hdc, rect.left + 16, rect.top + 82, rect.right - 16, rgb(180, 190, 200), "Workspace trust is never persisted here; execution permission must be earned again from the audited workspace.");
}

fn drawKeybindingsPanel(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, rect, rgb(10, 12, 14));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));

    const definitions = command_mod.all();
    var header_buf: [120]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "KEYBOARD SHORTCUTS  {d} commands", .{definitions.len}) catch "KEYBOARD SHORTCUTS";
    drawTextClipped(hdc, rect.left + 16, rect.top + 10, rect.right - 16, rgb(79, 230, 226), header);

    const visible = bottomPanelVisibleRows(rect);
    const start = @min(state.keybindings_scroll_line, if (definitions.len > visible) definitions.len - visible else 0);
    const content_left = rect.left + 16;
    const content_right = @max(content_left + 4, rect.right - 16);
    const content_width = content_right - content_left;
    const title_right = content_left + @divTrunc(content_width * 35, 100);
    const id_right = content_left + @divTrunc(content_width * 65, 100);
    const key_right = content_left + @divTrunc(content_width * 84, 100);
    var row: usize = 0;
    var y = rect.top + HEADER_HEIGHT;
    while (row < visible and start + row < definitions.len) : (row += 1) {
        const definition = definitions[start + row];
        drawTextClipped(hdc, content_left, y, title_right - 6, rgb(220, 226, 232), definition.title);
        drawTextClipped(hdc, title_right, y, id_right - 6, rgb(145, 158, 170), definition.id);
        drawTextClipped(hdc, id_right, y, key_right - 6, rgb(255, 207, 92), if (definition.default_key.len == 0) "unbound" else definition.default_key);
        drawTextClipped(hdc, key_right, y, content_right, commandCapabilityColor(definition.capability), commandCapabilityLabel(definition.capability));
        y += ROW_HEIGHT;
    }
}

fn settingsPanelActionButtonRect(rect: RECT, action: SettingsPanelAction) RECT {
    const index: c_int = switch (action) {
        .toggle_file_tree => 0,
        .toggle_output => 1,
        .tutorial_ja => 2,
        .tutorial_en => 3,
    };
    const action_count: c_int = 4;
    const gap: c_int = 8;
    const available = @max(rect.right - rect.left - 32 - gap * (action_count - 1), action_count);
    const width: c_int = @max(1, @min(142, @divTrunc(available, action_count)));
    const left = rect.left + 16 + index * (width + gap);
    return .{ .left = left, .top = rect.top + 42, .right = left + width, .bottom = rect.top + 68 };
}

fn settingsPanelActionAt(rect: RECT, x: c_int, y: c_int) ?SettingsPanelAction {
    const actions = [_]SettingsPanelAction{ .toggle_file_tree, .toggle_output, .tutorial_ja, .tutorial_en };
    for (actions) |action| {
        if (pointIn(settingsPanelActionButtonRect(rect, action), x, y)) return action;
    }
    return null;
}

fn settingsPanelActionLabel(state: *const GuiState, action: SettingsPanelAction) []const u8 {
    return switch (action) {
        .toggle_file_tree => if (state.show_file_tree) "HIDE TREE" else "SHOW TREE",
        .toggle_output => if (state.show_output) "HIDE PANEL" else "SHOW PANEL",
        .tutorial_ja => "TUTORIAL JA",
        .tutorial_en => "TUTORIAL EN",
    };
}

fn drawTutorialPanel(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, rect, rgb(10, 12, 14));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));

    const counts = riskCounts(&state.app.security_findings);
    var header_buf: [260]u8 = undefined;
    const language_label = switch (state.tutorial_language) {
        .ja => "JA",
        .en => "EN",
    };
    const header = std.fmt.bufPrint(
        &header_buf,
        "ZIDE TUTORIAL  lang:{s} trust:{s} findings:{d} critical:{d} high:{d} medium:{d}",
        .{
            language_label,
            @tagName(state.app.runtime.trust_state),
            state.app.security_findings.items.items.len,
            counts.critical,
            counts.high,
            counts.medium,
        },
    ) catch "ZIDE TUTORIAL";
    const header_right = if (tutorialPanelHasActionButtons(rect)) rect.right - 156 else rect.right - 16;
    drawTextClipped(hdc, rect.left + 16, rect.top + 10, header_right, rgb(79, 230, 226), header);
    drawTutorialPanelActions(hdc, rect, state.tutorial_language);

    const rows = @max(0, @divTrunc(rect.bottom - rect.top - HEADER_HEIGHT, ROW_HEIGHT));
    const lines = tutorialLines(state.tutorial_language);
    const start = @min(state.tutorial_scroll_line, if (lines.len > @as(usize, @intCast(rows))) lines.len - @as(usize, @intCast(rows)) else 0);
    var row: usize = 0;
    var y = rect.top + HEADER_HEIGHT;
    while (row < @as(usize, @intCast(rows)) and start + row < lines.len) : (row += 1) {
        const line = lines[start + row];
        const color = tutorialLineColor(line);
        drawTextClipped(hdc, rect.left + 16, y, rect.right - 16, color, line);
        y += ROW_HEIGHT;
    }
}

fn drawTutorialPanelActions(hdc: windows.HDC, rect: RECT, active_language: TutorialLanguage) void {
    if (!tutorialPanelHasActionButtons(rect)) return;
    const actions = [_]TutorialPanelAction{ .ja, .en };
    for (actions) |action| {
        const active = switch (action) {
            .ja => active_language == .ja,
            .en => active_language == .en,
        };
        const button = tutorialPanelActionButtonRect(rect, action);
        fillRect(hdc, button, if (active) rgb(51, 153, 235) else rgb(32, 42, 50));
        fillRect(hdc, RECT{ .left = button.left, .top = button.top, .right = button.right, .bottom = button.top + 1 }, rgb(79, 230, 226));
        drawTextClipped(hdc, button.left + 10, button.top + 5, button.right - 6, if (active) rgb(16, 19, 22) else rgb(226, 234, 242), tutorialPanelActionLabel(action));
    }
}

fn tutorialPanelActionAt(rect: RECT, x: c_int, y: c_int) ?TutorialPanelAction {
    if (!tutorialPanelHasActionButtons(rect)) return null;
    if (y < rect.top or y >= rect.top + HEADER_HEIGHT) return null;
    const actions = [_]TutorialPanelAction{ .ja, .en };
    for (actions) |action| {
        if (pointIn(tutorialPanelActionButtonRect(rect, action), x, y)) return action;
    }
    return null;
}

fn tutorialPanelHasActionButtons(rect: RECT) bool {
    return rect.right - rect.left >= 360;
}

fn tutorialPanelActionButtonRect(rect: RECT, action: TutorialPanelAction) RECT {
    const width: c_int = 58;
    const gap: c_int = 8;
    const slot: c_int = switch (action) {
        .en => 0,
        .ja => 1,
    };
    const right = rect.right - 12 - slot * (width + gap);
    return .{
        .left = right - width,
        .top = rect.top + 8,
        .right = right,
        .bottom = rect.top + 32,
    };
}

fn tutorialPanelActionLabel(action: TutorialPanelAction) []const u8 {
    return switch (action) {
        .ja => "JA",
        .en => "EN",
    };
}

fn drawPublishPanel(hdc: windows.HDC, state: *GuiState, rect: RECT) void {
    fillRect(hdc, rect, rgb(10, 12, 14));
    fillRect(hdc, RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, rgb(43, 53, 61));

    var header_buf: [220]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "SHIP  release:{s} gui:{s} cli:{s} workflows:{s}", .{
        if (workspaceHasAnyLicense(&state.app)) "licensed" else "no-license",
        if (workspaceFileExistsGui(&state.app, "zig-out/bin/zide-gui.exe")) "built" else "missing",
        if (workspaceFileExistsGui(&state.app, "zig-out/bin/zide.exe")) "built" else "missing",
        if (workspaceHasPrefixGui(&state.app, ".github/workflows/")) "yes" else "none",
    }) catch "SHIP";
    const header_right = if (publishPanelHasActionButtons(rect)) publishPanelActionButtonRect(rect, .checklist).left - 12 else rect.right - 16;
    drawTextClipped(hdc, rect.left + 16, rect.top + 10, header_right, rgb(79, 230, 226), header);
    drawPublishPanelActions(hdc, rect);

    const lines = publishLines();
    const rows = @max(0, @divTrunc(rect.bottom - rect.top - HEADER_HEIGHT, ROW_HEIGHT));
    const start = @min(state.publish_scroll_line, if (lines.len > @as(usize, @intCast(rows))) lines.len - @as(usize, @intCast(rows)) else 0);
    var y = rect.top + HEADER_HEIGHT;
    var row: usize = 0;
    while (row < @as(usize, @intCast(rows)) and start + row < lines.len) : (row += 1) {
        const line = lines[start + row];
        drawTextClipped(hdc, rect.left + 16, y, rect.right - 16, publishLineColor(line), line);
        y += ROW_HEIGHT;
    }
}

fn drawPublishPanelActions(hdc: windows.HDC, rect: RECT) void {
    if (!publishPanelHasActionButtons(rect)) return;
    const actions = [_]PublishPanelAction{ .checklist, .assets, .manifests, .bundle, .verify, .preflight };
    for (actions) |action| {
        drawButton(hdc, publishPanelActionButtonRect(rect, action), publishPanelActionLabel(action));
    }
}

fn publishPanelActionAt(rect: RECT, x: c_int, y: c_int) ?PublishPanelAction {
    if (!publishPanelHasActionButtons(rect)) return null;
    if (y < rect.top or y >= rect.top + HEADER_HEIGHT) return null;
    const actions = [_]PublishPanelAction{ .checklist, .assets, .manifests, .bundle, .verify, .preflight };
    for (actions) |action| {
        if (pointIn(publishPanelActionButtonRect(rect, action), x, y)) return action;
    }
    return null;
}

fn publishPanelHasActionButtons(rect: RECT) bool {
    return rect.right - rect.left >= 680;
}

fn publishPanelActionButtonRect(rect: RECT, action: PublishPanelAction) RECT {
    const width: c_int = 72;
    const gap: c_int = 8;
    const slot: c_int = switch (action) {
        .preflight => 0,
        .verify => 1,
        .bundle => 2,
        .manifests => 3,
        .assets => 4,
        .checklist => 5,
    };
    const right = rect.right - 12 - slot * (width + gap);
    return .{
        .left = right - width,
        .top = rect.top + 8,
        .right = right,
        .bottom = rect.top + 32,
    };
}

fn publishPanelActionLabel(action: PublishPanelAction) []const u8 {
    return switch (action) {
        .checklist => "CHECK",
        .assets => "HASH",
        .manifests => "MANI",
        .bundle => "ZIP",
        .verify => "VFY",
        .preflight => "GATE",
    };
}

fn publishLineColor(line: []const u8) windows.COLORREF {
    if (std.mem.startsWith(u8, line, "==")) return rgb(255, 207, 92);
    if (std.mem.startsWith(u8, line, "[ship]")) return rgb(165, 214, 167);
    if (std.mem.startsWith(u8, line, "[hash]")) return rgb(79, 230, 226);
    if (std.mem.startsWith(u8, line, "[later]")) return rgb(127, 211, 255);
    if (std.mem.startsWith(u8, line, "[avoid]")) return rgb(255, 118, 118);
    return rgb(210, 218, 226);
}

fn tutorialLineColor(line: []const u8) windows.COLORREF {
    if (std.mem.startsWith(u8, line, "==")) return rgb(255, 207, 92);
    if (std.mem.startsWith(u8, line, "SECURITY") or std.mem.startsWith(u8, line, "セキュリティ")) return rgb(255, 118, 118);
    if (std.mem.startsWith(u8, line, "ZIG")) return rgb(79, 230, 226);
    if (std.mem.startsWith(u8, line, "TRY") or std.mem.startsWith(u8, line, "今すぐ")) return rgb(165, 214, 167);
    return rgb(210, 218, 226);
}

fn drawSecurityPanelActions(hdc: windows.HDC, rect: RECT) void {
    if (!securityPanelHasActionButtons(rect)) return;
    const actions = [_]SecurityPanelAction{ .audit, .lock, .scan, .lf, .crlf, .clean };
    for (actions) |action| {
        drawButton(hdc, securityPanelActionButtonRect(rect, action), securityPanelActionLabel(action));
    }
}

fn securityPanelActionAt(rect: RECT, x: c_int, y: c_int) ?SecurityPanelAction {
    if (!securityPanelHasActionButtons(rect)) return null;
    if (y < rect.top or y >= rect.top + HEADER_HEIGHT) return null;
    const actions = [_]SecurityPanelAction{ .audit, .lock, .scan, .lf, .crlf, .clean };
    for (actions) |action| {
        if (pointIn(securityPanelActionButtonRect(rect, action), x, y)) return action;
    }
    return null;
}

fn securityPanelHasActionButtons(rect: RECT) bool {
    return rect.right - rect.left >= 720;
}

fn securityPanelActionButtonRect(rect: RECT, action: SecurityPanelAction) RECT {
    const width: c_int = 64;
    const gap: c_int = 8;
    const slot: c_int = switch (action) {
        .clean => 0,
        .crlf => 1,
        .lf => 2,
        .scan => 3,
        .lock => 4,
        .audit => 5,
    };
    const right = rect.right - 12 - slot * (width + gap);
    return .{
        .left = right - width,
        .top = rect.top + 8,
        .right = right,
        .bottom = rect.top + 32,
    };
}

fn securityPanelActionLabel(action: SecurityPanelAction) []const u8 {
    return switch (action) {
        .audit => "AUDIT",
        .lock => "LOCK",
        .scan => "SCAN",
        .lf => "LF",
        .crlf => "CRLF",
        .clean => "CLEAN",
    };
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
        const scope_rect = commandScopeRect(palette, y);
        const capability_rect = commandCapabilityRect(palette, y);
        const key_rect = commandKeyRect(palette, y);
        drawTextClipped(hdc, palette.left + 18, y, scope_rect.left - 12, color, match.definition.title);
        drawCommandScopeBadge(hdc, scope_rect, match.definition.scope, selected);
        drawCommandCapabilityBadge(hdc, capability_rect, match.definition.capability, selected);
        drawTextClipped(hdc, key_rect.left + 6, y, key_rect.right, color, match.definition.default_key);
        y += ROW_HEIGHT;
    }

    if (state.app.palette.selected()) |definition| {
        drawCommandPaletteDetail(hdc, palette, definition);
    }
}

fn drawCommandPaletteDetail(hdc: windows.HDC, palette: RECT, definition: command_mod.Definition) void {
    const top = palette.bottom - 58;
    fillRect(hdc, RECT{ .left = palette.left + 8, .top = top - 8, .right = palette.right - 8, .bottom = palette.bottom - 8 }, rgb(16, 20, 25));
    fillRect(hdc, RECT{ .left = palette.left + 8, .top = top - 8, .right = palette.left + 11, .bottom = palette.bottom - 8 }, commandCapabilityColor(definition.capability));

    var meta_buf: [220]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "id:{s}  scope:{s}  capability:{s}", .{
        definition.id,
        @tagName(definition.scope),
        commandCapabilityLabel(definition.capability),
    }) catch definition.id;
    drawTextClipped(hdc, palette.left + 20, top, palette.right - 16, commandCapabilityColor(definition.capability), meta);
    drawTextClipped(hdc, palette.left + 20, top + ROW_HEIGHT, palette.right - 16, rgb(205, 213, 222), definition.description);
}

fn commandScopeRect(palette: RECT, y: c_int) RECT {
    return .{ .left = palette.right - 316, .top = y - 3, .right = palette.right - 230, .bottom = y + ROW_HEIGHT - 3 };
}

fn commandCapabilityRect(palette: RECT, y: c_int) RECT {
    return .{ .left = palette.right - 222, .top = y - 3, .right = palette.right - 116, .bottom = y + ROW_HEIGHT - 3 };
}

fn commandKeyRect(palette: RECT, y: c_int) RECT {
    return .{ .left = palette.right - 110, .top = y - 3, .right = palette.right - 16, .bottom = y + ROW_HEIGHT - 3 };
}

fn drawCommandScopeBadge(hdc: windows.HDC, rect: RECT, scope: command_mod.Scope, selected: bool) void {
    const bg = if (selected) rgb(194, 223, 244) else rgb(31, 40, 49);
    fillRect(hdc, rect, bg);
    drawTextClipped(hdc, rect.left + 7, rect.top + 5, rect.right - 5, if (selected) rgb(16, 19, 22) else rgb(180, 190, 200), @tagName(scope));
}

fn drawCommandCapabilityBadge(hdc: windows.HDC, rect: RECT, capability: command_mod.Capability, selected: bool) void {
    const color = commandCapabilityColor(capability);
    fillRect(hdc, rect, if (selected) color else commandCapabilityBackground(capability));
    drawTextClipped(hdc, rect.left + 7, rect.top + 5, rect.right - 5, if (selected) rgb(16, 19, 22) else color, commandCapabilityLabel(capability));
}

fn commandCapabilityLabel(capability: command_mod.Capability) []const u8 {
    return switch (capability) {
        .safe => "safe",
        .workspace_write => "write",
        .network_read => "net-read",
        .network_write => "net-write",
        .external_command => "exec",
    };
}

fn commandCapabilityColor(capability: command_mod.Capability) windows.COLORREF {
    return switch (capability) {
        .safe => rgb(165, 214, 167),
        .workspace_write => rgb(255, 207, 92),
        .network_read => rgb(127, 211, 255),
        .network_write => rgb(255, 148, 82),
        .external_command => rgb(255, 118, 118),
    };
}

fn commandCapabilityBackground(capability: command_mod.Capability) windows.COLORREF {
    return switch (capability) {
        .safe => rgb(22, 42, 32),
        .workspace_write => rgb(52, 43, 22),
        .network_read => rgb(20, 42, 52),
        .network_write => rgb(58, 34, 24),
        .external_command => rgb(58, 26, 31),
    };
}

fn drawQuickPanel(hdc: windows.HDC, state: *GuiState, client: RECT) void {
    const panel = paletteRect(client);
    fillRect(hdc, panel, rgb(22, 26, 31));
    fillRect(hdc, RECT{ .left = panel.left, .top = panel.top, .right = panel.right, .bottom = panel.top + 1 }, rgb(79, 230, 226));

    const title = switch (state.quick_panel.mode) {
        .find_file => "FIND FILE",
        .find_document => "FIND IN FILE",
        .replace_document => "REPLACE  search=>replacement",
        .rename_symbol => "RENAME  old=>new",
        .goto_line => "GO TO LINE  line[:column]",
        .search_workspace => "SEARCH",
        .replace_workspace => "REPLACE WORKSPACE",
        .run_task => "TASKS",
        .new_file => "NEW FILE",
        .new_folder => "NEW FOLDER",
        .rename_path => "RENAME PATH  old=>new",
        .delete_path => "DELETE PATH  path=>DELETE",
        .git_commit => "SOURCE CONTROL  COMMIT MESSAGE",
        .git_branch_switch => "SOURCE CONTROL  SWITCH BRANCH",
        .git_branch_create => "SOURCE CONTROL  CREATE BRANCH",
        .github_pr => "GITHUB  CREATE DRAFT PULL REQUEST",
        .document_symbols => "SYMBOLS",
        .workspace_symbols => "WORKSPACE SYMBOLS",
        .lsp_actions => "LSP ACTIONS  Ctrl+Alt+L",
        .lsp_locations => "LSP LOCATIONS  Enter opens",
        .problems => "PROBLEMS  diagnostics + security",
        .completion => "COMPLETE  Enter inserts",
        .lsp_hover => "HOVER  Enter closes",
        .code_actions => "QUICK FIX  Enter applies",
        .language_mode => "LANGUAGE MODE",
        .recovery => "RECOVERY CENTER  hash-bound / source writes locked",
        .debug_watch => "RESTRICTED WATCH  type to add; Enter removes selected; calls and assignments blocked",
        .debug_breakpoint => "ADVANCED BREAKPOINTS  source + function + data + exception",
        .debug_breakpoint_condition => "CONDITION  bounded predicate / no calls or assignments",
        .debug_breakpoint_hit => "HIT COUNT  positive decimal",
        .debug_breakpoint_log => "LOGPOINT  restricted {inspection} interpolation",
        .debug_functions => "FUNCTION BREAKPOINTS  bounded explicit symbols / adapter-resolved",
        .debug_data => "DATA BREAKPOINTS  inspect current variable / explicit commit / opaque IDs",
        .debug_low_level => "LOW LEVEL  read-only memory / disassembly / session-only instruction breakpoints",
        .debug_exceptions => "EXCEPTION BREAKPOINTS  explicit selection / adapter defaults never auto-enable",
    };
    drawText(hdc, panel.left + 16, panel.top + 14, rgb(79, 230, 226), title);
    if (state.quick_panel.mode == .replace_workspace) {
        drawButton(hdc, quickPanelApplyButtonRect(panel), "APPLY");
        var options_buf: [200]u8 = undefined;
        const options = if (state.quick_panel.replacement_preview) |preview|
            std.fmt.bufPrint(&options_buf, "{d} files  {d} matches  #{s}  {s}/{s}", .{
                preview.files.len,
                preview.matches,
                preview.token[0..12],
                if (state.quick_panel.search_options.case_sensitive) "case" else "ignore",
                if (state.quick_panel.search_options.whole_word) "word" else "partial",
            }) catch ""
        else
            "search=>replacement";
        drawTextRight(hdc, panel.left + 300, panel.top + 44, panel.right - 16, rgb(180, 190, 200), options);
    } else if (isDocumentSearchMode(state.quick_panel.mode)) {
        var options_buf: [120]u8 = undefined;
        const count = state.quick_panel.itemCount();
        const current = if (count == 0) 0 else @min(state.quick_panel.selected_index + 1, count);
        const options = std.fmt.bufPrint(&options_buf, "{d}/{d}  F3 next  F6 {s}  F7 {s}{s}", .{
            current,
            count,
            if (state.quick_panel.search_options.case_sensitive) "case" else "ignore",
            if (state.quick_panel.search_options.whole_word) "word" else "partial",
            if (state.quick_panel.mode == .replace_document) "  Ctrl+Enter all" else "",
        }) catch "";
        drawTextRight(hdc, panel.left + 260, panel.top + 14, panel.right - 16, rgb(180, 190, 200), options);
    }
    const query_right = if (state.quick_panel.mode == .replace_workspace) panel.left + 288 else panel.right - 16;
    if (state.quick_panel.mode == .recovery) {
        var summary_buf: [240]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "integrity-valid:{d}  rejected:{d}  scan-truncated:{}  restore target:unsaved editor", .{
            state.quick_panel.recovery_count,
            state.quick_panel.recovery_invalid_count,
            state.app.recovery_manager.scan_truncated,
        }) catch "recovery integrity boundary";
        drawTextClipped(hdc, panel.left + 16, panel.top + 44, query_right, rgb(180, 190, 200), summary);
    } else if (state.quick_panel.mode == .debug_exceptions) {
        const session = &state.app.debug_manager.session;
        var summary_buf: [240]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "selected:{d}  advertised:{d}  active:{d}  withheld:{d}  metadata-rejected:{d}", .{
            session.selectedExceptionFilterCount(),
            session.exception_filters.items.len,
            session.selectedAdvertisedExceptionFilterCount(),
            session.withheldExceptionFilterCount(),
            session.rejected_exception_filter_metadata,
        }) catch "exception filter boundary";
        drawTextClipped(hdc, panel.left + 16, panel.top + 44, query_right, rgb(180, 190, 200), summary);
    } else if (state.quick_panel.mode == .debug_functions and std.mem.trim(u8, state.quick_panel.query.items, " \t\r\n").len == 0) {
        const session = &state.app.debug_manager.session;
        var summary_buf: [220]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "configured:{d}  adapter-capability:{s}  withheld:{d}  type to add", .{
            session.function_breakpoints.items.len,
            @tagName(session.functionBreakpointCapability()),
            session.unsupportedFunctionBreakpointCount(),
        }) catch "function breakpoint boundary";
        drawTextClipped(hdc, panel.left + 16, panel.top + 44, query_right, rgb(180, 190, 200), summary);
    } else if (state.quick_panel.mode == .debug_data) {
        const session = &state.app.debug_manager.session;
        var summary_buf: [300]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "configured:{d}  vars:{d}  candidate:{s}  adapter-capability:{s}  withheld:{d}  metadata-rejected:{d}", .{
            session.data_breakpoints.items.len,
            session.variables.items.len,
            if (session.data_breakpoint_candidate != null) "staged" else "none",
            @tagName(session.dataBreakpointCapability()),
            session.withheldDataBreakpointCount(),
            session.rejected_data_breakpoint_metadata,
        }) catch "data breakpoint boundary";
        drawTextClipped(hdc, panel.left + 16, panel.top + 44, query_right, rgb(180, 190, 200), summary);
    } else if (state.quick_panel.mode == .debug_low_level) {
        const session = &state.app.debug_manager.session;
        var summary_buf: [420]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "memory:{s}  disasm:{s}  instruction-bp:{s}  refs frame:{d}/var:{d}  write:LOCKED(adapter:{})  rejected:{d}", .{
            @tagName(session.memoryReadCapability()),
            @tagName(session.disassemblyCapability()),
            @tagName(session.instructionBreakpointCapability()),
            session.stackFrameInstructionReferenceCount(),
            session.variableMemoryReferenceCount(),
            session.capabilities.supports_write_memory_request,
            session.rejected_low_level_metadata,
        }) catch "low-level boundary";
        drawTextClipped(hdc, panel.left + 16, panel.top + 44, query_right, rgb(180, 190, 200), summary);
    } else {
        drawTextClipped(hdc, panel.left + 16, panel.top + 44, query_right, rgb(235, 239, 244), state.quick_panel.query.items);
    }

    var y = panel.top + PALETTE_MATCH_TOP;
    const max_matches: usize = 10;
    const total = state.quick_panel.itemCount();
    const start = quickPanelVisibleStart(&state.quick_panel, max_matches);
    const count = @min(max_matches, total - start);
    var row: usize = 0;
    while (row < count) : (row += 1) {
        const item_index = start + row;
        const selected = item_index == state.quick_panel.selected_index;
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
            .replace_workspace => {
                const preview = if (state.quick_panel.replacement_preview) |*value| value else break;
                const item = preview.files[row];
                var location_buf: [360]u8 = undefined;
                const location = std.fmt.bufPrint(&location_buf, "{s}:{d}:{d}", .{
                    item.path,
                    item.first_line + 1,
                    item.first_column + 1,
                }) catch item.path;
                var meta_buf: [96]u8 = undefined;
                const meta = std.fmt.bufPrint(&meta_buf, "{d} matches  #{s}", .{ item.matches, item.digest[0..12] }) catch "";
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 210, color, location);
                drawTextClipped(hdc, panel.right - 198, y, panel.right - 16, color, meta);
            },
            .find_document, .replace_document => {
                const items = state.quick_panel.document_matches orelse break;
                const item = items[row];
                var location_buf: [80]u8 = undefined;
                const location = std.fmt.bufPrint(&location_buf, "{d}:{d}", .{ item.line + 1, item.column + 1 }) catch "";
                drawTextClipped(hdc, panel.left + 18, y, panel.left + 104, color, location);
                drawTextClipped(hdc, panel.left + 116, y, panel.right - 16, color, item.preview);
            },
            .rename_symbol => {
                const request = pathMutationRequest(state.quick_panel.query.items) orelse break;
                var rename_buf: [240]u8 = undefined;
                const label = std.fmt.bufPrint(&rename_buf, "{s} -> {s}", .{ request.find, request.replace }) catch "Rename";
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
            },
            .goto_line => {
                const target = goto_line.parse(state.quick_panel.query.items) orelse break;
                var target_buf: [96]u8 = undefined;
                const label = std.fmt.bufPrint(&target_buf, "Jump to {d}:{d}", .{ target.line + 1, target.column + 1 }) catch "Jump";
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
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
            .new_folder => {
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "Create folder inside workspace");
            },
            .rename_path => {
                const request = renameRequest(state.quick_panel.query.items) orelse break;
                var rename_buf: [320]u8 = undefined;
                const label = std.fmt.bufPrint(&rename_buf, "{s} -> {s}", .{ request.find, request.replace }) catch "Rename path";
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
            },
            .delete_path => {
                const path = confirmedDeletePath(state.quick_panel.query.items) orelse break;
                var delete_buf: [320]u8 = undefined;
                const label = std.fmt.bufPrint(&delete_buf, "Delete {s}", .{path}) catch "Delete path";
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
            },
            .git_commit => {
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "Commit staged changes");
            },
            .git_branch_switch => {
                const items = state.quick_panel.task_matches orelse break;
                if (item_index >= items.len) break;
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 180, color, items[item_index].name);
                drawTextRight(hdc, panel.right - 170, y, panel.right - 16, color, items[item_index].executable);
            },
            .git_branch_create => {
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "Create and switch to new branch");
            },
            .github_pr => {
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "Create draft PR with this title");
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
            .workspace_symbols => {
                const items = state.quick_panel.workspace_symbol_matches orelse break;
                const item = items[row];
                var location_buf: [320]u8 = undefined;
                const location = std.fmt.bufPrint(&location_buf, "{s}:{d}:{d}", .{ item.path, item.line + 1, item.column + 1 }) catch item.path;
                drawTextClipped(hdc, panel.left + 18, y, panel.left + 220, color, item.name);
                drawTextClipped(hdc, panel.left + 230, y, panel.left + 350, color, @tagName(item.kind));
                drawTextClipped(hdc, panel.left + 360, y, panel.left + 450, color, modes.label(item.language));
                drawTextClipped(hdc, panel.left + 460, y, panel.right - 16, color, location);
            },
            .lsp_actions => {
                const action = lspActionAt(state.quick_panel.query.items, row) orelse break;
                drawTextClipped(hdc, panel.left + 18, y, panel.left + 188, color, action.label);
                drawTextClipped(hdc, panel.left + 198, y, panel.left + 398, color, action.id);
                drawTextClipped(hdc, panel.left + 408, y, panel.right - 16, color, action.hint);
            },
            .lsp_locations => {
                const session = state.app.activeLspSessionConst() orelse break;
                const locations = session.last_locations orelse break;
                if (row >= locations.items.len) break;
                const item = locations.items[row];
                var meta_buf: [96]u8 = undefined;
                const meta = std.fmt.bufPrint(&meta_buf, "{d}. {d}:{d}", .{
                    row + 1,
                    item.range.start.line + 1,
                    item.range.start.column + 1,
                }) catch "";
                drawTextClipped(hdc, panel.left + 18, y, panel.left + 120, color, meta);
                drawTextClipped(hdc, panel.left + 130, y, panel.right - 16, color, item.path);
            },
            .problems => {
                const items = state.quick_panel.problem_matches orelse break;
                const item = items[row];
                var meta_buf: [320]u8 = undefined;
                const meta = std.fmt.bufPrint(&meta_buf, "{s}/{s}", .{ @tagName(item.kind), item.level }) catch item.level;
                var location_buf: [320]u8 = undefined;
                const location = std.fmt.bufPrint(&location_buf, "{s}:{d}:{d}", .{
                    if (item.path.len == 0) "(workspace)" else item.path,
                    item.line + 1,
                    item.column + 1,
                }) catch item.path;
                drawTextClipped(hdc, panel.left + 18, y, panel.left + 170, color, meta);
                drawTextClipped(hdc, panel.left + 180, y, panel.left + 420, color, location);
                drawTextClipped(hdc, panel.left + 430, y, panel.right - 16, color, item.message);
            },
            .completion => {
                const items = state.quick_panel.completion_matches orelse break;
                const item = items[row];
                drawTextClipped(hdc, panel.left + 18, y, panel.left + 250, color, item.label);
                drawTextClipped(hdc, panel.left + 260, y, panel.left + 370, color, @tagName(item.kind));
                drawTextClipped(hdc, panel.left + 380, y, panel.right - 16, color, item.detail);
            },
            .lsp_hover => {
                const session = state.app.activeLspSessionConst() orelse break;
                const hover = session.last_hover orelse break;
                const line = hoverLineAt(hover.text, row) orelse break;
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, line);
            },
            .code_actions => {
                const session = state.app.activeLspSessionConst() orelse break;
                const actions = session.last_code_actions orelse break;
                if (row >= actions.items.len) break;
                const item = actions.items[row];
                var meta_buf: [160]u8 = undefined;
                const meta = std.fmt.bufPrint(&meta_buf, "{d}. {s}{s}", .{
                    row + 1,
                    item.kind,
                    if (item.workspace_edit != null) " edit" else " command",
                }) catch item.kind;
                drawTextClipped(hdc, panel.left + 18, y, panel.left + 190, color, meta);
                drawTextClipped(hdc, panel.left + 200, y, panel.right - 16, color, item.title);
            },
            .language_mode => {
                const items = state.quick_panel.language_matches orelse break;
                const mode = items[row];
                drawTextClipped(hdc, panel.left + 18, y, panel.left + 180, color, modes.label(mode));
                drawTextClipped(hdc, panel.left + 190, y, panel.left + 310, color, @tagName(modes.family(mode)));
                drawTextClipped(hdc, panel.left + 320, y, panel.right - 16, color, modes.securityFocus(mode));
            },
            .recovery => recovery: {
                const snapshot_count = state.app.recovery_manager.entries.items.len;
                const discard_all_index = snapshot_count * 2;
                if (snapshot_count > 0 and item_index == discard_all_index) {
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, if (selected) color else rgb(255, 148, 82), "DISCARD ALL INTEGRITY-VALID SNAPSHOTS");
                    break :recovery;
                }
                const purge_index = discard_all_index + @intFromBool(snapshot_count > 0);
                if (state.app.recovery_manager.invalid_entries > 0 and item_index == purge_index) {
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, if (selected) color else rgb(255, 118, 118), "PURGE REJECTED RECOVERY ENVELOPES");
                    break :recovery;
                }
                const snapshot_index = item_index / 2;
                if (snapshot_index >= snapshot_count) break :recovery;
                const entry = state.app.recovery_manager.entries.items[snapshot_index];
                const baseline_hex = std.fmt.bytesToHex(entry.baseline_digest, .lower);
                var label_buf: [900]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "{s} {d}  {s}  bytes:{d}  baseline:{s}  {s}", .{
                    if (item_index % 2 == 0) "RESTORE" else "DISCARD",
                    snapshot_index + 1,
                    entry.relative_path,
                    entry.content_len,
                    baseline_hex[0..12],
                    if (entry.owned_by_session) "current-session" else "previous-session",
                }) catch entry.relative_path;
                const row_color = if (!selected and item_index % 2 == 1) rgb(255, 184, 116) else color;
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, row_color, label);
            },
            .debug_watch => {
                if (std.mem.trim(u8, state.quick_panel.query.items, " \t\r\n").len > 0) {
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "ADD  session inspection watch");
                } else if (row < state.app.debug_manager.session.watches.items.len) {
                    const watch = state.app.debug_manager.session.watches.items[row];
                    var watch_buf: [720]u8 = undefined;
                    const value = watch.result orelse watch.error_message orelse if (watch.pending_seq != null) "(pending)" else "(not evaluated)";
                    const label = std.fmt.bufPrint(&watch_buf, "REMOVE {d}  {s} = {s}", .{ row + 1, watch.expression, value }) catch watch.expression;
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
                }
            },
            .debug_breakpoint => {
                const breakpoint = state.currentLineBreakpoint();
                var value_buf: [900]u8 = undefined;
                const label = switch (row) {
                    0 => std.fmt.bufPrint(&value_buf, "CONDITION  {s}", .{if (breakpoint) |item| item.condition orelse "(not set)" else "(not set)"}) catch "CONDITION",
                    1 => std.fmt.bufPrint(&value_buf, "HIT COUNT  {s}", .{if (breakpoint) |item| item.hit_condition orelse "(not set)" else "(not set)"}) catch "HIT COUNT",
                    2 => std.fmt.bufPrint(&value_buf, "LOGPOINT  {s}", .{if (breakpoint) |item| item.log_message orelse "(not set)" else "(not set)"}) catch "LOGPOINT",
                    3 => "CLEAR ADVANCED SETTINGS",
                    4 => "EXCEPTION FILTERS  adapter-advertised / explicit-only",
                    5 => "FUNCTION BREAKPOINTS  bounded explicit symbols",
                    6 => "DATA BREAKPOINTS  stopped variables / explicit access / opaque IDs",
                    7 => "LOW LEVEL  read-only memory / disassembly / instruction breakpoints",
                    else => "",
                };
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
            },
            .debug_breakpoint_condition => drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "SET RESTRICTED CONDITION"),
            .debug_breakpoint_hit => drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "SET HIT COUNT"),
            .debug_breakpoint_log => drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "SET RESTRICTED LOGPOINT"),
            .debug_functions => {
                if (std.mem.trim(u8, state.quick_panel.query.items, " \t\r\n").len > 0) {
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "ADD  bounded explicit function selector");
                    break;
                }
                if (item_index >= state.quick_panel.debug_function_count) {
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "CLEAR ALL FUNCTION BREAKPOINTS");
                    break;
                }
                const breakpoint = state.app.debug_manager.session.function_breakpoints.items[item_index];
                var function_buf: [1500]u8 = undefined;
                const label = std.fmt.bufPrint(&function_buf, "REMOVE {d}  {s}{s}{s}  {s}", .{
                    item_index + 1,
                    breakpoint.name,
                    if (breakpoint.verified) |verified| if (verified) "  verified" else "  rejected" else "  pending",
                    if (state.app.debug_manager.session.unsupportedFunctionBreakpointCount() > 0) "  saved-only/withheld" else "",
                    breakpoint.message orelse "",
                }) catch breakpoint.name;
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
            },
            .debug_data => data: {
                const session = &state.app.debug_manager.session;
                var relative = item_index;
                if (relative < state.quick_panel.debug_data_commit_count) {
                    const choice = session.dataBreakpointCandidateCommitChoiceAt(relative) orelse break :data;
                    const candidate = session.data_breakpoint_candidate orelse break :data;
                    var candidate_buf: [1500]u8 = undefined;
                    const label = std.fmt.bufPrint(&candidate_buf, "COMMIT {s}  {s}  {s}  persistence:{s}", .{
                        choice.displayName(),
                        candidate.variable_name,
                        candidate.description,
                        if (candidate.can_persist) "workspace" else "session-only",
                    }) catch candidate.description;
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
                    break :data;
                }
                relative -= state.quick_panel.debug_data_commit_count;
                if (state.quick_panel.debug_data_has_candidate) {
                    if (relative == 0) {
                        const candidate = session.data_breakpoint_candidate orelse break :data;
                        var cancel_buf: [1500]u8 = undefined;
                        const label = std.fmt.bufPrint(&cancel_buf, "CANCEL CANDIDATE  {s}  {s}{s}", .{
                            candidate.variable_name,
                            candidate.description,
                            if (candidate.data_id == null) "  unavailable" else "",
                        }) catch "CANCEL CANDIDATE";
                        drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
                        break :data;
                    }
                    relative -= 1;
                }
                if (relative < state.quick_panel.debug_data_variable_count) {
                    if (relative >= session.variables.items.len) break :data;
                    const variable = session.variables.items[relative];
                    var variable_buf: [1500]u8 = undefined;
                    const label = std.fmt.bufPrint(&variable_buf, "INSPECT {d}  {s} = {s}  ({s})", .{
                        relative + 1,
                        variable.name,
                        variable.value,
                        variable.type_name orelse "?",
                    }) catch variable.name;
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
                    break :data;
                }
                relative -= state.quick_panel.debug_data_variable_count;
                if (relative < state.quick_panel.debug_data_breakpoint_count) {
                    if (relative >= session.data_breakpoints.items.len) break :data;
                    const breakpoint = session.data_breakpoints.items[relative];
                    var breakpoint_buf: [1500]u8 = undefined;
                    const label = std.fmt.bufPrint(&breakpoint_buf, "REMOVE {d}  {s}  adapter:{s}  access:{s}  {s}{s}{s}", .{
                        relative + 1,
                        breakpoint.description,
                        breakpoint.adapter_key,
                        if (breakpoint.access_type) |access_type| access_type.protocolName() else "adapter-default",
                        if (breakpoint.can_persist) "persisted" else "session-only",
                        if (breakpoint.verified) |verified| if (verified) "  verified" else "  rejected" else "  pending",
                        if (!session.dataBreakpointsSupported() or session.active_adapter_key == null or !std.mem.eql(u8, breakpoint.adapter_key, session.active_adapter_key.?)) "  withheld" else "",
                    }) catch breakpoint.description;
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
                    break :data;
                }
                relative -= state.quick_panel.debug_data_breakpoint_count;
                if (state.quick_panel.debug_data_breakpoint_count > 0 and relative == 0) {
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "CLEAR ALL DATA BREAKPOINTS");
                }
            },
            .debug_low_level => low_level: {
                const session = &state.app.debug_manager.session;
                var relative = item_index;
                if (relative < state.quick_panel.debug_low_frame_count) {
                    const frame_index = session.stackFrameInstructionReferenceIndexAt(relative) orelse break :low_level;
                    const frame = session.stack_frames.items[frame_index];
                    var frame_buf: [1500]u8 = undefined;
                    const label = std.fmt.bufPrint(&frame_buf, "DISASSEMBLE FRAME {d}  {s}  ip:{s}", .{
                        frame_index + 1,
                        frame.name,
                        frame.instruction_pointer_reference.?,
                    }) catch frame.name;
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
                    break :low_level;
                }
                relative -= state.quick_panel.debug_low_frame_count;
                if (relative < state.quick_panel.debug_low_variable_count) {
                    const variable_index = session.variableMemoryReferenceIndexAt(relative) orelse break :low_level;
                    const variable = session.variables.items[variable_index];
                    var variable_buf: [1500]u8 = undefined;
                    const label = std.fmt.bufPrint(&variable_buf, "READ MEMORY {d}  {s} = {s}  ref:{s}  max:256/read-only", .{
                        variable_index + 1,
                        variable.name,
                        variable.value,
                        variable.memory_reference.?,
                    }) catch variable.name;
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
                    break :low_level;
                }
                relative -= state.quick_panel.debug_low_variable_count;
                if (state.quick_panel.debug_low_has_memory) {
                    const snapshot = session.memory_snapshot orelse break :low_level;
                    if (relative == 0) {
                        var refresh_buf: [480]u8 = undefined;
                        const label = std.fmt.bufPrint(&refresh_buf, "REFRESH READ-ONLY MEMORY  base:{s}  bytes:{d}  unreadable:{d}", .{
                            snapshot.address,
                            snapshot.bytes.len,
                            snapshot.unreadable_bytes,
                        }) catch "REFRESH READ-ONLY MEMORY";
                        drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
                        break :low_level;
                    }
                    relative -= 1;
                    if (relative < state.quick_panel.debug_low_memory_line_count) {
                        var memory_buf: [256]u8 = undefined;
                        const label = formatMemoryHexRow(&memory_buf, snapshot.bytes, relative);
                        drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, rgb(165, 214, 167), label);
                        break :low_level;
                    }
                    relative -= state.quick_panel.debug_low_memory_line_count;
                }
                if (relative < state.quick_panel.debug_low_instruction_count) {
                    const instruction = session.disassembled_instructions.items[relative];
                    var instruction_buf: [1800]u8 = undefined;
                    const label = std.fmt.bufPrint(&instruction_buf, "TOGGLE [{s}] {d}  {s}  {s}  {s}  {s}", .{
                        if (session.instructionBreakpointSet(instruction.address)) "x" else " ",
                        relative + 1,
                        instruction.address,
                        instruction.instruction_bytes orelse "",
                        instruction.instruction,
                        instruction.symbol orelse "",
                    }) catch instruction.instruction;
                    const instruction_color = if (instruction.invalid) rgb(126, 138, 150) else color;
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, instruction_color, label);
                    break :low_level;
                }
                relative -= state.quick_panel.debug_low_instruction_count;
                if (relative < state.quick_panel.debug_low_breakpoint_count) {
                    const breakpoint = session.instruction_breakpoints.items[relative];
                    var breakpoint_buf: [1500]u8 = undefined;
                    const label = std.fmt.bufPrint(&breakpoint_buf, "REMOVE INSTRUCTION BP {d}  {s}  {s}{s}", .{
                        relative + 1,
                        breakpoint.instruction_reference,
                        if (breakpoint.verified) |verified| if (verified) "verified" else "rejected" else "pending",
                        if (session.withheldInstructionBreakpointCount() > 0) "  withheld" else "",
                    }) catch breakpoint.instruction_reference;
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, label);
                    break :low_level;
                }
                relative -= state.quick_panel.debug_low_breakpoint_count;
                if (state.quick_panel.debug_low_breakpoint_count > 0 and relative == 0) {
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "CLEAR ALL SESSION-ONLY INSTRUCTION BREAKPOINTS");
                }
            },
            .debug_exceptions => {
                if (item_index >= state.quick_panel.debug_exception_count) {
                    drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, color, "CLEAR ALL SELECTED EXCEPTION FILTERS");
                    break;
                }
                const filter = state.app.debug_manager.session.exceptionFilterDisplayAt(item_index) orelse break;
                var filter_buf: [1400]u8 = undefined;
                const label = std.fmt.bufPrint(&filter_buf, "[{s}] {s}  id:{s}{s}{s}{s}{s}", .{
                    if (filter.selected) "x" else " ",
                    filter.label,
                    filter.id,
                    if (filter.default_enabled) "  adapter-default" else "",
                    if (filter.supports_condition) "  condition-capable/ZIDE-locked" else "",
                    if (!filter.advertised) "  saved-only/withheld" else "",
                    if (filter.verified) |verified| if (verified) "  verified" else "  rejected" else "",
                }) catch filter.label;
                drawTextClipped(hdc, panel.left + 18, y, panel.right - 16, if (!selected and filter.selected) rgb(165, 214, 167) else color, label);
            },
        }
        y += ROW_HEIGHT;
    }

    if (state.quick_panel.itemCount() == 0) {
        const empty_text = switch (state.quick_panel.mode) {
            .debug_watch => "Type a field, pointer, or indexed value",
            .debug_breakpoint_condition => "Enter a comparison predicate",
            .debug_breakpoint_hit => "Enter a positive hit count",
            .debug_breakpoint_log => "Enter a log message",
            .debug_functions => "Type an explicit qualified function symbol or signature",
            .debug_data => "Pause the debuggee and load variables, or start an adapter with data-breakpoint support",
            .debug_low_level => "Pause the debuggee and load stack/variables from a low-level capable adapter",
            .debug_exceptions => "Start a debug adapter to discover bounded exception filters",
            .recovery => if (state.quick_panel.recovery_invalid_count > 0) "No valid snapshots; malformed or tampered envelopes were rejected" else "No recovery snapshots",
            else => "No matches",
        };
        drawText(hdc, panel.left + 18, y, rgb(126, 138, 150), empty_text);
    }
}

fn drawStatus(hdc: windows.HDC, state: *GuiState, status: RECT) void {
    var buffer: [760]u8 = undefined;
    var boundary_buffer: [64]u8 = undefined;
    var lsp_buffer: [80]u8 = undefined;
    const mode = @tagName(state.app.mode);
    const focus = @tagName(state.app.focus);
    const message = state.last_error orelse "ready";
    const cursor = if (state.app.documents.active()) |doc| doc.cursor.position else null;
    const dirty = if (state.app.documents.active()) |doc| doc.dirty else false;
    const dirty_count = state.app.documents.dirtyCount();
    const language = if (state.app.documents.active()) |doc| modes.label(doc.language) else "none";
    const newline = if (state.app.documents.active()) |doc| doc.newlineLabel() else "NONE";
    const encoding = if (state.app.documents.active()) |doc| doc.encodingLabel() else "UTF-8";
    const current_risk = currentDocumentRiskCounts(state);
    const current_boundary = currentLineBoundaryHint(state, &boundary_buffer);
    const lsp_status = activeLspStatusText(&state.app, &lsp_buffer);
    const git_changes = if (state.git_overview) |overview| overview.changes.len else 0;
    const text = std.fmt.bufPrint(
        &buffer,
        " {s}/{s}  |  line:{d} col:{d} carets:{d} {s} dirty:{d} lang:{s} lsp:{s} fmt:{s}/{s} trust:{s} risk:{d}/{d}/{d} at:{s} git:{d} | files:{d} code:{d} langs:{d} docs:{d} zig:{d} output:{s} | {s}",
        .{
            mode,
            focus,
            if (cursor) |position| position.line + 1 else 0,
            if (cursor) |position| position.column + 1 else 0,
            if (cursor != null) state.secondary_cursors.items.len + 1 else 0,
            if (dirty) "dirty" else "clean",
            dirty_count,
            language,
            lsp_status,
            encoding,
            newline,
            @tagName(state.app.runtime.trust_state),
            current_risk.critical,
            current_risk.high,
            current_risk.medium,
            current_boundary,
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

fn findDocumentMatches(
    allocator: std.mem.Allocator,
    doc: *const document_mod.Document,
    query: []const u8,
    options: literal_search.Options,
    max_results: usize,
) ![]DocumentMatch {
    const literal_matches = try literal_search.findAll(allocator, doc.text.bytes, query, options);
    defer allocator.free(literal_matches);

    var matches = std.array_list.Managed(DocumentMatch).init(allocator);
    errdefer {
        for (matches.items) |*item| item.deinit(allocator);
        matches.deinit();
    }

    for (literal_matches) |match| {
        if (matches.items.len >= max_results) break;
        const lc = doc.text.offsetToLineColumn(match.start) catch continue;
        const preview = try allocator.dupe(u8, doc.text.lineSlice(lc.line));
        errdefer allocator.free(preview);
        try matches.append(.{
            .line = lc.line,
            .column = lc.column,
            .byte_offset = match.start,
            .end_offset = match.end,
            .preview = preview,
        });
    }

    return try matches.toOwnedSlice();
}

fn isDocumentSearchMode(mode: QuickPanelMode) bool {
    return mode == .find_document or mode == .replace_document;
}

fn formatMemoryHexRow(buffer: []u8, bytes: []const u8, row: usize) []const u8 {
    const start = std.math.mul(usize, row, 16) catch return "";
    if (start >= bytes.len) return "";

    const prefix = std.fmt.bufPrint(buffer, "+{d:0>4}  ", .{start}) catch return "";
    var cursor = prefix.len;
    const hex = "0123456789abcdef";
    var column: usize = 0;
    while (column < 16) : (column += 1) {
        if (cursor + 3 > buffer.len) return buffer[0..cursor];
        const index = start + column;
        if (index < bytes.len) {
            const byte = bytes[index];
            buffer[cursor] = hex[byte >> 4];
            buffer[cursor + 1] = hex[byte & 0x0f];
        } else {
            buffer[cursor] = ' ';
            buffer[cursor + 1] = ' ';
        }
        buffer[cursor + 2] = ' ';
        cursor += 3;
    }

    if (cursor + 2 > buffer.len) return buffer[0..cursor];
    buffer[cursor] = '|';
    cursor += 1;
    column = 0;
    while (column < 16 and start + column < bytes.len) : (column += 1) {
        if (cursor + 1 > buffer.len) return buffer[0..cursor];
        const byte = bytes[start + column];
        buffer[cursor] = if (byte >= 0x20 and byte <= 0x7e) byte else '.';
        cursor += 1;
    }
    if (cursor < buffer.len) {
        buffer[cursor] = '|';
        cursor += 1;
    }
    return buffer[0..cursor];
}

fn isReadOnlyQuickPanelMode(mode: QuickPanelMode) bool {
    return mode == .recovery or mode == .debug_breakpoint or mode == .debug_data or mode == .debug_low_level or mode == .debug_exceptions or mode == .lsp_hover;
}

fn quickPanelVisibleStart(panel: *const QuickPanel, max_visible: usize) usize {
    if ((panel.mode != .git_branch_switch and panel.mode != .debug_exceptions and panel.mode != .debug_functions and panel.mode != .debug_data and panel.mode != .debug_low_level) or max_visible == 0) return 0;
    const count = panel.itemCount();
    if (count <= max_visible or panel.selected_index < max_visible) return 0;
    return @min(panel.selected_index + 1 - max_visible, count - max_visible);
}

fn containsOffset(offsets: []const usize, target: usize) bool {
    for (offsets) |offset| if (offset == target) return true;
    return false;
}

fn offsetLessThan(_: void, left: usize, right: usize) bool {
    return left < right;
}

fn supportsQuickPanelSearchOptions(mode: QuickPanelMode) bool {
    return isDocumentSearchMode(mode) or mode == .search_workspace or mode == .replace_workspace;
}

fn lspActionMatches(query: []const u8, action: LspPanelAction) bool {
    if (query.len == 0) return true;
    return command_mod.fuzzyScore(query, action.label) != null or
        command_mod.fuzzyScore(query, action.id) != null or
        command_mod.fuzzyScore(query, action.hint) != null;
}

fn lspActionCount(query: []const u8) usize {
    var count: usize = 0;
    for (lsp_panel_actions) |action| {
        if (lspActionMatches(query, action)) count += 1;
    }
    return count;
}

fn lspActionAt(query: []const u8, display_index: usize) ?LspPanelAction {
    var index: usize = 0;
    for (lsp_panel_actions) |action| {
        if (!lspActionMatches(query, action)) continue;
        if (index == display_index) return action;
        index += 1;
    }
    return null;
}

fn activeLspStatusText(app: *const app_mod.App, buffer: []u8) []const u8 {
    const language = app.activeLanguage() orelse return "none";
    const server = app.lsp_manager.findServerConst(language) orelse return "none";
    return std.fmt.bufPrint(buffer, "{s}/{s}/p{d}", .{
        modes.label(language),
        if (server.transport != null) "run" else "stop",
        server.session.pendingCount(),
    }) catch "err";
}

fn hoverDisplayLineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn hoverLineAt(text: []const u8, target: usize) ?[]const u8 {
    var line: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= text.len) : (index += 1) {
        if (index < text.len and text[index] != '\n') continue;
        if (line == target) {
            var end = index;
            if (end > start and text[end - 1] == '\r') end -= 1;
            return text[start..end];
        }
        line += 1;
        start = index + 1;
    }
    return null;
}

fn findNextMatchIndex(matches: []const literal_search.Match, pivot: usize) usize {
    for (matches, 0..) |match, index| {
        if (match.start >= pivot) return index;
    }
    return 0;
}

fn findPreviousMatchIndex(matches: []const literal_search.Match, pivot: usize) usize {
    var index = matches.len;
    while (index > 0) {
        index -= 1;
        if (matches[index].end <= pivot) return index;
    }
    return matches.len - 1;
}

fn parseReplaceRequest(query: []const u8) ?ReplaceRequest {
    const delimiter = std.mem.indexOf(u8, query, "=>") orelse return null;
    const find = std.mem.trim(u8, query[0..delimiter], " \t\r\n");
    const replace = query[delimiter + 2 ..];
    if (find.len == 0) return null;
    return .{ .find = find, .replace = replace };
}

fn renameRequest(query: []const u8) ?ReplaceRequest {
    const request = parseReplaceRequest(query) orelse return null;
    const replace = std.mem.trim(u8, request.replace, " \t\r\n");
    if (!isValidIdentifierName(request.find) or !isValidIdentifierName(replace)) return null;
    return .{ .find = request.find, .replace = replace };
}

fn pathMutationRequest(query: []const u8) ?ReplaceRequest {
    const request = parseReplaceRequest(query) orelse return null;
    const replace = std.mem.trim(u8, request.replace, " \t\r\n");
    if (replace.len == 0) return null;
    return .{ .find = request.find, .replace = replace };
}

fn confirmedDeletePath(query: []const u8) ?[]const u8 {
    const request = pathMutationRequest(query) orelse return null;
    if (!std.mem.eql(u8, request.replace, "DELETE")) return null;
    return request.find;
}

fn isValidIdentifierName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
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
    const sidebar_width = if (state.show_file_tree) @min(@max(@divTrunc(width, 4), 280), 380) else 0;
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

fn saveAllButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 1);
}

fn runButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 2);
}

fn testButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 3);
}

fn buildButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 4);
}

fn taskButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 5);
}

fn diagButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 6);
}

fn secButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 7);
}

fn symbolButtonRect(layout: Layout) RECT {
    return toolbarButtonRect(layout, 8);
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

fn outputApplyButtonRect(rect: RECT) RECT {
    return .{
        .left = @max(rect.left + 110, rect.right - 94),
        .top = rect.top + 7,
        .right = rect.right - 14,
        .bottom = rect.top + 31,
    };
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

fn securityPanelVisibleRows(rect: RECT) usize {
    return @as(usize, @intCast(@max(0, @divTrunc(rect.bottom - rect.top - HEADER_HEIGHT - ROW_HEIGHT, ROW_HEIGHT))));
}

fn securityPanelFindingRowAt(rect: RECT, y: c_int) ?usize {
    const top = rect.top + HEADER_HEIGHT + ROW_HEIGHT;
    if (y < top or y >= rect.bottom) return null;
    return @as(usize, @intCast(@divTrunc(y - top, ROW_HEIGHT)));
}

fn bottomPanelTabRect(rect: RECT, panel: BottomPanel) RECT {
    const panel_count: c_int = 10;
    const rect_width = @max(rect.right - rect.left, panel_count);
    const margin: c_int = if (rect_width >= 160) 8 else 0;
    const gap: c_int = if (rect_width >= 400) 4 else 0;
    const available = @max(rect_width - margin * 2 - gap * (panel_count - 1), panel_count);
    const width: c_int = @max(1, @min(82, @divTrunc(available, panel_count)));
    const index: c_int = switch (panel) {
        .output => 0,
        .debug => 1,
        .git => 2,
        .extensions => 3,
        .diagnostics => 4,
        .security => 5,
        .settings => 6,
        .keybindings => 7,
        .tutorial => 8,
        .publish => 9,
    };
    const left = rect.left + margin + index * (width + gap);
    return .{ .left = left, .top = rect.top + 9, .right = left + width, .bottom = rect.top + 33 };
}

fn bottomPanelTabAt(rect: RECT, x: c_int, y: c_int) ?BottomPanel {
    if (y < rect.top or y >= rect.top + HEADER_HEIGHT) return null;
    const panels = [_]BottomPanel{ .output, .debug, .git, .extensions, .diagnostics, .security, .settings, .keybindings, .tutorial, .publish };
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

fn quickPanelApplyButtonRect(panel: RECT) RECT {
    return .{
        .left = panel.right - 92,
        .top = panel.top + 7,
        .right = panel.right - 14,
        .bottom = panel.top + 33,
    };
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

fn isEditorLineCommand(id: []const u8) bool {
    return std.mem.eql(u8, id, "editor.delete_line") or
        std.mem.eql(u8, id, "editor.indent") or
        std.mem.eql(u8, id, "editor.outdent") or
        std.mem.eql(u8, id, "editor.duplicate_line") or
        std.mem.eql(u8, id, "editor.move_line_up") or
        std.mem.eql(u8, id, "editor.move_line_down");
}

fn securityFindingSelectionEnd(doc: *const document_mod.Document, finding: *const findings_mod.Finding, offset: usize) usize {
    if (offset >= doc.text.bytes.len) return offset;
    if (finding.category == .text_integrity) {
        if (text_integrity.hiddenControlLengthAt(doc.text.bytes, offset)) |len| {
            return @min(offset + len, doc.text.bytes.len);
        }
        if (doc.text.bytes[offset] == '\r') {
            if (offset + 1 < doc.text.bytes.len and doc.text.bytes[offset + 1] == '\n') return offset + 2;
            return offset + 1;
        }
        if (doc.text.bytes[offset] == '\n') return offset + 1;
    }
    return doc.text.nextByteOffset(offset) catch offset;
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

fn setClipboardUtf8(hwnd: ?windows.HWND, text: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, text);
    defer std.heap.page_allocator.free(wide);

    const bytes = (wide.len + 1) * @sizeOf(u16);
    const handle = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return error.ClipboardAllocationFailed;
    errdefer _ = GlobalFree(handle);

    const locked = GlobalLock(handle) orelse return error.ClipboardLockFailed;
    const target: [*]u16 = @ptrCast(@alignCast(locked));
    @memcpy(target[0 .. wide.len + 1], wide.ptr[0 .. wide.len + 1]);
    _ = GlobalUnlock(handle);

    if (OpenClipboard(hwnd) == .FALSE) return error.ClipboardOpenFailed;
    defer _ = CloseClipboard();

    if (EmptyClipboard() == .FALSE) return error.ClipboardClearFailed;
    if (SetClipboardData(CF_UNICODETEXT, handle) == null) return error.ClipboardSetFailed;
}

fn getClipboardUtf8(allocator: std.mem.Allocator, hwnd: ?windows.HWND) ![]u8 {
    if (IsClipboardFormatAvailable(CF_UNICODETEXT) == .FALSE) return error.NoClipboardText;
    if (OpenClipboard(hwnd) == .FALSE) return error.ClipboardOpenFailed;
    defer _ = CloseClipboard();

    const handle = GetClipboardData(CF_UNICODETEXT) orelse return error.NoClipboardText;
    const locked = GlobalLock(handle) orelse return error.ClipboardLockFailed;
    defer _ = GlobalUnlock(handle);

    const wide_z: [*:0]const u16 = @ptrCast(@alignCast(locked));
    return try std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(wide_z));
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

const BoundaryCounts = struct {
    workspace: usize = 0,
    memory: usize = 0,
    execution: usize = 0,
    filesystem: usize = 0,
    network: usize = 0,
    dependency: usize = 0,
    secret: usize = 0,
    text: usize = 0,
    path: usize = 0,
    git: usize = 0,
    output: usize = 0,
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

fn boundaryCounts(collection: *const findings_mod.Collection) BoundaryCounts {
    var counts = BoundaryCounts{};
    for (collection.items.items) |item| {
        switch (findings_mod.boundaryFor(item.category)) {
            .workspace => counts.workspace += 1,
            .memory => counts.memory += 1,
            .execution => counts.execution += 1,
            .filesystem => counts.filesystem += 1,
            .network => counts.network += 1,
            .dependency => counts.dependency += 1,
            .secret => counts.secret += 1,
            .text => counts.text += 1,
            .path => counts.path += 1,
            .git => counts.git += 1,
            .output => counts.output += 1,
        }
    }
    return counts;
}

fn currentDocumentRiskCounts(state: *GuiState) RiskCounts {
    const doc = state.app.documents.active() orelse return .{};
    const path = doc.path orelse return .{};
    return pathRiskCounts(state, path);
}

fn currentLineBoundaryHint(state: *GuiState, buffer: []u8) []const u8 {
    const doc = state.app.documents.active() orelse return "clear";
    const path = doc.path orelse return "clear";
    const line = doc.cursor.position.line;

    var best_risk: ?findings_mod.Risk = null;
    var best_boundary: ?findings_mod.Boundary = null;
    for (state.app.security_findings.items.items) |item| {
        if (item.line != line) continue;
        if (!pathMatches(path, item.path)) continue;
        if (best_risk == null or riskRank(item.risk) > riskRank(best_risk.?)) {
            best_risk = item.risk;
            best_boundary = findings_mod.boundaryFor(item.category);
        }
    }

    const risk = best_risk orelse return "clear";
    const boundary = best_boundary orelse return @tagName(risk);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ @tagName(risk), findings_mod.boundaryLabel(boundary) }) catch "hot";
}

fn tutorialLines(language: TutorialLanguage) []const []const u8 {
    return switch (language) {
        .ja => &.{
            "== はじめに ==",
            "F1 でこのチュートリアルを開きます。Ctrl+Shift+P でコマンド、Ctrl+O でワークスペースを開きます。",
            "左のファイルをクリックして開きます。編集はinsertモードで行い、Ctrl+Sでatomic saveします。",
            "Ctrl+F はファイル内検索、Ctrl+H はファイル内置換、Ctrl+Shift+F はワークスペース検索です。",
            "F12 はZigのローカル定義へ移動、Shift+F12 は参照検索、F2 は安全なリネームpreviewです。",
            "Ctrl+Shift+L はSHIPパネルです。公開前の配布、信頼、パッケージ化の抜けを確認します。",
            "",
            "== 安全にコードを動かす ==",
            "build/test/run/task は、trust policy と明示的なconsentを通ります。",
            "フォルダを開くだけでは、hook、build script、package script、Git filterは実行されません。",
            "出力はパネルに捕捉され、sanitized textからdiagnosticsが抽出されます。",
            "",
            "== セキュリティの流れ ==",
            "SECを開いてAUDITを押すと、ワークスペース全体の静的監査を走らせます。",
            "SCANは現在ファイルだけを監査します。LF/CRLFは改行正規化、CLEANはNUL/Bidi制御文字除去です。",
            "security findingをクリックすると、ZIDEが特定できる場合は危険なbyte範囲を選択します。",
            "SEC上部のBOUNDARY行は、mem/exec/fs/net/deps/secret/text/path/gitのどの境界が濃いかを示します。",
            "怪しいワークスペースではLOCKを押します。writesとexecutionがpolicyでブロックされます。",
            "",
            "セキュリティ差分: byte-first editor",
            "ZIDEはraw bytesを保持し、UTF-8妥当性とLF/CRLF/MIXED状態をstatus barへ出します。",
            "NUL、invalid UTF-8、Bidi制御文字、mixed endingsを外部コマンドなしで検査します。",
            "ファイル名も監査します: report.pdf.exe、.env、id_rsa、Windows予約名、hidden scriptを検出します。",
            "Zigの境界性をSECへ落とし込み、memory/execution/filesystem/networkの交差点としてfindingを読めます。",
            "",
            "セキュリティ差分: trust before execution",
            "commandはsafe/workspace_write/network_read/network_write/external_commandへ分類されます。",
            "untrusted workspaceは読めて編集できますが、外部実行とnetwork writeは止めます。",
            "critical findingはlocked_downへ、high findingはtrusted workspaceをparanoid寄りへ押し戻します。",
            "",
            "セキュリティ差分: Git without hook execution",
            "Git panelはgit statusを実行せず、repository metadataをZigで直接読みます。",
            "hook、filter、fsmonitor、alias、Git設定経由のcommand executionを避けるためです。",
            "",
            "セキュリティ差分: Zig-native scanner core",
            "build.zig、build.zig.zon、CI、IaC、script、env、polyglot package edgeをZigで監査します。",
            "最初の安全確認を外部parserに委ねず、IDE自身の小さな監査coreで持ちます。",
            "",
            "今すぐ試す",
            "1. SECを押してAUDITを実行します。",
            "2. findingをクリックして該当箇所へ移動します。",
            "3. text-integrity findingがあればCLEANまたはLF/CRLFで修復します。",
            "4. LOCKを押して、trust postureがlocked_downへ入る様子を見ます。",
            "5. SHIPを押して、最初の公開に必要な成果物と信頼パッケージを確認します。",
        },
        .en => &.{
            "== QUICK START ==",
            "F1 opens this tutorial. Ctrl+Shift+P opens commands. Ctrl+O opens a workspace folder.",
            "Click files on the left. Edit in insert mode. Ctrl+S saves with atomic write.",
            "Ctrl+F finds in the file. Ctrl+H replaces in the file. Ctrl+Shift+F searches the workspace.",
            "F12 jumps to definition. Ctrl+F12 jumps to implementation. Ctrl+Alt+F12 jumps to type definition. Shift+F12 finds references.",
            "Ctrl+Shift+L opens SHIP, the release, trust, and packaging checklist.",
            "",
            "== RUNNING CODE SAFELY ==",
            "Build, test, run, and task execution go through consent and trust policy.",
            "Opening a folder never executes hooks, build scripts, package scripts, or Git filters.",
            "Output is captured into the panel and diagnostics are parsed from sanitized text.",
            "",
            "== SECURITY WORKFLOW ==",
            "Open SEC. Press AUDIT for workspace static review. Press SCAN for the current file.",
            "Use LF/CRLF to normalize line endings. Use CLEAN to remove NUL and bidi control markers.",
            "Click a security finding to jump to the exact byte range when ZIDE can identify it.",
            "The BOUNDARY line shows which lanes are hot: mem/exec/fs/net/deps/secret/text/path/git.",
            "Press LOCK when a workspace feels suspicious; writes and execution are blocked by policy.",
            "",
            "SECURITY DIFFERENCE: byte-first editor",
            "ZIDE preserves raw bytes and shows UTF-8 validity plus LF/CRLF/MIXED state in the status bar.",
            "Hidden text hazards are scanned without shelling out: NUL, invalid UTF-8, bidi controls, mixed endings.",
            "File names are audited too: report.pdf.exe, .env, id_rsa, Windows reserved names, hidden scripts.",
            "Zig boundary thinking is surfaced as memory/execution/filesystem/network crossing points in SEC.",
            "",
            "SECURITY DIFFERENCE: trust before execution",
            "Commands are classified as safe, workspace_write, network_read, network_write, or external_command.",
            "Untrusted workspaces can be read and edited, but external execution and network writes are blocked.",
            "Critical findings force locked_down posture; high findings can push trusted workspaces into paranoid mode.",
            "",
            "SECURITY DIFFERENCE: Git without hook execution",
            "The Git panel reads repository metadata directly instead of running git status.",
            "This avoids hooks, filters, fsmonitor, aliases, and configured Git-side command execution.",
            "Press REF to refresh, STAT to audit Git metadata, and DIFF or Ctrl+Shift+G for a pure Zig diff preview.",
            "Clicking a changed file in GIT opens it and renders a compact diff preview in OUTPUT.",
            "",
            "SECURITY DIFFERENCE: extensions without implicit execution",
            "Open EXT or press Ctrl+Shift+X to scan zide-extension.json and zide.extension.json manifests.",
            "ZIDE shows capabilities and risk before any extension code can run.",
            "",
            "SECURITY DIFFERENCE: Zig-native scanner core",
            "Build.zig, build.zig.zon, CI files, IaC, scripts, env files, and polyglot package edges are scanned in Zig.",
            "No external parser is trusted for the security baseline. The IDE owns the first-pass audit.",
            "",
            "TRY THIS NOW",
            "1. Press SEC then AUDIT.",
            "2. Click a finding to jump to it.",
            "3. Press CLEAN or LF/CRLF when text-integrity findings appear.",
            "4. Press LOCK to see the workspace enter locked_down trust posture.",
            "5. Press SHIP to check first-release assets and the trust package.",
        },
    };
}

fn tutorialLineCount(language: TutorialLanguage) usize {
    return tutorialLines(language).len;
}

fn publishLines() []const []const u8 {
    return &.{
        "== FIRST PUBLIC RELEASE ==",
        "[ship] GitHub Releases: publish a draft first, attach zide-windows-x86_64.zip and a short demo clip.",
        "[ship] Press ZIP after builds to create zide-windows-x86_64.zip with pure Zig archive writing.",
        "[ship] Press VFY before upload to verify ZIP paths, central directory, CRC32, and embedded checksums.",
        "[ship] Press GATE for the final local publish decision: docs, git state, artifacts, verification, and hashes.",
        "[hash] Press HASH after builds to render size and SHA-256 for GitHub Releases, winget, and Scoop.",
        "[ship] Press MANI to render GitHub Release, winget, and Scoop draft manifests; ZIP is preferred when present.",
        "[ship] Mark the first tag as prerelease until outside users exercise edit/save/git/security flows.",
        "[ship] Make the promise obvious: secure Zig-native workbench, hook-free Git, visible capability boundaries.",
        "[ship] Keep README human-written. Let this panel carry the mechanical checklist.",
        "",
        "== TRUST PACKAGE ==",
        "[ship] Include docs/security.md in the release links.",
        "[ship] Show checksums next to binaries.",
        "[ship] Mention that EXT scans manifests but does not execute extension code.",
        "[ship] Mention that GIT reads metadata without running git status, hooks, filters, or fsmonitor.",
        "",
        "== DISTRIBUTION LADDER ==",
        "[ship] Phase 1: GitHub release zip for Windows x86_64.",
        "[later] Phase 2: Scoop manifest for power users who want quick install/update.",
        "[later] Phase 3: winget manifest once the installer/portable story and hashes are stable.",
        "[later] Phase 4: signed binaries and update channel.",
        "",
        "== COMMUNITY LOOP ==",
        "[ship] Ask for security false-positive reports as a first-class issue type.",
        "[ship] Ask users for screenshots of their workflow; ZIDE is visual and trust-oriented.",
        "[ship] Keep a 60-second demo focused on opening a scary repo, seeing boundaries, and safe Git diff.",
        "[avoid] Do not lead with a giant feature matrix. Lead with the trust workflow.",
    };
}

fn publishLineCount() usize {
    return publishLines().len;
}

fn workspaceHasAnyLicense(app: *const app_mod.App) bool {
    return workspaceHasPathGui(app, "LICENSE") or workspaceHasPathGui(app, "LICENSE.md") or workspaceHasPathGui(app, "COPYING");
}

fn workspaceHasPathGui(app: *const app_mod.App, relative: []const u8) bool {
    for (app.workspace.entries.items) |entry| {
        if (pathEqualIgnoreCaseAndSlashGui(entry.path, relative)) return true;
    }
    return false;
}

fn workspaceHasPrefixGui(app: *const app_mod.App, prefix: []const u8) bool {
    for (app.workspace.entries.items) |entry| {
        if (pathStartsWithIgnoreCaseAndSlashGui(entry.path, prefix)) return true;
    }
    return false;
}

fn pathEqualIgnoreCaseAndSlashGui(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (normalizePathByteGui(left) != normalizePathByteGui(right)) return false;
    }
    return true;
}

fn pathStartsWithIgnoreCaseAndSlashGui(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return pathEqualIgnoreCaseAndSlashGui(value[0..prefix.len], prefix);
}

fn normalizePathByteGui(byte: u8) u8 {
    return if (byte == '\\') '/' else std.ascii.toLower(byte);
}

fn commentToggleMessage(result: document_mod.CommentToggleResult) []const u8 {
    return switch (result) {
        .line_commented => "Commented lines",
        .line_uncommented => "Uncommented lines",
        .block_commented => "Commented block",
        .block_uncommented => "Uncommented block",
    };
}

fn workspaceFileExistsGui(app: *const app_mod.App, relative: []const u8) bool {
    const path = std.fs.path.join(app.allocator, &.{ app.workspace.root_path, relative }) catch return false;
    defer app.allocator.free(path);
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

fn workflowRiskCounts(state: *GuiState, overview: git_repository.Overview) RiskCounts {
    var counts = RiskCounts{};
    for (overview.workflow_paths) |path| {
        addRiskCounts(&counts, pathRiskCounts(state, path));
    }
    return counts;
}

fn pathRiskCounts(state: *const GuiState, path: []const u8) RiskCounts {
    var counts = RiskCounts{};
    for (state.app.security_findings.items.items) |item| {
        if (!pathMatches(path, item.path)) continue;
        addRisk(&counts, item.risk);
    }
    return counts;
}

fn addRisk(counts: *RiskCounts, risk: findings_mod.Risk) void {
    switch (risk) {
        .info => counts.info += 1,
        .low => counts.low += 1,
        .medium => counts.medium += 1,
        .high => counts.high += 1,
        .critical => counts.critical += 1,
    }
}

fn addRiskCounts(counts: *RiskCounts, other: RiskCounts) void {
    counts.info += other.info;
    counts.low += other.low;
    counts.medium += other.medium;
    counts.high += other.high;
    counts.critical += other.critical;
}

fn highestRisk(counts: RiskCounts) ?findings_mod.Risk {
    if (counts.critical > 0) return .critical;
    if (counts.high > 0) return .high;
    if (counts.medium > 0) return .medium;
    if (counts.low > 0) return .low;
    if (counts.info > 0) return .info;
    return null;
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
const TIMERPROC = ?*const fn (windows.HWND, windows.UINT, WPARAM, windows.DWORD) callconv(.winapi) void;

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
const HGLOBAL = *anyopaque;
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
const SW_SHOWNORMAL: c_int = 1;
const TRANSPARENT: c_int = 1;
const WS_OVERLAPPEDWINDOW: windows.DWORD = 0x00CF0000;
const FW_NORMAL: c_int = 400;
const DEFAULT_CHARSET: windows.DWORD = 1;
const OUT_DEFAULT_PRECIS: windows.DWORD = 0;
const CLIP_DEFAULT_PRECIS: windows.DWORD = 0;
const CLEARTYPE_QUALITY: windows.DWORD = 5;
const FIXED_PITCH: windows.DWORD = 0x01;
const FF_MODERN: windows.DWORD = 0x30;
const GMEM_MOVEABLE: windows.UINT = 0x0002;
const CF_UNICODETEXT: windows.UINT = 13;

const WM_DESTROY: windows.UINT = 0x0002;
const WM_SIZE: windows.UINT = 0x0005;
const WM_PAINT: windows.UINT = 0x000F;
const WM_TIMER: windows.UINT = 0x0113;
const WM_KEYDOWN: windows.UINT = 0x0100;
const WM_CHAR: windows.UINT = 0x0102;
const WM_LBUTTONDOWN: windows.UINT = 0x0201;
const WM_LBUTTONUP: windows.UINT = 0x0202;
const WM_MOUSEMOVE: windows.UINT = 0x0200;
const WM_MOUSEWHEEL: windows.UINT = 0x020A;
const VK_BACK: WPARAM = 0x08;
const VK_TAB: WPARAM = 0x09;
const VK_RETURN: WPARAM = 0x0D;
const VK_SHIFT: c_int = 0x10;
const VK_CONTROL: c_int = 0x11;
const VK_MENU: c_int = 0x12;
const VK_ESCAPE: WPARAM = 0x1B;
const VK_SPACE: WPARAM = 0x20;
const VK_OEM_PERIOD: WPARAM = 0xBE;
const VK_OEM_COMMA: WPARAM = 0xBC;
const VK_OEM_2: WPARAM = 0xBF;
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
const VK_F2: WPARAM = 0x71;
const VK_F3: WPARAM = 0x72;
const VK_F5: WPARAM = 0x74;
const VK_F6: WPARAM = 0x75;
const VK_F7: WPARAM = 0x76;
const VK_F8: WPARAM = 0x77;
const VK_F9: WPARAM = 0x78;
const VK_F10: WPARAM = 0x79;
const VK_F11: WPARAM = 0x7A;
const VK_F12: WPARAM = 0x7B;
const LSP_PUMP_TIMER_ID: WPARAM = 29;

extern "kernel32" fn GetModuleHandleW(lpModuleName: ?windows.LPCWSTR) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GlobalAlloc(uFlags: windows.UINT, dwBytes: usize) callconv(.winapi) ?HGLOBAL;
extern "kernel32" fn GlobalLock(hMem: HGLOBAL) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: HGLOBAL) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GlobalFree(hMem: HGLOBAL) callconv(.winapi) ?HGLOBAL;

extern "shell32" fn ShellExecuteW(
    hwnd: ?windows.HWND,
    lpOperation: ?windows.LPCWSTR,
    lpFile: windows.LPCWSTR,
    lpParameters: ?windows.LPCWSTR,
    lpDirectory: ?windows.LPCWSTR,
    nShowCmd: c_int,
) callconv(.winapi) windows.HINSTANCE;

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
extern "user32" fn SetCapture(hWnd: windows.HWND) callconv(.winapi) ?windows.HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) windows.BOOL;
extern "user32" fn GetKeyState(nVirtKey: c_int) callconv(.winapi) c_short;
extern "user32" fn OpenClipboard(hWndNewOwner: ?windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn SetClipboardData(uFormat: windows.UINT, hMem: HGLOBAL) callconv(.winapi) ?HGLOBAL;
extern "user32" fn GetClipboardData(uFormat: windows.UINT) callconv(.winapi) ?HGLOBAL;
extern "user32" fn IsClipboardFormatAvailable(format: windows.UINT) callconv(.winapi) windows.BOOL;
extern "user32" fn ShowWindow(hWnd: windows.HWND, nCmdShow: c_int) callconv(.winapi) windows.BOOL;
extern "user32" fn UpdateWindow(hWnd: windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?windows.HWND, wMsgFilterMin: windows.UINT, wMsgFilterMax: windows.UINT) callconv(.winapi) windows.BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) windows.BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
extern "user32" fn SetTimer(hWnd: windows.HWND, nIDEvent: WPARAM, uElapse: windows.UINT, lpTimerFunc: TIMERPROC) callconv(.winapi) WPARAM;
extern "user32" fn KillTimer(hWnd: windows.HWND, uIDEvent: WPARAM) callconv(.winapi) windows.BOOL;
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
