const types = @import("types.zig");

pub const Modifiers = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
};

pub const KeyCode = union(enum) {
    char: u21,
    enter,
    escape,
    backspace,
    delete,
    tab,
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    function: u8,
};

pub const KeyEvent = struct {
    code: KeyCode,
    modifiers: Modifiers = .{},
};

pub const ResizeEvent = struct {
    width: u16,
    height: u16,
};

pub const ProcessOutput = struct {
    process_id: u64,
    stream: enum { stdout, stderr },
    bytes: []const u8,
};

pub const FileChange = struct {
    path: []const u8,
    kind: enum { created, modified, deleted, renamed },
};

pub const Event = union(enum) {
    key: KeyEvent,
    paste: []const u8,
    resize: ResizeEvent,
    command_requested: []const u8,
    process_output: ProcessOutput,
    file_changed: FileChange,
    diagnostics_ready,
    render_requested,
    cursor_moved: types.Position,
    shutdown,
};
