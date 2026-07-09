const std = @import("std");
const modes = @import("../language/modes.zig");
const framing = @import("framing.zig");

pub const RequestId = union(enum) {
    number: i64,
    string: []const u8,
};

pub const TextPosition = struct {
    line: usize,
    character: usize,
};

pub const TextDocument = struct {
    uri: []const u8,
    language_id: []const u8,
    version: i64,
    text: []const u8,
};

pub const RequestMethod = enum {
    initialize,
    shutdown,
    completion,
    hover,
    definition,
};

pub fn makeInitializeRequest(allocator: std.mem.Allocator, id: RequestId, root_uri: []const u8, client_name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, id, "initialize");
        try json.objectField("params");
        try json.beginObject();
        try json.objectField("processId");
        try json.write(null);
        try json.objectField("rootUri");
        try json.write(root_uri);
        try json.objectField("clientInfo");
        try json.beginObject();
        try json.objectField("name");
        try json.write(client_name);
        try json.objectField("version");
        try json.write("0.1.0");
        try json.endObject();
        try json.objectField("capabilities");
        try writeClientCapabilities(&json);
        try json.endObject();
        try json.endObject();
    }
    return try out.toOwnedSlice();
}

pub fn makeShutdownRequest(allocator: std.mem.Allocator, id: RequestId) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, id, "shutdown");
        try json.objectField("params");
        try json.write(null);
        try json.endObject();
    }
    return try out.toOwnedSlice();
}

pub fn makeExitNotification(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginNotification(&json, "exit");
        try json.endObject();
    }
    return try out.toOwnedSlice();
}

pub fn makeDidOpenNotification(allocator: std.mem.Allocator, document: TextDocument) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginNotification(&json, "textDocument/didOpen");
        try json.objectField("params");
        try json.beginObject();
        try json.objectField("textDocument");
        try json.beginObject();
        try json.objectField("uri");
        try json.write(document.uri);
        try json.objectField("languageId");
        try json.write(document.language_id);
        try json.objectField("version");
        try json.write(document.version);
        try json.objectField("text");
        try json.write(document.text);
        try json.endObject();
        try json.endObject();
        try json.endObject();
    }
    return try out.toOwnedSlice();
}

pub fn makePositionRequest(
    allocator: std.mem.Allocator,
    id: RequestId,
    method: RequestMethod,
    uri: []const u8,
    position: TextPosition,
) ![]u8 {
    const method_name = switch (method) {
        .completion => "textDocument/completion",
        .hover => "textDocument/hover",
        .definition => "textDocument/definition",
        .initialize, .shutdown => return error.NotPositionRequest,
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, id, method_name);
        try json.objectField("params");
        try json.beginObject();
        try json.objectField("textDocument");
        try json.beginObject();
        try json.objectField("uri");
        try json.write(uri);
        try json.endObject();
        try json.objectField("position");
        try writePosition(&json, position);
        try json.endObject();
        try json.endObject();
    }
    return try out.toOwnedSlice();
}

pub fn makeFramed(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return framing.encode(allocator, payload);
}

pub fn languageId(mode: modes.LanguageMode) []const u8 {
    return switch (mode) {
        .zig => "zig",
        .zon => "zig",
        .c => "c",
        .cpp => "cpp",
        .objective_c => "objective-c",
        .objective_cpp => "objective-cpp",
        .go => "go",
        .rust => "rust",
        .python => "python",
        .java => "java",
        .csharp => "csharp",
        .fsharp => "fsharp",
        .php => "php",
        .ruby => "ruby",
        .lua => "lua",
        .r => "r",
        .julia => "julia",
        .perl => "perl",
        .elixir => "elixir",
        .erlang => "erlang",
        .clojure => "clojure",
        .haskell => "haskell",
        .ocaml => "ocaml",
        .nim => "nim",
        .crystal => "crystal",
        .javascript, .jsx => "javascript",
        .typescript, .tsx => "typescript",
        .html => "html",
        .css => "css",
        .json => "json",
        .yaml => "yaml",
        .toml => "toml",
        .xml => "xml",
        .sql => "sql",
        .graphql => "graphql",
        .proto => "proto",
        .swift => "swift",
        .kotlin => "kotlin",
        .scala => "scala",
        .dart => "dart",
        .solidity => "solidity",
        .vue => "vue",
        .svelte => "svelte",
        .markdown => "markdown",
        else => "plaintext",
    };
}

pub fn pathToFileUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll("file://");
    if (looksLikeWindowsPath(path)) try out.writer.writeByte('/');
    for (path) |byte| {
        const normalized = if (byte == '\\') '/' else byte;
        if (isUriSafe(normalized)) {
            try out.writer.writeByte(normalized);
        } else {
            try out.writer.print("%{X:0>2}", .{normalized});
        }
    }
    return try out.toOwnedSlice();
}

fn beginRequest(json: *std.json.Stringify, id: RequestId, method: []const u8) !void {
    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("id");
    try writeRequestId(json, id);
    try json.objectField("method");
    try json.write(method);
}

fn beginNotification(json: *std.json.Stringify, method: []const u8) !void {
    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("method");
    try json.write(method);
}

fn writeRequestId(json: *std.json.Stringify, id: RequestId) !void {
    switch (id) {
        .number => |value| try json.write(value),
        .string => |value| try json.write(value),
    }
}

fn writeClientCapabilities(json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("textDocument");
    try json.beginObject();
    try json.objectField("synchronization");
    try json.beginObject();
    try json.objectField("didSave");
    try json.write(true);
    try json.objectField("willSave");
    try json.write(false);
    try json.endObject();
    try json.objectField("completion");
    try json.beginObject();
    try json.objectField("completionItem");
    try json.beginObject();
    try json.objectField("snippetSupport");
    try json.write(false);
    try json.endObject();
    try json.endObject();
    try json.objectField("hover");
    try json.beginObject();
    try json.endObject();
    try json.objectField("definition");
    try json.beginObject();
    try json.endObject();
    try json.objectField("publishDiagnostics");
    try json.beginObject();
    try json.endObject();
    try json.endObject();
    try json.objectField("workspace");
    try json.beginObject();
    try json.objectField("workspaceFolders");
    try json.write(false);
    try json.endObject();
    try json.endObject();
}

fn writePosition(json: *std.json.Stringify, position: TextPosition) !void {
    try json.beginObject();
    try json.objectField("line");
    try json.write(position.line);
    try json.objectField("character");
    try json.write(position.character);
    try json.endObject();
}

fn looksLikeWindowsPath(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

fn isUriSafe(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '/' or byte == ':' or byte == '-' or byte == '_' or byte == '.' or byte == '~';
}

test "build initialize request" {
    const payload = try makeInitializeRequest(std.testing.allocator, .{ .number = 1 }, "file:///tmp/project", "zide");
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"method\":\"initialize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"rootUri\":\"file:///tmp/project\"") != null);
}

test "build completion request and frame" {
    const payload = try makePositionRequest(std.testing.allocator, .{ .number = 7 }, .completion, "file:///tmp/main.zig", .{ .line = 3, .character = 9 });
    defer std.testing.allocator.free(payload);
    const framed = try makeFramed(std.testing.allocator, payload);
    defer std.testing.allocator.free(framed);

    try std.testing.expect(std.mem.indexOf(u8, payload, "textDocument/completion") != null);
    try std.testing.expect(std.mem.startsWith(u8, framed, "Content-Length: "));
}

test "path to file URI normalizes Windows paths" {
    const uri = try pathToFileUri(std.testing.allocator, "C:\\Projects\\zide main\\src\\main.zig");
    defer std.testing.allocator.free(uri);

    try std.testing.expectEqualStrings("file:///C:/Projects/zide%20main/src/main.zig", uri);
}
