const std = @import("std");

pub const Newline = enum {
    none,
    lf,
    crlf,
    mixed,
};

pub const TextBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    line_starts: std.array_list.Managed(usize),
    newline: Newline,
    valid_utf8: bool,

    pub fn initEmpty(allocator: std.mem.Allocator) !TextBuffer {
        return initFromBytes(allocator, "");
    }

    pub fn initFromBytes(allocator: std.mem.Allocator, input: []const u8) !TextBuffer {
        var self = TextBuffer{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, input),
            .line_starts = std.array_list.Managed(usize).init(allocator),
            .newline = .none,
            .valid_utf8 = false,
        };
        try self.rebuildLineIndex();
        return self;
    }

    pub fn deinit(self: *TextBuffer) void {
        self.allocator.free(self.bytes);
        self.line_starts.deinit();
        self.* = undefined;
    }

    pub fn lineCount(self: *const TextBuffer) usize {
        return self.line_starts.items.len;
    }

    pub fn lineSlice(self: *const TextBuffer, line: usize) []const u8 {
        if (line >= self.line_starts.items.len) return "";
        const start = self.line_starts.items[line];
        var end = if (line + 1 < self.line_starts.items.len)
            self.line_starts.items[line + 1]
        else
            self.bytes.len;

        if (end > start and self.bytes[end - 1] == '\n') end -= 1;
        if (end > start and self.bytes[end - 1] == '\r') end -= 1;
        return self.bytes[start..end];
    }

    pub fn lineStart(self: *const TextBuffer, line: usize) ?usize {
        if (line >= self.line_starts.items.len) return null;
        return self.line_starts.items[line];
    }

    pub fn offsetToLine(self: *const TextBuffer, offset: usize) !usize {
        if (offset > self.bytes.len) return error.OffsetOutOfBounds;
        var low: usize = 0;
        var high: usize = self.line_starts.items.len;
        while (low + 1 < high) {
            const mid = low + (high - low) / 2;
            if (self.line_starts.items[mid] <= offset) {
                low = mid;
            } else {
                high = mid;
            }
        }
        return low;
    }

    pub fn offsetToLineColumn(self: *const TextBuffer, offset: usize) !LineColumn {
        const line = try self.offsetToLine(offset);
        const start = self.line_starts.items[line];
        return .{ .line = line, .column = offset - start };
    }

    pub fn lineColumnToOffset(self: *const TextBuffer, line: usize, column: usize) !usize {
        const start = self.lineStart(line) orelse return error.LineOutOfBounds;
        const line_text = self.lineSlice(line);
        return start + @min(column, line_text.len);
    }

    pub fn slice(self: *const TextBuffer, start: usize, end: usize) ![]const u8 {
        if (start > end or end > self.bytes.len) return error.OffsetOutOfBounds;
        return self.bytes[start..end];
    }

    pub fn nextByteOffset(self: *const TextBuffer, offset: usize) !usize {
        if (offset > self.bytes.len) return error.OffsetOutOfBounds;
        if (offset == self.bytes.len) return offset;
        return offset + utf8SequenceLengthFallback(self.bytes[offset]);
    }

    pub fn previousByteOffset(self: *const TextBuffer, offset: usize) !usize {
        if (offset > self.bytes.len) return error.OffsetOutOfBounds;
        if (offset == 0) return 0;
        var i = offset - 1;
        while (i > 0 and isUtf8Continuation(self.bytes[i])) : (i -= 1) {}
        return i;
    }

    pub fn insertBytes(self: *TextBuffer, offset: usize, text: []const u8) !void {
        try self.replaceRange(offset, offset, text);
    }

    pub fn deleteRange(self: *TextBuffer, start: usize, end: usize) !void {
        try self.replaceRange(start, end, "");
    }

    pub fn replaceRange(self: *TextBuffer, start: usize, end: usize, text: []const u8) !void {
        if (start > end or end > self.bytes.len) return error.OffsetOutOfBounds;
        const retained = self.bytes.len - (end - start);
        const next_len = std.math.add(usize, retained, text.len) catch return error.BufferTooLarge;
        const next = try self.allocator.alloc(u8, next_len);
        errdefer self.allocator.free(next);

        std.mem.copyForwards(u8, next[0..start], self.bytes[0..start]);
        std.mem.copyForwards(u8, next[start .. start + text.len], text);
        std.mem.copyForwards(u8, next[start + text.len ..], self.bytes[end..]);
        try self.line_starts.ensureTotalCapacity(requiredLineStarts(next));

        const previous = self.bytes;
        self.bytes = next;
        self.allocator.free(previous);
        self.rebuildLineIndexAssumeCapacity();
    }

    fn rebuildLineIndex(self: *TextBuffer) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(0);
        self.newline = .none;

        var i: usize = 0;
        while (i < self.bytes.len) : (i += 1) {
            if (self.bytes[i] == '\n') {
                self.noteNewline(if (i > 0 and self.bytes[i - 1] == '\r') .crlf else .lf);
                if (i + 1 < self.bytes.len) {
                    try self.line_starts.append(i + 1);
                }
            }
        }

        self.valid_utf8 = std.unicode.utf8ValidateSlice(self.bytes);
    }

    fn rebuildLineIndexAssumeCapacity(self: *TextBuffer) void {
        self.line_starts.clearRetainingCapacity();
        self.line_starts.appendAssumeCapacity(0);
        self.newline = .none;

        for (self.bytes, 0..) |byte, index| {
            if (byte != '\n') continue;
            self.noteNewline(if (index > 0 and self.bytes[index - 1] == '\r') .crlf else .lf);
            if (index + 1 < self.bytes.len) self.line_starts.appendAssumeCapacity(index + 1);
        }
        self.valid_utf8 = std.unicode.utf8ValidateSlice(self.bytes);
    }

    fn noteNewline(self: *TextBuffer, found: Newline) void {
        if (self.newline == .none) {
            self.newline = found;
        } else if (self.newline != found) {
            self.newline = .mixed;
        }
    }
};

pub const LineColumn = struct {
    line: usize,
    column: usize,
};

fn utf8SequenceLengthFallback(first: u8) usize {
    if (first < 0x80) return 1;
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return 1;
}

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

fn requiredLineStarts(bytes: []const u8) usize {
    var count: usize = 1;
    for (bytes, 0..) |byte, index| {
        if (byte == '\n' and index + 1 < bytes.len) count += 1;
    }
    return count;
}

test "line index tracks edits" {
    var buf = try TextBuffer.initFromBytes(std.testing.allocator, "a\nb\nc");
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());
    try std.testing.expectEqualStrings("b", buf.lineSlice(1));

    try buf.insertBytes(2, "x\n");
    try std.testing.expectEqual(@as(usize, 4), buf.lineCount());
    try std.testing.expectEqualStrings("x", buf.lineSlice(1));
}

test "invalid utf8 is retained without panic" {
    var buf = try TextBuffer.initFromBytes(std.testing.allocator, &.{ 0xff, '\n', 'o', 'k' });
    defer buf.deinit();

    try std.testing.expect(!buf.valid_utf8);
    try std.testing.expectEqual(@as(usize, 2), buf.lineCount());
}

test "offset and line column conversions work" {
    var buf = try TextBuffer.initFromBytes(std.testing.allocator, "alpha\nbeta\ngamma");
    defer buf.deinit();

    const offset = try buf.lineColumnToOffset(1, 2);
    try std.testing.expectEqual(@as(usize, 8), offset);

    const lc = try buf.offsetToLineColumn(offset);
    try std.testing.expectEqual(@as(usize, 1), lc.line);
    try std.testing.expectEqual(@as(usize, 2), lc.column);
}

test "replace range is atomic and accepts replacement aliased from the buffer" {
    var buf = try TextBuffer.initFromBytes(std.testing.allocator, "one\r\ntwo\nthree");
    defer buf.deinit();

    try buf.replaceRange(5, 8, buf.bytes[0..3]);
    try std.testing.expectEqualStrings("one\r\none\nthree", buf.bytes);
    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());
    try std.testing.expectEqual(Newline.mixed, buf.newline);
    try std.testing.expect(buf.valid_utf8);
}
