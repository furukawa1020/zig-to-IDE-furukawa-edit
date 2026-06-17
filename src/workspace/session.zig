const types = @import("../core/types.zig");

pub const OpenFile = struct {
    path: []const u8,
    cursor: types.Position = types.Position.start(),
    scroll_line: usize = 0,
};

pub const Session = struct {
    open_files: []const OpenFile = &.{},
    recent_commands: []const []const u8 = &.{},
    recent_files: []const []const u8 = &.{},
};

