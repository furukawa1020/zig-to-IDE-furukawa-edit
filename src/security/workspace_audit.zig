const std = @import("std");
const build_firewall = @import("build_firewall.zig");
const findings = @import("findings.zig");
const package_trust = @import("package_trust.zig");
const workspace = @import("../workspace/workspace.zig");
const zig_scanner = @import("zig_scanner.zig");

pub const Options = struct {
    max_file_bytes: usize = 1024 * 1024,
    max_files: usize = 256,
};

pub fn auditWorkspace(allocator: std.mem.Allocator, ws: *const workspace.Workspace, options: Options) !findings.Collection {
    var collection = findings.Collection.init(allocator);
    errdefer collection.deinit();

    try collection.append(.workspace_trust, .info, ws.root_path, 0, 0, "workspace opened in static audit mode; open is not execute", "");

    var scanned: usize = 0;
    var truncated = false;
    for (ws.entries.items) |entry| {
        if (scanned >= options.max_files) {
            truncated = true;
            break;
        }
        if (entry.kind != .file) continue;
        if (!isInteresting(entry.path)) continue;
        scanned += 1;

        const absolute = try std.fs.path.join(allocator, &.{ ws.root_path, entry.path });
        defer allocator.free(absolute);

        const bytes = readFile(allocator, absolute, options.max_file_bytes) catch |err| {
            try collection.append(.workspace_trust, .medium, entry.path, 0, 0, "file could not be read during security audit", @errorName(err));
            continue;
        };
        defer allocator.free(bytes);

        if (std.mem.eql(u8, entry.path, "build.zig")) {
            var build_findings = try build_firewall.scanBuildZig(allocator, bytes, .{ .path = entry.path });
            defer build_findings.deinit();
            try appendAll(&collection, &build_findings);
        }

        if (std.mem.eql(u8, entry.path, "build.zig.zon")) {
            var package_findings = try package_trust.scanZon(allocator, bytes, .{ .path = entry.path });
            defer package_findings.deinit();
            try appendAll(&collection, &package_findings);
        }

        if (std.mem.endsWith(u8, entry.path, ".zig")) {
            var zig_findings = try zig_scanner.scanSource(allocator, bytes, .{ .path = entry.path });
            defer zig_findings.deinit();
            try appendAll(&collection, &zig_findings);
        }
    }

    if (truncated) {
        try collection.append(.workspace_trust, .medium, ws.root_path, 0, 0, "workspace security audit reached its file limit", "");
    }

    return collection;
}

fn appendAll(target: *findings.Collection, source: *const findings.Collection) !void {
    for (source.items.items) |item| {
        try target.appendFinding(item);
    }
}

fn isInteresting(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") or
        std.mem.eql(u8, path, "build.zig.zon");
}

fn readFile(allocator: std.mem.Allocator, absolute: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, absolute, allocator, .limited(max_bytes));
}
