pub const StorageKind = enum {
    global_config,
    workspace_config,
    session,
    cache,
    journal,
    backup,
    log,
};

pub const StoragePath = struct {
    kind: StorageKind,
    path: []const u8,
};

