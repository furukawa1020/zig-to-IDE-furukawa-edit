const std = @import("std");
const gui = @import("gui/win32.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const root_path = if (args.len > 1) args[1] else ".";
    try gui.run(allocator, root_path);
}

