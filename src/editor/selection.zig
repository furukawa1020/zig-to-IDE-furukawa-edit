const types = @import("../core/types.zig");

pub const Selection = struct {
    anchor: types.Position,
    cursor: types.Position,

    pub fn isEmpty(self: Selection) bool {
        return self.anchor.byte_offset == self.cursor.byte_offset;
    }
};

