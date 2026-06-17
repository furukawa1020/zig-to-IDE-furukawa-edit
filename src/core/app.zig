const std = @import("std");
const build_consent = @import("../security/build_consent.zig");
const command_palette = @import("../ui/command_palette.zig");
const diagnostics = @import("../diagnostics/collection.zig");
const security_findings = @import("../security/findings.zig");
const store = @import("../editor/store.zig");
const render = @import("../ui/render.zig");
const runtime = @import("runtime.zig");
const console = @import("../tasks/console.zig");
const execution_queue = @import("../tasks/execution_queue.zig");
const workspace = @import("../workspace/workspace.zig");

pub const Mode = enum {
    normal,
    command,
    insert,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    runtime: runtime.Runtime,
    mode: Mode,
    workspace: workspace.Workspace,
    documents: store.DocumentStore,
    palette: command_palette.CommandPalette,
    diagnostics: diagnostics.Collection,
    security_findings: security_findings.Collection,
    process_console: console.ProcessConsole,
    pending_build_consent: ?build_consent.Preview,
    pending_build_source_id: ?[]u8,
    execution_queue: execution_queue.Queue,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !App {
        const open_kind = detectOpenKind(root_path);
        const workspace_path = if (open_kind == .file)
            std.fs.path.dirname(root_path) orelse "."
        else
            root_path;

        var self = App{
            .allocator = allocator,
            .runtime = runtime.Runtime.init(allocator),
            .mode = .normal,
            .workspace = try workspace.Workspace.open(allocator, workspace_path),
            .documents = store.DocumentStore.init(allocator),
            .palette = command_palette.CommandPalette.init(allocator),
            .diagnostics = diagnostics.Collection.init(allocator),
            .security_findings = security_findings.Collection.init(allocator),
            .process_console = console.ProcessConsole.init(allocator),
            .pending_build_consent = null,
            .pending_build_source_id = null,
            .execution_queue = execution_queue.Queue.init(allocator),
        };
        errdefer self.deinit();

        if (open_kind == .file) {
            _ = try self.documents.openFile(root_path);
        }

        return self;
    }

    pub fn deinit(self: *App) void {
        self.clearPendingBuildConsent();
        self.execution_queue.deinit();
        self.process_console.deinit();
        self.security_findings.deinit();
        self.diagnostics.deinit();
        self.palette.deinit();
        self.documents.deinit();
        self.workspace.deinit();
    }

    pub fn render(self: *const App, stdout: anytype) !void {
        try render.renderWorkspace(stdout, self);
    }

    pub fn clearPendingBuildConsent(self: *App) void {
        if (self.pending_build_consent) |*preview| {
            preview.deinit();
        }
        if (self.pending_build_source_id) |source_id| {
            self.allocator.free(source_id);
        }
        self.pending_build_consent = null;
        self.pending_build_source_id = null;
    }

    pub fn setPendingBuildConsent(self: *App, source_command_id: []const u8, preview: build_consent.Preview) !void {
        const owned_source_id = try self.allocator.dupe(u8, source_command_id);
        errdefer self.allocator.free(owned_source_id);
        self.clearPendingBuildConsent();
        self.pending_build_consent = preview;
        self.pending_build_source_id = owned_source_id;
    }
};

const OpenKind = enum {
    file,
    directory,
    unknown,
};

fn detectOpenKind(path: []const u8) OpenKind {
    const stat = std.fs.cwd().statFile(path) catch return .unknown;
    return switch (stat.kind) {
        .file => .file,
        .directory => .directory,
        else => .unknown,
    };
}
