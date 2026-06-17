pub const Breakpoint = struct {
    path: []const u8,
    line: usize,
    enabled: bool = true,
    condition: ?[]const u8 = null,
    hit_count: ?usize = null,
};

pub const DebugState = enum {
    stopped,
    launching,
    running,
    paused,
    terminated,
};

pub const DebugSession = struct {
    executable: []const u8,
    state: DebugState = .stopped,
    breakpoints: []const Breakpoint = &.{},
};

