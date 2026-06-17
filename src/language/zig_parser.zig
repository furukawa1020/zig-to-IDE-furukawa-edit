const std = @import("std");
const ast = @import("zig_ast.zig");
const tokenizer = @import("zig_tokenizer.zig");
const types = @import("../core/types.zig");

pub const ParseResult = struct {
    nodes: []ast.Node,
    diagnostics: usize = 0,
};

pub fn parseTopLevel(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var nodes = std.ArrayList(ast.Node).init(allocator);
    errdefer nodes.deinit();

    try nodes.append(.{
        .tag = .root,
        .range = .{ .start = types.Position.start(), .end = .{ .line = 0, .column = 0, .byte_offset = source.len } },
    });

    var lexer = tokenizer.Tokenizer.init(source);
    while (true) {
        const token = lexer.next();
        if (token.tag == .eof) break;
        if (token.tag == .keyword and std.mem.eql(u8, source[token.start..token.end], "fn")) {
            try nodes.append(.{
                .tag = .function_decl,
                .range = .{
                    .start = .{ .line = 0, .column = 0, .byte_offset = token.start },
                    .end = .{ .line = 0, .column = 0, .byte_offset = token.end },
                },
                .parent = 0,
            });
        }
    }

    return .{ .nodes = try nodes.toOwnedSlice() };
}

