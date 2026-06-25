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
            if (looksEmptyHash(line)) {
                try collection.append(.package_trust, .high, options.path, line_number, column, "dependency hash appears empty", line);
            }
            if (looksWeakHash(line)) {
                try collection.append(.package_trust, .medium, options.path, line_number, column, "dependency hash looks too short or placeholder-like", line);
            }
        }

        if (std.mem.indexOf(u8, line, ".url")) |column| {
            const risk: findings.Risk = if (looksPlainHttp(line)) .high else .medium;
            const message = if (risk == .high)
                "dependency fetched over non-HTTPS URL"
            else
                "dependency fetched from URL; source and fingerprint should be reviewed";
            try collection.append(.package_trust, risk, options.path, line_number, column, message, line);
            try scanUrlTrustEdges(&collection, options.path, line, line_number);
        }

        if (std.mem.indexOf(u8, line, ".path")) |column| {
            const risk = pathDependencyRisk(line);
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

fn looksPlainHttp(line: []const u8) bool {
    return indexOfIgnoreCase(line, "http://") != null;
}

fn looksEmptyHash(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"\"") != null;
}

fn looksWeakHash(line: []const u8) bool {
    const value = quotedValue(line) orelse return false;
    if (value.len == 0) return false;
    if (value.len < 32) return true;
    return indexOfIgnoreCase(value, "todo") != null or
        indexOfIgnoreCase(value, "replace") != null or
        std.mem.eql(u8, value, "...");
}

fn pathDependencyRisk(line: []const u8) findings.Risk {
    const value = quotedValue(line) orelse line;
    if (std.mem.indexOf(u8, value, "../") != null or std.mem.indexOf(u8, value, "..\\") != null) return .high;
    if (std.mem.startsWith(u8, value, "/") or std.mem.startsWith(u8, value, "~/")) return .high;
    if (value.len >= 3 and std.ascii.isAlphabetic(value[0]) and value[1] == ':' and (value[2] == '/' or value[2] == '\\')) return .high;
    return .low;
}

fn scanUrlTrustEdges(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detect(collection, path, line, line_number, "git://", .critical, "dependency uses unauthenticated git transport");
    try detect(collection, path, line, line_number, "file://", .high, "dependency URL reads from local filesystem");
    try detect(collection, path, line, line_number, "localhost", .high, "dependency URL depends on the local host");
    try detect(collection, path, line, line_number, "127.0.0.1", .high, "dependency URL depends on loopback host state");
    try detect(collection, path, line, line_number, "archive/refs/heads", .high, "dependency URL points at a moving branch archive");
    try detect(collection, path, line, line_number, "/tarball/main", .high, "dependency URL points at a moving branch tarball");
    try detect(collection, path, line, line_number, "/tarball/master", .high, "dependency URL points at a moving branch tarball");
    try detect(collection, path, line, line_number, "/zipball/main", .high, "dependency URL points at a moving branch archive");
    try detect(collection, path, line, line_number, "/zipball/master", .high, "dependency URL points at a moving branch archive");
    try detect(collection, path, line, line_number, "releases/latest", .medium, "dependency URL points at a moving latest release");
    try detect(collection, path, line, line_number, ".git", .medium, "dependency URL references a VCS endpoint; prefer immutable archive plus hash");
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
    if (indexOfIgnoreCase(line, needle)) |column| {
        try collection.append(.package_trust, risk, path, line_number, column, message, line);
    }
}

fn quotedValue(line: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    var index = first + 1;
    var escaped = false;
    while (index < line.len) : (index += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (line[index] == '\\') {
            escaped = true;
            continue;
        }
        if (line[index] == '"') return line[first + 1 .. index];
    }
    return null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
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

test "package trust detects mutable and host-local dependencies" {
    var collection = try scanZon(std.testing.allocator,
        \\.{
        \\  .dependencies = .{
        \\    .moving = .{
        \\      .url = "https://github.com/example/pkg/archive/refs/heads/main.tar.gz",
        \\      .hash = "TODO",
        \\    },
        \\    .git_transport = .{
        \\      .url = "git://example.test/pkg.git",
        \\      .hash = "1220abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
        \\    },
        \\    .local = .{
        \\      .path = "C:\\vendor\\pkg",
        \\    },
        \\  },
        \\}
        \\
    , .{});
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.critical) >= 1);
    try std.testing.expect(collection.countRiskAtLeast(.high) >= 2);
    try std.testing.expect(collection.countRiskAtLeast(.medium) >= 2);
}
