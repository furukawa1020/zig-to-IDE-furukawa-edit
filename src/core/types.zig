pub const ByteOffset = usize;
pub const Line = usize;
pub const Column = usize;

pub const Position = struct {
    line: Line,
    column: Column,
    byte_offset: ByteOffset,

    pub fn start() Position {
        return .{ .line = 0, .column = 0, .byte_offset = 0 };
    }
};

pub const Range = struct {
    start: Position,
    end: Position,

    pub fn empty(at: Position) Range {
        return .{ .start = at, .end = at };
    }
};

pub const Severity = enum {
    info,
    warning,
    error,
};

