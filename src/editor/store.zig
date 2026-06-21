const std = @import("std");
const document = @import("document.zig");
const save = @import("save.zig");

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    documents: std.array_list.Managed(document.Document),
    active_index: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) DocumentStore {
        return .{
            .allocator = allocator,
            .documents = std.array_list.Managed(document.Document).init(allocator),
        };
    }

    pub fn deinit(self: *DocumentStore) void {
        for (self.documents.items) |*doc| doc.deinit();
        self.documents.deinit();
        self.* = undefined;
    }

    pub fn openFile(self: *DocumentStore, path: []const u8) !usize {
        if (self.findByPath(path)) |existing| {
            self.active_index = existing;
            return existing;
        }

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

    pub fn activeIndex(self: *const DocumentStore) ?usize {
        const index = self.active_index orelse return null;
        if (index >= self.documents.items.len) return null;
        return index;
    }

    pub fn switchTo(self: *DocumentStore, index: usize) !void {
        if (index >= self.documents.items.len) return error.DocumentIndexOutOfBounds;
        self.active_index = index;
    }

    pub fn moveActive(self: *DocumentStore, delta: isize) void {
        if (self.documents.items.len == 0) {
            self.active_index = null;
            return;
        }

        const current = self.activeIndex() orelse 0;
        const max_index = self.documents.items.len - 1;
        const next = if (delta < 0) blk: {
            const amount = @as(usize, @intCast(-delta));
            break :blk if (amount > current) max_index else current - amount;
        } else blk: {
            const amount = @as(usize, @intCast(delta));
            break :blk if (current + amount > max_index) 0 else current + amount;
        };
        self.active_index = next;
    }

    pub fn active(self: *DocumentStore) ?*document.Document {
        const index = self.activeIndex() orelse return null;
        return &self.documents.items[index];
    }

    pub fn saveActive(self: *DocumentStore, strategy: save.SaveStrategy) !void {
        const doc = self.active() orelse return error.NoActiveDocument;
        const path = doc.path orelse return error.DocumentHasNoPath;
        try save.saveBytes(self.allocator, path, doc.text.bytes, strategy);
        doc.dirty = false;
    }

    fn findByPath(self: *const DocumentStore, path: []const u8) ?usize {
        for (self.documents.items, 0..) |doc, index| {
            const doc_path = doc.path orelse continue;
            if (std.mem.eql(u8, doc_path, path)) return index;
        }
        return null;
    }
};

fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(max_bytes));
}

test "document store creates scratch document" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const index = try store.createScratch("scratch.zig", "const x = 1;\n");
    try std.testing.expectEqual(@as(usize, 0), index);
    try std.testing.expect(store.active() != null);
}

test "document store switches active document" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.createScratch("one.zig", "const one = 1;\n");
    _ = try store.createScratch("two.zig", "const two = 2;\n");

    try std.testing.expectEqual(@as(?usize, 1), store.activeIndex());
    try store.switchTo(0);
    try std.testing.expectEqual(@as(?usize, 0), store.activeIndex());
    store.moveActive(-1);
    try std.testing.expectEqual(@as(?usize, 1), store.activeIndex());
}
