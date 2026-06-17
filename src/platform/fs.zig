pub const WriteIntent = enum {
    save_buffer,
    create_file,
    rename,
    delete,
    backup,
    journal,
    cache,
};

pub const PathDecision = enum {
    allow,
    confirm,
    deny,
};

pub const PathPolicy = struct {
    workspace_root: []const u8,

    pub fn classifyWrite(self: PathPolicy, path: []const u8, intent: WriteIntent) PathDecision {
        _ = intent;
        if (startsWith(path, self.workspace_root)) return .allow;
        return .confirm;
    }
};

fn startsWith(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return @import("std").mem.eql(u8, value[0..prefix.len], prefix);
}

