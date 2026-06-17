const std = @import("std");
const literal = @import("literal.zig");
const workspace = @import("../workspace/workspace.zig");

pub const Options = struct {
    literal_options: literal.Options = .{},
    max_file_bytes: usize = 2 * 1024 * 1024,
    max_results: usize = 10_000,
};

pub const Result = struct {
    path: []u8,
    line: usize,
    column: usize,
    byte_offset: usize,
    preview: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.preview);
        self.* = undefined;
    }
};

pub fn search(allocator: std.mem.Allocator, ws: *const workspace.Workspace, query: []const u8, options: Options) ![]Result {
    var results = std.ArrayList(Result).init(allocator);
    errdefer {
        for (results.items) |*item| item.deinit(allocator);
        results.deinit();
    }

    for (ws.entries.items) |entry| {
        if (results.items.len >= options.max_results) break;
        if (entry.kind != .file) continue;

        const absolute = try std.fs.path.join(allocator, &.{ ws.root_path, entry.path });
        defer allocator.free(absolute);

        const bytes = readFile(allocator, absolute, options.max_file_bytes) catch continue;
        defer allocator.free(bytes);
        if (looksBinary(bytes)) continue;

        const matches = try literal.findAll(allocator, bytes, query, options.literal_options);
        defer allocator.free(matches);

        for (matches) |match| {
            if (results.items.len >= options.max_results) break;
            const location = lineColumnForOffset(bytes, match.start);
            try results.append(.{
                .path = try allocator.dupe(u8, entry.path),
                .line = location.line,
                .column = location.column,
                .byte_offset = match.start,
                .preview = try previewForLine(allocator, bytes, match.start),
            });
        }
    }

    return results.toOwnedSlice();
}

fn readFile(allocator: std.mem.Allocator, absolute: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.fs.openFileAbsolute(absolute, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn looksBinary(bytes: []const u8) bool {
    const limit = @min(bytes.len, 4096);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (bytes[i] == 0) return true;
    }
    return false;
}

const Location = struct {
    line: usize,
    column: usize,
};

fn lineColumnForOffset(bytes: []const u8, offset: usize) Location {
    var line: usize = 0;
    var column: usize = 0;
    var i: usize = 0;
    while (i < offset and i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') {
            line += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn previewForLine(allocator: std.mem.Allocator, bytes: []const u8, offset: usize) ![]u8 {
    var start = @min(offset, bytes.len);
    while (start > 0 and bytes[start - 1] != '\n' and bytes[start - 1] != '\r') : (start -= 1) {}

    var end = @min(offset, bytes.len);
    while (end < bytes.len and bytes[end] != '\n' and bytes[end] != '\r') : (end += 1) {}

    return allocator.dupe(u8, bytes[start..end]);
}

