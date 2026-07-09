const std = @import("std");
const completion = @import("../language/completion.zig");
const types = @import("../core/types.zig");
const lsp_diagnostics = @import("diagnostics.zig");

pub const CompletionItems = struct {
    allocator: std.mem.Allocator,
    items: []completion.Item,

    pub fn deinit(self: *CompletionItems) void {
        completion.deinitItems(self.allocator, self.items);
        self.* = undefined;
    }
};

pub const Hover = struct {
    allocator: std.mem.Allocator,
    text: []u8,

    pub fn deinit(self: *Hover) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Location = struct {
    path: []u8,
    range: types.Range,
};

pub const Locations = struct {
    allocator: std.mem.Allocator,
    items: []Location,

    pub fn deinit(self: *Locations) void {
        for (self.items) |item| self.allocator.free(item.path);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn parseCompletionResponse(allocator: std.mem.Allocator, payload: []const u8) !?CompletionItems {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const result = resultValue(parsed.value) orelse return null;
    const items_value = switch (result) {
        .array => |array| array,
        .object => |object| switch (object.get("items") orelse return error.MissingCompletionItems) {
            .array => |array| array,
            else => return error.InvalidCompletionItems,
        },
        .null => return null,
        else => return error.InvalidCompletionResult,
    };

    var items = std.array_list.Managed(completion.Item).init(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }

    for (items_value.items) |item_value| {
        const object = switch (item_value) {
            .object => |object| object,
            else => continue,
        };
        try appendCompletion(allocator, &items, object);
    }

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(),
    };
}

pub fn parseHoverResponse(allocator: std.mem.Allocator, payload: []const u8) !?Hover {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const result = resultValue(parsed.value) orelse return null;
    if (result == .null) return null;
    const contents = switch (result) {
        .object => |object| object.get("contents") orelse return error.MissingHoverContents,
        else => return error.InvalidHoverResult,
    };

    var text: std.Io.Writer.Allocating = .init(allocator);
    errdefer text.deinit();
    try appendHoverValue(&text.writer, contents);

    return .{
        .allocator = allocator,
        .text = try text.toOwnedSlice(),
    };
}

pub fn parseLocationResponse(allocator: std.mem.Allocator, payload: []const u8, workspace_root: ?[]const u8) !?Locations {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const result = resultValue(parsed.value) orelse return null;
    if (result == .null) return null;

    var locations = std.array_list.Managed(Location).init(allocator);
    errdefer {
        for (locations.items) |item| allocator.free(item.path);
        locations.deinit();
    }

    switch (result) {
        .array => |array| {
            for (array.items) |item| {
                if (try parseLocation(allocator, item, workspace_root)) |location| {
                    try locations.append(location);
                }
            }
        },
        .object => {
            if (try parseLocation(allocator, result, workspace_root)) |location| {
                try locations.append(location);
            }
        },
        else => return error.InvalidLocationResult,
    }

    return .{
        .allocator = allocator,
        .items = try locations.toOwnedSlice(),
    };
}

fn appendCompletion(allocator: std.mem.Allocator, items: *std.array_list.Managed(completion.Item), object: std.json.ObjectMap) !void {
    const label = stringField(object, "label") orelse return;
    const insert_text = stringField(object, "insertText") orelse label;
    const detail = stringField(object, "detail") orelse "LSP";
    const kind = completionKind(intField(object, "kind", 1));

    var item = completion.Item{
        .label = try allocator.dupe(u8, label),
        .insert_text = undefined,
        .detail = undefined,
        .kind = kind,
        .score = 950,
    };
    errdefer allocator.free(item.label);
    item.insert_text = try allocator.dupe(u8, insert_text);
    errdefer allocator.free(item.insert_text);
    item.detail = try allocator.dupe(u8, detail);
    errdefer allocator.free(item.detail);
    try items.append(item);
}

fn completionKind(kind: usize) completion.Kind {
    return switch (kind) {
        14 => .keyword,
        15 => .snippet,
        2, 3, 4, 5, 7, 8, 9, 10, 13, 20, 21, 22 => .symbol,
        1, 6, 12 => .word,
        else => .builtin,
    };
}

fn parseLocation(allocator: std.mem.Allocator, value: std.json.Value, workspace_root: ?[]const u8) !?Location {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const uri = stringField(object, "uri") orelse stringField(object, "targetUri") orelse return null;
    const range_value = object.get("range") orelse object.get("targetRange") orelse return error.MissingLocationRange;
    const path = try lsp_diagnostics.fileUriToPath(allocator, uri, workspace_root);
    errdefer allocator.free(path);

    return .{
        .path = path,
        .range = try parseRange(range_value),
    };
}

fn parseRange(value: std.json.Value) !types.Range {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidRange,
    };
    return .{
        .start = try parsePosition(object.get("start") orelse return error.MissingRangeStart),
        .end = try parsePosition(object.get("end") orelse return error.MissingRangeEnd),
    };
}

fn parsePosition(value: std.json.Value) !types.Position {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidPosition,
    };
    return .{
        .line = intField(object, "line", 0),
        .column = intField(object, "character", 0),
        .byte_offset = 0,
    };
}

fn appendHoverValue(writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .string => |text| try writer.writeAll(text),
        .object => |object| {
            if (stringField(object, "value")) |text| {
                try writer.writeAll(text);
            } else if (stringField(object, "language")) |language| {
                try writer.writeAll(language);
            }
        },
        .array => |array| {
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeAll("\n\n");
                try appendHoverValue(writer, item);
            }
        },
        else => {},
    }
}

fn resultValue(value: std.json.Value) ?std.json.Value {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    return object.get("result");
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn intField(object: std.json.ObjectMap, key: []const u8, fallback: usize) usize {
    const value = object.get(key) orelse return fallback;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else fallback,
        else => fallback,
    };
}

test "parse completion response" {
    const payload =
        \\{"jsonrpc":"2.0","id":3,"result":{"isIncomplete":false,"items":[{"label":"ArrayList","insertText":"std.ArrayList","detail":"type","kind":7},{"label":"fn","kind":14}]}}
    ;
    var parsed = (try parseCompletionResponse(std.testing.allocator, payload)).?;
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.items.len);
    try std.testing.expectEqualStrings("ArrayList", parsed.items[0].label);
    try std.testing.expectEqualStrings("std.ArrayList", parsed.items[0].insert_text);
    try std.testing.expectEqual(completion.Kind.symbol, parsed.items[0].kind);
    try std.testing.expectEqual(completion.Kind.keyword, parsed.items[1].kind);
}

test "parse hover response" {
    const payload =
        \\{"jsonrpc":"2.0","id":4,"result":{"contents":{"kind":"markdown","value":"**main** docs"}}}
    ;
    var hover = (try parseHoverResponse(std.testing.allocator, payload)).?;
    defer hover.deinit();

    try std.testing.expectEqualStrings("**main** docs", hover.text);
}

test "parse location response" {
    const payload =
        \\{"jsonrpc":"2.0","id":5,"result":[{"uri":"file:///C:/Projects/zide/src/main.zig","range":{"start":{"line":9,"character":1},"end":{"line":9,"character":5}}}]}
    ;
    var locations = (try parseLocationResponse(std.testing.allocator, payload, "C:\\Projects\\zide")).?;
    defer locations.deinit();

    try std.testing.expectEqual(@as(usize, 1), locations.items.len);
    try std.testing.expectEqualStrings("src/main.zig", locations.items[0].path);
    try std.testing.expectEqual(@as(usize, 9), locations.items[0].range.start.line);
    try std.testing.expectEqual(@as(usize, 1), locations.items[0].range.start.column);
}
