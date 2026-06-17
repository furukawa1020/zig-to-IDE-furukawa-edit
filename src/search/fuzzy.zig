const std = @import("std");

pub fn score(query: []const u8, candidate: []const u8) ?u16 {
    if (query.len == 0) return 0;
    var qi: usize = 0;
    var total: u16 = 0;
    for (candidate, 0..) |c, i| {
        if (qi == query.len) break;
        if (std.ascii.toLower(c) != std.ascii.toLower(query[qi])) continue;
        total += if (i == qi) 6 else 2;
        qi += 1;
    }
    return if (qi == query.len) total else null;
}

test "fuzzy score matches ordered characters" {
    try std.testing.expect(score("zd", "zide") != null);
    try std.testing.expect(score("dz", "zide") == null);
}

