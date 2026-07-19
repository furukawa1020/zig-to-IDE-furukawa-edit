const std = @import("std");

pub const Target = struct {
    line: usize,
    column: usize = 0,
};

pub fn parse(query: []const u8) ?Target {
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

test "parse one-based line and optional column" {
    try std.testing.expectEqual(Target{ .line = 11 }, parse("12").?);
    try std.testing.expectEqual(Target{ .line = 11, .column = 6 }, parse(" 12:7 ").?);
    try std.testing.expectEqual(Target{ .line = 2, .column = 3 }, parse("3,4").?);
}

test "reject invalid goto line input" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("0") == null);
    try std.testing.expect(parse("1:0") == null);
    try std.testing.expect(parse("line") == null);
    try std.testing.expect(parse(":4") == null);
}
