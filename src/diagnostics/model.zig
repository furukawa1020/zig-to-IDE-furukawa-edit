const types = @import("../core/types.zig");

pub const DiagnosticSource = enum {
    parser,
    compiler,
    build,
    test_runner,
    config,
    internal,
};

pub const Diagnostic = struct {
    source: DiagnosticSource,
    severity: types.Severity,
    path: []const u8,
    range: types.Range,
    message: []const u8,
};

pub const Collection = struct {
    items: []const Diagnostic = &.{},
};

