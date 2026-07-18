const std = @import("std");
const document_mod = @import("../editor/document.zig");
const editor_save = @import("../editor/save.zig");
const store_mod = @import("../editor/store.zig");
const workspace_io = @import("../security/workspace_io.zig");

const io = std.Options.debug_io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const storage_directory = ".zide/recovery";
pub const max_document_bytes: usize = 32 * 1024 * 1024;
pub const max_entries: usize = 128;
const max_scanned_entries: usize = max_entries * 2;
const max_relative_path_bytes: usize = 4096;
const magic = "ZIDE_RECOVERY\x00";
const format_version: u16 = 1;
const envelope_digest_length = Sha256.digest_length;
const snapshot_extension = ".zrec";
const snapshot_stem_length = Sha256.digest_length * 2;
const snapshot_file_name_length = snapshot_stem_length + snapshot_extension.len;
const SnapshotFileName = [snapshot_file_name_length]u8;

pub const Entry = struct {
    relative_path: []u8,
    file_name: SnapshotFileName,
    content_len: usize,
    cursor_offset: usize,
    baseline_digest: document_mod.ContentDigest,
    content_digest: document_mod.ContentDigest,
    owned_by_session: bool = false,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.relative_path);
        self.* = undefined;
    }
};

pub const CheckpointReport = struct {
    written: usize = 0,
    unchanged: usize = 0,
    removed: usize = 0,
    pending_resolution: usize = 0,
    skipped: usize = 0,
};

pub const RestoreResult = struct {
    document_index: usize,
    relative_path: []const u8,
    bytes_restored: usize,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    workspace_root: []u8,
    entries: std.array_list.Managed(Entry),
    invalid_entries: usize = 0,
    scan_truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) !Manager {
        var self: Manager = .{
            .allocator = allocator,
            .workspace_root = try allocator.dupe(u8, workspace_root),
            .entries = std.array_list.Managed(Entry).init(allocator),
        };
        errdefer self.deinit();
        try self.refresh();
        return self;
    }

    pub fn deinit(self: *Manager) void {
        self.clearEntries();
        self.entries.deinit();
        self.allocator.free(self.workspace_root);
        self.* = undefined;
    }

    pub fn refresh(self: *Manager) !void {
        self.clearEntries();
        self.invalid_entries = 0;
        self.scan_truncated = false;

        var dir = workspace_io.openDirectoryCapability(self.workspace_root, storage_directory) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);

        var iterator = dir.iterate();
        var scanned: usize = 0;
        while (try iterator.next(io)) |directory_entry| {
            if (scanned >= max_scanned_entries) {
                self.scan_truncated = true;
                break;
            }
            scanned += 1;

            if (!validSnapshotFileName(directory_entry.name)) {
                if (std.mem.endsWith(u8, directory_entry.name, snapshot_extension)) self.invalid_entries += 1;
                continue;
            }
            if (directory_entry.kind != .file) {
                self.invalid_entries += 1;
                continue;
            }

            var storage_path_buffer: [storage_directory.len + 1 + snapshot_file_name_length]u8 = undefined;
            const storage_path = std.fmt.bufPrint(&storage_path_buffer, "{s}/{s}", .{ storage_directory, directory_entry.name }) catch unreachable;
            var capability = workspace_io.openFileCapability(self.workspace_root, storage_path) catch |err| {
                if (err == error.OutOfMemory) return err;
                self.invalid_entries += 1;
                continue;
            };
            defer capability.close();

            const bytes = capability.readFileAlloc(self.allocator, maxSnapshotBytes()) catch |err| {
                if (err == error.OutOfMemory) return err;
                self.invalid_entries += 1;
                continue;
            };
            defer self.allocator.free(bytes);

            const parsed = parseSnapshot(bytes) catch {
                self.invalid_entries += 1;
                continue;
            };
            const expected_name = snapshotFileName(parsed.relative_path);
            if (!std.mem.eql(u8, expected_name[0..], directory_entry.name)) {
                self.invalid_entries += 1;
                continue;
            }
            if (self.entries.items.len >= max_entries) {
                self.scan_truncated = true;
                break;
            }

            try self.entries.append(.{
                .relative_path = try self.allocator.dupe(u8, parsed.relative_path),
                .file_name = expected_name,
                .content_len = parsed.content.len,
                .cursor_offset = parsed.cursor_offset,
                .baseline_digest = parsed.baseline_digest,
                .content_digest = parsed.content_digest,
            });
        }

        std.mem.sort(Entry, self.entries.items, {}, entryLessThan);
    }

    pub fn checkpointDocuments(self: *Manager, documents: []document_mod.Document) !CheckpointReport {
        var report: CheckpointReport = .{};
        for (documents) |*doc| {
            const absolute_path = doc.path orelse {
                report.skipped += 1;
                continue;
            };
            const relative_borrowed = workspace_io.relativeFilePath(self.workspace_root, absolute_path) catch {
                report.skipped += 1;
                continue;
            };
            const relative_path = try canonicalRelativePathAlloc(self.allocator, relative_borrowed);
            defer self.allocator.free(relative_path);
            if (isRecoveryStoragePath(relative_path)) {
                report.skipped += 1;
                continue;
            }

            const existing_index = self.findIndex(relative_path);
            if (!doc.dirty) {
                if (existing_index) |index| {
                    if (self.entries.items[index].owned_by_session) {
                        try self.discardIndex(index);
                        report.removed += 1;
                    }
                }
                continue;
            }
            if (doc.text.bytes.len > max_document_bytes or relative_path.len > max_relative_path_bytes) {
                report.skipped += 1;
                continue;
            }

            const content_digest = document_mod.contentDigest(doc.text.bytes);
            if (existing_index) |index| {
                const current = &self.entries.items[index];
                if (!current.owned_by_session) {
                    report.pending_resolution += 1;
                    continue;
                }
                if (std.mem.eql(u8, &current.content_digest, &content_digest) and
                    std.mem.eql(u8, &current.baseline_digest, &doc.saved_digest) and
                    current.cursor_offset == doc.cursor.position.byte_offset)
                {
                    report.unchanged += 1;
                    continue;
                }

                try self.writeSnapshot(relative_path, doc);
                current.content_len = doc.text.bytes.len;
                current.cursor_offset = doc.cursor.position.byte_offset;
                current.baseline_digest = doc.saved_digest;
                current.content_digest = content_digest;
                report.written += 1;
                continue;
            }

            if (self.entries.items.len >= max_entries) {
                report.skipped += 1;
                continue;
            }
            try self.writeSnapshot(relative_path, doc);
            try self.entries.append(.{
                .relative_path = try self.allocator.dupe(u8, relative_path),
                .file_name = snapshotFileName(relative_path),
                .content_len = doc.text.bytes.len,
                .cursor_offset = doc.cursor.position.byte_offset,
                .baseline_digest = doc.saved_digest,
                .content_digest = content_digest,
                .owned_by_session = true,
            });
            report.written += 1;
        }
        std.mem.sort(Entry, self.entries.items, {}, entryLessThan);
        return report;
    }

    pub fn restore(self: *Manager, index: usize, documents: *store_mod.DocumentStore) !RestoreResult {
        if (index >= self.entries.items.len) return error.RecoveryIndexOutOfBounds;
        const entry = &self.entries.items[index];

        var storage_path_buffer: [storage_directory.len + 1 + snapshot_file_name_length]u8 = undefined;
        const storage_path = storagePath(&storage_path_buffer, entry.file_name);
        var capability = try workspace_io.openFileCapability(self.workspace_root, storage_path);
        defer capability.close();
        const snapshot_bytes = try capability.readFileAlloc(self.allocator, maxSnapshotBytes());
        defer self.allocator.free(snapshot_bytes);
        const parsed = try parseSnapshot(snapshot_bytes);
        if (!pathEqual(parsed.relative_path, entry.relative_path)) return error.InvalidRecoverySnapshot;
        const expected_name = snapshotFileName(parsed.relative_path);
        if (!std.mem.eql(u8, &expected_name, &entry.file_name)) return error.InvalidRecoverySnapshot;

        var source = workspace_io.openFileCapability(self.workspace_root, parsed.relative_path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied => return error.RecoverySourceChanged,
            else => return err,
        };
        defer source.close();
        const disk_bytes = source.readFileAlloc(self.allocator, max_document_bytes) catch |err| switch (err) {
            error.FileChangedDuringRead, error.FileTooLarge => return error.RecoverySourceChanged,
            else => return err,
        };
        defer self.allocator.free(disk_bytes);
        const disk_digest = document_mod.contentDigest(disk_bytes);
        if (!std.mem.eql(u8, &disk_digest, &parsed.baseline_digest)) return error.RecoverySourceChanged;

        const absolute_path = try workspace_io.absolutePathAlloc(self.allocator, self.workspace_root, parsed.relative_path);
        defer self.allocator.free(absolute_path);
        const document_index = if (documents.indexOfPath(absolute_path)) |existing_index| existing_index else try documents.openBytes(absolute_path, disk_bytes);
        var doc = &documents.documents.items[document_index];
        const editor_digest = document_mod.contentDigest(doc.text.bytes);
        if (doc.dirty and !std.mem.eql(u8, &editor_digest, &parsed.content_digest)) return error.DirtyDocumentRecoveryConflict;
        if (!doc.dirty and !std.mem.eql(u8, &editor_digest, &parsed.baseline_digest)) return error.EditorRecoveryBaselineChanged;

        if (!std.mem.eql(u8, doc.text.bytes, parsed.content)) {
            try doc.replaceRange(0, doc.text.bytes.len, parsed.content);
        } else {
            doc.dirty = true;
        }
        doc.saved_digest = parsed.baseline_digest;
        doc.cursor.position = try doc.positionFromOffset(parsed.cursor_offset);
        try documents.switchTo(document_index);
        entry.owned_by_session = true;
        entry.content_len = parsed.content.len;
        entry.cursor_offset = parsed.cursor_offset;
        entry.baseline_digest = parsed.baseline_digest;
        entry.content_digest = parsed.content_digest;

        return .{
            .document_index = document_index,
            .relative_path = entry.relative_path,
            .bytes_restored = parsed.content.len,
        };
    }

    pub fn discardIndex(self: *Manager, index: usize) !void {
        if (index >= self.entries.items.len) return error.RecoveryIndexOutOfBounds;
        const entry = &self.entries.items[index];
        var storage_path_buffer: [storage_directory.len + 1 + snapshot_file_name_length]u8 = undefined;
        const path = storagePath(&storage_path_buffer, entry.file_name);
        _ = workspace_io.deleteFileOrEmptyDirectory(self.workspace_root, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        var removed = self.entries.orderedRemove(index);
        removed.deinit(self.allocator);
    }

    pub fn discardAll(self: *Manager) !usize {
        var discarded: usize = 0;
        while (self.entries.items.len > 0) {
            try self.discardIndex(self.entries.items.len - 1);
            discarded += 1;
        }
        return discarded;
    }

    pub fn discardAbsolutePath(self: *Manager, absolute_path: []const u8) !bool {
        const relative = workspace_io.relativeFilePath(self.workspace_root, absolute_path) catch return false;
        return self.discardRelativePath(relative);
    }

    pub fn discardRelativePath(self: *Manager, relative_path: []const u8) !bool {
        const canonical = try canonicalRelativePathAlloc(self.allocator, relative_path);
        defer self.allocator.free(canonical);
        const index = self.findIndex(canonical) orelse return false;
        try self.discardIndex(index);
        return true;
    }

    fn writeSnapshot(self: *Manager, relative_path: []const u8, doc: *const document_mod.Document) !void {
        var bytes: std.Io.Writer.Allocating = .init(self.allocator);
        defer bytes.deinit();
        try encodeSnapshot(self.allocator, &bytes.writer, relative_path, doc);
        if (bytes.written().len > maxSnapshotBytes()) return error.RecoverySnapshotTooLarge;

        const file_name = snapshotFileName(relative_path);
        var storage_path_buffer: [storage_directory.len + 1 + snapshot_file_name_length]u8 = undefined;
        const path = storagePath(&storage_path_buffer, file_name);
        var capability = try workspace_io.openFileCapabilityCreateParents(self.workspace_root, path);
        defer capability.close();
        try editor_save.saveBytesInDir(self.allocator, capability.parent, capability.name, bytes.written(), .{
            .atomic = true,
            .backup_before_overwrite = false,
            .preserve_permissions = true,
        });
    }

    fn findIndex(self: *const Manager, relative_path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (pathEqual(entry.relative_path, relative_path)) return index;
        }
        return null;
    }

    fn clearEntries(self: *Manager) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
    }
};

const ParsedSnapshot = struct {
    relative_path: []const u8,
    content: []const u8,
    cursor_offset: usize,
    baseline_digest: document_mod.ContentDigest,
    content_digest: document_mod.ContentDigest,
};

fn encodeSnapshot(allocator: std.mem.Allocator, writer: *std.Io.Writer, relative_path: []const u8, doc: *const document_mod.Document) !void {
    if (relative_path.len == 0 or relative_path.len > max_relative_path_bytes) return error.InvalidRecoveryPath;
    if (doc.text.bytes.len > max_document_bytes) return error.RecoverySnapshotTooLarge;
    const content_digest = document_mod.contentDigest(doc.text.bytes);

    var envelope: std.Io.Writer.Allocating = .init(allocator);
    defer envelope.deinit();
    try envelope.writer.writeAll(magic);
    try envelope.writer.writeInt(u16, format_version, .little);
    try envelope.writer.writeInt(u16, 0, .little);
    try envelope.writer.writeInt(u32, @intCast(relative_path.len), .little);
    try envelope.writer.writeInt(u64, @intCast(doc.text.bytes.len), .little);
    try envelope.writer.writeInt(u64, @intCast(@min(doc.cursor.position.byte_offset, doc.text.bytes.len)), .little);
    try envelope.writer.writeAll(&doc.saved_digest);
    try envelope.writer.writeAll(&content_digest);
    try envelope.writer.writeAll(relative_path);
    try envelope.writer.writeAll(doc.text.bytes);
    const digest = document_mod.contentDigest(envelope.written());
    try envelope.writer.writeAll(&digest);
    try writer.writeAll(envelope.written());
}

fn parseSnapshot(bytes: []const u8) !ParsedSnapshot {
    if (bytes.len < magic.len + 2 + 2 + 4 + 8 + 8 + (Sha256.digest_length * 3)) return error.InvalidRecoverySnapshot;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidRecoverySnapshot;
    if (bytes.len > maxSnapshotBytes()) return error.RecoverySnapshotTooLarge;

    var offset: usize = magic.len;
    const version = try readUnsigned(u16, bytes, &offset);
    const flags = try readUnsigned(u16, bytes, &offset);
    const path_len_u32 = try readUnsigned(u32, bytes, &offset);
    const content_len_u64 = try readUnsigned(u64, bytes, &offset);
    const cursor_offset_u64 = try readUnsigned(u64, bytes, &offset);
    if (version != format_version or flags != 0) return error.InvalidRecoverySnapshot;
    if (path_len_u32 == 0 or path_len_u32 > max_relative_path_bytes) return error.InvalidRecoverySnapshot;
    if (content_len_u64 > max_document_bytes or cursor_offset_u64 > content_len_u64) return error.InvalidRecoverySnapshot;

    const path_len: usize = @intCast(path_len_u32);
    const content_len: usize = @intCast(content_len_u64);
    const cursor_offset: usize = @intCast(cursor_offset_u64);
    if (bytes.len - offset < Sha256.digest_length * 2) return error.InvalidRecoverySnapshot;
    var baseline_digest: document_mod.ContentDigest = undefined;
    @memcpy(&baseline_digest, bytes[offset .. offset + Sha256.digest_length]);
    offset += Sha256.digest_length;
    var content_digest: document_mod.ContentDigest = undefined;
    @memcpy(&content_digest, bytes[offset .. offset + Sha256.digest_length]);
    offset += Sha256.digest_length;

    const payload_len = std.math.add(usize, path_len, content_len) catch return error.InvalidRecoverySnapshot;
    const expected_len = std.math.add(usize, offset, payload_len) catch return error.InvalidRecoverySnapshot;
    const full_len = std.math.add(usize, expected_len, envelope_digest_length) catch return error.InvalidRecoverySnapshot;
    if (full_len != bytes.len) return error.InvalidRecoverySnapshot;
    const relative_path = bytes[offset .. offset + path_len];
    try workspace_io.validateRelativeFilePath(relative_path);
    if (!std.unicode.utf8ValidateSlice(relative_path) or isRecoveryStoragePath(relative_path)) return error.InvalidRecoveryPath;
    offset += path_len;
    const content = bytes[offset .. offset + content_len];

    const expected_content_digest = document_mod.contentDigest(content);
    if (!std.mem.eql(u8, &expected_content_digest, &content_digest)) return error.InvalidRecoverySnapshot;
    const expected_envelope_digest = document_mod.contentDigest(bytes[0..expected_len]);
    if (!std.mem.eql(u8, &expected_envelope_digest, bytes[expected_len..])) return error.InvalidRecoverySnapshot;

    return .{
        .relative_path = relative_path,
        .content = content,
        .cursor_offset = cursor_offset,
        .baseline_digest = baseline_digest,
        .content_digest = content_digest,
    };
}

fn readUnsigned(comptime T: type, bytes: []const u8, offset: *usize) !T {
    const size = @sizeOf(T);
    if (offset.* > bytes.len or bytes.len - offset.* < size) return error.InvalidRecoverySnapshot;
    var value: T = 0;
    for (bytes[offset.* .. offset.* + size], 0..) |byte, index| {
        value |= @as(T, byte) << @intCast(index * 8);
    }
    offset.* += size;
    return value;
}

fn snapshotFileName(relative_path: []const u8) SnapshotFileName {
    const digest = document_mod.contentDigest(relative_path);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    var result: SnapshotFileName = undefined;
    @memcpy(result[0..snapshot_stem_length], encoded[0..]);
    @memcpy(result[snapshot_stem_length..], snapshot_extension);
    return result;
}

fn validSnapshotFileName(name: []const u8) bool {
    if (name.len != snapshot_file_name_length or !std.mem.endsWith(u8, name, snapshot_extension)) return false;
    for (name[0..snapshot_stem_length]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn storagePath(buffer: *[storage_directory.len + 1 + snapshot_file_name_length]u8, file_name: SnapshotFileName) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ storage_directory, file_name[0..] }) catch unreachable;
}

fn canonicalRelativePathAlloc(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    try workspace_io.validateRelativeFilePath(relative_path);
    const canonical = try allocator.dupe(u8, relative_path);
    for (canonical) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return canonical;
}

fn isRecoveryStoragePath(path: []const u8) bool {
    if (path.len <= storage_directory.len) return pathEqual(path, storage_directory);
    return pathEqual(path[0..storage_directory.len], storage_directory) and path[storage_directory.len] == '/';
}

fn pathEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    if (@import("builtin").os.tag == .windows) return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}

fn entryLessThan(_: void, left: Entry, right: Entry) bool {
    return std.mem.lessThan(u8, left.relative_path, right.relative_path);
}

fn maxSnapshotBytes() usize {
    return magic.len + 2 + 2 + 4 + 8 + 8 + (Sha256.digest_length * 3) + max_relative_path_bytes + max_document_bytes;
}

test "recovery snapshot survives manager restart and restores only the editor buffer" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    const baseline = "const value = 1;\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = baseline });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const absolute = try workspace_io.absolutePathAlloc(std.testing.allocator, root, "src/main.zig");
    defer std.testing.allocator.free(absolute);

    var documents = store_mod.DocumentStore.init(std.testing.allocator);
    defer documents.deinit();
    _ = try documents.openBytes(absolute, baseline);
    const doc = documents.active().?;
    try doc.insert(doc.text.bytes.len, "// unsaved\n");
    doc.cursor.position = try doc.positionFromOffset(6);

    {
        var manager = try Manager.init(std.testing.allocator, root);
        defer manager.deinit();
        const report = try manager.checkpointDocuments(documents.documents.items);
        try std.testing.expectEqual(@as(usize, 1), report.written);
        try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);
    }

    var restored_documents = store_mod.DocumentStore.init(std.testing.allocator);
    defer restored_documents.deinit();
    _ = try restored_documents.openBytes(absolute, baseline);
    var restored_manager = try Manager.init(std.testing.allocator, root);
    defer restored_manager.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored_manager.entries.items.len);
    try std.testing.expect(!restored_manager.entries.items[0].owned_by_session);
    const result = try restored_manager.restore(0, &restored_documents);
    try std.testing.expectEqualStrings("src/main.zig", result.relative_path);
    try std.testing.expectEqualStrings("const value = 1;\n// unsaved\n", restored_documents.active().?.text.bytes);
    try std.testing.expect(restored_documents.active().?.dirty);
    try std.testing.expectEqual(@as(usize, 6), restored_documents.active().?.cursor.position.byte_offset);
    const disk_bytes = try tmp.dir.readFileAlloc(io, "src/main.zig", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(disk_bytes);
    try std.testing.expectEqualStrings(baseline, disk_bytes);
}

test "recovery refuses changed source and preserves the snapshot" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const baseline = "before\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "main.txt", .data = baseline });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const absolute = try workspace_io.absolutePathAlloc(std.testing.allocator, root, "main.txt");
    defer std.testing.allocator.free(absolute);
    var documents = store_mod.DocumentStore.init(std.testing.allocator);
    defer documents.deinit();
    _ = try documents.openBytes(absolute, baseline);
    try documents.active().?.insert(baseline.len, "unsaved\n");

    var manager = try Manager.init(std.testing.allocator, root);
    defer manager.deinit();
    _ = try manager.checkpointDocuments(documents.documents.items);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.txt", .data = "changed outside\n" });

    var clean_documents = store_mod.DocumentStore.init(std.testing.allocator);
    defer clean_documents.deinit();
    try std.testing.expectError(error.RecoverySourceChanged, manager.restore(0, &clean_documents));
    try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);
}

test "unresolved recovery is never overwritten by a new session checkpoint" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.txt", .data = "base\n" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const absolute = try workspace_io.absolutePathAlloc(std.testing.allocator, root, "main.txt");
    defer std.testing.allocator.free(absolute);

    {
        var documents = store_mod.DocumentStore.init(std.testing.allocator);
        defer documents.deinit();
        _ = try documents.openBytes(absolute, "base\n");
        try documents.active().?.insert(5, "first\n");
        var manager = try Manager.init(std.testing.allocator, root);
        defer manager.deinit();
        _ = try manager.checkpointDocuments(documents.documents.items);
    }

    var manager = try Manager.init(std.testing.allocator, root);
    defer manager.deinit();
    var documents = store_mod.DocumentStore.init(std.testing.allocator);
    defer documents.deinit();
    _ = try documents.openBytes(absolute, "base\n");
    try documents.active().?.insert(5, "second\n");
    const report = try manager.checkpointDocuments(documents.documents.items);
    try std.testing.expectEqual(@as(usize, 1), report.pending_resolution);
    try std.testing.expectEqual(@as(usize, 0), report.written);

    var recovered = store_mod.DocumentStore.init(std.testing.allocator);
    defer recovered.deinit();
    _ = try recovered.openBytes(absolute, "base\n");
    _ = try manager.restore(0, &recovered);
    try std.testing.expectEqualStrings("base\nfirst\n", recovered.active().?.text.bytes);
}

test "corrupt recovery envelopes are reported but never loaded" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, storage_directory);
    const fake_name = snapshotFileName("main.txt");
    var path_buffer: [storage_directory.len + 1 + snapshot_file_name_length]u8 = undefined;
    const path = storagePath(&path_buffer, fake_name);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "not a recovery envelope" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);

    var manager = try Manager.init(std.testing.allocator, root_buffer[0..root_len]);
    defer manager.deinit();
    try std.testing.expectEqual(@as(usize, 0), manager.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), manager.invalid_entries);
}
