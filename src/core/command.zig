const std = @import("std");

pub const Scope = enum {
    editor,
    file,
    workspace,
    zig,
    view,
    task,
    demo,
};

pub const Capability = enum {
    safe,
    workspace_write,
    external_command,
};

pub const Request = struct {
    id: []const u8,
    argument: ?[]const u8 = null,
    source: Source = .command_palette,
};

pub const Source = enum {
    keybinding,
    command_palette,
    startup,
    task,
    demo,
};

pub const Check = union(enum) {
    allowed: Definition,
    unknown_command,
    confirmation_required: []const u8,
    blocked: []const u8,
};

pub const Definition = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    default_key: []const u8,
    scope: Scope,
    capability: Capability,
};

const definitions = [_]Definition{
    .{ .id = "file.open", .title = "Open File", .description = "Open a file in the workspace.", .default_key = "ctrl-o", .scope = .file, .capability = .safe },
    .{ .id = "file.new", .title = "New File", .description = "Create a new file inside the workspace.", .default_key = "ctrl-n", .scope = .file, .capability = .workspace_write },
    .{ .id = "file.save", .title = "Save File", .description = "Save the current buffer with atomic write.", .default_key = "ctrl-s", .scope = .file, .capability = .workspace_write },
    .{ .id = "editor.enter_insert", .title = "Enter Insert Mode", .description = "Switch to insert mode.", .default_key = "i", .scope = .editor, .capability = .safe },
    .{ .id = "editor.exit_insert", .title = "Exit Insert Mode", .description = "Switch back to normal mode.", .default_key = "escape", .scope = .editor, .capability = .safe },
    .{ .id = "editor.insert", .title = "Insert Text", .description = "Insert UTF-8 bytes into the current buffer.", .default_key = "", .scope = .editor, .capability = .safe },
    .{ .id = "editor.move_left", .title = "Move Left", .description = "Move the cursor one character left.", .default_key = "left", .scope = .editor, .capability = .safe },
    .{ .id = "editor.move_right", .title = "Move Right", .description = "Move the cursor one character right.", .default_key = "right", .scope = .editor, .capability = .safe },
    .{ .id = "editor.move_up", .title = "Move Up", .description = "Move the cursor one line up.", .default_key = "up", .scope = .editor, .capability = .safe },
    .{ .id = "editor.move_down", .title = "Move Down", .description = "Move the cursor one line down.", .default_key = "down", .scope = .editor, .capability = .safe },
    .{ .id = "editor.undo", .title = "Undo", .description = "Undo the last editing transaction.", .default_key = "ctrl-z", .scope = .editor, .capability = .safe },
    .{ .id = "editor.redo", .title = "Redo", .description = "Redo the last undone editing transaction.", .default_key = "ctrl-y", .scope = .editor, .capability = .safe },
    .{ .id = "workspace.search", .title = "Search Workspace", .description = "Search text across workspace files.", .default_key = "ctrl-f", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.find_file", .title = "Find File", .description = "Fuzzy-find a file in the workspace.", .default_key = "ctrl-p", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.previous_file", .title = "Previous File", .description = "Move the file-tree selection upward.", .default_key = "k", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.next_file", .title = "Next File", .description = "Move the file-tree selection downward.", .default_key = "j", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.open_selected", .title = "Open Selected File", .description = "Open the selected file-tree entry.", .default_key = "enter", .scope = .workspace, .capability = .safe },
    .{ .id = "zig.build", .title = "Zig Build", .description = "Run zig build for the current workspace.", .default_key = "ctrl-b", .scope = .zig, .capability = .external_command },
    .{ .id = "zig.test", .title = "Zig Test", .description = "Run Zig tests for the current context.", .default_key = "ctrl-t", .scope = .zig, .capability = .external_command },
    .{ .id = "zig.fmt", .title = "Zig Format", .description = "Format the current Zig file using zig fmt.", .default_key = "ctrl-alt-f", .scope = .zig, .capability = .external_command },
    .{ .id = "task.run", .title = "Run Task", .description = "Run a configured project task.", .default_key = "ctrl-r", .scope = .task, .capability = .external_command },
    .{ .id = "task.preview_next", .title = "Preview Next Command", .description = "Render the latest approved launch plan without spawning it.", .default_key = "", .scope = .task, .capability = .safe },
    .{ .id = "task.run_next", .title = "Run Approved Command", .description = "Run the next explicitly approved command and capture sanitized output.", .default_key = "", .scope = .task, .capability = .safe },
    .{ .id = "task.history", .title = "Show Task History", .description = "Render recent approved command results.", .default_key = "", .scope = .task, .capability = .safe },
    .{ .id = "view.toggle_file_tree", .title = "Toggle File Tree", .description = "Show or hide the file tree.", .default_key = "ctrl-e", .scope = .view, .capability = .safe },
    .{ .id = "view.toggle_diagnostics", .title = "Toggle Diagnostics", .description = "Show or hide diagnostics.", .default_key = "ctrl-d", .scope = .view, .capability = .safe },
    .{ .id = "view.command_palette", .title = "Command Palette", .description = "Open the command palette.", .default_key = "ctrl-shift-p", .scope = .view, .capability = .safe },
    .{ .id = "symbol.goto_definition", .title = "Go To Definition", .description = "Jump to the selected symbol definition.", .default_key = "f12", .scope = .zig, .capability = .safe },
    .{ .id = "symbol.find_references", .title = "Find References", .description = "Find references for the selected symbol.", .default_key = "shift-f12", .scope = .zig, .capability = .safe },
    .{ .id = "symbol.rename", .title = "Rename Symbol", .description = "Rename a symbol with preview and undo.", .default_key = "f2", .scope = .zig, .capability = .workspace_write },
    .{ .id = "diagnostics.next", .title = "Next Diagnostic", .description = "Jump to the next diagnostic.", .default_key = "f8", .scope = .workspace, .capability = .safe },
    .{ .id = "security.scan_current", .title = "Scan Current File", .description = "Scan the current Zig file for security boundaries.", .default_key = "ctrl-alt-s", .scope = .zig, .capability = .safe },
    .{ .id = "security.audit_workspace", .title = "Audit Workspace", .description = "Run static Security Workbench audit for the workspace.", .default_key = "ctrl-alt-a", .scope = .workspace, .capability = .safe },
    .{ .id = "security.mark_reviewed", .title = "Mark Workspace Reviewed", .description = "Mark the workspace as reviewed without allowing execution.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "security.trust_workspace", .title = "Trust Workspace", .description = "Trust audited workspace when no high-risk findings are present.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "security.lock_workspace", .title = "Lock Workspace", .description = "Lock workspace writes and execution until review.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "security.approve_consent", .title = "Approve Build Consent", .description = "Queue the pending build/test command after explicit review.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "security.dismiss_consent", .title = "Dismiss Build Consent", .description = "Clear the pending build consent preview.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "debug.start", .title = "Start Debugging", .description = "Launch the configured debug session.", .default_key = "f5", .scope = .task, .capability = .external_command },
    .{ .id = "git.status", .title = "Git Security Status", .description = "Read Git metadata without executing Git hooks, filters, or fsmonitor.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "demo.run", .title = "Run Demo", .description = "Run an internal zide demo.", .default_key = "", .scope = .demo, .capability = .safe },
};

pub fn all() []const Definition {
    return definitions[0..];
}

pub fn findById(id: []const u8) ?Definition {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.id, id)) return definition;
    }
    return null;
}

pub fn fuzzyScore(query: []const u8, candidate: []const u8) ?u16 {
    if (query.len == 0) return 0;

    var q_index: usize = 0;
    var score: u16 = 0;
    var last_match: ?usize = null;

    for (candidate, 0..) |c, i| {
        if (q_index >= query.len) break;

        const qc = std.ascii.toLower(query[q_index]);
        const cc = std.ascii.toLower(c);
        if (qc != cc) continue;

        score += 2;
        if (i == 0) score += 8;
        if (i > 0 and isBoundary(candidate[i - 1])) score += 5;
        if (last_match) |last| {
            if (last + 1 == i) score += 4;
        }

        last_match = i;
        q_index += 1;
    }

    if (q_index == query.len) return score;
    return null;
}

fn isBoundary(c: u8) bool {
    return c == '.' or c == '_' or c == '-' or c == '/' or c == '\\' or std.ascii.isWhitespace(c);
}

test "find command by id" {
    const definition = findById("zig.build") orelse return error.ExpectedCommand;
    try std.testing.expectEqual(Scope.zig, definition.scope);
}

test "fuzzy score prefers consecutive matches" {
    const compact = fuzzyScore("zb", "zig.build").?;
    const distant = fuzzyScore("zb", "workspace.zig.build").?;
    try std.testing.expect(compact >= distant);
}
