const model = @import("model.zig");

pub const ParseDiagnostic = struct {
    message: []const u8,
    offset: usize,
};

pub const ParseResult = struct {
    config: model.Config,
    diagnostics: []const ParseDiagnostic = &.{},
};

pub fn parseConfig(source: []const u8) ParseResult {
    _ = source;
    return .{ .config = .{} };
}

