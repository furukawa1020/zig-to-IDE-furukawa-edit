const std = @import("std");

pub const Options = struct {
    case_sensitive: bool = true,
    whole_word: bool = false,
};

pub const Match = struct {
    start: usize,
    end: usize,
};

pub fn findAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, options: Options) ![]Match {
    var matches = std.ArrayList(Match).init(allocator);
    errdefer matches.deinit();

    if (needle.len == 0) return matches.toOwnedSlice();

    var at: usize = 0;
    while (at <= haystack.len) {
        const found = findNext(haystack, needle, at, options) orelse break;
        try matches.append(.{ .start = found, .end = found + needle.len });
        at = found + @max(needle.len, 1);
    }

    return matches.toOwnedSlice();
}

pub fn findNext(haystack: []const u8, needle: []const u8, start: usize, options: Options) ?usize {
    if (needle.len == 0 or start > haystack.len) return null;

    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        const candidate = haystack[i .. i + needle.len];
        const same = if (options.case_sensitive)
            std.mem.eql(u8, candidate, needle)
        else
            std.ascii.eqlIgnoreCase(candidate, needle);
        if (!same) continue;
        if (options.whole_word and !isWholeWord(haystack, i, i + needle.len)) continue;
        return i;
    }

    return null;
}

fn isWholeWord(text: []const u8, start: usize, end: usize) bool {
    const before_ok = start == 0 or !isWordByte(text[start - 1]);
    const after_ok = end >= text.len or !isWordByte(text[end]);
    return before_ok and after_ok;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "literal search finds all matches" {
    const matches = try findAll(std.testing.allocator, "one two one", "one", .{});
    defer std.testing.allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(usize, 0), matches[0].start);
    try std.testing.expectEqual(@as(usize, 8), matches[1].start);
}

test "whole word search rejects embedded matches" {
    const found = findNext("stone one", "one", 0, .{ .whole_word = true });
    try std.testing.expectEqual(@as(?usize, 6), found);
}
