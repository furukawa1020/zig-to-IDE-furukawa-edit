const std = @import("std");
const document = @import("document.zig");
const types = @import("../core/types.zig");

pub const Move = enum {
    left,
    right,
    word_left,
    word_right,
    line_start,
    line_end,
    up,
    down,
    file_start,
    file_end,
};

pub fn moveCursor(doc: *document.Document, move: Move) !void {
    const current = doc.cursor.position.byte_offset;
    const next = switch (move) {
        .left => try doc.text.previousByteOffset(current),
        .right => try doc.text.nextByteOffset(current),
        .word_left => try previousWordOffset(doc, current),
        .word_right => try nextWordOffset(doc, current),
        .line_start => blk: {
            const lc = try doc.text.offsetToLineColumn(current);
            break :blk (doc.text.lineStart(lc.line) orelse 0);
        },
        .line_end => blk: {
            const lc = try doc.text.offsetToLineColumn(current);
            const start = doc.text.lineStart(lc.line) orelse 0;
            break :blk start + doc.text.lineSlice(lc.line).len;
        },
        .up => try moveVertical(doc, -1),
        .down => try moveVertical(doc, 1),
        .file_start => 0,
        .file_end => doc.text.bytes.len,
    };
    doc.cursor.position = try doc.positionFromOffset(next);
    doc.cursor.preferred_column = doc.cursor.position.column;
}

fn previousWordOffset(doc: *document.Document, offset: usize) !usize {
    if (offset > doc.text.bytes.len) return error.OffsetOutOfBounds;
    if (offset == 0) return 0;

    var index = try doc.text.previousByteOffset(offset);
    while (index > 0 and !isWordByte(doc.text.bytes[index])) {
        index = try doc.text.previousByteOffset(index);
    }
    while (index > 0) {
        const previous = try doc.text.previousByteOffset(index);
        if (!isWordByte(doc.text.bytes[previous])) break;
        index = previous;
    }
    return index;
}

fn nextWordOffset(doc: *document.Document, offset: usize) !usize {
    if (offset > doc.text.bytes.len) return error.OffsetOutOfBounds;
    var index = offset;
    while (index < doc.text.bytes.len and isWordByte(doc.text.bytes[index])) {
        index = try doc.text.nextByteOffset(index);
    }
    while (index < doc.text.bytes.len and !isWordByte(doc.text.bytes[index])) {
        index = try doc.text.nextByteOffset(index);
    }
    return index;
}

fn isWordByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn moveVertical(doc: *document.Document, delta: isize) !usize {
    const current = doc.cursor.position;
    const line_count = doc.text.lineCount();
    if (line_count == 0) return 0;

    const target_line = if (delta < 0) blk: {
        const amount = @as(usize, @intCast(-delta));
        break :blk if (amount > current.line) 0 else current.line - amount;
    } else blk: {
        const amount = @as(usize, @intCast(delta));
        break :blk @min(line_count - 1, current.line + amount);
    };

    return doc.text.lineColumnToOffset(target_line, doc.cursor.preferred_column);
}

pub fn setCursor(doc: *document.Document, position: types.Position) void {
    doc.cursor.position = position;
    doc.cursor.preferred_column = position.column;
}

test "navigation moves through document" {
    var doc = try document.Document.fromBytes(@import("std").testing.allocator, "demo.zig", "abc\ndef\n");
    defer doc.deinit();

    try moveCursor(&doc, .right);
    try moveCursor(&doc, .right);
    try @import("std").testing.expectEqual(@as(usize, 2), doc.cursor.position.byte_offset);

    try moveCursor(&doc, .down);
    try @import("std").testing.expectEqual(@as(usize, 6), doc.cursor.position.byte_offset);
}

test "navigation moves by source words" {
    var doc = try document.Document.fromBytes(std.testing.allocator, "demo.zig", "pub fn main() void {}\n");
    defer doc.deinit();

    try moveCursor(&doc, .word_right);
    try std.testing.expectEqual(@as(usize, 4), doc.cursor.position.byte_offset);

    try moveCursor(&doc, .word_right);
    try std.testing.expectEqual(@as(usize, 7), doc.cursor.position.byte_offset);

    try moveCursor(&doc, .word_left);
    try std.testing.expectEqual(@as(usize, 4), doc.cursor.position.byte_offset);
}
