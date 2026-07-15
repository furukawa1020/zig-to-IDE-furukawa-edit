const std = @import("std");
const builtin = @import("builtin");
const modes = @import("../language/modes.zig");
const process = @import("../platform/process.zig");
const workspace_io = @import("../security/workspace_io.zig");

const config_path = ".zide/debug.json";
const max_config_bytes: usize = 64 * 1024;
const max_args: usize = 128;
const max_argument_bytes: usize = 4096;

pub const Source = enum {
    workspace_config,
    explicit_program,
    inferred_script,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    label: []u8,
    adapter_id: []u8,
    adapter_argv: [][]const u8,
    program: []u8,
    cwd: []u8,
    program_args: [][]const u8,
    stop_on_entry: bool,
    source: Source,

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.label);
        self.allocator.free(self.adapter_id);
        freeArgs(self.allocator, self.adapter_argv);
        self.allocator.free(self.program);
        self.allocator.free(self.cwd);
        freeArgs(self.allocator, self.program_args);
        self.* = undefined;
    }

    pub fn spawnSpec(self: *const Plan) process.SpawnSpec {
        return .{
            .command = .{
                .executable = self.adapter_argv[0],
                .args = self.adapter_argv[1..],
                .cwd = self.cwd,
            },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        };
    }
};

pub fn resolve(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    language: modes.LanguageMode,
    active_path: ?[]const u8,
    explicit_program: ?[]const u8,
) !Plan {
    if (try loadWorkspaceConfig(allocator, workspace_root, explicit_program)) |plan| return plan;

    if (explicit_program) |program| {
        const defaults = defaultAdapter(language) orelse return error.DebugAdapterConfigurationRequired;
        return makePlan(allocator, workspace_root, .{
            .label = defaults.label,
            .adapter_id = defaults.adapter_id,
            .adapter = defaults.executable,
            .adapter_args = defaults.args,
            .program = program,
            .source = .explicit_program,
        });
    }

    if (isDirectScript(language)) {
        const path = active_path orelse return error.DebugProgramRequired;
        const relative = if (std.fs.path.isAbsolute(path))
            try workspace_io.relativeFilePath(workspace_root, path)
        else
            path;
        const defaults = defaultAdapter(language) orelse return error.DebugAdapterConfigurationRequired;
        return makePlan(allocator, workspace_root, .{
            .label = defaults.label,
            .adapter_id = defaults.adapter_id,
            .adapter = defaults.executable,
            .adapter_args = defaults.args,
            .program = relative,
            .source = .inferred_script,
        });
    }

    return error.DebugConfigurationRequired;
}

pub fn configPath() []const u8 {
    return config_path;
}

pub fn defaultAdapterHint(language: modes.LanguageMode) []const u8 {
    if (defaultAdapter(language)) |adapter| return adapter.hint;
    return "Create .zide/debug.json with a DAP adapter, workspace-relative program, cwd, and argv.";
}

pub fn makeConfigTemplate(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    language: modes.LanguageMode,
    active_path: ?[]const u8,
    explicit_program: ?[]const u8,
) ![]u8 {
    const defaults = defaultAdapter(language);
    const label = if (defaults) |value| value.label else "Custom DAP";
    const adapter_id = if (defaults) |value| value.adapter_id else "custom";
    const adapter = if (defaults) |value| value.executable else "dap-adapter";
    const adapter_args: []const []const u8 = if (defaults) |value| value.args else &.{};
    const program = try configTemplateProgram(allocator, workspace_root, language, active_path, explicit_program);
    defer allocator.free(program);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try json.write(.{
            .name = label,
            .adapter = adapter,
            .adapterID = adapter_id,
            .adapterArgs = adapter_args,
            .program = program,
            .args = @as([]const []const u8, &.{}),
            .cwd = ".",
            .stopOnEntry = false,
        });
    }
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn configTemplateProgram(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    language: modes.LanguageMode,
    active_path: ?[]const u8,
    explicit_program: ?[]const u8,
) ![]u8 {
    if (explicit_program) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return error.DebugProgramRequired;
        const relative = if (std.fs.path.isAbsolute(trimmed))
            try workspace_io.relativeFilePath(workspace_root, trimmed)
        else
            trimmed;
        try workspace_io.validateRelativeFilePath(relative);
        return allocator.dupe(u8, relative);
    }

    if (language == .python) {
        const path = active_path orelse return error.DebugProgramRequired;
        const relative = if (std.fs.path.isAbsolute(path))
            try workspace_io.relativeFilePath(workspace_root, path)
        else
            path;
        try workspace_io.validateRelativeFilePath(relative);
        return allocator.dupe(u8, relative);
    }

    return allocator.dupe(u8, "zig-out/bin/CHANGE_ME");
}

const PlanInput = struct {
    label: []const u8,
    adapter_id: []const u8,
    adapter: []const u8,
    adapter_args: []const []const u8 = &.{},
    program: []const u8,
    program_args: []const []const u8 = &.{},
    cwd: []const u8 = ".",
    stop_on_entry: bool = false,
    source: Source,
};

fn makePlan(allocator: std.mem.Allocator, workspace_root: []const u8, input: PlanInput) !Plan {
    try validateAdapterExecutable(input.adapter);
    try validateArgs(input.adapter_args);
    try validateArgs(input.program_args);

    const program_relative = if (std.fs.path.isAbsolute(input.program))
        try workspace_io.relativeFilePath(workspace_root, input.program)
    else
        input.program;
    try validateRegularWorkspaceFile(workspace_root, program_relative);
    const program = try workspace_io.absolutePathAlloc(allocator, workspace_root, program_relative);
    errdefer allocator.free(program);

    const cwd = try resolveWorkspaceCwd(allocator, workspace_root, input.cwd);
    errdefer allocator.free(cwd);
    const adapter_argv = try dupeCommand(allocator, input.adapter, input.adapter_args);
    errdefer freeArgs(allocator, adapter_argv);
    const program_args = try dupeArgs(allocator, input.program_args);
    errdefer freeArgs(allocator, program_args);
    const label = try allocator.dupe(u8, input.label);
    errdefer allocator.free(label);
    const adapter_id = try allocator.dupe(u8, input.adapter_id);
    errdefer allocator.free(adapter_id);

    return .{
        .allocator = allocator,
        .label = label,
        .adapter_id = adapter_id,
        .adapter_argv = adapter_argv,
        .program = program,
        .cwd = cwd,
        .program_args = program_args,
        .stop_on_entry = input.stop_on_entry,
        .source = input.source,
    };
}

fn loadWorkspaceConfig(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    explicit_program: ?[]const u8,
) !?Plan {
    var capability = workspace_io.openFileCapability(workspace_root, config_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer capability.close();
    const bytes = try capability.readFileAlloc(allocator, max_config_bytes);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidDebugConfiguration,
    };

    const adapter = stringField(object, "adapter") orelse return error.DebugAdapterRequired;
    const configured_program = stringField(object, "program") orelse return error.DebugProgramRequired;
    const program = explicit_program orelse configured_program;
    const adapter_id = stringField(object, "adapterID") orelse inferAdapterId(adapter);
    const label = stringField(object, "name") orelse "Workspace debug";
    const cwd = stringField(object, "cwd") orelse ".";
    const stop_on_entry = boolField(object, "stopOnEntry", false);

    const adapter_args = try stringArray(allocator, object, "adapterArgs");
    defer freeArgs(allocator, adapter_args);
    const program_args = try stringArray(allocator, object, "args");
    defer freeArgs(allocator, program_args);

    return try makePlan(allocator, workspace_root, .{
        .label = label,
        .adapter_id = adapter_id,
        .adapter = adapter,
        .adapter_args = adapter_args,
        .program = program,
        .program_args = program_args,
        .cwd = cwd,
        .stop_on_entry = stop_on_entry,
        .source = .workspace_config,
    });
}

const AdapterDefault = struct {
    label: []const u8,
    adapter_id: []const u8,
    executable: []const u8,
    args: []const []const u8,
    hint: []const u8,
};

fn defaultAdapter(language: modes.LanguageMode) ?AdapterDefault {
    return switch (language) {
        .zig, .c, .cpp, .objective_c, .objective_cpp, .assembly, .rust, .swift => .{
            .label = "LLDB DAP",
            .adapter_id = "lldb",
            .executable = "lldb-dap",
            .args = &.{},
            .hint = "Install lldb-dap and set program in .zide/debug.json or pass a workspace-relative executable.",
        },
        .python => .{
            .label = "debugpy DAP",
            .adapter_id = "python",
            .executable = if (builtin.os.tag == .windows) "python" else "python3",
            .args = &.{ "-m", "debugpy.adapter" },
            .hint = "Install debugpy in the selected Python environment.",
        },
        else => null,
    };
}

fn isDirectScript(language: modes.LanguageMode) bool {
    return language == .python;
}

fn validateAdapterExecutable(executable: []const u8) !void {
    if (executable.len == 0 or executable.len > 512) return error.InvalidDebugAdapter;
    if (std.mem.indexOfScalar(u8, executable, 0) != null) return error.InvalidDebugAdapter;
    if (std.mem.indexOfAny(u8, executable, "/\\:") != null) return error.AdapterMustUsePathLookup;
}

fn validateArgs(args: []const []const u8) !void {
    if (args.len > max_args) return error.TooManyDebugArguments;
    for (args) |arg| {
        if (arg.len > max_argument_bytes or std.mem.indexOfScalar(u8, arg, 0) != null) {
            return error.InvalidDebugArgument;
        }
    }
}

fn validateRegularWorkspaceFile(workspace_root: []const u8, relative_path: []const u8) !void {
    try workspace_io.validateRelativeFilePath(relative_path);
    var capability = try workspace_io.openFileCapability(workspace_root, relative_path);
    defer capability.close();
    const stat = try capability.statNoFollow();
    if (stat.kind != .file) return error.DebugProgramNotRegularFile;
    const file = try capability.openRead();
    file.close(std.Options.debug_io);
}

fn resolveWorkspaceCwd(allocator: std.mem.Allocator, workspace_root: []const u8, raw: []const u8) ![]u8 {
    if (std.mem.eql(u8, raw, ".") or raw.len == 0) return allocator.dupe(u8, workspace_root);
    const relative = if (std.fs.path.isAbsolute(raw))
        try workspace_io.relativeFilePath(workspace_root, raw)
    else
        raw;
    try workspace_io.validateRelativeFilePath(relative);

    const probe = try std.fs.path.join(allocator, &.{ relative, ".zide-cwd-probe" });
    defer allocator.free(probe);
    var capability = try workspace_io.openFileCapability(workspace_root, probe);
    defer capability.close();
    return workspace_io.absolutePathAlloc(allocator, workspace_root, relative);
}

fn dupeCommand(allocator: std.mem.Allocator, executable: []const u8, args: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, args.len + 1);
    errdefer allocator.free(result);
    result[0] = try allocator.dupe(u8, executable);
    errdefer allocator.free(result[0]);
    var initialized: usize = 1;
    errdefer for (result[1..initialized]) |arg| allocator.free(arg);
    for (args, 0..) |arg, index| {
        result[index + 1] = try allocator.dupe(u8, arg);
        initialized += 1;
    }
    return result;
}

fn dupeArgs(allocator: std.mem.Allocator, args: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, args.len);
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |arg| allocator.free(arg);
    for (args, 0..) |arg, index| {
        result[index] = try allocator.dupe(u8, arg);
        initialized += 1;
    }
    return result;
}

fn freeArgs(allocator: std.mem.Allocator, args: [][]const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn stringArray(allocator: std.mem.Allocator, object: std.json.ObjectMap, name: []const u8) ![][]const u8 {
    const value = object.get(name) orelse return allocator.alloc([]const u8, 0);
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidDebugArgumentArray,
    };
    if (array.items.len > max_args) return error.TooManyDebugArguments;
    const result = try allocator.alloc([]const u8, array.items.len);
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |arg| allocator.free(arg);
    for (array.items, 0..) |item, index| {
        const text = switch (item) {
            .string => |text| text,
            else => return error.InvalidDebugArgumentArray,
        };
        if (text.len > max_argument_bytes or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidDebugArgument;
        result[index] = try allocator.dupe(u8, text);
        initialized += 1;
    }
    return result;
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

fn inferAdapterId(adapter: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(adapter, "lldb-dap")) return "lldb";
    if (std.ascii.eqlIgnoreCase(adapter, "python") or std.ascii.eqlIgnoreCase(adapter, "python3")) return "python";
    return "custom";
}

test "Python launch plan infers active workspace script" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "main.py", .data = "print('ok')\n" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root = root_buffer[0..root_len];
    const active = try std.fs.path.join(std.testing.allocator, &.{ root, "main.py" });
    defer std.testing.allocator.free(active);

    var plan = try resolve(std.testing.allocator, root, .python, active, null);
    defer plan.deinit();
    try std.testing.expectEqualStrings("python", plan.adapter_id);
    try std.testing.expectEqual(Source.inferred_script, plan.source);
    try std.testing.expect(std.mem.endsWith(u8, plan.program, "main.py"));
}

test "workspace config is parsed without shell interpolation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.Options.debug_io, ".zide");
    try tmp.dir.createDirPath(std.Options.debug_io, "bin");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "bin/app", .data = "binary" });
    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = config_path,
        .data =
        \\{"name":"App","adapter":"lldb-dap","adapterID":"lldb","program":"bin/app","args":["--safe value"],"stopOnEntry":true}
        ,
    });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);

    var plan = try resolve(std.testing.allocator, root_buffer[0..root_len], .zig, null, null);
    defer plan.deinit();
    try std.testing.expectEqual(Source.workspace_config, plan.source);
    try std.testing.expectEqualStrings("lldb-dap", plan.adapter_argv[0]);
    try std.testing.expectEqualStrings("--safe value", plan.program_args[0]);
    try std.testing.expect(plan.stop_on_entry);
}

test "adapter configuration rejects paths and program traversal" {
    try std.testing.expectError(error.AdapterMustUsePathLookup, validateAdapterExecutable("../lldb-dap"));
    try std.testing.expectError(error.InvalidWorkspacePath, workspace_io.validateRelativeFilePath("../outside"));
}

test "debug config template is structured JSON and workspace relative" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "main.py", .data = "print('ok')\n" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root = root_buffer[0..root_len];
    const active = try std.fs.path.join(std.testing.allocator, &.{ root, "main.py" });
    defer std.testing.allocator.free(active);

    const bytes = try makeConfigTemplate(std.testing.allocator, root, .python, active, null);
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("python", object.get("adapterID").?.string);
    try std.testing.expectEqualStrings("main.py", object.get("program").?.string);
    try std.testing.expectEqualStrings("python", object.get("adapter").?.string);

    try std.testing.expectError(
        error.InvalidWorkspacePath,
        makeConfigTemplate(std.testing.allocator, root, .zig, null, "../outside"),
    );
}
