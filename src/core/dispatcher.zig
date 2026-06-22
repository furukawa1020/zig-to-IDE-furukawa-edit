const std = @import("std");
const app_mod = @import("app.zig");
const build_commands = @import("../build/commands.zig");
const build_consent = @import("../security/build_consent.zig");
const command = @import("command.zig");
const navigation = @import("../editor/navigation.zig");
const editor_save = @import("../editor/save.zig");
const process = @import("../platform/process.zig");
const executor = @import("../tasks/executor.zig");
const task_registry = @import("../tasks/registry.zig");
const git_status = @import("../git/status.zig");
const diagnostic_model = @import("../diagnostics/model.zig");
const zig_output = @import("../diagnostics/zig_output.zig");
const file_finder = @import("../search/file_finder.zig");
const workspace_search = @import("../search/workspace_search.zig");
const permissions = @import("../security/permissions.zig");
const posture = @import("../security/posture.zig");
const security_findings = @import("../security/findings.zig");
const types = @import("types.zig");
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
        const doc = app.documents.active() orelse return .no_active_document;
        _ = doc.path orelse return .{ .blocked = "active document has no file path" };
        if (try runSaveSafetyCheck(app)) |message| return .{ .blocked = message };
        try app.documents.saveActive(.{});
        return .{ .completed = "saved" };
    }

    if (std.mem.eql(u8, definition.id, "file.new")) {
        const argument = request.argument orelse return .{ .unsupported = "file.new requires a workspace-relative path" };
        const relative = std.mem.trim(u8, argument, " \t\r\n");
        if (validateNewWorkspaceFilePath(relative)) |message| return .{ .blocked = message };

        const path = try workspacePath(app, relative);
        defer app.allocator.free(path);
        if (!permissions.allowsWrite(.workspace_only, app.workspace.root_path, path)) {
            return .{ .blocked = "new file path is outside workspace" };
        }

        if (std.fs.path.dirname(path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, parent);
        }
        const exists = exists: {
            _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :exists false,
                else => return err,
            };
            break :exists true;
        };
        if (exists) return .{ .blocked = "file already exists" };

        try editor_save.saveBytes(app.allocator, path, "", .{});
        try app.workspace.refresh();
        _ = try app.documents.openFile(path);
        app.focus = .editor;
        return .{ .completed = "created file" };
    }

    if (std.mem.eql(u8, definition.id, "file.open")) {
        const argument = request.argument orelse return .{ .unsupported = "file.open requires a path argument" };
        const path = try workspacePath(app, argument);
        defer app.allocator.free(path);
        _ = try app.documents.openFile(path);
        app.focus = .editor;
        return .{ .completed = "opened file" };
    }

    if (std.mem.eql(u8, definition.id, "workspace.previous_file")) {
        app.moveFileCursor(-1);
        return .{ .completed = "selected previous file-tree entry" };
    }

    if (std.mem.eql(u8, definition.id, "workspace.next_file")) {
        app.moveFileCursor(1);
        return .{ .completed = "selected next file-tree entry" };
    }

    if (std.mem.eql(u8, definition.id, "workspace.open_selected")) {
        if (try app.openSelectedWorkspaceEntry()) {
            return .{ .completed = "opened selected file" };
        }
        return .{ .blocked = "selected workspace entry is not a file" };
    }

    if (std.mem.eql(u8, definition.id, "workspace.find_file")) {
        const query = request.argument orelse return .{ .unsupported = "workspace.find_file requires a query argument" };
        try renderFileFinder(app, query);
        return .{ .completed = "file search complete" };
    }

    if (std.mem.eql(u8, definition.id, "workspace.search")) {
        const query = request.argument orelse return .{ .unsupported = "workspace.search requires a query argument" };
        try renderWorkspaceSearch(app, query);
        return .{ .completed = "workspace search complete" };
    }

    if (std.mem.eql(u8, definition.id, "diagnostics.next")) {
        if (app.diagnostics.items.items.len == 0) return .{ .blocked = "no diagnostics available" };
        const index = findNextDiagnosticIndex(app) orelse return .{ .blocked = "no diagnostics available" };
        if (!try openDiagnostic(app, app.diagnostics.items.items[index])) {
            return .{ .blocked = "diagnostic target could not be opened" };
        }
        return .{ .completed = "jumped to diagnostic" };
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
        try syncDiagnosticsFromSecurity(app);
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
        try syncDiagnosticsFromSecurity(app);
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

    if (std.mem.eql(u8, definition.id, "task.run")) {
        const name = request.argument orelse "run";
        if (try queueConfiguredTask(app, name)) |message| return .{ .blocked = message };
        return .{ .completed = "task queued" };
    }

    if (std.mem.eql(u8, definition.id, "task.preview_next")) {
        return switch (try executor.previewLatest(&app.execution_queue, &app.process_console)) {
            .rendered => .{ .completed = "launch plan rendered" },
            .empty_queue => .{ .blocked = "no approved command in execution queue" },
        };
    }

    if (std.mem.eql(u8, definition.id, "task.run_next")) {
        const run_result = try executor.runNext(&app.execution_queue, &app.process_console, .{
            .workspace_root = app.workspace.root_path,
            .io = app.io,
            .environ = app.environ,
        });
        try syncDiagnosticsFromConsole(app);
        return switch (run_result) {
            .ran => |exit_code| if (exit_code == 0) .{ .completed = "approved command finished" } else .{ .completed = "approved command finished with non-zero exit" },
            .empty_queue => .{ .blocked = "no approved command in execution queue" },
            .blocked => |message| .{ .blocked = message },
            .failed => |message| .{ .blocked = message },
            .timed_out => .{ .blocked = "approved command timed out" },
            .output_limited => .{ .blocked = "approved command exceeded output limit" },
        };
    }

    if (std.mem.eql(u8, definition.id, "task.history")) {
        return switch (try executor.renderHistory(&app.execution_queue, &app.process_console)) {
            .rendered => .{ .completed = "task history rendered" },
            .empty_history => .{ .blocked = "no approved command history" },
        };
    }

    if (std.mem.eql(u8, definition.id, "git.status")) {
        var audit = try git_status.auditRepository(app.allocator, app.workspace.root_path, .{});
        defer audit.deinit();

        app.security_findings.clearCategory(.git_trust);
        for (audit.items.items) |item| {
            try app.security_findings.appendFinding(item);
        }
        try renderGitAudit(app, &audit);
        try syncDiagnosticsFromSecurity(app);
        applyPostureGuard(app);
        return .{ .completed = "git metadata audit complete" };
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

fn validateNewWorkspaceFilePath(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "new file path is empty";
    if (std.fs.path.isAbsolute(path)) return "new file path must be relative to workspace";
    if (path.len >= 2 and path[1] == ':') return "new file path must not use a drive prefix";
    if (path[0] == '/' or path[0] == '\\') return "new file path must not start at filesystem root";
    if (path[path.len - 1] == '/' or path[path.len - 1] == '\\') return "new file path must include a file name";

    var start: usize = 0;
    while (start <= path.len) {
        var end = start;
        while (end < path.len and path[end] != '/' and path[end] != '\\') : (end += 1) {}
        const segment = path[start..end];
        if (std.mem.eql(u8, segment, "..")) return "new file path must not contain parent traversal";
        if (std.ascii.eqlIgnoreCase(segment, ".git")) return "new file path must not write inside .git";
        if (std.ascii.eqlIgnoreCase(segment, ".tools")) return "new file path must not write inside .tools";
        if (std.ascii.eqlIgnoreCase(segment, ".zig-cache") or std.ascii.eqlIgnoreCase(segment, ".zig-global-cache")) {
            return "new file path must not write inside Zig cache directories";
        }
        if (std.ascii.eqlIgnoreCase(segment, "zig-out")) return "new file path must not write inside zig-out";
        if (end == path.len) break;
        start = end + 1;
    }
    return null;
}

fn queueConfiguredTask(app: *app_mod.App, name: []const u8) !?[]const u8 {
    var registry = try task_registry.loadProjectTasks(app.allocator, app.workspace.root_path);
    defer registry.deinit();

    for (registry.diagnostics.items) |message| {
        try appendConsole(app, .stderr, "task config: {s}\n", .{message});
    }

    const task = registry.find(name) orelse {
        try renderTaskList(app, &registry, name);
        return "task not found";
    };

    var plan = try task_registry.makeSpawnPlan(app.allocator, app.workspace.root_path, task);
    defer plan.deinit();

    if (!permissions.allowsWorkspacePath(plan.consent.fs_policy, app.workspace.root_path, plan.consent.cwd)) {
        try appendConsole(app, .stderr, "task blocked: cwd outside workspace: {s}\n", .{plan.consent.cwd});
        return "task cwd is outside workspace";
    }

    try app.execution_queue.enqueueSpec("task.run", plan.spec, plan.consent);
    try appendConsole(app, .stdout, "queued task: {s}\n{s}\n", .{ task.name, plan.command_display });
    return null;
}

fn renderTaskList(app: *app_mod.App, registry: *const task_registry.Registry, missing: []const u8) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.print("task not found: {s}\n", .{missing});
    try writer.writeAll("available tasks\n");
    for (registry.tasks.items) |task| {
        try writer.print("- {s}\n", .{task.name});
    }
    try app.process_console.appendBytes(.stderr, text.written());
}

fn syncDiagnosticsFromConsole(app: *app_mod.App) !void {
    for (app.process_console.lines.items) |line| {
        if (zig_output.parseLine(line.text)) |parsed| {
            try app.diagnostics.append(zig_output.toDiagnostic(parsed));
        }
    }
}

fn runSaveSafetyCheck(app: *app_mod.App) !?[]const u8 {
    const doc = app.documents.active() orelse return null;
    const path = doc.path orelse return null;
    if (!std.mem.endsWith(u8, path, ".zig")) return null;

    var scan = try zig_scanner.scanSource(app.allocator, doc.text.bytes, .{ .path = path });
    defer scan.deinit();

    app.security_findings.clearPath(path);
    for (scan.items.items) |item| {
        try app.security_findings.appendFinding(item);
    }
    try syncDiagnosticsFromSecurity(app);
    try renderSaveSafetyCheck(app, path, &scan);
    applyPostureGuard(app);

    if (scan.countRiskAtLeast(.critical) > 0) {
        return "save blocked by critical Zig security finding";
    }
    return null;
}

fn renderSaveSafetyCheck(app: *app_mod.App, path: []const u8, scan: *const security_findings.Collection) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.print("save safety check: {s} -> {d} findings\n", .{ path, scan.items.items.len });
    for (scan.items.items, 0..) |item, index| {
        if (index >= 8) {
            try writer.print("... {d} more save findings\n", .{scan.items.items.len - index});
            break;
        }
        try writer.print("{s}/{s} {d}:{d} {s}\n", .{
            @tagName(item.risk),
            @tagName(item.category),
            item.line + 1,
            item.column + 1,
            item.message,
        });
    }
    try app.process_console.appendBytes(.stdout, text.written());
}

fn syncDiagnosticsFromSecurity(app: *app_mod.App) !void {
    app.diagnostics.clear();
    for (app.security_findings.items.items) |item| {
        try app.diagnostics.append(.{
            .source = .internal,
            .severity = severityForRisk(item.risk),
            .path = item.path,
            .range = types.Range.empty(.{
                .line = item.line,
                .column = item.column,
                .byte_offset = 0,
            }),
            .message = item.message,
        });
    }
}

fn severityForRisk(risk: security_findings.Risk) types.Severity {
    return switch (risk) {
        .critical, .high => .err,
        .medium => .warning,
        .low, .info => .info,
    };
}

fn findNextDiagnosticIndex(app: *app_mod.App) ?usize {
    if (app.diagnostics.items.items.len == 0) return null;
    const active = app.documents.active();
    const active_path = if (active) |doc| doc.path else null;
    const active_position = if (active) |doc| doc.cursor.position else types.Position.start();

    if (active_path) |path| {
        var fallback: ?usize = null;
        for (app.diagnostics.items.items, 0..) |item, index| {
            if (!pathMatchesDiagnostic(path, item.path)) continue;
            if (fallback == null) fallback = index;
            if (positionAfter(item.range.start, active_position)) return index;
        }
        if (fallback) |index| return index;
    }

    return 0;
}

fn openDiagnostic(app: *app_mod.App, diagnostic: diagnostic_model.Diagnostic) !bool {
    const active = app.documents.active();
    if (active) |doc| {
        if (doc.path) |path| {
            if (pathMatchesDiagnostic(path, diagnostic.path)) {
                return setDiagnosticCursor(doc, diagnostic);
            }
        }
    }

    const path = try workspacePath(app, diagnostic.path);
    defer app.allocator.free(path);
    const index = app.documents.openFile(path) catch return false;
    app.focus = .editor;
    return setDiagnosticCursor(&app.documents.documents.items[index], diagnostic);
}

fn setDiagnosticCursor(doc: *@import("../editor/document.zig").Document, diagnostic: diagnostic_model.Diagnostic) bool {
    const offset = doc.text.lineColumnToOffset(diagnostic.range.start.line, diagnostic.range.start.column) catch return false;
    const position = doc.positionFromOffset(offset) catch return false;
    navigation.setCursor(doc, position);
    return true;
}

fn positionAfter(left: types.Position, right: types.Position) bool {
    if (left.line != right.line) return left.line > right.line;
    return left.column > right.column;
}

fn pathMatchesDiagnostic(document_path: []const u8, diagnostic_path: []const u8) bool {
    if (std.mem.eql(u8, document_path, diagnostic_path)) return true;
    if (!std.mem.endsWith(u8, document_path, diagnostic_path)) return false;
    const prefix_len = document_path.len - diagnostic_path.len;
    if (prefix_len == 0) return true;
    const boundary = document_path[prefix_len - 1];
    return boundary == '/' or boundary == '\\';
}

fn renderFileFinder(app: *app_mod.App, query: []const u8) !void {
    const matches = try file_finder.find(app.allocator, &app.workspace, query, 24);
    defer app.allocator.free(matches);

    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.print("find file: \"{s}\" -> {d} matches\n", .{ query, matches.len });
    for (matches, 0..) |match, index| {
        if (index >= 20) {
            try writer.print("... {d} more file matches\n", .{matches.len - index});
            break;
        }
        try writer.print("{d}. {s} [{s}] score={d}\n", .{ index + 1, match.path, @tagName(match.language), match.score });
    }
    try app.process_console.appendBytes(.stdout, text.written());
}

fn renderWorkspaceSearch(app: *app_mod.App, query: []const u8) !void {
    const results = try workspace_search.search(app.allocator, &app.workspace, query, .{
        .max_file_bytes = 512 * 1024,
        .max_results = 256,
    });
    defer {
        for (results) |*item| item.deinit(app.allocator);
        app.allocator.free(results);
    }

    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.print("workspace search: \"{s}\" -> {d} matches\n", .{ query, results.len });
    for (results, 0..) |item, index| {
        if (index >= 20) {
            try writer.print("... {d} more search matches\n", .{results.len - index});
            break;
        }
        try writer.print("{s}:{d}:{d}: {s}\n", .{ item.path, item.line + 1, item.column + 1, item.preview });
    }
    try app.process_console.appendBytes(.stdout, text.written());
}

fn renderGitAudit(app: *app_mod.App, audit: *const security_findings.Collection) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.print("git metadata audit: {d} findings\n", .{audit.items.items.len});
    for (audit.items.items, 0..) |item, index| {
        if (index >= 12) {
            try writer.print("... {d} more git findings\n", .{audit.items.items.len - index});
            break;
        }
        try writer.print("{s}/{s} {s}:{d}:{d} {s}\n", .{
            @tagName(item.risk),
            @tagName(item.category),
            item.path,
            item.line + 1,
            item.column + 1,
            item.message,
        });
    }
    try app.process_console.appendBytes(.stdout, text.written());
}

fn appendConsole(app: *app_mod.App, stream: @import("../tasks/console.zig").Stream, comptime fmt: []const u8, args: anytype) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    try text.writer.print(fmt, args);
    try app.process_console.appendBytes(stream, text.written());
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

test "task run queues default project task when trusted" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();
    app.runtime.trust_state = .trusted;

    const result = try dispatch(&app, .{ .id = "task.run", .argument = "run" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expectEqual(@as(usize, 1), app.execution_queue.queuedCount());
}

test "console diagnostics sync parses Zig compiler output" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();

    try app.process_console.appendBytes(.stderr, "src/main.zig:2:3: error: nope\n");
    try syncDiagnosticsFromConsole(&app);

    try std.testing.expectEqual(@as(usize, 1), app.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("src/main.zig", app.diagnostics.items.items[0].path);
}

test "open selected workspace file activates editor focus" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "workspace.open_selected" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expect(app.documents.active() != null);
    try std.testing.expectEqual(app_mod.Focus.editor, app.focus);
}

test "workspace find file command renders matches" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "workspace.find_file", .argument = "dispatcher" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expect(app.process_console.lines.items.len > 0);
}

test "workspace search command renders literal matches" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "workspace.search", .argument = "workspace.search" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expect(app.process_console.lines.items.len > 0);
}

test "file new creates a workspace file and opens it" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "file.new", .argument = "src/new_file.zig" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    _ = try tmp.dir.statFile(std.Options.debug_io, "src/new_file.zig", .{});
    const doc = app.documents.active() orelse return error.ExpectedDocument;
    try std.testing.expect(doc.path != null);
    try std.testing.expect(std.mem.endsWith(u8, doc.path.?, "src\\new_file.zig") or std.mem.endsWith(u8, doc.path.?, "src/new_file.zig"));
}

test "file new rejects workspace escape paths" {
    try std.testing.expect(validateNewWorkspaceFilePath("../outside.zig") != null);
    try std.testing.expect(validateNewWorkspaceFilePath(".git/hooks/pre-commit") != null);
    try std.testing.expect(validateNewWorkspaceFilePath("zig-out/generated.zig") != null);
}

test "save blocks critical Zig security findings" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();
    _ = try app.documents.createScratch("danger.zig", "const p = @ptrFromInt(0xdeadbeef);\n");

    const result = try dispatch(&app, .{ .id = "file.save" });
    try std.testing.expect(std.meta.activeTag(result) == .blocked);
    try std.testing.expect(app.diagnostics.items.items.len > 0);
}

test "diagnostics next jumps within active document" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();
    _ = try app.documents.createScratch("danger.zig", "const p = @ptrFromInt(0xdeadbeef);\n");

    const scan = try dispatch(&app, .{ .id = "security.scan_current" });
    try std.testing.expect(std.meta.activeTag(scan) == .completed);

    const jump = try dispatch(&app, .{ .id = "diagnostics.next" });
    try std.testing.expect(std.meta.activeTag(jump) == .completed);
    const doc = app.documents.active() orelse return error.ExpectedDocument;
    try std.testing.expectEqual(@as(usize, 0), doc.cursor.position.line);
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
