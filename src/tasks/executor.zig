const std = @import("std");
const console = @import("console.zig");
const execution_queue = @import("execution_queue.zig");
const permissions = @import("../security/permissions.zig");

pub const PreviewResult = enum {
    rendered,
    empty_queue,
};

pub const HistoryResult = enum {
    rendered,
    empty_history,
};

pub const RunOptions = struct {
    workspace_root: []const u8,
    io: std.Io = std.Options.debug_io,
    environ: std.process.Environ = std.process.Environ.empty,
    stdout_limit: usize = 512 * 1024,
    stderr_limit: usize = 512 * 1024,
};

pub const RunResult = union(enum) {
    ran: i32,
    empty_queue,
    blocked: []const u8,
    failed: []const u8,
};

pub fn previewLatest(queue: *const execution_queue.Queue, process_console: *console.ProcessConsole) !PreviewResult {
    const ticket = queue.latest() orelse return .empty_queue;

    var text: std.Io.Writer.Allocating = .init(process_console.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("launch plan\n");
    try writer.print("source: {s}\n", .{ticket.source_command_id});
    try writer.print("command: {s}\n", .{ticket.display_command});
    try writer.print("cwd: {s}\n", .{ticket.cwd});
    try writer.print("env: {s}\n", .{@tagName(ticket.env_policy)});
    try writer.print("fs: {s}\n", .{@tagName(ticket.fs_policy)});
    try writer.print("network: {s}\n", .{@tagName(ticket.network_policy)});
    try writer.print("output_sanitized: {}\n", .{ticket.output_sanitized});

    try process_console.appendBytes(.stdout, text.written());
    return .rendered;
}

pub fn renderHistory(queue: *const execution_queue.Queue, process_console: *console.ProcessConsole) !HistoryResult {
    if (queue.history.items.len == 0) return .empty_history;

    var text: std.Io.Writer.Allocating = .init(process_console.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("task history\n");
    for (queue.history.items, 0..) |entry, index| {
        try writer.print("{d}: {s} {s}", .{
            index + 1,
            @tagName(entry.state),
            entry.display_command,
        });
        if (entry.exit_code) |code| {
            try writer.print(" exit={d}", .{code});
        } else {
            try writer.writeAll(" exit=none");
        }
        try writer.print(" lines={d} sanitized={d} cwd={s}\n", .{
            entry.output_lines,
            entry.sanitized_controls,
            entry.cwd,
        });
    }

    try process_console.appendBytes(.stdout, text.written());
    return .rendered;
}

pub fn runNext(queue: *execution_queue.Queue, process_console: *console.ProcessConsole, options: RunOptions) !RunResult {
    var ticket = queue.takeNextQueued() orelse return .empty_queue;
    defer ticket.deinit();

    process_console.begin();
    if (!permissions.allowsWorkspacePath(ticket.fs_policy, options.workspace_root, ticket.cwd)) {
        const message = "approved command cwd is outside the permitted workspace boundary";
        try appendFormatted(process_console, .stderr, "blocked: {s}\n", .{message});
        process_console.finish(-1);
        try queue.recordHistory(&ticket, .blocked, -1, process_console.lines.items.len, process_console.sanitized_stats.total());
        return .{ .blocked = message };
    }

    if (looksNetworked(&ticket) and !permissions.allowsNetwork(ticket.network_policy)) {
        const message = "approved command looks networked but network policy is deny";
        try appendFormatted(process_console, .stderr, "blocked: {s}\n", .{message});
        process_console.finish(-1);
        try queue.recordHistory(&ticket, .blocked, -1, process_console.lines.items.len, process_console.sanitized_stats.total());
        return .{ .blocked = message };
    }

    var argv = try argvFromTicket(process_console.allocator, &ticket);
    defer argv.deinit();

    var env_map = try environmentMapForPolicy(process_console.allocator, options.environ, ticket.env_policy);
    defer if (env_map) |*map| map.deinit();
    const env_ptr: ?*const std.process.Environ.Map = if (env_map) |*map| map else null;

    try appendFormatted(process_console, .stdout, "$ {s}\n", .{ticket.display_command});
    if (ticket.env_policy != .inherit_all) {
        try appendFormatted(process_console, .stdout, "env policy: {s}\n", .{@tagName(ticket.env_policy)});
    }

    const result = std.process.run(process_console.allocator, options.io, .{
        .argv = argv.items,
        .cwd = .{ .path = ticket.cwd },
        .environ_map = env_ptr,
        .stdout_limit = .limited(options.stdout_limit),
        .stderr_limit = .limited(options.stderr_limit),
    }) catch |err| {
        try appendFormatted(process_console, .stderr, "spawn failed: {s}\n", .{@errorName(err)});
        process_console.finish(-1);
        try queue.recordHistory(&ticket, .failed, -1, process_console.lines.items.len, process_console.sanitized_stats.total());
        return .{ .failed = @errorName(err) };
    };
    defer process_console.allocator.free(result.stdout);
    defer process_console.allocator.free(result.stderr);

    try process_console.appendBytes(.stdout, result.stdout);
    try process_console.appendBytes(.stderr, result.stderr);
    const exit_code = termExitCode(result.term);
    process_console.finish(exit_code);
    try appendFormatted(process_console, .stdout, "exit: {d}\n", .{exit_code});
    try queue.recordHistory(&ticket, .finished, exit_code, process_console.lines.items.len, process_console.sanitized_stats.total());

    return .{ .ran = exit_code };
}

fn argvFromTicket(allocator: std.mem.Allocator, ticket: *const execution_queue.Ticket) !std.array_list.Managed([]const u8) {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    errdefer argv.deinit();
    try argv.append(ticket.executable);
    for (ticket.args.items) |arg| {
        try argv.append(arg);
    }
    return argv;
}

fn environmentMapForPolicy(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    policy: permissions.EnvPolicy,
) !?std.process.Environ.Map {
    switch (policy) {
        .inherit_all => return null,
        .empty => return std.process.Environ.Map.init(allocator),
        .allowlist => {
            var source = try std.process.Environ.createMap(environ, allocator);
            defer source.deinit();

            var filtered = std.process.Environ.Map.init(allocator);
            errdefer filtered.deinit();
            var iter = source.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                if (!permissions.allowsEnv(.allowlist, key)) continue;
                try filtered.put(key, entry.value_ptr.*);
            }
            return filtered;
        },
    }
}

fn looksNetworked(ticket: *const execution_queue.Ticket) bool {
    if (looksNetworkExecutable(ticket.executable)) return true;
    for (ticket.args.items) |arg| {
        if (std.mem.indexOf(u8, arg, "://") != null) return true;
        if (std.mem.startsWith(u8, arg, "git@")) return true;
    }
    return false;
}

fn looksNetworkExecutable(executable: []const u8) bool {
    const basename = std.fs.path.basename(executable);
    const known = [_][]const u8{
        "curl",
        "curl.exe",
        "wget",
        "wget.exe",
        "git",
        "git.exe",
        "ssh",
        "ssh.exe",
        "scp",
        "scp.exe",
        "sftp",
        "sftp.exe",
    };
    for (known) |candidate| {
        if (std.ascii.eqlIgnoreCase(basename, candidate)) return true;
    }
    return false;
}

fn termExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @as(i32, code),
        .signal, .stopped, .unknown => -1,
    };
}

fn appendFormatted(process_console: *console.ProcessConsole, stream: console.Stream, comptime fmt: []const u8, args: anytype) !void {
    var text: std.Io.Writer.Allocating = .init(process_console.allocator);
    defer text.deinit();
    try text.writer.print(fmt, args);
    try process_console.appendBytes(stream, text.written());
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

test "executor renders task history" {
    var queue = execution_queue.Queue.init(std.testing.allocator);
    defer queue.deinit();
    var process_console = console.ProcessConsole.init(std.testing.allocator);
    defer process_console.deinit();

    try queue.enqueueSpec("zig.build", .{
        .command = .{
            .executable = "zig",
            .args = &.{"build"},
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
    var ticket = queue.takeNextQueued() orelse return error.ExpectedTicket;
    defer ticket.deinit();
    try queue.recordHistory(&ticket, .finished, 0, 2, 0);

    try std.testing.expectEqual(HistoryResult.rendered, try renderHistory(&queue, &process_console));
    try std.testing.expect(process_console.lines.items.len > 0);
}

test "runner blocks approved command cwd traversal before spawn" {
    var queue = execution_queue.Queue.init(std.testing.allocator);
    defer queue.deinit();
    var process_console = console.ProcessConsole.init(std.testing.allocator);
    defer process_console.deinit();

    try queue.enqueueSpec("demo.network", .{
        .command = .{
            .executable = "zig",
            .args = &.{ "version" },
            .cwd = "..\\outside",
        },
    }, .{
        .command = "zig version",
        .cwd = "..\\outside",
        .env_policy = .empty,
        .fs_policy = .workspace_only,
        .network_policy = .deny,
        .output_sanitized = true,
    });

    const result = try runNext(&queue, &process_console, .{ .workspace_root = "." });
    try std.testing.expect(std.meta.activeTag(result) == .blocked);
    try std.testing.expectEqual(@as(usize, 0), queue.queuedCount());
    try std.testing.expectEqual(@as(usize, 1), queue.history.items.len);
    try std.testing.expectEqual(execution_queue.State.blocked, queue.latestHistory().?.state);
    try std.testing.expect(process_console.lines.items.len > 0);
}

test "runner blocks obvious network command when network is denied" {
    var queue = execution_queue.Queue.init(std.testing.allocator);
    defer queue.deinit();
    var process_console = console.ProcessConsole.init(std.testing.allocator);
    defer process_console.deinit();

    try queue.enqueueSpec("demo.network", .{
        .command = .{
            .executable = "curl",
            .args = &.{"https://example.test"},
            .cwd = ".",
        },
    }, .{
        .command = "curl https://example.test",
        .cwd = ".",
        .env_policy = .empty,
        .fs_policy = .workspace_only,
        .network_policy = .deny,
        .output_sanitized = true,
    });

    const result = try runNext(&queue, &process_console, .{ .workspace_root = "." });
    try std.testing.expect(std.meta.activeTag(result) == .blocked);
    try std.testing.expect(process_console.exit_code.? == -1);
    try std.testing.expectEqual(execution_queue.State.blocked, queue.latestHistory().?.state);
}
