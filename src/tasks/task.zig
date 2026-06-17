pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const Task = struct {
    name: []const u8,
    command: []const u8,
    cwd: ?[]const u8 = null,
    env: []const EnvVar = &.{},
};

pub const TaskState = enum {
    idle,
    running,
    succeeded,
    failed,
    cancelled,
};

