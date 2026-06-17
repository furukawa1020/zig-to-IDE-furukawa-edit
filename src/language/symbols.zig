const types = @import("../core/types.zig");

pub const SymbolKind = enum {
    package,
    file,
    import_alias,
    constant,
    variable,
    function,
    parameter,
    local,
    struct_type,
    struct_field,
    enum_type,
    enum_field,
    union_type,
    union_field,
    error_set,
    error_value,
    test_block,
    builtin,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    file_path: []const u8,
    range: types.Range,
    doc_comment: ?[]const u8 = null,
};

pub const SymbolIndex = struct {
    symbols: []const Symbol = &.{},
};

