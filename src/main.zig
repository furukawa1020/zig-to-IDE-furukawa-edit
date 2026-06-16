const std = @import("std");
const zide = @import("zide.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = zide.cli.parse(args);
    var stdout = std.io.getStdOut().writer();
    var stderr = std.io.getStdErr().writer();

    try zide.run(allocator, options, stdout, stderr);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("zide.zig");
    _ = @import("cli.zig");
    _ = @import("core/app.zig");
    _ = @import("core/command.zig");
    _ = @import("core/demo.zig");
    _ = @import("editor/buffer.zig");
    _ = @import("language/modes.zig");
    _ = @import("language/zig_tokenizer.zig");
    _ = @import("ui/render.zig");
    _ = @import("workspace/workspace.zig");
}

