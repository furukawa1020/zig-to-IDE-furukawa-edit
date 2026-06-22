const std = @import("std");
const permissions = @import("../security/permissions.zig");
const process = @import("../platform/process.zig");

pub const TaskDefinition = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    executable: ?[]u8 = null,
    args: std.array_list.Managed([]const u8),
    cwd: ?[]u8 = null,
    env_policy: permissions.EnvPolicy = .allowlist,
    fs_policy: permissions.FileSystemPolicy = .workspace_only,
    network_policy: permissions.NetworkPolicy = .deny,
    timeout_ms: ?u32 = 60_000,
    output_limit_bytes: usize = 512 * 1024,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !TaskDefinition {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .args = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *TaskDefinition) void {
        self.allocator.free(self.name);
        if (self.executable) |value| self.allocator.free(value);
        for (self.args.items) |arg| self.allocator.free(arg);
        self.args.deinit();
        if (self.cwd) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn displayName(self: *const TaskDefinition) []const u8 {
        return self.name;
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    tasks: std.array_list.Managed(TaskDefinition),
    diagnostics: std.array_list.Managed([]u8),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .tasks = std.array_list.Managed(TaskDefinition).init(allocator),
            .diagnostics = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.tasks.items) |*task| task.deinit();
        self.tasks.deinit();
        for (self.diagnostics.items) |message| self.allocator.free(message);
        self.diagnostics.deinit();
        self.* = undefined;
    }

    pub fn addOrReplace(self: *Registry, task: TaskDefinition) !void {
        if (self.findIndex(task.name)) |index| {
            var old = self.tasks.orderedRemove(index);
            old.deinit();
        }
        try self.tasks.append(task);
    }

    pub fn find(self: *const Registry, name: []const u8) ?*const TaskDefinition {
        if (self.findIndex(name)) |index| return &self.tasks.items[index];
        return null;
    }

    fn findIndex(self: *const Registry, name: []const u8) ?usize {
        for (self.tasks.items, 0..) |task, index| {
            if (std.mem.eql(u8, task.name, name)) return index;
        }
        return null;
    }

    fn appendDiagnostic(self: *Registry, comptime fmt: []const u8, args: anytype) !void {
        try self.diagnostics.append(try std.fmt.allocPrint(self.allocator, fmt, args));
    }
};

pub const SpawnPlan = struct {
    allocator: std.mem.Allocator,
    cwd: []u8,
    command_display: []u8,
    spec: process.SpawnSpec,
    consent: permissions.Consent,

    pub fn deinit(self: *SpawnPlan) void {
        self.allocator.free(self.command_display);
        self.allocator.free(self.cwd);
        self.* = undefined;
    }
};

pub fn loadProjectTasks(allocator: std.mem.Allocator, workspace_root: []const u8) !Registry {
    var registry = Registry.init(allocator);
    errdefer registry.deinit();

    try addDefaultTasks(&registry, workspace_root);

    const path = try std.fs.path.join(allocator, &.{ workspace_root, "zide.tasks" });
    defer allocator.free(path);
    const source = readFile(allocator, path, 512 * 1024) catch |err| switch (err) {
        error.FileNotFound => return registry,
        else => {
            try registry.appendDiagnostic("could not read zide.tasks: {s}", .{@errorName(err)});
            return registry;
        },
    };
    defer allocator.free(source);

    try parseInto(&registry, source);
    return registry;
}

pub fn makeSpawnPlan(allocator: std.mem.Allocator, workspace_root: []const u8, task: *const TaskDefinition) !SpawnPlan {
    const executable = task.executable orelse return error.TaskMissingExecutable;
    const cwd = try resolveTaskCwd(allocator, workspace_root, task.cwd);
    errdefer allocator.free(cwd);

    const command_display = try process.appendDisplay(allocator, .{
        .executable = executable,
        .args = task.args.items,
        .cwd = cwd,
    });
    errdefer allocator.free(command_display);

    return .{
        .allocator = allocator,
        .cwd = cwd,
        .command_display = command_display,
        .spec = .{
            .command = .{
                .executable = executable,
                .args = task.args.items,
                .cwd = cwd,
            },
            .stdout = .pipe,
            .stderr = .pipe,
            .stdin = .ignore,
        },
        .consent = .{
            .command = command_display,
            .cwd = cwd,
            .env_policy = task.env_policy,
            .fs_policy = task.fs_policy,
            .network_policy = task.network_policy,
            .output_sanitized = true,
            .timeout_ms = task.timeout_ms,
            .output_limit_bytes = task.output_limit_bytes,
        },
    };
}

fn addDefaultTasks(registry: *Registry, workspace_root: []const u8) !void {
    const zig = try defaultZigExecutable(registry.allocator, workspace_root);
    defer registry.allocator.free(zig);

    try registry.addOrReplace(try makeTask(registry.allocator, "build", zig, &.{"build"}));
    try registry.addOrReplace(try makeTask(registry.allocator, "test", zig, &.{ "build", "test" }));
    try registry.addOrReplace(try makeTask(registry.allocator, "run", zig, &.{ "build", "run" }));
    try registry.addOrReplace(try makeTask(registry.allocator, "fmt", zig, &.{"fmt"}));
}

fn makeTask(allocator: std.mem.Allocator, name: []const u8, executable: []const u8, args: []const []const u8) !TaskDefinition {
    var task = try TaskDefinition.init(allocator, name);
    errdefer task.deinit();
    task.executable = try allocator.dupe(u8, executable);
    for (args) |arg| {
        try task.args.append(try allocator.dupe(u8, arg));
    }
    return task;
}

fn defaultZigExecutable(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const local = try std.fs.path.join(allocator, &.{ workspace_root, ".tools", "zig-0.16.0", "zig.exe" });
    errdefer allocator.free(local);
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, local, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(local);
            return allocator.dupe(u8, "zig");
        },
        else => return err,
    };
    return local;
}

fn parseInto(registry: *Registry, source: []const u8) !void {
    var current: ?TaskDefinition = null;
    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (line_iter.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, stripComment(raw_line), " \t\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "task ") and std.mem.endsWith(u8, line, "{")) {
            if (current) |*task| {
                task.deinit();
                try registry.appendDiagnostic("line {d}: nested task section ignored", .{line_number + 1});
            }
            const name = std.mem.trim(u8, line["task ".len .. line.len - 1], " \t");
            current = TaskDefinition.init(registry.allocator, name) catch |err| {
                try registry.appendDiagnostic("line {d}: could not allocate task: {s}", .{ line_number + 1, @errorName(err) });
                continue;
            };
            continue;
        }

        if (std.mem.eql(u8, line, "}")) {
            if (current) |task| {
                if (task.executable == null) {
                    var owned = task;
                    owned.deinit();
                    try registry.appendDiagnostic("line {d}: task missing executable", .{line_number + 1});
                } else {
                    try registry.addOrReplace(task);
                }
            } else {
                try registry.appendDiagnostic("line {d}: unmatched task close", .{line_number + 1});
            }
            current = null;
            continue;
        }

        if (current == null) {
            try registry.appendDiagnostic("line {d}: expected task section", .{line_number + 1});
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try registry.appendDiagnostic("line {d}: expected key = value", .{line_number + 1});
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = trimValue(line[eq + 1 ..]);
        applyTaskValue(registry.allocator, &current.?, key, value) catch |err| {
            try registry.appendDiagnostic("line {d}: invalid task value for {s}: {s}", .{ line_number + 1, key, @errorName(err) });
        };
    }

    if (current) |*task| {
        task.deinit();
        try registry.appendDiagnostic("unterminated task section", .{});
    }
}

fn applyTaskValue(allocator: std.mem.Allocator, task: *TaskDefinition, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "executable")) {
        if (task.executable) |old| allocator.free(old);
        task.executable = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "args")) {
        for (task.args.items) |arg| allocator.free(arg);
        task.args.clearRetainingCapacity();
        try appendArgs(allocator, &task.args, value);
    } else if (std.mem.eql(u8, key, "cwd")) {
        if (task.cwd) |old| allocator.free(old);
        task.cwd = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "env")) {
        task.env_policy = try parseEnum(permissions.EnvPolicy, value);
    } else if (std.mem.eql(u8, key, "fs")) {
        task.fs_policy = try parseEnum(permissions.FileSystemPolicy, value);
    } else if (std.mem.eql(u8, key, "network")) {
        task.network_policy = try parseEnum(permissions.NetworkPolicy, value);
    } else if (std.mem.eql(u8, key, "timeout_ms")) {
        task.timeout_ms = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, key, "output_limit_bytes")) {
        task.output_limit_bytes = try std.fmt.parseInt(usize, value, 10);
    } else {
        return error.UnknownTaskField;
    }
}

fn appendArgs(allocator: std.mem.Allocator, list: *std.array_list.Managed([]const u8), value: []const u8) !void {
    var at: usize = 0;
    while (at < value.len) {
        while (at < value.len and std.ascii.isWhitespace(value[at])) : (at += 1) {}
        if (at >= value.len) break;

        const start = at;
        if (value[at] == '"') {
            at += 1;
            const arg_start = at;
            while (at < value.len and value[at] != '"') : (at += 1) {}
            try list.append(try allocator.dupe(u8, value[arg_start..at]));
            if (at < value.len and value[at] == '"') at += 1;
        } else {
            while (at < value.len and !std.ascii.isWhitespace(value[at])) : (at += 1) {}
            try list.append(try allocator.dupe(u8, value[start..at]));
        }
    }
}

fn parseEnum(comptime T: type, value: []const u8) !T {
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(T, field.name);
    }
    return error.InvalidEnumValue;
}

fn stripComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
    const slash = std.mem.indexOf(u8, line, "//") orelse line.len;
    return line[0..@min(hash, slash)];
}

fn trimValue(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t\r,");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    return value;
}

fn resolveTaskCwd(allocator: std.mem.Allocator, workspace_root: []const u8, cwd: ?[]const u8) ![]u8 {
    const raw = cwd orelse return allocator.dupe(u8, workspace_root);
    if (std.fs.path.isAbsolute(raw)) return allocator.dupe(u8, raw);
    return std.fs.path.resolve(allocator, &.{ workspace_root, raw });
}

fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(max_bytes));
}

test "task registry parses project task config" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try parseInto(&registry,
        \\task run {
        \\  executable = "zig"
        \\  args = "build run -- demo"
        \\  cwd = "."
        \\  env = "allowlist"
        \\  fs = "workspace_only"
        \\  network = "deny"
        \\  timeout_ms = 1234
        \\}
        \\
    );

    const task = registry.find("run") orelse return error.ExpectedTask;
    try std.testing.expectEqualStrings("zig", task.executable.?);
    try std.testing.expectEqual(@as(usize, 4), task.args.items.len);
    try std.testing.expectEqual(@as(?u32, 1234), task.timeout_ms);
}

test "default registry includes build test run fmt" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try addDefaultTasks(&registry, ".");

    try std.testing.expect(registry.find("build") != null);
    try std.testing.expect(registry.find("test") != null);
    try std.testing.expect(registry.find("run") != null);
    try std.testing.expect(registry.find("fmt") != null);
}
