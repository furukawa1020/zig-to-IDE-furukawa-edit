const std = @import("std");
const builtin = @import("builtin");

const io = std.Options.debug_io;
const max_backup_bytes = 128 * 1024 * 1024;
const temporary_attempts = 32;

pub const SaveStrategy = struct {
    atomic: bool = true,
    backup_before_overwrite: bool = false,
    preserve_permissions: bool = true,
};

pub const SavePlan = struct {
    destination: []const u8,
    temporary_path: []const u8,
    strategy: SaveStrategy = .{},
};

pub fn saveBytes(allocator: std.mem.Allocator, destination: []const u8, bytes: []const u8, strategy: SaveStrategy) !void {
    const parent_path = std.fs.path.dirname(destination) orelse ".";
    const destination_name = std.fs.path.basename(destination);
    var parent = if (std.fs.path.isAbsolute(parent_path))
        try std.Io.Dir.openDirAbsolute(io, parent_path, .{ .follow_symlinks = false })
    else
        try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, parent_path, .{ .follow_symlinks = false });
    defer parent.close(io);
    try saveBytesInDir(allocator, parent, destination_name, bytes, strategy);
}

/// Saves a single file relative to an already-open directory capability.
/// `destination_name` must be a leaf name so resolution cannot leave `dir`.
pub fn saveBytesInDir(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    destination_name: []const u8,
    bytes: []const u8,
    strategy: SaveStrategy,
) !void {
    try validateLeafName(destination_name);

    if (strategy.backup_before_overwrite) {
        try createBackupInDir(allocator, dir, destination_name);
    }
    try saveBytesInDirNoBackup(allocator, dir, destination_name, bytes, strategy);
}

fn saveBytesInDirNoBackup(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    destination_name: []const u8,
    bytes: []const u8,
    strategy: SaveStrategy,
) !void {
    if (!strategy.atomic) {
        try writeDirectInDir(dir, destination_name, bytes);
        return;
    }

    const permissions = if (strategy.preserve_permissions)
        try destinationPermissionsInDir(dir, destination_name)
    else
        null;
    var temporary = try createTemporaryFile(allocator, dir, permissions orelse .default_file);
    defer allocator.free(temporary.name);

    var temporary_exists = true;
    errdefer if (temporary_exists) deleteFileInDirIfExists(dir, temporary.name);
    {
        defer temporary.file.close(io);
        try writeFileBytes(temporary.file, bytes);
    }

    try std.Io.Dir.rename(dir, temporary.name, dir, destination_name, io);
    temporary_exists = false;
}

fn writeDirectInDir(dir: std.Io.Dir, destination_name: []const u8, bytes: []const u8) !void {
    var opened_no_follow = true;
    var file = std.Io.Dir.openFile(dir, io, destination_name, .{
        .mode = .write_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| created: {
        if (err != error.FileNotFound) return err;
        opened_no_follow = false;
        break :created try std.Io.Dir.createFile(dir, io, destination_name, .{
            .truncate = true,
            .exclusive = true,
            .resolve_beneath = true,
        });
    };
    if (opened_no_follow) markNoFollowFileMode(&file);
    defer file.close(io);
    try file.setLength(io, 0);
    try writeFileBytes(file, bytes);
}

fn createBackupInDir(allocator: std.mem.Allocator, dir: std.Io.Dir, destination_name: []const u8) !void {
    const bytes = readFileInDir(allocator, dir, destination_name, max_backup_bytes) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);

    const backup_name = try std.fmt.allocPrint(allocator, "{s}.bak", .{destination_name});
    defer allocator.free(backup_name);
    try validateLeafName(backup_name);
    try saveBytesInDirNoBackup(allocator, dir, backup_name, bytes, .{});
}

const TemporaryFile = struct {
    name: []u8,
    file: std.Io.File,
};

fn createTemporaryFile(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    permissions: std.Io.File.Permissions,
) !TemporaryFile {
    var attempt: usize = 0;
    while (attempt < temporary_attempts) : (attempt += 1) {
        var nonce: [16]u8 = undefined;
        try io.randomSecure(&nonce);
        const encoded = std.fmt.bytesToHex(nonce, .lower);
        const name = try std.fmt.allocPrint(allocator, ".zide-tmp-{s}", .{encoded[0..]});
        const file = std.Io.Dir.createFile(dir, io, name, .{
            .truncate = true,
            .exclusive = true,
            .permissions = permissions,
            .resolve_beneath = true,
        }) catch |err| {
            allocator.free(name);
            if (err == error.PathAlreadyExists) continue;
            return err;
        };
        return .{ .name = name, .file = file };
    }
    return error.TemporaryNameExhausted;
}

fn destinationPermissionsInDir(dir: std.Io.Dir, destination_name: []const u8) !?std.Io.File.Permissions {
    var file = std.Io.Dir.openFile(dir, io, destination_name, .{
        .allow_directory = false,
        .path_only = true,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    return stat.permissions;
}

fn readFileInDir(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    file_name: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try std.Io.Dir.openFile(dir, io, file_name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    markNoFollowFileMode(&file);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > max_bytes) return error.FileTooLarge;

    var read_buffer: [8192]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

fn markNoFollowFileMode(file: *std.Io.File) void {
    if (builtin.os.tag == .windows) file.flags.nonblocking = true;
}

fn validateLeafName(name: []const u8) !void {
    if (name.len == 0 or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.indexOfAny(u8, name, "/\\") != null or
        std.fs.path.isAbsolute(name))
    {
        return error.InvalidFileName;
    }
}

fn deleteFileInDirIfExists(dir: std.Io.Dir, name: []const u8) void {
    std.Io.Dir.deleteFile(dir, io, name) catch {};
}

fn writeFileBytes(file: std.Io.File, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try file.sync(io);
}

test "atomic save uses an unpredictable temporary path" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "document.txt", .data = "before" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "document.txt.zide-tmp", .data = "do-not-follow" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const destination = try std.fs.path.join(std.testing.allocator, &.{ root_buffer[0..root_len], "document.txt" });
    defer std.testing.allocator.free(destination);

    try saveBytes(std.testing.allocator, destination, "after", .{});
    const original = try tmp.dir.readFileAlloc(std.Options.debug_io, "document.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(original);
    const temporary = try tmp.dir.readFileAlloc(std.Options.debug_io, "document.txt.zide-tmp", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(temporary);
    try std.testing.expectEqualStrings("after", original);
    try std.testing.expectEqualStrings("do-not-follow", temporary);
}

test "directory-relative save accepts only a leaf file name" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.testing.expectError(
        error.InvalidFileName,
        saveBytesInDir(std.testing.allocator, tmp.dir, "nested/document.txt", "blocked", .{}),
    );
    try std.testing.expectError(
        error.InvalidFileName,
        saveBytesInDir(std.testing.allocator, tmp.dir, "..", "blocked", .{}),
    );
}
