const std = @import("std");
const command_intent = @import("../security/command_intent.zig");
const launch_audit = @import("../security/launch_audit.zig");
const permissions = @import("../security/permissions.zig");
const process = @import("../platform/process.zig");

pub const State = enum {
    queued,
    running,
    finished,
    cancelled,
    blocked,
    failed,
    timed_out,
    output_limited,
};

pub const Ticket = struct {
    allocator: std.mem.Allocator,
    source_command_id: []u8,
    display_command: []u8,
    executable: []u8,
    args: std.array_list.Managed([]u8),
    cwd: []u8,
    stdout: process.StreamMode,
    stderr: process.StreamMode,
    stdin: process.StreamMode,
    env_policy: permissions.EnvPolicy,
    fs_policy: permissions.FileSystemPolicy,
    network_policy: permissions.NetworkPolicy,
    output_sanitized: bool,
    timeout_ms: ?u32,
    output_limit_bytes: usize,
    state: State = .queued,

    pub fn init(
        allocator: std.mem.Allocator,
        source_command_id: []const u8,
        spec: process.SpawnSpec,
        consent: permissions.Consent,
    ) !Ticket {
        const owned_source = try allocator.dupe(u8, source_command_id);
        errdefer allocator.free(owned_source);
        const owned_display = try process.appendDisplay(allocator, spec.command);
        errdefer allocator.free(owned_display);
        const owned_executable = try allocator.dupe(u8, spec.command.executable);
        errdefer allocator.free(owned_executable);
        const owned_cwd = try allocator.dupe(u8, spec.command.cwd orelse consent.cwd);
        errdefer allocator.free(owned_cwd);

        var owned_args = std.array_list.Managed([]u8).init(allocator);
        errdefer {
            for (owned_args.items) |arg| allocator.free(arg);
            owned_args.deinit();
        }
        for (spec.command.args) |arg| {
            const owned_arg = try allocator.dupe(u8, arg);
            owned_args.append(owned_arg) catch |err| {
                allocator.free(owned_arg);
                return err;
            };
        }

        return .{
            .allocator = allocator,
            .source_command_id = owned_source,
            .display_command = owned_display,
            .executable = owned_executable,
            .args = owned_args,
            .cwd = owned_cwd,
            .stdout = spec.stdout,
            .stderr = spec.stderr,
            .stdin = spec.stdin,
            .env_policy = consent.env_policy,
            .fs_policy = consent.fs_policy,
            .network_policy = consent.network_policy,
            .output_sanitized = consent.output_sanitized,
            .timeout_ms = consent.timeout_ms,
            .output_limit_bytes = consent.output_limit_bytes,
        };
    }

    pub fn deinit(self: *Ticket) void {
        self.allocator.free(self.source_command_id);
        self.allocator.free(self.display_command);
        self.allocator.free(self.executable);
        for (self.args.items) |arg| self.allocator.free(arg);
        self.args.deinit();
        self.allocator.free(self.cwd);
        self.* = undefined;
    }
};

pub const HistoryEntry = struct {
    allocator: std.mem.Allocator,
    source_command_id: []u8,
    display_command: []u8,
    cwd: []u8,
    env_policy: permissions.EnvPolicy,
    fs_policy: permissions.FileSystemPolicy,
    network_policy: permissions.NetworkPolicy,
    intent: command_intent.Intent,
    audit_id: launch_audit.Fingerprint,
    output_sanitized: bool,
    timeout_ms: ?u32,
    output_limit_bytes: usize,
    state: State,
    exit_code: ?i32,
    output_lines: usize,
    sanitized_controls: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        ticket: *const Ticket,
        workspace_root: []const u8,
        state: State,
        exit_code: ?i32,
        output_lines: usize,
        sanitized_controls: usize,
    ) !HistoryEntry {
        const owned_source = try allocator.dupe(u8, ticket.source_command_id);
        errdefer allocator.free(owned_source);
        const owned_display = try allocator.dupe(u8, ticket.display_command);
        errdefer allocator.free(owned_display);
        const owned_cwd = try allocator.dupe(u8, ticket.cwd);
        errdefer allocator.free(owned_cwd);
        const intent = command_intent.classify(ticket.executable, ticket.args.items);

        return .{
            .allocator = allocator,
            .source_command_id = owned_source,
            .display_command = owned_display,
            .cwd = owned_cwd,
            .env_policy = ticket.env_policy,
            .fs_policy = ticket.fs_policy,
            .network_policy = ticket.network_policy,
            .intent = intent,
            .audit_id = launch_audit.fingerprint(.{
                .source_command_id = ticket.source_command_id,
                .display_command = ticket.display_command,
                .executable = ticket.executable,
                .args = ticket.args.items,
                .cwd = ticket.cwd,
                .workspace_root = workspace_root,
                .env_policy = @tagName(ticket.env_policy),
                .fs_policy = @tagName(ticket.fs_policy),
                .network_policy = @tagName(ticket.network_policy),
                .output_sanitized = ticket.output_sanitized,
                .timeout_ms = ticket.timeout_ms,
                .output_limit_bytes = ticket.output_limit_bytes,
                .intent_network = intent.network,
                .intent_mutating = intent.mutating,
                .intent_shell = intent.shell,
                .intent_destructive = intent.destructive,
                .intent_package_manager = intent.package_manager,
                .intent_reason = intent.reason,
            }),
            .output_sanitized = ticket.output_sanitized,
            .timeout_ms = ticket.timeout_ms,
            .output_limit_bytes = ticket.output_limit_bytes,
            .state = state,
            .exit_code = exit_code,
            .output_lines = output_lines,
            .sanitized_controls = sanitized_controls,
        };
    }

    pub fn deinit(self: *HistoryEntry) void {
        self.allocator.free(self.source_command_id);
        self.allocator.free(self.display_command);
        self.allocator.free(self.cwd);
        self.* = undefined;
    }
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    tickets: std.array_list.Managed(Ticket),
    history: std.array_list.Managed(HistoryEntry),
    max_history: usize = 64,

    pub fn init(allocator: std.mem.Allocator) Queue {
        return .{
            .allocator = allocator,
            .tickets = std.array_list.Managed(Ticket).init(allocator),
            .history = std.array_list.Managed(HistoryEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Queue) void {
        self.clear();
        self.history.deinit();
        self.tickets.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *Queue) void {
        for (self.tickets.items) |*ticket| ticket.deinit();
        self.tickets.clearRetainingCapacity();
        for (self.history.items) |*entry| entry.deinit();
        self.history.clearRetainingCapacity();
    }

    pub fn enqueue(self: *Queue, ticket: Ticket) !void {
        try self.tickets.append(ticket);
    }

    pub fn enqueueSpec(
        self: *Queue,
        source_command_id: []const u8,
        spec: process.SpawnSpec,
        consent: permissions.Consent,
    ) !void {
        const ticket = try Ticket.init(self.allocator, source_command_id, spec, consent);
        errdefer {
            var owned = ticket;
            owned.deinit();
        }
        try self.enqueue(ticket);
    }

    pub fn queuedCount(self: *const Queue) usize {
        var count: usize = 0;
        for (self.tickets.items) |ticket| {
            if (ticket.state == .queued) count += 1;
        }
        return count;
    }

    pub fn latest(self: *const Queue) ?*const Ticket {
        if (self.tickets.items.len == 0) return null;
        return &self.tickets.items[self.tickets.items.len - 1];
    }

    pub fn latestQueued(self: *Queue) ?*Ticket {
        var index = self.tickets.items.len;
        while (index > 0) {
            index -= 1;
            if (self.tickets.items[index].state == .queued) return &self.tickets.items[index];
        }
        return null;
    }

    pub fn latestHistory(self: *const Queue) ?*const HistoryEntry {
        if (self.history.items.len == 0) return null;
        return &self.history.items[self.history.items.len - 1];
    }

    pub fn recordHistory(
        self: *Queue,
        ticket: *const Ticket,
        workspace_root: []const u8,
        state: State,
        exit_code: ?i32,
        output_lines: usize,
        sanitized_controls: usize,
    ) !void {
        if (self.history.items.len >= self.max_history) {
            var first = self.history.orderedRemove(0);
            first.deinit();
        }

        const entry = try HistoryEntry.init(
            self.allocator,
            ticket,
            workspace_root,
            state,
            exit_code,
            output_lines,
            sanitized_controls,
        );
        errdefer {
            var owned = entry;
            owned.deinit();
        }
        try self.history.append(entry);
    }

    pub fn takeNextQueued(self: *Queue) ?Ticket {
        for (self.tickets.items, 0..) |ticket, index| {
            if (ticket.state == .queued) {
                return self.tickets.orderedRemove(index);
            }
        }
        return null;
    }
};

test "execution queue owns command ticket" {
    var queue = Queue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueueSpec("zig.build", .{
        .command = .{
            .executable = "zig",
            .args = &.{ "build", "test" },
            .cwd = ".",
        },
    }, .{
        .command = "zig build test",
        .cwd = ".",
        .env_policy = .allowlist,
        .fs_policy = .workspace_only,
        .network_policy = .deny,
        .output_sanitized = true,
        .timeout_ms = 30_000,
        .output_limit_bytes = 128 * 1024,
    });

    try std.testing.expectEqual(@as(usize, 1), queue.queuedCount());
    try std.testing.expectEqualStrings("zig build test", queue.latest().?.display_command);
    try std.testing.expectEqual(@as(?u32, 30_000), queue.latest().?.timeout_ms);
    try std.testing.expectEqual(@as(usize, 128 * 1024), queue.latest().?.output_limit_bytes);
}

test "execution queue hands ownership to runner" {
    var queue = Queue.init(std.testing.allocator);
    defer queue.deinit();

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
        .timeout_ms = 30_000,
        .output_limit_bytes = 128 * 1024,
    });

    var ticket = queue.takeNextQueued() orelse return error.ExpectedTicket;
    defer ticket.deinit();

    try std.testing.expectEqual(@as(usize, 0), queue.queuedCount());
    try std.testing.expectEqualStrings("zig", ticket.executable);
}

test "execution queue exposes latest queued ticket for policy edits" {
    var queue = Queue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueueSpec("old", .{
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
    try queue.enqueueSpec("new", .{
        .command = .{
            .executable = "zig",
            .args = &.{"test"},
            .cwd = ".",
        },
    }, .{
        .command = "zig test",
        .cwd = ".",
        .env_policy = .allowlist,
        .fs_policy = .workspace_only,
        .network_policy = .deny,
        .output_sanitized = true,
    });

    const latest = queue.latestQueued() orelse return error.ExpectedTicket;
    latest.network_policy = .unrestricted;

    try std.testing.expectEqualStrings("new", latest.source_command_id);
    try std.testing.expectEqual(permissions.NetworkPolicy.deny, queue.tickets.items[0].network_policy);
    try std.testing.expectEqual(permissions.NetworkPolicy.unrestricted, queue.tickets.items[1].network_policy);
}

test "execution queue records bounded run history" {
    var queue = Queue.init(std.testing.allocator);
    defer queue.deinit();
    queue.max_history = 1;

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

    var first = queue.takeNextQueued() orelse return error.ExpectedTicket;
    defer first.deinit();
    try queue.recordHistory(&first, ".", .finished, 0, 3, 1);
    try queue.recordHistory(&first, ".", .failed, -1, 4, 2);

    try std.testing.expectEqual(@as(usize, 1), queue.history.items.len);
    try std.testing.expectEqual(State.failed, queue.latestHistory().?.state);
    try std.testing.expectEqual(@as(usize, 2), queue.latestHistory().?.sanitized_controls);
    try std.testing.expect(queue.latestHistory().?.intent.mutating);
    try std.testing.expect(!queue.latestHistory().?.intent.network);
    try std.testing.expectEqual(@as(usize, 64), queue.latestHistory().?.audit_id.len);
}
