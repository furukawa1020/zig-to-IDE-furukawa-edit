const event = @import("../core/event.zig");

pub const DecodeResult = union(enum) {
    need_more,
    event: event.Event,
    invalid,
};

pub const InputDecoder = struct {
    pub fn decode(bytes: []const u8) DecodeResult {
        if (bytes.len == 0) return .need_more;
        if (bytes[0] == 0x1b) return .{ .event = .{ .key = .{ .code = .escape } } };
        if (bytes[0] == '\r' or bytes[0] == '\n') return .{ .event = .{ .key = .{ .code = .enter } } };
        return .{ .event = .{ .key = .{ .code = .{ .char = bytes[0] } } } };
    }
};

