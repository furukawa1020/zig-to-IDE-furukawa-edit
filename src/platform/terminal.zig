pub const ColorCapability = enum {
    monochrome,
    ansi16,
    ansi256,
    truecolor,
};

pub const TerminalCapabilities = struct {
    width: u16 = 80,
    height: u16 = 24,
    colors: ColorCapability = .ansi16,
    alternate_screen: bool = true,
    bracketed_paste: bool = true,
    mouse: bool = false,
};

