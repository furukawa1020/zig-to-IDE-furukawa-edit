const std = @import("std");
const sanitizer = @import("../security/output_sanitizer.zig");

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
    lines: std.array_list.Managed(Line),
    running: bool = false,
    exit_code: ?i32 = null,
    max_lines: usize = 2000,
    sanitized_stats: sanitizer.Stats = .{},

    pub fn init(allocator: std.mem.Allocator) ProcessConsole {
        return .{
            .allocator = allocator,
            .lines = std.array_list.Managed(Line).init(allocator),
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
        var sanitized = try sanitizer.sanitizeAlloc(self.allocator, bytes);
        defer sanitized.deinit(self.allocator);
        self.sanitized_stats.stripped_csi += sanitized.stats.stripped_csi;
        self.sanitized_stats.stripped_osc += sanitized.stats.stripped_osc;
        self.sanitized_stats.stripped_control += sanitized.stats.stripped_control;

        var iter = std.mem.splitScalar(u8, sanitized.text, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            try self.appendLine(stream, std.mem.trim(u8, line, "\r"));
        }
    }

    pub fn clear(self: *ProcessConsole) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.clearRetainingCapacity();
        self.sanitized_stats = .{};
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

test "console sanitizes terminal controls" {
    var console = ProcessConsole.init(std.testing.allocator);
    defer console.deinit();

    try console.appendBytes(.stderr, "bad\x1b[2Jstill visible\n");
    try std.testing.expectEqualStrings("badstill visible", console.lines.items[0].text);
    try std.testing.expectEqual(@as(usize, 1), console.sanitized_stats.stripped_csi);
}
