const std = @import("std");
const collection_mod = @import("../diagnostics/collection.zig");
const model = @import("../diagnostics/model.zig");
const types = @import("../core/types.zig");

pub const PublishDiagnostics = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    diagnostics: []model.Diagnostic,

    pub fn deinit(self: *PublishDiagnostics) void {
        for (self.diagnostics) |item| {
            self.allocator.free(item.message);
        }
        self.allocator.free(self.diagnostics);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub fn parsePublishDiagnostics(allocator: std.mem.Allocator, payload: []const u8, workspace_root: ?[]const u8) !?PublishDiagnostics {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidLspMessage,
    };
    const method_value = root_object.get("method") orelse return null;
    const method = switch (method_value) {
        .string => |value| value,
        else => return error.InvalidLspMessage,
    };
    if (!std.mem.eql(u8, method, "textDocument/publishDiagnostics")) return null;

    const params_value = root_object.get("params") orelse return error.MissingParams;
    const params = switch (params_value) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    const uri = stringField(params, "uri") orelse return error.MissingUri;
    const path = try fileUriToPath(allocator, uri, workspace_root);
    errdefer allocator.free(path);

    const diagnostics_value = params.get("diagnostics") orelse return error.MissingDiagnostics;
    const diagnostics_array = switch (diagnostics_value) {
        .array => |array| array,
        else => return error.InvalidDiagnostics,
    };

    var diagnostics = std.array_list.Managed(model.Diagnostic).init(allocator);
    errdefer {
        for (diagnostics.items) |item| allocator.free(item.message);
        diagnostics.deinit();
    }

    for (diagnostics_array.items) |diagnostic_value| {
        const diagnostic_object = switch (diagnostic_value) {
            .object => |object| object,
            else => continue,
        };
        try diagnostics.append(try parseDiagnostic(allocator, path, diagnostic_object));
    }

    return .{
        .allocator = allocator,
        .path = path,
        .diagnostics = try diagnostics.toOwnedSlice(),
    };
}

pub fn applyPublishDiagnostics(collection: *collection_mod.Collection, publish: *const PublishDiagnostics) !void {
    collection.clearPathSource(publish.path, .lsp);
    for (publish.diagnostics) |item| {
        try collection.append(item);
    }
}

pub fn fileUriToPath(allocator: std.mem.Allocator, uri: []const u8, workspace_root: ?[]const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.UnsupportedUriScheme;

    var raw = uri[prefix.len..];
    if (raw.len >= 3 and raw[0] == '/' and std.ascii.isAlphabetic(raw[1]) and raw[2] == ':') {
        raw = raw[1..];
    }

    const decoded = try percentDecodePath(allocator, raw);
    errdefer allocator.free(decoded);
    normalizeSlashes(decoded);

    if (workspace_root) |root| {
        const normalized_root = try allocator.dupe(u8, root);
        defer allocator.free(normalized_root);
        normalizeSlashes(normalized_root);
        trimTrailingSlash(normalized_root);

        if (pathStartsWith(decoded, normalized_root)) {
            var relative_start = normalized_root.len;
            if (relative_start < decoded.len and decoded[relative_start] == '/') relative_start += 1;
            const relative = try allocator.dupe(u8, decoded[relative_start..]);
            allocator.free(decoded);
            return relative;
        }
    }

    return decoded;
}

fn parseDiagnostic(allocator: std.mem.Allocator, path: []const u8, object: std.json.ObjectMap) !model.Diagnostic {
    const range_object = switch (object.get("range") orelse return error.MissingRange) {
        .object => |range| range,
        else => return error.InvalidRange,
    };
    const start = try parsePosition(range_object.get("start") orelse return error.MissingRangeStart);
    const end = if (range_object.get("end")) |value| try parsePosition(value) else start;
    const severity = lspSeverity(object.get("severity"));
    const message = try allocator.dupe(u8, stringField(object, "message") orelse "(no message)");

    return .{
        .source = .lsp,
        .severity = severity,
        .path = path,
        .range = .{ .start = start, .end = end },
        .message = message,
    };
}

fn parsePosition(value: std.json.Value) !types.Position {
    const object = switch (value) {
        .object => |position| position,
        else => return error.InvalidPosition,
    };
    return .{
        .line = intField(object, "line", 0),
        .column = intField(object, "character", 0),
        .byte_offset = 0,
    };
}

fn lspSeverity(value: ?std.json.Value) types.Severity {
    const number = if (value) |actual| switch (actual) {
        .integer => |integer| integer,
        else => 3,
    } else 3;
    return switch (number) {
        1 => .err,
        2 => .warning,
        else => .info,
    };
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

fn percentDecodePath(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, value.len);
    errdefer allocator.free(out);

    var read: usize = 0;
    var write: usize = 0;
    while (read < value.len) {
        if (value[read] == '%' and read + 2 < value.len) {
            const high = hexNibble(value[read + 1]);
            const low = hexNibble(value[read + 2]);
            if (high != null and low != null) {
                out[write] = (high.? << 4) | low.?;
                read += 3;
                write += 1;
                continue;
            }
        }
        out[write] = value[read];
        read += 1;
        write += 1;
    }
    return allocator.realloc(out, write);
}

fn hexNibble(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

fn normalizeSlashes(path: []u8) void {
    for (path) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
}

fn trimTrailingSlash(path: []u8) void {
    while (path.len > 1 and path[path.len - 1] == '/') {
        path.len -= 1;
    }
}

fn pathStartsWith(path: []const u8, root: []const u8) bool {
    if (path.len < root.len) return false;
    const prefix_matches = if (looksLikeWindowsPath(path) or looksLikeWindowsPath(root))
        std.ascii.eqlIgnoreCase(path[0..root.len], root)
    else
        std.mem.eql(u8, path[0..root.len], root);
    if (!prefix_matches) return false;
    return path.len == root.len or path[root.len] == '/';
}

fn looksLikeWindowsPath(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

test "parse publish diagnostics into model diagnostics" {
    const payload =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///C:/Projects/zide/src/main.zig","diagnostics":[{"range":{"start":{"line":4,"character":2},"end":{"line":4,"character":8}},"severity":1,"message":"boom"}]}}
    ;
    var publish = (try parsePublishDiagnostics(std.testing.allocator, payload, "C:\\Projects\\zide")).?;
    defer publish.deinit();

    try std.testing.expectEqualStrings("src/main.zig", publish.path);
    try std.testing.expectEqual(@as(usize, 1), publish.diagnostics.len);
    try std.testing.expectEqual(model.DiagnosticSource.lsp, publish.diagnostics[0].source);
    try std.testing.expectEqual(types.Severity.err, publish.diagnostics[0].severity);
    try std.testing.expectEqual(@as(usize, 4), publish.diagnostics[0].range.start.line);
    try std.testing.expectEqual(@as(usize, 2), publish.diagnostics[0].range.start.column);
    try std.testing.expectEqualStrings("boom", publish.diagnostics[0].message);
}

test "apply publish diagnostics replaces only LSP diagnostics for path" {
    var collection = collection_mod.Collection.init(std.testing.allocator);
    defer collection.deinit();
    const position = types.Position.start();
    try collection.append(.{ .source = .compiler, .severity = .err, .path = "src/main.zig", .range = types.Range.empty(position), .message = "compiler" });

    const payload =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/project/src/main.zig","diagnostics":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":1}},"severity":2,"message":"lsp warning"}]}}
    ;
    var publish = (try parsePublishDiagnostics(std.testing.allocator, payload, "/tmp/project")).?;
    defer publish.deinit();
    try applyPublishDiagnostics(&collection, &publish);

    try std.testing.expectEqual(@as(usize, 2), collection.items.items.len);
    try std.testing.expectEqual(model.DiagnosticSource.compiler, collection.items.items[0].source);
    try std.testing.expectEqual(model.DiagnosticSource.lsp, collection.items.items[1].source);
}
