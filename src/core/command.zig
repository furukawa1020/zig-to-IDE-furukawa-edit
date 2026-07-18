const std = @import("std");

pub const Scope = enum {
    editor,
    file,
    workspace,
    zig,
    debug,
    view,
    task,
    demo,
    extensions,
    release,
};

pub const Capability = enum {
    safe,
    network_read,
    network_write,
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
    .{ .id = "file.new_folder", .title = "New Folder", .description = "Create a folder inside the workspace after boundary checks.", .default_key = "", .scope = .file, .capability = .workspace_write },
    .{ .id = "file.rename", .title = "Rename File or Folder", .description = "Rename a workspace file or folder and update open editor paths.", .default_key = "", .scope = .file, .capability = .workspace_write },
    .{ .id = "file.delete", .title = "Delete File or Empty Folder", .description = "Delete a workspace file or empty folder after explicit DELETE confirmation.", .default_key = "", .scope = .file, .capability = .workspace_write },
    .{ .id = "file.close", .title = "Close Editor", .description = "Close the active editor tab when it has no unsaved changes.", .default_key = "ctrl-w", .scope = .file, .capability = .safe },
    .{ .id = "file.next_editor", .title = "Next Editor", .description = "Switch to the next open editor tab.", .default_key = "ctrl-tab", .scope = .file, .capability = .safe },
    .{ .id = "file.previous_editor", .title = "Previous Editor", .description = "Switch to the previous open editor tab.", .default_key = "ctrl-shift-tab", .scope = .file, .capability = .safe },
    .{ .id = "file.save", .title = "Save File", .description = "Save the current buffer with atomic write.", .default_key = "ctrl-s", .scope = .file, .capability = .workspace_write },
    .{ .id = "file.save_all", .title = "Save All Files", .description = "Save every dirty editor buffer after security checks.", .default_key = "ctrl-shift-s", .scope = .file, .capability = .workspace_write },
    .{ .id = "recovery.open", .title = "Open Recovery Center", .description = "Review bounded crash-recovery snapshots without writing source files.", .default_key = "", .scope = .file, .capability = .safe },
    .{ .id = "recovery.restore", .title = "Restore Recovery Snapshot", .description = "Restore a one-based snapshot into an unsaved editor buffer after source-hash verification.", .default_key = "", .scope = .file, .capability = .safe },
    .{ .id = "recovery.discard", .title = "Discard Recovery Snapshot", .description = "Delete one bounded internal recovery snapshot by one-based index.", .default_key = "", .scope = .file, .capability = .safe },
    .{ .id = "recovery.discard_all", .title = "Discard All Recovery Snapshots", .description = "Delete all internal recovery snapshots only when the exact DISCARD ALL confirmation is supplied.", .default_key = "", .scope = .file, .capability = .safe },
    .{ .id = "recovery.purge_rejected", .title = "Purge Rejected Recovery Data", .description = "Delete only rejected recovery envelopes after a complete bounded directory scan and exact confirmation.", .default_key = "", .scope = .file, .capability = .safe },
    .{ .id = "editor.enter_insert", .title = "Enter Insert Mode", .description = "Switch to insert mode.", .default_key = "i", .scope = .editor, .capability = .safe },
    .{ .id = "editor.exit_insert", .title = "Exit Insert Mode", .description = "Switch back to normal mode.", .default_key = "escape", .scope = .editor, .capability = .safe },
    .{ .id = "editor.insert", .title = "Insert Text", .description = "Insert UTF-8 bytes into the current buffer.", .default_key = "", .scope = .editor, .capability = .safe },
    .{ .id = "editor.move_left", .title = "Move Left", .description = "Move the cursor one character left.", .default_key = "left", .scope = .editor, .capability = .safe },
    .{ .id = "editor.move_right", .title = "Move Right", .description = "Move the cursor one character right.", .default_key = "right", .scope = .editor, .capability = .safe },
    .{ .id = "editor.move_up", .title = "Move Up", .description = "Move the cursor one line up.", .default_key = "up", .scope = .editor, .capability = .safe },
    .{ .id = "editor.move_down", .title = "Move Down", .description = "Move the cursor one line down.", .default_key = "down", .scope = .editor, .capability = .safe },
    .{ .id = "editor.undo", .title = "Undo", .description = "Undo the last editing transaction.", .default_key = "ctrl-z", .scope = .editor, .capability = .safe },
    .{ .id = "editor.redo", .title = "Redo", .description = "Redo the last undone editing transaction.", .default_key = "ctrl-y", .scope = .editor, .capability = .safe },
    .{ .id = "editor.indent", .title = "Indent Lines", .description = "Indent the current line or selected lines as one undoable edit.", .default_key = "tab", .scope = .editor, .capability = .safe },
    .{ .id = "editor.outdent", .title = "Outdent Lines", .description = "Remove one indentation level from the current line or selected lines.", .default_key = "shift-tab", .scope = .editor, .capability = .safe },
    .{ .id = "editor.find", .title = "Find in File", .description = "Find literal text in the current editor document.", .default_key = "ctrl-f", .scope = .editor, .capability = .safe },
    .{ .id = "editor.goto_line", .title = "Go To Line", .description = "Jump to a line and optional column in the current editor document.", .default_key = "ctrl-g", .scope = .editor, .capability = .safe },
    .{ .id = "editor.replace", .title = "Replace in File", .description = "Replace the selected current-document match.", .default_key = "ctrl-h", .scope = .editor, .capability = .safe },
    .{ .id = "editor.complete", .title = "Complete Symbol", .description = "Open language-aware completions for the current cursor without executing plugins.", .default_key = "ctrl-space", .scope = .editor, .capability = .safe },
    .{ .id = "editor.format_document", .title = "Format Document", .description = "Request LSP document formatting and preview the safe WorkspaceEdit before applying.", .default_key = "shift-alt-f", .scope = .editor, .capability = .safe },
    .{ .id = "editor.set_language", .title = "Change Language Mode", .description = "Set the active document language for highlighting, completions, symbols, and security scanning.", .default_key = "", .scope = .editor, .capability = .safe },
    .{ .id = "editor.find_next", .title = "Find Next", .description = "Jump to the next current-document match.", .default_key = "f3", .scope = .editor, .capability = .safe },
    .{ .id = "editor.find_previous", .title = "Find Previous", .description = "Jump to the previous current-document match.", .default_key = "shift-f3", .scope = .editor, .capability = .safe },
    .{ .id = "editor.toggle_comment", .title = "Toggle Comment", .description = "Toggle line or block comments using the active document language mode.", .default_key = "ctrl-/", .scope = .editor, .capability = .safe },
    .{ .id = "editor.normalize_newlines_lf", .title = "Normalize Line Endings: LF", .description = "Convert current buffer line endings to LF without saving automatically.", .default_key = "", .scope = .editor, .capability = .safe },
    .{ .id = "editor.normalize_newlines_crlf", .title = "Normalize Line Endings: CRLF", .description = "Convert current buffer line endings to CRLF without saving automatically.", .default_key = "", .scope = .editor, .capability = .safe },
    .{ .id = "editor.sanitize_hidden_controls", .title = "Sanitize Hidden Controls", .description = "Remove NUL and bidirectional Unicode control markers from the current buffer.", .default_key = "", .scope = .editor, .capability = .safe },
    .{ .id = "editor.delete_line", .title = "Delete Line", .description = "Delete the current editor line.", .default_key = "ctrl-shift-k", .scope = .editor, .capability = .safe },
    .{ .id = "editor.duplicate_line", .title = "Duplicate Line", .description = "Duplicate the current editor line below.", .default_key = "ctrl-shift-d", .scope = .editor, .capability = .safe },
    .{ .id = "editor.move_line_up", .title = "Move Line Up", .description = "Move the current editor line upward.", .default_key = "alt-up", .scope = .editor, .capability = .safe },
    .{ .id = "editor.move_line_down", .title = "Move Line Down", .description = "Move the current editor line downward.", .default_key = "alt-down", .scope = .editor, .capability = .safe },
    .{ .id = "editor.add_cursor_above", .title = "Add Cursor Above", .description = "Add an editor cursor on the line above.", .default_key = "ctrl-alt-up", .scope = .editor, .capability = .safe },
    .{ .id = "editor.add_cursor_below", .title = "Add Cursor Below", .description = "Add an editor cursor on the line below.", .default_key = "ctrl-alt-down", .scope = .editor, .capability = .safe },
    .{ .id = "workspace.search", .title = "Search Workspace", .description = "Search text across workspace files.", .default_key = "ctrl-shift-f", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.replace", .title = "Replace in Workspace", .description = "Preview a hash-bound literal replacement across workspace files.", .default_key = "ctrl-shift-h", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.replace_apply", .title = "Apply Staged Workspace Replacement", .description = "Apply a previously previewed workspace replacement after content-token verification.", .default_key = "", .scope = .workspace, .capability = .workspace_write },
    .{ .id = "workspace.find_file", .title = "Find File", .description = "Fuzzy-find a file in the workspace.", .default_key = "ctrl-p", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.refresh", .title = "Refresh Explorer", .description = "Rescan workspace files without executing tools, hooks, or scripts.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.language_report", .title = "Workspace Language Report", .description = "Show recognized languages, LSP mappings, run profiles, and security focus without executing tools.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.previous_file", .title = "Previous File", .description = "Move the file-tree selection upward.", .default_key = "k", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.next_file", .title = "Next File", .description = "Move the file-tree selection downward.", .default_key = "j", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.open_selected", .title = "Open Selected File", .description = "Open the selected file-tree entry.", .default_key = "enter", .scope = .workspace, .capability = .safe },
    .{ .id = "zig.build", .title = "Zig Build", .description = "Run zig build for the current workspace.", .default_key = "ctrl-b", .scope = .zig, .capability = .external_command },
    .{ .id = "zig.test", .title = "Zig Test", .description = "Run Zig tests for the current context.", .default_key = "ctrl-alt-t", .scope = .zig, .capability = .external_command },
    .{ .id = "zig.fmt", .title = "Zig Format", .description = "Format the current Zig file using zig fmt.", .default_key = "ctrl-alt-f", .scope = .zig, .capability = .external_command },
    .{ .id = "task.run", .title = "Run Task", .description = "Run a configured project task.", .default_key = "ctrl-r", .scope = .task, .capability = .external_command },
    .{ .id = "task.preview_next", .title = "Preview Next Command", .description = "Render the latest approved launch plan without spawning it.", .default_key = "", .scope = .task, .capability = .safe },
    .{ .id = "task.run_next", .title = "Run Approved Command", .description = "Run the next explicitly approved command and capture sanitized output.", .default_key = "", .scope = .task, .capability = .safe },
    .{ .id = "task.history", .title = "Show Task History", .description = "Render recent approved command results.", .default_key = "", .scope = .task, .capability = .safe },
    .{ .id = "view.toggle_file_tree", .title = "Toggle File Tree", .description = "Show or hide the file tree.", .default_key = "ctrl-e", .scope = .view, .capability = .safe },
    .{ .id = "view.toggle_diagnostics", .title = "Toggle Diagnostics", .description = "Show or hide diagnostics.", .default_key = "ctrl-d", .scope = .view, .capability = .safe },
    .{ .id = "view.command_palette", .title = "Command Palette", .description = "Open the command palette.", .default_key = "ctrl-shift-p", .scope = .view, .capability = .safe },
    .{ .id = "view.tutorial", .title = "Open Tutorial", .description = "Open the in-app ZIDE tutorial and security tour.", .default_key = "f1", .scope = .view, .capability = .safe },
    .{ .id = "view.extensions", .title = "Open Extensions", .description = "Open the extension and integration manifest panel.", .default_key = "ctrl-shift-x", .scope = .view, .capability = .safe },
    .{ .id = "view.publish", .title = "Open Publish Checklist", .description = "Open the release and public launch checklist.", .default_key = "ctrl-shift-l", .scope = .view, .capability = .safe },
    .{ .id = "preferences.open_settings", .title = "Open Settings", .description = "Open the Linux workbench settings panel.", .default_key = "ctrl-,", .scope = .view, .capability = .safe },
    .{ .id = "preferences.open_keybindings", .title = "Open Keyboard Shortcuts", .description = "Open the keybinding reference and command launcher panel.", .default_key = "ctrl-k", .scope = .view, .capability = .safe },
    .{ .id = "symbol.goto_symbol", .title = "Go To Symbol", .description = "Open the current document outline.", .default_key = "ctrl-shift-o", .scope = .zig, .capability = .safe },
    .{ .id = "symbol.workspace_symbols", .title = "Go To Symbol in Workspace", .description = "Search function, type, class, and constant symbols across recognized workspace languages.", .default_key = "ctrl-t", .scope = .workspace, .capability = .safe },
    .{ .id = "symbol.goto_definition", .title = "Go To Definition", .description = "Jump to the selected symbol definition.", .default_key = "f12", .scope = .zig, .capability = .safe },
    .{ .id = "symbol.goto_implementation", .title = "Go To Implementation", .description = "Jump to the selected symbol implementation through the active language server.", .default_key = "ctrl-f12", .scope = .zig, .capability = .safe },
    .{ .id = "symbol.goto_type_definition", .title = "Go To Type Definition", .description = "Jump to the selected symbol type definition through the active language server.", .default_key = "ctrl-alt-f12", .scope = .zig, .capability = .safe },
    .{ .id = "symbol.find_references", .title = "Find References", .description = "Find references for the selected symbol.", .default_key = "shift-f12", .scope = .zig, .capability = .safe },
    .{ .id = "symbol.rename", .title = "Rename Symbol", .description = "Rename a symbol with preview and undo.", .default_key = "f2", .scope = .zig, .capability = .workspace_write },
    .{ .id = "diagnostics.next", .title = "Next Diagnostic", .description = "Jump to the next diagnostic.", .default_key = "f8", .scope = .workspace, .capability = .safe },
    .{ .id = "problems.open", .title = "Open Problems", .description = "Search diagnostics and security findings without running external tools.", .default_key = "ctrl-shift-m", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.plan", .title = "Show LSP Launch Plan", .description = "Render the language server plan for the active document without spawning it.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.actions", .title = "Open LSP Actions", .description = "Open the LSP action launcher for status, sync, hover, formatting, navigation, and quick fixes.", .default_key = "ctrl-alt-l", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.ensure_active", .title = "Ensure Active LSP", .description = "Start the mapped language server when allowed, or show the exact trust-gated launch plan and install hint.", .default_key = "ctrl-alt-i", .scope = .workspace, .capability = .external_command },
    .{ .id = "lsp.status", .title = "Show LSP Session Status", .description = "Show the in-process LSP session state, pending requests, and cached server results.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.sync_current", .title = "Sync Current Document to LSP", .description = "Build didOpen/didChange packets for the active document without launching external code.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.request_completion", .title = "Build LSP Completion Request", .description = "Build a textDocument/completion packet for the active cursor.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.request_hover", .title = "Build LSP Hover Request", .description = "Build a textDocument/hover packet for the active cursor.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.request_definition", .title = "Build LSP Definition Request", .description = "Build a textDocument/definition packet for the active cursor.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.request_implementation", .title = "Build LSP Implementation Request", .description = "Build a textDocument/implementation packet for the active cursor.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.request_type_definition", .title = "Build LSP Type Definition Request", .description = "Build a textDocument/typeDefinition packet for the active cursor.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.request_references", .title = "Build LSP References Request", .description = "Build a textDocument/references packet for the active cursor.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.request_rename", .title = "Build LSP Rename Request", .description = "Build or send a textDocument/rename request for the active cursor and requested new name.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.request_formatting", .title = "Build LSP Formatting Request", .description = "Build or send a textDocument/formatting request for the active document.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.apply_workspace_edit", .title = "Apply LSP Workspace Edit", .description = "Apply the last LSP WorkspaceEdit to editor buffers after workspace boundary and range checks.", .default_key = "ctrl-enter", .scope = .workspace, .capability = .workspace_write },
    .{ .id = "lsp.request_code_action", .title = "Request LSP Code Actions", .description = "Request quick-fix Code Actions for the active cursor and current diagnostics.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.apply_code_action", .title = "Apply LSP Code Action", .description = "Apply the one-based cached Code Action index through the safe WorkspaceEdit path.", .default_key = "", .scope = .workspace, .capability = .workspace_write },
    .{ .id = "lsp.apply_first_code_action", .title = "Apply First LSP Code Action", .description = "Apply the first editable cached Code Action through the safe WorkspaceEdit path.", .default_key = "", .scope = .workspace, .capability = .workspace_write },
    .{ .id = "lsp.start", .title = "Start LSP Server", .description = "Start the mapped language server for the active document using stdio after trust approval.", .default_key = "", .scope = .workspace, .capability = .external_command },
    .{ .id = "lsp.stop", .title = "Stop LSP Server", .description = "Stop the active language server transport.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.ingest_payload", .title = "Ingest LSP Payload", .description = "Apply a JSON-RPC payload to the LSP session, diagnostics, and cached language results.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "lsp.drain", .title = "Drain LSP Frames", .description = "Process complete LSP frames already buffered from the transport.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "security.scan_current", .title = "Scan Current File", .description = "Scan the current file for Zig and polyglot security boundaries.", .default_key = "ctrl-alt-s", .scope = .workspace, .capability = .safe },
    .{ .id = "security.audit_workspace", .title = "Audit Workspace", .description = "Run static Security Workbench audit for the workspace.", .default_key = "ctrl-alt-a", .scope = .workspace, .capability = .safe },
    .{ .id = "security.audit_log", .title = "Show Run Audit Log", .description = "Render persisted command launch audit JSONL without running external tools.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "security.audit_verify", .title = "Verify Run Audit Chain", .description = "Verify tamper-evident command launch audit hashes without running external tools.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "security.mark_reviewed", .title = "Mark Workspace Reviewed", .description = "Mark the workspace as reviewed without allowing execution.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "security.trust_workspace", .title = "Trust Workspace", .description = "Trust audited workspace when no high-risk findings are present.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "security.lock_workspace", .title = "Lock Workspace", .description = "Lock workspace writes and execution until review.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "security.approve_consent", .title = "Approve Build Consent", .description = "Queue the pending build/test command after explicit review.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "security.dismiss_consent", .title = "Dismiss Build Consent", .description = "Clear the pending build consent preview.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "debug.create_config", .title = "Create or Open Debug Configuration", .description = "Create .zide/debug.json without overwriting an existing file, then open it for editing.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.plan", .title = "Show Debug Launch Plan", .description = "Render the resolved DAP adapter, target, argv, cwd, and security policy without spawning it.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.start", .title = "Start Debugging", .description = "Start an explicitly trusted DAP adapter over bounded stdio.", .default_key = "f5", .scope = .debug, .capability = .external_command },
    .{ .id = "debug.stop", .title = "Stop Debugging", .description = "Disconnect the active adapter and terminate the debuggee.", .default_key = "shift-f5", .scope = .debug, .capability = .safe },
    .{ .id = "debug.continue", .title = "Continue Debugging", .description = "Continue the paused debuggee.", .default_key = "f5", .scope = .debug, .capability = .safe },
    .{ .id = "debug.pause", .title = "Pause Debugging", .description = "Pause the active debug thread.", .default_key = "f6", .scope = .debug, .capability = .safe },
    .{ .id = "debug.step_over", .title = "Step Over", .description = "Advance the paused thread to the next source line.", .default_key = "f10", .scope = .debug, .capability = .safe },
    .{ .id = "debug.step_into", .title = "Step Into", .description = "Step into the next callable source location.", .default_key = "f11", .scope = .debug, .capability = .safe },
    .{ .id = "debug.step_out", .title = "Step Out", .description = "Run until the current stack frame returns.", .default_key = "shift-f11", .scope = .debug, .capability = .safe },
    .{ .id = "debug.toggle_breakpoint", .title = "Toggle Breakpoint", .description = "Toggle a source breakpoint and persist workspace debug state.", .default_key = "f9", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.breakpoint_condition", .title = "Set Restricted Breakpoint Condition", .description = "Set and persist a comparison-only condition on the current source line.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.breakpoint_hit_condition", .title = "Set Breakpoint Hit Count", .description = "Set and persist a positive decimal hit count on the current source line.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.breakpoint_log", .title = "Set Restricted Logpoint", .description = "Set and persist a logpoint whose interpolations are restricted inspection expressions.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.breakpoint_clear_advanced", .title = "Clear Advanced Breakpoint Settings", .description = "Clear condition, hit count, and log message while keeping the current source breakpoint.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.function_add", .title = "Add Function Breakpoint", .description = "Validate and persist a bounded explicit multi-language function selector without evaluating it in ZIDE.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.function_remove", .title = "Remove Function Breakpoint", .description = "Remove a function breakpoint by its one-based list index and update the active capable adapter.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.function_clear", .title = "Clear Function Breakpoints", .description = "Clear every persisted function breakpoint and update the active capable adapter.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.data_inspect", .title = "Inspect Data Breakpoint Support", .description = "Ask the active adapter for bounded data-breakpoint metadata for a variable from the current suspended state without setting it.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.data_commit", .title = "Commit Data Breakpoint", .description = "Commit the explicitly inspected data-breakpoint candidate with an adapter-advertised access type.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.data_cancel", .title = "Cancel Data Breakpoint Candidate", .description = "Discard the staged data-breakpoint candidate without changing adapter configuration.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.data_remove", .title = "Remove Data Breakpoint", .description = "Remove a data breakpoint by its one-based list index and update the active capable adapter.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.data_clear", .title = "Clear Data Breakpoints", .description = "Clear every data breakpoint and update the active capable adapter with an empty replacement list.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.low_level", .title = "Open Low-Level Debugger", .description = "Inspect read-only memory, disassembly, and session-only instruction breakpoints through bounded adapter references.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.disassemble", .title = "Disassemble Stack Frame", .description = "Disassemble a bounded window around an adapter-provided instruction reference from the current stopped state.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.memory_read", .title = "Read Variable Memory", .description = "Read at most 256 bytes from an adapter-provided variable memory reference; memory writes are never generated.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.memory_refresh", .title = "Refresh Read-Only Memory", .description = "Repeat the last bounded read while its stopped-state memory reference remains valid.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.instruction_toggle", .title = "Toggle Instruction Breakpoint", .description = "Toggle a session-only instruction breakpoint at a validated disassembly result.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.instruction_remove", .title = "Remove Instruction Breakpoint", .description = "Remove a session-only instruction breakpoint by its one-based list index.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.instruction_clear", .title = "Clear Instruction Breakpoints", .description = "Clear all session-only instruction breakpoints with a full replacement request.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.exception_toggle", .title = "Configure Exception Breakpoints", .description = "Select only exception filter IDs explicitly advertised by the active debug adapter and persist the selection.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.exception_clear", .title = "Clear Exception Breakpoints", .description = "Clear every persisted exception breakpoint filter and update the active adapter.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.status", .title = "Show Debug Status", .description = "Render adapter state, policies, breakpoints, threads, stack frames, scopes, and variables.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.threads", .title = "Refresh Debug Threads", .description = "Request the current DAP thread list.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.stack", .title = "Refresh Debug Stack", .description = "Request stack frames for the active debug thread.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.scopes", .title = "Refresh Debug Scopes", .description = "Request scopes for the active stack frame.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.variables", .title = "Refresh Debug Variables", .description = "Request variables for the first available scope or an explicit reference.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.select_frame", .title = "Select Debug Stack Frame", .description = "Select a DAP stack frame and request its scopes by numeric frame ID.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.watch_add", .title = "Add Restricted Debug Watch", .description = "Add and persist an inspection-shaped watch; calls, assignments, statements, and arithmetic or logical operators are rejected.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.watch_remove", .title = "Remove Debug Watch", .description = "Remove a watch by its one-based list index and persist the state.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.watch_clear", .title = "Clear Debug Watches", .description = "Remove every persisted debug watch expression.", .default_key = "", .scope = .debug, .capability = .workspace_write },
    .{ .id = "debug.watch_refresh", .title = "Refresh Debug Watches", .description = "Evaluate restricted watches in the selected paused stack frame.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.ingest_payload", .title = "Ingest DAP Payload", .description = "Ingest one DAP JSON message for protocol diagnostics and tests.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "debug.drain", .title = "Drain Debug Adapter Frames", .description = "Process complete bounded DAP frames already buffered from the adapter.", .default_key = "", .scope = .debug, .capability = .safe },
    .{ .id = "git.overview", .title = "Git and GitHub Overview", .description = "Read branch, remotes, GitHub links, and file changes without executing Git.", .default_key = "ctrl-g", .scope = .workspace, .capability = .safe },
    .{ .id = "git.status", .title = "Git Security Status", .description = "Read Git metadata without executing Git hooks, filters, or fsmonitor.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "git.diff_current", .title = "Preview Current Git Diff", .description = "Render a compact diff for the active file without running git diff.", .default_key = "ctrl-shift-g", .scope = .workspace, .capability = .safe },
    .{ .id = "github.overview", .title = "GitHub Overview", .description = "Show GitHub repository and Actions links inferred from local Git remotes.", .default_key = "", .scope = .workspace, .capability = .safe },
    .{ .id = "github.fetch", .title = "Fetch GitHub Live Overview", .description = "Fetch read-only GitHub repo, PR, and Actions data with optional GITHUB_TOKEN.", .default_key = "", .scope = .workspace, .capability = .network_read },
    .{ .id = "github.issues", .title = "Fetch GitHub Issues", .description = "Fetch open GitHub issues and pull requests for the current repository.", .default_key = "", .scope = .workspace, .capability = .network_read },
    .{ .id = "github.actions.failures", .title = "Fetch Actions Failure Log", .description = "Fetch the latest failed GitHub Actions job log excerpt.", .default_key = "", .scope = .workspace, .capability = .network_read },
    .{ .id = "github.pr.create_draft", .title = "Create Draft GitHub PR", .description = "Create a draft PR from the current branch to the default branch using GITHUB_TOKEN.", .default_key = "", .scope = .workspace, .capability = .network_write },
    .{ .id = "extensions.scan", .title = "Scan Extensions", .description = "Scan ZIDE extension manifests without executing extension code.", .default_key = "", .scope = .extensions, .capability = .safe },
    .{ .id = "release.checklist", .title = "Release Checklist", .description = "Render a public launch checklist for GitHub Releases, Windows ZIP, Linux TAR, winget, and Scoop.", .default_key = "", .scope = .release, .capability = .safe },
    .{ .id = "release.assets", .title = "Release Assets and Checksums", .description = "Render artifact sizes and SHA-256 hashes without running shell tools.", .default_key = "", .scope = .release, .capability = .safe },
    .{ .id = "release.manifests", .title = "Release Manifest Drafts", .description = "Render GitHub Release, winget, and Scoop manifest drafts from local artifact hashes.", .default_key = "", .scope = .release, .capability = .safe },
    .{ .id = "release.bundle", .title = "Build Release Bundle", .description = "Create Windows ZIP and Linux TAR release bundles using pure Zig archive writing.", .default_key = "", .scope = .release, .capability = .workspace_write },
    .{ .id = "release.verify", .title = "Verify Release Bundle", .description = "Verify release archives, paths, checksums, and executable permissions using pure Zig.", .default_key = "", .scope = .release, .capability = .safe },
    .{ .id = "release.preflight", .title = "Final Release Preflight", .description = "Run the final publish gate for docs, Git state, artifacts, ZIP verification, and release hashes.", .default_key = "", .scope = .release, .capability = .safe },
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
    const audit_definition = findById("security.audit_log") orelse return error.ExpectedCommand;
    try std.testing.expectEqual(Capability.safe, audit_definition.capability);
    const verify_definition = findById("security.audit_verify") orelse return error.ExpectedCommand;
    try std.testing.expectEqual(Scope.workspace, verify_definition.scope);
}

test "fuzzy score prefers consecutive matches" {
    const compact = fuzzyScore("zb", "zig.build").?;
    const distant = fuzzyScore("zb", "workspace.zig.build").?;
    try std.testing.expect(compact >= distant);
}
