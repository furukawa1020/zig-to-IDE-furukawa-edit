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

pub const TextEdit = struct {
    path: []u8,
    range: types.Range,
    new_text: []u8,
};

pub const WorkspaceEdit = struct {
    allocator: std.mem.Allocator,
    edits: []TextEdit,
    skipped_resource_ops: usize = 0,

    pub fn deinit(self: *WorkspaceEdit) void {
        for (self.edits) |edit| {
            self.allocator.free(edit.path);
            self.allocator.free(edit.new_text);
        }
        self.allocator.free(self.edits);
        self.* = undefined;
    }
};

pub const CodeAction = struct {
    allocator: std.mem.Allocator,
    title: []u8,
    kind: []u8,
    command_title: []u8,
    diagnostics: usize = 0,
    workspace_edit: ?WorkspaceEdit = null,

    pub fn deinit(self: *CodeAction) void {
        if (self.workspace_edit) |*edit| edit.deinit();
        self.allocator.free(self.command_title);
        self.allocator.free(self.kind);
        self.allocator.free(self.title);
        self.* = undefined;
    }
};

pub const CodeActions = struct {
    allocator: std.mem.Allocator,
    items: []CodeAction,

    pub fn deinit(self: *CodeActions) void {
        for (self.items) |*item| item.deinit();
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

pub fn parseWorkspaceEditResponse(allocator: std.mem.Allocator, payload: []const u8, workspace_root: ?[]const u8) !?WorkspaceEdit {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const result = resultValue(parsed.value) orelse return null;
    if (result == .null) return null;
    const object = switch (result) {
        .object => |object| object,
        else => return error.InvalidWorkspaceEditResult,
    };

    return try parseWorkspaceEditObject(allocator, object, workspace_root);
}

pub fn parseCodeActionResponse(allocator: std.mem.Allocator, payload: []const u8, workspace_root: ?[]const u8) !?CodeActions {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const result = resultValue(parsed.value) orelse return null;
    if (result == .null) return null;
    const array = switch (result) {
        .array => |array| array,
        else => return error.InvalidCodeActionResult,
    };

    var actions = std.array_list.Managed(CodeAction).init(allocator);
    errdefer {
        for (actions.items) |*item| item.deinit();
        actions.deinit();
    }

    for (array.items) |item| {
        if (try parseCodeAction(allocator, item, workspace_root)) |action| {
            try actions.append(action);
        }
    }

    return .{
        .allocator = allocator,
        .items = try actions.toOwnedSlice(),
    };
}

fn parseWorkspaceEditObject(allocator: std.mem.Allocator, object: std.json.ObjectMap, workspace_root: ?[]const u8) !WorkspaceEdit {
    var edits = std.array_list.Managed(TextEdit).init(allocator);
    errdefer {
        for (edits.items) |edit| {
            allocator.free(edit.path);
            allocator.free(edit.new_text);
        }
        edits.deinit();
    }
    var skipped_resource_ops: usize = 0;

    if (object.get("changes")) |changes_value| {
        const changes = switch (changes_value) {
            .object => |changes| changes,
            else => return error.InvalidWorkspaceEditChanges,
        };
        var iterator = changes.iterator();
        while (iterator.next()) |entry| {
            const uri = entry.key_ptr.*;
            const edit_array = switch (entry.value_ptr.*) {
                .array => |array| array,
                else => return error.InvalidWorkspaceEditEdits,
            };
            try appendTextEditsForUri(allocator, &edits, uri, edit_array, workspace_root);
        }
    }

    if (object.get("documentChanges")) |document_changes_value| {
        const document_changes = switch (document_changes_value) {
            .array => |array| array,
            else => return error.InvalidWorkspaceEditDocumentChanges,
        };
        for (document_changes.items) |document_change_value| {
            const document_change = switch (document_change_value) {
                .object => |document_change| document_change,
                else => continue,
            };
            if (stringField(document_change, "kind") != null) {
                skipped_resource_ops += 1;
                continue;
            }
            const text_document_value = document_change.get("textDocument") orelse {
                skipped_resource_ops += 1;
                continue;
            };
            const text_document = switch (text_document_value) {
                .object => |text_document| text_document,
                else => return error.InvalidWorkspaceEditTextDocument,
            };
            const uri = stringField(text_document, "uri") orelse return error.MissingWorkspaceEditUri;
            const edit_array = switch (document_change.get("edits") orelse return error.MissingWorkspaceEditEdits) {
                .array => |array| array,
                else => return error.InvalidWorkspaceEditEdits,
            };
            try appendTextEditsForUri(allocator, &edits, uri, edit_array, workspace_root);
        }
    }

    return .{
        .allocator = allocator,
        .edits = try edits.toOwnedSlice(),
        .skipped_resource_ops = skipped_resource_ops,
    };
}

fn parseCodeAction(allocator: std.mem.Allocator, value: std.json.Value, workspace_root: ?[]const u8) !?CodeAction {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };

    const command_title_source = codeActionCommandTitle(object);
    const title_source = stringField(object, "title") orelse command_title_source orelse return null;
    const kind_source = stringField(object, "kind") orelse if (object.get("edit") != null) "quickfix" else "command";
    const command_source = command_title_source orelse "";

    const title = try allocator.dupe(u8, title_source);
    errdefer allocator.free(title);
    const kind = try allocator.dupe(u8, kind_source);
    errdefer allocator.free(kind);
    const command_title = try allocator.dupe(u8, command_source);
    errdefer allocator.free(command_title);

    var workspace_edit: ?WorkspaceEdit = null;
    errdefer if (workspace_edit) |*edit| edit.deinit();
    if (object.get("edit")) |edit_value| {
        const edit_object = switch (edit_value) {
            .object => |edit_object| edit_object,
            else => return error.InvalidCodeActionEdit,
        };
        workspace_edit = try parseWorkspaceEditObject(allocator, edit_object, workspace_root);
    }

    return .{
        .allocator = allocator,
        .title = title,
        .kind = kind,
        .command_title = command_title,
        .diagnostics = codeActionDiagnosticCount(object),
        .workspace_edit = workspace_edit,
    };
}

fn codeActionCommandTitle(object: std.json.ObjectMap) ?[]const u8 {
    const command_value = object.get("command") orelse return null;
    return switch (command_value) {
        .string => |command| command,
        .object => |command_object| stringField(command_object, "title") orelse stringField(command_object, "command"),
        else => null,
    };
}

fn codeActionDiagnosticCount(object: std.json.ObjectMap) usize {
    const value = object.get("diagnostics") orelse return 0;
    return switch (value) {
        .array => |array| array.items.len,
        else => 0,
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

fn appendTextEditsForUri(allocator: std.mem.Allocator, edits: *std.array_list.Managed(TextEdit), uri: []const u8, edit_array: std.json.Array, workspace_root: ?[]const u8) !void {
    for (edit_array.items) |edit_value| {
        const edit_object = switch (edit_value) {
            .object => |object| object,
            else => continue,
        };
        const range_value = edit_object.get("range") orelse return error.MissingWorkspaceEditRange;
        const new_text = stringField(edit_object, "newText") orelse return error.MissingWorkspaceEditNewText;
        const path = try lsp_diagnostics.fileUriToPath(allocator, uri, workspace_root);
        errdefer allocator.free(path);
        const owned_text = try allocator.dupe(u8, new_text);
        errdefer allocator.free(owned_text);
        try edits.append(.{
            .path = path,
            .range = try parseRange(range_value),
            .new_text = owned_text,
        });
    }
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

test "parse workspace edit response changes map" {
    const payload =
        \\{"jsonrpc":"2.0","id":9,"result":{"changes":{"file:///C:/Projects/zide/src/main.zig":[{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":8}},"newText":"renamed"}]}}}
    ;
    var edit = (try parseWorkspaceEditResponse(std.testing.allocator, payload, "C:\\Projects\\zide")).?;
    defer edit.deinit();

    try std.testing.expectEqual(@as(usize, 1), edit.edits.len);
    try std.testing.expectEqualStrings("src/main.zig", edit.edits[0].path);
    try std.testing.expectEqual(@as(usize, 2), edit.edits[0].range.start.line);
    try std.testing.expectEqual(@as(usize, 4), edit.edits[0].range.start.column);
    try std.testing.expectEqualStrings("renamed", edit.edits[0].new_text);
}

test "parse workspace edit response document changes" {
    const payload =
        \\{"jsonrpc":"2.0","id":10,"result":{"documentChanges":[{"textDocument":{"uri":"file:///tmp/project/src/main.zig","version":1},"edits":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},"newText":"pub"}]},{"kind":"rename","oldUri":"file:///tmp/project/old.zig","newUri":"file:///tmp/project/new.zig"}]}}
    ;
    var edit = (try parseWorkspaceEditResponse(std.testing.allocator, payload, "/tmp/project")).?;
    defer edit.deinit();

    try std.testing.expectEqual(@as(usize, 1), edit.edits.len);
    try std.testing.expectEqual(@as(usize, 1), edit.skipped_resource_ops);
    try std.testing.expectEqualStrings("src/main.zig", edit.edits[0].path);
    try std.testing.expectEqualStrings("pub", edit.edits[0].new_text);
}

test "parse code action response with workspace edit and command action" {
    const payload =
        \\{"jsonrpc":"2.0","id":12,"result":[{"title":"Remove unused local","kind":"quickfix","diagnostics":[{"message":"unused"}],"edit":{"changes":{"file:///tmp/project/src/main.zig":[{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":12}},"newText":""}]}}},{"title":"Organize Imports","kind":"source.organizeImports","command":{"title":"Organize Imports","command":"source.organizeImports"}}]}
    ;
    var actions = (try parseCodeActionResponse(std.testing.allocator, payload, "/tmp/project")).?;
    defer actions.deinit();

    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    try std.testing.expectEqualStrings("Remove unused local", actions.items[0].title);
    try std.testing.expectEqualStrings("quickfix", actions.items[0].kind);
    try std.testing.expectEqual(@as(usize, 1), actions.items[0].diagnostics);
    try std.testing.expect(actions.items[0].workspace_edit != null);
    try std.testing.expectEqualStrings("src/main.zig", actions.items[0].workspace_edit.?.edits[0].path);
    try std.testing.expectEqualStrings("", actions.items[0].workspace_edit.?.edits[0].new_text);
    try std.testing.expectEqualStrings("Organize Imports", actions.items[1].title);
    try std.testing.expectEqualStrings("Organize Imports", actions.items[1].command_title);
    try std.testing.expect(actions.items[1].workspace_edit == null);
}
