const std = @import("std");
const diagnostics_collection = @import("../diagnostics/collection.zig");
const modes = @import("../language/modes.zig");
const types = @import("../core/types.zig");
const lsp_diagnostics = @import("diagnostics.zig");
const protocol = @import("protocol.zig");
const responses = @import("responses.zig");

pub const State = enum {
    idle,
    initialized,
    shutting_down,
    stopped,
};

pub const RequestKind = enum {
    initialize,
    shutdown,
    completion,
    hover,
    definition,
    references,
    implementation,
    type_definition,
    document_highlight,
    signature_help,
    rename,
    code_action,
    formatting,
    document_symbol,
    workspace_symbol,
};

pub const Pending = struct {
    id: i64,
    kind: RequestKind,
    path: ?[]u8 = null,

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const Outbound = struct {
    allocator: std.mem.Allocator,
    id: ?i64,
    kind: ?RequestKind,
    payload: []u8,
    framed: []u8,

    pub fn deinit(self: *Outbound) void {
        self.allocator.free(self.framed);
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const IngestResult = union(enum) {
    ignored,
    diagnostics: usize,
    completion: usize,
    hover: usize,
    locations: usize,
    workspace_edit: usize,
    code_actions: usize,
    acknowledged: RequestKind,
};

pub const CodeActionDiagnostic = protocol.CodeActionDiagnostic;

pub const Session = struct {
    allocator: std.mem.Allocator,
    workspace_root: []u8,
    state: State = .idle,
    next_request_id: i64 = 1,
    pending: std.array_list.Managed(Pending),
    opened_documents: std.array_list.Managed(DocumentVersion),
    last_completion: ?responses.CompletionItems = null,
    last_hover: ?responses.Hover = null,
    last_locations: ?responses.Locations = null,
    last_locations_kind: ?RequestKind = null,
    last_workspace_edit: ?responses.WorkspaceEdit = null,
    last_workspace_edit_kind: ?RequestKind = null,
    last_code_actions: ?responses.CodeActions = null,

    pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) !Session {
        return .{
            .allocator = allocator,
            .workspace_root = try allocator.dupe(u8, workspace_root),
            .pending = std.array_list.Managed(Pending).init(allocator),
            .opened_documents = std.array_list.Managed(DocumentVersion).init(allocator),
        };
    }

    pub fn deinit(self: *Session) void {
        self.clearLastResults();
        for (self.opened_documents.items) |item| self.allocator.free(item.path);
        self.opened_documents.deinit();
        for (self.pending.items) |*pending| pending.deinit(self.allocator);
        self.pending.deinit();
        self.allocator.free(self.workspace_root);
        self.* = undefined;
    }

    pub fn pendingCount(self: *const Session) usize {
        return self.pending.items.len;
    }

    pub fn openedCount(self: *const Session) usize {
        return self.opened_documents.items.len;
    }

    pub fn cancelPending(self: *Session, id: i64) void {
        if (self.takePending(id)) |pending_value| {
            var pending = pending_value;
            pending.deinit(self.allocator);
        }
    }

    pub fn clearCachedResultForRequest(self: *Session, kind: RequestKind) void {
        switch (kind) {
            .completion => self.clearLastCompletion(),
            .hover => self.clearLastHover(),
            .definition, .references, .implementation, .type_definition => self.clearLastLocations(),
            .rename, .formatting => self.clearLastWorkspaceEdit(),
            .code_action => self.clearLastCodeActions(),
            else => {},
        }
    }

    pub fn documentVersion(self: *const Session, path: []const u8) ?i64 {
        for (self.opened_documents.items) |item| {
            if (pathEquals(item.path, path)) return item.version;
        }
        return null;
    }

    pub fn makeInitialize(self: *Session, client_name: []const u8) !Outbound {
        const id = self.nextId();
        const root_uri = try protocol.pathToFileUri(self.allocator, self.workspace_root);
        defer self.allocator.free(root_uri);
        const payload = try protocol.makeInitializeRequest(self.allocator, .{ .number = id }, root_uri, client_name);
        return try self.wrapRequest(payload, id, .initialize);
    }

    pub fn makeShutdown(self: *Session) !Outbound {
        const id = self.nextId();
        const payload = try protocol.makeShutdownRequest(self.allocator, .{ .number = id });
        self.state = .shutting_down;
        return try self.wrapRequest(payload, id, .shutdown);
    }

    pub fn makeExit(self: *Session) !Outbound {
        const payload = try protocol.makeExitNotification(self.allocator);
        self.state = .stopped;
        return try self.wrapNotification(payload);
    }

    pub fn makeInitialized(self: *Session) !Outbound {
        const payload = try protocol.makeInitializedNotification(self.allocator);
        return try self.wrapNotification(payload);
    }

    pub fn makeDidOpen(self: *Session, path: []const u8, language: modes.LanguageMode, version: i64, text: []const u8) !Outbound {
        const uri = try self.uriForPath(path);
        defer self.allocator.free(uri);
        const payload = try protocol.makeDidOpenNotification(self.allocator, .{
            .uri = uri,
            .language_id = protocol.languageId(language),
            .version = version,
            .text = text,
        });
        try self.rememberDocument(path, version);
        return try self.wrapNotification(payload);
    }

    pub fn makeDidChange(self: *Session, path: []const u8, version: i64, text: []const u8) !Outbound {
        const uri = try self.uriForPath(path);
        defer self.allocator.free(uri);
        const payload = try protocol.makeDidChangeNotification(self.allocator, .{
            .uri = uri,
            .version = version,
            .text = text,
        });
        try self.rememberDocument(path, version);
        return try self.wrapNotification(payload);
    }

    pub fn makeDidSave(self: *Session, path: []const u8, text: ?[]const u8) !Outbound {
        const uri = try self.uriForPath(path);
        defer self.allocator.free(uri);
        const payload = try protocol.makeDidSaveNotification(self.allocator, uri, text);
        return try self.wrapNotification(payload);
    }

    pub fn requestPosition(self: *Session, kind: RequestKind, path: []const u8, position: types.Position) !Outbound {
        const method = protocolMethod(kind) orelse return error.NotPositionRequest;
        const id = self.nextId();
        const uri = try self.uriForPath(path);
        defer self.allocator.free(uri);
        const payload = try protocol.makePositionRequest(self.allocator, .{ .number = id }, method, uri, .{
            .line = position.line,
            .character = position.column,
        });
        return try self.wrapRequest(payload, id, kind);
    }

    pub fn requestRename(self: *Session, path: []const u8, position: types.Position, new_name: []const u8) !Outbound {
        const id = self.nextId();
        const uri = try self.uriForPath(path);
        defer self.allocator.free(uri);
        const payload = try protocol.makeRenameRequest(self.allocator, .{ .number = id }, uri, .{
            .line = position.line,
            .character = position.column,
        }, new_name);
        return try self.wrapRequest(payload, id, .rename);
    }

    pub fn requestCodeActions(self: *Session, path: []const u8, range: types.Range, diagnostics: []const CodeActionDiagnostic) !Outbound {
        const id = self.nextId();
        const uri = try self.uriForPath(path);
        defer self.allocator.free(uri);
        const payload = try protocol.makeCodeActionRequest(self.allocator, .{ .number = id }, uri, .{
            .start = .{ .line = range.start.line, .character = range.start.column },
            .end = .{ .line = range.end.line, .character = range.end.column },
        }, diagnostics);
        return try self.wrapRequest(payload, id, .code_action);
    }

    pub fn requestFormatting(self: *Session, path: []const u8, tab_size: usize, insert_spaces: bool) !Outbound {
        const id = self.nextId();
        const uri = try self.uriForPath(path);
        defer self.allocator.free(uri);
        const payload = try protocol.makeFormattingRequest(self.allocator, .{ .number = id }, uri, tab_size, insert_spaces);
        return try self.wrapRequestWithPath(payload, id, .formatting, path);
    }

    pub fn requestDocumentSymbols(self: *Session, path: []const u8) !Outbound {
        const id = self.nextId();
        const uri = try self.uriForPath(path);
        defer self.allocator.free(uri);
        const payload = try protocol.makeDocumentRequest(self.allocator, .{ .number = id }, .document_symbol, uri);
        return try self.wrapRequest(payload, id, .document_symbol);
    }

    pub fn requestWorkspaceSymbols(self: *Session, query: []const u8) !Outbound {
        const id = self.nextId();
        const payload = try protocol.makeWorkspaceRequest(self.allocator, .{ .number = id }, .workspace_symbol, query);
        return try self.wrapRequest(payload, id, .workspace_symbol);
    }

    pub fn ingestPayload(self: *Session, payload: []const u8, diagnostics: *diagnostics_collection.Collection) !IngestResult {
        if (try lsp_diagnostics.parsePublishDiagnostics(self.allocator, payload, self.workspace_root)) |publish_value| {
            var publish = publish_value;
            defer publish.deinit();
            try lsp_diagnostics.applyPublishDiagnostics(diagnostics, &publish);
            return .{ .diagnostics = publish.diagnostics.len };
        }

        const id = try responseId(self.allocator, payload) orelse return .ignored;
        var pending = self.takePending(id) orelse return .ignored;
        defer pending.deinit(self.allocator);
        switch (pending.kind) {
            .initialize => {
                self.state = .initialized;
                return .{ .acknowledged = .initialize };
            },
            .shutdown => {
                self.state = .stopped;
                return .{ .acknowledged = .shutdown };
            },
            .completion => {
                if (try responses.parseCompletionResponse(self.allocator, payload)) |items| {
                    self.clearLastCompletion();
                    self.last_completion = items;
                    return .{ .completion = items.items.len };
                }
                return .ignored;
            },
            .hover => {
                if (try responses.parseHoverResponse(self.allocator, payload)) |hover| {
                    self.clearLastHover();
                    self.last_hover = hover;
                    return .{ .hover = hover.text.len };
                }
                return .ignored;
            },
            .definition, .references, .implementation, .type_definition => {
                if (try responses.parseLocationResponse(self.allocator, payload, self.workspace_root)) |locations| {
                    self.clearLastLocations();
                    self.last_locations = locations;
                    self.last_locations_kind = pending.kind;
                    return .{ .locations = locations.items.len };
                }
                return .ignored;
            },
            .rename => {
                if (try responses.parseWorkspaceEditResponse(self.allocator, payload, self.workspace_root)) |edit| {
                    self.clearLastWorkspaceEdit();
                    self.last_workspace_edit = edit;
                    self.last_workspace_edit_kind = pending.kind;
                    return .{ .workspace_edit = edit.edits.len };
                }
                return .ignored;
            },
            .formatting => {
                const path = pending.path orelse return .ignored;
                if (try responses.parseFormattingResponse(self.allocator, payload, path)) |edit| {
                    self.clearLastWorkspaceEdit();
                    self.last_workspace_edit = edit;
                    self.last_workspace_edit_kind = pending.kind;
                    return .{ .workspace_edit = edit.edits.len };
                }
                return .ignored;
            },
            .code_action => {
                if (try responses.parseCodeActionResponse(self.allocator, payload, self.workspace_root)) |actions| {
                    self.clearLastCodeActions();
                    self.last_code_actions = actions;
                    return .{ .code_actions = actions.items.len };
                }
                return .ignored;
            },
            .document_highlight, .signature_help, .document_symbol, .workspace_symbol => {
                return .{ .acknowledged = pending.kind };
            },
        }
    }

    fn nextId(self: *Session) i64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    fn wrapRequest(self: *Session, payload: []u8, id: i64, kind: RequestKind) !Outbound {
        return try self.wrapRequestWithPath(payload, id, kind, null);
    }

    fn wrapRequestWithPath(self: *Session, payload: []u8, id: i64, kind: RequestKind, path: ?[]const u8) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        const pending_path = if (path) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (pending_path) |value| self.allocator.free(value);
        try self.pending.append(.{ .id = id, .kind = kind, .path = pending_path });
        return .{
            .allocator = self.allocator,
            .id = id,
            .kind = kind,
            .payload = payload,
            .framed = framed,
        };
    }

    fn wrapNotification(self: *Session, payload: []u8) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        return .{
            .allocator = self.allocator,
            .id = null,
            .kind = null,
            .payload = payload,
            .framed = framed,
        };
    }

    fn takePending(self: *Session, id: i64) ?Pending {
        for (self.pending.items, 0..) |pending, index| {
            if (pending.id == id) return self.pending.orderedRemove(index);
        }
        return null;
    }

    fn rememberDocument(self: *Session, path: []const u8, version: i64) !void {
        for (self.opened_documents.items) |*item| {
            if (pathEquals(item.path, path)) {
                item.version = version;
                return;
            }
        }
        try self.opened_documents.append(.{
            .path = try self.allocator.dupe(u8, path),
            .version = version,
        });
    }

    fn uriForPath(self: *Session, path: []const u8) ![]u8 {
        if (looksAbsolute(path)) return protocol.pathToFileUri(self.allocator, path);
        const absolute = try std.fs.path.join(self.allocator, &.{ self.workspace_root, path });
        defer self.allocator.free(absolute);
        return protocol.pathToFileUri(self.allocator, absolute);
    }

    fn clearLastResults(self: *Session) void {
        self.clearLastCompletion();
        self.clearLastHover();
        self.clearLastLocations();
        self.clearLastWorkspaceEdit();
        self.clearLastCodeActions();
    }

    fn clearLastCompletion(self: *Session) void {
        if (self.last_completion) |*items| items.deinit();
        self.last_completion = null;
    }

    fn clearLastHover(self: *Session) void {
        if (self.last_hover) |*hover| hover.deinit();
        self.last_hover = null;
    }

    fn clearLastLocations(self: *Session) void {
        if (self.last_locations) |*locations| locations.deinit();
        self.last_locations = null;
        self.last_locations_kind = null;
    }

    fn clearLastWorkspaceEdit(self: *Session) void {
        if (self.last_workspace_edit) |*edit| edit.deinit();
        self.last_workspace_edit = null;
        self.last_workspace_edit_kind = null;
    }

    fn clearLastCodeActions(self: *Session) void {
        if (self.last_code_actions) |*actions| actions.deinit();
        self.last_code_actions = null;
    }
};

const DocumentVersion = struct {
    path: []u8,
    version: i64,
};

fn protocolMethod(kind: RequestKind) ?protocol.RequestMethod {
    return switch (kind) {
        .completion => .completion,
        .hover => .hover,
        .definition => .definition,
        .references => .references,
        .implementation => .implementation,
        .type_definition => .type_definition,
        .document_highlight => .document_highlight,
        .signature_help => .signature_help,
        else => null,
    };
}

fn responseId(allocator: std.mem.Allocator, payload: []const u8) !?i64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const id_value = object.get("id") orelse return null;
    return switch (id_value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn looksAbsolute(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return true;
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

fn pathEquals(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    if (looksAbsolute(left) or looksAbsolute(right)) return std.ascii.eqlIgnoreCase(left, right);
    return false;
}

test "session builds initialize and tracks pending request" {
    var session = try Session.init(std.testing.allocator, "C:\\Projects\\zide");
    defer session.deinit();

    var outbound = try session.makeInitialize("zide-test");
    defer outbound.deinit();

    try std.testing.expectEqual(@as(?i64, 1), outbound.id);
    try std.testing.expectEqual(@as(usize, 1), session.pendingCount());
    try std.testing.expect(std.mem.startsWith(u8, outbound.framed, "Content-Length: "));
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "\"method\":\"initialize\"") != null);
}

test "session builds initialized notification without pending request" {
    var session = try Session.init(std.testing.allocator, "C:\\Projects\\zide");
    defer session.deinit();

    var outbound = try session.makeInitialized();
    defer outbound.deinit();

    try std.testing.expect(outbound.id == null);
    try std.testing.expect(outbound.kind == null);
    try std.testing.expectEqual(@as(usize, 0), session.pendingCount());
    try std.testing.expect(std.mem.startsWith(u8, outbound.framed, "Content-Length: "));
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "\"method\":\"initialized\"") != null);
}

test "session syncs document notifications and versions" {
    var session = try Session.init(std.testing.allocator, "/tmp/project");
    defer session.deinit();

    var open = try session.makeDidOpen("src/main.zig", .zig, 1, "pub fn main() void {}\n");
    defer open.deinit();
    try std.testing.expectEqual(@as(usize, 1), session.openedCount());
    try std.testing.expect(std.mem.indexOf(u8, open.payload, "textDocument/didOpen") != null);

    var change = try session.makeDidChange("src/main.zig", 2, "pub fn main() void { }\n");
    defer change.deinit();
    try std.testing.expectEqual(@as(usize, 1), session.openedCount());
    try std.testing.expectEqual(@as(i64, 2), session.opened_documents.items[0].version);
    try std.testing.expect(std.mem.indexOf(u8, change.payload, "textDocument/didChange") != null);
}

test "session routes completion response by pending id" {
    var session = try Session.init(std.testing.allocator, "/tmp/project");
    defer session.deinit();

    var outbound = try session.requestPosition(.completion, "src/main.zig", .{ .line = 0, .column = 4, .byte_offset = 4 });
    defer outbound.deinit();

    var collection = diagnostics_collection.Collection.init(std.testing.allocator);
    defer collection.deinit();
    const payload =
        \\{"jsonrpc":"2.0","id":1,"result":[{"label":"main","kind":3,"detail":"fn"}]}
    ;
    const result = try session.ingestPayload(payload, &collection);
    try std.testing.expectEqual(IngestResult{ .completion = 1 }, result);
    try std.testing.expectEqual(@as(usize, 0), session.pendingCount());
    try std.testing.expect(session.last_completion != null);
}

test "session applies publish diagnostics without a pending request" {
    var session = try Session.init(std.testing.allocator, "/tmp/project");
    defer session.deinit();

    var collection = diagnostics_collection.Collection.init(std.testing.allocator);
    defer collection.deinit();
    const payload =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/project/src/main.zig","diagnostics":[{"range":{"start":{"line":2,"character":1},"end":{"line":2,"character":4}},"severity":2,"message":"warn"}]}}
    ;
    const result = try session.ingestPayload(payload, &collection);
    try std.testing.expectEqual(IngestResult{ .diagnostics = 1 }, result);
    try std.testing.expectEqual(@as(usize, 1), collection.items.items.len);
    try std.testing.expectEqualStrings("src/main.zig", collection.items.items[0].path);
}

test "session routes definition locations by pending id" {
    var session = try Session.init(std.testing.allocator, "/tmp/project");
    defer session.deinit();

    var outbound = try session.requestPosition(.definition, "src/main.zig", .{ .line = 0, .column = 4, .byte_offset = 4 });
    defer outbound.deinit();

    var collection = diagnostics_collection.Collection.init(std.testing.allocator);
    defer collection.deinit();
    const payload =
        \\{"jsonrpc":"2.0","id":1,"result":{"uri":"file:///tmp/project/src/lib.zig","range":{"start":{"line":7,"character":2},"end":{"line":7,"character":8}}}}
    ;
    const result = try session.ingestPayload(payload, &collection);
    try std.testing.expectEqual(IngestResult{ .locations = 1 }, result);
    try std.testing.expect(session.last_locations != null);
    try std.testing.expectEqual(RequestKind.definition, session.last_locations_kind.?);
    try std.testing.expectEqualStrings("src/lib.zig", session.last_locations.?.items[0].path);
}

test "session routes rename workspace edit by pending id" {
    var session = try Session.init(std.testing.allocator, "/tmp/project");
    defer session.deinit();

    var outbound = try session.requestRename("src/main.zig", .{ .line = 0, .column = 4, .byte_offset = 4 }, "renamed");
    defer outbound.deinit();

    var collection = diagnostics_collection.Collection.init(std.testing.allocator);
    defer collection.deinit();
    const payload =
        \\{"jsonrpc":"2.0","id":1,"result":{"changes":{"file:///tmp/project/src/main.zig":[{"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":8}},"newText":"renamed"}]}}}
    ;
    const result = try session.ingestPayload(payload, &collection);
    try std.testing.expectEqual(IngestResult{ .workspace_edit = 1 }, result);
    try std.testing.expect(session.last_workspace_edit != null);
    try std.testing.expectEqual(RequestKind.rename, session.last_workspace_edit_kind.?);
    try std.testing.expectEqualStrings("src/main.zig", session.last_workspace_edit.?.edits[0].path);
    try std.testing.expectEqualStrings("renamed", session.last_workspace_edit.?.edits[0].new_text);
}

test "session routes formatting edits by pending id" {
    var session = try Session.init(std.testing.allocator, "/tmp/project");
    defer session.deinit();

    var outbound = try session.requestFormatting("src/main.zig", 4, true);
    defer outbound.deinit();
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "textDocument/formatting") != null);

    var collection = diagnostics_collection.Collection.init(std.testing.allocator);
    defer collection.deinit();
    const payload =
        \\{"jsonrpc":"2.0","id":1,"result":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":8}},"newText":"const x = 1;"}]}
    ;
    const result = try session.ingestPayload(payload, &collection);
    try std.testing.expectEqual(IngestResult{ .workspace_edit = 1 }, result);
    try std.testing.expect(session.last_workspace_edit != null);
    try std.testing.expectEqual(RequestKind.formatting, session.last_workspace_edit_kind.?);
    try std.testing.expectEqualStrings("src/main.zig", session.last_workspace_edit.?.edits[0].path);
    try std.testing.expectEqualStrings("const x = 1;", session.last_workspace_edit.?.edits[0].new_text);
}

test "session routes code actions by pending id" {
    var session = try Session.init(std.testing.allocator, "/tmp/project");
    defer session.deinit();

    var outbound = try session.requestCodeActions("src/main.zig", .{
        .start = .{ .line = 0, .column = 4, .byte_offset = 4 },
        .end = .{ .line = 0, .column = 8, .byte_offset = 8 },
    }, &.{
        .{
            .range = .{
                .start = .{ .line = 0, .character = 4 },
                .end = .{ .line = 0, .character = 8 },
            },
            .severity = 1,
            .message = "unused",
        },
    });
    defer outbound.deinit();

    var collection = diagnostics_collection.Collection.init(std.testing.allocator);
    defer collection.deinit();
    const payload =
        \\{"jsonrpc":"2.0","id":1,"result":[{"title":"Remove unused","kind":"quickfix","edit":{"changes":{"file:///tmp/project/src/main.zig":[{"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":8}},"newText":""}]}}}]}
    ;
    const result = try session.ingestPayload(payload, &collection);
    try std.testing.expectEqual(IngestResult{ .code_actions = 1 }, result);
    try std.testing.expectEqual(@as(usize, 0), session.pendingCount());
    try std.testing.expect(session.last_code_actions != null);
    try std.testing.expectEqualStrings("Remove unused", session.last_code_actions.?.items[0].title);
    try std.testing.expect(session.last_code_actions.?.items[0].workspace_edit != null);
}
