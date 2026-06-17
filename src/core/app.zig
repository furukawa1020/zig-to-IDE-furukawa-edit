const std = @import("std");
const store = @import("../editor/store.zig");
const render = @import("../ui/render.zig");
const runtime = @import("runtime.zig");
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
        };
        errdefer self.deinit();

        if (open_kind == .file) {
            _ = try self.documents.openFile(root_path);
        }

        return self;
    }

    pub fn deinit(self: *App) void {
        self.documents.deinit();
        self.workspace.deinit();
    }

    pub fn render(self: *const App, stdout: anytype) !void {
        try render.renderWorkspace(stdout, self);
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
