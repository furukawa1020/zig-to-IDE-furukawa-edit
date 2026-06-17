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

