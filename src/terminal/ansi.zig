pub const enter_alternate_screen = "\x1b[?1049h";
pub const leave_alternate_screen = "\x1b[?1049l";
pub const clear_screen = "\x1b[2J";
pub const home = "\x1b[H";
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";
pub const reset = "\x1b[0m";

pub fn moveCursor(row: u16, col: u16, writer: anytype) !void {
    try writer.print("\x1b[{d};{d}H", .{ row, col });
}

