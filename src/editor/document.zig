const std = @import("std");
const buffer = @import("buffer.zig");
const cursor = @import("cursor.zig");
const modes = @import("../language/modes.zig");
const types = @import("../core/types.zig");
const undo = @import("undo.zig");

pub const Document = struct {
    allocator: std.mem.Allocator,
    path: ?[]u8,
    language: modes.LanguageMode,
    text: buffer.TextBuffer,
    cursor: cursor.Cursor = .{},
    undo_stack: undo.UndoStack,
    dirty: bool = false,

    pub fn fromBytes(allocator: std.mem.Allocator, path: ?[]const u8, bytes: []const u8) !Document {
        return .{
            .allocator = allocator,
            .path = if (path) |p| try allocator.dupe(u8, p) else null,
            .language = if (path) |p| modes.detect(p) else .unknown,
            .text = try buffer.TextBuffer.initFromBytes(allocator, bytes),
            .undo_stack = undo.UndoStack.init(allocator),
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
