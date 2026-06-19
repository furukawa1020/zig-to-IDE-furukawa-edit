const std = @import("std");
const permissions = @import("permissions.zig");
const process = @import("../platform/process.zig");
const trust = @import("trust.zig");

pub const Preview = struct {
    allocator: std.mem.Allocator,
    command: []u8,
    cwd: []u8,
    trust_state: trust.TrustState,
    consent: permissions.Consent,
    warnings: [][]const u8,

    pub fn deinit(self: *Preview) void {
        self.allocator.free(self.command);
        self.allocator.free(self.cwd);
        self.allocator.free(self.warnings);
        self.* = undefined;
    }
};

pub fn makePreview(allocator: std.mem.Allocator, spec: process.SpawnSpec, state: trust.TrustState) !Preview {
    const command_text = try process.appendDisplay(allocator, spec.command);
    errdefer allocator.free(command_text);
    const cwd = try allocator.dupe(u8, spec.command.cwd orelse ".");
    errdefer allocator.free(cwd);

    var warnings = std.array_list.Managed([]const u8).init(allocator);
    errdefer warnings.deinit();

    switch (state) {
        .untrusted => try warnings.append("build/test/run are blocked until workspace trust is elevated"),
        .reviewed => try warnings.append("workspace reviewed but execution is still blocked"),
        .hardened => try warnings.append("hardened mode: env allowlist and output sanitizer expected"),
        .paranoid => try warnings.append("paranoid mode: verify toolchain and dependency fingerprints"),
        .locked_down => try warnings.append("locked down: security findings must be reviewed first"),
        .trusted => {},
    }
    if (state != .trusted) {
        try warnings.append("execution timeout is enforced for approved commands");
    }

    return .{
        .allocator = allocator,
        .command = command_text,
        .cwd = cwd,
        .trust_state = state,
        .consent = .{
            .command = command_text,
            .cwd = cwd,
            .env_policy = if (state == .trusted) .inherit_all else .allowlist,
            .fs_policy = if (state == .trusted) .unrestricted else .workspace_only,
            .network_policy = if (state == .trusted) .unrestricted else .deny,
            .output_sanitized = true,
            .timeout_ms = if (state == .trusted) 120_000 else 30_000,
            .output_limit_bytes = if (state == .trusted) 2 * 1024 * 1024 else 512 * 1024,
        },
        .warnings = try warnings.toOwnedSlice(),
    };
}

test "consent preview names command and trust state" {
    var preview = try makePreview(std.testing.allocator, .{
        .command = .{ .executable = "zig", .args = &.{ "build", "test" }, .cwd = "." },
    }, .untrusted);
    defer preview.deinit();

    try std.testing.expect(std.mem.indexOf(u8, preview.command, "zig build test") != null);
    try std.testing.expect(preview.warnings.len > 0);
    try std.testing.expectEqual(@as(?u32, 30_000), preview.consent.timeout_ms);
    try std.testing.expectEqual(@as(usize, 512 * 1024), preview.consent.output_limit_bytes);
}
