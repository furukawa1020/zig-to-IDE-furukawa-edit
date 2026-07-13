const std = @import("std");
const document_mod = @import("../editor/document.zig");

pub const WatchBackend = enum {
    native,
    polling,
    disabled,
};

pub const WatchConfig = struct {
    backend: WatchBackend = .polling,
    poll_interval_ms: u32 = 1000,
    max_documents: usize = 256,
};

pub const ChangeKind = enum {
    modified,
    deleted,
};

pub const Change = struct {
    document_index: usize,
    kind: ChangeKind,
};

pub const Batch = struct {
    allocator: std.mem.Allocator,
    items: []Change,

    pub fn deinit(self: *Batch) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

const Fingerprint = struct {
    size: u64,
    inode: std.Io.File.INode,
    mtime_ns: i96,
    ctime_ns: i96,

    fn fromStat(stat: std.Io.File.Stat) Fingerprint {
        return .{
            .size = stat.size,
            .inode = stat.inode,
            .mtime_ns = stat.mtime.nanoseconds,
            .ctime_ns = stat.ctime.nanoseconds,
        };
    }

    fn eql(left: Fingerprint, right: Fingerprint) bool {
        return left.size == right.size and
            left.inode == right.inode and
            left.mtime_ns == right.mtime_ns and
            left.ctime_ns == right.ctime_ns;
    }
};

const Entry = struct {
    path: []u8,
    fingerprint: ?Fingerprint,
    missing_reported: bool = false,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Poller = struct {
    allocator: std.mem.Allocator,
    config: WatchConfig,
    entries: std.array_list.Managed(Entry),

    pub fn init(allocator: std.mem.Allocator, config: WatchConfig) Poller {
        return .{
            .allocator = allocator,
            .config = config,
            .entries = std.array_list.Managed(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Poller) void {
        self.clear();
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *Poller) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
    }

    pub fn poll(self: *Poller, documents: []const document_mod.Document) !Batch {
        var changes = std.array_list.Managed(Change).init(self.allocator);
        errdefer changes.deinit();
        if (self.config.backend == .disabled) return .{ .allocator = self.allocator, .items = try changes.toOwnedSlice() };

        self.removeClosedDocuments(documents);
        const limit = @min(documents.len, self.config.max_documents);
        for (documents[0..limit], 0..) |doc, document_index| {
            const path = doc.path orelse continue;
            const entry = try self.ensureEntry(path);
            const fingerprint = statFingerprint(path) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };

            if (fingerprint) |current| {
                if (entry.fingerprint) |previous| {
                    if (!Fingerprint.eql(previous, current)) try changes.append(.{ .document_index = document_index, .kind = .modified });
                } else if (entry.missing_reported) {
                    try changes.append(.{ .document_index = document_index, .kind = .modified });
                }
                entry.fingerprint = current;
                entry.missing_reported = false;
            } else {
                if (entry.fingerprint != null or !entry.missing_reported) try changes.append(.{ .document_index = document_index, .kind = .deleted });
                entry.fingerprint = null;
                entry.missing_reported = true;
            }
        }

        return .{ .allocator = self.allocator, .items = try changes.toOwnedSlice() };
    }

    fn ensureEntry(self: *Poller, path: []const u8) !*Entry {
        for (self.entries.items) |*entry| {
            if (pathEqual(entry.path, path)) return entry;
        }
        const fingerprint = statFingerprint(path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.entries.append(.{
            .path = owned_path,
            .fingerprint = fingerprint,
            .missing_reported = false,
        });
        return &self.entries.items[self.entries.items.len - 1];
    }

    fn removeClosedDocuments(self: *Poller, documents: []const document_mod.Document) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const path = self.entries.items[index].path;
            var found = false;
            for (documents) |doc| {
                if (doc.path) |doc_path| {
                    if (pathEqual(path, doc_path)) {
                        found = true;
                        break;
                    }
                }
            }
            if (found) {
                index += 1;
                continue;
            }
            var removed = self.entries.orderedRemove(index);
            removed.deinit(self.allocator);
        }
    }
};

fn statFingerprint(path: []const u8) !Fingerprint {
    const stat = try std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{});
    if (stat.kind != .file) return error.FileNotFound;
    return Fingerprint.fromStat(stat);
}

fn pathEqual(left: []const u8, right: []const u8) bool {
    if (std.fs.path.sep == '\\') return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}

test "poller reports modification and deletion once" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "main.zig", .data = "const a = 1;\n" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root_buffer[0..root_len], "main.zig" });
    defer std.testing.allocator.free(path);

    var doc = try document_mod.Document.fromBytes(std.testing.allocator, path, "const a = 1;\n");
    defer doc.deinit();
    var poller = Poller.init(std.testing.allocator, .{});
    defer poller.deinit();

    var initial = try poller.poll(&.{doc});
    defer initial.deinit();
    try std.testing.expectEqual(@as(usize, 0), initial.items.len);

    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "main.zig", .data = "const answer = 42;\n" });
    var modified = try poller.poll(&.{doc});
    defer modified.deinit();
    try std.testing.expectEqual(@as(usize, 1), modified.items.len);
    try std.testing.expectEqual(ChangeKind.modified, modified.items[0].kind);

    var unchanged = try poller.poll(&.{doc});
    defer unchanged.deinit();
    try std.testing.expectEqual(@as(usize, 0), unchanged.items.len);

    try tmp.dir.deleteFile(std.Options.debug_io, "main.zig");
    var deleted = try poller.poll(&.{doc});
    defer deleted.deinit();
    try std.testing.expectEqual(@as(usize, 1), deleted.items.len);
    try std.testing.expectEqual(ChangeKind.deleted, deleted.items[0].kind);

    var still_deleted = try poller.poll(&.{doc});
    defer still_deleted.deinit();
    try std.testing.expectEqual(@as(usize, 0), still_deleted.items.len);
}
