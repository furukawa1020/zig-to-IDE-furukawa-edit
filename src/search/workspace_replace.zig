const std = @import("std");
const literal = @import("literal.zig");
const editor_save = @import("../editor/save.zig");
const workspace_io = @import("../security/workspace_io.zig");
const workspace_mod = @import("../workspace/workspace.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Token = [Sha256.digest_length * 2]u8;

pub const Request = struct {
    find: []const u8,
    replacement: []const u8,
    literal_options: literal.Options = .{},
};

pub const Limits = struct {
    max_file_bytes: usize = 2 * 1024 * 1024,
    max_files: usize = 1024,
    max_matches: usize = 10_000,
    max_total_bytes: usize = 64 * 1024 * 1024,
};

pub const Skipped = struct {
    too_large: usize = 0,
    binary: usize = 0,
    unreadable: usize = 0,
};

pub const FilePreview = struct {
    path: []u8,
    matches: usize,
    before_bytes: usize,
    after_bytes: usize,
    first_line: usize,
    first_column: usize,
    digest: Token,

    pub fn deinit(self: *FilePreview, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Preview = struct {
    allocator: std.mem.Allocator,
    files: []FilePreview,
    matches: usize,
    before_bytes: usize,
    after_bytes: usize,
    skipped: Skipped,
    token: Token,

    pub fn deinit(self: *Preview) void {
        for (self.files) |*file| file.deinit(self.allocator);
        self.allocator.free(self.files);
        self.* = undefined;
    }
};

pub const ApplyReport = struct {
    files: usize,
    matches: usize,
    before_bytes: usize,
    after_bytes: usize,
    token: Token,
};

pub const ParsedApply = struct {
    token: []const u8,
    request: Request,
};

pub fn parseQuery(query: []const u8) ?Request {
    const delimiter = std.mem.indexOf(u8, query, "=>") orelse return null;
    const find = std.mem.trim(u8, query[0..delimiter], " \t\r\n");
    if (find.len == 0) return null;
    return .{ .find = find, .replacement = query[delimiter + 2 ..] };
}

pub fn parseApplyArgument(argument: []const u8) ?ParsedApply {
    const first_newline = std.mem.indexOfScalar(u8, argument, '\n') orelse return null;
    const token = std.mem.trim(u8, argument[0..first_newline], " \t\r");
    if (token.len != @sizeOf(Token)) return null;
    const remainder = argument[first_newline + 1 ..];
    const second_newline = std.mem.indexOfScalar(u8, remainder, '\n') orelse return null;
    const flags = std.mem.trim(u8, remainder[0..second_newline], " \t\r");
    if (flags.len != 2 or (flags[0] != '0' and flags[0] != '1') or (flags[1] != '0' and flags[1] != '1')) return null;
    var request = parseQuery(remainder[second_newline + 1 ..]) orelse return null;
    request.literal_options = .{
        .case_sensitive = flags[0] == '1',
        .whole_word = flags[1] == '1',
    };
    return .{ .token = token, .request = request };
}

pub fn formatApplyArgument(
    allocator: std.mem.Allocator,
    token: Token,
    query: []const u8,
    options: literal.Options,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\n{d}{d}\n{s}", .{
        token[0..],
        @intFromBool(options.case_sensitive),
        @intFromBool(options.whole_word),
        query,
    });
}

pub fn preview(
    allocator: std.mem.Allocator,
    workspace: *const workspace_mod.Workspace,
    request: Request,
    limits: Limits,
) !Preview {
    var plan = try buildPlan(allocator, workspace, request, limits);
    defer plan.deinit();

    const files = try allocator.alloc(FilePreview, plan.files.items.len);
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |*file| file.deinit(allocator);
        allocator.free(files);
    }
    for (plan.files.items, 0..) |file, index| {
        files[index] = .{
            .path = try allocator.dupe(u8, file.path),
            .matches = file.matches,
            .before_bytes = file.before.len,
            .after_bytes = file.after.len,
            .first_line = file.first_line,
            .first_column = file.first_column,
            .digest = std.fmt.bytesToHex(file.digest, .lower),
        };
        initialized += 1;
    }

    return .{
        .allocator = allocator,
        .files = files,
        .matches = plan.matches,
        .before_bytes = plan.before_bytes,
        .after_bytes = plan.after_bytes,
        .skipped = plan.skipped,
        .token = plan.token,
    };
}

pub fn apply(
    allocator: std.mem.Allocator,
    workspace: *const workspace_mod.Workspace,
    request: Request,
    expected_token: []const u8,
    limits: Limits,
) !ApplyReport {
    var plan = try buildPlan(allocator, workspace, request, limits);
    defer plan.deinit();

    if (expected_token.len != plan.token.len or !std.ascii.eqlIgnoreCase(expected_token, plan.token[0..])) {
        return error.PreviewStale;
    }
    if (plan.files.items.len == 0) return error.NoMatches;

    var written: usize = 0;
    while (written < plan.files.items.len) {
        const file = &plan.files.items[written];
        applyPreparedFile(allocator, plan.workspace_root, file, limits.max_file_bytes) catch |err| {
            rollback(&plan, written) catch return error.RollbackFailed;
            return err;
        };
        written += 1;
    }

    return .{
        .files = plan.files.items.len,
        .matches = plan.matches,
        .before_bytes = plan.before_bytes,
        .after_bytes = plan.after_bytes,
        .token = plan.token,
    };
}

const PreparedFile = struct {
    path: []u8,
    before: []u8,
    after: []u8,
    matches: usize,
    first_line: usize,
    first_column: usize,
    digest: [Sha256.digest_length]u8,

    fn deinit(self: *PreparedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.before);
        allocator.free(self.after);
        self.* = undefined;
    }
};

const Plan = struct {
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    files: std.array_list.Managed(PreparedFile),
    matches: usize = 0,
    before_bytes: usize = 0,
    after_bytes: usize = 0,
    skipped: Skipped = .{},
    token: Token = undefined,

    fn init(allocator: std.mem.Allocator, workspace_root: []const u8) Plan {
        return .{
            .allocator = allocator,
            .workspace_root = workspace_root,
            .files = std.array_list.Managed(PreparedFile).init(allocator),
        };
    }

    fn deinit(self: *Plan) void {
        for (self.files.items) |*file| file.deinit(self.allocator);
        self.files.deinit();
        self.* = undefined;
    }
};

fn buildPlan(
    allocator: std.mem.Allocator,
    workspace: *const workspace_mod.Workspace,
    request: Request,
    limits: Limits,
) !Plan {
    if (request.find.len == 0) return error.EmptyNeedle;
    if (std.mem.eql(u8, request.find, request.replacement)) return error.NoChangeRequested;

    var plan = Plan.init(allocator, workspace.root_path);
    errdefer plan.deinit();

    for (workspace.entries.items) |entry| {
        if (entry.kind != .file) continue;

        var capability = workspace_io.openFileCapability(workspace.root_path, entry.path) catch |err| switch (err) {
            error.InvalidWorkspacePath, error.WorkspaceRootNotAbsolute => return error.PathEscapesWorkspace,
            else => {
                plan.skipped.unreadable += 1;
                continue;
            },
        };
        defer capability.close();

        const before = capability.readFileAlloc(allocator, limits.max_file_bytes) catch |err| switch (err) {
            error.FileTooLarge => {
                plan.skipped.too_large += 1;
                continue;
            },
            else => {
                plan.skipped.unreadable += 1;
                continue;
            },
        };
        errdefer allocator.free(before);
        if (looksBinary(before)) {
            allocator.free(before);
            plan.skipped.binary += 1;
            continue;
        }

        const matches = try literal.findAll(allocator, before, request.find, request.literal_options);
        defer allocator.free(matches);
        if (matches.len == 0) {
            allocator.free(before);
            continue;
        }
        if (plan.files.items.len >= limits.max_files) return error.TooManyFiles;
        if (plan.matches +| matches.len > limits.max_matches) return error.TooManyMatches;
        if (plan.before_bytes +| before.len > limits.max_total_bytes) return error.ReplacementTooLarge;

        const after = try replaceAll(allocator, before, matches, request.replacement);
        errdefer allocator.free(after);
        if (plan.after_bytes +| after.len > limits.max_total_bytes) return error.ReplacementTooLarge;

        const location = lineColumnForOffset(before, matches[0].start);
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(before, &digest, .{});
        var prepared: PreparedFile = .{
            .path = try allocator.dupe(u8, entry.path),
            .before = before,
            .after = after,
            .matches = matches.len,
            .first_line = location.line,
            .first_column = location.column,
            .digest = digest,
        };
        errdefer prepared.deinit(allocator);
        try plan.files.append(prepared);
        plan.matches += matches.len;
        plan.before_bytes += before.len;
        plan.after_bytes += after.len;
    }

    std.mem.sort(PreparedFile, plan.files.items, {}, preparedFileLessThan);
    plan.token = planToken(&plan, request);
    return plan;
}

fn replaceAll(
    allocator: std.mem.Allocator,
    before: []const u8,
    matches: []const literal.Match,
    replacement: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var cursor: usize = 0;
    for (matches) |match| {
        try output.writer.writeAll(before[cursor..match.start]);
        try output.writer.writeAll(replacement);
        cursor = match.end;
    }
    try output.writer.writeAll(before[cursor..]);
    return output.toOwnedSlice();
}

fn rollback(plan: *const Plan, written: usize) !void {
    var index = written;
    while (index > 0) {
        index -= 1;
        const file = &plan.files.items[index];
        try restorePreparedFile(plan.allocator, plan.workspace_root, file);
    }
}

fn applyPreparedFile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    file: *const PreparedFile,
    max_file_bytes: usize,
) !void {
    var capability = try workspace_io.openFileCapability(workspace_root, file.path);
    defer capability.close();

    const current = try capability.readFileAlloc(allocator, max_file_bytes);
    defer allocator.free(current);
    if (!std.mem.eql(u8, current, file.before)) return error.PreviewStale;
    editor_save.saveBytesInDirIfUnchanged(
        allocator,
        capability.parent,
        capability.name,
        file.before,
        file.after,
        .{},
    ) catch |err| switch (err) {
        error.DestinationChanged => return error.PreviewStale,
        else => return err,
    };
}

fn restorePreparedFile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    file: *const PreparedFile,
) !void {
    var capability = try workspace_io.openFileCapability(workspace_root, file.path);
    defer capability.close();

    const current = try capability.readFileAlloc(allocator, file.after.len +| 1);
    defer allocator.free(current);
    if (!std.mem.eql(u8, current, file.after)) return error.RollbackConflict;
    editor_save.saveBytesInDirIfUnchanged(
        allocator,
        capability.parent,
        capability.name,
        file.after,
        file.before,
        .{},
    ) catch |err| switch (err) {
        error.DestinationChanged => return error.RollbackConflict,
        else => return err,
    };
}

fn planToken(plan: *const Plan, request: Request) Token {
    var hasher = Sha256.init(.{});
    hashSlice(&hasher, "zide-workspace-replace-v1");
    hashSlice(&hasher, request.find);
    hashSlice(&hasher, request.replacement);
    const flags = [_]u8{
        @intFromBool(request.literal_options.case_sensitive),
        @intFromBool(request.literal_options.whole_word),
    };
    hasher.update(&flags);
    hashUsize(&hasher, plan.files.items.len);
    for (plan.files.items) |file| {
        hashSlice(&hasher, file.path);
        hashUsize(&hasher, file.matches);
        hashUsize(&hasher, file.before.len);
        hashUsize(&hasher, file.after.len);
        hasher.update(&file.digest);
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashSlice(hasher: *Sha256, bytes: []const u8) void {
    hashUsize(hasher, bytes.len);
    hasher.update(bytes);
}

fn hashUsize(hasher: *Sha256, value: usize) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hasher.update(&encoded);
}

fn preparedFileLessThan(_: void, left: PreparedFile, right: PreparedFile) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

fn looksBinary(bytes: []const u8) bool {
    const limit = @min(bytes.len, 4096);
    return std.mem.indexOfScalar(u8, bytes[0..limit], 0) != null;
}

const Location = struct {
    line: usize,
    column: usize,
};

fn lineColumnForOffset(bytes: []const u8, offset: usize) Location {
    var location: Location = .{ .line = 0, .column = 0 };
    var index: usize = 0;
    while (index < offset and index < bytes.len) : (index += 1) {
        if (bytes[index] == '\n') {
            location.line += 1;
            location.column = 0;
        } else {
            location.column += 1;
        }
    }
    return location;
}

test "workspace replace parses preview and apply requests" {
    const request = parseQuery("old=>new=>tail").?;
    try std.testing.expectEqualStrings("old", request.find);
    try std.testing.expectEqualStrings("new=>tail", request.replacement);

    const token: Token = [1]u8{'a'} ** @sizeOf(Token);
    const argument = try formatApplyArgument(std.testing.allocator, token, "old=>new", .{ .case_sensitive = false, .whole_word = true });
    defer std.testing.allocator.free(argument);
    const parsed = parseApplyArgument(argument).?;
    try std.testing.expectEqualStrings(token[0..], parsed.token);
    try std.testing.expectEqualStrings("new", parsed.request.replacement);
    try std.testing.expect(!parsed.request.literal_options.case_sensitive);
    try std.testing.expect(parsed.request.literal_options.whole_word);
}

test "workspace replace previews and atomically applies multiple files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.Options.debug_io, "src");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/a.txt", .data = "old one old\n" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/b.txt", .data = "old two\n" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/data.bin", .data = "old\x00data" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    var workspace = try workspace_mod.Workspace.open(std.testing.allocator, root_buffer[0..root_len]);
    defer workspace.deinit();

    const request: Request = .{ .find = "old", .replacement = "fresh" };
    var plan_preview = try preview(std.testing.allocator, &workspace, request, .{});
    defer plan_preview.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan_preview.files.len);
    try std.testing.expectEqual(@as(usize, 3), plan_preview.matches);
    try std.testing.expectEqual(@as(usize, 1), plan_preview.skipped.binary);

    const report = try apply(std.testing.allocator, &workspace, request, plan_preview.token[0..], .{});
    try std.testing.expectEqual(@as(usize, 2), report.files);
    try std.testing.expectEqual(@as(usize, 3), report.matches);

    const first = try tmp.dir.readFileAlloc(std.Options.debug_io, "src/a.txt", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(first);
    const second = try tmp.dir.readFileAlloc(std.Options.debug_io, "src/b.txt", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("fresh one fresh\n", first);
    try std.testing.expectEqualStrings("fresh two\n", second);
}

test "workspace replace rejects a stale preview before writing" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "a.txt", .data = "old a\n" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "b.txt", .data = "old b\n" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.Options.debug_io, &root_buffer);
    var workspace = try workspace_mod.Workspace.open(std.testing.allocator, root_buffer[0..root_len]);
    defer workspace.deinit();

    const request: Request = .{ .find = "old", .replacement = "new" };
    var plan_preview = try preview(std.testing.allocator, &workspace, request, .{});
    defer plan_preview.deinit();
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "b.txt", .data = "old changed externally\n" });

    try std.testing.expectError(error.PreviewStale, apply(std.testing.allocator, &workspace, request, plan_preview.token[0..], .{}));
    const first = try tmp.dir.readFileAlloc(std.Options.debug_io, "a.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("old a\n", first);
}
