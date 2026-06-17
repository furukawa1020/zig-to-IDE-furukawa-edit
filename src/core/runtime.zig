const std = @import("std");
const command = @import("command.zig");
const trust = @import("../security/trust.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    trust_state: trust.TrustState,
    command_catalog: []const command.Definition,

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{
            .allocator = allocator,
            .trust_state = .untrusted,
            .command_catalog = command.all(),
        };
    }

    pub fn canAutoRun(self: *const Runtime, definition: command.Definition) bool {
        const policy = trust.Policy{ .state = self.trust_state };
        return policy.canRun(definition.capability, .automatic);
    }
};
