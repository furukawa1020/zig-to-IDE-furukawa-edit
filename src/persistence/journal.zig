pub const JournalEntryKind = enum {
    buffer_snapshot,
    edit_transaction,
    command_history,
};

pub const JournalEntry = struct {
    kind: JournalEntryKind,
    path: []const u8,
    bytes: []const u8,
};

