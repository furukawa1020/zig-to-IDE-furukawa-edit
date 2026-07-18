const std = @import("std");
const build_consent = @import("../security/build_consent.zig");
const command_palette = @import("../ui/command_palette.zig");
const diagnostics = @import("../diagnostics/collection.zig");
const security_findings = @import("../security/findings.zig");
const store = @import("../editor/store.zig");
const render_view = @import("../ui/render.zig");
const runtime = @import("runtime.zig");
const console = @import("../tasks/console.zig");
const execution_queue = @import("../tasks/execution_queue.zig");
const modes = @import("../language/modes.zig");
const lsp_manager = @import("../lsp/manager.zig");
const lsp_session = @import("../lsp/session.zig");
const workspace = @import("../workspace/workspace.zig");
const workspace_io = @import("../security/workspace_io.zig");
const debug_manager = @import("../debug/manager.zig");
const recovery_mod = @import("../persistence/recovery.zig");

const max_document_bytes = 32 * 1024 * 1024;

pub const Mode = enum {
    normal,
    command,
    insert,
};

pub const Focus = enum {
    files,
    editor,
    output,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    runtime: runtime.Runtime,
    mode: Mode,
    focus: Focus,
    file_cursor: usize,
    workspace: workspace.Workspace,
    documents: store.DocumentStore,
    palette: command_palette.CommandPalette,
    diagnostics: diagnostics.Collection,
    security_findings: security_findings.Collection,
    process_console: console.ProcessConsole,
    lsp_manager: lsp_manager.Manager,
    debug_manager: debug_manager.Manager,
    recovery_manager: recovery_mod.Manager,
    pending_build_consent: ?build_consent.Preview,
    pending_build_source_id: ?[]u8,
    pending_build_argument: ?[]u8,
    execution_queue: execution_queue.Queue,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !App {
        return initWithProcess(allocator, root_path, std.Options.debug_io, std.process.Environ.empty);
    }

    pub fn initWithProcess(
        allocator: std.mem.Allocator,
        root_path: []const u8,
        io: std.Io,
        environ: std.process.Environ,
    ) !App {
        const open_kind = detectOpenKind(root_path);
        const workspace_path = if (open_kind == .file)
            std.fs.path.dirname(root_path) orelse "."
        else
            root_path;

        var self = initialized: {
            var workspace_state = try workspace.Workspace.open(allocator, workspace_path);
            errdefer workspace_state.deinit();
            var language_servers = try lsp_manager.Manager.init(allocator, workspace_path);
            errdefer language_servers.deinit();
            var debugger = try debug_manager.Manager.init(allocator, workspace_state.root_path);
            errdefer debugger.deinit();
            var recovery = try recovery_mod.Manager.init(allocator, workspace_state.root_path);
            errdefer recovery.deinit();

            break :initialized App{
                .allocator = allocator,
                .io = io,
                .environ = environ,
                .runtime = runtime.Runtime.init(allocator),
                .mode = .normal,
                .focus = .files,
                .file_cursor = 0,
                .workspace = workspace_state,
                .documents = store.DocumentStore.init(allocator),
                .palette = command_palette.CommandPalette.init(allocator),
                .diagnostics = diagnostics.Collection.init(allocator),
                .security_findings = security_findings.Collection.init(allocator),
                .process_console = console.ProcessConsole.init(allocator),
                .lsp_manager = language_servers,
                .debug_manager = debugger,
                .recovery_manager = recovery,
                .pending_build_consent = null,
                .pending_build_source_id = null,
                .pending_build_argument = null,
                .execution_queue = execution_queue.Queue.init(allocator),
            };
        };
        errdefer self.deinit();
        self.file_cursor = self.firstFileEntryIndex() orelse 0;

        if (open_kind == .file) {
            const resolved_file = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, root_path, allocator);
            defer allocator.free(resolved_file);
            _ = try self.openWorkspacePath(resolved_file);
            self.focus = .editor;
        }

        return self;
    }

    pub fn deinit(self: *App) void {
        self.clearPendingBuildConsent();
        self.recovery_manager.deinit();
        self.debug_manager.deinit();
        self.lsp_manager.deinit();
        self.execution_queue.deinit();
        self.process_console.deinit();
        self.security_findings.deinit();
        self.diagnostics.deinit();
        self.palette.deinit();
        self.documents.deinit();
        self.workspace.deinit();
    }

    pub fn checkpointRecovery(self: *App) !recovery_mod.CheckpointReport {
        return self.recovery_manager.checkpointDocuments(self.documents.documents.items);
    }

    pub fn render(self: *const App, stdout: anytype) !void {
        try render_view.renderWorkspace(stdout, self);
    }

    pub fn clearPendingBuildConsent(self: *App) void {
        if (self.pending_build_consent) |*preview| {
            preview.deinit();
        }
        if (self.pending_build_source_id) |source_id| {
            self.allocator.free(source_id);
        }
        if (self.pending_build_argument) |argument| {
            self.allocator.free(argument);
        }
        self.pending_build_consent = null;
        self.pending_build_source_id = null;
        self.pending_build_argument = null;
    }

    pub fn setPendingBuildConsent(
        self: *App,
        source_command_id: []const u8,
        argument: ?[]const u8,
        preview: build_consent.Preview,
    ) !void {
        const owned_source_id = try self.allocator.dupe(u8, source_command_id);
        errdefer self.allocator.free(owned_source_id);
        const owned_argument = if (argument) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_argument) |value| self.allocator.free(value);
        self.clearPendingBuildConsent();
        self.pending_build_consent = preview;
        self.pending_build_source_id = owned_source_id;
        self.pending_build_argument = owned_argument;
    }

    pub fn selectedWorkspaceEntry(self: *const App) ?*const workspace.FileEntry {
        if (self.workspace.entries.items.len == 0) return null;
        const index = @min(self.file_cursor, self.workspace.entries.items.len - 1);
        return &self.workspace.entries.items[index];
    }

    pub fn moveFileCursor(self: *App, delta: isize) void {
        self.focus = .files;
        if (self.workspace.entries.items.len == 0) {
            self.file_cursor = 0;
            return;
        }

        const max_index = self.workspace.entries.items.len - 1;
        if (delta < 0) {
            const amount = @as(usize, @intCast(-delta));
            self.file_cursor = if (amount > self.file_cursor) 0 else self.file_cursor - amount;
        } else {
            self.file_cursor = @min(max_index, self.file_cursor + @as(usize, @intCast(delta)));
        }
    }

    pub fn openSelectedWorkspaceEntry(self: *App) !bool {
        const entry = self.selectedWorkspaceEntry() orelse return false;
        if (entry.kind != .file) return false;
        _ = try self.openWorkspaceFile(entry.path);
        self.focus = .editor;
        return true;
    }

    pub fn openWorkspaceFile(self: *App, relative_path: []const u8) !usize {
        try workspace_io.validateRelativeFilePath(relative_path);
        const absolute_path = try workspace_io.absolutePathAlloc(self.allocator, self.workspace.root_path, relative_path);
        defer self.allocator.free(absolute_path);
        if (self.documents.activatePath(absolute_path)) |existing| return existing;

        var capability = try workspace_io.openFileCapability(self.workspace.root_path, relative_path);
        defer capability.close();
        const bytes = try capability.readFileAlloc(self.allocator, max_document_bytes);
        defer self.allocator.free(bytes);
        return self.documents.openBytes(absolute_path, bytes);
    }

    pub fn openWorkspacePath(self: *App, absolute_path: []const u8) !usize {
        const relative_path = try workspace_io.relativeFilePath(self.workspace.root_path, absolute_path);
        return self.openWorkspaceFile(relative_path);
    }

    pub fn activeLanguage(self: *const App) ?modes.LanguageMode {
        const index = self.documents.activeIndex() orelse return null;
        return self.documents.documents.items[index].language;
    }

    pub fn activeLspSession(self: *App) ?*lsp_session.Session {
        const language = self.activeLanguage() orelse return null;
        const server = self.lsp_manager.findServer(language) orelse return null;
        return &server.session;
    }

    pub fn activeLspSessionConst(self: *const App) ?*const lsp_session.Session {
        const language = self.activeLanguage() orelse return null;
        const server = self.lsp_manager.findServerConst(language) orelse return null;
        return &server.session;
    }

    pub fn hasRunningLspForActiveDocument(self: *const App) bool {
        const language = self.activeLanguage() orelse return false;
        const server = self.lsp_manager.findServerConst(language) orelse return false;
        return server.isRunning();
    }

    pub fn hasAnyRunningLsp(self: *const App) bool {
        return self.lsp_manager.hasRunningServer();
    }

    fn firstFileEntryIndex(self: *const App) ?usize {
        for (self.workspace.entries.items, 0..) |entry, index| {
            if (entry.kind == .file) return index;
        }
        return null;
    }
};

const OpenKind = enum {
    file,
    directory,
    unknown,
};

fn detectOpenKind(path: []const u8) OpenKind {
    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return .unknown;
    return switch (stat.kind) {
        .file => .file,
        .directory => .directory,
        else => .unknown,
    };
}
