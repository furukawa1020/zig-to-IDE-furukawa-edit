const std = @import("std");

pub const DemoName = enum {
    overview,
    languages,
    commands,
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

pub fn parse(args: []const []const u8) Options {
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
    if (std.mem.eql(u8, raw, "languages")) return .languages;
    if (std.mem.eql(u8, raw, "commands")) return .commands;
    if (std.mem.eql(u8, raw, "buffer")) return .buffer;
    if (std.mem.eql(u8, raw, "zig-tokens")) return .zig_tokens;
    if (std.mem.eql(u8, raw, "zig_tokens")) return .zig_tokens;
    return null;
}

test "parse defaults to current workspace" {
    const options = parse(&.{ "zide" });
    try std.testing.expectEqualStrings(".", options.action.open);
}

test "parse demo names" {
    const options = parse(&.{ "zide", "demo", "buffer" });
    try std.testing.expect(options.action.demo == .buffer);
}

