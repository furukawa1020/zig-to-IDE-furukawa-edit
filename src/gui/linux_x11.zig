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
const highlight = @import("../language/highlight.zig");
const lsp_responses = @import("../lsp/responses.zig");
const modes = @import("../language/modes.zig");
const completion_mod = @import("../language/completion.zig");
const symbols_mod = @import("../language/symbols.zig");
const findings_mod = @import("../security/findings.zig");
const text_integrity = @import("../security/text_integrity.zig");
const zig_scanner = @import("../security/zig_scanner.zig");
const polyglot_scanner = @import("../security/polyglot_scanner.zig");
const package_trust = @import("../security/package_trust.zig");
const command_intent = @import("../security/command_intent.zig");
const launch_audit = @import("../security/launch_audit.zig");
const file_finder = @import("../search/file_finder.zig");
const literal_search = @import("../search/literal.zig");
const problems_search = @import("../search/problems.zig");
const workspace_search = @import("../search/workspace_search.zig");
const workspace_symbols = @import("../search/workspace_symbols.zig");
const zig_output = @import("../diagnostics/zig_output.zig");
const task_registry = @import("../tasks/registry.zig");
const execution_queue = @import("../tasks/execution_queue.zig");
const permissions = @import("../security/permissions.zig");
const terminal_command_line = @import("../terminal/command_line.zig");
const terminal_pty = @import("../terminal/pty.zig");
const types = @import("../core/types.zig");
const workbench_settings = @import("workbench_settings.zig");

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
const X11_SHIFT_MASK: u16 = 1 << 0;

const X = struct {
    const EventMask = struct {
        const key_press: u32 = 1 << 0;
        const button_press: u32 = 1 << 2;
        const button_release: u32 = 1 << 3;
        const pointer_motion: u32 = 1 << 6;
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
    clipboard: u32,
    primary: u32,
    targets: u32,
    utf8_string: u32,
    string: u32,
    text: u32,
    atom: u32,
    zide_clipboard: u32,
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
            .atoms = .{
                .wm_protocols = 0,
                .wm_delete_window = 0,
                .clipboard = 0,
                .primary = 0,
                .targets = 0,
                .utf8_string = 0,
                .string = 0,
                .text = 0,
                .atom = 0,
                .zide_clipboard = 0,
            },
            .gc = undefined,
        };
        self.gc = try self.createGraphics();
        self.window = try self.createWindow();
        self.atoms = .{
            .wm_protocols = try self.internAtom("WM_PROTOCOLS"),
            .wm_delete_window = try self.internAtom("WM_DELETE_WINDOW"),
            .clipboard = try self.internAtom("CLIPBOARD"),
            .primary = try self.internAtom("PRIMARY"),
            .targets = try self.internAtom("TARGETS"),
            .utf8_string = try self.internAtom("UTF8_STRING"),
            .string = try self.internAtom("STRING"),
            .text = try self.internAtom("TEXT"),
            .atom = try self.internAtom("ATOM"),
            .zide_clipboard = try self.internAtom("ZIDE_CLIPBOARD"),
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
        writeLe32(req[36..40], X.EventMask.exposure | X.EventMask.key_press | X.EventMask.button_press | X.EventMask.button_release | X.EventMask.pointer_motion | X.EventMask.structure_notify);
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

    fn setSelectionOwner(self: *X11, selection: u32) !void {
        var req: [16]u8 = undefined;
        @memset(req[0..], 0);
        req[0] = 22;
        req[1] = 0;
        writeLe16(req[2..4], 4);
        writeLe32(req[4..8], self.window);
        writeLe32(req[8..12], selection);
        writeLe32(req[12..16], 0);
        try self.writeRequest(req[0..]);
    }

    fn convertSelection(self: *X11, selection: u32, target: u32, property: u32) !void {
        var req: [24]u8 = undefined;
        @memset(req[0..], 0);
        req[0] = 24;
        req[1] = 0;
        writeLe16(req[2..4], 6);
        writeLe32(req[4..8], self.window);
        writeLe32(req[8..12], selection);
        writeLe32(req[12..16], target);
        writeLe32(req[16..20], property);
        writeLe32(req[20..24], 0);
        try self.writeRequest(req[0..]);
    }

    fn sendSelectionNotify(self: *X11, requestor: u32, selection: u32, target: u32, property: u32, time: u32) !void {
        var req: [44]u8 = undefined;
        @memset(req[0..], 0);
        req[0] = 25;
        req[1] = 0;
        writeLe16(req[2..4], 11);
        writeLe32(req[4..8], requestor);
        writeLe32(req[8..12], 0);
        req[12] = 31;
        req[13] = 0;
        writeLe16(req[14..16], 0);
        writeLe32(req[16..20], time);
        writeLe32(req[20..24], requestor);
        writeLe32(req[24..28], selection);
        writeLe32(req[28..32], target);
        writeLe32(req[32..36], property);
        try self.writeRequest(req[0..]);
    }

    fn requestSelectionText(self: *X11, allocator: std.mem.Allocator, selection: u32) ![]u8 {
        return self.requestSelectionTextTarget(allocator, selection, self.atoms.utf8_string) catch |utf8_err| {
            return self.requestSelectionTextTarget(allocator, selection, self.atoms.string) catch |string_err| switch (string_err) {
                error.NoClipboardText, error.ClipboardTimeout, error.UnsupportedClipboardFormat => utf8_err,
                else => string_err,
            };
        };
    }

    fn requestSelectionTextTarget(self: *X11, allocator: std.mem.Allocator, requested_selection: u32, requested_target: u32) ![]u8 {
        try self.convertSelection(requested_selection, requested_target, self.atoms.zide_clipboard);
        var ignored: usize = 0;
        while (ignored < 64) : (ignored += 1) {
            var event: [32]u8 = undefined;
            try readExact(self.fd, event[0..]);
            const event_type = event[0] & 0x7f;
            if (event_type != 31) continue;
            const actual_selection = readLe32(event[12..16]);
            const actual_target = readLe32(event[16..20]);
            const property = readLe32(event[20..24]);
            if (actual_selection != requested_selection or actual_target != requested_target or property == 0) return error.NoClipboardText;
            return try self.getProperty8(allocator, self.window, property);
        }
        return error.ClipboardTimeout;
    }

    fn getProperty8(self: *X11, allocator: std.mem.Allocator, window: u32, property: u32) ![]u8 {
        var req: [24]u8 = undefined;
        @memset(req[0..], 0);
        req[0] = 20;
        req[1] = 1;
        writeLe16(req[2..4], 6);
        writeLe32(req[4..8], window);
        writeLe32(req[8..12], property);
        writeLe32(req[12..16], 0);
        writeLe32(req[16..20], 0);
        writeLe32(req[20..24], 1024 * 1024);
        try self.writeRequest(req[0..]);

        var reply: [32]u8 = undefined;
        try readReply(self.fd, reply[0..]);
        if (reply[0] != 1) return error.X11ProtocolError;
        if (reply[1] != 8) return error.UnsupportedClipboardFormat;
        const value_len = readLe32(reply[16..20]);
        const reply_extra_len = readLe32(reply[4..8]) * 4;
        if (value_len > 8 * 1024 * 1024 or reply_extra_len > 8 * 1024 * 1024) return error.ClipboardTooLarge;
        const bytes = try allocator.alloc(u8, @intCast(value_len));
        errdefer allocator.free(bytes);
        const extra = try allocator.alloc(u8, @intCast(reply_extra_len));
        defer allocator.free(extra);
        if (reply_extra_len > 0) try readExact(self.fd, extra);
        if (value_len > 0) @memcpy(bytes[0..], extra[0..value_len]);
        return bytes;
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
    tasks,
    git,
    extensions,
    diagnostics,
    security,
    settings,
    keybindings,
    tutorial,
    publish,
};

const PendingLspAction = enum {
    none,
    goto_definition,
    find_references,
    hover,
    rename_preview,
    formatting_preview,
    code_actions,
};

const HeaderAction = enum {
    open_workspace,
    save,
    save_all,
    build,
    test_run,
    task,
    git,
    audit,
    scan,
    extensions,
    tutorial,
    publish,
};

const SettingsPanelAction = enum {
    profile_read_only,
    profile_safe,
    profile_network,
    profile_publish,
    tutorial_ja,
    tutorial_en,
    review,
    trust,
    lock,
    seal,
};

const GitPanelAction = enum {
    refresh,
    status,
    diff,
    live,
    issues,
    failures,
    draft_pr,
};

const SecurityPanelAction = enum {
    audit,
    lock,
    scan,
    lf,
    crlf,
    clean,
    seal,
    linux,
};

const TaskPanelAction = enum {
    profile_read_only,
    profile_safe,
    profile_network,
    profile_publish,
    terminal,
    queue_terminal,
    run_pty,
    stop_pty,
    tasks,
    preview,
    seal,
    run_next,
    history,
};

const LinuxLaunchProfile = enum {
    read_only,
    safe,
    network,
    publish,
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

const ContextAction = enum {
    copy,
    cut,
    paste,
    select_all,
    find,
    scan,
    scan_selection,
    boundary_lens,
    comment,
    references,
    rename,
    goto_line,
    close_editor,
    task_queue,
    palette,
};

const QuickPanelMode = enum {
    open_workspace,
    find_file,
    find_document,
    replace_document,
    rename_symbol,
    goto_line,
    search_workspace,
    new_file,
    run_task,
    document_symbols,
    workspace_symbols,
    lsp_actions,
    lsp_locations,
    problems,
    completion,
    lsp_hover,
    code_actions,
    language_mode,
};

const ReplaceRequest = struct {
    find: []const u8,
    replace: []const u8,
};

const GotoLineTarget = struct {
    line: usize,
    column: usize = 0,
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

const LspPanelAction = struct {
    id: []const u8,
    label: []const u8,
    hint: []const u8,
};

const lsp_panel_actions = [_]LspPanelAction{
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
    .{ .id = "symbol.find_references", .label = "Find references", .hint = "LSP first, local fallback" },
    .{ .id = "symbol.rename", .label = "Rename symbol", .hint = "preview rename edits safely" },
    .{ .id = "lsp.request_code_action", .label = "Quick fixes", .hint = "request code actions for cursor diagnostics" },
    .{ .id = "lsp.apply_workspace_edit", .label = "Apply last edit", .hint = "apply cached LSP edit after boundary checks" },
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
    workspace_symbol_matches: ?[]workspace_symbols.Result = null,
    problem_matches: ?[]problems_search.Result = null,
    completion_matches: ?[]completion_mod.Item = null,
    language_matches: ?[]modes.LanguageMode = null,
    lsp_action_count: usize = 0,
    lsp_location_count: usize = 0,
    lsp_hover_line_count: usize = 0,
    code_action_count: usize = 0,
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
            .goto_line => if (parseGotoLine(self.query.items)) |_| 1 else 0,
            .search_workspace => if (self.search_results) |items| items.len else 0,
            .new_file => if (self.query.items.len > 0) 1 else 0,
            .run_task => if (self.task_matches) |items| items.len else 0,
            .document_symbols => if (self.symbol_matches) |items| items.len else 0,
            .workspace_symbols => if (self.workspace_symbol_matches) |items| items.len else 0,
            .lsp_actions => self.lsp_action_count,
            .lsp_locations => self.lsp_location_count,
            .problems => if (self.problem_matches) |items| items.len else 0,
            .completion => if (self.completion_matches) |items| items.len else 0,
            .lsp_hover => self.lsp_hover_line_count,
            .code_actions => self.code_action_count,
            .language_mode => if (self.language_matches) |items| items.len else 0,
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
            .goto_line => {},
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
        if (self.language_matches) |items| {
            self.allocator.free(items);
            self.language_matches = null;
        }
    }
};

const LinuxFlag = enum {
    unknown,
    off,
    on,
};

const FdSealResult = struct {
    sealed: usize = 0,
    failed: usize = 0,
};

const LinuxSecuritySnapshot = struct {
    no_new_privs: LinuxFlag = .unknown,
    no_new_privs_set: LinuxFlag = .unknown,
    dumpable: LinuxFlag = .unknown,
    dumpable_set: LinuxFlag = .unknown,
    ambient_clear: LinuxFlag = .unknown,
    seccomp_mode: ?u8 = null,
    seccomp_filters: ?usize = null,
    tracer_pid: ?usize = null,
    core_dumping: LinuxFlag = .unknown,
    euid: ?usize = null,
    euid_root: LinuxFlag = .unknown,
    nspid_count: usize = 0,
    pid_namespace: LinuxFlag = .unknown,
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
    fd_cloexec_sealed: usize = 0,
    fd_cloexec_seal_failed: usize = 0,
};

const LinuxGuiState = struct {
    allocator: std.mem.Allocator,
    app: app_mod.App,
    quick_panel: QuickPanel,
    git_overview: ?git_repository.Overview = null,
    extensions_registry: ?extension_registry.Registry = null,
    tutorial_language: TutorialLanguage = .ja,
    linux_launch_profile: LinuxLaunchProfile = .safe,
    linux_security: LinuxSecuritySnapshot = .{},
    last_document_search_query: std.array_list.Managed(u8),
    last_document_search_options: literal_search.Options = .{},
    selection_anchor: ?usize = null,
    editor_dragging: bool = false,
    last_editor_click_time: u32 = 0,
    last_editor_click_x: i16 = 0,
    last_editor_click_y: i16 = 0,
    context_menu_visible: bool = false,
    context_menu_x: i16 = 0,
    context_menu_y: i16 = 0,
    context_menu_selected: usize = 0,
    pending_lsp_action: PendingLspAction = .none,
    clipboard: std.array_list.Managed(u8),
    primary_selection: std.array_list.Managed(u8),
    clipboard_owned: bool = false,
    primary_owned: bool = false,
    terminal_input: std.array_list.Managed(u8),
    terminal_focused: bool = false,
    terminal_history_cursor: ?usize = null,
    pty_session: ?terminal_pty.Session = null,
    pty_ticket: ?execution_queue.Ticket = null,
    pty_forced_state: ?execution_queue.State = null,
    pty_started_ms: i64 = 0,
    pty_output_bytes: usize = 0,
    bottom_panel: BottomPanel = .output,
    window_width: i16 = WIDTH,
    window_height: i16 = HEIGHT,
    file_scroll_line: usize = 0,
    collapsed_dirs: []bool,
    editor_scroll_line: usize = 0,
    output_scroll_line: usize = 0,
    task_scroll_line: usize = 0,
    task_history_selected: ?usize = null,
    git_scroll_line: usize = 0,
    extensions_scroll_line: usize = 0,
    diagnostics_scroll_line: usize = 0,
    security_scroll_line: usize = 0,
    settings_scroll_line: usize = 0,
    keybindings_scroll_line: usize = 0,
    tutorial_scroll_line: usize = 0,
    publish_scroll_line: usize = 0,
    message_buf: [240]u8 = [_]u8{0} ** 240,
    message_len: usize = 0,

    fn init(allocator: std.mem.Allocator, root_path: []const u8, environ: std.process.Environ) !LinuxGuiState {
        var app = try app_mod.App.initWithProcess(allocator, root_path, std.Options.debug_io, environ);
        errdefer app.deinit();
        const collapsed_dirs = try allocator.alloc(bool, app.workspace.entries.items.len);
        errdefer allocator.free(collapsed_dirs);
        @memset(collapsed_dirs, false);
        var state = LinuxGuiState{
            .allocator = allocator,
            .app = app,
            .quick_panel = QuickPanel.init(allocator),
            .collapsed_dirs = collapsed_dirs,
            .last_document_search_query = std.array_list.Managed(u8).init(allocator),
            .clipboard = std.array_list.Managed(u8).init(allocator),
            .primary_selection = std.array_list.Managed(u8).init(allocator),
            .terminal_input = std.array_list.Managed(u8).init(allocator),
        };
        state.loadWorkbenchSettings();
        return state;
    }

    fn deinit(self: *LinuxGuiState) void {
        self.closePtySession();
        self.clearExtensionsRegistry();
        self.clearGitOverview();
        self.terminal_input.deinit();
        self.primary_selection.deinit();
        self.clipboard.deinit();
        self.last_document_search_query.deinit();
        self.quick_panel.deinit();
        self.allocator.free(self.collapsed_dirs);
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

    fn pumpLsp(self: *LinuxGuiState) bool {
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
        return true;
    }

    fn syncActiveDocumentToLsp(self: *LinuxGuiState) void {
        _ = dispatcher.syncActiveDocumentToRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp sync failed: {s}\n", .{@errorName(err)});
            return;
        };
    }

    fn requestCompletionFromLsp(self: *LinuxGuiState) void {
        _ = dispatcher.requestActiveCompletionFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp completion request failed: {s}\n", .{@errorName(err)});
            return;
        };
    }

    fn requestDefinitionFromLsp(self: *LinuxGuiState) bool {
        const sent = dispatcher.requestActiveDefinitionFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp definition request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .goto_definition;
        self.message("LSP definition requested", .{});
        return true;
    }

    fn requestReferencesFromLsp(self: *LinuxGuiState) bool {
        const sent = dispatcher.requestActiveReferencesFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp references request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .find_references;
        self.message("LSP references requested", .{});
        return true;
    }

    fn requestHoverFromLsp(self: *LinuxGuiState) bool {
        const sent = dispatcher.requestActiveHoverFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp hover request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .hover;
        self.message("LSP hover requested", .{});
        return true;
    }

    fn requestFormattingFromLsp(self: *LinuxGuiState) bool {
        const sent = dispatcher.requestActiveFormattingFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp formatting request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .formatting_preview;
        self.message("LSP formatting requested", .{});
        return true;
    }

    fn requestCodeActionsFromLsp(self: *LinuxGuiState) bool {
        const sent = dispatcher.requestActiveCodeActionsFromRunningLsp(&self.app) catch |err| {
            self.appendOutput(.stderr, "lsp code action request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .code_actions;
        self.message("LSP code actions requested", .{});
        return true;
    }

    fn requestRenameFromLsp(self: *LinuxGuiState, new_name: []const u8) bool {
        const sent = dispatcher.requestActiveRenameFromRunningLsp(&self.app, new_name) catch |err| {
            self.appendOutput(.stderr, "lsp rename request failed: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!sent) return false;
        self.pending_lsp_action = .rename_preview;
        self.message("LSP rename requested", .{});
        return true;
    }

    fn finishPendingLspAction(self: *LinuxGuiState) void {
        switch (self.pending_lsp_action) {
            .none => {},
            .goto_definition => {
                if (self.app.activeLspSessionConst()) |session| {
                    if (session.last_locations) |locations| {
                        self.pending_lsp_action = .none;
                        if (locations.items.len == 0) return self.message("no LSP definition", .{});
                        if (locations.items.len > 1) {
                            self.showLspLocations("LSP definitions");
                            return;
                        }
                        const location = locations.items[0];
                        self.openRelativeLocation(location.path, location.range.start.line, location.range.start.column);
                        self.message("opened LSP definition", .{});
                    }
                }
            },
            .find_references => {
                if (self.app.activeLspSessionConst()) |session| {
                    if (session.last_locations) |locations| {
                        self.pending_lsp_action = .none;
                        if (locations.items.len == 0) return self.message("no LSP references", .{});
                        self.showLspLocations("LSP references");
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
                    if (session.last_workspace_edit) |edit| {
                        self.pending_lsp_action = .none;
                        self.showLspWorkspaceEdit("LSP rename preview", &edit);
                    }
                }
            },
            .formatting_preview => {
                if (self.app.activeLspSessionConst()) |session| {
                    if (session.last_workspace_edit) |edit| {
                        self.pending_lsp_action = .none;
                        self.showLspWorkspaceEdit("LSP formatting preview", &edit);
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

    fn showLspLocations(self: *LinuxGuiState, label: []const u8) void {
        const session = self.app.activeLspSessionConst() orelse return;
        const locations = session.last_locations orelse return;
        self.bottom_panel = .output;
        self.appendOutput(.stdout, "{s}: {d}\n", .{ label, locations.items.len });
        for (locations.items[0..@min(locations.items.len, @as(usize, 80))]) |location| {
            self.appendOutput(.stdout, "{s}:{d}:{d}\n", .{ location.path, location.range.start.line + 1, location.range.start.column + 1 });
        }
        if (locations.items.len > 80) self.appendOutput(.stdout, "... {d} more LSP location(s)\n", .{locations.items.len - 80});
        self.message("showing {d} LSP location(s)", .{locations.items.len});
        if (locations.items.len > 0) {
            self.openQuickPanel(.lsp_locations);
            self.quick_panel.visible = true;
            self.message("select an LSP location and press Enter", .{});
        }
    }

    fn showLspHover(self: *LinuxGuiState, label: []const u8, hover: *const lsp_responses.Hover) void {
        self.bottom_panel = .output;
        self.appendOutput(.stdout, "{s}: {d} bytes\n{s}\n", .{ label, hover.text.len, hover.text });
        if (hover.text.len == 0) return self.message("empty LSP hover", .{});
        self.openQuickPanel(.lsp_hover);
        self.quick_panel.visible = true;
        self.message("LSP hover", .{});
    }

    fn showLspWorkspaceEdit(self: *LinuxGuiState, label: []const u8, edit: *const lsp_responses.WorkspaceEdit) void {
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
        self.message("{s}", .{label});
    }

    fn showLspCodeActions(self: *LinuxGuiState, label: []const u8, actions: *const lsp_responses.CodeActions) void {
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
        self.message("showing LSP code actions", .{});
        if (actions.items.len > 0) {
            self.openQuickPanel(.code_actions);
            self.quick_panel.visible = true;
            self.message("select a Quick Fix and press Enter", .{});
        }
    }

    fn focusTerminalInput(self: *LinuxGuiState) void {
        self.bottom_panel = .tasks;
        self.terminal_focused = true;
        self.app.mode = .command;
        self.saveWorkbenchSettings();
        if (self.pty_session != null) {
            self.message("pty terminal: Enter sends input, Ctrl+C sends interrupt", .{});
        } else {
            self.message("terminal: type command, or PTY opens a bounded workspace shell", .{});
        }
    }

    fn blurTerminalInput(self: *LinuxGuiState) void {
        self.terminal_focused = false;
        self.terminal_history_cursor = null;
        self.app.mode = .normal;
        self.message("terminal input blurred", .{});
    }

    fn terminalInsertText(self: *LinuxGuiState, bytes: []const u8) void {
        if (self.terminal_input.items.len + bytes.len > 4096) {
            self.message("terminal input limit reached", .{});
            return;
        }
        self.terminal_input.appendSlice(bytes) catch |err| return self.message("terminal input failed: {s}", .{@errorName(err)});
        self.terminal_history_cursor = null;
    }

    fn terminalDeleteBackward(self: *LinuxGuiState) void {
        if (self.terminal_input.items.len == 0) return;
        var end = self.terminal_input.items.len - 1;
        while (end > 0 and isUtf8Continuation(self.terminal_input.items[end])) : (end -= 1) {}
        self.terminal_input.shrinkRetainingCapacity(end);
        self.terminal_history_cursor = null;
    }

    fn terminalSetInput(self: *LinuxGuiState, bytes: []const u8) void {
        self.terminal_input.clearRetainingCapacity();
        self.terminal_input.appendSlice(bytes[0..@min(bytes.len, 4096)]) catch |err| return self.message("terminal input failed: {s}", .{@errorName(err)});
    }

    fn terminalClearInput(self: *LinuxGuiState) void {
        self.terminal_input.clearRetainingCapacity();
        self.terminal_history_cursor = null;
        self.message("terminal input cleared", .{});
    }

    fn terminalLoadHistory(self: *LinuxGuiState, delta: isize) void {
        const total = self.app.execution_queue.history.items.len;
        if (total == 0) return self.message("terminal history empty", .{});

        var index = self.terminal_history_cursor orelse total;
        if (delta < 0) {
            if (index == 0) return;
            index -= 1;
        } else {
            if (index >= total) return;
            index += 1;
            if (index >= total) {
                self.terminal_history_cursor = null;
                self.terminal_input.clearRetainingCapacity();
                self.message("terminal history: newest", .{});
                return;
            }
        }

        self.terminal_history_cursor = index;
        const entry = self.app.execution_queue.history.items[index];
        self.terminalSetInput(entry.display_command);
        self.message("terminal history #{d}", .{index + 1});
    }

    fn handleTerminalKey(self: *LinuxGuiState, x11: *X11, key: event_mod.KeyEvent) bool {
        if (!self.terminal_focused) return false;
        switch (key.code) {
            .escape => {
                self.blurTerminalInput();
                return true;
            },
            .enter => {
                if (self.pty_session != null) {
                    self.sendTerminalInputToPty();
                } else {
                    self.queueTerminalInput();
                }
                return true;
            },
            .backspace => {
                self.terminalDeleteBackward();
                return true;
            },
            .delete => {
                self.terminalClearInput();
                return true;
            },
            .arrow_up => {
                self.terminalLoadHistory(-1);
                return true;
            },
            .arrow_down => {
                self.terminalLoadHistory(1);
                return true;
            },
            .char => |char| {
                if (key.modifiers.ctrl) {
                    if (char == 'u' or char == 'U') self.terminalClearInput();
                    if (char == 'c' or char == 'C') {
                        if (self.pty_session != null) {
                            self.writeBytesToPty("\x03");
                            self.message("pty: sent interrupt", .{});
                        } else {
                            self.blurTerminalInput();
                        }
                    }
                    if (char == 'd' or char == 'D') {
                        if (self.pty_session != null) self.writeBytesToPty("\x04");
                    }
                    if (char == 'v' or char == 'V') {
                        self.pasteIntoTerminal(x11);
                    }
                    return true;
                }
                if (key.modifiers.alt) return true;
                var bytes: [4]u8 = undefined;
                const len = encodeUtf8(char, &bytes) catch return true;
                self.terminalInsertText(bytes[0..len]);
                return true;
            },
            else => return true,
        }
    }

    fn queueTerminalInput(self: *LinuxGuiState) void {
        const line = std.mem.trim(u8, self.terminal_input.items, " \t\r\n");
        if (line.len == 0) return self.message("terminal: type a command first", .{});

        var parsed = terminal_command_line.parse(self.allocator, line) catch |err| {
            self.message("terminal parse failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "terminal parse failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer parsed.deinit();

        const spec: @import("../platform/process.zig").SpawnSpec = .{
            .command = .{
                .executable = parsed.executable,
                .args = parsed.args,
                .cwd = self.app.workspace.root_path,
            },
            .stdout = .pipe,
            .stderr = .pipe,
            .stdin = .ignore,
        };

        var preview = build_consent.makePreview(self.allocator, spec, self.app.runtime.trust_state) catch |err| {
            self.message("terminal preview failed: {s}", .{@errorName(err)});
            return;
        };
        defer preview.deinit();

        self.app.execution_queue.enqueueSpec("terminal.run", spec, preview.consent) catch |err| {
            self.message("terminal queue failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "terminal queue failed: {s}\n", .{@errorName(err)});
            return;
        };
        _ = self.applyLinuxLaunchProfileToLatestQueued("terminal command queued");

        self.appendOutput(.stdout, "terminal queued: {s}\n", .{preview.command});
        self.appendOutput(.stdout, "terminal intent: network={} mutating={} shell={} destructive={} package={} reason={s}\n", .{
            preview.intent.network,
            preview.intent.mutating,
            preview.intent.shell,
            preview.intent.destructive,
            preview.intent.package_manager,
            preview.intent.reason,
        });
        for (preview.warnings) |warning| {
            self.appendOutput(.stdout, "terminal warning: {s}\n", .{warning});
        }

        self.terminal_input.clearRetainingCapacity();
        self.terminal_history_cursor = null;
        self.bottom_panel = .tasks;
        const preview_result = dispatcher.dispatch(&self.app, .{ .id = "task.preview_next", .source = .task }) catch |err| {
            self.message("terminal preview failed: {s}", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult("task.preview_next", preview_result);
        self.message("terminal queued; review PLAN, then PTY or RUN", .{});
    }

    fn startPtyFromQueue(self: *LinuxGuiState) void {
        if (self.pty_session != null) return self.message("pty already running", .{});
        if (!self.prepareLinuxLaunchBoundary()) return;

        var ticket = self.app.execution_queue.takeNextQueued() orelse self.makeInteractiveShellTicket() catch |err| {
            self.message("pty shell failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "pty shell ticket failed: {s}\n", .{@errorName(err)});
            return;
        };
        errdefer ticket.deinit();

        if (terminal_pty.validateTicket(&ticket, self.app.workspace.root_path)) |reason| {
            self.app.process_console.begin();
            self.appendOutput(.stderr, "pty blocked: {s}\n", .{reason});
            self.app.process_console.finish(-1);
            self.recordPtyTicket(&ticket, .blocked, -1);
            self.message("pty blocked", .{});
            return;
        }

        self.app.process_console.begin();
        self.appendOutput(.stdout, "$ {s}\n", .{ticket.display_command});
        if (std.mem.eql(u8, ticket.source_command_id, "terminal.shell")) {
            self.appendOutput(.stdout, "pty shell: bounded to workspace, allowlisted env, network denied by default\n", .{});
        }
        self.appendOutput(.stdout, "pty profile:{s} env:{s} fs:{s} net:{s} timeout:{s} output:{d}\n", .{
            linuxLaunchProfileLabel(self.linux_launch_profile),
            @tagName(ticket.env_policy),
            @tagName(ticket.fs_policy),
            @tagName(ticket.network_policy),
            timeoutLabel(ticket.timeout_ms),
            ticket.output_limit_bytes,
        });

        const session = terminal_pty.spawnTicket(self.allocator, &ticket, .{
            .workspace_root = self.app.workspace.root_path,
            .environ = self.app.environ,
            .size = self.terminalPtySize(),
        }) catch |err| {
            self.appendOutput(.stderr, "pty spawn failed: {s}\n", .{@errorName(err)});
            self.app.process_console.finish(-1);
            self.recordPtyTicket(&ticket, .failed, -1);
            self.message("pty spawn failed: {s}", .{@errorName(err)});
            return;
        };

        self.pty_ticket = ticket;
        self.pty_session = session;
        self.pty_forced_state = null;
        self.pty_started_ms = monotonicMillis();
        self.pty_output_bytes = 0;
        self.terminal_focused = true;
        self.bottom_panel = .tasks;
        self.message("pty running pid:{d}", .{session.pid});
    }

    fn makeInteractiveShellTicket(self: *LinuxGuiState) !execution_queue.Ticket {
        const shell = self.defaultInteractiveShell();
        return execution_queue.Ticket.init(self.allocator, "terminal.shell", .{
            .command = .{
                .executable = shell,
                .args = &.{},
                .cwd = self.app.workspace.root_path,
            },
            .stdout = .pipe,
            .stderr = .pipe,
            .stdin = .inherit,
        }, .{
            .command = shell,
            .cwd = self.app.workspace.root_path,
            .env_policy = .allowlist,
            .fs_policy = .workspace_only,
            .network_policy = .deny,
            .output_sanitized = true,
            .timeout_ms = null,
            .output_limit_bytes = 2 * 1024 * 1024,
        });
    }

    fn defaultInteractiveShell(self: *const LinuxGuiState) []const u8 {
        const shell = self.app.environ.getPosix("SHELL") orelse return "/bin/sh";
        if (shell.len == 0) return "/bin/sh";
        if (std.mem.indexOfScalar(u8, shell, 0) != null) return "/bin/sh";
        if (!std.fs.path.isAbsolute(shell)) return "/bin/sh";
        return shell;
    }

    fn stopPtySession(self: *LinuxGuiState) void {
        if (self.pty_session) |*session| {
            if (self.pty_forced_state) |state| {
                if (state == .cancelled) {
                    session.kill();
                    self.appendOutput(.stderr, "pty kill requested\n", .{});
                    self.message("pty kill requested", .{});
                    return;
                }
            }
            self.pty_forced_state = .cancelled;
            session.terminate();
            self.appendOutput(.stderr, "pty stop requested\n", .{});
            self.message("pty stop requested", .{});
            return;
        }
        self.message("pty: no active session", .{});
    }

    fn terminalPtySize(self: *const LinuxGuiState) terminal_pty.Size {
        const cols: u16 = @intCast(@max(@divTrunc(self.window_width - 36, 8), 40));
        const rows: u16 = @intCast(@max(self.bottomRowsFrom(outputLinesTop(self)), 12));
        return .{ .rows = rows, .cols = cols };
    }

    fn activePtyFd(self: *const LinuxGuiState) ?i32 {
        if (self.pty_session) |session| return session.master_fd;
        return null;
    }

    fn ptyStatusLabel(self: *const LinuxGuiState) []const u8 {
        if (self.pty_session != null) return "running";
        return "idle";
    }

    fn pumpPtySession(self: *LinuxGuiState) bool {
        var changed = false;
        if (self.pty_session) |*session| {
            var buffer: [4096]u8 = undefined;
            while (true) {
                const result = session.read(buffer[0..]) catch {
                    self.pty_forced_state = .failed;
                    session.terminate();
                    break;
                };
                switch (result) {
                    .data => |len| {
                        self.pty_output_bytes += len;
                        self.app.process_console.appendBytes(.stdout, buffer[0..len]) catch {};
                        changed = true;
                        if (self.pty_ticket) |ticket| {
                            if (self.pty_output_bytes > ticket.output_limit_bytes and self.pty_forced_state == null) {
                                self.pty_forced_state = .output_limited;
                                self.appendOutput(.stderr, "pty output exceeded {d} byte limit; terminating\n", .{ticket.output_limit_bytes});
                                session.terminate();
                            }
                        }
                    },
                    .would_block => break,
                    .closed => break,
                }
            }

            if (self.pty_ticket) |ticket| {
                if (ticket.timeout_ms) |timeout_ms| {
                    const elapsed: u64 = @intCast(@max(monotonicMillis() - self.pty_started_ms, 0));
                    if (elapsed > timeout_ms and self.pty_forced_state == null) {
                        self.pty_forced_state = .timed_out;
                        self.appendOutput(.stderr, "pty timeout after {d}ms; terminating\n", .{timeout_ms});
                        session.terminate();
                        changed = true;
                    }
                }
            }

            if (session.pollExit()) |exit_status| {
                self.finishPtySession(exit_status.exit_code);
                changed = true;
            }
        }
        return changed;
    }

    fn finishPtySession(self: *LinuxGuiState, exit_code: i32) void {
        var ticket = self.pty_ticket orelse return;
        self.pty_ticket = null;
        defer ticket.deinit();

        const state = self.pty_forced_state orelse .finished;
        self.pty_forced_state = null;
        if (self.pty_session) |*session| {
            session.deinit();
            self.pty_session = null;
        }

        self.app.process_console.finish(exit_code);
        self.appendOutput(.stdout, "pty exit: {d}\n", .{exit_code});
        self.recordPtyTicket(&ticket, state, exit_code);
        self.refreshLinuxSelfProtection();
        self.message("pty {s}: {d}", .{ @tagName(state), exit_code });
    }

    fn recordPtyTicket(self: *LinuxGuiState, ticket: *const execution_queue.Ticket, state: execution_queue.State, exit_code: i32) void {
        self.app.execution_queue.recordHistory(
            ticket,
            self.app.workspace.root_path,
            state,
            exit_code,
            self.app.process_console.lines.items.len,
            self.app.process_console.sanitized_stats.total(),
        ) catch |err| {
            self.appendOutput(.stderr, "pty history failed: {s}\n", .{@errorName(err)});
        };
    }

    fn sendTerminalInputToPty(self: *LinuxGuiState) void {
        if (self.pty_session == null) return self.queueTerminalInput();
        var line: std.Io.Writer.Allocating = .init(self.allocator);
        defer line.deinit();
        line.writer.writeAll(self.terminal_input.items) catch |err| return self.message("pty input failed: {s}", .{@errorName(err)});
        line.writer.writeByte('\n') catch |err| return self.message("pty input failed: {s}", .{@errorName(err)});
        self.writeBytesToPty(line.written());
        self.terminal_input.clearRetainingCapacity();
        self.terminal_history_cursor = null;
    }

    fn writeBytesToPty(self: *LinuxGuiState, bytes: []const u8) void {
        if (self.pty_session) |*pty| {
            var index: usize = 0;
            while (index < bytes.len) {
                const written = pty.write(bytes[index..]) catch |err| {
                    self.message("pty write failed: {s}", .{@errorName(err)});
                    return;
                };
                if (written == 0) return;
                index += written;
            }
        }
    }

    fn closePtySession(self: *LinuxGuiState) void {
        if (self.pty_session) |*session| {
            session.terminate();
            session.deinit();
            self.pty_session = null;
        }
        if (self.pty_ticket) |*ticket| {
            ticket.deinit();
            self.pty_ticket = null;
        }
        self.pty_forced_state = null;
    }

    fn loadWorkbenchSettings(self: *LinuxGuiState) void {
        const path = self.allocWorkbenchSettingsPath() catch |err| {
            self.appendOutput(.stderr, "workbench settings path failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, self.allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                self.appendOutput(.stderr, "workbench settings load failed: {s}\n", .{@errorName(err)});
                return;
            },
        };
        defer self.allocator.free(bytes);

        self.applyWorkbenchSettings(workbench_settings.parse(bytes));
    }

    fn saveWorkbenchSettings(self: *LinuxGuiState) void {
        self.persistWorkbenchSettings() catch |err| {
            self.appendOutput(.stderr, "workbench settings save failed: {s}\n", .{@errorName(err)});
        };
    }

    fn persistWorkbenchSettings(self: *LinuxGuiState) !void {
        var text: std.Io.Writer.Allocating = .init(self.allocator);
        defer text.deinit();
        try workbench_settings.write(&text.writer, self.currentWorkbenchSettings());

        const dir_path = try self.allocWorkbenchSettingsDirPath();
        defer self.allocator.free(dir_path);
        try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir_path);

        const path = try self.allocWorkbenchSettingsPath();
        defer self.allocator.free(path);
        var file = try createWorkbenchSettingsFile(path);
        defer file.close(std.Options.debug_io);

        var buffer: [4096]u8 = undefined;
        var writer = file.writer(std.Options.debug_io, &buffer);
        try writer.interface.writeAll(text.written());
        try writer.interface.flush();
        try file.sync(std.Options.debug_io);
    }

    fn currentWorkbenchSettings(self: *const LinuxGuiState) workbench_settings.Settings {
        return .{
            .launch_profile = switch (self.linux_launch_profile) {
                .read_only => .read_only,
                .safe => .safe,
                .network => .network,
                .publish => .publish,
            },
            .tutorial_language = switch (self.tutorial_language) {
                .ja => .ja,
                .en => .en,
            },
            .bottom_panel = switch (self.bottom_panel) {
                .output => .output,
                .tasks => .tasks,
                .git => .git,
                .extensions => .extensions,
                .diagnostics => .diagnostics,
                .security => .security,
                .settings => .settings,
                .keybindings => .keybindings,
                .tutorial => .tutorial,
                .publish => .publish,
            },
        };
    }

    fn applyWorkbenchSettings(self: *LinuxGuiState, settings: workbench_settings.Settings) void {
        self.linux_launch_profile = switch (settings.launch_profile) {
            .read_only => .read_only,
            .safe => .safe,
            .network => .network,
            .publish => .publish,
        };
        self.tutorial_language = switch (settings.tutorial_language) {
            .ja => .ja,
            .en => .en,
        };
        self.bottom_panel = switch (settings.bottom_panel) {
            .output => .output,
            .tasks => .tasks,
            .git => .git,
            .extensions => .extensions,
            .diagnostics => .diagnostics,
            .security => .security,
            .settings => .settings,
            .keybindings => .keybindings,
            .tutorial => .tutorial,
            .publish => .publish,
        };
    }

    fn allocWorkbenchSettingsDirPath(self: *const LinuxGuiState) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.app.workspace.root_path, ".zide" });
    }

    fn allocWorkbenchSettingsPath(self: *const LinuxGuiState) ![]u8 {
        const dir_path = try self.allocWorkbenchSettingsDirPath();
        defer self.allocator.free(dir_path);
        return std.fs.path.join(self.allocator, &.{ dir_path, "workbench.conf" });
    }

    fn enableLinuxSelfProtection(self: *LinuxGuiState) void {
        self.linux_security.no_new_privs_set = if (trySetNoNewPrivs()) .on else .off;
        self.linux_security.dumpable_set = if (trySetDumpable(false)) .on else .off;
        self.linux_security.ambient_clear = if (tryClearAmbientCapabilities()) .on else .off;
        const drops = tryDropDangerousBoundingCapabilities();
        self.linux_security.bounding_caps_dropped = drops.dropped;
        self.linux_security.bounding_caps_drop_failed = drops.failed;
        const seals = trySealExecFileDescriptors();
        self.linux_security.fd_cloexec_sealed = seals.sealed;
        self.linux_security.fd_cloexec_seal_failed = seals.failed;
        self.refreshLinuxSelfProtection();
        var tracer_buf: [32]u8 = undefined;
        var euid_buf: [32]u8 = undefined;
        var filters_buf: [32]u8 = undefined;
        self.appendOutput(.stdout, "linux self-protection: no_new_privs_set={s} no_new_privs={s} dumpable={s} dumpable_set={s} ambient_clear={s} seccomp={s} filters={s} cap_eff={s} euid={s}/{s} tracer={s} core={s} nspid={d}/{s} dangerous_bound={d} dropped={d} drop_failed={d} fd_sealed={d} fd_seal_failed={d}\n", .{
            flagLabel(self.linux_security.no_new_privs_set),
            flagLabel(self.linux_security.no_new_privs),
            flagLabel(self.linux_security.dumpable),
            flagLabel(self.linux_security.dumpable_set),
            flagLabel(self.linux_security.ambient_clear),
            seccompLabel(self.linux_security.seccomp_mode),
            optionalUsizeLabel(filters_buf[0..], self.linux_security.seccomp_filters),
            self.linuxSecurityCapEffLabel(),
            optionalUsizeLabel(euid_buf[0..], self.linux_security.euid),
            flagLabel(self.linux_security.euid_root),
            optionalUsizeLabel(tracer_buf[0..], self.linux_security.tracer_pid),
            flagLabel(self.linux_security.core_dumping),
            self.linux_security.nspid_count,
            flagLabel(self.linux_security.pid_namespace),
            self.linux_security.dangerous_bounding_caps,
            self.linux_security.bounding_caps_dropped,
            self.linux_security.bounding_caps_drop_failed,
            self.linux_security.fd_cloexec_sealed,
            self.linux_security.fd_cloexec_seal_failed,
        });
    }

    fn refreshLinuxSelfProtection(self: *LinuxGuiState) void {
        const previous = self.linux_security;
        self.linux_security = readLinuxSecuritySnapshot(self.allocator, previous.no_new_privs_set, previous.dumpable_set);
        self.linux_security.ambient_clear = previous.ambient_clear;
        self.linux_security.bounding_caps_dropped = previous.bounding_caps_dropped;
        self.linux_security.bounding_caps_drop_failed = previous.bounding_caps_drop_failed;
        self.linux_security.fd_cloexec_sealed = previous.fd_cloexec_sealed;
        self.linux_security.fd_cloexec_seal_failed = previous.fd_cloexec_seal_failed;
    }

    fn sealLinuxExecBoundary(self: *LinuxGuiState) void {
        const seals = trySealExecFileDescriptors();
        self.linux_security.fd_cloexec_sealed += seals.sealed;
        self.linux_security.fd_cloexec_seal_failed += seals.failed;
        self.refreshLinuxSelfProtection();
        self.message("linux fd seal: +{d} failed:{d}", .{ seals.sealed, seals.failed });
    }

    fn setLinuxLaunchProfile(self: *LinuxGuiState, profile: LinuxLaunchProfile) void {
        self.linux_launch_profile = profile;
        self.saveWorkbenchSettings();
        if (self.applyLinuxLaunchProfileToLatestQueued("profile selected")) {
            self.message("launch profile: {s}", .{linuxLaunchProfileLabel(profile)});
        } else {
            self.message("launch profile: {s} (next task)", .{linuxLaunchProfileLabel(profile)});
        }
    }

    fn applyLinuxLaunchProfileToLatestQueued(self: *LinuxGuiState, reason: []const u8) bool {
        const ticket = self.app.execution_queue.latestQueued() orelse return false;
        applyLinuxLaunchProfile(ticket, self.linux_launch_profile);
        self.appendOutput(.stdout, "linux launch profile: {s} ({s}) env:{s} fs:{s} net:{s} timeout:{s} output:{d}\n", .{
            linuxLaunchProfileLabel(self.linux_launch_profile),
            reason,
            @tagName(ticket.env_policy),
            @tagName(ticket.fs_policy),
            @tagName(ticket.network_policy),
            timeoutLabel(ticket.timeout_ms),
            ticket.output_limit_bytes,
        });
        return true;
    }

    fn prepareLinuxLaunchBoundary(self: *LinuxGuiState) bool {
        _ = self.applyLinuxLaunchProfileToLatestQueued("before run");
        self.linux_security.no_new_privs_set = if (trySetNoNewPrivs()) .on else .off;
        self.linux_security.dumpable_set = if (trySetDumpable(false)) .on else .off;
        self.linux_security.ambient_clear = if (tryClearAmbientCapabilities()) .on else .off;
        self.sealLinuxExecBoundary();
        self.appendOutput(.stdout, "linux launch boundary: nnp={s} dumpable={s} fd_no_cloexec={d} sealed_total={d} seal_failed={d}\n", .{
            flagLabel(self.linux_security.no_new_privs),
            flagLabel(self.linux_security.dumpable),
            self.linux_security.fd_cloexec_missing,
            self.linux_security.fd_cloexec_sealed,
            self.linux_security.fd_cloexec_seal_failed,
        });
        if (self.linux_security.no_new_privs != .on) {
            self.appendOutput(.stderr, "blocked: linux no_new_privs is not active\n", .{});
            self.message("linux launch blocked: no_new_privs inactive", .{});
            self.bottom_panel = .tasks;
            return false;
        }
        return true;
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
        self.refreshWorkspaceTreeState();
        self.ensureFileCursorVisible();
    }

    fn refreshWorkspaceTreeState(self: *LinuxGuiState) void {
        if (self.collapsed_dirs.len == self.app.workspace.entries.items.len) return;
        const next = self.allocator.alloc(bool, self.app.workspace.entries.items.len) catch |err| {
            self.message("tree state failed: {s}", .{@errorName(err)});
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
        if (self.visibleRankOfIndex(self.app.file_cursor) == null) {
            self.app.file_cursor = self.nearestVisibleIndex(self.app.file_cursor) orelse 0;
        }
    }

    fn ensureFileCursorVisible(self: *LinuxGuiState) void {
        self.refreshWorkspaceTreeState();
        const visible = self.visibleFileRows();
        if (self.visibleRankOfIndex(self.app.file_cursor) == null) {
            self.app.file_cursor = self.nearestVisibleIndex(self.app.file_cursor) orelse 0;
        }
        const selected_rank = self.visibleRankOfIndex(self.app.file_cursor) orelse 0;
        if (selected_rank < self.file_scroll_line) {
            self.file_scroll_line = selected_rank;
        } else if (selected_rank >= self.file_scroll_line + visible) {
            self.file_scroll_line = selected_rank - visible + 1;
        }
        const total = self.visibleEntryCount();
        const max_start = if (total > visible) total - visible else 0;
        self.file_scroll_line = @min(self.file_scroll_line, max_start);
    }

    fn scrollFileTree(self: *LinuxGuiState, delta: isize) void {
        self.refreshWorkspaceTreeState();
        const visible = self.visibleFileRows();
        const total = self.visibleEntryCount();
        const max_start = if (total > visible) total - visible else 0;
        self.file_scroll_line = scrollValue(self.file_scroll_line, max_start, delta);
    }

    fn moveFileSelection(self: *LinuxGuiState, delta: isize) void {
        self.app.focus = .files;
        self.refreshWorkspaceTreeState();
        const total = self.visibleEntryCount();
        if (total == 0) {
            self.app.file_cursor = 0;
            return;
        }
        const selected_rank = self.visibleRankOfIndex(self.app.file_cursor) orelse 0;
        const max_rank = total - 1;
        const next_rank = if (delta < 0) blk: {
            const amount: usize = @intCast(-delta);
            break :blk if (amount > selected_rank) 0 else selected_rank - amount;
        } else blk: {
            const amount: usize = @intCast(delta);
            break :blk @min(max_rank, selected_rank + amount);
        };
        if (self.entryIndexAtVisibleRank(next_rank)) |index| self.app.file_cursor = index;
        self.ensureFileCursorVisible();
    }

    fn openSelectedFileTreeEntry(self: *LinuxGuiState) void {
        self.refreshWorkspaceTreeState();
        if (self.app.workspace.entries.items.len == 0) {
            self.message("no workspace entry selected", .{});
            return;
        }
        const selected_index = @min(self.app.file_cursor, self.app.workspace.entries.items.len - 1);
        const entry = self.app.workspace.entries.items[selected_index];
        self.app.focus = .files;
        if (entry.kind == .directory) {
            self.toggleDirectoryCollapse(selected_index);
            return;
        }
        const opened = self.app.openSelectedWorkspaceEntry() catch |err| {
            self.message("open failed: {s}", .{@errorName(err)});
            return;
        };
        if (opened) {
            self.app.mode = .insert;
            self.app.focus = .editor;
            self.syncActiveDocumentToLsp();
            self.message("opened selected file", .{});
        } else {
            self.message("select a file to open", .{});
        }
    }

    fn collapseSelectedDirectory(self: *LinuxGuiState) void {
        self.refreshWorkspaceTreeState();
        if (self.app.workspace.entries.items.len == 0) return;
        const selected_index = @min(self.app.file_cursor, self.app.workspace.entries.items.len - 1);
        const entry = self.app.workspace.entries.items[selected_index];
        if (entry.kind == .directory) {
            if (selected_index < self.collapsed_dirs.len and !self.collapsed_dirs[selected_index] and self.directoryHasChildren(selected_index)) {
                self.toggleDirectoryCollapse(selected_index);
                return;
            }
        }
        if (self.parentDirectoryIndex(selected_index)) |parent| {
            self.app.file_cursor = parent;
            self.app.focus = .files;
            self.ensureFileCursorVisible();
            self.message("selected parent folder", .{});
        }
    }

    fn expandSelectedDirectory(self: *LinuxGuiState) void {
        self.refreshWorkspaceTreeState();
        if (self.app.workspace.entries.items.len == 0) return;
        const selected_index = @min(self.app.file_cursor, self.app.workspace.entries.items.len - 1);
        const entry = self.app.workspace.entries.items[selected_index];
        if (entry.kind == .directory and selected_index < self.collapsed_dirs.len and self.directoryHasChildren(selected_index)) {
            if (self.collapsed_dirs[selected_index]) {
                self.toggleDirectoryCollapse(selected_index);
            } else {
                self.moveFileSelection(1);
            }
            return;
        }
        self.openSelectedFileTreeEntry();
    }

    fn toggleDirectoryCollapse(self: *LinuxGuiState, index: usize) void {
        self.refreshWorkspaceTreeState();
        if (index >= self.collapsed_dirs.len) return;
        if (self.app.workspace.entries.items[index].kind != .directory) return;
        self.collapsed_dirs[index] = !self.collapsed_dirs[index];
        if (self.collapsed_dirs[index]) {
            if (self.visibleRankOfIndex(self.app.file_cursor) == null) self.app.file_cursor = index;
            self.message("folder collapsed", .{});
        } else {
            self.message("folder expanded", .{});
        }
        self.ensureFileCursorVisible();
    }

    fn visibleEntryCount(self: *const LinuxGuiState) usize {
        var count: usize = 0;
        for (self.app.workspace.entries.items, 0..) |_, index| {
            if (self.isEntryVisible(index)) count += 1;
        }
        return count;
    }

    fn visibleRankOfIndex(self: *const LinuxGuiState, target: usize) ?usize {
        var rank: usize = 0;
        for (self.app.workspace.entries.items, 0..) |_, index| {
            if (!self.isEntryVisible(index)) continue;
            if (index == target) return rank;
            rank += 1;
        }
        return null;
    }

    fn entryIndexAtVisibleRank(self: *const LinuxGuiState, target_rank: usize) ?usize {
        var rank: usize = 0;
        for (self.app.workspace.entries.items, 0..) |_, index| {
            if (!self.isEntryVisible(index)) continue;
            if (rank == target_rank) return index;
            rank += 1;
        }
        return null;
    }

    fn nearestVisibleIndex(self: *const LinuxGuiState, target: usize) ?usize {
        if (self.app.workspace.entries.items.len == 0) return null;
        var index = @min(target, self.app.workspace.entries.items.len - 1);
        while (true) {
            if (self.isEntryVisible(index)) return index;
            if (index == 0) break;
            index -= 1;
        }
        for (self.app.workspace.entries.items, 0..) |_, forward| {
            if (forward > target and self.isEntryVisible(forward)) return forward;
        }
        return null;
    }

    fn isEntryVisible(self: *const LinuxGuiState, index: usize) bool {
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

    fn directoryHasChildren(self: *const LinuxGuiState, index: usize) bool {
        if (index + 1 >= self.app.workspace.entries.items.len) return false;
        const entry = self.app.workspace.entries.items[index];
        return self.app.workspace.entries.items[index + 1].depth > entry.depth;
    }

    fn parentDirectoryIndex(self: *const LinuxGuiState, index: usize) ?usize {
        if (index >= self.app.workspace.entries.items.len) return null;
        const depth = self.app.workspace.entries.items[index].depth;
        if (depth == 0) return null;
        var i = index;
        while (i > 0) {
            i -= 1;
            const candidate = self.app.workspace.entries.items[i];
            if (candidate.depth < depth and candidate.kind == .directory) return i;
        }
        return null;
    }

    fn fileTreeHasControl(self: *const LinuxGuiState) bool {
        return self.app.focus == .files or self.app.documents.active_index == null;
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

    fn clearSelection(self: *LinuxGuiState) void {
        self.selection_anchor = null;
    }

    fn publishPrimarySelection(self: *LinuxGuiState, x11: *X11) void {
        const doc = self.app.documents.active() orelse return;
        const range = self.selectedRange(doc) orelse return;
        self.primary_selection.clearRetainingCapacity();
        self.primary_selection.appendSlice(doc.text.bytes[range.start..range.end]) catch |err| {
            self.primary_owned = false;
            self.appendOutput(.stderr, "x11 primary copy failed: {s}\n", .{@errorName(err)});
            return;
        };
        x11.setSelectionOwner(x11.atoms.primary) catch |err| {
            self.primary_owned = false;
            self.appendOutput(.stderr, "x11 primary owner failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.primary_owned = true;
    }

    fn deleteSelectedRange(self: *LinuxGuiState, doc: *document_mod.Document) bool {
        const range = self.selectedRange(doc) orelse return false;
        doc.deleteRange(range.start, range.end) catch |err| {
            self.message("delete failed: {s}", .{@errorName(err)});
            return false;
        };
        self.clearSelection();
        self.ensureEditorCursorVisible();
        self.syncActiveDocumentToLsp();
        return true;
    }

    fn insertText(self: *LinuxGuiState, bytes: []const u8) void {
        const doc = self.app.documents.active() orelse {
            self.message("open a file before typing", .{});
            return;
        };
        if (self.selectedRange(doc)) |range| {
            doc.replaceRange(range.start, range.end, bytes) catch |err| {
                self.message("insert failed: {s}", .{@errorName(err)});
                return;
            };
            self.clearSelection();
        } else {
            doc.insert(doc.cursor.position.byte_offset, bytes) catch |err| {
                self.message("insert failed: {s}", .{@errorName(err)});
                return;
            };
        }
        self.app.mode = .insert;
        self.app.focus = .editor;
        self.ensureEditorCursorVisible();
        self.syncActiveDocumentToLsp();
    }

    fn insertNewline(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse {
            self.message("open a file before typing", .{});
            return;
        };
        self.insertText(doc.preferredNewline());
    }

    fn selectAll(self: *LinuxGuiState, x11: *X11) void {
        const doc = self.app.documents.active() orelse return;
        self.selection_anchor = 0;
        const position = doc.positionFromOffset(doc.text.bytes.len) catch return;
        navigation.setCursor(doc, position);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.publishPrimarySelection(x11);
        self.message("selected all", .{});
    }

    fn copySelectionToClipboard(self: *LinuxGuiState, x11: *X11) bool {
        const doc = self.app.documents.active() orelse return false;
        const range = self.selectedRange(doc) orelse {
            self.message("no selection to copy", .{});
            return false;
        };
        self.clipboard.clearRetainingCapacity();
        self.clipboard.appendSlice(doc.text.bytes[range.start..range.end]) catch |err| {
            self.message("copy failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "clipboard copy failed: {s}\n", .{@errorName(err)});
            return false;
        };
        self.primary_selection.clearRetainingCapacity();
        self.primary_selection.appendSlice(self.clipboard.items) catch |err| {
            self.message("primary copy failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "primary copy failed: {s}\n", .{@errorName(err)});
            return false;
        };
        x11.setSelectionOwner(x11.atoms.clipboard) catch |err| {
            self.clipboard_owned = false;
            self.message("x11 clipboard failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "x11 clipboard owner failed: {s}\n", .{@errorName(err)});
            return false;
        };
        self.clipboard_owned = true;
        x11.setSelectionOwner(x11.atoms.primary) catch |err| {
            self.primary_owned = false;
            self.appendOutput(.stderr, "x11 primary owner failed: {s}\n", .{@errorName(err)});
            self.message("copied selection (clipboard only)", .{});
            return true;
        };
        self.primary_owned = true;
        self.message("copied selection", .{});
        return true;
    }

    fn cutSelectionToClipboard(self: *LinuxGuiState, x11: *X11) void {
        const doc = self.app.documents.active() orelse return;
        if (!self.copySelectionToClipboard(x11)) return;
        _ = self.deleteSelectedRange(doc);
        self.message("cut selection", .{});
    }

    fn pasteFromClipboard(self: *LinuxGuiState, x11: *X11) void {
        if (!self.clipboard_owned) {
            const external = x11.requestSelectionText(self.allocator, x11.atoms.clipboard) catch |clipboard_err| {
                return self.pasteFromPrimaryOrLocal(x11, clipboard_err);
            };
            defer self.allocator.free(external);
            if (external.len == 0) return;
            self.insertText(external);
            self.message("pasted from X11 clipboard", .{});
            return;
        }
        if (self.clipboard.items.len == 0) {
            self.message("clipboard is empty", .{});
            return;
        }
        self.insertText(self.clipboard.items);
        self.message("pasted", .{});
    }

    fn pasteFromPrimaryOrLocal(self: *LinuxGuiState, x11: *X11, clipboard_err: anyerror) void {
        if (!self.primary_owned) {
            const primary = x11.requestSelectionText(self.allocator, x11.atoms.primary) catch |primary_err| {
                if (self.clipboard.items.len == 0) {
                    self.message("clipboard paste failed: {s}", .{@errorName(clipboard_err)});
                    self.appendOutput(.stderr, "x11 clipboard paste failed: {s}; primary failed: {s}\n", .{ @errorName(clipboard_err), @errorName(primary_err) });
                    return;
                }
                self.message("external clipboard unavailable; using ZIDE clipboard", .{});
                self.insertText(self.clipboard.items);
                return;
            };
            defer self.allocator.free(primary);
            if (primary.len == 0) return;
            self.insertText(primary);
            self.message("pasted from X11 primary", .{});
            return;
        }

        if (self.primary_selection.items.len == 0) {
            self.message("primary is empty", .{});
            return;
        }
        self.insertText(self.primary_selection.items);
        self.message("pasted from ZIDE primary", .{});
    }

    fn pasteFromPrimary(self: *LinuxGuiState, x11: *X11) void {
        if (!self.primary_owned) {
            const primary = x11.requestSelectionText(self.allocator, x11.atoms.primary) catch |err| {
                if (self.clipboard.items.len == 0) {
                    self.message("primary paste failed: {s}", .{@errorName(err)});
                    return;
                }
                self.insertText(self.clipboard.items);
                self.message("primary unavailable; pasted ZIDE clipboard", .{});
                return;
            };
            defer self.allocator.free(primary);
            if (primary.len == 0) return;
            self.insertText(primary);
            self.message("pasted from X11 primary", .{});
            return;
        }

        if (self.primary_selection.items.len == 0) return self.message("primary is empty", .{});
        self.insertText(self.primary_selection.items);
        self.message("pasted from ZIDE primary", .{});
    }

    fn terminalAcceptPaste(self: *LinuxGuiState, bytes: []const u8, source: []const u8) void {
        if (bytes.len == 0) return self.message("terminal paste: {s} empty", .{source});

        if (self.pty_session != null) {
            const max_pty_paste: usize = 64 * 1024;
            const paste_len = @min(bytes.len, max_pty_paste);
            self.writeBytesToPty(bytes[0..paste_len]);
            if (paste_len < bytes.len) {
                self.appendOutput(.stderr, "pty paste clipped: {d}/{d} byte(s) from {s}\n", .{ paste_len, bytes.len, source });
                self.message("pty paste clipped: {d}/{d} byte(s)", .{ paste_len, bytes.len });
            } else {
                self.message("pty paste: {s} {d} byte(s)", .{ source, paste_len });
            }
            return;
        }

        const max_input: usize = 4096;
        if (self.terminal_input.items.len >= max_input) return self.message("terminal paste limit reached", .{});
        const remaining = max_input - self.terminal_input.items.len;
        const paste_len = @min(bytes.len, remaining);
        self.terminalInsertText(bytes[0..paste_len]);
        if (paste_len < bytes.len) {
            self.message("terminal paste clipped: {d}/{d} byte(s)", .{ paste_len, bytes.len });
        } else {
            self.message("terminal paste: {s} {d} byte(s)", .{ source, paste_len });
        }
    }

    fn pasteIntoTerminal(self: *LinuxGuiState, x11: *X11) void {
        if (!self.clipboard_owned) {
            const external = x11.requestSelectionText(self.allocator, x11.atoms.clipboard) catch |clipboard_err| {
                return self.pastePrimaryOrLocalIntoTerminal(x11, clipboard_err);
            };
            defer self.allocator.free(external);
            self.terminalAcceptPaste(external, "X11 clipboard");
            return;
        }
        if (self.clipboard.items.len == 0) return self.message("terminal clipboard is empty", .{});
        self.terminalAcceptPaste(self.clipboard.items, "ZIDE clipboard");
    }

    fn pastePrimaryOrLocalIntoTerminal(self: *LinuxGuiState, x11: *X11, clipboard_err: anyerror) void {
        if (!self.primary_owned) {
            const primary = x11.requestSelectionText(self.allocator, x11.atoms.primary) catch |primary_err| {
                if (self.clipboard.items.len == 0) {
                    self.message("terminal paste failed: {s}", .{@errorName(clipboard_err)});
                    self.appendOutput(.stderr, "terminal clipboard paste failed: {s}; primary failed: {s}\n", .{ @errorName(clipboard_err), @errorName(primary_err) });
                    return;
                }
                self.terminalAcceptPaste(self.clipboard.items, "ZIDE clipboard");
                return;
            };
            defer self.allocator.free(primary);
            self.terminalAcceptPaste(primary, "X11 primary");
            return;
        }

        if (self.primary_selection.items.len == 0) return self.message("terminal primary is empty", .{});
        self.terminalAcceptPaste(self.primary_selection.items, "ZIDE primary");
    }

    fn pastePrimaryIntoTerminal(self: *LinuxGuiState, x11: *X11) void {
        if (!self.primary_owned) {
            const primary = x11.requestSelectionText(self.allocator, x11.atoms.primary) catch |err| {
                if (self.clipboard.items.len == 0) return self.message("terminal primary paste failed: {s}", .{@errorName(err)});
                self.terminalAcceptPaste(self.clipboard.items, "ZIDE clipboard");
                return;
            };
            defer self.allocator.free(primary);
            self.terminalAcceptPaste(primary, "X11 primary");
            return;
        }

        if (self.primary_selection.items.len == 0) return self.message("terminal primary is empty", .{});
        self.terminalAcceptPaste(self.primary_selection.items, "ZIDE primary");
    }

    fn openContextMenu(self: *LinuxGuiState, x: i16, y: i16) void {
        const menu_w: i16 = 230;
        const menu_h = contextMenuHeight();
        self.context_menu_x = @min(@max(x, @as(i16, 8)), @max(@as(i16, 8), self.window_width - menu_w - 8));
        self.context_menu_y = @min(@max(y, @as(i16, 8)), @max(@as(i16, 8), self.window_height - STATUS_HEIGHT - menu_h - 8));
        self.context_menu_selected = 0;
        self.context_menu_visible = true;
        self.quick_panel.close();
        self.app.palette.close();
        self.message("context menu", .{});
    }

    fn closeContextMenu(self: *LinuxGuiState) void {
        self.context_menu_visible = false;
        self.context_menu_selected = 0;
    }

    fn moveContextSelection(self: *LinuxGuiState, delta: isize) void {
        const count = context_actions.len;
        if (count == 0) return;
        if (delta < 0) {
            const amount: usize = @intCast(-delta);
            self.context_menu_selected = if (amount > self.context_menu_selected) 0 else self.context_menu_selected - amount;
        } else {
            const amount: usize = @intCast(delta);
            self.context_menu_selected = @min(count - 1, self.context_menu_selected + amount);
        }
    }

    fn handleContextMenuKey(self: *LinuxGuiState, x11: *X11, key: event_mod.KeyEvent) bool {
        if (!self.context_menu_visible) return false;
        switch (key.code) {
            .escape => {
                self.closeContextMenu();
                return true;
            },
            .arrow_up => {
                self.moveContextSelection(-1);
                return true;
            },
            .arrow_down => {
                self.moveContextSelection(1);
                return true;
            },
            .enter => {
                const action = context_actions[@min(self.context_menu_selected, context_actions.len - 1)];
                self.closeContextMenu();
                self.executeContextAction(x11, action);
                return true;
            },
            else => {
                self.closeContextMenu();
                return false;
            },
        }
    }

    fn handleContextMenuClick(self: *LinuxGuiState, x11: *X11, x: i16, y: i16) bool {
        if (!self.context_menu_visible) return false;
        const action = contextActionAt(self, x, y) orelse {
            self.closeContextMenu();
            return true;
        };
        self.closeContextMenu();
        self.executeContextAction(x11, action);
        return true;
    }

    fn executeContextAction(self: *LinuxGuiState, x11: *X11, action: ContextAction) void {
        if (!contextActionEnabled(self, action)) {
            self.message("{s} unavailable", .{contextActionLabel(action)});
            return;
        }
        switch (action) {
            .copy => _ = self.copySelectionToClipboard(x11),
            .cut => self.cutSelectionToClipboard(x11),
            .paste => self.pasteFromClipboard(x11),
            .select_all => self.selectAll(x11),
            .find => self.execute("editor.find", .command_palette),
            .scan => self.execute("security.scan_current", .command_palette),
            .scan_selection => self.scanSelectedRangeSecurity(),
            .boundary_lens => self.explainBoundaryLens(),
            .comment => self.execute("editor.toggle_comment", .command_palette),
            .references => self.findReferencesAtCursor(),
            .rename => self.openRenamePanel(),
            .goto_line => self.execute("editor.goto_line", .command_palette),
            .close_editor => self.closeActiveDocument(),
            .task_queue => self.execute("task.preview_next", .command_palette),
            .palette => self.execute("view.command_palette", .command_palette),
        }
    }

    fn explainBoundaryLens(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const base_path = doc.path orelse "(scratch)";
        const Scope = struct {
            label: []const u8,
            bytes: []const u8,
            line: usize,
            column: usize,
        };
        const scope: Scope = if (self.selectedRange(doc)) |range| blk: {
            const lc = doc.text.offsetToLineColumn(range.start) catch return self.message("selection offset invalid", .{});
            break :blk .{
                .label = "selection",
                .bytes = doc.text.bytes[range.start..range.end],
                .line = lc.line,
                .column = lc.column,
            };
        } else blk: {
            const line = doc.cursor.position.line;
            break :blk .{
                .label = "current-line",
                .bytes = doc.text.lineSlice(line),
                .line = line,
                .column = 0,
            };
        };
        if (scope.bytes.len == 0) return self.message("boundary lens: empty {s}", .{scope.label});

        var collection = self.scanSelectionSource(scope.bytes, base_path, doc.language) catch |err| {
            self.message("boundary lens failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "boundary lens failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer collection.deinit();

        var boundaries: BoundaryCounts = .{};
        for (collection.items.items) |item| addBoundary(&boundaries, findings_mod.boundaryFor(item.category));
        const risks = riskCounts(&collection);

        self.bottom_panel = .output;
        self.appendOutput(.stdout, "boundary lens: {s}:{d}:{d} scope={s} bytes={d} findings={d} risk c/h/m/l/i={d}/{d}/{d}/{d}/{d}\n", .{
            base_path,
            scope.line + 1,
            scope.column + 1,
            scope.label,
            scope.bytes.len,
            collection.items.items.len,
            risks.critical,
            risks.high,
            risks.medium,
            risks.low,
            risks.info,
        });
        self.appendOutput(.stdout, "boundary counts: memory={d} execution={d} filesystem={d} network={d} dependency={d} secret={d} text={d} path={d} git={d}\n", .{
            boundaries.memory,
            boundaries.execution,
            boundaries.filesystem,
            boundaries.network,
            boundaries.dependency,
            boundaries.secret,
            boundaries.text,
            boundaries.path,
            boundaries.git,
        });

        for (collection.items.items[0..@min(collection.items.items.len, @as(usize, 10))]) |item| {
            const line = scope.line + item.line + 1;
            const column = if (item.line == 0) scope.column + item.column + 1 else item.column + 1;
            const boundary = findings_mod.boundaryFor(item.category);
            self.appendOutput(.stdout, "- {s}:{d}:{d} [{s}/{s}/{s}] {s}\n", .{
                base_path,
                line,
                column,
                @tagName(item.risk),
                findings_mod.boundaryLabel(boundary),
                @tagName(item.category),
                item.message,
            });
        }
        if (collection.items.items.len > 10) self.appendOutput(.stdout, "... {d} more boundary item(s)\n", .{collection.items.items.len - 10});
        self.message("boundary lens: {d} finding(s)", .{collection.items.items.len});
    }

    fn scanSelectedRangeSecurity(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const range = self.selectedRange(doc) orelse return self.message("select code to scan", .{});
        if (range.start >= range.end) return self.message("select code to scan", .{});
        const selected = doc.text.bytes[range.start..range.end];
        const base_path = doc.path orelse "(scratch)";
        const start_lc = doc.text.offsetToLineColumn(range.start) catch return self.message("selection offset invalid", .{});

        var label_buf: [760]u8 = undefined;
        const selection_label = std.fmt.bufPrint(label_buf[0..], "{s}#selection:{d}:{d}", .{
            base_path,
            start_lc.line + 1,
            start_lc.column + 1,
        }) catch base_path;

        var collection = self.scanSelectionSource(selected, base_path, doc.language) catch |err| {
            self.message("selection scan failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "selection scan failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer collection.deinit();

        self.app.security_findings.clear();
        for (collection.items.items) |item| {
            const line = start_lc.line + item.line;
            const column = if (item.line == 0) start_lc.column + item.column else item.column;
            self.app.security_findings.append(item.category, item.risk, base_path, line, column, item.message, item.evidence) catch |err| {
                self.message("selection scan store failed: {s}", .{@errorName(err)});
                self.appendOutput(.stderr, "selection scan store failed: {s}\n", .{@errorName(err)});
                return;
            };
        }

        self.security_scroll_line = 0;
        self.bottom_panel = .security;
        self.appendOutput(.stdout, "selection security scan: {s} bytes={d} findings={d}\n", .{ selection_label, selected.len, collection.items.items.len });
        for (collection.items.items[0..@min(collection.items.items.len, @as(usize, 12))]) |item| {
            const line = start_lc.line + item.line + 1;
            const column = if (item.line == 0) start_lc.column + item.column + 1 else item.column + 1;
            self.appendOutput(.stdout, "{s}:{d}:{d} [{s}/{s}] {s}\n", .{
                base_path,
                line,
                column,
                @tagName(item.category),
                @tagName(item.risk),
                item.message,
            });
        }
        if (collection.items.items.len > 12) self.appendOutput(.stdout, "... {d} more selection finding(s)\n", .{collection.items.items.len - 12});
        self.message("selection scan: {d} finding(s)", .{collection.items.items.len});
    }

    fn scanSelectionSource(self: *LinuxGuiState, source: []const u8, path: []const u8, language: modes.LanguageMode) !findings_mod.Collection {
        var collection = try text_integrity.scan(self.allocator, source, .{ .path = path });
        errdefer collection.deinit();

        if (language == .zon or std.mem.endsWith(u8, path, "build.zig.zon")) {
            var package_findings = try package_trust.scanZon(self.allocator, source, .{ .path = path });
            defer package_findings.deinit();
            try appendSecurityFindings(&collection, &package_findings);
            return collection;
        }
        if (language == .zig) {
            var zig_findings = try zig_scanner.scanSource(self.allocator, source, .{ .path = path });
            defer zig_findings.deinit();
            try appendSecurityFindings(&collection, &zig_findings);
            return collection;
        }
        if (polyglot_scanner.isInterestingPath(path, language)) {
            var polyglot_findings = try polyglot_scanner.scanSource(self.allocator, source, .{ .path = path, .language = language });
            defer polyglot_findings.deinit();
            try appendSecurityFindings(&collection, &polyglot_findings);
            return collection;
        }
        return collection;
    }

    fn moveEditorCursor(self: *LinuxGuiState, x11: *X11, move: navigation.Move, extend_selection: bool) void {
        const doc = self.app.documents.active() orelse return;
        const anchor = doc.cursor.position.byte_offset;
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = anchor;
        }
        navigation.moveCursor(doc, move) catch return;
        if (!extend_selection) {
            self.clearSelection();
        } else if (self.selection_anchor) |selection_anchor| {
            if (selection_anchor == doc.cursor.position.byte_offset) self.clearSelection();
        }
        self.app.focus = .editor;
        self.ensureEditorCursorVisible();
        if (extend_selection) self.publishPrimarySelection(x11);
    }

    fn handleSelectionClear(self: *LinuxGuiState, selection: u32, x11: *const X11) void {
        if (selection == x11.atoms.clipboard) {
            self.clipboard_owned = false;
            self.message("x11 clipboard ownership moved", .{});
        } else if (selection == x11.atoms.primary) {
            self.primary_owned = false;
            self.message("x11 primary ownership moved", .{});
        }
    }

    fn handleSelectionRequest(self: *LinuxGuiState, x11: *X11, event: []const u8) void {
        const time = readLe32(event[4..8]);
        const requestor = readLe32(event[12..16]);
        const selection = readLe32(event[16..20]);
        const target = readLe32(event[20..24]);
        const requested_property = readLe32(event[24..28]);
        const property = if (requested_property == 0) target else requested_property;
        var response_property: u32 = 0;

        const selection_data: ?[]const u8 = if (selection == x11.atoms.clipboard and self.clipboard_owned)
            self.clipboard.items
        else if (selection == x11.atoms.primary and self.primary_owned)
            self.primary_selection.items
        else
            null;
        const owns_selection = selection_data != null;
        if (owns_selection) {
            if (target == x11.atoms.targets) {
                var data: [16]u8 = undefined;
                writeLe32(data[0..4], x11.atoms.targets);
                writeLe32(data[4..8], x11.atoms.utf8_string);
                writeLe32(data[8..12], x11.atoms.string);
                writeLe32(data[12..16], x11.atoms.text);
                x11.changeProperty32(requestor, property, x11.atoms.atom, data[0..]) catch |err| {
                    self.appendOutput(.stderr, "x11 clipboard TARGETS failed: {s}\n", .{@errorName(err)});
                };
                response_property = property;
            } else if (target == x11.atoms.utf8_string or target == x11.atoms.string or target == x11.atoms.text) {
                x11.changeProperty8(requestor, property, target, selection_data.?) catch |err| {
                    self.appendOutput(.stderr, "x11 clipboard transfer failed: {s}\n", .{@errorName(err)});
                };
                response_property = property;
            }
        }

        x11.sendSelectionNotify(requestor, selection, target, response_property, time) catch |err| {
            self.appendOutput(.stderr, "x11 selection notify failed: {s}\n", .{@errorName(err)});
        };
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
            self.switchActiveDocument(1);
            return;
        }
        if (std.mem.eql(u8, id, "file.previous_editor")) {
            self.switchActiveDocument(-1);
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
        if (std.mem.eql(u8, id, "editor.toggle_comment")) {
            self.toggleActiveDocumentComment();
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
        if (std.mem.eql(u8, id, "problems.open")) {
            self.openQuickPanel(.problems);
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
        if (std.mem.eql(u8, id, "symbol.workspace_symbols")) {
            self.openQuickPanel(.workspace_symbols);
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
        if (std.mem.eql(u8, id, "lsp.actions")) {
            self.openQuickPanel(.lsp_actions);
            return;
        }
        if (std.mem.eql(u8, id, "lsp.request_code_action")) {
            if (self.requestCodeActionsFromLsp()) return;
        }
        if (std.mem.eql(u8, id, "lsp.request_hover")) {
            if (self.requestHoverFromLsp()) return;
        }
        if (std.mem.eql(u8, id, "editor.format_document") or std.mem.eql(u8, id, "lsp.request_formatting")) {
            if (self.requestFormattingFromLsp()) return;
        }
        if (std.mem.eql(u8, id, "preferences.open_settings")) {
            self.bottom_panel = .settings;
            self.saveWorkbenchSettings();
            self.message("settings", .{});
            return;
        }
        if (std.mem.eql(u8, id, "preferences.open_keybindings")) {
            self.bottom_panel = .keybindings;
            self.saveWorkbenchSettings();
            self.message("keyboard shortcuts", .{});
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
                if (isEditorLineCommand(id)) {
                    self.clearSelection();
                    self.app.focus = .editor;
                    self.ensureEditorCursorVisible();
                    self.syncActiveDocumentToLsp();
                }
            },
            .blocked => |message_text| {
                self.message("{s}: blocked", .{id});
                self.appendOutput(.stderr, "blocked {s}: {s}\n", .{ id, message_text });
                if (self.app.pending_build_consent) |preview| {
                    self.appendOutput(.stdout, "pending consent: {s}\n", .{preview.command});
                    self.appendOutput(.stdout, "pending intent: network={} mutating={} shell={} destructive={} package={} reason={s}\n", .{
                        preview.intent.network,
                        preview.intent.mutating,
                        preview.intent.shell,
                        preview.intent.destructive,
                        preview.intent.package_manager,
                        preview.intent.reason,
                    });
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
                _ = self.applyLinuxLaunchProfileToLatestQueued("external command queued");
                self.appendOutput(.stdout, "queued external command: {s}\n", .{preview.command});
                self.appendOutput(.stdout, "queued intent: network={} mutating={} shell={} destructive={} package={} reason={s}\n", .{
                    preview.intent.network,
                    preview.intent.mutating,
                    preview.intent.shell,
                    preview.intent.destructive,
                    preview.intent.package_manager,
                    preview.intent.reason,
                });

                if (!self.prepareLinuxLaunchBoundary()) return;
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
        if (std.mem.startsWith(u8, id, "github.") and !std.mem.eql(u8, id, "github.overview")) self.bottom_panel = .output;
        if (std.mem.startsWith(u8, id, "task.")) {
            self.refreshLinuxSelfProtection();
            self.bottom_panel = .tasks;
        }
        if (std.mem.eql(u8, id, "view.extensions") or std.mem.eql(u8, id, "extensions.scan")) self.bottom_panel = .extensions;
        if (std.mem.eql(u8, id, "view.publish") or std.mem.eql(u8, id, "release.checklist")) self.bottom_panel = .publish;
        if (std.mem.eql(u8, id, "preferences.open_settings")) self.bottom_panel = .settings;
        if (std.mem.eql(u8, id, "preferences.open_keybindings")) self.bottom_panel = .keybindings;
        if (std.mem.eql(u8, id, "security.audit_workspace") or std.mem.eql(u8, id, "security.scan_current")) {
            self.refreshLinuxSelfProtection();
            self.bottom_panel = .security;
        }
    }

    fn hasCachedLspWorkspaceEdit(self: *const LinuxGuiState) bool {
        const session = self.app.activeLspSessionConst() orelse return false;
        const edit = session.last_workspace_edit orelse return false;
        return edit.edits.len > 0;
    }

    fn applyCachedLspWorkspaceEdit(self: *LinuxGuiState) void {
        const result = dispatcher.dispatch(&self.app, .{ .id = "lsp.apply_workspace_edit", .source = .command_palette }) catch |err| {
            self.message("workspace edit apply failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "workspace edit apply failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult("lsp.apply_workspace_edit", result);
        if (std.meta.activeTag(result) == .completed) {
            self.clearSelection();
            self.syncActiveDocumentToLsp();
            self.app.focus = .editor;
            self.ensureEditorCursorVisible();
        }
    }

    fn runHeaderAction(self: *LinuxGuiState, action: HeaderAction) void {
        switch (action) {
            .open_workspace => self.openQuickPanel(.open_workspace),
            .save => self.execute("file.save", .keybinding),
            .save_all => self.execute("file.save_all", .keybinding),
            .build => self.execute("zig.build", .keybinding),
            .test_run => self.execute("zig.test", .keybinding),
            .task => self.openTasksPanel(),
            .git => self.openGitPanel(),
            .audit => self.execute("security.audit_workspace", .keybinding),
            .scan => self.execute("security.scan_current", .keybinding),
            .extensions => self.execute("extensions.scan", .keybinding),
            .tutorial => {
                self.bottom_panel = .tutorial;
                self.saveWorkbenchSettings();
                self.message("help: tutorial opened", .{});
            },
            .publish => self.execute("release.checklist", .keybinding),
        }
    }

    fn openGitPanel(self: *LinuxGuiState) void {
        self.bottom_panel = .git;
        self.saveWorkbenchSettings();
        self.refreshGitOverview();
    }

    fn openTasksPanel(self: *LinuxGuiState) void {
        self.bottom_panel = .tasks;
        self.saveWorkbenchSettings();
        self.refreshLinuxSelfProtection();
        self.openQuickPanel(.run_task);
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
            .live, .issues, .failures, .draft_pr => {
                self.execute(gitPanelActionCommand(action), .command_palette);
                self.bottom_panel = .output;
            },
        }
    }

    fn executeTaskPanelAction(self: *LinuxGuiState, action: TaskPanelAction) void {
        self.bottom_panel = .tasks;
        switch (action) {
            .profile_read_only => self.setLinuxLaunchProfile(.read_only),
            .profile_safe => self.setLinuxLaunchProfile(.safe),
            .profile_network => self.setLinuxLaunchProfile(.network),
            .profile_publish => self.setLinuxLaunchProfile(.publish),
            .terminal => self.focusTerminalInput(),
            .queue_terminal => self.queueTerminalInput(),
            .run_pty => self.startPtyFromQueue(),
            .stop_pty => self.stopPtySession(),
            .tasks => self.openQuickPanel(.run_task),
            .preview => self.execute("task.preview_next", .command_palette),
            .seal => self.sealLinuxExecBoundary(),
            .run_next => {
                if (!self.prepareLinuxLaunchBoundary()) return;
                self.execute("task.run_next", .command_palette);
                self.refreshLinuxSelfProtection();
            },
            .history => self.execute("task.history", .command_palette),
        }
    }

    fn selectTaskHistoryEntry(self: *LinuxGuiState, index: usize) void {
        if (index >= self.app.execution_queue.history.items.len) return;
        self.task_history_selected = index;
        const entry = self.app.execution_queue.history.items[index];
        self.appendOutput(.stdout, "run history #{d}: {s} {s} audit:{s} lines:{d} clean:{d} env:{s} fs:{s} net:{s} cwd:{s}\n", .{
            index + 1,
            @tagName(entry.state),
            exitCodeLabel(entry.exit_code),
            entry.audit_id[0..12],
            entry.output_lines,
            entry.sanitized_controls,
            @tagName(entry.env_policy),
            @tagName(entry.fs_policy),
            @tagName(entry.network_policy),
            entry.cwd,
        });
        self.appendOutput(.stdout, "command: {s}\n", .{entry.display_command});
        self.terminalSetInput(entry.display_command);
        self.focusTerminalInput();
        self.message("history #{d} loaded: {s} {s}", .{ index + 1, @tagName(entry.state), exitCodeLabel(entry.exit_code) });
    }

    fn executeSettingsPanelAction(self: *LinuxGuiState, action: SettingsPanelAction) void {
        self.bottom_panel = .settings;
        switch (action) {
            .profile_read_only => self.setLinuxLaunchProfile(.read_only),
            .profile_safe => self.setLinuxLaunchProfile(.safe),
            .profile_network => self.setLinuxLaunchProfile(.network),
            .profile_publish => self.setLinuxLaunchProfile(.publish),
            .tutorial_ja => self.executeTutorialPanelAction(.ja),
            .tutorial_en => self.executeTutorialPanelAction(.en),
            .review => self.execute("security.mark_reviewed", .command_palette),
            .trust => self.execute("security.trust_workspace", .command_palette),
            .lock => self.execute("security.lock_workspace", .command_palette),
            .seal => self.sealLinuxExecBoundary(),
        }
        if (action == .tutorial_ja or action == .tutorial_en) self.bottom_panel = .settings;
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
            .seal => {
                self.sealLinuxExecBoundary();
                self.message("linux fd inheritance boundary sealed", .{});
            },
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
        self.saveWorkbenchSettings();
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
        if (mode == .completion) self.requestCompletionFromLsp();
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
        if (self.quick_panel.visible and self.quick_panel.mode == .completion) self.requestCompletionFromLsp();
    }

    fn quickPanelDeleteBackward(self: *LinuxGuiState) void {
        self.quick_panel.deleteBackward(&self.app) catch |err| {
            self.message("panel failed: {s}", .{@errorName(err)});
            return;
        };
        self.rememberDocumentSearchFromQuickPanel();
        if (self.quick_panel.visible and self.quick_panel.mode == .completion) self.requestCompletionFromLsp();
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
                if (self.requestRenameFromLsp(new_name)) return;
                self.renameWorkspaceSymbol(old_name, new_name);
            },
            .goto_line => self.gotoLineFromQuickPanel(),
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
            .workspace_symbols => {
                const item = self.quick_panel.selectedWorkspaceSymbol() orelse return self.message("no workspace symbol selected", .{});
                const path = self.allocator.dupe(u8, item.path) catch |err| return self.message("open failed: {s}", .{@errorName(err)});
                defer self.allocator.free(path);
                const line = item.line;
                const column = item.column;
                self.quick_panel.close();
                self.openRelativeLocation(path, line, column);
            },
            .lsp_actions => {
                const action = lspActionAt(self.quick_panel.query.items, self.quick_panel.selected_index) orelse return self.message("no LSP action selected", .{});
                self.quick_panel.close();
                self.execute(action.id, .command_palette);
            },
            .lsp_locations => {
                const session = self.app.activeLspSessionConst() orelse return self.message("no LSP session", .{});
                const locations = session.last_locations orelse return self.message("no LSP locations", .{});
                if (locations.items.len == 0) return self.message("no LSP locations", .{});
                const selected = @min(self.quick_panel.selected_index, locations.items.len - 1);
                const location = locations.items[selected];
                const path = self.allocator.dupe(u8, location.path) catch |err| return self.message("open failed: {s}", .{@errorName(err)});
                defer self.allocator.free(path);
                const line = location.range.start.line;
                const column = location.range.start.column;
                self.quick_panel.close();
                self.openRelativeLocation(path, line, column);
                self.message("opened LSP location", .{});
            },
            .problems => {
                const item = self.quick_panel.selectedProblem() orelse return self.message("no problem selected", .{});
                if (item.path.len == 0) return self.message("{s}: {s}", .{ item.level, item.message });
                const path = self.allocator.dupe(u8, item.path) catch |err| return self.message("open failed: {s}", .{@errorName(err)});
                defer self.allocator.free(path);
                const line = item.line;
                const column = item.column;
                const kind = item.kind;
                self.quick_panel.close();
                self.openRelativeLocation(path, line, column);
                self.bottom_panel = if (kind == .security) .security else .diagnostics;
            },
            .completion => {
                const item = self.quick_panel.selectedCompletion() orelse return self.message("no completion selected", .{});
                const insert_text = self.allocator.dupe(u8, item.insert_text) catch |err| return self.message("completion failed: {s}", .{@errorName(err)});
                defer self.allocator.free(insert_text);
                const start = self.quick_panel.completion_replace_start;
                const end = self.quick_panel.completion_replace_end;
                self.quick_panel.close();
                self.replaceActiveDocumentRange(start, end, insert_text);
                self.app.mode = .insert;
                self.app.focus = .editor;
                self.message("completed: {s}", .{insert_text});
            },
            .lsp_hover => {
                self.quick_panel.close();
                self.app.focus = .editor;
                self.message("closed LSP hover", .{});
            },
            .code_actions => {
                const count = self.quick_panel.itemCount();
                if (count == 0) return self.message("no code action selected", .{});
                const selected = @min(self.quick_panel.selected_index, count - 1);
                var index_buf: [32]u8 = undefined;
                const argument = std.fmt.bufPrint(&index_buf, "{d}", .{selected + 1}) catch return;
                self.quick_panel.close();
                const result = dispatcher.dispatch(&self.app, .{ .id = "lsp.apply_code_action", .argument = argument, .source = .command_palette }) catch |err| {
                    self.message("code action failed: {s}", .{@errorName(err)});
                    self.appendOutput(.stderr, "code action failed: {s}\n", .{@errorName(err)});
                    return;
                };
                self.handleDispatchResult("lsp.apply_code_action", result);
                if (std.meta.activeTag(result) == .completed) {
                    self.clearSelection();
                    self.syncActiveDocumentToLsp();
                    self.app.focus = .editor;
                    self.ensureEditorCursorVisible();
                }
            },
            .language_mode => {
                const mode = self.quick_panel.selectedLanguageMode() orelse return self.message("no language selected", .{});
                self.quick_panel.close();
                self.setActiveDocumentLanguage(mode);
            },
        }
    }

    fn setActiveDocumentLanguage(self: *LinuxGuiState, mode: modes.LanguageMode) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        doc.language = mode;
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.refreshActiveSecurityFindings("language mode changed");
        self.syncActiveDocumentToLsp();
        self.message("language: {s}  family:{s}  security:{s}", .{
            modes.label(mode),
            @tagName(modes.family(mode)),
            modes.securityFocus(mode),
        });
    }

    fn runTaskByName(self: *LinuxGuiState, name: []const u8) void {
        const queued = dispatcher.dispatch(&self.app, .{ .id = "task.run", .argument = name, .source = .command_palette }) catch |err| {
            self.message("task failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "task queue failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.handleDispatchResult("task.run", queued);
        if (std.meta.activeTag(queued) != .completed) return;
        _ = self.applyLinuxLaunchProfileToLatestQueued("task queued");

        const preview = dispatcher.dispatch(&self.app, .{ .id = "task.preview_next", .source = .task }) catch |err| {
            self.message("task preview failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "task preview failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.refreshLinuxSelfProtection();
        self.bottom_panel = .tasks;
        self.handleDispatchResult("task.preview_next", preview);
        self.message("task queued; review RUN panel, then click RUN", .{});
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
            self.syncActiveDocumentToLsp();
        } else {
            self.message("line endings already normalized", .{});
        }
    }

    fn toggleActiveDocumentComment(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const range = self.selectedRange(doc);
        const start = if (range) |selected| selected.start else doc.cursor.position.byte_offset;
        const end = if (range) |selected| selected.end else doc.cursor.position.byte_offset;
        const result = (doc.toggleComment(start, end) catch |err| return self.message("comment toggle failed: {s}", .{@errorName(err)})) orelse {
            return self.message("no comment syntax for language", .{});
        };
        self.selection_anchor = null;
        self.ensureEditorCursorVisible();
        self.syncActiveDocumentToLsp();
        self.message("{s}", .{commentToggleMessage(result)});
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
        self.syncActiveDocumentToLsp();
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
        self.syncActiveDocumentToLsp();
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
        self.syncActiveDocumentToLsp();
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
        if (self.requestDefinitionFromLsp()) return;
        if (self.app.activeLspSessionConst()) |session| {
            if (session.last_locations) |locations| {
                if (locations.items.len > 0) {
                    const location = locations.items[0];
                    self.openRelativeLocation(location.path, location.range.start.line, location.range.start.column);
                    self.message("opened LSP definition", .{});
                    return;
                }
            }
        }

        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const name = identifierAtOffset(doc.text.bytes, doc.cursor.position.byte_offset) orelse return self.message("no identifier under cursor", .{});
        const path = doc.path orelse "(scratch)";
        var index = symbols_mod.collectDocument(self.allocator, doc.text.bytes, path, doc.language) catch |err| return self.message("symbol scan failed: {s}", .{@errorName(err)});
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
        if (self.requestReferencesFromLsp()) return;
        if (self.app.activeLspSessionConst()) |session| {
            if (session.last_locations) |locations| {
                if (locations.items.len > 0) {
                    self.showLspLocations("LSP locations");
                    return;
                }
            }
        }

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

    fn gotoLineFromQuickPanel(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return self.message("no active document", .{});
        const target = parseGotoLine(self.quick_panel.query.items) orelse return self.message("type line or line:column", .{});
        const last_line = if (doc.text.lineCount() == 0) 0 else doc.text.lineCount() - 1;
        const line = @min(target.line, last_line);
        const column = @min(target.column, doc.text.lineSlice(line).len);
        const offset = doc.text.lineColumnToOffset(line, column) catch |err| return self.message("goto failed: {s}", .{@errorName(err)});
        navigation.setCursor(doc, doc.positionFromOffset(offset) catch doc.cursor.position);
        self.clearSelection();
        self.quick_panel.close();
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.message("line {d}:{d}", .{ line + 1, column + 1 });
    }

    fn closeActiveDocument(self: *LinuxGuiState) void {
        const index = self.app.documents.activeIndex() orelse return self.message("no active document", .{});
        self.closeDocumentAt(index);
    }

    fn closeDocumentAt(self: *LinuxGuiState, index: usize) void {
        if (index >= self.app.documents.documents.items.len) return self.message("no document at tab", .{});
        if (self.app.documents.documents.items[index].dirty) return self.message("save before closing dirty editor", .{});
        self.app.documents.closeAt(index, .deny_dirty) catch |err| return self.message("close failed: {s}", .{@errorName(err)});
        self.clearSelection();
        self.editor_dragging = false;
        self.app.focus = if (self.app.documents.active() != null) .editor else .files;
        self.ensureEditorCursorVisible();
        self.message("closed editor", .{});
    }

    fn switchActiveDocument(self: *LinuxGuiState, delta: isize) void {
        if (self.app.documents.documents.items.len == 0) return self.message("no open editors", .{});
        self.app.documents.moveActive(delta);
        self.clearSelection();
        self.editor_dragging = false;
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.syncActiveDocumentToLsp();
        if (self.app.documents.active()) |doc| {
            const label = if (doc.path) |path| std.fs.path.basename(path) else "(scratch)";
            self.message("editor: {s}", .{label});
        } else {
            self.message("no open editors", .{});
        }
    }

    fn openWorkspace(self: *LinuxGuiState, root_path: []const u8) void {
        var next = app_mod.App.initWithProcess(self.allocator, root_path, std.Options.debug_io, self.app.environ) catch |err| {
            self.message("workspace open failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "workspace open failed: {s}\n", .{@errorName(err)});
            return;
        };
        const next_collapsed = self.allocator.alloc(bool, next.workspace.entries.items.len) catch |err| {
            next.deinit();
            self.message("workspace state failed: {s}", .{@errorName(err)});
            self.appendOutput(.stderr, "workspace state failed: {s}\n", .{@errorName(err)});
            return;
        };
        @memset(next_collapsed, false);
        self.closePtySession();
        self.app.deinit();
        self.allocator.free(self.collapsed_dirs);
        self.app = next;
        self.collapsed_dirs = next_collapsed;
        self.quick_panel.close();
        self.clearSelection();
        self.editor_dragging = false;
        self.pending_lsp_action = .none;
        self.file_scroll_line = 0;
        self.editor_scroll_line = 0;
        self.output_scroll_line = 0;
        self.task_scroll_line = 0;
        self.task_history_selected = null;
        self.git_scroll_line = 0;
        self.extensions_scroll_line = 0;
        self.diagnostics_scroll_line = 0;
        self.security_scroll_line = 0;
        self.settings_scroll_line = 0;
        self.keybindings_scroll_line = 0;
        self.tutorial_scroll_line = 0;
        self.publish_scroll_line = 0;
        self.bottom_panel = .output;
        self.message("workspace opened", .{});
        self.appendOutput(.stdout, "opened workspace: {s}\n", .{self.app.workspace.root_path});
        self.refreshGitOverview();
        self.execute("security.audit_workspace", .startup);
        self.loadWorkbenchSettings();
    }

    fn handleKey(self: *LinuxGuiState, x11: *X11, key: event_mod.KeyEvent) void {
        if (self.handleContextMenuKey(x11, key)) return;
        if (self.handleQuickPanelKey(key)) return;
        if (self.handleTerminalKey(x11, key)) return;
        if (key.modifiers.ctrl and std.meta.activeTag(key.code) == .tab) {
            self.execute(if (key.modifiers.shift) "file.previous_editor" else "file.next_editor", .keybinding);
            return;
        }
        if (key.modifiers.ctrl and std.meta.activeTag(key.code) == .enter and self.hasCachedLspWorkspaceEdit()) {
            self.applyCachedLspWorkspaceEdit();
            return;
        }
        if (key.modifiers.ctrl and self.app.focus == .editor) {
            switch (key.code) {
                .char => |char| {
                    if (char == ' ') {
                        self.execute("editor.complete", .keybinding);
                        return;
                    }
                    if (char == '.') {
                        self.execute("lsp.request_code_action", .keybinding);
                        return;
                    }
                },
                else => {},
            }
        }
        if (key.modifiers.alt and self.app.focus == .editor) {
            switch (key.code) {
                .arrow_up => {
                    self.execute("editor.move_line_up", .keybinding);
                    return;
                },
                .arrow_down => {
                    self.execute("editor.move_line_down", .keybinding);
                    return;
                },
                else => {},
            }
        }

        if (self.app.mode == .insert and self.app.focus == .editor) {
            if (key.modifiers.ctrl) {
                switch (key.code) {
                    .char => |char| {
                        if (char == 'a' or char == 'A') {
                            self.selectAll(x11);
                            return;
                        }
                        if (char == 'c' or char == 'C') {
                            _ = self.copySelectionToClipboard(x11);
                            return;
                        }
                        if (char == 'x' or char == 'X') {
                            self.cutSelectionToClipboard(x11);
                            return;
                        }
                        if (char == 'v' or char == 'V') {
                            self.pasteFromClipboard(x11);
                            return;
                        }
                        if (char == 'g' or char == 'G') {
                            self.execute("editor.goto_line", .keybinding);
                            return;
                        }
                        if (char == 'w' or char == 'W') {
                            self.execute("file.close", .keybinding);
                            return;
                        }
                        if (key.modifiers.shift and (char == 'p' or char == 'P')) {
                            self.execute("view.command_palette", .keybinding);
                            return;
                        }
                        if (key.modifiers.shift and (char == 'o' or char == 'O')) {
                            self.openQuickPanel(.document_symbols);
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
                        if (char == '/') {
                            self.execute("editor.toggle_comment", .keybinding);
                            return;
                        }
                        if (char == '.') {
                            self.execute("lsp.request_code_action", .keybinding);
                            return;
                        }
                        if (char == 'p' or char == 'P') {
                            self.openQuickPanel(.find_file);
                            return;
                        }
                        if (char == 'o' or char == 'O') {
                            self.openQuickPanel(.open_workspace);
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
                        if (char == '`') {
                            self.focusTerminalInput();
                            return;
                        }
                        if (char == 's' or char == 'S') {
                            self.runHeaderAction(if (key.modifiers.shift) .save_all else .save);
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
                        if (char == 'b' or char == 'B') {
                            self.runHeaderAction(.build);
                            return;
                        }
                        if (key.modifiers.alt and (char == 't' or char == 'T')) {
                            self.runHeaderAction(.test_run);
                            return;
                        }
                        if (char == 't' or char == 'T') {
                            self.openQuickPanel(.workspace_symbols);
                            return;
                        }
                        if (key.modifiers.shift and (char == 'x' or char == 'X')) {
                            self.runHeaderAction(.extensions);
                            return;
                        }
                        if (key.modifiers.alt and (char == 'l' or char == 'L')) {
                            self.execute("lsp.actions", .keybinding);
                            return;
                        }
                        if (key.modifiers.shift and (char == 'l' or char == 'L')) {
                            self.runHeaderAction(.publish);
                            return;
                        }
                        if (key.modifiers.shift and (char == 'm' or char == 'M')) {
                            self.openQuickPanel(.problems);
                            return;
                        }
                        if (key.modifiers.shift and (char == 'd' or char == 'D')) {
                            self.execute("editor.duplicate_line", .keybinding);
                            return;
                        }
                        if (key.modifiers.shift and (char == 'k' or char == 'K')) {
                            self.execute("editor.delete_line", .keybinding);
                            return;
                        }
                        if (char == ',') {
                            self.execute("preferences.open_settings", .keybinding);
                            return;
                        }
                        if (!key.modifiers.shift and (char == 'k' or char == 'K')) {
                            self.execute("preferences.open_keybindings", .keybinding);
                            return;
                        }
                        return;
                    },
                    else => {},
                }
            }
            switch (key.code) {
                .escape => {
                    self.execute("editor.exit_insert", .keybinding);
                    return;
                },
                .backspace => {
                    self.deleteBackward();
                    return;
                },
                .delete => {
                    self.deleteForward();
                    return;
                },
                .enter => {
                    self.insertNewline();
                    return;
                },
                .tab => {
                    self.insertText("    ");
                    return;
                },
                .arrow_left => {
                    self.moveEditorCursor(x11, .left, key.modifiers.shift);
                    return;
                },
                .arrow_right => {
                    self.moveEditorCursor(x11, .right, key.modifiers.shift);
                    return;
                },
                .arrow_up => {
                    self.moveEditorCursor(x11, .up, key.modifiers.shift);
                    return;
                },
                .arrow_down => {
                    self.moveEditorCursor(x11, .down, key.modifiers.shift);
                    return;
                },
                .char => |char| {
                    var bytes: [4]u8 = undefined;
                    const len = encodeUtf8(char, &bytes) catch return;
                    self.insertText(bytes[0..len]);
                    return;
                },
                else => {},
            }
        }

        if (key.modifiers.ctrl and self.app.focus == .editor) {
            switch (key.code) {
                .char => |char| {
                    if (char == 'a' or char == 'A') {
                        self.selectAll(x11);
                        return;
                    }
                    if (char == 'c' or char == 'C') {
                        _ = self.copySelectionToClipboard(x11);
                        return;
                    }
                    if (char == 'x' or char == 'X') {
                        self.cutSelectionToClipboard(x11);
                        return;
                    }
                    if (char == 'v' or char == 'V') {
                        self.pasteFromClipboard(x11);
                        return;
                    }
                    if (char == 'g' or char == 'G') {
                        self.execute("editor.goto_line", .keybinding);
                        return;
                    }
                    if (char == 'w' or char == 'W') {
                        self.execute("file.close", .keybinding);
                        return;
                    }
                    if (char == ',') {
                        self.execute("preferences.open_settings", .keybinding);
                        return;
                    }
                    if (char == '/') {
                        self.execute("editor.toggle_comment", .keybinding);
                        return;
                    }
                    if (char == '.') {
                        self.execute("lsp.request_code_action", .keybinding);
                        return;
                    }
                    if (key.modifiers.shift and (char == 'd' or char == 'D')) {
                        self.execute("editor.duplicate_line", .keybinding);
                        return;
                    }
                    if (key.modifiers.shift and (char == 'k' or char == 'K')) {
                        self.execute("editor.delete_line", .keybinding);
                        return;
                    }
                    if (key.modifiers.shift and (char == 'm' or char == 'M')) {
                        self.openQuickPanel(.problems);
                        return;
                    }
                    if (!key.modifiers.shift and (char == 'k' or char == 'K')) {
                        self.execute("preferences.open_keybindings", .keybinding);
                        return;
                    }
                },
                else => {},
            }
        }

        if (self.app.focus == .editor) {
            switch (key.code) {
                .arrow_left => {
                    self.moveEditorCursor(x11, .left, key.modifiers.shift);
                    return;
                },
                .arrow_right => {
                    self.moveEditorCursor(x11, .right, key.modifiers.shift);
                    return;
                },
                .arrow_up => {
                    self.moveEditorCursor(x11, .up, key.modifiers.shift);
                    return;
                },
                .arrow_down => {
                    self.moveEditorCursor(x11, .down, key.modifiers.shift);
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

        if (self.fileTreeHasControl()) {
            switch (key.code) {
                .arrow_up => {
                    self.moveFileSelection(-1);
                    return;
                },
                .arrow_down => {
                    self.moveFileSelection(1);
                    return;
                },
                .arrow_left => {
                    self.collapseSelectedDirectory();
                    return;
                },
                .arrow_right => {
                    self.expandSelectedDirectory();
                    return;
                },
                .enter => {
                    self.openSelectedFileTreeEntry();
                    return;
                },
                .char => |char| {
                    if (char == 'j' or char == 'J') {
                        self.moveFileSelection(1);
                        return;
                    }
                    if (char == 'k' or char == 'K') {
                        self.moveFileSelection(-1);
                        return;
                    }
                    if (char == 'o' or char == 'O') {
                        self.openSelectedFileTreeEntry();
                        return;
                    }
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
                    if (char == '`') {
                        self.focusTerminalInput();
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
                    if (char == ',') {
                        self.execute("preferences.open_settings", .keybinding);
                        return;
                    }
                    if (key.modifiers.shift and (char == 'd' or char == 'D')) {
                        self.execute("editor.duplicate_line", .keybinding);
                        return;
                    }
                    if (key.modifiers.shift and (char == 'k' or char == 'K')) {
                        self.execute("editor.delete_line", .keybinding);
                        return;
                    }
                    if (!key.modifiers.shift and (char == 'k' or char == 'K')) {
                        self.execute("preferences.open_keybindings", .keybinding);
                        return;
                    }
                    if (char == 'b' or char == 'B') {
                        self.runHeaderAction(.build);
                        return;
                    }
                    if (key.modifiers.alt and (char == 't' or char == 'T')) {
                        self.runHeaderAction(.test_run);
                        return;
                    }
                    if (char == 't' or char == 'T') {
                        self.openQuickPanel(.workspace_symbols);
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
                        if (key.modifiers.shift) {
                            self.runHeaderAction(.git);
                        } else {
                            self.execute("editor.goto_line", .keybinding);
                        }
                        return;
                    }
                    if (char == 'w' or char == 'W') {
                        self.execute("file.close", .keybinding);
                        return;
                    }
                    if (!key.modifiers.shift and (char == 'd' or char == 'D')) {
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
        if (self.deleteSelectedRange(doc)) {
            self.message("deleted selection", .{});
            return;
        }
        const current = doc.cursor.position.byte_offset;
        if (current == 0) return;
        const previous = doc.text.previousByteOffset(current) catch current - 1;
        doc.deleteRange(previous, current) catch |err| {
            self.message("delete failed: {s}", .{@errorName(err)});
            return;
        };
        self.syncActiveDocumentToLsp();
        self.message("deleted backward", .{});
    }

    fn deleteForward(self: *LinuxGuiState) void {
        const doc = self.app.documents.active() orelse return;
        if (self.deleteSelectedRange(doc)) {
            self.message("deleted selection", .{});
            return;
        }
        const current = doc.cursor.position.byte_offset;
        if (current >= doc.text.bytes.len) return;
        const next = doc.text.nextByteOffset(current) catch current + 1;
        doc.deleteRange(current, next) catch |err| {
            self.message("delete failed: {s}", .{@errorName(err)});
            return;
        };
        self.syncActiveDocumentToLsp();
        self.message("deleted forward", .{});
    }

    fn handlePointer(self: *LinuxGuiState, x11: *X11, button: u8, x: i16, y: i16, time: u32, state_mask: u16) void {
        if (self.context_menu_visible and (button == 4 or button == 5)) {
            self.moveContextSelection(if (button == 4) -1 else 1);
            return;
        }
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
        if (button == 2) {
            if (documentTabAt(self, x, y)) |index| {
                self.closeDocumentAt(index);
                return;
            }
        }
        if (button == 2 and self.bottom_panel == .tasks and pointIn(terminalInputRect(self), x, y)) {
            self.focusTerminalInput();
            self.pastePrimaryIntoTerminal(x11);
            return;
        }
        if (button == 2 and x >= FILE_WIDTH and y >= HEADER_HEIGHT and y < self.bottomTop()) {
            self.app.focus = .editor;
            self.pasteFromPrimary(x11);
            return;
        }
        if (button == 3) {
            self.prepareContextMenuPoint(x, y);
            self.openContextMenu(x, y);
            return;
        }
        if (button != 1) return;
        self.handleClick(x11, x, y, time, state_mask);
    }

    fn handlePointerMotion(self: *LinuxGuiState, x: i16, y: i16) void {
        if (self.context_menu_visible) {
            if (contextActionAt(self, x, y)) |action| self.context_menu_selected = contextActionIndex(action);
            return;
        }
        if (!self.editor_dragging) return;
        const doc = self.app.documents.active() orelse return;
        const position = self.editorPositionFromPoint(x, y) orelse return;
        navigation.setCursor(doc, position);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
    }

    fn handlePointerRelease(self: *LinuxGuiState, x11: *X11, button: u8) void {
        if (button != 1) return;
        if (!self.editor_dragging) return;
        self.editor_dragging = false;
        if (self.app.documents.active()) |doc| {
            if (self.selectedRange(doc) == null) {
                self.clearSelection();
            } else {
                self.publishPrimarySelection(x11);
            }
        }
    }

    fn prepareContextMenuPoint(self: *LinuxGuiState, x: i16, y: i16) void {
        if (x < FILE_WIDTH or y < HEADER_HEIGHT or y >= self.bottomTop()) return;
        const doc = self.app.documents.active() orelse return;
        const position = self.editorPositionFromPoint(x, y) orelse return;
        const clicked_offset = position.byte_offset;
        if (self.selectedRange(doc)) |range| {
            if (clicked_offset >= range.start and clicked_offset <= range.end) {
                self.app.focus = .editor;
                return;
            }
        }
        self.clearSelection();
        navigation.setCursor(doc, position);
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
    }

    fn handleClick(self: *LinuxGuiState, x11: *X11, x: i16, y: i16, time: u32, state_mask: u16) void {
        if (self.handleContextMenuClick(x11, x, y)) return;

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
            self.terminal_focused = false;
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
            self.terminal_focused = false;
            const row = @divTrunc(@as(isize, y - 98), LINE_HEIGHT);
            if (row >= 0) {
                if (self.entryIndexAtVisibleRank(self.file_scroll_line + @as(usize, @intCast(row)))) |index| {
                    self.app.file_cursor = index;
                    self.app.focus = .files;
                    self.openSelectedFileTreeEntry();
                }
            }
            return;
        }

        if (y >= HEADER_HEIGHT and y < bottom and x >= FILE_WIDTH) {
            self.terminal_focused = false;
            self.app.focus = .editor;
            if (self.handleBoundaryGutterClick(x, y)) return;
            const extend_selection = (state_mask & X11_SHIFT_MASK) != 0;
            if (!extend_selection and self.consumeEditorDoubleClick(time, x, y)) {
                if (!self.selectIdentifierAtPoint(x11, x, y)) self.beginEditorSelection(x11, x, y, false);
            } else {
                self.beginEditorSelection(x11, x, y, extend_selection);
            }
            if (self.app.documents.active() != null) self.app.mode = .insert;
            return;
        }

        if (y >= bottom and y < bottom + 34) {
            if (bottomPanelAt(self, x, y)) |panel| {
                if (self.bottom_panel != panel) {
                    self.bottom_panel = panel;
                    if (panel != .tasks) self.terminal_focused = false;
                    self.saveWorkbenchSettings();
                }
            }
            return;
        }

        if (y >= bottom + 40 and y < self.window_height - STATUS_HEIGHT) {
            if (self.handleBottomPanelContentClick(x, y)) return;
        }
    }

    fn handleBoundaryGutterClick(self: *LinuxGuiState, x: i16, y: i16) bool {
        if (x < EDITOR_LEFT + 34 or x >= EDITOR_LEFT + 56) return false;
        const doc = self.app.documents.active() orelse return false;
        const path = doc.path orelse return false;
        if (y < EDITOR_TEXT_TOP - 14) return false;
        const line_delta = @divTrunc(@as(isize, y - (EDITOR_TEXT_TOP - 14)), LINE_HEIGHT);
        if (line_delta < 0) return false;
        const line = self.editor_scroll_line + @as(usize, @intCast(line_delta));
        if (line >= doc.text.lineCount()) return false;
        const marker = lineBoundaryMarker(self, path, line) orelse return false;
        navigation.setCursor(doc, doc.positionFromOffset(doc.text.lineStart(line) orelse 0) catch doc.cursor.position);
        self.clearSelection();
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.bottom_panel = .security;
        self.appendOutput(.stdout, "line boundary: {s}:{d} {s}/{s} findings={d}\n", .{
            path,
            line + 1,
            @tagName(marker.risk),
            findings_mod.boundaryLabel(marker.boundary),
            marker.count,
        });
        var emitted: usize = 0;
        for (self.app.security_findings.items.items) |item| {
            if (item.line != line or !pathMatchesX11(path, item.path)) continue;
            self.appendOutput(.stdout, "- col:{d} [{s}/{s}] {s}\n", .{
                item.column + 1,
                @tagName(item.risk),
                @tagName(item.category),
                item.message,
            });
            emitted += 1;
            if (emitted >= 8) break;
        }
        self.message("line boundary: {s}/{s}", .{ @tagName(marker.risk), findings_mod.boundaryLabel(marker.boundary) });
        return true;
    }

    fn handleBottomPanelContentClick(self: *LinuxGuiState, x: i16, y: i16) bool {
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
                self.openRelativeLocation(finding.path, finding.line, finding.column);
                return true;
            },
            .diagnostics => {
                if (diagnosticRowAt(self, y)) |index| {
                    if (index < self.app.diagnostics.items.items.len) {
                        const item = self.app.diagnostics.items.items[index];
                        self.openRelativeLocation(item.path, item.range.start.line, item.range.start.column);
                    }
                }
                return true;
            },
            .tasks => {
                if (taskPanelActionAt(self, x, y)) |action| {
                    self.executeTaskPanelAction(action);
                    return true;
                }
                if (pointIn(terminalInputRect(self), x, y)) {
                    self.focusTerminalInput();
                    return true;
                }
                if (taskHistoryRowAt(self, y)) |index| {
                    self.selectTaskHistoryEntry(index);
                    return true;
                }
                return true;
            },
            .output => {
                if (self.hasCachedLspWorkspaceEdit() and pointIn(outputApplyButtonRect(self), x, y)) {
                    self.applyCachedLspWorkspaceEdit();
                    return true;
                }
                if (outputLineRowAt(self, y)) |index| {
                    if (index < self.app.process_console.lines.items.len) {
                        const line = self.app.process_console.lines.items[index];
                        if (zig_output.parseLine(line.text)) |parsed| {
                            self.openRelativeLocation(parsed.path, parsed.line, parsed.column);
                        } else {
                            self.message("output line has no source location", .{});
                        }
                    }
                }
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
            .settings => {
                if (settingsPanelActionAt(self, x, y)) |action| {
                    self.executeSettingsPanelAction(action);
                    return true;
                }
                return true;
            },
            .keybindings => {
                if (keybindingRowAt(self, y)) |index| {
                    const definitions = command_mod.all();
                    if (index < definitions.len) self.execute(definitions[index].id, .command_palette);
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
        self.clearSelection();
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.syncActiveDocumentToLsp();
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

    fn consumeEditorDoubleClick(self: *LinuxGuiState, time: u32, x: i16, y: i16) bool {
        const elapsed = time -% self.last_editor_click_time;
        const close_x = absI16(x - self.last_editor_click_x) <= 5;
        const close_y = absI16(y - self.last_editor_click_y) <= 5;
        const is_double = self.last_editor_click_time != 0 and elapsed <= 500 and close_x and close_y;
        self.last_editor_click_time = time;
        self.last_editor_click_x = x;
        self.last_editor_click_y = y;
        return is_double;
    }

    fn selectIdentifierAtPoint(self: *LinuxGuiState, x11: *X11, x: i16, y: i16) bool {
        const doc = self.app.documents.active() orelse return false;
        const position = self.editorPositionFromPoint(x, y) orelse return false;
        const source = doc.text.bytes;
        if (source.len == 0) return false;
        var at = @min(position.byte_offset, source.len - 1);
        if (!isIdentifierByte(source[at])) {
            if (position.byte_offset > 0 and isIdentifierByte(source[position.byte_offset - 1])) {
                at = position.byte_offset - 1;
            } else {
                navigation.setCursor(doc, position);
                self.clearSelection();
                self.ensureEditorCursorVisible();
                self.message("cursor: {d}:{d}", .{ position.line + 1, position.column + 1 });
                return false;
            }
        }

        var start = at;
        while (start > 0 and isIdentifierByte(source[start - 1])) : (start -= 1) {}
        var end = at + 1;
        while (end < source.len and isIdentifierByte(source[end])) : (end += 1) {}
        if (start == end) return false;

        self.selection_anchor = start;
        navigation.setCursor(doc, doc.positionFromOffset(end) catch position);
        self.editor_dragging = false;
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.publishPrimarySelection(x11);
        self.message("selected identifier", .{});
        return true;
    }

    fn beginEditorSelection(self: *LinuxGuiState, x11: *X11, x: i16, y: i16, extend_selection: bool) void {
        const doc = self.app.documents.active() orelse return;
        const previous = doc.cursor.position.byte_offset;
        const position = self.editorPositionFromPoint(x, y) orelse return;
        if (extend_selection) {
            if (self.selection_anchor == null) self.selection_anchor = previous;
        } else {
            self.selection_anchor = position.byte_offset;
        }
        navigation.setCursor(doc, position);
        if (extend_selection) {
            if (self.selectedRange(doc) == null) {
                self.clearSelection();
            } else {
                self.publishPrimarySelection(x11);
            }
        }
        self.editor_dragging = true;
        self.app.focus = .editor;
        self.app.mode = .insert;
        self.ensureEditorCursorVisible();
        self.message("cursor: {d}:{d}", .{ position.line + 1, position.column + 1 });
    }

    fn editorPositionFromPoint(self: *LinuxGuiState, x: i16, y: i16) ?types.Position {
        const doc = self.app.documents.active() orelse return null;
        if (doc.text.lineCount() == 0) return types.Position.start();
        if (y < EDITOR_TEXT_TOP - 14) return null;

        const line_delta = @divTrunc(@as(isize, y - (EDITOR_TEXT_TOP - 14)), LINE_HEIGHT);
        if (line_delta < 0) return null;
        const line = @min(self.editor_scroll_line + @as(usize, @intCast(line_delta)), doc.text.lineCount() - 1);
        const column_raw = if (x <= EDITOR_LEFT + 56) 0 else @divTrunc(@as(isize, x - (EDITOR_LEFT + 56)), 8);
        const column = @min(@as(usize, @intCast(@max(column_raw, 0))), doc.text.lineSlice(line).len);
        const offset = doc.text.lineColumnToOffset(line, column) catch return null;
        return doc.positionFromOffset(offset) catch null;
    }

    fn bottomRowsFrom(self: *const LinuxGuiState, top: i16) usize {
        return @intCast(@max(@divTrunc(self.window_height - top - STATUS_HEIGHT - 8, LINE_HEIGHT), 1));
    }

    fn scrollBottomPanel(self: *LinuxGuiState, delta: isize) void {
        switch (self.bottom_panel) {
            .output => {
                const visible = outputVisibleRows(self);
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
                const visible = self.bottomRowsFrom(diagnosticsTop(self));
                const max_start = if (total > visible) total - visible else 0;
                self.diagnostics_scroll_line = scrollValue(self.diagnostics_scroll_line, max_start, delta);
            },
            .tasks => {
                const total = self.app.execution_queue.history.items.len;
                const visible = self.bottomRowsFrom(taskHistoryTop(self));
                const max_start = if (total > visible) total - visible else 0;
                self.task_scroll_line = scrollValue(self.task_scroll_line, max_start, delta);
            },
            .security => {
                const total = self.app.security_findings.items.items.len;
                const visible = self.bottomRowsFrom(securityFindingsTop(self));
                const max_start = if (total > visible) total - visible else 0;
                self.security_scroll_line = scrollValue(self.security_scroll_line, max_start, delta);
            },
            .settings => {
                const total = settingsLines().len;
                const visible = self.bottomRowsFrom(self.bottomTop() + 118);
                const max_start = if (total > visible) total - visible else 0;
                self.settings_scroll_line = scrollValue(self.settings_scroll_line, max_start, delta);
            },
            .keybindings => {
                const total = command_mod.all().len;
                const visible = self.bottomRowsFrom(keybindingsTop(self));
                const max_start = if (total > visible) total - visible else 0;
                self.keybindings_scroll_line = scrollValue(self.keybindings_scroll_line, max_start, delta);
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

fn createWorkbenchSettingsFile(path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
    }
    return std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{ .truncate = true });
}

pub fn run(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    environ: std.process.Environ,
    environ_map: *const std.process.Environ.Map,
) !void {
    var state = try LinuxGuiState.init(allocator, root_path, environ);
    defer state.deinit();
    defer state.saveWorkbenchSettings();

    state.enableLinuxSelfProtection();
    state.refreshGitOverview();
    state.execute("security.audit_workspace", .startup);
    state.loadWorkbenchSettings();

    var x11 = try X11.connect(allocator, environ_map);
    defer x11.close();

    try draw(&x11, &state);
    main_loop: while (true) {
        var fds: [2]std.posix.pollfd = undefined;
        fds[0] = .{ .fd = x11.fd, .events = std.posix.POLL.IN, .revents = 0 };
        var fd_count: usize = 1;
        var pty_poll_index: ?usize = null;
        if (state.activePtyFd()) |pty_fd| {
            pty_poll_index = fd_count;
            fds[fd_count] = .{ .fd = pty_fd, .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR, .revents = 0 };
            fd_count += 1;
        }

        const timeout_ms: i32 = if (pty_poll_index != null or state.app.hasAnyRunningLsp()) 100 else -1;
        _ = try std.posix.poll(fds[0..fd_count], timeout_ms);

        var needs_draw = state.pumpPtySession();
        needs_draw = state.pumpLsp() or needs_draw;
        const pty_ready_mask: i16 = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        if (pty_poll_index) |index| {
            if ((fds[index].revents & pty_ready_mask) != 0) {
                needs_draw = state.pumpPtySession() or needs_draw;
            }
        }

        if ((fds[0].revents & std.posix.POLL.IN) != 0) {
            var event: [32]u8 = undefined;
            try readExact(x11.fd, event[0..]);
            const event_type = event[0] & 0x7f;
            switch (event_type) {
                2 => {
                    if (keyEventFromX(event[0..])) |key| {
                        if (std.meta.activeTag(key.code) == .escape and state.app.mode == .normal and !state.app.palette.visible) break :main_loop;
                        state.handleKey(&x11, key);
                        needs_draw = true;
                    }
                },
                4 => {
                    state.handlePointer(&x11, event[1], @bitCast(readLe16(event[24..26])), @bitCast(readLe16(event[26..28])), readLe32(event[4..8]), readLe16(event[28..30]));
                    needs_draw = true;
                },
                5 => {
                    state.handlePointerRelease(&x11, event[1]);
                    needs_draw = true;
                },
                6 => {
                    state.handlePointerMotion(@bitCast(readLe16(event[24..26])), @bitCast(readLe16(event[26..28])));
                    needs_draw = true;
                },
                12 => needs_draw = true,
                22 => {
                    state.resize(readLe16(event[20..22]), readLe16(event[22..24]));
                    needs_draw = true;
                },
                29 => {
                    state.handleSelectionClear(readLe32(event[12..16]), &x11);
                },
                30 => {
                    state.handleSelectionRequest(&x11, event[0..]);
                },
                33 => {
                    const message_type = readLe32(event[8..12]);
                    const data0 = readLe32(event[12..16]);
                    if (message_type == x11.atoms.wm_protocols and data0 == x11.atoms.wm_delete_window) break :main_loop;
                },
                else => {},
            }
        }

        if (needs_draw) try draw(&x11, &state);
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
    const visible_total = state.visibleEntryCount();
    const max_files = @min(visible_total - @min(state.file_scroll_line, visible_total), state.visibleFileRows());
    var visible_index: usize = 0;
    while (visible_index < max_files) : (visible_index += 1) {
        const index = state.entryIndexAtVisibleRank(state.file_scroll_line + visible_index) orelse break;
        const entry = app.workspace.entries.items[index];
        const marker = riskMarkerForEntry(state, entry.path, entry.kind == .directory);
        const git_marker = gitMarkerForEntry(state, entry.path, entry.kind == .directory);
        const gc = if (index == app.file_cursor)
            x11.gc.cyan
        else if (marker) |risk_marker|
            riskGc(x11, risk_marker.risk)
        else if (git_marker) |git_marker_value|
            gitChangeGc(x11, git_marker_value.status)
        else if (entry.kind == .directory)
            x11.gc.green
        else
            x11.gc.text;
        if (index == app.file_cursor) try x11.fillRect(x11.gc.panel_2, 8, y - 14, FILE_WIDTH - 16, LINE_HEIGHT);
        var line_buf: [280]u8 = undefined;
        const prefix: []const u8 = if (entry.kind == .directory)
            if (state.directoryHasChildren(index) and !state.collapsed_dirs[index]) "- " else "+ "
        else
            "  ";
        const indent = @min(entry.depth * 2, @as(usize, 12));
        const lang = if (entry.kind == .file) modes.label(entry.language) else "";
        const risk_label = if (marker) |risk_marker| risk_marker.label else "";
        const risk_sep = if (marker != null) " " else "";
        const git_label = if (git_marker) |git_marker_value| git_marker_value.label else "";
        const git_sep = if (git_marker != null) " " else "";
        @memset(line_buf[0..indent], ' ');
        const suffix = std.fmt.bufPrint(line_buf[indent..], "{s}{s}  {s}{s}{s}{s}{s}", .{ prefix, entry.path, lang, risk_sep, risk_label, git_sep, git_label }) catch clipped: {
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
    if (state.context_menu_visible) try drawContextMenu(x11, state);

    try x11.fillRect(x11.gc.cyan, 0, state.window_height - STATUS_HEIGHT, width_u, STATUS_HEIGHT);
    var status_buf: [880]u8 = undefined;
    var hot_buf: [80]u8 = undefined;
    var lsp_buf: [80]u8 = undefined;
    const active = app.documents.active();
    const dirty_count = app.documents.dirtyCount();
    const language = if (active) |doc| modes.label(doc.language) else "none";
    const cursor = if (active) |doc| doc.cursor.position else null;
    const current_risk = currentDocumentRiskCounts(state);
    const hot_boundary = currentLineBoundaryHint(state, hot_buf[0..]);
    const lsp_status = activeLspStatusText(app, lsp_buf[0..]);
    const git_changes = if (state.git_overview) |overview| overview.changes.len else 0;
    const linux_grade = linuxBoundaryGrade(&state.linux_security);
    const status = std.fmt.bufPrint(
        status_buf[0..],
        "{s}/{s} | line:{d} col:{d} dirty:{d} lang:{s} lsp:{s} trust:{s} risk:{d}/{d}/{d} at:{s} git:{d} linux:{s} files:{d} code:{d} langs:{d} zig:{d} docs:{d} | Ctrl+P Ctrl+T Ctrl+S Ctrl+G Ctrl+Alt+L | {s}",
        .{
            @tagName(app.mode),
            @tagName(app.focus),
            if (cursor) |pos| pos.line + 1 else 0,
            if (cursor) |pos| pos.column + 1 else 0,
            dirty_count,
            language,
            lsp_status,
            @tagName(app.runtime.trust_state),
            current_risk.critical,
            current_risk.high,
            current_risk.medium,
            hot_boundary,
            git_changes,
            linux_grade.label,
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
    const total = state.visibleEntryCount();
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
    const run_label = if (modes.runProfile(doc.language)) |profile| profile.label else "manual";
    const comment_label = modes.lineComment(doc.language) orelse if (modes.blockComment(doc.language)) |block| block.start else "-";
    var path_buf: [900]u8 = undefined;
    const header = std.fmt.bufPrint(path_buf[0..], "{s}  lang={s}/{s}  run={s}  cmt={s}  sec={s}  newline={s}  encoding={s}", .{
        path,
        modes.label(doc.language),
        @tagName(modes.family(doc.language)),
        run_label,
        comment_label,
        modes.securityFocus(doc.language),
        doc.newlineLabel(),
        doc.encodingLabel(),
    }) catch path;
    var header_ascii: [900]u8 = undefined;
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
        if (lineBoundaryMarker(state, path, line_index)) |marker| {
            const marker_gc = riskGc(x11, marker.risk);
            try x11.fillRect(marker_gc, EDITOR_LEFT + 52, line_y - 14, 3, LINE_HEIGHT);
            var marker_buf: [8]u8 = undefined;
            const marker_text = std.fmt.bufPrint(marker_buf[0..], "{s}{s}", .{ riskInitial(marker.risk), boundaryInitial(marker.boundary) }) catch "!!";
            try x11.text(marker_gc, EDITOR_LEFT + 36, line_y, marker_text);
        }

        try drawHighlightedEditorLine(x11, state, doc.language, EDITOR_LEFT + 56, line_y, line, if (selected) x11.gc.text else x11.gc.muted);

        if (selected and app.mode == .insert and app.focus == .editor) {
            const cursor_x: i16 = EDITOR_LEFT + 56 + @as(i16, @intCast(@min(doc.cursor.position.column, 120))) * 8;
            try x11.fillRect(x11.gc.cyan, cursor_x, line_y - 14, 2, LINE_HEIGHT);
        }
        line_y += LINE_HEIGHT;
    }
}

fn drawHighlightedEditorLine(x11: *X11, state: *LinuxGuiState, mode: modes.LanguageMode, x: i16, y: i16, line: []const u8, fallback_gc: u32) !void {
    if (!modes.isHighlightable(mode)) {
        var line_buf: [720]u8 = undefined;
        try x11.text(fallback_gc, x, y, asciiInto(line_buf[0..], line));
        return;
    }

    const spans = highlight.collectLine(state.allocator, line, mode) catch {
        var line_buf: [720]u8 = undefined;
        try x11.text(fallback_gc, x, y, asciiInto(line_buf[0..], line));
        return;
    };
    defer state.allocator.free(spans);

    if (spans.len == 0) {
        var line_buf: [720]u8 = undefined;
        try x11.text(fallback_gc, x, y, asciiInto(line_buf[0..], line));
        return;
    }

    for (spans) |span| {
        if (span.end <= span.start or span.start >= line.len) continue;
        const end = @min(span.end, line.len);
        const segment = line[span.start..end];
        const segment_x = x + @as(i16, @intCast(@min(span.start, @as(usize, 140)))) * 8;
        var segment_buf: [360]u8 = undefined;
        try x11.text(highlightGc(x11, span.role, fallback_gc), segment_x, y, asciiInto(segment_buf[0..], segment));
    }
}

fn highlightGc(x11: *X11, role: highlight.Role, fallback_gc: u32) u32 {
    return switch (role) {
        .plain => fallback_gc,
        .keyword => x11.gc.cyan,
        .type_name => x11.gc.amber,
        .string => x11.gc.green,
        .number => x11.gc.amber,
        .comment, .doc_comment => x11.gc.muted,
        .builtin => x11.gc.cyan,
        .operator, .punctuation => x11.gc.text,
        .unsafe_boundary => x11.gc.red,
    };
}

fn drawBottomPanel(x11: *X11, state: *LinuxGuiState) !void {
    const bottom = state.bottomTop();
    try x11.fillRect(x11.gc.line, 0, bottom, toU16(state.window_width), 1);
    try drawPanelTab(x11, bottom, state.bottom_panel == .output, 18, "OUTPUT");
    try drawPanelTab(x11, bottom, state.bottom_panel == .tasks, 122, "RUN");
    try drawPanelTab(x11, bottom, state.bottom_panel == .git, 226, "GIT");
    try drawPanelTab(x11, bottom, state.bottom_panel == .extensions, 330, "EXT");
    try drawPanelTab(x11, bottom, state.bottom_panel == .diagnostics, 434, "DIAG");
    try drawPanelTab(x11, bottom, state.bottom_panel == .security, 538, "SEC");
    try drawPanelTab(x11, bottom, state.bottom_panel == .settings, 642, "SET");
    try drawPanelTab(x11, bottom, state.bottom_panel == .keybindings, 746, "KEYS");
    try drawPanelTab(x11, bottom, state.bottom_panel == .tutorial, 850, "HELP");
    try drawPanelTab(x11, bottom, state.bottom_panel == .publish, 954, "SHIP");

    switch (state.bottom_panel) {
        .output => try drawOutputPanel(x11, state),
        .tasks => try drawTaskPanel(x11, state),
        .git => try drawGitPanel(x11, state),
        .extensions => try drawExtensionsPanel(x11, state),
        .diagnostics => try drawDiagnosticsPanel(x11, state),
        .security => try drawSecurityPanel(x11, state),
        .settings => try drawSettingsPanel(x11, state),
        .keybindings => try drawKeybindingsPanel(x11, state),
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

fn drawActionButtonState(x11: *X11, rect: HitRect, label: []const u8, active: bool, color: u32) !void {
    try x11.fillRect(if (active) color else x11.gc.panel_2, rect.left, rect.top, @intCast(rect.right - rect.left), @intCast(rect.bottom - rect.top));
    try x11.text(if (active) x11.gc.bg else color, rect.left + 7, rect.top + 16, label);
}

fn drawContextMenu(x11: *X11, state: *const LinuxGuiState) !void {
    const rect = contextMenuRect(state);
    try x11.fillRect(x11.gc.panel_2, rect.left, rect.top, @intCast(rect.right - rect.left), @intCast(rect.bottom - rect.top));
    try x11.fillRect(x11.gc.cyan, rect.left, rect.top, @intCast(rect.right - rect.left), 2);
    try x11.fillRect(x11.gc.line, rect.left, rect.bottom - 2, @intCast(rect.right - rect.left), 2);
    try x11.fillRect(x11.gc.line, rect.left, rect.top, 2, @intCast(rect.bottom - rect.top));
    try x11.fillRect(x11.gc.line, rect.right - 2, rect.top, 2, @intCast(rect.bottom - rect.top));
    try x11.text(x11.gc.green, rect.left + 12, rect.top + 23, "ZIDE ACTIONS");

    inline for (context_actions, 0..) |action, index| {
        const item = contextActionRect(state, action);
        const selected = state.context_menu_selected == index;
        const enabled = contextActionEnabled(state, action);
        if (selected) try x11.fillRect(x11.gc.cyan, item.left + 4, item.top + 2, @intCast(item.right - item.left - 8), @intCast(item.bottom - item.top - 4));
        const gc = if (selected) x11.gc.bg else if (enabled) x11.gc.text else x11.gc.muted;
        try x11.text(gc, item.left + 14, item.top + 19, contextActionLabel(action));
        if (contextActionHint(action).len > 0) {
            try x11.text(if (selected) x11.gc.bg else x11.gc.cyan, item.right - 74, item.top + 19, contextActionHint(action));
        }
    }
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
    var header_buf: [360]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "OUTPUT lines:{d} status:{s} sanitizer:csi={d} osc={d} ctrl={d}  click source lines to jump", .{
        app.process_console.lines.items.len,
        if (app.process_console.running) "running" else exitCodeLabel(app.process_console.exit_code),
        app.process_console.sanitized_stats.stripped_csi,
        app.process_console.sanitized_stats.stripped_osc,
        app.process_console.sanitized_stats.stripped_control,
    }) catch "OUTPUT";
    try x11.text(x11.gc.green, 18, bottom + 58, header);
    if (state.hasCachedLspWorkspaceEdit()) {
        try drawActionButton(x11, outputApplyButtonRect(state), "APPLY");
        try x11.text(x11.gc.muted, outputApplyButtonRect(state).left - 104, bottom + 58, "Ctrl+Enter");
    }

    var y: i16 = outputLinesTop(state);
    const max_lines = outputVisibleRows(state);
    const start = outputVisibleStart(state);
    const limit = @min(app.process_console.lines.items.len, start + max_lines);
    try drawScrollHint(x11, state, app.process_console.lines.items.len, max_lines, start, y);
    for (app.process_console.lines.items[start..limit]) |line| {
        var text_buf: [900]u8 = undefined;
        const color = outputLineGc(x11, line);
        try x11.text(color, 18, y, asciiInto(text_buf[0..], line.text));
        y += LINE_HEIGHT;
    }
    if (app.process_console.lines.items.len == 0) {
        try x11.text(x11.gc.muted, 18, y, "No output yet.");
    }
}

fn drawTaskPanel(x11: *X11, state: *LinuxGuiState) !void {
    const bottom = state.bottomTop();
    const queue = &state.app.execution_queue;
    try drawTaskPanelActions(x11, state);

    var header_buf: [300]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "RUN / Linux policy profile:{s} queued:{d} history:{d} console:{s} pty:{s}", .{
        linuxLaunchProfileLabel(state.linux_launch_profile),
        queue.queuedCount(),
        queue.history.items.len,
        if (state.app.process_console.running) "running" else "idle",
        state.ptyStatusLabel(),
    }) catch "RUN / Linux policy profile";
    try x11.text(x11.gc.green, 18, bottom + 58, header);

    var profile_buf: [560]u8 = undefined;
    const profile_line = std.fmt.bufPrint(profile_buf[0..], "PROFILE {s}: {s}", .{
        linuxLaunchProfileLabel(state.linux_launch_profile),
        linuxLaunchProfileDescription(state.linux_launch_profile),
    }) catch "PROFILE";
    try x11.text(linuxLaunchProfileGc(x11, state.linux_launch_profile), 18, bottom + 82, profile_line);

    var linux_buf: [420]u8 = undefined;
    const linux_line = std.fmt.bufPrint(linux_buf[0..], "INHERITED nnp:{s} dump:{s} ambient_clear:{s} seccomp:{s} cap_eff:{s} fd:{d} no-cloexec:{d} sealed:{d}/{d} wx:{d}", .{
        flagLabel(state.linux_security.no_new_privs),
        flagLabel(state.linux_security.dumpable),
        flagLabel(state.linux_security.ambient_clear),
        seccompLabel(state.linux_security.seccomp_mode),
        state.linuxSecurityCapEffLabel(),
        state.linux_security.fd_total,
        state.linux_security.fd_cloexec_missing,
        state.linux_security.fd_cloexec_sealed,
        state.linux_security.fd_cloexec_seal_failed,
        state.linux_security.maps_writable_executable,
    }) catch "INHERITED";
    const linux_gc = if (state.linux_security.no_new_privs == .on and state.linux_security.maps_writable_executable == 0) x11.gc.cyan else x11.gc.amber;
    try x11.text(linux_gc, 18, bottom + 106, linux_line);

    try drawTerminalInput(x11, state);

    if (queue.latest()) |ticket| {
        var command_ascii: [900]u8 = undefined;
        var command_buf: [900]u8 = undefined;
        const fingerprint = launchAuditFingerprint(ticket, state.app.workspace.root_path);
        const command_line = std.fmt.bufPrint(command_buf[0..], "QUEUED {s} state:{s} argv:{d} audit:{s}  {s}", .{
            ticket.source_command_id,
            @tagName(ticket.state),
            ticket.args.items.len + 1,
            fingerprint[0..12],
            ticket.display_command,
        }) catch ticket.display_command;
        try x11.text(x11.gc.text, 18, bottom + 160, asciiInto(command_ascii[0..], command_line));

        var policy_buf: [520]u8 = undefined;
        const policy_line = std.fmt.bufPrint(policy_buf[0..], "policy env:{s} fs:{s} net:{s} sanitized:{s} timeout:{s} output:{d}", .{
            @tagName(ticket.env_policy),
            @tagName(ticket.fs_policy),
            @tagName(ticket.network_policy),
            boolLabel(ticket.output_sanitized),
            timeoutLabel(ticket.timeout_ms),
            ticket.output_limit_bytes,
        }) catch "policy";
        try x11.text(x11.gc.muted, 18, bottom + 184, policy_line);

        var gate_buf: [720]u8 = undefined;
        const cwd_ok = permissions.allowsWorkspacePath(ticket.fs_policy, state.app.workspace.root_path, ticket.cwd);
        const intent = command_intent.classify(ticket.executable, ticket.args.items);
        const network_ok = !intent.network or permissions.allowsNetwork(ticket.network_policy);
        const write_ok = ticket.fs_policy != .read_only_workspace or !intent.mutating;
        const readonly_note = if (ticket.fs_policy == .read_only_workspace) " requested-read-only" else "";
        const gate_line = std.fmt.bufPrint(gate_buf[0..], "gate cwd:{s} net:{s} write:{s}{s} intent:{s} cwd:{s}", .{
            if (cwd_ok) "ok" else "blocked",
            if (network_ok) "ok" else "blocked",
            if (write_ok) "ok" else "blocked",
            readonly_note,
            intent.reason,
            ticket.cwd,
        }) catch "gate";
        var gate_ascii: [720]u8 = undefined;
        try x11.text(if (cwd_ok and network_ok and write_ok) x11.gc.muted else x11.gc.red, 18, bottom + 208, asciiInto(gate_ascii[0..], gate_line));
    } else {
        try x11.text(x11.gc.muted, 18, bottom + 160, "No queued task. Type in TERM, pick TASKS, or Ctrl+R. Review PLAN/SEAL before PTY or RUN.");
        if (queue.latestHistory()) |entry| {
            var last_buf: [720]u8 = undefined;
            const last_line = std.fmt.bufPrint(last_buf[0..], "LAST {s} {s} lines:{d} sanitized:{d}  {s}", .{
                @tagName(entry.state),
                exitCodeLabel(entry.exit_code),
                entry.output_lines,
                entry.sanitized_controls,
                entry.display_command,
            }) catch entry.display_command;
            var last_ascii: [720]u8 = undefined;
            try x11.text(x11.gc.cyan, 18, bottom + 184, asciiInto(last_ascii[0..], last_line));
        }
    }

    const history_top = taskHistoryTop(state);
    try x11.text(x11.gc.amber, 18, history_top - 12, "HISTORY");
    const visible = state.bottomRowsFrom(history_top);
    const start = @min(state.task_scroll_line, queue.history.items.len);
    const limit = @min(queue.history.items.len, start + visible);
    try drawScrollHint(x11, state, queue.history.items.len, visible, start, history_top);
    var y: i16 = history_top;
    for (queue.history.items[start..limit], start..) |entry, index| {
        var row_buf: [900]u8 = undefined;
        const row = std.fmt.bufPrint(row_buf[0..], "{d}. {s} {s} audit:{s} lines:{d} clean:{d} intent:n{} w{} sh{} d{} pkg{} env:{s} fs:{s} net:{s}  {s}", .{
            index + 1,
            @tagName(entry.state),
            exitCodeLabel(entry.exit_code),
            entry.audit_id[0..12],
            entry.output_lines,
            entry.sanitized_controls,
            entry.intent.network,
            entry.intent.mutating,
            entry.intent.shell,
            entry.intent.destructive,
            entry.intent.package_manager,
            @tagName(entry.env_policy),
            @tagName(entry.fs_policy),
            @tagName(entry.network_policy),
            entry.display_command,
        }) catch entry.display_command;
        var ascii_buf: [900]u8 = undefined;
        const selected = if (state.task_history_selected) |selected_index| selected_index == index else false;
        if (selected) try x11.fillRect(x11.gc.panel_2, 10, y - 14, toU16(state.window_width - 20), LINE_HEIGHT);
        try x11.text(if (selected) x11.gc.text else taskStateGc(x11, entry.state), 18, y, asciiInto(ascii_buf[0..], row));
        y += LINE_HEIGHT;
    }
    if (queue.history.items.len == 0) {
        try x11.text(x11.gc.muted, 18, y, "No task history yet. PTY opens a bounded shell when queue is empty; RUN records captured tasks.");
    }
}

fn drawTerminalInput(x11: *X11, state: *LinuxGuiState) !void {
    const rect = terminalInputRect(state);
    try x11.fillRect(if (state.terminal_focused) x11.gc.panel_2 else x11.gc.bg, rect.left, rect.top, @intCast(rect.right - rect.left), @intCast(rect.bottom - rect.top));
    try x11.fillRect(if (state.terminal_focused) x11.gc.cyan else x11.gc.line, rect.left, rect.top, @intCast(rect.right - rect.left), 1);
    try x11.fillRect(x11.gc.line, rect.left, rect.bottom - 1, @intCast(rect.right - rect.left), 1);

    var prompt_buf: [900]u8 = undefined;
    const cursor = if (state.terminal_focused) "_" else "";
    const prompt = std.fmt.bufPrint(prompt_buf[0..], "TERM > {s}{s}", .{ state.terminal_input.items, cursor }) catch "TERM >";
    var prompt_ascii: [900]u8 = undefined;
    try x11.text(if (state.terminal_focused) x11.gc.green else x11.gc.cyan, rect.left + 10, rect.top + 19, asciiInto(prompt_ascii[0..], prompt));

    const hint = if (state.pty_session != null)
        "Enter sends / Ctrl+V paste / Ctrl+C interrupt / STOP ends"
    else
        "Enter queues / PTY shell if empty / Ctrl+V paste / Up history";
    const hint_x = @max(rect.left + 360, rect.right - 430);
    if (hint_x > rect.left + 220) try x11.text(x11.gc.muted, hint_x, rect.top + 19, hint);
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
    const boundary_grade = linuxBoundaryGrade(&state.linux_security);
    var cap_buf: [320]u8 = undefined;
    const cap_line = std.fmt.bufPrint(cap_buf[0..], "LINUX BOUNDARY grade:{s} score:{d}/{d} / direct X11 no-toolkit / dangerous caps dropped:{d} failed:{d} / proc:{s}", .{
        boundary_grade.label,
        boundary_grade.score,
        boundary_grade.max,
        state.linux_security.bounding_caps_dropped,
        state.linux_security.bounding_caps_drop_failed,
        if (state.linux_security.proc_status_read) "read" else "blocked",
    }) catch "linux cap boundary";
    try x11.text(linuxBoundaryGc(x11, boundary_grade), 18, bottom + 130, cap_line);
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
    var fd_buf: [360]u8 = undefined;
    const fd_line = std.fmt.bufPrint(fd_buf[0..], "PROC FD read:{s} total:{d} no-cloexec:{d} sealed:{d}/{d} unknown:{d} socket:{d} pipe:{d} memfd:{d} anon:{d} files:{d}", .{
        if (state.linux_security.proc_fd_read) "yes" else "no",
        state.linux_security.fd_total,
        state.linux_security.fd_cloexec_missing,
        state.linux_security.fd_cloexec_sealed,
        state.linux_security.fd_cloexec_seal_failed,
        state.linux_security.fd_cloexec_unknown,
        state.linux_security.fd_sockets,
        state.linux_security.fd_pipes,
        state.linux_security.fd_memfd,
        state.linux_security.fd_anon,
        state.linux_security.fd_files,
    }) catch "PROC FD";
    try x11.text(if (state.linux_security.fd_cloexec_missing > 3) x11.gc.amber else x11.gc.muted, 18, bottom + 178, fd_line);
    var euid_buf: [32]u8 = undefined;
    var tracer_buf: [32]u8 = undefined;
    var filters_buf: [32]u8 = undefined;
    var identity_buf: [360]u8 = undefined;
    const identity_line = std.fmt.bufPrint(identity_buf[0..], "LINUX ID euid:{s} root:{s} tracer:{s} core:{s} nspid:{d}/{s} seccomp_filters:{s}", .{
        optionalUsizeLabel(euid_buf[0..], state.linux_security.euid),
        flagLabel(state.linux_security.euid_root),
        optionalUsizeLabel(tracer_buf[0..], state.linux_security.tracer_pid),
        flagLabel(state.linux_security.core_dumping),
        state.linux_security.nspid_count,
        flagLabel(state.linux_security.pid_namespace),
        optionalUsizeLabel(filters_buf[0..], state.linux_security.seccomp_filters),
    }) catch "LINUX ID";
    const identity_gc = if (state.linux_security.euid_root == .on or
        (state.linux_security.tracer_pid orelse 0) != 0 or
        state.linux_security.core_dumping == .on)
        x11.gc.red
    else
        x11.gc.muted;
    try x11.text(identity_gc, 18, bottom + 202, identity_line);
    var y: i16 = securityFindingsTop(state);
    const visible = state.bottomRowsFrom(y);
    const start = @min(state.security_scroll_line, app.security_findings.items.items.len);
    const limit = @min(app.security_findings.items.items.len, start + visible);
    try drawScrollHint(x11, state, app.security_findings.items.items.len, visible, start, y);
    for (app.security_findings.items.items[start..limit]) |finding| {
        var row_buf: [900]u8 = undefined;
        const finding_boundary = findings_mod.boundaryFor(finding.category);
        const row = std.fmt.bufPrint(row_buf[0..], "{s}:{d}:{d} [{s}/{s}/{s}] {s}", .{
            finding.path,
            finding.line + 1,
            finding.column + 1,
            @tagName(finding.risk),
            findings_mod.boundaryLabel(finding_boundary),
            @tagName(finding.category),
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
    try x11.text(x11.gc.green, 18, bottom + 58, "GIT / hook-free repository view / GitHub live actions");

    const overview = state.git_overview orelse {
        try x11.text(x11.gc.muted, 18, bottom + 86, "Press REFRESH. ZIDE reads .git directly without running hooks, filters, fsmonitor, or git status.");
        return;
    };

    if (!overview.present) {
        try x11.text(x11.gc.muted, 18, bottom + 86, "No Git repository detected in this workspace.");
        return;
    }

    const workflow_risk = workflowRiskCounts(state, overview);
    var meta_buf: [720]u8 = undefined;
    const meta = std.fmt.bufPrint(meta_buf[0..], "branch:{s} commit:{s} index:v{d} entries:{d} tracked-clean:{d} changes:{d} ignored:{d} workflows:{d} wf-risk:{d}/{d}/{d}", .{
        overview.branch orelse "(detached)",
        if (overview.commit) |commit| commit[0..@min(commit.len, 12)] else "unknown",
        overview.index_version orelse 0,
        overview.index_entries,
        overview.clean_tracked,
        overview.changes.len,
        overview.ignored_untracked,
        overview.workflow_files,
        workflow_risk.critical,
        workflow_risk.high,
        workflow_risk.medium,
    }) catch "git overview";
    var meta_ascii: [720]u8 = undefined;
    try x11.text(x11.gc.muted, 18, bottom + 82, asciiInto(meta_ascii[0..], meta));

    const has_github_remote = overviewHasGitHubRemote(overview);
    const token_label = githubTokenPresenceLabel(state.app.environ);
    var lane_buf: [420]u8 = undefined;
    const lane = std.fmt.bufPrint(lane_buf[0..], "GITHUB lanes remote:{s} token:{s} read:LIVE/ISS/FAIL write:PR(draft)", .{
        if (has_github_remote) "yes" else "no",
        token_label,
    }) catch "GITHUB lanes";
    var lane_ascii: [420]u8 = undefined;
    const lane_gc = if (!has_github_remote) x11.gc.amber else if (std.mem.eql(u8, token_label, "none")) x11.gc.muted else x11.gc.cyan;
    try x11.text(lane_gc, 18, bottom + 106, asciiInto(lane_ascii[0..], lane));

    var y: i16 = bottom + 130;
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
        const counts = pathRiskCounts(state, change.path);
        const worst = highestRisk(counts);
        var row_buf: [720]u8 = undefined;
        const line = std.fmt.bufPrint(row_buf[0..], "{s}  {s}  +{d}/-{d}{s}  risk:{d}/{d}/{d}", .{
            gitChangeLabel(change.status),
            change.path,
            change.additions,
            change.deletions,
            if (change.diff_available) " diff" else "",
            counts.critical,
            counts.high,
            counts.medium,
        }) catch change.path;
        var row_ascii: [720]u8 = undefined;
        const row_gc = if (worst) |risk| riskGc(x11, risk) else gitChangeGc(x11, change.status);
        try x11.text(row_gc, 18, y, asciiInto(row_ascii[0..], line));
        y += LINE_HEIGHT;
    }
    if (overview.changes.len == 0) {
        try x11.text(x11.gc.muted, 18, y, "No tracked or untracked changes found by the safe .git reader.");
    }
}

fn drawSettingsPanel(x11: *X11, state: *LinuxGuiState) !void {
    const bottom = state.bottomTop();
    try drawSettingsPanelActions(x11, state);

    var header_buf: [420]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "SETTINGS / profile:{s} trust:{s} tutorial:{s} linux:{s}", .{
        linuxLaunchProfileLabel(state.linux_launch_profile),
        @tagName(state.app.runtime.trust_state),
        @tagName(state.tutorial_language),
        linuxBoundaryGrade(&state.linux_security).label,
    }) catch "SETTINGS";
    try x11.text(x11.gc.green, 18, bottom + 58, header);

    var safety_buf: [520]u8 = undefined;
    const safety = std.fmt.bufPrint(safety_buf[0..], "safe defaults: save gate:{s} hidden-control scan:on hook-free-git:on extension-exec:off no_new_privs:{s} dumpable:{s} cap_eff:{s}", .{
        @tagName(state.app.runtime.trust_state),
        flagLabel(state.linux_security.no_new_privs),
        flagLabel(state.linux_security.dumpable),
        state.linuxSecurityCapEffLabel(),
    }) catch "safe defaults";
    var safety_ascii: [520]u8 = undefined;
    try x11.text(x11.gc.cyan, 18, bottom + 82, asciiInto(safety_ascii[0..], safety));

    var panel_buf: [520]u8 = undefined;
    const panel = std.fmt.bufPrint(panel_buf[0..], "panels: Output/Run/Git/Ext/Diag/Sec/Set/Keys/Help/Ship  shortcuts: Ctrl+, settings  Ctrl+K keys  Ctrl+Shift+P command", .{}) catch "panels";
    var panel_ascii: [520]u8 = undefined;
    try x11.text(x11.gc.muted, 18, bottom + 106, asciiInto(panel_ascii[0..], panel));

    const lines = settingsLines();
    const top = bottom + 136;
    const visible = state.bottomRowsFrom(top);
    const start = @min(state.settings_scroll_line, lines.len);
    const limit = @min(lines.len, start + visible);
    try drawScrollHint(x11, state, lines.len, visible, start, top);
    var y: i16 = top;
    for (lines[start..limit]) |line| {
        try x11.text(settingsLineGc(x11, line), 18, y, line);
        y += LINE_HEIGHT;
    }
}

fn drawKeybindingsPanel(x11: *X11, state: *LinuxGuiState) !void {
    const bottom = state.bottomTop();
    const definitions = command_mod.all();
    var header_buf: [440]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "KEYBINDINGS / commands:{d} / click a row to run / Ctrl+Shift+P filters commands", .{definitions.len}) catch "KEYBINDINGS";
    try x11.text(x11.gc.green, 18, bottom + 58, header);
    try x11.text(x11.gc.muted, 18, bottom + 82, "key                 scope       capability        title / id");

    const top = keybindingsTop(state);
    const visible = state.bottomRowsFrom(top);
    const start = @min(state.keybindings_scroll_line, definitions.len);
    const limit = @min(definitions.len, start + visible);
    try drawScrollHint(x11, state, definitions.len, visible, start, top);
    var y: i16 = top;
    for (definitions[start..limit], start..) |definition, index| {
        var row_buf: [900]u8 = undefined;
        const key = if (definition.default_key.len == 0) "-" else definition.default_key;
        const row = std.fmt.bufPrint(row_buf[0..], "{d}. key:{s} scope:{s} cap:{s}  {s}  {s}", .{
            index + 1,
            key,
            @tagName(definition.scope),
            @tagName(definition.capability),
            definition.title,
            definition.id,
        }) catch definition.id;
        var ascii_buf: [900]u8 = undefined;
        try x11.text(commandCapabilityGc(x11, definition.capability), 18, y, asciiInto(ascii_buf[0..], row));
        y += LINE_HEIGHT;
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
    var header_buf: [260]u8 = undefined;
    const header = std.fmt.bufPrint(header_buf[0..], "DIAGNOSTICS total:{d} err:{d} warn:{d} info:{d}  click row to jump", .{
        app.diagnostics.items.items.len,
        app.diagnostics.countBySeverity(.err),
        app.diagnostics.countBySeverity(.warning),
        app.diagnostics.countBySeverity(.info),
    }) catch "DIAGNOSTICS";
    try x11.text(x11.gc.green, 18, bottom + 58, header);
    var y: i16 = diagnosticsTop(state);
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
        try x11.text(severityGc(x11, item.severity), 18, y, asciiInto(ascii_buf[0..], row));
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
        .goto_line => blk: {
            const target = parseGotoLine(state.quick_panel.query.items) orelse break :blk "Type line or line:column";
            break :blk std.fmt.bufPrint(text_buf[0..], "Jump to {d}:{d}", .{ target.line + 1, target.column + 1 }) catch "Jump";
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
        .workspace_symbols => blk: {
            const items = state.quick_panel.workspace_symbol_matches orelse break :blk "";
            if (row >= items.len) break :blk "";
            break :blk std.fmt.bufPrint(text_buf[0..], "{s}  {s}  {s}:{d}:{d}  {s}", .{
                items[row].name,
                @tagName(items[row].kind),
                items[row].path,
                items[row].line + 1,
                items[row].column + 1,
                modes.label(items[row].language),
            }) catch items[row].name;
        },
        .lsp_actions => blk: {
            const action = lspActionAt(state.quick_panel.query.items, row) orelse break :blk "";
            break :blk std.fmt.bufPrint(text_buf[0..], "{s}  {s}  {s}", .{ action.label, action.id, action.hint }) catch action.label;
        },
        .lsp_locations => blk: {
            const session = state.app.activeLspSessionConst() orelse break :blk "";
            const locations = session.last_locations orelse break :blk "";
            if (row >= locations.items.len) break :blk "";
            const item = locations.items[row];
            break :blk std.fmt.bufPrint(text_buf[0..], "{d}. {s}:{d}:{d}", .{
                row + 1,
                item.path,
                item.range.start.line + 1,
                item.range.start.column + 1,
            }) catch item.path;
        },
        .problems => blk: {
            const items = state.quick_panel.problem_matches orelse break :blk "";
            if (row >= items.len) break :blk "";
            break :blk std.fmt.bufPrint(text_buf[0..], "{s}/{s}  {s}:{d}:{d}  {s}", .{
                @tagName(items[row].kind),
                items[row].level,
                if (items[row].path.len == 0) "(workspace)" else items[row].path,
                items[row].line + 1,
                items[row].column + 1,
                items[row].message,
            }) catch items[row].message;
        },
        .completion => blk: {
            const items = state.quick_panel.completion_matches orelse break :blk "";
            if (row >= items.len) break :blk "";
            break :blk std.fmt.bufPrint(text_buf[0..], "{s}  {s}  {s}", .{
                items[row].label,
                @tagName(items[row].kind),
                items[row].detail,
            }) catch items[row].label;
        },
        .lsp_hover => blk: {
            const session = state.app.activeLspSessionConst() orelse break :blk "";
            const hover = session.last_hover orelse break :blk "";
            break :blk hoverLineAt(hover.text, row) orelse "";
        },
        .code_actions => blk: {
            const session = state.app.activeLspSessionConst() orelse break :blk "";
            const actions = session.last_code_actions orelse break :blk "";
            if (row >= actions.items.len) break :blk "";
            const item = actions.items[row];
            break :blk std.fmt.bufPrint(text_buf[0..], "{d}. [{s}] {s}{s}", .{
                row + 1,
                item.kind,
                item.title,
                if (item.workspace_edit != null) "  edit" else "  command",
            }) catch item.title;
        },
        .language_mode => blk: {
            const items = state.quick_panel.language_matches orelse break :blk "";
            if (row >= items.len) break :blk "";
            const mode = items[row];
            break :blk std.fmt.bufPrint(text_buf[0..], "{s}  family:{s}  security:{s}", .{
                modes.label(mode),
                @tagName(modes.family(mode)),
                modes.securityFocus(mode),
            }) catch modes.label(mode);
        },
    };
    var ascii_buf: [720]u8 = undefined;
    try x11.text(color, x, y, asciiInto(ascii_buf[0..], text));
}

const RiskCounts = struct {
    info: usize = 0,
    low: usize = 0,
    medium: usize = 0,
    high: usize = 0,
    critical: usize = 0,
};

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

const RiskMarker = struct {
    label: []const u8,
    risk: findings_mod.Risk,
};

const LineBoundaryMarker = struct {
    risk: findings_mod.Risk,
    boundary: findings_mod.Boundary,
    count: usize,
};

const GitMarker = struct {
    label: []const u8,
    status: git_repository.ChangeStatus,
};

const LinuxBoundaryGrade = struct {
    label: []const u8,
    score: u8,
    max: u8,
};

fn boundaryCounts(app: *const app_mod.App) BoundaryCounts {
    var counts: BoundaryCounts = .{};
    for (app.security_findings.items.items) |finding| {
        addBoundary(&counts, findings_mod.boundaryFor(finding.category));
    }
    return counts;
}

fn addBoundary(counts: *BoundaryCounts, boundary: findings_mod.Boundary) void {
    switch (boundary) {
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

fn riskCounts(collection: *const findings_mod.Collection) RiskCounts {
    var counts: RiskCounts = .{};
    for (collection.items.items) |item| addRisk(&counts, item.risk);
    return counts;
}

fn currentDocumentRiskCounts(state: *LinuxGuiState) RiskCounts {
    const doc = state.app.documents.active() orelse return .{};
    const path = doc.path orelse return .{};
    return pathRiskCounts(state, path);
}

fn currentLineBoundaryHint(state: *LinuxGuiState, buffer: []u8) []const u8 {
    const doc = state.app.documents.active() orelse return "clear";
    const path = doc.path orelse return "clear";
    const line = doc.cursor.position.line;

    var best_risk: ?findings_mod.Risk = null;
    var best_boundary: ?findings_mod.Boundary = null;
    for (state.app.security_findings.items.items) |item| {
        if (item.line != line) continue;
        if (!pathMatchesX11(path, item.path)) continue;
        if (best_risk == null or riskRank(item.risk) > riskRank(best_risk.?)) {
            best_risk = item.risk;
            best_boundary = findings_mod.boundaryFor(item.category);
        }
    }

    const risk = best_risk orelse return "clear";
    const boundary = best_boundary orelse return @tagName(risk);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ @tagName(risk), findings_mod.boundaryLabel(boundary) }) catch "hot";
}

fn lineBoundaryMarker(state: *const LinuxGuiState, path: []const u8, line: usize) ?LineBoundaryMarker {
    var marker: ?LineBoundaryMarker = null;
    for (state.app.security_findings.items.items) |item| {
        if (item.line != line) continue;
        if (!pathMatchesX11(path, item.path)) continue;
        const boundary = findings_mod.boundaryFor(item.category);
        if (marker) |*current| {
            current.count += 1;
            if (riskRank(item.risk) > riskRank(current.risk)) {
                current.risk = item.risk;
                current.boundary = boundary;
            }
        } else {
            marker = .{ .risk = item.risk, .boundary = boundary, .count = 1 };
        }
    }
    return marker;
}

fn workflowRiskCounts(state: *const LinuxGuiState, overview: git_repository.Overview) RiskCounts {
    var counts: RiskCounts = .{};
    for (overview.workflow_paths) |path| addRiskCounts(&counts, pathRiskCounts(state, path));
    return counts;
}

fn pathRiskCounts(state: *const LinuxGuiState, path: []const u8) RiskCounts {
    var counts: RiskCounts = .{};
    for (state.app.security_findings.items.items) |item| {
        if (!pathMatchesX11(path, item.path)) continue;
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

fn riskMarkerForEntry(state: *const LinuxGuiState, entry_path: []const u8, is_directory: bool) ?RiskMarker {
    var best: ?findings_mod.Risk = null;
    for (state.app.security_findings.items.items) |finding| {
        if (!findingPathBelongsToEntry(finding.path, entry_path, is_directory)) continue;
        if (best == null or riskRank(finding.risk) > riskRank(best.?)) best = finding.risk;
    }
    const risk = best orelse return null;
    return .{ .label = riskMarkerLabel(risk), .risk = risk };
}

fn gitMarkerForEntry(state: *const LinuxGuiState, entry_path: []const u8, is_directory: bool) ?GitMarker {
    const overview = state.git_overview orelse return null;
    if (!overview.present) return null;
    for (overview.changes) |change| {
        if (is_directory) {
            if (pathIsInsideDirectoryX11(change.path, entry_path)) {
                return .{ .label = "*", .status = change.status };
            }
        } else if (pathMatchesX11(entry_path, change.path)) {
            return .{ .label = gitChangeLabel(change.status), .status = change.status };
        }
    }
    return null;
}

fn findingPathBelongsToEntry(finding_path: []const u8, entry_path: []const u8, is_directory: bool) bool {
    if (pathEqualNormalizedX11(finding_path, entry_path)) return true;
    if (!is_directory) return false;
    return pathIsInsideDirectoryX11(finding_path, entry_path);
}

fn pathIsInsideDirectoryX11(path: []const u8, directory: []const u8) bool {
    if (directory.len == 0 or path.len <= directory.len) return false;
    if (!pathStartsWithNormalizedX11(path, directory)) return false;
    const separator = path[directory.len];
    return separator == '/' or separator == '\\';
}

fn pathMatchesX11(path: []const u8, candidate: []const u8) bool {
    if (candidate.len == 0) return false;
    if (pathEqualNormalizedX11(path, candidate)) return true;
    return pathEndsWithNormalizedX11(path, candidate);
}

fn pathEndsWithNormalizedX11(path: []const u8, suffix: []const u8) bool {
    if (suffix.len == 0 or suffix.len > path.len) return false;
    const start = path.len - suffix.len;
    if (!pathEqualNormalizedX11(path[start..], suffix)) return false;
    return start == 0 or path[start - 1] == '/' or path[start - 1] == '\\';
}

fn pathStartsWithNormalizedX11(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return pathEqualNormalizedX11(value[0..prefix.len], prefix);
}

fn pathEqualNormalizedX11(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (normalizePathByteX11(a) != normalizePathByteX11(b)) return false;
    }
    return true;
}

fn normalizePathByteX11(byte: u8) u8 {
    return if (byte == '\\') '/' else byte;
}

fn commentToggleMessage(result: document_mod.CommentToggleResult) []const u8 {
    return switch (result) {
        .line_commented => "commented lines",
        .line_uncommented => "uncommented lines",
        .block_commented => "commented block",
        .block_uncommented => "uncommented block",
    };
}

fn riskMarkerLabel(risk: findings_mod.Risk) []const u8 {
    return switch (risk) {
        .critical => "[C]",
        .high => "[H]",
        .medium => "[M]",
        .low => "[L]",
        .info => "[I]",
    };
}

fn gitChangeLabel(status: git_repository.ChangeStatus) []const u8 {
    return switch (status) {
        .modified => "M",
        .deleted => "D",
        .untracked => "??",
    };
}

fn gitChangeGc(x11: *X11, status: git_repository.ChangeStatus) u32 {
    return switch (status) {
        .modified => x11.gc.amber,
        .deleted => x11.gc.red,
        .untracked => x11.gc.cyan,
    };
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

fn riskInitial(risk: findings_mod.Risk) []const u8 {
    return switch (risk) {
        .info => "I",
        .low => "L",
        .medium => "M",
        .high => "H",
        .critical => "C",
    };
}

fn boundaryInitial(boundary: findings_mod.Boundary) []const u8 {
    return switch (boundary) {
        .workspace => "W",
        .memory => "M",
        .execution => "E",
        .filesystem => "F",
        .network => "N",
        .dependency => "D",
        .secret => "S",
        .text => "T",
        .path => "P",
        .git => "G",
        .output => "O",
    };
}

fn riskGc(x11: *X11, risk: findings_mod.Risk) u32 {
    return switch (risk) {
        .critical, .high => x11.gc.red,
        .medium => x11.gc.amber,
        .low, .info => x11.gc.muted,
    };
}

fn linuxBoundaryGrade(snapshot: *const LinuxSecuritySnapshot) LinuxBoundaryGrade {
    const max_score: u8 = 20;
    var score: u8 = 0;
    if (snapshot.no_new_privs == .on) score += 2;
    if (snapshot.dumpable == .off) score += 2;
    if (snapshot.ambient_clear == .on) score += 1;
    if (snapshot.seccomp_mode != null and snapshot.seccomp_mode.? > 0) score += 1;
    if (snapshot.seccomp_filters != null and snapshot.seccomp_filters.? > 0) score += 1;
    if (snapshot.cap_eff_zero == .on) score += 2;
    if (snapshot.euid_root == .off) score += 2;
    if ((snapshot.tracer_pid orelse 0) == 0) score += 2;
    if (snapshot.core_dumping == .off) score += 1;
    if (snapshot.pid_namespace == .on) score += 1;
    if (snapshot.dangerous_bounding_caps == 0) {
        score += 2;
    } else if (snapshot.bounding_caps_dropped > 0) {
        score += 1;
    }
    if (snapshot.maps_writable_executable == 0) score += 2;
    if (snapshot.fd_cloexec_missing <= 3) {
        score += 2;
    } else if (snapshot.fd_cloexec_missing <= 8) {
        score += 1;
    }
    if (snapshot.proc_status_read and snapshot.proc_maps_read and snapshot.proc_fd_read) score += 1;

    const label: []const u8 = if (score >= 17)
        "sealed"
    else if (score >= 13)
        "guarded"
    else if (score >= 8)
        "mixed"
    else
        "open";
    return .{ .label = label, .score = score, .max = max_score };
}

fn linuxBoundaryGc(x11: *X11, grade: LinuxBoundaryGrade) u32 {
    if (grade.score >= 17) return x11.gc.cyan;
    if (grade.score >= 13) return x11.gc.green;
    if (grade.score >= 8) return x11.gc.amber;
    return x11.gc.red;
}

fn applyLinuxLaunchProfile(ticket: *execution_queue.Ticket, profile: LinuxLaunchProfile) void {
    switch (profile) {
        .read_only => {
            ticket.env_policy = .allowlist;
            ticket.fs_policy = .read_only_workspace;
            ticket.network_policy = .deny;
            ticket.output_sanitized = true;
            ticket.timeout_ms = 15_000;
            ticket.output_limit_bytes = 256 * 1024;
        },
        .safe => {
            ticket.env_policy = .allowlist;
            ticket.fs_policy = .workspace_only;
            ticket.network_policy = .deny;
            ticket.output_sanitized = true;
            ticket.timeout_ms = 60_000;
            ticket.output_limit_bytes = 512 * 1024;
        },
        .network => {
            ticket.env_policy = .allowlist;
            ticket.fs_policy = .workspace_only;
            ticket.network_policy = .unrestricted;
            ticket.output_sanitized = true;
            ticket.timeout_ms = 90_000;
            ticket.output_limit_bytes = 768 * 1024;
        },
        .publish => {
            ticket.env_policy = .inherit_all;
            ticket.fs_policy = .workspace_only;
            ticket.network_policy = .unrestricted;
            ticket.output_sanitized = true;
            ticket.timeout_ms = 180_000;
            ticket.output_limit_bytes = 2 * 1024 * 1024;
        },
    }
}

fn linuxLaunchProfileLabel(profile: LinuxLaunchProfile) []const u8 {
    return switch (profile) {
        .read_only => "RO",
        .safe => "SAFE",
        .network => "NET",
        .publish => "PUB",
    };
}

fn linuxLaunchProfileDescription(profile: LinuxLaunchProfile) []const u8 {
    return switch (profile) {
        .read_only => "allowlist env / read-only workspace policy / network denied / tight output",
        .safe => "allowlist env / workspace cwd / network denied / normal build limits",
        .network => "allowlist env / workspace cwd / network allowed / larger output",
        .publish => "inherit env / workspace cwd / network allowed / release-sized output",
    };
}

fn linuxLaunchProfileGc(x11: *const X11, profile: LinuxLaunchProfile) u32 {
    return switch (profile) {
        .read_only => x11.gc.cyan,
        .safe => x11.gc.green,
        .network => x11.gc.amber,
        .publish => x11.gc.red,
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

fn settingsLines() []const []const u8 {
    return &.{
        "== WORKBENCH SETTINGS ==",
        "[profile] RO: read-only tasks, no network, tiny output. SAFE: workspace write, no network, bounded output.",
        "[profile] NET: explicit network-read tasks. PUB: release-sized output and publishing workflow.",
        "[trust] REVIEW marks the current audit reviewed. TRUST only succeeds when high-risk findings allow it.",
        "[trust] LOCK puts the workspace back into locked-down mode. Execution must be reviewed again.",
        "[linux] SEAL marks inherited file descriptors close-on-exec and refreshes no_new_privs/dumpable/capability state.",
        "[zide] Git overview reads .git directly; hooks, filters, fsmonitor, and git status are not executed.",
        "[zide] Extension discovery is manifest-only. Extension code stays inert until a future capability grant exists.",
        "[zide] Saves run through text integrity checks: hidden controls, mixed newlines, path boundaries, and security findings.",
        "[zide] Run output is sanitized and clipped before it reaches the IDE surface.",
        "[zide] .zide/workbench.conf remembers UX state only; trust state is intentionally re-earned.",
        "[ux] Ctrl+, opens this panel. Ctrl+K opens keybindings. Ctrl+Shift+P opens the command palette.",
        "[ux] The keybindings panel doubles as a command launcher; click a row to execute it.",
    };
}

fn settingsLineGc(x11: *X11, line: []const u8) u32 {
    if (std.mem.startsWith(u8, line, "==")) return x11.gc.amber;
    if (std.mem.startsWith(u8, line, "[profile]")) return x11.gc.green;
    if (std.mem.startsWith(u8, line, "[trust]")) return x11.gc.cyan;
    if (std.mem.startsWith(u8, line, "[linux]")) return x11.gc.amber;
    if (std.mem.startsWith(u8, line, "[zide]")) return x11.gc.cyan;
    if (std.mem.startsWith(u8, line, "[ux]")) return x11.gc.muted;
    return x11.gc.text;
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
            "TERM: QUE de plan, PTY de pseudo-terminal/shell. Ctrl+V paste, Ctrl+C interrupt, STOP de terminate.",
            "SHIP: bundle/verify/preflight wo Zig dake de hash to path boundary made kakunin.",
            "LINUX: no_new_privs, dumpable off, caps, /proc maps wo SEC ni dasu.",
        },
        .en => &.{
            "== ZIDE EN TOUR ==",
            "F1 opens help. Ctrl+P opens files. Ctrl+Shift+P opens commands. Ctrl+S saves through security gates.",
            "SEC shows Zig-owned boundary findings: memory, execution, filesystem, network, dependency, secret, text, path, git.",
            "GIT reads repository metadata directly; hooks, filters, fsmonitor, and git status are not executed for overview.",
            "EXT scans extension manifests only. Extension code is never executed during the baseline scan.",
            "TERM queues plans and runs them in a pseudo-terminal. PTY opens a bounded shell if the queue is empty.",
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

fn overviewHasGitHubRemote(overview: git_repository.Overview) bool {
    for (overview.remotes) |remote| {
        if (remote.github != null) return true;
    }
    return false;
}

fn githubTokenPresenceLabel(environ: std.process.Environ) []const u8 {
    if (environ.containsUnemptyConstant("GITHUB_TOKEN")) return "GITHUB_TOKEN";
    if (environ.containsUnemptyConstant("GH_TOKEN")) return "GH_TOKEN";
    return "none";
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

fn trySealExecFileDescriptors() FdSealResult {
    var result: FdSealResult = .{};
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, "/proc/self/fd", .{ .iterate = true }) catch return result;
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();
    while (true) {
        const maybe_entry = iter.next(std.Options.debug_io) catch {
            result.failed += 1;
            break;
        };
        const entry = maybe_entry orelse break;
        const fd = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        if (fd <= 2) continue;

        const flags_rc = linux.fcntl(fd, linux.F.GETFD, 0);
        if (linux.errno(flags_rc) != .SUCCESS) {
            result.failed += 1;
            continue;
        }
        if ((flags_rc & linux.FD_CLOEXEC) != 0) continue;

        const set_rc = linux.fcntl(fd, linux.F.SETFD, flags_rc | linux.FD_CLOEXEC);
        if (linux.errno(set_rc) == .SUCCESS) {
            result.sealed += 1;
        } else {
            result.failed += 1;
        }
    }
    return result;
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

fn parseStatusUsize(line: []const u8, prefix: []const u8) ?usize {
    return parseStatusUsizeField(line, prefix, 0);
}

fn parseStatusUsizeField(line: []const u8, prefix: []const u8, target_index: usize) ?usize {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = std.mem.trim(u8, line[prefix.len..], " \t\r\n");
    var fields = std.mem.tokenizeAny(u8, rest, " \t\r\n");
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index == target_index) return std.fmt.parseInt(usize, field, 10) catch null;
    }
    return null;
}

fn countStatusUsizeFields(line: []const u8, prefix: []const u8) usize {
    if (!std.mem.startsWith(u8, line, prefix)) return 0;
    const rest = std.mem.trim(u8, line[prefix.len..], " \t\r\n");
    var fields = std.mem.tokenizeAny(u8, rest, " \t\r\n");
    var count: usize = 0;
    while (fields.next()) |field| {
        _ = std.fmt.parseInt(usize, field, 10) catch continue;
        count += 1;
    }
    return count;
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
        } else if (std.mem.startsWith(u8, line, "Seccomp_filters:")) {
            snapshot.seccomp_filters = parseStatusUsize(line, "Seccomp_filters:") orelse snapshot.seccomp_filters;
        } else if (std.mem.startsWith(u8, line, "TracerPid:")) {
            snapshot.tracer_pid = parseStatusUsize(line, "TracerPid:") orelse snapshot.tracer_pid;
        } else if (std.mem.startsWith(u8, line, "CoreDumping:")) {
            if (parseStatusUsize(line, "CoreDumping:")) |value| snapshot.core_dumping = if (value == 0) .off else .on;
        } else if (std.mem.startsWith(u8, line, "Uid:")) {
            if (parseStatusUsizeField(line, "Uid:", 1) orelse parseStatusUsizeField(line, "Uid:", 0)) |euid| {
                snapshot.euid = euid;
                snapshot.euid_root = if (euid == 0) .on else .off;
            }
        } else if (std.mem.startsWith(u8, line, "NSpid:")) {
            snapshot.nspid_count = countStatusUsizeFields(line, "NSpid:");
            snapshot.pid_namespace = if (snapshot.nspid_count > 1) .on else if (snapshot.nspid_count == 1) .off else .unknown;
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

fn optionalUsizeLabel(buffer: []u8, value: ?usize) []const u8 {
    if (value) |number| return std.fmt.bufPrint(buffer, "{d}", .{number}) catch "n/a";
    return "unknown";
}

fn flagLabel(flag: LinuxFlag) []const u8 {
    return switch (flag) {
        .unknown => "unknown",
        .off => "off",
        .on => "on",
    };
}

fn boolLabel(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn launchAuditFingerprint(ticket: *const execution_queue.Ticket, workspace_root: []const u8) launch_audit.Fingerprint {
    const intent = command_intent.classify(ticket.executable, ticket.args.items);
    return launch_audit.fingerprint(.{
        .source_command_id = ticket.source_command_id,
        .display_command = ticket.display_command,
        .executable = ticket.executable,
        .args = ticket.args.items,
        .cwd = ticket.cwd,
        .workspace_root = workspace_root,
        .env_policy = @tagName(ticket.env_policy),
        .fs_policy = @tagName(ticket.fs_policy),
        .network_policy = @tagName(ticket.network_policy),
        .output_sanitized = ticket.output_sanitized,
        .timeout_ms = ticket.timeout_ms,
        .output_limit_bytes = ticket.output_limit_bytes,
        .intent_network = intent.network,
        .intent_mutating = intent.mutating,
        .intent_shell = intent.shell,
        .intent_destructive = intent.destructive,
        .intent_package_manager = intent.package_manager,
        .intent_reason = intent.reason,
    });
}

fn timeoutLabel(timeout_ms: ?u32) []const u8 {
    return if (timeout_ms == null) "none" else "set";
}

fn exitCodeLabel(exit_code: ?i32) []const u8 {
    const code = exit_code orelse return "exit:none";
    return switch (code) {
        0 => "exit:0",
        -1 => "exit:-1",
        else => "exit:nonzero",
    };
}

fn taskStateGc(x11: *const X11, state: execution_queue.State) u32 {
    return switch (state) {
        .finished => x11.gc.muted,
        .queued, .running => x11.gc.cyan,
        .blocked, .failed, .timed_out, .output_limited => x11.gc.red,
        .cancelled => x11.gc.amber,
    };
}

fn severityGc(x11: *const X11, severity: types.Severity) u32 {
    return switch (severity) {
        .err => x11.gc.red,
        .warning => x11.gc.amber,
        .info => x11.gc.cyan,
    };
}

fn outputLineGc(x11: *const X11, line: @import("../tasks/console.zig").Line) u32 {
    if (zig_output.parseLine(line.text)) |parsed| return severityGc(x11, parsed.severity);
    return if (line.stream == .stderr) x11.gc.red else x11.gc.muted;
}

fn commandCapabilityGc(x11: *const X11, capability: command_mod.Capability) u32 {
    return switch (capability) {
        .safe => x11.gc.green,
        .network_read => x11.gc.cyan,
        .network_write => x11.gc.amber,
        .workspace_write => x11.gc.amber,
        .external_command => x11.gc.red,
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

fn parseGotoLine(query: []const u8) ?GotoLineTarget {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return null;

    const delimiter = std.mem.indexOfAny(u8, trimmed, ":,");
    const line_text = if (delimiter) |index| std.mem.trim(u8, trimmed[0..index], " \t\r\n") else trimmed;
    const column_text = if (delimiter) |index| std.mem.trim(u8, trimmed[index + 1 ..], " \t\r\n") else "";
    if (line_text.len == 0) return null;

    const line_one = std.fmt.parseUnsigned(usize, line_text, 10) catch return null;
    if (line_one == 0) return null;

    var column: usize = 0;
    if (column_text.len > 0) {
        const column_one = std.fmt.parseUnsigned(usize, column_text, 10) catch return null;
        if (column_one == 0) return null;
        column = column_one - 1;
    }

    return .{ .line = line_one - 1, .column = column };
}

fn isValidIdentifierName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn isEditorLineCommand(id: []const u8) bool {
    return std.mem.eql(u8, id, "editor.delete_line") or
        std.mem.eql(u8, id, "editor.duplicate_line") or
        std.mem.eql(u8, id, "editor.move_line_up") or
        std.mem.eql(u8, id, "editor.move_line_down");
}

fn absI16(value: i16) u16 {
    const wide: i32 = value;
    return @intCast(if (wide < 0) -wide else wide);
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
        .goto_line => "GO TO LINE  line[:column]",
        .search_workspace => "SEARCH WORKSPACE",
        .new_file => "NEW FILE",
        .run_task => "RUN TASK",
        .document_symbols => "SYMBOLS",
        .workspace_symbols => "WORKSPACE SYMBOLS",
        .lsp_actions => "LSP ACTIONS  Ctrl+Alt+L",
        .lsp_locations => "LSP LOCATIONS  Enter opens",
        .problems => "PROBLEMS  diagnostics + security",
        .completion => "COMPLETE  Enter inserts",
        .lsp_hover => "HOVER  Enter closes",
        .code_actions => "QUICK FIX  Enter applies",
        .language_mode => "LANGUAGE MODE",
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

const header_actions = [_]HeaderAction{ .open_workspace, .save, .save_all, .build, .test_run, .task, .git, .audit, .scan, .extensions, .tutorial, .publish };

fn headerActionRect(action: HeaderAction) HitRect {
    const top: i16 = 15;
    const height: i16 = 30;
    return switch (action) {
        .open_workspace => .{ .left = 410, .top = top, .right = 472, .bottom = top + height },
        .save => .{ .left = 480, .top = top, .right = 540, .bottom = top + height },
        .save_all => .{ .left = 548, .top = top, .right = 606, .bottom = top + height },
        .build => .{ .left = 614, .top = top, .right = 684, .bottom = top + height },
        .test_run => .{ .left = 692, .top = top, .right = 750, .bottom = top + height },
        .task => .{ .left = 758, .top = top, .right = 824, .bottom = top + height },
        .git => .{ .left = 832, .top = top, .right = 888, .bottom = top + height },
        .audit => .{ .left = 896, .top = top, .right = 970, .bottom = top + height },
        .scan => .{ .left = 978, .top = top, .right = 1044, .bottom = top + height },
        .extensions => .{ .left = 1052, .top = top, .right = 1110, .bottom = top + height },
        .tutorial => .{ .left = 1118, .top = top, .right = 1184, .bottom = top + height },
        .publish => .{ .left = 1192, .top = top, .right = 1258, .bottom = top + height },
    };
}

fn headerActionLabel(action: HeaderAction) []const u8 {
    return switch (action) {
        .open_workspace => "OPEN",
        .save => "SAVE",
        .save_all => "ALL",
        .build => "BUILD",
        .test_run => "TEST",
        .task => "TASK",
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
    const panels = [_]BottomPanel{ .output, .tasks, .git, .extensions, .diagnostics, .security, .settings, .keybindings, .tutorial, .publish };
    for (panels, 0..) |panel, index| {
        const left: i16 = 10 + @as(i16, @intCast(index)) * 104;
        const rect = HitRect{ .left = left, .top = bottom + 8, .right = left + 96, .bottom = bottom + 32 };
        if (pointIn(rect, x, y)) return panel;
    }
    return null;
}

const git_panel_actions = [_]GitPanelAction{ .refresh, .status, .diff, .live, .issues, .failures, .draft_pr };
const task_panel_actions = [_]TaskPanelAction{ .profile_read_only, .profile_safe, .profile_network, .profile_publish, .terminal, .queue_terminal, .run_pty, .stop_pty, .tasks, .preview, .seal, .run_next, .history };
const security_panel_actions = [_]SecurityPanelAction{ .audit, .lock, .scan, .lf, .crlf, .clean, .seal, .linux };
const settings_panel_actions = [_]SettingsPanelAction{ .profile_read_only, .profile_safe, .profile_network, .profile_publish, .tutorial_ja, .tutorial_en, .review, .trust, .lock, .seal };
const extension_panel_actions = [_]ExtensionPanelAction{.scan};
const tutorial_panel_actions = [_]TutorialPanelAction{ .ja, .en };
const publish_panel_actions = [_]PublishPanelAction{ .checklist, .assets, .manifests, .bundle, .verify, .preflight };
const context_actions = [_]ContextAction{ .copy, .cut, .paste, .select_all, .find, .goto_line, .scan, .scan_selection, .boundary_lens, .comment, .references, .rename, .close_editor, .task_queue, .palette };

fn drawGitPanelActions(x11: *X11, state: *const LinuxGuiState) !void {
    inline for (git_panel_actions) |action| {
        try drawActionButton(x11, gitPanelActionRect(state, action), gitPanelActionLabel(action));
    }
}

fn drawTaskPanelActions(x11: *X11, state: *const LinuxGuiState) !void {
    inline for (task_panel_actions) |action| {
        const profile = taskPanelActionProfile(action);
        const active = if (profile) |value| value == state.linux_launch_profile else false;
        const color = if (profile) |value| linuxLaunchProfileGc(x11, value) else x11.gc.cyan;
        try drawActionButtonState(x11, taskPanelActionRect(state, action), taskPanelActionLabel(action), active, color);
    }
}

fn drawSecurityPanelActions(x11: *X11, state: *const LinuxGuiState) !void {
    inline for (security_panel_actions) |action| {
        try drawActionButton(x11, securityPanelActionRect(state, action), securityPanelActionLabel(action));
    }
}

fn drawSettingsPanelActions(x11: *X11, state: *const LinuxGuiState) !void {
    inline for (settings_panel_actions) |action| {
        const active = settingsPanelActionActive(state, action);
        const color = settingsPanelActionGc(x11, state, action);
        try drawActionButtonState(x11, settingsPanelActionRect(state, action), settingsPanelActionLabel(action), active, color);
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

fn taskPanelActionAt(state: *const LinuxGuiState, x: i16, y: i16) ?TaskPanelAction {
    inline for (task_panel_actions) |action| {
        if (pointIn(taskPanelActionRect(state, action), x, y)) return action;
    }
    return null;
}

fn securityPanelActionAt(state: *const LinuxGuiState, x: i16, y: i16) ?SecurityPanelAction {
    inline for (security_panel_actions) |action| {
        if (pointIn(securityPanelActionRect(state, action), x, y)) return action;
    }
    return null;
}

fn settingsPanelActionAt(state: *const LinuxGuiState, x: i16, y: i16) ?SettingsPanelAction {
    inline for (settings_panel_actions) |action| {
        if (pointIn(settingsPanelActionRect(state, action), x, y)) return action;
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

fn outputApplyButtonRect(state: *const LinuxGuiState) HitRect {
    const bottom = state.bottomTop();
    const right = state.window_width - 18;
    return .{ .left = right - 76, .top = bottom + 42, .right = right, .bottom = bottom + 66 };
}

fn gitPanelActionRect(state: *const LinuxGuiState, action: GitPanelAction) HitRect {
    const index: i16 = switch (action) {
        .refresh => 0,
        .status => 1,
        .diff => 2,
        .live => 3,
        .issues => 4,
        .failures => 5,
        .draft_pr => 6,
    };
    const width: i16 = 62;
    const gap: i16 = 8;
    const right = state.window_width - 18 - (6 - index) * (width + gap);
    const bottom = state.bottomTop();
    return .{ .left = right - width, .top = bottom + 42, .right = right, .bottom = bottom + 66 };
}

fn taskPanelActionRect(state: *const LinuxGuiState, action: TaskPanelAction) HitRect {
    const index: i16 = switch (action) {
        .profile_read_only => 0,
        .profile_safe => 1,
        .profile_network => 2,
        .profile_publish => 3,
        .terminal => 4,
        .queue_terminal => 5,
        .run_pty => 6,
        .stop_pty => 7,
        .tasks => 8,
        .preview => 9,
        .seal => 10,
        .run_next => 11,
        .history => 12,
    };
    const width: i16 = 49;
    const gap: i16 = 5;
    const right = state.window_width - 18 - (12 - index) * (width + gap);
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
        .seal => 6,
        .linux => 7,
    };
    const width: i16 = 58;
    const gap: i16 = 7;
    const right = state.window_width - 18 - (7 - index) * (width + gap);
    const bottom = state.bottomTop();
    return .{ .left = right - width, .top = bottom + 42, .right = right, .bottom = bottom + 66 };
}

fn settingsPanelActionRect(state: *const LinuxGuiState, action: SettingsPanelAction) HitRect {
    const index: i16 = switch (action) {
        .profile_read_only => 0,
        .profile_safe => 1,
        .profile_network => 2,
        .profile_publish => 3,
        .tutorial_ja => 4,
        .tutorial_en => 5,
        .review => 6,
        .trust => 7,
        .lock => 8,
        .seal => 9,
    };
    const width: i16 = 56;
    const gap: i16 = 7;
    const right = state.window_width - 18 - (9 - index) * (width + gap);
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
        .refresh => "REF",
        .status => "STAT",
        .diff => "DIFF",
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
        .live => "github.fetch",
        .issues => "github.issues",
        .failures => "github.actions.failures",
        .draft_pr => "github.pr.create_draft",
    };
}

fn taskPanelActionLabel(action: TaskPanelAction) []const u8 {
    return switch (action) {
        .profile_read_only => "RO",
        .profile_safe => "SAFE",
        .profile_network => "NET",
        .profile_publish => "PUB",
        .terminal => "TERM",
        .queue_terminal => "QUE",
        .run_pty => "PTY",
        .stop_pty => "STOP",
        .tasks => "TASKS",
        .preview => "PLAN",
        .seal => "SEAL",
        .run_next => "RUN",
        .history => "HIST",
    };
}

fn taskPanelActionProfile(action: TaskPanelAction) ?LinuxLaunchProfile {
    return switch (action) {
        .profile_read_only => .read_only,
        .profile_safe => .safe,
        .profile_network => .network,
        .profile_publish => .publish,
        else => null,
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
        .seal => "SEAL",
        .linux => "LINUX",
    };
}

fn settingsPanelActionLabel(action: SettingsPanelAction) []const u8 {
    return switch (action) {
        .profile_read_only => "RO",
        .profile_safe => "SAFE",
        .profile_network => "NET",
        .profile_publish => "PUB",
        .tutorial_ja => "JA",
        .tutorial_en => "EN",
        .review => "REV",
        .trust => "TRUST",
        .lock => "LOCK",
        .seal => "SEAL",
    };
}

fn settingsPanelActionActive(state: *const LinuxGuiState, action: SettingsPanelAction) bool {
    return switch (action) {
        .profile_read_only => state.linux_launch_profile == .read_only,
        .profile_safe => state.linux_launch_profile == .safe,
        .profile_network => state.linux_launch_profile == .network,
        .profile_publish => state.linux_launch_profile == .publish,
        .tutorial_ja => state.tutorial_language == .ja,
        .tutorial_en => state.tutorial_language == .en,
        .review => state.app.runtime.trust_state == .reviewed,
        .trust => switch (state.app.runtime.trust_state) {
            .trusted, .hardened, .paranoid => true,
            else => false,
        },
        .lock => state.app.runtime.trust_state == .locked_down,
        .seal => state.linux_security.fd_cloexec_sealed > 0 and state.linux_security.fd_cloexec_seal_failed == 0,
    };
}

fn settingsPanelActionGc(x11: *const X11, state: *const LinuxGuiState, action: SettingsPanelAction) u32 {
    return switch (action) {
        .profile_read_only => linuxLaunchProfileGc(x11, .read_only),
        .profile_safe => linuxLaunchProfileGc(x11, .safe),
        .profile_network => linuxLaunchProfileGc(x11, .network),
        .profile_publish => linuxLaunchProfileGc(x11, .publish),
        .tutorial_ja, .tutorial_en => x11.gc.cyan,
        .review => x11.gc.green,
        .trust => if (settingsPanelActionActive(state, action)) x11.gc.green else x11.gc.amber,
        .lock => x11.gc.red,
        .seal => x11.gc.amber,
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

fn contextMenuHeight() i16 {
    return 34 + @as(i16, @intCast(context_actions.len)) * 28 + 8;
}

fn contextMenuRect(state: *const LinuxGuiState) HitRect {
    return .{
        .left = state.context_menu_x,
        .top = state.context_menu_y,
        .right = state.context_menu_x + 230,
        .bottom = state.context_menu_y + contextMenuHeight(),
    };
}

fn contextActionRect(state: *const LinuxGuiState, action: ContextAction) HitRect {
    const index: i16 = @intCast(contextActionIndex(action));
    return .{
        .left = state.context_menu_x + 6,
        .top = state.context_menu_y + 32 + index * 28,
        .right = state.context_menu_x + 224,
        .bottom = state.context_menu_y + 32 + index * 28 + 28,
    };
}

fn contextActionIndex(action: ContextAction) usize {
    return switch (action) {
        .copy => 0,
        .cut => 1,
        .paste => 2,
        .select_all => 3,
        .find => 4,
        .goto_line => 5,
        .scan => 6,
        .scan_selection => 7,
        .boundary_lens => 8,
        .comment => 9,
        .references => 10,
        .rename => 11,
        .close_editor => 12,
        .task_queue => 13,
        .palette => 14,
    };
}

fn contextActionAt(state: *const LinuxGuiState, x: i16, y: i16) ?ContextAction {
    if (!state.context_menu_visible) return null;
    inline for (context_actions) |action| {
        if (pointIn(contextActionRect(state, action), x, y)) return action;
    }
    return null;
}

fn contextActionEnabled(state: *const LinuxGuiState, action: ContextAction) bool {
    return switch (action) {
        .copy, .cut, .scan_selection => blk: {
            const active_index = state.app.documents.activeIndex() orelse break :blk false;
            const doc = &state.app.documents.documents.items[active_index];
            break :blk state.selectedRange(doc) != null;
        },
        .paste => true,
        .select_all, .find, .goto_line, .scan, .boundary_lens, .comment, .references, .rename, .close_editor => state.app.documents.activeIndex() != null,
        .task_queue, .palette => true,
    };
}

fn contextActionLabel(action: ContextAction) []const u8 {
    return switch (action) {
        .copy => "Copy selection",
        .cut => "Cut selection",
        .paste => "Paste",
        .select_all => "Select all",
        .find => "Find in file",
        .goto_line => "Go to line",
        .scan => "Scan current file",
        .scan_selection => "Scan selection",
        .boundary_lens => "Boundary lens",
        .comment => "Toggle comment",
        .references => "Find references",
        .rename => "Rename symbol",
        .close_editor => "Close editor",
        .task_queue => "Preview run queue",
        .palette => "Command palette",
    };
}

fn contextActionHint(action: ContextAction) []const u8 {
    return switch (action) {
        .copy => "Ctrl+C",
        .cut => "Ctrl+X",
        .paste => "Ctrl+V",
        .select_all => "Ctrl+A",
        .find => "Ctrl+F",
        .goto_line => "Ctrl+G",
        .scan => "Alt+S",
        .scan_selection => "SEL",
        .boundary_lens => "LENS",
        .comment => "Ctrl+/",
        .references => "F12+S",
        .rename => "F2",
        .close_editor => "Ctrl+W",
        .task_queue => "RUN",
        .palette => "C+S+P",
    };
}

fn appendSecurityFindings(target: *findings_mod.Collection, source: *const findings_mod.Collection) !void {
    for (source.items.items) |item| {
        try target.appendFinding(item);
    }
}

fn outputLinesTop(state: *const LinuxGuiState) i16 {
    return state.bottomTop() + 86;
}

fn outputVisibleRows(state: *const LinuxGuiState) usize {
    return state.bottomRowsFrom(outputLinesTop(state));
}

fn outputVisibleStart(state: *const LinuxGuiState) usize {
    const total = state.app.process_console.lines.items.len;
    const visible = outputVisibleRows(state);
    const max_start = if (total > visible) total - visible else 0;
    return if (state.output_scroll_line == 0) max_start else @min(state.output_scroll_line - 1, max_start);
}

fn outputLineRowAt(state: *const LinuxGuiState, y: i16) ?usize {
    const top = outputLinesTop(state);
    if (y < top) return null;
    const row = @divTrunc(@as(isize, y - top), LINE_HEIGHT);
    if (row < 0) return null;
    return outputVisibleStart(state) + @as(usize, @intCast(row));
}

fn gitChangesTop(state: *const LinuxGuiState) i16 {
    const bottom = state.bottomTop();
    const remote_rows: usize = if (state.git_overview) |overview| @max(@min(overview.remotes.len, @as(usize, 2)), 1) else 1;
    return bottom + 132 + @as(i16, @intCast(remote_rows)) * LINE_HEIGHT;
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

fn keybindingsTop(state: *const LinuxGuiState) i16 {
    return state.bottomTop() + 108;
}

fn keybindingRowAt(state: *const LinuxGuiState, y: i16) ?usize {
    const top = keybindingsTop(state);
    if (y < top) return null;
    const row = @divTrunc(@as(isize, y - top), LINE_HEIGHT);
    if (row < 0) return null;
    return state.keybindings_scroll_line + @as(usize, @intCast(row));
}

fn diagnosticsTop(state: *const LinuxGuiState) i16 {
    return state.bottomTop() + 86;
}

fn diagnosticRowAt(state: *const LinuxGuiState, y: i16) ?usize {
    const top = diagnosticsTop(state);
    if (y < top) return null;
    const row = @divTrunc(@as(isize, y - top), LINE_HEIGHT);
    if (row < 0) return null;
    return state.diagnostics_scroll_line + @as(usize, @intCast(row));
}

fn securityFindingsTop(state: *const LinuxGuiState) i16 {
    return state.bottomTop() + 230;
}

fn taskHistoryTop(state: *const LinuxGuiState) i16 {
    return state.bottomTop() + 238;
}

fn terminalInputRect(state: *const LinuxGuiState) HitRect {
    const bottom = state.bottomTop();
    return .{ .left = 18, .top = bottom + 116, .right = state.window_width - 18, .bottom = bottom + 142 };
}

fn taskHistoryRowAt(state: *const LinuxGuiState, y: i16) ?usize {
    const top = taskHistoryTop(state);
    if (y < top) return null;
    const row = @divTrunc(@as(isize, y - top), LINE_HEIGHT);
    if (row < 0) return null;
    return state.task_scroll_line + @as(usize, @intCast(row));
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

fn monotonicMillis() i64 {
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &ts);
    if (linux.errno(rc) != .SUCCESS) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
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
