const std = @import("std");
const modes = @import("modes.zig");
const zig_tokenizer = @import("zig_tokenizer.zig");

pub const Role = enum {
    plain,
    keyword,
    type_name,
    string,
    number,
    comment,
    doc_comment,
    builtin,
    operator,
    punctuation,
    unsafe_boundary,
};

pub const Span = struct {
    start: usize,
    end: usize,
    role: Role,
};

pub fn collectLine(allocator: std.mem.Allocator, line: []const u8, mode: modes.LanguageMode) ![]Span {
    if (line.len == 0) return allocator.alloc(Span, 0);
    if (modes.isZigFamily(mode)) return collectZigLine(allocator, line);
    return collectGenericLine(allocator, line, mode);
}

fn collectZigLine(allocator: std.mem.Allocator, line: []const u8) ![]Span {
    var spans = std.array_list.Managed(Span).init(allocator);
    errdefer spans.deinit();

    var tokenizer = zig_tokenizer.Tokenizer.init(line);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        const role: Role = switch (token.tag) {
            .keyword => .keyword,
            .builtin_identifier => if (isUnsafeZigBuiltin(line[token.start..token.end])) .unsafe_boundary else .builtin,
            .string_literal, .multiline_string_literal, .char_literal => .string,
            .integer_literal, .float_literal => .number,
            .comment => .comment,
            .doc_comment => .doc_comment,
            .operator => .operator,
            .punctuation => .punctuation,
            .identifier => if (looksLikeTypeName(line[token.start..token.end])) .type_name else .plain,
            .invalid => .unsafe_boundary,
            .eof => unreachable,
        };
        try spans.append(.{ .start = token.start, .end = token.end, .role = role });
    }

    return spans.toOwnedSlice();
}

fn collectGenericLine(allocator: std.mem.Allocator, line: []const u8, mode: modes.LanguageMode) ![]Span {
    var spans = std.array_list.Managed(Span).init(allocator);
    errdefer spans.deinit();

    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == ' ' or line[i] == '\t') {
            i += 1;
            continue;
        }

        if (commentStart(line, i, mode)) |role| {
            try spans.append(.{ .start = i, .end = line.len, .role = role });
            break;
        }

        if (line[i] == '"' or line[i] == '\'' or line[i] == '`') {
            const end = scanQuoted(line, i);
            try spans.append(.{ .start = i, .end = end, .role = .string });
            i = end;
            continue;
        }

        if (std.ascii.isDigit(line[i])) {
            const start = i;
            i += 1;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_' or line[i] == '.')) : (i += 1) {}
            try spans.append(.{ .start = start, .end = i, .role = .number });
            continue;
        }

        if (isIdentifierStart(line[i])) {
            const start = i;
            i += 1;
            while (i < line.len and isIdentifierContinue(line[i])) : (i += 1) {}
            const text = line[start..i];
            try spans.append(.{ .start = start, .end = i, .role = genericIdentifierRole(text, mode) });
            continue;
        }

        const role: Role = if (isPunctuation(line[i])) .punctuation else .operator;
        try spans.append(.{ .start = i, .end = i + 1, .role = role });
        i += 1;
    }

    return spans.toOwnedSlice();
}

fn commentStart(line: []const u8, index: usize, mode: modes.LanguageMode) ?Role {
    if (modes.blockComment(mode)) |block| {
        if (startsAt(line, index, block.start)) return .comment;
    }
    if (modes.lineComment(mode)) |prefix| {
        if (startsAtIgnoreCase(line, index, prefix)) return .comment;
    }
    return null;
}

fn scanQuoted(line: []const u8, start: usize) usize {
    const quote = line[start];
    var i = start + 1;
    var escaped = false;
    while (i < line.len) : (i += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (line[i] == '\\') {
            escaped = true;
            continue;
        }
        if (line[i] == quote) return i + 1;
    }
    return line.len;
}

fn genericIdentifierRole(text: []const u8, mode: modes.LanguageMode) Role {
    if (isDangerousGenericIdentifier(text, mode)) return .unsafe_boundary;
    if (isKeyword(text, mode)) return .keyword;
    if (looksLikeTypeName(text)) return .type_name;
    return .plain;
}

fn isKeyword(text: []const u8, mode: modes.LanguageMode) bool {
    const family = modes.family(mode);
    if (family == .web) {
        return inList(text, &.{ "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "else", "export", "extends", "for", "from", "function", "if", "import", "interface", "let", "new", "return", "switch", "throw", "try", "type", "var", "while" });
    }
    if (family == .native) {
        return inList(text, &.{ "as", "break", "case", "class", "const", "continue", "contract", "data", "defer", "else", "enum", "event", "extern", "for", "fn", "func", "function", "if", "impl", "import", "in", "interface", "let", "mapping", "match", "method", "modifier", "module", "mut", "namespace", "object", "package", "payable", "private", "pub", "public", "pure", "return", "static", "struct", "switch", "template", "type", "unsafe", "using", "var", "view", "where", "while" });
    }
    if (family == .script) {
        return inList(text, &.{ "and", "begin", "break", "catch", "class", "def", "defmodule", "do", "else", "elseif", "end", "except", "finally", "for", "fn", "function", "if", "in", "lambda", "let", "local", "module", "nil", "not", "or", "receive", "return", "then", "try", "unless", "when", "while", "yield" });
    }
    return switch (mode) {
        .json, .yaml, .toml, .hcl => inList(text, &.{ "true", "false", "null" }),
        .sql => inList(text, &.{ "select", "from", "where", "join", "insert", "update", "delete", "create", "drop", "alter", "table", "index", "into", "values", "and", "or", "not", "null" }),
        .graphql => inList(text, &.{ "query", "mutation", "subscription", "fragment", "type", "interface", "union", "enum", "input", "schema" }),
        .proto => inList(text, &.{ "syntax", "package", "message", "service", "rpc", "returns", "option", "repeated", "oneof", "reserved", "import" }),
        .cmake => inList(text, &.{ "add_executable", "add_library", "add_subdirectory", "cmake_minimum_required", "execute_process", "find_package", "include", "project", "set" }),
        else => false,
    };
}

fn isDangerousGenericIdentifier(text: []const u8, mode: modes.LanguageMode) bool {
    if (inList(text, &.{ "eval", "exec", "system", "subprocess", "child_process", "shell_exec", "popen", "pickle", "unsafe", "syscall", "Invoke-Expression", "ProcessBuilder", "Runtime", "DllImport", "Assembly", "dlopen", "delegatecall", "selfdestruct", "tx.origin", "loadstring", "unsafePerformIO", "Obj.magic" })) return true;
    return switch (mode) {
        .c, .cpp => inList(text, &.{ "gets", "strcpy", "sprintf" }),
        .rust => std.ascii.eqlIgnoreCase(text, "unsafe"),
        .solidity => inList(text, &.{ "delegatecall", "selfdestruct" }),
        else => false,
    };
}

fn inList(text: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.ascii.eqlIgnoreCase(text, item)) return true;
    }
    return false;
}

fn isUnsafeZigBuiltin(text: []const u8) bool {
    return inList(text, &.{ "@ptrCast", "@alignCast", "@ptrFromInt", "@fieldParentPtr", "@addrSpaceCast", "@constCast", "@volatileCast", "@cImport", "@setRuntimeSafety", "@embedFile" });
}

fn looksLikeTypeName(text: []const u8) bool {
    if (text.len == 0) return false;
    return std.ascii.isUpper(text[0]) or inList(text, &.{ "usize", "isize", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "bool", "void", "anytype" });
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte) or byte == '-';
}

fn isPunctuation(byte: u8) bool {
    return switch (byte) {
        '(', ')', '{', '}', '[', ']', ';', ',', ':', '.' => true,
        else => false,
    };
}

fn startsAt(line: []const u8, index: usize, prefix: []const u8) bool {
    if (index + prefix.len > line.len) return false;
    return std.mem.eql(u8, line[index .. index + prefix.len], prefix);
}

fn startsAtIgnoreCase(line: []const u8, index: usize, prefix: []const u8) bool {
    if (index + prefix.len > line.len) return false;
    return std.ascii.eqlIgnoreCase(line[index .. index + prefix.len], prefix);
}

test "highlights Zig unsafe builtin" {
    const spans = try collectLine(std.testing.allocator, "const p = @ptrFromInt(x);", .zig);
    defer std.testing.allocator.free(spans);

    var found = false;
    for (spans) |span| {
        if (span.role == .unsafe_boundary) found = true;
    }
    try std.testing.expect(found);
}

test "highlights JS dynamic execution" {
    const spans = try collectLine(std.testing.allocator, "eval(input) // no", .javascript);
    defer std.testing.allocator.free(spans);

    try std.testing.expect(spans.len >= 2);
    try std.testing.expectEqual(Role.unsafe_boundary, spans[0].role);
    try std.testing.expectEqual(Role.comment, spans[spans.len - 1].role);
}

test "highlights extended language comments and boundaries" {
    const py = try collectLine(std.testing.allocator, "value = 1 # comment", .python);
    defer std.testing.allocator.free(py);
    try std.testing.expectEqual(Role.comment, py[py.len - 1].role);

    const html = try collectLine(std.testing.allocator, "<!-- note -->", .html);
    defer std.testing.allocator.free(html);
    try std.testing.expectEqual(Role.comment, html[0].role);

    const sol = try collectLine(std.testing.allocator, "delegatecall(payload);", .solidity);
    defer std.testing.allocator.free(sol);
    try std.testing.expectEqual(Role.unsafe_boundary, sol[0].role);
}
