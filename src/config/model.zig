pub const EditorConfig = struct {
    tab_width: u8 = 4,
    insert_spaces: bool = true,
    format_on_save: bool = false,
};

pub const ThemeConfig = struct {
    name: []const u8 = "default",
};

pub const Config = struct {
    version: u32 = 1,
    editor: EditorConfig = .{},
    theme: ThemeConfig = .{},
};

