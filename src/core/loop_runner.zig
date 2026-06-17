const app_mod = @import("app.zig");
const event = @import("event.zig");
const event_loop = @import("event_loop.zig");
const input_handler = @import("input_handler.zig");

pub const StepResult = struct {
    handled: usize = 0,
    redraw_requested: bool = false,
    shutdown_requested: bool = false,
};

pub fn drain(app: *app_mod.App, loop: *event_loop.EventLoop) !StepResult {
    var result = StepResult{};
    while (loop.pop()) |item| {
        result.handled += 1;
        switch (item) {
            .shutdown => {
                result.shutdown_requested = true;
                break;
            },
            .render_requested => result.redraw_requested = true,
            else => {
                const outcome = try input_handler.handle(app, item);
                switch (outcome) {
                    .ignored => {},
                    .redraw => result.redraw_requested = true,
                    .command_result => result.redraw_requested = true,
                }
            },
        }
    }
    return result;
}

pub fn pushInputBytes(loop: *event_loop.EventLoop, bytes: []const u8) !void {
    const decoded = @import("../terminal/input.zig").InputDecoder.decode(bytes);
    switch (decoded) {
        .event => |item| try loop.push(item),
        .need_more => {},
        .invalid => {},
    }
}

test "loop runner drains key input" {
    var app = try app_mod.App.init(@import("std").testing.allocator, ".");
    defer app.deinit();
    var loop = event_loop.EventLoop.init(@import("std").testing.allocator);
    defer loop.deinit();

    try loop.push(.{ .key = .{ .code = .{ .char = 'p' }, .modifiers = .{ .ctrl = true } } });
    const result = try drain(&app, &loop);
    try @import("std").testing.expect(result.redraw_requested);
    try @import("std").testing.expect(app.palette.visible);
}
