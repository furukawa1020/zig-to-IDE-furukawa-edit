const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const app_mod = @import("../core/app.zig");
const command_mod = @import("../core/command.zig");
const dispatcher = @import("../core/dispatcher.zig");
const navigation = @import("../editor/navigation.zig");
const console_mod = @import("../tasks/console.zig");

pub fn run(allocator: std.mem.Allocator, root_path: []const u8) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    var state = try GuiState.init(allocator, root_path);
    defer state.deinit();
    global_state = &state;
    defer global_state = null;

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
    last_error: ?[]u8 = null,
    collapsed_dirs: []bool,
    editor_scroll_line: usize = 0,
    output_scroll_line: usize = 0,
    show_output: bool = true,

    fn init(allocator: std.mem.Allocator, root_path: []const u8) !GuiState {
        var app = try app_mod.App.init(allocator, root_path);
        errdefer app.deinit();

        const collapsed_dirs = try allocator.alloc(bool, app.workspace.entries.items.len);
        @memset(collapsed_dirs, false);

        return .{
            .allocator = allocator,
            .app = app,
            .collapsed_dirs = collapsed_dirs,
        };
    }

    fn deinit(self: *GuiState) void {
        if (self.last_error) |message| self.allocator.free(message);
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

    fn executeCommand(self: *GuiState, id: []const u8) void {
        const result = dispatcher.dispatch(&self.app, .{ .id = id, .source = .command_palette }) catch |err| {
            self.setError(err) catch {};
            self.appendOutput(.stderr, "command failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult(id, result);
        self.show_output = true;
    }

    fn handleDispatchResult(self: *GuiState, id: []const u8, result: dispatcher.Result) void {
        switch (result) {
            .completed => |message| {
                self.setMessage(message) catch {};
                self.appendOutput(.stdout, "{s}: {s}\n", .{ id, message });
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
                self.setMessage("External command needs explicit approval") catch {};
                const cwd = spec.command.cwd orelse self.app.workspace.root_path;
                self.appendOutput(.stdout, "external command: {s}\n", .{spec.command.executable});
                self.appendOutput(.stdout, "cwd: {s}\n", .{cwd});
                self.appendOutput(.stdout, "Use consent commands before running external tools.\n", .{});
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

        if (pointIn(layout.sidebar, x, y)) {
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
            self.setEditorCursorFromPoint(layout, x, y);
            return;
        }

        if (pointIn(layout.output, x, y)) {
            self.app.focus = .output;
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
                    state.scrollOutput(if (delta > 0) -3 else 3);
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
    if (key == VK_F1) {
        state.openPalette();
        return;
    }
    if (ctrl and key == 'S') {
        state.executeCommand("file.save");
        return;
    }
    if (ctrl and key == 'B') {
        state.executeCommand("zig.build");
        return;
    }
    if (ctrl and key == 'T') {
        state.executeCommand("zig.test");
        return;
    }
    if (ctrl and key == 'R') {
        state.executeCommand("task.run_next");
        return;
    }
    if (ctrl and key == 'O') {
        state.app.focus = .files;
        state.setMessage("File tree focused") catch {};
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
        drawFileList(hdc, state, layout);
        drawEditor(hdc, state, layout);
        if (state.show_output) drawOutput(hdc, state, layout);
        drawStatus(hdc, state, layout.status);
        if (state.app.palette.visible) drawCommandPalette(hdc, state, layout.client);
    } else {
        drawText(hdc, 24, 24, rgb(235, 238, 242), "zide");
    }
}

fn drawFileList(hdc: windows.HDC, state: *GuiState, layout: Layout) void {
    const visible_rows = @max(0, @divTrunc(layout.sidebar.bottom - HEADER_HEIGHT - 10, ROW_HEIGHT));
    const visible_count = state.visibleEntryCount();
    const selected_rank = state.visibleRankOfIndex(state.app.file_cursor) orelse 0;
    const start = scrollStart(selected_rank, visible_count, @intCast(visible_rows));

    var y = HEADER_HEIGHT;
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
            .file => if (entry.language == .zig) rgb(63, 217, 84) else rgb(205, 211, 217),
            .other => rgb(121, 133, 145),
        };

        drawText(hdc, 16 + indent, y + 3, color, marker);
        drawTextClipped(hdc, 36 + indent, y + 3, layout.sidebar.right - 12, color, entry.path);
        y += ROW_HEIGHT;
    }

    if (state.app.workspace.entries.items.len == 0) {
        drawText(hdc, 18, HEADER_HEIGHT + 4, rgb(140, 148, 158), "No files found");
    }
}

fn drawEditor(hdc: windows.HDC, state: *GuiState, layout: Layout) void {
    const editor = layout.editor;
    const active = state.app.documents.active();
    if (active) |doc| {
        const title = doc.path orelse "untitled";
        drawTextClipped(hdc, editor.left + 20, 15, editor.right - 24, rgb(79, 230, 226), title);
        if (doc.dirty) drawText(hdc, editor.right - 72, 15, rgb(255, 207, 92), "dirty");
        fillRect(hdc, RECT{ .left = editor.left, .top = HEADER_HEIGHT, .right = editor.left + GUTTER_WIDTH, .bottom = editor.bottom }, rgb(14, 18, 23));

        const max_rows = @max(0, @divTrunc(editor.bottom - HEADER_HEIGHT - 8, ROW_HEIGHT));
        var visible_line: usize = 0;
        var y = HEADER_HEIGHT + EDITOR_TEXT_PADDING_Y;
        while (visible_line < @as(usize, @intCast(max_rows)) and state.editor_scroll_line + visible_line < doc.text.lineCount()) : (visible_line += 1) {
            const line = state.editor_scroll_line + visible_line;
            var number_buf: [32]u8 = undefined;
            const number = std.fmt.bufPrint(&number_buf, "{d}", .{line + 1}) catch "";
            const current_line = line == doc.cursor.position.line;
            if (current_line) {
                fillRect(hdc, RECT{ .left = editor.left + GUTTER_WIDTH, .top = y - 2, .right = editor.right, .bottom = y + ROW_HEIGHT - 2 }, rgb(20, 27, 34));
            }
            drawTextRight(hdc, editor.left + 10, y, editor.left + GUTTER_WIDTH - 12, rgb(105, 116, 128), number);
            drawTextClipped(hdc, editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X, y, editor.right - 20, rgb(224, 229, 235), doc.text.lineSlice(line));
            if (current_line) {
                const caret_x = editor.left + GUTTER_WIDTH + EDITOR_TEXT_PADDING_X + @as(c_int, @intCast(doc.cursor.position.column)) * CHAR_WIDTH;
                fillRect(hdc, RECT{ .left = caret_x, .top = y - 2, .right = caret_x + 2, .bottom = y + ROW_HEIGHT - 4 }, rgb(255, 255, 255));
            }
            y += ROW_HEIGHT;
        }
    } else {
        drawText(hdc, editor.left + 22, 15, rgb(79, 230, 226), "zide workbench");
        drawText(hdc, editor.left + 22, HEADER_HEIGHT + 10, rgb(199, 206, 214), "Click a file to open it.");
        drawText(hdc, editor.left + 22, HEADER_HEIGHT + 38, rgb(126, 138, 150), "F1 opens commands. Ctrl+S saves. Ctrl+B prepares build.");
    }
}

fn drawOutput(hdc: windows.HDC, state: *GuiState, layout: Layout) void {
    fillRect(hdc, RECT{ .left = layout.output.left, .top = layout.output.top, .right = layout.output.right, .bottom = layout.output.top + 1 }, rgb(43, 53, 61));
    drawText(hdc, layout.output.left + 16, layout.output.top + 10, rgb(79, 230, 226), "OUTPUT");

    const lines = state.app.process_console.lines.items;
    const rows = @max(0, @divTrunc(layout.output.bottom - layout.output.top - HEADER_HEIGHT, ROW_HEIGHT));
    const max_start = if (lines.len > @as(usize, @intCast(rows))) lines.len - @as(usize, @intCast(rows)) else 0;
    const start = @min(state.output_scroll_line, max_start);
    var y = layout.output.top + HEADER_HEIGHT;
    var row: usize = 0;
    while (row < @as(usize, @intCast(rows)) and start + row < lines.len) : (row += 1) {
        const line = lines[start + row];
        const color = switch (line.stream) {
            .stdout => rgb(200, 207, 216),
            .stderr => rgb(255, 125, 125),
        };
        drawTextClipped(hdc, layout.output.left + 16, y, layout.output.right - 16, color, line.text);
        y += ROW_HEIGHT;
    }

    if (lines.len == 0) {
        drawText(hdc, layout.output.left + 16, layout.output.top + HEADER_HEIGHT, rgb(116, 128, 140), "No output yet");
    }
}

fn drawCommandPalette(hdc: windows.HDC, state: *GuiState, client: RECT) void {
    const width = @min(@max(client.right - client.left - 220, 420), 760);
    const left = client.left + @divTrunc((client.right - client.left) - width, 2);
    const top: c_int = 70;
    const palette = RECT{ .left = left, .top = top, .right = left + width, .bottom = top + 360 };
    fillRect(hdc, palette, rgb(22, 26, 31));
    fillRect(hdc, RECT{ .left = palette.left, .top = palette.top, .right = palette.right, .bottom = palette.top + 1 }, rgb(79, 230, 226));
    drawText(hdc, palette.left + 16, palette.top + 14, rgb(79, 230, 226), "COMMAND");
    drawTextClipped(hdc, palette.left + 16, palette.top + 44, palette.right - 16, rgb(235, 239, 244), state.app.palette.query.items);

    var y = palette.top + 78;
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

fn drawStatus(hdc: windows.HDC, state: *GuiState, status: RECT) void {
    var buffer: [512]u8 = undefined;
    const mode = @tagName(state.app.mode);
    const focus = @tagName(state.app.focus);
    const message = state.last_error orelse "ready";
    const cursor = if (state.app.documents.active()) |doc| doc.cursor.position else null;
    const dirty = if (state.app.documents.active()) |doc| doc.dirty else false;
    const text = std.fmt.bufPrint(
        &buffer,
        " {s}/{s}  |  line:{d} col:{d} {s} | files:{d} docs:{d} zig:{d} output:{s} | {s}",
        .{
            mode,
            focus,
            if (cursor) |position| position.line + 1 else 0,
            if (cursor) |position| position.column + 1 else 0,
            if (dirty) "dirty" else "clean",
            state.app.workspace.entries.items.len,
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
    if (y < HEADER_HEIGHT or y >= layout.sidebar.bottom) return null;
    const visible_rows = @max(0, @divTrunc(layout.sidebar.bottom - HEADER_HEIGHT - 10, ROW_HEIGHT));
    const visible_count = state.visibleEntryCount();
    const selected_rank = state.visibleRankOfIndex(state.app.file_cursor) orelse 0;
    const start = scrollStart(selected_rank, visible_count, @intCast(visible_rows));
    const row = @as(usize, @intCast(@divTrunc(y - HEADER_HEIGHT, ROW_HEIGHT)));
    if (row >= @as(usize, @intCast(visible_rows))) return null;
    if (start + row >= visible_count) return null;
    return start + row;
}

fn pointIn(rect: RECT, x: c_int, y: c_int) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
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

fn isKeyDown(vk: c_int) bool {
    return (@as(u16, @bitCast(GetKeyState(vk))) & 0x8000) != 0;
}

fn drawText(hdc: windows.HDC, x: c_int, y: c_int, color: windows.COLORREF, text: []const u8) void {
    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetTextColor(hdc, color);
    if (text.len == 0) return;
    _ = TextOutA(hdc, x, y, text.ptr, @intCast(text.len));
}

fn drawTextClipped(hdc: windows.HDC, x: c_int, y: c_int, right: c_int, color: windows.COLORREF, text: []const u8) void {
    if (right <= x) return;
    const available_columns: usize = @intCast(@max(@divTrunc(right - x, 8), 1));
    const clipped = if (text.len > available_columns) text[0..available_columns] else text;
    drawText(hdc, x, y, color, clipped);
}

fn drawTextRight(hdc: windows.HDC, left: c_int, y: c_int, right: c_int, color: windows.COLORREF, text: []const u8) void {
    const width: c_int = @intCast(text.len * 8);
    drawText(hdc, @max(left, right - width), y, color, text);
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

const HGDIOBJ = *opaque {};
const WPARAM = windows.ULONG_PTR;
const LRESULT = windows.LONG_PTR;

const STATUS_HEIGHT: c_int = 30;
const HEADER_HEIGHT: c_int = 42;
const GUTTER_WIDTH: c_int = 58;
const ROW_HEIGHT: c_int = 22;
const CHAR_WIDTH: c_int = 8;
const EDITOR_TEXT_PADDING_X: c_int = 16;
const EDITOR_TEXT_PADDING_Y: c_int = 7;

const CS_HREDRAW: windows.UINT = 0x0002;
const CS_VREDRAW: windows.UINT = 0x0001;
const CW_USEDEFAULT: c_int = -2147483648;
const IDC_ARROW: windows.LPCWSTR = @ptrFromInt(32512);
const SW_SHOW: c_int = 5;
const TRANSPARENT: c_int = 1;
const WS_OVERLAPPEDWINDOW: windows.DWORD = 0x00CF0000;

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

extern "gdi32" fn SetTextColor(hdc: windows.HDC, crColor: windows.COLORREF) callconv(.winapi) windows.COLORREF;
extern "gdi32" fn SetBkMode(hdc: windows.HDC, mode: c_int) callconv(.winapi) c_int;
extern "gdi32" fn TextOutA(hdc: windows.HDC, x: c_int, y: c_int, lpString: [*]const u8, c: c_int) callconv(.winapi) windows.BOOL;
extern "gdi32" fn CreateSolidBrush(color: windows.COLORREF) callconv(.winapi) ?windows.HBRUSH;
extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(.winapi) windows.BOOL;
