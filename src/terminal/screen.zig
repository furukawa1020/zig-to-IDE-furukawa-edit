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
        var self = Screen{
            .allocator = allocator,
            .width = width,
            .height = height,
            .cells = try allocator.alloc(Cell, count),
        };
        self.clear(.{});
        return self;
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn clear(self: *Screen, style: Style) void {
        for (self.cells) |*cell| {
            cell.* = .{ .char = ' ', .style = style };
        }
    }

    pub fn setCell(self: *Screen, x: u16, y: u16, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[indexOf(self.width, x, y)] = cell;
    }

    pub fn writeText(self: *Screen, x: u16, y: u16, text: []const u8, style: Style) void {
        var column = x;
        for (text) |byte| {
            if (column >= self.width) break;
            if (byte < 0x20) continue;
            self.setCell(column, y, .{ .char = @as(u21, byte), .style = style });
            column += 1;
        }
    }
};

fn indexOf(width: u16, x: u16, y: u16) usize {
    return @as(usize, y) * @as(usize, width) + @as(usize, x);
}

test "screen write text updates cells" {
    var screen = try Screen.init(std.testing.allocator, 10, 2);
    defer screen.deinit();

    screen.writeText(1, 1, "zide", .{});
    try std.testing.expectEqual(@as(u21, 'z'), screen.cells[indexOf(10, 1, 1)].char);
    try std.testing.expectEqual(@as(u21, 'e'), screen.cells[indexOf(10, 4, 1)].char);
}
