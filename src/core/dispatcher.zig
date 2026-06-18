const std = @import("std");
const app_mod = @import("app.zig");
const build_commands = @import("../build/commands.zig");
const build_consent = @import("../security/build_consent.zig");
const command = @import("command.zig");
const navigation = @import("../editor/navigation.zig");
const process = @import("../platform/process.zig");
const executor = @import("../tasks/executor.zig");
const permissions = @import("../security/permissions.zig");
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
        applyPostureGuard(app);
        return .{ .completed = "security scan complete" };
    }

    if (std.mem.eql(u8, definition.id, "security.audit_workspace")) {
        var audit = try workspace_audit.auditWorkspace(app.allocator, &app.workspace, .{});
        defer audit.deinit();

        app.security_findings.clear();
        for (audit.items.items) |item| {
            try app.security_findings.appendFinding(item);
        }
        applyPostureGuard(app);
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

    if (std.mem.eql(u8, definition.id, "security.approve_consent")) {
        const source_id = app.pending_build_source_id orelse return .{ .blocked = "no pending build consent to approve" };
        const preview = app.pending_build_consent orelse return .{ .blocked = "no pending build consent to approve" };
        switch (app.runtime.checkCommand(.{ .id = source_id, .source = .command_palette })) {
            .unknown_command => return .unknown_command,
            .blocked => |message| return .{ .blocked = message },
            .allowed, .confirmation_required => {},
        }

        const spec = externalCommandPreviewById(app, source_id) orelse return .{ .blocked = "pending consent is not an executable command" };
        const cwd = spec.command.cwd orelse app.workspace.root_path;
        if (!permissions.allowsWorkspacePath(preview.consent.fs_policy, app.workspace.root_path, cwd)) {
            return .{ .blocked = "approved command cwd is outside the permitted workspace boundary" };
        }
        try app.execution_queue.enqueueSpec(source_id, spec, preview.consent);
        app.clearPendingBuildConsent();
        return .{ .completed = "approved command queued" };
    }

    if (std.mem.eql(u8, definition.id, "task.preview_next")) {
        return switch (try executor.previewLatest(&app.execution_queue, &app.process_console)) {
            .rendered => .{ .completed = "launch plan rendered" },
            .empty_queue => .{ .blocked = "no approved command in execution queue" },
        };
    }

    if (std.mem.eql(u8, definition.id, "task.run_next")) {
        return switch (try executor.runNext(&app.execution_queue, &app.process_console, .{
            .workspace_root = app.workspace.root_path,
            .io = app.io,
            .environ = app.environ,
        })) {
            .ran => |exit_code| if (exit_code == 0)
                .{ .completed = "approved command finished" }
            else
                .{ .completed = "approved command finished with non-zero exit" },
            .empty_queue => .{ .blocked = "no approved command in execution queue" },
            .blocked => |message| .{ .blocked = message },
            .failed => |message| .{ .blocked = message },
        };
    }

    if (std.mem.eql(u8, definition.id, "task.history")) {
        return switch (try executor.renderHistory(&app.execution_queue, &app.process_console)) {
            .rendered => .{ .completed = "task history rendered" },
            .empty_history => .{ .blocked = "no approved command history" },
        };
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
    const spec = externalCommandPreviewById(app, request.id) orelse return;
    var preview = try build_consent.makePreview(app.allocator, spec, app.runtime.trust_state);
    errdefer preview.deinit();
    try app.setPendingBuildConsent(request.id, preview);
}

fn externalCommandPreviewById(app: *app_mod.App, id: []const u8) ?process.SpawnSpec {
    if (std.mem.eql(u8, id, "zig.build")) return zigCommand(app, .build);
    if (std.mem.eql(u8, id, "zig.test")) return zigCommand(app, .test_step);
    if (std.mem.eql(u8, id, "zig.fmt")) return zigCommand(app, .fmt);
    return null;
}

fn hasWorkspaceAudit(collection: *const security_findings.Collection) bool {
    for (collection.items.items) |item| {
        if (item.category == .workspace_trust) return true;
    }
    return false;
}

fn applyPostureGuard(app: *app_mod.App) void {
    const summary = posture.summarize(&app.security_findings, app.runtime.trust_state);
    if (summary.critical > 0) {
        app.runtime.trust_state = .locked_down;
        return;
    }
    if (summary.high > 0) {
        app.runtime.trust_state = switch (app.runtime.trust_state) {
            .trusted, .hardened => .paranoid,
            else => app.runtime.trust_state,
        };
    }
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

test "hardened consent approval queues command" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();
    app.runtime.trust_state = .hardened;

    const blocked = try dispatch(&app, .{ .id = "zig.test" });
    try std.testing.expect(std.meta.activeTag(blocked) == .blocked);
    try std.testing.expect(app.pending_build_consent != null);

    const approved = try dispatch(&app, .{ .id = "security.approve_consent" });
    try std.testing.expect(std.meta.activeTag(approved) == .completed);
    try std.testing.expectEqual(@as(usize, 1), app.execution_queue.queuedCount());
    try std.testing.expect(app.pending_build_consent == null);
}

test "task history command renders recorded command results" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();

    try app.execution_queue.enqueueSpec("zig.build", .{
        .command = .{
            .executable = "zig",
            .args = &.{"build"},
            .cwd = ".",
        },
    }, .{
        .command = "zig build",
        .cwd = ".",
        .env_policy = .allowlist,
        .fs_policy = .workspace_only,
        .network_policy = .deny,
        .output_sanitized = true,
    });
    var ticket = app.execution_queue.takeNextQueued() orelse return error.ExpectedTicket;
    defer ticket.deinit();
    try app.execution_queue.recordHistory(&ticket, .finished, 0, 2, 0);

    const result = try dispatch(&app, .{ .id = "task.history" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expect(app.process_console.lines.items.len > 0);
}

test "critical security scan locks workspace down" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();
    app.runtime.trust_state = .trusted;
    _ = try app.documents.createScratch("critical.zig", "const p = @ptrFromInt(0xdeadbeef);\n");

    const result = try dispatch(&app, .{ .id = "security.scan_current" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expectEqual(@import("../security/trust.zig").TrustState.locked_down, app.runtime.trust_state);
}
