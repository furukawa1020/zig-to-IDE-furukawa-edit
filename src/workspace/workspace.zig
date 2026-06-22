const std = @import("std");
const modes = @import("../language/modes.zig");

pub const FileKind = enum {
    file,
    directory,
    other,
};

pub const FileEntry = struct {
    path: []u8,
    kind: FileKind,
    language: modes.LanguageMode,
    depth: usize,
};

pub const ScanOptions = struct {
    max_entries: usize = 20_000,
    max_depth: usize = 32,
    include_hidden: bool = true,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    root_path: []u8,
    entries: std.array_list.Managed(FileEntry),
    scan_options: ScanOptions = .{},

    pub fn open(allocator: std.mem.Allocator, root_path: []const u8) !Workspace {
        const resolved = resolved_path: {
            const resolved_raw = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, root_path, allocator) catch {
                break :resolved_path try allocator.dupe(u8, root_path);
            };
            defer allocator.free(resolved_raw);
            break :resolved_path try allocator.dupe(u8, resolved_raw);
        };
        var self = Workspace{
            .allocator = allocator,
            .root_path = resolved,
            .entries = std.array_list.Managed(FileEntry).init(allocator),
        };
        try self.scanTopLevel();
        return self;
    }

    pub fn deinit(self: *Workspace) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.path);
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

    pub fn refresh(self: *Workspace) !void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.path);
        }
        self.entries.clearRetainingCapacity();
        try self.scanTopLevel();
    }

    fn scanTopLevel(self: *Workspace) !void {
        try self.scanRecursive("", 0);
    }

    fn scanRecursive(self: *Workspace, relative: []const u8, depth: usize) !void {
        if (depth > self.scan_options.max_depth) return;
        if (self.entries.items.len >= self.scan_options.max_entries) return;

        const absolute = try self.absolutePath(relative);
        defer self.allocator.free(absolute);

        var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, absolute, .{ .iterate = true }) catch {
            return;
        };
        defer dir.close(std.Options.debug_io);

        var iter = dir.iterate();
        while (try iter.next(std.Options.debug_io)) |entry| {
            if (self.entries.items.len >= self.scan_options.max_entries) break;
            if (shouldSkip(entry.name, self.scan_options)) continue;

            const kind: FileKind = switch (entry.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            };
            const child_path = try joinRelative(self.allocator, relative, entry.name);
            defer self.allocator.free(child_path);

            try self.entries.append(.{
                .path = try self.allocator.dupe(u8, child_path),
                .kind = kind,
                .language = modes.detect(child_path),
                .depth = depth,
            });

            if (kind == .directory) {
                try self.scanRecursive(child_path, depth + 1);
            }
        }
    }

    fn absolutePath(self: *Workspace, relative: []const u8) ![]u8 {
        if (relative.len == 0) return self.allocator.dupe(u8, self.root_path);
        return std.fs.path.join(self.allocator, &.{ self.root_path, relative });
    }
};

fn joinRelative(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![]u8 {
    if (parent.len == 0) return allocator.dupe(u8, name);
    return std.fs.path.join(allocator, &.{ parent, name });
}

fn shouldSkip(name: []const u8, options: ScanOptions) bool {
    if (!options.include_hidden and name.len > 0 and name[0] == '.') return true;
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".tools") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, ".zig-global-cache") or
        std.mem.eql(u8, name, "zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, ".DS_Store");
}

test "workspace can open current directory" {
    var ws = try Workspace.open(std.testing.allocator, ".");
    defer ws.deinit();

    try std.testing.expect(ws.root_path.len > 0);
}

test "workspace skips generated tool and cache directories" {
    try std.testing.expect(shouldSkip(".tools", .{}));
    try std.testing.expect(shouldSkip(".zig-cache", .{}));
    try std.testing.expect(shouldSkip(".zig-global-cache", .{}));
    try std.testing.expect(shouldSkip("zig-out", .{}));
}
