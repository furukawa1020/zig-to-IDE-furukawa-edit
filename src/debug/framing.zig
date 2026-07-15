const std = @import("std");

pub const max_payload_bytes: usize = 8 * 1024 * 1024;
pub const max_header_bytes: usize = 16 * 1024;

pub const Frame = struct {
    content_length: usize,
    consumed_bytes: usize,
    body: []const u8,
};

pub const OwnedFrame = struct {
    allocator: std.mem.Allocator,
    body: []u8,

    pub fn deinit(self: *OwnedFrame) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn encode(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    if (payload.len > max_payload_bytes) return error.FrameTooLarge;
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
}

pub fn parse(buffer: []const u8) !Frame {
    const header_end = findHeaderEnd(buffer) orelse {
        if (buffer.len > max_header_bytes) return error.HeaderTooLarge;
        return error.IncompleteFrame;
    };
    if (header_end > max_header_bytes) return error.HeaderTooLarge;

    const content_length = try parseContentLength(buffer[0 .. header_end - 4]);
    if (content_length > max_payload_bytes) return error.FrameTooLarge;
    const body_end = std.math.add(usize, header_end, content_length) catch return error.FrameTooLarge;
    if (body_end > buffer.len) return error.IncompleteFrame;
    return .{
        .content_length = content_length,
        .consumed_bytes = body_end,
        .body = buffer[header_end..body_end],
    };
}

fn findHeaderEnd(buffer: []const u8) ?usize {
    const marker = "\r\n\r\n";
    return if (std.mem.indexOf(u8, buffer, marker)) |index| index + marker.len else null;
}

fn parseContentLength(headers: []const u8) !usize {
    var found: ?usize = null;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..separator], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        if (found != null) return error.DuplicateContentLength;
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (value.len == 0) return error.InvalidContentLength;
        found = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
    }
    return found orelse error.MissingContentLength;
}

test "DAP frame round trip" {
    const payload = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\"}";
    const bytes = try encode(std.testing.allocator, payload);
    defer std.testing.allocator.free(bytes);

    const frame = try parse(bytes);
    try std.testing.expectEqualStrings(payload, frame.body);
    try std.testing.expectEqual(bytes.len, frame.consumed_bytes);
}

test "DAP frame parser rejects oversized and duplicate lengths" {
    try std.testing.expectError(error.IncompleteFrame, parse("Content-Length: 5\r\n\r\nab"));
    try std.testing.expectError(error.DuplicateContentLength, parse("Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}"));

    const header = try std.fmt.allocPrint(std.testing.allocator, "Content-Length: {d}\r\n\r\n", .{max_payload_bytes + 1});
    defer std.testing.allocator.free(header);
    try std.testing.expectError(error.FrameTooLarge, parse(header));
}
