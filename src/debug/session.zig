const std = @import("std");
const protocol = @import("protocol.zig");
const debug_breakpoint = @import("../security/debug_breakpoint.zig");

const max_collection_items: usize = 4096;
const max_event_text_bytes: usize = 64 * 1024;
const max_watches: usize = 64;
const max_watch_expression_bytes: usize = 4096;
const max_breakpoints: usize = 4096;

pub const DebugState = enum {
    idle,
    initializing,
    initialized,
    launching,
    configuring,
    running,
    paused,
    terminating,
    terminated,
    failed,
};

pub const State = DebugState;

pub const RequestKind = enum {
    initialize,
    launch,
    set_breakpoints,
    configuration_done,
    disconnect,
    continue_execution,
    pause,
    next,
    step_in,
    step_out,
    threads,
    stack_trace,
    scopes,
    variables,
    evaluate,
};

pub const EventKind = enum {
    initialized,
    stopped,
    continued,
    terminated,
    exited,
    output,
    thread,
    breakpoint,
    unknown,
};

pub const ReverseRequestKind = enum {
    run_in_terminal,
    start_debugging,
    unknown,
};

pub const Capabilities = struct {
    supports_configuration_done_request: bool = false,
    supports_conditional_breakpoints: bool = false,
    supports_hit_conditional_breakpoints: bool = false,
    supports_function_breakpoints: bool = false,
    supports_log_points: bool = false,
    supports_terminate_request: bool = false,
    supports_restart_request: bool = false,
    supports_step_back: bool = false,
    supports_set_variable: bool = false,
};

pub const Breakpoint = struct {
    path: []u8,
    line: usize,
    enabled: bool = true,
    condition: ?[]u8 = null,
    hit_condition: ?[]u8 = null,
    log_message: ?[]u8 = null,
    verified: bool = false,
    adapter_id: ?i64 = null,
    resolved_line: ?usize = null,
    message: ?[]u8 = null,

    fn deinit(self: *Breakpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.condition) |value| allocator.free(value);
        if (self.hit_condition) |value| allocator.free(value);
        if (self.log_message) |value| allocator.free(value);
        if (self.message) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Thread = struct {
    id: i64,
    name: []u8,

    fn deinit(self: *Thread, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const StackFrame = struct {
    id: i64,
    name: []u8,
    path: ?[]u8,
    line: usize,
    column: usize,

    fn deinit(self: *StackFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.path) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Scope = struct {
    name: []u8,
    variables_reference: i64,
    expensive: bool,
    named_variables: ?usize,
    indexed_variables: ?usize,

    fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Variable = struct {
    name: []u8,
    value: []u8,
    type_name: ?[]u8,
    evaluate_name: ?[]u8,
    variables_reference: i64,
    named_variables: ?usize,
    indexed_variables: ?usize,

    fn deinit(self: *Variable, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        if (self.type_name) |item| allocator.free(item);
        if (self.evaluate_name) |item| allocator.free(item);
        self.* = undefined;
    }
};

pub const Watch = struct {
    id: u64,
    expression: []u8,
    result: ?[]u8 = null,
    type_name: ?[]u8 = null,
    error_message: ?[]u8 = null,
    variables_reference: i64 = 0,
    pending_seq: ?i64 = null,

    fn clearRuntime(self: *Watch, allocator: std.mem.Allocator) void {
        if (self.result) |value| allocator.free(value);
        if (self.type_name) |value| allocator.free(value);
        if (self.error_message) |value| allocator.free(value);
        self.result = null;
        self.type_name = null;
        self.error_message = null;
        self.variables_reference = 0;
        self.pending_seq = null;
    }

    fn deinit(self: *Watch, allocator: std.mem.Allocator) void {
        self.clearRuntime(allocator);
        allocator.free(self.expression);
        self.* = undefined;
    }
};

pub const Pending = struct {
    seq: i64,
    kind: RequestKind,
    path: ?[]u8 = null,
    watch_id: ?u64 = null,

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const Outbound = struct {
    allocator: std.mem.Allocator,
    seq: i64,
    kind: ?RequestKind,
    payload: []u8,
    framed: []u8,

    pub fn deinit(self: *Outbound) void {
        self.allocator.free(self.framed);
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const ReverseRequest = struct {
    request_seq: i64,
    kind: ReverseRequestKind,
};

pub const IngestResult = union(enum) {
    ignored,
    acknowledged: RequestKind,
    failed: RequestKind,
    event: EventKind,
    reverse_request: ReverseRequest,
};

pub const ToggleResult = enum { added, removed };

pub const BreakpointProperty = debug_breakpoint.Property;

pub const BreakpointUpdateResult = enum {
    created,
    updated,
    unchanged,
};

pub const BreakpointSpec = struct {
    path: []const u8,
    line: usize,
    enabled: bool = true,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    workspace_root: []u8,
    state: DebugState = .idle,
    next_seq: i64 = 1,
    pending: std.array_list.Managed(Pending),
    breakpoints: std.array_list.Managed(Breakpoint),
    threads: std.array_list.Managed(Thread),
    stack_frames: std.array_list.Managed(StackFrame),
    scopes: std.array_list.Managed(Scope),
    variables: std.array_list.Managed(Variable),
    watches: std.array_list.Managed(Watch),
    next_watch_id: u64 = 1,
    capabilities: Capabilities = .{},
    active_thread_id: ?i64 = null,
    active_frame_id: ?i64 = null,
    stop_reason: ?[]u8 = null,
    last_output: ?[]u8 = null,
    last_output_category: ?[]u8 = null,
    last_error: ?[]u8 = null,
    last_reverse_command: ?[]u8 = null,
    exit_code: ?i64 = null,

    pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) !Session {
        return .{
            .allocator = allocator,
            .workspace_root = try allocator.dupe(u8, workspace_root),
            .pending = std.array_list.Managed(Pending).init(allocator),
            .breakpoints = std.array_list.Managed(Breakpoint).init(allocator),
            .threads = std.array_list.Managed(Thread).init(allocator),
            .stack_frames = std.array_list.Managed(StackFrame).init(allocator),
            .scopes = std.array_list.Managed(Scope).init(allocator),
            .variables = std.array_list.Managed(Variable).init(allocator),
            .watches = std.array_list.Managed(Watch).init(allocator),
        };
    }

    pub fn deinit(self: *Session) void {
        self.clearRuntimeData();
        for (self.breakpoints.items) |*item| item.deinit(self.allocator);
        for (self.watches.items) |*item| item.deinit(self.allocator);
        self.breakpoints.deinit();
        self.watches.deinit();
        self.variables.deinit();
        self.scopes.deinit();
        self.stack_frames.deinit();
        self.threads.deinit();
        self.pending.deinit();
        self.allocator.free(self.workspace_root);
        self.* = undefined;
    }

    pub fn reset(self: *Session) void {
        self.clearRuntimeData();
        self.state = .idle;
        self.next_seq = 1;
        self.capabilities = .{};
        self.exit_code = null;
        for (self.breakpoints.items) |*breakpoint| {
            breakpoint.verified = false;
            breakpoint.adapter_id = null;
            breakpoint.resolved_line = null;
            if (breakpoint.message) |message| self.allocator.free(message);
            breakpoint.message = null;
        }
    }

    pub fn pendingCount(self: *const Session) usize {
        return self.pending.items.len;
    }

    pub fn hasPending(self: *const Session, kind: RequestKind) bool {
        for (self.pending.items) |pending| {
            if (pending.kind == kind) return true;
        }
        return false;
    }

    pub fn addWatch(self: *Session, raw_expression: []const u8) !u64 {
        const expression = std.mem.trim(u8, raw_expression, " \t\r\n");
        if (expression.len == 0) return error.EmptyWatchExpression;
        if (expression.len > max_watch_expression_bytes) return error.WatchExpressionTooLong;
        for (self.watches.items) |watch| {
            if (std.mem.eql(u8, watch.expression, expression)) return watch.id;
        }
        if (self.watches.items.len >= max_watches) return error.TooManyWatches;

        const owned_expression = try self.allocator.dupe(u8, expression);
        errdefer self.allocator.free(owned_expression);
        const id = self.next_watch_id;
        try self.watches.append(.{
            .id = id,
            .expression = owned_expression,
        });
        self.next_watch_id +%= 1;
        if (self.next_watch_id == 0) self.next_watch_id = 1;
        return id;
    }

    pub fn removeWatchAt(self: *Session, index: usize) bool {
        if (index >= self.watches.items.len) return false;
        var removed = self.watches.orderedRemove(index);
        removed.deinit(self.allocator);
        return true;
    }

    pub fn clearWatches(self: *Session) void {
        for (self.watches.items) |*watch| watch.deinit(self.allocator);
        self.watches.clearRetainingCapacity();
    }

    pub fn toggleBreakpoint(self: *Session, path: []const u8, line: usize) !ToggleResult {
        if (line == 0) return error.InvalidBreakpointLine;
        for (self.breakpoints.items, 0..) |*breakpoint, index| {
            if (breakpoint.line != line or !pathEquals(breakpoint.path, path)) continue;
            var removed = self.breakpoints.orderedRemove(index);
            removed.deinit(self.allocator);
            return .removed;
        }
        _ = try self.addBreakpoint(path, line, true);
        return .added;
    }

    pub fn addBreakpoint(self: *Session, path: []const u8, line: usize, enabled: bool) !bool {
        return self.addConfiguredBreakpoint(.{ .path = path, .line = line, .enabled = enabled });
    }

    pub fn addConfiguredBreakpoint(self: *Session, spec: BreakpointSpec) !bool {
        if (spec.line == 0) return error.InvalidBreakpointLine;
        if (spec.path.len == 0 or spec.path.len > std.fs.max_path_bytes) return error.InvalidBreakpointPath;
        for (self.breakpoints.items) |breakpoint| {
            if (breakpoint.line == spec.line and pathEquals(breakpoint.path, spec.path)) return false;
        }
        if (self.breakpoints.items.len >= max_breakpoints) return error.TooManyBreakpoints;

        const condition = if (spec.condition) |value| try debug_breakpoint.validateCondition(value) else null;
        const hit_condition = if (spec.hit_condition) |value| try debug_breakpoint.validateHitCondition(value) else null;
        const log_message = if (spec.log_message) |value| try debug_breakpoint.validateLogMessage(value) else null;

        const owned_path = try self.allocator.dupe(u8, spec.path);
        errdefer self.allocator.free(owned_path);
        const owned_condition = if (condition) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_condition) |value| self.allocator.free(value);
        const owned_hit_condition = if (hit_condition) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_hit_condition) |value| self.allocator.free(value);
        const owned_log_message = if (log_message) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_log_message) |value| self.allocator.free(value);
        try self.breakpoints.append(.{
            .path = owned_path,
            .line = spec.line,
            .enabled = spec.enabled,
            .condition = owned_condition,
            .hit_condition = owned_hit_condition,
            .log_message = owned_log_message,
        });
        return true;
    }

    pub fn setBreakpointProperty(
        self: *Session,
        path: []const u8,
        line: usize,
        property: BreakpointProperty,
        raw_value: []const u8,
    ) !BreakpointUpdateResult {
        const value = try debug_breakpoint.validate(property, raw_value);
        for (self.breakpoints.items) |*breakpoint| {
            if (breakpoint.line != line or !pathEquals(breakpoint.path, path)) continue;
            const destination = switch (property) {
                .condition => &breakpoint.condition,
                .hit_condition => &breakpoint.hit_condition,
                .log_message => &breakpoint.log_message,
            };
            if (destination.*) |existing| {
                if (std.mem.eql(u8, existing, value)) return .unchanged;
            }
            const owned = try self.allocator.dupe(u8, value);
            if (destination.*) |existing| self.allocator.free(existing);
            destination.* = owned;
            breakpoint.verified = false;
            breakpoint.adapter_id = null;
            breakpoint.resolved_line = null;
            if (breakpoint.message) |message| self.allocator.free(message);
            breakpoint.message = null;
            return .updated;
        }

        var spec: BreakpointSpec = .{ .path = path, .line = line };
        switch (property) {
            .condition => spec.condition = value,
            .hit_condition => spec.hit_condition = value,
            .log_message => spec.log_message = value,
        }
        _ = try self.addConfiguredBreakpoint(spec);
        return .created;
    }

    pub fn clearBreakpointProperties(self: *Session, path: []const u8, line: usize) bool {
        for (self.breakpoints.items) |*breakpoint| {
            if (breakpoint.line != line or !pathEquals(breakpoint.path, path)) continue;
            if (breakpoint.condition) |value| self.allocator.free(value);
            if (breakpoint.hit_condition) |value| self.allocator.free(value);
            if (breakpoint.log_message) |value| self.allocator.free(value);
            breakpoint.condition = null;
            breakpoint.hit_condition = null;
            breakpoint.log_message = null;
            breakpoint.verified = false;
            breakpoint.adapter_id = null;
            breakpoint.resolved_line = null;
            if (breakpoint.message) |message| self.allocator.free(message);
            breakpoint.message = null;
            return true;
        }
        return false;
    }

    pub fn capabilitiesKnown(self: *const Session) bool {
        return switch (self.state) {
            .idle, .initializing => false,
            else => true,
        };
    }

    pub fn breakpointSupported(self: *const Session, breakpoint: Breakpoint) bool {
        if (!self.capabilitiesKnown()) return true;
        if (breakpoint.condition != null and !self.capabilities.supports_conditional_breakpoints) return false;
        if (breakpoint.hit_condition != null and !self.capabilities.supports_hit_conditional_breakpoints) return false;
        if (breakpoint.log_message != null and !self.capabilities.supports_log_points) return false;
        return true;
    }

    pub fn unsupportedBreakpointCountForPath(self: *const Session, path: []const u8) usize {
        if (!self.capabilitiesKnown()) return 0;
        var count: usize = 0;
        for (self.breakpoints.items) |breakpoint| {
            if (!breakpoint.enabled or !pathEquals(breakpoint.path, path)) continue;
            if (!self.breakpointSupported(breakpoint)) count += 1;
        }
        return count;
    }

    pub fn clearBreakpoints(self: *Session) void {
        for (self.breakpoints.items) |*breakpoint| breakpoint.deinit(self.allocator);
        self.breakpoints.clearRetainingCapacity();
    }

    pub fn makeInitialize(self: *Session, adapter_id: []const u8) !Outbound {
        const seq = self.takeSeq();
        const payload = try protocol.makeInitializeRequest(self.allocator, seq, adapter_id);
        self.state = .initializing;
        return self.wrapRequest(payload, seq, .initialize, null);
    }

    pub fn makeLaunch(self: *Session, launch: protocol.LaunchArguments) !Outbound {
        const seq = self.takeSeq();
        const payload = try protocol.makeLaunchRequest(self.allocator, seq, launch);
        self.state = .launching;
        return self.wrapRequest(payload, seq, .launch, null);
    }

    pub fn makeSetBreakpoints(self: *Session, path: []const u8) !Outbound {
        var items = std.array_list.Managed(protocol.SourceBreakpoint).init(self.allocator);
        defer items.deinit();
        for (self.breakpoints.items) |breakpoint| {
            if (!breakpoint.enabled or !pathEquals(breakpoint.path, path)) continue;
            if (!self.breakpointSupported(breakpoint)) continue;
            try items.append(.{
                .line = breakpoint.line,
                .condition = breakpoint.condition,
                .hit_condition = breakpoint.hit_condition,
                .log_message = breakpoint.log_message,
            });
        }
        const seq = self.takeSeq();
        const payload = try protocol.makeSetBreakpointsRequest(self.allocator, seq, path, items.items);
        return self.wrapRequest(payload, seq, .set_breakpoints, path);
    }

    pub fn makeConfigurationDone(self: *Session) !Outbound {
        const seq = self.takeSeq();
        const payload = try protocol.makeConfigurationDoneRequest(self.allocator, seq);
        return self.wrapRequest(payload, seq, .configuration_done, null);
    }

    pub fn makeThreads(self: *Session) !Outbound {
        const seq = self.takeSeq();
        return self.wrapRequest(try protocol.makeThreadsRequest(self.allocator, seq), seq, .threads, null);
    }

    pub fn makeStackTrace(self: *Session, thread_id: i64) !Outbound {
        const seq = self.takeSeq();
        return self.wrapRequest(try protocol.makeStackTraceRequest(self.allocator, seq, thread_id, 0, 200), seq, .stack_trace, null);
    }

    pub fn makeScopes(self: *Session, frame_id: i64) !Outbound {
        const seq = self.takeSeq();
        return self.wrapRequest(try protocol.makeScopesRequest(self.allocator, seq, frame_id), seq, .scopes, null);
    }

    pub fn makeVariables(self: *Session, reference: i64) !Outbound {
        const seq = self.takeSeq();
        return self.wrapRequest(try protocol.makeVariablesRequest(self.allocator, seq, reference, 0, 1000), seq, .variables, null);
    }

    pub fn makeEvaluateWatch(self: *Session, watch_id: u64, frame_id: i64) !Outbound {
        const watch = self.findWatch(watch_id) orelse return error.UnknownWatch;
        const seq = self.takeSeq();
        const payload = try protocol.makeEvaluateRequest(self.allocator, seq, .{
            .expression = watch.expression,
            .frame_id = frame_id,
            .context = "watch",
        });
        const outbound = try self.wrapWatchRequest(payload, seq, watch_id);
        watch.clearRuntime(self.allocator);
        watch.pending_seq = seq;
        return outbound;
    }

    pub fn makeContinue(self: *Session, thread_id: i64) !Outbound {
        const seq = self.takeSeq();
        return self.wrapRequest(try protocol.makeContinueRequest(self.allocator, seq, thread_id), seq, .continue_execution, null);
    }

    pub fn makePause(self: *Session, thread_id: i64) !Outbound {
        const seq = self.takeSeq();
        return self.wrapRequest(try protocol.makePauseRequest(self.allocator, seq, thread_id), seq, .pause, null);
    }

    pub fn makeNext(self: *Session, thread_id: i64) !Outbound {
        const seq = self.takeSeq();
        return self.wrapRequest(try protocol.makeNextRequest(self.allocator, seq, thread_id), seq, .next, null);
    }

    pub fn makeStepIn(self: *Session, thread_id: i64) !Outbound {
        const seq = self.takeSeq();
        return self.wrapRequest(try protocol.makeStepInRequest(self.allocator, seq, thread_id), seq, .step_in, null);
    }

    pub fn makeStepOut(self: *Session, thread_id: i64) !Outbound {
        const seq = self.takeSeq();
        return self.wrapRequest(try protocol.makeStepOutRequest(self.allocator, seq, thread_id), seq, .step_out, null);
    }

    pub fn makeDisconnect(self: *Session, terminate_debuggee: bool) !Outbound {
        const seq = self.takeSeq();
        self.state = .terminating;
        return self.wrapRequest(try protocol.makeDisconnectRequest(self.allocator, seq, terminate_debuggee), seq, .disconnect, null);
    }

    pub fn makeReverseRequestRejection(self: *Session, request_seq: i64, command: []const u8) !Outbound {
        const seq = self.takeSeq();
        const payload = try protocol.makeErrorResponse(
            self.allocator,
            seq,
            request_seq,
            command,
            "ZIDE blocks adapter-initiated process launches; use an explicitly approved launch plan",
        );
        const framed = try protocol.makeFramed(self.allocator, payload);
        return .{ .allocator = self.allocator, .seq = seq, .kind = null, .payload = payload, .framed = framed };
    }

    pub fn ingestPayload(self: *Session, payload: []const u8) !IngestResult {
        if (payload.len > @import("framing.zig").max_payload_bytes) return error.DebugPayloadTooLarge;
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return .ignored,
        };
        const message_type = stringField(object, "type") orelse return .ignored;
        if (std.mem.eql(u8, message_type, "response")) return self.ingestResponse(object);
        if (std.mem.eql(u8, message_type, "event")) return self.ingestEvent(object);
        if (std.mem.eql(u8, message_type, "request")) return self.ingestReverseRequest(object);
        return .ignored;
    }

    fn ingestResponse(self: *Session, object: std.json.ObjectMap) !IngestResult {
        const request_seq = intField(object, "request_seq") orelse return .ignored;
        var pending = self.takePending(request_seq) orelse return .ignored;
        defer pending.deinit(self.allocator);
        const success = boolField(object, "success", false);
        if (!success) {
            const message = stringField(object, "message") orelse "debug adapter request failed";
            if (pending.kind == .evaluate) {
                if (pending.watch_id) |watch_id| try self.setWatchError(watch_id, request_seq, message);
                return .{ .failed = pending.kind };
            }
            try self.setLastError(message);
            if (pending.kind == .initialize or pending.kind == .launch or pending.kind == .configuration_done) {
                self.state = .failed;
            }
            return .{ .failed = pending.kind };
        }

        const body = objectField(object, "body");
        switch (pending.kind) {
            .initialize => {
                if (body) |value| self.parseCapabilities(value);
                self.state = .initialized;
            },
            .launch => self.state = .configuring,
            .set_breakpoints => if (pending.path) |path| if (body) |value| try self.parseBreakpointsResponse(path, value),
            .configuration_done => self.state = .running,
            .disconnect => self.state = .terminated,
            .continue_execution, .next, .step_in, .step_out => self.state = .running,
            .pause => {},
            .threads => if (body) |value| try self.parseThreads(value),
            .stack_trace => if (body) |value| try self.parseStackFrames(value),
            .scopes => if (body) |value| try self.parseScopes(value),
            .variables => if (body) |value| try self.parseVariables(value),
            .evaluate => if (pending.watch_id) |watch_id| {
                if (body) |value|
                    try self.parseWatchEvaluation(watch_id, request_seq, value)
                else
                    try self.setWatchError(watch_id, request_seq, "debug adapter returned no evaluation body");
            },
        }
        self.clearLastError();
        return .{ .acknowledged = pending.kind };
    }

    fn ingestEvent(self: *Session, object: std.json.ObjectMap) !IngestResult {
        const event_name = stringField(object, "event") orelse return .ignored;
        const body = objectField(object, "body");
        if (std.mem.eql(u8, event_name, "initialized")) {
            self.state = .configuring;
            return .{ .event = .initialized };
        }
        if (std.mem.eql(u8, event_name, "stopped")) {
            self.state = .paused;
            self.active_thread_id = if (body) |value| intField(value, "threadId") else null;
            const reason = if (body) |value| stringField(value, "reason") orelse "paused" else "paused";
            try self.setStopReason(reason);
            return .{ .event = .stopped };
        }
        if (std.mem.eql(u8, event_name, "continued")) {
            self.state = .running;
            self.active_thread_id = if (body) |value| intField(value, "threadId") else self.active_thread_id;
            return .{ .event = .continued };
        }
        if (std.mem.eql(u8, event_name, "terminated")) {
            self.state = .terminated;
            return .{ .event = .terminated };
        }
        if (std.mem.eql(u8, event_name, "exited")) {
            self.state = .terminated;
            self.exit_code = if (body) |value| intField(value, "exitCode") else null;
            return .{ .event = .exited };
        }
        if (std.mem.eql(u8, event_name, "output")) {
            const text = if (body) |value| stringField(value, "output") orelse "" else "";
            const category = if (body) |value| stringField(value, "category") orelse "console" else "console";
            try self.setOutput(category, text);
            return .{ .event = .output };
        }
        if (std.mem.eql(u8, event_name, "thread")) return .{ .event = .thread };
        if (std.mem.eql(u8, event_name, "breakpoint")) return .{ .event = .breakpoint };
        return .{ .event = .unknown };
    }

    fn ingestReverseRequest(self: *Session, object: std.json.ObjectMap) !IngestResult {
        const request_seq = intField(object, "seq") orelse return .ignored;
        const command = stringField(object, "command") orelse return .ignored;
        if (self.last_reverse_command) |previous| self.allocator.free(previous);
        self.last_reverse_command = try dupeLimited(self.allocator, command, 256);
        const kind: ReverseRequestKind = if (std.mem.eql(u8, command, "runInTerminal"))
            .run_in_terminal
        else if (std.mem.eql(u8, command, "startDebugging"))
            .start_debugging
        else
            .unknown;
        return .{ .reverse_request = .{ .request_seq = request_seq, .kind = kind } };
    }

    fn parseCapabilities(self: *Session, body: std.json.ObjectMap) void {
        self.capabilities = .{
            .supports_configuration_done_request = boolField(body, "supportsConfigurationDoneRequest", false),
            .supports_conditional_breakpoints = boolField(body, "supportsConditionalBreakpoints", false),
            .supports_hit_conditional_breakpoints = boolField(body, "supportsHitConditionalBreakpoints", false),
            .supports_function_breakpoints = boolField(body, "supportsFunctionBreakpoints", false),
            .supports_log_points = boolField(body, "supportsLogPoints", false),
            .supports_terminate_request = boolField(body, "supportsTerminateRequest", false),
            .supports_restart_request = boolField(body, "supportsRestartRequest", false),
            .supports_step_back = boolField(body, "supportsStepBack", false),
            .supports_set_variable = boolField(body, "supportsSetVariable", false),
        };
    }

    fn parseBreakpointsResponse(self: *Session, path: []const u8, body: std.json.ObjectMap) !void {
        const values = arrayField(body, "breakpoints") orelse return;
        var response_index: usize = 0;
        for (self.breakpoints.items) |*breakpoint| {
            if (!breakpoint.enabled or !pathEquals(breakpoint.path, path)) continue;
            if (response_index >= values.items.len) break;
            const object = switch (values.items[response_index]) {
                .object => |item| item,
                else => {
                    response_index += 1;
                    continue;
                },
            };
            response_index += 1;
            breakpoint.verified = boolField(object, "verified", false);
            breakpoint.adapter_id = intField(object, "id");
            breakpoint.resolved_line = usizeField(object, "line");
            if (breakpoint.message) |message| self.allocator.free(message);
            breakpoint.message = if (stringField(object, "message")) |message|
                try dupeLimited(self.allocator, message, 4096)
            else
                null;
        }
    }

    fn parseThreads(self: *Session, body: std.json.ObjectMap) !void {
        clearThreads(self);
        const values = arrayField(body, "threads") orelse return;
        for (values.items[0..@min(values.items.len, max_collection_items)]) |value| {
            const object = switch (value) {
                .object => |object| object,
                else => continue,
            };
            const id = intField(object, "id") orelse continue;
            const name = stringField(object, "name") orelse "thread";
            try self.threads.append(.{ .id = id, .name = try dupeLimited(self.allocator, name, 4096) });
        }
        if (self.active_thread_id == null and self.threads.items.len > 0) self.active_thread_id = self.threads.items[0].id;
    }

    fn parseStackFrames(self: *Session, body: std.json.ObjectMap) !void {
        clearStackFrames(self);
        clearScopes(self);
        clearVariables(self);
        const values = arrayField(body, "stackFrames") orelse return;
        for (values.items[0..@min(values.items.len, max_collection_items)]) |value| {
            const object = switch (value) {
                .object => |object| object,
                else => continue,
            };
            const id = intField(object, "id") orelse continue;
            const name = stringField(object, "name") orelse "frame";
            const source = objectField(object, "source");
            const path = if (source) |source_object| if (stringField(source_object, "path")) |source_path|
                try dupeLimited(self.allocator, source_path, std.fs.max_path_bytes)
            else
                null else null;
            errdefer if (path) |owned| self.allocator.free(owned);
            try self.stack_frames.append(.{
                .id = id,
                .name = try dupeLimited(self.allocator, name, 4096),
                .path = path,
                .line = usizeField(object, "line") orelse 1,
                .column = usizeField(object, "column") orelse 1,
            });
        }
        self.active_frame_id = if (self.stack_frames.items.len > 0) self.stack_frames.items[0].id else null;
    }

    fn parseScopes(self: *Session, body: std.json.ObjectMap) !void {
        clearScopes(self);
        clearVariables(self);
        const values = arrayField(body, "scopes") orelse return;
        for (values.items[0..@min(values.items.len, max_collection_items)]) |value| {
            const object = switch (value) {
                .object => |object| object,
                else => continue,
            };
            const reference = intField(object, "variablesReference") orelse continue;
            const name = stringField(object, "name") orelse "scope";
            try self.scopes.append(.{
                .name = try dupeLimited(self.allocator, name, 4096),
                .variables_reference = reference,
                .expensive = boolField(object, "expensive", false),
                .named_variables = usizeField(object, "namedVariables"),
                .indexed_variables = usizeField(object, "indexedVariables"),
            });
        }
    }

    fn parseVariables(self: *Session, body: std.json.ObjectMap) !void {
        clearVariables(self);
        const values = arrayField(body, "variables") orelse return;
        for (values.items[0..@min(values.items.len, max_collection_items)]) |value| {
            const object = switch (value) {
                .object => |object| object,
                else => continue,
            };
            const name = stringField(object, "name") orelse continue;
            const display_value = stringField(object, "value") orelse "";
            var variable = Variable{
                .name = try dupeLimited(self.allocator, name, 4096),
                .value = undefined,
                .type_name = null,
                .evaluate_name = null,
                .variables_reference = intField(object, "variablesReference") orelse 0,
                .named_variables = usizeField(object, "namedVariables"),
                .indexed_variables = usizeField(object, "indexedVariables"),
            };
            errdefer variable.deinit(self.allocator);
            variable.value = try dupeLimited(self.allocator, display_value, max_event_text_bytes);
            if (stringField(object, "type")) |type_name| variable.type_name = try dupeLimited(self.allocator, type_name, 4096);
            if (stringField(object, "evaluateName")) |evaluate_name| variable.evaluate_name = try dupeLimited(self.allocator, evaluate_name, 4096);
            try self.variables.append(variable);
        }
    }

    fn parseWatchEvaluation(self: *Session, watch_id: u64, request_seq: i64, body: std.json.ObjectMap) !void {
        const watch = self.findWatch(watch_id) orelse return;
        if (watch.pending_seq != request_seq) return;

        const display_value = stringField(body, "result") orelse "";
        const owned_result = try dupeLimited(self.allocator, display_value, max_event_text_bytes);
        errdefer self.allocator.free(owned_result);
        const owned_type = if (stringField(body, "type")) |type_name|
            try dupeLimited(self.allocator, type_name, 4096)
        else
            null;
        errdefer if (owned_type) |value| self.allocator.free(value);

        watch.clearRuntime(self.allocator);
        watch.result = owned_result;
        watch.type_name = owned_type;
        watch.variables_reference = intField(body, "variablesReference") orelse 0;
    }

    fn setWatchError(self: *Session, watch_id: u64, request_seq: i64, message: []const u8) !void {
        const watch = self.findWatch(watch_id) orelse return;
        if (watch.pending_seq != request_seq) return;
        const owned_message = try dupeLimited(self.allocator, message, max_event_text_bytes);
        watch.clearRuntime(self.allocator);
        watch.error_message = owned_message;
    }

    fn findWatch(self: *Session, watch_id: u64) ?*Watch {
        for (self.watches.items) |*watch| {
            if (watch.id == watch_id) return watch;
        }
        return null;
    }

    fn wrapRequest(self: *Session, payload: []u8, seq: i64, kind: RequestKind, path: ?[]const u8) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        const owned_path = if (path) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_path) |value| self.allocator.free(value);
        try self.pending.append(.{ .seq = seq, .kind = kind, .path = owned_path });
        return .{ .allocator = self.allocator, .seq = seq, .kind = kind, .payload = payload, .framed = framed };
    }

    fn wrapWatchRequest(self: *Session, payload: []u8, seq: i64, watch_id: u64) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        try self.pending.append(.{ .seq = seq, .kind = .evaluate, .watch_id = watch_id });
        return .{ .allocator = self.allocator, .seq = seq, .kind = .evaluate, .payload = payload, .framed = framed };
    }

    fn takeSeq(self: *Session) i64 {
        const seq = self.next_seq;
        self.next_seq +%= 1;
        if (self.next_seq <= 0) self.next_seq = 1;
        return seq;
    }

    fn takePending(self: *Session, seq: i64) ?Pending {
        for (self.pending.items, 0..) |pending, index| {
            if (pending.seq == seq) return self.pending.orderedRemove(index);
        }
        return null;
    }

    fn clearRuntimeData(self: *Session) void {
        for (self.pending.items) |*item| item.deinit(self.allocator);
        self.pending.clearRetainingCapacity();
        clearThreads(self);
        clearStackFrames(self);
        clearScopes(self);
        clearVariables(self);
        for (self.watches.items) |*watch| watch.clearRuntime(self.allocator);
        self.active_thread_id = null;
        self.active_frame_id = null;
        if (self.stop_reason) |value| self.allocator.free(value);
        if (self.last_output) |value| self.allocator.free(value);
        if (self.last_output_category) |value| self.allocator.free(value);
        if (self.last_error) |value| self.allocator.free(value);
        if (self.last_reverse_command) |value| self.allocator.free(value);
        self.stop_reason = null;
        self.last_output = null;
        self.last_output_category = null;
        self.last_error = null;
        self.last_reverse_command = null;
    }

    fn setStopReason(self: *Session, reason: []const u8) !void {
        if (self.stop_reason) |previous| self.allocator.free(previous);
        self.stop_reason = try dupeLimited(self.allocator, reason, 4096);
    }

    fn setOutput(self: *Session, category: []const u8, output: []const u8) !void {
        if (self.last_output) |previous| self.allocator.free(previous);
        if (self.last_output_category) |previous| self.allocator.free(previous);
        self.last_output = try dupeLimited(self.allocator, output, max_event_text_bytes);
        errdefer {
            self.allocator.free(self.last_output.?);
            self.last_output = null;
        }
        self.last_output_category = try dupeLimited(self.allocator, category, 128);
    }

    fn setLastError(self: *Session, message: []const u8) !void {
        self.clearLastError();
        self.last_error = try dupeLimited(self.allocator, message, max_event_text_bytes);
    }

    fn clearLastError(self: *Session) void {
        if (self.last_error) |previous| self.allocator.free(previous);
        self.last_error = null;
    }
};

fn clearThreads(self: *Session) void {
    for (self.threads.items) |*item| item.deinit(self.allocator);
    self.threads.clearRetainingCapacity();
}

fn clearStackFrames(self: *Session) void {
    for (self.stack_frames.items) |*item| item.deinit(self.allocator);
    self.stack_frames.clearRetainingCapacity();
    self.active_frame_id = null;
}

fn clearScopes(self: *Session) void {
    for (self.scopes.items) |*item| item.deinit(self.allocator);
    self.scopes.clearRetainingCapacity();
}

fn clearVariables(self: *Session) void {
    for (self.variables.items) |*item| item.deinit(self.allocator);
    self.variables.clearRetainingCapacity();
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .object => |nested| nested,
        else => null,
    };
}

fn arrayField(object: std.json.ObjectMap, name: []const u8) ?std.json.Array {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8, fallback: bool) bool {
    const value = object.get(name) orelse return fallback;
    return switch (value) {
        .bool => |flag| flag,
        else => fallback,
    };
}

fn intField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn usizeField(object: std.json.ObjectMap, name: []const u8) ?usize {
    const number = intField(object, name) orelse return null;
    return if (number >= 0) @intCast(number) else null;
}

fn dupeLimited(allocator: std.mem.Allocator, value: []const u8, limit: usize) ![]u8 {
    return allocator.dupe(u8, value[0..@min(value.len, limit)]);
}

fn pathEquals(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left == right) continue;
        if ((left == '/' or left == '\\') and (right == '/' or right == '\\')) continue;
        if (@import("builtin").os.tag == .windows and std.ascii.toLower(left) == std.ascii.toLower(right)) continue;
        return false;
    }
    return true;
}

test "DAP session tracks requests and initialize capabilities" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    var initialize = try session.makeInitialize("lldb");
    defer initialize.deinit();
    try std.testing.expectEqual(DebugState.initializing, session.state);
    try std.testing.expectEqual(@as(usize, 1), session.pendingCount());

    const result = try session.ingestPayload(
        \\{"seq":1,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{"supportsConfigurationDoneRequest":true,"supportsConditionalBreakpoints":true}}
    );
    try std.testing.expectEqual(RequestKind.initialize, result.acknowledged);
    try std.testing.expectEqual(DebugState.initialized, session.state);
    try std.testing.expect(session.capabilities.supports_configuration_done_request);
    try std.testing.expect(session.capabilities.supports_conditional_breakpoints);
}

test "DAP session ingests stopped stack scopes and variables" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    const stopped = try session.ingestPayload(
        \\{"seq":2,"type":"event","event":"stopped","body":{"reason":"breakpoint","threadId":7}}
    );
    try std.testing.expectEqual(EventKind.stopped, stopped.event);
    try std.testing.expectEqual(DebugState.paused, session.state);
    try std.testing.expectEqual(@as(?i64, 7), session.active_thread_id);

    var stack = try session.makeStackTrace(7);
    defer stack.deinit();
    _ = try session.ingestPayload(
        \\{"seq":3,"type":"response","request_seq":1,"success":true,"command":"stackTrace","body":{"stackFrames":[{"id":42,"name":"main","source":{"path":"/repo/main.zig"},"line":9,"column":3}]}}
    );
    try std.testing.expectEqual(@as(usize, 1), session.stack_frames.items.len);
    try std.testing.expectEqual(@as(?i64, 42), session.active_frame_id);

    var scopes = try session.makeScopes(42);
    defer scopes.deinit();
    _ = try session.ingestPayload(
        \\{"seq":4,"type":"response","request_seq":2,"success":true,"command":"scopes","body":{"scopes":[{"name":"Locals","variablesReference":12,"expensive":false}]}}
    );
    try std.testing.expectEqual(@as(usize, 1), session.scopes.items.len);

    var variables = try session.makeVariables(12);
    defer variables.deinit();
    _ = try session.ingestPayload(
        \\{"seq":5,"type":"response","request_seq":3,"success":true,"command":"variables","body":{"variables":[{"name":"answer","value":"42","type":"usize","variablesReference":0}]}}
    );
    try std.testing.expectEqual(@as(usize, 1), session.variables.items.len);
    try std.testing.expectEqualStrings("answer", session.variables.items[0].name);
    try std.testing.expectEqualStrings("42", session.variables.items[0].value);
}

test "DAP session tracks breakpoints and rejects reverse execution requests" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    try std.testing.expectEqual(ToggleResult.added, try session.toggleBreakpoint("/repo/main.zig", 10));
    var outbound = try session.makeSetBreakpoints("/repo/main.zig");
    defer outbound.deinit();
    _ = try session.ingestPayload(
        \\{"seq":6,"type":"response","request_seq":1,"success":true,"command":"setBreakpoints","body":{"breakpoints":[{"id":3,"verified":true,"line":10}]}}
    );
    try std.testing.expect(session.breakpoints.items[0].verified);
    try std.testing.expectEqual(@as(?i64, 3), session.breakpoints.items[0].adapter_id);

    const reverse = try session.ingestPayload(
        \\{"seq":99,"type":"request","command":"runInTerminal","arguments":{"args":["sh","-c","evil"]}}
    );
    try std.testing.expectEqual(ReverseRequestKind.run_in_terminal, reverse.reverse_request.kind);
    try std.testing.expectEqualStrings("runInTerminal", session.last_reverse_command.?);
}

test "DAP session validates and emits advanced source breakpoints" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();
    session.state = .initialized;
    session.capabilities.supports_conditional_breakpoints = true;
    session.capabilities.supports_hit_conditional_breakpoints = true;
    session.capabilities.supports_log_points = true;

    try std.testing.expectEqual(BreakpointUpdateResult.created, try session.setBreakpointProperty("/repo/main.zig", 12, .condition, "value > 4"));
    try std.testing.expectEqual(BreakpointUpdateResult.updated, try session.setBreakpointProperty("/repo/main.zig", 12, .hit_condition, "3"));
    try std.testing.expectEqual(BreakpointUpdateResult.updated, try session.setBreakpointProperty("/repo/main.zig", 12, .log_message, "value {value}"));
    try std.testing.expectEqual(BreakpointUpdateResult.unchanged, try session.setBreakpointProperty("/repo/main.zig", 12, .hit_condition, "3"));

    var outbound = try session.makeSetBreakpoints("/repo/main.zig");
    defer outbound.deinit();
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "\"condition\":\"value > 4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "\"hitCondition\":\"3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "\"logMessage\":\"value {value}\"") != null);

    try std.testing.expect(session.clearBreakpointProperties("/repo/main.zig", 12));
    try std.testing.expect(session.breakpoints.items[0].condition == null);
    try std.testing.expect(session.breakpoints.items[0].hit_condition == null);
    try std.testing.expect(session.breakpoints.items[0].log_message == null);
}

test "DAP session withholds unsupported advanced breakpoints without downgrade" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();
    _ = try session.addConfiguredBreakpoint(.{
        .path = "/repo/main.zig",
        .line = 7,
        .condition = "ready == true",
    });
    session.state = .initialized;
    try std.testing.expectEqual(@as(usize, 1), session.unsupportedBreakpointCountForPath("/repo/main.zig"));

    var outbound = try session.makeSetBreakpoints("/repo/main.zig");
    defer outbound.deinit();
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "\"breakpoints\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "ready == true") == null);
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "\"line\":7") == null);
}

test "DAP session evaluates persistent watches and ignores stale results" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    const watch_id = try session.addWatch(" state.items[0].name ");
    try std.testing.expectEqual(watch_id, try session.addWatch("state.items[0].name"));
    try std.testing.expectEqual(@as(usize, 1), session.watches.items.len);
    try std.testing.expectEqualStrings("state.items[0].name", session.watches.items[0].expression);

    var first = try session.makeEvaluateWatch(watch_id, 41);
    defer first.deinit();
    var latest = try session.makeEvaluateWatch(watch_id, 42);
    defer latest.deinit();

    _ = try session.ingestPayload(
        \\{"seq":3,"type":"response","request_seq":1,"success":true,"command":"evaluate","body":{"result":"stale","type":"[]const u8","variablesReference":0}}
    );
    try std.testing.expect(session.watches.items[0].result == null);
    try std.testing.expectEqual(@as(?i64, 2), session.watches.items[0].pending_seq);

    const result = try session.ingestPayload(
        \\{"seq":4,"type":"response","request_seq":2,"success":true,"command":"evaluate","body":{"result":"zide","type":"[]const u8","variablesReference":17}}
    );
    try std.testing.expectEqual(RequestKind.evaluate, result.acknowledged);
    try std.testing.expectEqualStrings("zide", session.watches.items[0].result.?);
    try std.testing.expectEqualStrings("[]const u8", session.watches.items[0].type_name.?);
    try std.testing.expectEqual(@as(i64, 17), session.watches.items[0].variables_reference);
    try std.testing.expect(session.watches.items[0].pending_seq == null);

    session.reset();
    try std.testing.expectEqual(@as(usize, 1), session.watches.items.len);
    try std.testing.expectEqualStrings("state.items[0].name", session.watches.items[0].expression);
    try std.testing.expect(session.watches.items[0].result == null);
}

test "DAP session stores watch evaluation failures locally" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    const watch_id = try session.addWatch("missing.field");
    var evaluate = try session.makeEvaluateWatch(watch_id, 7);
    defer evaluate.deinit();
    const result = try session.ingestPayload(
        \\{"seq":2,"type":"response","request_seq":1,"success":false,"command":"evaluate","message":"unknown identifier"}
    );
    try std.testing.expectEqual(RequestKind.evaluate, result.failed);
    try std.testing.expectEqualStrings("unknown identifier", session.watches.items[0].error_message.?);
    try std.testing.expect(session.watches.items[0].pending_seq == null);
    try std.testing.expect(session.last_error == null);

    try std.testing.expect(session.removeWatchAt(0));
    try std.testing.expectEqual(@as(usize, 0), session.watches.items.len);
    try std.testing.expect(!session.removeWatchAt(0));
}

test "DAP session bounds automatic watch count" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    var expression_buf: [32]u8 = undefined;
    for (0..max_watches) |index| {
        const expression = try std.fmt.bufPrint(&expression_buf, "watch_{d}", .{index});
        _ = try session.addWatch(expression);
    }
    try std.testing.expectError(error.TooManyWatches, session.addWatch("one_too_many"));
}
