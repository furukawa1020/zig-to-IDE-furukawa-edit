const std = @import("std");
const permissions = @import("../security/permissions.zig");
const process = @import("../platform/process.zig");

pub const State = enum {
    queued,
    running,
    finished,
    cancelled,
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

pub const Queue = struct {
    allocator: std.mem.Allocator,
    tickets: std.array_list.Managed(Ticket),

    pub fn init(allocator: std.mem.Allocator) Queue {
        return .{
            .allocator = allocator,
            .tickets = std.array_list.Managed(Ticket).init(allocator),
        };
    }

    pub fn deinit(self: *Queue) void {
        self.clear();
        self.tickets.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *Queue) void {
        for (self.tickets.items) |*ticket| ticket.deinit();
        self.tickets.clearRetainingCapacity();
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
    });

    try std.testing.expectEqual(@as(usize, 1), queue.queuedCount());
    try std.testing.expectEqualStrings("zig build test", queue.latest().?.display_command);
}

test "execution queue hands ownership to runner" {
    var queue = Queue.init(std.testing.allocator);
    defer queue.deinit();

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

    var ticket = queue.takeNextQueued() orelse return error.ExpectedTicket;
    defer ticket.deinit();

    try std.testing.expectEqual(@as(usize, 0), queue.queuedCount());
    try std.testing.expectEqualStrings("zig", ticket.executable);
}
