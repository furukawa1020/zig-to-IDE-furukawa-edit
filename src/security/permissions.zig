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
