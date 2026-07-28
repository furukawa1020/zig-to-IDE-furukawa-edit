const std = @import("std");
const workspace_mod = @import("../workspace/workspace.zig");
const source_control = @import("source_control.zig");
const flate = std.compress.flate;

pub const ChangeStatus = enum {
    added,
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

pub const DiffPreviewOptions = struct {
    max_index_bytes: usize = 16 * 1024 * 1024,
    max_file_bytes: usize = 8 * 1024 * 1024,
    max_lines: usize = 160,
};

pub const Overview = struct {
    allocator: std.mem.Allocator,
    present: bool = false,
    git_dir: ?[]u8 = null,
    branch: ?[]u8 = null,
    commit: ?[]u8 = null,
    remotes: []Remote = &.{},
    changes: []Change = &.{},
    staged_changes: []Change = &.{},
    workflow_paths: [][]u8 = &.{},
    index_version: ?u32 = null,
    index_entries: usize = 0,
    clean_tracked: usize = 0,
    workflow_files: usize = 0,
    ignored_untracked: usize = 0,
    change_limit_hit: bool = false,
    unsupported_index: bool = false,
    staged_scan_available: bool = false,

    pub fn deinit(self: *Overview) void {
        if (self.git_dir) |value| self.allocator.free(value);
        if (self.branch) |value| self.allocator.free(value);
        if (self.commit) |value| self.allocator.free(value);
        for (self.remotes) |*remote| remote.deinit(self.allocator);
        if (self.remotes.len > 0) self.allocator.free(self.remotes);
        for (self.changes) |*change| change.deinit(self.allocator);
        if (self.changes.len > 0) self.allocator.free(self.changes);
        for (self.staged_changes) |*change| change.deinit(self.allocator);
        if (self.staged_changes.len > 0) self.allocator.free(self.staged_changes);
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

const ObjectKind = enum {
    blob,
    tree,
    commit,
};

const LooseObject = struct {
    allocation: []u8,
    body: []const u8,
    kind: ObjectKind,

    fn deinit(self: *LooseObject, allocator: std.mem.Allocator) void {
        allocator.free(self.allocation);
        self.* = undefined;
    }
};

const HeadEntry = struct {
    path: []u8,
    object_id: [20]u8,

    fn deinit(self: *HeadEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

const HeadTree = struct {
    allocator: std.mem.Allocator,
    entries: []HeadEntry = &.{},

    fn deinit(self: *HeadTree) void {
        for (self.entries) |*entry| entry.deinit(self.allocator);
        if (self.entries.len > 0) self.allocator.free(self.entries);
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

const TextMode = enum {
    auto,
    text,
    binary,
    unspecified,
};

const TextAttributeRule = struct {
    pattern: []u8,
    mode: TextMode,

    fn deinit(self: *TextAttributeRule, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        self.* = undefined;
    }
};

const TextAttributes = struct {
    allocator: std.mem.Allocator,
    rules: []TextAttributeRule = &.{},

    fn deinit(self: *TextAttributes) void {
        for (self.rules) |*rule| rule.deinit(self.allocator);
        if (self.rules.len > 0) self.allocator.free(self.rules);
        self.* = undefined;
    }

    fn modeForPath(self: *const TextAttributes, path: []const u8) TextMode {
        var mode: TextMode = .unspecified;
        for (self.rules) |rule| {
            if (attributePatternMatches(rule.pattern, path)) mode = rule.mode;
        }
        return mode;
    }

    fn canonicalize(
        self: *const TextAttributes,
        allocator: std.mem.Allocator,
        path: []const u8,
        bytes: []const u8,
    ) !CanonicalBytes {
        const mode = self.modeForPath(path);
        const normalize = switch (mode) {
            .text => true,
            .auto => !hasNul(bytes),
            .binary, .unspecified => false,
        };
        if (!normalize or std.mem.indexOf(u8, bytes, "\r\n") == null) {
            return .{ .bytes = bytes };
        }

        const normalized = try allocator.alloc(u8, bytes.len - countCrLf(bytes));
        var source: usize = 0;
        var destination: usize = 0;
        while (source < bytes.len) : (source += 1) {
            if (bytes[source] == '\r' and source + 1 < bytes.len and bytes[source + 1] == '\n') continue;
            normalized[destination] = bytes[source];
            destination += 1;
        }
        std.debug.assert(destination == normalized.len);
        return .{ .bytes = normalized, .owned = normalized };
    }
};

const CanonicalBytes = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: *CanonicalBytes, allocator: std.mem.Allocator) void {
        if (self.owned) |bytes| allocator.free(bytes);
        self.* = undefined;
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
    overview.staged_changes = collectStagedChanges(
        allocator,
        overview.git_dir.?,
        overview.commit,
        index.entries,
        options.max_file_bytes,
        options.max_changes,
    ) catch &.{};
    overview.staged_scan_available = overview.commit == null or overview.staged_changes.len > 0 or
        headTreeReadable(allocator, overview.git_dir.?, overview.commit, options.max_file_bytes);
    var ignore_rules = try loadIgnoreRules(allocator, workspace.root_path, options.max_file_bytes);
    defer ignore_rules.deinit();
    var text_attributes = try loadTextAttributes(allocator, workspace.root_path, overview.git_dir.?, options.max_file_bytes);
    defer text_attributes.deinit();
    try collectChanges(allocator, workspace, &index, &ignore_rules, &text_attributes, options, &overview);

    return overview;
}

pub fn applySourceControlSnapshot(
    overview: *Overview,
    snapshot: *const source_control.Snapshot,
    max_changes: usize,
) !void {
    var staged = std.array_list.Managed(Change).init(overview.allocator);
    errdefer {
        for (staged.items) |*change| change.deinit(overview.allocator);
        staged.deinit();
    }
    var unstaged = std.array_list.Managed(Change).init(overview.allocator);
    errdefer {
        for (unstaged.items) |*change| change.deinit(overview.allocator);
        unstaged.deinit();
    }

    for (snapshot.entries) |entry| {
        if (entry.isStaged() and staged.items.len < max_changes) {
            try appendChange(
                &staged,
                overview.allocator,
                entry.path,
                sourceControlStatus(entry.index_status),
                .{},
            );
        }
        if (entry.isUnstaged() and unstaged.items.len < max_changes) {
            const status = if (entry.index_status == .untracked)
                ChangeStatus.untracked
            else
                sourceControlStatus(entry.worktree_status);
            try appendChange(&unstaged, overview.allocator, entry.path, status, .{});
        }
    }

    const staged_owned = try staged.toOwnedSlice();
    errdefer {
        for (staged_owned) |*change| change.deinit(overview.allocator);
        if (staged_owned.len > 0) overview.allocator.free(staged_owned);
    }
    const unstaged_owned = try unstaged.toOwnedSlice();

    for (overview.staged_changes) |*change| change.deinit(overview.allocator);
    if (overview.staged_changes.len > 0) overview.allocator.free(overview.staged_changes);
    for (overview.changes) |*change| change.deinit(overview.allocator);
    if (overview.changes.len > 0) overview.allocator.free(overview.changes);
    overview.staged_changes = staged_owned;
    overview.changes = unstaged_owned;
    overview.staged_scan_available = true;
    overview.change_limit_hit = snapshot.entries.len > max_changes;
}

fn sourceControlStatus(status: source_control.FileStatus) ChangeStatus {
    return switch (status) {
        .added => .added,
        .deleted => .deleted,
        .untracked => .untracked,
        .clean, .modified, .type_changed, .renamed, .copied, .unmerged, .ignored, .unknown => .modified,
    };
}

pub fn previewStagedFileDiff(allocator: std.mem.Allocator, workspace: *const workspace_mod.Workspace, path: []const u8, options: DiffPreviewOptions) ![]u8 {
    const relative = try normalizeWorkspacePath(allocator, workspace.root_path, path);
    defer allocator.free(relative);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("git staged diff preview (pure Zig, no git executable)\n");
    try writer.print("path: {s}\n", .{relative});

    const git_dir = try resolveGitDir(allocator, workspace.root_path);
    defer if (git_dir) |value| allocator.free(value);
    if (git_dir == null) {
        try writer.writeAll("status: no .git metadata found\n");
        return try out.toOwnedSlice();
    }

    var index = readIndex(allocator, git_dir.?, options.max_index_bytes) catch |err| switch (err) {
        error.UnsupportedGitIndexVersion => {
            try writer.writeAll("status: unsupported Git index version\n");
            return try out.toOwnedSlice();
        },
        error.FileNotFound => {
            try writer.writeAll("status: Git index not found\n");
            return try out.toOwnedSlice();
        },
        else => return err,
    };
    defer index.deinit();

    var head_commit: ?[]u8 = null;
    defer if (head_commit) |value| allocator.free(value);
    var head_overview = Overview{ .allocator = allocator };
    defer head_overview.deinit();
    try readHead(allocator, &head_overview, git_dir.?);
    if (head_overview.commit) |commit| {
        head_commit = try allocator.dupe(u8, commit);
    }

    var head_tree = loadHeadTree(allocator, git_dir.?, head_commit, options.max_file_bytes, 65_536) catch {
        try writer.writeAll("status: staged preview unavailable because HEAD objects are packed or unreadable\n");
        return try out.toOwnedSlice();
    };
    defer head_tree.deinit();

    const old_entry = findHeadEntry(head_tree.entries, relative);
    const new_entry = findTrackedEntry(index.entries, relative);
    if (old_entry == null and new_entry == null) {
        try writer.writeAll("status: file not found in HEAD or Git index\n");
        return try out.toOwnedSlice();
    }
    if (old_entry != null and new_entry != null and std.mem.eql(u8, old_entry.?.object_id[0..], new_entry.?.object_id[0..])) {
        try writer.writeAll("status: no staged change\n");
        return try out.toOwnedSlice();
    }

    var old_blob = if (old_entry) |entry| readLooseBlob(allocator, git_dir.?, entry.object_id, options.max_file_bytes) catch null else null;
    defer if (old_blob) |*blob| blob.deinit(allocator);
    var new_blob = if (new_entry) |entry| readLooseBlob(allocator, git_dir.?, entry.object_id, options.max_file_bytes) catch null else null;
    defer if (new_blob) |*blob| blob.deinit(allocator);

    if (old_entry == null) {
        try writer.writeAll("status: staged added\n");
        if (new_blob) |blob| try writePrefixedLines(writer, '+', blob.body, options.max_lines) else try writer.writeAll("diff body unavailable: indexed blob is packed or too large\n");
    } else if (new_entry == null) {
        try writer.writeAll("status: staged deleted\n");
        if (old_blob) |blob| try writePrefixedLines(writer, '-', blob.body, options.max_lines) else try writer.writeAll("diff body unavailable: HEAD blob is packed or too large\n");
    } else {
        try writer.writeAll("status: staged modified\n");
        if (old_blob != null and new_blob != null) {
            try writeChangedPreview(writer, old_blob.?.body, new_blob.?.body, options.max_lines);
        } else {
            try writer.writeAll("diff body unavailable: HEAD or indexed blob is packed or too large\n");
        }
    }

    return try out.toOwnedSlice();
}

pub fn previewFileDiff(allocator: std.mem.Allocator, workspace: *const workspace_mod.Workspace, path: []const u8, options: DiffPreviewOptions) ![]u8 {
    const relative = try normalizeWorkspacePath(allocator, workspace.root_path, path);
    defer allocator.free(relative);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("git diff preview (pure Zig, no git executable)\n");
    try writer.print("path: {s}\n", .{relative});

    const git_dir = try resolveGitDir(allocator, workspace.root_path);
    defer if (git_dir) |value| allocator.free(value);
    if (git_dir == null) {
        try writer.writeAll("status: no .git metadata found\n");
        return try out.toOwnedSlice();
    }

    var index = readIndex(allocator, git_dir.?, options.max_index_bytes) catch |err| switch (err) {
        error.UnsupportedGitIndexVersion => {
            try writer.writeAll("status: unsupported Git index version\n");
            return try out.toOwnedSlice();
        },
        error.FileNotFound => {
            try writer.writeAll("status: Git index not found\n");
            return try out.toOwnedSlice();
        },
        else => return err,
    };
    defer index.deinit();

    const entry = findTrackedEntry(index.entries, relative);
    const absolute = try std.fs.path.join(allocator, &.{ workspace.root_path, relative });
    defer allocator.free(absolute);

    const new_bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, absolute, allocator, .limited(options.max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (new_bytes) |bytes| allocator.free(bytes);
    var text_attributes = try loadTextAttributes(allocator, workspace.root_path, git_dir.?, options.max_file_bytes);
    defer text_attributes.deinit();

    if (entry) |tracked| {
        var old_blob = readLooseBlob(allocator, git_dir.?, tracked.object_id, options.max_file_bytes) catch null;
        defer if (old_blob) |*blob| blob.deinit(allocator);

        if (new_bytes) |new_body| {
            var canonical = try text_attributes.canonicalize(allocator, relative, new_body);
            defer canonical.deinit(allocator);
            const object_id = gitBlobSha1(canonical.bytes);
            if (std.mem.eql(u8, object_id[0..], tracked.object_id[0..])) {
                try writer.writeAll("status: clean against index\n");
                return try out.toOwnedSlice();
            }
            try writer.writeAll("status: modified\n");
            if (old_blob) |blob| {
                try writeChangedPreview(writer, blob.body, canonical.bytes, options.max_lines);
            } else {
                try writer.writeAll("diff body unavailable: indexed blob is packed or too large\n");
            }
            return try out.toOwnedSlice();
        }

        try writer.writeAll("status: deleted\n");
        if (old_blob) |blob| {
            try writePrefixedLines(writer, '-', blob.body, options.max_lines);
        } else {
            try writer.writeAll("diff body unavailable: indexed blob is packed or too large\n");
        }
        return try out.toOwnedSlice();
    }

    if (new_bytes) |body| {
        try writer.writeAll("status: untracked\n");
        try writePrefixedLines(writer, '+', body, options.max_lines);
        return try out.toOwnedSlice();
    }

    try writer.writeAll("status: file not found in workspace or index\n");
    return try out.toOwnedSlice();
}

fn collectChanges(
    allocator: std.mem.Allocator,
    workspace: *const workspace_mod.Workspace,
    index: *const Index,
    ignore_rules: *const IgnoreRules,
    text_attributes: *const TextAttributes,
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

        var canonical = try text_attributes.canonicalize(allocator, entry.path, bytes);
        defer canonical.deinit(allocator);
        const object_id = gitBlobSha1(canonical.bytes);
        if (std.mem.eql(u8, object_id[0..], entry.object_id[0..])) {
            overview.clean_tracked += 1;
        } else {
            var old_blob = readLooseBlob(allocator, overview.git_dir.?, entry.object_id, options.max_file_bytes) catch null;
            defer if (old_blob) |*blob| blob.deinit(allocator);
            const stats = if (old_blob) |blob| changedStats(blob.body, canonical.bytes) else DiffStats{};
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

fn collectStagedChanges(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    head_commit: ?[]const u8,
    index_entries: []const IndexEntry,
    max_blob_bytes: usize,
    max_changes: usize,
) ![]Change {
    var head_tree = try loadHeadTree(allocator, git_dir, head_commit, max_blob_bytes, 65_536);
    defer head_tree.deinit();

    var changes = std.array_list.Managed(Change).init(allocator);
    errdefer {
        for (changes.items) |*change| change.deinit(allocator);
        changes.deinit();
    }

    for (index_entries) |entry| {
        if (changes.items.len >= max_changes) break;
        const head_entry = findHeadEntry(head_tree.entries, entry.path);
        if (head_entry) |previous| {
            if (std.mem.eql(u8, previous.object_id[0..], entry.object_id[0..])) continue;
            const stats = stagedDiffStats(allocator, git_dir, previous.object_id, entry.object_id, max_blob_bytes);
            try appendChange(&changes, allocator, entry.path, .modified, stats);
        } else {
            const stats = stagedAddedStats(allocator, git_dir, entry.object_id, max_blob_bytes);
            try appendChange(&changes, allocator, entry.path, .added, stats);
        }
    }

    for (head_tree.entries) |entry| {
        if (changes.items.len >= max_changes) break;
        if (findTrackedEntry(index_entries, entry.path) != null) continue;
        const stats = stagedRemovedStats(allocator, git_dir, entry.object_id, max_blob_bytes);
        try appendChange(&changes, allocator, entry.path, .deleted, stats);
    }

    return try changes.toOwnedSlice();
}

fn stagedDiffStats(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    old_id: [20]u8,
    new_id: [20]u8,
    max_blob_bytes: usize,
) DiffStats {
    var old_blob = readLooseBlob(allocator, git_dir, old_id, max_blob_bytes) catch return .{};
    defer old_blob.deinit(allocator);
    var new_blob = readLooseBlob(allocator, git_dir, new_id, max_blob_bytes) catch return .{};
    defer new_blob.deinit(allocator);
    return changedStats(old_blob.body, new_blob.body);
}

fn stagedAddedStats(allocator: std.mem.Allocator, git_dir: []const u8, object_id: [20]u8, max_blob_bytes: usize) DiffStats {
    var blob = readLooseBlob(allocator, git_dir, object_id, max_blob_bytes) catch return .{};
    defer blob.deinit(allocator);
    return addedStats(blob.body);
}

fn stagedRemovedStats(allocator: std.mem.Allocator, git_dir: []const u8, object_id: [20]u8, max_blob_bytes: usize) DiffStats {
    var blob = readLooseBlob(allocator, git_dir, object_id, max_blob_bytes) catch return .{};
    defer blob.deinit(allocator);
    return removedStats(blob.body);
}

fn headTreeReadable(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    head_commit: ?[]const u8,
    max_object_bytes: usize,
) bool {
    var tree = loadHeadTree(allocator, git_dir, head_commit, max_object_bytes, 65_536) catch return false;
    tree.deinit();
    return true;
}

fn loadHeadTree(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    head_commit: ?[]const u8,
    max_object_bytes: usize,
    max_entries: usize,
) !HeadTree {
    const commit_hex = head_commit orelse return .{ .allocator = allocator };
    const commit_id = parseHexObjectId(commit_hex) orelse return error.InvalidGitObject;
    var commit = try readLooseObject(allocator, git_dir, commit_id, max_object_bytes);
    defer commit.deinit(allocator);
    if (commit.kind != .commit) return error.UnsupportedGitObject;

    const tree_id = commitTreeId(commit.body) orelse return error.InvalidGitObject;
    var entries = std.array_list.Managed(HeadEntry).init(allocator);
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }
    try appendHeadTreeEntries(allocator, git_dir, tree_id, "", max_object_bytes, max_entries, 0, &entries);
    return .{
        .allocator = allocator,
        .entries = try entries.toOwnedSlice(),
    };
}

fn appendHeadTreeEntries(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    tree_id: [20]u8,
    prefix: []const u8,
    max_object_bytes: usize,
    max_entries: usize,
    depth: usize,
    entries: *std.array_list.Managed(HeadEntry),
) !void {
    if (depth > 128) return error.GitTreeTooDeep;
    var tree = try readLooseObject(allocator, git_dir, tree_id, max_object_bytes);
    defer tree.deinit(allocator);
    if (tree.kind != .tree) return error.UnsupportedGitObject;

    var offset: usize = 0;
    while (offset < tree.body.len) {
        const mode_end_relative = std.mem.indexOfScalar(u8, tree.body[offset..], ' ') orelse return error.InvalidGitObject;
        const mode_end = offset + mode_end_relative;
        const mode = tree.body[offset..mode_end];
        const name_start = mode_end + 1;
        const name_end_relative = std.mem.indexOfScalar(u8, tree.body[name_start..], 0) orelse return error.InvalidGitObject;
        const name_end = name_start + name_end_relative;
        const name = tree.body[name_start..name_end];
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.indexOfScalar(u8, name, '/') != null) {
            return error.InvalidGitObject;
        }
        const object_start = name_end + 1;
        if (object_start + 20 > tree.body.len) return error.InvalidGitObject;
        var object_id: [20]u8 = undefined;
        @memcpy(object_id[0..], tree.body[object_start .. object_start + 20]);
        offset = object_start + 20;

        const path = if (prefix.len == 0)
            try allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
        if (isTreeMode(mode)) {
            defer allocator.free(path);
            try appendHeadTreeEntries(allocator, git_dir, object_id, path, max_object_bytes, max_entries, depth + 1, entries);
            continue;
        }

        if (entries.items.len >= max_entries) {
            allocator.free(path);
            return error.GitTreeEntryLimitExceeded;
        }
        try entries.append(.{ .path = path, .object_id = object_id });
    }
}

fn isTreeMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "40000") or std.mem.eql(u8, mode, "040000");
}

fn commitTreeId(body: []const u8) ?[20]u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "tree ")) continue;
        return parseHexObjectId(std.mem.trim(u8, line["tree ".len..], " \t\r"));
    }
    return null;
}

fn findHeadEntry(entries: []const HeadEntry, path: []const u8) ?*const HeadEntry {
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
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

fn loadTextAttributes(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    git_dir: []const u8,
    max_bytes: usize,
) !TextAttributes {
    var rules = std.array_list.Managed(TextAttributeRule).init(allocator);
    errdefer {
        for (rules.items) |*rule| rule.deinit(allocator);
        rules.deinit();
    }

    const workspace_attributes = try std.fs.path.join(allocator, &.{ workspace_root, ".gitattributes" });
    defer allocator.free(workspace_attributes);
    try appendTextAttributeFile(allocator, &rules, workspace_attributes, max_bytes);

    // Repository-local info attributes have higher precedence than tracked attributes.
    const info_attributes = try std.fs.path.join(allocator, &.{ git_dir, "info", "attributes" });
    defer allocator.free(info_attributes);
    try appendTextAttributeFile(allocator, &rules, info_attributes, max_bytes);

    return .{
        .allocator = allocator,
        .rules = try rules.toOwnedSlice(),
    };
}

fn appendTextAttributeFile(
    allocator: std.mem.Allocator,
    rules: *std.array_list.Managed(TextAttributeRule),
    path: []const u8,
    max_bytes: usize,
) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        var pattern = tokens.next() orelse continue;
        if (pattern.len == 0 or pattern[0] == '!') continue;
        if (pattern[0] == '/') pattern = pattern[1..];
        if (pattern.len == 0 or pattern[pattern.len - 1] == '/') continue;

        var mode: ?TextMode = null;
        while (tokens.next()) |attribute| {
            if (std.mem.eql(u8, attribute, "text")) {
                mode = .text;
            } else if (std.mem.eql(u8, attribute, "text=auto")) {
                mode = .auto;
            } else if (std.mem.eql(u8, attribute, "-text") or std.mem.eql(u8, attribute, "binary")) {
                mode = .binary;
            } else if (std.mem.eql(u8, attribute, "!text")) {
                mode = .unspecified;
            } else if (std.mem.startsWith(u8, attribute, "eol=")) {
                mode = .text;
            }
        }
        const resolved_mode = mode orelse continue;
        try rules.append(.{
            .pattern = try allocator.dupe(u8, pattern),
            .mode = resolved_mode,
        });
    }
}

fn attributePatternMatches(pattern: []const u8, path: []const u8) bool {
    if (containsSlash(pattern)) return wildcardMatch(pattern, path);
    const basename_start = (std.mem.lastIndexOfAny(u8, path, "/\\") orelse return wildcardMatch(pattern, path)) + 1;
    return wildcardMatch(pattern, path[basename_start..]);
}

fn countCrLf(bytes: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 1) {
        if (bytes[index] == '\r' and bytes[index + 1] == '\n') count += 1;
    }
    return count;
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
    const prefixes = [_][]const u8{
        "https://github.com/",
        "git@github.com:",
        "ssh://git@github.com/",
        "ssh://github.com/",
    };
    var rest: ?[]const u8 = null;
    for (prefixes) |prefix| {
        if (startsWithIgnoreCase(url, prefix)) {
            rest = url[prefix.len..];
            break;
        }
    }
    var path = rest orelse return null;

    const owner_end = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const owner = path[0..owner_end];
    path = path[owner_end + 1 ..];
    const repo_end = std.mem.indexOfAny(u8, path, "/?#") orelse path.len;
    var repo = path[0..repo_end];
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
    var object = try readLooseObject(allocator, git_dir, object_id, max_body_bytes);
    errdefer object.deinit(allocator);
    if (object.kind != .blob) return error.UnsupportedGitObject;
    return .{
        .allocation = object.allocation,
        .body = object.body,
    };
}

fn readLooseObject(allocator: std.mem.Allocator, git_dir: []const u8, object_id: [20]u8, max_body_bytes: usize) !LooseObject {
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
    const separator = std.mem.indexOfScalar(u8, header, ' ') orelse return error.InvalidGitObject;
    const kind = objectKind(header[0..separator]) orelse return error.UnsupportedGitObject;
    const declared_size = std.fmt.parseUnsigned(usize, header[separator + 1 ..], 10) catch return error.InvalidGitObject;
    const body = decompressed[nul + 1 ..];
    if (body.len != declared_size) return error.InvalidGitObject;
    if (body.len > max_body_bytes) return error.FileTooBig;

    return .{
        .allocation = decompressed,
        .body = body,
        .kind = kind,
    };
}

fn objectKind(value: []const u8) ?ObjectKind {
    if (std.mem.eql(u8, value, "blob")) return .blob;
    if (std.mem.eql(u8, value, "tree")) return .tree;
    if (std.mem.eql(u8, value, "commit")) return .commit;
    return null;
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

const ChangeSpan = struct {
    old_start: usize,
    old_end: usize,
    new_start: usize,
    new_end: usize,
};

fn changedSpan(old: []const u8, new: []const u8) ?ChangeSpan {
    if (std.mem.eql(u8, old, new)) return null;

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
    while (new_end < new.len and new_end > prefix and new_end - 1 < new.len and new[new_end - 1] != '\n') : (new_end += 1) {}

    return .{
        .old_start = prefix,
        .old_end = old_end,
        .new_start = prefix,
        .new_end = new_end,
    };
}

fn writeChangedPreview(writer: anytype, old: []const u8, new: []const u8, max_lines: usize) !void {
    if (hasNul(old) or hasNul(new)) {
        try writer.writeAll("diff body unavailable: binary-looking content\n");
        return;
    }

    const span = changedSpan(old, new) orelse {
        try writer.writeAll("no content changes\n");
        return;
    };

    try writer.writeAll("@@ compact changed region @@\n");
    var emitted: usize = 0;
    try writePrefixedLinesCounted(writer, '-', old[span.old_start..span.old_end], max_lines, &emitted);
    try writePrefixedLinesCounted(writer, '+', new[span.new_start..span.new_end], max_lines, &emitted);
    if (emitted >= max_lines) {
        try writer.writeAll("... diff preview truncated\n");
    }
}

fn writePrefixedLines(writer: anytype, prefix: u8, bytes: []const u8, max_lines: usize) !void {
    if (hasNul(bytes)) {
        try writer.writeAll("diff body unavailable: binary-looking content\n");
        return;
    }
    var emitted: usize = 0;
    try writePrefixedLinesCounted(writer, prefix, bytes, max_lines, &emitted);
    if (emitted >= max_lines) {
        try writer.writeAll("... diff preview truncated\n");
    }
}

fn writePrefixedLinesCounted(writer: anytype, prefix: u8, bytes: []const u8, max_lines: usize, emitted: *usize) !void {
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |raw_line| {
        if (emitted.* >= max_lines) return;
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        try writer.print("{c}{s}\n", .{ prefix, line });
        emitted.* += 1;
    }
}

fn hasNul(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) != null;
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

fn parseHexObjectId(value: []const u8) ?[20]u8 {
    if (value.len != 40) return null;
    var object_id: [20]u8 = undefined;
    for (0..20) |index| {
        const high = hexNibble(value[index * 2]) orelse return null;
        const low = hexNibble(value[index * 2 + 1]) orelse return null;
        object_id[index] = (high << 4) | low;
    }
    return object_id;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn isTracked(entries: []const IndexEntry, path: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

fn findTrackedEntry(entries: []const IndexEntry, path: []const u8) ?*const IndexEntry {
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

fn duplicateWithSlashes(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const copy = try allocator.dupe(u8, path);
    for (copy) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return copy;
}

fn normalizeWorkspacePath(allocator: std.mem.Allocator, workspace_root: []const u8, path: []const u8) ![]u8 {
    const relative = if (std.fs.path.isAbsolute(path)) blk: {
        if (!startsWithPath(path, workspace_root)) return error.PathOutsideWorkspace;
        var start = workspace_root.len;
        if (start < path.len and (path[start] == '/' or path[start] == '\\')) start += 1;
        break :blk path[start..];
    } else path;

    if (hasParentTraversal(relative)) return error.PathOutsideWorkspace;
    return duplicateWithSlashes(allocator, relative);
}

fn assignmentValue(line: []const u8, key: []const u8) ?[]const u8 {
    const equals = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..equals], " \t");
    if (!std.ascii.eqlIgnoreCase(left, key)) return null;
    return std.mem.trim(u8, line[equals + 1 ..], " \t");
}

fn startsWithPath(path: []const u8, root: []const u8) bool {
    if (root.len == 0) return false;
    if (path.len < root.len) return false;
    if (!std.ascii.eqlIgnoreCase(path[0..root.len], root)) return false;
    if (path.len == root.len) return true;
    const next = path[root.len];
    return next == '/' or next == '\\';
}

fn hasParentTraversal(path: []const u8) bool {
    var start: usize = 0;
    while (start <= path.len) {
        var end = start;
        while (end < path.len and path[end] != '/' and path[end] != '\\') : (end += 1) {}
        if (std.mem.eql(u8, path[start..end], "..")) return true;
        if (end == path.len) break;
        start = end + 1;
    }
    return false;
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

test "github remote parser requires the exact github host" {
    try std.testing.expect((try parseGitHubRemote(std.testing.allocator, "https://evil.example/github.com/owner/repo.git")) == null);
    try std.testing.expect((try parseGitHubRemote(std.testing.allocator, "https://github.com.evil.example/owner/repo.git")) == null);
    try std.testing.expect((try parseGitHubRemote(std.testing.allocator, "https://github.com@evil.example/owner/repo.git")) == null);

    var remote = (try parseGitHubRemote(std.testing.allocator, "https://github.com/owner/repo.git")) orelse return error.ExpectedRemote;
    defer remote.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("owner", remote.owner);
    try std.testing.expectEqualStrings("repo", remote.repo);
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

test "text attributes normalize CRLF before index hashing" {
    var attributes = TextAttributes{
        .allocator = std.testing.allocator,
        .rules = try std.testing.allocator.dupe(TextAttributeRule, &.{
            .{ .pattern = try std.testing.allocator.dupe(u8, "*"), .mode = .auto },
            .{ .pattern = try std.testing.allocator.dupe(u8, "*.png"), .mode = .binary },
        }),
    };
    defer attributes.deinit();

    var source = try attributes.canonicalize(std.testing.allocator, "src/main.zig", "one\r\ntwo\r\n");
    defer source.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("one\ntwo\n", source.bytes);
    try std.testing.expectEqualSlices(u8, gitBlobSha1("one\ntwo\n")[0..], gitBlobSha1(source.bytes)[0..]);

    var binary = try attributes.canonicalize(std.testing.allocator, "assets/image.png", "a\r\nb");
    defer binary.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a\r\nb", binary.bytes);
}

test "text attribute parser honors later binary overrides" {
    var rules = std.array_list.Managed(TextAttributeRule).init(std.testing.allocator);
    defer {
        for (rules.items) |*rule| rule.deinit(std.testing.allocator);
        rules.deinit();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "attributes",
        .data = "* text=auto\n*.zig text eol=lf\n*.png binary\n",
    });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.Options.debug_io, "attributes", &path_buffer);
    try appendTextAttributeFile(std.testing.allocator, &rules, path_buffer[0..path_len], 4096);

    const attributes = TextAttributes{ .allocator = std.testing.allocator, .rules = rules.items };
    try std.testing.expectEqual(TextMode.text, attributes.modeForPath("src/main.zig"));
    try std.testing.expectEqual(TextMode.binary, attributes.modeForPath("assets/logo.png"));
    try std.testing.expectEqual(TextMode.auto, attributes.modeForPath("README.md"));
}
