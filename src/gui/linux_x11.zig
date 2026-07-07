const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const app_mod = @import("../core/app.zig");
const build_consent = @import("../security/build_consent.zig");
const dispatcher = @import("../core/dispatcher.zig");
const event_mod = @import("../core/event.zig");
const input_handler = @import("../core/input_handler.zig");
const navigation = @import("../editor/navigation.zig");
const modes = @import("../language/modes.zig");
const findings_mod = @import("../security/findings.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("linux_x11.zig is Linux-only");
}

const WIDTH = 1280;
const HEIGHT = 820;
const FILE_WIDTH = 330;
const HEADER_HEIGHT = 58;
const STATUS_HEIGHT = 28;
const OUTPUT_HEIGHT = 210;
const LINE_HEIGHT = 19;
const EDITOR_LEFT = FILE_WIDTH + 24;
const EDITOR_TOP = HEADER_HEIGHT + 58;
const EDITOR_TEXT_TOP = EDITOR_TOP + 44;
const BOTTOM_TOP = HEIGHT - OUTPUT_HEIGHT - STATUS_HEIGHT;

const X = struct {
    const EventMask = struct {
        const key_press: u32 = 1 << 0;
        const button_press: u32 = 1 << 2;
        const exposure: u32 = 1 << 15;
        const structure_notify: u32 = 1 << 17;
    };

    const WindowClass = struct {
        const input_output: u16 = 1;
    };

    const Cw = struct {
        const back_pixel: u32 = 1 << 1;
        const event_mask: u32 = 1 << 11;
    };

    const Gc = struct {
        const foreground: u32 = 1 << 2;
        const background: u32 = 1 << 3;
    };
};

const DisplaySpec = struct {
    display: []const u8,
    display_number: u16,
    screen_number: u16,
};

const SetupInfo = struct {
    resource_id_base: u32,
    resource_id_mask: u32,
    root: u32,
    root_visual: u32,
    root_depth: u8,
    white_pixel: u32,
    black_pixel: u32,
};

const Atoms = struct {
    wm_protocols: u32,
    wm_delete_window: u32,
};

const Graphics = struct {
    bg: u32,
    panel: u32,
    panel_2: u32,
    line: u32,
    text: u32,
    muted: u32,
    cyan: u32,
    green: u32,
    amber: u32,
    red: u32,
};

const X11 = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    sequence: u16 = 0,
    next_resource: u32 = 1,
    setup: SetupInfo,
    window: u32,
    atoms: Atoms,
    gc: Graphics,

    fn connect(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) !X11 {
        const display_env = environ.get("DISPLAY") orelse return error.DisplayNotSet;
        const spec = try parseDisplay(display_env);
        const path = try std.fmt.allocPrint(allocator, "/tmp/.X11-unix/X{d}", .{spec.display_number});
        defer allocator.free(path);

        const fd = try connectUnix(path);
        errdefer _ = linux.close(fd);

        var auth_name: []u8 = &.{};
        var auth_data: []u8 = &.{};
        var auth_owned = false;
        if (try loadXAuthority(allocator, environ, spec.display_number)) |auth| {
            auth_name = auth.name;
            auth_data = auth.data;
            auth_owned = true;
        }
        defer if (auth_owned) {
            allocator.free(auth_name);
            allocator.free(auth_data);
        };

        try sendSetup(fd, auth_name, auth_data);
        const setup = try readSetup(allocator, fd);

        var self = X11{
            .allocator = allocator,
            .fd = fd,
            .setup = setup,
            .window = 0,
            .atoms = .{ .wm_protocols = 0, .wm_delete_window = 0 },
            .gc = undefined,
        };
        self.gc = try self.createGraphics();
        self.window = try self.createWindow();
        self.atoms = .{
            .wm_protocols = try self.internAtom("WM_PROTOCOLS"),
            .wm_delete_window = try self.internAtom("WM_DELETE_WINDOW"),
        };
        try self.setWindowTitle("ZIDE - Linux GUI");
        try self.setWmDelete();
        try self.mapWindow();
        return self;
    }

    fn close(self: *X11) void {
        _ = linux.close(self.fd);
        self.* = undefined;
    }

    fn allocId(self: *X11) u32 {
        const id = self.setup.resource_id_base | (self.next_resource & self.setup.resource_id_mask);
        self.next_resource += 1;
        return id;
    }

    fn nextSeq(self: *X11) void {
        self.sequence +%= 1;
    }

    fn writeRequest(self: *X11, bytes: []const u8) !void {
        try writeAll(self.fd, bytes);
        self.nextSeq();
    }

    fn createGraphics(self: *X11) !Graphics {
        return .{
            .bg = try self.createGc(rgb(5, 7, 8), rgb(5, 7, 8)),
            .panel = try self.createGc(rgb(17, 24, 28), rgb(17, 24, 28)),
            .panel_2 = try self.createGc(rgb(23, 33, 38), rgb(23, 33, 38)),
            .line = try self.createGc(rgb(39, 50, 56), rgb(39, 50, 56)),
            .text = try self.createGc(rgb(244, 247, 248), rgb(5, 7, 8)),
            .muted = try self.createGc(rgb(170, 180, 184), rgb(5, 7, 8)),
            .cyan = try self.createGc(rgb(66, 217, 213), rgb(5, 7, 8)),
            .green = try self.createGc(rgb(125, 227, 139), rgb(5, 7, 8)),
            .amber = try self.createGc(rgb(255, 209, 102), rgb(5, 7, 8)),
            .red = try self.createGc(rgb(255, 127, 110), rgb(5, 7, 8)),
        };
    }

    fn createGc(self: *X11, foreground: u32, background: u32) !u32 {
        const gc = self.allocId();
        var req: [24]u8 = undefined;
        req[0] = 55;
        req[1] = 0;
        writeLe16(req[2..4], 6);
        writeLe32(req[4..8], gc);
        writeLe32(req[8..12], self.setup.root);
        writeLe32(req[12..16], X.Gc.foreground | X.Gc.background);
        writeLe32(req[16..20], foreground);
        writeLe32(req[20..24], background);
        try self.writeRequest(req[0..]);
        return gc;
    }

    fn createWindow(self: *X11) !u32 {
        const window = self.allocId();
        var req: [40]u8 = undefined;
        req[0] = 1;
        req[1] = self.setup.root_depth;
        writeLe16(req[2..4], 10);
        writeLe32(req[4..8], window);
        writeLe32(req[8..12], self.setup.root);
        writeLe16(req[12..14], 40);
        writeLe16(req[14..16], 40);
        writeLe16(req[16..18], WIDTH);
        writeLe16(req[18..20], HEIGHT);
        writeLe16(req[20..22], 0);
        writeLe16(req[22..24], X.WindowClass.input_output);
        writeLe32(req[24..28], self.setup.root_visual);
        writeLe32(req[28..32], X.Cw.back_pixel | X.Cw.event_mask);
        writeLe32(req[32..36], rgb(5, 7, 8));
        writeLe32(req[36..40], X.EventMask.exposure | X.EventMask.key_press | X.EventMask.button_press | X.EventMask.structure_notify);
        try self.writeRequest(req[0..]);
        return window;
    }

    fn internAtom(self: *X11, name: []const u8) !u32 {
        const padded_len = pad4(name.len);
        var req = try self.allocator.alloc(u8, 8 + padded_len);
        defer self.allocator.free(req);
        @memset(req, 0);
        req[0] = 16;
        req[1] = 0;
        writeLe16(req[2..4], @intCast((8 + padded_len) / 4));
        writeLe16(req[4..6], @intCast(name.len));
        writeLe16(req[6..8], 0);
        @memcpy(req[8..][0..name.len], name);
        try self.writeRequest(req);

        var reply: [32]u8 = undefined;
        try readReply(self.fd, reply[0..]);
        if (reply[0] != 1) return error.X11ProtocolError;
        return readLe32(reply[8..12]);
    }

    fn setWindowTitle(self: *X11, title: []const u8) !void {
        const atom_wm_name = try self.internAtom("WM_NAME");
        const atom_string = try self.internAtom("STRING");
        try self.changeProperty8(self.window, atom_wm_name, atom_string, title);
    }

    fn setWmDelete(self: *X11) !void {
        var data: [4]u8 = undefined;
        writeLe32(data[0..4], self.atoms.wm_delete_window);
        try self.changeProperty32(self.window, self.atoms.wm_protocols, 4, data[0..]);
    }

    fn changeProperty8(self: *X11, window: u32, property: u32, property_type: u32, data: []const u8) !void {
        const padded_len = pad4(data.len);
        var req = try self.allocator.alloc(u8, 24 + padded_len);
        defer self.allocator.free(req);
        @memset(req, 0);
        req[0] = 18;
        req[1] = 0;
        writeLe16(req[2..4], @intCast((24 + padded_len) / 4));
        writeLe32(req[4..8], window);
        writeLe32(req[8..12], property);
        writeLe32(req[12..16], property_type);
        req[16] = 8;
        req[17] = 0;
        writeLe16(req[18..20], 0);
        writeLe32(req[20..24], @intCast(data.len));
        @memcpy(req[24..][0..data.len], data);
        try self.writeRequest(req);
    }

    fn changeProperty32(self: *X11, window: u32, property: u32, property_type: u32, data: []const u8) !void {
        var req = try self.allocator.alloc(u8, 24 + data.len);
        defer self.allocator.free(req);
        @memset(req, 0);
        req[0] = 18;
        req[1] = 0;
        writeLe16(req[2..4], @intCast((24 + data.len) / 4));
        writeLe32(req[4..8], window);
        writeLe32(req[8..12], property);
        writeLe32(req[12..16], property_type);
        req[16] = 32;
        req[17] = 0;
        writeLe16(req[18..20], 0);
        writeLe32(req[20..24], @intCast(data.len / 4));
        @memcpy(req[24..], data);
        try self.writeRequest(req);
    }

    fn mapWindow(self: *X11) !void {
        var req: [8]u8 = undefined;
        req[0] = 8;
        req[1] = 0;
        writeLe16(req[2..4], 2);
        writeLe32(req[4..8], self.window);
        try self.writeRequest(req[0..]);
    }

    fn fillRect(self: *X11, gc: u32, x: i16, y: i16, w: u16, h: u16) !void {
        var req: [20]u8 = undefined;
        req[0] = 70;
        req[1] = 0;
        writeLe16(req[2..4], 5);
        writeLe32(req[4..8], self.window);
        writeLe32(req[8..12], gc);
        writeLe16(req[12..14], @bitCast(x));
        writeLe16(req[14..16], @bitCast(y));
        writeLe16(req[16..18], w);
        writeLe16(req[18..20], h);
        try self.writeRequest(req[0..]);
    }

    fn text(self: *X11, gc: u32, x: i16, y: i16, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const visible = bytes[0..@min(bytes.len, 240)];
        const padded_len = pad4(visible.len);
        var req = try self.allocator.alloc(u8, 16 + padded_len);
        defer self.allocator.free(req);
        @memset(req, 0);
        req[0] = 76;
        req[1] = @intCast(visible.len);
        writeLe16(req[2..4], @intCast((16 + padded_len) / 4));
        writeLe32(req[4..8], self.window);
        writeLe32(req[8..12], gc);
        writeLe16(req[12..14], @bitCast(x));
        writeLe16(req[14..16], @bitCast(y));
        @memcpy(req[16..][0..visible.len], visible);
        try self.writeRequest(req);
    }
};

const XAuth = struct {
    name: []u8,
    data: []u8,
};

const BottomPanel = enum {
    output,
    git,
    extensions,
    diagnostics,
    security,
    tutorial,
    publish,
};

const HeaderAction = enum {
    save,
    save_all,
    git,
    audit,
    extensions,
    tutorial,
    publish,
};

const LinuxGuiState = struct {
    allocator: std.mem.Allocator,
    app: app_mod.App,
    bottom_panel: BottomPanel = .output,
    editor_scroll_line: usize = 0,
    message_buf: [240]u8 = [_]u8{0} ** 240,
    message_len: usize = 0,

    fn init(allocator: std.mem.Allocator, root_path: []const u8) !LinuxGuiState {
        return .{
            .allocator = allocator,
            .app = try app_mod.App.init(allocator, root_path),
        };
    }

    fn deinit(self: *LinuxGuiState) void {
        self.app.deinit();
        self.* = undefined;
    }

    fn message(self: *LinuxGuiState, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.message_buf[0..], fmt, args) catch self.message_buf[0..0];
        self.message_len = written.len;
    }

    fn appendOutput(self: *LinuxGuiState, stream: @import("../tasks/console.zig").Stream, comptime fmt: []const u8, args: anytype) void {
        var text: std.Io.Writer.Allocating = .init(self.allocator);
        defer text.deinit();
        text.writer.print(fmt, args) catch return;
        self.app.process_console.appendBytes(stream, text.written()) catch return;
    }

    fn execute(self: *LinuxGuiState, id: []const u8, source: @import("../core/command.zig").Source) void {
        const result = dispatcher.dispatch(&self.app, .{ .id = id, .source = source }) catch |err| {
            self.message("{s} failed: {s}", .{ id, @errorName(err) });
            self.app.process_console.appendBytes(.stderr, "command failed\n") catch {};
            return;
        };
        self.handleDispatchResult(id, result);
    }

    fn handleOutcome(self: *LinuxGuiState, outcome: input_handler.Outcome) void {
        switch (outcome) {
            .ignored => {},
            .redraw => {},
            .command_result => |result| self.handleDispatchResult("input", result),
        }
    }

    fn handleDispatchResult(self: *LinuxGuiState, id: []const u8, result: dispatcher.Result) void {
        switch (result) {
            .completed => |message_text| {
                self.message("{s}: {s}", .{ id, message_text });
                self.appendOutput(.stdout, "{s}: {s}\n", .{ id, message_text });
            },
            .blocked => |message_text| {
                self.message("{s}: blocked", .{id});
                self.appendOutput(.stderr, "blocked {s}: {s}\n", .{ id, message_text });
                if (self.app.pending_build_consent) |preview| {
                    self.appendOutput(.stdout, "pending consent: {s}\n", .{preview.command});
                    self.appendOutput(.stdout, "review the command, then run task.run_next from the command palette\n", .{});
                }
            },
            .unknown_command => {
                self.message("{s}: unknown command", .{id});
                self.appendOutput(.stderr, "unknown command: {s}\n", .{id});
            },
            .no_active_document => {
                self.message("{s}: no active document", .{id});
                self.appendOutput(.stderr, "{s}: no active document\n", .{id});
            },
            .external_command => |spec| {
                var preview = build_consent.makePreview(self.allocator, spec, self.app.runtime.trust_state) catch |err| {
                    self.message("preview failed: {s}", .{@errorName(err)});
                    return;
                };
                defer preview.deinit();

                self.app.execution_queue.enqueueSpec(id, spec, preview.consent) catch |err| {
                    self.message("queue failed: {s}", .{@errorName(err)});
                    return;
                };
                self.appendOutput(.stdout, "queued external command: {s}\n", .{preview.command});

                const run_result = dispatcher.dispatch(&self.app, .{ .id = "task.run_next", .source = .task }) catch |err| {
                    self.message("run failed: {s}", .{@errorName(err)});
                    self.appendOutput(.stderr, "run failed: {s}\n", .{@errorName(err)});
                    return;
                };
                self.handleDispatchResult("task.run_next", run_result);
            },
            .unsupported => |message_text| {
                self.message("{s}: {s}", .{ id, message_text });
                self.appendOutput(.stderr, "unsupported {s}: {s}\n", .{ id, message_text });
            },
        }

        if (std.mem.eql(u8, id, "git.overview") or std.mem.eql(u8, id, "github.overview")) self.bottom_panel = .git;
        if (std.mem.eql(u8, id, "view.extensions") or std.mem.eql(u8, id, "extensions.scan")) self.bottom_panel = .extensions;
        if (std.mem.eql(u8, id, "view.publish") or std.mem.eql(u8, id, "release.checklist")) self.bottom_panel = .publish;
        if (std.mem.eql(u8, id, "security.audit_workspace") or std.mem.eql(u8, id, "security.scan_current")) self.bottom_panel = .security;
    }

    fn runHeaderAction(self: *LinuxGuiState, action: HeaderAction) void {
        switch (action) {
            .save => self.execute("file.save", .keybinding),
            .save_all => self.execute("file.save_all", .keybinding),
            .git => self.execute("git.overview", .keybinding),
            .audit => self.execute("security.audit_workspace", .keybinding),
            .extensions => self.execute("extensions.scan", .keybinding),
            .tutorial => {
                self.bottom_panel = .tutorial;
                self.message("help: tutorial opened", .{});
            },
            .publish => self.execute("release.checklist", .keybinding),
        }
    }

    fn handleKey(self: *LinuxGuiState, key: event_mod.KeyEvent) void {
        if (self.app.mode == .insert and self.app.focus == .editor) {
            switch (key.code) {
                .backspace => {
                    self.deleteBackward();
                    return;
                },
                .delete => {
                    self.deleteForward();
                    return;
                },
                else => {},
            }
        }

        if (std.meta.activeTag(key.code) == .function) {
            switch (key.code.function) {
                1 => {
                    self.bottom_panel = .tutorial;
                    self.message("help: tutorial opened", .{});
                    return;
                },
                8 => {
                    self.bottom_panel = .diagnostics;
                    self.execute("diagnostics.next", .keybinding);
                    return;
                },
                else => {},
            }
        }

        if (key.modifiers.ctrl) {
            switch (key.code) {
                .char => |char| {
                    if (key.modifiers.shift and (char == 'x' or char == 'X')) {
                        self.runHeaderAction(.extensions);
                        return;
                    }
                    if (key.modifiers.shift and (char == 'l' or char == 'L')) {
                        self.runHeaderAction(.publish);
                        return;
                    }
                    if (char == 'z' or char == 'Z') {
                        self.execute("editor.undo", .keybinding);
                        return;
                    }
                    if (char == 'y' or char == 'Y') {
                        self.execute("editor.redo", .keybinding);
                        return;
                    }
                    if (char == 's' or char == 'S') {
                        self.runHeaderAction(if (key.modifiers.shift) .save_all else .save);
                        return;
                    }
                    if (char == 'g' or char == 'G') {
                        self.runHeaderAction(.git);
                        return;
                    }
                    if (char == 'd' or char == 'D') {
                        self.bottom_panel = .diagnostics;
                        self.message("diagnostics: {d} item(s)", .{self.app.diagnostics.items.items.len});
                        return;
                    }
                    if (char == 'a' or char == 'A') {
                        self.runHeaderAction(.audit);
                        return;
                    }
                },
                else => {},
            }
        }

        const outcome = input_handler.handle(&self.app, .{ .key = key }) catch |err| {
            self.message("input failed: {s}", .{@errorName(err)});
            return;
        };
        self.handleOutcome(outcome);
    }

    fn deleteBackward(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return;
        const current = doc.cursor.position.byte_offset;
        if (current == 0) return;
        const previous = doc.text.previousByteOffset(current) catch current - 1;
        doc.deleteRange(previous, current) catch |err| {
            self.message("delete failed: {s}", .{@errorName(err)});
            return;
        };
        self.message("deleted backward", .{});
    }

    fn deleteForward(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return;
        const current = doc.cursor.position.byte_offset;
        if (current >= doc.text.bytes.len) return;
        const next = doc.text.nextByteOffset(current) catch current + 1;
        doc.deleteRange(current, next) catch |err| {
            self.message("delete failed: {s}", .{@errorName(err)});
            return;
        };
        self.message("deleted forward", .{});
    }

    fn handleClick(self: *LinuxGuiState, x: i16, y: i16) void {
        if (headerActionAt(x, y)) |action| {
            self.runHeaderAction(action);
            return;
        }

        if (documentTabAt(&self.app, x, y)) |index| {
            self.app.documents.switchTo(index) catch |err| {
                self.message("tab switch failed: {s}", .{@errorName(err)});
                return;
            };
            self.app.focus = .editor;
            self.message("switched document", .{});
            return;
        }

        if (y >= 78 and y < BOTTOM_TOP and x < FILE_WIDTH) {
            const row = @divTrunc(@as(isize, y - 98), LINE_HEIGHT);
            if (row >= 0) {
                const index: usize = @intCast(row);
                if (index < self.app.workspace.entries.items.len) {
                    self.app.file_cursor = index;
                    self.app.focus = .files;
                    _ = self.app.openSelectedWorkspaceEntry() catch |err| {
                        self.message("open failed: {s}", .{@errorName(err)});
                        return;
                    };
                    if (self.app.documents.active() != null) self.app.mode = .insert;
                    self.message("opened selected workspace entry", .{});
                }
            }
            return;
        }

        if (y >= HEADER_HEIGHT and y < BOTTOM_TOP and x >= FILE_WIDTH) {
            self.app.focus = .editor;
            self.setCursorFromEditorClick(x, y);
            if (self.app.documents.active() != null) self.app.mode = .insert;
            return;
        }

        if (y >= BOTTOM_TOP and y < BOTTOM_TOP + 34) {
            if (bottomPanelAt(x, y)) |panel| self.bottom_panel = panel;
            return;
        }
    }

    fn setCursorFromEditorClick(self: *LinuxGuiState, x: i16, y: i16) void {
        const doc = self.app.documents.active() orelse return;
        if (y < EDITOR_TEXT_TOP - 14) return;

        const line_delta = @divTrunc(@as(isize, y - (EDITOR_TEXT_TOP - 14)), LINE_HEIGHT);
        if (line_delta < 0) return;
        const line = self.editor_scroll_line + @as(usize, @intCast(line_delta));
        if (line >= doc.text.lineCount()) return;

        const column_raw = if (x <= EDITOR_LEFT + 56) 0 else @divTrunc(@as(isize, x - (EDITOR_LEFT + 56)), 8);
        const column = @min(@as(usize, @intCast(@max(column_raw, 0))), doc.text.lineSlice(line).len);
        const offset = doc.text.lineColumnToOffset(line, column) catch return;
        navigation.setCursor(doc, doc.positionFromOffset(offset) catch return);
        self.message("cursor: {d}:{d}", .{ line + 1, column + 1 });
    }
};

pub fn run(allocator: std.mem.Allocator, root_path: []const u8, environ: *const std.process.Environ.Map) !void {
    var state = try LinuxGuiState.init(allocator, root_path);
    defer state.deinit();

    state.execute("git.overview", .startup);
    state.execute("security.audit_workspace", .startup);

    var x11 = try X11.connect(allocator, environ);
    defer x11.close();

    try draw(&x11, &state);
    while (true) {
        var event: [32]u8 = undefined;
        try readExact(x11.fd, event[0..]);
        const event_type = event[0] & 0x7f;
        switch (event_type) {
            2 => {
                if (keyEventFromX(event[0..])) |key| {
                    if (std.meta.activeTag(key.code) == .escape and state.app.mode == .normal and !state.app.palette.visible) break;
                    state.handleKey(key);
                    try draw(&x11, &state);
                }
            },
            4 => {
                state.handleClick(@bitCast(readLe16(event[24..26])), @bitCast(readLe16(event[26..28])));
                try draw(&x11, &state);
            },
            12 => try draw(&x11, &state),
            33 => {
                const message_type = readLe32(event[8..12]);
                const data0 = readLe32(event[12..16]);
                if (message_type == x11.atoms.wm_protocols and data0 == x11.atoms.wm_delete_window) break;
            },
            else => {},
        }
    }
}

fn draw(x11: *X11, state: *LinuxGuiState) !void {
    const app = &state.app;
    try x11.fillRect(x11.gc.bg, 0, 0, WIDTH, HEIGHT);
    try x11.fillRect(x11.gc.panel, 0, 0, WIDTH, HEADER_HEIGHT);
    try x11.fillRect(x11.gc.line, 0, HEADER_HEIGHT - 1, WIDTH, 1);
    try x11.fillRect(x11.gc.panel, 0, HEADER_HEIGHT, FILE_WIDTH, HEIGHT - HEADER_HEIGHT - STATUS_HEIGHT);
    try x11.fillRect(x11.gc.line, FILE_WIDTH, HEADER_HEIGHT, 1, HEIGHT - HEADER_HEIGHT - STATUS_HEIGHT);
    try x11.fillRect(x11.gc.panel_2, 0, BOTTOM_TOP, WIDTH, OUTPUT_HEIGHT);
    try x11.fillRect(x11.gc.cyan, 16, 14, 30, 30);

    try x11.text(x11.gc.bg, 26, 35, "Z");
    try x11.text(x11.gc.text, 58, 34, "ZIDE");
    try x11.text(x11.gc.muted, 152, 34, "Linux GUI / direct X11 / shared ZIDE core");
    try drawHeaderActions(x11);

    try x11.text(x11.gc.cyan, 18, 86, "FILES");
    try x11.text(x11.gc.muted, 112, 86, "click opens / Enter opens / j,k move");
    var y: i16 = 112;
    const max_files = @min(app.workspace.entries.items.len, @as(usize, @intCast((BOTTOM_TOP - 104) / LINE_HEIGHT)));
    for (app.workspace.entries.items[0..max_files], 0..) |entry, index| {
        const gc = if (index == app.file_cursor) x11.gc.cyan else if (entry.kind == .directory) x11.gc.green else x11.gc.text;
        if (index == app.file_cursor) try x11.fillRect(x11.gc.panel_2, 8, y - 14, FILE_WIDTH - 16, LINE_HEIGHT);
        var line_buf: [280]u8 = undefined;
        const prefix: []const u8 = if (entry.kind == .directory) "+ " else "  ";
        const label = std.fmt.bufPrint(line_buf[0..], "{s}{s}", .{ prefix, entry.path }) catch entry.path;
        var ascii_buf: [260]u8 = undefined;
        try x11.text(gc, 18, y, asciiInto(ascii_buf[0..], label));
        y += LINE_HEIGHT;
    }

    try drawEditor(x11, state);
    try drawBottomPanel(x11, state);
    if (app.palette.visible) try drawPalette(x11, state);

    try x11.fillRect(x11.gc.cyan, 0, HEIGHT - STATUS_HEIGHT, WIDTH, STATUS_HEIGHT);
    var status_buf: [520]u8 = undefined;
    const active = app.documents.active();
    const dirty_count = app.documents.dirtyCount();
    const language = if (active) |doc| modes.label(doc.language) else "none";
    const cursor = if (active) |doc| doc.cursor.position else null;
    const status = std.fmt.bufPrint(status_buf[0..],
        "{s}/{s} | line:{d} col:{d} dirty:{d} lang:{s} trust:{s} risk:{d} files:{d} code:{d} langs:{d} zig:{d} docs:{d} | Ctrl+P Ctrl+S Ctrl+G Ctrl+A | {s}",
        .{
            @tagName(app.mode),
            @tagName(app.focus),
            if (cursor) |pos| pos.line + 1 else 0,
            if (cursor) |pos| pos.column + 1 else 0,
            dirty_count,
            language,
            @tagName(app.runtime.trust_state),
            app.security_findings.items.items.len,
            app.workspace.entries.items.len,
            app.workspace.countCodeFiles(),
            app.workspace.countRecognizedLanguages(),
            app.workspace.countZigFamily(),
            app.documents.documents.items.len,
            state.message_buf[0..state.message_len],
        },
    ) catch "status unavailable";
    try x11.text(x11.gc.bg, 14, HEIGHT - 9, status);
}

fn drawHeaderActions(x11: *X11) !void {
    inline for (.{ HeaderAction.save, HeaderAction.save_all, HeaderAction.git, HeaderAction.audit, HeaderAction.extensions, HeaderAction.tutorial, HeaderAction.publish }) |action| {
        const rect = headerActionRect(action);
        try x11.fillRect(x11.gc.panel_2, rect.left, rect.top, @intCast(rect.right - rect.left), @intCast(rect.bottom - rect.top));
        try x11.text(x11.gc.cyan, rect.left + 10, rect.top + 20, headerActionLabel(action));
    }
}

fn drawEditor(x11: *X11, state: *LinuxGuiState) !void {
    const app = &state.app;
    try x11.text(x11.gc.cyan, EDITOR_LEFT, 86, "EDITOR");
    try x11.text(x11.gc.muted, EDITOR_LEFT + 88, 86, "shared buffer/save/security core");

    const tab_y: i16 = 112;
    var tab_x: i16 = EDITOR_LEFT;
    for (app.documents.documents.items, 0..) |doc, index| {
        const selected = if (app.documents.activeIndex()) |active_index| active_index == index else false;
        const tab_w: u16 = 178;
        if (selected) try x11.fillRect(x11.gc.panel_2, tab_x - 4, tab_y - 16, tab_w, 24);
        const label = if (doc.path) |path| std.fs.path.basename(path) else "(scratch)";
        var tab_buf: [160]u8 = undefined;
        var text_buf: [180]u8 = undefined;
        const dirty = if (doc.dirty) "*" else "";
        const text = std.fmt.bufPrint(tab_buf[0..], "{s}{s}", .{ label, dirty }) catch label;
        try x11.text(if (selected) x11.gc.cyan else x11.gc.muted, tab_x, tab_y, asciiInto(text_buf[0..], text));
        tab_x += 188;
        if (tab_x > WIDTH - 220) break;
    }

    const doc = app.documents.active() orelse {
        try x11.text(x11.gc.text, EDITOR_LEFT, EDITOR_TEXT_TOP, "No file open. Click a file on the left, or press Enter from FILES.");
        try x11.text(x11.gc.muted, EDITOR_LEFT, EDITOR_TEXT_TOP + 30, "Linux zide-gui is using the same App/document/dispatcher core as the Windows workbench.");
        return;
    };

    const path = doc.path orelse "(scratch)";
    var path_buf: [520]u8 = undefined;
    const header = std.fmt.bufPrint(path_buf[0..], "{s}  lang={s}  newline={s}  encoding={s}", .{
        path,
        modes.label(doc.language),
        doc.newlineLabel(),
        doc.encodingLabel(),
    }) catch path;
    var header_ascii: [520]u8 = undefined;
    try x11.text(x11.gc.green, EDITOR_LEFT, EDITOR_TOP, asciiInto(header_ascii[0..], header));

    const visible_rows: usize = @intCast((BOTTOM_TOP - EDITOR_TEXT_TOP - 16) / LINE_HEIGHT);
    const cursor_line = doc.cursor.position.line;
    if (cursor_line < state.editor_scroll_line) state.editor_scroll_line = cursor_line;
    if (visible_rows > 0 and cursor_line >= state.editor_scroll_line + visible_rows) {
        state.editor_scroll_line = cursor_line - visible_rows + 1;
    }

    var line_y: i16 = EDITOR_TEXT_TOP;
    var row: usize = 0;
    while (row < visible_rows and state.editor_scroll_line + row < doc.text.lineCount()) : (row += 1) {
        const line_index = state.editor_scroll_line + row;
        const line = doc.text.lineSlice(line_index);
        const selected = line_index == cursor_line;
        if (selected) try x11.fillRect(x11.gc.panel_2, EDITOR_LEFT - 8, line_y - 14, WIDTH - EDITOR_LEFT - 20, LINE_HEIGHT);

        var number_buf: [24]u8 = undefined;
        const number = std.fmt.bufPrint(number_buf[0..], "{d: >4}", .{line_index + 1}) catch "   ?";
        try x11.text(x11.gc.muted, EDITOR_LEFT, line_y, number);

        var line_buf: [720]u8 = undefined;
        try x11.text(if (selected) x11.gc.text else x11.gc.muted, EDITOR_LEFT + 56, line_y, asciiInto(line_buf[0..], line));

        if (selected and app.mode == .insert and app.focus == .editor) {
            const cursor_x: i16 = EDITOR_LEFT + 56 + @as(i16, @intCast(@min(doc.cursor.position.column, 120))) * 8;
            try x11.fillRect(x11.gc.cyan, cursor_x, line_y - 14, 2, LINE_HEIGHT);
        }
        line_y += LINE_HEIGHT;
    }
}

fn drawBottomPanel(x11: *X11, state: *LinuxGuiState) !void {
    try x11.fillRect(x11.gc.line, 0, BOTTOM_TOP, WIDTH, 1);
    try drawPanelTab(x11, state.bottom_panel == .output, 18, "OUTPUT");
    try drawPanelTab(x11, state.bottom_panel == .git, 122, "GIT");
    try drawPanelTab(x11, state.bottom_panel == .extensions, 226, "EXT");
    try drawPanelTab(x11, state.bottom_panel == .diagnostics, 330, "DIAG");
    try drawPanelTab(x11, state.bottom_panel == .security, 434, "SEC");
    try drawPanelTab(x11, state.bottom_panel == .tutorial, 538, "HELP");
    try drawPanelTab(x11, state.bottom_panel == .publish, 642, "SHIP");

    switch (state.bottom_panel) {
        .output => try drawOutputPanel(x11, state),
        .git => try drawGitPanel(x11, state),
        .extensions => try drawExtensionsPanel(x11, state),
        .diagnostics => try drawDiagnosticsPanel(x11, state),
        .security => try drawSecurityPanel(x11, state),
        .tutorial => try drawTutorialPanel(x11, state),
        .publish => try drawPublishPanel(x11, state),
    }
}

fn drawPanelTab(x11: *X11, active: bool, x: i16, label: []const u8) !void {
    if (active) try x11.fillRect(x11.gc.cyan, x - 8, BOTTOM_TOP + 8, 104, 24);
    try x11.text(if (active) x11.gc.bg else x11.gc.cyan, x, BOTTOM_TOP + 27, label);
}

fn drawOutputPanel(x11: *X11, state: *LinuxGuiState) !void {
    const app = &state.app;
    var y: i16 = BOTTOM_TOP + 58;
    const max_lines: usize = @intCast((OUTPUT_HEIGHT - 64) / LINE_HEIGHT);
    const start = if (app.process_console.lines.items.len > max_lines) app.process_console.lines.items.len - max_lines else 0;
    for (app.process_console.lines.items[start..]) |line| {
        var text_buf: [900]u8 = undefined;
        const color = if (line.stream == .stderr) x11.gc.red else x11.gc.muted;
        try x11.text(color, 18, y, asciiInto(text_buf[0..], line.text));
        y += LINE_HEIGHT;
    }
    if (app.process_console.lines.items.len == 0) {
        try x11.text(x11.gc.muted, 18, y, "No output yet.");
    }
}

fn drawSecurityPanel(x11: *X11, state: *LinuxGuiState) !void {
    const app = &state.app;
    var header_buf: [180]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "{d} finding(s) / trust={s}", .{
        app.security_findings.items.items.len,
        @tagName(app.runtime.trust_state),
    }) catch "security status unavailable";
    try x11.text(x11.gc.green, 18, BOTTOM_TOP + 58, header);
    var boundary_buf: [240]u8 = undefined;
    const counts = boundaryCounts(app);
    const boundary = std.fmt.bufPrint(boundary_buf[0..], "BOUNDARY mem:{d} exec:{d} fs:{d} net:{d} deps:{d} secret:{d} text:{d} path:{d} git:{d}", .{
        counts.memory,
        counts.execution,
        counts.filesystem,
        counts.network,
        counts.dependency,
        counts.secret,
        counts.text,
        counts.path,
        counts.git,
    }) catch "BOUNDARY";
    try x11.text(x11.gc.amber, 18, BOTTOM_TOP + 82, boundary);
    var y: i16 = BOTTOM_TOP + 110;
    const limit = @min(app.security_findings.items.items.len, @as(usize, 6));
    for (app.security_findings.items.items[0..limit]) |finding| {
        var row_buf: [900]u8 = undefined;
        const row = std.fmt.bufPrint(row_buf[0..], "{s}:{d} [{s}] {s}", .{
            finding.path,
            finding.line,
            @tagName(finding.risk),
            finding.message,
        }) catch finding.message;
        var ascii_buf: [900]u8 = undefined;
        try x11.text(riskGc(x11, finding.risk), 18, y, asciiInto(ascii_buf[0..], row));
        y += LINE_HEIGHT;
    }
    if (app.security_findings.items.items.len == 0) {
        try x11.text(x11.gc.muted, 18, y, "No security findings. Ctrl+A reruns the workspace audit.");
    }
}

fn drawGitPanel(x11: *X11, state: *LinuxGuiState) !void {
    try x11.text(x11.gc.green, 18, BOTTOM_TOP + 58, "Git/GitHub overview is read by ZIDE without running git hooks or filters.");
    var y: i16 = BOTTOM_TOP + 86;
    const app = &state.app;
    const max_lines: usize = @intCast((OUTPUT_HEIGHT - 92) / LINE_HEIGHT);
    const start = if (app.process_console.lines.items.len > max_lines) app.process_console.lines.items.len - max_lines else 0;
    for (app.process_console.lines.items[start..]) |line| {
        if (std.mem.indexOf(u8, line.text, "git") == null and std.mem.indexOf(u8, line.text, "Git") == null and std.mem.indexOf(u8, line.text, "branch") == null and std.mem.indexOf(u8, line.text, "remote") == null) continue;
        var ascii_buf: [900]u8 = undefined;
        try x11.text(x11.gc.muted, 18, y, asciiInto(ascii_buf[0..], line.text));
        y += LINE_HEIGHT;
        if (y > HEIGHT - STATUS_HEIGHT - 12) break;
    }
}

fn drawExtensionsPanel(x11: *X11, state: *LinuxGuiState) !void {
    try x11.text(x11.gc.green, 18, BOTTOM_TOP + 58, "Extensions and integrations are manifest-scanned; extension code is not executed.");
    try drawFilteredConsole(x11, state, BOTTOM_TOP + 86, &.{ "extension", "Extension", "manifest", "capabilities", "integrations" });
}

fn drawDiagnosticsPanel(x11: *X11, state: *LinuxGuiState) !void {
    const app = &state.app;
    var header_buf: [160]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "DIAGNOSTICS total:{d}", .{app.diagnostics.items.items.len}) catch "DIAGNOSTICS";
    try x11.text(x11.gc.green, 18, BOTTOM_TOP + 58, header);
    var y: i16 = BOTTOM_TOP + 86;
    const limit = @min(app.diagnostics.items.items.len, @as(usize, 6));
    for (app.diagnostics.items.items[0..limit]) |item| {
        var row_buf: [900]u8 = undefined;
        const row = std.fmt.bufPrint(row_buf[0..], "{s}:{d}:{d} [{s}] {s}", .{
            item.path,
            item.range.start.line + 1,
            item.range.start.column + 1,
            @tagName(item.severity),
            item.message,
        }) catch item.message;
        var ascii_buf: [900]u8 = undefined;
        try x11.text(x11.gc.muted, 18, y, asciiInto(ascii_buf[0..], row));
        y += LINE_HEIGHT;
    }
    if (app.diagnostics.items.items.len == 0) {
        try x11.text(x11.gc.muted, 18, y, "No diagnostics yet. Build/test output will be sanitized and parsed here.");
    }
}

fn drawTutorialPanel(x11: *X11, state: *LinuxGuiState) !void {
    const app = &state.app;
    var header_buf: [220]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "HELP / ZIDE security tour   trust={s} risk={d}", .{
        @tagName(app.runtime.trust_state),
        app.security_findings.items.items.len,
    }) catch "HELP / ZIDE security tour";
    try x11.text(x11.gc.green, 18, BOTTOM_TOP + 58, header);

    const lines = [_][]const u8{
        "F1 opens help. Ctrl+P opens commands. Ctrl+S saves with atomic write and save-time security scan.",
        "Click files to open. Insert mode edits the same DocumentStore used by Windows and the TUI.",
        "SEC shows Zig-owned boundary findings: memory, exec, filesystem, network, dependency, secret, text, path, git.",
        "GIT reads repository metadata directly; hooks, filters, fsmonitor, and git status are not executed for overview.",
        "EXT scans extension manifests only. SHIP verifies archives, paths, executable bits, and SHA-256 before release.",
    };
    var y: i16 = BOTTOM_TOP + 86;
    for (lines) |line| {
        try x11.text(x11.gc.muted, 18, y, line);
        y += LINE_HEIGHT;
    }
}

fn drawPublishPanel(x11: *X11, state: *LinuxGuiState) !void {
    try x11.text(x11.gc.green, 18, BOTTOM_TOP + 58, "SHIP / release gate");
    try drawFilteredConsole(x11, state, BOTTOM_TOP + 86, &.{ "release", "bundle", "Linux", "Windows", "sha256", "publish", "GitHub" });
}

fn drawFilteredConsole(x11: *X11, state: *LinuxGuiState, start_y: i16, needles: []const []const u8) !void {
    const app = &state.app;
    var y = start_y;
    var shown: usize = 0;
    for (app.process_console.lines.items) |line| {
        var match = false;
        for (needles) |needle| {
            if (std.mem.indexOf(u8, line.text, needle) != null) {
                match = true;
                break;
            }
        }
        if (!match) continue;
        var ascii_buf: [900]u8 = undefined;
        try x11.text(if (line.stream == .stderr) x11.gc.red else x11.gc.muted, 18, y, asciiInto(ascii_buf[0..], line.text));
        y += LINE_HEIGHT;
        shown += 1;
        if (y > HEIGHT - STATUS_HEIGHT - 12) break;
    }
    if (shown == 0) {
        try x11.text(x11.gc.muted, 18, y, "Run the matching header action or command palette item to populate this panel.");
    }
}

fn drawPalette(x11: *X11, state: *LinuxGuiState) !void {
    const left: i16 = 245;
    const top: i16 = 92;
    const width: u16 = 790;
    const height: u16 = 420;
    try x11.fillRect(x11.gc.panel, left, top, width, height);
    try x11.fillRect(x11.gc.cyan, left, top, width, 3);
    try x11.text(x11.gc.cyan, left + 18, top + 34, "COMMAND");
    var query_buf: [260]u8 = undefined;
    try x11.text(x11.gc.text, left + 18, top + 66, asciiInto(query_buf[0..], state.app.palette.query.items));

    var y: i16 = top + 104;
    const limit = @min(state.app.palette.matches.items.len, @as(usize, 12));
    for (state.app.palette.matches.items[0..limit], 0..) |item, index| {
        const selected = index == state.app.palette.selected_index;
        if (selected) try x11.fillRect(x11.gc.panel_2, left + 10, y - 15, width - 20, LINE_HEIGHT + 2);
        var row_buf: [520]u8 = undefined;
        const row = std.fmt.bufPrint(row_buf[0..], "{s}  [{s}]  {s}", .{
            item.definition.title,
            @tagName(item.definition.capability),
            item.definition.id,
        }) catch item.definition.id;
        var ascii_buf: [520]u8 = undefined;
        try x11.text(if (selected) x11.gc.cyan else x11.gc.text, left + 18, y, asciiInto(ascii_buf[0..], row));
        y += LINE_HEIGHT + 4;
    }
}

const BoundaryCounts = struct {
    memory: usize = 0,
    execution: usize = 0,
    filesystem: usize = 0,
    network: usize = 0,
    dependency: usize = 0,
    secret: usize = 0,
    text: usize = 0,
    path: usize = 0,
    git: usize = 0,
};

fn boundaryCounts(app: *const app_mod.App) BoundaryCounts {
    var counts: BoundaryCounts = .{};
    for (app.security_findings.items.items) |finding| {
        switch (findings_mod.boundaryFor(finding.category)) {
            .memory => counts.memory += 1,
            .execution => counts.execution += 1,
            .filesystem => counts.filesystem += 1,
            .network => counts.network += 1,
            .dependency => counts.dependency += 1,
            .secret => counts.secret += 1,
            .text => counts.text += 1,
            .path => counts.path += 1,
            .git => counts.git += 1,
            else => {},
        }
    }
    return counts;
}

fn riskGc(x11: *X11, risk: findings_mod.Risk) u32 {
    return switch (risk) {
        .critical, .high => x11.gc.red,
        .medium => x11.gc.amber,
        .low, .info => x11.gc.muted,
    };
}

fn ascii(bytes: []const u8) []const u8 {
    for (bytes, 0..) |byte, index| {
        if (byte >= 0x80) return bytes[0..index];
    }
    return bytes;
}

fn asciiInto(buffer: []u8, bytes: []const u8) []const u8 {
    const limit = @min(buffer.len, bytes.len);
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        const byte = bytes[index];
        buffer[index] = switch (byte) {
            0x20...0x7e => byte,
            '\t' => ' ',
            else => '?',
        };
    }
    return buffer[0..limit];
}

fn keyEventFromX(bytes: []const u8) ?event_mod.KeyEvent {
    const keycode = bytes[1];
    const state = readLe16(bytes[28..30]);
    const modifiers = event_mod.Modifiers{
        .shift = (state & 1) != 0,
        .ctrl = (state & 4) != 0,
        .alt = (state & 8) != 0,
        .super = (state & 64) != 0,
    };

    const code: event_mod.KeyCode = switch (keycode) {
        9 => .escape,
        22 => .backspace,
        23 => .tab,
        36 => .enter,
        67 => .{ .function = 1 },
        111 => .arrow_up,
        113 => .arrow_left,
        114 => .arrow_right,
        116 => .arrow_down,
        119 => .delete,
        else => if (keycodeToAscii(keycode, modifiers.shift)) |char| .{ .char = char } else return null,
    };

    return .{ .code = code, .modifiers = modifiers };
}

fn keycodeToAscii(keycode: u8, shift: bool) ?u21 {
    return switch (keycode) {
        10 => if (shift) '!' else '1',
        11 => if (shift) '@' else '2',
        12 => if (shift) '#' else '3',
        13 => if (shift) '$' else '4',
        14 => if (shift) '%' else '5',
        15 => if (shift) '^' else '6',
        16 => if (shift) '&' else '7',
        17 => if (shift) '*' else '8',
        18 => if (shift) '(' else '9',
        19 => if (shift) ')' else '0',
        20 => if (shift) '_' else '-',
        21 => if (shift) '+' else '=',
        24 => shifted('q', shift),
        25 => shifted('w', shift),
        26 => shifted('e', shift),
        27 => shifted('r', shift),
        28 => shifted('t', shift),
        29 => shifted('y', shift),
        30 => shifted('u', shift),
        31 => shifted('i', shift),
        32 => shifted('o', shift),
        33 => shifted('p', shift),
        34 => if (shift) '{' else '[',
        35 => if (shift) '}' else ']',
        38 => shifted('a', shift),
        39 => shifted('s', shift),
        40 => shifted('d', shift),
        41 => shifted('f', shift),
        42 => shifted('g', shift),
        43 => shifted('h', shift),
        44 => shifted('j', shift),
        45 => shifted('k', shift),
        46 => shifted('l', shift),
        47 => if (shift) ':' else ';',
        48 => if (shift) '"' else '\'',
        49 => if (shift) '~' else '`',
        51 => if (shift) '|' else '\\',
        52 => shifted('z', shift),
        53 => shifted('x', shift),
        54 => shifted('c', shift),
        55 => shifted('v', shift),
        56 => shifted('b', shift),
        57 => shifted('n', shift),
        58 => shifted('m', shift),
        59 => if (shift) '<' else ',',
        60 => if (shift) '>' else '.',
        61 => if (shift) '?' else '/',
        65 => ' ',
        else => null,
    };
}

fn shifted(lower: u8, shift: bool) u21 {
    return if (shift) lower - ('a' - 'A') else lower;
}

const HitRect = struct {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
};

fn headerActionRect(action: HeaderAction) HitRect {
    const top: i16 = 15;
    const height: i16 = 30;
    return switch (action) {
        .save => .{ .left = 520, .top = top, .right = 588, .bottom = top + height },
        .save_all => .{ .left = 596, .top = top, .right = 666, .bottom = top + height },
        .git => .{ .left = 674, .top = top, .right = 736, .bottom = top + height },
        .audit => .{ .left = 744, .top = top, .right = 822, .bottom = top + height },
        .extensions => .{ .left = 830, .top = top, .right = 896, .bottom = top + height },
        .tutorial => .{ .left = 904, .top = top, .right = 978, .bottom = top + height },
        .publish => .{ .left = 986, .top = top, .right = 1058, .bottom = top + height },
    };
}

fn headerActionLabel(action: HeaderAction) []const u8 {
    return switch (action) {
        .save => "SAVE",
        .save_all => "ALL",
        .git => "GIT",
        .audit => "AUDIT",
        .extensions => "EXT",
        .tutorial => "HELP",
        .publish => "SHIP",
    };
}

fn headerActionAt(x: i16, y: i16) ?HeaderAction {
    inline for (.{ HeaderAction.save, HeaderAction.save_all, HeaderAction.git, HeaderAction.audit, HeaderAction.extensions, HeaderAction.tutorial, HeaderAction.publish }) |action| {
        if (pointIn(headerActionRect(action), x, y)) return action;
    }
    return null;
}

fn bottomPanelAt(x: i16, y: i16) ?BottomPanel {
    if (y < BOTTOM_TOP or y >= BOTTOM_TOP + 34) return null;
    const panels = [_]BottomPanel{ .output, .git, .extensions, .diagnostics, .security, .tutorial, .publish };
    for (panels, 0..) |panel, index| {
        const left: i16 = 10 + @as(i16, @intCast(index)) * 104;
        const rect = HitRect{ .left = left, .top = BOTTOM_TOP + 8, .right = left + 96, .bottom = BOTTOM_TOP + 32 };
        if (pointIn(rect, x, y)) return panel;
    }
    return null;
}

fn documentTabAt(app: *const app_mod.App, x: i16, y: i16) ?usize {
    if (y < 92 or y >= 122 or x < EDITOR_LEFT) return null;
    var tab_x: i16 = EDITOR_LEFT;
    for (app.documents.documents.items, 0..) |_, index| {
        const rect = HitRect{ .left = tab_x - 4, .top = 96, .right = tab_x + 174, .bottom = 122 };
        if (pointIn(rect, x, y)) return index;
        tab_x += 188;
        if (tab_x > WIDTH - 220) break;
    }
    return null;
}

fn pointIn(rect: HitRect, x: i16, y: i16) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
}

fn connectUnix(path: []const u8) !i32 {
    var addr: linux.sockaddr.un = undefined;
    addr.family = linux.AF.UNIX;
    @memset(addr.path[0..], 0);
    if (path.len >= addr.path.len) return error.DisplayPathTooLong;
    @memcpy(addr.path[0..path.len], path);

    const fd_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(fd_rc);
    errdefer _ = linux.close(fd);

    const len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    const rc = linux.connect(fd, &addr, len);
    if (linux.errno(rc) != .SUCCESS) return error.DisplayConnectFailed;
    return fd;
}

fn sendSetup(fd: i32, auth_name: []const u8, auth_data: []const u8) !void {
    const name_pad = pad4(auth_name.len);
    const data_pad = pad4(auth_data.len);
    var buf: [12]u8 = undefined;
    @memset(buf[0..], 0);
    buf[0] = 'l';
    writeLe16(buf[2..4], 11);
    writeLe16(buf[4..6], 0);
    writeLe16(buf[6..8], @intCast(auth_name.len));
    writeLe16(buf[8..10], @intCast(auth_data.len));
    try writeAll(fd, buf[0..]);
    try writeAll(fd, auth_name);
    try writeZeros(fd, name_pad - auth_name.len);
    try writeAll(fd, auth_data);
    try writeZeros(fd, data_pad - auth_data.len);
}

fn readSetup(allocator: std.mem.Allocator, fd: i32) !SetupInfo {
    var header: [8]u8 = undefined;
    try readExact(fd, header[0..]);
    if (header[0] != 1) return error.X11SetupRejected;

    const extra_len = @as(usize, readLe16(header[6..8])) * 4;
    const body = try allocator.alloc(u8, extra_len);
    defer allocator.free(body);
    try readExact(fd, body);
    if (body.len < 32) return error.X11SetupTruncated;

    const resource_id_base = readLe32(body[4..8]);
    const resource_id_mask = readLe32(body[8..12]);
    const vendor_len = readLe16(body[20..22]);
    const format_count = body[23];
    const roots_len = body[22];
    const vendor_end = 32 + pad4(vendor_len);
    const formats_end = vendor_end + @as(usize, format_count) * 8;
    if (roots_len == 0 or formats_end + 40 > body.len) return error.X11SetupTruncated;

    const screen = body[formats_end..];
    return .{
        .resource_id_base = resource_id_base,
        .resource_id_mask = resource_id_mask,
        .root = readLe32(screen[0..4]),
        .root_visual = readLe32(screen[32..36]),
        .root_depth = screen[38],
        .white_pixel = readLe32(screen[8..12]),
        .black_pixel = readLe32(screen[12..16]),
    };
}

fn readReply(fd: i32, out: []u8) !void {
    while (true) {
        try readExact(fd, out[0..32]);
        if (out[0] == 1) return;
        if (out[0] == 0) return error.X11ProtocolError;
    }
}

fn loadXAuthority(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, display_number: u16) !?XAuth {
    var owned_path: ?[]u8 = null;
    const path: []const u8 = if (environ.get("XAUTHORITY")) |value| value else path: {
        const home = environ.get("HOME") orelse return null;
        owned_path = try std.fs.path.join(allocator, &.{ home, ".Xauthority" });
        break :path owned_path.?;
    };
    defer if (owned_path) |value| allocator.free(value);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024 * 1024)) catch return null;
    defer allocator.free(bytes);

    var index: usize = 0;
    while (index + 2 <= bytes.len) {
        const family = readBe16(bytes[index..][0..2]);
        index += 2;
        const address = readAuthField(bytes, &index) orelse return null;
        const number = readAuthField(bytes, &index) orelse return null;
        const name = readAuthField(bytes, &index) orelse return null;
        const data = readAuthField(bytes, &index) orelse return null;
        _ = address;

        var display_buf: [12]u8 = undefined;
        const display_text = try std.fmt.bufPrint(display_buf[0..], "{d}", .{display_number});
        if (family == 256 and std.mem.eql(u8, number, display_text) and std.mem.eql(u8, name, "MIT-MAGIC-COOKIE-1")) {
            return .{
                .name = try allocator.dupe(u8, name),
                .data = try allocator.dupe(u8, data),
            };
        }
    }
    return null;
}

fn readAuthField(bytes: []const u8, index: *usize) ?[]const u8 {
    if (index.* + 2 > bytes.len) return null;
    const len = readBe16(bytes[index.*..][0..2]);
    index.* += 2;
    if (index.* + len > bytes.len) return null;
    const field = bytes[index.*..][0..len];
    index.* += len;
    return field;
}

fn parseDisplay(value: []const u8) !DisplaySpec {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidDisplay;
    var rest = value[colon + 1 ..];
    var screen_number: u16 = 0;
    if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
        screen_number = try std.fmt.parseInt(u16, rest[dot + 1 ..], 10);
        rest = rest[0..dot];
    }
    const display_number = try std.fmt.parseInt(u16, rest, 10);
    return .{ .display = value, .display_number = display_number, .screen_number = screen_number };
}

fn readExact(fd: i32, out: []u8) !void {
    var done: usize = 0;
    while (done < out.len) {
        const rc = linux.read(fd, out[done..].ptr, out.len - done);
        if (linux.errno(rc) != .SUCCESS) return error.ReadFailed;
        if (rc == 0) return error.EndOfStream;
        done += @intCast(rc);
    }
}

fn writeAll(fd: i32, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
        done += @intCast(rc);
    }
}

fn writeZeros(fd: i32, count: usize) !void {
    if (count == 0) return;
    const zeros = [_]u8{0} ** 4;
    try writeAll(fd, zeros[0..count]);
}

fn pad4(value: usize) usize {
    return (value + 3) & ~@as(usize, 3);
}

fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

fn readLe16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readLe32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readBe16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn writeLe16(dest: []u8, value: u16) void {
    dest[0] = @truncate(value);
    dest[1] = @truncate(value >> 8);
}

fn writeLe32(dest: []u8, value: u32) void {
    dest[0] = @truncate(value);
    dest[1] = @truncate(value >> 8);
    dest[2] = @truncate(value >> 16);
    dest[3] = @truncate(value >> 24);
}
