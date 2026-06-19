const std = @import("std");
const app_mod = @import("app.zig");
const input_handler = @import("input_handler.zig");
const platform_terminal = @import("../platform/terminal.zig");
const terminal_input = @import("../terminal/input.zig");
const terminal_renderer = @import("../terminal/renderer.zig");
const terminal_session = @import("../terminal/session.zig");
const tui = @import("../ui/tui.zig");

pub const Options = struct {
    width: u16 = 100,
    height: u16 = 30,
    max_events: ?usize = null,
};

pub const Result = struct {
    frames: usize = 0,
    events: usize = 0,
};

pub fn run(
    allocator: std.mem.Allocator,
    app: *app_mod.App,
    io: std.Io,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    writer: *std.Io.Writer,
    options: Options,
) !Result {
    platform_terminal.enableAnsi(stdout_file, io);
    const raw_mode = platform_terminal.RawMode.enable(stdin_file);
    defer raw_mode.restore(stdin_file);

    const session = terminal_session.TerminalSession{};
    try session.begin(writer);
    defer session.end(writer) catch {};
    try writer.flush();

    var result = Result{};
    try render(allocator, app, writer, options.width, options.height);
    result.frames += 1;
    try writer.flush();

    var read_buffer: [16]u8 = undefined;
    var stdin_reader = stdin_file.readerStreaming(io, &read_buffer);
    var input_buffer = std.array_list.Managed(u8).init(allocator);
    defer input_buffer.deinit();

    while (true) {
        if (options.max_events) |limit| {
            if (result.events >= limit) break;
        }

        const byte = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try input_buffer.append(byte);

        const decoded = terminal_input.InputDecoder.decode(input_buffer.items);
        switch (decoded) {
            .need_more => continue,
            .invalid => input_buffer.clearRetainingCapacity(),
            .event => |event| {
                input_buffer.clearRetainingCapacity();
                result.events += 1;
                if (std.meta.activeTag(event) == .shutdown) break;
                if (isNormalQuit(app, event)) break;
                const outcome = try input_handler.handle(app, event);
                switch (outcome) {
                    .ignored => {},
                    .redraw, .command_result => {
                        try render(allocator, app, writer, options.width, options.height);
                        result.frames += 1;
                        try writer.flush();
                    },
                }
            },
        }
    }

    return result;
}

fn isNormalQuit(app: *const app_mod.App, event: @import("event.zig").Event) bool {
    if (app.palette.visible or app.mode != .normal) return false;
    return switch (event) {
        .key => |key| switch (key.code) {
            .char => |char| char == 'q' or char == 'Q',
            else => false,
        },
        else => false,
    };
}

fn render(allocator: std.mem.Allocator, app: *const app_mod.App, writer: *std.Io.Writer, width: u16, height: u16) !void {
    var screen = try tui.renderApp(allocator, app, width, height);
    defer screen.deinit();
    try terminal_renderer.renderAnsi(writer, &screen);
}

test "interactive render can run zero events against an in-memory writer" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var screen = try tui.renderApp(std.testing.allocator, &app, 40, 12);
    defer screen.deinit();
    try terminal_renderer.renderAnsi(&output.writer, &screen);
    try std.testing.expect(output.written().len > 0);
}
