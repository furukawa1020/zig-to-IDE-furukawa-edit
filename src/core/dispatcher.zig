const std = @import("std");
const app_mod = @import("app.zig");
const audit_chain = @import("../security/audit_chain.zig");
const build_commands = @import("../build/commands.zig");
const build_consent = @import("../security/build_consent.zig");
const command = @import("command.zig");
const navigation = @import("../editor/navigation.zig");
const editor_save = @import("../editor/save.zig");
const process = @import("../platform/process.zig");
const executor = @import("../tasks/executor.zig");
const task_registry = @import("../tasks/registry.zig");
const git_repository = @import("../git/repository.zig");
const git_status = @import("../git/status.zig");
const github_client = @import("../github/client.zig");
const diagnostic_model = @import("../diagnostics/model.zig");
const zig_output = @import("../diagnostics/zig_output.zig");
const document_mod = @import("../editor/document.zig");
const extension_registry = @import("../extensions/registry.zig");
const file_finder = @import("../search/file_finder.zig");
const workspace_search = @import("../search/workspace_search.zig");
const workspace_replace = @import("../search/workspace_replace.zig");
const permissions = @import("../security/permissions.zig");
const posture = @import("../security/posture.zig");
const security_findings = @import("../security/findings.zig");
const types = @import("types.zig");
const workspace_audit = @import("../security/workspace_audit.zig");
const workspace_io = @import("../security/workspace_io.zig");
const modes = @import("../language/modes.zig");
const package_trust = @import("../security/package_trust.zig");
const polyglot_scanner = @import("../security/polyglot_scanner.zig");
const text_integrity = @import("../security/text_integrity.zig");
const zig_scanner = @import("../security/zig_scanner.zig");
const lsp_launch_plan = @import("../lsp/launch_plan.zig");
const lsp_manager = @import("../lsp/manager.zig");
const lsp_responses = @import("../lsp/responses.zig");
const lsp_session = @import("../lsp/session.zig");
const lsp_transport = @import("../lsp/transport.zig");

pub const LspPumpResult = struct {
    frames: usize = 0,
    stderr_bytes: usize = 0,
};

const max_automatic_lsp_sync_bytes: usize = 4 * 1024 * 1024;

fn commentToggleMessage(result: document_mod.CommentToggleResult) []const u8 {
    return switch (result) {
        .line_commented => "commented lines",
        .line_uncommented => "uncommented lines",
        .block_commented => "commented block",
        .block_uncommented => "uncommented block",
    };
}

pub const Result = union(enum) {
    completed: []const u8,
    blocked: []const u8,
    unknown_command,
    no_active_document,
    external_command: process.SpawnSpec,
    unsupported: []const u8,
};

pub fn dispatch(app: *app_mod.App, request: command.Request) !Result {
    if (std.mem.eql(u8, request.id, "lsp.ensure_active")) {
        return try ensureActiveLsp(app, request.source);
    }

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

    if (std.mem.eql(u8, definition.id, "editor.indent")) {
        const doc = app.documents.active() orelse return .no_active_document;
        const offset = doc.cursor.position.byte_offset;
        _ = try doc.indentLines(offset, offset, "    ");
        return .{ .completed = "indented line" };
    }

    if (std.mem.eql(u8, definition.id, "editor.outdent")) {
        const doc = app.documents.active() orelse return .no_active_document;
        const offset = doc.cursor.position.byte_offset;
        const result = try doc.outdentLines(offset, offset, 4);
        if (!result.changed) return .{ .blocked = "line is already fully outdented" };
        return .{ .completed = "outdented line" };
    }

    if (std.mem.eql(u8, definition.id, "editor.delete_line")) {
        const doc = app.documents.active() orelse return .no_active_document;
        if (try doc.deleteLine(doc.cursor.position.line)) return .{ .completed = "deleted line" };
        return .{ .blocked = "no line to delete" };
    }

    if (std.mem.eql(u8, definition.id, "editor.duplicate_line")) {
        const doc = app.documents.active() orelse return .no_active_document;
        if (try doc.duplicateLine(doc.cursor.position.line)) return .{ .completed = "duplicated line" };
        return .{ .blocked = "no line to duplicate" };
    }

    if (std.mem.eql(u8, definition.id, "editor.move_line_up")) {
        const doc = app.documents.active() orelse return .no_active_document;
        if (try doc.moveLineUp(doc.cursor.position.line)) return .{ .completed = "moved line up" };
        return .{ .blocked = "line is already at top" };
    }

    if (std.mem.eql(u8, definition.id, "editor.move_line_down")) {
        const doc = app.documents.active() orelse return .no_active_document;
        if (try doc.moveLineDown(doc.cursor.position.line)) return .{ .completed = "moved line down" };
        return .{ .blocked = "line is already at bottom" };
    }

    if (std.mem.eql(u8, definition.id, "editor.toggle_comment")) {
        const doc = app.documents.active() orelse return .no_active_document;
        const offset = doc.cursor.position.byte_offset;
        const result = (try doc.toggleComment(offset, offset)) orelse return .{ .blocked = "active language has no comment syntax" };
        return .{ .completed = commentToggleMessage(result) };
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
        try saveDocumentInWorkspace(app, doc, .{});
        _ = try notifyActiveDocumentSavedToRunningLsp(app);
        return .{ .completed = "saved" };
    }

    if (std.mem.eql(u8, definition.id, "file.save_all")) {
        const dirty_count = app.documents.dirtyCount();
        if (dirty_count == 0) return .{ .completed = "all files already saved" };

        for (app.documents.documents.items) |*doc| {
            if (!doc.dirty) continue;
            _ = doc.path orelse return .{ .blocked = "dirty document has no file path" };
            if (try runDocumentSaveSafetyCheck(app, doc)) |message| return .{ .blocked = message };
        }

        var saved_count: usize = 0;
        for (app.documents.documents.items) |*doc| {
            if (!doc.dirty) continue;
            try saveDocumentInWorkspace(app, doc, .{});
            _ = try notifyDocumentSavedToRunningLsp(app, doc);
            saved_count += 1;
        }

        try appendConsole(app, .stdout, "saved all: {d} file(s)\n", .{saved_count});
        return .{ .completed = "saved all" };
    }

    if (std.mem.eql(u8, definition.id, "file.new")) {
        const argument = request.argument orelse return .{ .unsupported = "file.new requires a workspace-relative path" };
        const relative = std.mem.trim(u8, argument, " \t\r\n");
        if (validateNewWorkspaceFilePath(relative)) |message| return .{ .blocked = message };

        var new_file = try workspace_io.openFileCapabilityCreateParents(app.workspace.root_path, relative);
        defer new_file.close();
        editor_save.createBytesInDirExclusive(app.allocator, new_file.parent, new_file.name, "") catch |err| switch (err) {
            error.PathAlreadyExists => return .{ .blocked = "file already exists" },
            else => return err,
        };
        try app.workspace.refresh();
        _ = try app.openWorkspaceFile(relative);
        app.focus = .editor;
        return .{ .completed = "created file" };
    }

    if (std.mem.eql(u8, definition.id, "file.new_folder")) {
        const argument = request.argument orelse return .{ .unsupported = "file.new_folder requires a workspace-relative path" };
        const relative = std.mem.trim(u8, argument, " \t\r\n");
        if (validateWorkspaceMutationPath(relative, .directory)) |message| return .{ .blocked = message };

        workspace_io.createDirectoryPath(app.workspace.root_path, relative) catch |err| switch (err) {
            error.PathAlreadyExists => return .{ .blocked = "file or folder already exists at destination" },
            else => return err,
        };
        try app.workspace.refresh();
        return .{ .completed = "created folder" };
    }

    if (std.mem.eql(u8, definition.id, "file.rename")) {
        const argument = request.argument orelse return .{ .unsupported = "file.rename requires old_path=>new_path" };
        const pair = parsePathMutation(argument) orelse return .{ .blocked = "rename must use old_path=>new_path" };
        if (validateWorkspaceMutationPath(pair.source, .either)) |message| return .{ .blocked = message };
        if (validateWorkspaceMutationPath(pair.destination, .either)) |message| return .{ .blocked = message };
        if (workspaceRelativePathEqual(pair.source, pair.destination)) return .{ .blocked = "rename source and destination are identical" };

        const source = try workspace_io.absolutePathAlloc(app.allocator, app.workspace.root_path, pair.source);
        defer app.allocator.free(source);
        const destination = try workspace_io.absolutePathAlloc(app.allocator, app.workspace.root_path, pair.destination);
        defer app.allocator.free(destination);
        _ = workspace_io.renamePathPreserve(app.workspace.root_path, pair.source, pair.destination) catch |err| switch (err) {
            error.PathAlreadyExists => return .{ .blocked = "rename destination already exists" },
            error.FileNotFound, error.NotDir => return .{ .blocked = "rename source or destination folder does not exist" },
            error.UnsupportedWorkspacePath => return .{ .blocked = "only regular files and folders can be renamed" },
            else => return err,
        };
        const updated_documents = try app.documents.renamePathPrefix(source, destination);
        try app.workspace.refresh();
        try appendConsole(app, .stdout, "renamed: {s} -> {s} (open editors updated: {d})\n", .{ pair.source, pair.destination, updated_documents });
        return .{ .completed = "renamed workspace path" };
    }

    if (std.mem.eql(u8, definition.id, "file.delete")) {
        const argument = request.argument orelse return .{ .unsupported = "file.delete requires path=>DELETE" };
        const pair = parsePathMutation(argument) orelse return .{ .blocked = "delete must use path=>DELETE" };
        if (!std.mem.eql(u8, pair.destination, "DELETE")) return .{ .blocked = "type DELETE exactly to confirm deletion" };
        if (validateWorkspaceMutationPath(pair.source, .either)) |message| return .{ .blocked = message };

        const path = try workspace_io.absolutePathAlloc(app.allocator, app.workspace.root_path, pair.source);
        defer app.allocator.free(path);
        if (app.documents.hasDirtyPathPrefix(path)) {
            return .{ .blocked = "save or close dirty editors under this path before deleting" };
        }

        _ = workspace_io.deleteFileOrEmptyDirectory(app.workspace.root_path, pair.source) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return .{ .blocked = "delete target does not exist" },
            error.DirNotEmpty => return .{ .blocked = "folder is not empty; recursive deletion is intentionally disabled" },
            error.UnsupportedWorkspacePath => return .{ .blocked = "only regular files and empty folders can be deleted" },
            else => return err,
        };
        const closed_documents = try app.documents.closePathPrefix(path, .deny_dirty);
        try app.workspace.refresh();
        try appendConsole(app, .stdout, "deleted: {s} (closed editors: {d})\n", .{ pair.source, closed_documents });
        return .{ .completed = "deleted workspace path" };
    }

    if (std.mem.eql(u8, definition.id, "file.open")) {
        const argument = request.argument orelse return .{ .unsupported = "file.open requires a path argument" };
        const relative = if (std.fs.path.isAbsolute(argument))
            try workspace_io.relativeFilePath(app.workspace.root_path, argument)
        else
            argument;
        _ = try app.openWorkspaceFile(relative);
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

    if (std.mem.eql(u8, definition.id, "workspace.replace")) {
        const argument = request.argument orelse return .{ .unsupported = "workspace.replace requires search=>replacement" };
        const replace_request = workspace_replace.parseQuery(argument) orelse return .{ .unsupported = "workspace.replace requires search=>replacement" };
        try renderWorkspaceReplacePreview(app, replace_request);
        return .{ .completed = "workspace replacement preview ready" };
    }

    if (std.mem.eql(u8, definition.id, "workspace.replace_apply")) {
        const argument = request.argument orelse return .{ .unsupported = "workspace.replace_apply requires token, options, and search=>replacement" };
        const parsed = workspace_replace.parseApplyArgument(argument) orelse return .{ .unsupported = "invalid workspace replacement confirmation" };
        return try applyWorkspaceReplacement(app, parsed);
    }

    if (std.mem.eql(u8, definition.id, "workspace.refresh")) {
        try app.workspace.refresh();
        return .{ .completed = "workspace explorer refreshed" };
    }

    if (std.mem.eql(u8, definition.id, "workspace.language_report")) {
        try renderWorkspaceLanguageReport(app);
        return .{ .completed = "workspace language report rendered" };
    }

    if (std.mem.eql(u8, definition.id, "diagnostics.next")) {
        if (app.diagnostics.items.items.len == 0) return .{ .blocked = "no diagnostics available" };
        const index = findNextDiagnosticIndex(app) orelse return .{ .blocked = "no diagnostics available" };
        if (!try openDiagnostic(app, app.diagnostics.items.items[index])) {
            return .{ .blocked = "diagnostic target could not be opened" };
        }
        return .{ .completed = "jumped to diagnostic" };
    }

    if (std.mem.eql(u8, definition.id, "lsp.plan")) {
        const doc = app.documents.active() orelse return .no_active_document;
        var plan = try lsp_launch_plan.forLanguage(app.allocator, doc.language);
        defer plan.deinit(app.allocator);
        const rendered = try lsp_launch_plan.render(app.allocator, plan);
        defer app.allocator.free(rendered);
        try app.process_console.appendBytes(.stdout, rendered);
        try app.process_console.appendBytes(.stdout, "\n");
        return .{ .completed = "LSP launch plan rendered" };
    }

    if (std.mem.eql(u8, definition.id, "lsp.status")) {
        try renderLspStatus(app);
        return .{ .completed = "LSP status rendered" };
    }

    if (std.mem.eql(u8, definition.id, "lsp.actions")) {
        try renderLspStatus(app);
        return .{ .completed = "LSP actions status rendered" };
    }

    if (std.mem.eql(u8, definition.id, "lsp.sync_current")) {
        return try syncCurrentDocumentToLsp(app);
    }

    if (std.mem.eql(u8, definition.id, "lsp.request_completion")) {
        return try requestCurrentPositionLsp(app, .completion, "completion");
    }

    if (std.mem.eql(u8, definition.id, "lsp.request_hover")) {
        return try requestCurrentPositionLsp(app, .hover, "hover");
    }

    if (std.mem.eql(u8, definition.id, "lsp.request_definition")) {
        return try requestCurrentPositionLsp(app, .definition, "definition");
    }

    if (std.mem.eql(u8, definition.id, "lsp.request_implementation")) {
        return try requestCurrentPositionLsp(app, .implementation, "implementation");
    }

    if (std.mem.eql(u8, definition.id, "lsp.request_type_definition")) {
        return try requestCurrentPositionLsp(app, .type_definition, "typeDefinition");
    }

    if (std.mem.eql(u8, definition.id, "lsp.request_references")) {
        return try requestCurrentPositionLsp(app, .references, "references");
    }

    if (std.mem.eql(u8, definition.id, "lsp.request_rename")) {
        const new_name = request.argument orelse return .{ .unsupported = "lsp.request_rename requires a new symbol name" };
        return try requestCurrentRenameLsp(app, new_name);
    }

    if (std.mem.eql(u8, definition.id, "editor.format_document") or std.mem.eql(u8, definition.id, "lsp.request_formatting")) {
        return try requestCurrentFormattingLsp(app);
    }

    if (std.mem.eql(u8, definition.id, "lsp.request_code_action")) {
        return try requestCurrentCodeActionsLsp(app);
    }

    if (std.mem.eql(u8, definition.id, "lsp.apply_workspace_edit")) {
        return try applyLastLspWorkspaceEdit(app);
    }

    if (std.mem.eql(u8, definition.id, "lsp.apply_code_action")) {
        const argument = request.argument orelse return .{ .unsupported = "lsp.apply_code_action requires a one-based action index" };
        const index = parseOneBasedIndex(argument) orelse return .{ .blocked = "code action index must be a positive integer" };
        return try applyLspCodeAction(app, index - 1);
    }

    if (std.mem.eql(u8, definition.id, "lsp.apply_first_code_action")) {
        return try applyFirstLspCodeAction(app);
    }

    if (std.mem.eql(u8, definition.id, "lsp.start")) {
        return try startLspTransport(app);
    }

    if (std.mem.eql(u8, definition.id, "lsp.stop")) {
        return try stopLspTransport(app);
    }

    if (std.mem.eql(u8, definition.id, "lsp.ingest_payload")) {
        const payload = request.argument orelse return .{ .unsupported = "lsp.ingest_payload requires a JSON-RPC payload argument" };
        return try ingestLspPayload(app, payload);
    }

    if (std.mem.eql(u8, definition.id, "lsp.drain")) {
        return try drainLspFrames(app);
    }

    if (std.mem.eql(u8, definition.id, "security.scan_current")) {
        const doc = app.documents.active() orelse return .no_active_document;
        const path = doc.path orelse "(scratch)";
        var scan = try scanDocumentSecurity(app.allocator, path, doc.language, doc.text.bytes);
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
        if (preview.intent.network and !permissions.allowsNetwork(preview.consent.network_policy)) {
            return .{ .blocked = "approved command intent requires network but consent denies network" };
        }
        if (preview.intent.mutating and preview.consent.fs_policy == .read_only_workspace) {
            return .{ .blocked = "approved command intent may write but consent is read-only" };
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

    if (std.mem.eql(u8, definition.id, "security.audit_log")) {
        try renderRunAuditLog(app);
        return .{ .completed = "run audit log rendered" };
    }

    if (std.mem.eql(u8, definition.id, "security.audit_verify")) {
        return try verifyRunAuditLog(app);
    }

    if (std.mem.eql(u8, definition.id, "git.overview") or std.mem.eql(u8, definition.id, "github.overview")) {
        var overview = try git_repository.inspect(app.allocator, &app.workspace, .{});
        defer overview.deinit();

        try renderGitOverview(app, &overview);
        return .{ .completed = "git overview complete" };
    }

    if (std.mem.eql(u8, definition.id, "git.diff_current")) {
        const doc = app.documents.active() orelse return .no_active_document;
        const path = doc.path orelse return .{ .blocked = "active document has no file path" };
        const preview = try git_repository.previewFileDiff(app.allocator, &app.workspace, path, .{});
        defer app.allocator.free(preview);
        try app.process_console.appendBytes(.stdout, preview);
        return .{ .completed = "git diff preview rendered" };
    }

    if (std.mem.eql(u8, definition.id, "github.fetch")) {
        return try fetchGitHubLive(app);
    }

    if (std.mem.eql(u8, definition.id, "github.issues")) {
        return try fetchGitHubIssues(app);
    }

    if (std.mem.eql(u8, definition.id, "github.actions.failures")) {
        return try fetchGitHubActionsFailureLog(app);
    }

    if (std.mem.eql(u8, definition.id, "github.pr.create_draft")) {
        return try createDraftGitHubPullRequest(app, request.argument);
    }

    if (std.mem.eql(u8, definition.id, "view.extensions") or std.mem.eql(u8, definition.id, "extensions.scan")) {
        var registry = try extension_registry.Registry.scan(app.allocator, &app.workspace, .{});
        defer registry.deinit();
        try renderExtensionRegistry(app, &registry);
        return .{ .completed = "extension manifests scanned" };
    }

    if (std.mem.eql(u8, definition.id, "view.publish") or std.mem.eql(u8, definition.id, "release.checklist")) {
        try renderReleaseChecklist(app);
        return .{ .completed = "release checklist rendered" };
    }

    if (std.mem.eql(u8, definition.id, "release.assets")) {
        try renderReleaseAssets(app);
        return .{ .completed = "release assets hashed" };
    }

    if (std.mem.eql(u8, definition.id, "release.manifests")) {
        try renderReleaseManifests(app, request.argument);
        return .{ .completed = "release manifest drafts rendered" };
    }

    if (std.mem.eql(u8, definition.id, "release.bundle")) {
        const created = try renderReleaseBundle(app);
        return .{ .completed = if (created) "release bundle created" else "release bundle waiting for build artifacts" };
    }

    if (std.mem.eql(u8, definition.id, "release.verify")) {
        const verified = try renderReleaseVerification(app);
        return .{ .completed = if (verified) "release bundle verified" else "release bundle verification found issues" };
    }

    if (std.mem.eql(u8, definition.id, "release.preflight")) {
        const passed = try renderReleasePreflight(app, request.argument);
        return .{ .completed = if (passed) "release preflight passed" else "release preflight found blockers" };
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
    if (std.mem.eql(u8, id, "lsp.ensure_active")) return lspStartPreview(app);
    if (std.mem.eql(u8, id, "lsp.start")) return lspStartPreview(app);
    return null;
}

fn lspStartPreview(app: *app_mod.App) ?process.SpawnSpec {
    const doc = app.documents.active() orelse return null;
    return lsp_transport.spawnPreviewForLanguage(doc.language, app.workspace.root_path);
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

fn saveDocumentInWorkspace(
    app: *app_mod.App,
    doc: *document_mod.Document,
    strategy: editor_save.SaveStrategy,
) !void {
    const absolute_path = doc.path orelse return error.DocumentHasNoPath;
    const relative_path = try workspace_io.relativeFilePath(app.workspace.root_path, absolute_path);
    var capability = try workspace_io.openFileCapability(app.workspace.root_path, relative_path);
    defer capability.close();
    try editor_save.saveBytesInDir(app.allocator, capability.parent, capability.name, doc.text.bytes, strategy);
    doc.dirty = false;
}

const MutationPathKind = enum { file, directory, either };

const PathMutation = struct {
    source: []const u8,
    destination: []const u8,
};

fn validateNewWorkspaceFilePath(path: []const u8) ?[]const u8 {
    return validateWorkspaceMutationPath(path, .file);
}

fn validateWorkspaceMutationPath(path: []const u8, kind: MutationPathKind) ?[]const u8 {
    if (path.len == 0) return "workspace path is empty";
    if (std.fs.path.isAbsolute(path)) return "workspace path must be relative";
    if (path.len >= 2 and path[1] == ':') return "workspace path must not use a drive prefix";
    if (path[0] == '/' or path[0] == '\\') return "workspace path must not start at filesystem root";
    if (path[path.len - 1] == '/' or path[path.len - 1] == '\\') {
        return switch (kind) {
            .file => "new file path must include a file name",
            .directory, .either => "workspace path must not end with a separator",
        };
    }

    var start: usize = 0;
    while (start <= path.len) {
        var end = start;
        while (end < path.len and path[end] != '/' and path[end] != '\\') : (end += 1) {}
        const segment = path[start..end];
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) return "workspace path contains an empty or current-directory segment";
        if (std.mem.eql(u8, segment, "..")) return "workspace path must not contain parent traversal";
        if (std.ascii.eqlIgnoreCase(segment, ".git")) return "workspace path must not modify .git";
        if (std.ascii.eqlIgnoreCase(segment, ".tools")) return "workspace path must not modify .tools";
        if (std.ascii.eqlIgnoreCase(segment, ".zig-cache") or
            std.ascii.startsWithIgnoreCase(segment, ".zig-cache-") or
            std.ascii.eqlIgnoreCase(segment, ".zig-global-cache") or
            std.ascii.startsWithIgnoreCase(segment, ".zig-global-cache-"))
        {
            return "workspace path must not modify Zig cache directories";
        }
        if (std.ascii.eqlIgnoreCase(segment, "zig-out") or std.ascii.startsWithIgnoreCase(segment, "zig-out-")) {
            return "workspace path must not modify zig-out directories";
        }
        if (end == path.len) break;
        start = end + 1;
    }
    return null;
}

fn parsePathMutation(argument: []const u8) ?PathMutation {
    const arrow = std.mem.indexOf(u8, argument, "=>") orelse return null;
    const source = std.mem.trim(u8, argument[0..arrow], " \t\r\n");
    const destination = std.mem.trim(u8, argument[arrow + 2 ..], " \t\r\n");
    if (source.len == 0 or destination.len == 0) return null;
    return .{ .source = source, .destination = destination };
}

fn workspaceRelativePathEqual(left: []const u8, right: []const u8) bool {
    if (std.fs.path.sep == '\\') return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
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

fn renderRunAuditLog(app: *app_mod.App) !void {
    const path = try std.fs.path.join(app.allocator, &.{ app.workspace.root_path, ".zide", "audit", "run-history.jsonl" });
    defer app.allocator.free(path);

    var file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{
        .mode = .read_only,
        .allow_directory = false,
        .lock = .shared,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try appendConsole(app, .stdout, "run audit log\npath: .zide/audit/run-history.jsonl\nstatus: no persisted launch audit yet\n", .{});
            return;
        },
        else => return err,
    };
    defer file.close(std.Options.debug_io);

    const length = try file.length(std.Options.debug_io);
    const tail_len_u64 = @min(length, 64 * 1024);
    const tail_len: usize = @intCast(tail_len_u64);
    const offset = length - tail_len_u64;
    const buffer = try app.allocator.alloc(u8, tail_len);
    defer app.allocator.free(buffer);
    const read_len = try file.readPositionalAll(std.Options.debug_io, buffer, offset);
    const bytes = buffer[0..read_len];

    var start: usize = 0;
    if (offset > 0) {
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |line_end| {
            start = line_end + 1;
        }
    }

    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("run audit log\n");
    try writer.writeAll("path: .zide/audit/run-history.jsonl\n");
    try writer.print("bytes: {d}\n", .{length});
    if (start > 0) try writer.writeAll("showing: tail, truncated to last 64 KiB boundary\n");
    try writer.writeAll("--- jsonl begin ---\n");
    try writer.writeAll(bytes[start..]);
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') try writer.writeAll("\n");
    try writer.writeAll("--- jsonl end ---\n");
    try app.process_console.appendBytes(.stdout, text.written());
}

fn verifyRunAuditLog(app: *app_mod.App) !Result {
    const path = try std.fs.path.join(app.allocator, &.{ app.workspace.root_path, ".zide", "audit", "run-history.jsonl" });
    defer app.allocator.free(path);

    var file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{
        .mode = .read_only,
        .allow_directory = false,
        .lock = .shared,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try appendConsole(app, .stdout, "run audit verification\npath: .zide/audit/run-history.jsonl\nstatus: no persisted launch audit yet\n", .{});
            return .{ .blocked = "no persisted launch audit yet" };
        },
        else => return err,
    };
    defer file.close(std.Options.debug_io);

    const length = try file.length(std.Options.debug_io);
    if (length > 16 * 1024 * 1024) {
        try appendConsole(app, .stderr, "run audit verification blocked: log is {d} bytes; rotate or export before full verification\n", .{length});
        return .{ .blocked = "run audit log is too large for in-process verification" };
    }

    const size: usize = @intCast(length);
    const buffer = try app.allocator.alloc(u8, size);
    defer app.allocator.free(buffer);
    const read_len = try file.readPositionalAll(std.Options.debug_io, buffer, 0);
    const stats = audit_chain.verify(buffer[0..read_len]);

    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;
    try writer.writeAll("run audit verification\n");
    try writer.writeAll("path: .zide/audit/run-history.jsonl\n");
    try writer.print("bytes: {d}\n", .{length});
    try writer.print("lines: {d}\n", .{stats.lines});
    try writer.print("chained: {d}\n", .{stats.chained});
    try writer.print("legacy: {d}\n", .{stats.legacy});
    try writer.print("broken: {d}\n", .{stats.broken});
    if (stats.first_broken_line) |line| try writer.print("first_broken_line: {d}\n", .{line});
    if (stats.last_record_hash) |hash| try writer.print("last_record_hash: {s}\n", .{hash[0..]});
    if (stats.ok()) {
        if (stats.legacy > 0) {
            try writer.writeAll("status: ok with legacy unchained entries\n");
        } else {
            try writer.writeAll("status: ok\n");
        }
    } else {
        try writer.writeAll("status: broken\n");
    }
    try app.process_console.appendBytes(.stdout, text.written());

    if (!stats.ok()) return .{ .blocked = "run audit chain verification failed" };
    return .{ .completed = "run audit chain verified" };
}

fn renderLspStatus(app: *app_mod.App) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("lsp servers\n");
    try writer.print("workspace: {s}\n", .{app.lsp_manager.workspace_root});
    try writer.print("slots: {d}\n", .{app.lsp_manager.servers.items.len});
    try writer.print("running: {d}\n", .{app.lsp_manager.runningCount()});
    if (app.lsp_manager.servers.items.len == 0) {
        try writer.writeAll("servers: none\n");
    } else {
        for (app.lsp_manager.servers.items) |server| {
            try writer.print("- {s}: state={s} opened={d} pending={d}", .{
                modes.label(server.language),
                @tagName(server.session.state),
                server.session.openedCount(),
                server.session.pendingCount(),
            });
            if (server.transport) |transport| {
                try writer.print(" transport=running ({s})\n", .{transport.command_label});
            } else {
                try writer.writeAll(" transport=stopped\n");
            }
        }
    }

    if (app.documents.active()) |doc| {
        const path = doc.path orelse "(scratch)";
        try writer.print("\nactive document: {s}\n", .{path});
        try writer.print("language: {s}\n", .{modes.label(doc.language)});
        if (app.lsp_manager.findServerConst(doc.language)) |server| {
            if (doc.path) |real_path| {
                if (server.session.documentVersion(real_path)) |version| {
                    try writer.print("lsp version: {d}\n", .{version});
                } else {
                    try writer.writeAll("lsp version: not synced\n");
                }
            } else {
                try writer.writeAll("lsp version: scratch\n");
            }
            if (server.session.last_completion) |items| {
                try writer.print("last completion items: {d}\n", .{items.items.len});
            }
            if (server.session.last_hover) |hover| {
                const preview_len = @min(hover.text.len, 160);
                try writer.print("last hover bytes: {d}\n", .{hover.text.len});
                if (preview_len > 0) try writer.print("last hover preview: {s}\n", .{hover.text[0..preview_len]});
            }
            if (server.session.last_locations) |locations| {
                try writer.print("last locations ({s}): {d}\n", .{ @tagName(server.session.last_locations_kind orelse .definition), locations.items.len });
                for (locations.items[0..@min(locations.items.len, 6)]) |location| {
                    try writer.print("- {s}:{d}:{d}\n", .{ location.path, location.range.start.line + 1, location.range.start.column + 1 });
                }
            }
            if (server.session.last_workspace_edit) |edit| {
                try writer.print("last workspace edit ({s}): edits={d} skipped_resource_ops={d}\n", .{
                    @tagName(server.session.last_workspace_edit_kind orelse .rename),
                    edit.edits.len,
                    edit.skipped_resource_ops,
                });
                for (edit.edits[0..@min(edit.edits.len, 6)]) |item| {
                    try writer.print("- {s}:{d}:{d}-{d}:{d} bytes={d}\n", .{
                        item.path,
                        item.range.start.line + 1,
                        item.range.start.column + 1,
                        item.range.end.line + 1,
                        item.range.end.column + 1,
                        item.new_text.len,
                    });
                }
            }
            if (server.session.last_code_actions) |actions| {
                try writer.print("last code actions: {d}\n", .{actions.items.len});
                for (actions.items[0..@min(actions.items.len, 6)], 0..) |item, index| {
                    try writer.print("- {d}. [{s}] {s}", .{ index + 1, item.kind, item.title });
                    if (item.workspace_edit) |workspace_edit| try writer.print(" edits={d}", .{workspace_edit.edits.len});
                    if (item.command_title.len > 0) try writer.print(" command={s}", .{item.command_title});
                    if (item.diagnostics > 0) try writer.print(" diagnostics={d}", .{item.diagnostics});
                    try writer.writeByte('\n');
                }
            }
        } else {
            try writer.writeAll("lsp version: no language session\n");
        }

        var plan = try lsp_launch_plan.forLanguage(app.allocator, doc.language);
        defer plan.deinit(app.allocator);
        try writer.print("server: {s}\n", .{plan.label});
        try writer.print("command: {s}\n", .{if (plan.command.len == 0) "(none)" else plan.command});
        try writer.print("security: {s}\n", .{plan.security_note});
        if (!plan.available) try writer.print("hint: {s}\n", .{plan.install_hint});
    }

    try app.process_console.appendBytes(.stdout, text.written());
}

fn syncCurrentDocumentToLsp(app: *app_mod.App) !Result {
    const doc = app.documents.active() orelse return .no_active_document;
    const path = doc.path orelse return .{ .blocked = "scratch documents cannot be synced to LSP yet" };
    const server = try app.lsp_manager.ensureServer(doc.language);
    if (server.transport != null and !lspServerReady(server)) {
        try appendConsole(app, .stdout, "lsp sync delayed: waiting for initialize acknowledgement\n", .{});
        return .{ .blocked = "LSP server is still initializing" };
    }
    const existing_version = server.session.documentVersion(path);
    const version = if (existing_version) |value| value + 1 else 1;

    var outbound = if (existing_version == null)
        try server.session.makeDidOpen(path, doc.language, version, doc.text.bytes)
    else
        try server.session.makeDidChange(path, version, doc.text.bytes);
    defer outbound.deinit();

    const sent = try deliverLspOutbound(app, server, if (existing_version == null) "didOpen" else "didChange", &outbound);
    return .{ .completed = if (sent) "LSP document sync sent" else "LSP document sync packet built" };
}

pub fn syncActiveDocumentToRunningLsp(app: *app_mod.App) !bool {
    const doc = app.documents.active() orelse return false;
    return try syncDocumentToRunningLsp(app, doc);
}

fn syncDocumentToRunningLsp(app: *app_mod.App, doc: *document_mod.Document) !bool {
    const server = app.lsp_manager.findServer(doc.language) orelse return false;
    if (!lspServerReady(server)) return false;
    if (doc.text.bytes.len > max_automatic_lsp_sync_bytes) return false;
    const path = doc.path orelse return false;
    const existing_version = server.session.documentVersion(path);
    const version = if (existing_version) |value| value + 1 else 1;

    var outbound = if (existing_version == null)
        try server.session.makeDidOpen(path, doc.language, version, doc.text.bytes)
    else
        try server.session.makeDidChange(path, version, doc.text.bytes);
    defer outbound.deinit();

    return try deliverLspOutboundWithOptions(app, server, if (existing_version == null) "didOpen" else "didChange", &outbound, .{
        .log_sent = false,
        .emit_when_missing = false,
    });
}

pub fn notifyActiveDocumentSavedToRunningLsp(app: *app_mod.App) !bool {
    const doc = app.documents.active() orelse return false;
    return try notifyDocumentSavedToRunningLsp(app, doc);
}

fn notifyDocumentSavedToRunningLsp(app: *app_mod.App, doc: *document_mod.Document) !bool {
    const server = app.lsp_manager.findServer(doc.language) orelse return false;
    if (!lspServerReady(server)) return false;
    const path = doc.path orelse return false;
    var outbound = try server.session.makeDidSave(path, null);
    defer outbound.deinit();
    return try deliverLspOutboundWithOptions(app, server, "didSave", &outbound, .{
        .log_sent = false,
        .emit_when_missing = false,
    });
}

fn lspServerReady(server: *const lsp_manager.Server) bool {
    return server.transport != null and server.session.state == .initialized;
}

pub fn requestActiveCompletionFromRunningLsp(app: *app_mod.App) !bool {
    return try requestActivePositionFromRunningLsp(app, .completion, "completion");
}

pub fn requestActiveHoverFromRunningLsp(app: *app_mod.App) !bool {
    return try requestActivePositionFromRunningLsp(app, .hover, "hover");
}

pub fn requestActiveFormattingFromRunningLsp(app: *app_mod.App) !bool {
    const doc = app.documents.active() orelse return false;
    const server = app.lsp_manager.findServer(doc.language) orelse return false;
    if (!lspServerReady(server)) return false;
    const path = doc.path orelse return false;
    _ = try syncDocumentToRunningLsp(app, doc);
    server.session.clearCachedResultForRequest(.formatting);
    var outbound = try server.session.requestFormatting(path, 4, true);
    defer outbound.deinit();
    return try deliverLspOutboundWithOptions(app, server, "formatting", &outbound, .{
        .log_sent = false,
        .emit_when_missing = false,
    });
}

pub fn requestActiveDefinitionFromRunningLsp(app: *app_mod.App) !bool {
    return try requestActivePositionFromRunningLsp(app, .definition, "definition");
}

pub fn requestActiveImplementationFromRunningLsp(app: *app_mod.App) !bool {
    return try requestActivePositionFromRunningLsp(app, .implementation, "implementation");
}

pub fn requestActiveTypeDefinitionFromRunningLsp(app: *app_mod.App) !bool {
    return try requestActivePositionFromRunningLsp(app, .type_definition, "typeDefinition");
}

pub fn requestActiveReferencesFromRunningLsp(app: *app_mod.App) !bool {
    return try requestActivePositionFromRunningLsp(app, .references, "references");
}

pub fn requestActiveCodeActionsFromRunningLsp(app: *app_mod.App) !bool {
    const doc = app.documents.active() orelse return false;
    const server = app.lsp_manager.findServer(doc.language) orelse return false;
    if (!lspServerReady(server)) return false;
    const path = doc.path orelse return false;
    _ = try syncDocumentToRunningLsp(app, doc);
    const range = codeActionRangeForActiveDocument(app, doc);
    const diagnostics = collectCodeActionDiagnostics(app, path, range);
    server.session.clearCachedResultForRequest(.code_action);
    var outbound = try server.session.requestCodeActions(path, range, diagnostics.items[0..diagnostics.len]);
    defer outbound.deinit();
    return try deliverLspOutboundWithOptions(app, server, "codeAction", &outbound, .{
        .log_sent = false,
        .emit_when_missing = false,
    });
}

pub fn requestActiveRenameFromRunningLsp(app: *app_mod.App, new_name: []const u8) !bool {
    const doc = app.documents.active() orelse return false;
    const server = app.lsp_manager.findServer(doc.language) orelse return false;
    if (!lspServerReady(server)) return false;
    const path = doc.path orelse return false;
    _ = try syncDocumentToRunningLsp(app, doc);
    server.session.clearCachedResultForRequest(.rename);
    var outbound = try server.session.requestRename(path, doc.cursor.position, new_name);
    defer outbound.deinit();
    return try deliverLspOutboundWithOptions(app, server, "rename", &outbound, .{
        .log_sent = false,
        .emit_when_missing = false,
    });
}

fn requestActivePositionFromRunningLsp(app: *app_mod.App, kind: lsp_session.RequestKind, label: []const u8) !bool {
    const doc = app.documents.active() orelse return false;
    const server = app.lsp_manager.findServer(doc.language) orelse return false;
    if (!lspServerReady(server)) return false;
    const path = doc.path orelse return false;
    _ = try syncDocumentToRunningLsp(app, doc);
    server.session.clearCachedResultForRequest(kind);
    var outbound = try server.session.requestPosition(kind, path, doc.cursor.position);
    defer outbound.deinit();
    return try deliverLspOutboundWithOptions(app, server, label, &outbound, .{
        .log_sent = false,
        .emit_when_missing = false,
    });
}

fn requestCurrentPositionLsp(app: *app_mod.App, kind: lsp_session.RequestKind, label: []const u8) !Result {
    const doc = app.documents.active() orelse return .no_active_document;
    const path = doc.path orelse return .{ .blocked = "scratch documents cannot request LSP features yet" };
    const server = try app.lsp_manager.ensureServer(doc.language);
    if (server.transport != null and !lspServerReady(server)) return .{ .blocked = "LSP server is still initializing" };
    _ = try syncDocumentToRunningLsp(app, doc);

    server.session.clearCachedResultForRequest(kind);
    var outbound = try server.session.requestPosition(kind, path, doc.cursor.position);
    defer outbound.deinit();
    const sent = try deliverLspOutbound(app, server, label, &outbound);
    return .{ .completed = if (sent) "LSP request sent" else "LSP request packet built" };
}

fn requestCurrentRenameLsp(app: *app_mod.App, new_name: []const u8) !Result {
    const doc = app.documents.active() orelse return .no_active_document;
    const path = doc.path orelse return .{ .blocked = "scratch documents cannot request LSP rename yet" };
    const server = try app.lsp_manager.ensureServer(doc.language);
    if (server.transport != null and !lspServerReady(server)) return .{ .blocked = "LSP server is still initializing" };
    _ = try syncDocumentToRunningLsp(app, doc);

    server.session.clearCachedResultForRequest(.rename);
    var outbound = try server.session.requestRename(path, doc.cursor.position, new_name);
    defer outbound.deinit();
    const sent = try deliverLspOutbound(app, server, "rename", &outbound);
    return .{ .completed = if (sent) "LSP rename request sent" else "LSP rename request packet built" };
}

fn requestCurrentFormattingLsp(app: *app_mod.App) !Result {
    const doc = app.documents.active() orelse return .no_active_document;
    const path = doc.path orelse return .{ .blocked = "scratch documents cannot request LSP formatting yet" };
    const server = try app.lsp_manager.ensureServer(doc.language);
    if (server.transport != null and !lspServerReady(server)) return .{ .blocked = "LSP server is still initializing" };
    _ = try syncDocumentToRunningLsp(app, doc);

    server.session.clearCachedResultForRequest(.formatting);
    var outbound = try server.session.requestFormatting(path, 4, true);
    defer outbound.deinit();
    const sent = try deliverLspOutbound(app, server, "formatting", &outbound);
    return .{ .completed = if (sent) "LSP formatting request sent" else "LSP formatting request packet built" };
}

fn requestCurrentCodeActionsLsp(app: *app_mod.App) !Result {
    const doc = app.documents.active() orelse return .no_active_document;
    const path = doc.path orelse return .{ .blocked = "scratch documents cannot request LSP code actions yet" };
    const server = try app.lsp_manager.ensureServer(doc.language);
    if (server.transport != null and !lspServerReady(server)) return .{ .blocked = "LSP server is still initializing" };
    _ = try syncDocumentToRunningLsp(app, doc);
    const range = codeActionRangeForActiveDocument(app, doc);
    const diagnostics = collectCodeActionDiagnostics(app, path, range);

    server.session.clearCachedResultForRequest(.code_action);
    var outbound = try server.session.requestCodeActions(path, range, diagnostics.items[0..diagnostics.len]);
    defer outbound.deinit();
    const sent = try deliverLspOutbound(app, server, "codeAction", &outbound);
    return .{ .completed = if (sent) "LSP code action request sent" else "LSP code action request packet built" };
}

const WorkspaceEditApplySummary = struct {
    edits: usize = 0,
    applied: usize = 0,
    failed: usize = 0,
    blocked: usize = 0,
    files: usize = 0,
    skipped_resource_ops: usize = 0,

    fn ok(self: WorkspaceEditApplySummary) bool {
        return self.failed == 0 and self.blocked == 0;
    }
};

const WorkspaceEditApplyStatus = enum {
    applied,
    blocked,
    failed,
};

fn applyLastLspWorkspaceEdit(app: *app_mod.App) !Result {
    const session = app.activeLspSession() orelse return .{ .blocked = "no LSP session for active document" };
    const edit = if (session.last_workspace_edit) |*cached| cached else return .{ .blocked = "no cached LSP workspace edit to apply" };

    const summary = try applyWorkspaceEdit(app, edit);
    try appendConsole(
        app,
        if (summary.ok()) .stdout else .stderr,
        "lsp workspace edit apply: edits={d} applied={d} files={d} blocked={d} failed={d} skipped_resource_ops={d}\n",
        .{ summary.edits, summary.applied, summary.files, summary.blocked, summary.failed, summary.skipped_resource_ops },
    );

    if (summary.applied > 0) {
        session.clearCachedResultForRequest(.rename);
    }
    if (summary.ok()) return .{ .completed = "LSP workspace edit applied to editor buffers" };
    return .{ .blocked = "LSP workspace edit partially applied; review output" };
}

fn applyFirstLspCodeAction(app: *app_mod.App) !Result {
    const session = app.activeLspSession() orelse return .{ .blocked = "no LSP session for active document" };
    const actions = if (session.last_code_actions) |*cached| cached else return .{ .blocked = "no cached LSP code actions to apply" };

    for (actions.items, 0..) |*action, index| {
        if (action.workspace_edit) |*edit| {
            _ = edit;
            return try applyLspCodeAction(app, index);
        }
    }

    return .{ .blocked = "cached LSP code actions did not include an editable WorkspaceEdit" };
}

fn applyLspCodeAction(app: *app_mod.App, zero_based_index: usize) !Result {
    const session = app.activeLspSession() orelse return .{ .blocked = "no LSP session for active document" };
    const actions = if (session.last_code_actions) |*cached| cached else return .{ .blocked = "no cached LSP code actions to apply" };
    if (zero_based_index >= actions.items.len) return .{ .blocked = "code action index is out of range" };
    const action = &actions.items[zero_based_index];
    const edit = if (action.workspace_edit) |*workspace_edit| workspace_edit else return .{ .blocked = "selected LSP code action has no editable WorkspaceEdit" };

    const summary = try applyWorkspaceEdit(app, edit);
    try appendConsole(
        app,
        if (summary.ok()) .stdout else .stderr,
        "lsp code action apply: #{d} {s} edits={d} applied={d} files={d} blocked={d} failed={d} skipped_resource_ops={d}\n",
        .{
            zero_based_index + 1,
            action.title,
            summary.edits,
            summary.applied,
            summary.files,
            summary.blocked,
            summary.failed,
            summary.skipped_resource_ops,
        },
    );
    if (summary.applied > 0) session.clearCachedResultForRequest(.code_action);
    if (summary.ok()) return .{ .completed = "LSP code action applied to editor buffers" };
    return .{ .blocked = "LSP code action partially applied; review output" };
}

fn applyWorkspaceEdit(app: *app_mod.App, edit: *const lsp_responses.WorkspaceEdit) !WorkspaceEditApplySummary {
    var summary: WorkspaceEditApplySummary = .{
        .edits = edit.edits.len,
        .skipped_resource_ops = edit.skipped_resource_ops,
    };
    if (edit.edits.len == 0) return summary;

    const previous_active = app.documents.activeIndex();
    defer {
        if (previous_active) |index| {
            if (index < app.documents.documents.items.len) app.documents.active_index = index;
        }
    }

    const indices = try app.allocator.alloc(usize, edit.edits.len);
    defer app.allocator.free(indices);
    for (indices, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, indices, edit.edits, workspaceEditIndexLess);

    var last_applied_path: ?[]const u8 = null;
    for (indices) |index| {
        const item = edit.edits[index];
        switch (try applyWorkspaceTextEdit(app, item)) {
            .applied => {
                summary.applied += 1;
                if (last_applied_path == null or !pathEqualIgnoreCaseAndSlash(last_applied_path.?, item.path)) {
                    summary.files += 1;
                    last_applied_path = item.path;
                }
            },
            .blocked => summary.blocked += 1,
            .failed => summary.failed += 1,
        }
    }

    return summary;
}

fn workspaceEditIndexLess(edits: []const lsp_responses.TextEdit, left_index: usize, right_index: usize) bool {
    const left = edits[left_index];
    const right = edits[right_index];
    const path_order = pathOrderIgnoreCaseAndSlash(left.path, right.path);
    if (path_order != .eq) return path_order == .lt;
    if (left.range.start.line != right.range.start.line) return left.range.start.line > right.range.start.line;
    if (left.range.start.column != right.range.start.column) return left.range.start.column > right.range.start.column;
    if (left.range.end.line != right.range.end.line) return left.range.end.line > right.range.end.line;
    if (left.range.end.column != right.range.end.column) return left.range.end.column > right.range.end.column;
    return left_index > right_index;
}

fn applyWorkspaceTextEdit(app: *app_mod.App, edit: lsp_responses.TextEdit) !WorkspaceEditApplyStatus {
    const absolute = try workspacePath(app, edit.path);
    defer app.allocator.free(absolute);

    if (!permissions.allowsWrite(.workspace_only, app.workspace.root_path, absolute)) {
        try appendConsole(app, .stderr, "lsp edit blocked outside workspace: {s}\n", .{edit.path});
        return .blocked;
    }

    const doc_index = app.openWorkspacePath(absolute) catch |err| {
        try appendConsole(app, .stderr, "lsp edit failed open: {s}: {s}\n", .{ edit.path, @errorName(err) });
        return .failed;
    };
    const doc = &app.documents.documents.items[doc_index];

    const start = doc.text.lineColumnToOffset(edit.range.start.line, edit.range.start.column) catch |err| {
        try appendConsole(app, .stderr, "lsp edit failed start range: {s}:{d}:{d}: {s}\n", .{
            edit.path,
            edit.range.start.line + 1,
            edit.range.start.column + 1,
            @errorName(err),
        });
        return .failed;
    };
    const end = doc.text.lineColumnToOffset(edit.range.end.line, edit.range.end.column) catch |err| {
        try appendConsole(app, .stderr, "lsp edit failed end range: {s}:{d}:{d}: {s}\n", .{
            edit.path,
            edit.range.end.line + 1,
            edit.range.end.column + 1,
            @errorName(err),
        });
        return .failed;
    };
    if (start > end) {
        try appendConsole(app, .stderr, "lsp edit failed inverted range: {s}:{d}:{d}-{d}:{d}\n", .{
            edit.path,
            edit.range.start.line + 1,
            edit.range.start.column + 1,
            edit.range.end.line + 1,
            edit.range.end.column + 1,
        });
        return .failed;
    }

    doc.replaceRange(start, end, edit.new_text) catch |err| {
        try appendConsole(app, .stderr, "lsp edit failed apply: {s}:{d}:{d}-{d}:{d}: {s}\n", .{
            edit.path,
            edit.range.start.line + 1,
            edit.range.start.column + 1,
            edit.range.end.line + 1,
            edit.range.end.column + 1,
            @errorName(err),
        });
        return .failed;
    };
    return .applied;
}

const max_code_action_diagnostics = 8;

const CodeActionDiagnostics = struct {
    items: [max_code_action_diagnostics]lsp_session.CodeActionDiagnostic = undefined,
    len: usize = 0,

    fn append(self: *CodeActionDiagnostics, item: lsp_session.CodeActionDiagnostic) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = item;
        self.len += 1;
    }
};

fn codeActionRangeForActiveDocument(app: *const app_mod.App, doc: *const document_mod.Document) types.Range {
    const path = doc.path orelse return types.Range.empty(doc.cursor.position);
    for (app.diagnostics.items.items) |item| {
        if (!pathMatchesDiagnostic(path, item.path)) continue;
        if (rangeTouchesLine(item.range, doc.cursor.position.line)) return item.range;
    }
    return types.Range.empty(doc.cursor.position);
}

fn collectCodeActionDiagnostics(app: *const app_mod.App, path: []const u8, range: types.Range) CodeActionDiagnostics {
    var diagnostics: CodeActionDiagnostics = .{};
    for (app.diagnostics.items.items) |item| {
        if (!pathMatchesDiagnostic(path, item.path)) continue;
        if (!rangesTouchLines(item.range, range)) continue;
        diagnostics.append(.{
            .range = lspRange(item.range),
            .severity = lspSeverity(item.severity),
            .source = @tagName(item.source),
            .message = item.message,
        });
    }
    return diagnostics;
}

fn lspRange(range: types.Range) @import("../lsp/protocol.zig").TextRange {
    return .{
        .start = .{ .line = range.start.line, .character = range.start.column },
        .end = .{ .line = range.end.line, .character = range.end.column },
    };
}

fn lspSeverity(severity: types.Severity) usize {
    return switch (severity) {
        .err => 1,
        .warning => 2,
        .info => 3,
    };
}

fn rangeTouchesLine(range: types.Range, line: usize) bool {
    const start = @min(range.start.line, range.end.line);
    const end = @max(range.start.line, range.end.line);
    return line >= start and line <= end;
}

fn rangesTouchLines(left: types.Range, right: types.Range) bool {
    const left_start = @min(left.start.line, left.end.line);
    const left_end = @max(left.start.line, left.end.line);
    const right_start = @min(right.start.line, right.end.line);
    const right_end = @max(right.start.line, right.end.line);
    return left_end >= right_start and right_end >= left_start;
}

fn ensureActiveLsp(app: *app_mod.App, source: command.Source) !Result {
    const doc = app.documents.active() orelse return .no_active_document;

    if (app.hasRunningLspForActiveDocument()) {
        return try syncCurrentDocumentToLsp(app);
    }

    var plan = try lsp_launch_plan.forLanguage(app.allocator, doc.language);
    defer plan.deinit(app.allocator);
    try appendConsole(app, .stdout, "lsp ensure\nlanguage: {s}\nserver: {s}\ncommand: {s}\nnote: {s}\nhint: {s}\n", .{
        modes.label(doc.language),
        plan.label,
        if (plan.command.len == 0) "(none)" else plan.command,
        plan.security_note,
        plan.install_hint,
    });
    if (!plan.available) {
        return .{ .blocked = "no default LSP server mapping for active language" };
    }

    switch (app.runtime.checkCommand(.{ .id = "lsp.start", .source = source })) {
        .unknown_command => return .unknown_command,
        .allowed => {},
        .blocked => |message| return .{ .blocked = message },
        .confirmation_required => |message| return .{ .blocked = message },
    }

    const started = try startLspTransport(app);
    return switch (started) {
        .completed => .{ .completed = "LSP server starting; waiting for initialize acknowledgement" },
        else => started,
    };
}

fn startLspTransport(app: *app_mod.App) !Result {
    const doc = app.documents.active() orelse return .no_active_document;
    const server = try app.lsp_manager.ensureServer(doc.language);
    if (server.transport != null) return .{ .blocked = "LSP transport is already running for active language" };

    var spec = (try lsp_transport.launchSpecForLanguage(app.allocator, doc.language, app.workspace.root_path)) orelse {
        return .{ .blocked = "no default LSP server mapping for active language" };
    };
    defer spec.deinit();

    var transport = lsp_transport.Transport.start(app.allocator, app.io, spec, null) catch |err| {
        try appendConsole(app, .stderr, "lsp start failed: {s}\nhint: {s}\n", .{ @errorName(err), spec.install_hint });
        return .{ .blocked = "LSP server could not be started" };
    };
    errdefer transport.deinit();

    var initialize = try server.session.makeInitialize("zide");
    defer initialize.deinit();
    transport.send(initialize.framed) catch |err| {
        if (initialize.id) |id| server.session.cancelPending(id);
        try appendConsole(app, .stderr, "lsp initialize send failed: {s}\n", .{@errorName(err)});
        return .{ .blocked = "LSP initialize could not be sent" };
    };

    try appendConsole(app, .stdout, "lsp started: {s}\nlanguage: {s}\ncommand: {s}\ninitialize id: {d}\nnote: {s}\n", .{
        spec.label,
        modes.label(doc.language),
        transport.command_label,
        initialize.id orelse 0,
        spec.security_note,
    });
    server.transport = transport;
    return .{ .completed = "LSP server started" };
}

fn stopLspTransport(app: *app_mod.App) !Result {
    const doc = app.documents.active() orelse return .no_active_document;
    if (app.lsp_manager.stopServer(doc.language)) {
        try appendConsole(app, .stdout, "lsp stopped: {s}\n", .{modes.label(doc.language)});
        return .{ .completed = "LSP server stopped" };
    }
    return .{ .blocked = "no LSP transport is running for active language" };
}

fn ingestLspPayload(app: *app_mod.App, payload: []const u8) !Result {
    const doc = app.documents.active() orelse return .no_active_document;
    const server = try app.lsp_manager.ensureServer(doc.language);
    const result = try server.session.ingestPayload(payload, &app.diagnostics);
    try renderLspIngestResult(app, result);
    return switch (result) {
        .ignored => .{ .blocked = "LSP payload ignored" },
        else => .{ .completed = "LSP payload ingested" },
    };
}

fn drainLspFrames(app: *app_mod.App) !Result {
    if (!app.lsp_manager.hasRunningServer()) return .{ .blocked = "no LSP transport is running" };
    const result = try pumpLsp(app);
    if (result.frames == 0 and result.stderr_bytes == 0) return .{ .blocked = "no complete LSP frames buffered" };
    return .{ .completed = "LSP frames drained" };
}

pub fn pumpLsp(app: *app_mod.App) !LspPumpResult {
    var result: LspPumpResult = .{};
    for (app.lsp_manager.servers.items) |*server| {
        const transport = if (server.transport) |*transport| transport else continue;
        while (true) {
            var frame = (try transport.nextStdoutFrame()) orelse break;
            const ingest_result = try server.session.ingestPayload(frame.body, &app.diagnostics);
            try renderLspIngestResult(app, ingest_result);
            switch (ingest_result) {
                .acknowledged => |kind| if (kind == .initialize) try completeLspInitialization(app, server),
                else => {},
            }
            frame.deinit();
            result.frames += 1;
        }

        const preview = try transport.takeStderrPreview(app.allocator, 4096);
        defer app.allocator.free(preview.bytes);
        result.stderr_bytes += preview.total;
        if (preview.total > 0) {
            try appendConsole(app, .stderr, "lsp stderr {s} ({d} bytes)\n{s}\n", .{ modes.label(server.language), preview.total, preview.bytes });
        }
    }

    return result;
}

fn completeLspInitialization(app: *app_mod.App, server: *lsp_manager.Server) !void {
    var initialized = try server.session.makeInitialized();
    defer initialized.deinit();
    _ = try deliverLspOutbound(app, server, "initialized", &initialized);

    if (try syncActiveDocumentToRunningLsp(app)) {
        try appendConsole(app, .stdout, "lsp ready: active document synced\n", .{});
    } else {
        try appendConsole(app, .stdout, "lsp ready: no active document sync needed\n", .{});
    }
}

fn deliverLspOutbound(app: *app_mod.App, server: *lsp_manager.Server, label: []const u8, outbound: *const lsp_session.Outbound) !bool {
    return try deliverLspOutboundWithOptions(app, server, label, outbound, .{});
}

const LspDeliveryOptions = struct {
    log_sent: bool = true,
    emit_when_missing: bool = true,
};

fn deliverLspOutboundWithOptions(app: *app_mod.App, server: *lsp_manager.Server, label: []const u8, outbound: *const lsp_session.Outbound, options: LspDeliveryOptions) !bool {
    if (server.transport) |*transport| {
        transport.send(outbound.framed) catch |err| {
            if (outbound.id) |id| server.session.cancelPending(id);
            try appendConsole(app, .stderr, "lsp send failed ({s}): {s}\n", .{ label, @errorName(err) });
            return err;
        };
        if (options.log_sent) {
            try appendConsole(app, .stdout, "lsp sent: {s} {s} bytes:{d}\n", .{ modes.label(server.language), label, outbound.framed.len });
        }
        return true;
    }

    if (outbound.id) |id| server.session.cancelPending(id);
    if (options.emit_when_missing) try emitLspOutbound(app, label, outbound);
    return false;
}

fn emitLspOutbound(app: *app_mod.App, label: []const u8, outbound: *const lsp_session.Outbound) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.print("lsp outbound: {s}\n", .{label});
    if (outbound.id) |id| try writer.print("id: {d}\n", .{id});
    if (outbound.kind) |kind| try writer.print("kind: {s}\n", .{@tagName(kind)});
    try writer.print("payload bytes: {d}\n", .{outbound.payload.len});
    try writer.print("framed bytes: {d}\n", .{outbound.framed.len});
    try writer.writeAll("--- payload preview ---\n");
    const preview_len = @min(outbound.payload.len, 4096);
    try writer.writeAll(outbound.payload[0..preview_len]);
    if (preview_len < outbound.payload.len) {
        try writer.print("\n... truncated {d} byte(s)\n", .{outbound.payload.len - preview_len});
    }
    try writer.writeAll("\n--- end ---\n");
    try app.process_console.appendBytes(.stdout, text.written());
}

fn renderLspIngestResult(app: *app_mod.App, result: lsp_session.IngestResult) !void {
    switch (result) {
        .ignored => try appendConsole(app, .stdout, "lsp ingest: ignored\n", .{}),
        .diagnostics => |count| try appendConsole(app, .stdout, "lsp ingest: diagnostics {d}\n", .{count}),
        .completion => |count| try appendConsole(app, .stdout, "lsp ingest: completion items {d}\n", .{count}),
        .hover => |bytes| try appendConsole(app, .stdout, "lsp ingest: hover bytes {d}\n", .{bytes}),
        .locations => |count| try appendConsole(app, .stdout, "lsp ingest: locations {d}\n", .{count}),
        .workspace_edit => |count| try appendConsole(app, .stdout, "lsp ingest: workspace edit {d}\n", .{count}),
        .code_actions => |count| try appendConsole(app, .stdout, "lsp ingest: code actions {d}\n", .{count}),
        .acknowledged => |kind| try appendConsole(app, .stdout, "lsp ingest: acknowledged {s}\n", .{@tagName(kind)}),
    }
}

fn syncDiagnosticsFromConsole(app: *app_mod.App) !void {
    app.diagnostics.clearSource(.compiler);
    for (app.process_console.lines.items) |line| {
        if (zig_output.parseLine(line.text)) |parsed| {
            try app.diagnostics.append(zig_output.toDiagnostic(parsed));
        }
    }
}

fn runSaveSafetyCheck(app: *app_mod.App) !?[]const u8 {
    const doc = app.documents.active() orelse return null;
    return runDocumentSaveSafetyCheck(app, doc);
}

fn runDocumentSaveSafetyCheck(app: *app_mod.App, doc: *const document_mod.Document) !?[]const u8 {
    const path = doc.path orelse return null;
    var scan = try scanDocumentSecurity(app.allocator, path, doc.language, doc.text.bytes);
    defer scan.deinit();

    app.security_findings.clearPath(path);
    for (scan.items.items) |item| {
        try app.security_findings.appendFinding(item);
    }
    try syncDiagnosticsFromSecurity(app);
    try renderSaveSafetyCheck(app, path, &scan);
    applyPostureGuard(app);

    if (scan.countRiskAtLeast(.critical) > 0) {
        return "save blocked by critical security finding";
    }
    return null;
}

fn scanDocumentSecurity(
    allocator: std.mem.Allocator,
    path: []const u8,
    language: modes.LanguageMode,
    source: []const u8,
) !security_findings.Collection {
    var collection = try text_integrity.scan(allocator, source, .{ .path = path });
    errdefer collection.deinit();

    if (language == .zon or std.mem.eql(u8, path, "build.zig.zon")) {
        var package_findings = try package_trust.scanZon(allocator, source, .{ .path = path });
        defer package_findings.deinit();
        try appendFindings(&collection, &package_findings);
        return collection;
    }
    if (language == .zig) {
        var zig_findings = try zig_scanner.scanSource(allocator, source, .{ .path = path });
        defer zig_findings.deinit();
        try appendFindings(&collection, &zig_findings);
        return collection;
    }
    if (polyglot_scanner.isInterestingPath(path, language)) {
        var polyglot_findings = try polyglot_scanner.scanSource(allocator, source, .{ .path = path, .language = language });
        defer polyglot_findings.deinit();
        try appendFindings(&collection, &polyglot_findings);
        return collection;
    }
    return collection;
}

fn appendFindings(target: *security_findings.Collection, source: *const security_findings.Collection) !void {
    for (source.items.items) |item| {
        try target.appendFinding(item);
    }
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
    app.diagnostics.clearSource(.internal);
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
    const index = app.openWorkspacePath(path) catch return false;
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

fn renderWorkspaceReplacePreview(app: *app_mod.App, request: workspace_replace.Request) !void {
    var replacement_preview = try workspace_replace.preview(app.allocator, &app.workspace, request, .{
        .max_file_bytes = 2 * 1024 * 1024,
        .max_files = 1024,
        .max_matches = 10_000,
        .max_total_bytes = 64 * 1024 * 1024,
    });
    defer replacement_preview.deinit();

    try appendConsole(
        app,
        .stdout,
        "workspace replacement preview\nfiles: {d}\nmatches: {d}\nbytes: {d} -> {d}\nskipped: binary={d} too_large={d} unreadable={d}\nconfirmation token: {s}\n",
        .{
            replacement_preview.files.len,
            replacement_preview.matches,
            replacement_preview.before_bytes,
            replacement_preview.after_bytes,
            replacement_preview.skipped.binary,
            replacement_preview.skipped.too_large,
            replacement_preview.skipped.unreadable,
            replacement_preview.token[0..],
        },
    );
    for (replacement_preview.files, 0..) |file, index| {
        if (index >= 40) {
            try appendConsole(app, .stdout, "... {d} more files\n", .{replacement_preview.files.len - index});
            break;
        }
        try appendConsole(app, .stdout, "{s}:{d}:{d} matches={d} sha256={s}\n", .{
            file.path,
            file.first_line + 1,
            file.first_column + 1,
            file.matches,
            file.digest[0..12],
        });
    }
}

fn applyWorkspaceReplacement(app: *app_mod.App, parsed: workspace_replace.ParsedApply) !Result {
    var replacement_preview = try workspace_replace.preview(app.allocator, &app.workspace, parsed.request, .{});
    defer replacement_preview.deinit();
    if (replacement_preview.files.len == 0) return .{ .blocked = "workspace replacement has no matches" };
    if (!std.ascii.eqlIgnoreCase(parsed.token, replacement_preview.token[0..])) {
        return .{ .blocked = "workspace changed after preview; review the replacement again" };
    }
    if (try workspaceReplacementTouchesDirtyDocument(app, &replacement_preview)) {
        return .{ .blocked = "workspace replacement touches an unsaved editor; save or close it first" };
    }

    const report = workspace_replace.apply(app.allocator, &app.workspace, parsed.request, parsed.token, .{}) catch |err| switch (err) {
        error.PreviewStale => return .{ .blocked = "workspace changed during replacement; no unverified write was applied" },
        error.NoMatches => return .{ .blocked = "workspace replacement has no matches" },
        error.RollbackFailed => return .{ .blocked = "workspace replacement rollback failed; inspect files before continuing" },
        else => return err,
    };
    const reloaded = try reloadWorkspaceReplacementDocuments(app, &replacement_preview);
    try appendConsole(app, .stdout, "workspace replacement applied: files={d} matches={d} open_editors_updated={d} token={s}\n", .{
        report.files,
        report.matches,
        reloaded,
        report.token[0..],
    });
    return .{ .completed = "workspace replacement applied" };
}

fn workspaceReplacementTouchesDirtyDocument(app: *app_mod.App, replacement_preview: *const workspace_replace.Preview) !bool {
    for (replacement_preview.files) |file| {
        const absolute_path = try std.fs.path.join(app.allocator, &.{ app.workspace.root_path, file.path });
        defer app.allocator.free(absolute_path);
        for (app.documents.documents.items) |doc| {
            const document_path = doc.path orelse continue;
            if (doc.dirty and filesystemPathEqual(document_path, absolute_path)) return true;
        }
    }
    return false;
}

fn reloadWorkspaceReplacementDocuments(app: *app_mod.App, replacement_preview: *const workspace_replace.Preview) !usize {
    var updated: usize = 0;
    for (replacement_preview.files) |file| {
        const absolute_path = try std.fs.path.join(app.allocator, &.{ app.workspace.root_path, file.path });
        defer app.allocator.free(absolute_path);
        for (app.documents.documents.items) |*doc| {
            const document_path = doc.path orelse continue;
            if (!filesystemPathEqual(document_path, absolute_path)) continue;

            const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, absolute_path, app.allocator, .limited(2 * 1024 * 1024)) catch |err| {
                try appendConsole(app, .stderr, "workspace replacement editor reload failed: {s}: {s}\n", .{ file.path, @errorName(err) });
                continue;
            };
            defer app.allocator.free(bytes);
            if (!std.mem.eql(u8, doc.text.bytes, bytes)) {
                const previous = doc.cursor.position;
                try doc.replaceRange(0, doc.text.bytes.len, bytes);
                const line = @min(previous.line, doc.text.lineCount() - 1);
                const column = @min(previous.column, doc.text.lineSlice(line).len);
                const offset = try doc.text.lineColumnToOffset(line, column);
                doc.cursor.position = try doc.positionFromOffset(offset);
            }
            doc.dirty = false;
            _ = syncDocumentToRunningLsp(app, doc) catch false;
            _ = notifyDocumentSavedToRunningLsp(app, doc) catch false;
            updated += 1;
        }
    }
    return updated;
}

fn filesystemPathEqual(left: []const u8, right: []const u8) bool {
    if (std.fs.path.sep == '\\') return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}

const LanguageRow = struct {
    mode: modes.LanguageMode,
    files: usize,
};

fn languageRowLess(_: void, left: LanguageRow, right: LanguageRow) bool {
    if (left.files != right.files) return left.files > right.files;
    return @intFromEnum(left.mode) < @intFromEnum(right.mode);
}

fn renderWorkspaceLanguageReport(app: *app_mod.App) !void {
    try app.workspace.refresh();

    const language_count_len = @typeInfo(modes.LanguageMode).@"enum".fields.len;
    const family_count_len = @typeInfo(modes.LanguageFamily).@"enum".fields.len;
    var language_counts = [_]usize{0} ** language_count_len;
    var family_counts = [_]usize{0} ** family_count_len;
    var total_files: usize = 0;
    var total_dirs: usize = 0;
    var other_entries: usize = 0;
    var recognized_files: usize = 0;
    var code_files: usize = 0;
    var unknown_files: usize = 0;

    for (app.workspace.entries.items) |entry| {
        switch (entry.kind) {
            .file => {
                total_files += 1;
                language_counts[@intFromEnum(entry.language)] += 1;
                family_counts[@intFromEnum(modes.family(entry.language))] += 1;
                if (modes.isRecognized(entry.language)) recognized_files += 1 else unknown_files += 1;
                if (modes.isCode(entry.language)) code_files += 1;
            },
            .directory => total_dirs += 1,
            .other => other_entries += 1,
        }
    }

    var rows = std.array_list.Managed(LanguageRow).init(app.allocator);
    defer rows.deinit();
    for (modes.all()) |mode| {
        const files = language_counts[@intFromEnum(mode)];
        if (files > 0) try rows.append(.{ .mode = mode, .files = files });
    }
    std.mem.sort(LanguageRow, rows.items, {}, languageRowLess);

    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("workspace language report\n");
    try writer.print("root: {s}\n", .{app.workspace.root_path});
    try writer.print("entries: files={d} dirs={d} other={d}\n", .{ total_files, total_dirs, other_entries });
    try writer.print("recognized files: {d}/{d}\n", .{ recognized_files, total_files });
    try writer.print("code files: {d}\n", .{code_files});
    try writer.print("language modes present: {d}\n", .{rows.items.len});
    try writer.writeAll("boundary: filename/language registry only; no hooks, plugins, package scripts, language servers, or shell commands were executed\n");

    try writer.writeAll("\nfamilies\n");
    inline for (@typeInfo(modes.LanguageFamily).@"enum".fields) |field| {
        const family_value: modes.LanguageFamily = @enumFromInt(field.value);
        const count = family_counts[@intFromEnum(family_value)];
        if (count > 0) try writer.print("- {s}: {d}\n", .{ field.name, count });
    }

    try writer.writeAll("\nlanguages\n");
    for (rows.items) |row| {
        var plan = try lsp_launch_plan.forLanguage(app.allocator, row.mode);
        defer plan.deinit(app.allocator);
        const run_label = if (modes.runProfile(row.mode)) |profile| profile.label else "none";
        try writer.print("- {s}: files={d} family={s} lsp={s} run={s} security={s}\n", .{
            modes.label(row.mode),
            row.files,
            @tagName(modes.family(row.mode)),
            if (plan.available) plan.label else "none",
            run_label,
            modes.securityFocus(row.mode),
        });
        if (plan.available and plan.command.len > 0) {
            try writer.print("  lsp command: {s}\n", .{plan.command});
        } else if (!plan.available and row.files > 0 and modes.isCode(row.mode)) {
            try writer.print("  lsp hint: {s}\n", .{plan.install_hint});
        }
    }

    if (unknown_files > 0) {
        try writer.writeAll("\nunknown file examples\n");
        var shown: usize = 0;
        for (app.workspace.entries.items) |entry| {
            if (entry.kind != .file or entry.language != .unknown) continue;
            try writer.print("- {s}\n", .{entry.path});
            shown += 1;
            if (shown >= 8) break;
        }
        if (unknown_files > shown) try writer.print("... {d} more unknown file(s)\n", .{unknown_files - shown});
    }

    try writer.writeAll("\nopen editors\n");
    try writer.print("tabs={d} dirty={d}\n", .{ app.documents.documents.items.len, app.documents.dirtyCount() });
    for (app.documents.documents.items[0..@min(app.documents.documents.items.len, @as(usize, 12))]) |doc| {
        try writer.print("- {s} [{s}]{s}\n", .{
            doc.path orelse "(scratch)",
            modes.label(doc.language),
            if (doc.dirty) " dirty" else "",
        });
    }

    try writer.writeAll("\nlsp runtime\n");
    try writer.print("slots={d} running={d}\n", .{ app.lsp_manager.servers.items.len, app.lsp_manager.runningCount() });
    for (app.lsp_manager.servers.items) |server| {
        try writer.print("- {s}: state={s} opened={d} pending={d} transport={s}\n", .{
            modes.label(server.language),
            @tagName(server.session.state),
            server.session.openedCount(),
            server.session.pendingCount(),
            if (server.transport != null) "running" else "stopped",
        });
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

fn renderExtensionRegistry(app: *app_mod.App, registry: *const extension_registry.Registry) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("extensions/integrations (pure Zig manifest scan, no extension code executed)\n");
    try writer.print("manifests: {d}, loaded={d}, invalid={d}, high={d}, medium={d}\n", .{
        registry.items.items.len,
        registry.countStatus(.loaded),
        registry.countStatus(.invalid),
        registry.countRisk(.high),
        registry.countRisk(.medium),
    });

    if (registry.items.items.len == 0) {
        try writer.writeAll("no zide-extension.json or zide.extension.json manifests found\n");
    }

    for (registry.items.items, 0..) |extension, index| {
        if (index >= 40) {
            try writer.print("... {d} more extension manifests\n", .{registry.items.items.len - index});
            break;
        }

        try writer.print("- [{s}/{s}] {s} {s} ({s})\n", .{
            @tagName(extension.status),
            extension_registry.riskLabel(extension_registry.extensionRisk(extension)),
            extension.name,
            extension.version,
            extension.manifest_path,
        });
        if (extension.capabilities.len > 0) {
            try writer.writeAll("  capabilities:");
            for (extension.capabilities) |capability| {
                try writer.print(" {s}", .{extension_registry.capabilityLabel(capability)});
            }
            try writer.writeByte('\n');
        }
        if (extension.commands > 0 or extension.integrations > 0) {
            try writer.print("  commands={d} integrations={d}\n", .{ extension.commands, extension.integrations });
        }
        if (extension.message.len > 0) {
            try writer.print("  {s}\n", .{extension.message});
        }
    }

    try app.process_console.appendBytes(.stdout, text.written());
}

fn renderReleaseChecklist(app: *app_mod.App) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("release/public launch checklist\n");
    try writer.writeAll("goal: make the first public build easy to try, easy to trust, and easy to talk about\n\n");

    try writer.print("{s} README.md present (human-written landing story)\n", .{checkMark(workspaceHasPath(app, "README.md"))});
    try writer.print("{s} docs/security.md present (trust model explainer)\n", .{checkMark(workspaceHasPath(app, "docs/security.md"))});
    try writer.print("{s} built Windows GUI artifact zig-out/bin/zide-gui.exe\n", .{checkMark(workspaceFileExists(app, "zig-out/bin/zide-gui.exe"))});
    try writer.print("{s} built Windows CLI artifact zig-out/bin/zide.exe\n", .{checkMark(workspaceFileExists(app, "zig-out/bin/zide.exe"))});
    try writer.print("{s} built Linux GUI artifact zig-out/linux-x86_64/bin/zide-gui\n", .{checkMark(workspaceFileExists(app, release_linux_gui_asset.relative_path))});
    try writer.print("{s} built Linux CLI/TUI artifact zig-out/linux-x86_64/bin/zide\n", .{checkMark(workspaceFileExists(app, release_linux_cli_asset.relative_path))});
    try writer.print("{s} bundled Windows ZIP zig-out/release/zide-windows-x86_64.zip\n", .{checkMark(workspaceFileExists(app, release_bundle_asset.relative_path))});
    try writer.print("{s} bundled Linux TAR zig-out/release/zide-linux-x86_64.tar\n", .{checkMark(workspaceFileExists(app, release_linux_bundle_asset.relative_path))});
    try writer.print("{s} GitHub Actions workflow present\n", .{checkMark(workspaceHasPrefix(app, ".github/workflows/"))});
    try writer.print("{s} LICENSE present\n", .{checkMark(workspaceHasPath(app, "LICENSE") or workspaceHasPath(app, "LICENSE.md") or workspaceHasPath(app, "COPYING"))});

    try writer.writeAll("\nfirst public path\n");
    try writer.writeAll("1. Ship a GitHub draft release with Windows ZIP, Linux TAR, checksum text, and a short screencast/GIF.\n");
    try writer.writeAll("2. Mark it prerelease until save/edit/git/security flows are exercised by outside users.\n");
    try writer.writeAll("3. Add issue templates for bug, security false-positive, and feature request once first testers appear.\n");
    try writer.writeAll("4. After the first stable tag, publish install manifests: winget first for Windows, Scoop bucket next for power users.\n");
    try writer.writeAll("5. Keep the hook-free Git/security story in every release note; that is the memorable difference.\n");
    try writer.writeAll("6. Run release.bundle, release.verify, then release.assets; paste archive SHA-256 values into release notes and package manifests.\n");

    try writer.writeAll("\nasset naming suggestion\n");
    try writer.writeAll("- zide-windows-x86_64.zip\n");
    try writer.writeAll("- zide-linux-x86_64.tar\n");
    try writer.writeAll("- zide-windows-x86_64.sha256.txt\n");
    try writer.writeAll("- zide-linux-x86_64.sha256.txt\n");
    try writer.writeAll("- zide-demo-60s.mp4 or zide-demo.gif\n");

    try app.process_console.appendBytes(.stdout, text.written());
}

const ReleaseAsset = struct {
    label: []const u8,
    relative_path: []const u8,
    release_name: []const u8,
};

const Sha256Hex = [std.crypto.hash.sha2.Sha256.digest_length * 2]u8;

const ReleaseAssetDigest = struct {
    asset: ReleaseAsset,
    size: u64,
    sha256: Sha256Hex,
};

const release_bundle_root = "zide-windows-x86_64";
const release_linux_bundle_root = "zide-linux-x86_64";
const release_bundle_asset = ReleaseAsset{ .label = "WIN ZIP", .relative_path = "zig-out/release/zide-windows-x86_64.zip", .release_name = "zide-windows-x86_64.zip" };
const release_linux_bundle_asset = ReleaseAsset{ .label = "LINUX TAR", .relative_path = "zig-out/release/zide-linux-x86_64.tar", .release_name = "zide-linux-x86_64.tar" };
const release_gui_asset = ReleaseAsset{ .label = "WIN GUI", .relative_path = "zig-out/bin/zide-gui.exe", .release_name = "zide-gui.exe" };
const release_cli_asset = ReleaseAsset{ .label = "WIN CLI", .relative_path = "zig-out/bin/zide.exe", .release_name = "zide.exe" };
const release_linux_gui_asset = ReleaseAsset{ .label = "LINUX GUI", .relative_path = "zig-out/linux-x86_64/bin/zide-gui", .release_name = "zide-gui" };
const release_linux_cli_asset = ReleaseAsset{ .label = "LINUX CLI", .relative_path = "zig-out/linux-x86_64/bin/zide", .release_name = "zide" };

const release_assets = [_]ReleaseAsset{
    release_bundle_asset,
    release_linux_bundle_asset,
    release_gui_asset,
    release_cli_asset,
    release_linux_gui_asset,
    release_linux_cli_asset,
};

fn renderReleaseAssets(app: *app_mod.App) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("release assets and checksums\n");
    try writer.writeAll("mode: pure Zig file read + SHA-256; no shell, no git, no network\n\n");

    var found: usize = 0;
    for (release_assets) |asset| {
        if (try renderReleaseAsset(app, writer, asset)) found += 1;
    }

    if (found == 0) {
        try writer.writeAll("\nno release artifacts found yet; run zig build install, zig build install-gui, zig build install-linux, and zig build install-linux-gui first\n");
    } else {
        try writer.writeAll("\ncopy targets\n");
        try writer.writeAll("- GitHub release notes: include each sha256 line below the attached file name.\n");
        try writer.writeAll("- winget: use the matching SHA-256 as InstallerSha256.\n");
        try writer.writeAll("- Scoop: use the matching SHA-256 as hash.\n");
    }

    try app.process_console.appendBytes(.stdout, text.written());
}

fn renderReleaseAsset(app: *app_mod.App, writer: *std.Io.Writer, asset: ReleaseAsset) !bool {
    const digest = (try hashReleaseAsset(app, asset)) orelse {
        try writer.print("- [{s}] missing: {s}\n", .{ asset.label, asset.relative_path });
        return false;
    };

    try writer.print("- [{s}] {s}\n", .{ asset.label, asset.release_name });
    try writer.print("  path   : {s}\n", .{asset.relative_path});
    try writer.print("  size   : {d} bytes\n", .{digest.size});
    try writer.print("  sha256 : {s}\n", .{digest.sha256[0..]});
    try writer.print("  winget : InstallerSha256: {s}\n", .{digest.sha256[0..]});
    try writer.print("  scoop  : \"hash\": \"{s}\"\n", .{digest.sha256[0..]});
    return true;
}

fn hashReleaseAsset(app: *app_mod.App, asset: ReleaseAsset) !?ReleaseAssetDigest {
    const path = try std.fs.path.join(app.allocator, &.{ app.workspace.root_path, asset.relative_path });
    defer app.allocator.free(path);

    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind != .file) return null;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, app.allocator, .limited(512 * 1024 * 1024));
    defer app.allocator.free(bytes);

    return .{ .asset = asset, .size = stat.size, .sha256 = try sha256Hex(bytes) };
}

fn readReleaseAssetBytes(app: *app_mod.App, asset: ReleaseAsset) !?[]u8 {
    const path = try std.fs.path.join(app.allocator, &.{ app.workspace.root_path, asset.relative_path });
    defer app.allocator.free(path);

    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind != .file) return null;

    return try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, app.allocator, .limited(512 * 1024 * 1024));
}

fn sha256Hex(bytes: []const u8) !Sha256Hex {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    var hex: Sha256Hex = undefined;
    try std.crypto.codecs.hex.encode(hex[0..], digest[0..], .lower);
    return hex;
}

const ZipInputEntry = struct {
    name: []const u8,
    bytes: []const u8,
};

const ZipCentralEntry = struct {
    name: []const u8,
    crc32: u32,
    size: u32,
    local_header_offset: u32,
};

const TarInputEntry = struct {
    name: []const u8,
    bytes: []const u8,
    mode: u32,
};

fn renderReleaseBundle(app: *app_mod.App) !bool {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("release bundle\n");
    try writer.writeAll("mode: pure Zig ZIP/TAR writers; no shell, no archive executable, no network\n\n");

    const gui_bytes_opt = try readReleaseAssetBytes(app, release_gui_asset);
    defer {
        if (gui_bytes_opt) |bytes| app.allocator.free(bytes);
    }
    const cli_bytes_opt = try readReleaseAssetBytes(app, release_cli_asset);
    defer {
        if (cli_bytes_opt) |bytes| app.allocator.free(bytes);
    }
    const linux_gui_bytes_opt = try readReleaseAssetBytes(app, release_linux_gui_asset);
    defer {
        if (linux_gui_bytes_opt) |bytes| app.allocator.free(bytes);
    }
    const linux_cli_bytes_opt = try readReleaseAssetBytes(app, release_linux_cli_asset);
    defer {
        if (linux_cli_bytes_opt) |bytes| app.allocator.free(bytes);
    }

    if (gui_bytes_opt == null or cli_bytes_opt == null or linux_gui_bytes_opt == null or linux_cli_bytes_opt == null) {
        if (gui_bytes_opt == null) try writer.print("- missing: {s}\n", .{release_gui_asset.relative_path});
        if (cli_bytes_opt == null) try writer.print("- missing: {s}\n", .{release_cli_asset.relative_path});
        if (linux_gui_bytes_opt == null) try writer.print("- missing: {s}\n", .{release_linux_gui_asset.relative_path});
        if (linux_cli_bytes_opt == null) try writer.print("- missing: {s}\n", .{release_linux_cli_asset.relative_path});
        try writer.writeAll("\nrun zig build install, zig build install-gui, zig build install-linux, and zig build install-linux-gui before creating release bundles\n");
        try app.process_console.appendBytes(.stdout, text.written());
        return false;
    }

    const gui_bytes = gui_bytes_opt.?;
    const cli_bytes = cli_bytes_opt.?;
    const linux_gui_bytes = linux_gui_bytes_opt.?;
    const linux_cli_bytes = linux_cli_bytes_opt.?;
    const gui_sha = try sha256Hex(gui_bytes);
    const cli_sha = try sha256Hex(cli_bytes);
    const linux_gui_sha = try sha256Hex(linux_gui_bytes);
    const linux_cli_sha = try sha256Hex(linux_cli_bytes);

    var windows_checksums: std.Io.Writer.Allocating = .init(app.allocator);
    defer windows_checksums.deinit();
    try windows_checksums.writer.print("{s}  {s}/zide-gui.exe\n", .{ gui_sha[0..], release_bundle_root });
    try windows_checksums.writer.print("{s}  {s}/zide.exe\n", .{ cli_sha[0..], release_bundle_root });
    const windows_checksum_bytes = try windows_checksums.toOwnedSlice();
    defer app.allocator.free(windows_checksum_bytes);

    var linux_checksums: std.Io.Writer.Allocating = .init(app.allocator);
    defer linux_checksums.deinit();
    try linux_checksums.writer.print("{s}  {s}/zide-gui\n", .{ linux_gui_sha[0..], release_linux_bundle_root });
    try linux_checksums.writer.print("{s}  {s}/zide\n", .{ linux_cli_sha[0..], release_linux_bundle_root });
    const linux_checksum_bytes = try linux_checksums.toOwnedSlice();
    defer app.allocator.free(linux_checksum_bytes);

    const release_note =
        "ZIDE Windows x86_64 release bundle\n" ++
        "\n" ++
        "- zide-gui.exe: Windows GUI IDE/workbench\n" ++
        "- zide.exe: CLI/TUI entry point\n" ++
        "- CHECKSUMS.sha256: SHA-256 values for files inside this archive\n" ++
        "\n" ++
        "Built by release.bundle with pure Zig ZIP writing.\n";

    const linux_release_note =
        "ZIDE Linux x86_64 release bundle\n" ++
        "\n" ++
        "- zide-gui: Linux GUI IDE/workbench using Zig-only direct X11 protocol\n" ++
        "- zide: Linux CLI/TUI IDE/workbench entry point\n" ++
        "- CHECKSUMS.sha256: SHA-256 values for files inside this archive\n" ++
        "\n" ++
        "Built by release.bundle with pure Zig TAR writing.\n";

    const zip_entries = [_]ZipInputEntry{
        .{ .name = release_bundle_root ++ "/zide-gui.exe", .bytes = gui_bytes },
        .{ .name = release_bundle_root ++ "/zide.exe", .bytes = cli_bytes },
        .{ .name = release_bundle_root ++ "/CHECKSUMS.sha256", .bytes = windows_checksum_bytes },
        .{ .name = release_bundle_root ++ "/ZIDE-RELEASE.txt", .bytes = release_note },
    };
    const zip_bytes = try buildStoredZip(app.allocator, zip_entries[0..]);
    defer app.allocator.free(zip_bytes);

    const tar_entries = [_]TarInputEntry{
        .{ .name = release_linux_bundle_root ++ "/zide-gui", .bytes = linux_gui_bytes, .mode = 0o755 },
        .{ .name = release_linux_bundle_root ++ "/zide", .bytes = linux_cli_bytes, .mode = 0o755 },
        .{ .name = release_linux_bundle_root ++ "/CHECKSUMS.sha256", .bytes = linux_checksum_bytes, .mode = 0o644 },
        .{ .name = release_linux_bundle_root ++ "/ZIDE-RELEASE.txt", .bytes = linux_release_note, .mode = 0o644 },
    };
    const tar_bytes = try buildStoredTar(app.allocator, tar_entries[0..]);
    defer app.allocator.free(tar_bytes);

    const release_dir = try std.fs.path.join(app.allocator, &.{ app.workspace.root_path, "zig-out/release" });
    defer app.allocator.free(release_dir);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, release_dir);

    const out_path = try std.fs.path.join(app.allocator, &.{ app.workspace.root_path, release_bundle_asset.relative_path });
    defer app.allocator.free(out_path);
    try writeFileAbsolute(out_path, zip_bytes);

    const linux_out_path = try std.fs.path.join(app.allocator, &.{ app.workspace.root_path, release_linux_bundle_asset.relative_path });
    defer app.allocator.free(linux_out_path);
    try writeFileAbsolute(linux_out_path, tar_bytes);

    const digest = (try hashReleaseAsset(app, release_bundle_asset)).?;
    const linux_digest = (try hashReleaseAsset(app, release_linux_bundle_asset)).?;
    try writer.print("- wrote : {s}\n", .{release_bundle_asset.relative_path});
    try writer.print("  size  : {d} bytes\n", .{digest.size});
    try writer.print("  sha256: {s}\n", .{digest.sha256[0..]});
    try writer.print("- wrote : {s}\n", .{release_linux_bundle_asset.relative_path});
    try writer.print("  size  : {d} bytes\n", .{linux_digest.size});
    try writer.print("  sha256: {s}\n", .{linux_digest.sha256[0..]});
    try writer.writeAll("\nnext: run release.manifests to refresh GitHub Release, winget, and Scoop drafts\n");

    try app.process_console.appendBytes(.stdout, text.written());
    return true;
}

fn buildStoredZip(allocator: std.mem.Allocator, entries: []const ZipInputEntry) ![]u8 {
    if (entries.len > std.math.maxInt(u16)) return error.ZipTooManyEntries;

    var zip: std.Io.Writer.Allocating = .init(allocator);
    errdefer zip.deinit();
    const writer = &zip.writer;

    const central_entries = try allocator.alloc(ZipCentralEntry, entries.len);
    defer allocator.free(central_entries);

    for (entries, 0..) |entry, index| {
        if (entry.name.len > std.math.maxInt(u16)) return error.ZipEntryNameTooLong;
        if (entry.bytes.len > std.math.maxInt(u32)) return error.ZipEntryTooLarge;
        if (zip.written().len > std.math.maxInt(u32)) return error.ZipTooLarge;

        const size: u32 = @intCast(entry.bytes.len);
        const offset: u32 = @intCast(zip.written().len);
        const crc32 = std.hash.Crc32.hash(entry.bytes);

        try writer.writeInt(u32, 0x04034b50, .little);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, crc32, .little);
        try writer.writeInt(u32, size, .little);
        try writer.writeInt(u32, size, .little);
        try writer.writeInt(u16, @intCast(entry.name.len), .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeAll(entry.name);
        try writer.writeAll(entry.bytes);

        central_entries[index] = .{
            .name = entry.name,
            .crc32 = crc32,
            .size = size,
            .local_header_offset = offset,
        };
    }

    if (zip.written().len > std.math.maxInt(u32)) return error.ZipTooLarge;
    const central_directory_offset: u32 = @intCast(zip.written().len);

    for (central_entries) |entry| {
        try writer.writeInt(u32, 0x02014b50, .little);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, entry.crc32, .little);
        try writer.writeInt(u32, entry.size, .little);
        try writer.writeInt(u32, entry.size, .little);
        try writer.writeInt(u16, @intCast(entry.name.len), .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, 0, .little);
        try writer.writeInt(u32, entry.local_header_offset, .little);
        try writer.writeAll(entry.name);
    }

    if (zip.written().len > std.math.maxInt(u32)) return error.ZipTooLarge;
    const central_directory_size: u32 = @intCast(zip.written().len - central_directory_offset);
    const entry_count: u16 = @intCast(entries.len);

    try writer.writeInt(u32, 0x06054b50, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, entry_count, .little);
    try writer.writeInt(u16, entry_count, .little);
    try writer.writeInt(u32, central_directory_size, .little);
    try writer.writeInt(u32, central_directory_offset, .little);
    try writer.writeInt(u16, 0, .little);

    return try zip.toOwnedSlice();
}

fn buildStoredTar(allocator: std.mem.Allocator, entries: []const TarInputEntry) ![]u8 {
    var tar: std.Io.Writer.Allocating = .init(allocator);
    errdefer tar.deinit();
    const writer = &tar.writer;

    for (entries) |entry| {
        var header: [512]u8 = undefined;
        try writeTarHeader(&header, entry.name, entry.mode, entry.bytes.len);
        try writer.writeAll(header[0..]);
        try writer.writeAll(entry.bytes);
        const padding = tarPadding(entry.bytes.len);
        if (padding > 0) try writer.splatByteAll(0, padding);
    }

    try writer.splatByteAll(0, 1024);
    return try tar.toOwnedSlice();
}

fn writeTarHeader(header: *[512]u8, name: []const u8, mode: u32, size: usize) !void {
    if (name.len == 0 or name.len > 100) return error.TarNameTooLong;
    if (size > 0o77777777777) return error.TarEntryTooLarge;

    @memset(header, 0);
    @memcpy(header[0..name.len], name);
    try writeTarOctal(header[100..108], mode);
    try writeTarOctal(header[108..116], 0);
    try writeTarOctal(header[116..124], 0);
    try writeTarOctal(header[124..136], size);
    try writeTarOctal(header[136..148], 0);
    @memset(header[148..156], ' ');
    header[156] = '0';
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    @memcpy(header[265..269], "zide");
    @memcpy(header[297..301], "zide");

    var checksum: u32 = 0;
    for (header) |byte| checksum += byte;
    try writeTarChecksum(header[148..156], checksum);
}

fn writeTarOctal(field: []u8, value: usize) !void {
    if (field.len < 2) return error.TarFieldTooSmall;
    @memset(field, '0');
    field[field.len - 1] = 0;

    var remaining = value;
    var index = field.len - 2;
    while (remaining > 0) {
        field[index] = @as(u8, @intCast('0' + (remaining & 7)));
        remaining >>= 3;
        if (index == 0) {
            if (remaining > 0) return error.TarNumberTooLarge;
            break;
        }
        index -= 1;
    }
}

fn writeTarChecksum(field: []u8, value: u32) !void {
    if (field.len != 8) return error.TarFieldTooSmall;
    @memset(field, '0');
    field[6] = 0;
    field[7] = ' ';

    var remaining = value;
    var index: usize = 5;
    while (remaining > 0) {
        field[index] = @as(u8, @intCast('0' + (remaining & 7)));
        remaining >>= 3;
        if (index == 0) {
            if (remaining > 0) return error.TarNumberTooLarge;
            break;
        }
        index -= 1;
    }
}

fn tarPadding(size: usize) usize {
    const rem = size % 512;
    return if (rem == 0) 0 else 512 - rem;
}

fn writeFileAbsolute(path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, bytes);
    try file.sync(std.Options.debug_io);
}

fn renderReleaseVerification(app: *app_mod.App) !bool {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("release bundle verification\n");
    try writer.writeAll("mode: pure Zig archive parsers + path boundary + embedded SHA-256 checks\n\n");

    const zip_bytes_opt = try readReleaseAssetBytes(app, release_bundle_asset);
    defer {
        if (zip_bytes_opt) |bytes| app.allocator.free(bytes);
    }
    const tar_bytes_opt = try readReleaseAssetBytes(app, release_linux_bundle_asset);
    defer {
        if (tar_bytes_opt) |bytes| app.allocator.free(bytes);
    }

    var ok = true;
    if (zip_bytes_opt) |bytes| {
        const sha = try sha256Hex(bytes);
        try writer.print("\nwindows bundle: {s}\n", .{release_bundle_asset.relative_path});
        try writer.print("- size  : {d} bytes\n", .{bytes.len});
        try writer.print("- sha256: {s}\n", .{sha[0..]});
        ok = (try verifyStoredReleaseZip(writer, bytes)) and ok;
    } else {
        try writer.print("- missing: {s}\n", .{release_bundle_asset.relative_path});
        ok = false;
    }

    if (tar_bytes_opt) |bytes| {
        const sha = try sha256Hex(bytes);
        try writer.print("\nlinux bundle: {s}\n", .{release_linux_bundle_asset.relative_path});
        try writer.print("- size  : {d} bytes\n", .{bytes.len});
        try writer.print("- sha256: {s}\n", .{sha[0..]});
        ok = (try verifyStoredReleaseTar(writer, bytes)) and ok;
    } else {
        try writer.print("- missing: {s}\n", .{release_linux_bundle_asset.relative_path});
        ok = false;
    }

    if (zip_bytes_opt == null or tar_bytes_opt == null) try writer.writeAll("\nrun release.bundle first\n");
    try app.process_console.appendBytes(.stdout, text.written());
    return ok;
}

fn renderReleasePreflight(app: *app_mod.App, argument: ?[]const u8) !bool {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    var blockers: usize = 0;
    var warnings: usize = 0;

    var overview = try git_repository.inspect(app.allocator, &app.workspace, .{});
    defer overview.deinit();

    const remote = firstGitHubRemote(&overview);
    const raw_version = std.mem.trim(u8, argument orelse "0.1.0", " \t\r\n");
    const package_version = packageVersionFromTag(if (raw_version.len == 0) "0.1.0" else raw_version);
    var allocated_tag: ?[]u8 = null;
    const tag = if (std.mem.startsWith(u8, package_version, "v"))
        package_version
    else tag: {
        allocated_tag = try std.fmt.allocPrint(app.allocator, "v{s}", .{package_version});
        break :tag allocated_tag.?;
    };
    defer if (allocated_tag) |value| app.allocator.free(value);

    try writer.writeAll("final release preflight\n");
    try writer.writeAll("mode: pure Zig local gate; no shell, no network, no upload\n\n");
    try writer.print("tag     : {s}\n", .{tag});
    try writer.print("version : {s}\n", .{package_version});
    try writer.print("trust   : {s}\n\n", .{@tagName(app.runtime.trust_state)});

    try writer.writeAll("project surface\n");
    try preflightRequired(writer, &blockers, workspaceHasPath(app, "README.md"), "README.md is present and remains human-written", .{});
    try preflightRequired(writer, &blockers, workspaceHasPath(app, "docs/security.md"), "docs/security.md explains the trust/security model", .{});
    try preflightRequired(writer, &blockers, workspaceHasPath(app, "LICENSE") or workspaceHasPath(app, "LICENSE.md") or workspaceHasPath(app, "COPYING"), "license file is present", .{});
    try preflightRequired(writer, &blockers, workspaceHasPrefix(app, ".github/workflows/"), "GitHub Actions workflow is present", .{});
    try preflightWarning(writer, &warnings, workspaceHasPath(app, ".github/workflows/pages.yml"), "GitHub Pages may need one-time repository enablement or a PAGES_TOKEN secret", .{});

    try writer.writeAll("\ngit state\n");
    try preflightRequired(writer, &blockers, overview.present, ".git metadata is readable without executing git", .{});
    try preflightRequired(writer, &blockers, remote != null, "GitHub remote is detected", .{});
    try preflightRequired(writer, &blockers, overview.branch != null, "current branch is known", .{});
    try preflightRequired(writer, &blockers, overview.commit != null, "current commit is known", .{});
    try preflightRequired(writer, &blockers, overview.changes.len == 0, "working tree has no local changes", .{});
    if (overview.branch) |branch| try writer.print("  branch : {s}\n", .{branch});
    if (overview.commit) |commit| try writer.print("  commit : {s}\n", .{commit});
    if (remote) |github| try writer.print("  remote : {s}\n", .{github.web_url});
    if (overview.changes.len > 0) try writer.print("  changes: {d}\n", .{overview.changes.len});

    try writer.writeAll("\nartifacts\n");
    const bundle = try hashReleaseAsset(app, release_bundle_asset);
    const linux_bundle = try hashReleaseAsset(app, release_linux_bundle_asset);
    const gui = try hashReleaseAsset(app, release_gui_asset);
    const cli = try hashReleaseAsset(app, release_cli_asset);
    const linux_gui = try hashReleaseAsset(app, release_linux_gui_asset);
    const linux_cli = try hashReleaseAsset(app, release_linux_cli_asset);
    try preflightRequired(writer, &blockers, gui != null, "GUI artifact exists: {s}", .{release_gui_asset.relative_path});
    try preflightRequired(writer, &blockers, cli != null, "CLI artifact exists: {s}", .{release_cli_asset.relative_path});
    try preflightRequired(writer, &blockers, linux_gui != null, "Linux GUI artifact exists: {s}", .{release_linux_gui_asset.relative_path});
    try preflightRequired(writer, &blockers, linux_cli != null, "Linux CLI/TUI artifact exists: {s}", .{release_linux_cli_asset.relative_path});
    try preflightRequired(writer, &blockers, bundle != null, "Windows release ZIP exists: {s}", .{release_bundle_asset.relative_path});
    try preflightRequired(writer, &blockers, linux_bundle != null, "Linux release TAR exists: {s}", .{release_linux_bundle_asset.relative_path});
    if (bundle) |item| {
        try writer.print("  win zip sha256: {s}\n", .{item.sha256[0..]});
        try writer.print("  win zip size  : {d} bytes\n", .{item.size});
    }
    if (linux_bundle) |item| {
        try writer.print("  linux tar sha256: {s}\n", .{item.sha256[0..]});
        try writer.print("  linux tar size  : {d} bytes\n", .{item.size});
    }

    try writer.writeAll("\nbundle verification\n");
    const zip_bytes_opt = try readReleaseAssetBytes(app, release_bundle_asset);
    defer {
        if (zip_bytes_opt) |bytes| app.allocator.free(bytes);
    }
    const tar_bytes_opt = try readReleaseAssetBytes(app, release_linux_bundle_asset);
    defer {
        if (tar_bytes_opt) |bytes| app.allocator.free(bytes);
    }
    if (zip_bytes_opt) |zip_bytes| {
        const verified = try verifyStoredReleaseZip(writer, zip_bytes);
        try preflightRequired(writer, &blockers, verified, "Windows ZIP passes structural and checksum verification", .{});
    } else {
        try preflightRequired(writer, &blockers, false, "Windows ZIP can be read for verification", .{});
    }
    if (tar_bytes_opt) |tar_bytes| {
        const verified = try verifyStoredReleaseTar(writer, tar_bytes);
        try preflightRequired(writer, &blockers, verified, "Linux TAR passes structural, checksum, and executable-mode verification", .{});
    } else {
        try preflightRequired(writer, &blockers, false, "Linux TAR can be read for verification", .{});
    }

    try writer.writeAll("\nrelease manifest readiness\n");
    try preflightRequired(writer, &blockers, bundle != null and linux_bundle != null, "GitHub release drafts can use Windows and Linux archive hashes", .{});
    try preflightWarning(writer, &warnings, package_version.len > 0 and !std.mem.eql(u8, package_version, "0.1.0"), "default version 0.1.0 is still in use; confirm this is intentional", .{});
    try preflightWarning(writer, &warnings, overview.changes.len == 0, "preflight should be rerun after committing these release changes", .{});

    try writer.writeAll("\nfinal verdict\n");
    if (blockers == 0) {
        try writer.print("READY: {d} blocker(s), {d} warning(s)\n", .{ blockers, warnings });
        if (bundle) |item| try writer.print("publish asset: {s}  sha256={s}\n", .{ release_bundle_asset.release_name, item.sha256[0..] });
        if (linux_bundle) |item| try writer.print("publish asset: {s}  sha256={s}\n", .{ release_linux_bundle_asset.release_name, item.sha256[0..] });
    } else {
        try writer.print("BLOCKED: {d} blocker(s), {d} warning(s)\n", .{ blockers, warnings });
        try writer.writeAll("fix blockers, rebuild with release.bundle, verify with release.verify, then rerun release.preflight\n");
    }

    try app.process_console.appendBytes(.stdout, text.written());
    return blockers == 0;
}

fn preflightRequired(writer: *std.Io.Writer, blockers: *usize, ok: bool, comptime fmt: []const u8, args: anytype) !void {
    if (ok) {
        try writer.writeAll("- [ok] ");
    } else {
        blockers.* += 1;
        try writer.writeAll("- [block] ");
    }
    try writer.print(fmt, args);
    try writer.writeByte('\n');
}

fn preflightWarning(writer: *std.Io.Writer, warnings: *usize, ok: bool, comptime fmt: []const u8, args: anytype) !void {
    if (ok) return;
    warnings.* += 1;
    try writer.writeAll("- [warn] ");
    try writer.print(fmt, args);
    try writer.writeByte('\n');
}

fn verifyStoredReleaseZip(writer: *std.Io.Writer, bytes: []const u8) !bool {
    var ok = true;
    var issues: usize = 0;

    const eocd_offset = findZipEndOfCentralDirectory(bytes) orelse {
        try reportZipIssue(writer, &ok, &issues, "end of central directory record not found", .{});
        try renderZipVerificationSummary(writer, ok, issues);
        return false;
    };

    if (bytes.len - eocd_offset < 22) {
        try reportZipIssue(writer, &ok, &issues, "end of central directory record is truncated", .{});
        try renderZipVerificationSummary(writer, ok, issues);
        return false;
    }

    const disk_number = readU16Le(bytes, eocd_offset + 4).?;
    const central_disk = readU16Le(bytes, eocd_offset + 6).?;
    const entries_this_disk = readU16Le(bytes, eocd_offset + 8).?;
    const entry_count = readU16Le(bytes, eocd_offset + 10).?;
    const central_size: usize = readU32Le(bytes, eocd_offset + 12).?;
    const central_offset: usize = readU32Le(bytes, eocd_offset + 16).?;
    const comment_len: usize = readU16Le(bytes, eocd_offset + 20).?;

    if (disk_number != 0 or central_disk != 0) {
        try reportZipIssue(writer, &ok, &issues, "multi-disk ZIP is not allowed", .{});
    }
    if (entries_this_disk != entry_count) {
        try reportZipIssue(writer, &ok, &issues, "central directory entry counts disagree", .{});
    }
    if (eocd_offset + 22 + comment_len != bytes.len) {
        try reportZipIssue(writer, &ok, &issues, "ZIP comment length does not match archive tail", .{});
    }
    if (central_offset > bytes.len or central_size > bytes.len - central_offset or central_offset + central_size > eocd_offset) {
        try reportZipIssue(writer, &ok, &issues, "central directory points outside the archive", .{});
        try renderZipVerificationSummary(writer, ok, issues);
        return false;
    }

    const central_end = central_offset + central_size;
    try writer.print("- entries: {d}\n", .{entry_count});
    try writer.print("- central directory: offset={d} size={d}\n", .{ central_offset, central_size });

    var pos = central_offset;
    var index: usize = 0;
    var gui_data: ?[]const u8 = null;
    var cli_data: ?[]const u8 = null;
    var checksum_data: ?[]const u8 = null;
    var note_seen = false;

    while (index < entry_count) : (index += 1) {
        if (central_end - pos < 46) {
            try reportZipIssue(writer, &ok, &issues, "central directory entry {d} is truncated", .{index});
            break;
        }
        if (readU32Le(bytes, pos).? != 0x02014b50) {
            try reportZipIssue(writer, &ok, &issues, "central directory entry {d} has a bad signature", .{index});
            break;
        }

        const method = readU16Le(bytes, pos + 10).?;
        const crc32 = readU32Le(bytes, pos + 16).?;
        const compressed_size: usize = readU32Le(bytes, pos + 20).?;
        const uncompressed_size: usize = readU32Le(bytes, pos + 24).?;
        const name_len: usize = readU16Le(bytes, pos + 28).?;
        const extra_len: usize = readU16Le(bytes, pos + 30).?;
        const comment_length: usize = readU16Le(bytes, pos + 32).?;
        const local_offset: usize = readU32Le(bytes, pos + 42).?;

        const name_start = pos + 46;
        const entry_end = name_start + name_len + extra_len + comment_length;
        if (entry_end > central_end) {
            try reportZipIssue(writer, &ok, &issues, "central directory entry {d} length points outside the central directory", .{index});
            break;
        }
        const name = bytes[name_start..][0..name_len];

        if (!isSafeZipEntryName(name)) {
            try reportZipIssue(writer, &ok, &issues, "unsafe entry path: {s}", .{name});
        }
        if (method != 0) {
            try reportZipIssue(writer, &ok, &issues, "entry {s} uses unsupported compression method {d}", .{ name, method });
        }
        if (compressed_size != uncompressed_size) {
            try reportZipIssue(writer, &ok, &issues, "entry {s} has mismatched stored sizes", .{name});
        }

        const data = verifyZipLocalEntry(writer, bytes, central_offset, name, method, crc32, compressed_size, local_offset, &ok, &issues);
        if (data) |entry_bytes| {
            if (std.mem.eql(u8, name, release_bundle_root ++ "/zide-gui.exe")) {
                if (gui_data != null) try reportZipIssue(writer, &ok, &issues, "duplicate GUI entry", .{});
                gui_data = entry_bytes;
            } else if (std.mem.eql(u8, name, release_bundle_root ++ "/zide.exe")) {
                if (cli_data != null) try reportZipIssue(writer, &ok, &issues, "duplicate CLI entry", .{});
                cli_data = entry_bytes;
            } else if (std.mem.eql(u8, name, release_bundle_root ++ "/CHECKSUMS.sha256")) {
                if (checksum_data != null) try reportZipIssue(writer, &ok, &issues, "duplicate checksum entry", .{});
                checksum_data = entry_bytes;
            } else if (std.mem.eql(u8, name, release_bundle_root ++ "/ZIDE-RELEASE.txt")) {
                if (note_seen) try reportZipIssue(writer, &ok, &issues, "duplicate release note entry", .{});
                note_seen = true;
            } else {
                try reportZipIssue(writer, &ok, &issues, "unexpected release entry: {s}", .{name});
            }
        }

        pos = entry_end;
    }

    if (pos != central_end) {
        try reportZipIssue(writer, &ok, &issues, "central directory was not consumed exactly", .{});
    }
    if (gui_data == null) try reportZipIssue(writer, &ok, &issues, "missing zide-gui.exe entry", .{});
    if (cli_data == null) try reportZipIssue(writer, &ok, &issues, "missing zide.exe entry", .{});
    if (checksum_data == null) try reportZipIssue(writer, &ok, &issues, "missing CHECKSUMS.sha256 entry", .{});
    if (!note_seen) try reportZipIssue(writer, &ok, &issues, "missing ZIDE-RELEASE.txt entry", .{});

    if (checksum_data) |checksums| {
        if (gui_data) |gui| {
            const gui_sha = try sha256Hex(gui);
            if (std.mem.indexOf(u8, checksums, gui_sha[0..]) == null) {
                try reportZipIssue(writer, &ok, &issues, "CHECKSUMS.sha256 does not contain the GUI SHA-256", .{});
            }
        }
        if (cli_data) |cli_bytes| {
            const cli_sha = try sha256Hex(cli_bytes);
            if (std.mem.indexOf(u8, checksums, cli_sha[0..]) == null) {
                try reportZipIssue(writer, &ok, &issues, "CHECKSUMS.sha256 does not contain the CLI SHA-256", .{});
            }
        }
    }

    try renderZipVerificationSummary(writer, ok, issues);
    return ok;
}

fn verifyZipLocalEntry(
    writer: *std.Io.Writer,
    bytes: []const u8,
    central_offset: usize,
    name: []const u8,
    method: u16,
    expected_crc32: u32,
    compressed_size: usize,
    local_offset: usize,
    ok: *bool,
    issues: *usize,
) ?[]const u8 {
    _ = method;
    if (local_offset > bytes.len or bytes.len - local_offset < 30) {
        reportZipIssue(writer, ok, issues, "local header for {s} points outside the archive", .{name}) catch {};
        return null;
    }
    if (readU32Le(bytes, local_offset).? != 0x04034b50) {
        reportZipIssue(writer, ok, issues, "local header for {s} has a bad signature", .{name}) catch {};
        return null;
    }

    const local_method = readU16Le(bytes, local_offset + 8).?;
    const local_crc32 = readU32Le(bytes, local_offset + 14).?;
    const local_compressed_size: usize = readU32Le(bytes, local_offset + 18).?;
    const local_uncompressed_size: usize = readU32Le(bytes, local_offset + 22).?;
    const local_name_len: usize = readU16Le(bytes, local_offset + 26).?;
    const local_extra_len: usize = readU16Le(bytes, local_offset + 28).?;
    const local_name_start = local_offset + 30;
    const data_start = local_name_start + local_name_len + local_extra_len;

    if (data_start > bytes.len or data_start > central_offset or compressed_size > central_offset - data_start) {
        reportZipIssue(writer, ok, issues, "entry data for {s} overlaps archive metadata or escapes the file", .{name}) catch {};
        return null;
    }

    const local_name = bytes[local_name_start..][0..local_name_len];
    if (!std.mem.eql(u8, local_name, name)) {
        reportZipIssue(writer, ok, issues, "central/local name mismatch for {s}", .{name}) catch {};
    }
    if (local_method != 0) {
        reportZipIssue(writer, ok, issues, "local header for {s} uses unsupported method {d}", .{ name, local_method }) catch {};
    }
    if (local_compressed_size != compressed_size or local_uncompressed_size != compressed_size) {
        reportZipIssue(writer, ok, issues, "local size fields do not match central directory for {s}", .{name}) catch {};
    }
    if (local_crc32 != expected_crc32) {
        reportZipIssue(writer, ok, issues, "local CRC32 does not match central directory for {s}", .{name}) catch {};
    }

    const data = bytes[data_start..][0..compressed_size];
    const actual_crc32 = std.hash.Crc32.hash(data);
    if (actual_crc32 != expected_crc32) {
        reportZipIssue(writer, ok, issues, "CRC32 mismatch for {s}", .{name}) catch {};
    } else {
        writer.print("- [ok] {s} ({d} bytes)\n", .{ name, compressed_size }) catch {};
    }

    return data;
}

fn reportZipIssue(writer: *std.Io.Writer, ok: *bool, issues: *usize, comptime fmt: []const u8, args: anytype) !void {
    ok.* = false;
    issues.* += 1;
    try writer.writeAll("- [issue] ");
    try writer.print(fmt, args);
    try writer.writeByte('\n');
}

fn renderZipVerificationSummary(writer: *std.Io.Writer, ok: bool, issues: usize) !void {
    if (ok) {
        try writer.writeAll("\nverification: OK\n");
    } else {
        try writer.print("\nverification: FAILED ({d} issue(s))\n", .{issues});
    }
}

fn verifyStoredReleaseTar(writer: *std.Io.Writer, bytes: []const u8) !bool {
    var ok = true;
    var issues: usize = 0;
    var pos: usize = 0;
    var entry_count: usize = 0;
    var gui_data: ?[]const u8 = null;
    var cli_data: ?[]const u8 = null;
    var checksum_data: ?[]const u8 = null;
    var note_seen = false;
    var gui_mode: ?u32 = null;
    var cli_mode: ?u32 = null;

    while (pos + 512 <= bytes.len) {
        const header = bytes[pos..][0..512];
        if (isZeroBlock(header)) {
            if (pos + 1024 > bytes.len or !isZeroBlock(bytes[pos + 512 ..][0..512])) {
                try reportTarIssue(writer, &ok, &issues, "TAR is missing the second zero end block", .{});
            }
            pos += 1024;
            break;
        }

        const name = tarString(header[0..100]);
        const mode = parseTarOctal(header[100..108]) orelse {
            try reportTarIssue(writer, &ok, &issues, "entry {d} has invalid mode", .{entry_count});
            return false;
        };
        const size = parseTarOctal(header[124..136]) orelse {
            try reportTarIssue(writer, &ok, &issues, "entry {d} has invalid size", .{entry_count});
            return false;
        };
        const stored_checksum = parseTarOctal(header[148..156]) orelse {
            try reportTarIssue(writer, &ok, &issues, "entry {d} has invalid checksum field", .{entry_count});
            return false;
        };
        const computed_checksum = tarHeaderChecksum(header);
        const typeflag = header[156];

        if (name.len == 0 or !isSafeTarEntryName(name)) {
            try reportTarIssue(writer, &ok, &issues, "unsafe TAR entry path: {s}", .{name});
        }
        if (stored_checksum != computed_checksum) {
            try reportTarIssue(writer, &ok, &issues, "header checksum mismatch for {s}", .{name});
        }
        if (!std.mem.eql(u8, header[257..263], "ustar\x00")) {
            try reportTarIssue(writer, &ok, &issues, "entry {s} is not ustar", .{name});
        }
        if (typeflag != '0' and typeflag != 0) {
            try reportTarIssue(writer, &ok, &issues, "entry {s} uses unsupported typeflag {d}", .{ name, typeflag });
        }

        const data_start = pos + 512;
        if (size > bytes.len - data_start) {
            try reportTarIssue(writer, &ok, &issues, "entry {s} data escapes archive", .{name});
            return false;
        }
        const data = bytes[data_start..][0..size];

        if (std.mem.eql(u8, name, release_linux_bundle_root ++ "/zide-gui")) {
            if (gui_data != null) try reportTarIssue(writer, &ok, &issues, "duplicate Linux zide-gui entry", .{});
            gui_data = data;
            gui_mode = @intCast(mode);
        } else if (std.mem.eql(u8, name, release_linux_bundle_root ++ "/zide")) {
            if (cli_data != null) try reportTarIssue(writer, &ok, &issues, "duplicate Linux zide entry", .{});
            cli_data = data;
            cli_mode = @intCast(mode);
        } else if (std.mem.eql(u8, name, release_linux_bundle_root ++ "/CHECKSUMS.sha256")) {
            if (checksum_data != null) try reportTarIssue(writer, &ok, &issues, "duplicate Linux checksum entry", .{});
            checksum_data = data;
        } else if (std.mem.eql(u8, name, release_linux_bundle_root ++ "/ZIDE-RELEASE.txt")) {
            if (note_seen) try reportTarIssue(writer, &ok, &issues, "duplicate Linux release note entry", .{});
            note_seen = true;
        } else {
            try reportTarIssue(writer, &ok, &issues, "unexpected Linux release entry: {s}", .{name});
        }

        try writer.print("- [ok] {s} ({d} bytes, mode {o})\n", .{ name, size, mode });
        pos = data_start + size + tarPadding(size);
        entry_count += 1;
    }

    if (pos > bytes.len) try reportTarIssue(writer, &ok, &issues, "TAR cursor moved beyond archive length", .{});
    if (entry_count == 0) try reportTarIssue(writer, &ok, &issues, "TAR has no entries", .{});
    if (gui_data == null) try reportTarIssue(writer, &ok, &issues, "missing Linux zide-gui entry", .{});
    if (cli_data == null) try reportTarIssue(writer, &ok, &issues, "missing Linux zide entry", .{});
    if (checksum_data == null) try reportTarIssue(writer, &ok, &issues, "missing Linux CHECKSUMS.sha256 entry", .{});
    if (!note_seen) try reportTarIssue(writer, &ok, &issues, "missing Linux ZIDE-RELEASE.txt entry", .{});
    if (gui_mode) |mode| {
        if ((mode & 0o111) == 0) try reportTarIssue(writer, &ok, &issues, "Linux zide-gui entry is not executable", .{});
    }
    if (cli_mode) |mode| {
        if ((mode & 0o111) == 0) try reportTarIssue(writer, &ok, &issues, "Linux zide entry is not executable", .{});
    }

    if (checksum_data) |checksums| {
        if (gui_data) |gui_bytes| {
            const gui_sha = try sha256Hex(gui_bytes);
            if (std.mem.indexOf(u8, checksums, gui_sha[0..]) == null) {
                try reportTarIssue(writer, &ok, &issues, "CHECKSUMS.sha256 does not contain the Linux GUI SHA-256", .{});
            }
        }
        if (cli_data) |cli_bytes| {
            const cli_sha = try sha256Hex(cli_bytes);
            if (std.mem.indexOf(u8, checksums, cli_sha[0..]) == null) {
                try reportTarIssue(writer, &ok, &issues, "CHECKSUMS.sha256 does not contain the Linux CLI SHA-256", .{});
            }
        }
    }

    try renderTarVerificationSummary(writer, ok, issues);
    return ok;
}

fn isZeroBlock(block: []const u8) bool {
    for (block) |byte| if (byte != 0) return false;
    return true;
}

fn tarString(field: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    var trimmed_end = end;
    while (trimmed_end > 0 and field[trimmed_end - 1] == ' ') : (trimmed_end -= 1) {}
    return field[0..trimmed_end];
}

fn parseTarOctal(field: []const u8) ?usize {
    const value = std.mem.trim(u8, field, " \x00");
    if (value.len == 0) return 0;
    var result: usize = 0;
    for (value) |byte| {
        if (byte < '0' or byte > '7') return null;
        result = result * 8 + (byte - '0');
    }
    return result;
}

fn tarHeaderChecksum(header: []const u8) usize {
    var sum: usize = 0;
    for (header, 0..) |byte, index| {
        sum += if (index >= 148 and index < 156) ' ' else byte;
    }
    return sum;
}

fn isSafeTarEntryName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.startsWith(u8, name, "/") or std.mem.startsWith(u8, name, "\\")) return false;
    if (name.len >= 2 and std.ascii.isAlphabetic(name[0]) and name[1] == ':') return false;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;

    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn reportTarIssue(writer: *std.Io.Writer, ok: *bool, issues: *usize, comptime fmt: []const u8, args: anytype) !void {
    ok.* = false;
    issues.* += 1;
    try writer.writeAll("- [issue] ");
    try writer.print(fmt, args);
    try writer.writeByte('\n');
}

fn renderTarVerificationSummary(writer: *std.Io.Writer, ok: bool, issues: usize) !void {
    if (ok) {
        try writer.writeAll("\nlinux tar verification: OK\n");
    } else {
        try writer.print("\nlinux tar verification: FAILED ({d} issue(s))\n", .{issues});
    }
}

fn findZipEndOfCentralDirectory(bytes: []const u8) ?usize {
    if (bytes.len < 22) return null;
    const earliest = if (bytes.len > 22 + 65535) bytes.len - (22 + 65535) else 0;
    var index = bytes.len - 22;
    while (true) {
        if (std.mem.eql(u8, bytes[index..][0..4], "PK\x05\x06")) return index;
        if (index == earliest) break;
        index -= 1;
    }
    return null;
}

fn isSafeZipEntryName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.startsWith(u8, name, "/") or std.mem.startsWith(u8, name, "\\")) return false;
    if (name.len >= 2 and std.ascii.isAlphabetic(name[0]) and name[1] == ':') return false;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;

    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn readU16Le(bytes: []const u8, offset: usize) ?u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return null;
    return @as(u16, bytes[offset]) |
        (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32Le(bytes: []const u8, offset: usize) ?u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return null;
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn renderReleaseManifests(app: *app_mod.App, argument: ?[]const u8) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    var overview = try git_repository.inspect(app.allocator, &app.workspace, .{});
    defer overview.deinit();
    const remote = firstGitHubRemote(&overview);

    const raw_version = std.mem.trim(u8, argument orelse "0.1.0", " \t\r\n");
    const package_version = packageVersionFromTag(if (raw_version.len == 0) "0.1.0" else raw_version);
    var allocated_tag: ?[]u8 = null;
    const tag = if (std.mem.startsWith(u8, package_version, "v"))
        package_version
    else tag: {
        allocated_tag = try std.fmt.allocPrint(app.allocator, "v{s}", .{package_version});
        break :tag allocated_tag.?;
    };
    defer if (allocated_tag) |value| app.allocator.free(value);

    const homepage = if (remote) |github| github.web_url else "https://github.com/OWNER/REPO";
    const owner = if (remote) |github| github.owner else "Publisher";
    const repo = if (remote) |github| github.repo else "zide";
    const bundle = try hashReleaseAsset(app, release_bundle_asset);
    const linux_bundle = try hashReleaseAsset(app, release_linux_bundle_asset);
    const gui = try hashReleaseAsset(app, release_gui_asset);
    const cli = try hashReleaseAsset(app, release_cli_asset);
    const linux_gui = try hashReleaseAsset(app, release_linux_gui_asset);
    const linux_cli = try hashReleaseAsset(app, release_linux_cli_asset);

    try writer.writeAll("release manifest drafts\n");
    try writer.writeAll("mode: pure Zig; hashes come from local artifacts; verify final schema before submitting upstream\n\n");
    try writer.print("repo    : {s}\n", .{homepage});
    try writer.print("tag     : {s}\n", .{tag});
    try writer.print("version : {s}\n", .{package_version});
    if (bundle == null or linux_bundle == null) {
        try writer.writeAll("missing : run release.bundle after zig build install, zig build install-gui, zig build install-linux, and zig build install-linux-gui for preferred archive assets\n");
    }

    try writer.writeAll("\nGitHub Release assets\n");
    if (bundle) |item| try renderReleaseAssetUrl(writer, homepage, tag, item);
    if (linux_bundle) |item| try renderReleaseAssetUrl(writer, homepage, tag, item);
    if (gui) |item| try renderReleaseAssetUrl(writer, homepage, tag, item);
    if (cli) |item| try renderReleaseAssetUrl(writer, homepage, tag, item);
    if (linux_gui) |item| try renderReleaseAssetUrl(writer, homepage, tag, item);
    if (linux_cli) |item| try renderReleaseAssetUrl(writer, homepage, tag, item);
    if (bundle == null and linux_bundle == null and gui == null and cli == null and linux_gui == null and linux_cli == null) try writer.writeAll("- no local artifacts found yet\n");

    try writer.writeAll("\nwinget portable draft\n");
    try writer.print(
        \\PackageIdentifier: {s}.{s}
        \\PackageVersion: {s}
        \\PackageLocale: en-US
        \\Publisher: {s}
        \\PackageName: ZIDE
        \\License: TODO
        \\ShortDescription: Secure Zig-native IDE/workbench with visible trust boundaries.
        \\Installers:
        \\
    , .{ owner, repo, package_version, owner });
    if (bundle) |item| {
        try renderWingetZipInstaller(writer, homepage, tag, item);
    } else {
        if (gui) |item| try renderWingetInstaller(writer, homepage, tag, item, "zide-gui");
        if (cli) |item| try renderWingetInstaller(writer, homepage, tag, item, "zide");
    }
    try writer.writeAll(
        \\ManifestType: singleton
        \\ManifestVersion: 1.9.0
        \\
    );

    try writer.writeAll("\nScoop bucket draft\n");
    try writer.writeAll("{\n");
    try writer.print(
        \\  "version": "{s}",
        \\  "description": "Secure Zig-native IDE/workbench with visible trust boundaries.",
        \\  "homepage": "{s}",
        \\  "license": "TODO",
        \\  "architecture": {{
        \\    "64bit": {{
        \\
    , .{ package_version, homepage });
    try renderScoopUrlAndHash(writer, homepage, tag, bundle, gui, cli);
    try writer.writeAll(
        \\    }
        \\  },
        \\  "bin": "zide.exe",
        \\  "shortcuts": [["zide-gui.exe", "ZIDE"]]
        \\}
        \\
    );

    try writer.writeAll("\nnext packaging move\n");
    try writer.print("- Preferred asset: zig-out/release/{s}; keep the same tag {s}.\n", .{ release_bundle_asset.release_name, tag });
    try writer.print("- GitHub CLI shape: gh release create {s} zig-out/release/{s} --draft --prerelease\n", .{ tag, release_bundle_asset.release_name });

    try app.process_console.appendBytes(.stdout, text.written());
}

fn packageVersionFromTag(value: []const u8) []const u8 {
    if (value.len > 1 and (value[0] == 'v' or value[0] == 'V') and std.ascii.isDigit(value[1])) {
        return value[1..];
    }
    return value;
}

fn renderReleaseAssetUrl(writer: *std.Io.Writer, homepage: []const u8, tag: []const u8, item: ReleaseAssetDigest) !void {
    try writer.print("- {s}: {s}/releases/download/{s}/{s}\n", .{ item.asset.label, homepage, tag, item.asset.release_name });
    try writer.print("  sha256: {s}\n", .{item.sha256[0..]});
}

fn renderWingetInstaller(writer: *std.Io.Writer, homepage: []const u8, tag: []const u8, item: ReleaseAssetDigest, command_name: []const u8) !void {
    try writer.print(
        \\- Architecture: x64
        \\  InstallerType: portable
        \\  InstallerUrl: {s}/releases/download/{s}/{s}
        \\  InstallerSha256: {s}
        \\  Commands:
        \\  - {s}
        \\
    , .{ homepage, tag, item.asset.release_name, item.sha256[0..], command_name });
}

fn renderWingetZipInstaller(writer: *std.Io.Writer, homepage: []const u8, tag: []const u8, item: ReleaseAssetDigest) !void {
    try writer.print(
        \\- Architecture: x64
        \\  InstallerType: zip
        \\  NestedInstallerType: portable
        \\  NestedInstallerFiles:
        \\  - RelativeFilePath: {s}\zide-gui.exe
        \\    PortableCommandAlias: zide-gui
        \\  - RelativeFilePath: {s}\zide.exe
        \\    PortableCommandAlias: zide
        \\  InstallerUrl: {s}/releases/download/{s}/{s}
        \\  InstallerSha256: {s}
        \\
    , .{ release_bundle_root, release_bundle_root, homepage, tag, item.asset.release_name, item.sha256[0..] });
}

fn renderScoopUrlAndHash(writer: *std.Io.Writer, homepage: []const u8, tag: []const u8, bundle: ?ReleaseAssetDigest, gui: ?ReleaseAssetDigest, cli: ?ReleaseAssetDigest) !void {
    if (bundle) |item| {
        try writer.print(
            \\      "url": "{s}/releases/download/{s}/{s}",
            \\      "hash": "{s}",
            \\      "extract_dir": "{s}"
            \\
        , .{ homepage, tag, item.asset.release_name, item.sha256[0..], release_bundle_root });
        return;
    }
    if (gui != null and cli != null) {
        try writer.print(
            \\      "url": [
            \\        "{s}/releases/download/{s}/{s}",
            \\        "{s}/releases/download/{s}/{s}"
            \\      ],
            \\      "hash": [
            \\        "{s}",
            \\        "{s}"
            \\      ]
            \\
        , .{
            homepage,
            tag,
            gui.?.asset.release_name,
            homepage,
            tag,
            cli.?.asset.release_name,
            gui.?.sha256[0..],
            cli.?.sha256[0..],
        });
        return;
    }
    if (gui) |item| {
        try writer.print(
            \\      "url": "{s}/releases/download/{s}/{s}",
            \\      "hash": "{s}"
            \\
        , .{ homepage, tag, item.asset.release_name, item.sha256[0..] });
        return;
    }
    if (cli) |item| {
        try writer.print(
            \\      "url": "{s}/releases/download/{s}/{s}",
            \\      "hash": "{s}"
            \\
        , .{ homepage, tag, item.asset.release_name, item.sha256[0..] });
        return;
    }
    try writer.writeAll(
        \\      "url": "https://github.com/OWNER/REPO/releases/download/v0.1.0/zide-windows-x86_64.zip",
        \\      "hash": "TODO"
        \\
    );
}

fn checkMark(ok: bool) []const u8 {
    return if (ok) "[ok]" else "[missing]";
}

fn workspaceHasPath(app: *const app_mod.App, relative: []const u8) bool {
    for (app.workspace.entries.items) |entry| {
        if (pathEqualIgnoreCaseAndSlash(entry.path, relative)) return true;
    }
    return false;
}

fn workspaceHasPrefix(app: *const app_mod.App, prefix: []const u8) bool {
    for (app.workspace.entries.items) |entry| {
        if (pathStartsWithIgnoreCaseAndSlash(entry.path, prefix)) return true;
    }
    return false;
}

fn pathEqualIgnoreCaseAndSlash(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (normalizePathByte(left) != normalizePathByte(right)) return false;
    }
    return true;
}

fn pathStartsWithIgnoreCaseAndSlash(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return pathEqualIgnoreCaseAndSlash(value[0..prefix.len], prefix);
}

fn pathOrderIgnoreCaseAndSlash(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);
    for (a[0..min_len], b[0..min_len]) |left, right| {
        const normalized_left = normalizePathByte(left);
        const normalized_right = normalizePathByte(right);
        if (normalized_left < normalized_right) return .lt;
        if (normalized_left > normalized_right) return .gt;
    }
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return .eq;
}

fn normalizePathByte(byte: u8) u8 {
    return if (byte == '\\') '/' else std.ascii.toLower(byte);
}

fn workspaceFileExists(app: *const app_mod.App, relative: []const u8) bool {
    const path = std.fs.path.join(app.allocator, &.{ app.workspace.root_path, relative }) catch return false;
    defer app.allocator.free(path);
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

fn renderGitOverview(app: *app_mod.App, overview: *const git_repository.Overview) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("git/github overview (pure Zig, no git executable)\n");
    if (!overview.present) {
        try writer.writeAll("no .git metadata found for this workspace\n");
        try app.process_console.appendBytes(.stdout, text.written());
        return;
    }

    try writer.print("branch    : {s}\n", .{overview.branch orelse "(detached or unknown)"});
    if (overview.commit) |commit| try writer.print("commit    : {s}\n", .{commit});
    if (overview.index_version) |version| {
        try writer.print("index     : v{d}, tracked={d}, clean={d}\n", .{ version, overview.index_entries, overview.clean_tracked });
    } else if (overview.unsupported_index) {
        try writer.writeAll("index     : unsupported Git index version; file status skipped\n");
    } else {
        try writer.writeAll("index     : not found\n");
    }
    try writer.print("workflows : {d} GitHub Actions workflow file(s)\n", .{overview.workflow_files});

    if (overview.remotes.len == 0) {
        try writer.writeAll("remotes   : none\n");
    } else {
        try writer.writeAll("remotes\n");
        for (overview.remotes) |remote| {
            try writer.print("- {s}: {s}\n", .{ remote.name, remote.url });
            if (remote.github) |github| {
                try writer.print("  github : {s}\n", .{github.web_url});
                try writer.print("  actions: {s}\n", .{github.actions_url});
            }
        }
    }

    try writer.print("ignored   : {d} untracked file(s) hidden by .gitignore\n", .{overview.ignored_untracked});

    try writer.print("changes   : {d}", .{overview.changes.len});
    if (overview.change_limit_hit) try writer.writeAll(" (truncated)");
    try writer.writeByte('\n');

    const limit = @min(overview.changes.len, 80);
    for (overview.changes[0..limit]) |change| {
        if (change.diff_available) {
            try writer.print("{s} +{d} -{d} {s}\n", .{ gitChangeLabel(change.status), change.additions, change.deletions, change.path });
        } else {
            try writer.print("{s} diff:n/a {s}\n", .{ gitChangeLabel(change.status), change.path });
        }
    }
    if (overview.changes.len > limit) {
        try writer.print("... {d} more changes\n", .{overview.changes.len - limit});
    }
    if (overview.changes.len == 0) {
        try writer.writeAll("working tree appears clean against the Git index\n");
    }

    try app.process_console.appendBytes(.stdout, text.written());
}

const GitHubAuth = struct {
    allocator: std.mem.Allocator,
    token: ?github_client.Token = null,

    fn init(app: *app_mod.App) !GitHubAuth {
        return .{
            .allocator = app.allocator,
            .token = try github_client.tokenFromEnv(app.allocator, app.environ),
        };
    }

    fn deinit(self: *GitHubAuth) void {
        if (self.token) |*token| token.deinit(self.allocator);
        self.* = undefined;
    }

    fn options(self: *const GitHubAuth) github_client.FetchOptions {
        return .{
            .token = if (self.token) |token| token.value else null,
            .token_source = if (self.token) |token| token.source else .none,
        };
    }

    fn hasToken(self: *const GitHubAuth) bool {
        return self.token != null;
    }
};

fn fetchGitHubLive(app: *app_mod.App) !Result {
    var overview = try git_repository.inspect(app.allocator, &app.workspace, .{});
    defer overview.deinit();

    const remote = firstGitHubRemote(&overview) orelse {
        try appendConsole(app, .stdout, "github live: no GitHub remote found\n", .{});
        return .{ .blocked = "no GitHub remote found" };
    };

    var auth = try GitHubAuth.init(app);
    defer auth.deinit();

    var live = github_client.fetchLiveOverview(app.allocator, app.io, remote.owner, remote.repo, auth.options()) catch |err| {
        try appendConsole(app, .stderr, "github live fetch failed for {s}/{s}: {s}\n", .{ remote.owner, remote.repo, @errorName(err) });
        return .{ .blocked = "github live fetch failed" };
    };
    defer live.deinit();

    try renderGitHubLive(app, &live);
    return .{ .completed = "github live overview fetched" };
}

fn fetchGitHubIssues(app: *app_mod.App) !Result {
    var overview = try git_repository.inspect(app.allocator, &app.workspace, .{});
    defer overview.deinit();

    const remote = firstGitHubRemote(&overview) orelse {
        try appendConsole(app, .stdout, "github issues: no GitHub remote found\n", .{});
        return .{ .blocked = "no GitHub remote found" };
    };

    var auth = try GitHubAuth.init(app);
    defer auth.deinit();

    const issues = github_client.fetchIssues(app.allocator, app.io, remote.owner, remote.repo, auth.options()) catch |err| {
        try appendConsole(app, .stderr, "github issues fetch failed for {s}/{s}: {s}\n", .{ remote.owner, remote.repo, @errorName(err) });
        return .{ .blocked = "github issues fetch failed" };
    };
    defer {
        for (issues) |*issue| issue.deinit(app.allocator);
        if (issues.len > 0) app.allocator.free(issues);
    }

    try renderGitHubIssues(app, remote.owner, remote.repo, issues, auth.options().token_source);
    return .{ .completed = "github issues fetched" };
}

fn fetchGitHubActionsFailureLog(app: *app_mod.App) !Result {
    var overview = try git_repository.inspect(app.allocator, &app.workspace, .{});
    defer overview.deinit();

    const remote = firstGitHubRemote(&overview) orelse {
        try appendConsole(app, .stdout, "github actions failures: no GitHub remote found\n", .{});
        return .{ .blocked = "no GitHub remote found" };
    };

    var auth = try GitHubAuth.init(app);
    defer auth.deinit();

    var failure = github_client.fetchLatestFailureLog(app.allocator, app.io, remote.owner, remote.repo, auth.options()) catch |err| {
        try appendConsole(app, .stderr, "github actions failure log fetch failed for {s}/{s}: {s}\n", .{ remote.owner, remote.repo, @errorName(err) });
        return .{ .blocked = "github actions failure log fetch failed" };
    };
    defer failure.deinit(app.allocator);

    try renderGitHubFailureLog(app, remote.owner, remote.repo, &failure, auth.options().token_source);
    return .{ .completed = "github actions failure log fetched" };
}

fn createDraftGitHubPullRequest(app: *app_mod.App, argument: ?[]const u8) !Result {
    var overview = try git_repository.inspect(app.allocator, &app.workspace, .{});
    defer overview.deinit();

    const remote = firstGitHubRemote(&overview) orelse {
        try appendConsole(app, .stdout, "github pr create: no GitHub remote found\n", .{});
        return .{ .blocked = "no GitHub remote found" };
    };

    const branch = overview.branch orelse {
        try appendConsole(app, .stderr, "github pr create blocked: current Git branch is unknown\n", .{});
        return .{ .blocked = "current Git branch is unknown" };
    };

    var auth = try GitHubAuth.init(app);
    defer auth.deinit();
    if (!auth.hasToken()) {
        try appendConsole(app, .stderr, "github pr create blocked: set GITHUB_TOKEN or GH_TOKEN first\n", .{});
        return .{ .blocked = "GITHUB_TOKEN or GH_TOKEN required" };
    }

    var repository = github_client.fetchRepository(app.allocator, app.io, remote.owner, remote.repo, auth.options()) catch |err| {
        try appendConsole(app, .stderr, "github repository fetch failed for {s}/{s}: {s}\n", .{ remote.owner, remote.repo, @errorName(err) });
        return .{ .blocked = "github repository fetch failed" };
    };
    defer repository.deinit(app.allocator);

    const base = if (repository.default_branch.len > 0) repository.default_branch else "main";
    if (std.mem.eql(u8, branch, base)) {
        try appendConsole(app, .stderr, "github pr create blocked: current branch {s} is the base branch\n", .{branch});
        return .{ .blocked = "current branch is the base branch" };
    }

    const trimmed_title = if (argument) |value| std.mem.trim(u8, value, " \t\r\n") else "";
    const title = if (trimmed_title.len > 0)
        try app.allocator.dupe(u8, trimmed_title)
    else
        try std.fmt.allocPrint(app.allocator, "Draft: {s}", .{branch});
    defer app.allocator.free(title);

    const body = try std.fmt.allocPrint(app.allocator,
        \\Created from ZIDE secure GitHub integration.
        \\
        \\Head: {s}
        \\Base: {s}
        \\Workspace trust: {s}
        \\
        \\ZIDE sends this network write only through an explicit command with a GitHub token.
        \\
    , .{ branch, base, @tagName(app.runtime.trust_state) });
    defer app.allocator.free(body);

    var pull = github_client.createDraftPullRequest(app.allocator, app.io, remote.owner, remote.repo, auth.options(), .{
        .title = title,
        .head = branch,
        .base = base,
        .body = body,
        .draft = true,
    }) catch |err| {
        try appendConsole(app, .stderr, "github draft PR create failed for {s}/{s}: {s}\n", .{ remote.owner, remote.repo, @errorName(err) });
        return .{ .blocked = "github draft PR create failed" };
    };
    defer pull.deinit(app.allocator);

    try renderCreatedPullRequest(app, remote.owner, remote.repo, base, branch, &pull, auth.options().token_source);
    return .{ .completed = "github draft pull request created" };
}

fn firstGitHubRemote(overview: *const git_repository.Overview) ?git_repository.GitHubRemote {
    for (overview.remotes) |remote| {
        if (remote.github) |github| return github;
    }
    return null;
}

fn renderGitHubLive(app: *app_mod.App, live: *const github_client.LiveOverview) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("github live overview (read-only REST API)\n");
    try writer.print("repo      : {s}\n", .{live.repository.full_name});
    try writer.print("url       : {s}\n", .{live.repository.html_url});
    try writer.print("branch    : {s}\n", .{live.repository.default_branch});
    try writer.print("visibility: {s}\n", .{if (live.repository.private) "private" else "public"});
    try writer.print("token     : {s}\n", .{tokenSourceLabel(live.token_source)});
    try writer.print("stars     : {d}, forks={d}, open issues={d}\n", .{ live.repository.stargazers_count, live.repository.forks_count, live.repository.open_issues_count });

    try writer.print("open PRs  : {d} shown\n", .{live.pulls.len});
    for (live.pulls, 0..) |pull, index| {
        if (index >= 8) {
            try writer.print("... {d} more PRs in fetched page\n", .{live.pulls.len - index});
            break;
        }
        try writer.print("#{d} {s}{s} by {s}\n", .{
            pull.number,
            if (pull.draft) "[draft] " else "",
            pull.title,
            pull.user,
        });
    }

    try writer.print("actions   : {d} recent run(s)\n", .{live.runs.len});
    for (live.runs, 0..) |run, index| {
        if (index >= 5) break;
        try writer.print("- #{d} {s}: {s}/{s}\n", .{ run.id, run.name, run.status, run.conclusion });
    }

    try app.process_console.appendBytes(.stdout, text.written());
}

fn renderGitHubIssues(
    app: *app_mod.App,
    owner: []const u8,
    repo: []const u8,
    issues: []const github_client.Issue,
    token_source: github_client.TokenSource,
) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("github issues (read-only REST API)\n");
    try writer.print("repo : {s}/{s}\n", .{ owner, repo });
    try writer.print("token: {s}\n", .{tokenSourceLabel(token_source)});
    try writer.print("open : {d} item(s) shown\n", .{issues.len});

    for (issues, 0..) |issue, index| {
        if (index >= 20) break;
        try writer.print("#{d} [{s}] {s} by {s} comments={d}\n", .{
            issue.number,
            if (issue.pull_request) "PR" else "issue",
            issue.title,
            issue.user,
            issue.comments,
        });
        if (issue.html_url.len > 0) try writer.print("  {s}\n", .{issue.html_url});
    }
    if (issues.len == 0) {
        try writer.writeAll("no open issues or pull requests returned\n");
    }

    try app.process_console.appendBytes(.stdout, text.written());
}

fn renderGitHubFailureLog(
    app: *app_mod.App,
    owner: []const u8,
    repo: []const u8,
    failure: *const github_client.FailureLog,
    token_source: github_client.TokenSource,
) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("github actions latest failure log (read-only REST API)\n");
    try writer.print("repo : {s}/{s}\n", .{ owner, repo });
    try writer.print("token: {s}\n", .{tokenSourceLabel(token_source)});
    try writer.print("run  : #{d} {s} {s}/{s}\n", .{ failure.run.id, failure.run.name, failure.run.status, failure.run.conclusion });
    if (failure.run.html_url.len > 0) try writer.print("       {s}\n", .{failure.run.html_url});
    try writer.print("job  : #{d} {s} {s}/{s}\n", .{ failure.job.id, failure.job.name, failure.job.status, failure.job.conclusion });
    if (failure.job.html_url.len > 0) try writer.print("       {s}\n", .{failure.job.html_url});
    if (failure.truncated) {
        try writer.writeAll("log  : tail excerpt, truncated to 64 KiB\n");
    } else {
        try writer.writeAll("log  : full fetched job log\n");
    }
    try writer.writeAll("----- log begin -----\n");
    try writer.writeAll(failure.log_excerpt);
    if (failure.log_excerpt.len == 0 or failure.log_excerpt[failure.log_excerpt.len - 1] != '\n') {
        try writer.writeByte('\n');
    }
    try writer.writeAll("----- log end -----\n");

    try app.process_console.appendBytes(.stdout, text.written());
}

fn renderCreatedPullRequest(
    app: *app_mod.App,
    owner: []const u8,
    repo: []const u8,
    base: []const u8,
    head: []const u8,
    pull: *const github_client.PullRequest,
    token_source: github_client.TokenSource,
) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    const writer = &text.writer;

    try writer.writeAll("github draft pull request created (network write)\n");
    try writer.print("repo : {s}/{s}\n", .{ owner, repo });
    try writer.print("token: {s}\n", .{tokenSourceLabel(token_source)});
    try writer.print("from : {s}\n", .{head});
    try writer.print("to   : {s}\n", .{base});
    try writer.print("pr   : #{d} {s}\n", .{ pull.number, pull.title });
    try writer.print("url  : {s}\n", .{pull.html_url});
    try writer.print("draft: {s}\n", .{if (pull.draft) "yes" else "no"});

    try app.process_console.appendBytes(.stdout, text.written());
}

fn tokenSourceLabel(source: github_client.TokenSource) []const u8 {
    return switch (source) {
        .none => "none",
        .github_token => "GITHUB_TOKEN present",
        .gh_token => "GH_TOKEN present",
    };
}

fn gitChangeLabel(status: git_repository.ChangeStatus) []const u8 {
    return switch (status) {
        .modified => "M ",
        .deleted => "D ",
        .untracked => "??",
    };
}

fn appendConsole(app: *app_mod.App, stream: @import("../tasks/console.zig").Stream, comptime fmt: []const u8, args: anytype) !void {
    var text: std.Io.Writer.Allocating = .init(app.allocator);
    defer text.deinit();
    try text.writer.print(fmt, args);
    try app.process_console.appendBytes(stream, text.written());
}

fn parseOneBasedIndex(argument: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, argument, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseUnsigned(usize, trimmed, 10) catch return null;
    if (value == 0) return null;
    return value;
}

const TestWorkspaceEditSpec = struct {
    path: []const u8,
    start_line: usize,
    start_column: usize,
    end_line: usize,
    end_column: usize,
    new_text: []const u8,
};

fn makeTestWorkspaceEdit(allocator: std.mem.Allocator, specs: []const TestWorkspaceEditSpec) !lsp_responses.WorkspaceEdit {
    var edits = try allocator.alloc(lsp_responses.TextEdit, specs.len);
    var initialized: usize = 0;
    errdefer {
        for (edits[0..initialized]) |item| {
            allocator.free(item.path);
            allocator.free(item.new_text);
        }
        allocator.free(edits);
    }

    for (specs) |spec| {
        edits[initialized] = try makeTestTextEdit(allocator, spec);
        initialized += 1;
    }

    return .{
        .allocator = allocator,
        .edits = edits,
    };
}

fn makeTestTextEdit(allocator: std.mem.Allocator, spec: TestWorkspaceEditSpec) !lsp_responses.TextEdit {
    const path = try allocator.dupe(u8, spec.path);
    errdefer allocator.free(path);
    const new_text = try allocator.dupe(u8, spec.new_text);
    return .{
        .path = path,
        .range = .{
            .start = .{ .line = spec.start_line, .column = spec.start_column, .byte_offset = 0 },
            .end = .{ .line = spec.end_line, .column = spec.end_column, .byte_offset = 0 },
        },
        .new_text = new_text,
    };
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
    try app.execution_queue.recordHistory(&ticket, app.workspace.root_path, .finished, 0, 2, 0);

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

test "workspace replacement command updates clean open editors and remains undoable" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "main.txt", .data = "old value\n" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];
    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const document_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "main.txt" });
    defer std.testing.allocator.free(document_path);
    _ = try app.documents.openFile(document_path);

    const preview_result = try dispatch(&app, .{ .id = "workspace.replace", .argument = "old=>new" });
    try std.testing.expect(std.meta.activeTag(preview_result) == .completed);
    var replacement_preview = try workspace_replace.preview(std.testing.allocator, &app.workspace, .{ .find = "old", .replacement = "new" }, .{});
    defer replacement_preview.deinit();
    const apply_argument = try workspace_replace.formatApplyArgument(std.testing.allocator, replacement_preview.token, "old=>new", .{});
    defer std.testing.allocator.free(apply_argument);

    const apply_result = try dispatch(&app, .{ .id = "workspace.replace_apply", .argument = apply_argument });
    try std.testing.expect(std.meta.activeTag(apply_result) == .completed);
    const active = app.documents.active().?;
    try std.testing.expectEqualStrings("new value\n", active.text.bytes);
    try std.testing.expect(!active.dirty);
    try std.testing.expect(try active.undo());
    try std.testing.expectEqualStrings("old value\n", active.text.bytes);
    try std.testing.expect(active.dirty);
}

test "workspace replacement command blocks files with unsaved editors" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "main.txt", .data = "old disk\n" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];
    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const document_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "main.txt" });
    defer std.testing.allocator.free(document_path);
    _ = try app.documents.openFile(document_path);
    try app.documents.active().?.insert(0, "unsaved ");

    var replacement_preview = try workspace_replace.preview(std.testing.allocator, &app.workspace, .{ .find = "old", .replacement = "new" }, .{});
    defer replacement_preview.deinit();
    const apply_argument = try workspace_replace.formatApplyArgument(std.testing.allocator, replacement_preview.token, "old=>new", .{});
    defer std.testing.allocator.free(apply_argument);
    const result = try dispatch(&app, .{ .id = "workspace.replace_apply", .argument = apply_argument });
    try std.testing.expect(std.meta.activeTag(result) == .blocked);

    const disk = try tmp.dir.readFileAlloc(std.Options.debug_io, "main.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(disk);
    try std.testing.expectEqualStrings("old disk\n", disk);
}

test "git overview command renders repository output" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "git.overview" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expect(app.process_console.lines.items.len > 0);
}

test "extension scan command renders manifest overview" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "extensions.scan" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expect(app.process_console.lines.items.len > 0);
}

test "release checklist command renders launch overview" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "release.checklist" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expect(app.process_console.lines.items.len > 0);
}

test "release assets command renders artifact hashes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "zig-out/bin");
    try tmp.dir.createDirPath(std.Options.debug_io, "zig-out/linux-x86_64/bin");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/bin/zide-gui.exe", .data = "gui-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/bin/zide.exe", .data = "cli-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/linux-x86_64/bin/zide-gui", .data = "linux-gui-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/linux-x86_64/bin/zide", .data = "linux-cli-bytes" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "release.assets" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);

    var saw_hash = false;
    for (app.process_console.lines.items) |line| {
        if (std.mem.indexOf(u8, line.text, "sha256") != null) saw_hash = true;
    }
    try std.testing.expect(saw_hash);
}

test "release bundle command creates Windows zip and Linux tar artifacts" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "zig-out/bin");
    try tmp.dir.createDirPath(std.Options.debug_io, "zig-out/linux-x86_64/bin");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/bin/zide-gui.exe", .data = "gui-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/bin/zide.exe", .data = "cli-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/linux-x86_64/bin/zide-gui", .data = "linux-gui-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/linux-x86_64/bin/zide", .data = "linux-cli-bytes" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "release.bundle" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);

    const zip_stat = try tmp.dir.statFile(std.Options.debug_io, release_bundle_asset.relative_path, .{});
    try std.testing.expect(zip_stat.size > 22);
    const tar_stat = try tmp.dir.statFile(std.Options.debug_io, release_linux_bundle_asset.relative_path, .{});
    try std.testing.expect(tar_stat.size > 1024);

    const bytes = try tmp.dir.readFileAlloc(std.Options.debug_io, release_bundle_asset.relative_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len >= 4);
    try std.testing.expectEqualSlices(u8, "PK\x03\x04", bytes[0..4]);
    try std.testing.expect(std.mem.indexOf(u8, bytes, release_bundle_root ++ "/zide.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, release_bundle_root ++ "/CHECKSUMS.sha256") != null);

    const tar_bytes = try tmp.dir.readFileAlloc(std.Options.debug_io, release_linux_bundle_asset.relative_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(tar_bytes);
    try std.testing.expect(tar_bytes.len >= 1024);
    try std.testing.expect(std.mem.indexOf(u8, tar_bytes, "ustar") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_bytes, release_linux_bundle_root ++ "/zide-gui") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_bytes, release_linux_bundle_root ++ "/zide") != null);
}

test "release verify validates bundled Windows zip and Linux tar artifacts" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "zig-out/bin");
    try tmp.dir.createDirPath(std.Options.debug_io, "zig-out/linux-x86_64/bin");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/bin/zide-gui.exe", .data = "gui-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/bin/zide.exe", .data = "cli-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/linux-x86_64/bin/zide-gui", .data = "linux-gui-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/linux-x86_64/bin/zide", .data = "linux-cli-bytes" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    _ = try dispatch(&app, .{ .id = "release.bundle" });
    app.process_console.clear();
    const result = try dispatch(&app, .{ .id = "release.verify" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);

    var saw_zip_ok = false;
    var saw_tar_ok = false;
    for (app.process_console.lines.items) |line| {
        if (std.mem.indexOf(u8, line.text, "verification: OK") != null) saw_zip_ok = true;
        if (std.mem.indexOf(u8, line.text, "linux tar verification: OK") != null) saw_tar_ok = true;
    }
    try std.testing.expect(saw_zip_ok);
    try std.testing.expect(saw_tar_ok);
}

test "release verify rejects unsafe zip paths" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "zig-out/release");
    const entries = [_]ZipInputEntry{
        .{ .name = "../evil.exe", .bytes = "nope" },
    };
    const zip_bytes = try buildStoredZip(std.testing.allocator, entries[0..]);
    defer std.testing.allocator.free(zip_bytes);
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = release_bundle_asset.relative_path, .data = zip_bytes });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "release.verify" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);

    var saw_failed = false;
    var saw_unsafe = false;
    for (app.process_console.lines.items) |line| {
        if (std.mem.indexOf(u8, line.text, "verification: FAILED") != null) saw_failed = true;
        if (std.mem.indexOf(u8, line.text, "unsafe entry path") != null) saw_unsafe = true;
    }
    try std.testing.expect(saw_failed);
    try std.testing.expect(saw_unsafe);
}

test "release preflight reports final gate blockers" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "release.preflight" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);

    var saw_header = false;
    var saw_blocked = false;
    for (app.process_console.lines.items) |line| {
        if (std.mem.indexOf(u8, line.text, "final release preflight") != null) saw_header = true;
        if (std.mem.indexOf(u8, line.text, "BLOCKED") != null) saw_blocked = true;
    }
    try std.testing.expect(saw_header);
    try std.testing.expect(saw_blocked);
}

test "workspace path checks treat slash styles equally" {
    try std.testing.expect(pathEqualIgnoreCaseAndSlash("docs\\security.md", "docs/security.md"));
    try std.testing.expect(pathEqualIgnoreCaseAndSlash(".GITHUB\\workflows\\ci.yml", ".github/workflows/ci.yml"));
    try std.testing.expect(pathStartsWithIgnoreCaseAndSlash(".github\\workflows\\ci.yml", ".github/workflows/"));
}

test "release manifests command renders package drafts" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "zig-out/bin");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/bin/zide-gui.exe", .data = "gui-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/bin/zide.exe", .data = "cli-bytes" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "release.manifests", .argument = "v0.2.0" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);

    var saw_winget = false;
    var saw_scoop = false;
    for (app.process_console.lines.items) |line| {
        if (std.mem.indexOf(u8, line.text, "winget") != null) saw_winget = true;
        if (std.mem.indexOf(u8, line.text, "Scoop") != null) saw_scoop = true;
    }
    try std.testing.expect(saw_winget);
    try std.testing.expect(saw_scoop);
}

test "release manifests prefer bundled zip artifact" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "zig-out/bin");
    try tmp.dir.createDirPath(std.Options.debug_io, "zig-out/release");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/bin/zide-gui.exe", .data = "gui-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-out/bin/zide.exe", .data = "cli-bytes" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = release_bundle_asset.relative_path, .data = "zip-bytes" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const result = try dispatch(&app, .{ .id = "release.manifests", .argument = "v0.2.0" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);

    var saw_bundle = false;
    var saw_winget_zip = false;
    var saw_scoop_extract = false;
    for (app.process_console.lines.items) |line| {
        if (std.mem.indexOf(u8, line.text, release_bundle_asset.release_name) != null) saw_bundle = true;
        if (std.mem.indexOf(u8, line.text, "InstallerType: zip") != null) saw_winget_zip = true;
        if (std.mem.indexOf(u8, line.text, "\"extract_dir\"") != null) saw_scoop_extract = true;
    }
    try std.testing.expect(saw_bundle);
    try std.testing.expect(saw_winget_zip);
    try std.testing.expect(saw_scoop_extract);
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
    try std.testing.expect(validateNewWorkspaceFilePath(".zig-cache-check/generated.zig") != null);
}

test "workspace file operations create rename and explicitly delete" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "src");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/main.zig", .data = "const answer = 42;\n" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "src/main.zig" });
    defer std.testing.allocator.free(source_path);
    _ = try app.documents.openFile(source_path);

    const folder_result = try dispatch(&app, .{ .id = "file.new_folder", .argument = "lib/generated" });
    try std.testing.expect(std.meta.activeTag(folder_result) == .completed);
    _ = try tmp.dir.statFile(std.Options.debug_io, "lib/generated", .{});

    const rename_result = try dispatch(&app, .{ .id = "file.rename", .argument = "src=>source" });
    try std.testing.expect(std.meta.activeTag(rename_result) == .completed);
    _ = try tmp.dir.statFile(std.Options.debug_io, "source/main.zig", .{});
    try std.testing.expect(std.mem.indexOf(u8, app.documents.active().?.path.?, "source") != null);

    const missing_confirmation = try dispatch(&app, .{ .id = "file.delete", .argument = "source/main.zig=>delete" });
    try std.testing.expect(std.meta.activeTag(missing_confirmation) == .blocked);

    const delete_result = try dispatch(&app, .{ .id = "file.delete", .argument = "source/main.zig=>DELETE" });
    try std.testing.expect(std.meta.activeTag(delete_result) == .completed);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.Options.debug_io, "source/main.zig", .{}));
    try std.testing.expectEqual(@as(usize, 0), app.documents.documents.items.len);
}

test "workspace delete protects dirty editor and non-empty folder" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "src");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/main.zig", .data = "const answer = 42;\n" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "src/main.zig" });
    defer std.testing.allocator.free(source_path);
    _ = try app.documents.openFile(source_path);
    app.documents.active().?.dirty = true;

    const dirty_result = try dispatch(&app, .{ .id = "file.delete", .argument = "src/main.zig=>DELETE" });
    try std.testing.expect(std.meta.activeTag(dirty_result) == .blocked);
    _ = try tmp.dir.statFile(std.Options.debug_io, "src/main.zig", .{});

    app.documents.active().?.dirty = false;
    const directory_result = try dispatch(&app, .{ .id = "file.delete", .argument = "src=>DELETE" });
    try std.testing.expect(std.meta.activeTag(directory_result) == .blocked);
    _ = try tmp.dir.statFile(std.Options.debug_io, "src/main.zig", .{});
}

test "workspace edit applies sorted LSP edits to editor buffers" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "src");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/main.zig", .data = "const old = 1;\nold;\n" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    var edit = try makeTestWorkspaceEdit(std.testing.allocator, &.{
        .{ .path = "src/main.zig", .start_line = 0, .start_column = 6, .end_line = 0, .end_column = 9, .new_text = "new" },
        .{ .path = "src/main.zig", .start_line = 1, .start_column = 0, .end_line = 1, .end_column = 3, .new_text = "new" },
    });
    defer edit.deinit();

    const summary = try applyWorkspaceEdit(&app, &edit);
    try std.testing.expectEqual(@as(usize, 2), summary.edits);
    try std.testing.expectEqual(@as(usize, 2), summary.applied);
    try std.testing.expectEqual(@as(usize, 1), summary.files);
    try std.testing.expectEqual(@as(usize, 0), summary.blocked);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);

    const doc = app.documents.active() orelse return error.ExpectedDocument;
    try std.testing.expect(doc.dirty);
    try std.testing.expectEqualStrings("const new = 1;\nnew;\n", doc.text.bytes);
}

test "workspace edit blocks files outside workspace" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    var edit = try makeTestWorkspaceEdit(std.testing.allocator, &.{
        .{ .path = "../outside.zig", .start_line = 0, .start_column = 0, .end_line = 0, .end_column = 0, .new_text = "nope" },
    });
    defer edit.deinit();

    const summary = try applyWorkspaceEdit(&app, &edit);
    try std.testing.expectEqual(@as(usize, 1), summary.edits);
    try std.testing.expectEqual(@as(usize, 0), summary.applied);
    try std.testing.expectEqual(@as(usize, 0), summary.files);
    try std.testing.expectEqual(@as(usize, 1), summary.blocked);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), app.documents.documents.items.len);
}

test "code action request includes active diagnostic context" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "src");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/main.zig", .data = "const unused = 1;\n" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "src/main.zig" });
    defer std.testing.allocator.free(path);
    _ = try app.documents.openFile(path);
    try app.diagnostics.append(.{
        .source = .lsp,
        .severity = .warning,
        .path = "src/main.zig",
        .range = .{
            .start = .{ .line = 0, .column = 6, .byte_offset = 6 },
            .end = .{ .line = 0, .column = 12, .byte_offset = 12 },
        },
        .message = "unused local constant",
    });

    const result = try dispatch(&app, .{ .id = "lsp.request_code_action" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);

    var saw_method = false;
    var saw_diagnostic = false;
    for (app.process_console.lines.items) |line| {
        if (std.mem.indexOf(u8, line.text, "textDocument/codeAction") != null) saw_method = true;
        if (std.mem.indexOf(u8, line.text, "unused local constant") != null) saw_diagnostic = true;
    }
    try std.testing.expect(saw_method);
    try std.testing.expect(saw_diagnostic);
}

test "lsp ensure renders launch guidance without starting in untrusted workspace" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "src");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/main.zig", .data = "const answer = 42;\n" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "src/main.zig" });
    defer std.testing.allocator.free(path);
    _ = try app.documents.openFile(path);

    const result = try dispatch(&app, .{ .id = "lsp.ensure_active" });
    try std.testing.expect(std.meta.activeTag(result) == .blocked);
    try std.testing.expect(!app.hasRunningLspForActiveDocument());
    try std.testing.expect(app.pending_build_consent == null);

    var saw_ensure = false;
    var saw_zls = false;
    for (app.process_console.lines.items) |line| {
        if (std.mem.indexOf(u8, line.text, "lsp ensure") != null) saw_ensure = true;
        if (std.mem.indexOf(u8, line.text, "zls") != null or std.mem.indexOf(u8, line.text, "ZLS") != null) saw_zls = true;
    }
    try std.testing.expect(saw_ensure);
    try std.testing.expect(saw_zls);
}

test "first editable code action applies through workspace edit safety" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "src");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/main.zig", .data = "const old = 1;\n" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "src/main.zig" });
    defer std.testing.allocator.free(path);
    _ = try app.documents.openFile(path);

    const server = try app.lsp_manager.ensureServer(.zig);
    const items = try std.testing.allocator.alloc(lsp_responses.CodeAction, 1);
    errdefer std.testing.allocator.free(items);
    items[0] = .{
        .allocator = std.testing.allocator,
        .title = try std.testing.allocator.dupe(u8, "Rename old to new"),
        .kind = try std.testing.allocator.dupe(u8, "quickfix"),
        .command_title = try std.testing.allocator.dupe(u8, ""),
        .workspace_edit = try makeTestWorkspaceEdit(std.testing.allocator, &.{
            .{ .path = "src/main.zig", .start_line = 0, .start_column = 6, .end_line = 0, .end_column = 9, .new_text = "new" },
        }),
    };
    server.session.last_code_actions = .{
        .allocator = std.testing.allocator,
        .items = items,
    };

    const result = try dispatch(&app, .{ .id = "lsp.apply_first_code_action" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    const doc = app.documents.active() orelse return error.ExpectedDocument;
    try std.testing.expect(doc.dirty);
    try std.testing.expectEqualStrings("const new = 1;\n", doc.text.bytes);
    try std.testing.expect(server.session.last_code_actions == null);
}

test "save blocks critical Zig security findings" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();
    _ = try app.documents.createScratch("danger.zig", "const p = @ptrFromInt(0xdeadbeef);\n");

    const result = try dispatch(&app, .{ .id = "file.save" });
    try std.testing.expect(std.meta.activeTag(result) == .blocked);
    try std.testing.expect(app.diagnostics.items.items.len > 0);
}

test "save blocks critical polyglot security findings" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();
    _ = try app.documents.createScratch(".env", "PRIVATE KEY\n");

    const result = try dispatch(&app, .{ .id = "file.save" });
    try std.testing.expect(std.meta.activeTag(result) == .blocked);
    try std.testing.expect(app.diagnostics.items.items.len > 0);
}

test "save scans package manifest security findings" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const package_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "package.json" });
    defer std.testing.allocator.free(package_path);
    _ = try app.documents.createScratch(package_path,
        \\"scripts": {
        \\  "postinstall": "powershell -c whoami"
        \\}
        \\
    );

    const result = try dispatch(&app, .{ .id = "file.save" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expect(app.diagnostics.items.items.len > 0);
}

test "save all persists every dirty document" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var app = try app_mod.App.init(std.testing.allocator, root_path);
    defer app.deinit();

    const path_a = try std.fs.path.join(std.testing.allocator, &.{ root_path, "a.txt" });
    defer std.testing.allocator.free(path_a);
    const path_b = try std.fs.path.join(std.testing.allocator, &.{ root_path, "b.txt" });
    defer std.testing.allocator.free(path_b);

    _ = try app.documents.createScratch(path_a, "");
    try app.documents.documents.items[0].insert(0, "alpha\n");
    _ = try app.documents.createScratch(path_b, "");
    try app.documents.documents.items[1].insert(0, "beta\n");
    try std.testing.expectEqual(@as(usize, 2), app.documents.dirtyCount());

    const result = try dispatch(&app, .{ .id = "file.save_all" });
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    try std.testing.expectEqual(@as(usize, 0), app.documents.dirtyCount());

    const bytes_a = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path_a, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes_a);
    const bytes_b = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path_b, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes_b);
    try std.testing.expectEqualStrings("alpha\n", bytes_a);
    try std.testing.expectEqualStrings("beta\n", bytes_b);
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
