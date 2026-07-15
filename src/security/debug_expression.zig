const std = @import("std");
const text_integrity = @import("text_integrity.zig");

pub const max_expression_bytes: usize = 4096;

pub const Classification = enum {
    inspection,
    potentially_executing,
    invalid,
};

pub fn classify(raw: []const u8) Classification {
    const expression = std.mem.trim(u8, raw, " \t\r\n");
    if (expression.len == 0 or expression.len > max_expression_bytes) return .invalid;
    if (!std.unicode.utf8ValidateSlice(expression)) return .invalid;

    var bracket_depth: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    var saw_token = false;

    for (expression, 0..) |byte, index| {
        if (text_integrity.hiddenControlLengthAt(expression, index) != null) return .invalid;
        if (byte == 0 or (byte < 0x20 and byte != ' ' and byte != '\t')) return .invalid;
        if (quote) |delimiter| {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == delimiter) {
                quote = null;
            }
            continue;
        }

        switch (byte) {
            '\'', '"' => {
                if (bracket_depth == 0) return .potentially_executing;
                quote = byte;
                saw_token = true;
            },
            '[' => {
                bracket_depth += 1;
                if (bracket_depth > 32) return .invalid;
            },
            ']' => {
                if (bracket_depth == 0) return .invalid;
                bracket_depth -= 1;
            },
            '(', ')', '=', ';', '{', '}', '`', ',' => return .potentially_executing,
            '+', '/', '%', '!', '&', '|', '^', '~' => return .potentially_executing,
            '-' => {
                const next = if (index + 1 < expression.len) expression[index + 1] else 0;
                if (next != '>' and !(bracket_depth > 0 and std.ascii.isDigit(next))) return .potentially_executing;
            },
            '*' => {
                const previous = if (index > 0) expression[index - 1] else 0;
                if (previous != '.') return .potentially_executing;
            },
            ' ', '\t' => return .potentially_executing,
            '>' => {
                const previous = if (index > 0) expression[index - 1] else 0;
                if (previous != '-') return .potentially_executing;
            },
            '?' => {
                const previous = if (index > 0) expression[index - 1] else 0;
                if (previous != '.') return .potentially_executing;
            },
            ':' => {
                const previous = if (index > 0) expression[index - 1] else 0;
                const next = if (index + 1 < expression.len) expression[index + 1] else 0;
                if (bracket_depth == 0 and previous != ':' and next != ':') return .potentially_executing;
            },
            '.', '$' => {},
            else => {
                if (byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_') {
                    saw_token = true;
                } else {
                    return .potentially_executing;
                }
            },
        }
    }

    if (!saw_token or quote != null or bracket_depth != 0 or escaped) return .invalid;
    return .inspection;
}

pub fn rejectionMessage(classification: Classification) []const u8 {
    return switch (classification) {
        .inspection => "",
        .potentially_executing => "watch rejected: calls, assignments, statements, and operator expressions require the future consent-gated debug REPL",
        .invalid => "watch rejected: expression is empty, malformed, invalid UTF-8, or exceeds 4096 bytes",
    };
}

test "inspection-shaped debug expressions are accepted" {
    try std.testing.expectEqual(Classification.inspection, classify("state.worker.items[3].name"));
    try std.testing.expectEqual(Classification.inspection, classify("map[\"safe-key\"]"));
    try std.testing.expectEqual(Classification.inspection, classify("ptr->field"));
    try std.testing.expectEqual(Classification.inspection, classify("optional.?"));
    try std.testing.expectEqual(Classification.inspection, classify("value.*"));
    try std.testing.expectEqual(Classification.inspection, classify("namespace::value[-1]"));
}

test "potentially executing debug expressions are rejected" {
    try std.testing.expectEqual(Classification.potentially_executing, classify("run()"));
    try std.testing.expectEqual(Classification.potentially_executing, classify("value = 1"));
    try std.testing.expectEqual(Classification.potentially_executing, classify("items[0] + items[1]"));
    try std.testing.expectEqual(Classification.potentially_executing, classify("a; system('x')"));
    try std.testing.expectEqual(Classification.potentially_executing, classify("left > right"));
    try std.testing.expectEqual(Classification.potentially_executing, classify("new Thing"));
    try std.testing.expectEqual(Classification.potentially_executing, classify("\"root literal\""));
}

test "malformed debug expressions are invalid" {
    try std.testing.expectEqual(Classification.invalid, classify(""));
    try std.testing.expectEqual(Classification.invalid, classify("items[0"));
    try std.testing.expectEqual(Classification.invalid, classify("map[\"key]"));
    try std.testing.expectEqual(Classification.invalid, classify(&.{ 0xff, 0xfe }));
    try std.testing.expectEqual(Classification.invalid, classify("safe\xe2\x80\xaefile"));
}
