const std = @import("std");
const modes = @import("../language/modes.zig");
const symbols = @import("../language/symbols.zig");
const fuzzy = @import("fuzzy.zig");
const workspace = @import("../workspace/workspace.zig");

pub const Options = struct {
    max_file_bytes: usize = 512 * 1024,
    max_files: usize = 500,
    max_results: usize = 512,
};

pub const Result = struct {
    path: []u8,
    name: []u8,
    kind: symbols.SymbolKind,
    language: modes.LanguageMode,
    line: usize,
    column: usize,
    byte_offset: usize,
    score: u16,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub fn search(allocator: std.mem.Allocator, ws: *const workspace.Workspace, query: []const u8, options: Options) ![]Result {
    var results = std.array_list.Managed(Result).init(allocator);
    errdefer {
        for (results.items) |*item| item.deinit(allocator);
        results.deinit();
    }

    var scanned_files: usize = 0;
    for (ws.entries.items) |entry| {
        if (results.items.len >= options.max_results) break;
        if (scanned_files >= options.max_files) break;
        if (entry.kind != .file) continue;
        if (!modes.isCode(entry.language)) continue;

        scanned_files += 1;
        const absolute = try std.fs.path.join(allocator, &.{ ws.root_path, entry.path });
        defer allocator.free(absolute);

        const bytes = readFile(allocator, absolute, options.max_file_bytes) catch continue;
        defer allocator.free(bytes);
        if (looksBinary(bytes)) continue;

        var index = symbols.collectDocument(allocator, bytes, entry.path, entry.language) catch continue;
        defer index.deinit();

        for (index.symbols) |symbol| {
            if (results.items.len >= options.max_results) break;
            const symbol_score = scoreSymbol(query, symbol.name, entry.path, symbol.kind) orelse continue;
            try results.append(.{
                .path = try allocator.dupe(u8, entry.path),
                .name = try allocator.dupe(u8, symbol.name),
                .kind = symbol.kind,
                .language = entry.language,
                .line = symbol.range.start.line,
                .column = symbol.range.start.column,
                .byte_offset = symbol.range.start.byte_offset,
                .score = symbol_score,
            });
        }
    }

    sortResults(results.items);
    return results.toOwnedSlice();
}

fn scoreSymbol(query: []const u8, name: []const u8, path: []const u8, kind: symbols.SymbolKind) ?u16 {
    if (query.len == 0) return kindBaseScore(kind);
    const name_score = fuzzy.score(query, name);
    const path_score = fuzzy.score(query, path);
    const kind_score = fuzzy.score(query, @tagName(kind));
    if (name_score == null and path_score == null and kind_score == null) return null;
    return @max(name_score orelse 0, @max((path_score orelse 0) / 2, kind_score orelse 0)) + kindBaseScore(kind);
}

fn kindBaseScore(kind: symbols.SymbolKind) u16 {
    return switch (kind) {
        .function, .test_block => 40,
        .struct_type, .enum_type, .union_type, .error_set => 34,
        .constant, .variable => 24,
        .import_alias, .package, .file => 18,
        .parameter, .local, .struct_field, .enum_field, .union_field, .error_value, .builtin => 10,
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
    const name_order = compareIgnoreCase(left.name, right.name);
    if (name_order != 0) return name_order < 0;
    return std.mem.lessThan(u8, left.path, right.path);
}

fn compareIgnoreCase(left: []const u8, right: []const u8) i32 {
    const len = @min(left.len, right.len);
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const l = std.ascii.toLower(left[index]);
        const r = std.ascii.toLower(right[index]);
        if (l < r) return -1;
        if (l > r) return 1;
    }
    if (left.len < right.len) return -1;
    if (left.len > right.len) return 1;
    return 0;
}

fn readFile(allocator: std.mem.Allocator, absolute: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, absolute, allocator, .limited(max_bytes));
}

fn looksBinary(bytes: []const u8) bool {
    const limit = @min(bytes.len, 4096);
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        if (bytes[index] == 0) return true;
    }
    return false;
}

test "workspace symbol result ordering favors functions" {
    var items = [_]Result{
        .{ .path = try std.testing.allocator.dupe(u8, "b.zig"), .name = try std.testing.allocator.dupe(u8, "value"), .kind = .variable, .language = .zig, .line = 0, .column = 0, .byte_offset = 0, .score = 10 },
        .{ .path = try std.testing.allocator.dupe(u8, "a.zig"), .name = try std.testing.allocator.dupe(u8, "render"), .kind = .function, .language = .zig, .line = 0, .column = 0, .byte_offset = 0, .score = 50 },
    };
    defer {
        for (&items) |*item| item.deinit(std.testing.allocator);
    }

    sortResults(items[0..]);
    try std.testing.expectEqualStrings("render", items[0].name);
}
