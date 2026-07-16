const std = @import("std");
const text_integrity = @import("text_integrity.zig");

pub const max_breakpoints: usize = 128;
pub const max_data_id_bytes: usize = 4096;
pub const max_description_bytes: usize = 4096;
pub const max_variable_name_bytes: usize = 4096;

pub const TextKind = enum {
    data_id,
    description,
    variable_name,
};

pub const AccessType = enum {
    read,
    write,
    read_write,

    pub fn protocolName(self: AccessType) []const u8 {
        return switch (self) {
            .read => "read",
            .write => "write",
            .read_write => "readWrite",
        };
    }

    pub fn displayName(self: AccessType) []const u8 {
        return switch (self) {
            .read => "READ",
            .write => "WRITE",
            .read_write => "READ + WRITE",
        };
    }
};

pub const ValidationError = error{
    EmptyDataBreakpointText,
    DataBreakpointTextTooLong,
    InvalidDataBreakpointUtf8,
    HiddenDataBreakpointControl,
};

/// Adapter-provided data IDs remain opaque. This validator only enforces the
/// bounded visible-text boundary before an ID is retained or persisted.
pub fn validate(kind: TextKind, value: []const u8) ValidationError![]const u8 {
    if (value.len == 0 and kind != .description) return error.EmptyDataBreakpointText;
    const limit: usize = switch (kind) {
        .data_id => max_data_id_bytes,
        .description => max_description_bytes,
        .variable_name => max_variable_name_bytes,
    };
    if (value.len > limit) return error.DataBreakpointTextTooLong;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidDataBreakpointUtf8;

    for (value, 0..) |byte, index| {
        if (text_integrity.hiddenControlLengthAt(value, index) != null) return error.HiddenDataBreakpointControl;
        if (byte < 0x20 or byte == 0x7f) return error.HiddenDataBreakpointControl;
    }
    var view = std.unicode.Utf8View.init(value) catch return error.InvalidDataBreakpointUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint >= 0x80 and codepoint <= 0x9f) return error.HiddenDataBreakpointControl;
        if (isInvisibleCodepoint(codepoint)) return error.HiddenDataBreakpointControl;
    }
    return value;
}

pub fn parseAccessType(value: []const u8) ?AccessType {
    if (std.mem.eql(u8, value, "read")) return .read;
    if (std.mem.eql(u8, value, "write")) return .write;
    if (std.mem.eql(u8, value, "readWrite")) return .read_write;
    return null;
}

pub fn parseAccessArgument(raw: []const u8) ?AccessType {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(value, "read")) return .read;
    if (std.ascii.eqlIgnoreCase(value, "write")) return .write;
    if (std.ascii.eqlIgnoreCase(value, "readWrite") or
        std.ascii.eqlIgnoreCase(value, "read_write") or
        std.ascii.eqlIgnoreCase(value, "read-write")) return .read_write;
    return null;
}

pub fn rejectionMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyDataBreakpointText => "data breakpoint metadata is empty",
        error.DataBreakpointTextTooLong => "data breakpoint metadata exceeds ZIDE's bounded size limit",
        error.InvalidDataBreakpointUtf8 => "data breakpoint metadata is not valid UTF-8",
        error.HiddenDataBreakpointControl => "data breakpoint metadata contains hidden or control characters",
        else => "invalid data breakpoint metadata",
    };
}

fn isInvisibleCodepoint(codepoint: u21) bool {
    return codepoint == 0x00a0 or
        codepoint == 0x00ad or
        codepoint == 0x034f or
        codepoint == 0x061c or
        codepoint == 0x1680 or
        (codepoint >= 0x115f and codepoint <= 0x1160) or
        (codepoint >= 0x17b4 and codepoint <= 0x17b5) or
        (codepoint >= 0x180b and codepoint <= 0x180e) or
        (codepoint >= 0x2000 and codepoint <= 0x200f) or
        (codepoint >= 0x2028 and codepoint <= 0x202f) or
        codepoint == 0x205f or
        (codepoint >= 0x2060 and codepoint <= 0x206f) or
        codepoint == 0x3000 or
        codepoint == 0x3164 or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
        codepoint == 0xfeff or
        codepoint == 0xffa0 or
        (codepoint >= 0xfff9 and codepoint <= 0xfffb) or
        (codepoint >= 0xe0100 and codepoint <= 0xe01ef);
}

test "data breakpoint metadata accepts bounded visible opaque values" {
    try std.testing.expectEqualStrings("0x7fff:watch slot", try validate(.data_id, "0x7fff:watch slot"));
    try std.testing.expectEqualStrings("counter", try validate(.variable_name, "counter"));
    _ = try validate(.description, "Writes to counter");
    _ = try validate(.description, "");
    try std.testing.expectEqual(AccessType.read_write, parseAccessType("readWrite").?);
    try std.testing.expectEqual(AccessType.read_write, parseAccessArgument(" READ-WRITE ").?);
}

test "data breakpoint metadata rejects hidden controls and oversized IDs" {
    try std.testing.expectError(error.EmptyDataBreakpointText, validate(.data_id, ""));
    try std.testing.expectError(error.HiddenDataBreakpointControl, validate(.data_id, "slot\nnext"));
    try std.testing.expectError(error.HiddenDataBreakpointControl, validate(.description, "rtl \xe2\x80\xae"));
    try std.testing.expectError(error.HiddenDataBreakpointControl, validate(.variable_name, "zero\xe2\x80\x8bwidth"));
    try std.testing.expectError(error.InvalidDataBreakpointUtf8, validate(.data_id, "bad\xff"));
    const oversized = [_]u8{'x'} ** (max_data_id_bytes + 1);
    try std.testing.expectError(error.DataBreakpointTextTooLong, validate(.data_id, &oversized));
    try std.testing.expect(parseAccessType("execute") == null);
}
