pub const Binding = struct {
    key: []const u8,
    command_id: []const u8,
};

pub const Keymap = struct {
    name: []const u8,
    bindings: []const Binding = &.{},
};

