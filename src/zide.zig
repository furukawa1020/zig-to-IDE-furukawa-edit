const std = @import("std");

pub const cli = @import("cli.zig");
pub const app = @import("core/app.zig");
pub const command = @import("core/command.zig");
pub const demo = @import("core/demo.zig");
pub const buffer = @import("editor/buffer.zig");
pub const modes = @import("language/modes.zig");
pub const zig_tokenizer = @import("language/zig_tokenizer.zig");
pub const render = @import("ui/render.zig");
pub const workspace = @import("workspace/workspace.zig");

pub fn run(
    allocator: std.mem.Allocator,
    options: cli.Options,
    stdout: anytype,
    stderr: anytype,
) !void {
    switch (options.action) {
        .open => |path| {
            var instance = app.App.init(allocator, path) catch |err| {
                try stderr.print("zide: workspace open failed for '{s}': {s}\n", .{ path, @errorName(err) });
                return err;
            };
            defer instance.deinit();
            try instance.render(stdout);
        },
        .demo => |kind| try demo.run(allocator, kind, stdout),
        .commands => try render.renderCommands(stdout),
        .version => try stdout.print("zide 0.1.0-dev\n", .{}),
        .help => try render.renderHelp(stdout),
    }
}

