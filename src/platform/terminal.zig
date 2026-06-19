const std = @import("std");
const builtin = @import("builtin");

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

pub const RawMode = struct {
    active: bool = false,
    original_mode: if (builtin.os.tag == .windows) std.os.windows.DWORD else void = if (builtin.os.tag == .windows) 0 else {},

    pub fn enable(stdin: std.Io.File) RawMode {
        if (builtin.os.tag != .windows) return .{};
        return enableWindows(stdin) catch .{};
    }

    pub fn restore(self: RawMode, stdin: std.Io.File) void {
        if (builtin.os.tag != .windows or !self.active) return;
        restoreWindows(stdin, self.original_mode);
    }
};

pub fn enableAnsi(stdout: std.Io.File, io: std.Io) void {
    stdout.enableAnsiEscapeCodes(io) catch {};
}

pub fn isInteractive(stdin: std.Io.File, stdout: std.Io.File, io: std.Io) bool {
    const input_tty = stdin.isTty(io) catch false;
    const output_tty = stdout.isTty(io) catch false;
    return input_tty and output_tty;
}

fn enableWindows(stdin: std.Io.File) !RawMode {
    const windows = std.os.windows;
    var mode: windows.DWORD = 0;
    if (!GetConsoleMode(stdin.handle, &mode).toBool()) return error.ConsoleModeUnavailable;

    var raw = mode;
    raw &= ~@as(windows.DWORD, enable_echo_input | enable_line_input | enable_processed_input | enable_quick_edit_mode);
    raw |= enable_virtual_terminal_input | enable_extended_flags;
    if (!SetConsoleMode(stdin.handle, raw).toBool()) return error.ConsoleModeUnavailable;

    return .{
        .active = true,
        .original_mode = mode,
    };
}

fn restoreWindows(stdin: std.Io.File, original_mode: std.os.windows.DWORD) void {
    _ = SetConsoleMode(stdin.handle, original_mode);
}

const enable_processed_input: u32 = 0x0001;
const enable_line_input: u32 = 0x0002;
const enable_echo_input: u32 = 0x0004;
const enable_virtual_terminal_input: u32 = 0x0200;
const enable_quick_edit_mode: u32 = 0x0040;
const enable_extended_flags: u32 = 0x0080;

extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: std.os.windows.HANDLE,
    lpMode: *std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn SetConsoleMode(
    hConsoleHandle: std.os.windows.HANDLE,
    dwMode: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

test "terminal defaults are usable" {
    const caps = TerminalCapabilities{};
    try std.testing.expect(caps.width > 0);
    try std.testing.expect(caps.height > 0);
}
