const std = @import("std");
const command = @import("../core/command.zig");

pub const TrustState = enum {
    untrusted,
    reviewed,
    trusted,
    hardened,
    paranoid,
    locked_down,
};

pub const RunReason = enum {
    manual,
    automatic,
};

pub const Decision = union(enum) {
    allow,
    confirm: []const u8,
    block: []const u8,
};

pub const Policy = struct {
    state: TrustState,

    pub fn canRun(self: Policy, capability: command.Capability, reason: RunReason) bool {
        return std.meta.activeTag(self.decide(capability, reason)) == .allow;
    }

    pub fn decide(self: Policy, capability: command.Capability, reason: RunReason) Decision {
        if (capability == .safe) return .allow;
        if (capability == .workspace_write) {
            return switch (self.state) {
                .locked_down => .{ .block = "workspace is locked down; writes require security review" },
                else => .allow,
            };
        }

        if (capability != .external_command) return .allow;

        return switch (self.state) {
            .untrusted => .{ .block = "untrusted workspace: external commands are blocked" },
            .reviewed => .{ .block = "reviewed workspace is not trusted for execution yet" },
            .locked_down => .{ .block = "workspace is locked down by security policy" },
            .trusted => if (reason == .automatic)
                .{ .confirm = "automatic external command requires consent" }
            else
                .allow,
            .hardened => .{ .confirm = "hardened mode requires per-command consent" },
            .paranoid => .{ .confirm = "paranoid mode requires explicit toolchain/dependency review" },
        };
    }
};

test "untrusted workspaces block automatic external commands" {
    const policy = Policy{ .state = .untrusted };
    try @import("std").testing.expect(!policy.canRun(.external_command, .automatic));
    try @import("std").testing.expect(!policy.canRun(.external_command, .manual));
}

test "trusted manual external command is allowed" {
    const policy = Policy{ .state = .trusted };
    try @import("std").testing.expect(policy.canRun(.external_command, .manual));
}
