const std = @import("std");

pub const Stream = enum {
    stdout,
    stderr,
};

pub const Line = struct {
    stream: Stream,
    text: []u8,

    fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const ProcessConsole = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(Line),
    running: bool = false,
    exit_code: ?i32 = null,
    max_lines: usize = 2000,

    pub fn init(allocator: std.mem.Allocator) ProcessConsole {
        return .{
            .allocator = allocator,
            .lines = std.ArrayList(Line).init(allocator),
        };
    }

    pub fn deinit(self: *ProcessConsole) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *ProcessConsole) void {
        self.clear();
        self.running = true;
        self.exit_code = null;
    }

    pub fn finish(self: *ProcessConsole, exit_code: i32) void {
        self.running = false;
        self.exit_code = exit_code;
    }

    pub fn appendBytes(self: *ProcessConsole, stream: Stream, bytes: []const u8) !void {
        var iter = std.mem.splitScalar(u8, bytes, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            try self.appendLine(stream, std.mem.trimRight(u8, line, "\r"));
        }
    }

    pub fn clear(self: *ProcessConsole) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.clearRetainingCapacity();
    }

    fn appendLine(self: *ProcessConsole, stream: Stream, text: []const u8) !void {
        if (self.lines.items.len >= self.max_lines) {
            var first = self.lines.orderedRemove(0);
            first.deinit(self.allocator);
        }
        try self.lines.append(.{
            .stream = stream,
            .text = try self.allocator.dupe(u8, text),
        });
    }
};

test "console stores output lines" {
    var console = ProcessConsole.init(std.testing.allocator);
    defer console.deinit();

    try console.appendBytes(.stdout, "one\ntwo\n");
    try std.testing.expectEqual(@as(usize, 2), console.lines.items.len);
    try std.testing.expectEqualStrings("two", console.lines.items[1].text);
}

