const std = @import("std");
const findings = @import("findings.zig");

pub const ScanOptions = struct {
    path: []const u8 = "build.zig.zon",
};

pub fn scanZon(allocator: std.mem.Allocator, source: []const u8, options: ScanOptions) !findings.Collection {
    var collection = findings.Collection.init(allocator);
    errdefer collection.deinit();

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    var in_dependency_block = false;
    var current_dependency_has_hash = false;
    var current_dependency_line: ?usize = null;

    while (line_iter.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \t\r,");

        if (std.mem.indexOf(u8, line, ".dependencies")) |_| {
            in_dependency_block = true;
            continue;
        }

        if (!in_dependency_block) continue;

        if (looksLikeDependencyName(line)) {
            if (current_dependency_line) |dependency_line| {
                if (!current_dependency_has_hash) {
                    try collection.append(.package_trust, .high, options.path, dependency_line, 0, "dependency has no visible hash/fingerprint before next dependency", "");
                }
            }
            current_dependency_line = line_number;
            current_dependency_has_hash = false;
        }

        if (std.mem.indexOf(u8, line, ".hash")) |column| {
            current_dependency_has_hash = true;
            try collection.append(.package_trust, .info, options.path, line_number, column, "dependency fingerprint/hash is present", line);
        }

        if (std.mem.indexOf(u8, line, ".url")) |column| {
            try collection.append(.package_trust, .medium, options.path, line_number, column, "dependency fetched from URL; source and fingerprint should be reviewed", line);
        }

        if (std.mem.indexOf(u8, line, ".path")) |column| {
            const risk: findings.Risk = if (std.mem.indexOf(u8, line, "../") != null) .high else .low;
            try collection.append(.package_trust, risk, options.path, line_number, column, "dependency uses local path; boundary should be reviewed", line);
        }
    }

    if (current_dependency_line) |dependency_line| {
        if (!current_dependency_has_hash) {
            try collection.append(.package_trust, .high, options.path, dependency_line, 0, "dependency has no visible hash/fingerprint", "");
        }
    }

    return collection;
}

fn looksLikeDependencyName(line: []const u8) bool {
    if (line.len < 4) return false;
    if (line[0] != '.') return false;
    if (std.mem.indexOfScalar(u8, line, '=') == null) return false;
    return std.mem.indexOf(u8, line, ".hash") == null and
        std.mem.indexOf(u8, line, ".url") == null and
        std.mem.indexOf(u8, line, ".path") == null;
}

test "package trust detects url and missing hash" {
    var collection = try scanZon(std.testing.allocator,
        \\.{
        \\  .dependencies = .{
        \\    .foo = .{
        \\      .url = "https://example.test/foo.tar.gz",
        \\    },
        \\  },
        \\}
        \\
    , .{});
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.medium) >= 1);
}
