const std = @import("std");
const modes = @import("../language/modes.zig");
const registry = @import("registry.zig");

pub const Plan = struct {
    available: bool,
    language: modes.LanguageMode,
    label: []const u8,
    command: []u8,
    install_hint: []const u8,
    security_note: []const u8,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        self.* = undefined;
    }
};

pub fn forLanguage(allocator: std.mem.Allocator, language: modes.LanguageMode) !Plan {
    const server = registry.serverForLanguage(language) orelse return .{
        .available = false,
        .language = language,
        .label = "none",
        .command = try allocator.dupe(u8, ""),
        .install_hint = "No default LSP mapping yet for this language.",
        .security_note = "no external language server selected",
    };

    return .{
        .available = true,
        .language = language,
        .label = server.label,
        .command = try registry.commandLine(allocator, server),
        .install_hint = server.install_hint,
        .security_note = server.security_note,
    };
}

pub fn render(allocator: std.mem.Allocator, plan: Plan) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "LSP plan language:{s} server:{s} command:{s} consent:required note:{s} hint:{s}",
        .{
            modes.label(plan.language),
            plan.label,
            if (plan.command.len == 0) "(none)" else plan.command,
            plan.security_note,
            plan.install_hint,
        },
    );
}

test "render Zig LSP launch plan" {
    var plan = try forLanguage(std.testing.allocator, .zig);
    defer plan.deinit(std.testing.allocator);

    const text = try render(std.testing.allocator, plan);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "server:ZLS") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "consent:required") != null);
}
