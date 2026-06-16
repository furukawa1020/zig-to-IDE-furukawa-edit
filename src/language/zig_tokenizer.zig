const std = @import("std");

pub const TokenTag = enum {
    eof,
    identifier,
    builtin_identifier,
    keyword,
    string_literal,
    multiline_string_literal,
    char_literal,
    integer_literal,
    float_literal,
    comment,
    doc_comment,
    operator,
    punctuation,
    invalid,
};

pub const Token = struct {
    tag: TokenTag,
    start: usize,
    end: usize,
};

pub const Tokenizer = struct {
    source: []const u8,
    index: usize,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source, .index = 0 };
    }

    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespace();

        const start = self.index;
        if (start >= self.source.len) {
            return .{ .tag = .eof, .start = start, .end = start };
        }

        const c = self.source[start];

        if (isIdentifierStart(c)) return self.identifier();
        if (std.ascii.isDigit(c)) return self.number();
        if (c == '@' and self.index + 1 < self.source.len and isIdentifierStart(self.source[self.index + 1])) {
            return self.builtinIdentifier();
        }
        if (c == '/' and self.peek(1) == '/') return self.lineComment();
        if (c == '"' ) return self.quoted(.string_literal, '"');
        if (c == '\'') return self.quoted(.char_literal, '\'');
        if (c == '\\' and self.peek(1) == '\\') return self.multilineStringLine();
        if (isPunctuation(c)) {
            self.index += 1;
            return .{ .tag = .punctuation, .start = start, .end = self.index };
        }
        if (isOperatorByte(c)) return self.operator();

        self.index += 1;
        return .{ .tag = .invalid, .start = start, .end = self.index };
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.index < self.source.len) : (self.index += 1) {
            switch (self.source[self.index]) {
                ' ', '\t', '\r', '\n' => {},
                else => break,
            }
        }
    }

    fn identifier(self: *Tokenizer) Token {
        const start = self.index;
        self.index += 1;
        while (self.index < self.source.len and isIdentifierContinue(self.source[self.index])) {
            self.index += 1;
        }
        const slice = self.source[start..self.index];
        return .{
            .tag = if (isKeyword(slice)) .keyword else .identifier,
            .start = start,
            .end = self.index,
        };
    }

    fn builtinIdentifier(self: *Tokenizer) Token {
        const start = self.index;
        self.index += 2;
        while (self.index < self.source.len and isIdentifierContinue(self.source[self.index])) {
            self.index += 1;
        }
        return .{ .tag = .builtin_identifier, .start = start, .end = self.index };
    }

    fn number(self: *Tokenizer) Token {
        const start = self.index;
        var tag: TokenTag = .integer_literal;
        while (self.index < self.source.len and isNumberContinue(self.source[self.index])) {
            self.index += 1;
        }
        if (self.index < self.source.len and self.source[self.index] == '.' and self.peek(1) != '.') {
            tag = .float_literal;
            self.index += 1;
            while (self.index < self.source.len and isNumberContinue(self.source[self.index])) {
                self.index += 1;
            }
        }
        return .{ .tag = tag, .start = start, .end = self.index };
    }

    fn lineComment(self: *Tokenizer) Token {
        const start = self.index;
        self.index += 2;
        const tag: TokenTag = if (self.index < self.source.len and (self.source[self.index] == '/' or self.source[self.index] == '!'))
            .doc_comment
        else
            .comment;
        while (self.index < self.source.len and self.source[self.index] != '\n') {
            self.index += 1;
        }
        return .{ .tag = tag, .start = start, .end = self.index };
    }

    fn quoted(self: *Tokenizer, tag: TokenTag, quote: u8) Token {
        const start = self.index;
        self.index += 1;
        var escaped = false;
        while (self.index < self.source.len) : (self.index += 1) {
            const c = self.source[self.index];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == quote) {
                self.index += 1;
                return .{ .tag = tag, .start = start, .end = self.index };
            }
            if (c == '\n') break;
        }
        return .{ .tag = .invalid, .start = start, .end = self.index };
    }

    fn multilineStringLine(self: *Tokenizer) Token {
        const start = self.index;
        self.index += 2;
        while (self.index < self.source.len and self.source[self.index] != '\n') {
            self.index += 1;
        }
        return .{ .tag = .multiline_string_literal, .start = start, .end = self.index };
    }

    fn operator(self: *Tokenizer) Token {
        const start = self.index;
        while (self.index < self.source.len and isOperatorByte(self.source[self.index])) {
            self.index += 1;
        }
        return .{ .tag = .operator, .start = start, .end = self.index };
    }

    fn peek(self: *const Tokenizer, offset: usize) u8 {
        const at = self.index + offset;
        if (at >= self.source.len) return 0;
        return self.source[at];
    }
};

const keywords = [_][]const u8{
    "addrspace",
    "align",
    "allowzero",
    "and",
    "anyframe",
    "anytype",
    "asm",
    "async",
    "await",
    "break",
    "callconv",
    "catch",
    "comptime",
    "const",
    "continue",
    "defer",
    "else",
    "enum",
    "errdefer",
    "error",
    "export",
    "extern",
    "fn",
    "for",
    "if",
    "inline",
    "linksection",
    "noalias",
    "noinline",
    "nosuspend",
    "opaque",
    "or",
    "orelse",
    "packed",
    "pub",
    "resume",
    "return",
    "struct",
    "suspend",
    "switch",
    "test",
    "threadlocal",
    "try",
    "union",
    "unreachable",
    "usingnamespace",
    "var",
    "volatile",
    "while",
};

fn isKeyword(slice: []const u8) bool {
    for (keywords) |keyword| {
        if (std.mem.eql(u8, keyword, slice)) return true;
    }
    return false;
}

fn isIdentifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentifierContinue(c: u8) bool {
    return isIdentifierStart(c) or std.ascii.isDigit(c);
}

fn isNumberContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isPunctuation(c: u8) bool {
    return switch (c) {
        '(', ')', '{', '}', '[', ']', ';', ',', ':' => true,
        else => false,
    };
}

fn isOperatorByte(c: u8) bool {
    return switch (c) {
        '.', '+', '-', '*', '/', '%', '=', '!', '<', '>', '&', '|', '^', '~', '?' => true,
        else => false,
    };
}

test "tokenizes Zig declarations" {
    var tokenizer = Tokenizer.init("pub fn add(a: i32) i32 { return a + 1; }");
    try std.testing.expectEqual(TokenTag.keyword, tokenizer.next().tag);
    try std.testing.expectEqual(TokenTag.keyword, tokenizer.next().tag);
    try std.testing.expectEqual(TokenTag.identifier, tokenizer.next().tag);
}

test "keeps incomplete string as invalid token" {
    var tokenizer = Tokenizer.init("\"unterminated");
    const token = tokenizer.next();
    try std.testing.expectEqual(TokenTag.invalid, token.tag);
}

