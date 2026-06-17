pub const Color = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
};

pub const Theme = struct {
    name: []const u8 = "default",
    foreground: Color = .white,
    background: Color = .black,
    accent: Color = .cyan,
    error_color: Color = .red,
    warning: Color = .yellow,
    success: Color = .green,
};
