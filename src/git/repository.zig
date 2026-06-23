const std = @import("std");
const workspace_mod = @import("../workspace/workspace.zig");
const flate = std.compress.flate;

pub const ChangeStatus = enum {
    modified,
    deleted,
    untracked,
};

pub const Change = struct {
    path: []u8,
    status: ChangeStatus,
    additions: usize = 0,
    deletions: usize = 0,
    diff_available: bool = false,

    pub fn deinit(self: *Change, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const GitHubRemote = struct {
    owner: []u8,
    repo: []u8,
    web_url: []u8,
    actions_url: []u8,

    pub fn deinit(self: *GitHubRemote, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.repo);
        allocator.free(self.web_url);
        allocator.free(self.actions_url);
        self.* = undefined;
    }
};

pub const Remote = struct {
    name: []u8,
    url: []u8,
    github: ?GitHubRemote = null,

    pub fn deinit(self: *Remote, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.url);
        if (self.github) |*github| github.deinit(allocator);
        self.* = undefined;
    }
};

pub const InspectOptions = struct {
    max_index_bytes: usize = 16 * 1024 * 1024,
    max_file_bytes: usize = 8 * 1024 * 1024,
    max_changes: usize = 512,
    include_untracked: bool = true,
};

pub const Overview = struct {
    allocator: std.mem.Allocator,
    present: bool = false,
    git_dir: ?[]u8 = null,
    branch: ?[]u8 = null,
    commit: ?[]u8 = null,
    remotes: []Remote = &.{},
    changes: []Change = &.{},
    workflow_paths: [][]u8 = &.{},
    index_version: ?u32 = null,
    index_entries: usize = 0,
    clean_tracked: usize = 0,
    workflow_files: usize = 0,
    ignored_untracked: usize = 0,
    change_limit_hit: bool = false,
    unsupported_index: bool = false,

    pub fn deinit(self: *Overview) void {
        if (self.git_dir) |value| self.allocator.free(value);
        if (self.branch) |value| self.allocator.free(value);
        if (self.commit) |value| self.allocator.free(value);
        for (self.remotes) |*remote| remote.deinit(self.allocator);
        if (self.remotes.len > 0) self.allocator.free(self.remotes);
        for (self.changes) |*change| change.deinit(self.allocator);
        if (self.changes.len > 0) self.allocator.free(self.changes);
        for (self.workflow_paths) |path| self.allocator.free(path);
        if (self.workflow_paths.len > 0) self.allocator.free(self.workflow_paths);
        self.* = undefined;
    }
};

const Index = struct {
    allocator: std.mem.Allocator,
    version: u32,
    entries: []IndexEntry,

    fn deinit(self: *Index) void {
        for (self.entries) |*entry| entry.deinit(self.allocator);
        if (self.entries.len > 0) self.allocator.free(self.entries);
        self.* = undefined;
    }
};

const IndexEntry = struct {
    path: []u8,
    object_id: [20]u8,

    fn deinit(self: *IndexEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

const DiffStats = struct {
    additions: usize = 0,
    deletions: usize = 0,
    available: bool = false,
};

const LooseBlob = struct {
    allocation: []u8,
    body: []const u8,

    fn deinit(self: *LooseBlob, allocator: std.mem.Allocator) void {
        allocator.free(self.allocation);
        self.* = undefined;
    }
};

const IgnorePattern = struct {
    text: []const u8,
    directory_only: bool = false,
    anchored: bool = false,

    fn deinit(self: *IgnorePattern, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

const IgnoreRules = struct {
    allocator: std.mem.Allocator,
    patterns: []IgnorePattern = &.{},

    fn deinit(self: *IgnoreRules) void {
        for (self.patterns) |*pattern| pattern.deinit(self.allocator);
        if (self.patterns.len > 0) self.allocator.free(self.patterns);
        self.* = undefined;
    }

    fn isIgnored(self: *const IgnoreRules, path: []const u8) bool {
        for (self.patterns) |pattern| {
            if (ignorePatternMatches(pattern, path)) return true;
        }
        return false;
    }
};

pub fn inspect(allocator: std.mem.Allocator, workspace: *const workspace_mod.Workspace, options: InspectOptions) !Overview {
    var overview = Overview{ .allocator = allocator };
    errdefer overview.deinit();

    const git_dir = try resolveGitDir(allocator, workspace.root_path);
    overview.git_dir = git_dir orelse return overview;
    overview.present = true;
    overview.workflow_paths = try collectGitHubWorkflowFiles(allocator, workspace);
    overview.workflow_files = overview.workflow_paths.len;

    try readHead(allocator, &overview, overview.git_dir.?);
    overview.remotes = try readRemotes(allocator, overview.git_dir.?);

    var index = readIndex(allocator, overview.git_dir.?, options.max_index_bytes) catch |err| switch (err) {
        error.UnsupportedGitIndexVersion => {
            overview.unsupported_index = true;
            return overview;
        },
        error.FileNotFound => return overview,
        else => return err,
    };
    defer index.deinit();

    overview.index_version = index.version;
    overview.index_entries = index.entries.len;
    var ignore_rules = try loadIgnoreRules(allocator, workspace.root_path, options.max_file_bytes);
    defer ignore_rules.deinit();
    try collectChanges(allocator, workspace, &index, &ignore_rules, options, &overview);

    return overview;
}

fn collectChanges(
    allocator: std.mem.Allocator,
    workspace: *const workspace_mod.Workspace,
    index: *const Index,
    ignore_rules: *const IgnoreRules,
    options: InspectOptions,
    overview: *Overview,
) !void {
    var changes = std.array_list.Managed(Change).init(allocator);
    errdefer {
        for (changes.items) |*change| change.deinit(allocator);
        changes.deinit();
    }

    for (index.entries) |entry| {
        if (changes.items.len >= options.max_changes) {
            overview.change_limit_hit = true;
            break;
        }

        const absolute = try std.fs.path.join(allocator, &.{ workspace.root_path, entry.path });
        defer allocator.free(absolute);

        const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, absolute, allocator, .limited(options.max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
                var old_blob = readLooseBlob(allocator, overview.git_dir.?, entry.object_id, options.max_file_bytes) catch null;
                defer if (old_blob) |*blob| blob.deinit(allocator);
                const stats = if (old_blob) |blob| removedStats(blob.body) else DiffStats{};
                try appendChange(&changes, allocator, entry.path, .deleted, stats);
                continue;
            },
            else => {
                try appendChange(&changes, allocator, entry.path, .modified, .{});
                continue;
            },
        };
        defer allocator.free(bytes);

        const object_id = gitBlobSha1(bytes);
        if (std.mem.eql(u8, object_id[0..], entry.object_id[0..])) {
            overview.clean_tracked += 1;
        } else {
            var old_blob = readLooseBlob(allocator, overview.git_dir.?, entry.object_id, options.max_file_bytes) catch null;
            defer if (old_blob) |*blob| blob.deinit(allocator);
            const stats = if (old_blob) |blob| changedStats(blob.body, bytes) else DiffStats{};
            try appendChange(&changes, allocator, entry.path, .modified, stats);
        }
    }

    if (options.include_untracked and !overview.change_limit_hit) {
        for (workspace.entries.items) |file| {
            if (file.kind != .file) continue;
            if (changes.items.len >= options.max_changes) {
                overview.change_limit_hit = true;
                break;
            }

            const normalized = try duplicateWithSlashes(allocator, file.path);
            defer allocator.free(normalized);
            if (isTracked(index.entries, normalized)) continue;
            if (ignore_rules.isIgnored(normalized)) {
                overview.ignored_untracked += 1;
                continue;
            }
            const stats = addedFileStats(allocator, workspace.root_path, normalized, options.max_file_bytes) catch DiffStats{};
            try appendChange(&changes, allocator, normalized, .untracked, stats);
        }
    }

    overview.changes = try changes.toOwnedSlice();
}

fn appendChange(changes: *std.array_list.Managed(Change), allocator: std.mem.Allocator, path: []const u8, status: ChangeStatus, stats: DiffStats) !void {
    var change = Change{
        .path = try allocator.dupe(u8, path),
        .status = status,
        .additions = stats.additions,
        .deletions = stats.deletions,
        .diff_available = stats.available,
    };
    errdefer change.deinit(allocator);
    try changes.append(change);
}

fn loadIgnoreRules(allocator: std.mem.Allocator, workspace_root: []const u8, max_bytes: usize) !IgnoreRules {
    const ignore_path = try std.fs.path.join(allocator, &.{ workspace_root, ".gitignore" });
    defer allocator.free(ignore_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, ignore_path, allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{ .allocator = allocator },
        else => return err,
    };
    defer allocator.free(bytes);

    var patterns = std.array_list.Managed(IgnorePattern).init(allocator);
    errdefer {
        for (patterns.items) |*pattern| pattern.deinit(allocator);
        patterns.deinit();
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '!') continue;

        var anchored = false;
        if (line[0] == '/') {
            anchored = true;
            line = std.mem.trim(u8, line[1..], "/\\");
        }

        var directory_only = false;
        while (line.len > 0 and (line[line.len - 1] == '/' or line[line.len - 1] == '\\')) {
            directory_only = true;
            line = line[0 .. line.len - 1];
        }
        if (line.len == 0) continue;

        try patterns.append(.{
            .text = try duplicateWithSlashes(allocator, line),
            .directory_only = directory_only,
            .anchored = anchored,
        });
    }

    return .{
        .allocator = allocator,
        .patterns = try patterns.toOwnedSlice(),
    };
}

fn readHead(allocator: std.mem.Allocator, overview: *Overview, git_dir: []const u8) !void {
    const head_path = try std.fs.path.join(allocator, &.{ git_dir, "HEAD" });
    defer allocator.free(head_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, head_path, allocator, .limited(16 * 1024)) catch return;
    defer allocator.free(bytes);
    const head = std.mem.trim(u8, bytes, " \t\r\n");
    if (startsWith(head, "ref:")) {
        const ref_name = std.mem.trim(u8, head["ref:".len..], " \t\r\n");
        if (startsWith(ref_name, "refs/heads/")) {
            overview.branch = try allocator.dupe(u8, ref_name["refs/heads/".len..]);
        } else {
            overview.branch = try allocator.dupe(u8, ref_name);
        }

        const ref_path = try std.fs.path.join(allocator, &.{ git_dir, ref_name });
        defer allocator.free(ref_path);
        if (std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, ref_path, allocator, .limited(256))) |commit_bytes| {
            defer allocator.free(commit_bytes);
            const commit = std.mem.trim(u8, commit_bytes, " \t\r\n");
            if (commit.len > 0) overview.commit = try allocator.dupe(u8, commit[0..@min(commit.len, 40)]);
        } else |_| {
            if (try lookupPackedRef(allocator, git_dir, ref_name)) |commit| {
                overview.commit = commit;
            }
        }
        return;
    }

    if (head.len > 0) {
        overview.commit = try allocator.dupe(u8, head[0..@min(head.len, 40)]);
    }
}

fn lookupPackedRef(allocator: std.mem.Allocator, git_dir: []const u8, ref_name: []const u8) !?[]u8 {
    const packed_path = try std.fs.path.join(allocator, &.{ git_dir, "packed-refs" });
    defer allocator.free(packed_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, packed_path, allocator, .limited(1024 * 1024)) catch return null;
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const commit = parts.next() orelse continue;
        const name = parts.next() orelse continue;
        if (std.mem.eql(u8, name, ref_name)) {
            return try allocator.dupe(u8, commit[0..@min(commit.len, 40)]);
        }
    }
    return null;
}

fn readRemotes(allocator: std.mem.Allocator, git_dir: []const u8) ![]Remote {
    const config_path = try std.fs.path.join(allocator, &.{ git_dir, "config" });
    defer allocator.free(config_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, config_path, allocator, .limited(1024 * 1024)) catch return &.{};
    defer allocator.free(bytes);

    var remotes = std.array_list.Managed(Remote).init(allocator);
    errdefer {
        for (remotes.items) |*remote| remote.deinit(allocator);
        remotes.deinit();
    }

    var current_remote: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            current_remote = parseRemoteSection(line);
            continue;
        }
        const remote_name = current_remote orelse continue;
        const url = assignmentValue(line, "url") orelse continue;
        var remote = Remote{
            .name = try allocator.dupe(u8, remote_name),
            .url = try allocator.dupe(u8, url),
            .github = try parseGitHubRemote(allocator, url),
        };
        errdefer remote.deinit(allocator);
        try remotes.append(remote);
    }

    return try remotes.toOwnedSlice();
}

fn parseRemoteSection(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "[remote")) return null;
    const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const tail = line[first_quote + 1 ..];
    const end_quote = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
    return tail[0..end_quote];
}

fn parseGitHubRemote(allocator: std.mem.Allocator, url: []const u8) !?GitHubRemote {
    const marker = "github.com";
    const at = std.mem.indexOf(u8, url, marker) orelse return null;
    var rest = url[at + marker.len ..];
    if (rest.len > 0 and (rest[0] == ':' or rest[0] == '/')) rest = rest[1..];
    if (startsWith(rest, "git/")) rest = rest["git/".len..];

    const owner_end = std.mem.indexOfAny(u8, rest, "/:") orelse return null;
    const owner = rest[0..owner_end];
    rest = rest[owner_end + 1 ..];
    const repo_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var repo = rest[0..repo_end];
    if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - ".git".len];
    if (owner.len == 0 or repo.len == 0) return null;

    const owner_copy = try allocator.dupe(u8, owner);
    errdefer allocator.free(owner_copy);
    const repo_copy = try allocator.dupe(u8, repo);
    errdefer allocator.free(repo_copy);
    const web = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}", .{ owner, repo });
    errdefer allocator.free(web);
    const actions = try std.fmt.allocPrint(allocator, "{s}/actions", .{web});
    errdefer allocator.free(actions);
    return .{
        .owner = owner_copy,
        .repo = repo_copy,
        .web_url = web,
        .actions_url = actions,
    };
}

fn readIndex(allocator: std.mem.Allocator, git_dir: []const u8, max_bytes: usize) !Index {
    const index_path = try std.fs.path.join(allocator, &.{ git_dir, "index" });
    defer allocator.free(index_path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, index_path, allocator, .limited(max_bytes));
    defer allocator.free(bytes);
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "DIRC")) return error.InvalidGitIndex;

    const version = readU32(bytes[4..8]);
    if (version != 2 and version != 3) return error.UnsupportedGitIndexVersion;

    const count = readU32(bytes[8..12]);
    var entries = std.array_list.Managed(IndexEntry).init(allocator);
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    var offset: usize = 12;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        if (offset + 62 > bytes.len) return error.InvalidGitIndex;
        const entry_start = offset;
        var object_id: [20]u8 = undefined;
        @memcpy(object_id[0..], bytes[offset + 40 .. offset + 60]);
        const flags = readU16(bytes[offset + 60 .. offset + 62]);
        offset += 62;
        if (version == 3 and (flags & 0x4000) != 0) {
            if (offset + 2 > bytes.len) return error.InvalidGitIndex;
            offset += 2;
        }

        const path_len_hint = flags & 0x0fff;
        const path_start = offset;
        var path_end = path_start;
        if (path_len_hint == 0x0fff) {
            while (path_end < bytes.len and bytes[path_end] != 0) : (path_end += 1) {}
        } else {
            path_end = path_start + path_len_hint;
            if (path_end > bytes.len) return error.InvalidGitIndex;
        }
        if (path_end >= bytes.len) return error.InvalidGitIndex;

        try entries.append(.{
            .path = try allocator.dupe(u8, bytes[path_start..path_end]),
            .object_id = object_id,
        });

        const unpadded = (path_end + 1) - entry_start;
        offset = entry_start + align8(unpadded);
    }

    return .{
        .allocator = allocator,
        .version = version,
        .entries = try entries.toOwnedSlice(),
    };
}

fn resolveGitDir(allocator: std.mem.Allocator, workspace_root: []const u8) !?[]u8 {
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
            const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, dot_git, allocator, .limited(16 * 1024));
            defer allocator.free(bytes);
            const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
            if (!startsWithIgnoreCase(trimmed, "gitdir:")) {
                allocator.free(dot_git);
                return null;
            }
            const value = std.mem.trim(u8, trimmed["gitdir:".len..], " \t\r\n");
            const resolved = if (std.fs.path.isAbsolute(value))
                try std.fs.path.resolve(allocator, &.{value})
            else
                try std.fs.path.resolve(allocator, &.{ workspace_root, value });
            allocator.free(dot_git);
            return resolved;
        },
        else => {
            allocator.free(dot_git);
            return null;
        },
    }
}

fn collectGitHubWorkflowFiles(allocator: std.mem.Allocator, workspace: *const workspace_mod.Workspace) ![][]u8 {
    var paths = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }

    for (workspace.entries.items) |entry| {
        if (entry.kind != .file) continue;
        const path = entry.path;
        if (!startsWithNormalized(path, ".github/workflows/")) continue;
        if (std.mem.endsWith(u8, path, ".yml") or std.mem.endsWith(u8, path, ".yaml")) {
            try paths.append(try duplicateWithSlashes(allocator, path));
        }
    }
    return try paths.toOwnedSlice();
}

fn startsWithNormalized(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    for (prefix, 0..) |byte, index| {
        const left = path[index];
        if ((left == '/' or left == '\\') and byte == '/') continue;
        if (std.ascii.toLower(left) != std.ascii.toLower(byte)) return false;
    }
    return true;
}

fn ignorePatternMatches(pattern: IgnorePattern, path: []const u8) bool {
    if (pattern.text.len == 0) return false;
    if (pattern.anchored or containsSlash(pattern.text)) {
        if (pattern.directory_only) {
            return pathMatchesDirectoryPrefix(path, pattern.text);
        }
        return wildcardMatch(pattern.text, path);
    }

    var start: usize = 0;
    while (start <= path.len) {
        var end = start;
        while (end < path.len and path[end] != '/' and path[end] != '\\') : (end += 1) {}
        const segment = path[start..end];
        if (wildcardMatch(pattern.text, segment)) return true;
        if (pattern.directory_only and pathMatchesDirectoryPrefix(path[start..], pattern.text)) return true;
        if (end == path.len) break;
        start = end + 1;
    }
    return false;
}

fn pathMatchesDirectoryPrefix(path: []const u8, directory: []const u8) bool {
    if (path.len < directory.len) return false;
    if (!wildcardMatch(directory, path[0..directory.len])) return false;
    if (path.len == directory.len) return true;
    return path[directory.len] == '/' or path[directory.len] == '\\';
}

fn containsSlash(bytes: []const u8) bool {
    return std.mem.indexOfAny(u8, bytes, "/\\") != null;
}

fn wildcardMatch(pattern: []const u8, value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        return std.mem.eql(u8, pattern, value);
    }

    var p: usize = 0;
    var v: usize = 0;
    var star: ?usize = null;
    var match_after_star: usize = 0;
    while (v < value.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            match_after_star = v;
        } else if (p < pattern.len and pattern[p] == value[v]) {
            p += 1;
            v += 1;
        } else if (star) |star_index| {
            p = star_index + 1;
            match_after_star += 1;
            v = match_after_star;
        } else {
            return false;
        }
    }

    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}

fn addedFileStats(allocator: std.mem.Allocator, workspace_root: []const u8, path: []const u8, max_bytes: usize) !DiffStats {
    const absolute = try std.fs.path.join(allocator, &.{ workspace_root, path });
    defer allocator.free(absolute);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, absolute, allocator, .limited(max_bytes));
    defer allocator.free(bytes);
    return addedStats(bytes);
}

fn readLooseBlob(allocator: std.mem.Allocator, git_dir: []const u8, object_id: [20]u8, max_body_bytes: usize) !LooseBlob {
    var hex: [40]u8 = undefined;
    hexObjectId(&hex, object_id);

    const object_path = try std.fs.path.join(allocator, &.{ git_dir, "objects", hex[0..2], hex[2..40] });
    defer allocator.free(object_path);

    const compressed = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, object_path, allocator, .limited(max_body_bytes + 1024));
    defer allocator.free(compressed);

    var reader: std.Io.Reader = .fixed(compressed);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var decompress: flate.Decompress = .init(&reader, .zlib, &.{});
    _ = try decompress.reader.streamRemaining(&output.writer);
    const decompressed = try output.toOwnedSlice();
    errdefer allocator.free(decompressed);

    const nul = std.mem.indexOfScalar(u8, decompressed, 0) orelse return error.InvalidGitObject;
    const header = decompressed[0..nul];
    if (!startsWith(header, "blob ")) return error.UnsupportedGitObject;
    const body = decompressed[nul + 1 ..];
    if (body.len > max_body_bytes) return error.FileTooBig;

    return .{
        .allocation = decompressed,
        .body = body,
    };
}

fn changedStats(old: []const u8, new: []const u8) DiffStats {
    if (std.mem.eql(u8, old, new)) return .{ .available = true };

    var prefix: usize = 0;
    const min_len = @min(old.len, new.len);
    while (prefix < min_len and old[prefix] == new[prefix]) : (prefix += 1) {}
    while (prefix > 0 and old[prefix - 1] != '\n') : (prefix -= 1) {}

    var old_end = old.len;
    var new_end = new.len;
    while (old_end > prefix and new_end > prefix and old[old_end - 1] == new[new_end - 1]) {
        old_end -= 1;
        new_end -= 1;
    }
    while (old_end < old.len and old_end > prefix and old[old_end - 1] != '\n') : (old_end += 1) {}
    while (new_end < new.len and new_end > prefix and new[new_end - 1] != '\n') : (new_end += 1) {}

    return .{
        .additions = countLines(new[prefix..new_end]),
        .deletions = countLines(old[prefix..old_end]),
        .available = true,
    };
}

fn addedStats(bytes: []const u8) DiffStats {
    return .{ .additions = countLines(bytes), .available = true };
}

fn removedStats(bytes: []const u8) DiffStats {
    return .{ .deletions = countLines(bytes), .available = true };
}

fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    if (bytes[bytes.len - 1] != '\n') count += 1;
    return count;
}

fn gitBlobSha1(bytes: []const u8) [20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "blob {d}\x00", .{bytes.len}) catch unreachable;
    hasher.update(header);
    hasher.update(bytes);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn hexObjectId(out: *[40]u8, object_id: [20]u8) void {
    const digits = "0123456789abcdef";
    for (object_id, 0..) |byte, index| {
        out[index * 2] = digits[byte >> 4];
        out[index * 2 + 1] = digits[byte & 0x0f];
    }
}

fn isTracked(entries: []const IndexEntry, path: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

fn duplicateWithSlashes(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const copy = try allocator.dupe(u8, path);
    for (copy) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return copy;
}

fn assignmentValue(line: []const u8, key: []const u8) ?[]const u8 {
    const equals = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..equals], " \t");
    if (!std.ascii.eqlIgnoreCase(left, key)) return null;
    return std.mem.trim(u8, line[equals + 1 ..], " \t");
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.mem.eql(u8, haystack[0..prefix.len], prefix);
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn align8(value: usize) usize {
    return (value + 7) & ~@as(usize, 7);
}

fn readU16(bytes: []const u8) u16 {
    std.debug.assert(bytes.len >= 2);
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn readU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= 4);
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

test "parse github remote urls" {
    var remote = (try parseGitHubRemote(std.testing.allocator, "git@github.com:owner/repo.git")) orelse return error.ExpectedRemote;
    defer remote.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("owner", remote.owner);
    try std.testing.expectEqualStrings("repo", remote.repo);
    try std.testing.expectEqualStrings("https://github.com/owner/repo", remote.web_url);
    try std.testing.expectEqualStrings("https://github.com/owner/repo/actions", remote.actions_url);
}

test "git blob sha1 matches known empty blob id" {
    const digest = gitBlobSha1("");
    const expected = [_]u8{ 0xe6, 0x9d, 0xe2, 0x9b, 0xb2, 0xd1, 0xd6, 0x43, 0x4b, 0x8b, 0x29, 0xae, 0x77, 0x5a, 0xd8, 0xc2, 0xe4, 0x8c, 0x53, 0x91 };
    try std.testing.expectEqualSlices(u8, expected[0..], digest[0..]);
}

test "line diff stats report changed middle" {
    const stats = changedStats(
        "one\ntwo\nthree\n",
        "one\nTWO\nthree\n",
    );
    try std.testing.expect(stats.available);
    try std.testing.expectEqual(@as(usize, 1), stats.additions);
    try std.testing.expectEqual(@as(usize, 1), stats.deletions);
}

test "added and removed stats count logical lines" {
    try std.testing.expectEqual(@as(usize, 2), addedStats("a\nb").additions);
    try std.testing.expectEqual(@as(usize, 1), addedStats("a\n").additions);
    try std.testing.expectEqual(@as(usize, 0), removedStats("").deletions);
}

test "ignore patterns match directories and wildcards" {
    const dir_pattern = IgnorePattern{ .text = "zig-out", .directory_only = true };
    try std.testing.expect(ignorePatternMatches(dir_pattern, "zig-out/bin/zide.exe"));
    try std.testing.expect(ignorePatternMatches(dir_pattern, "nested/zig-out/file"));

    const exe_pattern = IgnorePattern{ .text = "*.exe" };
    try std.testing.expect(ignorePatternMatches(exe_pattern, "zide.exe"));
    try std.testing.expect(ignorePatternMatches(exe_pattern, "bin/zide.exe"));
    try std.testing.expect(!ignorePatternMatches(exe_pattern, "src/main.zig"));
}
