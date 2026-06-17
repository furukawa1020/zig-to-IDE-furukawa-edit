const std = @import("std");
const app_mod = @import("app.zig");
const build_commands = @import("../build/commands.zig");
const command = @import("command.zig");
const process = @import("../platform/process.zig");

pub const Result = union(enum) {
    completed: []const u8,
    blocked: []const u8,
    unknown_command,
    no_active_document,
    external_command: process.SpawnSpec,
    unsupported: []const u8,
};

pub fn dispatch(app: *app_mod.App, request: command.Request) !Result {
    const check = app.runtime.checkCommand(request);
    switch (check) {
        .unknown_command => return .unknown_command,
        .blocked => |message| return .{ .blocked = message },
        .allowed => |definition| return dispatchAllowed(app, definition, request),
    }
}

fn dispatchAllowed(app: *app_mod.App, definition: command.Definition, request: command.Request) !Result {
    _ = request;

    if (std.mem.eql(u8, definition.id, "view.command_palette")) {
        try app.palette.open();
        app.mode = .command;
        return .{ .completed = "command palette opened" };
    }

    if (std.mem.eql(u8, definition.id, "editor.undo")) {
        const doc = app.documents.active() orelse return .no_active_document;
        _ = try doc.undo();
        return .{ .completed = "undo" };
    }

    if (std.mem.eql(u8, definition.id, "editor.redo")) {
        const doc = app.documents.active() orelse return .no_active_document;
        _ = try doc.redo();
        return .{ .completed = "redo" };
    }

    if (std.mem.eql(u8, definition.id, "file.save")) {
        try app.documents.saveActive(.{});
        return .{ .completed = "saved" };
    }

    if (std.mem.eql(u8, definition.id, "zig.build")) {
        return .{ .external_command = zigCommand(app, .build) };
    }

    if (std.mem.eql(u8, definition.id, "zig.test")) {
        return .{ .external_command = zigCommand(app, .test_step) };
    }

    if (std.mem.eql(u8, definition.id, "zig.fmt")) {
        return .{ .external_command = zigCommand(app, .fmt) };
    }

    return .{ .unsupported = "command is registered but has no dispatcher yet" };
}

fn zigCommand(app: *app_mod.App, invocation: build_commands.BuildInvocation) process.SpawnSpec {
    var spec = build_commands.makeZigCommand(.{}, invocation, &.{});
    spec.command.cwd = app.workspace.root_path;
    return spec;
}

test "dispatch opens command palette" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "view.command_palette" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expect(app.palette.visible);
}
