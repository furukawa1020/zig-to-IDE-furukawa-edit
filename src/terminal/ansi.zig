pub const enter_alternate_screen = "\x1b[?1049h";
pub const leave_alternate_screen = "\x1b[?1049l";
pub const clear_screen = "\x1b[2J";
pub const home = "\x1b[H";
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";
pub const reset = "\x1b[0m";

pub fn setTitle(title: []const u8, writer: anytype) !void {
    try writer.writeAll("\x1b]0;");
    for (title) |byte| {
        if (byte < 0x20 or byte == 0x7f) continue;
        try writer.writeByte(byte);
    }
    try writer.writeByte(0x07);
}

pub fn moveCursor(row: u16, col: u16, writer: anytype) !void {
    try writer.print("\x1b[{d};{d}H", .{ row, col });
}

test "set title emits osc sequence" {
    const std = @import("std");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try setTitle("zide", &output.writer);
    try std.testing.expect(std.mem.startsWith(u8, output.written(), "\x1b]0;zide"));
}
