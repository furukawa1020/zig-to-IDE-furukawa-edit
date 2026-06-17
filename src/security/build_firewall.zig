const std = @import("std");
const findings = @import("findings.zig");

pub const ScanOptions = struct {
    path: []const u8 = "build.zig",
};

pub fn scanBuildZig(allocator: std.mem.Allocator, source: []const u8, options: ScanOptions) !findings.Collection {
    var collection = findings.Collection.init(allocator);
    errdefer collection.deinit();

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (line_iter.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, "\r");
        try scanLine(&collection, options.path, line, line_number);
    }

    return collection;
}

fn scanLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detect(collection, path, line, line_number, "addSystemCommand", .critical, "build.zig can execute an arbitrary system command");
    try detect(collection, path, line, line_number, "addRunArtifact", .high, "build step can execute a compiled artifact");
    try detect(collection, path, line, line_number, "std.process", .high, "build script references process APIs");
    try detect(collection, path, line, line_number, "getEnv", .high, "build script may read environment variables");
    try detect(collection, path, line, line_number, "env_map", .medium, "build script handles environment variables");
    try detect(collection, path, line, line_number, "addWriteFiles", .medium, "build script can generate files");
    try detect(collection, path, line, line_number, "addConfigHeader", .medium, "build script can generate configuration headers");
    try detect(collection, path, line, line_number, "addAnonymousModule", .medium, "build script can inject generated module content");
    try detect(collection, path, line, line_number, "linkSystemLibrary", .medium, "build links a system library outside Zig package trust");
    try detect(collection, path, line, line_number, "pkg-config", .medium, "build may consult host pkg-config state");
    try detect(collection, path, line, line_number, "dependency(", .medium, "build resolves a dependency; fingerprint should be reviewed");
    try detect(collection, path, line, line_number, "ReleaseFast", .high, "build selects ReleaseFast; safety posture should be reviewed");

    if (std.mem.indexOf(u8, line, "zig-out")) |column| {
        try collection.append(.build_firewall, .info, path, line_number, column, "build writes to zig-out", line);
    }

    if (std.mem.indexOf(u8, line, "../")) |column| {
        try collection.append(.build_firewall, .high, path, line_number, column, "build script references a parent directory path", line);
    }
}

fn detect(
    collection: *findings.Collection,
    path: []const u8,
    line: []const u8,
    line_number: usize,
    needle: []const u8,
    risk: findings.Risk,
    message: []const u8,
) !void {
    if (std.mem.indexOf(u8, line, needle)) |column| {
        try collection.append(.build_firewall, risk, path, line_number, column, message, line);
    }
}

test "build firewall catches system commands and generated files" {
    var collection = try scanBuildZig(std.testing.allocator,
        \\const run = b.addSystemCommand(&.{ "sh", "-c", "curl x" });
        \\const generated = b.addWriteFiles();
        \\exe.linkSystemLibrary("z");
        \\
    , .{});
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.medium) >= 3);
}
