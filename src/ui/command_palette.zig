const std = @import("std");
const command = @import("../core/command.zig");

pub const Match = struct {
    definition: command.Definition,
    score: u16,
};

pub const CommandPalette = struct {
    allocator: std.mem.Allocator,
    visible: bool = false,
    query: std.ArrayList(u8),
    matches: std.ArrayList(Match),
    selected_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) CommandPalette {
        return .{
            .allocator = allocator,
            .query = std.ArrayList(u8).init(allocator),
            .matches = std.ArrayList(Match).init(allocator),
        };
    }

    pub fn deinit(self: *CommandPalette) void {
        self.query.deinit();
        self.matches.deinit();
        self.* = undefined;
    }

    pub fn open(self: *CommandPalette) !void {
        self.visible = true;
        try self.setQuery("");
    }

    pub fn close(self: *CommandPalette) void {
        self.visible = false;
    }

    pub fn setQuery(self: *CommandPalette, query: []const u8) !void {
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(query);
        try self.rebuildMatches();
    }

    pub fn insertText(self: *CommandPalette, text: []const u8) !void {
        try self.query.appendSlice(text);
        try self.rebuildMatches();
    }

    pub fn deleteBackward(self: *CommandPalette) !void {
        if (self.query.items.len == 0) return;
        var end = self.query.items.len - 1;
        while (end > 0 and isUtf8Continuation(self.query.items[end])) : (end -= 1) {}
        self.query.shrinkRetainingCapacity(end);
        try self.rebuildMatches();
    }

    pub fn selected(self: *const CommandPalette) ?command.Definition {
        if (self.matches.items.len == 0) return null;
        const index = @min(self.selected_index, self.matches.items.len - 1);
        return self.matches.items[index].definition;
    }

    pub fn moveSelection(self: *CommandPalette, delta: isize) void {
        if (self.matches.items.len == 0) {
            self.selected_index = 0;
            return;
        }
        const max_index = self.matches.items.len - 1;
        if (delta < 0) {
            const amount = @as(usize, @intCast(-delta));
            self.selected_index = if (amount > self.selected_index) 0 else self.selected_index - amount;
        } else {
            self.selected_index = @min(max_index, self.selected_index + @as(usize, @intCast(delta)));
        }
    }

    fn rebuildMatches(self: *CommandPalette) !void {
        self.matches.clearRetainingCapacity();
        for (command.all()) |definition| {
            const score = scoreDefinition(self.query.items, definition) orelse continue;
            try self.matches.append(.{ .definition = definition, .score = score });
        }
        sortMatches(self.matches.items);
        if (self.selected_index >= self.matches.items.len) self.selected_index = 0;
    }
};

fn scoreDefinition(query: []const u8, definition: command.Definition) ?u16 {
    if (query.len == 0) return 1;
    const id_score = command.fuzzyScore(query, definition.id);
    const title_score = command.fuzzyScore(query, definition.title);
    if (id_score == null and title_score == null) return null;
    return @max(id_score orelse 0, title_score orelse 0);
}

fn sortMatches(items: []Match) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and comesBefore(items[j], items[j - 1])) : (j -= 1) {
            const tmp = items[j - 1];
            items[j - 1] = items[j];
            items[j] = tmp;
        }
    }
}

fn comesBefore(left: Match, right: Match) bool {
    if (left.score != right.score) return left.score > right.score;
    return std.mem.lessThan(u8, left.definition.id, right.definition.id);
}

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

test "command palette filters commands" {
    var palette = CommandPalette.init(std.testing.allocator);
    defer palette.deinit();

    try palette.open();
    try palette.setQuery("zb");

    const selected = palette.selected() orelse return error.ExpectedSelection;
    try std.testing.expectEqualStrings("zig.build", selected.id);
}
