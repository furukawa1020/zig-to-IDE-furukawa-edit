const std = @import("std");
const findings = @import("../security/findings.zig");

pub const FileStatus = enum {
    clean,
    modified,
    added,
    deleted,
    renamed,
    untracked,
    ignored,
    conflicted,
};

pub const StatusEntry = struct {
    path: []const u8,
    status: FileStatus,
};

pub const AuditOptions = struct {
    max_file_bytes: usize = 256 * 1024,
    max_hooks: usize = 64,
};

pub fn auditRepository(allocator: std.mem.Allocator, workspace_root: []const u8, options: AuditOptions) !findings.Collection {
    var collection = findings.Collection.init(allocator);
    errdefer collection.deinit();

    const git_dir = try resolveGitDir(allocator, workspace_root, &collection);
    defer if (git_dir) |path| allocator.free(path);

    const metadata_dir = git_dir orelse {
        try collection.append(.git_trust, .info, workspace_root, 0, 0, "no Git metadata found; Git audit skipped", "");
        return collection;
    };

    try collection.append(.git_trust, .info, ".git", 0, 0, "Git metadata opened read-only; zide did not run git status, hooks, filters, or fsmonitor", "");

    try scanConfigFile(allocator, &collection, metadata_dir, "config", ".git/config", options.max_file_bytes);
    try scanHooks(allocator, &collection, metadata_dir, options.max_hooks);
    try scanMetadataAttributesFile(allocator, &collection, metadata_dir, options.max_file_bytes);

    const modules_path = try std.fs.path.join(allocator, &.{ workspace_root, ".gitmodules" });
    defer allocator.free(modules_path);
    if (readFile(allocator, modules_path, options.max_file_bytes)) |bytes| {
        defer allocator.free(bytes);
        try scanGitModules(&collection, ".gitmodules", bytes);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => try collection.append(.git_trust, .medium, ".gitmodules", 0, 0, "could not read .gitmodules during Git audit", @errorName(err)),
    }

    const attributes_path = try std.fs.path.join(allocator, &.{ workspace_root, ".gitattributes" });
    defer allocator.free(attributes_path);
    try scanOptionalAttributesFile(allocator, &collection, attributes_path, ".gitattributes", options.max_file_bytes);

    return collection;
}

fn resolveGitDir(allocator: std.mem.Allocator, workspace_root: []const u8, collection: *findings.Collection) !?[]u8 {
    const dot_git = try std.fs.path.join(allocator, &.{ workspace_root, ".git" });
    errdefer allocator.free(dot_git);

    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, dot_git, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(dot_git);
            return null;
        },
        else => return err,
    };

    switch (stat.kind) {
        .directory => return dot_git,
        .file => {
            const bytes = try readFile(allocator, dot_git, 16 * 1024);
            defer allocator.free(bytes);
            const resolved = (try parseGitdirFile(allocator, workspace_root, bytes)) orelse {
                try collection.append(.git_trust, .medium, ".git", 0, 0, ".git file does not contain a gitdir pointer", "");
                allocator.free(dot_git);
                return null;
            };
            if (!isInsideWorkspace(workspace_root, resolved)) {
                try collection.append(.git_trust, .high, ".git", 0, 0, ".git points outside the workspace; Git metadata trust crosses a directory boundary", resolved);
            }
            allocator.free(dot_git);
            return resolved;
        },
        else => {
            try collection.append(.git_trust, .medium, ".git", 0, 0, ".git is neither a directory nor a gitdir file", "");
            allocator.free(dot_git);
            return null;
        },
    }
}

fn parseGitdirFile(allocator: std.mem.Allocator, workspace_root: []const u8, bytes: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (!startsWithIgnoreCase(trimmed, "gitdir:")) return null;
    const value = std.mem.trim(u8, trimmed["gitdir:".len..], " \t\r\n");
    if (value.len == 0) return null;
    return try resolvePathFrom(allocator, workspace_root, value);
}

fn scanConfigFile(
    allocator: std.mem.Allocator,
    collection: *findings.Collection,
    git_dir: []const u8,
    relative: []const u8,
    display_path: []const u8,
    max_file_bytes: usize,
) !void {
    const path = try std.fs.path.join(allocator, &.{ git_dir, relative });
    defer allocator.free(path);

    const bytes = readFile(allocator, path, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try collection.append(.git_trust, .medium, display_path, 0, 0, "could not read Git config file", @errorName(err));
            return;
        },
    };
    defer allocator.free(bytes);

    try scanGitConfig(collection, display_path, bytes);
}

fn scanGitConfig(collection: *findings.Collection, path: []const u8, bytes: []const u8) !void {
    var current_section: []const u8 = "";
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    var line_number: usize = 0;
    while (line_iter.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            current_section = line;
            if (indexOfIgnoreCase(line, "[includeIf") != null) {
                try collection.append(.git_trust, .high, path, line_number, 0, "conditional Git config include changes trust based on repository path", line);
            }
            continue;
        }

        const lower_section_is_filter = indexOfIgnoreCase(current_section, "[filter") != null;
        const lower_section_is_alias = indexOfIgnoreCase(current_section, "[alias") != null;
        const lower_section_is_core = indexOfIgnoreCase(current_section, "[core") != null;
        const lower_section_is_diff = indexOfIgnoreCase(current_section, "[diff") != null;
        const lower_section_is_difftool = indexOfIgnoreCase(current_section, "[difftool") != null;
        const lower_section_is_include = indexOfIgnoreCase(current_section, "[include") != null;
        const lower_section_is_merge = indexOfIgnoreCase(current_section, "[merge") != null;
        const lower_section_is_mergetool = indexOfIgnoreCase(current_section, "[mergetool") != null;
        const lower_section_is_gpg = indexOfIgnoreCase(current_section, "[gpg") != null;
        const lower_section_is_protocol = indexOfIgnoreCase(current_section, "[protocol") != null;
        const lower_section_is_remote = indexOfIgnoreCase(current_section, "[remote") != null;
        const lower_section_is_sequence = indexOfIgnoreCase(current_section, "[sequence") != null;
        const lower_section_is_submodule = indexOfIgnoreCase(current_section, "[submodule") != null;

        try detectConfig(collection, path, line, line_number, "hooksPath", .high, "custom hooksPath can redirect future Git hook execution");
        try detectConfig(collection, path, line, line_number, "fsmonitor", .high, "Git fsmonitor can execute an external helper during status-like operations");
        try detectConfig(collection, path, line, line_number, "sshCommand", .high, "core.sshCommand changes the executable used for Git network operations");
        try detectConfig(collection, path, line, line_number, "insteadOf", .medium, "url.insteadOf rewrites remotes and can hide the real fetch destination");
        try detectConfig(collection, path, line, line_number, "credential.helper", .medium, "credential helper can execute external credential code");
        try detectConfig(collection, path, line, line_number, "include.path", .high, "Git config includes another config file; review inherited trust");
        try detectConfig(collection, path, line, line_number, "includeIf", .high, "conditional Git config include changes trust based on repository path");

        if (lower_section_is_include and containsAssignment(line, "path")) {
            try collection.append(.git_trust, .high, path, line_number, 0, "Git config includes another config file; review inherited trust", line);
        }

        if (lower_section_is_core and containsAssignment(line, "worktree")) {
            try collection.append(.git_trust, .high, path, line_number, 0, "core.worktree can redirect Git operations outside the opened workspace", line);
        }

        if (lower_section_is_core and containsAssignment(line, "pager")) {
            try collection.append(.git_trust, .medium, path, line_number, 0, "core.pager can execute an external pager during Git output", line);
        }

        if ((lower_section_is_core or lower_section_is_sequence) and containsAssignment(line, "editor")) {
            try collection.append(.git_trust, .medium, path, line_number, 0, "Git editor setting can execute an external editor", line);
        }

        if (lower_section_is_remote and (containsAssignment(line, "url") or containsAssignment(line, "pushurl"))) {
            try detectRemoteUrl(collection, path, line, line_number);
        }

        if (lower_section_is_alias and aliasRunsShell(line)) {
            try collection.append(.git_trust, .high, path, line_number, 0, "Git alias runs a shell command", line);
        }

        if (lower_section_is_filter and (containsAssignment(line, "clean") or containsAssignment(line, "smudge") or containsAssignment(line, "process"))) {
            try collection.append(.git_trust, .high, path, line_number, 0, "Git filter can execute clean/smudge/process commands on file content", line);
        }

        if (lower_section_is_diff and containsAssignment(line, "textconv")) {
            try collection.append(.git_trust, .medium, path, line_number, 0, "Git diff textconv can execute external conversion commands", line);
        }

        if (lower_section_is_merge and containsAssignment(line, "driver")) {
            try collection.append(.git_trust, .medium, path, line_number, 0, "Git merge driver can execute external commands", line);
        }

        if ((lower_section_is_difftool or lower_section_is_mergetool) and containsAssignment(line, "cmd")) {
            try collection.append(.git_trust, .high, path, line_number, 0, "Git tool command can execute external code", line);
        }

        if (lower_section_is_gpg and containsAssignment(line, "program")) {
            try collection.append(.git_trust, .high, path, line_number, 0, "Git gpg.program changes the executable used for signature operations", line);
        }

        if (lower_section_is_protocol and containsAssignment(line, "allow") and assignmentValueIs(line, "allow", "always")) {
            try collection.append(.git_trust, .high, path, line_number, 0, "Git protocol allow=always can enable unsafe transport helpers", line);
        }

        if (lower_section_is_submodule and containsAssignment(line, "update") and indexOfIgnoreCase(line, "!") != null) {
            try collection.append(.git_trust, .critical, path, line_number, 0, "submodule update command executes shell code", line);
        }
    }
}

fn scanGitModules(collection: *findings.Collection, path: []const u8, bytes: []const u8) !void {
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    var line_number: usize = 0;
    while (line_iter.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (containsAssignment(line, "url")) {
            if (indexOfIgnoreCase(line, "http://") != null) {
                try collection.append(.git_trust, .high, path, line_number, 0, "submodule URL uses non-HTTPS transport", line);
            } else {
                try collection.append(.git_trust, .medium, path, line_number, 0, "submodule URL should be reviewed before recursive update", line);
            }
        }
        if (containsAssignment(line, "path") and indexOfIgnoreCase(line, "..") != null) {
            try collection.append(.git_trust, .high, path, line_number, 0, "submodule path references parent traversal", line);
        }
        if (containsAssignment(line, "update") and indexOfIgnoreCase(line, "!") != null) {
            try collection.append(.git_trust, .critical, path, line_number, 0, "submodule update command executes shell code", line);
        }
    }
}

fn scanMetadataAttributesFile(
    allocator: std.mem.Allocator,
    collection: *findings.Collection,
    git_dir: []const u8,
    max_file_bytes: usize,
) !void {
    const path = try std.fs.path.join(allocator, &.{ git_dir, "info", "attributes" });
    defer allocator.free(path);
    try scanOptionalAttributesFile(allocator, collection, path, ".git/info/attributes", max_file_bytes);
}

fn scanOptionalAttributesFile(
    allocator: std.mem.Allocator,
    collection: *findings.Collection,
    absolute: []const u8,
    display_path: []const u8,
    max_file_bytes: usize,
) !void {
    const bytes = readFile(allocator, absolute, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try collection.append(.git_trust, .medium, display_path, 0, 0, "could not read Git attributes file", @errorName(err));
            return;
        },
    };
    defer allocator.free(bytes);

    try scanGitAttributes(collection, display_path, bytes);
}

fn scanGitAttributes(collection: *findings.Collection, path: []const u8, bytes: []const u8) !void {
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    var line_number: usize = 0;
    while (line_iter.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        try detectAttribute(collection, path, line, line_number, "filter=", .high, "Git attribute selects a clean/smudge/process filter that may execute on file content");
        try detectAttribute(collection, path, line, line_number, "diff=", .medium, "Git attribute selects a diff driver; textconv commands should be reviewed");
        try detectAttribute(collection, path, line, line_number, "merge=", .medium, "Git attribute selects a merge driver; custom drivers may execute commands");
        try detectAttribute(collection, path, line, line_number, "working-tree-encoding", .medium, "Git attribute changes working-tree encoding and can affect file interpretation");
        try detectAttribute(collection, path, line, line_number, "export-subst", .low, "Git attribute rewrites archive output through export substitution");
        try detectAttribute(collection, path, line, line_number, "ident", .low, "Git attribute rewrites ident markers during checkout");
    }
}

fn scanHooks(allocator: std.mem.Allocator, collection: *findings.Collection, git_dir: []const u8, max_hooks: usize) !void {
    const hooks_dir = try std.fs.path.join(allocator, &.{ git_dir, "hooks" });
    defer allocator.free(hooks_dir);

    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, hooks_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try collection.append(.git_trust, .medium, ".git/hooks", 0, 0, "could not inspect Git hooks directory", @errorName(err));
            return;
        },
    };
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();
    var seen: usize = 0;
    while (try iter.next(std.Options.debug_io)) |entry| {
        if (seen >= max_hooks) {
            try collection.append(.git_trust, .medium, ".git/hooks", 0, 0, "Git hook audit reached its hook limit", "");
            break;
        }
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".sample")) continue;
        seen += 1;

        const risk: findings.Risk = if (isHighImpactHook(entry.name)) .high else .medium;
        try collection.append(.git_trust, risk, ".git/hooks", 0, 0, "Git hook script present; zide will not run it, but future Git commands may", entry.name);
    }
}

fn detectAttribute(
    collection: *findings.Collection,
    path: []const u8,
    line: []const u8,
    line_number: usize,
    needle: []const u8,
    risk: findings.Risk,
    message: []const u8,
) !void {
    if (attributeContains(line, needle)) |column| {
        try collection.append(.git_trust, risk, path, line_number, column, message, line);
    }
}

fn detectConfig(
    collection: *findings.Collection,
    path: []const u8,
    line: []const u8,
    line_number: usize,
    needle: []const u8,
    risk: findings.Risk,
    message: []const u8,
) !void {
    if (indexOfIgnoreCase(line, needle)) |column| {
        try collection.append(.git_trust, risk, path, line_number, column, message, line);
    }
}

fn detectRemoteUrl(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    const value = assignmentValue(line, "url") orelse assignmentValue(line, "pushurl") orelse return;
    if (startsWithIgnoreCase(value, "http://")) {
        try collection.append(.git_trust, .high, path, line_number, 0, "Git remote URL uses non-HTTPS transport", line);
        return;
    }
    if (startsWithIgnoreCase(value, "git://")) {
        try collection.append(.git_trust, .high, path, line_number, 0, "Git remote URL uses unauthenticated git:// transport", line);
        return;
    }
    if (startsWithIgnoreCase(value, "file://") or startsWithIgnoreCase(value, "../") or startsWithIgnoreCase(value, "..\\")) {
        try collection.append(.git_trust, .high, path, line_number, 0, "Git remote URL points at a local or parent-directory path", line);
        return;
    }
    try collection.append(.git_trust, .medium, path, line_number, 0, "Git remote URL should be reviewed before network operations", line);
}

fn attributeContains(line: []const u8, needle: []const u8) ?usize {
    var offset: usize = 0;
    var parts = std.mem.tokenizeAny(u8, line, " \t");
    while (parts.next()) |part| {
        const found = indexOfIgnoreCase(part, needle) orelse {
            offset += part.len + 1;
            continue;
        };
        return offset + found;
    }
    return null;
}

fn aliasRunsShell(line: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, line, '=') orelse return false;
    const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
    return value.len > 0 and value[0] == '!';
}

fn containsAssignment(line: []const u8, key: []const u8) bool {
    return assignmentValue(line, key) != null;
}

fn assignmentValueIs(line: []const u8, key: []const u8, expected: []const u8) bool {
    const value = assignmentValue(line, key) orelse return false;
    return std.ascii.eqlIgnoreCase(value, expected);
}

fn assignmentValue(line: []const u8, key: []const u8) ?[]const u8 {
    const equals = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..equals], " \t");
    if (!std.ascii.eqlIgnoreCase(left, key)) return null;
    return std.mem.trim(u8, line[equals + 1 ..], " \t");
}

fn isHighImpactHook(name: []const u8) bool {
    const hooks = [_][]const u8{
        "pre-commit",
        "prepare-commit-msg",
        "commit-msg",
        "post-checkout",
        "post-merge",
        "post-rewrite",
        "pre-push",
        "pre-rebase",
    };
    for (hooks) |hook| {
        if (std.ascii.eqlIgnoreCase(name, hook)) return true;
    }
    return false;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(max_bytes));
}

fn resolvePathFrom(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try std.fs.path.resolve(allocator, &.{path});
    return try std.fs.path.resolve(allocator, &.{ base, path });
}

fn isInsideWorkspace(workspace_root: []const u8, path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return true;
    if (workspace_root.len == 0 or path.len < workspace_root.len) return false;
    if (!std.ascii.eqlIgnoreCase(path[0..workspace_root.len], workspace_root)) return false;
    if (path.len == workspace_root.len) return true;
    const next = path[workspace_root.len];
    return next == '/' or next == '\\';
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

test "git config audit detects executable trust edges" {
    var collection = findings.Collection.init(std.testing.allocator);
    defer collection.deinit();

    try scanGitConfig(&collection, ".git/config",
        \\[core]
        \\  fsmonitor = .git/hooks/fsmonitor-watchman
        \\  hooksPath = hooks
        \\  worktree = ..\outside
        \\  pager = less
        \\[includeIf "gitdir:../other/"]
        \\  path = ../global.gitconfig
        \\[filter "x"]
        \\  process = ./filter.exe
        \\[alias]
        \\  root = !powershell -c whoami
        \\[remote "origin"]
        \\  url = git://example.test/project.git
        \\[difftool "x"]
        \\  cmd = ./diff-tool
        \\[gpg]
        \\  program = ./gpg-wrapper
        \\[protocol "ext"]
        \\  allow = always
        \\
    );

    try std.testing.expect(collection.countRiskAtLeast(.high) >= 11);
}

test "gitmodules audit detects shell update and plain http" {
    var collection = findings.Collection.init(std.testing.allocator);
    defer collection.deinit();

    try scanGitModules(&collection, ".gitmodules",
        \\[submodule "evil"]
        \\  path = ../evil
        \\  url = http://example.test/repo.git
        \\  update = !cmd /c calc
        \\
    );

    try std.testing.expect(collection.countRiskAtLeast(.critical) >= 1);
    try std.testing.expect(collection.countRiskAtLeast(.high) >= 3);
}

test "git attributes audit detects command-backed drivers" {
    var collection = findings.Collection.init(std.testing.allocator);
    defer collection.deinit();

    try scanGitAttributes(&collection, ".gitattributes",
        \\*.secret filter=decrypt diff=secret
        \\*.generated merge=ours
        \\*.txt working-tree-encoding=UTF-16
        \\
    );

    try std.testing.expect(collection.countRiskAtLeast(.high) >= 1);
    try std.testing.expect(collection.countRiskAtLeast(.medium) >= 3);
}
