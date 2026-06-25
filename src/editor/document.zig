const std = @import("std");
const buffer = @import("buffer.zig");
const cursor = @import("cursor.zig");
const modes = @import("../language/modes.zig");
const types = @import("../core/types.zig");
const undo_mod = @import("undo.zig");

pub const Document = struct {
    allocator: std.mem.Allocator,
    path: ?[]u8,
    language: modes.LanguageMode,
    text: buffer.TextBuffer,
    cursor: cursor.Cursor = .{},
    undo_stack: undo_mod.UndoStack,
    dirty: bool = false,

    pub fn fromBytes(allocator: std.mem.Allocator, path: ?[]const u8, bytes: []const u8) !Document {
        return .{
            .allocator = allocator,
            .path = if (path) |p| try allocator.dupe(u8, p) else null,
            .language = if (path) |p| modes.detect(p) else .unknown,
            .text = try buffer.TextBuffer.initFromBytes(allocator, bytes),
            .undo_stack = undo_mod.UndoStack.init(allocator),
        };
    }

    pub fn deinit(self: *Document) void {
        if (self.path) |p| self.allocator.free(p);
        self.undo_stack.deinit();
        self.text.deinit();
        self.* = undefined;
    }

    pub fn insert(self: *Document, offset: usize, bytes: []const u8) !void {
        try self.text.insertBytes(offset, bytes);
        try self.undo_stack.push("insert", .insert, offset, "", bytes);
        self.cursor.position = try self.positionFromOffset(offset + bytes.len);
        self.dirty = true;
    }

    pub fn deleteRange(self: *Document, start: usize, end: usize) !void {
        const before = try self.text.slice(start, end);
        try self.undo_stack.push("delete", .delete, start, before, "");
        try self.text.deleteRange(start, end);
        self.cursor.position = try self.positionFromOffset(start);
        self.dirty = true;
    }

    pub fn replaceRange(self: *Document, start: usize, end: usize, bytes: []const u8) !void {
        const before = try self.text.slice(start, end);
        try self.undo_stack.push("replace", .replace, start, before, bytes);
        try self.text.replaceRange(start, end, bytes);
        self.cursor.position = try self.positionFromOffset(start + bytes.len);
        self.dirty = true;
    }

    pub fn deleteLine(self: *Document, line: usize) !bool {
        if (line >= self.text.lineCount()) return false;
        const range = self.lineRange(line) orelse return false;
        try self.deleteRange(range.start, range.end);
        const target_line = @min(line, if (self.text.lineCount() == 0) 0 else self.text.lineCount() - 1);
        const target_offset = self.text.lineColumnToOffset(target_line, 0) catch @min(range.start, self.text.bytes.len);
        self.cursor.position = try self.positionFromOffset(target_offset);
        return true;
    }

    pub fn duplicateLine(self: *Document, line: usize) !bool {
        if (line >= self.text.lineCount()) return false;
        const range = self.lineRange(line) orelse return false;
        const content = self.text.bytes[range.start..range.content_end];
        const line_ending = self.text.bytes[range.content_end..range.end];
        const column = self.cursor.position.column;

        var duplicated: std.Io.Writer.Allocating = .init(self.allocator);
        defer duplicated.deinit();
        if (line_ending.len == 0) try duplicated.writer.writeAll(self.preferredNewline());
        try duplicated.writer.writeAll(content);
        if (line_ending.len > 0) try duplicated.writer.writeAll(line_ending);

        const inserted = duplicated.written();
        try self.insert(range.end, inserted);
        const new_line = @min(line + 1, if (self.text.lineCount() == 0) 0 else self.text.lineCount() - 1);
        const target_column = @min(column, self.text.lineSlice(new_line).len);
        const target_offset = try self.text.lineColumnToOffset(new_line, target_column);
        self.cursor.position = try self.positionFromOffset(target_offset);
        return true;
    }

    pub fn moveLineUp(self: *Document, line: usize) !bool {
        if (line == 0 or line >= self.text.lineCount()) return false;
        return try self.moveAdjacentLines(line - 1, line, line - 1);
    }

    pub fn moveLineDown(self: *Document, line: usize) !bool {
        if (line + 1 >= self.text.lineCount()) return false;
        return try self.moveAdjacentLines(line, line + 1, line + 1);
    }

    pub fn undo(self: *Document) !bool {
        const changed = try self.undo_stack.undo(&self.text);
        if (changed) self.dirty = true;
        return changed;
    }

    pub fn redo(self: *Document) !bool {
        const changed = try self.undo_stack.redo(&self.text);
        if (changed) self.dirty = true;
        return changed;
    }

    pub fn positionFromOffset(self: *const Document, offset: usize) !types.Position {
        const lc = try self.text.offsetToLineColumn(offset);
        return .{ .line = lc.line, .column = lc.column, .byte_offset = offset };
    }

    fn moveAdjacentLines(self: *Document, first_line: usize, second_line: usize, target_line: usize) !bool {
        const first = self.lineRange(first_line) orelse return false;
        const second = self.lineRange(second_line) orelse return false;
        const column = self.cursor.position.column;

        var replacement: std.Io.Writer.Allocating = .init(self.allocator);
        defer replacement.deinit();
        try replacement.writer.writeAll(self.text.bytes[second.start..second.content_end]);
        try replacement.writer.writeAll(self.text.bytes[first.content_end..second.start]);
        try replacement.writer.writeAll(self.text.bytes[first.start..first.content_end]);
        try replacement.writer.writeAll(self.text.bytes[second.content_end..second.end]);

        try self.replaceRange(first.start, second.end, replacement.written());
        const target_column = @min(column, self.text.lineSlice(target_line).len);
        const target_offset = try self.text.lineColumnToOffset(target_line, target_column);
        self.cursor.position = try self.positionFromOffset(target_offset);
        return true;
    }

    fn lineRange(self: *const Document, line: usize) ?LineRange {
        const start = self.text.lineStart(line) orelse return null;
        const content_end = start + self.text.lineSlice(line).len;
        const end = if (line + 1 < self.text.lineCount())
            self.text.lineStart(line + 1) orelse self.text.bytes.len
        else
            self.text.bytes.len;
        return .{ .start = start, .content_end = content_end, .end = end };
    }

    fn preferredNewline(self: *const Document) []const u8 {
        return switch (self.text.newline) {
            .crlf => "\r\n",
            else => "\n",
        };
    }
};

const LineRange = struct {
    start: usize,
    content_end: usize,
    end: usize,
};

test "document edit tracks dirty and undo" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "pub fn main() void {}\n");
    defer doc.deinit();

    try doc.insert(0, "// hello\n");
    try std.testing.expect(doc.dirty);
    try std.testing.expectEqualStrings("// hello\npub fn main() void {}\n", doc.text.bytes);

    try std.testing.expect(try doc.undo());
    try std.testing.expectEqualStrings("pub fn main() void {}\n", doc.text.bytes);
}

test "document line operations duplicate delete and move" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "a\nb\nc\n");
    defer doc.deinit();

    try std.testing.expect(try doc.duplicateLine(1));
    try std.testing.expectEqualStrings("a\nb\nb\nc\n", doc.text.bytes);

    try std.testing.expect(try doc.deleteLine(1));
    try std.testing.expectEqualStrings("a\nb\nc\n", doc.text.bytes);
}

test "document line operations move distinct lines" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "a\nb\nc\n");
    defer doc.deinit();

    try std.testing.expect(try doc.moveLineUp(2));
    try std.testing.expectEqualStrings("a\nc\nb\n", doc.text.bytes);

    try std.testing.expect(try doc.moveLineDown(0));
    try std.testing.expectEqualStrings("c\na\nb\n", doc.text.bytes);
}

test "document line duplicate handles final line without newline" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "a\nb");
    defer doc.deinit();

    try std.testing.expect(try doc.duplicateLine(1));
    try std.testing.expectEqualStrings("a\nb\nb", doc.text.bytes);
}
