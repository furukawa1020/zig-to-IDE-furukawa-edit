const command = @import("../core/command.zig");

pub const TrustState = enum {
    trusted,
    untrusted,
};

pub const RunReason = enum {
    manual,
    automatic,
};

pub const Policy = struct {
    state: TrustState,

    pub fn canRun(self: Policy, capability: command.Capability, reason: RunReason) bool {
        if (capability != .external_command) return true;
        if (self.state == .trusted) return true;
        return reason == .manual;
    }
};

test "untrusted workspaces block automatic external commands" {
    const policy = Policy{ .state = .untrusted };
    try @import("std").testing.expect(!policy.canRun(.external_command, .automatic));
    try @import("std").testing.expect(policy.canRun(.external_command, .manual));
}

