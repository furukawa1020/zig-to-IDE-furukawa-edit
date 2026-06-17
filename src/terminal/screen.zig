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

    pub fn writeTextClipped(self: *Screen, x: u16, y: u16, width: u16, text: []const u8, style: Style) void {
        if (width == 0) return;
        var column: u16 = 0;
        for (text) |byte| {
            if (column >= width) break;
            if (byte < 0x20) continue;
            self.setCell(x + column, y, .{ .char = @as(u21, byte), .style = style });
            column += 1;
        }
    }

    pub fn fillRect(self: *Screen, x: u16, y: u16, width: u16, height: u16, char: u21, style: Style) void {
        var row: u16 = 0;
        while (row < height) : (row += 1) {
            var column: u16 = 0;
            while (column < width) : (column += 1) {
                self.setCell(x + column, y + row, .{ .char = char, .style = style });
            }
        }
    }

    pub fn drawBox(self: *Screen, x: u16, y: u16, width: u16, height: u16, style: Style) void {
        if (width < 2 or height < 2) return;
        self.setCell(x, y, .{ .char = '+', .style = style });
        self.setCell(x + width - 1, y, .{ .char = '+', .style = style });
        self.setCell(x, y + height - 1, .{ .char = '+', .style = style });
        self.setCell(x + width - 1, y + height - 1, .{ .char = '+', .style = style });

        var column: u16 = 1;
        while (column + 1 < width) : (column += 1) {
            self.setCell(x + column, y, .{ .char = '-', .style = style });
            self.setCell(x + column, y + height - 1, .{ .char = '-', .style = style });
        }

        var row: u16 = 1;
        while (row + 1 < height) : (row += 1) {
            self.setCell(x, y + row, .{ .char = '|', .style = style });
            self.setCell(x + width - 1, y + row, .{ .char = '|', .style = style });
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

test "screen fill and box stay in bounds" {
    var screen = try Screen.init(std.testing.allocator, 6, 4);
    defer screen.deinit();

    screen.fillRect(1, 1, 3, 2, '.', .{});
    screen.drawBox(0, 0, 6, 4, .{});

    try std.testing.expectEqual(@as(u21, '+'), screen.cells[indexOf(6, 0, 0)].char);
    try std.testing.expectEqual(@as(u21, '.'), screen.cells[indexOf(6, 2, 1)].char);
}
