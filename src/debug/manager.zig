const std = @import("std");
const launch_plan = @import("launch_plan.zig");
const permissions = @import("../security/permissions.zig");
const session_mod = @import("session.zig");
const transport_mod = @import("transport.zig");

pub const Manager = struct {
    allocator: std.mem.Allocator,
    workspace_root: []u8,
    session: session_mod.Session,
    transport: ?transport_mod.Transport = null,
    plan: ?launch_plan.Plan = null,
    env_policy: permissions.EnvPolicy = .empty,
    fs_policy: permissions.FileSystemPolicy = .workspace_only,
    network_policy: permissions.NetworkPolicy = .deny,

    pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) !Manager {
        const root = try allocator.dupe(u8, workspace_root);
        errdefer allocator.free(root);
        return .{
            .allocator = allocator,
            .workspace_root = root,
            .session = try session_mod.Session.init(allocator, workspace_root),
        };
    }

    pub fn deinit(self: *Manager) void {
        self.closeTransport();
        self.session.deinit();
        self.allocator.free(self.workspace_root);
        self.* = undefined;
    }

    /// Takes ownership of `plan` only when startup succeeds.
    pub fn start(
        self: *Manager,
        io: std.Io,
        environ: std.process.Environ,
        plan: launch_plan.Plan,
        consent: permissions.Consent,
    ) !void {
        if (self.transport != null) return error.DebugSessionAlreadyRunning;
        if (!permissions.allowsWorkspacePath(consent.fs_policy, self.workspace_root, plan.cwd)) {
            return error.DebugCwdOutsideWorkspace;
        }
        if (!permissions.allowsWorkspacePath(consent.fs_policy, self.workspace_root, plan.program)) {
            return error.DebugProgramOutsideWorkspace;
        }

        var environment = try environmentMapForPolicy(self.allocator, environ, consent.env_policy);
        defer if (environment) |*map| map.deinit();
        const environment_ptr: ?*const std.process.Environ.Map = if (environment) |*map| map else null;

        var transport = try transport_mod.Transport.start(self.allocator, io, .{
            .argv = plan.adapter_argv,
            .cwd = plan.cwd,
        }, environment_ptr);
        errdefer transport.deinit();

        self.session.reset();
        var initialize = try self.session.makeInitialize(plan.adapter_id);
        defer initialize.deinit();
        try transport.send(initialize.framed);

        self.transport = transport;
        self.plan = plan;
        self.env_policy = consent.env_policy;
        self.fs_policy = consent.fs_policy;
        self.network_policy = consent.network_policy;
    }

    pub fn isRunning(self: *const Manager) bool {
        return self.transport != null;
    }

    pub fn send(self: *Manager, outbound: *const session_mod.Outbound) !void {
        const transport = if (self.transport) |*value| value else return error.DebugTransportNotRunning;
        try transport.send(outbound.framed);
    }

    pub fn stop(self: *Manager) bool {
        if (self.transport == null) return false;
        self.closeTransport();
        self.session.reset();
        self.session.state = .terminated;
        return true;
    }

    pub fn finishClosedTransport(self: *Manager) bool {
        if (self.transport == null) return false;
        self.closeTransport();
        if (self.session.state != .terminated and self.session.state != .failed) {
            self.session.state = .failed;
        }
        return true;
    }

    fn closeTransport(self: *Manager) void {
        if (self.transport) |*transport| transport.deinit();
        self.transport = null;
        if (self.plan) |*plan| plan.deinit();
        self.plan = null;
    }
};

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
            var iterator = source.iterator();
            while (iterator.next()) |entry| {
                if (!permissions.allowsEnv(.allowlist, entry.key_ptr.*)) continue;
                try filtered.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            return filtered;
        },
    }
}

test "debug manager starts idle with deny-by-default policy" {
    var manager = try Manager.init(std.testing.allocator, "/tmp/workspace");
    defer manager.deinit();
    try std.testing.expect(!manager.isRunning());
    try std.testing.expectEqual(permissions.EnvPolicy.empty, manager.env_policy);
    try std.testing.expectEqual(permissions.NetworkPolicy.deny, manager.network_policy);
}
