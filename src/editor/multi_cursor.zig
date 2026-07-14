const std = @import("std");

pub const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
    cursor_in_replacement: usize,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    cursor_offsets: []usize,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.cursor_offsets);
        self.* = undefined;
    }
};

pub fn apply(allocator: std.mem.Allocator, source: []const u8, edits: []const Edit) !Result {
    const cursor_offsets = try allocator.alloc(usize, edits.len);
    errdefer allocator.free(cursor_offsets);
    if (edits.len == 0) {
        return .{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, source),
            .cursor_offsets = cursor_offsets,
        };
    }

    const indices = try allocator.alloc(usize, edits.len);
    defer allocator.free(indices);
    for (indices, 0..) |*index, value| index.* = value;
    std.mem.sort(usize, indices, edits, editIndexLessThan);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var source_offset: usize = 0;
    var sorted_index: usize = 0;
    while (sorted_index < indices.len) {
        const first_index = indices[sorted_index];
        const first = edits[first_index];
        try validateEdit(source, first);
        if (first.start < source_offset) return error.OverlappingEdits;

        try output.writer.writeAll(source[source_offset..first.start]);
        const replacement_start = output.written().len;
        try output.writer.writeAll(first.replacement);
        cursor_offsets[first_index] = replacement_start + first.cursor_in_replacement;

        var duplicate_index = sorted_index + 1;
        while (duplicate_index < indices.len) : (duplicate_index += 1) {
            const candidate_index = indices[duplicate_index];
            const candidate = edits[candidate_index];
            if (candidate.start != first.start or candidate.end != first.end) break;
            try validateEdit(source, candidate);
            if (!std.mem.eql(u8, candidate.replacement, first.replacement)) return error.ConflictingEdits;
            cursor_offsets[candidate_index] = replacement_start + candidate.cursor_in_replacement;
        }

        source_offset = first.end;
        sorted_index = duplicate_index;
    }
    try output.writer.writeAll(source[source_offset..]);

    return .{
        .allocator = allocator,
        .bytes = try output.toOwnedSlice(),
        .cursor_offsets = cursor_offsets,
    };
}

fn validateEdit(source: []const u8, edit: Edit) !void {
    if (edit.start > edit.end or edit.end > source.len) return error.OffsetOutOfBounds;
    if (edit.cursor_in_replacement > edit.replacement.len) return error.CursorOutsideReplacement;
}

fn editIndexLessThan(edits: []const Edit, left: usize, right: usize) bool {
    const a = edits[left];
    const b = edits[right];
    if (a.start != b.start) return a.start < b.start;
    if (a.end != b.end) return a.end < b.end;
    return left < right;
}

test "multi cursor edits apply in source order and return mapped cursors" {
    const edits = [_]Edit{
        .{ .start = 3, .end = 3, .replacement = "X", .cursor_in_replacement = 1 },
        .{ .start = 1, .end = 1, .replacement = "X", .cursor_in_replacement = 1 },
    };
    var result = try apply(std.testing.allocator, "a\nb\n", &edits);
    defer result.deinit();

    try std.testing.expectEqualStrings("aX\nbX\n", result.bytes);
    try std.testing.expectEqualSlices(usize, &.{ 5, 2 }, result.cursor_offsets);
}

test "duplicate cursors produce one edit and share the mapped position" {
    const edits = [_]Edit{
        .{ .start = 2, .end = 2, .replacement = "!", .cursor_in_replacement = 1 },
        .{ .start = 2, .end = 2, .replacement = "!", .cursor_in_replacement = 1 },
    };
    var result = try apply(std.testing.allocator, "abcd", &edits);
    defer result.deinit();

    try std.testing.expectEqualStrings("ab!cd", result.bytes);
    try std.testing.expectEqualSlices(usize, &.{ 3, 3 }, result.cursor_offsets);
}

test "overlapping and conflicting cursor edits are rejected" {
    const overlapping = [_]Edit{
        .{ .start = 0, .end = 2, .replacement = "", .cursor_in_replacement = 0 },
        .{ .start = 1, .end = 3, .replacement = "", .cursor_in_replacement = 0 },
    };
    try std.testing.expectError(error.OverlappingEdits, apply(std.testing.allocator, "abcd", &overlapping));

    const conflicting = [_]Edit{
        .{ .start = 2, .end = 2, .replacement = "x", .cursor_in_replacement = 1 },
        .{ .start = 2, .end = 2, .replacement = "y", .cursor_in_replacement = 1 },
    };
    try std.testing.expectError(error.ConflictingEdits, apply(std.testing.allocator, "abcd", &conflicting));
}
