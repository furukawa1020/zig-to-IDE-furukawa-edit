const std = @import("std");
const builtin = @import("builtin");

const io = std.Options.debug_io;

/// A file name anchored to an open workspace directory. The borrowed `name`
/// cannot redirect operations outside `parent` because it is always a leaf.
pub const FileCapability = struct {
    parent: std.Io.Dir,
    name: []const u8,

    pub fn close(self: *FileCapability) void {
        self.parent.close(io);
        self.* = undefined;
    }

    pub fn openRead(self: FileCapability) !std.Io.File {
        return openFileNoFollow(self.parent, self.name, .read_only);
    }

    pub fn readFileAlloc(
        self: FileCapability,
        allocator: std.mem.Allocator,
        max_bytes: usize,
    ) ![]u8 {
        const file = try self.openRead();
        defer file.close(io);
        return readOpenedFileAlloc(file, allocator, max_bytes);
    }

    pub fn statNoFollow(self: FileCapability) !std.Io.File.Stat {
        return std.Io.Dir.statFile(self.parent, io, self.name, .{ .follow_symlinks = false });
    }
};

pub fn openFileNoFollow(
    dir: std.Io.Dir,
    name: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !std.Io.File {
    var file = try std.Io.Dir.openFile(dir, io, name, .{
        .mode = mode,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    errdefer file.close(io);
    if (builtin.os.tag == .windows) file.flags.nonblocking = true;
    if ((try file.stat(io)).kind != .file) return error.NotRegularFile;
    return file;
}

fn openDirectoryAbsoluteNoFollow(path: []const u8, iterate: bool) !std.Io.Dir {
    const dir = try std.Io.Dir.openDirAbsolute(io, path, .{
        .follow_symlinks = false,
        .iterate = iterate,
    });
    return verifyOpenedDirectory(dir);
}

fn openDirectoryNoFollow(parent: std.Io.Dir, name: []const u8, iterate: bool) !std.Io.Dir {
    const dir = try std.Io.Dir.openDir(parent, io, name, .{
        .follow_symlinks = false,
        .iterate = iterate,
    });
    return verifyOpenedDirectory(dir);
}

/// Windows opens a directory reparse point itself when no-follow is requested.
/// Verify the returned handle so links and every other reparse-point kind are
/// rejected without a path-based time-of-check/time-of-use gap.
fn verifyOpenedDirectory(opened: std.Io.Dir) !std.Io.Dir {
    errdefer opened.close(io);
    if ((try opened.stat(io)).kind != .directory) return error.WorkspacePathIsLink;
    return opened;
}

/// Reads a stable-size snapshot from an already-open no-follow file handle.
/// Windows uses event-backed NT I/O because Zig 0.16 misclassifies these
/// asynchronous handles in its default file reader.
pub fn readOpenedFileAlloc(
    file: std.Io.File,
    allocator: std.mem.Allocator,
    max_bytes: usize,
) ![]u8 {
    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularFile;
    if (before.size > @as(u64, @intCast(max_bytes))) return error.FileTooLarge;

    const expected_len: usize = @intCast(before.size);
    const bytes = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(bytes);

    var offset: usize = 0;
    while (offset < bytes.len) {
        const read_count = try readAt(file, bytes[offset..], offset);
        if (read_count == 0) return error.FileChangedDuringRead;
        offset += read_count;
    }

    var extra: [1]u8 = undefined;
    if (try readAt(file, &extra, bytes.len) != 0) return error.FileChangedDuringRead;
    const after = try file.stat(io);
    if (after.kind != .file or
        after.inode != before.inode or
        after.size != before.size or
        after.mtime.nanoseconds != before.mtime.nanoseconds or
        after.ctime.nanoseconds != before.ctime.nanoseconds)
    {
        return error.FileChangedDuringRead;
    }
    return bytes;
}

pub fn writeOpenedFileAll(file: std.Io.File, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const write_count = try writeAt(file, bytes[offset..], offset);
        if (write_count == 0) return error.WriteZero;
        offset += write_count;
    }
}

fn readAt(file: std.Io.File, buffer: []u8, offset: u64) !usize {
    if (builtin.os.tag == .windows) return readAtWindows(file, buffer, offset);
    return file.readPositional(io, &.{buffer}, offset);
}

fn readAtWindows(file: std.Io.File, buffer: []u8, offset: u64) !usize {
    const windows = std.os.windows;
    if (buffer.len == 0) return 0;

    var event: windows.HANDLE = undefined;
    switch (windows.ntdll.NtCreateEvent(
        &event,
        windows.ACCESS_MASK.Specific.Event.ALL_ACCESS,
        null,
        .Synchronization,
        .FALSE,
    )) {
        .SUCCESS => {},
        else => |status| return windows.unexpectedStatus(status),
    }
    defer windows.CloseHandle(event);

    var io_status: windows.IO_STATUS_BLOCK = undefined;
    const signed_offset: windows.LARGE_INTEGER = @intCast(offset);
    const read_len: windows.ULONG = @intCast(@min(buffer.len, std.math.maxInt(windows.ULONG)));
    const initial_status = windows.ntdll.NtReadFile(
        file.handle,
        event,
        null,
        null,
        &io_status,
        buffer.ptr,
        read_len,
        &signed_offset,
        null,
    );
    if (initial_status == .PENDING) {
        switch (windows.ntdll.NtWaitForSingleObject(event, .FALSE, null)) {
            .WAIT_0 => {},
            else => |status| return windows.unexpectedStatus(status),
        }
    } else if (initial_status != .SUCCESS and initial_status != .END_OF_FILE) {
        return windows.unexpectedStatus(initial_status);
    }

    const final_status = if (initial_status == .PENDING) io_status.u.Status else initial_status;
    return switch (final_status) {
        .SUCCESS => io_status.Information,
        .END_OF_FILE => 0,
        .ACCESS_DENIED => error.AccessDenied,
        .INVALID_HANDLE => error.NotOpenForReading,
        .FILE_LOCK_CONFLICT => error.LockViolation,
        else => |status| windows.unexpectedStatus(status),
    };
}

fn writeAt(file: std.Io.File, buffer: []const u8, offset: u64) !usize {
    if (builtin.os.tag == .windows) return writeAtWindows(file, buffer, offset);
    return file.writePositional(io, &.{buffer}, offset);
}

fn writeAtWindows(file: std.Io.File, buffer: []const u8, offset: u64) !usize {
    const windows = std.os.windows;
    if (buffer.len == 0) return 0;

    var event: windows.HANDLE = undefined;
    switch (windows.ntdll.NtCreateEvent(
        &event,
        windows.ACCESS_MASK.Specific.Event.ALL_ACCESS,
        null,
        .Synchronization,
        .FALSE,
    )) {
        .SUCCESS => {},
        else => |status| return windows.unexpectedStatus(status),
    }
    defer windows.CloseHandle(event);

    var io_status: windows.IO_STATUS_BLOCK = undefined;
    const signed_offset: windows.LARGE_INTEGER = @intCast(offset);
    const write_len: windows.ULONG = @intCast(@min(buffer.len, std.math.maxInt(windows.ULONG)));
    const initial_status = windows.ntdll.NtWriteFile(
        file.handle,
        event,
        null,
        null,
        &io_status,
        buffer.ptr,
        write_len,
        &signed_offset,
        null,
    );
    if (initial_status == .PENDING) {
        switch (windows.ntdll.NtWaitForSingleObject(event, .FALSE, null)) {
            .WAIT_0 => {},
            else => |status| return windows.unexpectedStatus(status),
        }
    } else if (initial_status != .SUCCESS) {
        return windows.unexpectedStatus(initial_status);
    }

    const final_status = if (initial_status == .PENDING) io_status.u.Status else initial_status;
    return switch (final_status) {
        .SUCCESS => io_status.Information,
        .ACCESS_DENIED => error.AccessDenied,
        .INVALID_HANDLE => error.NotOpenForWriting,
        .FILE_LOCK_CONFLICT => error.LockViolation,
        .DISK_FULL => error.NoSpaceLeft,
        else => |status| windows.unexpectedStatus(status),
    };
}

/// Resolves a workspace-relative file without ever following a directory
/// symlink. The returned parent handle stays bound even if path names change.
pub fn openFileCapability(root_path: []const u8, relative_path: []const u8) !FileCapability {
    return openFileCapabilityMode(root_path, relative_path, .existing_parents);
}

pub fn openFileCapabilityCreateParents(root_path: []const u8, relative_path: []const u8) !FileCapability {
    return openFileCapabilityMode(root_path, relative_path, .create_parents);
}

/// Opens a workspace-relative directory for iteration while refusing every
/// symlink in the path. The returned handle remains anchored to the workspace.
pub fn openDirectoryCapability(root_path: []const u8, relative_path: []const u8) !std.Io.Dir {
    try validateRelativeFilePath(relative_path);
    if (!std.fs.path.isAbsolute(root_path)) return error.WorkspaceRootNotAbsolute;

    var current = try openDirectoryAbsoluteNoFollow(root_path, false);
    errdefer current.close(io);

    var components = std.mem.splitAny(u8, relative_path, "/\\");
    while (components.next()) |component| {
        const next = try openDirectoryNoFollow(current, component, true);
        current.close(io);
        current = next;
    }
    return current;
}

pub fn createDirectoryPath(root_path: []const u8, relative_path: []const u8) !void {
    var capability = try openFileCapabilityMode(root_path, relative_path, .create_parents);
    defer capability.close();
    try std.Io.Dir.createDir(capability.parent, io, capability.name, .default_dir);
}

pub fn renamePathPreserve(
    root_path: []const u8,
    source_path: []const u8,
    destination_path: []const u8,
) !std.Io.File.Kind {
    var source = try openFileCapability(root_path, source_path);
    defer source.close();
    const source_stat = try source.statNoFollow();
    if (source_stat.kind != .file and source_stat.kind != .directory) return error.UnsupportedWorkspacePath;

    var destination = try openFileCapability(root_path, destination_path);
    defer destination.close();
    try std.Io.Dir.renamePreserve(
        source.parent,
        source.name,
        destination.parent,
        destination.name,
        io,
    );
    return source_stat.kind;
}

pub const DeletedKind = enum { file, directory };

pub fn deleteFileOrEmptyDirectory(root_path: []const u8, relative_path: []const u8) !DeletedKind {
    var capability = try openFileCapability(root_path, relative_path);
    defer capability.close();
    const stat = try capability.statNoFollow();
    return switch (stat.kind) {
        .file => deleted: {
            try std.Io.Dir.deleteFile(capability.parent, io, capability.name);
            break :deleted .file;
        },
        .directory => deleted: {
            try std.Io.Dir.deleteDir(capability.parent, io, capability.name);
            break :deleted .directory;
        },
        else => error.UnsupportedWorkspacePath,
    };
}

const ParentMode = enum { existing_parents, create_parents };

fn openFileCapabilityMode(
    root_path: []const u8,
    relative_path: []const u8,
    mode: ParentMode,
) !FileCapability {
    try validateRelativeFilePath(relative_path);
    if (!std.fs.path.isAbsolute(root_path)) return error.WorkspaceRootNotAbsolute;

    var current = try openDirectoryAbsoluteNoFollow(root_path, false);
    errdefer current.close(io);

    const separator_index = std.mem.lastIndexOfAny(u8, relative_path, "/\\");
    const parent_path = if (separator_index) |index| relative_path[0..index] else "";
    const name = if (separator_index) |index| relative_path[index + 1 ..] else relative_path;

    var components = std.mem.splitAny(u8, parent_path, "/\\");
    while (components.next()) |component| {
        if (component.len == 0) continue;
        const next = openDirectoryNoFollow(current, component, false) catch |err| opened: {
            if (mode != .create_parents or err != error.FileNotFound) return err;
            std.Io.Dir.createDir(current, io, component, .default_dir) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return create_err,
            };
            break :opened try openDirectoryNoFollow(current, component, false);
        };
        current.close(io);
        current = next;
    }

    return .{ .parent = current, .name = name };
}

pub fn relativeFilePath(root_path: []const u8, absolute_path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(root_path) or !std.fs.path.isAbsolute(absolute_path)) {
        return error.WorkspacePathNotAbsolute;
    }

    var root_len = root_path.len;
    while (root_len > 1 and isPathSeparator(root_path[root_len - 1])) root_len -= 1;
    if (absolute_path.len <= root_len or !pathPrefixEqual(absolute_path[0..root_len], root_path[0..root_len])) {
        return error.PathOutsideWorkspace;
    }

    const relative_start = if (root_len == 1 and isPathSeparator(root_path[0]))
        root_len
    else start: {
        if (!isPathSeparator(absolute_path[root_len])) return error.PathOutsideWorkspace;
        break :start root_len + 1;
    };
    const relative = absolute_path[relative_start..];
    try validateRelativeFilePath(relative);
    return relative;
}

pub fn absolutePathAlloc(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    relative_path: []const u8,
) ![]u8 {
    if (!std.fs.path.isAbsolute(root_path)) return error.WorkspaceRootNotAbsolute;
    try validateRelativeFilePath(relative_path);

    const normalized = try allocator.dupe(u8, relative_path);
    defer allocator.free(normalized);
    for (normalized) |*byte| {
        if (isPathSeparator(byte.*)) byte.* = std.fs.path.sep;
    }
    return std.fs.path.join(allocator, &.{ root_path, normalized });
}

pub fn validateRelativeFilePath(relative_path: []const u8) !void {
    if (relative_path.len == 0 or
        std.fs.path.isAbsolute(relative_path) or
        std.mem.indexOfScalar(u8, relative_path, 0) != null)
    {
        return error.InvalidWorkspacePath;
    }

    var components = std.mem.splitAny(u8, relative_path, "/\\");
    var component_count: usize = 0;
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..") or
            (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, component, ':') != null))
        {
            return error.InvalidWorkspacePath;
        }
        component_count += 1;
    }
    if (component_count == 0) return error.InvalidWorkspacePath;
}

fn pathPrefixEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (builtin.os.tag == .windows and isPathSeparator(left_byte) and isPathSeparator(right_byte)) continue;
        if (builtin.os.tag == .windows) {
            if (std.ascii.toLower(left_byte) != std.ascii.toLower(right_byte)) return false;
        } else if (left_byte != right_byte) return false;
    }
    return true;
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

test "workspace file paths reject traversal and ambiguous components" {
    try validateRelativeFilePath("src/main.zig");
    try validateRelativeFilePath("main.zig");
    try std.testing.expectError(error.InvalidWorkspacePath, validateRelativeFilePath(""));
    try std.testing.expectError(error.InvalidWorkspacePath, validateRelativeFilePath("../secret.txt"));
    try std.testing.expectError(error.InvalidWorkspacePath, validateRelativeFilePath("src/../secret.txt"));
    try std.testing.expectError(error.InvalidWorkspacePath, validateRelativeFilePath("src//main.zig"));
    try std.testing.expectError(error.InvalidWorkspacePath, validateRelativeFilePath("src/./main.zig"));
    try std.testing.expectError(error.InvalidWorkspacePath, validateRelativeFilePath("/outside.txt"));
}

test "workspace file capability reads a nested regular file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/nested/main.zig", .data = "const value = 42;\n" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    var capability = try openFileCapability(root_buffer[0..root_len], "src/nested/main.zig");
    defer capability.close();

    const bytes = try capability.readFileAlloc(std.testing.allocator, 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("const value = 42;\n", bytes);
}

test "absolute workspace file path converts to a validated relative path" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const absolute = try std.fs.path.join(std.testing.allocator, &.{ root_buffer[0..root_len], "src", "main.zig" });
    defer std.testing.allocator.free(absolute);
    const relative = try relativeFilePath(root_buffer[0..root_len], absolute);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ "src", "main.zig" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, relative);

    const outside = try std.fs.path.join(std.testing.allocator, &.{ root_buffer[0..root_len], "..", "outside.zig" });
    defer std.testing.allocator.free(outside);
    try std.testing.expectError(error.InvalidWorkspacePath, relativeFilePath(root_buffer[0..root_len], outside));

    const normalized = try absolutePathAlloc(std.testing.allocator, root_buffer[0..root_len], "src\\main.zig");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(absolute, normalized);
}

test "workspace file capability refuses an intermediate directory symlink" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = "secret" });
    tmp.dir.symLink(io, "outside", "linked", .{ .is_directory = true }) catch return;

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    if (openFileCapability(root_buffer[0..root_len], "linked/secret.txt")) |capability_value| {
        var capability = capability_value;
        capability.close();
        return error.TestUnexpectedResult;
    } else |_| {}

    if (openDirectoryCapability(root_buffer[0..root_len], "linked")) |directory_value| {
        directory_value.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "workspace mutation capabilities create rename and delete without absolute paths" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    try createDirectoryPath(root, "src/nested");
    {
        var file = try openFileCapabilityCreateParents(root, "src/nested/main.zig");
        defer file.close();
        try file.parent.writeFile(io, .{ .sub_path = file.name, .data = "const value = 1;\n" });
    }

    try std.testing.expectEqual(
        std.Io.File.Kind.file,
        try renamePathPreserve(root, "src/nested/main.zig", "src/nested/lib.zig"),
    );
    {
        var renamed = try openFileCapability(root, "src/nested/lib.zig");
        defer renamed.close();
        const bytes = try renamed.readFileAlloc(std.testing.allocator, 1024);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("const value = 1;\n", bytes);
    }

    try std.testing.expectEqual(DeletedKind.file, try deleteFileOrEmptyDirectory(root, "src/nested/lib.zig"));
    try std.testing.expectEqual(DeletedKind.directory, try deleteFileOrEmptyDirectory(root, "src/nested"));
}
