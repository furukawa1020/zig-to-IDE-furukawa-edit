const std = @import("std");
const model = @import("model.zig");
const types = @import("../core/types.zig");

pub const Collection = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(model.Diagnostic),

    pub fn init(allocator: std.mem.Allocator) Collection {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(model.Diagnostic).init(allocator),
        };
    }

    pub fn deinit(self: *Collection) void {
        self.items.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *Collection) void {
        self.items.clearRetainingCapacity();
    }

    pub fn append(self: *Collection, diagnostic: model.Diagnostic) !void {
        try self.items.append(diagnostic);
    }

    pub fn countBySeverity(self: *const Collection, severity: types.Severity) usize {
        var count: usize = 0;
        for (self.items.items) |item| {
            if (item.severity == severity) count += 1;
        }
        return count;
    }

    pub fn nextAfter(self: *const Collection, path: []const u8, byte_offset: usize) ?model.Diagnostic {
        var best: ?model.Diagnostic = null;
        for (self.items.items) |item| {
            if (!std.mem.eql(u8, item.path, path)) continue;
            if (item.range.start.byte_offset < byte_offset) continue;
            if (best == null or item.range.start.byte_offset < best.?.range.start.byte_offset) {
                best = item;
            }
        }
        return best;
    }
};

test "collection counts severity" {
    var collection = Collection.init(std.testing.allocator);
    defer collection.deinit();

    const position = types.Position.start();
    try collection.append(.{
        .source = .internal,
        .severity = .error,
        .path = "main.zig",
        .range = types.Range.empty(position),
        .message = "boom",
    });

    try std.testing.expectEqual(@as(usize, 1), collection.countBySeverity(.error));
}

