const std = @import("std");

pub const Parsed = struct {
    allocator: std.mem.Allocator,
    executable: []const u8,
    args: []const []const u8,

    pub fn deinit(self: *Parsed) void {
        self.allocator.free(self.executable);
        for (self.args) |arg| self.allocator.free(arg);
        self.allocator.free(self.args);
        self.* = undefined;
    }
};

pub const ParseError = error{
    EmptyCommand,
    UnclosedQuote,
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) (ParseError || std.mem.Allocator.Error)!Parsed {
    var tokens = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (tokens.items) |token| allocator.free(token);
        tokens.deinit();
    }

    var index: usize = 0;
    while (true) {
        while (index < input.len and std.ascii.isWhitespace(input[index])) : (index += 1) {}
        if (index >= input.len) break;

        const token = try parseToken(allocator, input, &index);
        tokens.append(token) catch |err| {
            allocator.free(token);
            return err;
        };
    }

    if (tokens.items.len == 0) return error.EmptyCommand;

    const executable = tokens.orderedRemove(0);
    errdefer allocator.free(executable);

    return .{
        .allocator = allocator,
        .executable = executable,
        .args = try tokens.toOwnedSlice(),
    };
}

fn parseToken(allocator: std.mem.Allocator, input: []const u8, index: *usize) (ParseError || std.mem.Allocator.Error)![]const u8 {
    var token = std.array_list.Managed(u8).init(allocator);
    errdefer token.deinit();

    var quote: ?u8 = null;
    var started = false;
    while (index.* < input.len) : (index.* += 1) {
        const byte = input[index.*];

        if (quote) |quote_byte| {
            started = true;
            if (byte == quote_byte) {
                quote = null;
                continue;
            }
            if (byte == '\\' and quote_byte == '"' and index.* + 1 < input.len) {
                index.* += 1;
                try token.append(input[index.*]);
                continue;
            }
            try token.append(byte);
            continue;
        }

        if (std.ascii.isWhitespace(byte)) break;
        started = true;
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == '\\' and index.* + 1 < input.len) {
            index.* += 1;
            try token.append(input[index.*]);
            continue;
        }
        try token.append(byte);
    }

    if (quote != null) return error.UnclosedQuote;
    if (!started) return error.EmptyCommand;
    return try token.toOwnedSlice();
}

test "parse plain command line" {
    var parsed = try parse(std.testing.allocator, "zig build test");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("zig", parsed.executable);
    try std.testing.expectEqual(@as(usize, 2), parsed.args.len);
    try std.testing.expectEqualStrings("build", parsed.args[0]);
    try std.testing.expectEqualStrings("test", parsed.args[1]);
}

test "parse quoted arguments and escapes" {
    var parsed = try parse(std.testing.allocator, "git commit -m \"hello zide\" path\\ with\\ spaces");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("git", parsed.executable);
    try std.testing.expectEqual(@as(usize, 4), parsed.args.len);
    try std.testing.expectEqualStrings("commit", parsed.args[0]);
    try std.testing.expectEqualStrings("-m", parsed.args[1]);
    try std.testing.expectEqualStrings("hello zide", parsed.args[2]);
    try std.testing.expectEqualStrings("path with spaces", parsed.args[3]);
}

test "parse empty quoted argument" {
    var parsed = try parse(std.testing.allocator, "echo \"\"");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("echo", parsed.executable);
    try std.testing.expectEqual(@as(usize, 1), parsed.args.len);
    try std.testing.expectEqualStrings("", parsed.args[0]);
}

test "reject empty and unclosed command lines" {
    try std.testing.expectError(error.EmptyCommand, parse(std.testing.allocator, "   \t"));
    try std.testing.expectError(error.UnclosedQuote, parse(std.testing.allocator, "echo \"open"));
}
