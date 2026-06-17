const std = @import("std");
const app_mod = @import("app.zig");
const build_commands = @import("../build/commands.zig");
const build_consent = @import("../security/build_consent.zig");
const command = @import("command.zig");
const navigation = @import("../editor/navigation.zig");
const process = @import("../platform/process.zig");
const posture = @import("../security/posture.zig");
const security_findings = @import("../security/findings.zig");
const workspace_audit = @import("../security/workspace_audit.zig");
const zig_scanner = @import("../security/zig_scanner.zig");

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
        .blocked => |message| {
            try rememberConsentPreview(app, request);
            return .{ .blocked = message };
        },
        .confirmation_required => |message| {
            try rememberConsentPreview(app, request);
            return .{ .blocked = message };
        },
        .allowed => |definition| return dispatchAllowed(app, definition, request),
    }
}

fn dispatchAllowed(app: *app_mod.App, definition: command.Definition, request: command.Request) !Result {
    if (std.mem.eql(u8, definition.id, "view.command_palette")) {
        try app.palette.open();
        app.mode = .command;
        return .{ .completed = "command palette opened" };
    }

    if (std.mem.eql(u8, definition.id, "editor.enter_insert")) {
        app.mode = .insert;
        return .{ .completed = "insert mode" };
    }

    if (std.mem.eql(u8, definition.id, "editor.exit_insert")) {
        app.mode = .normal;
        return .{ .completed = "normal mode" };
    }

    if (std.mem.eql(u8, definition.id, "editor.insert")) {
        const bytes = request.argument orelse return .{ .unsupported = "editor.insert requires text" };
        const doc = app.documents.active() orelse return .no_active_document;
        try doc.insert(doc.cursor.position.byte_offset, bytes);
        return .{ .completed = "inserted text" };
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

    if (std.mem.eql(u8, definition.id, "editor.move_left")) {
        const doc = app.documents.active() orelse return .no_active_document;
        try navigation.moveCursor(doc, .left);
        return .{ .completed = "cursor left" };
    }

    if (std.mem.eql(u8, definition.id, "editor.move_right")) {
        const doc = app.documents.active() orelse return .no_active_document;
        try navigation.moveCursor(doc, .right);
        return .{ .completed = "cursor right" };
    }

    if (std.mem.eql(u8, definition.id, "editor.move_up")) {
        const doc = app.documents.active() orelse return .no_active_document;
        try navigation.moveCursor(doc, .up);
        return .{ .completed = "cursor up" };
    }

    if (std.mem.eql(u8, definition.id, "editor.move_down")) {
        const doc = app.documents.active() orelse return .no_active_document;
        try navigation.moveCursor(doc, .down);
        return .{ .completed = "cursor down" };
    }

    if (std.mem.eql(u8, definition.id, "file.save")) {
        try app.documents.saveActive(.{});
        return .{ .completed = "saved" };
    }

    if (std.mem.eql(u8, definition.id, "file.open")) {
        const argument = request.argument orelse return .{ .unsupported = "file.open requires a path argument" };
        const path = try workspacePath(app, argument);
        defer app.allocator.free(path);
        _ = try app.documents.openFile(path);
        return .{ .completed = "opened file" };
    }

    if (std.mem.eql(u8, definition.id, "security.scan_current")) {
        const doc = app.documents.active() orelse return .no_active_document;
        const path = doc.path orelse "(scratch)";
        var scan = try zig_scanner.scanSource(app.allocator, doc.text.bytes, .{ .path = path });
        defer scan.deinit();

        app.security_findings.clear();
        for (scan.items.items) |item| {
            try app.security_findings.append(
                item.category,
                item.risk,
                item.path,
                item.line,
                item.column,
                item.message,
                item.evidence,
            );
        }
        return .{ .completed = "security scan complete" };
    }

    if (std.mem.eql(u8, definition.id, "security.audit_workspace")) {
        var audit = try workspace_audit.auditWorkspace(app.allocator, &app.workspace, .{});
        defer audit.deinit();

        app.security_findings.clear();
        for (audit.items.items) |item| {
            try app.security_findings.appendFinding(item);
        }
        return .{ .completed = "workspace security audit complete" };
    }

    if (std.mem.eql(u8, definition.id, "security.mark_reviewed")) {
        if (!hasWorkspaceAudit(&app.security_findings)) {
            return .{ .blocked = "run security.audit_workspace before marking this workspace reviewed" };
        }

        const summary = posture.summarize(&app.security_findings, app.runtime.trust_state);
        if (summary.critical > 0) {
            return .{ .blocked = "workspace has critical security findings; review cannot be marked complete" };
        }

        app.runtime.trust_state = .reviewed;
        return .{ .completed = "workspace marked reviewed" };
    }

    if (std.mem.eql(u8, definition.id, "security.trust_workspace")) {
        if (!hasWorkspaceAudit(&app.security_findings)) {
            return .{ .blocked = "run security.audit_workspace before trusting this workspace" };
        }

        const summary = posture.summarize(&app.security_findings, app.runtime.trust_state);
        if (summary.high > 0) {
            return .{ .blocked = "workspace has high-risk security findings; trust not elevated" };
        }

        app.runtime.trust_state = .trusted;
        return .{ .completed = "workspace trusted" };
    }

    if (std.mem.eql(u8, definition.id, "security.lock_workspace")) {
        app.runtime.trust_state = .locked_down;
        return .{ .completed = "workspace locked down" };
    }

    if (std.mem.eql(u8, definition.id, "security.dismiss_consent")) {
        app.clearPendingBuildConsent();
        return .{ .completed = "build consent dismissed" };
    }

    if (std.mem.eql(u8, definition.id, "zig.build")) {
        app.clearPendingBuildConsent();
        return .{ .external_command = zigCommand(app, .build) };
    }

    if (std.mem.eql(u8, definition.id, "zig.test")) {
        app.clearPendingBuildConsent();
        return .{ .external_command = zigCommand(app, .test_step) };
    }

    if (std.mem.eql(u8, definition.id, "zig.fmt")) {
        app.clearPendingBuildConsent();
        return .{ .external_command = zigCommand(app, .fmt) };
    }

    return .{ .unsupported = "command is registered but has no dispatcher yet" };
}

fn zigCommand(app: *app_mod.App, invocation: build_commands.BuildInvocation) process.SpawnSpec {
    var spec = build_commands.makeZigCommand(.{}, invocation, &.{});
    spec.command.cwd = app.workspace.root_path;
    return spec;
}

fn rememberConsentPreview(app: *app_mod.App, request: command.Request) !void {
    const spec = externalCommandPreview(app, request) orelse return;
    var preview = try build_consent.makePreview(app.allocator, spec, app.runtime.trust_state);
    errdefer preview.deinit();
    app.setPendingBuildConsent(preview);
}

fn externalCommandPreview(app: *app_mod.App, request: command.Request) ?process.SpawnSpec {
    if (std.mem.eql(u8, request.id, "zig.build")) return zigCommand(app, .build);
    if (std.mem.eql(u8, request.id, "zig.test")) return zigCommand(app, .test_step);
    if (std.mem.eql(u8, request.id, "zig.fmt")) return zigCommand(app, .fmt);
    return null;
}

fn hasWorkspaceAudit(collection: *const security_findings.Collection) bool {
    for (collection.items.items) |item| {
        if (item.category == .workspace_trust) return true;
    }
    return false;
}

fn workspacePath(app: *app_mod.App, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return app.allocator.dupe(u8, path);
    }
    return std.fs.path.join(app.allocator, &.{ app.workspace.root_path, path });
}

test "dispatch opens command palette" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "view.command_palette" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expect(app.palette.visible);
}

test "blocked build command creates consent preview" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "zig.build" });
    try std.testing.expect(std.meta.activeTag(result) == .blocked);
    try std.testing.expect(app.pending_build_consent != null);
    const preview = app.pending_build_consent.?;
    try std.testing.expect(std.mem.indexOf(u8, preview.command, "zig build") != null);
}
