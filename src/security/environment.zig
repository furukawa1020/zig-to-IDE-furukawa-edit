const std = @import("std");

pub fn wipeMapValues(map: *std.process.Environ.Map) void {
    for (map.values()) |value| {
        @memset(@constCast(value), 0);
    }
}

test "environment map values are zeroed in place" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("ZIDE_TEST_ONE", "alpha");
    try map.put("ZIDE_TEST_TWO", "beta");

    wipeMapValues(&map);
    for (map.values()) |value| {
        for (value) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
