const std = @import("std");
const model = @import("model.zig");
const types = @import("../core/types.zig");

pub const Collection = struct {
    allocator: std.mem.Allocator,
    items: std.array_list.Managed(model.Diagnostic),

    pub fn init(allocator: std.mem.Allocator) Collection {
        return .{
            .allocator = allocator,
            .items = std.array_list.Managed(model.Diagnostic).init(allocator),
        };
    }

    pub fn deinit(self: *Collection) void {
        self.freeItems();
        self.items.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *Collection) void {
        self.freeItems();
        self.items.clearRetainingCapacity();
    }

    pub fn append(self: *Collection, diagnostic: model.Diagnostic) !void {
        const path = try self.allocator.dupe(u8, diagnostic.path);
        errdefer self.allocator.free(path);
        const message = try self.allocator.dupe(u8, diagnostic.message);
        errdefer self.allocator.free(message);

        try self.items.append(.{
            .source = diagnostic.source,
            .severity = diagnostic.severity,
            .path = path,
            .range = diagnostic.range,
            .message = message,
        });
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

    fn freeItems(self: *Collection) void {
        for (self.items.items) |item| {
            self.allocator.free(item.path);
            self.allocator.free(item.message);
        }
    }
};

test "collection counts severity" {
    var collection = Collection.init(std.testing.allocator);
    defer collection.deinit();

    const position = types.Position.start();
    try collection.append(.{
        .source = .internal,
        .severity = .err,
        .path = "main.zig",
        .range = types.Range.empty(position),
        .message = "boom",
    });

    try std.testing.expectEqual(@as(usize, 1), collection.countBySeverity(.err));
}
