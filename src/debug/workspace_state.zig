const std = @import("std");
const editor_save = @import("../editor/save.zig");
const debug_breakpoint = @import("../security/debug_breakpoint.zig");
const debug_expression = @import("../security/debug_expression.zig");
const workspace_io = @import("../security/workspace_io.zig");
const session_mod = @import("session.zig");

pub const relative_path = ".zide/debug-state.json";
pub const schema_version: i64 = 2;
const legacy_schema_version: i64 = 1;
pub const max_state_bytes: usize = 1024 * 1024;
const max_stored_watches: usize = 64;
const max_stored_breakpoints: usize = 4096;

pub const LoadReport = struct {
    found: bool = false,
    watches_loaded: usize = 0,
    breakpoints_loaded: usize = 0,
    entries_rejected: usize = 0,
};

pub const SaveReport = struct {
    watches_saved: usize = 0,
    breakpoints_saved: usize = 0,
    breakpoints_skipped: usize = 0,
    bytes_written: usize = 0,
};

pub fn load(allocator: std.mem.Allocator, workspace_root: []const u8, session: *session_mod.Session) !LoadReport {
    var capability = workspace_io.openFileCapability(workspace_root, relative_path) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer capability.close();
    const bytes = try capability.readFileAlloc(allocator, max_state_bytes);
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidDebugState;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidDebugState,
    };
    const version = intField(root, "version") orelse return error.InvalidDebugState;
    if (version != legacy_schema_version and version != schema_version) return error.UnsupportedDebugStateVersion;
    const stored_watches = arrayField(root, "watches") orelse return error.InvalidDebugState;
    const stored_breakpoints = arrayField(root, "breakpoints") orelse return error.InvalidDebugState;

    var staged = try session_mod.Session.init(allocator, workspace_root);
    defer staged.deinit();
    var report: LoadReport = .{ .found = true };

    {
        const limit = @min(stored_watches.items.len, max_stored_watches);
        report.entries_rejected += stored_watches.items.len - limit;
        for (stored_watches.items[0..limit]) |value| {
            const expression = switch (value) {
                .string => |text| text,
                else => {
                    report.entries_rejected += 1;
                    continue;
                },
            };
            if (debug_expression.classify(expression) != .inspection) {
                report.entries_rejected += 1;
                continue;
            }
            const before = staged.watches.items.len;
            _ = try staged.addWatch(expression);
            if (staged.watches.items.len == before) {
                report.entries_rejected += 1;
            } else {
                report.watches_loaded += 1;
            }
        }
    }

    {
        const limit = @min(stored_breakpoints.items.len, max_stored_breakpoints);
        report.entries_rejected += stored_breakpoints.items.len - limit;
        for (stored_breakpoints.items[0..limit]) |value| {
            const object = switch (value) {
                .object => |item| item,
                else => {
                    report.entries_rejected += 1;
                    continue;
                },
            };
            if (version == legacy_schema_version and
                (object.contains("condition") or object.contains("hit_condition") or object.contains("log_message")))
            {
                report.entries_rejected += 1;
                continue;
            }
            const stored_path = stringField(object, "path") orelse {
                report.entries_rejected += 1;
                continue;
            };
            const line_value = intField(object, "line") orelse {
                report.entries_rejected += 1;
                continue;
            };
            if (line_value <= 0 or stored_path.len > std.fs.max_path_bytes) {
                report.entries_rejected += 1;
                continue;
            }
            workspace_io.validateRelativeFilePath(stored_path) catch {
                report.entries_rejected += 1;
                continue;
            };
            const line = std.math.cast(usize, line_value) orelse {
                report.entries_rejected += 1;
                continue;
            };
            const enabled = optionalBoolField(object, "enabled") catch {
                report.entries_rejected += 1;
                continue;
            } orelse true;
            const condition = optionalStringField(object, "condition") catch {
                report.entries_rejected += 1;
                continue;
            };
            const hit_condition = optionalStringField(object, "hit_condition") catch {
                report.entries_rejected += 1;
                continue;
            };
            const log_message = optionalStringField(object, "log_message") catch {
                report.entries_rejected += 1;
                continue;
            };
            const absolute_path = try workspace_io.absolutePathAlloc(allocator, workspace_root, stored_path);
            defer allocator.free(absolute_path);
            const added = staged.addConfiguredBreakpoint(.{
                .path = absolute_path,
                .line = line,
                .enabled = enabled,
                .condition = condition,
                .hit_condition = hit_condition,
                .log_message = log_message,
            }) catch |err| switch (err) {
                error.InvalidBreakpointLine,
                error.InvalidBreakpointPath,
                error.TooManyBreakpoints,
                error.EmptyBreakpointValue,
                error.BreakpointValueTooLong,
                error.InvalidBreakpointUtf8,
                error.HiddenBreakpointControl,
                error.UnsafeBreakpointCondition,
                error.InvalidHitCondition,
                error.UnsafeLogMessage,
                => {
                    report.entries_rejected += 1;
                    continue;
                },
                else => return err,
            };
            if (added) {
                report.breakpoints_loaded += 1;
            } else {
                report.entries_rejected += 1;
            }
        }
    }

    std.mem.swap(@TypeOf(session.watches), &session.watches, &staged.watches);
    std.mem.swap(@TypeOf(session.breakpoints), &session.breakpoints, &staged.breakpoints);
    std.mem.swap(u64, &session.next_watch_id, &staged.next_watch_id);
    return report;
}

pub fn save(allocator: std.mem.Allocator, workspace_root: []const u8, session: *const session_mod.Session) !SaveReport {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var report: SaveReport = .{};

    {
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
        try json.beginObject();
        try json.objectField("version");
        try json.write(schema_version);
        try json.objectField("watches");
        try json.beginArray();
        for (session.watches.items[0..@min(session.watches.items.len, max_stored_watches)]) |watch| {
            try json.write(watch.expression);
            report.watches_saved += 1;
        }
        try json.endArray();
        try json.objectField("breakpoints");
        try json.beginArray();
        for (session.breakpoints.items[0..@min(session.breakpoints.items.len, max_stored_breakpoints)]) |breakpoint| {
            if (!advancedFieldsValid(breakpoint)) {
                report.breakpoints_skipped += 1;
                continue;
            }
            const stored_path = workspace_io.relativeFilePath(workspace_root, breakpoint.path) catch {
                report.breakpoints_skipped += 1;
                continue;
            };
            try json.beginObject();
            try json.objectField("path");
            try json.write(stored_path);
            try json.objectField("line");
            try json.write(breakpoint.line);
            try json.objectField("enabled");
            try json.write(breakpoint.enabled);
            if (breakpoint.condition) |condition| {
                try json.objectField("condition");
                try json.write(condition);
            }
            if (breakpoint.hit_condition) |hit_condition| {
                try json.objectField("hit_condition");
                try json.write(hit_condition);
            }
            if (breakpoint.log_message) |log_message| {
                try json.objectField("log_message");
                try json.write(log_message);
            }
            try json.endObject();
            report.breakpoints_saved += 1;
        }
        try json.endArray();
        try json.endObject();
    }
    try out.writer.writeByte('\n');
    if (out.written().len > max_state_bytes) return error.DebugStateTooLarge;

    var capability = try workspace_io.openFileCapabilityCreateParents(workspace_root, relative_path);
    defer capability.close();
    try editor_save.saveBytesInDir(allocator, capability.parent, capability.name, out.written(), .{
        .atomic = true,
        .backup_before_overwrite = false,
        .preserve_permissions = true,
    });
    report.bytes_written = out.written().len;
    return report;
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

fn intField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn optionalStringField(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidDebugStateEntry,
    };
}

fn optionalBoolField(object: std.json.ObjectMap, name: []const u8) !?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidDebugStateEntry,
    };
}

fn advancedFieldsValid(breakpoint: session_mod.Breakpoint) bool {
    if (breakpoint.condition) |value| _ = debug_breakpoint.validateCondition(value) catch return false;
    if (breakpoint.hit_condition) |value| _ = debug_breakpoint.validateHitCondition(value) catch return false;
    if (breakpoint.log_message) |value| _ = debug_breakpoint.validateLogMessage(value) catch return false;
    return true;
}

test "debug workspace state atomically round trips restricted watches and breakpoints" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buf);
    const root = root_buf[0..root_len];

    var source = try session_mod.Session.init(std.testing.allocator, root);
    defer source.deinit();
    _ = try source.addWatch("state.items[0].name");
    const source_path = try workspace_io.absolutePathAlloc(std.testing.allocator, root, "src/main.zig");
    defer std.testing.allocator.free(source_path);
    _ = try source.addBreakpoint(source_path, 17, true);

    const saved = try save(std.testing.allocator, root, &source);
    try std.testing.expectEqual(@as(usize, 1), saved.watches_saved);
    try std.testing.expectEqual(@as(usize, 1), saved.breakpoints_saved);
    try std.testing.expect(saved.bytes_written > 0);

    var restored = try session_mod.Session.init(std.testing.allocator, root);
    defer restored.deinit();
    const loaded = try load(std.testing.allocator, root, &restored);
    try std.testing.expect(loaded.found);
    try std.testing.expectEqual(@as(usize, 1), loaded.watches_loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.breakpoints_loaded);
    try std.testing.expectEqualStrings("state.items[0].name", restored.watches.items[0].expression);
    try std.testing.expectEqualStrings(source_path, restored.breakpoints.items[0].path);
    try std.testing.expectEqual(@as(usize, 17), restored.breakpoints.items[0].line);
}

test "debug workspace state rejects executable watches and escaping paths" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.Options.debug_io, ".zide");
    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = relative_path,
        .data =
        \\{"version":1,"watches":["safe.value","run()"],"breakpoints":[{"path":"src/main.zig","line":4,"enabled":true},{"path":"../outside.zig","line":9}]}
        ,
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buf);
    const root = root_buf[0..root_len];

    var session = try session_mod.Session.init(std.testing.allocator, root);
    defer session.deinit();
    const report = try load(std.testing.allocator, root, &session);
    try std.testing.expectEqual(@as(usize, 1), report.watches_loaded);
    try std.testing.expectEqual(@as(usize, 1), report.breakpoints_loaded);
    try std.testing.expectEqual(@as(usize, 2), report.entries_rejected);
}

test "debug workspace state v2 round trips restricted advanced breakpoints" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buf);
    const root = root_buf[0..root_len];

    var source = try session_mod.Session.init(std.testing.allocator, root);
    defer source.deinit();
    const source_path = try workspace_io.absolutePathAlloc(std.testing.allocator, root, "src/main.zig");
    defer std.testing.allocator.free(source_path);
    _ = try source.addConfiguredBreakpoint(.{
        .path = source_path,
        .line = 9,
        .condition = "user.is_admin == true",
        .hit_condition = "3",
        .log_message = "admin {user.name}",
    });

    const saved = try save(std.testing.allocator, root, &source);
    try std.testing.expectEqual(@as(usize, 1), saved.breakpoints_saved);
    try std.testing.expectEqual(@as(usize, 0), saved.breakpoints_skipped);

    var restored = try session_mod.Session.init(std.testing.allocator, root);
    defer restored.deinit();
    const loaded = try load(std.testing.allocator, root, &restored);
    try std.testing.expectEqual(@as(usize, 1), loaded.breakpoints_loaded);
    try std.testing.expectEqualStrings("user.is_admin == true", restored.breakpoints.items[0].condition.?);
    try std.testing.expectEqualStrings("3", restored.breakpoints.items[0].hit_condition.?);
    try std.testing.expectEqualStrings("admin {user.name}", restored.breakpoints.items[0].log_message.?);
}

test "debug workspace state rejects unsafe advanced breakpoint fields transactionally" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.Options.debug_io, ".zide");
    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = relative_path,
        .data =
        \\{"version":2,"watches":[],"breakpoints":[{"path":"src/main.zig","line":4,"condition":"launch()"},{"path":"src/ok.zig","line":8,"hit_condition":"5"}]}
        ,
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buf);
    const root = root_buf[0..root_len];

    var session = try session_mod.Session.init(std.testing.allocator, root);
    defer session.deinit();
    const report = try load(std.testing.allocator, root, &session);
    try std.testing.expectEqual(@as(usize, 1), report.breakpoints_loaded);
    try std.testing.expectEqual(@as(usize, 1), report.entries_rejected);
    try std.testing.expectEqual(@as(usize, 8), session.breakpoints.items[0].line);
}

test "debug workspace state refuses unsafe in-memory advanced fields" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buf);
    const root = root_buf[0..root_len];

    var session = try session_mod.Session.init(std.testing.allocator, root);
    defer session.deinit();
    const source_path = try workspace_io.absolutePathAlloc(std.testing.allocator, root, "src/main.zig");
    defer std.testing.allocator.free(source_path);
    _ = try session.addBreakpoint(source_path, 4, true);
    session.breakpoints.items[0].condition = try std.testing.allocator.dupe(u8, "launch()");

    const report = try save(std.testing.allocator, root, &session);
    try std.testing.expectEqual(@as(usize, 0), report.breakpoints_saved);
    try std.testing.expectEqual(@as(usize, 1), report.breakpoints_skipped);
}

test "legacy debug state cannot smuggle advanced fields" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.Options.debug_io, ".zide");
    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = relative_path,
        .data =
        \\{"version":1,"watches":[],"breakpoints":[{"path":"src/main.zig","line":4,"condition":"ready == true"}]}
        ,
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buf);

    var session = try session_mod.Session.init(std.testing.allocator, root_buf[0..root_len]);
    defer session.deinit();
    const report = try load(std.testing.allocator, root_buf[0..root_len], &session);
    try std.testing.expectEqual(@as(usize, 0), report.breakpoints_loaded);
    try std.testing.expectEqual(@as(usize, 1), report.entries_rejected);
}

test "debug workspace state rejects incomplete schemas" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.Options.debug_io, ".zide");
    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = relative_path,
        .data = "{\"version\":1,\"watches\":[]}",
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buf);

    var session = try session_mod.Session.init(std.testing.allocator, root_buf[0..root_len]);
    defer session.deinit();
    try std.testing.expectError(error.InvalidDebugState, load(std.testing.allocator, root_buf[0..root_len], &session));
}

test "missing debug workspace state is not an error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buf);

    var session = try session_mod.Session.init(std.testing.allocator, root_buf[0..root_len]);
    defer session.deinit();
    const report = try load(std.testing.allocator, root_buf[0..root_len], &session);
    try std.testing.expect(!report.found);
}
