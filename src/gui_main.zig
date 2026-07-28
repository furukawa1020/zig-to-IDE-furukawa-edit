const std = @import("std");
const builtin = @import("builtin");

const gui = switch (builtin.os.tag) {
    .windows => @import("gui/win32.zig"),
    .linux => @import("gui/linux_x11.zig"),
    else => @compileError("zide-gui currently supports Windows and Linux"),
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const root_path = if (args.len > 1) args[1] else ".";
    switch (builtin.os.tag) {
        .windows => try gui.run(allocator, root_path, init.minimal.environ),
        .linux => try gui.run(allocator, root_path, init.minimal.environ, init.environ_map),
        else => unreachable,
    }
}
