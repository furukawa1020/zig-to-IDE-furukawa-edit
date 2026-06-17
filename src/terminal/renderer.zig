const std = @import("std");
const ansi = @import("ansi.zig");
const screen_mod = @import("screen.zig");

pub fn renderPlain(writer: anytype, screen: *const screen_mod.Screen) !void {
    var row: u16 = 0;
    while (row < screen.height) : (row += 1) {
        var column: u16 = 0;
        while (column < screen.width) : (column += 1) {
            try writeCodepoint(writer, screen.cells[indexOf(screen.width, column, row)].char);
        }
        try writer.writeByte('\n');
    }
}

pub fn renderAnsi(writer: anytype, screen: *const screen_mod.Screen) !void {
    try writer.writeAll(ansi.home);
    var current_style = screen_mod.Style{};
    try writeStyle(writer, current_style);

    var row: u16 = 0;
    while (row < screen.height) : (row += 1) {
        try ansi.moveCursor(row + 1, 1, writer);
        var column: u16 = 0;
        while (column < screen.width) : (column += 1) {
            const cell = screen.cells[indexOf(screen.width, column, row)];
            if (!sameStyle(current_style, cell.style)) {
                current_style = cell.style;
                try writeStyle(writer, current_style);
            }
            try writeCodepoint(writer, cell.char);
        }
    }
    try writer.writeAll(ansi.reset);
}

fn writeStyle(writer: anytype, style: screen_mod.Style) !void {
    try writer.writeAll(ansi.reset);
    if (style.bold) try writer.writeAll("\x1b[1m");
    if (style.inverse) try writer.writeAll("\x1b[7m");
    try writer.print("\x1b[3{d};4{d}m", .{ style.fg % 8, style.bg % 8 });
}

fn sameStyle(a: screen_mod.Style, b: screen_mod.Style) bool {
    return a.fg == b.fg and a.bg == b.bg and a.bold == b.bold and a.inverse == b.inverse;
}

fn writeCodepoint(writer: anytype, char: u21) !void {
    if (char <= 0x7f) {
        try writer.writeByte(@as(u8, @intCast(char)));
        return;
    }

    var bytes: [4]u8 = undefined;
    const len = encodeUtf8(char, &bytes) catch {
        try writer.writeByte('?');
        return;
    };
    try writer.writeAll(bytes[0..len]);
}

fn encodeUtf8(char: u21, out: *[4]u8) !usize {
    if (char <= 0x7f) {
        out[0] = @as(u8, @intCast(char));
        return 1;
    }
    if (char <= 0x7ff) {
        out[0] = @as(u8, @intCast(0xc0 | (char >> 6)));
        out[1] = @as(u8, @intCast(0x80 | (char & 0x3f)));
        return 2;
    }
    if (char <= 0xffff) {
        out[0] = @as(u8, @intCast(0xe0 | (char >> 12)));
        out[1] = @as(u8, @intCast(0x80 | ((char >> 6) & 0x3f)));
        out[2] = @as(u8, @intCast(0x80 | (char & 0x3f)));
        return 3;
    }
    if (char <= 0x10ffff) {
        out[0] = @as(u8, @intCast(0xf0 | (char >> 18)));
        out[1] = @as(u8, @intCast(0x80 | ((char >> 12) & 0x3f)));
        out[2] = @as(u8, @intCast(0x80 | ((char >> 6) & 0x3f)));
        out[3] = @as(u8, @intCast(0x80 | (char & 0x3f)));
        return 4;
    }
    return error.InvalidCodepoint;
}

fn indexOf(width: u16, x: u16, y: u16) usize {
    return @as(usize, y) * @as(usize, width) + @as(usize, x);
}

test "plain renderer emits screen rows" {
    var screen = try screen_mod.Screen.init(std.testing.allocator, 4, 2);
    defer screen.deinit();
    screen.writeText(0, 0, "zide", .{});

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try renderPlain(output.writer(), &screen);

    try std.testing.expect(std.mem.startsWith(u8, output.items, "zide\n"));
}

