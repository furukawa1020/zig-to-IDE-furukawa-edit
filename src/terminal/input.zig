const event = @import("../core/event.zig");

pub const DecodeResult = union(enum) {
    need_more,
    event: event.Event,
    invalid,
};

pub const InputDecoder = struct {
    pub fn decode(bytes: []const u8) DecodeResult {
        if (bytes.len == 0) return .need_more;

        if (bytes[0] == 0x1b) {
            if (bytes.len >= 3 and bytes[1] == '[') {
                switch (bytes[2]) {
                    'A' => return key(.arrow_up),
                    'B' => return key(.arrow_down),
                    'C' => return key(.arrow_right),
                    'D' => return key(.arrow_left),
                    '3' => {
                        if (bytes.len >= 4 and bytes[3] == '~') return key(.delete);
                        return .need_more;
                    },
                    else => return .invalid,
                }
            }
            if (bytes.len == 1) return key(.escape);
            return .invalid;
        }

        if (bytes[0] == '\r' or bytes[0] == '\n') return .{ .event = .{ .key = .{ .code = .enter } } };
        if (bytes[0] == '\t') return key(.tab);
        if (bytes[0] == 0x7f or bytes[0] == 0x08) return key(.backspace);
        if (bytes[0] == 0x03 or bytes[0] == 0x11) return .{ .event = .shutdown };
        if (bytes[0] == 0x10) return .{ .event = .{ .key = .{ .code = .{ .char = 'p' }, .modifiers = .{ .ctrl = true } } } };
        if (bytes[0] < 0x20) return .invalid;
        if (bytes[0] >= 0x80) return decodeUtf8(bytes);
        return .{ .event = .{ .key = .{ .code = .{ .char = bytes[0] } } } };
    }
};

fn key(code: event.KeyCode) DecodeResult {
    return .{ .event = .{ .key = .{ .code = code } } };
}

fn decodeUtf8(bytes: []const u8) DecodeResult {
    const first = bytes[0];
    const len: usize = if ((first & 0xe0) == 0xc0)
        2
    else if ((first & 0xf0) == 0xe0)
        3
    else if ((first & 0xf8) == 0xf0)
        4
    else
        return .invalid;

    if (bytes.len < len) return .need_more;

    var value: u21 = switch (len) {
        2 => @as(u21, first & 0x1f),
        3 => @as(u21, first & 0x0f),
        4 => @as(u21, first & 0x07),
        else => unreachable,
    };

    var i: usize = 1;
    while (i < len) : (i += 1) {
        if ((bytes[i] & 0xc0) != 0x80) return .invalid;
        value = (value << 6) | @as(u21, bytes[i] & 0x3f);
    }

    return .{ .event = .{ .key = .{ .code = .{ .char = value } } } };
}

test "input decoder maps arrows and ctrl-p" {
    const std = @import("std");

    const arrow = InputDecoder.decode("\x1b[A");
    switch (arrow) {
        .event => |decoded| try std.testing.expect(std.meta.activeTag(decoded.key.code) == .arrow_up),
        else => return error.ExpectedEvent,
    }

    const ctrl_p_result = InputDecoder.decode(&.{0x10});
    switch (ctrl_p_result) {
        .event => |decoded| try std.testing.expect(decoded.key.modifiers.ctrl),
        else => return error.ExpectedEvent,
    }

    const ctrl_c_result = InputDecoder.decode(&.{0x03});
    switch (ctrl_c_result) {
        .event => |decoded| try std.testing.expect(std.meta.activeTag(decoded) == .shutdown),
        else => return error.ExpectedEvent,
    }
}
