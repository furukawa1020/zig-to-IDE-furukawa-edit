const ansi = @import("ansi.zig");

pub const TerminalSession = struct {
    alternate_screen: bool = true,
    cursor_hidden: bool = true,
    bracketed_paste: bool = true,
    title: []const u8 = "zide",

    pub fn begin(self: TerminalSession, writer: anytype) !void {
        if (self.title.len > 0) try ansi.setTitle(self.title, writer);
        if (self.alternate_screen) try writer.writeAll(ansi.enter_alternate_screen);
        if (self.cursor_hidden) try writer.writeAll(ansi.hide_cursor);
        if (self.bracketed_paste) try writer.writeAll("\x1b[?2004h");
        try writer.writeAll(ansi.clear_screen);
        try writer.writeAll(ansi.home);
    }

    pub fn end(self: TerminalSession, writer: anytype) !void {
        if (self.bracketed_paste) try writer.writeAll("\x1b[?2004l");
        if (self.cursor_hidden) try writer.writeAll(ansi.show_cursor);
        if (self.alternate_screen) try writer.writeAll(ansi.leave_alternate_screen);
    }
};

test "terminal session titles the host" {
    const std = @import("std");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try (TerminalSession{ .alternate_screen = false, .cursor_hidden = false, .bracketed_paste = false }).begin(&output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b]0;zide") != null);
}
