const std = @import("std");
const framing = @import("framing.zig");

pub const LaunchArguments = struct {
    adapter_id: []const u8,
    program: []const u8,
    cwd: []const u8,
    args: []const []const u8 = &.{},
    stop_on_entry: bool = false,
};

pub const SourceBreakpoint = struct {
    line: usize,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,
};

pub const EvaluateArguments = struct {
    expression: []const u8,
    frame_id: ?i64 = null,
    context: []const u8 = "watch",
};

pub fn makeInitializeRequest(allocator: std.mem.Allocator, seq: i64, adapter_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, seq, "initialize");
        try json.objectField("arguments");
        try json.beginObject();
        try field(&json, "clientID", "zide");
        try field(&json, "clientName", "ZIDE");
        try field(&json, "adapterID", adapter_id);
        try field(&json, "pathFormat", "path");
        try field(&json, "linesStartAt1", true);
        try field(&json, "columnsStartAt1", true);
        try field(&json, "supportsVariableType", true);
        try field(&json, "supportsVariablePaging", true);
        try field(&json, "supportsRunInTerminalRequest", false);
        try field(&json, "locale", "en-US");
        try json.endObject();
        try json.endObject();
    }
    return out.toOwnedSlice();
}

pub fn makeLaunchRequest(allocator: std.mem.Allocator, seq: i64, launch: LaunchArguments) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, seq, "launch");
        try json.objectField("arguments");
        try json.beginObject();
        try field(&json, "type", launch.adapter_id);
        try field(&json, "request", "launch");
        try field(&json, "name", "ZIDE secure debug");
        try field(&json, "program", launch.program);
        try field(&json, "cwd", launch.cwd);
        try field(&json, "noDebug", false);
        try field(&json, "stopOnEntry", launch.stop_on_entry);
        try field(&json, "console", "internalConsole");
        try json.objectField("args");
        try json.beginArray();
        for (launch.args) |arg| try json.write(arg);
        try json.endArray();
        try json.endObject();
        try json.endObject();
    }
    return out.toOwnedSlice();
}

pub fn makeSetBreakpointsRequest(
    allocator: std.mem.Allocator,
    seq: i64,
    source_path: []const u8,
    breakpoints: []const SourceBreakpoint,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, seq, "setBreakpoints");
        try json.objectField("arguments");
        try json.beginObject();
        try json.objectField("source");
        try json.beginObject();
        try field(&json, "name", std.fs.path.basename(source_path));
        try field(&json, "path", source_path);
        try json.endObject();
        try json.objectField("breakpoints");
        try json.beginArray();
        for (breakpoints) |breakpoint| {
            try json.beginObject();
            try field(&json, "line", breakpoint.line);
            if (breakpoint.condition) |condition| try field(&json, "condition", condition);
            if (breakpoint.hit_condition) |condition| try field(&json, "hitCondition", condition);
            if (breakpoint.log_message) |message| try field(&json, "logMessage", message);
            try json.endObject();
        }
        try json.endArray();
        try json.objectField("lines");
        try json.beginArray();
        for (breakpoints) |breakpoint| try json.write(breakpoint.line);
        try json.endArray();
        try field(&json, "sourceModified", false);
        try json.endObject();
        try json.endObject();
    }
    return out.toOwnedSlice();
}

pub fn makeConfigurationDoneRequest(allocator: std.mem.Allocator, seq: i64) ![]u8 {
    return makeEmptyArgumentsRequest(allocator, seq, "configurationDone");
}

pub fn makeThreadsRequest(allocator: std.mem.Allocator, seq: i64) ![]u8 {
    return makeRequestWithoutArguments(allocator, seq, "threads");
}

pub fn makeStackTraceRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64, start_frame: usize, levels: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, seq, "stackTrace");
        try json.objectField("arguments");
        try json.beginObject();
        try field(&json, "threadId", thread_id);
        try field(&json, "startFrame", start_frame);
        try field(&json, "levels", levels);
        try field(&json, "format", .{});
        try json.endObject();
        try json.endObject();
    }
    return out.toOwnedSlice();
}

pub fn makeScopesRequest(allocator: std.mem.Allocator, seq: i64, frame_id: i64) ![]u8 {
    return makeThreadOrFrameRequest(allocator, seq, "scopes", "frameId", frame_id);
}

pub fn makeVariablesRequest(allocator: std.mem.Allocator, seq: i64, reference: i64, start: usize, count: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, seq, "variables");
        try json.objectField("arguments");
        try json.beginObject();
        try field(&json, "variablesReference", reference);
        try field(&json, "start", start);
        try field(&json, "count", count);
        try json.endObject();
        try json.endObject();
    }
    return out.toOwnedSlice();
}

pub fn makeEvaluateRequest(allocator: std.mem.Allocator, seq: i64, arguments: EvaluateArguments) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, seq, "evaluate");
        try json.objectField("arguments");
        try json.beginObject();
        try field(&json, "expression", arguments.expression);
        if (arguments.frame_id) |frame_id| try field(&json, "frameId", frame_id);
        try field(&json, "context", arguments.context);
        try json.endObject();
        try json.endObject();
    }
    return out.toOwnedSlice();
}

pub fn makeContinueRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]u8 {
    return makeThreadOrFrameRequest(allocator, seq, "continue", "threadId", thread_id);
}

pub fn makePauseRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]u8 {
    return makeThreadOrFrameRequest(allocator, seq, "pause", "threadId", thread_id);
}

pub fn makeNextRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]u8 {
    return makeThreadOrFrameRequest(allocator, seq, "next", "threadId", thread_id);
}

pub fn makeStepInRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]u8 {
    return makeThreadOrFrameRequest(allocator, seq, "stepIn", "threadId", thread_id);
}

pub fn makeStepOutRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]u8 {
    return makeThreadOrFrameRequest(allocator, seq, "stepOut", "threadId", thread_id);
}

pub fn makeDisconnectRequest(allocator: std.mem.Allocator, seq: i64, terminate_debuggee: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, seq, "disconnect");
        try json.objectField("arguments");
        try json.beginObject();
        try field(&json, "restart", false);
        try field(&json, "terminateDebuggee", terminate_debuggee);
        try field(&json, "suspendDebuggee", false);
        try json.endObject();
        try json.endObject();
    }
    return out.toOwnedSlice();
}

pub fn makeErrorResponse(
    allocator: std.mem.Allocator,
    seq: i64,
    request_seq: i64,
    command: []const u8,
    message: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try json.beginObject();
        try field(&json, "seq", seq);
        try field(&json, "type", "response");
        try field(&json, "request_seq", request_seq);
        try field(&json, "success", false);
        try field(&json, "command", command);
        try field(&json, "message", message);
        try json.endObject();
    }
    return out.toOwnedSlice();
}

pub fn makeFramed(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return framing.encode(allocator, payload);
}

fn makeThreadOrFrameRequest(
    allocator: std.mem.Allocator,
    seq: i64,
    command: []const u8,
    id_name: []const u8,
    id: i64,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, seq, command);
        try json.objectField("arguments");
        try json.beginObject();
        try field(&json, id_name, id);
        try json.endObject();
        try json.endObject();
    }
    return out.toOwnedSlice();
}

fn makeEmptyArgumentsRequest(allocator: std.mem.Allocator, seq: i64, command: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, seq, command);
        try json.objectField("arguments");
        try json.beginObject();
        try json.endObject();
        try json.endObject();
    }
    return out.toOwnedSlice();
}

fn makeRequestWithoutArguments(allocator: std.mem.Allocator, seq: i64, command: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try beginRequest(&json, seq, command);
        try json.endObject();
    }
    return out.toOwnedSlice();
}

fn beginRequest(json: *std.json.Stringify, seq: i64, command: []const u8) !void {
    try json.beginObject();
    try field(json, "seq", seq);
    try field(json, "type", "request");
    try field(json, "command", command);
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

test "build DAP initialize and launch requests" {
    const initialize = try makeInitializeRequest(std.testing.allocator, 1, "lldb");
    defer std.testing.allocator.free(initialize);
    try std.testing.expect(std.mem.indexOf(u8, initialize, "\"command\":\"initialize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, initialize, "\"supportsRunInTerminalRequest\":false") != null);

    const launch = try makeLaunchRequest(std.testing.allocator, 2, .{
        .adapter_id = "lldb",
        .program = "C:\\repo\\zig-out\\bin\\app.exe",
        .cwd = "C:\\repo",
        .args = &.{ "--mode", "test" },
    });
    defer std.testing.allocator.free(launch);
    try std.testing.expect(std.mem.indexOf(u8, launch, "\"command\":\"launch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, launch, "app.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, launch, "\"args\":[\"--mode\",\"test\"]") != null);
}

test "build DAP breakpoint and reverse-request rejection" {
    const breakpoints = try makeSetBreakpointsRequest(std.testing.allocator, 3, "/repo/main.zig", &.{
        .{ .line = 7 },
        .{ .line = 11, .condition = "value > 4", .hit_condition = "3", .log_message = "value {value}" },
    });
    defer std.testing.allocator.free(breakpoints);
    try std.testing.expect(std.mem.indexOf(u8, breakpoints, "\"line\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, breakpoints, "value > 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, breakpoints, "\"hitCondition\":\"3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, breakpoints, "\"logMessage\":\"value {value}\"") != null);

    const denied = try makeErrorResponse(std.testing.allocator, 4, 99, "runInTerminal", "blocked by ZIDE policy");
    defer std.testing.allocator.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "\"success\":false") != null);
}

test "build DAP watch evaluation request" {
    const evaluate = try makeEvaluateRequest(std.testing.allocator, 5, .{
        .expression = "state.items[0].name",
        .frame_id = 42,
    });
    defer std.testing.allocator.free(evaluate);
    try std.testing.expect(std.mem.indexOf(u8, evaluate, "\"command\":\"evaluate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evaluate, "\"frameId\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, evaluate, "\"context\":\"watch\"") != null);
}
