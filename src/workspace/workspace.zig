const std = @import("std");
const modes = @import("../language/modes.zig");

pub const FileKind = enum {
    file,
    directory,
    other,
};

pub const FileEntry = struct {
    name: []u8,
    kind: FileKind,
    language: modes.LanguageMode,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    root_path: []u8,
    entries: std.ArrayList(FileEntry),

    pub fn open(allocator: std.mem.Allocator, root_path: []const u8) !Workspace {
        const resolved = std.fs.cwd().realpathAlloc(allocator, root_path) catch try allocator.dupe(u8, root_path);
        var self = Workspace{
            .allocator = allocator,
            .root_path = resolved,
            .entries = std.ArrayList(FileEntry).init(allocator),
        };
        try self.scanTopLevel();
        return self;
    }

    pub fn deinit(self: *Workspace) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit();
        self.allocator.free(self.root_path);
        self.* = undefined;
    }

    pub fn countZigFamily(self: *const Workspace) usize {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (modes.isZigFamily(entry.language)) count += 1;
        }
        return count;
    }

    fn scanTopLevel(self: *Workspace) !void {
        var dir = std.fs.openDirAbsolute(self.root_path, .{ .iterate = true }) catch {
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        var seen: usize = 0;
        while (try iter.next()) |entry| {
            if (seen >= 128) break;
            seen += 1;

            const kind: FileKind = switch (entry.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            };

            try self.entries.append(.{
                .name = try self.allocator.dupe(u8, entry.name),
                .kind = kind,
                .language = modes.detect(entry.name),
            });
        }
    }
};

test "workspace can open current directory" {
    var ws = try Workspace.open(std.testing.allocator, ".");
    defer ws.deinit();

    try std.testing.expect(ws.root_path.len > 0);
}

