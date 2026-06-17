const std = @import("std");
const fuzzy = @import("fuzzy.zig");
const modes = @import("../language/modes.zig");
const workspace = @import("../workspace/workspace.zig");

pub const Match = struct {
    path: []const u8,
    score: u16,
    language: modes.LanguageMode,
};

pub fn find(allocator: std.mem.Allocator, ws: *const workspace.Workspace, query: []const u8, max_results: usize) ![]Match {
    var matches = std.ArrayList(Match).init(allocator);
    errdefer matches.deinit();

    for (ws.entries.items) |entry| {
        if (entry.kind != .file) continue;
        const score = scorePath(query, entry.path) orelse continue;
        try matches.append(.{
            .path = entry.path,
            .score = score,
            .language = entry.language,
        });
    }

    sortMatches(matches.items);
    if (matches.items.len > max_results) {
        matches.shrinkRetainingCapacity(max_results);
    }
    return matches.toOwnedSlice();
}

fn scorePath(query: []const u8, path: []const u8) ?u16 {
    if (query.len == 0) return 1;
    const base = std.fs.path.basename(path);
    const path_score = fuzzy.score(query, path);
    const base_score = fuzzy.score(query, base);
    if (path_score == null and base_score == null) return null;
    return @max(path_score orelse 0, (base_score orelse 0) + 8);
}

fn sortMatches(items: []Match) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and comesBefore(items[j], items[j - 1])) : (j -= 1) {
            const tmp = items[j - 1];
            items[j - 1] = items[j];
            items[j] = tmp;
        }
    }
}

fn comesBefore(left: Match, right: Match) bool {
    if (left.score != right.score) return left.score > right.score;
    return std.mem.lessThan(u8, left.path, right.path);
}

