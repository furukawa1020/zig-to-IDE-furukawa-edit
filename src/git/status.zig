pub const FileStatus = enum {
    clean,
    modified,
    added,
    deleted,
    renamed,
    untracked,
    ignored,
    conflicted,
};

pub const StatusEntry = struct {
    path: []const u8,
    status: FileStatus,
};

