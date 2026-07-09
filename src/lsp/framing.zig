const std = @import("std");

pub const Frame = struct {
    content_length: usize,
    header_bytes: usize,
    body: []const u8,
};

pub const OwnedFrame = struct {
    allocator: std.mem.Allocator,
    content_length: usize,
    body: []u8,

    pub fn deinit(self: *OwnedFrame) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn encode(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{s}",
        .{ payload.len, payload },
    );
}

pub fn parse(buffer: []const u8) !Frame {
    const header_end = findHeaderEnd(buffer) orelse return error.IncompleteFrame;
    const headers = buffer[0 .. header_end - 4];
    const content_length = try parseContentLength(headers);
    const body_start = header_end;
    const body_end = body_start + content_length;
    if (body_end > buffer.len) return error.IncompleteFrame;
    return .{
        .content_length = content_length,
        .header_bytes = header_end,
        .body = buffer[body_start..body_end],
    };
}

pub fn parseOwned(allocator: std.mem.Allocator, buffer: []const u8) !OwnedFrame {
    const frame = try parse(buffer);
    return .{
        .allocator = allocator,
        .content_length = frame.content_length,
        .body = try allocator.dupe(u8, frame.body),
    };
}

pub fn findHeaderEnd(buffer: []const u8) ?usize {
    const marker = "\r\n\r\n";
    var index: usize = 0;
    while (index + marker.len <= buffer.len) : (index += 1) {
        if (std.mem.eql(u8, buffer[index .. index + marker.len], marker)) return index + marker.len;
    }
    return null;
}

fn parseContentLength(headers: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..separator], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (value.len == 0) return error.InvalidContentLength;
        return std.fmt.parseInt(usize, value, 10) catch error.InvalidContentLength;
    }
    return error.MissingContentLength;
}

test "encode and parse LSP frame" {
    const payload = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const frame_bytes = try encode(std.testing.allocator, payload);
    defer std.testing.allocator.free(frame_bytes);

    const frame = try parse(frame_bytes);
    try std.testing.expectEqual(payload.len, frame.content_length);
    try std.testing.expectEqualStrings(payload, frame.body);
}

test "parse waits for complete body" {
    try std.testing.expectError(error.IncompleteFrame, parse("Content-Length: 10\r\n\r\nabc"));
}
