const std = @import("std");
const builtin = @import("builtin");
const process = @import("../platform/process.zig");
const workspace_io = @import("../security/workspace_io.zig");

pub const FileStatus = enum {
    clean,
    modified,
    type_changed,
    added,
    deleted,
    renamed,
    copied,
    unmerged,
    untracked,
    ignored,
    unknown,

    pub fn label(self: FileStatus) []const u8 {
        return switch (self) {
            .clean => " ",
            .modified => "M",
            .type_changed => "T",
            .added => "A",
            .deleted => "D",
            .renamed => "R",
            .copied => "C",
            .unmerged => "U",
            .untracked => "?",
            .ignored => "!",
            .unknown => "X",
        };
    }
};

pub const Entry = struct {
    path: []u8,
    original_path: ?[]u8 = null,
    index_status: FileStatus = .clean,
    worktree_status: FileStatus = .clean,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.original_path) |path| allocator.free(path);
        self.* = undefined;
    }

    pub fn isStaged(self: Entry) bool {
        return self.index_status != .clean and
            self.index_status != .untracked and
            self.index_status != .ignored;
    }

    pub fn isUnstaged(self: Entry) bool {
        return self.index_status == .untracked or
            (self.worktree_status != .clean and self.worktree_status != .ignored);
    }
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    branch: ?[]u8 = null,
    upstream: ?[]u8 = null,
    detached: bool = false,
    ahead: usize = 0,
    behind: usize = 0,
    branches: [][]u8 = &.{},
    entries: []Entry = &.{},

    pub fn deinit(self: *Snapshot) void {
        if (self.branch) |branch| self.allocator.free(branch);
        if (self.upstream) |upstream| self.allocator.free(upstream);
        for (self.branches) |branch| self.allocator.free(branch);
        if (self.branches.len > 0) self.allocator.free(self.branches);
        for (self.entries) |*entry| entry.deinit(self.allocator);
        if (self.entries.len > 0) self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn stagedCount(self: Snapshot) usize {
        var count: usize = 0;
        for (self.entries) |entry| {
            if (entry.isStaged()) count += 1;
        }
        return count;
    }

    pub fn unstagedCount(self: Snapshot) usize {
        var count: usize = 0;
        for (self.entries) |entry| {
            if (entry.isUnstaged()) count += 1;
        }
        return count;
    }

    pub fn stagedEntryAt(self: Snapshot, display_index: usize) ?*const Entry {
        var current: usize = 0;
        for (self.entries) |*entry| {
            if (!entry.isStaged()) continue;
            if (current == display_index) return entry;
            current += 1;
        }
        return null;
    }

    pub fn unstagedEntryAt(self: Snapshot, display_index: usize) ?*const Entry {
        var current: usize = 0;
        for (self.entries) |*entry| {
            if (!entry.isUnstaged()) continue;
            if (current == display_index) return entry;
            current += 1;
        }
        return null;
    }
};

pub const Operation = enum {
    status,
    list_branches,
    stage_path,
    unstage_path,
    stage_all,
    unstage_all,
    commit,
    fetch,
    pull,
    push,
    publish_branch,
    create_branch,
    switch_branch,
    diff_worktree,
    diff_index,

    pub fn usesNetwork(self: Operation) bool {
        return switch (self) {
            .fetch, .pull, .push, .publish_branch => true,
            else => false,
        };
    }

    pub fn changesWorktree(self: Operation) bool {
        return switch (self) {
            .pull, .create_branch, .switch_branch => true,
            else => false,
        };
    }
};

pub fn operationForCommand(command_id: []const u8) ?Operation {
    const mappings = [_]struct { []const u8, Operation }{
        .{ "git.refresh_source_control", .status },
        .{ "git.stage", .stage_path },
        .{ "git.unstage", .unstage_path },
        .{ "git.stage_all", .stage_all },
        .{ "git.unstage_all", .unstage_all },
        .{ "git.commit", .commit },
        .{ "git.fetch", .fetch },
        .{ "git.pull", .pull },
        .{ "git.push", .push },
        .{ "git.publish_branch", .publish_branch },
        .{ "git.branch.create", .create_branch },
        .{ "git.branch.switch", .switch_branch },
        .{ "git.diff_worktree", .diff_worktree },
        .{ "git.diff_staged", .diff_index },
    };
    for (mappings) |mapping| {
        if (std.mem.eql(u8, command_id, mapping[0])) return mapping[1];
    }
    return null;
}

pub fn operationSuccessMessage(operation: Operation) []const u8 {
    return switch (operation) {
        .status => "source control refreshed",
        .list_branches => "local branches refreshed",
        .stage_path => "change staged",
        .unstage_path => "change unstaged",
        .stage_all => "all changes staged",
        .unstage_all => "all changes unstaged",
        .commit => "staged changes committed",
        .fetch => "remote refs fetched",
        .pull => "branch fast-forwarded",
        .push => "branch pushed",
        .publish_branch => "branch published",
        .create_branch => "branch created and selected",
        .switch_branch => "branch switched",
        .diff_worktree => "working-tree diff rendered",
        .diff_index => "staged diff rendered",
    };
}

pub const PlanOptions = struct {
    argument: ?[]const u8 = null,
    remote: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    has_head: bool = true,
    executable: []const u8 = "git",
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    executable: []u8,
    root_path: []u8,
    args: std.array_list.Managed([]u8),
    operation: Operation,

    pub fn init(
        allocator: std.mem.Allocator,
        root_path: []const u8,
        operation: Operation,
        options: PlanOptions,
    ) !Plan {
        const executable = try allocator.dupe(u8, options.executable);
        errdefer allocator.free(executable);
        const owned_root = try allocator.dupe(u8, root_path);
        errdefer allocator.free(owned_root);
        var self = Plan{
            .allocator = allocator,
            .executable = executable,
            .root_path = owned_root,
            .args = std.array_list.Managed([]u8).init(allocator),
            .operation = operation,
        };
        errdefer self.deinit();

        try self.appendBaseArguments();
        switch (operation) {
            .status => try self.appendMany(&.{ "status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all" }),
            .list_branches => try self.appendMany(&.{ "for-each-ref", "--format=%(refname:short)", "refs/heads/" }),
            .stage_path => {
                const path = try requiredWorkspacePath(options.argument);
                try self.appendMany(&.{ "add", "--", path });
            },
            .unstage_path => {
                const path = try requiredWorkspacePath(options.argument);
                if (options.has_head) {
                    try self.appendMany(&.{ "reset", "--", path });
                } else {
                    try self.appendMany(&.{ "rm", "--cached", "--", path });
                }
            },
            .stage_all => try self.appendMany(&.{ "add", "--all", "--", "." }),
            .unstage_all => {
                if (options.has_head) {
                    try self.appendMany(&.{"reset"});
                } else {
                    try self.appendMany(&.{ "rm", "--cached", "-r", "--", "." });
                }
            },
            .commit => {
                const message = try requiredCommitMessage(options.argument);
                try self.appendMany(&.{ "commit", "--no-verify", "--no-gpg-sign", "-m", message });
            },
            .fetch => {
                const remote = try requiredRemote(options.remote);
                try self.appendNetworkBoundary();
                try self.appendMany(&.{ "fetch", "--prune", "--no-tags", "--no-recurse-submodules", remote });
            },
            .pull => {
                const remote = try requiredRemote(options.remote);
                const branch = try requiredBranch(options.branch);
                try self.appendNetworkBoundary();
                try self.appendMany(&.{ "pull", "--ff-only", "--no-edit", "--no-tags", "--no-recurse-submodules", remote, branch });
            },
            .push => {
                const remote = try requiredRemote(options.remote);
                try self.appendNetworkBoundary();
                try self.appendMany(&.{ "push", "--porcelain", "--recurse-submodules=no", remote, "HEAD" });
            },
            .publish_branch => {
                const remote = try requiredRemote(options.remote);
                try self.appendNetworkBoundary();
                try self.appendMany(&.{ "push", "--porcelain", "--recurse-submodules=no", "--set-upstream", remote, "HEAD" });
            },
            .create_branch => {
                const branch = try requiredBranch(options.argument);
                try self.appendMany(&.{ "switch", "-c", branch });
            },
            .switch_branch => {
                const branch = try requiredBranch(options.argument);
                try self.appendMany(&.{ "switch", branch });
            },
            .diff_worktree, .diff_index => {
                const path = try requiredWorkspacePath(options.argument);
                try self.append("diff");
                if (operation == .diff_index) try self.append("--cached");
                try self.appendMany(&.{ "--no-ext-diff", "--no-textconv", "--unified=3", "--", path });
            },
        }
        return self;
    }

    pub fn deinit(self: *Plan) void {
        for (self.args.items) |arg| self.allocator.free(arg);
        self.args.deinit();
        self.allocator.free(self.executable);
        self.allocator.free(self.root_path);
        self.* = undefined;
    }

    pub fn spawnSpec(self: *const Plan) process.SpawnSpec {
        return .{
            .command = .{
                .executable = self.executable,
                .args = self.args.items,
                .cwd = self.root_path,
            },
        };
    }

    fn appendBaseArguments(self: *Plan) !void {
        try self.appendMany(&.{
            "--no-pager",
            "--no-optional-locks",
            "--literal-pathspecs",
            "-c",
            "color.ui=false",
            "-c",
            "core.pager=cat",
            "-c",
            "pager.status=false",
            "-c",
            "core.fsmonitor=false",
            "-c",
            hooksConfig(),
            "-c",
            globalAttributesConfig(),
            "-c",
            "commit.gpgSign=false",
            "-c",
            "tag.gpgSign=false",
            "-c",
            "core.editor=false",
            "-c",
            "sequence.editor=false",
            "-c",
            "core.askPass=",
            "-c",
            "credential.interactive=never",
            "-c",
            "diff.external=",
            "-c",
            "submodule.recurse=false",
            "-c",
            "fetch.recurseSubmodules=false",
        });
    }

    fn appendNetworkBoundary(self: *Plan) !void {
        try self.appendMany(&.{
            "-c",
            "protocol.allow=never",
            "-c",
            "protocol.https.allow=always",
            "-c",
            "protocol.ssh.allow=never",
            "-c",
            "protocol.file.allow=never",
            "-c",
            "protocol.ext.allow=never",
        });
    }

    fn appendMany(self: *Plan, values: []const []const u8) !void {
        for (values) |value| try self.append(value);
    }

    fn append(self: *Plan, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);
        try self.args.append(owned);
    }
};

pub fn resolveGitExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    workspace_root: []const u8,
) ![:0]u8 {
    var env_map = try std.process.Environ.createMap(environ, allocator);
    defer env_map.deinit();
    const path_value = env_map.get("PATH") orelse return error.GitExecutableNotFound;
    const executable_names = if (builtin.os.tag == .windows)
        [_][]const u8{"git.exe"}
    else
        [_][]const u8{"git"};

    var entries = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (entries.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t\"");
        if (entry.len == 0 or !std.fs.path.isAbsolute(entry)) continue;
        for (executable_names) |name| {
            const candidate = try std.fs.path.join(allocator, &.{ entry, name });
            defer allocator.free(candidate);
            const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, candidate, allocator) catch continue;
            if (pathIsWithin(workspace_root, resolved)) {
                allocator.free(resolved);
                continue;
            }
            return resolved;
        }
    }
    return error.GitExecutableNotFound;
}

fn pathIsWithin(root_path: []const u8, candidate_path: []const u8) bool {
    var root_len = root_path.len;
    while (root_len > 1 and isPathSeparator(root_path[root_len - 1])) root_len -= 1;
    if (candidate_path.len < root_len) return false;

    const prefix_matches = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(root_path[0..root_len], candidate_path[0..root_len])
    else
        std.mem.eql(u8, root_path[0..root_len], candidate_path[0..root_len]);
    if (!prefix_matches) return false;
    return candidate_path.len == root_len or isPathSeparator(candidate_path[root_len]);
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or (builtin.os.tag == .windows and byte == '\\');
}

pub fn inspect(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    root_path: []const u8,
) !Snapshot {
    const executable = try resolveGitExecutable(allocator, io, environ, root_path);
    defer allocator.free(executable);
    var plan = try Plan.init(allocator, root_path, .status, .{ .executable = executable });
    defer plan.deinit();
    const spec = plan.spawnSpec();
    const argv = try argvForSpec(allocator, spec);
    defer allocator.free(argv);
    var env_map = try secureGitEnvironment(allocator, environ);
    defer env_map.deinit();
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = root_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
        .timeout = timeoutFromMs(10_000),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (termExitCode(result.term) != 0) return error.GitStatusFailed;

    var snapshot = try parseStatus(allocator, result.stdout);
    errdefer snapshot.deinit();

    var branch_plan = try Plan.init(allocator, root_path, .list_branches, .{ .executable = executable });
    defer branch_plan.deinit();
    const branch_spec = branch_plan.spawnSpec();
    const branch_argv = try argvForSpec(allocator, branch_spec);
    defer allocator.free(branch_argv);
    const branch_result = try std.process.run(allocator, io, .{
        .argv = branch_argv,
        .cwd = .{ .path = root_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
        .timeout = timeoutFromMs(10_000),
    });
    defer allocator.free(branch_result.stdout);
    defer allocator.free(branch_result.stderr);
    if (termExitCode(branch_result.term) != 0) return error.GitBranchListFailed;
    snapshot.branches = try parseBranches(allocator, branch_result.stdout);
    return snapshot;
}

pub fn previewDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    root_path: []const u8,
    path: []const u8,
    staged: bool,
) ![]u8 {
    const executable = try resolveGitExecutable(allocator, io, environ, root_path);
    defer allocator.free(executable);
    var plan = try Plan.init(
        allocator,
        root_path,
        if (staged) .diff_index else .diff_worktree,
        .{ .argument = path, .executable = executable },
    );
    defer plan.deinit();
    const spec = plan.spawnSpec();
    const argv = try argvForSpec(allocator, spec);
    defer allocator.free(argv);
    var env_map = try secureGitEnvironment(allocator, environ);
    defer env_map.deinit();
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = root_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
        .timeout = timeoutFromMs(10_000),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("git {s} diff (argv-only, hooks/textconv/external diff disabled)\npath: {s}\n", .{
        if (staged) "staged" else "working-tree",
        path,
    });
    if (result.stdout.len == 0 and result.stderr.len == 0 and termExitCode(result.term) == 0) {
        try output.writer.writeAll("no diff\n");
    } else {
        try output.writer.writeAll(result.stdout);
        try output.writer.writeAll(result.stderr);
    }
    if (termExitCode(result.term) != 0) {
        try output.writer.print("git diff exit: {d}\n", .{termExitCode(result.term)});
    }
    return output.toOwnedSlice();
}

pub fn parseStatus(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    var snapshot = Snapshot{ .allocator = allocator };
    errdefer snapshot.deinit();

    var entries = std.array_list.Managed(Entry).init(allocator);
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    var fields = std.mem.splitScalar(u8, bytes, 0);
    var first = true;
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        if (first and std.mem.startsWith(u8, field, "## ")) {
            try parseBranchHeader(allocator, &snapshot, field[3..]);
            first = false;
            continue;
        }
        first = false;
        if (field.len < 3 or field[2] != ' ') continue;

        const index_status = statusFromCode(field[0]);
        const worktree_status = statusFromCode(field[1]);
        const renamed = index_status == .renamed or index_status == .copied or
            worktree_status == .renamed or worktree_status == .copied;
        const original = if (renamed) fields.next() else null;
        var entry = Entry{
            .path = try allocator.dupe(u8, field[3..]),
            .original_path = if (original) |path| try allocator.dupe(u8, path) else null,
            .index_status = index_status,
            .worktree_status = worktree_status,
        };
        errdefer entry.deinit(allocator);
        try entries.append(entry);
    }
    snapshot.entries = try entries.toOwnedSlice();
    return snapshot;
}

pub fn parseBranches(allocator: std.mem.Allocator, bytes: []const u8) ![][]u8 {
    var branches = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (branches.items) |branch| allocator.free(branch);
        branches.deinit();
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const branch = std.mem.trim(u8, raw, " \t\r\n");
        if (!validateBranchName(branch)) continue;
        var duplicate = false;
        for (branches.items) |existing| {
            if (std.mem.eql(u8, existing, branch)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try branches.append(try allocator.dupe(u8, branch));
    }
    std.mem.sort([]u8, branches.items, {}, lessThanBranch);
    return branches.toOwnedSlice();
}

fn lessThanBranch(_: void, left: []u8, right: []u8) bool {
    return std.mem.lessThan(u8, left, right);
}

pub fn validateBranchName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255 or !std.unicode.utf8ValidateSlice(name) or
        name[0] == '-' or name[0] == '.' or
        name[name.len - 1] == '/' or name[name.len - 1] == '.' or
        std.mem.eql(u8, name, "HEAD") or
        std.mem.endsWith(u8, name, ".lock") or
        std.mem.indexOf(u8, name, "..") != null or
        std.mem.indexOf(u8, name, "@{") != null or
        std.mem.indexOf(u8, name, "//") != null)
    {
        return false;
    }
    var components = std.mem.splitScalar(u8, name, '/');
    while (components.next()) |component| {
        if (component.len == 0 or component[0] == '.' or
            component[component.len - 1] == '.' or
            std.mem.endsWith(u8, component, ".lock"))
        {
            return false;
        }
        for (component) |byte| {
            if (byte >= 0x80) continue;
            if (byte <= 0x20 or byte == 0x7f) return false;
            switch (byte) {
                '~', '^', ':', '?', '*', '[', '\\' => return false,
                else => {},
            }
        }
    }
    return true;
}

pub fn validateRemoteName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or name[0] == '-') return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '-', '_', '.' => {},
            else => return false,
        }
    }
    return true;
}

fn parseBranchHeader(allocator: std.mem.Allocator, snapshot: *Snapshot, value: []const u8) !void {
    var detail = value;
    if (std.mem.startsWith(u8, detail, "No commits yet on ")) {
        detail = detail["No commits yet on ".len..];
    } else if (std.mem.startsWith(u8, detail, "Initial commit on ")) {
        detail = detail["Initial commit on ".len..];
    }
    if (std.mem.eql(u8, detail, "HEAD (no branch)")) {
        snapshot.detached = true;
        return;
    }

    const tracking_start = std.mem.indexOf(u8, detail, " [");
    const branch_part = if (tracking_start) |index| detail[0..index] else detail;
    if (tracking_start) |index| {
        const tracking = detail[index + 2 ..];
        snapshot.ahead = parseTaggedNumber(tracking, "ahead ") orelse 0;
        snapshot.behind = parseTaggedNumber(tracking, "behind ") orelse 0;
    }

    if (std.mem.indexOf(u8, branch_part, "...")) |separator| {
        snapshot.branch = try allocator.dupe(u8, branch_part[0..separator]);
        snapshot.upstream = try allocator.dupe(u8, branch_part[separator + 3 ..]);
    } else if (branch_part.len > 0) {
        snapshot.branch = try allocator.dupe(u8, branch_part);
    }
}

fn parseTaggedNumber(value: []const u8, tag: []const u8) ?usize {
    const start = std.mem.indexOf(u8, value, tag) orelse return null;
    const digits = value[start + tag.len ..];
    var end: usize = 0;
    while (end < digits.len and std.ascii.isDigit(digits[end])) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseUnsigned(usize, digits[0..end], 10) catch null;
}

fn statusFromCode(code: u8) FileStatus {
    return switch (code) {
        ' ' => .clean,
        'M' => .modified,
        'T' => .type_changed,
        'A' => .added,
        'D' => .deleted,
        'R' => .renamed,
        'C' => .copied,
        'U' => .unmerged,
        '?' => .untracked,
        '!' => .ignored,
        else => .unknown,
    };
}

fn requiredWorkspacePath(value: ?[]const u8) ![]const u8 {
    const path = value orelse return error.GitPathRequired;
    try workspace_io.validateRelativeFilePath(path);
    if (std.mem.startsWith(u8, path, ".git/") or std.mem.startsWith(u8, path, ".git\\")) {
        return error.GitMetadataPathDenied;
    }
    return path;
}

fn requiredCommitMessage(value: ?[]const u8) ![]const u8 {
    const raw = value orelse return error.GitCommitMessageRequired;
    const message = std.mem.trim(u8, raw, " \t\r\n");
    if (message.len == 0) return error.GitCommitMessageRequired;
    if (message.len > 4096) return error.GitCommitMessageTooLong;
    if (!std.unicode.utf8ValidateSlice(message) or
        std.mem.indexOfScalar(u8, message, 0) != null or
        std.mem.indexOfAny(u8, message, "\r\n") != null)
    {
        return error.InvalidGitCommitMessage;
    }
    for (message) |byte| {
        if (byte < 0x20 and byte != '\t') return error.InvalidGitCommitMessage;
    }
    return message;
}

fn requiredRemote(value: ?[]const u8) ![]const u8 {
    const remote = value orelse return error.GitHubRemoteRequired;
    if (!validateRemoteName(remote)) return error.InvalidGitRemoteName;
    return remote;
}

fn requiredBranch(value: ?[]const u8) ![]const u8 {
    const branch = value orelse return error.GitBranchRequired;
    if (!validateBranchName(branch)) return error.InvalidGitBranchName;
    return branch;
}

fn hooksConfig() []const u8 {
    return if (builtin.os.tag == .windows)
        "core.hooksPath=NUL"
    else
        "core.hooksPath=/dev/null";
}

fn globalAttributesConfig() []const u8 {
    return if (builtin.os.tag == .windows)
        "core.attributesfile=NUL"
    else
        "core.attributesfile=/dev/null";
}

fn secureGitEnvironment(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
) !std.process.Environ.Map {
    var source = try std.process.Environ.createMap(environ, allocator);
    defer source.deinit();

    var filtered = std.process.Environ.Map.init(allocator);
    errdefer filtered.deinit();
    const inherited = [_][]const u8{
        "PATH",
        "HOME",
        "USERPROFILE",
        "TMP",
        "TEMP",
        "SYSTEMROOT",
        "SSH_AUTH_SOCK",
    };
    for (inherited) |key| {
        if (source.get(key)) |value| try filtered.put(key, value);
    }
    try filtered.put("GIT_CONFIG_NOSYSTEM", "1");
    try filtered.put("GIT_CONFIG_GLOBAL", if (builtin.os.tag == .windows) "NUL" else "/dev/null");
    try filtered.put("GIT_ATTR_NOSYSTEM", "1");
    try filtered.put("GIT_OPTIONAL_LOCKS", "0");
    try filtered.put("GIT_TERMINAL_PROMPT", "0");
    try filtered.put("GCM_INTERACTIVE", "Never");
    try filtered.put("GIT_PAGER", "cat");
    return filtered;
}

fn argvForSpec(allocator: std.mem.Allocator, spec: process.SpawnSpec) ![]const []const u8 {
    const argv = try allocator.alloc([]const u8, spec.command.args.len + 1);
    argv[0] = spec.command.executable;
    @memcpy(argv[1..], spec.command.args);
    return argv;
}

fn termExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @as(i32, code),
        .signal, .stopped, .unknown => -1,
    };
}

fn timeoutFromMs(ms: u32) std.Io.Timeout {
    return .{ .duration = .{
        .clock = .boot,
        .raw = .fromMilliseconds(ms),
    } };
}

test "porcelain status separates staged and working tree changes" {
    var snapshot = try parseStatus(std.testing.allocator, "## feature/source-control...origin/feature/source-control [ahead 2, behind 1]\x00" ++
        "M  src/staged.zig\x00" ++
        " M src/working.zig\x00" ++
        "MM src/both.zig\x00" ++
        "?? notes.txt\x00" ++
        "R  src/new.zig\x00src/old.zig\x00");
    defer snapshot.deinit();

    try std.testing.expectEqualStrings("feature/source-control", snapshot.branch.?);
    try std.testing.expectEqualStrings("origin/feature/source-control", snapshot.upstream.?);
    try std.testing.expectEqual(@as(usize, 2), snapshot.ahead);
    try std.testing.expectEqual(@as(usize, 1), snapshot.behind);
    try std.testing.expectEqual(@as(usize, 3), snapshot.stagedCount());
    try std.testing.expectEqual(@as(usize, 3), snapshot.unstagedCount());
    try std.testing.expectEqualStrings("src/old.zig", snapshot.entries[4].original_path.?);
}

test "git plans use fixed argv boundaries" {
    var plan = try Plan.init(std.testing.allocator, "C:\\workspace", .stage_path, .{
        .argument = "src/main.zig",
    });
    defer plan.deinit();

    try std.testing.expectEqualStrings("git", plan.spawnSpec().command.executable);
    try std.testing.expectEqualStrings("add", plan.args.items[plan.args.items.len - 3]);
    try std.testing.expectEqualStrings("--", plan.args.items[plan.args.items.len - 2]);
    try std.testing.expectEqualStrings("src/main.zig", plan.args.items[plan.args.items.len - 1]);
}

test "network plans permit HTTPS and deny alternate Git transports" {
    var plan = try Plan.init(std.testing.allocator, "/workspace", .push, .{
        .remote = "origin",
    });
    defer plan.deinit();

    var https_allowed = false;
    var ssh_denied = false;
    var file_denied = false;
    var ext_denied = false;
    for (plan.args.items) |arg| {
        https_allowed = https_allowed or std.mem.eql(u8, arg, "protocol.https.allow=always");
        ssh_denied = ssh_denied or std.mem.eql(u8, arg, "protocol.ssh.allow=never");
        file_denied = file_denied or std.mem.eql(u8, arg, "protocol.file.allow=never");
        ext_denied = ext_denied or std.mem.eql(u8, arg, "protocol.ext.allow=never");
    }

    try std.testing.expect(https_allowed);
    try std.testing.expect(ssh_denied);
    try std.testing.expect(file_denied);
    try std.testing.expect(ext_denied);
}

test "branch and remote validation reject option and ref injection" {
    try std.testing.expect(validateBranchName("feature/source-control"));
    try std.testing.expect(validateBranchName("feature/\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E"));
    try std.testing.expect(!validateBranchName("-danger"));
    try std.testing.expect(!validateBranchName("feature/../main"));
    try std.testing.expect(!validateBranchName("main@{1}"));
    try std.testing.expect(!validateBranchName("feature/.hidden"));
    try std.testing.expect(!validateBranchName("feature.lock/topic"));
    try std.testing.expect(validateRemoteName("origin"));
    try std.testing.expect(!validateRemoteName("../origin"));
}

test "local branch parser validates deduplicates and sorts refs" {
    const branches = try parseBranches(std.testing.allocator, "topic/zeta\r\nmain\n-danger\nmain\nfeature/gui\n");
    defer {
        for (branches) |branch| std.testing.allocator.free(branch);
        std.testing.allocator.free(branches);
    }

    try std.testing.expectEqual(@as(usize, 3), branches.len);
    try std.testing.expectEqualStrings("feature/gui", branches[0]);
    try std.testing.expectEqualStrings("main", branches[1]);
    try std.testing.expectEqualStrings("topic/zeta", branches[2]);
}
