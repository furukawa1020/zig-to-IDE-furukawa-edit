const std = @import("std");
const protocol = @import("protocol.zig");
const debug_breakpoint = @import("../security/debug_breakpoint.zig");
const debug_data = @import("../security/debug_data.zig");
const debug_exception = @import("../security/debug_exception.zig");
const debug_function = @import("../security/debug_function.zig");
const debug_memory = @import("../security/debug_memory.zig");

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
    set_function_breakpoints,
    data_breakpoint_info,
    set_data_breakpoints,
    set_instruction_breakpoints,
    set_exception_breakpoints,
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
    read_memory,
    disassemble,
};

pub const EventKind = enum {
    initialized,
    capabilities,
    stopped,
    continued,
    terminated,
    exited,
    output,
    thread,
    breakpoint,
    memory,
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
    supports_data_breakpoints: bool = false,
    supports_read_memory_request: bool = false,
    supports_write_memory_request: bool = false,
    supports_disassemble_request: bool = false,
    supports_instruction_breakpoints: bool = false,
    supports_log_points: bool = false,
    supports_terminate_request: bool = false,
    supports_restart_request: bool = false,
    supports_step_back: bool = false,
    supports_set_variable: bool = false,
    supports_exception_filter_options: bool = false,
};

pub const ExceptionFilter = struct {
    id: []u8,
    label: []u8,
    description: ?[]u8 = null,
    default_enabled: bool = false,
    supports_condition: bool = false,
    verified: ?bool = null,
    adapter_id: ?i64 = null,
    message: ?[]u8 = null,

    fn clearRuntime(self: *ExceptionFilter, allocator: std.mem.Allocator) void {
        if (self.message) |value| allocator.free(value);
        self.verified = null;
        self.adapter_id = null;
        self.message = null;
    }

    fn deinit(self: *ExceptionFilter, allocator: std.mem.Allocator) void {
        self.clearRuntime(allocator);
        allocator.free(self.id);
        allocator.free(self.label);
        if (self.description) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ExceptionFilterView = struct {
    id: []const u8,
    label: []const u8,
    description: ?[]const u8,
    default_enabled: bool,
    supports_condition: bool,
    selected: bool,
    advertised: bool,
    verified: ?bool,
    message: ?[]const u8,
};

pub const FunctionBreakpoint = struct {
    name: []u8,
    verified: ?bool = null,
    adapter_id: ?i64 = null,
    message: ?[]u8 = null,

    fn clearRuntime(self: *FunctionBreakpoint, allocator: std.mem.Allocator) void {
        if (self.message) |value| allocator.free(value);
        self.verified = null;
        self.adapter_id = null;
        self.message = null;
    }

    fn deinit(self: *FunctionBreakpoint, allocator: std.mem.Allocator) void {
        self.clearRuntime(allocator);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const DataAccessSet = struct {
    read: bool = false,
    write: bool = false,
    read_write: bool = false,

    pub fn count(self: DataAccessSet) usize {
        return @as(usize, @intFromBool(self.read)) +
            @as(usize, @intFromBool(self.write)) +
            @as(usize, @intFromBool(self.read_write));
    }

    pub fn allows(self: DataAccessSet, access_type: debug_data.AccessType) bool {
        return switch (access_type) {
            .read => self.read,
            .write => self.write,
            .read_write => self.read_write,
        };
    }

    fn insert(self: *DataAccessSet, access_type: debug_data.AccessType) bool {
        const flag = switch (access_type) {
            .read => &self.read,
            .write => &self.write,
            .read_write => &self.read_write,
        };
        if (flag.*) return false;
        flag.* = true;
        return true;
    }
};

pub const DataBreakpointCandidate = struct {
    adapter_key: []u8,
    data_id: ?[]u8,
    description: []u8,
    variable_name: []u8,
    access_types: DataAccessSet = .{},
    can_persist: bool = false,
    pause_generation: u64,

    fn deinit(self: *DataBreakpointCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.adapter_key);
        if (self.data_id) |data_id| allocator.free(data_id);
        allocator.free(self.description);
        allocator.free(self.variable_name);
        self.* = undefined;
    }
};

pub const DataBreakpoint = struct {
    adapter_key: []u8,
    data_id: []u8,
    description: []u8,
    access_type: ?debug_data.AccessType = null,
    can_persist: bool = false,
    verified: ?bool = null,
    adapter_id: ?i64 = null,
    message: ?[]u8 = null,

    fn clearRuntime(self: *DataBreakpoint, allocator: std.mem.Allocator) void {
        if (self.message) |value| allocator.free(value);
        self.verified = null;
        self.adapter_id = null;
        self.message = null;
    }

    fn deinit(self: *DataBreakpoint, allocator: std.mem.Allocator) void {
        self.clearRuntime(allocator);
        allocator.free(self.adapter_key);
        allocator.free(self.data_id);
        allocator.free(self.description);
        self.* = undefined;
    }
};

pub const InstructionBreakpoint = struct {
    adapter_key: []u8,
    instruction_reference: []u8,
    label: []u8,
    verified: ?bool = null,
    adapter_id: ?i64 = null,
    message: ?[]u8 = null,

    fn clearRuntime(self: *InstructionBreakpoint, allocator: std.mem.Allocator) void {
        if (self.message) |value| allocator.free(value);
        self.verified = null;
        self.adapter_id = null;
        self.message = null;
    }

    fn deinit(self: *InstructionBreakpoint, allocator: std.mem.Allocator) void {
        self.clearRuntime(allocator);
        allocator.free(self.adapter_key);
        allocator.free(self.instruction_reference);
        allocator.free(self.label);
        self.* = undefined;
    }
};

pub const MemorySnapshot = struct {
    memory_reference: []u8,
    address: []u8,
    bytes: []u8,
    offset: i64,
    unreadable_bytes: usize,
    pause_generation: u64,

    fn deinit(self: *MemorySnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.memory_reference);
        allocator.free(self.address);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const DisassembledInstruction = struct {
    address: []u8,
    instruction_bytes: ?[]u8,
    instruction: []u8,
    symbol: ?[]u8,
    source_path: ?[]u8,
    line: ?usize,
    column: ?usize,
    invalid: bool,
    pause_generation: u64,

    fn deinit(self: *DisassembledInstruction, allocator: std.mem.Allocator) void {
        allocator.free(self.address);
        if (self.instruction_bytes) |value| allocator.free(value);
        allocator.free(self.instruction);
        if (self.symbol) |value| allocator.free(value);
        if (self.source_path) |value| allocator.free(value);
        self.* = undefined;
    }
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
    instruction_pointer_reference: ?[]u8,
    pause_generation: u64,

    fn deinit(self: *StackFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.path) |value| allocator.free(value);
        if (self.instruction_pointer_reference) |value| allocator.free(value);
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
    memory_reference: ?[]u8,
    parent_variables_reference: i64,
    frame_id: ?i64,
    pause_generation: u64,

    fn deinit(self: *Variable, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        if (self.type_name) |item| allocator.free(item);
        if (self.evaluate_name) |item| allocator.free(item);
        if (self.memory_reference) |item| allocator.free(item);
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
    function_names: ?[][]u8 = null,
    data_ids: ?[][]u8 = null,
    exception_filter_ids: ?[][]u8 = null,
    instruction_references: ?[][]u8 = null,
    variable_name: ?[]u8 = null,
    memory_reference: ?[]u8 = null,
    variables_reference: ?i64 = null,
    frame_id: ?i64 = null,
    memory_offset: ?i64 = null,
    memory_count: ?usize = null,
    instruction_count: ?usize = null,
    pause_generation: ?u64 = null,

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
        if (self.function_names) |function_names| {
            for (function_names) |name| allocator.free(name);
            allocator.free(function_names);
        }
        if (self.data_ids) |data_ids| {
            for (data_ids) |data_id| allocator.free(data_id);
            allocator.free(data_ids);
        }
        if (self.exception_filter_ids) |filter_ids| {
            for (filter_ids) |filter_id| allocator.free(filter_id);
            allocator.free(filter_ids);
        }
        if (self.instruction_references) |references| {
            for (references) |reference| allocator.free(reference);
            allocator.free(references);
        }
        if (self.variable_name) |variable_name| allocator.free(variable_name);
        if (self.memory_reference) |memory_reference| allocator.free(memory_reference);
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

pub const FunctionBreakpointCapability = enum {
    unknown,
    supported,
    unsupported,
};

pub const DataBreakpointCapability = enum {
    unknown,
    supported,
    unsupported,
};

pub const LowLevelCapability = enum {
    unknown,
    supported,
    unsupported,
};

pub const DataBreakpointUpdateResult = enum {
    added,
    updated,
    unchanged,
};

pub const DataBreakpointCommitChoice = enum {
    adapter_default,
    read,
    write,
    read_write,

    pub fn accessType(self: DataBreakpointCommitChoice) ?debug_data.AccessType {
        return switch (self) {
            .adapter_default => null,
            .read => .read,
            .write => .write,
            .read_write => .read_write,
        };
    }

    pub fn commandArgument(self: DataBreakpointCommitChoice) []const u8 {
        return if (self.accessType()) |access_type| access_type.protocolName() else "default";
    }

    pub fn displayName(self: DataBreakpointCommitChoice) []const u8 {
        return if (self.accessType()) |access_type| access_type.displayName() else "ADAPTER DEFAULT";
    }
};

pub const BreakpointProperty = debug_breakpoint.Property;
pub const DataBreakpointAccessType = debug_data.AccessType;

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
    configuration_ready: bool = false,
    next_seq: i64 = 1,
    pending: std.array_list.Managed(Pending),
    breakpoints: std.array_list.Managed(Breakpoint),
    function_breakpoints: std.array_list.Managed(FunctionBreakpoint),
    data_breakpoints: std.array_list.Managed(DataBreakpoint),
    data_breakpoint_candidate: ?DataBreakpointCandidate = null,
    instruction_breakpoints: std.array_list.Managed(InstructionBreakpoint),
    exception_filters: std.array_list.Managed(ExceptionFilter),
    selected_exception_filter_ids: std.array_list.Managed([]u8),
    rejected_exception_filter_metadata: usize = 0,
    rejected_data_breakpoint_metadata: usize = 0,
    rejected_low_level_metadata: usize = 0,
    threads: std.array_list.Managed(Thread),
    stack_frames: std.array_list.Managed(StackFrame),
    scopes: std.array_list.Managed(Scope),
    variables: std.array_list.Managed(Variable),
    disassembled_instructions: std.array_list.Managed(DisassembledInstruction),
    memory_snapshot: ?MemorySnapshot = null,
    watches: std.array_list.Managed(Watch),
    next_watch_id: u64 = 1,
    capabilities: Capabilities = .{},
    active_thread_id: ?i64 = null,
    active_frame_id: ?i64 = null,
    active_adapter_key: ?[]u8 = null,
    pause_generation: u64 = 0,
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
            .function_breakpoints = std.array_list.Managed(FunctionBreakpoint).init(allocator),
            .data_breakpoints = std.array_list.Managed(DataBreakpoint).init(allocator),
            .instruction_breakpoints = std.array_list.Managed(InstructionBreakpoint).init(allocator),
            .exception_filters = std.array_list.Managed(ExceptionFilter).init(allocator),
            .selected_exception_filter_ids = std.array_list.Managed([]u8).init(allocator),
            .threads = std.array_list.Managed(Thread).init(allocator),
            .stack_frames = std.array_list.Managed(StackFrame).init(allocator),
            .scopes = std.array_list.Managed(Scope).init(allocator),
            .variables = std.array_list.Managed(Variable).init(allocator),
            .disassembled_instructions = std.array_list.Managed(DisassembledInstruction).init(allocator),
            .watches = std.array_list.Managed(Watch).init(allocator),
        };
    }

    pub fn deinit(self: *Session) void {
        self.clearRuntimeData();
        for (self.breakpoints.items) |*item| item.deinit(self.allocator);
        for (self.function_breakpoints.items) |*item| item.deinit(self.allocator);
        for (self.data_breakpoints.items) |*item| item.deinit(self.allocator);
        for (self.instruction_breakpoints.items) |*item| item.deinit(self.allocator);
        self.clearDataBreakpointCandidate();
        for (self.exception_filters.items) |*item| item.deinit(self.allocator);
        for (self.selected_exception_filter_ids.items) |filter_id| self.allocator.free(filter_id);
        for (self.watches.items) |*item| item.deinit(self.allocator);
        self.breakpoints.deinit();
        self.function_breakpoints.deinit();
        self.data_breakpoints.deinit();
        self.instruction_breakpoints.deinit();
        self.exception_filters.deinit();
        self.selected_exception_filter_ids.deinit();
        self.watches.deinit();
        self.variables.deinit();
        self.disassembled_instructions.deinit();
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
        self.configuration_ready = false;
        self.next_seq = 1;
        self.capabilities = .{};
        clearExceptionFilters(self);
        self.rejected_exception_filter_metadata = 0;
        self.rejected_data_breakpoint_metadata = 0;
        self.rejected_low_level_metadata = 0;
        self.exit_code = null;
        for (self.breakpoints.items) |*breakpoint| {
            breakpoint.verified = false;
            breakpoint.adapter_id = null;
            breakpoint.resolved_line = null;
            if (breakpoint.message) |message| self.allocator.free(message);
            breakpoint.message = null;
        }
        for (self.function_breakpoints.items) |*breakpoint| breakpoint.clearRuntime(self.allocator);
        _ = self.clearInstructionBreakpoints();
        self.clearDataBreakpointCandidate();
        var data_index: usize = 0;
        while (data_index < self.data_breakpoints.items.len) {
            if (!self.data_breakpoints.items[data_index].can_persist) {
                var breakpoint = self.data_breakpoints.orderedRemove(data_index);
                breakpoint.deinit(self.allocator);
                continue;
            }
            self.data_breakpoints.items[data_index].clearRuntime(self.allocator);
            data_index += 1;
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

    pub fn acceptsBreakpointConfiguration(self: *const Session) bool {
        if (!self.configuration_ready) return false;
        return switch (self.state) {
            .terminating, .terminated, .failed => false,
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

    pub fn addFunctionBreakpoint(self: *Session, raw_name: []const u8) !bool {
        const name = try debug_function.validate(raw_name);
        if (self.findFunctionBreakpoint(name) != null) return false;
        if (self.function_breakpoints.items.len >= debug_function.max_breakpoints) return error.TooManyFunctionBreakpoints;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.function_breakpoints.append(.{ .name = owned_name });
        return true;
    }

    pub fn removeFunctionBreakpointAt(self: *Session, index: usize) bool {
        if (index >= self.function_breakpoints.items.len) return false;
        var breakpoint = self.function_breakpoints.orderedRemove(index);
        breakpoint.deinit(self.allocator);
        return true;
    }

    pub fn clearFunctionBreakpoints(self: *Session) bool {
        if (self.function_breakpoints.items.len == 0) return false;
        for (self.function_breakpoints.items) |*breakpoint| breakpoint.deinit(self.allocator);
        self.function_breakpoints.clearRetainingCapacity();
        return true;
    }

    pub fn functionBreakpointsSupported(self: *const Session) bool {
        return self.functionBreakpointCapability() == .supported;
    }

    pub fn functionBreakpointCapability(self: *const Session) FunctionBreakpointCapability {
        if (!self.capabilitiesKnown()) return .unknown;
        return if (self.capabilities.supports_function_breakpoints) .supported else .unsupported;
    }

    pub fn unsupportedFunctionBreakpointCount(self: *const Session) usize {
        if (self.functionBreakpointCapability() != .unsupported) return 0;
        return self.function_breakpoints.items.len;
    }

    pub fn dataBreakpointsSupported(self: *const Session) bool {
        return self.dataBreakpointCapability() == .supported;
    }

    pub fn dataBreakpointCapability(self: *const Session) DataBreakpointCapability {
        if (!self.capabilitiesKnown()) return .unknown;
        return if (self.capabilities.supports_data_breakpoints) .supported else .unsupported;
    }

    pub fn unsupportedDataBreakpointCount(self: *const Session) usize {
        if (self.dataBreakpointCapability() != .unsupported) return 0;
        return self.data_breakpoints.items.len;
    }

    pub fn withheldDataBreakpointCount(self: *const Session) usize {
        if (!self.capabilitiesKnown()) return 0;
        if (!self.capabilities.supports_data_breakpoints) return self.data_breakpoints.items.len;
        const adapter_key = self.active_adapter_key orelse return self.data_breakpoints.items.len;
        var count: usize = 0;
        for (self.data_breakpoints.items) |breakpoint| {
            if (!std.mem.eql(u8, breakpoint.adapter_key, adapter_key)) count += 1;
        }
        return count;
    }

    pub fn dataBreakpointCandidateCommitChoiceCount(self: *const Session) usize {
        const candidate = self.data_breakpoint_candidate orelse return 0;
        if (candidate.data_id == null) return 0;
        const advertised = candidate.access_types.count();
        return if (advertised == 0) 1 else advertised;
    }

    pub fn dataBreakpointCandidateCommitChoiceAt(self: *const Session, index: usize) ?DataBreakpointCommitChoice {
        const candidate = self.data_breakpoint_candidate orelse return null;
        if (candidate.data_id == null) return null;
        if (candidate.access_types.count() == 0) return if (index == 0) .adapter_default else null;
        var current: usize = 0;
        if (candidate.access_types.read) {
            if (current == index) return .read;
            current += 1;
        }
        if (candidate.access_types.write) {
            if (current == index) return .write;
            current += 1;
        }
        if (candidate.access_types.read_write and current == index) return .read_write;
        return null;
    }

    pub fn addPersistedDataBreakpoint(
        self: *Session,
        raw_adapter_key: []const u8,
        raw_data_id: []const u8,
        raw_description: []const u8,
        access_type: ?debug_data.AccessType,
    ) !bool {
        const adapter_key = try debug_data.validate(.variable_name, raw_adapter_key);
        const data_id = try debug_data.validate(.data_id, raw_data_id);
        const description = try debug_data.validate(.description, raw_description);
        if (self.findDataBreakpoint(adapter_key, data_id) != null) return false;
        if (self.data_breakpoints.items.len >= debug_data.max_breakpoints) return error.TooManyDataBreakpoints;

        const owned_adapter_key = try self.allocator.dupe(u8, adapter_key);
        errdefer self.allocator.free(owned_adapter_key);
        const owned_id = try self.allocator.dupe(u8, data_id);
        errdefer self.allocator.free(owned_id);
        const owned_description = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(owned_description);
        try self.data_breakpoints.append(.{
            .adapter_key = owned_adapter_key,
            .data_id = owned_id,
            .description = owned_description,
            .access_type = access_type,
            .can_persist = true,
        });
        return true;
    }

    pub fn commitDataBreakpoint(
        self: *Session,
        access_type: ?debug_data.AccessType,
    ) !DataBreakpointUpdateResult {
        const candidate = if (self.data_breakpoint_candidate) |*value| value else return error.NoDataBreakpointCandidate;
        if (!self.dataBreakpointsSupported()) return error.DataBreakpointsUnsupported;
        if (self.state != .paused or candidate.pause_generation != self.pause_generation) return error.StaleDataBreakpointCandidate;
        const active_adapter_key = self.active_adapter_key orelse return error.StaleDataBreakpointCandidate;
        if (!std.mem.eql(u8, candidate.adapter_key, active_adapter_key)) return error.StaleDataBreakpointCandidate;
        const data_id = candidate.data_id orelse return error.DataBreakpointUnavailable;
        if (candidate.access_types.count() == 0) {
            if (access_type != null) return error.DataBreakpointAccessNotAdvertised;
        } else {
            const selected = access_type orelse return error.DataBreakpointAccessRequired;
            if (!candidate.access_types.allows(selected)) return error.DataBreakpointAccessNotAdvertised;
        }

        if (self.findDataBreakpointMut(candidate.adapter_key, data_id)) |existing| {
            if (existing.access_type == access_type and
                existing.can_persist == candidate.can_persist and
                std.mem.eql(u8, existing.description, candidate.description))
            {
                self.clearDataBreakpointCandidate();
                return .unchanged;
            }
            const description = try self.allocator.dupe(u8, candidate.description);
            self.allocator.free(existing.description);
            existing.description = description;
            existing.access_type = access_type;
            existing.can_persist = existing.can_persist or candidate.can_persist;
            existing.clearRuntime(self.allocator);
            self.clearDataBreakpointCandidate();
            return .updated;
        }

        if (self.data_breakpoints.items.len >= debug_data.max_breakpoints) return error.TooManyDataBreakpoints;
        const owned_adapter_key = try self.allocator.dupe(u8, candidate.adapter_key);
        errdefer self.allocator.free(owned_adapter_key);
        const owned_id = try self.allocator.dupe(u8, data_id);
        errdefer self.allocator.free(owned_id);
        const owned_description = try self.allocator.dupe(u8, candidate.description);
        errdefer self.allocator.free(owned_description);
        try self.data_breakpoints.append(.{
            .adapter_key = owned_adapter_key,
            .data_id = owned_id,
            .description = owned_description,
            .access_type = access_type,
            .can_persist = candidate.can_persist,
        });
        self.clearDataBreakpointCandidate();
        return .added;
    }

    pub fn cancelDataBreakpointCandidate(self: *Session) bool {
        if (self.data_breakpoint_candidate == null) return false;
        self.clearDataBreakpointCandidate();
        return true;
    }

    pub fn removeDataBreakpointAt(self: *Session, index: usize) bool {
        if (index >= self.data_breakpoints.items.len) return false;
        var breakpoint = self.data_breakpoints.orderedRemove(index);
        breakpoint.deinit(self.allocator);
        return true;
    }

    pub fn clearDataBreakpoints(self: *Session) bool {
        if (self.data_breakpoints.items.len == 0) return false;
        for (self.data_breakpoints.items) |*breakpoint| breakpoint.deinit(self.allocator);
        self.data_breakpoints.clearRetainingCapacity();
        return true;
    }

    pub fn memoryReadCapability(self: *const Session) LowLevelCapability {
        if (!self.capabilitiesKnown()) return .unknown;
        return if (self.capabilities.supports_read_memory_request) .supported else .unsupported;
    }

    pub fn disassemblyCapability(self: *const Session) LowLevelCapability {
        if (!self.capabilitiesKnown()) return .unknown;
        return if (self.capabilities.supports_disassemble_request) .supported else .unsupported;
    }

    pub fn instructionBreakpointCapability(self: *const Session) LowLevelCapability {
        if (!self.capabilitiesKnown()) return .unknown;
        return if (self.capabilities.supports_instruction_breakpoints) .supported else .unsupported;
    }

    pub fn stackFrameInstructionReferenceCount(self: *const Session) usize {
        var count: usize = 0;
        for (self.stack_frames.items) |frame| if (frame.instruction_pointer_reference != null) {
            count += 1;
        };
        return count;
    }

    pub fn stackFrameInstructionReferenceIndexAt(self: *const Session, display_index: usize) ?usize {
        var current: usize = 0;
        for (self.stack_frames.items, 0..) |frame, index| {
            if (frame.instruction_pointer_reference == null) continue;
            if (current == display_index) return index;
            current += 1;
        }
        return null;
    }

    pub fn variableMemoryReferenceCount(self: *const Session) usize {
        var count: usize = 0;
        for (self.variables.items) |variable| if (variable.memory_reference != null) {
            count += 1;
        };
        return count;
    }

    pub fn variableMemoryReferenceIndexAt(self: *const Session, display_index: usize) ?usize {
        var current: usize = 0;
        for (self.variables.items, 0..) |variable, index| {
            if (variable.memory_reference == null) continue;
            if (current == display_index) return index;
            current += 1;
        }
        return null;
    }

    pub fn toggleInstructionBreakpointAt(self: *Session, instruction_index: usize) !ToggleResult {
        if (!self.capabilities.supports_instruction_breakpoints) return error.InstructionBreakpointsUnsupported;
        if (self.state != .paused) return error.DebuggeeNotPaused;
        if (instruction_index >= self.disassembled_instructions.items.len) return error.UnknownDisassembledInstruction;
        const instruction = self.disassembled_instructions.items[instruction_index];
        if (instruction.pause_generation != self.pause_generation) return error.StaleDisassembly;
        const adapter_key = self.active_adapter_key orelse return error.DebugAdapterIdentityUnavailable;

        for (self.instruction_breakpoints.items, 0..) |breakpoint, index| {
            if (!std.mem.eql(u8, breakpoint.adapter_key, adapter_key) or
                !std.mem.eql(u8, breakpoint.instruction_reference, instruction.address)) continue;
            var removed = self.instruction_breakpoints.orderedRemove(index);
            removed.deinit(self.allocator);
            return .removed;
        }
        if (self.instruction_breakpoints.items.len >= debug_memory.max_instruction_breakpoints) return error.TooManyInstructionBreakpoints;

        const owned_adapter_key = try self.allocator.dupe(u8, adapter_key);
        errdefer self.allocator.free(owned_adapter_key);
        const owned_reference = try self.allocator.dupe(u8, instruction.address);
        errdefer self.allocator.free(owned_reference);
        const label_source = instruction.symbol orelse instruction.instruction;
        const owned_label = try self.allocator.dupe(u8, label_source);
        errdefer self.allocator.free(owned_label);
        try self.instruction_breakpoints.append(.{
            .adapter_key = owned_adapter_key,
            .instruction_reference = owned_reference,
            .label = owned_label,
        });
        return .added;
    }

    pub fn removeInstructionBreakpointAt(self: *Session, index: usize) bool {
        if (index >= self.instruction_breakpoints.items.len) return false;
        var removed = self.instruction_breakpoints.orderedRemove(index);
        removed.deinit(self.allocator);
        return true;
    }

    pub fn clearInstructionBreakpoints(self: *Session) bool {
        if (self.instruction_breakpoints.items.len == 0) return false;
        for (self.instruction_breakpoints.items) |*breakpoint| breakpoint.deinit(self.allocator);
        self.instruction_breakpoints.clearRetainingCapacity();
        return true;
    }

    pub fn instructionBreakpointSet(self: *const Session, instruction_reference: []const u8) bool {
        const adapter_key = self.active_adapter_key orelse return false;
        for (self.instruction_breakpoints.items) |breakpoint| {
            if (std.mem.eql(u8, breakpoint.adapter_key, adapter_key) and
                std.mem.eql(u8, breakpoint.instruction_reference, instruction_reference)) return true;
        }
        return false;
    }

    pub fn withheldInstructionBreakpointCount(self: *const Session) usize {
        if (!self.capabilitiesKnown()) return 0;
        if (!self.capabilities.supports_instruction_breakpoints) return self.instruction_breakpoints.items.len;
        const adapter_key = self.active_adapter_key orelse return self.instruction_breakpoints.items.len;
        var count: usize = 0;
        for (self.instruction_breakpoints.items) |breakpoint| {
            if (!std.mem.eql(u8, breakpoint.adapter_key, adapter_key)) count += 1;
        }
        return count;
    }

    pub fn addConfiguredExceptionFilter(self: *Session, raw_filter_id: []const u8) !bool {
        const filter_id = try debug_exception.validate(.filter_id, raw_filter_id);
        if (self.isExceptionFilterSelected(filter_id)) return false;
        if (self.selected_exception_filter_ids.items.len >= debug_exception.max_filters) return error.TooManyExceptionFilters;
        try self.selected_exception_filter_ids.append(try self.allocator.dupe(u8, filter_id));
        return true;
    }

    pub fn toggleExceptionFilter(self: *Session, raw_filter_id: []const u8) !ToggleResult {
        const filter_id = try debug_exception.validate(.filter_id, raw_filter_id);
        for (self.selected_exception_filter_ids.items, 0..) |selected, index| {
            if (!std.mem.eql(u8, selected, filter_id)) continue;
            self.allocator.free(self.selected_exception_filter_ids.orderedRemove(index));
            return .removed;
        }
        if (self.findExceptionFilter(filter_id) == null) return error.ExceptionFilterNotAdvertised;
        if (self.selected_exception_filter_ids.items.len >= debug_exception.max_filters) return error.TooManyExceptionFilters;
        try self.selected_exception_filter_ids.append(try self.allocator.dupe(u8, filter_id));
        return .added;
    }

    pub fn clearSelectedExceptionFilters(self: *Session) bool {
        if (self.selected_exception_filter_ids.items.len == 0) return false;
        for (self.selected_exception_filter_ids.items) |filter_id| self.allocator.free(filter_id);
        self.selected_exception_filter_ids.clearRetainingCapacity();
        return true;
    }

    pub fn isExceptionFilterSelected(self: *const Session, filter_id: []const u8) bool {
        for (self.selected_exception_filter_ids.items) |selected| {
            if (std.mem.eql(u8, selected, filter_id)) return true;
        }
        return false;
    }

    pub fn hasAdvertisedExceptionFilters(self: *const Session) bool {
        return self.exception_filters.items.len > 0;
    }

    pub fn selectedExceptionFilterCount(self: *const Session) usize {
        return self.selected_exception_filter_ids.items.len;
    }

    pub fn selectedAdvertisedExceptionFilterCount(self: *const Session) usize {
        var count: usize = 0;
        for (self.exception_filters.items) |filter| {
            if (self.isExceptionFilterSelected(filter.id)) count += 1;
        }
        return count;
    }

    pub fn withheldExceptionFilterCount(self: *const Session) usize {
        if (!self.capabilitiesKnown()) return 0;
        var count: usize = 0;
        for (self.selected_exception_filter_ids.items) |filter_id| {
            if (self.findExceptionFilter(filter_id) == null) count += 1;
        }
        return count;
    }

    pub fn exceptionFilterDisplayCount(self: *const Session) usize {
        return if (self.exception_filters.items.len > 0)
            self.exception_filters.items.len
        else
            self.selected_exception_filter_ids.items.len;
    }

    pub fn exceptionFilterDisplayAt(self: *const Session, index: usize) ?ExceptionFilterView {
        if (self.exception_filters.items.len > 0) {
            if (index >= self.exception_filters.items.len) return null;
            const filter = self.exception_filters.items[index];
            return .{
                .id = filter.id,
                .label = filter.label,
                .description = filter.description,
                .default_enabled = filter.default_enabled,
                .supports_condition = filter.supports_condition,
                .selected = self.isExceptionFilterSelected(filter.id),
                .advertised = true,
                .verified = filter.verified,
                .message = filter.message,
            };
        }
        if (index >= self.selected_exception_filter_ids.items.len) return null;
        const filter_id = self.selected_exception_filter_ids.items[index];
        return .{
            .id = filter_id,
            .label = filter_id,
            .description = null,
            .default_enabled = false,
            .supports_condition = false,
            .selected = true,
            .advertised = false,
            .verified = null,
            .message = null,
        };
    }

    pub fn makeInitialize(self: *Session, adapter_id: []const u8) !Outbound {
        const adapter_key = try debug_data.validate(.variable_name, adapter_id);
        const owned_adapter_key = try self.allocator.dupe(u8, adapter_key);
        errdefer self.allocator.free(owned_adapter_key);
        const seq = self.takeSeq();
        const payload = try protocol.makeInitializeRequest(self.allocator, seq, adapter_id);
        if (self.active_adapter_key) |previous| self.allocator.free(previous);
        self.active_adapter_key = owned_adapter_key;
        self.state = .initializing;
        return self.wrapRequest(payload, seq, .initialize, null) catch |err| {
            self.active_adapter_key = null;
            return err;
        };
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

    pub fn makeSetFunctionBreakpoints(self: *Session) !Outbound {
        if (!self.functionBreakpointsSupported()) return error.FunctionBreakpointsUnsupported;
        var items = std.array_list.Managed(protocol.FunctionBreakpoint).init(self.allocator);
        defer items.deinit();
        for (self.function_breakpoints.items) |*breakpoint| {
            breakpoint.clearRuntime(self.allocator);
            try items.append(.{ .name = breakpoint.name });
        }
        const seq = self.takeSeq();
        const payload = try protocol.makeSetFunctionBreakpointsRequest(self.allocator, seq, items.items);
        return self.wrapFunctionRequest(payload, seq, items.items);
    }

    pub fn makeDataBreakpointInfo(self: *Session, variable_index: usize) !Outbound {
        if (!self.dataBreakpointsSupported()) return error.DataBreakpointsUnsupported;
        if (self.active_adapter_key == null) return error.DebugAdapterIdentityUnavailable;
        if (self.state != .paused) return error.DebuggeeNotPaused;
        if (variable_index >= self.variables.items.len) return error.UnknownVariable;
        const variable = self.variables.items[variable_index];
        if (variable.pause_generation != self.pause_generation) return error.StaleVariableReference;
        if (variable.parent_variables_reference <= 0) return error.InvalidVariableReference;
        const variable_name = try debug_data.validate(.variable_name, variable.name);

        self.clearDataBreakpointCandidate();
        const seq = self.takeSeq();
        const payload = try protocol.makeDataBreakpointInfoRequest(self.allocator, seq, .{
            .variables_reference = variable.parent_variables_reference,
            .name = variable_name,
        });
        return self.wrapDataBreakpointInfoRequest(
            payload,
            seq,
            variable_name,
            variable.parent_variables_reference,
            variable.frame_id,
            variable.pause_generation,
        );
    }

    pub fn makeSetDataBreakpoints(self: *Session) !Outbound {
        if (!self.dataBreakpointsSupported()) return error.DataBreakpointsUnsupported;
        const adapter_key = self.active_adapter_key orelse return error.DebugAdapterIdentityUnavailable;
        var items = std.array_list.Managed(protocol.DataBreakpoint).init(self.allocator);
        defer items.deinit();
        for (self.data_breakpoints.items) |*breakpoint| {
            if (!std.mem.eql(u8, breakpoint.adapter_key, adapter_key)) continue;
            breakpoint.clearRuntime(self.allocator);
            try items.append(.{
                .data_id = breakpoint.data_id,
                .access_type = breakpoint.access_type,
            });
        }
        const seq = self.takeSeq();
        const payload = try protocol.makeSetDataBreakpointsRequest(self.allocator, seq, items.items);
        return self.wrapDataBreakpointRequest(payload, seq, items.items);
    }

    pub fn makeSetInstructionBreakpoints(self: *Session) !Outbound {
        if (!self.capabilities.supports_instruction_breakpoints) return error.InstructionBreakpointsUnsupported;
        const adapter_key = self.active_adapter_key orelse return error.DebugAdapterIdentityUnavailable;
        var items = std.array_list.Managed(protocol.InstructionBreakpoint).init(self.allocator);
        defer items.deinit();
        for (self.instruction_breakpoints.items) |*breakpoint| {
            if (!std.mem.eql(u8, breakpoint.adapter_key, adapter_key)) continue;
            breakpoint.clearRuntime(self.allocator);
            try items.append(.{ .instruction_reference = breakpoint.instruction_reference });
        }
        const seq = self.takeSeq();
        const payload = try protocol.makeSetInstructionBreakpointsRequest(self.allocator, seq, items.items);
        return self.wrapInstructionBreakpointRequest(payload, seq, items.items);
    }

    pub fn makeSetExceptionBreakpoints(self: *Session) !Outbound {
        var selected = std.array_list.Managed([]const u8).init(self.allocator);
        defer selected.deinit();
        for (self.exception_filters.items) |*filter| {
            filter.clearRuntime(self.allocator);
            if (self.isExceptionFilterSelected(filter.id)) try selected.append(filter.id);
        }
        const seq = self.takeSeq();
        const payload = try protocol.makeSetExceptionBreakpointsRequest(self.allocator, seq, selected.items);
        return self.wrapExceptionRequest(payload, seq, selected.items);
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
        if (self.state != .paused) return error.DebuggeeNotPaused;
        const seq = self.takeSeq();
        return self.wrapPausedRequest(try protocol.makeStackTraceRequest(self.allocator, seq, thread_id, 0, 200), seq, .stack_trace, self.pause_generation);
    }

    pub fn makeScopes(self: *Session, frame_id: i64) !Outbound {
        if (self.state != .paused) return error.DebuggeeNotPaused;
        const seq = self.takeSeq();
        return self.wrapPausedRequest(try protocol.makeScopesRequest(self.allocator, seq, frame_id), seq, .scopes, self.pause_generation);
    }

    pub fn makeVariables(self: *Session, reference: i64) !Outbound {
        const seq = self.takeSeq();
        const payload = try protocol.makeVariablesRequest(self.allocator, seq, reference, 0, 1000);
        return self.wrapVariablesRequest(payload, seq, reference, self.active_frame_id, self.pause_generation);
    }

    pub fn makeReadMemoryForVariable(self: *Session, variable_index: usize) !Outbound {
        if (!self.capabilities.supports_read_memory_request) return error.ReadMemoryUnsupported;
        if (self.state != .paused) return error.DebuggeeNotPaused;
        if (variable_index >= self.variables.items.len) return error.UnknownVariable;
        const variable = self.variables.items[variable_index];
        if (variable.pause_generation != self.pause_generation) return error.StaleVariableReference;
        const memory_reference = variable.memory_reference orelse return error.MemoryReferenceUnavailable;
        return self.makeReadMemoryReference(memory_reference, 0, debug_memory.max_memory_bytes);
    }

    pub fn makeRefreshMemory(self: *Session) !Outbound {
        if (!self.capabilities.supports_read_memory_request) return error.ReadMemoryUnsupported;
        if (self.state != .paused) return error.DebuggeeNotPaused;
        const snapshot = self.memory_snapshot orelse return error.MemorySnapshotUnavailable;
        if (snapshot.pause_generation != self.pause_generation) return error.StaleMemoryReference;
        return self.makeReadMemoryReference(snapshot.memory_reference, snapshot.offset, debug_memory.max_memory_bytes);
    }

    pub fn makeDisassembleForFrame(self: *Session, frame_index: usize) !Outbound {
        if (!self.capabilities.supports_disassemble_request) return error.DisassemblyUnsupported;
        if (self.state != .paused) return error.DebuggeeNotPaused;
        if (frame_index >= self.stack_frames.items.len) return error.UnknownStackFrame;
        const frame = self.stack_frames.items[frame_index];
        if (frame.pause_generation != self.pause_generation) return error.StaleStackFrame;
        const memory_reference = frame.instruction_pointer_reference orelse return error.InstructionReferenceUnavailable;
        const instruction_offset: i64 = -16;
        const instruction_count: usize = 64;
        const seq = self.takeSeq();
        const payload = try protocol.makeDisassembleRequest(self.allocator, seq, .{
            .memory_reference = memory_reference,
            .instruction_offset = instruction_offset,
            .instruction_count = instruction_count,
            .resolve_symbols = true,
        });
        const outbound = try self.wrapLowLevelRequest(
            payload,
            seq,
            .disassemble,
            memory_reference,
            0,
            null,
            instruction_count,
            self.pause_generation,
        );
        self.clearDisassembledInstructions();
        return outbound;
    }

    fn makeReadMemoryReference(self: *Session, memory_reference: []const u8, offset: i64, count: usize) !Outbound {
        _ = try debug_memory.validateText(.memory_reference, memory_reference);
        _ = try debug_memory.validateByteOffset(offset);
        _ = try debug_memory.validateReadCount(count);
        const seq = self.takeSeq();
        const payload = try protocol.makeReadMemoryRequest(self.allocator, seq, .{
            .memory_reference = memory_reference,
            .offset = offset,
            .count = count,
        });
        const outbound = try self.wrapLowLevelRequest(
            payload,
            seq,
            .read_memory,
            memory_reference,
            offset,
            count,
            null,
            self.pause_generation,
        );
        self.clearMemorySnapshot();
        return outbound;
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
        const outbound = try self.wrapRequest(try protocol.makeContinueRequest(self.allocator, seq, thread_id), seq, .continue_execution, null);
        self.state = .running;
        self.invalidatePausedReferences();
        return outbound;
    }

    pub fn makePause(self: *Session, thread_id: i64) !Outbound {
        const seq = self.takeSeq();
        return self.wrapRequest(try protocol.makePauseRequest(self.allocator, seq, thread_id), seq, .pause, null);
    }

    pub fn makeNext(self: *Session, thread_id: i64) !Outbound {
        const seq = self.takeSeq();
        const outbound = try self.wrapRequest(try protocol.makeNextRequest(self.allocator, seq, thread_id), seq, .next, null);
        self.state = .running;
        self.invalidatePausedReferences();
        return outbound;
    }

    pub fn makeStepIn(self: *Session, thread_id: i64) !Outbound {
        const seq = self.takeSeq();
        const outbound = try self.wrapRequest(try protocol.makeStepInRequest(self.allocator, seq, thread_id), seq, .step_in, null);
        self.state = .running;
        self.invalidatePausedReferences();
        return outbound;
    }

    pub fn makeStepOut(self: *Session, thread_id: i64) !Outbound {
        const seq = self.takeSeq();
        const outbound = try self.wrapRequest(try protocol.makeStepOutRequest(self.allocator, seq, thread_id), seq, .step_out, null);
        self.state = .running;
        self.invalidatePausedReferences();
        return outbound;
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
                if (body) |value| try self.parseCapabilities(value);
                self.state = .initialized;
            },
            .launch => self.state = .configuring,
            .set_breakpoints => if (pending.path) |path| if (body) |value| try self.parseBreakpointsResponse(path, value),
            .set_function_breakpoints => if (pending.function_names) |function_names| if (body) |value| try self.parseFunctionBreakpointsResponse(function_names, value),
            .data_breakpoint_info => if (body) |value| try self.parseDataBreakpointInfo(pending, value),
            .set_data_breakpoints => if (pending.data_ids) |data_ids| if (body) |value| try self.parseDataBreakpointsResponse(data_ids, value),
            .set_instruction_breakpoints => if (pending.instruction_references) |references| if (body) |value| try self.parseInstructionBreakpointsResponse(references, value),
            .set_exception_breakpoints => if (pending.exception_filter_ids) |filter_ids| if (body) |value| try self.parseExceptionBreakpointsResponse(filter_ids, value),
            .configuration_done => self.state = .running,
            .disconnect => {
                self.state = .terminated;
                self.configuration_ready = false;
                self.invalidatePausedReferences();
            },
            .continue_execution, .next, .step_in, .step_out => {
                self.state = .running;
                self.invalidatePausedReferences();
            },
            .pause => {},
            .threads => if (body) |value| try self.parseThreads(value),
            .stack_trace => if (body) |value| try self.parseStackFrames(pending, value),
            .scopes => if (body) |value| try self.parseScopes(pending, value),
            .variables => if (body) |value| try self.parseVariables(pending, value),
            .evaluate => if (pending.watch_id) |watch_id| {
                if (body) |value|
                    try self.parseWatchEvaluation(watch_id, request_seq, value)
                else
                    try self.setWatchError(watch_id, request_seq, "debug adapter returned no evaluation body");
            },
            .read_memory => if (body) |value| try self.parseReadMemory(pending, value),
            .disassemble => if (body) |value| try self.parseDisassembly(pending, value),
        }
        self.clearLastError();
        return .{ .acknowledged = pending.kind };
    }

    fn ingestEvent(self: *Session, object: std.json.ObjectMap) !IngestResult {
        const event_name = stringField(object, "event") orelse return .ignored;
        const body = objectField(object, "body");
        if (std.mem.eql(u8, event_name, "initialized")) {
            self.state = .configuring;
            self.configuration_ready = true;
            return .{ .event = .initialized };
        }
        if (std.mem.eql(u8, event_name, "capabilities")) {
            if (body) |value| if (objectField(value, "capabilities")) |capabilities| try self.parseCapabilitiesUpdate(capabilities);
            return .{ .event = .capabilities };
        }
        if (std.mem.eql(u8, event_name, "stopped")) {
            self.invalidatePausedReferences();
            self.pause_generation +%= 1;
            if (self.pause_generation == 0) self.pause_generation = 1;
            self.state = .paused;
            self.active_thread_id = if (body) |value| intField(value, "threadId") else null;
            const reason = if (body) |value| stringField(value, "reason") orelse "paused" else "paused";
            try self.setStopReason(reason);
            return .{ .event = .stopped };
        }
        if (std.mem.eql(u8, event_name, "continued")) {
            self.state = .running;
            self.active_thread_id = if (body) |value| intField(value, "threadId") else self.active_thread_id;
            self.invalidatePausedReferences();
            return .{ .event = .continued };
        }
        if (std.mem.eql(u8, event_name, "terminated")) {
            self.state = .terminated;
            self.configuration_ready = false;
            self.invalidatePausedReferences();
            return .{ .event = .terminated };
        }
        if (std.mem.eql(u8, event_name, "exited")) {
            self.state = .terminated;
            self.configuration_ready = false;
            self.invalidatePausedReferences();
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
        if (std.mem.eql(u8, event_name, "memory")) {
            self.clearMemorySnapshot();
            self.clearDisassembledInstructions();
            return .{ .event = .memory };
        }
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

    fn parseCapabilities(self: *Session, body: std.json.ObjectMap) !void {
        try self.replaceExceptionFilters(body);
        self.capabilities = .{
            .supports_configuration_done_request = boolField(body, "supportsConfigurationDoneRequest", false),
            .supports_conditional_breakpoints = boolField(body, "supportsConditionalBreakpoints", false),
            .supports_hit_conditional_breakpoints = boolField(body, "supportsHitConditionalBreakpoints", false),
            .supports_function_breakpoints = boolField(body, "supportsFunctionBreakpoints", false),
            .supports_data_breakpoints = boolField(body, "supportsDataBreakpoints", false),
            .supports_read_memory_request = boolField(body, "supportsReadMemoryRequest", false),
            .supports_write_memory_request = boolField(body, "supportsWriteMemoryRequest", false),
            .supports_disassemble_request = boolField(body, "supportsDisassembleRequest", false),
            .supports_instruction_breakpoints = boolField(body, "supportsInstructionBreakpoints", false),
            .supports_log_points = boolField(body, "supportsLogPoints", false),
            .supports_terminate_request = boolField(body, "supportsTerminateRequest", false),
            .supports_restart_request = boolField(body, "supportsRestartRequest", false),
            .supports_step_back = boolField(body, "supportsStepBack", false),
            .supports_set_variable = boolField(body, "supportsSetVariable", false),
            .supports_exception_filter_options = boolField(body, "supportsExceptionFilterOptions", false),
        };
    }

    fn parseCapabilitiesUpdate(self: *Session, body: std.json.ObjectMap) !void {
        const supported_data_before = self.capabilities.supports_data_breakpoints;
        const supported_memory_before = self.capabilities.supports_read_memory_request;
        const supported_disassembly_before = self.capabilities.supports_disassemble_request;
        updateBoolField(body, "supportsConfigurationDoneRequest", &self.capabilities.supports_configuration_done_request);
        updateBoolField(body, "supportsConditionalBreakpoints", &self.capabilities.supports_conditional_breakpoints);
        updateBoolField(body, "supportsHitConditionalBreakpoints", &self.capabilities.supports_hit_conditional_breakpoints);
        updateBoolField(body, "supportsFunctionBreakpoints", &self.capabilities.supports_function_breakpoints);
        updateBoolField(body, "supportsDataBreakpoints", &self.capabilities.supports_data_breakpoints);
        updateBoolField(body, "supportsReadMemoryRequest", &self.capabilities.supports_read_memory_request);
        updateBoolField(body, "supportsWriteMemoryRequest", &self.capabilities.supports_write_memory_request);
        updateBoolField(body, "supportsDisassembleRequest", &self.capabilities.supports_disassemble_request);
        updateBoolField(body, "supportsInstructionBreakpoints", &self.capabilities.supports_instruction_breakpoints);
        updateBoolField(body, "supportsLogPoints", &self.capabilities.supports_log_points);
        updateBoolField(body, "supportsTerminateRequest", &self.capabilities.supports_terminate_request);
        updateBoolField(body, "supportsRestartRequest", &self.capabilities.supports_restart_request);
        updateBoolField(body, "supportsStepBack", &self.capabilities.supports_step_back);
        updateBoolField(body, "supportsSetVariable", &self.capabilities.supports_set_variable);
        updateBoolField(body, "supportsExceptionFilterOptions", &self.capabilities.supports_exception_filter_options);
        if (supported_data_before and !self.capabilities.supports_data_breakpoints) self.clearDataBreakpointCandidate();
        if (supported_memory_before and !self.capabilities.supports_read_memory_request) self.clearMemorySnapshot();
        if (supported_disassembly_before and !self.capabilities.supports_disassemble_request) self.clearDisassembledInstructions();
        if (body.contains("exceptionBreakpointFilters")) try self.replaceExceptionFilters(body);
    }

    fn replaceExceptionFilters(self: *Session, body: std.json.ObjectMap) !void {
        var parsed_filters = std.array_list.Managed(ExceptionFilter).init(self.allocator);
        errdefer {
            for (parsed_filters.items) |*filter| filter.deinit(self.allocator);
            parsed_filters.deinit();
        }
        var rejected: usize = 0;
        if (arrayField(body, "exceptionBreakpointFilters")) |values| {
            const limit = @min(values.items.len, debug_exception.max_filters);
            rejected += values.items.len - limit;
            for (values.items[0..limit]) |value| {
                const object = switch (value) {
                    .object => |item| item,
                    else => {
                        rejected += 1;
                        continue;
                    },
                };
                const id = stringField(object, "filter") orelse {
                    rejected += 1;
                    continue;
                };
                const label = stringField(object, "label") orelse {
                    rejected += 1;
                    continue;
                };
                const description: ?[]const u8 = if (object.get("description")) |description_value| switch (description_value) {
                    .string => |text| text,
                    else => {
                        rejected += 1;
                        continue;
                    },
                } else null;
                _ = debug_exception.validate(.filter_id, id) catch {
                    rejected += 1;
                    continue;
                };
                _ = debug_exception.validate(.label, label) catch {
                    rejected += 1;
                    continue;
                };
                if (description) |text| _ = debug_exception.validate(.description, text) catch {
                    rejected += 1;
                    continue;
                };
                var duplicate = false;
                for (parsed_filters.items) |filter| {
                    if (std.mem.eql(u8, filter.id, id)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) {
                    rejected += 1;
                    continue;
                }

                const owned_id = try self.allocator.dupe(u8, id);
                errdefer self.allocator.free(owned_id);
                const owned_label = try self.allocator.dupe(u8, label);
                errdefer self.allocator.free(owned_label);
                const owned_description = if (description) |text| try self.allocator.dupe(u8, text) else null;
                errdefer if (owned_description) |text| self.allocator.free(text);
                try parsed_filters.append(.{
                    .id = owned_id,
                    .label = owned_label,
                    .description = owned_description,
                    .default_enabled = boolField(object, "default", false),
                    .supports_condition = boolField(object, "supportsCondition", false),
                });
            }
        }

        clearExceptionFilters(self);
        std.mem.swap(@TypeOf(self.exception_filters), &self.exception_filters, &parsed_filters);
        parsed_filters.deinit();
        self.rejected_exception_filter_metadata = rejected;
    }

    fn parseBreakpointsResponse(self: *Session, path: []const u8, body: std.json.ObjectMap) !void {
        const values = arrayField(body, "breakpoints") orelse return;
        var response_index: usize = 0;
        for (self.breakpoints.items) |*breakpoint| {
            if (!breakpoint.enabled or !pathEquals(breakpoint.path, path)) continue;
            if (!self.breakpointSupported(breakpoint.*)) continue;
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

    fn parseExceptionBreakpointsResponse(self: *Session, filter_ids: [][]u8, body: std.json.ObjectMap) !void {
        const values = arrayField(body, "breakpoints") orelse return;
        for (filter_ids, 0..) |filter_id, index| {
            if (index >= values.items.len) break;
            const filter = self.findExceptionFilterMut(filter_id) orelse continue;
            const object = switch (values.items[index]) {
                .object => |item| item,
                else => continue,
            };
            filter.clearRuntime(self.allocator);
            filter.verified = boolField(object, "verified", false);
            filter.adapter_id = intField(object, "id");
            filter.message = if (stringField(object, "message")) |message|
                try dupeLimited(self.allocator, message, 4096)
            else
                null;
        }
    }

    fn parseFunctionBreakpointsResponse(self: *Session, function_names: [][]u8, body: std.json.ObjectMap) !void {
        const values = arrayField(body, "breakpoints") orelse return;
        for (function_names, 0..) |name, index| {
            if (index >= values.items.len) break;
            const breakpoint = self.findFunctionBreakpointMut(name) orelse continue;
            const object = switch (values.items[index]) {
                .object => |item| item,
                else => continue,
            };
            breakpoint.clearRuntime(self.allocator);
            breakpoint.verified = boolField(object, "verified", false);
            breakpoint.adapter_id = intField(object, "id");
            breakpoint.message = if (stringField(object, "message")) |message|
                try dupeLimited(self.allocator, message, 4096)
            else
                null;
        }
    }

    fn parseDataBreakpointInfo(self: *Session, pending: Pending, body: std.json.ObjectMap) !void {
        const generation = pending.pause_generation orelse return;
        if (self.state != .paused or generation != self.pause_generation) return;
        if (!self.dataBreakpointsSupported()) return;
        const adapter_key = self.active_adapter_key orelse return;
        const variable_name = pending.variable_name orelse return;

        const data_value = body.get("dataId") orelse {
            self.rejectDataBreakpointMetadata();
            return;
        };
        const raw_data_id: ?[]const u8 = switch (data_value) {
            .string => |value| value,
            .null => null,
            else => {
                self.rejectDataBreakpointMetadata();
                return;
            },
        };
        const raw_description = stringField(body, "description") orelse {
            self.rejectDataBreakpointMetadata();
            return;
        };
        _ = debug_data.validate(.variable_name, variable_name) catch {
            self.rejectDataBreakpointMetadata();
            return;
        };
        if (raw_data_id) |data_id| _ = debug_data.validate(.data_id, data_id) catch {
            self.rejectDataBreakpointMetadata();
            return;
        };
        _ = debug_data.validate(.description, raw_description) catch {
            self.rejectDataBreakpointMetadata();
            return;
        };

        var access_types: DataAccessSet = .{};
        if (body.get("accessTypes")) |access_value| {
            const values = switch (access_value) {
                .array => |items| items,
                else => {
                    self.rejectDataBreakpointMetadata();
                    return;
                },
            };
            if (values.items.len > 3) {
                self.rejectDataBreakpointMetadata();
                return;
            }
            for (values.items) |value| {
                const name = switch (value) {
                    .string => |text| text,
                    else => {
                        self.rejectDataBreakpointMetadata();
                        return;
                    },
                };
                const access_type = debug_data.parseAccessType(name) orelse {
                    self.rejectDataBreakpointMetadata();
                    return;
                };
                if (!access_types.insert(access_type)) {
                    self.rejectDataBreakpointMetadata();
                    return;
                }
            }
        }
        const can_persist = optionalStrictBoolField(body, "canPersist") orelse false;
        if (body.contains("canPersist") and optionalStrictBoolField(body, "canPersist") == null) {
            self.rejectDataBreakpointMetadata();
            return;
        }

        const owned_adapter_key = try self.allocator.dupe(u8, adapter_key);
        errdefer self.allocator.free(owned_adapter_key);
        const owned_data_id = if (raw_data_id) |data_id| try self.allocator.dupe(u8, data_id) else null;
        errdefer if (owned_data_id) |data_id| self.allocator.free(data_id);
        const owned_description = try self.allocator.dupe(u8, raw_description);
        errdefer self.allocator.free(owned_description);
        const owned_variable_name = try self.allocator.dupe(u8, variable_name);
        errdefer self.allocator.free(owned_variable_name);

        self.clearDataBreakpointCandidate();
        self.data_breakpoint_candidate = .{
            .adapter_key = owned_adapter_key,
            .data_id = owned_data_id,
            .description = owned_description,
            .variable_name = owned_variable_name,
            .access_types = access_types,
            .can_persist = can_persist and raw_data_id != null,
            .pause_generation = generation,
        };
    }

    fn parseDataBreakpointsResponse(self: *Session, data_ids: [][]u8, body: std.json.ObjectMap) !void {
        const adapter_key = self.active_adapter_key orelse return;
        const values = arrayField(body, "breakpoints") orelse return;
        for (data_ids, 0..) |data_id, index| {
            if (index >= values.items.len) break;
            const breakpoint = self.findDataBreakpointMut(adapter_key, data_id) orelse continue;
            const object = switch (values.items[index]) {
                .object => |item| item,
                else => continue,
            };
            breakpoint.clearRuntime(self.allocator);
            breakpoint.verified = boolField(object, "verified", false);
            breakpoint.adapter_id = intField(object, "id");
            breakpoint.message = if (stringField(object, "message")) |message| message: {
                _ = debug_data.validate(.description, message) catch {
                    self.countRejectedDataBreakpointMetadata();
                    break :message null;
                };
                break :message try self.allocator.dupe(u8, message);
            } else null;
        }
    }

    fn parseInstructionBreakpointsResponse(self: *Session, references: [][]u8, body: std.json.ObjectMap) !void {
        const adapter_key = self.active_adapter_key orelse return;
        const values = arrayField(body, "breakpoints") orelse return;
        if (values.items.len != references.len) self.countRejectedLowLevelMetadata();
        for (references, 0..) |reference, index| {
            if (index >= values.items.len) break;
            const breakpoint = self.findInstructionBreakpointMut(adapter_key, reference) orelse continue;
            const object = switch (values.items[index]) {
                .object => |item| item,
                else => {
                    self.countRejectedLowLevelMetadata();
                    continue;
                },
            };
            const verified = optionalStrictBoolField(object, "verified") orelse {
                self.countRejectedLowLevelMetadata();
                continue;
            };
            const adapter_id = if (object.contains("id")) intField(object, "id") orelse {
                self.countRejectedLowLevelMetadata();
                continue;
            } else null;
            const raw_message: ?[]const u8 = if (object.get("message")) |message_value| switch (message_value) {
                .string => |message| message,
                else => {
                    self.countRejectedLowLevelMetadata();
                    continue;
                },
            } else null;
            if (raw_message) |message| _ = debug_memory.validateText(.message, message) catch {
                self.countRejectedLowLevelMetadata();
                continue;
            };
            const owned_message = if (raw_message) |message| try self.allocator.dupe(u8, message) else null;
            errdefer if (owned_message) |message| self.allocator.free(message);

            breakpoint.clearRuntime(self.allocator);
            breakpoint.verified = verified;
            breakpoint.adapter_id = adapter_id;
            breakpoint.message = owned_message;
        }
    }

    fn parseReadMemory(self: *Session, pending: Pending, body: std.json.ObjectMap) !void {
        const generation = pending.pause_generation orelse return;
        const memory_reference = pending.memory_reference orelse return;
        const requested_count = pending.memory_count orelse return;
        const offset = pending.memory_offset orelse 0;
        if (self.state != .paused or generation != self.pause_generation) return;
        if (!self.capabilities.supports_read_memory_request) return;

        const address = stringField(body, "address") orelse {
            self.countRejectedLowLevelMetadata();
            return;
        };
        _ = debug_memory.validateText(.address, address) catch {
            self.countRejectedLowLevelMetadata();
            return;
        };
        const unreadable_bytes = if (body.contains("unreadableBytes")) usizeField(body, "unreadableBytes") orelse {
            self.countRejectedLowLevelMetadata();
            return;
        } else 0;
        if (unreadable_bytes > requested_count) {
            self.countRejectedLowLevelMetadata();
            return;
        }
        const encoded = if (body.get("data")) |value| switch (value) {
            .string => |text| text,
            else => {
                self.countRejectedLowLevelMetadata();
                return;
            },
        } else "";
        const decoded_size = debug_memory.decodedMemorySize(encoded) catch {
            self.countRejectedLowLevelMetadata();
            return;
        };
        if (decoded_size > requested_count - unreadable_bytes) {
            self.countRejectedLowLevelMetadata();
            return;
        }

        const owned_reference = try self.allocator.dupe(u8, memory_reference);
        errdefer self.allocator.free(owned_reference);
        const owned_address = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(owned_address);
        const decoded = try self.allocator.alloc(u8, decoded_size);
        errdefer self.allocator.free(decoded);
        std.base64.standard.Decoder.decode(decoded, encoded) catch {
            self.allocator.free(decoded);
            self.allocator.free(owned_address);
            self.allocator.free(owned_reference);
            self.countRejectedLowLevelMetadata();
            return;
        };

        self.clearMemorySnapshot();
        self.memory_snapshot = .{
            .memory_reference = owned_reference,
            .address = owned_address,
            .bytes = decoded,
            .offset = offset,
            .unreadable_bytes = unreadable_bytes,
            .pause_generation = generation,
        };
    }

    fn parseDisassembly(self: *Session, pending: Pending, body: std.json.ObjectMap) !void {
        const generation = pending.pause_generation orelse return;
        const requested_count = pending.instruction_count orelse return;
        if (self.state != .paused or generation != self.pause_generation) return;
        if (!self.capabilities.supports_disassemble_request) return;
        const values = arrayField(body, "instructions") orelse {
            self.countRejectedLowLevelMetadata();
            return;
        };

        var parsed = std.array_list.Managed(DisassembledInstruction).init(self.allocator);
        errdefer {
            for (parsed.items) |*instruction| instruction.deinit(self.allocator);
            parsed.deinit();
        }
        const limit = @min(values.items.len, requested_count);
        if (values.items.len != requested_count) self.countRejectedLowLevelMetadata();
        for (values.items[0..limit]) |value| {
            const object = switch (value) {
                .object => |item| item,
                else => {
                    self.countRejectedLowLevelMetadata();
                    continue;
                },
            };
            const address = stringField(object, "address") orelse {
                self.countRejectedLowLevelMetadata();
                continue;
            };
            const instruction_text = stringField(object, "instruction") orelse {
                self.countRejectedLowLevelMetadata();
                continue;
            };
            _ = debug_memory.validateText(.address, address) catch {
                self.countRejectedLowLevelMetadata();
                continue;
            };
            _ = debug_memory.validateText(.memory_reference, address) catch {
                self.countRejectedLowLevelMetadata();
                continue;
            };
            _ = debug_memory.validateText(.instruction, instruction_text) catch {
                self.countRejectedLowLevelMetadata();
                continue;
            };

            const raw_instruction_bytes: ?[]const u8 = if (object.get("instructionBytes")) |bytes_value| switch (bytes_value) {
                .string => |text| text,
                else => {
                    self.countRejectedLowLevelMetadata();
                    continue;
                },
            } else null;
            if (raw_instruction_bytes) |text| _ = debug_memory.validateText(.instruction_bytes, text) catch {
                self.countRejectedLowLevelMetadata();
                continue;
            };
            const raw_symbol: ?[]const u8 = if (object.get("symbol")) |symbol_value| switch (symbol_value) {
                .string => |text| text,
                else => {
                    self.countRejectedLowLevelMetadata();
                    continue;
                },
            } else null;
            if (raw_symbol) |text| _ = debug_memory.validateText(.symbol, text) catch {
                self.countRejectedLowLevelMetadata();
                continue;
            };
            const invalid = if (object.get("presentationHint")) |hint_value| hint: {
                const hint_text = switch (hint_value) {
                    .string => |text| text,
                    else => {
                        self.countRejectedLowLevelMetadata();
                        continue;
                    },
                };
                if (std.mem.eql(u8, hint_text, "invalid")) break :hint true;
                if (std.mem.eql(u8, hint_text, "normal")) break :hint false;
                self.countRejectedLowLevelMetadata();
                continue;
            } else false;

            var source_path: ?[]u8 = null;
            if (objectField(object, "location")) |location| {
                if (stringField(location, "path")) |path| {
                    _ = debug_memory.validateText(.source_path, path) catch {
                        self.countRejectedLowLevelMetadata();
                        source_path = null;
                        continue;
                    };
                    source_path = try self.allocator.dupe(u8, path);
                }
            }
            errdefer if (source_path) |path| self.allocator.free(path);
            const owned_address = try self.allocator.dupe(u8, address);
            errdefer self.allocator.free(owned_address);
            const owned_instruction_bytes = if (raw_instruction_bytes) |text| try self.allocator.dupe(u8, text) else null;
            errdefer if (owned_instruction_bytes) |text| self.allocator.free(text);
            const owned_instruction = try dupeNormalizedInstruction(self.allocator, instruction_text);
            errdefer self.allocator.free(owned_instruction);
            const owned_symbol = if (raw_symbol) |text| try self.allocator.dupe(u8, text) else null;
            errdefer if (owned_symbol) |text| self.allocator.free(text);
            try parsed.append(.{
                .address = owned_address,
                .instruction_bytes = owned_instruction_bytes,
                .instruction = owned_instruction,
                .symbol = owned_symbol,
                .source_path = source_path,
                .line = usizeField(object, "line"),
                .column = usizeField(object, "column"),
                .invalid = invalid,
                .pause_generation = generation,
            });
        }

        self.clearDisassembledInstructions();
        std.mem.swap(@TypeOf(self.disassembled_instructions), &self.disassembled_instructions, &parsed);
        parsed.deinit();
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

    fn parseStackFrames(self: *Session, pending: Pending, body: std.json.ObjectMap) !void {
        const generation = pending.pause_generation orelse return;
        if (self.state != .paused or generation != self.pause_generation) return;
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
            const instruction_reference = if (object.contains("instructionPointerReference")) reference_block: {
                const reference = stringField(object, "instructionPointerReference") orelse {
                    self.countRejectedLowLevelMetadata();
                    break :reference_block null;
                };
                _ = debug_memory.validateText(.memory_reference, reference) catch {
                    self.countRejectedLowLevelMetadata();
                    break :reference_block null;
                };
                break :reference_block try self.allocator.dupe(u8, reference);
            } else null;
            errdefer if (instruction_reference) |owned| self.allocator.free(owned);
            const owned_name = try dupeLimited(self.allocator, name, 4096);
            errdefer self.allocator.free(owned_name);
            try self.stack_frames.append(.{
                .id = id,
                .name = owned_name,
                .path = path,
                .line = usizeField(object, "line") orelse 1,
                .column = usizeField(object, "column") orelse 1,
                .instruction_pointer_reference = instruction_reference,
                .pause_generation = generation,
            });
        }
        self.active_frame_id = if (self.stack_frames.items.len > 0) self.stack_frames.items[0].id else null;
    }

    fn parseScopes(self: *Session, pending: Pending, body: std.json.ObjectMap) !void {
        const generation = pending.pause_generation orelse return;
        if (self.state != .paused or generation != self.pause_generation) return;
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

    fn parseVariables(self: *Session, pending: Pending, body: std.json.ObjectMap) !void {
        const generation = pending.pause_generation orelse return;
        const parent_reference = pending.variables_reference orelse return;
        if (self.state != .paused or generation != self.pause_generation) return;
        clearVariables(self);
        const values = arrayField(body, "variables") orelse return;
        for (values.items[0..@min(values.items.len, max_collection_items)]) |value| {
            const object = switch (value) {
                .object => |object| object,
                else => continue,
            };
            const name = stringField(object, "name") orelse continue;
            const display_value = stringField(object, "value") orelse "";
            const owned_name = try dupeLimited(self.allocator, name, 4096);
            errdefer self.allocator.free(owned_name);
            const owned_value = try dupeLimited(self.allocator, display_value, max_event_text_bytes);
            errdefer self.allocator.free(owned_value);
            const owned_type = if (stringField(object, "type")) |type_name| try dupeLimited(self.allocator, type_name, 4096) else null;
            errdefer if (owned_type) |type_value| self.allocator.free(type_value);
            const owned_evaluate_name = if (stringField(object, "evaluateName")) |evaluate_name| try dupeLimited(self.allocator, evaluate_name, 4096) else null;
            errdefer if (owned_evaluate_name) |evaluate_value| self.allocator.free(evaluate_value);
            const owned_memory_reference = if (object.contains("memoryReference")) reference_block: {
                const reference = stringField(object, "memoryReference") orelse {
                    self.countRejectedLowLevelMetadata();
                    break :reference_block null;
                };
                _ = debug_memory.validateText(.memory_reference, reference) catch {
                    self.countRejectedLowLevelMetadata();
                    break :reference_block null;
                };
                break :reference_block try self.allocator.dupe(u8, reference);
            } else null;
            errdefer if (owned_memory_reference) |reference_value| self.allocator.free(reference_value);
            try self.variables.append(.{
                .name = owned_name,
                .value = owned_value,
                .type_name = owned_type,
                .evaluate_name = owned_evaluate_name,
                .variables_reference = intField(object, "variablesReference") orelse 0,
                .named_variables = usizeField(object, "namedVariables"),
                .indexed_variables = usizeField(object, "indexedVariables"),
                .memory_reference = owned_memory_reference,
                .parent_variables_reference = parent_reference,
                .frame_id = pending.frame_id,
                .pause_generation = generation,
            });
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

    fn findExceptionFilter(self: *const Session, filter_id: []const u8) ?*const ExceptionFilter {
        for (self.exception_filters.items) |*filter| {
            if (std.mem.eql(u8, filter.id, filter_id)) return filter;
        }
        return null;
    }

    fn findFunctionBreakpoint(self: *const Session, name: []const u8) ?*const FunctionBreakpoint {
        for (self.function_breakpoints.items) |*breakpoint| {
            if (std.mem.eql(u8, breakpoint.name, name)) return breakpoint;
        }
        return null;
    }

    fn findFunctionBreakpointMut(self: *Session, name: []const u8) ?*FunctionBreakpoint {
        for (self.function_breakpoints.items) |*breakpoint| {
            if (std.mem.eql(u8, breakpoint.name, name)) return breakpoint;
        }
        return null;
    }

    fn findDataBreakpoint(self: *const Session, adapter_key: []const u8, data_id: []const u8) ?*const DataBreakpoint {
        for (self.data_breakpoints.items) |*breakpoint| {
            if (std.mem.eql(u8, breakpoint.adapter_key, adapter_key) and std.mem.eql(u8, breakpoint.data_id, data_id)) return breakpoint;
        }
        return null;
    }

    fn findDataBreakpointMut(self: *Session, adapter_key: []const u8, data_id: []const u8) ?*DataBreakpoint {
        for (self.data_breakpoints.items) |*breakpoint| {
            if (std.mem.eql(u8, breakpoint.adapter_key, adapter_key) and std.mem.eql(u8, breakpoint.data_id, data_id)) return breakpoint;
        }
        return null;
    }

    fn findInstructionBreakpointMut(self: *Session, adapter_key: []const u8, instruction_reference: []const u8) ?*InstructionBreakpoint {
        for (self.instruction_breakpoints.items) |*breakpoint| {
            if (std.mem.eql(u8, breakpoint.adapter_key, adapter_key) and
                std.mem.eql(u8, breakpoint.instruction_reference, instruction_reference)) return breakpoint;
        }
        return null;
    }

    fn findExceptionFilterMut(self: *Session, filter_id: []const u8) ?*ExceptionFilter {
        for (self.exception_filters.items) |*filter| {
            if (std.mem.eql(u8, filter.id, filter_id)) return filter;
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

    fn wrapPausedRequest(self: *Session, payload: []u8, seq: i64, kind: RequestKind, pause_generation: u64) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        try self.pending.append(.{
            .seq = seq,
            .kind = kind,
            .pause_generation = pause_generation,
        });
        return .{ .allocator = self.allocator, .seq = seq, .kind = kind, .payload = payload, .framed = framed };
    }

    fn wrapWatchRequest(self: *Session, payload: []u8, seq: i64, watch_id: u64) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        try self.pending.append(.{ .seq = seq, .kind = .evaluate, .watch_id = watch_id });
        return .{ .allocator = self.allocator, .seq = seq, .kind = .evaluate, .payload = payload, .framed = framed };
    }

    fn wrapVariablesRequest(
        self: *Session,
        payload: []u8,
        seq: i64,
        variables_reference: i64,
        frame_id: ?i64,
        pause_generation: u64,
    ) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        try self.pending.append(.{
            .seq = seq,
            .kind = .variables,
            .variables_reference = variables_reference,
            .frame_id = frame_id,
            .pause_generation = pause_generation,
        });
        return .{ .allocator = self.allocator, .seq = seq, .kind = .variables, .payload = payload, .framed = framed };
    }

    fn wrapDataBreakpointInfoRequest(
        self: *Session,
        payload: []u8,
        seq: i64,
        variable_name: []const u8,
        variables_reference: i64,
        frame_id: ?i64,
        pause_generation: u64,
    ) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        const owned_name = try self.allocator.dupe(u8, variable_name);
        errdefer self.allocator.free(owned_name);
        try self.pending.append(.{
            .seq = seq,
            .kind = .data_breakpoint_info,
            .variable_name = owned_name,
            .variables_reference = variables_reference,
            .frame_id = frame_id,
            .pause_generation = pause_generation,
        });
        return .{
            .allocator = self.allocator,
            .seq = seq,
            .kind = .data_breakpoint_info,
            .payload = payload,
            .framed = framed,
        };
    }

    fn wrapDataBreakpointRequest(
        self: *Session,
        payload: []u8,
        seq: i64,
        breakpoints: []const protocol.DataBreakpoint,
    ) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        const owned_ids = try self.allocator.alloc([]u8, breakpoints.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_ids[0..initialized]) |data_id| self.allocator.free(data_id);
            self.allocator.free(owned_ids);
        }
        for (breakpoints) |breakpoint| {
            owned_ids[initialized] = try self.allocator.dupe(u8, breakpoint.data_id);
            initialized += 1;
        }
        try self.pending.append(.{
            .seq = seq,
            .kind = .set_data_breakpoints,
            .data_ids = owned_ids,
        });
        return .{
            .allocator = self.allocator,
            .seq = seq,
            .kind = .set_data_breakpoints,
            .payload = payload,
            .framed = framed,
        };
    }

    fn wrapInstructionBreakpointRequest(
        self: *Session,
        payload: []u8,
        seq: i64,
        breakpoints: []const protocol.InstructionBreakpoint,
    ) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        const owned_references = try self.allocator.alloc([]u8, breakpoints.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_references[0..initialized]) |reference| self.allocator.free(reference);
            self.allocator.free(owned_references);
        }
        for (breakpoints) |breakpoint| {
            owned_references[initialized] = try self.allocator.dupe(u8, breakpoint.instruction_reference);
            initialized += 1;
        }
        try self.pending.append(.{
            .seq = seq,
            .kind = .set_instruction_breakpoints,
            .instruction_references = owned_references,
        });
        return .{
            .allocator = self.allocator,
            .seq = seq,
            .kind = .set_instruction_breakpoints,
            .payload = payload,
            .framed = framed,
        };
    }

    fn wrapLowLevelRequest(
        self: *Session,
        payload: []u8,
        seq: i64,
        kind: RequestKind,
        memory_reference: []const u8,
        memory_offset: i64,
        memory_count: ?usize,
        instruction_count: ?usize,
        pause_generation: u64,
    ) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        const owned_reference = try self.allocator.dupe(u8, memory_reference);
        errdefer self.allocator.free(owned_reference);
        try self.pending.append(.{
            .seq = seq,
            .kind = kind,
            .memory_reference = owned_reference,
            .memory_offset = memory_offset,
            .memory_count = memory_count,
            .instruction_count = instruction_count,
            .pause_generation = pause_generation,
        });
        return .{ .allocator = self.allocator, .seq = seq, .kind = kind, .payload = payload, .framed = framed };
    }

    fn wrapFunctionRequest(self: *Session, payload: []u8, seq: i64, breakpoints: []const protocol.FunctionBreakpoint) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        const owned_names = try self.allocator.alloc([]u8, breakpoints.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_names[0..initialized]) |name| self.allocator.free(name);
            self.allocator.free(owned_names);
        }
        for (breakpoints) |breakpoint| {
            owned_names[initialized] = try self.allocator.dupe(u8, breakpoint.name);
            initialized += 1;
        }
        try self.pending.append(.{
            .seq = seq,
            .kind = .set_function_breakpoints,
            .function_names = owned_names,
        });
        return .{
            .allocator = self.allocator,
            .seq = seq,
            .kind = .set_function_breakpoints,
            .payload = payload,
            .framed = framed,
        };
    }

    fn wrapExceptionRequest(self: *Session, payload: []u8, seq: i64, filter_ids: []const []const u8) !Outbound {
        errdefer self.allocator.free(payload);
        const framed = try protocol.makeFramed(self.allocator, payload);
        errdefer self.allocator.free(framed);
        const owned_filter_ids = try self.allocator.alloc([]u8, filter_ids.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_filter_ids[0..initialized]) |filter_id| self.allocator.free(filter_id);
            self.allocator.free(owned_filter_ids);
        }
        for (filter_ids) |filter_id| {
            owned_filter_ids[initialized] = try self.allocator.dupe(u8, filter_id);
            initialized += 1;
        }
        try self.pending.append(.{
            .seq = seq,
            .kind = .set_exception_breakpoints,
            .exception_filter_ids = owned_filter_ids,
        });
        return .{
            .allocator = self.allocator,
            .seq = seq,
            .kind = .set_exception_breakpoints,
            .payload = payload,
            .framed = framed,
        };
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
        self.clearMemorySnapshot();
        self.clearDisassembledInstructions();
        self.clearDataBreakpointCandidate();
        for (self.watches.items) |*watch| watch.clearRuntime(self.allocator);
        self.active_thread_id = null;
        self.active_frame_id = null;
        if (self.stop_reason) |value| self.allocator.free(value);
        if (self.last_output) |value| self.allocator.free(value);
        if (self.last_output_category) |value| self.allocator.free(value);
        if (self.last_error) |value| self.allocator.free(value);
        if (self.last_reverse_command) |value| self.allocator.free(value);
        if (self.active_adapter_key) |value| self.allocator.free(value);
        self.stop_reason = null;
        self.last_output = null;
        self.last_output_category = null;
        self.last_error = null;
        self.last_reverse_command = null;
        self.active_adapter_key = null;
    }

    fn clearDataBreakpointCandidate(self: *Session) void {
        if (self.data_breakpoint_candidate) |*candidate| candidate.deinit(self.allocator);
        self.data_breakpoint_candidate = null;
    }

    fn clearMemorySnapshot(self: *Session) void {
        if (self.memory_snapshot) |*snapshot| snapshot.deinit(self.allocator);
        self.memory_snapshot = null;
    }

    fn clearDisassembledInstructions(self: *Session) void {
        for (self.disassembled_instructions.items) |*instruction| instruction.deinit(self.allocator);
        self.disassembled_instructions.clearRetainingCapacity();
    }

    fn invalidatePausedReferences(self: *Session) void {
        clearStackFrames(self);
        clearScopes(self);
        clearVariables(self);
        self.clearMemorySnapshot();
        self.clearDisassembledInstructions();
        self.clearDataBreakpointCandidate();
        for (self.watches.items) |*watch| watch.clearRuntime(self.allocator);
    }

    fn rejectDataBreakpointMetadata(self: *Session) void {
        self.clearDataBreakpointCandidate();
        self.countRejectedDataBreakpointMetadata();
    }

    fn countRejectedDataBreakpointMetadata(self: *Session) void {
        if (self.rejected_data_breakpoint_metadata < std.math.maxInt(usize)) {
            self.rejected_data_breakpoint_metadata += 1;
        }
    }

    fn countRejectedLowLevelMetadata(self: *Session) void {
        if (self.rejected_low_level_metadata < std.math.maxInt(usize)) {
            self.rejected_low_level_metadata += 1;
        }
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

fn clearExceptionFilters(self: *Session) void {
    for (self.exception_filters.items) |*filter| filter.deinit(self.allocator);
    self.exception_filters.clearRetainingCapacity();
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

fn optionalStrictBoolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn updateBoolField(object: std.json.ObjectMap, name: []const u8, destination: *bool) void {
    const value = object.get(name) orelse return;
    switch (value) {
        .bool => |flag| destination.* = flag,
        else => {},
    }
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

fn dupeNormalizedInstruction(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    _ = try debug_memory.validateText(.instruction, value);
    const owned = try allocator.dupe(u8, value);
    for (owned) |*byte| if (byte.* == '\t') {
        byte.* = ' ';
    };
    return owned;
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
        \\{"seq":1,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{"supportsConfigurationDoneRequest":true,"supportsConditionalBreakpoints":true,"supportsFunctionBreakpoints":true}}
    );
    try std.testing.expectEqual(RequestKind.initialize, result.acknowledged);
    try std.testing.expectEqual(DebugState.initialized, session.state);
    try std.testing.expect(session.capabilities.supports_configuration_done_request);
    try std.testing.expect(session.capabilities.supports_conditional_breakpoints);
    try std.testing.expect(session.functionBreakpointsSupported());
    try std.testing.expect(!session.acceptsBreakpointConfiguration());
    const initialized = try session.ingestPayload(
        \\{"seq":2,"type":"event","event":"initialized"}
    );
    try std.testing.expectEqual(EventKind.initialized, initialized.event);
    try std.testing.expect(session.acceptsBreakpointConfiguration());
}

test "DAP session bounds advertises selects and verifies exception filters" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    var initialize = try session.makeInitialize("lldb");
    defer initialize.deinit();
    _ = try session.ingestPayload(
        \\{"seq":1,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{"exceptionBreakpointFilters":[{"filter":"all","label":"All exceptions","default":true},{"filter":"uncaught","label":"Uncaught","description":"Only uncaught exceptions"},{"filter":"all","label":"Duplicate"},{"filter":"hidden","label":"Bad\nlabel"}]}}
    );
    try std.testing.expectEqual(@as(usize, 2), session.exception_filters.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.rejected_exception_filter_metadata);
    try std.testing.expect(session.exception_filters.items[0].default_enabled);
    try std.testing.expectEqual(@as(usize, 0), session.selectedExceptionFilterCount());

    try std.testing.expectEqual(ToggleResult.added, try session.toggleExceptionFilter("all"));
    try std.testing.expectError(error.ExceptionFilterNotAdvertised, session.toggleExceptionFilter("future"));
    try std.testing.expect(try session.addConfiguredExceptionFilter("stale"));
    try std.testing.expectEqual(@as(usize, 1), session.withheldExceptionFilterCount());

    var outbound = try session.makeSetExceptionBreakpoints();
    defer outbound.deinit();
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "\"filters\":[\"all\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "stale") == null);
    _ = try session.ingestPayload(
        \\{"seq":2,"type":"response","request_seq":2,"success":true,"command":"setExceptionBreakpoints","body":{"breakpoints":[{"id":41,"verified":true}]}}
    );
    try std.testing.expectEqual(@as(?bool, true), session.exception_filters.items[0].verified);
    try std.testing.expectEqual(@as(?i64, 41), session.exception_filters.items[0].adapter_id);

    session.reset();
    try std.testing.expectEqual(@as(usize, 0), session.exception_filters.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.selectedExceptionFilterCount());
}

test "DAP session validates persists and aligns delayed function breakpoint responses" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    try std.testing.expectEqual(FunctionBreakpointCapability.unknown, session.functionBreakpointCapability());

    try std.testing.expect(try session.addFunctionBreakpoint(" std::vector<int>::push_back "));
    try std.testing.expect(try session.addFunctionBreakpoint("pkg.worker.run"));
    try std.testing.expect(!try session.addFunctionBreakpoint("pkg.worker.run"));
    try std.testing.expectError(error.UnsafeFunctionSelector, session.addFunctionBreakpoint("pkg.*"));
    try std.testing.expectEqual(@as(usize, 0), session.unsupportedFunctionBreakpointCount());

    session.state = .initialized;
    session.capabilities.supports_function_breakpoints = true;
    try std.testing.expectEqual(FunctionBreakpointCapability.supported, session.functionBreakpointCapability());
    var outbound = try session.makeSetFunctionBreakpoints();
    defer outbound.deinit();
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "std::vector<int>::push_back") != null);
    try std.testing.expect(std.mem.indexOf(u8, outbound.payload, "pkg.worker.run") != null);

    try std.testing.expect(session.removeFunctionBreakpointAt(0));
    try std.testing.expect(try session.addFunctionBreakpoint("crate::worker::latest"));
    const result = try session.ingestPayload(
        \\{"seq":2,"type":"response","request_seq":1,"success":true,"command":"setFunctionBreakpoints","body":{"breakpoints":[{"id":10,"verified":true},{"id":20,"verified":false,"message":"symbol not loaded"}]}}
    );
    try std.testing.expectEqual(RequestKind.set_function_breakpoints, result.acknowledged);
    try std.testing.expectEqualStrings("pkg.worker.run", session.function_breakpoints.items[0].name);
    try std.testing.expectEqual(@as(?bool, false), session.function_breakpoints.items[0].verified);
    try std.testing.expectEqual(@as(?i64, 20), session.function_breakpoints.items[0].adapter_id);
    try std.testing.expectEqualStrings("symbol not loaded", session.function_breakpoints.items[0].message.?);
    try std.testing.expect(session.function_breakpoints.items[1].verified == null);

    session.reset();
    try std.testing.expectEqual(@as(usize, 2), session.function_breakpoints.items.len);
    try std.testing.expect(session.function_breakpoints.items[0].verified == null);
    session.state = .initialized;
    try std.testing.expectEqual(FunctionBreakpointCapability.unsupported, session.functionBreakpointCapability());
    try std.testing.expectEqual(@as(usize, 2), session.unsupportedFunctionBreakpointCount());
    try std.testing.expectError(error.FunctionBreakpointsUnsupported, session.makeSetFunctionBreakpoints());
    try std.testing.expect(session.clearFunctionBreakpoints());
    try std.testing.expect(!session.clearFunctionBreakpoints());
}

test "DAP session bounds function breakpoint count" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    var name_buf: [48]u8 = undefined;
    for (0..debug_function.max_breakpoints) |index| {
        const name = try std.fmt.bufPrint(&name_buf, "pkg.worker_{d}", .{index});
        try std.testing.expect(try session.addFunctionBreakpoint(name));
    }
    try std.testing.expectError(error.TooManyFunctionBreakpoints, session.addFunctionBreakpoint("pkg.one_too_many"));
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

test "DAP session stages commits verifies and persists adapter-approved data breakpoints" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    var initialize = try session.makeInitialize("lldb");
    defer initialize.deinit();
    _ = try session.ingestPayload(
        \\{"seq":1,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{"supportsDataBreakpoints":true}}
    );
    try std.testing.expectEqual(DataBreakpointCapability.supported, session.dataBreakpointCapability());
    _ = try session.ingestPayload(
        \\{"seq":2,"type":"event","event":"stopped","body":{"reason":"breakpoint","threadId":7}}
    );
    session.active_frame_id = 91;

    var variables = try session.makeVariables(42);
    defer variables.deinit();
    _ = try session.ingestPayload(
        \\{"seq":3,"type":"response","request_seq":2,"success":true,"command":"variables","body":{"variables":[{"name":"counter","value":"3","type":"usize","variablesReference":0}]}}
    );
    try std.testing.expectEqual(@as(usize, 1), session.variables.items.len);
    try std.testing.expectEqual(@as(i64, 42), session.variables.items[0].parent_variables_reference);
    try std.testing.expectEqual(@as(?i64, 91), session.variables.items[0].frame_id);

    var info = try session.makeDataBreakpointInfo(0);
    defer info.deinit();
    try std.testing.expect(std.mem.indexOf(u8, info.payload, "\"variablesReference\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, info.payload, "\"name\":\"counter\"") != null);
    _ = try session.ingestPayload(
        \\{"seq":4,"type":"response","request_seq":3,"success":true,"command":"dataBreakpointInfo","body":{"dataId":"opaque:counter","description":"counter storage","accessTypes":["read","write","readWrite"],"canPersist":true}}
    );
    const candidate = session.data_breakpoint_candidate.?;
    try std.testing.expectEqualStrings("lldb", candidate.adapter_key);
    try std.testing.expectEqualStrings("counter", candidate.variable_name);
    try std.testing.expect(candidate.access_types.allows(.write));
    try std.testing.expect(candidate.can_persist);

    try std.testing.expectEqual(DataBreakpointUpdateResult.added, try session.commitDataBreakpoint(.write));
    try std.testing.expect(session.data_breakpoint_candidate == null);
    try std.testing.expectEqual(@as(usize, 1), session.data_breakpoints.items.len);
    try std.testing.expect(session.data_breakpoints.items[0].can_persist);

    var set = try session.makeSetDataBreakpoints();
    defer set.deinit();
    try std.testing.expect(std.mem.indexOf(u8, set.payload, "\"accessType\":\"write\"") != null);
    const result = try session.ingestPayload(
        \\{"seq":5,"type":"response","request_seq":4,"success":true,"command":"setDataBreakpoints","body":{"breakpoints":[{"id":88,"verified":true}]}}
    );
    try std.testing.expectEqual(RequestKind.set_data_breakpoints, result.acknowledged);
    try std.testing.expectEqual(@as(?bool, true), session.data_breakpoints.items[0].verified);
    try std.testing.expectEqual(@as(?i64, 88), session.data_breakpoints.items[0].adapter_id);

    session.reset();
    try std.testing.expectEqual(@as(usize, 1), session.data_breakpoints.items.len);
    try std.testing.expect(session.data_breakpoints.items[0].verified == null);

    var gdb_initialize = try session.makeInitialize("gdb");
    defer gdb_initialize.deinit();
    _ = try session.ingestPayload(
        \\{"seq":6,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{"supportsDataBreakpoints":true}}
    );
    try std.testing.expectEqual(@as(usize, 1), session.withheldDataBreakpointCount());
    var gdb_set = try session.makeSetDataBreakpoints();
    defer gdb_set.deinit();
    try std.testing.expect(std.mem.indexOf(u8, gdb_set.payload, "\"breakpoints\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, gdb_set.payload, "opaque:counter") == null);
}

test "DAP session reads bounded memory disassembles and manages session-only instruction breakpoints" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    var initialize = try session.makeInitialize("lldb");
    defer initialize.deinit();
    _ = try session.ingestPayload(
        \\{"seq":1,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{"supportsReadMemoryRequest":true,"supportsWriteMemoryRequest":true,"supportsDisassembleRequest":true,"supportsInstructionBreakpoints":true}}
    );
    try std.testing.expectEqual(LowLevelCapability.supported, session.memoryReadCapability());
    try std.testing.expect(session.capabilities.supports_write_memory_request);
    try std.testing.expectEqual(LowLevelCapability.supported, session.disassemblyCapability());
    try std.testing.expectEqual(LowLevelCapability.supported, session.instructionBreakpointCapability());

    _ = try session.ingestPayload(
        \\{"seq":2,"type":"event","event":"stopped","body":{"reason":"breakpoint","threadId":7}}
    );
    var stack = try session.makeStackTrace(7);
    defer stack.deinit();
    _ = try session.ingestPayload(
        \\{"seq":3,"type":"response","request_seq":2,"success":true,"command":"stackTrace","body":{"stackFrames":[{"id":42,"name":"main","source":{"path":"/repo/main.zig"},"line":9,"column":3,"instructionPointerReference":"opaque:ip:main"}]}}
    );
    try std.testing.expectEqual(@as(usize, 1), session.stackFrameInstructionReferenceCount());
    try std.testing.expectEqualStrings("opaque:ip:main", session.stack_frames.items[0].instruction_pointer_reference.?);

    session.active_frame_id = 42;
    var variables = try session.makeVariables(12);
    defer variables.deinit();
    _ = try session.ingestPayload(
        \\{"seq":4,"type":"response","request_seq":3,"success":true,"command":"variables","body":{"variables":[{"name":"buffer","value":"0x401000","type":"[*]u8","variablesReference":0,"memoryReference":"opaque:pointer:buffer"}]}}
    );
    try std.testing.expectEqual(@as(usize, 1), session.variableMemoryReferenceCount());
    try std.testing.expectEqualStrings("opaque:pointer:buffer", session.variables.items[0].memory_reference.?);

    var read = try session.makeReadMemoryForVariable(0);
    defer read.deinit();
    try std.testing.expect(std.mem.indexOf(u8, read.payload, "\"count\":256") != null);
    _ = try session.ingestPayload(
        \\{"seq":5,"type":"response","request_seq":4,"success":true,"command":"readMemory","body":{"address":"0x401000","unreadableBytes":0,"data":"AAECAwQFBgcICQoLDA0ODw=="}}
    );
    const snapshot = session.memory_snapshot.?;
    try std.testing.expectEqualStrings("opaque:pointer:buffer", snapshot.memory_reference);
    try std.testing.expectEqualStrings("0x401000", snapshot.address);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, snapshot.bytes);

    var disassemble = try session.makeDisassembleForFrame(0);
    defer disassemble.deinit();
    try std.testing.expect(std.mem.indexOf(u8, disassemble.payload, "\"instructionOffset\":-16") != null);
    _ = try session.ingestPayload(
        \\{"seq":6,"type":"response","request_seq":5,"success":true,"command":"disassemble","body":{"instructions":[{"address":"0x401020","instructionBytes":"48 89 d8","instruction":"mov\trax, rbx","symbol":"main+4","location":{"path":"/repo/main.zig"},"line":9,"column":3},{"address":"0x401023","instructionBytes":"c3","instruction":"ret","presentationHint":"normal"}]}}
    );
    try std.testing.expectEqual(@as(usize, 2), session.disassembled_instructions.items.len);
    try std.testing.expectEqualStrings("mov rax, rbx", session.disassembled_instructions.items[0].instruction);
    try std.testing.expectEqualStrings("main+4", session.disassembled_instructions.items[0].symbol.?);

    try std.testing.expectEqual(ToggleResult.added, try session.toggleInstructionBreakpointAt(0));
    try std.testing.expect(session.instructionBreakpointSet("0x401020"));
    var set_instruction = try session.makeSetInstructionBreakpoints();
    defer set_instruction.deinit();
    try std.testing.expect(std.mem.indexOf(u8, set_instruction.payload, "\"instructionReference\":\"0x401020\"") != null);
    _ = try session.ingestPayload(
        \\{"seq":7,"type":"response","request_seq":6,"success":true,"command":"setInstructionBreakpoints","body":{"breakpoints":[{"id":91,"verified":true}]}}
    );
    try std.testing.expectEqual(@as(?bool, true), session.instruction_breakpoints.items[0].verified);
    try std.testing.expectEqual(@as(?i64, 91), session.instruction_breakpoints.items[0].adapter_id);

    var continuation = try session.makeContinue(7);
    defer continuation.deinit();
    try std.testing.expectEqual(State.running, session.state);
    try std.testing.expect(session.memory_snapshot == null);
    try std.testing.expectEqual(@as(usize, 0), session.disassembled_instructions.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.instruction_breakpoints.items.len);
    _ = try session.ingestPayload(
        \\{"seq":8,"type":"response","request_seq":7,"success":true,"command":"continue"}
    );
    try std.testing.expect(session.memory_snapshot == null);
    try std.testing.expectEqual(@as(usize, 0), session.disassembled_instructions.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.instruction_breakpoints.items.len);
    session.reset();
    try std.testing.expectEqual(@as(usize, 0), session.instruction_breakpoints.items.len);
}

test "DAP session rejects malformed and delayed memory responses" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();

    var initialize = try session.makeInitialize("lldb");
    defer initialize.deinit();
    _ = try session.ingestPayload(
        \\{"seq":1,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{"supportsReadMemoryRequest":true}}
    );
    _ = try session.ingestPayload(
        \\{"seq":2,"type":"event","event":"stopped","body":{"reason":"pause","threadId":1}}
    );
    var variables = try session.makeVariables(4);
    defer variables.deinit();
    _ = try session.ingestPayload(
        \\{"seq":3,"type":"response","request_seq":2,"success":true,"command":"variables","body":{"variables":[{"name":"p","value":"ptr","variablesReference":0,"memoryReference":"opaque:p"}]}}
    );

    var malformed = try session.makeReadMemoryForVariable(0);
    defer malformed.deinit();
    _ = try session.ingestPayload(
        \\{"seq":4,"type":"response","request_seq":3,"success":true,"command":"readMemory","body":{"address":"0x10","data":"not base64"}}
    );
    try std.testing.expect(session.memory_snapshot == null);
    try std.testing.expectEqual(@as(usize, 1), session.rejected_low_level_metadata);

    var inconsistent = try session.makeReadMemoryForVariable(0);
    defer inconsistent.deinit();
    _ = try session.ingestPayload(
        \\{"seq":5,"type":"response","request_seq":4,"success":true,"command":"readMemory","body":{"address":"0x10","unreadableBytes":255,"data":"AQIDBA=="}}
    );
    try std.testing.expect(session.memory_snapshot == null);
    try std.testing.expectEqual(@as(usize, 2), session.rejected_low_level_metadata);

    var delayed = try session.makeReadMemoryForVariable(0);
    defer delayed.deinit();
    _ = try session.ingestPayload(
        \\{"seq":6,"type":"event","event":"continued","body":{"threadId":1}}
    );
    _ = try session.ingestPayload(
        \\{"seq":7,"type":"response","request_seq":5,"success":true,"command":"readMemory","body":{"address":"0x10","data":"AQIDBA=="}}
    );
    try std.testing.expect(session.memory_snapshot == null);
}

test "DAP memory event invalidates cached memory and disassembly" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();
    session.state = .paused;
    session.pause_generation = 3;
    session.memory_snapshot = .{
        .memory_reference = try std.testing.allocator.dupe(u8, "opaque:data"),
        .address = try std.testing.allocator.dupe(u8, "0x1000"),
        .bytes = try std.testing.allocator.dupe(u8, &.{ 1, 2, 3, 4 }),
        .offset = 0,
        .unreadable_bytes = 0,
        .pause_generation = 3,
    };
    try session.disassembled_instructions.append(.{
        .address = try std.testing.allocator.dupe(u8, "0x1000"),
        .instruction_bytes = try std.testing.allocator.dupe(u8, "90"),
        .instruction = try std.testing.allocator.dupe(u8, "nop"),
        .symbol = null,
        .source_path = null,
        .line = null,
        .column = null,
        .invalid = false,
        .pause_generation = 3,
    });

    const result = try session.ingestPayload(
        \\{"seq":1,"type":"event","event":"memory","body":{"memoryReference":"opaque:data","offset":0,"count":4}}
    );
    try std.testing.expectEqual(EventKind.memory, result.event);
    try std.testing.expect(session.memory_snapshot == null);
    try std.testing.expectEqual(@as(usize, 0), session.disassembled_instructions.items.len);
}

test "DAP instruction breakpoint response rejects malformed runtime metadata" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();
    session.capabilities.supports_instruction_breakpoints = true;
    session.active_adapter_key = try std.testing.allocator.dupe(u8, "lldb");
    try session.instruction_breakpoints.append(.{
        .adapter_key = try std.testing.allocator.dupe(u8, "lldb"),
        .instruction_reference = try std.testing.allocator.dupe(u8, "0x1000"),
        .label = try std.testing.allocator.dupe(u8, "nop"),
    });

    var set = try session.makeSetInstructionBreakpoints();
    defer set.deinit();
    _ = try session.ingestPayload(
        \\{"seq":2,"type":"response","request_seq":1,"success":true,"command":"setInstructionBreakpoints","body":{"breakpoints":[{"verified":"yes","id":7}]}}
    );
    try std.testing.expectEqual(@as(usize, 1), session.rejected_low_level_metadata);
    try std.testing.expect(session.instruction_breakpoints.items[0].verified == null);
    try std.testing.expect(session.instruction_breakpoints.items[0].adapter_id == null);
}

test "DAP session rejects stale or malformed data breakpoint metadata" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();
    session.state = .paused;
    session.pause_generation = 4;
    session.capabilities.supports_data_breakpoints = true;
    session.active_adapter_key = try std.testing.allocator.dupe(u8, "lldb");
    try session.variables.append(.{
        .name = try std.testing.allocator.dupe(u8, "value"),
        .value = try std.testing.allocator.dupe(u8, "1"),
        .type_name = null,
        .evaluate_name = null,
        .variables_reference = 0,
        .named_variables = null,
        .indexed_variables = null,
        .memory_reference = null,
        .parent_variables_reference = 20,
        .frame_id = 3,
        .pause_generation = 4,
    });

    var info = try session.makeDataBreakpointInfo(0);
    defer info.deinit();
    _ = try session.ingestPayload(
        \\{"seq":1,"type":"response","request_seq":1,"success":true,"command":"dataBreakpointInfo","body":{"dataId":"unsafe\nID","description":"bad","accessTypes":["write"]}}
    );
    try std.testing.expect(session.data_breakpoint_candidate == null);
    try std.testing.expectEqual(@as(usize, 1), session.rejected_data_breakpoint_metadata);

    var delayed = try session.makeDataBreakpointInfo(0);
    defer delayed.deinit();
    _ = try session.ingestPayload(
        \\{"seq":2,"type":"event","event":"continued","body":{"threadId":7}}
    );
    _ = try session.ingestPayload(
        \\{"seq":3,"type":"response","request_seq":2,"success":true,"command":"dataBreakpointInfo","body":{"dataId":"opaque:stale","description":"stale","accessTypes":["write"]}}
    );
    try std.testing.expect(session.data_breakpoint_candidate == null);
    try std.testing.expectEqual(@as(usize, 0), session.variables.items.len);
}

test "DAP capabilities events update only advertised fields" {
    var session = try Session.init(std.testing.allocator, "/repo");
    defer session.deinit();
    var initialize = try session.makeInitialize("lldb");
    defer initialize.deinit();
    _ = try session.ingestPayload(
        \\{"seq":1,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{"supportsFunctionBreakpoints":true,"supportsDataBreakpoints":true,"supportsLogPoints":true,"exceptionBreakpointFilters":[{"filter":"all","label":"All"}]}}
    );
    session.data_breakpoint_candidate = .{
        .adapter_key = try std.testing.allocator.dupe(u8, "lldb"),
        .data_id = try std.testing.allocator.dupe(u8, "opaque:temporary"),
        .description = try std.testing.allocator.dupe(u8, "temporary"),
        .variable_name = try std.testing.allocator.dupe(u8, "value"),
        .access_types = .{ .write = true },
        .pause_generation = 1,
    };

    const result = try session.ingestPayload(
        \\{"seq":2,"type":"event","event":"capabilities","body":{"capabilities":{"supportsDataBreakpoints":false}}}
    );
    try std.testing.expectEqual(EventKind.capabilities, result.event);
    try std.testing.expect(!session.capabilities.supports_data_breakpoints);
    try std.testing.expect(session.data_breakpoint_candidate == null);
    try std.testing.expect(session.capabilities.supports_function_breakpoints);
    try std.testing.expect(session.capabilities.supports_log_points);
    try std.testing.expectEqual(@as(usize, 1), session.exception_filters.items.len);

    _ = try session.ingestPayload(
        \\{"seq":3,"type":"event","event":"capabilities","body":{"capabilities":{"supportsDataBreakpoints":true,"exceptionBreakpointFilters":[{"filter":"uncaught","label":"Uncaught"}]}}}
    );
    try std.testing.expect(session.capabilities.supports_data_breakpoints);
    try std.testing.expectEqualStrings("uncaught", session.exception_filters.items[0].id);
}
