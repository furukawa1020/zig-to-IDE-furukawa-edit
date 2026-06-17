const std = @import("std");
const buffer = @import("buffer.zig");
const cursor = @import("cursor.zig");
const modes = @import("../language/modes.zig");

pub const Document = struct {
    allocator: std.mem.Allocator,
    path: ?[]u8,
    language: modes.LanguageMode,
    text: buffer.TextBuffer,
    cursor: cursor.Cursor = .{},
    dirty: bool = false,

    pub fn fromBytes(allocator: std.mem.Allocator, path: ?[]const u8, bytes: []const u8) !Document {
        return .{
            .allocator = allocator,
            .path = if (path) |p| try allocator.dupe(u8, p) else null,
            .language = if (path) |p| modes.detect(p) else .unknown,
            .text = try buffer.TextBuffer.initFromBytes(allocator, bytes),
        };
    }

    pub fn deinit(self: *Document) void {
        if (self.path) |p| self.allocator.free(p);
        self.text.deinit();
        self.* = undefined;
    }
};

