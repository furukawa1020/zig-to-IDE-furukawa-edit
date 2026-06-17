const std = @import("std");
const console = @import("console.zig");
const execution_queue = @import("execution_queue.zig");

pub const PreviewResult = enum {
    rendered,
    empty_queue,
};

pub fn previewLatest(queue: *const execution_queue.Queue, process_console: *console.ProcessConsole) !PreviewResult {
    const ticket = queue.latest() orelse return .empty_queue;

    var text = std.ArrayList(u8).init(process_console.allocator);
    defer text.deinit();
    const writer = text.writer();

    try writer.writeAll("launch plan\n");
    try writer.print("source: {s}\n", .{ticket.source_command_id});
    try writer.print("command: {s}\n", .{ticket.display_command});
    try writer.print("cwd: {s}\n", .{ticket.cwd});
    try writer.print("env: {s}\n", .{@tagName(ticket.env_policy)});
    try writer.print("fs: {s}\n", .{@tagName(ticket.fs_policy)});
    try writer.print("network: {s}\n", .{@tagName(ticket.network_policy)});
    try writer.print("output_sanitized: {}\n", .{ticket.output_sanitized});

    try process_console.appendBytes(.stdout, text.items);
    return .rendered;
}

test "executor renders latest queued launch plan" {
    var queue = execution_queue.Queue.init(std.testing.allocator);
    defer queue.deinit();
    var process_console = console.ProcessConsole.init(std.testing.allocator);
    defer process_console.deinit();

    try queue.enqueueSpec("zig.build", .{
        .command = .{
            .executable = "zig",
            .args = &.{ "build" },
            .cwd = ".",
        },
    }, .{
        .command = "zig build",
        .cwd = ".",
        .env_policy = .allowlist,
        .fs_policy = .workspace_only,
        .network_policy = .deny,
        .output_sanitized = true,
    });

    try std.testing.expectEqual(PreviewResult.rendered, try previewLatest(&queue, &process_console));
    try std.testing.expect(process_console.lines.items.len > 0);
}
