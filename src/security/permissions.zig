const std = @import("std");

pub const ExternalCommandRisk = enum {
    normal,
    writes_workspace,
    writes_outside_workspace,
    reads_env,
    deletes_files,
    executes_build_zig,
    executes_tests,
    network,
    terminal_control_output,
    unknown,
};

pub const CommandPermission = struct {
    display_command: []const u8,
    cwd: []const u8,
    risk: ExternalCommandRisk,
    requires_confirmation: bool,
};

pub const Consent = struct {
    command: []const u8,
    cwd: []const u8,
    env_policy: EnvPolicy = .allowlist,
    fs_policy: FileSystemPolicy = .workspace_only,
    network_policy: NetworkPolicy = .deny,
    output_sanitized: bool = true,
    timeout_ms: ?u32 = 60_000,
    output_limit_bytes: usize = 512 * 1024,
};

pub const EnvPolicy = enum {
    inherit_all,
    allowlist,
    empty,
};

pub const FileSystemPolicy = enum {
    unrestricted,
    workspace_only,
    read_only_workspace,
};

pub const NetworkPolicy = enum {
    unrestricted,
    deny,
};

pub fn allowsEnv(policy: EnvPolicy, key: []const u8) bool {
    return switch (policy) {
        .inherit_all => true,
        .empty => false,
        .allowlist => isAllowedEnvKey(key),
    };
}

pub fn allowsNetwork(policy: NetworkPolicy) bool {
    return policy == .unrestricted;
}

pub fn allowsWorkspacePath(policy: FileSystemPolicy, workspace_root: []const u8, path: []const u8) bool {
    return switch (policy) {
        .unrestricted => true,
        .workspace_only, .read_only_workspace => isInsideWorkspace(workspace_root, path),
    };
}

pub fn allowsWrite(policy: FileSystemPolicy, workspace_root: []const u8, path: []const u8) bool {
    return switch (policy) {
        .unrestricted => true,
        .workspace_only => isInsideWorkspace(workspace_root, path),
        .read_only_workspace => false,
    };
}

fn isAllowedEnvKey(key: []const u8) bool {
    const allowed = [_][]const u8{
        "PATH",
        "HOME",
        "USERPROFILE",
        "TMP",
        "TEMP",
        "ZIG_GLOBAL_CACHE_DIR",
        "ZIG_LOCAL_CACHE_DIR",
    };
    for (allowed) |candidate| {
        if (std.ascii.eqlIgnoreCase(key, candidate)) return true;
    }
    return false;
}

fn isInsideWorkspace(workspace_root: []const u8, path: []const u8) bool {
    if (hasParentTraversal(path)) return false;
    if (!std.fs.path.isAbsolute(path)) return true;
    if (!startsWithPath(path, workspace_root)) return false;
    return true;
}

fn startsWithPath(path: []const u8, root: []const u8) bool {
    if (root.len == 0) return false;
    if (path.len < root.len) return false;
    if (!std.ascii.eqlIgnoreCase(path[0..root.len], root)) return false;
    if (path.len == root.len) return true;
    const next = path[root.len];
    return next == '/' or next == '\\';
}

fn hasParentTraversal(path: []const u8) bool {
    var start: usize = 0;
    while (start <= path.len) {
        var end = start;
        while (end < path.len and path[end] != '/' and path[end] != '\\') : (end += 1) {}
        if (std.mem.eql(u8, path[start..end], "..")) return true;
        if (end == path.len) break;
        start = end + 1;
    }
    return false;
}

test "allowlist environment keeps secrets out" {
    try std.testing.expect(allowsEnv(.allowlist, "PATH"));
    try std.testing.expect(!allowsEnv(.allowlist, "GITHUB_TOKEN"));
    try std.testing.expect(!allowsEnv(.empty, "PATH"));
}

test "workspace path policy blocks traversal and outside absolute paths" {
    try std.testing.expect(allowsWorkspacePath(.workspace_only, "C:\\repo", "src\\main.zig"));
    try std.testing.expect(!allowsWorkspacePath(.workspace_only, "C:\\repo", "..\\secret.txt"));
    try std.testing.expect(!allowsWorkspacePath(.workspace_only, "C:\\repo", "C:\\Users\\hatake\\.ssh\\id_rsa"));
    try std.testing.expect(allowsWorkspacePath(.workspace_only, "C:\\repo", "C:\\repo\\src\\main.zig"));
}
