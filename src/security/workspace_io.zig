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
    if (builtin.os.tag == .windows) file.flags.nonblocking = true;
    return file;
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
    if (after.kind != .file or after.inode != before.inode or after.size != before.size) {
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
    try validateRelativeFilePath(relative_path);
    if (!std.fs.path.isAbsolute(root_path)) return error.WorkspaceRootNotAbsolute;

    var current = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .follow_symlinks = false });
    errdefer current.close(io);

    const separator_index = std.mem.lastIndexOfAny(u8, relative_path, "/\\");
    const parent_path = if (separator_index) |index| relative_path[0..index] else "";
    const name = if (separator_index) |index| relative_path[index + 1 ..] else relative_path;

    var components = std.mem.splitAny(u8, parent_path, "/\\");
    while (components.next()) |component| {
        if (component.len == 0) continue;
        const next = try std.Io.Dir.openDir(current, io, component, .{ .follow_symlinks = false });
        current.close(io);
        current = next;
    }

    return .{ .parent = current, .name = name };
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
}
