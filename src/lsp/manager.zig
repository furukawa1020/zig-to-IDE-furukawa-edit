const std = @import("std");
const modes = @import("../language/modes.zig");
const lsp_session = @import("session.zig");
const lsp_transport = @import("transport.zig");

pub const Server = struct {
    language: modes.LanguageMode,
    session: lsp_session.Session,
    transport: ?lsp_transport.Transport = null,

    pub fn deinit(self: *Server) void {
        if (self.transport) |*transport| {
            transport.deinit();
            self.transport = null;
        }
        self.session.deinit();
        self.* = undefined;
    }

    pub fn isRunning(self: *const Server) bool {
        return self.transport != null;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    workspace_root: []u8,
    servers: std.array_list.Managed(Server),

    pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) !Manager {
        return .{
            .allocator = allocator,
            .workspace_root = try allocator.dupe(u8, workspace_root),
            .servers = std.array_list.Managed(Server).init(allocator),
        };
    }

    pub fn deinit(self: *Manager) void {
        for (self.servers.items) |*server| server.deinit();
        self.servers.deinit();
        self.allocator.free(self.workspace_root);
        self.* = undefined;
    }

    pub fn ensureServer(self: *Manager, language: modes.LanguageMode) !*Server {
        if (self.findServer(language)) |server| return server;
        try self.servers.append(.{
            .language = language,
            .session = try lsp_session.Session.init(self.allocator, self.workspace_root),
        });
        return &self.servers.items[self.servers.items.len - 1];
    }

    pub fn findServer(self: *Manager, language: modes.LanguageMode) ?*Server {
        for (self.servers.items) |*server| {
            if (server.language == language) return server;
        }
        return null;
    }

    pub fn findServerConst(self: *const Manager, language: modes.LanguageMode) ?*const Server {
        for (self.servers.items) |*server| {
            if (server.language == language) return server;
        }
        return null;
    }

    pub fn runningCount(self: *const Manager) usize {
        var count: usize = 0;
        for (self.servers.items) |server| {
            if (server.isRunning()) count += 1;
        }
        return count;
    }

    pub fn hasRunningServer(self: *const Manager) bool {
        return self.runningCount() > 0;
    }

    pub fn stopServer(self: *Manager, language: modes.LanguageMode) bool {
        const server = self.findServer(language) orelse return false;
        if (server.transport) |*transport| {
            transport.deinit();
            server.transport = null;
            server.session.state = .stopped;
            return true;
        }
        return false;
    }

    pub fn stopAll(self: *Manager) usize {
        var count: usize = 0;
        for (self.servers.items) |*server| {
            if (server.transport) |*transport| {
                transport.deinit();
                server.transport = null;
                server.session.state = .stopped;
                count += 1;
            }
        }
        return count;
    }
};

test "manager creates one slot per language" {
    var manager = try Manager.init(std.testing.allocator, "/tmp/project");
    defer manager.deinit();

    const zig_one = try manager.ensureServer(.zig);
    const zig_two = try manager.ensureServer(.zig);
    const rust = try manager.ensureServer(.rust);

    try std.testing.expectEqual(@as(usize, 2), manager.servers.items.len);
    try std.testing.expect(zig_one == zig_two);
    try std.testing.expect(zig_one != rust);
}
