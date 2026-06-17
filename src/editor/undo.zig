const types = @import("../core/types.zig");

pub const EditKind = enum {
    insert,
    delete,
    replace,
};

pub const Edit = struct {
    kind: EditKind,
    range: types.Range,
    before: []const u8,
    after: []const u8,
};

pub const Transaction = struct {
    label: []const u8,
    edits: []const Edit,
};

