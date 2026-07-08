const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Fingerprint = [Sha256.digest_length * 2]u8;

pub const Input = struct {
    source_command_id: []const u8,
    display_command: []const u8,
    executable: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    workspace_root: []const u8,
    env_policy: []const u8,
    fs_policy: []const u8,
    network_policy: []const u8,
    output_sanitized: bool,
    timeout_ms: ?u32,
    output_limit_bytes: usize,
    intent_network: bool = false,
    intent_mutating: bool = false,
    intent_shell: bool = false,
    intent_destructive: bool = false,
    intent_package_manager: bool = false,
    intent_reason: []const u8 = "none",
};

pub fn fingerprint(input: Input) Fingerprint {
    var hasher = Sha256.init(.{});
    update(&hasher, "zide-launch-v2");
    update(&hasher, input.source_command_id);
    update(&hasher, input.display_command);
    update(&hasher, input.executable);
    for (input.args) |arg| update(&hasher, arg);
    update(&hasher, input.cwd);
    update(&hasher, input.workspace_root);
    update(&hasher, input.env_policy);
    update(&hasher, input.fs_policy);
    update(&hasher, input.network_policy);
    update(&hasher, if (input.output_sanitized) "output:sanitized" else "output:raw");
    update(&hasher, if (input.intent_network) "intent:network" else "intent:no-network");
    update(&hasher, if (input.intent_mutating) "intent:mutating" else "intent:read");
    update(&hasher, if (input.intent_shell) "intent:shell" else "intent:no-shell");
    update(&hasher, if (input.intent_destructive) "intent:destructive" else "intent:not-destructive");
    update(&hasher, if (input.intent_package_manager) "intent:package" else "intent:no-package");
    update(&hasher, input.intent_reason);

    var number_buf: [48]u8 = undefined;
    if (input.timeout_ms) |ms| {
        update(&hasher, std.fmt.bufPrint(number_buf[0..], "timeout_ms:{d}", .{ms}) catch "timeout_ms:?");
    } else {
        update(&hasher, "timeout_ms:none");
    }
    update(&hasher, std.fmt.bufPrint(number_buf[0..], "output_limit_bytes:{d}", .{input.output_limit_bytes}) catch "output_limit_bytes:?");

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn update(hasher: *Sha256, bytes: []const u8) void {
    hasher.update(bytes);
    hasher.update(&[_]u8{0});
}

test "launch audit fingerprint changes when policy changes" {
    const a = fingerprint(.{
        .source_command_id = "zig.build",
        .display_command = "zig build",
        .executable = "zig",
        .args = &.{"build"},
        .cwd = ".",
        .workspace_root = ".",
        .env_policy = "allowlist",
        .fs_policy = "workspace_only",
        .network_policy = "deny",
        .output_sanitized = true,
        .timeout_ms = 30_000,
        .output_limit_bytes = 512 * 1024,
        .intent_mutating = true,
        .intent_reason = "Zig subcommand writes build artifacts or source",
    });
    const b = fingerprint(.{
        .source_command_id = "zig.build",
        .display_command = "zig build",
        .executable = "zig",
        .args = &.{"build"},
        .cwd = ".",
        .workspace_root = ".",
        .env_policy = "allowlist",
        .fs_policy = "read_only_workspace",
        .network_policy = "deny",
        .output_sanitized = true,
        .timeout_ms = 30_000,
        .output_limit_bytes = 512 * 1024,
        .intent_mutating = true,
        .intent_reason = "Zig subcommand writes build artifacts or source",
    });
    try std.testing.expect(!std.mem.eql(u8, a[0..], b[0..]));
}
