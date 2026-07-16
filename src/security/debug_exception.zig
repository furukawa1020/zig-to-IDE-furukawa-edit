const std = @import("std");
const text_integrity = @import("text_integrity.zig");

pub const max_filters: usize = 64;
pub const max_filter_id_bytes: usize = 256;
pub const max_label_bytes: usize = 1024;
pub const max_description_bytes: usize = 4096;

pub const TextKind = enum {
    filter_id,
    label,
    description,
};

pub const ValidationError = error{
    EmptyExceptionFilterText,
    ExceptionFilterTextTooLong,
    InvalidExceptionFilterUtf8,
    HiddenExceptionFilterControl,
};

pub fn validate(kind: TextKind, value: []const u8) ValidationError![]const u8 {
    if (value.len == 0) {
        if (kind == .description) return value;
        return error.EmptyExceptionFilterText;
    }
    const limit: usize = switch (kind) {
        .filter_id => max_filter_id_bytes,
        .label => max_label_bytes,
        .description => max_description_bytes,
    };
    if (value.len > limit) return error.ExceptionFilterTextTooLong;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidExceptionFilterUtf8;

    for (value, 0..) |byte, index| {
        if (text_integrity.hiddenControlLengthAt(value, index) != null) return error.HiddenExceptionFilterControl;
        if (byte < 0x20 or byte == 0x7f) return error.HiddenExceptionFilterControl;
    }
    var view = std.unicode.Utf8View.init(value) catch return error.InvalidExceptionFilterUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint >= 0x80 and codepoint <= 0x9f) return error.HiddenExceptionFilterControl;
        if (codepoint == 0x200b or codepoint == 0x200c or codepoint == 0x200d or codepoint == 0x2060 or codepoint == 0xfeff) {
            return error.HiddenExceptionFilterControl;
        }
    }
    return value;
}

pub fn rejectionMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyExceptionFilterText => "exception filter ID is empty",
        error.ExceptionFilterTextTooLong => "exception filter metadata exceeds ZIDE's bounded size limit",
        error.InvalidExceptionFilterUtf8 => "exception filter metadata is not valid UTF-8",
        error.HiddenExceptionFilterControl => "exception filter metadata contains hidden or control characters",
        else => "invalid exception filter metadata",
    };
}

test "exception filter metadata accepts bounded visible UTF-8" {
    try std.testing.expectEqualStrings("all", try validate(.filter_id, "all"));
    try std.testing.expectEqualStrings("Thrown exceptions", try validate(.label, "Thrown exceptions"));
    _ = try validate(.description, "Break when an exception is thrown.");
    _ = try validate(.description, "");
}

test "exception filter metadata rejects controls invalid UTF-8 and oversized IDs" {
    const oversized = [_]u8{'x'} ** (max_filter_id_bytes + 1);
    try std.testing.expectError(error.EmptyExceptionFilterText, validate(.filter_id, ""));
    try std.testing.expectError(error.HiddenExceptionFilterControl, validate(.label, "hidden\nline"));
    try std.testing.expectError(error.HiddenExceptionFilterControl, validate(.label, "rtl \xe2\x80\xae"));
    try std.testing.expectError(error.HiddenExceptionFilterControl, validate(.label, "zero\xe2\x80\x8bwidth"));
    try std.testing.expectError(error.InvalidExceptionFilterUtf8, validate(.label, "bad\xff"));
    try std.testing.expectError(error.ExceptionFilterTextTooLong, validate(.filter_id, &oversized));
}
