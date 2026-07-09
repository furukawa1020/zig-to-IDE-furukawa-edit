const std = @import("std");
const modes = @import("../language/modes.zig");
const process = @import("../platform/process.zig");
const lsp_framing = @import("framing.zig");
const lsp_registry = @import("registry.zig");

pub const LaunchSpec = struct {
    allocator: std.mem.Allocator,
    label: []u8,
    argv: []const []const u8,
    cwd: []u8,
    install_hint: []u8,
    security_note: []u8,

    pub fn deinit(self: *LaunchSpec) void {
        self.allocator.free(self.label);
        for (self.argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.argv);
        self.allocator.free(self.cwd);
        self.allocator.free(self.install_hint);
        self.allocator.free(self.security_note);
        self.* = undefined;
    }
};

pub const StartError = error{
    NoServerForLanguage,
    MissingPipe,
} || std.mem.Allocator.Error || std.Io.Writer.Error || std.process.SpawnError;

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    command_label: []u8,
    stdout_buffer: std.array_list.Managed(u8),
    stderr_buffer: std.array_list.Managed(u8),
    alive: bool = true,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, spec: LaunchSpec, environ_map: ?*const std.process.Environ.Map) StartError!Transport {
        var child = try std.process.spawn(io, .{
            .argv = spec.argv,
            .cwd = .{ .path = spec.cwd },
            .environ_map = environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
        errdefer child.kill(io);

        if (child.stdin == null or child.stdout == null or child.stderr == null) return error.MissingPipe;

        return .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .command_label = try joinArgv(allocator, spec.argv),
            .stdout_buffer = std.array_list.Managed(u8).init(allocator),
            .stderr_buffer = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Transport) void {
        if (self.alive) self.child.kill(self.io);
        self.stderr_buffer.deinit();
        self.stdout_buffer.deinit();
        self.allocator.free(self.command_label);
        self.* = undefined;
    }

    pub fn send(self: *Transport, framed_payload: []const u8) !void {
        const stdin = self.child.stdin orelse return error.MissingPipe;
        try std.Io.File.writeStreamingAll(stdin, self.io, framed_payload);
    }

    pub fn readStdoutChunk(self: *Transport, max_bytes: usize) !usize {
        const stdout = self.child.stdout orelse return error.MissingPipe;
        return try self.readInto(&self.stdout_buffer, stdout, max_bytes);
    }

    pub fn readStderrChunk(self: *Transport, max_bytes: usize) !usize {
        const stderr = self.child.stderr orelse return error.MissingPipe;
        return try self.readInto(&self.stderr_buffer, stderr, max_bytes);
    }

    pub fn nextStdoutFrame(self: *Transport) !?lsp_framing.OwnedFrame {
        const frame = lsp_framing.parse(self.stdout_buffer.items) catch |err| switch (err) {
            error.IncompleteFrame => return null,
            else => return err,
        };
        const owned = lsp_framing.OwnedFrame{
            .allocator = self.allocator,
            .content_length = frame.content_length,
            .body = try self.allocator.dupe(u8, frame.body),
        };
        self.stdout_buffer.replaceRange(0, frame.header_bytes + frame.content_length, &.{}) catch unreachable;
        return owned;
    }

    pub fn stderrText(self: *const Transport) []const u8 {
        return self.stderr_buffer.items;
    }

    pub fn stop(self: *Transport) void {
        if (!self.alive) return;
        self.child.kill(self.io);
        self.alive = false;
    }

    fn readInto(self: *Transport, target: *std.array_list.Managed(u8), file: std.Io.File, max_bytes: usize) !usize {
        if (max_bytes == 0) return 0;
        const previous_len = target.items.len;
        try target.resize(previous_len + max_bytes);
        const bytes = target.items[previous_len..];
        const read_len = std.Io.File.readStreaming(file, self.io, &.{bytes}) catch |err| switch (err) {
            error.EndOfStream => {
                try target.resize(previous_len);
                return 0;
            },
            else => return err,
        };
        try target.resize(previous_len + read_len);
        return read_len;
    }
};

pub fn launchSpecForLanguage(allocator: std.mem.Allocator, language: modes.LanguageMode, workspace_root: []const u8) !?LaunchSpec {
    const server = lsp_registry.serverForLanguage(language) orelse return null;
    const argv = try allocator.alloc([]const u8, 1 + server.args.len);
    errdefer allocator.free(argv);

    argv[0] = try allocator.dupe(u8, server.executable);
    errdefer allocator.free(argv[0]);
    for (server.args, 0..) |arg, index| {
        argv[index + 1] = try allocator.dupe(u8, arg);
        errdefer allocator.free(argv[index + 1]);
    }

    return .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, server.label),
        .argv = argv,
        .cwd = try allocator.dupe(u8, workspace_root),
        .install_hint = try allocator.dupe(u8, server.install_hint),
        .security_note = try allocator.dupe(u8, server.security_note),
    };
}

pub fn spawnPreviewForLanguage(language: modes.LanguageMode, workspace_root: []const u8) ?process.SpawnSpec {
    const server = lsp_registry.serverForLanguage(language) orelse return null;
    return .{
        .command = .{
            .executable = server.executable,
            .args = server.args,
            .cwd = workspace_root,
        },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    };
}

pub fn joinArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.writer.writeByte(' ');
        try writeShellishArg(&out.writer, arg);
    }
    return try out.toOwnedSlice();
}

fn writeShellishArg(writer: *std.Io.Writer, arg: []const u8) !void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\r\n\"") == null) {
        try writer.writeAll(arg);
        return;
    }
    try writer.writeByte('"');
    for (arg) |byte| {
        if (byte == '"') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

test "launch spec uses registry command argv" {
    var spec = (try launchSpecForLanguage(std.testing.allocator, .typescript, "/tmp/project")).?;
    defer spec.deinit();

    try std.testing.expectEqualStrings("TypeScript Language Server", spec.label);
    try std.testing.expectEqual(@as(usize, 2), spec.argv.len);
    try std.testing.expectEqualStrings("typescript-language-server", spec.argv[0]);
    try std.testing.expectEqualStrings("--stdio", spec.argv[1]);
}

test "spawn preview uses static registry slices" {
    const spec = spawnPreviewForLanguage(.rust, "/tmp/project") orelse return error.ExpectedServer;
    try std.testing.expectEqualStrings("rust-analyzer", spec.command.executable);
    try std.testing.expectEqualStrings("/tmp/project", spec.command.cwd.?);
    try std.testing.expectEqual(@as(usize, 0), spec.command.args.len);
}

test "join argv quotes spaces" {
    const line = try joinArgv(std.testing.allocator, &.{ "server name", "--stdio", "plain" });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("\"server name\" --stdio plain", line);
}

test "extract multiple stdout frames from buffer" {
    var transport = Transport{
        .allocator = std.testing.allocator,
        .io = std.Options.debug_io,
        .child = undefined,
        .command_label = try std.testing.allocator.dupe(u8, "test"),
        .stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator),
        .stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator),
        .alive = false,
    };
    defer transport.deinit();

    const one = try lsp_framing.encode(std.testing.allocator, "{\"id\":1}");
    defer std.testing.allocator.free(one);
    const two = try lsp_framing.encode(std.testing.allocator, "{\"id\":2}");
    defer std.testing.allocator.free(two);
    try transport.stdout_buffer.appendSlice(one);
    try transport.stdout_buffer.appendSlice(two);

    var frame_one = (try transport.nextStdoutFrame()).?;
    defer frame_one.deinit();
    try std.testing.expectEqualStrings("{\"id\":1}", frame_one.body);

    var frame_two = (try transport.nextStdoutFrame()).?;
    defer frame_two.deinit();
    try std.testing.expectEqualStrings("{\"id\":2}", frame_two.body);

    try std.testing.expect((try transport.nextStdoutFrame()) == null);
}
