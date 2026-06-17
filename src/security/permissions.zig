pub const ExternalCommandRisk = enum {
    normal,
    writes_workspace,
    deletes_files,
    network,
    unknown,
};

pub const CommandPermission = struct {
    display_command: []const u8,
    cwd: []const u8,
    risk: ExternalCommandRisk,
    requires_confirmation: bool,
};

