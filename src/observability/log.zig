const types = @import("../core/types.zig");

pub const LogLevel = enum {
    trace,
    debug,
    info,
    warning,
    err,
};

pub const LogRecord = struct {
    level: LogLevel,
    message: []const u8,
    source_range: ?types.Range = null,
};

