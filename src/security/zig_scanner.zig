const std = @import("std");
const findings = @import("findings.zig");

pub const ScanOptions = struct {
    path: []const u8 = "(memory)",
};

pub fn scanSource(allocator: std.mem.Allocator, source: []const u8, options: ScanOptions) !findings.Collection {
    var collection = findings.Collection.init(allocator);
    errdefer collection.deinit();

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (line_iter.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        try scanLine(&collection, options.path, line, line_number);
    }

    return collection;
}

fn scanLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detect(collection, path, line, line_number, "@ptrCast", .ffi_boundary, .high, "pointer cast crosses a dangerous memory boundary");
    try detect(collection, path, line, line_number, "@alignCast", .ffi_boundary, .high, "alignment cast must be justified at the boundary");
    try detect(collection, path, line, line_number, "@ptrFromInt", .ffi_boundary, .critical, "integer-to-pointer conversion can create invalid pointers");
    try detect(collection, path, line, line_number, "@intFromPtr", .ffi_boundary, .medium, "pointer value is being exposed as an integer");
    try detect(collection, path, line, line_number, "@setRuntimeSafety(false)", .safety_profile, .high, "runtime safety checks disabled in this scope");

    if (std.mem.indexOf(u8, line, "catch unreachable")) |column| {
        try collection.append(.safety_profile, .medium, path, line_number, column, "catch unreachable turns recoverable failure into a safety boundary", line);
    }

    if (std.mem.indexOf(u8, line, "undefined")) |column| {
        try collection.append(.ide_self_protection, .medium, path, line_number, column, "undefined value requires proof before it crosses a boundary", line);
    }

    if (std.mem.indexOf(u8, line, "extern fn")) |column| {
        try collection.append(.ffi_boundary, .high, path, line_number, column, "extern function is an FFI boundary; wrapper checks should be visible", line);
    }

    if (std.mem.indexOf(u8, line, "export fn")) |column| {
        try collection.append(.ffi_boundary, .medium, path, line_number, column, "exported function exposes a Zig boundary to external callers", line);
    }

    if (std.mem.indexOf(u8, line, "callconv(.c")) |column| {
        try collection.append(.ffi_boundary, .medium, path, line_number, column, "C calling convention boundary detected", line);
    }

    if (std.mem.indexOf(u8, line, "@embedFile")) |column| {
        const risk: findings.Risk = if (mentionsSecretPath(line)) .high else .medium;
        const message = if (risk == .high)
            "possible secret embedded into binary through @embedFile"
        else
            "@embedFile embeds file contents into the artifact";
        try collection.append(.secret_flow, risk, path, line_number, column, message, line);
    }

    if (std.mem.indexOf(u8, line, "addSystemCommand")) |column| {
        try collection.append(.build_firewall, .high, path, line_number, column, "build.zig can execute an external system command", line);
    }

    if (std.mem.indexOf(u8, line, "linkSystemLibrary")) |column| {
        try collection.append(.ffi_boundary, .medium, path, line_number, column, "system library link expands the trusted computing boundary", line);
    }
}

fn detect(
    collection: *findings.Collection,
    path: []const u8,
    line: []const u8,
    line_number: usize,
    needle: []const u8,
    category: findings.Category,
    risk: findings.Risk,
    message: []const u8,
) !void {
    if (std.mem.indexOf(u8, line, needle)) |column| {
        try collection.append(category, risk, path, line_number, column, message, line);
    }
}

fn mentionsSecretPath(line: []const u8) bool {
    const needles = [_][]const u8{ ".env", "secret", "token", "key", ".pem", "credential", "password" };
    for (needles) |needle| {
        if (indexOfIgnoreCase(line, needle) != null) return true;
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

test "scanner detects Zig-specific security boundaries" {
    var collection = try scanSource(std.testing.allocator,
        \\extern fn c_read(buf: [*]u8, len: usize) c_int;
        \\const token = @embedFile("../.env");
        \\@setRuntimeSafety(false);
        \\const p = @ptrCast(raw);
        \\
    , .{ .path = "src/main.zig" });
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.high) >= 3);
}

