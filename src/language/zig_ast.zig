const types = @import("../core/types.zig");

pub const NodeTag = enum {
    root,
    container_decl,
    function_decl,
    variable_decl,
    test_block,
    import_expr,
    invalid,
    incomplete,
};

pub const Node = struct {
    tag: NodeTag,
    range: types.Range,
    parent: ?usize = null,
    first_child: ?usize = null,
    next_sibling: ?usize = null,
};

pub const Ast = struct {
    nodes: []const Node,
    source: []const u8,
};

