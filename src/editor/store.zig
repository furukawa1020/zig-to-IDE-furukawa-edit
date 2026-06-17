const std = @import("std");
const document = @import("document.zig");
const save = @import("save.zig");

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    documents: std.ArrayList(document.Document),
    active_index: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) DocumentStore {
        return .{
            .allocator = allocator,
            .documents = std.ArrayList(document.Document).init(allocator),
        };
    }

    pub fn deinit(self: *DocumentStore) void {
        for (self.documents.items) |*doc| doc.deinit();
        self.documents.deinit();
        self.* = undefined;
    }

    pub fn openFile(self: *DocumentStore, path: []const u8) !usize {
        const bytes = try readFile(self.allocator, path, 32 * 1024 * 1024);
        defer self.allocator.free(bytes);

        try self.documents.append(try document.Document.fromBytes(self.allocator, path, bytes));
        const index = self.documents.items.len - 1;
        self.active_index = index;
        return index;
    }

    pub fn createScratch(self: *DocumentStore, name: []const u8, bytes: []const u8) !usize {
        try self.documents.append(try document.Document.fromBytes(self.allocator, name, bytes));
        const index = self.documents.items.len - 1;
        self.active_index = index;
        return index;
    }

    pub fn active(self: *DocumentStore) ?*document.Document {
        const index = self.active_index orelse return null;
        if (index >= self.documents.items.len) return null;
        return &self.documents.items[index];
    }

    pub fn saveActive(self: *DocumentStore, strategy: save.SaveStrategy) !void {
        const doc = self.active() orelse return error.NoActiveDocument;
        const path = doc.path orelse return error.DocumentHasNoPath;
        try save.saveBytes(self.allocator, path, doc.text.bytes, strategy);
        doc.dirty = false;
    }
};

fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

test "document store creates scratch document" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const index = try store.createScratch("scratch.zig", "const x = 1;\n");
    try std.testing.expectEqual(@as(usize, 0), index);
    try std.testing.expect(store.active() != null);
}
