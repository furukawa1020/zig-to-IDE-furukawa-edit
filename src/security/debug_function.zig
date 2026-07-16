const std = @import("std");
const text_integrity = @import("text_integrity.zig");

pub const max_breakpoints: usize = 256;
pub const max_selector_bytes: usize = 1024;
const max_group_depth: usize = 16;

pub const ValidationError = error{
    EmptyFunctionSelector,
    FunctionSelectorTooLong,
    InvalidFunctionSelectorUtf8,
    HiddenFunctionSelectorControl,
    UnsafeFunctionSelector,
    UnbalancedFunctionSelector,
};

/// Validates a bounded, explicit symbol selector. ZIDE never evaluates this text
/// and only serializes it as the DAP FunctionBreakpoint.name JSON field.
pub fn validate(raw: []const u8) ValidationError![]const u8 {
    const selector = std.mem.trim(u8, raw, " ");
    if (selector.len == 0) return error.EmptyFunctionSelector;
    if (selector.len > max_selector_bytes) return error.FunctionSelectorTooLong;
    if (!std.unicode.utf8ValidateSlice(selector)) return error.InvalidFunctionSelectorUtf8;

    for (selector, 0..) |byte, index| {
        if (text_integrity.hiddenControlLengthAt(selector, index) != null) return error.HiddenFunctionSelectorControl;
        if (byte < 0x20 or byte == 0x7f) return error.HiddenFunctionSelectorControl;
    }
    var view = std.unicode.Utf8View.init(selector) catch return error.InvalidFunctionSelectorUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint >= 0x80 and codepoint <= 0x9f) return error.HiddenFunctionSelectorControl;
        if (isInvisibleCodepoint(codepoint)) return error.HiddenFunctionSelectorControl;
    }

    if (!isSelectorStart(selector[0])) return error.UnsafeFunctionSelector;

    var groups: [max_group_depth]u8 = undefined;
    var depth: usize = 0;
    var has_identifier = false;
    var index: usize = 0;
    while (index < selector.len) : (index += 1) {
        const byte = selector[index];
        if (byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte == '@') {
            has_identifier = true;
            continue;
        }
        switch (byte) {
            ' ' => {},
            '.', '/' => {
                if (index == 0 or index + 1 == selector.len) return error.UnsafeFunctionSelector;
                if (selector[index - 1] == byte or selector[index + 1] == byte or selector[index + 1] == '*') {
                    return error.UnsafeFunctionSelector;
                }
            },
            ':' => {
                if (index + 1 >= selector.len or selector[index + 1] != ':') return error.UnsafeFunctionSelector;
                if (index == 0 or index + 2 >= selector.len) return error.UnsafeFunctionSelector;
                index += 1;
            },
            '(', '[', '<' => {
                if (depth >= max_group_depth) return error.UnbalancedFunctionSelector;
                groups[depth] = byte;
                depth += 1;
            },
            ')', ']', '>' => {
                if (depth == 0 or !matchingGroup(groups[depth - 1], byte)) return error.UnbalancedFunctionSelector;
                depth -= 1;
            },
            ',' => if (depth == 0) return error.UnsafeFunctionSelector,
            '+', '-', '~' => {},
            '*', '&' => if (depth == 0) return error.UnsafeFunctionSelector,
            else => return error.UnsafeFunctionSelector,
        }
    }
    if (depth != 0) return error.UnbalancedFunctionSelector;
    if (!isSelectorEnd(selector[selector.len - 1])) return error.UnsafeFunctionSelector;
    if (!has_identifier) return error.UnsafeFunctionSelector;
    return selector;
}

pub fn rejectionMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyFunctionSelector => "function selector is empty",
        error.FunctionSelectorTooLong => "function selector exceeds ZIDE's bounded size limit",
        error.InvalidFunctionSelectorUtf8 => "function selector is not valid UTF-8",
        error.HiddenFunctionSelectorControl => "function selector contains hidden or control characters",
        error.UnbalancedFunctionSelector => "function selector has unbalanced (), [], or <> groups",
        error.UnsafeFunctionSelector => "function selector rejected: enter an explicit qualified symbol or signature without wildcards or expressions",
        else => "invalid function selector",
    };
}

fn matchingGroup(open: u8, close: u8) bool {
    return (open == '(' and close == ')') or
        (open == '[' and close == ']') or
        (open == '<' and close == '>');
}

fn isSelectorStart(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte == '@' or byte == '~';
}

fn isSelectorEnd(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte == ')' or byte == ']' or byte == '>';
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
        (codepoint >= 0x2000 and codepoint <= 0x200a) or
        (codepoint >= 0x200b and codepoint <= 0x200f) or
        (codepoint >= 0x2028 and codepoint <= 0x202e) or
        codepoint == 0x202f or
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

test "function selectors accept common bounded multi-language symbols" {
    try std.testing.expectEqualStrings("main", try validate(" main "));
    _ = try validate("std::vector<int>::push_back");
    _ = try validate("pkg.module.Class.method");
    _ = try validate("crate::worker::run");
    _ = try validate("Type.method(*const u8, usize)");
    _ = try validate("operator new");
    _ = try validate("\xe6\x8f\x8f\xe7\x94\xbb");
}

test "function selectors reject controls patterns expressions and malformed groups" {
    try std.testing.expectError(error.HiddenFunctionSelectorControl, validate(" \t "));
    try std.testing.expectError(error.UnsafeFunctionSelector, validate("main.*"));
    try std.testing.expectError(error.UnsafeFunctionSelector, validate("main; launch"));
    try std.testing.expectError(error.UnsafeFunctionSelector, validate("run() || other()"));
    try std.testing.expectError(error.UnsafeFunctionSelector, validate("*main"));
    try std.testing.expectError(error.UnsafeFunctionSelector, validate("--main"));
    try std.testing.expectError(error.UnbalancedFunctionSelector, validate("Type.method("));
    try std.testing.expectError(error.HiddenFunctionSelectorControl, validate("hidden\nname"));
    try std.testing.expectError(error.HiddenFunctionSelectorControl, validate("rtl \xe2\x80\xae"));
    try std.testing.expectError(error.HiddenFunctionSelectorControl, validate("line\xe2\x80\xa8break"));
    try std.testing.expectError(error.HiddenFunctionSelectorControl, validate("soft\xc2\xadhyphen"));
    try std.testing.expectError(error.HiddenFunctionSelectorControl, validate("\xc2\xa0"));
    try std.testing.expectError(error.HiddenFunctionSelectorControl, validate("wide\xe3\x80\x80space"));
    try std.testing.expectError(error.InvalidFunctionSelectorUtf8, validate("bad\xff"));
    const oversized = [_]u8{'x'} ** (max_selector_bytes + 1);
    try std.testing.expectError(error.FunctionSelectorTooLong, validate(&oversized));
}
