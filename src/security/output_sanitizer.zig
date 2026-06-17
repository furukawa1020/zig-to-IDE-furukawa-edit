const std = @import("std");

pub const Stats = struct {
    stripped_csi: usize = 0,
    stripped_osc: usize = 0,
    stripped_control: usize = 0,

    pub fn total(self: Stats) usize {
        return self.stripped_csi + self.stripped_osc + self.stripped_control;
    }
};

pub const Result = struct {
    text: []u8,
    stats: Stats,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn sanitizeAlloc(allocator: std.mem.Allocator, input: []const u8) !Result {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var stats = Stats{};
    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (byte == 0x1b) {
            const consumed = consumeEscape(input[i..], &stats);
            i += consumed;
            continue;
        }

        if (isAllowedControl(byte)) {
            try output.append(byte);
        } else if (byte < 0x20 or byte == 0x7f) {
            stats.stripped_control += 1;
        } else {
            try output.append(byte);
        }
        i += 1;
    }

    return .{
        .text = try output.toOwnedSlice(),
        .stats = stats,
    };
}

fn consumeEscape(input: []const u8, stats: *Stats) usize {
    if (input.len == 0 or input[0] != 0x1b) return 0;
    if (input.len == 1) {
        stats.stripped_control += 1;
        return 1;
    }

    switch (input[1]) {
        '[' => {
            stats.stripped_csi += 1;
            var i: usize = 2;
            while (i < input.len) : (i += 1) {
                if (input[i] >= 0x40 and input[i] <= 0x7e) return i + 1;
            }
            return input.len;
        },
        ']' => {
            stats.stripped_osc += 1;
            var i: usize = 2;
            while (i < input.len) : (i += 1) {
                if (input[i] == 0x07) return i + 1;
                if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') return i + 2;
            }
            return input.len;
        },
        else => {
            stats.stripped_control += 1;
            return 2;
        },
    }
}

fn isAllowedControl(byte: u8) bool {
    return byte == '\n' or byte == '\r' or byte == '\t';
}

test "sanitizer strips csi and osc sequences" {
    var result = try sanitizeAlloc(std.testing.allocator, "ok\x1b[2Jbad\x1b]52;c;AAAA\x07done");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("okbaddone", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.stats.stripped_csi);
    try std.testing.expectEqual(@as(usize, 1), result.stats.stripped_osc);
}

