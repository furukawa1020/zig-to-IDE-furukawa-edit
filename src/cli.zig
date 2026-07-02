const std = @import("std");

pub const DemoName = enum {
    overview,
    architecture,
    languages,
    commands,
    editor,
    palette,
    dispatch,
    diagnostics,
    input,
    loop,
    screen,
    security,
    extensions,
    buffer,
    zig_tokens,
};

pub const Action = union(enum) {
    open: []const u8,
    demo: DemoName,
    commands,
    version,
    help,
};

pub const Options = struct {
    action: Action,
};

pub fn parse(args: anytype) Options {
    if (args.len <= 1) {
        return .{ .action = .{ .open = "." } };
    }

    const first = args[1];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "help")) {
        return .{ .action = .help };
    }
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "version")) {
        return .{ .action = .version };
    }
    if (std.mem.eql(u8, first, "commands")) {
        return .{ .action = .commands };
    }
    if (std.mem.eql(u8, first, "demo")) {
        if (args.len <= 2) {
            return .{ .action = .{ .demo = .overview } };
        }
        return .{ .action = .{ .demo = parseDemoName(args[2]) orelse .overview } };
    }

    return .{ .action = .{ .open = first } };
}

fn parseDemoName(raw: []const u8) ?DemoName {
    if (std.mem.eql(u8, raw, "overview")) return .overview;
    if (std.mem.eql(u8, raw, "architecture")) return .architecture;
    if (std.mem.eql(u8, raw, "arch")) return .architecture;
    if (std.mem.eql(u8, raw, "languages")) return .languages;
    if (std.mem.eql(u8, raw, "commands")) return .commands;
    if (std.mem.eql(u8, raw, "editor")) return .editor;
    if (std.mem.eql(u8, raw, "palette")) return .palette;
    if (std.mem.eql(u8, raw, "dispatch")) return .dispatch;
    if (std.mem.eql(u8, raw, "diagnostics")) return .diagnostics;
    if (std.mem.eql(u8, raw, "input")) return .input;
    if (std.mem.eql(u8, raw, "loop")) return .loop;
    if (std.mem.eql(u8, raw, "screen")) return .screen;
    if (std.mem.eql(u8, raw, "security")) return .security;
    if (std.mem.eql(u8, raw, "extensions")) return .extensions;
    if (std.mem.eql(u8, raw, "extension")) return .extensions;
    if (std.mem.eql(u8, raw, "buffer")) return .buffer;
    if (std.mem.eql(u8, raw, "zig-tokens")) return .zig_tokens;
    if (std.mem.eql(u8, raw, "zig_tokens")) return .zig_tokens;
    return null;
}

test "parse defaults to current workspace" {
    const options = parse(&.{ "zide" });
    switch (options.action) {
        .open => |path| try std.testing.expectEqualStrings(".", path),
        else => return error.ExpectedOpenAction,
    }
}

test "parse demo names" {
    const options = parse(&.{ "zide", "demo", "buffer" });
    switch (options.action) {
        .demo => |name| try std.testing.expect(name == .buffer),
        else => return error.ExpectedDemoAction,
    }
}
