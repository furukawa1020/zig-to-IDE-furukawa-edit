const std = @import("std");
const console = @import("console.zig");
const execution_queue = @import("execution_queue.zig");
const audit_chain = @import("../security/audit_chain.zig");
const command_intent = @import("../security/command_intent.zig");
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
    audit_log: bool = true,
    clear_console: bool = true,
    environment_overrides: []const EnvironmentOverride = &.{},
};

pub const EnvironmentOverride = struct {
    key: []const u8,
    value: []const u8,
};

pub const RunResult = union(enum) {
    ran: i32,
    empty_queue,
    blocked: []const u8,
    failed: []const u8,
    timed_out,
    output_limited,
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
    const intent = command_intent.classify(ticket.executable, ticket.args.items);
    try writer.print("intent: network={} mutating={} shell={} destructive={} package={} reason={s}\n", .{
        intent.network,
        intent.mutating,
        intent.shell,
        intent.destructive,
        intent.package_manager,
        intent.reason,
    });
    try writer.print("output_sanitized: {}\n", .{ticket.output_sanitized});
    if (ticket.timeout_ms) |ms| {
        try writer.print("timeout_ms: {d}\n", .{ms});
    } else {
        try writer.writeAll("timeout_ms: none\n");
    }
    try writer.print("output_limit_bytes: {d}\n", .{ticket.output_limit_bytes});

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
        if (entry.timeout_ms) |ms| {
            try writer.print(" timeout_ms={d}", .{ms});
        } else {
            try writer.writeAll(" timeout_ms=none");
        }
        try writer.print(" audit={s} output_limit={d} lines={d} sanitized={d} intent:n{} w{} sh{} d{} pkg{} reason={s} cwd={s}\n", .{
            entry.audit_id[0..12],
            entry.output_limit_bytes,
            entry.output_lines,
            entry.sanitized_controls,
            entry.intent.network,
            entry.intent.mutating,
            entry.intent.shell,
            entry.intent.destructive,
            entry.intent.package_manager,
            entry.intent.reason,
            entry.cwd,
        });
    }

    try process_console.appendBytes(.stdout, text.written());
    return .rendered;
}

pub fn runNext(queue: *execution_queue.Queue, process_console: *console.ProcessConsole, options: RunOptions) !RunResult {
    var ticket = queue.takeNextQueued() orelse return .empty_queue;
    defer ticket.deinit();

    if (options.clear_console) {
        process_console.begin();
    } else {
        process_console.running = true;
        process_console.exit_code = null;
    }
    if (!permissions.allowsWorkspacePath(ticket.fs_policy, options.workspace_root, ticket.cwd)) {
        const message = "approved command cwd is outside the permitted workspace boundary";
        try appendFormatted(process_console, .stderr, "blocked: {s}\n", .{message});
        process_console.finish(-1);
        try recordRunHistory(queue, &ticket, process_console, options, .blocked, -1);
        return .{ .blocked = message };
    }

    const intent = command_intent.classify(ticket.executable, ticket.args.items);
    if (intent.network and !permissions.allowsNetwork(ticket.network_policy)) {
        const message = "approved command looks networked but network policy is deny";
        try appendFormatted(process_console, .stderr, "blocked: {s}\n", .{message});
        try appendFormatted(process_console, .stderr, "intent reason: {s}\n", .{intent.reason});
        process_console.finish(-1);
        try recordRunHistory(queue, &ticket, process_console, options, .blocked, -1);
        return .{ .blocked = message };
    }

    if (ticket.fs_policy == .read_only_workspace and intent.mutating) {
        const message = "approved command looks mutating but file system policy is read_only_workspace";
        try appendFormatted(process_console, .stderr, "blocked: {s}\n", .{message});
        try appendFormatted(process_console, .stderr, "intent reason: {s}\n", .{intent.reason});
        process_console.finish(-1);
        try recordRunHistory(queue, &ticket, process_console, options, .blocked, -1);
        return .{ .blocked = message };
    }

    var argv = try argvFromTicket(process_console.allocator, &ticket);
    defer argv.deinit();

    var env_map = try environmentMapForPolicy(process_console.allocator, options.environ, ticket.env_policy);
    defer if (env_map) |*map| map.deinit();
    if (options.environment_overrides.len > 0 and env_map == null) {
        env_map = try std.process.Environ.createMap(options.environ, process_console.allocator);
    }
    if (env_map) |*map| {
        for (options.environment_overrides) |entry| try map.put(entry.key, entry.value);
    }
    const env_ptr: ?*const std.process.Environ.Map = if (env_map) |*map| map else null;

    try appendFormatted(process_console, .stdout, "$ {s}\n", .{ticket.display_command});
    if (ticket.env_policy != .inherit_all) {
        try appendFormatted(process_console, .stdout, "env policy: {s}\n", .{@tagName(ticket.env_policy)});
    }

    const result = std.process.run(process_console.allocator, options.io, .{
        .argv = argv.items,
        .cwd = .{ .path = ticket.cwd },
        .environ_map = env_ptr,
        .stdout_limit = .limited(effectiveOutputLimit(ticket.output_limit_bytes, options.stdout_limit)),
        .stderr_limit = .limited(effectiveOutputLimit(ticket.output_limit_bytes, options.stderr_limit)),
        .timeout = timeoutFromMs(ticket.timeout_ms),
    }) catch |err| {
        if (err == error.Timeout) {
            try appendTimeoutExceeded(process_console, ticket.timeout_ms);
            process_console.finish(-1);
            try recordRunHistory(queue, &ticket, process_console, options, .timed_out, -1);
            return .timed_out;
        }
        if (err == error.StreamTooLong) {
            try appendFormatted(process_console, .stderr, "output exceeded {d} byte limit\n", .{ticket.output_limit_bytes});
            process_console.finish(-1);
            try recordRunHistory(queue, &ticket, process_console, options, .output_limited, -1);
            return .output_limited;
        }
        try appendFormatted(process_console, .stderr, "spawn failed: {s}\n", .{@errorName(err)});
        process_console.finish(-1);
        try recordRunHistory(queue, &ticket, process_console, options, .failed, -1);
        return .{ .failed = @errorName(err) };
    };
    defer process_console.allocator.free(result.stdout);
    defer process_console.allocator.free(result.stderr);

    try process_console.appendBytes(.stdout, result.stdout);
    try process_console.appendBytes(.stderr, result.stderr);
    const exit_code = termExitCode(result.term);
    process_console.finish(exit_code);
    try appendFormatted(process_console, .stdout, "exit: {d}\n", .{exit_code});
    try recordRunHistory(queue, &ticket, process_console, options, .finished, exit_code);

    return .{ .ran = exit_code };
}

fn recordRunHistory(
    queue: *execution_queue.Queue,
    ticket: *const execution_queue.Ticket,
    process_console: *console.ProcessConsole,
    options: RunOptions,
    state: execution_queue.State,
    exit_code: ?i32,
) !void {
    try queue.recordHistory(
        ticket,
        options.workspace_root,
        state,
        exit_code,
        process_console.lines.items.len,
        process_console.sanitized_stats.total(),
    );
    if (!options.audit_log) return;
    persistLatestAudit(queue, process_console, options) catch |err| {
        try appendFormatted(process_console, .stderr, "audit log write failed: {s}\n", .{@errorName(err)});
    };
}

fn persistLatestAudit(queue: *const execution_queue.Queue, process_console: *console.ProcessConsole, options: RunOptions) !void {
    const entry = queue.latestHistory() orelse return;

    const audit_dir = try std.fs.path.join(process_console.allocator, &.{ options.workspace_root, ".zide", "audit" });
    defer process_console.allocator.free(audit_dir);
    try std.Io.Dir.cwd().createDirPath(options.io, audit_dir);

    const log_path = try std.fs.path.join(process_console.allocator, &.{ audit_dir, "run-history.jsonl" });
    defer process_console.allocator.free(log_path);

    var file = try std.Io.Dir.cwd().createFile(options.io, log_path, .{
        .truncate = false,
        .lock = .exclusive,
    });
    defer file.close(options.io);

    const offset = try file.length(options.io);
    const prev_record_hash = try previousAuditRecordHash(process_console.allocator, file, options.io, offset);
    var line = try auditJsonLine(process_console.allocator, entry, prev_record_hash);
    defer line.deinit();

    try file.writePositionalAll(options.io, line.written(), offset);
    try file.sync(options.io);
    const record_hash = audit_chain.lastRecordHash(line.written()) orelse audit_chain.zero_digest;
    try appendFormatted(process_console, .stdout, "audit log: .zide/audit/run-history.jsonl id={s} chain={s}\n", .{ entry.audit_id[0..12], record_hash[0..12] });
}

fn previousAuditRecordHash(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io, length: u64) !audit_chain.Digest {
    if (length == 0) return audit_chain.zero_digest;

    const tail_len_u64 = @min(length, 64 * 1024);
    const tail_len: usize = @intCast(tail_len_u64);
    const offset = length - tail_len_u64;
    const buffer = try allocator.alloc(u8, tail_len);
    defer allocator.free(buffer);

    const read_len = try file.readPositionalAll(io, buffer, offset);
    return audit_chain.lastRecordHash(buffer[0..read_len]) orelse audit_chain.zero_digest;
}

fn auditJsonLine(allocator: std.mem.Allocator, entry: *const execution_queue.HistoryEntry, prev_record_hash: audit_chain.Digest) !std.Io.Writer.Allocating {
    var text: std.Io.Writer.Allocating = .init(allocator);
    errdefer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("{\"schema\":\"zide.run-history.v1\"");
    try writer.print(",\"audit_id\":\"{s}\"", .{entry.audit_id[0..]});
    try writeJsonField(writer, "source", entry.source_command_id);
    try writeJsonField(writer, "command", entry.display_command);
    try writeJsonField(writer, "cwd", entry.cwd);
    try writer.print(",\"state\":\"{s}\"", .{@tagName(entry.state)});
    if (entry.exit_code) |code| {
        try writer.print(",\"exit_code\":{d}", .{code});
    } else {
        try writer.writeAll(",\"exit_code\":null");
    }
    try writer.print(",\"output_lines\":{d}", .{entry.output_lines});
    try writer.print(",\"sanitized_controls\":{d}", .{entry.sanitized_controls});
    try writer.print(",\"output_sanitized\":{}", .{entry.output_sanitized});
    try writer.print(",\"timeout_ms\":", .{});
    if (entry.timeout_ms) |ms| {
        try writer.print("{d}", .{ms});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"output_limit_bytes\":{d}", .{entry.output_limit_bytes});
    try writer.print(",\"policies\":{{\"env\":\"{s}\",\"fs\":\"{s}\",\"network\":\"{s}\"}}", .{
        @tagName(entry.env_policy),
        @tagName(entry.fs_policy),
        @tagName(entry.network_policy),
    });
    try writer.print(",\"intent\":{{\"network\":{},\"mutating\":{},\"shell\":{},\"destructive\":{},\"package_manager\":{}", .{
        entry.intent.network,
        entry.intent.mutating,
        entry.intent.shell,
        entry.intent.destructive,
        entry.intent.package_manager,
    });
    try writeJsonField(writer, "reason", entry.intent.reason);
    try writer.writeAll("}");

    const record_hash = audit_chain.hashRecord(prev_record_hash[0..], text.written());
    try writer.print(",\"prev_record_hash\":\"{s}\",\"record_hash\":\"{s}\"}}\n", .{ prev_record_hash[0..], record_hash[0..] });
    return text;
}

fn writeJsonField(writer: *std.Io.Writer, comptime name: []const u8, value: []const u8) !void {
    try writer.print(",\"{s}\":", .{name});
    try writeJsonString(writer, value);
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...0x1f => try writer.print("\\u00{x:0>2}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
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

fn termExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @as(i32, code),
        .signal, .stopped, .unknown => -1,
    };
}

fn timeoutFromMs(timeout_ms: ?u32) std.Io.Timeout {
    const ms = timeout_ms orelse return .none;
    return .{ .duration = .{
        .clock = .boot,
        .raw = .fromMilliseconds(ms),
    } };
}

fn effectiveOutputLimit(ticket_limit: usize, option_limit: usize) usize {
    if (ticket_limit == 0) return option_limit;
    return @min(ticket_limit, option_limit);
}

fn appendTimeoutExceeded(process_console: *console.ProcessConsole, timeout_ms: ?u32) !void {
    if (timeout_ms) |ms| {
        try appendFormatted(process_console, .stderr, "timed out after {d}ms\n", .{ms});
    } else {
        try appendFormatted(process_console, .stderr, "timed out\n", .{});
    }
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

    try std.testing.expectEqual(PreviewResult.rendered, try previewLatest(&queue, &process_console));
    try std.testing.expect(process_console.lines.items.len > 0);
}

test "timeout conversion uses boot clock duration" {
    const timeout = timeoutFromMs(250);
    try std.testing.expect(std.meta.activeTag(timeout) == .duration);
    try std.testing.expectEqual(std.Io.Clock.boot, timeout.duration.clock);
    try std.testing.expectEqual(@as(i64, 250), timeout.duration.raw.toMilliseconds());
    try std.testing.expect(std.meta.activeTag(timeoutFromMs(null)) == .none);
}

test "effective output limit keeps the tighter cap" {
    try std.testing.expectEqual(@as(usize, 128), effectiveOutputLimit(128, 512));
    try std.testing.expectEqual(@as(usize, 256), effectiveOutputLimit(0, 256));
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
    try queue.recordHistory(&ticket, ".", .finished, 0, 2, 0);

    try std.testing.expectEqual(HistoryResult.rendered, try renderHistory(&queue, &process_console));
    try std.testing.expect(process_console.lines.items.len > 0);
}

test "audit json line escapes command metadata" {
    var queue = execution_queue.Queue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueueSpec("demo.audit", .{
        .command = .{
            .executable = "zig",
            .args = &.{ "build\ncheck", "\"quoted\"" },
            .cwd = ".",
        },
    }, .{
        .command = "zig build\ncheck \"quoted\"",
        .cwd = ".",
        .env_policy = .allowlist,
        .fs_policy = .workspace_only,
        .network_policy = .deny,
        .output_sanitized = true,
    });
    var ticket = queue.takeNextQueued() orelse return error.ExpectedTicket;
    defer ticket.deinit();
    try queue.recordHistory(&ticket, ".", .finished, 0, 2, 0);

    var line = try auditJsonLine(std.testing.allocator, queue.latestHistory().?, audit_chain.zero_digest);
    defer line.deinit();
    const bytes = line.written();
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\n"));
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\\\"quoted\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"schema\":\"zide.run-history.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"intent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"prev_record_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"record_hash\"") != null);
    try std.testing.expect(audit_chain.verify(bytes).ok());
}

test "runner blocks approved command cwd traversal before spawn" {
    var queue = execution_queue.Queue.init(std.testing.allocator);
    defer queue.deinit();
    var process_console = console.ProcessConsole.init(std.testing.allocator);
    defer process_console.deinit();

    try queue.enqueueSpec("demo.network", .{
        .command = .{
            .executable = "zig",
            .args = &.{"version"},
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

    const result = try runNext(&queue, &process_console, .{ .workspace_root = ".", .audit_log = false });
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

    const result = try runNext(&queue, &process_console, .{ .workspace_root = ".", .audit_log = false });
    try std.testing.expect(std.meta.activeTag(result) == .blocked);
    try std.testing.expect(process_console.exit_code.? == -1);
    try std.testing.expectEqual(execution_queue.State.blocked, queue.latestHistory().?.state);
}

test "runner blocks obvious mutating command when workspace is read only" {
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
        .env_policy = .empty,
        .fs_policy = .read_only_workspace,
        .network_policy = .deny,
        .output_sanitized = true,
    });

    const result = try runNext(&queue, &process_console, .{ .workspace_root = ".", .audit_log = false });
    try std.testing.expect(std.meta.activeTag(result) == .blocked);
    try std.testing.expect(process_console.exit_code.? == -1);
    try std.testing.expectEqual(execution_queue.State.blocked, queue.latestHistory().?.state);
}
