const std = @import("std");
const tokenizer = @import("zig_tokenizer.zig");
const types = @import("../core/types.zig");

pub const SymbolKind = enum {
    package,
    file,
    import_alias,
    constant,
    variable,
    function,
    parameter,
    local,
    struct_type,
    struct_field,
    enum_type,
    enum_field,
    union_type,
    union_field,
    error_set,
    error_value,
    test_block,
    builtin,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    file_path: []const u8,
    range: types.Range,
    doc_comment: ?[]const u8 = null,
};

pub const SymbolIndex = struct {
    symbols: []const Symbol = &.{},
};

pub const OwnedIndex = struct {
    allocator: std.mem.Allocator,
    symbols: []Symbol,

    pub fn deinit(self: *OwnedIndex) void {
        for (self.symbols) |symbol| {
            self.allocator.free(symbol.name);
            self.allocator.free(symbol.file_path);
            if (symbol.doc_comment) |doc| self.allocator.free(doc);
        }
        self.allocator.free(self.symbols);
        self.* = undefined;
    }
};

pub fn collectTopLevel(allocator: std.mem.Allocator, source: []const u8, file_path: []const u8) !OwnedIndex {
    var tokens = std.array_list.Managed(tokenizer.Token).init(allocator);
    defer tokens.deinit();

    var lexer = tokenizer.Tokenizer.init(source);
    while (true) {
        const token = lexer.next();
        try tokens.append(token);
        if (token.tag == .eof) break;
    }

    var symbols = std.array_list.Managed(Symbol).init(allocator);
    errdefer {
        for (symbols.items) |symbol| {
            allocator.free(symbol.name);
            allocator.free(symbol.file_path);
            if (symbol.doc_comment) |doc| allocator.free(doc);
        }
        symbols.deinit();
    }

    var depth: usize = 0;
    var i: usize = 0;
    while (i < tokens.items.len) : (i += 1) {
        const token = tokens.items[i];
        if (token.tag == .eof) break;

        if (depth == 0) {
            if (isKeyword(source, token, "pub")) {
                if (nextSignificant(tokens.items, i + 1)) |next| {
                    try parseDeclaration(allocator, source, file_path, tokens.items, next, &symbols);
                }
            } else if (!previousSignificantIsKeyword(source, tokens.items, i, "pub")) {
                try parseDeclaration(allocator, source, file_path, tokens.items, i, &symbols);
            }
        }

        if (token.tag == .punctuation) {
            const text = tokenText(source, token);
            if (std.mem.eql(u8, text, "{")) {
                depth += 1;
            } else if (std.mem.eql(u8, text, "}") and depth > 0) {
                depth -= 1;
            }
        }
    }

    return .{
        .allocator = allocator,
        .symbols = try symbols.toOwnedSlice(),
    };
}

fn parseDeclaration(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    tokens: []const tokenizer.Token,
    index: usize,
    symbols: *std.array_list.Managed(Symbol),
) !void {
    const token = tokens[index];
    if (isKeyword(source, token, "fn")) {
        const name_index = nextSignificant(tokens, index + 1) orelse return;
        const name_token = tokens[name_index];
        if (name_token.tag != .identifier) return;
        try appendSymbol(allocator, source, file_path, name_token, .function, symbols);
        return;
    }

    if (isKeyword(source, token, "const") or isKeyword(source, token, "var")) {
        const name_index = nextSignificant(tokens, index + 1) orelse return;
        const name_token = tokens[name_index];
        if (name_token.tag != .identifier) return;
        const base_kind: SymbolKind = if (isKeyword(source, token, "const")) .constant else .variable;
        const kind = inferValueKind(source, tokens, name_index + 1, base_kind);
        try appendSymbol(allocator, source, file_path, name_token, kind, symbols);
        return;
    }

    if (isKeyword(source, token, "test")) {
        const name_index = nextSignificant(tokens, index + 1);
        const name_slice = if (name_index) |candidate| testName(source, tokens[candidate]) else "test";
        const start_token = if (name_index) |candidate| tokens[candidate] else token;
        try appendNamedSymbol(allocator, source, file_path, name_slice, start_token.start, start_token.end, .test_block, symbols);
        return;
    }
}

fn inferValueKind(source: []const u8, tokens: []const tokenizer.Token, start: usize, fallback: SymbolKind) SymbolKind {
    var i = start;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (token.tag == .eof) break;
        if (token.tag == .punctuation and std.mem.eql(u8, tokenText(source, token), ";")) break;
        if (token.tag == .punctuation and std.mem.eql(u8, tokenText(source, token), "{")) break;
        if (isKeyword(source, token, "struct")) return .struct_type;
        if (isKeyword(source, token, "enum")) return .enum_type;
        if (isKeyword(source, token, "union")) return .union_type;
        if (isKeyword(source, token, "error")) return .error_set;
    }
    return fallback;
}

fn appendSymbol(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    name_token: tokenizer.Token,
    kind: SymbolKind,
    symbols: *std.array_list.Managed(Symbol),
) !void {
    try appendNamedSymbol(allocator, source, file_path, tokenText(source, name_token), name_token.start, name_token.end, kind, symbols);
}

fn appendNamedSymbol(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    name: []const u8,
    start: usize,
    end: usize,
    kind: SymbolKind,
    symbols: *std.array_list.Managed(Symbol),
) !void {
    const position = positionFromOffset(source, start);
    const end_position = positionFromOffset(source, end);
    try symbols.append(.{
        .name = try allocator.dupe(u8, name),
        .kind = kind,
        .file_path = try allocator.dupe(u8, file_path),
        .range = .{ .start = position, .end = end_position },
        .doc_comment = null,
    });
}

fn nextSignificant(tokens: []const tokenizer.Token, start: usize) ?usize {
    var i = start;
    while (i < tokens.len) : (i += 1) {
        switch (tokens[i].tag) {
            .comment, .doc_comment => continue,
            .eof => return null,
            else => return i,
        }
    }
    return null;
}

fn previousSignificantIsKeyword(source: []const u8, tokens: []const tokenizer.Token, index: usize, keyword: []const u8) bool {
    if (index == 0) return false;
    var i = index;
    while (i > 0) {
        i -= 1;
        switch (tokens[i].tag) {
            .comment, .doc_comment => continue,
            else => return isKeyword(source, tokens[i], keyword),
        }
    }
    return false;
}

fn testName(source: []const u8, token: tokenizer.Token) []const u8 {
    const text = tokenText(source, token);
    if (token.tag == .string_literal and text.len >= 2) return text[1 .. text.len - 1];
    if (token.tag == .identifier) return text;
    return "test";
}

fn isKeyword(source: []const u8, token: tokenizer.Token, keyword: []const u8) bool {
    return token.tag == .keyword and std.mem.eql(u8, tokenText(source, token), keyword);
}

fn tokenText(source: []const u8, token: tokenizer.Token) []const u8 {
    return source[token.start..token.end];
}

fn positionFromOffset(source: []const u8, offset: usize) types.Position {
    var line: usize = 0;
    var column: usize = 0;
    var i: usize = 0;
    const limit = @min(offset, source.len);
    while (i < limit) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column, .byte_offset = limit };
}

test "collects top level Zig declarations" {
    var index = try collectTopLevel(std.testing.allocator,
        \\pub const App = struct {};
        \\const answer = 42;
        \\pub fn main() void {}
        \\test "adds" {}
        \\
    , "src/main.zig");
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 4), index.symbols.len);
    try std.testing.expectEqual(SymbolKind.struct_type, index.symbols[0].kind);
    try std.testing.expectEqualStrings("App", index.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.function, index.symbols[2].kind);
    try std.testing.expectEqualStrings("main", index.symbols[2].name);
    try std.testing.expectEqual(SymbolKind.test_block, index.symbols[3].kind);
}
