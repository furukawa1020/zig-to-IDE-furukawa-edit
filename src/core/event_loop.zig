const std = @import("std");
const event = @import("event.zig");

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList(event.Event),
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator) EventLoop {
        return .{
            .allocator = allocator,
            .queue = std.ArrayList(event.Event).init(allocator),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.queue.deinit();
        self.* = undefined;
    }

    pub fn push(self: *EventLoop, item: event.Event) !void {
        try self.queue.append(item);
    }

    pub fn pop(self: *EventLoop) ?event.Event {
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    pub fn requestRender(self: *EventLoop) !void {
        try self.push(.render_requested);
    }
};

test "event loop preserves event order" {
    var loop = EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    try loop.push(.render_requested);
    try loop.push(.shutdown);

    try std.testing.expect(std.meta.activeTag(loop.pop().?) == .render_requested);
    try std.testing.expect(std.meta.activeTag(loop.pop().?) == .shutdown);
}
