pub const ZigToolchain = struct {
    executable: []const u8 = "zig",
    version: ?[]const u8 = null,
    std_path: ?[]const u8 = null,
    cache_path: ?[]const u8 = null,
};

pub const ToolchainStatus = union(enum) {
    missing,
    detected: ZigToolchain,
    unsupported: []const u8,
};

