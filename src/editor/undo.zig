const std = @import("std");
const buffer = @import("buffer.zig");

pub const EditKind = enum {
    insert,
    delete,
    replace,
};

pub const Edit = struct {
    kind: EditKind,
    start: usize,
    before: []u8,
    after: []u8,

    fn deinit(self: *Edit, allocator: std.mem.Allocator) void {
        allocator.free(self.before);
        allocator.free(self.after);
        self.* = undefined;
    }
};

pub const Transaction = struct {
    label: []u8,
    edit: Edit,

    fn deinit(self: *Transaction, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        self.edit.deinit(allocator);
        self.* = undefined;
    }
};

pub const UndoStack = struct {
    allocator: std.mem.Allocator,
    undo_items: std.ArrayList(Transaction),
    redo_items: std.ArrayList(Transaction),

    pub fn init(allocator: std.mem.Allocator) UndoStack {
        return .{
            .allocator = allocator,
            .undo_items = std.ArrayList(Transaction).init(allocator),
            .redo_items = std.ArrayList(Transaction).init(allocator),
        };
    }

    pub fn deinit(self: *UndoStack) void {
        for (self.undo_items.items) |*item| item.deinit(self.allocator);
        for (self.redo_items.items) |*item| item.deinit(self.allocator);
        self.undo_items.deinit();
        self.redo_items.deinit();
        self.* = undefined;
    }

    pub fn push(
        self: *UndoStack,
        label: []const u8,
        kind: EditKind,
        start: usize,
        before: []const u8,
        after: []const u8,
    ) !void {
        self.clearRedo();
        try self.undo_items.append(.{
            .label = try self.allocator.dupe(u8, label),
            .edit = .{
                .kind = kind,
                .start = start,
                .before = try self.allocator.dupe(u8, before),
                .after = try self.allocator.dupe(u8, after),
            },
        });
    }

    pub fn undo(self: *UndoStack, text: *buffer.TextBuffer) !bool {
        if (self.undo_items.items.len == 0) return false;
        var item = self.undo_items.orderedRemove(self.undo_items.items.len - 1);
        errdefer item.deinit(self.allocator);
        try applyInverse(item.edit, text);
        try self.redo_items.append(item);
        return true;
    }

    pub fn redo(self: *UndoStack, text: *buffer.TextBuffer) !bool {
        if (self.redo_items.items.len == 0) return false;
        var item = self.redo_items.orderedRemove(self.redo_items.items.len - 1);
        errdefer item.deinit(self.allocator);
        try applyForward(item.edit, text);
        try self.undo_items.append(item);
        return true;
    }

    fn clearRedo(self: *UndoStack) void {
        for (self.redo_items.items) |*item| item.deinit(self.allocator);
        self.redo_items.clearRetainingCapacity();
    }
};

fn applyInverse(edit: Edit, text: *buffer.TextBuffer) !void {
    try text.replaceRange(edit.start, edit.start + edit.after.len, edit.before);
}

fn applyForward(edit: Edit, text: *buffer.TextBuffer) !void {
    try text.replaceRange(edit.start, edit.start + edit.before.len, edit.after);
}

test "undo and redo single edit" {
    var text = try buffer.TextBuffer.initFromBytes(std.testing.allocator, "hello");
    defer text.deinit();

    var stack = UndoStack.init(std.testing.allocator);
    defer stack.deinit();

    try text.insertBytes(5, " zide");
    try stack.push("insert", .insert, 5, "", " zide");

    try std.testing.expect(try stack.undo(&text));
    try std.testing.expectEqualStrings("hello", text.bytes);

    try std.testing.expect(try stack.redo(&text));
    try std.testing.expectEqualStrings("hello zide", text.bytes);
}
