const ansi = @import("ansi.zig");

pub const TerminalSession = struct {
    alternate_screen: bool = true,
    cursor_hidden: bool = true,
    bracketed_paste: bool = true,

    pub fn begin(self: TerminalSession, writer: anytype) !void {
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

