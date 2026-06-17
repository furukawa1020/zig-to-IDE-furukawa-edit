const std = @import("std");

pub const Style = struct {
    fg: u8 = 7,
    bg: u8 = 0,
    bold: bool = false,
    inverse: bool = false,
};

pub const Cell = struct {
    char: u21 = ' ',
    style: Style = .{},
};

pub const Screen = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    cells: []Cell,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Screen {
        const count = @as(usize, width) * @as(usize, height);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .cells = try allocator.alloc(Cell, count),
        };
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

