const modes = @import("../language/modes.zig");

pub const NodeKind = enum {
    file,
    directory,
    symlink,
    other,
};

pub const Node = struct {
    name: []const u8,
    kind: NodeKind,
    language: modes.LanguageMode = .unknown,
    git_dirty: bool = false,
    has_diagnostics: bool = false,
};

