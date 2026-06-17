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

    pub fn findCommand(self: *const Runtime, id: []const u8) ?command.Definition {
        _ = self;
        return command.findById(id);
    }

    pub fn checkCommand(self: *const Runtime, request: command.Request) command.Check {
        const definition = self.findCommand(request.id) orelse return .unknown_command;
        const reason: trust.RunReason = switch (request.source) {
            .startup => .automatic,
            else => .manual,
        };
        const policy = trust.Policy{ .state = self.trust_state };
        if (!policy.canRun(definition.capability, reason)) {
            return .{ .blocked = "workspace is untrusted; external command requires manual confirmation" };
        }
        return .{ .allowed = definition };
    }
};

test "runtime blocks startup external commands in untrusted workspace" {
    const rt = Runtime.init(std.testing.allocator);
    const check = rt.checkCommand(.{ .id = "zig.build", .source = .startup });
    try std.testing.expect(std.meta.activeTag(check) == .blocked);
}
