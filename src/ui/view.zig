pub const ViewId = enum {
    editor,
    file_tree,
    symbol_outline,
    diagnostics,
    build_output,
    search,
    command_palette,
    quickfix,
    notifications,
    debug,
};

pub const ViewState = struct {
    id: ViewId,
    visible: bool = true,
    focused: bool = false,
};

