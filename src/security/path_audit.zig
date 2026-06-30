const std = @import("std");
const findings = @import("findings.zig");

pub fn scanPath(collection: *findings.Collection, path: []const u8, is_file: bool) !void {
    try detectControlPathByte(collection, path);
    try detectNonAsciiPath(collection, path);
    try detectWindowsAmbiguity(collection, path);
    try detectSecretBearingName(collection, path);
    if (is_file) {
        try detectDoubleExtensionMasquerade(collection, path);
        try detectHiddenExecutable(collection, path);
    }
}

fn detectControlPathByte(collection: *findings.Collection, path: []const u8) !void {
    for (path, 0..) |byte, index| {
        if (byte < 0x20 or byte == 0x7f) {
            try collection.append(.path_trust, .high, path, 0, index, "path contains a control byte", "control path byte");
            return;
        }
    }
}

fn detectNonAsciiPath(collection: *findings.Collection, path: []const u8) !void {
    for (path, 0..) |byte, index| {
        if (byte >= 0x80) {
            try collection.append(.path_trust, .low, path, 0, index, "non-ASCII path should be reviewed for lookalike or normalization attacks", "non-ascii path");
            return;
        }
    }
}

fn detectWindowsAmbiguity(collection: *findings.Collection, path: []const u8) !void {
    const base = std.fs.path.basename(path);
    if (base.len == 0) return;

    if (base[base.len - 1] == ' ' or base[base.len - 1] == '.') {
        try collection.append(.path_trust, .high, path, 0, path.len - 1, "path ends with a Windows-ambiguous space or dot", "ambiguous path suffix");
    }
    if (std.mem.indexOfScalar(u8, base, ':')) |index| {
        try collection.append(.path_trust, .high, path, 0, path.len - base.len + index, "path contains ':' which can be an alternate data stream boundary on Windows", "colon in path");
    }

    const stem = basenameStem(base);
    if (isWindowsReservedName(stem)) {
        try collection.append(.path_trust, .high, path, 0, path.len - base.len, "path uses a Windows reserved device name", "reserved device name");
    }
}

fn detectSecretBearingName(collection: *findings.Collection, path: []const u8) !void {
    const base = std.fs.path.basename(path);
    if (std.ascii.eqlIgnoreCase(base, ".env") or
        startsWithIgnoreCase(base, ".env.") or
        std.ascii.eqlIgnoreCase(base, ".npmrc") or
        std.ascii.eqlIgnoreCase(base, ".pypirc") or
        std.ascii.eqlIgnoreCase(base, ".netrc") or
        std.ascii.eqlIgnoreCase(base, "id_rsa") or
        std.ascii.eqlIgnoreCase(base, "id_dsa") or
        std.ascii.eqlIgnoreCase(base, "id_ed25519"))
    {
        try collection.append(.path_trust, .high, path, 0, 0, "secret-bearing filename should be reviewed before commit or execution", base);
        return;
    }

    if (endsWithIgnoreCase(base, ".pem") or endsWithIgnoreCase(base, ".key") or containsIgnoreCase(path, "credential") or containsIgnoreCase(path, "secret")) {
        try collection.append(.path_trust, .medium, path, 0, 0, "path name suggests credential or secret material", base);
    }
}

fn detectDoubleExtensionMasquerade(collection: *findings.Collection, path: []const u8) !void {
    const base = std.fs.path.basename(path);
    const outer = std.fs.path.extension(base);
    if (!isExecutableExtension(outer)) return;
    const without_outer = base[0 .. base.len - outer.len];
    const inner = std.fs.path.extension(without_outer);
    if (!isDocumentLikeExtension(inner)) return;

    try collection.append(.path_trust, .high, path, 0, path.len - outer.len, "double extension can disguise executable content", base);
}

fn detectHiddenExecutable(collection: *findings.Collection, path: []const u8) !void {
    const base = std.fs.path.basename(path);
    if (!isExecutableExtension(std.fs.path.extension(base))) return;
    if (!isHiddenPath(path)) return;
    try collection.append(.path_trust, .medium, path, 0, 0, "executable or script inside a hidden path should be reviewed", base);
}

fn basenameStem(base: []const u8) []const u8 {
    const ext = std.fs.path.extension(base);
    if (ext.len == 0) return base;
    return base[0 .. base.len - ext.len];
}

fn isWindowsReservedName(stem: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(stem, "CON") or
        std.ascii.eqlIgnoreCase(stem, "PRN") or
        std.ascii.eqlIgnoreCase(stem, "AUX") or
        std.ascii.eqlIgnoreCase(stem, "NUL"))
    {
        return true;
    }
    if (stem.len == 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) {
        return stem[3] >= '1' and stem[3] <= '9';
    }
    return false;
}

fn isExecutableExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".exe") or
        std.ascii.eqlIgnoreCase(ext, ".bat") or
        std.ascii.eqlIgnoreCase(ext, ".cmd") or
        std.ascii.eqlIgnoreCase(ext, ".ps1") or
        std.ascii.eqlIgnoreCase(ext, ".vbs") or
        std.ascii.eqlIgnoreCase(ext, ".scr") or
        std.ascii.eqlIgnoreCase(ext, ".msi") or
        std.ascii.eqlIgnoreCase(ext, ".dll") or
        std.ascii.eqlIgnoreCase(ext, ".jar") or
        std.ascii.eqlIgnoreCase(ext, ".js") or
        std.ascii.eqlIgnoreCase(ext, ".sh");
}

fn isDocumentLikeExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".txt") or
        std.ascii.eqlIgnoreCase(ext, ".md") or
        std.ascii.eqlIgnoreCase(ext, ".pdf") or
        std.ascii.eqlIgnoreCase(ext, ".doc") or
        std.ascii.eqlIgnoreCase(ext, ".docx") or
        std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg") or
        std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".gif") or
        std.ascii.eqlIgnoreCase(ext, ".svg") or
        std.ascii.eqlIgnoreCase(ext, ".zip");
}

fn isHiddenPath(path: []const u8) bool {
    var start: usize = 0;
    while (start < path.len) {
        var end = start;
        while (end < path.len and path[end] != '/' and path[end] != '\\') : (end += 1) {}
        const segment = path[start..end];
        if (segment.len > 1 and segment[0] == '.') return true;
        if (end == path.len) break;
        start = end + 1;
    }
    return false;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "path audit detects disguised executable and secret names" {
    var collection = findings.Collection.init(std.testing.allocator);
    defer collection.deinit();

    try scanPath(&collection, "docs/report.pdf.exe", true);
    try scanPath(&collection, ".env", true);
    try scanPath(&collection, ".github/hooks/run.ps1", true);

    try std.testing.expect(collection.countRiskAtLeast(.high) >= 2);
    try std.testing.expect(collection.countRiskAtLeast(.medium) >= 1);
}

test "path audit detects Windows path ambiguity" {
    var collection = findings.Collection.init(std.testing.allocator);
    defer collection.deinit();

    try scanPath(&collection, "NUL.txt", true);
    try scanPath(&collection, "safe/name.", true);
    try scanPath(&collection, "safe/file:stream", true);

    try std.testing.expect(collection.countRiskAtLeast(.high) >= 3);
}
