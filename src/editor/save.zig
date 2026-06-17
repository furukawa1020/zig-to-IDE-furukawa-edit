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
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }

    try renameFile(temporary_path, destination);
}

fn writeDirect(path: []const u8, bytes: []const u8) !void {
    var file = try createFile(path);
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
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

fn createFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, .{ .truncate = true });
    }
    return std.fs.cwd().createFile(path, .{ .truncate = true });
}

fn renameFile(source: []const u8, destination: []const u8) !void {
    if (std.fs.path.isAbsolute(source) or std.fs.path.isAbsolute(destination)) {
        return std.fs.renameAbsolute(source, destination);
    }
    return std.fs.cwd().rename(source, destination);
}

fn openFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{});
    }
    return std.fs.cwd().openFile(path, .{});
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try openFile(path);
    defer file.close();
    return file.readToEndAlloc(allocator, 128 * 1024 * 1024);
}
