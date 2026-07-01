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
        const line = std.mem.trim(u8, raw_line, "\r");
        try scanLine(&collection, options.path, line, line_number);
    }

    return collection;
}

fn scanLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detect(collection, path, line, line_number, "@ptrCast", .ffi_boundary, .high, "pointer cast crosses a dangerous memory boundary");
    try detect(collection, path, line, line_number, "@alignCast", .ffi_boundary, .high, "alignment cast must be justified at the boundary");
    try detect(collection, path, line, line_number, "@ptrFromInt", .ffi_boundary, .critical, "integer-to-pointer conversion can create invalid pointers");
    try detect(collection, path, line, line_number, "@intFromPtr", .ffi_boundary, .medium, "pointer value is being exposed as an integer");
    try detect(collection, path, line, line_number, "@fieldParentPtr", .ffi_boundary, .high, "field-to-parent pointer recovery requires layout and lifetime proof");
    try detect(collection, path, line, line_number, "@addrSpaceCast", .ffi_boundary, .high, "address-space cast crosses a memory domain boundary");
    try detect(collection, path, line, line_number, "@constCast", .ffi_boundary, .medium, "const cast weakens mutation guarantees at a boundary");
    try detect(collection, path, line, line_number, "@volatileCast", .ffi_boundary, .medium, "volatile cast changes observable memory semantics");
    try detect(collection, path, line, line_number, "@bitCast", .ffi_boundary, .medium, "bit cast relies on exact representation invariants");
    try detect(collection, path, line, line_number, "allowzero", .ffi_boundary, .high, "allowzero pointer accepts address zero; null invariants must be explicit");
    try detect(collection, path, line, line_number, "@setRuntimeSafety(false)", .safety_profile, .high, "runtime safety checks disabled in this scope");
    try detect(collection, path, line, line_number, "@cImport", .ffi_boundary, .high, "C import expands the trusted computing boundary");
    try detect(collection, path, line, line_number, "[*c]", .ffi_boundary, .high, "C pointer type requires explicit null and lifetime checks");
    try detect(collection, path, line, line_number, "anyopaque", .ffi_boundary, .medium, "opaque pointer boundary needs a typed wrapper");
    try detect(collection, path, line, line_number, "@memcpy", .allocator_policy, .medium, "raw memory copy requires length and aliasing proof");
    try detect(collection, path, line, line_number, "@memset", .allocator_policy, .medium, "raw memory initialization requires lifetime proof");
    try detect(collection, path, line, line_number, "std.heap.c_allocator", .allocator_policy, .high, "C allocator crosses Zig allocator policy");
    try detect(collection, path, line, line_number, "std.heap.raw_c_allocator", .allocator_policy, .high, "raw C allocator bypasses Zig allocator safety expectations");
    try detect(collection, path, line, line_number, "std.heap.page_allocator", .allocator_policy, .medium, "page allocator should be justified for long-lived allocations");
    try detect(collection, path, line, line_number, "ArenaAllocator", .allocator_policy, .low, "arena lifetime should be bounded to a visible scope");
    try detect(collection, path, line, line_number, "GeneralPurposeAllocator", .allocator_policy, .info, "general purpose allocator boundary detected");
    try detect(collection, path, line, line_number, "std.process.run", .build_firewall, .high, "Zig source can spawn a child process");
    try detect(collection, path, line, line_number, "std.process.Child", .build_firewall, .high, "Zig source constructs a child process");
    try detect(collection, path, line, line_number, "std.process.getEnv", .secret_flow, .medium, "environment read can expose ambient secrets");
    try detect(collection, path, line, line_number, "std.process.args", .secret_flow, .low, "process arguments are an ambient input boundary");
    try detect(collection, path, line, line_number, "std.Io.Dir.delete", .filesystem_boundary, .high, "filesystem deletion boundary requires workspace policy");
    try detect(collection, path, line, line_number, "deleteFile", .filesystem_boundary, .high, "file deletion boundary requires workspace policy");
    try detect(collection, path, line, line_number, "deleteTree", .filesystem_boundary, .critical, "recursive deletion boundary requires explicit review");
    try detect(collection, path, line, line_number, "createFileAbsolute", .filesystem_boundary, .high, "absolute file creation crosses the workspace boundary");
    try detect(collection, path, line, line_number, "openFileAbsolute", .filesystem_boundary, .medium, "absolute file open crosses the workspace boundary");
    try detect(collection, path, line, line_number, "openDirAbsolute", .filesystem_boundary, .medium, "absolute directory open crosses the workspace boundary");
    try detect(collection, path, line, line_number, "renameAbsolute", .filesystem_boundary, .medium, "absolute rename crosses the workspace boundary");
    try detect(collection, path, line, line_number, "makePath", .filesystem_boundary, .medium, "directory creation should be constrained to workspace policy");
    try detect(collection, path, line, line_number, "std.net", .network_boundary, .medium, "network boundary detected in Zig source");
    try detect(collection, path, line, line_number, "std.http.Client", .network_boundary, .medium, "HTTP client boundary detected in Zig source");
    try detect(collection, path, line, line_number, "resolveIp", .network_boundary, .medium, "DNS/IP resolution boundary detected");
    try detect(collection, path, line, line_number, "tcpConnectTo", .network_boundary, .high, "outbound TCP connection boundary detected");
    try detect(collection, path, line, line_number, "threadlocal", .concurrency_boundary, .medium, "threadlocal state can hide cross-thread invariants");
    try detect(collection, path, line, line_number, "std.Thread.spawn", .concurrency_boundary, .medium, "thread spawn boundary requires lifetime and allocator review");
    try detect(collection, path, line, line_number, "std.atomic", .concurrency_boundary, .medium, "atomic memory boundary requires ordering proof");
    try detect(collection, path, line, line_number, "@atomic", .concurrency_boundary, .medium, "atomic builtin requires ordering proof");
    try detect(collection, path, line, line_number, "ReleaseFast", .safety_profile, .high, "ReleaseFast removes runtime safety checks unless explicitly overridden");
    try detect(collection, path, line, line_number, "asm", .ffi_boundary, .high, "inline assembly escapes Zig's normal safety model");
    try detect(collection, path, line, line_number, "std.DynLib.open", .ffi_boundary, .high, "dynamic library load expands the trusted computing boundary");

    if (std.mem.indexOf(u8, line, "catch unreachable")) |column| {
        try collection.append(.safety_profile, .medium, path, line_number, column, "catch unreachable turns recoverable failure into a safety boundary", line);
    }

    if (std.mem.indexOf(u8, line, "unreachable")) |column| {
        try collection.append(.safety_profile, .medium, path, line_number, column, "unreachable is a proof obligation; invalid proof can become undefined behavior", line);
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

test "scanner detects allocator and C import boundaries" {
    var collection = try scanSource(std.testing.allocator,
        \\const c = @cImport({});
        \\const allocator = std.heap.c_allocator;
        \\const view: [*c]u8 = null;
        \\const mode = .ReleaseFast;
        \\
    , .{ .path = "src/ffi.zig" });
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.high) >= 4);
}

test "scanner detects Zig filesystem network and concurrency boundaries" {
    var collection = try scanSource(std.testing.allocator,
        \\const client = std.http.Client{};
        \\try std.net.tcpConnectToHost(allocator, "example.test", 443);
        \\try std.Io.Dir.deleteFile(dir, "old");
        \\try std.Io.Dir.deleteTree(dir, "cache");
        \\_ = try std.Thread.spawn(.{}, worker, .{});
        \\const value = @atomicLoad(u32, ptr, .seq_cst);
        \\const secret = try std.process.getEnvVarOwned(allocator, "TOKEN");
        \\
    , .{ .path = "src/boundaries.zig" });
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.critical) >= 1);
    try std.testing.expect(collection.countRiskAtLeast(.high) >= 2);
    try std.testing.expect(collection.countRiskAtLeast(.medium) >= 5);
}
