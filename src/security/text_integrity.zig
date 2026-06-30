const std = @import("std");
const findings = @import("findings.zig");

pub const Options = struct {
    path: []const u8,
};

pub fn scan(allocator: std.mem.Allocator, bytes: []const u8, options: Options) !findings.Collection {
    var collection = findings.Collection.init(allocator);
    errdefer collection.deinit();

    if (std.mem.indexOfScalar(u8, bytes, 0)) |offset| {
        const location = lineColumnAt(bytes, offset);
        try collection.append(
            .text_integrity,
            .medium,
            options.path,
            location.line,
            location.column,
            "NUL byte in text file can hide content from tools",
            "0x00",
        );
    }

    if (!std.unicode.utf8ValidateSlice(bytes)) {
        const offset = firstInvalidUtf8(bytes) orelse 0;
        const location = lineColumnAt(bytes, offset);
        try collection.append(
            .text_integrity,
            .medium,
            options.path,
            location.line,
            location.column,
            "file is not valid UTF-8; editor preserves bytes but review should verify encoding",
            "invalid utf-8",
        );
    }

    if (firstBidiControl(bytes)) |offset| {
        const location = lineColumnAt(bytes, offset);
        try collection.append(
            .text_integrity,
            .high,
            options.path,
            location.line,
            location.column,
            "bidirectional Unicode control character can disguise source order",
            "unicode bidi control",
        );
    }

    if (firstMixedNewline(bytes)) |offset| {
        const location = lineColumnAt(bytes, offset);
        try collection.append(
            .text_integrity,
            .low,
            options.path,
            location.line,
            location.column,
            "mixed line endings can hide diff noise or change script behavior",
            "mixed newline styles",
        );
    }

    return collection;
}

pub fn hiddenControlLengthAt(bytes: []const u8, index: usize) ?usize {
    if (index >= bytes.len) return null;
    if (bytes[index] == 0) return 1;
    if (index + 2 >= bytes.len) return null;
    if (bytes[index] != 0xe2) return null;
    if (bytes[index + 1] == 0x80 and bytes[index + 2] >= 0xaa and bytes[index + 2] <= 0xae) return 3;
    if (bytes[index + 1] == 0x81 and bytes[index + 2] >= 0xa6 and bytes[index + 2] <= 0xa9) return 3;
    return null;
}

const Location = struct {
    line: usize,
    column: usize,
};

fn lineColumnAt(bytes: []const u8, target: usize) Location {
    var location: Location = .{ .line = 0, .column = 0 };
    var index: usize = 0;
    while (index < bytes.len and index < target) : (index += 1) {
        if (bytes[index] == '\n') {
            location.line += 1;
            location.column = 0;
        } else {
            location.column += 1;
        }
    }
    return location;
}

fn firstInvalidUtf8(bytes: []const u8) ?usize {
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            index += 1;
            continue;
        }

        if (byte >= 0xc2 and byte <= 0xdf) {
            if (!hasContinuation(bytes, index, 1)) return index;
            index += 2;
            continue;
        }

        if (byte >= 0xe0 and byte <= 0xef) {
            if (!hasContinuation(bytes, index, 2)) return index;
            const second = bytes[index + 1];
            if (byte == 0xe0 and second < 0xa0) return index;
            if (byte == 0xed and second >= 0xa0) return index;
            index += 3;
            continue;
        }

        if (byte >= 0xf0 and byte <= 0xf4) {
            if (!hasContinuation(bytes, index, 3)) return index;
            const second = bytes[index + 1];
            if (byte == 0xf0 and second < 0x90) return index;
            if (byte == 0xf4 and second >= 0x90) return index;
            index += 4;
            continue;
        }

        return index;
    }
    return null;
}

fn hasContinuation(bytes: []const u8, start: usize, count: usize) bool {
    if (start + count >= bytes.len) return false;
    var offset: usize = 1;
    while (offset <= count) : (offset += 1) {
        if ((bytes[start + offset] & 0xc0) != 0x80) return false;
    }
    return true;
}

fn firstBidiControl(bytes: []const u8) ?usize {
    var index: usize = 0;
    while (index + 2 < bytes.len) : (index += 1) {
        if (bytes[index] != 0 and hiddenControlLengthAt(bytes, index) != null) return index;
    }
    return null;
}

const NewlineKind = enum {
    lf,
    crlf,
    cr,
};

fn firstMixedNewline(bytes: []const u8) ?usize {
    var first: ?NewlineKind = null;
    var index: usize = 0;
    while (index < bytes.len) {
        const start = index;
        const kind: NewlineKind = if (bytes[index] == '\r') blk: {
            if (index + 1 < bytes.len and bytes[index + 1] == '\n') {
                index += 2;
                break :blk .crlf;
            }
            index += 1;
            break :blk .cr;
        } else if (bytes[index] == '\n') blk: {
            index += 1;
            break :blk .lf;
        } else {
            index += 1;
            continue;
        };

        if (first) |known| {
            if (known != kind) return start;
        } else {
            first = kind;
        }
    }
    return null;
}

test "text integrity scan flags hidden control hazards" {
    var scan_result = try scan(std.testing.allocator, "ok\nbad\x00\nrtl \xe2\x80\xae\n", .{ .path = "src/main.zig" });
    defer scan_result.deinit();

    try std.testing.expect(scan_result.countRiskAtLeast(.high) >= 1);
    try std.testing.expect(scan_result.countRiskAtLeast(.medium) >= 2);
}

test "text integrity scan flags invalid utf8 and mixed newlines" {
    var scan_result = try scan(std.testing.allocator, "a\r\nb\nc\xff\n", .{ .path = "script.py" });
    defer scan_result.deinit();

    try std.testing.expect(scan_result.countRiskAtLeast(.medium) >= 1);
    try std.testing.expect(scan_result.items.items.len >= 2);
}

test "hidden control helper reports exact byte spans" {
    try std.testing.expectEqual(@as(?usize, 1), hiddenControlLengthAt("a\x00b", 1));
    try std.testing.expectEqual(@as(?usize, 3), hiddenControlLengthAt("x\xe2\x80\xaey", 1));
    try std.testing.expectEqual(@as(?usize, null), hiddenControlLengthAt("plain", 1));
}
