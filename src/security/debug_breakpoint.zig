const std = @import("std");
const debug_expression = @import("debug_expression.zig");
const text_integrity = @import("text_integrity.zig");

pub const max_condition_bytes: usize = 4096;
pub const max_hit_condition_bytes: usize = 20;
pub const max_log_message_bytes: usize = 8192;
const max_group_depth: usize = 16;
const max_predicate_atoms: usize = 128;
const max_log_interpolations: usize = 64;

pub const Property = enum {
    condition,
    hit_condition,
    log_message,
};

pub const ValidationError = error{
    EmptyBreakpointValue,
    BreakpointValueTooLong,
    InvalidBreakpointUtf8,
    HiddenBreakpointControl,
    UnsafeBreakpointCondition,
    InvalidHitCondition,
    UnsafeLogMessage,
};

pub fn validate(property: Property, raw: []const u8) ValidationError![]const u8 {
    return switch (property) {
        .condition => validateCondition(raw),
        .hit_condition => validateHitCondition(raw),
        .log_message => validateLogMessage(raw),
    };
}

pub fn validateCondition(raw: []const u8) ValidationError![]const u8 {
    const condition = std.mem.trim(u8, raw, " \t\r\n");
    try validateText(condition, max_condition_bytes);
    var parser = PredicateParser{ .input = condition };
    try parser.parse();
    return condition;
}

pub fn validateHitCondition(raw: []const u8) ValidationError![]const u8 {
    const hit_condition = std.mem.trim(u8, raw, " \t\r\n");
    try validateText(hit_condition, max_hit_condition_bytes);
    for (hit_condition) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidHitCondition;
    }
    const count = std.fmt.parseInt(u64, hit_condition, 10) catch return error.InvalidHitCondition;
    if (count == 0) return error.InvalidHitCondition;
    return hit_condition;
}

pub fn validateLogMessage(raw: []const u8) ValidationError![]const u8 {
    const message = std.mem.trim(u8, raw, " \t\r\n");
    try validateText(message, max_log_message_bytes);

    var index: usize = 0;
    var interpolations: usize = 0;
    while (index < message.len) {
        switch (message[index]) {
            '{' => {
                const start = index + 1;
                var end = start;
                while (end < message.len and message[end] != '}') : (end += 1) {
                    if (message[end] == '{') return error.UnsafeLogMessage;
                }
                if (end >= message.len) return error.UnsafeLogMessage;
                const expression = std.mem.trim(u8, message[start..end], " \t");
                if (debug_expression.classify(expression) != .inspection) return error.UnsafeLogMessage;
                interpolations += 1;
                if (interpolations > max_log_interpolations) return error.UnsafeLogMessage;
                index = end + 1;
            },
            '}' => return error.UnsafeLogMessage,
            else => index += 1,
        }
    }
    return message;
}

pub fn rejectionMessage(property: Property, err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyBreakpointValue => switch (property) {
            .condition => "condition is empty",
            .hit_condition => "hit count is empty",
            .log_message => "log message is empty",
        },
        error.BreakpointValueTooLong => "breakpoint value exceeds its bounded size limit",
        error.InvalidBreakpointUtf8 => "breakpoint value is not valid UTF-8",
        error.HiddenBreakpointControl => "breakpoint value contains hidden or control characters",
        error.UnsafeBreakpointCondition => "condition rejected: use field/index reads, literals, comparisons, boolean operators, and grouping only",
        error.InvalidHitCondition => "hit count rejected: enter a positive base-10 integer",
        error.UnsafeLogMessage => "log message rejected: each {expression} must be a restricted inspection without calls, assignments, or operators",
        else => "invalid breakpoint value",
    };
}

fn validateText(value: []const u8, limit: usize) ValidationError!void {
    if (value.len == 0) return error.EmptyBreakpointValue;
    if (value.len > limit) return error.BreakpointValueTooLong;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidBreakpointUtf8;
    for (value, 0..) |byte, index| {
        if (text_integrity.hiddenControlLengthAt(value, index) != null) return error.HiddenBreakpointControl;
        if (byte == 0 or byte < 0x20 and byte != ' ' and byte != '\t') return error.HiddenBreakpointControl;
    }
}

const PredicateParser = struct {
    input: []const u8,
    index: usize = 0,
    group_depth: usize = 0,
    atom_count: usize = 0,
    expecting_operand: bool = true,

    fn parse(self: *PredicateParser) ValidationError!void {
        while (true) {
            self.skipSpaces();
            if (self.index >= self.input.len) break;

            if (self.expecting_operand and self.consumeKeyword("not")) continue;
            if (!self.expecting_operand and
                (self.consumeKeyword("and") or self.consumeKeyword("or") or
                    self.consumeKeyword("is") or self.consumeKeyword("in")))
            {
                self.expecting_operand = true;
                continue;
            }

            const byte = self.input[self.index];
            switch (byte) {
                '(' => {
                    if (!self.expecting_operand) return error.UnsafeBreakpointCondition;
                    self.group_depth += 1;
                    if (self.group_depth > max_group_depth) return error.UnsafeBreakpointCondition;
                    self.index += 1;
                },
                ')' => {
                    if (self.expecting_operand or self.group_depth == 0) return error.UnsafeBreakpointCondition;
                    self.group_depth -= 1;
                    self.index += 1;
                },
                '!' => {
                    if (self.index + 1 < self.input.len and self.input[self.index + 1] == '=') {
                        try self.consumeBinaryOperator(2);
                    } else {
                        if (!self.expecting_operand) return error.UnsafeBreakpointCondition;
                        self.index += 1;
                    }
                },
                '=' => {
                    if (self.index + 1 >= self.input.len or self.input[self.index + 1] != '=') return error.UnsafeBreakpointCondition;
                    try self.consumeBinaryOperator(2);
                },
                '<', '>' => try self.consumeBinaryOperator(if (self.index + 1 < self.input.len and self.input[self.index + 1] == '=') 2 else 1),
                '&' => {
                    if (self.index + 1 >= self.input.len or self.input[self.index + 1] != '&') return error.UnsafeBreakpointCondition;
                    try self.consumeBinaryOperator(2);
                },
                '|' => {
                    if (self.index + 1 >= self.input.len or self.input[self.index + 1] != '|') return error.UnsafeBreakpointCondition;
                    try self.consumeBinaryOperator(2);
                },
                else => {
                    if (!self.expecting_operand) return error.UnsafeBreakpointCondition;
                    const operand = try self.scanOperand();
                    if (!isRestrictedOperand(operand)) return error.UnsafeBreakpointCondition;
                    self.atom_count += 1;
                    if (self.atom_count > max_predicate_atoms) return error.UnsafeBreakpointCondition;
                    self.expecting_operand = false;
                },
            }
        }

        if (self.expecting_operand or self.group_depth != 0 or self.atom_count == 0) return error.UnsafeBreakpointCondition;
    }

    fn consumeBinaryOperator(self: *PredicateParser, length: usize) ValidationError!void {
        if (self.expecting_operand) return error.UnsafeBreakpointCondition;
        self.index += length;
        self.expecting_operand = true;
    }

    fn consumeKeyword(self: *PredicateParser, keyword: []const u8) bool {
        if (!std.mem.startsWith(u8, self.input[self.index..], keyword)) return false;
        const end = self.index + keyword.len;
        if (end < self.input.len and isIdentifierByte(self.input[end])) return false;
        self.index = end;
        return true;
    }

    fn scanOperand(self: *PredicateParser) ValidationError![]const u8 {
        const start = self.index;
        var bracket_depth: usize = 0;
        var quote: ?u8 = null;
        var escaped = false;

        while (self.index < self.input.len) : (self.index += 1) {
            const byte = self.input[self.index];
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
            if (byte == '\'' or byte == '"') {
                quote = byte;
                continue;
            }
            if (byte == '[') {
                bracket_depth += 1;
                if (bracket_depth > max_group_depth) return error.UnsafeBreakpointCondition;
                continue;
            }
            if (byte == ']') {
                if (bracket_depth == 0) return error.UnsafeBreakpointCondition;
                bracket_depth -= 1;
                continue;
            }
            if (bracket_depth == 0) {
                if (byte == ' ' or byte == '\t' or byte == '(' or byte == ')' or
                    byte == '=' or byte == '!' or byte == '<' or byte == '&' or byte == '|') break;
                if (byte == '>' and !(self.index > start and self.input[self.index - 1] == '-')) break;
            }
        }

        if (self.index == start or quote != null or escaped or bracket_depth != 0) return error.UnsafeBreakpointCondition;
        return self.input[start..self.index];
    }

    fn skipSpaces(self: *PredicateParser) void {
        while (self.index < self.input.len and (self.input[self.index] == ' ' or self.input[self.index] == '\t')) : (self.index += 1) {}
    }
};

fn isRestrictedOperand(value: []const u8) bool {
    if (debug_expression.classify(value) == .inspection) return true;
    if (isScalarLiteral(value)) return true;
    return false;
}

fn isScalarLiteral(value: []const u8) bool {
    if (value.len >= 2 and (value[0] == '\'' or value[0] == '"')) {
        if (value[value.len - 1] != value[0]) return false;
        var escaped = false;
        for (value[1 .. value.len - 1]) |byte| {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == value[0]) {
                return false;
            }
        }
        return !escaped;
    }

    var start: usize = 0;
    if (value[0] == '-') {
        if (value.len == 1) return false;
        start = 1;
    }
    if (!std.ascii.isDigit(value[start])) return false;
    for (value[start + 1 ..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '.') return false;
    }
    return true;
}

fn isIdentifierByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$';
}

test "restricted breakpoint predicates accept comparisons without calls" {
    try std.testing.expectEqualStrings("value > 4", try validateCondition(" value > 4 "));
    _ = try validateCondition("state.ready and items[0].name == \"zig\"");
    _ = try validateCondition("(left <= right || optional.? != null) && !failed");
    _ = try validateCondition("ptr->field == 9");
}

test "restricted breakpoint predicates reject executing and malformed syntax" {
    try std.testing.expectError(error.UnsafeBreakpointCondition, validateCondition("run()"));
    try std.testing.expectError(error.UnsafeBreakpointCondition, validateCondition("value = 4"));
    try std.testing.expectError(error.UnsafeBreakpointCondition, validateCondition("items[0] + items[1] > 2"));
    try std.testing.expectError(error.UnsafeBreakpointCondition, validateCondition("ready &&"));
    try std.testing.expectError(error.UnsafeBreakpointCondition, validateCondition("a; launch()"));
}

test "hit conditions are bounded positive decimal counts" {
    try std.testing.expectEqualStrings("25", try validateHitCondition(" 25 "));
    try std.testing.expectError(error.InvalidHitCondition, validateHitCondition("0"));
    try std.testing.expectError(error.InvalidHitCondition, validateHitCondition(">= 5"));
    try std.testing.expectError(error.InvalidHitCondition, validateHitCondition("1;run"));
}

test "log points allow only restricted interpolations" {
    try std.testing.expectEqualStrings("worker {state.worker.name}", try validateLogMessage("worker {state.worker.name}"));
    _ = try validateLogMessage("checkpoint reached");
    try std.testing.expectError(error.UnsafeLogMessage, validateLogMessage("value {compute()}"));
    try std.testing.expectError(error.UnsafeLogMessage, validateLogMessage("value {left + right}"));
    try std.testing.expectError(error.UnsafeLogMessage, validateLogMessage("value {missing"));
}
