const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const app_mod = @import("../core/app.zig");
const build_consent = @import("../security/build_consent.zig");
const command_mod = @import("../core/command.zig");
const dispatcher = @import("../core/dispatcher.zig");
const event_mod = @import("../core/event.zig");
const input_handler = @import("../core/input_handler.zig");
const document_mod = @import("../editor/document.zig");
const extension_registry = @import("../extensions/registry.zig");
const navigation = @import("../editor/navigation.zig");
const git_repository = @import("../git/repository.zig");
const modes = @import("../language/modes.zig");
const symbols_mod = @import("../language/symbols.zig");
const findings_mod = @import("../security/findings.zig");
const text_integrity = @import("../security/text_integrity.zig");
const file_finder = @import("../search/file_finder.zig");
const literal_search = @import("../search/literal.zig");
const workspace_search = @import("../search/workspace_search.zig");
const task_registry = @import("../tasks/registry.zig");

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
    open_workspace,
    save,
    save_all,
    build,
    test_run,
    git,
    audit,
    scan,
    extensions,
    tutorial,
    publish,
};

const GitPanelAction = enum {
    refresh,
    status,
    diff,
    issues,
};

const SecurityPanelAction = enum {
    audit,
    lock,
    scan,
    lf,
    crlf,
    clean,
    linux,
};

const ExtensionPanelAction = enum {
    scan,
};

const TutorialLanguage = enum {
    ja,
    en,
};

const TutorialPanelAction = enum {
    ja,
    en,
};

const PublishPanelAction = enum {
    checklist,
    assets,
    manifests,
    bundle,
    verify,
    preflight,
};

const QuickPanelMode = enum {
    open_workspace,
    find_file,
    find_document,
    replace_document,
    rename_symbol,
    search_workspace,
    new_file,
    run_task,
    document_symbols,
};

const ReplaceRequest = struct {
    find: []const u8,
    replace: []const u8,
};

const SelectionRange = struct {
    start: usize,
    end: usize,
};

const SearchDirection = enum {
    forward,
    backward,
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

const TaskMatch = struct {
    name: []u8,
    executable: []u8,

    fn deinit(self: *TaskMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.executable);
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
        self.selected_index = 0;
        self.query.clearRetainingCapacity();
        self.clearResults();
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
            const amount: usize = @intCast(-delta);
            self.selected_index = if (amount > self.selected_index) 0 else self.selected_index - amount;
        } else {
            const amount: usize = @intCast(delta);
            self.selected_index = @min(max_index, self.selected_index + amount);
        }
    }

    fn itemCount(self: *const QuickPanel) usize {
        return switch (self.mode) {
            .open_workspace => if (self.query.items.len > 0) 1 else 0,
            .find_file => if (self.file_matches) |items| items.len else 0,
            .find_document => if (self.document_matches) |items| items.len else 0,
            .replace_document => if (self.document_matches) |items| items.len else 0,
            .rename_symbol => if (renameRequest(self.query.items)) |_| 1 else 0,
            .search_workspace => if (self.search_results) |items| items.len else 0,
            .new_file => if (self.query.items.len > 0) 1 else 0,
            .run_task => if (self.task_matches) |items| items.len else 0,
            .document_symbols => if (self.symbol_matches) |items| items.len else 0,
        };
    }

    fn selectedFile(self: *const QuickPanel) ?file_finder.Match {
        const items = self.file_matches orelse return null;
        if (items.len == 0) return null;
        return items[@min(self.selected_index, items.len - 1)];
    }

    fn selectedDocumentMatch(self: *const QuickPanel) ?*const DocumentMatch {
        const items = self.document_matches orelse return null;
        if (items.len == 0) return null;
        return &items[@min(self.selected_index, items.len - 1)];
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
            .open_workspace => {},
            .find_file => {
                self.file_matches = try file_finder.find(self.allocator, &app.workspace, self.query.items, 80);
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
            .rename_symbol => {},
            .search_workspace => {
                if (self.query.items.len > 0) {
                    self.search_results = try workspace_search.search(self.allocator, &app.workspace, self.query.items, .{
                        .literal_options = self.search_options,
                        .max_file_bytes = 512 * 1024,
                        .max_results = 256,
                    });
                }
            },
            .new_file => {},
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

const LinuxFlag = enum {
    unknown,
    off,
    on,
};

const LinuxSecuritySnapshot = struct {
    no_new_privs: LinuxFlag = .unknown,
    no_new_privs_set: LinuxFlag = .unknown,
    dumpable: LinuxFlag = .unknown,
    dumpable_set: LinuxFlag = .unknown,
    ambient_clear: LinuxFlag = .unknown,
    seccomp_mode: ?u8 = null,
    dangerous_bounding_caps: usize = 0,
    bounding_caps_dropped: usize = 0,
    bounding_caps_drop_failed: usize = 0,
    cap_eff: [32]u8 = [_]u8{0} ** 32,
    cap_eff_len: usize = 0,
    cap_eff_zero: LinuxFlag = .unknown,
    proc_status_read: bool = false,
    proc_maps_read: bool = false,
    maps_total: usize = 0,
    maps_executable: usize = 0,
    maps_writable_executable: usize = 0,
    maps_shared_objects: usize = 0,
    maps_anonymous_executable: usize = 0,
    proc_fd_read: bool = false,
    fd_total: usize = 0,
    fd_cloexec_missing: usize = 0,
    fd_cloexec_unknown: usize = 0,
    fd_sockets: usize = 0,
    fd_pipes: usize = 0,
    fd_memfd: usize = 0,
    fd_anon: usize = 0,
    fd_files: usize = 0,
    fd_unknown: usize = 0,
};

const LinuxGuiState = struct {
    allocator: std.mem.Allocator,
    app: app_mod.App,
    quick_panel: QuickPanel,
    git_overview: ?git_repository.Overview = null,
    extensions_registry: ?extension_registry.Registry = null,
    tutorial_language: TutorialLanguage = .ja,
    linux_security: LinuxSecuritySnapshot = .{},
    last_document_search_query: std.array_list.Managed(u8),
    last_document_search_options: literal_search.Options = .{},
    selection_anchor: ?usize = null,
    bottom_panel: BottomPanel = .output,
    window_width: i16 = WIDTH,
    window_height: i16 = HEIGHT,
    file_scroll_line: usize = 0,
    editor_scroll_line: usize = 0,
    output_scroll_line: usize = 0,
    git_scroll_line: usize = 0,
    extensions_scroll_line: usize = 0,
    diagnostics_scroll_line: usize = 0,
    security_scroll_line: usize = 0,
    tutorial_scroll_line: usize = 0,
    publish_scroll_line: usize = 0,
    message_buf: [240]u8 = [_]u8{0} ** 240,
    message_len: usize = 0,

    fn init(allocator: std.mem.Allocator, root_path: []const u8) !LinuxGuiState {
        return .{
            .allocator = allocator,
            .app = try app_mod.App.init(allocator, root_path),
            .quick_panel = QuickPanel.init(allocator),
            .last_document_search_query = std.array_list.Managed(u8).init(allocator),
        };
    }

    fn deinit(self: *LinuxGuiState) void {
        self.clearExtensionsRegistry();
        self.clearGitOverview();
        self.last_document_search_query.deinit();
        self.quick_panel.deinit();
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

    fn enableLinuxSelfProtection(self: *LinuxGuiState) void {
        self.linux_security.no_new_privs_set = if (trySetNoNewPrivs()) .on else .off;
        self.linux_security.dumpable_set = if (trySetDumpable(false)) .on else .off;
        self.linux_security.ambient_clear = if (tryClearAmbientCapabilities()) .on else .off;
        const drops = tryDropDangerousBoundingCapabilities();
        self.linux_security.bounding_caps_dropped = drops.dropped;
        self.linux_security.bounding_caps_drop_failed = drops.failed;
        self.refreshLinuxSelfProtection();
        self.appendOutput(.stdout, "linux self-protection: no_new_privs_set={s} no_new_privs={s} dumpable={s} dumpable_set={s} ambient_clear={s} seccomp={s} cap_eff={s} dangerous_bound={d} dropped={d} drop_failed={d}\n", .{
            flagLabel(self.linux_security.no_new_privs_set),
            flagLabel(self.linux_security.no_new_privs),
            flagLabel(self.linux_security.dumpable),
            flagLabel(self.linux_security.dumpable_set),
            flagLabel(self.linux_security.ambient_clear),
            seccompLabel(self.linux_security.seccomp_mode),
            self.linuxSecurityCapEffLabel(),
            self.linux_security.dangerous_bounding_caps,
            self.linux_security.bounding_caps_dropped,
            self.linux_security.bounding_caps_drop_failed,
        });
    }

    fn refreshLinuxSelfProtection(self: *LinuxGuiState) void {
        const previous = self.linux_security;
        self.linux_security = readLinuxSecuritySnapshot(self.allocator, previous.no_new_privs_set, previous.dumpable_set);
        self.linux_security.ambient_clear = previous.ambient_clear;
        self.linux_security.bounding_caps_dropped = previous.bounding_caps_dropped;
        self.linux_security.bounding_caps_drop_failed = previous.bounding_caps_drop_failed;
    }

    fn linuxSecurityCapEffLabel(self: *const LinuxGuiState) []const u8 {
        if (self.linux_security.cap_eff_len == 0) return "unknown";
        if (self.linux_security.cap_eff_zero == .on) return "none";
        return self.linux_security.cap_eff[0..self.linux_security.cap_eff_len];
    }

    fn bottomTop(self: *const LinuxGuiState) i16 {
        return @max(HEADER_HEIGHT + 180, self.window_height - OUTPUT_HEIGHT - STATUS_HEIGHT);
    }

    fn visibleFileRows(self: *const LinuxGuiState) usize {
        return @as(usize, @intCast(@max(@divTrunc(self.bottomTop() - 104, LINE_HEIGHT), 1)));
    }

    fn resize(self: *LinuxGuiState, width: u16, height: u16) void {
        self.window_width = @intCast(@max(width, 760));
        self.window_height = @intCast(@max(height, 520));
        self.ensureFileCursorVisible();
    }

    fn ensureFileCursorVisible(self: *LinuxGuiState) void {
        const visible = self.visibleFileRows();
        if (self.app.file_cursor < self.file_scroll_line) {
            self.file_scroll_line = self.app.file_cursor;
        } else if (self.app.file_cursor >= self.file_scroll_line + visible) {
            self.file_scroll_line = self.app.file_cursor - visible + 1;
        }
        const max_start = if (self.app.workspace.entries.items.len > visible) self.app.workspace.entries.items.len - visible else 0;
        self.file_scroll_line = @min(self.file_scroll_line, max_start);
    }

    fn scrollFileTree(self: *LinuxGuiState, delta: isize) void {
        const visible = self.visibleFileRows();
        const max_start = if (self.app.workspace.entries.items.len > visible) self.app.workspace.entries.items.len - visible else 0;
        self.file_scroll_line = scrollValue(self.file_scroll_line, max_start, delta);
    }

    fn scrollEditor(self: *LinuxGuiState, delta: isize) void {
        const doc = self.app.documents.active() orelse return;
        const bottom = self.bottomTop();
        const visible: usize = @intCast(@max(@divTrunc(bottom - EDITOR_TEXT_TOP - 16, LINE_HEIGHT), 1));
        const max_start = if (doc.text.lineCount() > visible) doc.text.lineCount() - visible else 0;
        self.editor_scroll_line = scrollValue(self.editor_scroll_line, max_start, delta);
    }

    fn ensureEditorCursorVisible(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return;
        const bottom = self.bottomTop();
        const visible: usize = @intCast(@max(@divTrunc(bottom - EDITOR_TEXT_TOP - 16, LINE_HEIGHT), 1));
        if (doc.cursor.position.line < self.editor_scroll_line) {
            self.editor_scroll_line = doc.cursor.position.line;
        } else if (doc.cursor.position.line >= self.editor_scroll_line + visible) {
            self.editor_scroll_line = doc.cursor.position.line - visible + 1;
        }
    }

    fn selectedRange(self: *const LinuxGuiState, doc: *const document_mod.Document) ?SelectionRange {
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

    fn execute(self: *LinuxGuiState, id: []const u8, source: command_mod.Source) void {
        if (std.mem.eql(u8, id, "view.command_palette")) {
            self.quick_panel.close();
            self.app.palette.open() catch |err| {
                self.message("palette failed: {s}", .{@errorName(err)});
                return;
            };
            self.app.mode = .command;
            self.message("command palette", .{});
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
        if (std.mem.eql(u8, id, "editor.find_next")) {
            self.findLastDocumentSearch(.forward);
            return;
        }
        if (std.mem.eql(u8, id, "editor.find_previous")) {
            self.findLastDocumentSearch(.backward);
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
        if (std.mem.eql(u8, id, "file.new")) {
            self.openQuickPanel(.new_file);
            return;
        }
        if (std.mem.eql(u8, id, "task.run")) {
            self.openQuickPanel(.run_task);
            return;
        }
        if (std.mem.eql(u8, id, "symbol.goto_symbol")) {
            self.openQuickPanel(.document_symbols);
            return;
        }
        if (std.mem.eql(u8, id, "symbol.goto_definition")) {
            self.gotoLocalDefinitionAtCursor();
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
        self.ensureFileCursorVisible();
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
        if (std.mem.eql(u8, id, "security.audit_workspace") or std.mem.eql(u8, id, "security.scan_current")) {
            self.refreshLinuxSelfProtection();
            self.bottom_panel = .security;
        }
    }

    fn runHeaderAction(self: *LinuxGuiState, action: HeaderAction) void {
        switch (action) {
            .open_workspace => self.openQuickPanel(.open_workspace),
            .save => self.execute("file.save", .keybinding),
            .save_all => self.execute("file.save_all", .keybinding),
            .build => self.execute("zig.build", .keybinding),
            .test_run => self.execute("zig.test", .keybinding),
            .git => self.openGitPanel(),
            .audit => self.execute("security.audit_workspace", .keybinding),
            .scan => self.execute("security.scan_current", .keybinding),
            .extensions => self.execute("extensions.scan", .keybinding),
            .tutorial => {
                self.bottom_panel = .tutorial;
                self.message("help: tutorial opened", .{});
            },
            .publish => self.execute("release.checklist", .keybinding),
        }
    }

    fn openGitPanel(self: *LinuxGuiState) void {
        self.bottom_panel = .git;
        self.refreshGitOverview();
    }

    fn refreshGitOverview(self: *LinuxGuiState) void {
        self.clearGitOverview();
        const overview = git_repository.inspect(self.allocator, &self.app.workspace, .{}) catch |err| {
            self.message("git overview failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "git overview failed: {s}\n", .{@errorName(err)});
            return;
        };
        const present = overview.present;
        const changes = overview.changes.len;
        self.git_overview = overview;
        self.git_scroll_line = 0;
        if (present) {
            self.message("git overview refreshed: {d} change(s)", .{changes});
        } else {
            self.message("no git repository", .{});
        }
    }

    fn clearGitOverview(self: *LinuxGuiState) void {
        if (self.git_overview) |*overview| {
            overview.deinit();
            self.git_overview = null;
        }
    }

    fn executeGitPanelAction(self: *LinuxGuiState, action: GitPanelAction) void {
        self.bottom_panel = .git;
        switch (action) {
            .refresh => self.refreshGitOverview(),
            .status => {
                self.execute("git.status", .command_palette);
                self.bottom_panel = .output;
            },
            .diff => {
                self.execute("git.diff_current", .command_palette);
                self.bottom_panel = .output;
            },
            .issues => {
                self.execute("github.issues", .command_palette);
                self.bottom_panel = .output;
            },
        }
    }

    fn executeSecurityPanelAction(self: *LinuxGuiState, action: SecurityPanelAction) void {
        self.bottom_panel = .security;
        switch (action) {
            .audit => self.execute("security.audit_workspace", .command_palette),
            .lock => self.execute("security.lock_workspace", .command_palette),
            .scan => self.refreshActiveSecurityFindings("current file security scan"),
            .lf => self.normalizeActiveDocumentNewlines(.lf),
            .crlf => self.normalizeActiveDocumentNewlines(.crlf),
            .clean => self.sanitizeActiveDocumentHiddenControls(),
            .linux => {
                self.refreshLinuxSelfProtection();
                self.message("linux self-protection refreshed", .{});
            },
        }
    }

    fn executeExtensionPanelAction(self: *LinuxGuiState, action: ExtensionPanelAction) void {
        self.bottom_panel = .extensions;
        switch (action) {
            .scan => self.refreshExtensionsRegistry(),
        }
    }

    fn refreshExtensionsRegistry(self: *LinuxGuiState) void {
        self.clearExtensionsRegistry();
        const registry = extension_registry.Registry.scan(self.allocator, &self.app.workspace, .{}) catch |err| {
            self.message("extension scan failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "extension scan failed: {s}\n", .{@errorName(err)});
            return;
        };
        const count = registry.items.items.len;
        self.extensions_registry = registry;
        self.extensions_scroll_line = 0;
        self.message("extension manifest scan: {d}", .{count});
    }

    fn clearExtensionsRegistry(self: *LinuxGuiState) void {
        if (self.extensions_registry) |*registry| {
            registry.deinit();
            self.extensions_registry = null;
        }
    }

    fn executeTutorialPanelAction(self: *LinuxGuiState, action: TutorialPanelAction) void {
        self.tutorial_language = switch (action) {
            .ja => .ja,
            .en => .en,
        };
        self.bottom_panel = .tutorial;
        self.message("tutorial language: {s}", .{@tagName(self.tutorial_language)});
    }

    fn executePublishPanelAction(self: *LinuxGuiState, action: PublishPanelAction) void {
        const id = switch (action) {
            .checklist => "release.checklist",
            .assets => "release.assets",
            .manifests => "release.manifests",
            .bundle => "release.bundle",
            .verify => "release.verify",
            .preflight => "release.preflight",
        };
        self.execute(id, .command_palette);
        self.bottom_panel = .output;
    }

    fn openQuickPanel(self: *LinuxGuiState, mode: QuickPanelMode) void {
        self.app.palette.close();
        self.quick_panel.open(mode, &self.app) catch |err| {
            self.message("panel failed: {s}", .{@errorName(err)});
            return;
        };
        self.seedQuickPanelFromLastSearch(mode);
        self.app.mode = .command;
        self.message("{s}", .{quickPanelTitle(mode)});
    }

    fn openRenamePanel(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const name = identifierAtOffset(doc.text.bytes, doc.cursor.position.byte_offset) orelse return self.message("no identifier under cursor", .{});
        self.openQuickPanel(.rename_symbol);
        self.quick_panel.query.clearRetainingCapacity();
        self.quick_panel.query.appendSlice(name) catch |err| return self.message("rename failed: {s}", .{@errorName(err)});
        self.quick_panel.query.appendSlice("=>") catch |err| return self.message("rename failed: {s}", .{@errorName(err)});
        self.quick_panel.rebuild(&self.app) catch |err| return self.message("rename failed: {s}", .{@errorName(err)});
        self.message("rename: type new name after =>", .{});
    }

    fn seedQuickPanelFromLastSearch(self: *LinuxGuiState, mode: QuickPanelMode) void {
        if (!isDocumentSearchMode(mode)) return;
        if (self.last_document_search_query.items.len == 0) return;
        self.quick_panel.query.clearRetainingCapacity();
        self.quick_panel.query.appendSlice(self.last_document_search_query.items) catch |err| return self.message("panel seed failed: {s}", .{@errorName(err)});
        if (mode == .replace_document) {
            self.quick_panel.query.appendSlice("=>") catch |err| return self.message("panel seed failed: {s}", .{@errorName(err)});
        }
        self.quick_panel.search_options = self.last_document_search_options;
        self.quick_panel.rebuild(&self.app) catch |err| return self.message("panel seed failed: {s}", .{@errorName(err)});
    }

    fn quickPanelInsertText(self: *LinuxGuiState, bytes: []const u8) void {
        self.quick_panel.insertText(&self.app, bytes) catch |err| {
            self.message("panel failed: {s}", .{@errorName(err)});
            return;
        };
        self.rememberDocumentSearchFromQuickPanel();
    }

    fn quickPanelDeleteBackward(self: *LinuxGuiState) void {
        self.quick_panel.deleteBackward(&self.app) catch |err| {
            self.message("panel failed: {s}", .{@errorName(err)});
            return;
        };
        self.rememberDocumentSearchFromQuickPanel();
    }

    fn toggleQuickPanelCaseSensitive(self: *LinuxGuiState) void {
        if (!isDocumentSearchMode(self.quick_panel.mode)) return;
        self.quick_panel.search_options.case_sensitive = !self.quick_panel.search_options.case_sensitive;
        self.quick_panel.rebuild(&self.app) catch |err| return self.message("panel failed: {s}", .{@errorName(err)});
        self.rememberDocumentSearchFromQuickPanel();
        if (self.quick_panel.search_options.case_sensitive) {
            self.message("find: case sensitive", .{});
        } else {
            self.message("find: ignore case", .{});
        }
    }

    fn toggleQuickPanelWholeWord(self: *LinuxGuiState) void {
        if (!isDocumentSearchMode(self.quick_panel.mode)) return;
        self.quick_panel.search_options.whole_word = !self.quick_panel.search_options.whole_word;
        self.quick_panel.rebuild(&self.app) catch |err| return self.message("panel failed: {s}", .{@errorName(err)});
        self.rememberDocumentSearchFromQuickPanel();
        if (self.quick_panel.search_options.whole_word) {
            self.message("find: whole word", .{});
        } else {
            self.message("find: partial word", .{});
        }
    }

    fn rememberDocumentSearchFromQuickPanel(self: *LinuxGuiState) void {
        if (!isDocumentSearchMode(self.quick_panel.mode)) return;
        const query = if (self.quick_panel.mode == .replace_document) blk: {
            const request = parseReplaceRequest(self.quick_panel.query.items) orelse return;
            break :blk request.find;
        } else self.quick_panel.query.items;
        if (query.len == 0) return;
        self.last_document_search_query.clearRetainingCapacity();
        self.last_document_search_query.appendSlice(query) catch |err| return self.message("search memory failed: {s}", .{@errorName(err)});
        self.last_document_search_options = self.quick_panel.search_options;
    }

    fn moveQuickPanelDocumentMatch(self: *LinuxGuiState, delta: isize) void {
        if (!isDocumentSearchMode(self.quick_panel.mode)) return;
        self.quick_panel.moveSelection(delta);
        const item = self.quick_panel.selectedDocumentMatch() orelse return;
        self.selectActiveDocumentRange(item.byte_offset, item.end_offset, "selected search match");
        self.quick_panel.visible = true;
        self.app.mode = .command;
    }

    fn handleQuickPanelKey(self: *LinuxGuiState, key: event_mod.KeyEvent) bool {
        if (!self.quick_panel.visible) return false;
        switch (key.code) {
            .escape => {
                self.quick_panel.close();
                self.app.mode = .normal;
                self.message("panel closed", .{});
                return true;
            },
            .backspace => {
                self.quickPanelDeleteBackward();
                return true;
            },
            .arrow_up => {
                self.quick_panel.moveSelection(-1);
                return true;
            },
            .arrow_down => {
                self.quick_panel.moveSelection(1);
                return true;
            },
            .enter => {
                if (key.modifiers.ctrl and self.quick_panel.mode == .replace_document) {
                    self.replaceAllFromQuickPanel();
                } else {
                    self.executeSelectedQuickPanelItem();
                }
                return true;
            },
            .tab => {
                if (isDocumentSearchMode(self.quick_panel.mode)) {
                    self.quick_panel.mode = .search_workspace;
                    self.quick_panel.rebuild(&self.app) catch |err| self.message("panel failed: {s}", .{@errorName(err)});
                }
                return true;
            },
            .function => |number| {
                switch (number) {
                    3 => self.moveQuickPanelDocumentMatch(if (key.modifiers.shift) -1 else 1),
                    6 => self.toggleQuickPanelCaseSensitive(),
                    7 => self.toggleQuickPanelWholeWord(),
                    else => {},
                }
                return true;
            },
            .char => |char| {
                if (key.modifiers.ctrl) return true;
                var bytes: [4]u8 = undefined;
                const len = encodeUtf8(char, &bytes) catch return true;
                self.quickPanelInsertText(bytes[0..len]);
                return true;
            },
            else => return true,
        }
    }

    fn executeSelectedQuickPanelItem(self: *LinuxGuiState) void {
        switch (self.quick_panel.mode) {
            .open_workspace => {
                if (self.quick_panel.query.items.len == 0) return self.message("type a workspace path", .{});
                const path = self.allocator.dupe(u8, self.quick_panel.query.items) catch |err| return self.message("open failed: {s}", .{@errorName(err)});
                defer self.allocator.free(path);
                self.quick_panel.close();
                self.openWorkspace(path);
            },
            .find_file => {
                const item = self.quick_panel.selectedFile() orelse return self.message("no file match", .{});
                const path = self.allocator.dupe(u8, item.path) catch |err| return self.message("open failed: {s}", .{@errorName(err)});
                defer self.allocator.free(path);
                self.quick_panel.close();
                self.openRelativeLocation(path, 0, 0);
            },
            .find_document => {
                const item = self.quick_panel.selectedDocumentMatch() orelse return self.message("no match", .{});
                const start = item.byte_offset;
                const end = item.end_offset;
                self.quick_panel.close();
                self.selectActiveDocumentRange(start, end, "found match");
            },
            .replace_document => {
                const item = self.quick_panel.selectedDocumentMatch() orelse return self.message("no replacement target", .{});
                const request = parseReplaceRequest(self.quick_panel.query.items) orelse return self.message("type search=>replacement", .{});
                const replacement = self.allocator.dupe(u8, request.replace) catch |err| return self.message("replace failed: {s}", .{@errorName(err)});
                defer self.allocator.free(replacement);
                const start = item.byte_offset;
                const end = item.end_offset;
                self.quick_panel.close();
                self.replaceActiveDocumentRange(start, end, replacement);
            },
            .rename_symbol => {
                const request = renameRequest(self.quick_panel.query.items) orelse return self.message("type old_name=>new_name", .{});
                const old_name = self.allocator.dupe(u8, request.find) catch |err| return self.message("rename failed: {s}", .{@errorName(err)});
                defer self.allocator.free(old_name);
                const new_name = self.allocator.dupe(u8, request.replace) catch |err| return self.message("rename failed: {s}", .{@errorName(err)});
                defer self.allocator.free(new_name);
                self.quick_panel.close();
                self.renameWorkspaceSymbol(old_name, new_name);
            },
            .search_workspace => {
                const item = self.quick_panel.selectedSearchResult() orelse return self.message("no workspace match", .{});
                const path = self.allocator.dupe(u8, item.path) catch |err| return self.message("open failed: {s}", .{@errorName(err)});
                defer self.allocator.free(path);
                const line = item.line;
                const column = item.column;
                self.quick_panel.close();
                self.openRelativeLocation(path, line, column);
            },
            .new_file => {
                if (self.quick_panel.query.items.len == 0) return self.message("type a workspace-relative path", .{});
                const path = self.allocator.dupe(u8, self.quick_panel.query.items) catch |err| return self.message("new failed: {s}", .{@errorName(err)});
                defer self.allocator.free(path);
                self.quick_panel.close();
                const result = dispatcher.dispatch(&self.app, .{ .id = "file.new", .argument = path, .source = .command_palette }) catch |err| {
                    self.message("new failed: {s}", .{@errorName(err)});
                    return;
                };
                self.handleDispatchResult("file.new", result);
            },
            .run_task => {
                const item = self.quick_panel.selectedTask() orelse return self.message("no task", .{});
                const name = self.allocator.dupe(u8, item.name) catch |err| return self.message("task failed: {s}", .{@errorName(err)});
                defer self.allocator.free(name);
                self.quick_panel.close();
                self.runTaskByName(name);
            },
            .document_symbols => {
                const item = self.quick_panel.selectedSymbol() orelse return self.message("no symbol selected", .{});
                const offset = item.byte_offset;
                self.quick_panel.close();
                self.jumpToActiveDocumentOffset(offset, "opened symbol");
            },
        }
    }

    fn runTaskByName(self: *LinuxGuiState, name: []const u8) void {
        const queued = dispatcher.dispatch(&self.app, .{ .id = "task.run", .argument = name, .source = .command_palette }) catch |err| {
            self.message("task failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "task queue failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult("task.run", queued);
        if (std.meta.activeTag(queued) != .completed) return;

        const run_result = dispatcher.dispatch(&self.app, .{ .id = "task.run_next", .source = .task }) catch |err| {
            self.message("task run failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "task run failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult("task.run_next", run_result);
        self.bottom_panel = .output;
    }

    fn normalizeActiveDocumentNewlines(self: *LinuxGuiState, newline: document_mod.Newline) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const changed = doc.normalizeNewlines(newline) catch |err| return self.message("newline normalize failed: {s}", .{@errorName(err)});
        self.selection_anchor = null;
        self.ensureEditorCursorVisible();
        if (changed) {
            const result_message = switch (newline) {
                .lf => "normalized line endings to LF",
                .crlf => "normalized line endings to CRLF",
                else => "normalized line endings",
            };
            self.refreshActiveSecurityFindings(result_message);
        } else {
            self.message("line endings already normalized", .{});
        }
    }

    fn sanitizeActiveDocumentHiddenControls(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
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
            sanitized.writer.writeByte(doc.text.bytes[index]) catch |err| return self.message("sanitize failed: {s}", .{@errorName(err)});
            index += 1;
        }

        if (removed == 0) return self.message("no hidden controls to clean", .{});

        doc.replaceRange(0, doc.text.bytes.len, sanitized.written()) catch |err| return self.message("sanitize failed: {s}", .{@errorName(err)});
        const target_line = @min(before_cursor.line, doc.text.lineCount() - 1);
        const target_column = @min(before_cursor.column, doc.text.lineSlice(target_line).len);
        const target_offset = doc.text.lineColumnToOffset(target_line, target_column) catch @min(before_cursor.byte_offset, doc.text.bytes.len);
        doc.cursor.position = doc.positionFromOffset(target_offset) catch doc.cursor.position;
        self.selection_anchor = null;
        self.ensureEditorCursorVisible();
        self.refreshActiveSecurityFindings("removed hidden control markers");
    }

    fn refreshActiveSecurityFindings(self: *LinuxGuiState, text: []const u8) void {
        const result = dispatcher.dispatch(&self.app, .{ .id = "security.scan_current", .source = .command_palette }) catch |err| {
            self.message("security scan failed: {s}", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult("security.scan_current", result);
        self.refreshLinuxSelfProtection();
        self.bottom_panel = .security;
        switch (result) {
            .completed => self.message("{s}", .{text}),
            .blocked => |reason| self.message("{s}", .{reason}),
            .unknown_command => self.message("security scan command missing", .{}),
            .no_active_document => self.message("no active document", .{}),
            .external_command => {},
            .unsupported => |reason| self.message("{s}", .{reason}),
        }
    }

    fn jumpToActiveDocumentOffset(self: *LinuxGuiState, offset: usize, text: []const u8) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        self.selection_anchor = null;
        const clamped = @min(offset, doc.text.bytes.len);
        navigation.setCursor(doc, doc.positionFromOffset(clamped) catch doc.cursor.position);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.message("{s}", .{text});
    }

    fn selectActiveDocumentRange(self: *LinuxGuiState, start: usize, end: usize, text: []const u8) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const clamped_start = @min(start, doc.text.bytes.len);
        const clamped_end = @min(end, doc.text.bytes.len);
        self.selection_anchor = clamped_start;
        navigation.setCursor(doc, doc.positionFromOffset(clamped_end) catch doc.cursor.position);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.message("{s}", .{text});
    }

    fn replaceActiveDocumentRange(self: *LinuxGuiState, start: usize, end: usize, replacement: []const u8) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const clamped_start = @min(start, doc.text.bytes.len);
        const clamped_end = @min(end, doc.text.bytes.len);
        if (clamped_start > clamped_end) return self.message("invalid replacement range", .{});
        doc.replaceRange(clamped_start, clamped_end, replacement) catch |err| return self.message("replace failed: {s}", .{@errorName(err)});
        self.selection_anchor = null;
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.message("replaced match", .{});
    }

    fn replaceAllFromQuickPanel(self: *LinuxGuiState) void {
        if (self.quick_panel.mode != .replace_document) return;
        const request = parseReplaceRequest(self.quick_panel.query.items) orelse return self.message("type search=>replacement", .{});
        const find = self.allocator.dupe(u8, request.find) catch |err| return self.message("replace failed: {s}", .{@errorName(err)});
        defer self.allocator.free(find);
        const replacement = self.allocator.dupe(u8, request.replace) catch |err| return self.message("replace failed: {s}", .{@errorName(err)});
        defer self.allocator.free(replacement);
        const options = self.quick_panel.search_options;
        self.quick_panel.close();
        self.replaceAllActiveDocumentMatches(find, replacement, options);
    }

    fn replaceAllActiveDocumentMatches(self: *LinuxGuiState, find: []const u8, replacement: []const u8, options: literal_search.Options) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const matches = literal_search.findAll(self.allocator, doc.text.bytes, find, options) catch |err| return self.message("replace failed: {s}", .{@errorName(err)});
        defer self.allocator.free(matches);
        if (matches.len == 0) return self.message("no matches to replace", .{});

        var next: std.Io.Writer.Allocating = .init(self.allocator);
        defer next.deinit();
        var cursor: usize = 0;
        for (matches) |match| {
            next.writer.writeAll(doc.text.bytes[cursor..match.start]) catch |err| return self.message("replace failed: {s}", .{@errorName(err)});
            next.writer.writeAll(replacement) catch |err| return self.message("replace failed: {s}", .{@errorName(err)});
            cursor = match.end;
        }
        next.writer.writeAll(doc.text.bytes[cursor..]) catch |err| return self.message("replace failed: {s}", .{@errorName(err)});

        const first_start = matches[0].start;
        doc.replaceRange(0, doc.text.bytes.len, next.written()) catch |err| return self.message("replace failed: {s}", .{@errorName(err)});
        const target = @min(first_start + replacement.len, doc.text.bytes.len);
        navigation.setCursor(doc, doc.positionFromOffset(target) catch doc.cursor.position);
        self.selection_anchor = null;
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.message("replaced all {d} match(es)", .{matches.len});
    }

    fn findLastDocumentSearch(self: *LinuxGuiState, direction: SearchDirection) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        if (self.last_document_search_query.items.len == 0) {
            self.openQuickPanel(.find_document);
            return;
        }
        const matches = literal_search.findAll(self.allocator, doc.text.bytes, self.last_document_search_query.items, self.last_document_search_options) catch |err| return self.message("find failed: {s}", .{@errorName(err)});
        defer self.allocator.free(matches);
        if (matches.len == 0) return self.message("no matches", .{});

        const cursor = doc.cursor.position.byte_offset;
        const index = switch (direction) {
            .forward => findNextMatchIndex(matches, cursor),
            .backward => findPreviousMatchIndex(matches, cursor),
        };
        const match = matches[index];
        self.selectActiveDocumentRange(match.start, match.end, "found match");
    }

    fn gotoLocalDefinitionAtCursor(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const name = identifierAtOffset(doc.text.bytes, doc.cursor.position.byte_offset) orelse return self.message("no identifier under cursor", .{});
        const path = doc.path orelse "(scratch)";
        var index = symbols_mod.collectTopLevel(self.allocator, doc.text.bytes, path) catch |err| return self.message("symbol scan failed: {s}", .{@errorName(err)});
        defer index.deinit();

        for (index.symbols) |symbol| {
            if (!std.mem.eql(u8, symbol.name, name)) continue;
            self.selection_anchor = null;
            navigation.setCursor(doc, symbol.range.start);
            self.app.focus = .editor;
            self.app.mode = .insert;
            self.ensureEditorCursorVisible();
            self.message("jumped to definition", .{});
            return;
        }
        self.message("no local top-level definition", .{});
    }

    fn findReferencesAtCursor(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const name = identifierAtOffset(doc.text.bytes, doc.cursor.position.byte_offset) orelse return self.message("no identifier under cursor", .{});
        const owned_name = self.allocator.dupe(u8, name) catch |err| return self.message("reference search failed: {s}", .{@errorName(err)});
        defer self.allocator.free(owned_name);

        const results = workspace_search.search(self.allocator, &self.app.workspace, owned_name, .{
            .literal_options = .{ .whole_word = true },
            .max_file_bytes = 2 * 1024 * 1024,
            .max_results = 1024,
        }) catch |err| return self.message("reference search failed: {s}", .{@errorName(err)});
        defer {
            for (results) |*item| item.deinit(self.allocator);
            self.allocator.free(results);
        }

        self.bottom_panel = .output;
        self.appendOutput(.stdout, "references for {s}: {d}\n", .{ owned_name, results.len });
        for (results[0..@min(results.len, @as(usize, 80))]) |item| {
            self.appendOutput(.stdout, "{s}:{d}:{d}: {s}\n", .{ item.path, item.line + 1, item.column + 1, item.preview });
        }
        if (results.len > 80) self.appendOutput(.stdout, "... {d} more references\n", .{results.len - 80});
        self.message("found {d} reference(s)", .{results.len});
    }

    fn renameWorkspaceSymbol(self: *LinuxGuiState, old_name: []const u8, new_name: []const u8) void {
        if (std.mem.eql(u8, old_name, new_name)) return self.message("rename target unchanged", .{});
        const results = workspace_search.search(self.allocator, &self.app.workspace, old_name, .{
            .literal_options = .{ .whole_word = true },
            .max_file_bytes = 2 * 1024 * 1024,
            .max_results = 2048,
        }) catch |err| return self.message("rename failed: {s}", .{@errorName(err)});
        defer {
            for (results) |*item| item.deinit(self.allocator);
            self.allocator.free(results);
        }
        if (results.len == 0) return self.message("no references to rename", .{});

        var replaced: usize = 0;
        var skipped: usize = 0;
        var index = results.len;
        while (index > 0) {
            index -= 1;
            const item = results[index];
            const absolute = std.fs.path.join(self.allocator, &.{ self.app.workspace.root_path, item.path }) catch |err| return self.message("rename path failed: {s}", .{@errorName(err)});
            defer self.allocator.free(absolute);

            const doc_index = self.app.documents.openFile(absolute) catch |err| {
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

        self.selection_anchor = null;
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.bottom_panel = .output;
        self.appendOutput(.stdout, "rename preview: {s} -> {s}, changed {d}, skipped {d}. Save changed tabs to write files.\n", .{ old_name, new_name, replaced, skipped });
        self.message("rename preview changed {d} reference(s)", .{replaced});
    }

    fn openWorkspace(self: *LinuxGuiState, root_path: []const u8) void {
        const next = app_mod.App.init(self.allocator, root_path) catch |err| {
            self.message("workspace open failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "workspace open failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.app.deinit();
        self.app = next;
        self.quick_panel.close();
        self.file_scroll_line = 0;
        self.editor_scroll_line = 0;
        self.output_scroll_line = 0;
        self.git_scroll_line = 0;
        self.extensions_scroll_line = 0;
        self.diagnostics_scroll_line = 0;
        self.security_scroll_line = 0;
        self.tutorial_scroll_line = 0;
        self.publish_scroll_line = 0;
        self.bottom_panel = .output;
        self.message("workspace opened", .{});
        self.appendOutput(.stdout, "opened workspace: {s}\n", .{self.app.workspace.root_path});
        self.refreshGitOverview();
        self.execute("security.audit_workspace", .startup);
    }

    fn handleKey(self: *LinuxGuiState, key: event_mod.KeyEvent) void {
        if (self.handleQuickPanelKey(key)) return;

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
                2 => {
                    self.openRenamePanel();
                    return;
                },
                3 => {
                    self.findLastDocumentSearch(if (key.modifiers.shift) .backward else .forward);
                    return;
                },
                8 => {
                    self.bottom_panel = .diagnostics;
                    self.execute("diagnostics.next", .keybinding);
                    return;
                },
                12 => {
                    if (key.modifiers.shift) {
                        self.findReferencesAtCursor();
                    } else {
                        self.gotoLocalDefinitionAtCursor();
                    }
                    return;
                },
                else => {},
            }
        }

        if (key.modifiers.ctrl) {
            switch (key.code) {
                .char => |char| {
                    if (key.modifiers.shift and (char == 'p' or char == 'P')) {
                        self.execute("view.command_palette", .keybinding);
                        return;
                    }
                    if (key.modifiers.shift and (char == 'o' or char == 'O')) {
                        self.openQuickPanel(.document_symbols);
                        return;
                    }
                    if (char == 'o' or char == 'O') {
                        self.openQuickPanel(.open_workspace);
                        return;
                    }
                    if (char == 'p' or char == 'P') {
                        self.openQuickPanel(.find_file);
                        return;
                    }
                    if (key.modifiers.shift and (char == 'f' or char == 'F')) {
                        self.openQuickPanel(.search_workspace);
                        return;
                    }
                    if (char == 'f' or char == 'F') {
                        self.openQuickPanel(.find_document);
                        return;
                    }
                    if (char == 'h' or char == 'H') {
                        self.openQuickPanel(.replace_document);
                        return;
                    }
                    if (char == 'n' or char == 'N') {
                        self.openQuickPanel(.new_file);
                        return;
                    }
                    if (char == 'r' or char == 'R') {
                        self.openQuickPanel(.run_task);
                        return;
                    }
                    if (key.modifiers.shift and (char == 'x' or char == 'X')) {
                        self.runHeaderAction(.extensions);
                        return;
                    }
                    if (key.modifiers.shift and (char == 'l' or char == 'L')) {
                        self.runHeaderAction(.publish);
                        return;
                    }
                    if (char == 'b' or char == 'B') {
                        self.runHeaderAction(.build);
                        return;
                    }
                    if (char == 't' or char == 'T') {
                        self.runHeaderAction(.test_run);
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
                        if (key.modifiers.alt) {
                            self.runHeaderAction(.scan);
                            return;
                        }
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

    fn handlePointer(self: *LinuxGuiState, button: u8, x: i16, y: i16) void {
        if (button == 4 or button == 5) {
            const delta: isize = if (button == 4) -3 else 3;
            if (x < FILE_WIDTH) {
                self.scrollFileTree(delta);
            } else if (y < self.bottomTop()) {
                self.scrollEditor(delta);
            } else if (y < self.window_height - STATUS_HEIGHT) {
                self.scrollBottomPanel(delta);
            }
            return;
        }
        if (button != 1) return;
        self.handleClick(x, y);
    }

    fn handleClick(self: *LinuxGuiState, x: i16, y: i16) void {
        if (self.quick_panel.visible) {
            if (self.handleQuickPanelClick(x, y)) return;
        }

        if (self.app.palette.visible) {
            if (self.handlePaletteClick(x, y)) return;
        }

        if (headerActionAt(x, y)) |action| {
            self.runHeaderAction(action);
            return;
        }

        if (documentTabAt(self, x, y)) |index| {
            self.app.documents.switchTo(index) catch |err| {
                self.message("tab switch failed: {s}", .{@errorName(err)});
                return;
            };
            self.app.focus = .editor;
            self.message("switched document", .{});
            return;
        }

        const bottom = self.bottomTop();
        if (y >= 78 and y < bottom and x < FILE_WIDTH) {
            const row = @divTrunc(@as(isize, y - 98), LINE_HEIGHT);
            if (row >= 0) {
                const index = self.file_scroll_line + @as(usize, @intCast(row));
                if (index < self.app.workspace.entries.items.len) {
                    self.app.file_cursor = index;
                    self.app.focus = .files;
                    const opened = self.app.openSelectedWorkspaceEntry() catch |err| {
                        self.message("open failed: {s}", .{@errorName(err)});
                        return;
                    };
                    if (opened) {
                        self.app.mode = .insert;
                        self.message("opened selected file", .{});
                    } else {
                        self.message("selected workspace folder", .{});
                    }
                }
            }
            return;
        }

        if (y >= HEADER_HEIGHT and y < bottom and x >= FILE_WIDTH) {
            self.app.focus = .editor;
            self.setCursorFromEditorClick(x, y);
            if (self.app.documents.active() != null) self.app.mode = .insert;
            return;
        }

        if (y >= bottom and y < bottom + 34) {
            if (bottomPanelAt(self, x, y)) |panel| self.bottom_panel = panel;
            return;
        }

        if (y >= bottom + 40 and y < self.window_height - STATUS_HEIGHT) {
            if (self.handleBottomPanelContentClick(x, y)) return;
        }
    }

    fn handleBottomPanelContentClick(self: *LinuxGuiState, x: i16, y: i16) bool {
        const bottom = self.bottomTop();
        switch (self.bottom_panel) {
            .security => {
                if (securityPanelActionAt(self, x, y)) |action| {
                    self.executeSecurityPanelAction(action);
                    return true;
                }
                const row = @divTrunc(@as(isize, y - securityFindingsTop(self)), LINE_HEIGHT);
                if (row < 0) return true;
                const index = self.security_scroll_line + @as(usize, @intCast(row));
                if (index >= self.app.security_findings.items.items.len) return true;
                const finding = self.app.security_findings.items.items[index];
                const line = if (finding.line > 0) finding.line - 1 else 0;
                self.openRelativeLocation(finding.path, line, finding.column);
                return true;
            },
            .diagnostics => {
                const row = @divTrunc(@as(isize, y - (bottom + 72)), LINE_HEIGHT);
                if (row < 0) return true;
                const index = self.diagnostics_scroll_line + @as(usize, @intCast(row));
                if (index >= self.app.diagnostics.items.items.len) return true;
                const item = self.app.diagnostics.items.items[index];
                self.openRelativeLocation(item.path, item.range.start.line, item.range.start.column);
                return true;
            },
            .git => {
                if (gitPanelActionAt(self, x, y)) |action| {
                    self.executeGitPanelAction(action);
                    return true;
                }
                if (gitChangeRowAt(self, y)) |index| {
                    if (self.git_overview) |overview| {
                        if (index < overview.changes.len) {
                            self.openRelativeLocation(overview.changes[index].path, 0, 0);
                        }
                    }
                } else {
                    self.executeGitPanelAction(.diff);
                }
                return true;
            },
            .extensions => {
                if (extensionPanelActionAt(self, x, y)) |action| {
                    self.executeExtensionPanelAction(action);
                    return true;
                }
                if (extensionRowAt(self, y)) |index| {
                    if (self.extensions_registry) |registry| {
                        if (index < registry.items.items.len) {
                            self.openRelativeLocation(registry.items.items[index].manifest_path, 0, 0);
                        }
                    }
                }
                return true;
            },
            .tutorial => {
                if (tutorialPanelActionAt(self, x, y)) |action| {
                    self.executeTutorialPanelAction(action);
                    return true;
                }
                return true;
            },
            .publish => {
                if (publishPanelActionAt(self, x, y)) |action| {
                    self.executePublishPanelAction(action);
                    return true;
                }
                return true;
            },
            else => return true,
        }
    }

    fn openRelativeLocation(self: *LinuxGuiState, relative: []const u8, line: usize, column: usize) void {
        const absolute = std.fs.path.join(self.allocator, &.{ self.app.workspace.root_path, relative }) catch |err| {
            self.message("path failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(absolute);

        const index = self.app.documents.openFile(absolute) catch |err| {
            self.message("open failed: {s}", .{@errorName(err)});
            return;
        };
        const doc = &self.app.documents.documents.items[index];
        const safe_line = @min(line, if (doc.text.lineCount() == 0) 0 else doc.text.lineCount() - 1);
        const safe_column = @min(column, doc.text.lineSlice(safe_line).len);
        const offset = doc.text.lineColumnToOffset(safe_line, safe_column) catch 0;
        navigation.setCursor(doc, doc.positionFromOffset(offset) catch doc.cursor.position);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.message("opened {s}:{d}:{d}", .{ relative, safe_line + 1, safe_column + 1 });
    }

    fn handlePaletteClick(self: *LinuxGuiState, x: i16, y: i16) bool {
        const left: i16 = 245;
        const top: i16 = 92;
        if (x < left or x > left + 790 or y < top or y > top + 420) return false;
        const row_top: i16 = top + 89;
        if (y >= row_top) {
            const row = @divTrunc(@as(isize, y - row_top), LINE_HEIGHT + 4);
            if (row >= 0) {
                const index: usize = @intCast(row);
                if (index < self.app.palette.matches.items.len) {
                    self.app.palette.selected_index = index;
                    const selected = self.app.palette.selected() orelse return true;
                    self.app.palette.close();
                    self.app.mode = .normal;
                    self.execute(selected.id, .command_palette);
                    return true;
                }
            }
        }
        return true;
    }

    fn handleQuickPanelClick(self: *LinuxGuiState, x: i16, y: i16) bool {
        const left: i16 = 245;
        const top: i16 = 92;
        if (x < left or x > left + 790 or y < top or y > top + 420) return false;
        const row_top: i16 = top + 89;
        if (y >= row_top) {
            const row = @divTrunc(@as(isize, y - row_top), LINE_HEIGHT + 4);
            if (row >= 0) {
                const index: usize = @intCast(row);
                if (index < self.quick_panel.itemCount()) {
                    self.quick_panel.selected_index = index;
                    self.executeSelectedQuickPanelItem();
                    return true;
                }
            }
        }
        return true;
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

    fn bottomRowsFrom(self: *const LinuxGuiState, top: i16) usize {
        return @intCast(@max(@divTrunc(self.window_height - top - STATUS_HEIGHT - 8, LINE_HEIGHT), 1));
    }

    fn scrollBottomPanel(self: *LinuxGuiState, delta: isize) void {
        switch (self.bottom_panel) {
            .output => {
                const visible = self.bottomRowsFrom(self.bottomTop() + 58);
                const total = self.app.process_console.lines.items.len;
                const max_start = if (total > visible) total - visible else 0;
                var start = if (self.output_scroll_line == 0) max_start else @min(self.output_scroll_line - 1, max_start);
                start = scrollValue(start, max_start, delta);
                self.output_scroll_line = if (start == max_start) 0 else start + 1;
            },
            .git => {
                const total = if (self.git_overview) |overview| overview.changes.len else 0;
                const visible = self.bottomRowsFrom(gitChangesTop(self));
                const max_start = if (total > visible) total - visible else 0;
                self.git_scroll_line = scrollValue(self.git_scroll_line, max_start, delta);
            },
            .extensions => {
                const total = if (self.extensions_registry) |registry| registry.items.items.len else 0;
                const visible = self.bottomRowsFrom(self.bottomTop() + 86);
                const max_start = if (total > visible) total - visible else 0;
                self.extensions_scroll_line = scrollValue(self.extensions_scroll_line, max_start, delta);
            },
            .diagnostics => {
                const total = self.app.diagnostics.items.items.len;
                const visible = self.bottomRowsFrom(self.bottomTop() + 86);
                const max_start = if (total > visible) total - visible else 0;
                self.diagnostics_scroll_line = scrollValue(self.diagnostics_scroll_line, max_start, delta);
            },
            .security => {
                const total = self.app.security_findings.items.items.len;
                const visible = self.bottomRowsFrom(securityFindingsTop(self));
                const max_start = if (total > visible) total - visible else 0;
                self.security_scroll_line = scrollValue(self.security_scroll_line, max_start, delta);
            },
            .tutorial => {
                const total = tutorialLines(self.tutorial_language).len;
                const visible = self.bottomRowsFrom(self.bottomTop() + 86);
                const max_start = if (total > visible) total - visible else 0;
                self.tutorial_scroll_line = scrollValue(self.tutorial_scroll_line, max_start, delta);
            },
            .publish => {
                const total = publishLines().len;
                const visible = self.bottomRowsFrom(self.bottomTop() + 86);
                const max_start = if (total > visible) total - visible else 0;
                self.publish_scroll_line = scrollValue(self.publish_scroll_line, max_start, delta);
            },
        }
    }
};

pub fn run(allocator: std.mem.Allocator, root_path: []const u8, environ: *const std.process.Environ.Map) !void {
    var state = try LinuxGuiState.init(allocator, root_path);
    defer state.deinit();

    state.enableLinuxSelfProtection();
    state.refreshGitOverview();
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
                state.handlePointer(event[1], @bitCast(readLe16(event[24..26])), @bitCast(readLe16(event[26..28])));
                try draw(&x11, &state);
            },
            12 => try draw(&x11, &state),
            22 => {
                state.resize(readLe16(event[20..22]), readLe16(event[22..24]));
                try draw(&x11, &state);
            },
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
    const width_u = toU16(state.window_width);
    const height_u = toU16(state.window_height);
    const bottom = state.bottomTop();
    try x11.fillRect(x11.gc.bg, 0, 0, width_u, height_u);
    try x11.fillRect(x11.gc.panel, 0, 0, width_u, HEADER_HEIGHT);
    try x11.fillRect(x11.gc.line, 0, HEADER_HEIGHT - 1, width_u, 1);
    try x11.fillRect(x11.gc.panel, 0, HEADER_HEIGHT, FILE_WIDTH, toU16(state.window_height - HEADER_HEIGHT - STATUS_HEIGHT));
    try x11.fillRect(x11.gc.line, FILE_WIDTH, HEADER_HEIGHT, 1, toU16(state.window_height - HEADER_HEIGHT - STATUS_HEIGHT));
    try x11.fillRect(x11.gc.panel_2, 0, bottom, width_u, toU16(state.window_height - bottom - STATUS_HEIGHT));
    try x11.fillRect(x11.gc.cyan, 16, 14, 30, 30);

    try x11.text(x11.gc.bg, 26, 35, "Z");
    try x11.text(x11.gc.text, 58, 34, "ZIDE");
    try x11.text(x11.gc.muted, 152, 34, "Linux GUI / direct X11 / shared ZIDE core");
    try drawHeaderActions(x11);

    try x11.text(x11.gc.cyan, 18, 86, "FILES");
    try x11.text(x11.gc.muted, 112, 86, "click opens / Enter opens / j,k move");
    var y: i16 = 112;
    state.ensureFileCursorVisible();
    const max_files = @min(app.workspace.entries.items.len - @min(state.file_scroll_line, app.workspace.entries.items.len), state.visibleFileRows());
    for (app.workspace.entries.items[state.file_scroll_line .. state.file_scroll_line + max_files], 0..) |entry, visible_index| {
        const index = state.file_scroll_line + visible_index;
        const gc = if (index == app.file_cursor) x11.gc.cyan else if (entry.kind == .directory) x11.gc.green else x11.gc.text;
        if (index == app.file_cursor) try x11.fillRect(x11.gc.panel_2, 8, y - 14, FILE_WIDTH - 16, LINE_HEIGHT);
        var line_buf: [280]u8 = undefined;
        const prefix: []const u8 = if (entry.kind == .directory) "+ " else "  ";
        const indent = @min(entry.depth * 2, @as(usize, 12));
        const lang = if (entry.kind == .file) modes.label(entry.language) else "";
        @memset(line_buf[0..indent], ' ');
        const suffix = std.fmt.bufPrint(line_buf[indent..], "{s}{s}  {s}", .{ prefix, entry.path, lang }) catch clipped: {
            const available = line_buf.len - indent;
            const clipped_path = entry.path[0..@min(entry.path.len, available)];
            @memcpy(line_buf[indent..][0..clipped_path.len], clipped_path);
            break :clipped line_buf[indent..][0..clipped_path.len];
        };
        const label = line_buf[0 .. indent + suffix.len];
        var ascii_buf: [260]u8 = undefined;
        try x11.text(gc, 18, y, asciiInto(ascii_buf[0..], label));
        y += LINE_HEIGHT;
    }
    try drawFileScrollbar(x11, state);

    try drawEditor(x11, state);
    try drawBottomPanel(x11, state);
    if (state.quick_panel.visible) try drawQuickPanel(x11, state);
    if (app.palette.visible) try drawPalette(x11, state);

    try x11.fillRect(x11.gc.cyan, 0, state.window_height - STATUS_HEIGHT, width_u, STATUS_HEIGHT);
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
    try x11.text(x11.gc.bg, 14, state.window_height - 9, status);
}

fn drawHeaderActions(x11: *X11) !void {
    inline for (header_actions) |action| {
        const rect = headerActionRect(action);
        try x11.fillRect(x11.gc.panel_2, rect.left, rect.top, @intCast(rect.right - rect.left), @intCast(rect.bottom - rect.top));
        try x11.text(x11.gc.cyan, rect.left + 10, rect.top + 20, headerActionLabel(action));
    }
}

fn drawFileScrollbar(x11: *X11, state: *LinuxGuiState) !void {
    const total = state.app.workspace.entries.items.len;
    const visible = state.visibleFileRows();
    if (total <= visible or visible == 0) return;
    const bottom = state.bottomTop();
    const track_top: i16 = 102;
    const track_h: i16 = @max(bottom - track_top - 12, 20);
    try x11.fillRect(x11.gc.line, FILE_WIDTH - 9, track_top, 3, toU16(track_h));
    const thumb_h: i16 = @max(@as(i16, @intCast((@as(usize, @intCast(track_h)) * visible) / total)), 18);
    const max_scroll = total - visible;
    const travel = @max(track_h - thumb_h, 1);
    const thumb_y = track_top + @as(i16, @intCast((@as(usize, @intCast(travel)) * state.file_scroll_line) / max_scroll));
    try x11.fillRect(x11.gc.cyan, FILE_WIDTH - 10, thumb_y, 5, toU16(thumb_h));
}

fn drawEditor(x11: *X11, state: *LinuxGuiState) !void {
    const app = &state.app;
    const bottom = state.bottomTop();
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
        if (tab_x > state.window_width - 220) break;
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

    const visible_rows: usize = @intCast(@max(@divTrunc(bottom - EDITOR_TEXT_TOP - 16, LINE_HEIGHT), 1));
    const cursor_line = doc.cursor.position.line;
    if (cursor_line < state.editor_scroll_line) state.editor_scroll_line = cursor_line;
    if (visible_rows > 0 and cursor_line >= state.editor_scroll_line + visible_rows) {
        state.editor_scroll_line = cursor_line - visible_rows + 1;
    }

    var line_y: i16 = EDITOR_TEXT_TOP;
    var row: usize = 0;
    const selection = state.selectedRange(doc);
    while (row < visible_rows and state.editor_scroll_line + row < doc.text.lineCount()) : (row += 1) {
        const line_index = state.editor_scroll_line + row;
        const line = doc.text.lineSlice(line_index);
        const selected = line_index == cursor_line;
        if (selected) try x11.fillRect(x11.gc.panel_2, EDITOR_LEFT - 8, line_y - 14, toU16(state.window_width - EDITOR_LEFT - 20), LINE_HEIGHT);

        if (selection) |range| {
            if (doc.text.lineStart(line_index)) |line_start| {
                const line_end = line_start + line.len;
                const start = @max(range.start, line_start);
                const end = @min(range.end, line_end);
                if (start < end) {
                    const start_col = @min(start - line_start, @as(usize, 140));
                    const end_col = @min(end - line_start, @as(usize, 140));
                    const select_x = EDITOR_LEFT + 56 + @as(i16, @intCast(start_col)) * 8;
                    const select_w: u16 = @intCast(@max(@as(i16, @intCast(end_col - start_col)) * 8, 8));
                    try x11.fillRect(x11.gc.line, select_x, line_y - 14, select_w, LINE_HEIGHT);
                }
            }
        }

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
    const bottom = state.bottomTop();
    try x11.fillRect(x11.gc.line, 0, bottom, toU16(state.window_width), 1);
    try drawPanelTab(x11, bottom, state.bottom_panel == .output, 18, "OUTPUT");
    try drawPanelTab(x11, bottom, state.bottom_panel == .git, 122, "GIT");
    try drawPanelTab(x11, bottom, state.bottom_panel == .extensions, 226, "EXT");
    try drawPanelTab(x11, bottom, state.bottom_panel == .diagnostics, 330, "DIAG");
    try drawPanelTab(x11, bottom, state.bottom_panel == .security, 434, "SEC");
    try drawPanelTab(x11, bottom, state.bottom_panel == .tutorial, 538, "HELP");
    try drawPanelTab(x11, bottom, state.bottom_panel == .publish, 642, "SHIP");

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

fn drawPanelTab(x11: *X11, bottom: i16, active: bool, x: i16, label: []const u8) !void {
    if (active) try x11.fillRect(x11.gc.cyan, x - 8, bottom + 8, 104, 24);
    try x11.text(if (active) x11.gc.bg else x11.gc.cyan, x, bottom + 27, label);
}

fn drawActionButton(x11: *X11, rect: HitRect, label: []const u8) !void {
    try x11.fillRect(x11.gc.panel_2, rect.left, rect.top, @intCast(rect.right - rect.left), @intCast(rect.bottom - rect.top));
    try x11.text(x11.gc.cyan, rect.left + 7, rect.top + 16, label);
}

fn drawScrollHint(x11: *X11, state: *const LinuxGuiState, total: usize, visible: usize, start: usize, y: i16) !void {
    if (total <= visible or visible == 0) return;
    var buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0..], "rows {d}-{d}/{d}", .{
        start + 1,
        @min(total, start + visible),
        total,
    }) catch return;
    const x = @max(@as(i16, 18), state.window_width - 170);
    try x11.text(x11.gc.cyan, x, y, text);
}

fn drawOutputPanel(x11: *X11, state: *LinuxGuiState) !void {
    const app = &state.app;
    const bottom = state.bottomTop();
    var y: i16 = bottom + 58;
    const max_lines: usize = @intCast(@max(@divTrunc(state.window_height - bottom - STATUS_HEIGHT - 64, LINE_HEIGHT), 1));
    const max_start = if (app.process_console.lines.items.len > max_lines) app.process_console.lines.items.len - max_lines else 0;
    const start = if (state.output_scroll_line == 0) max_start else @min(state.output_scroll_line - 1, max_start);
    const limit = @min(app.process_console.lines.items.len, start + max_lines);
    try drawScrollHint(x11, state, app.process_console.lines.items.len, max_lines, start, bottom + 58);
    for (app.process_console.lines.items[start..limit]) |line| {
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
    const bottom = state.bottomTop();
    try drawSecurityPanelActions(x11, state);
    var header_buf: [180]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "{d} finding(s) / trust={s}", .{
        app.security_findings.items.items.len,
        @tagName(app.runtime.trust_state),
    }) catch "security status unavailable";
    try x11.text(x11.gc.green, 18, bottom + 58, header);
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
    try x11.text(x11.gc.amber, 18, bottom + 82, boundary);
    var linux_buf: [260]u8 = undefined;
    const linux_line = std.fmt.bufPrint(linux_buf[0..], "LINUX SELF nnp:{s}/{s} dump:{s}/{s} ambient:{s} seccomp:{s} cap_eff:{s} bound:{d}", .{
        flagLabel(state.linux_security.no_new_privs),
        flagLabel(state.linux_security.no_new_privs_set),
        flagLabel(state.linux_security.dumpable),
        flagLabel(state.linux_security.dumpable_set),
        flagLabel(state.linux_security.ambient_clear),
        seccompLabel(state.linux_security.seccomp_mode),
        state.linuxSecurityCapEffLabel(),
        state.linux_security.dangerous_bounding_caps,
    }) catch "LINUX SELF";
    try x11.text(x11.gc.cyan, 18, bottom + 106, linux_line);
    var cap_buf: [220]u8 = undefined;
    const cap_line = std.fmt.bufPrint(cap_buf[0..], "direct X11 / no toolkit host / dangerous bounding caps dropped:{d} failed:{d} / proc:{s}", .{
        state.linux_security.bounding_caps_dropped,
        state.linux_security.bounding_caps_drop_failed,
        if (state.linux_security.proc_status_read) "read" else "blocked",
    }) catch "linux cap boundary";
    try x11.text(x11.gc.muted, 18, bottom + 130, cap_line);
    var maps_buf: [260]u8 = undefined;
    const maps_line = std.fmt.bufPrint(maps_buf[0..], "PROC MAPS read:{s} total:{d} exec:{d} wx:{d} so:{d} anon-x:{d}", .{
        if (state.linux_security.proc_maps_read) "yes" else "no",
        state.linux_security.maps_total,
        state.linux_security.maps_executable,
        state.linux_security.maps_writable_executable,
        state.linux_security.maps_shared_objects,
        state.linux_security.maps_anonymous_executable,
    }) catch "PROC MAPS";
    try x11.text(if (state.linux_security.maps_writable_executable > 0) x11.gc.red else x11.gc.muted, 18, bottom + 154, maps_line);
    var fd_buf: [300]u8 = undefined;
    const fd_line = std.fmt.bufPrint(fd_buf[0..], "PROC FD read:{s} total:{d} no-cloexec:{d} unknown:{d} socket:{d} pipe:{d} memfd:{d} anon:{d} files:{d}", .{
        if (state.linux_security.proc_fd_read) "yes" else "no",
        state.linux_security.fd_total,
        state.linux_security.fd_cloexec_missing,
        state.linux_security.fd_cloexec_unknown,
        state.linux_security.fd_sockets,
        state.linux_security.fd_pipes,
        state.linux_security.fd_memfd,
        state.linux_security.fd_anon,
        state.linux_security.fd_files,
    }) catch "PROC FD";
    try x11.text(if (state.linux_security.fd_cloexec_missing > 3) x11.gc.amber else x11.gc.muted, 18, bottom + 178, fd_line);
    var y: i16 = securityFindingsTop(state);
    const visible = state.bottomRowsFrom(y);
    const start = @min(state.security_scroll_line, app.security_findings.items.items.len);
    const limit = @min(app.security_findings.items.items.len, start + visible);
    try drawScrollHint(x11, state, app.security_findings.items.items.len, visible, start, y);
    for (app.security_findings.items.items[start..limit]) |finding| {
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
    const bottom = state.bottomTop();
    try drawGitPanelActions(x11, state);
    try x11.text(x11.gc.green, 18, bottom + 58, "GIT / hook-free repository view");

    const overview = state.git_overview orelse {
        try x11.text(x11.gc.muted, 18, bottom + 86, "Press REFRESH. ZIDE reads .git directly without running hooks, filters, fsmonitor, or git status.");
        return;
    };

    if (!overview.present) {
        try x11.text(x11.gc.muted, 18, bottom + 86, "No Git repository detected in this workspace.");
        return;
    }

    var meta_buf: [720]u8 = undefined;
    const meta = std.fmt.bufPrint(meta_buf[0..], "branch:{s} commit:{s} index:v{d} entries:{d} tracked-clean:{d} changes:{d} workflows:{d}", .{
        overview.branch orelse "(detached)",
        if (overview.commit) |commit| commit[0..@min(commit.len, 12)] else "unknown",
        overview.index_version orelse 0,
        overview.index_entries,
        overview.clean_tracked,
        overview.changes.len,
        overview.workflow_files,
    }) catch "git overview";
    var meta_ascii: [720]u8 = undefined;
    try x11.text(x11.gc.muted, 18, bottom + 82, asciiInto(meta_ascii[0..], meta));

    var y: i16 = bottom + 108;
    if (overview.remotes.len > 0) {
        for (overview.remotes[0..@min(overview.remotes.len, @as(usize, 2))]) |remote| {
            var remote_buf: [720]u8 = undefined;
            const remote_line = if (remote.github) |github|
                std.fmt.bufPrint(remote_buf[0..], "remote:{s} github:{s}/{s} actions:{s}", .{ remote.name, github.owner, github.repo, github.actions_url }) catch remote.name
            else
                std.fmt.bufPrint(remote_buf[0..], "remote:{s} {s}", .{ remote.name, remote.url }) catch remote.name;
            var remote_ascii: [720]u8 = undefined;
            try x11.text(x11.gc.cyan, 18, y, asciiInto(remote_ascii[0..], remote_line));
            y += LINE_HEIGHT;
        }
    } else {
        try x11.text(x11.gc.muted, 18, y, "No remotes configured.");
        y += LINE_HEIGHT;
    }

    const max_rows = state.bottomRowsFrom(y);
    const start = @min(state.git_scroll_line, overview.changes.len);
    const limit = @min(overview.changes.len, start + max_rows);
    try drawScrollHint(x11, state, overview.changes.len, max_rows, start, y);
    var row: usize = 0;
    while (start + row < limit) : (row += 1) {
        const change = overview.changes[start + row];
        var row_buf: [720]u8 = undefined;
        const line = std.fmt.bufPrint(row_buf[0..], "{s}  {s}  +{d}/-{d}{s}", .{
            @tagName(change.status),
            change.path,
            change.additions,
            change.deletions,
            if (change.diff_available) " diff" else "",
        }) catch change.path;
        var row_ascii: [720]u8 = undefined;
        try x11.text(if (change.status == .deleted) x11.gc.red else x11.gc.muted, 18, y, asciiInto(row_ascii[0..], line));
        y += LINE_HEIGHT;
    }
    if (overview.changes.len == 0) {
        try x11.text(x11.gc.muted, 18, y, "No tracked or untracked changes found by the safe .git reader.");
    }
}

fn drawExtensionsPanel(x11: *X11, state: *LinuxGuiState) !void {
    const bottom = state.bottomTop();
    try drawExtensionPanelActions(x11, state);
    const registry = state.extensions_registry orelse {
        try x11.text(x11.gc.green, 18, bottom + 58, "EXTENSIONS / manifest-only scan");
        try x11.text(x11.gc.muted, 18, bottom + 86, "Press SCAN. ZIDE reads zide-extension.json manifests but does not execute extension code.");
        return;
    };

    var header_buf: [220]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "EXTENSIONS manifests:{d} loaded:{d} invalid:{d} high:{d} medium:{d}", .{
        registry.items.items.len,
        registry.countStatus(.loaded),
        registry.countStatus(.invalid),
        registry.countRisk(.high),
        registry.countRisk(.medium),
    }) catch "EXTENSIONS";
    try x11.text(x11.gc.green, 18, bottom + 58, header);

    var y: i16 = bottom + 86;
    const max_rows = state.bottomRowsFrom(y);
    const start = @min(state.extensions_scroll_line, registry.items.items.len);
    const limit = @min(registry.items.items.len, start + max_rows);
    try drawScrollHint(x11, state, registry.items.items.len, max_rows, start, y);
    var row: usize = 0;
    while (start + row < limit) : (row += 1) {
        const extension = registry.items.items[start + row];
        const risk = extension_registry.extensionRisk(extension);
        var cap_buf: [220]u8 = undefined;
        const caps = extensionCapabilitiesLabel(cap_buf[0..], extension);
        var row_buf: [900]u8 = undefined;
        const text = std.fmt.bufPrint(row_buf[0..], "[{s}/{s}] {s} {s}  cmd:{d} int:{d}  {s}  {s}", .{
            @tagName(extension.status),
            extension_registry.riskLabel(risk),
            extension.name,
            extension.version,
            extension.commands,
            extension.integrations,
            caps,
            extension.manifest_path,
        }) catch extension.manifest_path;
        var ascii_buf: [900]u8 = undefined;
        try x11.text(extensionRiskGc(x11, risk), 18, y, asciiInto(ascii_buf[0..], text));
        y += LINE_HEIGHT;
    }
    if (registry.items.items.len == 0) {
        try x11.text(x11.gc.muted, 18, y, "No zide-extension.json or zide.extension.json manifests found.");
    }
}

fn drawDiagnosticsPanel(x11: *X11, state: *LinuxGuiState) !void {
    const app = &state.app;
    const bottom = state.bottomTop();
    var header_buf: [160]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "DIAGNOSTICS total:{d}", .{app.diagnostics.items.items.len}) catch "DIAGNOSTICS";
    try x11.text(x11.gc.green, 18, bottom + 58, header);
    var y: i16 = bottom + 86;
    const visible = state.bottomRowsFrom(y);
    const start = @min(state.diagnostics_scroll_line, app.diagnostics.items.items.len);
    const limit = @min(app.diagnostics.items.items.len, start + visible);
    try drawScrollHint(x11, state, app.diagnostics.items.items.len, visible, start, y);
    for (app.diagnostics.items.items[start..limit]) |item| {
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
    const bottom = state.bottomTop();
    try drawTutorialPanelActions(x11, state);
    var header_buf: [220]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "HELP / ZIDE tour lang:{s} trust:{s} risk:{d}", .{
        @tagName(state.tutorial_language),
        @tagName(app.runtime.trust_state),
        app.security_findings.items.items.len,
    }) catch "HELP / ZIDE security tour";
    try x11.text(x11.gc.green, 18, bottom + 58, header);

    const lines = tutorialLines(state.tutorial_language);
    var y: i16 = bottom + 86;
    const visible = state.bottomRowsFrom(y);
    const start = @min(state.tutorial_scroll_line, lines.len);
    const limit = @min(lines.len, start + visible);
    try drawScrollHint(x11, state, lines.len, visible, start, y);
    for (lines[start..limit]) |line| {
        try x11.text(x11.gc.muted, 18, y, line);
        y += LINE_HEIGHT;
    }
}

fn drawPublishPanel(x11: *X11, state: *LinuxGuiState) !void {
    const bottom = state.bottomTop();
    try drawPublishPanelActions(x11, state);
    var header_buf: [260]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "SHIP release:{s} win:{s} linux:{s} workflows:{s}", .{
        if (workspaceHasAnyLicense(&state.app)) "licensed" else "no-license",
        if (workspaceFileExistsGui(&state.app, "zig-out/release/zide-windows-x86_64.zip")) "zip" else "missing",
        if (workspaceFileExistsGui(&state.app, "zig-out/release/zide-linux-x86_64.tar")) "tar" else "missing",
        if (workspaceHasPrefixGui(&state.app, ".github/workflows/")) "yes" else "none",
    }) catch "SHIP";
    try x11.text(x11.gc.green, 18, bottom + 58, header);

    var y: i16 = bottom + 86;
    const lines = publishLines();
    const visible = state.bottomRowsFrom(y);
    const start = @min(state.publish_scroll_line, lines.len);
    const limit = @min(lines.len, start + visible);
    try drawScrollHint(x11, state, lines.len, visible, start, y);
    for (lines[start..limit]) |line| {
        try x11.text(publishLineGc(x11, line), 18, y, line);
        y += LINE_HEIGHT;
    }
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
        if (y > state.window_height - STATUS_HEIGHT - 12) break;
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

fn drawQuickPanel(x11: *X11, state: *LinuxGuiState) !void {
    const left: i16 = 245;
    const top: i16 = 92;
    const width: u16 = 790;
    const height: u16 = 420;
    try x11.fillRect(x11.gc.panel, left, top, width, height);
    try x11.fillRect(x11.gc.green, left, top, width, 3);
    try x11.text(x11.gc.green, left + 18, top + 34, quickPanelTitle(state.quick_panel.mode));

    var query_buf: [520]u8 = undefined;
    try x11.text(x11.gc.text, left + 18, top + 66, asciiInto(query_buf[0..], state.quick_panel.query.items));

    var meta_buf: [160]u8 = undefined;
    const meta = std.fmt.bufPrint(meta_buf[0..], "{d} item(s)", .{state.quick_panel.itemCount()}) catch "";
    try x11.text(x11.gc.muted, left + 650, top + 34, meta);
    if (isDocumentSearchMode(state.quick_panel.mode)) {
        var options_buf: [220]u8 = undefined;
        const options = std.fmt.bufPrint(options_buf[0..], "F3 next  F6 {s}  F7 {s}{s}", .{
            if (state.quick_panel.search_options.case_sensitive) "case" else "ignore",
            if (state.quick_panel.search_options.whole_word) "word" else "partial",
            if (state.quick_panel.mode == .replace_document) "  Ctrl+Enter all" else "",
        }) catch "";
        try x11.text(x11.gc.muted, left + 18, top + 86, options);
    }

    var y: i16 = top + 104;
    const limit = @min(state.quick_panel.itemCount(), @as(usize, 12));
    var row: usize = 0;
    while (row < limit) : (row += 1) {
        const selected = row == state.quick_panel.selected_index;
        if (selected) try x11.fillRect(x11.gc.panel_2, left + 10, y - 15, width - 20, LINE_HEIGHT + 2);
        try drawQuickPanelRow(x11, state, left + 18, y, row, selected);
        y += LINE_HEIGHT + 4;
    }
    if (state.quick_panel.itemCount() == 0) {
        try x11.text(x11.gc.muted, left + 18, y, "No matches");
    }
}

fn drawQuickPanelRow(x11: *X11, state: *LinuxGuiState, x: i16, y: i16, row: usize, selected: bool) !void {
    const color = if (selected) x11.gc.green else x11.gc.text;
    var text_buf: [720]u8 = undefined;
    const text: []const u8 = switch (state.quick_panel.mode) {
        .find_file => blk: {
            const items = state.quick_panel.file_matches orelse break :blk "";
            if (row >= items.len) break :blk "";
            break :blk std.fmt.bufPrint(text_buf[0..], "{s}  {s}", .{ items[row].path, modes.label(items[row].language) }) catch items[row].path;
        },
        .find_document, .replace_document => blk: {
            const items = state.quick_panel.document_matches orelse break :blk "";
            if (row >= items.len) break :blk "";
            break :blk std.fmt.bufPrint(text_buf[0..], "{d}:{d}  {s}", .{ items[row].line + 1, items[row].column + 1, items[row].preview }) catch items[row].preview;
        },
        .rename_symbol => blk: {
            const request = renameRequest(state.quick_panel.query.items) orelse break :blk "Type old_name=>new_name";
            break :blk std.fmt.bufPrint(text_buf[0..], "{s} -> {s}", .{ request.find, request.replace }) catch "Rename";
        },
        .search_workspace => blk: {
            const items = state.quick_panel.search_results orelse break :blk "";
            if (row >= items.len) break :blk "";
            break :blk std.fmt.bufPrint(text_buf[0..], "{s}:{d}:{d}  {s}", .{ items[row].path, items[row].line + 1, items[row].column + 1, items[row].preview }) catch items[row].path;
        },
        .open_workspace => if (state.quick_panel.query.items.len > 0) "Open workspace path" else "",
        .new_file => if (state.quick_panel.query.items.len > 0) "Create file inside workspace" else "",
        .run_task => blk: {
            const items = state.quick_panel.task_matches orelse break :blk "";
            if (row >= items.len) break :blk "";
            break :blk std.fmt.bufPrint(text_buf[0..], "{s}  {s}", .{ items[row].name, items[row].executable }) catch items[row].name;
        },
        .document_symbols => blk: {
            const items = state.quick_panel.symbol_matches orelse break :blk "";
            if (row >= items.len) break :blk "";
            break :blk std.fmt.bufPrint(text_buf[0..], "{s}  {s}:{d}:{d}", .{ items[row].name, @tagName(items[row].kind), items[row].line + 1, items[row].column + 1 }) catch items[row].name;
        },
    };
    var ascii_buf: [720]u8 = undefined;
    try x11.text(color, x, y, asciiInto(ascii_buf[0..], text));
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

fn extensionRiskGc(x11: *X11, risk: extension_registry.Risk) u32 {
    return switch (risk) {
        .high => x11.gc.red,
        .medium => x11.gc.amber,
        .low => x11.gc.muted,
    };
}

fn extensionCapabilitiesLabel(buffer: []u8, extension: extension_registry.Extension) []const u8 {
    if (extension.capabilities.len == 0) return "cap:none";
    var len: usize = 0;
    appendBounded(buffer, &len, "cap:");
    for (extension.capabilities, 0..) |capability, index| {
        if (index >= 5) {
            appendBounded(buffer, &len, "...");
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

fn tutorialLines(language: TutorialLanguage) []const []const u8 {
    return switch (language) {
        .ja => &.{
            "== ZIDE JA TOUR ==",
            "F1: help. Ctrl+P: file. Ctrl+Shift+P: command. Ctrl+S: save with security gate.",
            "SEC: memory/exec/fs/net/deps/secret/text/path/git boundary wo miru panel.",
            "GIT: .git wo Zig de yomu. hooks/filters/fsmonitor/git status ha ugokasanai.",
            "EXT: manifest dake scan. extension code ha jikko shinai.",
            "SHIP: bundle/verify/preflight wo Zig dake de hash to path boundary made kakunin.",
            "LINUX: no_new_privs, dumpable off, caps, /proc maps wo SEC ni dasu.",
        },
        .en => &.{
            "== ZIDE EN TOUR ==",
            "F1 opens help. Ctrl+P opens files. Ctrl+Shift+P opens commands. Ctrl+S saves through security gates.",
            "SEC shows Zig-owned boundary findings: memory, execution, filesystem, network, dependency, secret, text, path, git.",
            "GIT reads repository metadata directly; hooks, filters, fsmonitor, and git status are not executed for overview.",
            "EXT scans extension manifests only. Extension code is never executed during the baseline scan.",
            "SHIP verifies archives, paths, executable bits, and SHA-256 before release.",
            "LINUX exposes no_new_privs, dumpable, capabilities, and /proc maps as first-class IDE state.",
        },
    };
}

fn publishLines() []const []const u8 {
    return &.{
        "== RELEASE GATE ==",
        "[ship] Build Windows GUI/CLI and Linux GUI/CLI before bundling.",
        "[ship] Run ZIP/TAR bundle with pure Zig archive writers.",
        "[hash] Verify SHA-256 and archive paths before publishing.",
        "[ship] Keep GitHub Pages downloads and CHECKSUMS.sha256 in sync.",
        "[ship] Lead with the trust workflow: secure Zig-native workbench, hook-free Git, visible Linux boundaries.",
        "[avoid] Do not publish artifacts whose release.verify has not passed.",
    };
}

fn publishLineGc(x11: *X11, line: []const u8) u32 {
    if (std.mem.startsWith(u8, line, "==")) return x11.gc.amber;
    if (std.mem.startsWith(u8, line, "[hash]")) return x11.gc.cyan;
    if (std.mem.startsWith(u8, line, "[avoid]")) return x11.gc.red;
    return x11.gc.muted;
}

fn workspaceHasAnyLicense(app: *const app_mod.App) bool {
    for (app.workspace.entries.items) |entry| {
        if (entry.kind != .file) continue;
        const base = std.fs.path.basename(entry.path);
        if (std.ascii.eqlIgnoreCase(base, "LICENSE") or
            std.ascii.eqlIgnoreCase(base, "LICENSE.md") or
            std.ascii.eqlIgnoreCase(base, "COPYING")) return true;
    }
    return false;
}

fn workspaceHasPrefixGui(app: *const app_mod.App, prefix: []const u8) bool {
    for (app.workspace.entries.items) |entry| {
        if (std.mem.startsWith(u8, entry.path, prefix)) return true;
    }
    return false;
}

fn workspaceFileExistsGui(app: *const app_mod.App, relative: []const u8) bool {
    for (app.workspace.entries.items) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.path, relative)) return true;
    }
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, relative, .{}) catch return false;
    return true;
}

fn trySetNoNewPrivs() bool {
    const rc = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    return linux.errno(rc) == .SUCCESS;
}

fn trySetDumpable(enabled: bool) bool {
    const rc = linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), if (enabled) 1 else 0, 0, 0, 0);
    return linux.errno(rc) == .SUCCESS;
}

const PR_CAP_AMBIENT_CLEAR_ALL: usize = 4;

const dangerous_caps = [_]usize{
    1, // CAP_DAC_OVERRIDE
    2, // CAP_DAC_READ_SEARCH
    12, // CAP_NET_ADMIN
    13, // CAP_NET_RAW
    16, // CAP_SYS_MODULE
    17, // CAP_SYS_RAWIO
    19, // CAP_SYS_PTRACE
    21, // CAP_SYS_ADMIN
    24, // CAP_SYS_RESOURCE
    25, // CAP_SYS_TIME
    27, // CAP_MKNOD
};

const CapabilityDropResult = struct {
    dropped: usize = 0,
    failed: usize = 0,
};

fn tryClearAmbientCapabilities() bool {
    const rc = linux.prctl(@intFromEnum(linux.PR.CAP_AMBIENT), PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0);
    return linux.errno(rc) == .SUCCESS;
}

fn tryDropDangerousBoundingCapabilities() CapabilityDropResult {
    var result: CapabilityDropResult = .{};
    for (dangerous_caps) |cap| {
        const read_rc = linux.prctl(@intFromEnum(linux.PR.CAPBSET_READ), cap, 0, 0, 0);
        if (linux.errno(read_rc) != .SUCCESS or read_rc == 0) continue;

        const drop_rc = linux.prctl(@intFromEnum(linux.PR.CAPBSET_DROP), cap, 0, 0, 0);
        if (linux.errno(drop_rc) == .SUCCESS) {
            result.dropped += 1;
        } else {
            result.failed += 1;
        }
    }
    return result;
}

fn countDangerousBoundingCapabilities() usize {
    var count: usize = 0;
    for (dangerous_caps) |cap| {
        const rc = linux.prctl(@intFromEnum(linux.PR.CAPBSET_READ), cap, 0, 0, 0);
        if (linux.errno(rc) == .SUCCESS and rc != 0) count += 1;
    }
    return count;
}

fn readLinuxSecuritySnapshot(allocator: std.mem.Allocator, no_new_privs_set: LinuxFlag, dumpable_set: LinuxFlag) LinuxSecuritySnapshot {
    var snapshot = LinuxSecuritySnapshot{
        .no_new_privs_set = no_new_privs_set,
        .dumpable_set = dumpable_set,
    };

    const no_new_privs_rc = linux.prctl(@intFromEnum(linux.PR.GET_NO_NEW_PRIVS), 0, 0, 0, 0);
    if (linux.errno(no_new_privs_rc) == .SUCCESS) {
        snapshot.no_new_privs = if (no_new_privs_rc == 0) .off else .on;
    }

    const dumpable_rc = linux.prctl(@intFromEnum(linux.PR.GET_DUMPABLE), 0, 0, 0, 0);
    if (linux.errno(dumpable_rc) == .SUCCESS) {
        snapshot.dumpable = if (dumpable_rc == 0) .off else .on;
    }

    const seccomp_rc = linux.prctl(@intFromEnum(linux.PR.GET_SECCOMP), 0, 0, 0, 0);
    if (linux.errno(seccomp_rc) == .SUCCESS) {
        snapshot.seccomp_mode = @intCast(@min(seccomp_rc, 255));
    }

    snapshot.dangerous_bounding_caps = countDangerousBoundingCapabilities();
    readLinuxProcStatus(allocator, &snapshot);
    readLinuxProcMaps(allocator, &snapshot);
    readLinuxProcFd(&snapshot);
    return snapshot;
}

fn readLinuxProcStatus(allocator: std.mem.Allocator, snapshot: *LinuxSecuritySnapshot) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, "/proc/self/status", allocator, .limited(64 * 1024)) catch return;
    defer allocator.free(bytes);
    snapshot.proc_status_read = true;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "NoNewPrivs:")) {
            const value = std.mem.trim(u8, line["NoNewPrivs:".len..], " \t\r\n");
            const parsed = std.fmt.parseInt(u8, value, 10) catch continue;
            snapshot.no_new_privs = if (parsed == 0) .off else .on;
        } else if (std.mem.startsWith(u8, line, "Seccomp:")) {
            const value = std.mem.trim(u8, line["Seccomp:".len..], " \t\r\n");
            snapshot.seccomp_mode = std.fmt.parseInt(u8, value, 10) catch snapshot.seccomp_mode;
        } else if (std.mem.startsWith(u8, line, "CapEff:")) {
            const value = std.mem.trim(u8, line["CapEff:".len..], " \t\r\n");
            const len = @min(value.len, snapshot.cap_eff.len);
            @memcpy(snapshot.cap_eff[0..len], value[0..len]);
            snapshot.cap_eff_len = len;
            snapshot.cap_eff_zero = if (hexIsZero(value)) .on else .off;
        }
    }
}

fn readLinuxProcMaps(allocator: std.mem.Allocator, snapshot: *LinuxSecuritySnapshot) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, "/proc/self/maps", allocator, .limited(256 * 1024)) catch return;
    defer allocator.free(bytes);
    snapshot.proc_maps_read = true;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        snapshot.maps_total += 1;

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        const perms = fields.next() orelse continue;
        const executable = perms.len >= 3 and perms[2] == 'x';
        const writable = perms.len >= 2 and perms[1] == 'w';
        if (executable) snapshot.maps_executable += 1;
        if (executable and writable) snapshot.maps_writable_executable += 1;

        _ = fields.next();
        _ = fields.next();
        _ = fields.next();
        const path = fields.next() orelse "";
        if (std.mem.indexOf(u8, path, ".so") != null) snapshot.maps_shared_objects += 1;
        if (executable and (path.len == 0 or std.mem.startsWith(u8, path, "["))) {
            snapshot.maps_anonymous_executable += 1;
        }
    }
}

fn readLinuxProcFd(snapshot: *LinuxSecuritySnapshot) void {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, "/proc/self/fd", .{ .iterate = true }) catch return;
    defer dir.close(std.Options.debug_io);
    snapshot.proc_fd_read = true;

    var iter = dir.iterate();
    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    while (true) {
        const maybe_entry = iter.next(std.Options.debug_io) catch {
            snapshot.fd_unknown += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        const fd = std.fmt.parseInt(i32, entry.name, 10) catch {
            snapshot.fd_unknown += 1;
            continue;
        };
        snapshot.fd_total += 1;

        const flags_rc = linux.fcntl(fd, linux.F.GETFD, 0);
        if (linux.errno(flags_rc) == .SUCCESS) {
            if ((flags_rc & linux.FD_CLOEXEC) == 0) snapshot.fd_cloexec_missing += 1;
        } else {
            snapshot.fd_cloexec_unknown += 1;
        }

        const target_len = dir.readLink(std.Options.debug_io, entry.name, target_buf[0..]) catch {
            snapshot.fd_unknown += 1;
            continue;
        };
        classifyLinuxFdTarget(snapshot, target_buf[0..target_len]);
    }
}

fn classifyLinuxFdTarget(snapshot: *LinuxSecuritySnapshot, target: []const u8) void {
    if (std.mem.startsWith(u8, target, "socket:")) {
        snapshot.fd_sockets += 1;
    } else if (std.mem.startsWith(u8, target, "pipe:")) {
        snapshot.fd_pipes += 1;
    } else if (std.mem.indexOf(u8, target, "memfd:") != null) {
        snapshot.fd_memfd += 1;
    } else if (std.mem.startsWith(u8, target, "anon_inode:")) {
        snapshot.fd_anon += 1;
    } else if (std.mem.startsWith(u8, target, "/")) {
        snapshot.fd_files += 1;
    } else {
        snapshot.fd_unknown += 1;
    }
}

fn hexIsZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte == '0' or byte == 'x' or byte == 'X') continue;
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') continue;
        return false;
    }
    return true;
}

fn flagLabel(flag: LinuxFlag) []const u8 {
    return switch (flag) {
        .unknown => "unknown",
        .off => "off",
        .on => "on",
    };
}

fn seccompLabel(mode: ?u8) []const u8 {
    const value = mode orelse return "unknown";
    return switch (value) {
        0 => "off",
        1 => "strict",
        2 => "filter",
        else => "custom",
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

fn findDocumentMatches(
    allocator: std.mem.Allocator,
    doc: *const document_mod.Document,
    query: []const u8,
    options: literal_search.Options,
    max_results: usize,
) ![]DocumentMatch {
    const literal_matches = try literal_search.findAll(allocator, doc.text.bytes, query, options);
    defer allocator.free(literal_matches);

    var results = std.array_list.Managed(DocumentMatch).init(allocator);
    errdefer {
        for (results.items) |*item| item.deinit(allocator);
        results.deinit();
    }

    for (literal_matches) |match| {
        if (results.items.len >= max_results) break;
        const location = doc.text.offsetToLineColumn(match.start) catch continue;
        try results.append(.{
            .line = location.line,
            .column = location.column,
            .byte_offset = match.start,
            .end_offset = match.end,
            .preview = try allocator.dupe(u8, doc.text.lineSlice(location.line)),
        });
    }
    return results.toOwnedSlice();
}

fn isDocumentSearchMode(mode: QuickPanelMode) bool {
    return mode == .find_document or mode == .replace_document;
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

fn isValidIdentifierName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
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

fn quickPanelTitle(mode: QuickPanelMode) []const u8 {
    return switch (mode) {
        .open_workspace => "OPEN WORKSPACE",
        .find_file => "FIND FILE",
        .find_document => "FIND IN FILE",
        .replace_document => "REPLACE  search=>replacement",
        .rename_symbol => "RENAME  old=>new",
        .search_workspace => "SEARCH WORKSPACE",
        .new_file => "NEW FILE",
        .run_task => "RUN TASK",
        .document_symbols => "SYMBOLS",
    };
}

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

fn encodeUtf8(char: u21, out: *[4]u8) !usize {
    if (char <= 0x7f) {
        out[0] = @intCast(char);
        return 1;
    }
    if (char <= 0x7ff) {
        out[0] = @intCast(0xc0 | (char >> 6));
        out[1] = @intCast(0x80 | (char & 0x3f));
        return 2;
    }
    if (char <= 0xffff) {
        out[0] = @intCast(0xe0 | (char >> 12));
        out[1] = @intCast(0x80 | ((char >> 6) & 0x3f));
        out[2] = @intCast(0x80 | (char & 0x3f));
        return 3;
    }
    if (char <= 0x10ffff) {
        out[0] = @intCast(0xf0 | (char >> 18));
        out[1] = @intCast(0x80 | ((char >> 12) & 0x3f));
        out[2] = @intCast(0x80 | ((char >> 6) & 0x3f));
        out[3] = @intCast(0x80 | (char & 0x3f));
        return 4;
    }
    return error.InvalidCodepoint;
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
        68 => .{ .function = 2 },
        69 => .{ .function = 3 },
        72 => .{ .function = 6 },
        73 => .{ .function = 7 },
        95 => .{ .function = 11 },
        96 => .{ .function = 12 },
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

const header_actions = [_]HeaderAction{ .open_workspace, .save, .save_all, .build, .test_run, .git, .audit, .scan, .extensions, .tutorial, .publish };

fn headerActionRect(action: HeaderAction) HitRect {
    const top: i16 = 15;
    const height: i16 = 30;
    return switch (action) {
        .open_workspace => .{ .left = 410, .top = top, .right = 472, .bottom = top + height },
        .save => .{ .left = 480, .top = top, .right = 540, .bottom = top + height },
        .save_all => .{ .left = 548, .top = top, .right = 606, .bottom = top + height },
        .build => .{ .left = 614, .top = top, .right = 684, .bottom = top + height },
        .test_run => .{ .left = 692, .top = top, .right = 750, .bottom = top + height },
        .git => .{ .left = 758, .top = top, .right = 814, .bottom = top + height },
        .audit => .{ .left = 822, .top = top, .right = 896, .bottom = top + height },
        .scan => .{ .left = 904, .top = top, .right = 970, .bottom = top + height },
        .extensions => .{ .left = 978, .top = top, .right = 1036, .bottom = top + height },
        .tutorial => .{ .left = 1044, .top = top, .right = 1110, .bottom = top + height },
        .publish => .{ .left = 1118, .top = top, .right = 1184, .bottom = top + height },
    };
}

fn headerActionLabel(action: HeaderAction) []const u8 {
    return switch (action) {
        .open_workspace => "OPEN",
        .save => "SAVE",
        .save_all => "ALL",
        .build => "BUILD",
        .test_run => "TEST",
        .git => "GIT",
        .audit => "AUDIT",
        .scan => "SCAN",
        .extensions => "EXT",
        .tutorial => "HELP",
        .publish => "SHIP",
    };
}

fn headerActionAt(x: i16, y: i16) ?HeaderAction {
    inline for (header_actions) |action| {
        if (pointIn(headerActionRect(action), x, y)) return action;
    }
    return null;
}

fn bottomPanelAt(state: *const LinuxGuiState, x: i16, y: i16) ?BottomPanel {
    const bottom = state.bottomTop();
    if (y < bottom or y >= bottom + 34) return null;
    const panels = [_]BottomPanel{ .output, .git, .extensions, .diagnostics, .security, .tutorial, .publish };
    for (panels, 0..) |panel, index| {
        const left: i16 = 10 + @as(i16, @intCast(index)) * 104;
        const rect = HitRect{ .left = left, .top = bottom + 8, .right = left + 96, .bottom = bottom + 32 };
        if (pointIn(rect, x, y)) return panel;
    }
    return null;
}

const git_panel_actions = [_]GitPanelAction{ .refresh, .status, .diff, .issues };
const security_panel_actions = [_]SecurityPanelAction{ .audit, .lock, .scan, .lf, .crlf, .clean, .linux };
const extension_panel_actions = [_]ExtensionPanelAction{.scan};
const tutorial_panel_actions = [_]TutorialPanelAction{ .ja, .en };
const publish_panel_actions = [_]PublishPanelAction{ .checklist, .assets, .manifests, .bundle, .verify, .preflight };

fn drawGitPanelActions(x11: *X11, state: *const LinuxGuiState) !void {
    inline for (git_panel_actions) |action| {
        try drawActionButton(x11, gitPanelActionRect(state, action), gitPanelActionLabel(action));
    }
}

fn drawSecurityPanelActions(x11: *X11, state: *const LinuxGuiState) !void {
    inline for (security_panel_actions) |action| {
        try drawActionButton(x11, securityPanelActionRect(state, action), securityPanelActionLabel(action));
    }
}

fn drawExtensionPanelActions(x11: *X11, state: *const LinuxGuiState) !void {
    inline for (extension_panel_actions) |action| {
        try drawActionButton(x11, extensionPanelActionRect(state, action), extensionPanelActionLabel(action));
    }
}

fn drawTutorialPanelActions(x11: *X11, state: *const LinuxGuiState) !void {
    inline for (tutorial_panel_actions) |action| {
        try drawActionButton(x11, tutorialPanelActionRect(state, action), tutorialPanelActionLabel(action));
    }
}

fn drawPublishPanelActions(x11: *X11, state: *const LinuxGuiState) !void {
    inline for (publish_panel_actions) |action| {
        try drawActionButton(x11, publishPanelActionRect(state, action), publishPanelActionLabel(action));
    }
}

fn gitPanelActionAt(state: *const LinuxGuiState, x: i16, y: i16) ?GitPanelAction {
    inline for (git_panel_actions) |action| {
        if (pointIn(gitPanelActionRect(state, action), x, y)) return action;
    }
    return null;
}

fn securityPanelActionAt(state: *const LinuxGuiState, x: i16, y: i16) ?SecurityPanelAction {
    inline for (security_panel_actions) |action| {
        if (pointIn(securityPanelActionRect(state, action), x, y)) return action;
    }
    return null;
}

fn extensionPanelActionAt(state: *const LinuxGuiState, x: i16, y: i16) ?ExtensionPanelAction {
    inline for (extension_panel_actions) |action| {
        if (pointIn(extensionPanelActionRect(state, action), x, y)) return action;
    }
    return null;
}

fn tutorialPanelActionAt(state: *const LinuxGuiState, x: i16, y: i16) ?TutorialPanelAction {
    inline for (tutorial_panel_actions) |action| {
        if (pointIn(tutorialPanelActionRect(state, action), x, y)) return action;
    }
    return null;
}

fn publishPanelActionAt(state: *const LinuxGuiState, x: i16, y: i16) ?PublishPanelAction {
    inline for (publish_panel_actions) |action| {
        if (pointIn(publishPanelActionRect(state, action), x, y)) return action;
    }
    return null;
}

fn gitPanelActionRect(state: *const LinuxGuiState, action: GitPanelAction) HitRect {
    const index: i16 = switch (action) {
        .refresh => 0,
        .status => 1,
        .diff => 2,
        .issues => 3,
    };
    const width: i16 = 74;
    const gap: i16 = 8;
    const right = state.window_width - 18 - (3 - index) * (width + gap);
    const bottom = state.bottomTop();
    return .{ .left = right - width, .top = bottom + 42, .right = right, .bottom = bottom + 66 };
}

fn securityPanelActionRect(state: *const LinuxGuiState, action: SecurityPanelAction) HitRect {
    const index: i16 = switch (action) {
        .audit => 0,
        .lock => 1,
        .scan => 2,
        .lf => 3,
        .crlf => 4,
        .clean => 5,
        .linux => 6,
    };
    const width: i16 = 64;
    const gap: i16 = 7;
    const right = state.window_width - 18 - (6 - index) * (width + gap);
    const bottom = state.bottomTop();
    return .{ .left = right - width, .top = bottom + 42, .right = right, .bottom = bottom + 66 };
}

fn extensionPanelActionRect(state: *const LinuxGuiState, action: ExtensionPanelAction) HitRect {
    _ = action;
    const bottom = state.bottomTop();
    return .{ .left = state.window_width - 88, .top = bottom + 42, .right = state.window_width - 18, .bottom = bottom + 66 };
}

fn tutorialPanelActionRect(state: *const LinuxGuiState, action: TutorialPanelAction) HitRect {
    const index: i16 = switch (action) {
        .ja => 0,
        .en => 1,
    };
    const width: i16 = 58;
    const gap: i16 = 8;
    const right = state.window_width - 18 - (1 - index) * (width + gap);
    const bottom = state.bottomTop();
    return .{ .left = right - width, .top = bottom + 42, .right = right, .bottom = bottom + 66 };
}

fn publishPanelActionRect(state: *const LinuxGuiState, action: PublishPanelAction) HitRect {
    const index: i16 = switch (action) {
        .checklist => 0,
        .assets => 1,
        .manifests => 2,
        .bundle => 3,
        .verify => 4,
        .preflight => 5,
    };
    const width: i16 = 70;
    const gap: i16 = 8;
    const right = state.window_width - 18 - (5 - index) * (width + gap);
    const bottom = state.bottomTop();
    return .{ .left = right - width, .top = bottom + 42, .right = right, .bottom = bottom + 66 };
}

fn gitPanelActionLabel(action: GitPanelAction) []const u8 {
    return switch (action) {
        .refresh => "REFRESH",
        .status => "STATUS",
        .diff => "DIFF",
        .issues => "ISSUES",
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
        .linux => "LINUX",
    };
}

fn extensionPanelActionLabel(action: ExtensionPanelAction) []const u8 {
    return switch (action) {
        .scan => "SCAN",
    };
}

fn tutorialPanelActionLabel(action: TutorialPanelAction) []const u8 {
    return switch (action) {
        .ja => "JA",
        .en => "EN",
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

fn gitChangesTop(state: *const LinuxGuiState) i16 {
    const bottom = state.bottomTop();
    const remote_rows: usize = if (state.git_overview) |overview| @max(@min(overview.remotes.len, @as(usize, 2)), 1) else 1;
    return bottom + 108 + @as(i16, @intCast(remote_rows)) * LINE_HEIGHT;
}

fn gitChangeRowAt(state: *const LinuxGuiState, y: i16) ?usize {
    const top = gitChangesTop(state);
    if (y < top) return null;
    const row = @divTrunc(@as(isize, y - top), LINE_HEIGHT);
    if (row < 0) return null;
    return state.git_scroll_line + @as(usize, @intCast(row));
}

fn extensionRowAt(state: *const LinuxGuiState, y: i16) ?usize {
    const top = state.bottomTop() + 86;
    if (y < top) return null;
    const row = @divTrunc(@as(isize, y - top), LINE_HEIGHT);
    if (row < 0) return null;
    return state.extensions_scroll_line + @as(usize, @intCast(row));
}

fn securityFindingsTop(state: *const LinuxGuiState) i16 {
    return state.bottomTop() + 206;
}

fn documentTabAt(state: *const LinuxGuiState, x: i16, y: i16) ?usize {
    if (y < 92 or y >= 122 or x < EDITOR_LEFT) return null;
    var tab_x: i16 = EDITOR_LEFT;
    for (state.app.documents.documents.items, 0..) |_, index| {
        const rect = HitRect{ .left = tab_x - 4, .top = 96, .right = tab_x + 174, .bottom = 122 };
        if (pointIn(rect, x, y)) return index;
        tab_x += 188;
        if (tab_x > state.window_width - 220) break;
    }
    return null;
}

fn pointIn(rect: HitRect, x: i16, y: i16) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
}

fn scrollValue(current: usize, max_value: usize, delta: isize) usize {
    if (delta < 0) {
        const amount: usize = @intCast(-delta);
        return if (amount > current) 0 else current - amount;
    }
    const amount: usize = @intCast(delta);
    return @min(max_value, current + amount);
}

fn toU16(value: i16) u16 {
    return @intCast(@max(value, 0));
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
