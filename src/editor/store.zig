const std = @import("std");
const document = @import("document.zig");
const save = @import("save.zig");

pub const ClosePolicy = enum {
    allow_dirty,
    deny_dirty,
};

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

    pub fn closeAt(self: *DocumentStore, index: usize, policy: ClosePolicy) !void {
        if (index >= self.documents.items.len) return error.DocumentIndexOutOfBounds;
        if (policy == .deny_dirty and self.documents.items[index].dirty) return error.DirtyDocument;

        var doc = self.documents.orderedRemove(index);
        doc.deinit();

        if (self.documents.items.len == 0) {
            self.active_index = null;
            return;
        }

        const previous_active = self.active_index orelse 0;
        if (previous_active == index) {
            self.active_index = @min(index, self.documents.items.len - 1);
        } else if (previous_active > index) {
            self.active_index = previous_active - 1;
        } else {
            self.active_index = previous_active;
        }
    }

    pub fn closeActive(self: *DocumentStore, policy: ClosePolicy) !void {
        const index = self.activeIndex() orelse return error.NoActiveDocument;
        try self.closeAt(index, policy);
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

    pub fn dirtyCount(self: *const DocumentStore) usize {
        var count: usize = 0;
        for (self.documents.items) |doc| {
            if (doc.dirty) count += 1;
        }
        return count;
    }

    pub fn hasDirtyPathPrefix(self: *const DocumentStore, path: []const u8) bool {
        for (self.documents.items) |doc| {
            const doc_path = doc.path orelse continue;
            if (doc.dirty and pathMatchesOrDescendant(doc_path, path)) return true;
        }
        return false;
    }

    pub fn closePathPrefix(self: *DocumentStore, path: []const u8, policy: ClosePolicy) !usize {
        var closed: usize = 0;
        var index = self.documents.items.len;
        while (index > 0) {
            index -= 1;
            const doc_path = self.documents.items[index].path orelse continue;
            if (!pathMatchesOrDescendant(doc_path, path)) continue;
            try self.closeAt(index, policy);
            closed += 1;
        }
        return closed;
    }

    pub fn renamePathPrefix(self: *DocumentStore, old_path: []const u8, new_path: []const u8) !usize {
        var renamed: usize = 0;
        for (self.documents.items) |*doc| {
            const doc_path = doc.path orelse continue;
            if (!pathMatchesOrDescendant(doc_path, old_path)) continue;

            const suffix = doc_path[old_path.len..];
            const replacement = try std.mem.concat(self.allocator, u8, &.{ new_path, suffix });
            self.allocator.free(doc.path.?);
            doc.path = replacement;
            doc.language = @import("../language/modes.zig").detect(replacement);
            renamed += 1;
        }
        return renamed;
    }

    fn findByPath(self: *const DocumentStore, path: []const u8) ?usize {
        for (self.documents.items, 0..) |doc, index| {
            const doc_path = doc.path orelse continue;
            if (std.mem.eql(u8, doc_path, path)) return index;
        }
        return null;
    }
};

fn pathMatchesOrDescendant(path: []const u8, prefix: []const u8) bool {
    if (pathEqual(path, prefix)) return true;
    if (path.len <= prefix.len or !pathEqual(path[0..prefix.len], prefix)) return false;
    return path[prefix.len] == '/' or path[prefix.len] == '\\';
}

fn pathEqual(left: []const u8, right: []const u8) bool {
    if (std.fs.path.sep == '\\') return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}

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

test "document store closes active document" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.createScratch("one.zig", "const one = 1;\n");
    _ = try store.createScratch("two.zig", "const two = 2;\n");

    try store.closeActive(.allow_dirty);
    try std.testing.expectEqual(@as(usize, 1), store.documents.items.len);
    try std.testing.expectEqual(@as(?usize, 0), store.activeIndex());
}

test "document store counts dirty documents" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.createScratch("one.zig", "const one = 1;\n");
    _ = try store.createScratch("two.zig", "const two = 2;\n");

    try std.testing.expectEqual(@as(usize, 0), store.dirtyCount());
    store.documents.items[0].dirty = true;
    store.documents.items[1].dirty = true;
    try std.testing.expectEqual(@as(usize, 2), store.dirtyCount());
    store.documents.items[1].dirty = false;
    try std.testing.expectEqual(@as(usize, 1), store.dirtyCount());
}

test "document store follows renamed directory and protects dirty deletes" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.createScratch("C:\\repo\\src\\main.zig", "const x = 1;\n");
    _ = try store.createScratch("C:\\repo\\src2\\keep.zig", "const y = 2;\n");
    store.documents.items[0].dirty = true;

    try std.testing.expect(store.hasDirtyPathPrefix("C:\\repo\\src"));
    try std.testing.expect(!store.hasDirtyPathPrefix("C:\\repo\\src2"));
    try std.testing.expectEqual(@as(usize, 1), try store.renamePathPrefix("C:\\repo\\src", "C:\\repo\\lib"));
    try std.testing.expectEqualStrings("C:\\repo\\lib\\main.zig", store.documents.items[0].path.?);
    try std.testing.expectError(error.DirtyDocument, store.closePathPrefix("C:\\repo\\lib", .deny_dirty));
}
