const std = @import("std");
const types = @import("../core/types.zig");
const diagnostics = @import("../diagnostics/collection.zig");
const findings = @import("../security/findings.zig");
const fuzzy = @import("fuzzy.zig");

pub const Kind = enum {
    diagnostic,
    security,
};

pub const Options = struct {
    max_results: usize = 512,
};

pub const Result = struct {
    kind: Kind,
    path: []u8,
    line: usize,
    column: usize,
    source: []u8,
    level: []u8,
    message: []u8,
    score: u16,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        allocator.free(self.level);
        allocator.free(self.message);
        self.* = undefined;
    }
};

const BorrowedResult = struct {
    kind: Kind,
    path: []const u8,
    line: usize,
    column: usize,
    source: []const u8,
    level: []const u8,
    message: []const u8,
    score: u16,
};

pub fn collect(
    allocator: std.mem.Allocator,
    diagnostic_collection: *const diagnostics.Collection,
    security_collection: *const findings.Collection,
    query: []const u8,
    options: Options,
) ![]Result {
    var results = std.array_list.Managed(Result).init(allocator);
    errdefer {
        for (results.items) |*item| item.deinit(allocator);
        results.deinit();
    }

    for (diagnostic_collection.items.items) |item| {
        if (results.items.len >= options.max_results) break;
        const source = @tagName(item.source);
        const level = severityLabel(item.severity);
        const item_score = scoreProblem(query, item.path, source, level, item.message, severityWeight(item.severity)) orelse continue;
        try appendResult(allocator, &results, .{
            .kind = .diagnostic,
            .path = item.path,
            .line = item.range.start.line,
            .column = item.range.start.column,
            .source = source,
            .level = level,
            .message = item.message,
            .score = item_score,
        });
    }

    for (security_collection.items.items) |item| {
        if (results.items.len >= options.max_results) break;
        const source = @tagName(item.category);
        const level = @tagName(item.risk);
        const item_score = scoreProblem(query, item.path, source, level, item.message, riskWeight(item.risk)) orelse continue;
        try appendResult(allocator, &results, .{
            .kind = .security,
            .path = item.path,
            .line = item.line,
            .column = item.column,
            .source = source,
            .level = level,
            .message = item.message,
            .score = item_score,
        });
    }

    sortResults(results.items);
    return results.toOwnedSlice();
}

pub fn deinitResults(allocator: std.mem.Allocator, results: []Result) void {
    for (results) |*item| item.deinit(allocator);
    allocator.free(results);
}

fn appendResult(allocator: std.mem.Allocator, results: *std.array_list.Managed(Result), borrowed: BorrowedResult) !void {
    var owned = Result{
        .kind = borrowed.kind,
        .path = try allocator.dupe(u8, borrowed.path),
        .line = borrowed.line,
        .column = borrowed.column,
        .source = undefined,
        .level = undefined,
        .message = undefined,
        .score = borrowed.score,
    };
    errdefer allocator.free(owned.path);
    owned.source = try allocator.dupe(u8, borrowed.source);
    errdefer allocator.free(owned.source);
    owned.level = try allocator.dupe(u8, borrowed.level);
    errdefer allocator.free(owned.level);
    owned.message = try allocator.dupe(u8, borrowed.message);
    errdefer allocator.free(owned.message);
    try results.append(owned);
}

fn scoreProblem(
    query: []const u8,
    path: []const u8,
    source: []const u8,
    level: []const u8,
    message: []const u8,
    weight: u16,
) ?u16 {
    if (query.len == 0) return weight;
    const message_score = fuzzy.score(query, message);
    const path_score = fuzzy.score(query, path);
    const source_score = fuzzy.score(query, source);
    const level_score = fuzzy.score(query, level);
    if (message_score == null and path_score == null and source_score == null and level_score == null) return null;
    return weight + @max(@max(message_score orelse 0, path_score orelse 0), @max(source_score orelse 0, level_score orelse 0));
}

fn severityLabel(severity: types.Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .info => "info",
    };
}

fn severityWeight(severity: types.Severity) u16 {
    return switch (severity) {
        .err => 80,
        .warning => 50,
        .info => 20,
    };
}

fn riskWeight(risk: findings.Risk) u16 {
    return switch (risk) {
        .critical => 100,
        .high => 80,
        .medium => 55,
        .low => 30,
        .info => 15,
    };
}

fn sortResults(items: []Result) void {
    if (items.len < 2) return;
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

fn comesBefore(left: Result, right: Result) bool {
    if (left.score != right.score) return left.score > right.score;
    if (left.kind != right.kind) return left.kind == .security;
    const path_order = std.mem.order(u8, left.path, right.path);
    if (path_order != .eq) return path_order == .lt;
    if (left.line != right.line) return left.line < right.line;
    return left.column < right.column;
}

test "problem ordering favors higher risk" {
    var items = [_]Result{
        .{
            .kind = .diagnostic,
            .path = try std.testing.allocator.dupe(u8, "src/a.zig"),
            .line = 0,
            .column = 0,
            .source = try std.testing.allocator.dupe(u8, "compiler"),
            .level = try std.testing.allocator.dupe(u8, "warning"),
            .message = try std.testing.allocator.dupe(u8, "warn"),
            .score = 50,
        },
        .{
            .kind = .security,
            .path = try std.testing.allocator.dupe(u8, "src/b.zig"),
            .line = 0,
            .column = 0,
            .source = try std.testing.allocator.dupe(u8, "secret_flow"),
            .level = try std.testing.allocator.dupe(u8, "critical"),
            .message = try std.testing.allocator.dupe(u8, "secret"),
            .score = 100,
        },
    };
    defer {
        for (&items) |*item| item.deinit(std.testing.allocator);
    }

    sortResults(items[0..]);
    try std.testing.expectEqual(Kind.security, items[0].kind);
}
