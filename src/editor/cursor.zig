const types = @import("../core/types.zig");

pub const Cursor = struct {
    position: types.Position = types.Position.start(),
    preferred_column: types.Column = 0,
};

