const std = @import("std");
const render = @import("../ui/render.zig");
const workspace = @import("../workspace/workspace.zig");

pub const Mode = enum {
    normal,
    command,
    insert,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    workspace: workspace.Workspace,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !App {
        return .{
            .allocator = allocator,
            .mode = .normal,
            .workspace = try workspace.Workspace.open(allocator, root_path),
        };
    }

    pub fn deinit(self: *App) void {
        self.workspace.deinit();
    }

    pub fn render(self: *const App, stdout: anytype) !void {
        try render.renderWorkspace(stdout, self);
    }
};

