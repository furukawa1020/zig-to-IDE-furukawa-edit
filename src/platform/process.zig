const std = @import("std");

pub const StreamMode = enum {
    inherit,
    pipe,
    ignore,
};

pub const CommandLine = struct {
    executable: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
};

pub const SpawnSpec = struct {
    command: CommandLine,
    stdout: StreamMode = .pipe,
    stderr: StreamMode = .pipe,
    stdin: StreamMode = .ignore,
};

pub fn appendDisplay(allocator: std.mem.Allocator, command: CommandLine) ![]u8 {
    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();
    try list.appendSlice(command.executable);
    for (command.args) |arg| {
        try list.append(' ');
        try list.appendSlice(arg);
    }
    return list.toOwnedSlice();
}

