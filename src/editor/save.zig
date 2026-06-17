const std = @import("std");

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
    if (!strategy.atomic) {
        try writeDirect(destination, bytes);
        return;
    }

    const temporary_path = try std.fmt.allocPrint(allocator, "{s}.zide-tmp", .{destination});
    defer allocator.free(temporary_path);

    if (strategy.backup_before_overwrite) {
        try createBackup(allocator, destination);
    }

    {
        var file = try createFile(temporary_path);
        defer file.close(std.Options.debug_io);
        try writeFileBytes(file, bytes);
    }

    try renameFile(temporary_path, destination);
}

fn writeDirect(path: []const u8, bytes: []const u8) !void {
    var file = try createFile(path);
    defer file.close(std.Options.debug_io);
    try writeFileBytes(file, bytes);
}

fn createBackup(allocator: std.mem.Allocator, destination: []const u8) !void {
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak", .{destination});
    defer allocator.free(backup_path);

    const bytes = readFile(allocator, destination) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);
    try writeDirect(backup_path, bytes);
}

fn createFile(path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
    }
    return std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{ .truncate = true });
}

fn renameFile(source: []const u8, destination: []const u8) !void {
    if (std.fs.path.isAbsolute(source) or std.fs.path.isAbsolute(destination)) {
        return std.Io.Dir.renameAbsolute(source, destination, std.Options.debug_io);
    }
    return std.Io.Dir.rename(std.Io.Dir.cwd(), source, std.Io.Dir.cwd(), destination, std.Options.debug_io);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(128 * 1024 * 1024));
}

fn writeFileBytes(file: std.Io.File, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.Options.debug_io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try file.sync(std.Options.debug_io);
}
