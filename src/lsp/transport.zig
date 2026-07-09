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
} || std.mem.Allocator.Error || std.Io.Writer.Error || std.process.SpawnError || std.Thread.SpawnError;

pub const StderrPreview = struct {
    total: usize,
    bytes: []u8,
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    command_label: []u8,
    stdout_buffer: std.array_list.Managed(u8),
    stderr_buffer: std.array_list.Managed(u8),
    reader_state: ?*ReaderState = null,
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
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
        const command_label = try joinArgv(allocator, spec.argv);
        errdefer allocator.free(command_label);

        const reader_state = try ReaderState.create(allocator, io, child.stdout.?, child.stderr.?);
        errdefer {
            reader_state.deinit();
            allocator.destroy(reader_state);
        }

        var stdout_thread = try std.Thread.spawn(.{}, readerThread, .{ reader_state, Stream.stdout });
        errdefer {
            reader_state.requestStop();
            child.kill(io);
            stdout_thread.join();
        }

        var stderr_thread = try std.Thread.spawn(.{}, readerThread, .{ reader_state, Stream.stderr });
        errdefer {
            reader_state.requestStop();
            child.kill(io);
            stderr_thread.join();
        }

        return .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .command_label = command_label,
            .stdout_buffer = std.array_list.Managed(u8).init(allocator),
            .stderr_buffer = std.array_list.Managed(u8).init(allocator),
            .reader_state = reader_state,
            .stdout_thread = stdout_thread,
            .stderr_thread = stderr_thread,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.stop();
        if (self.reader_state) |state| {
            state.deinit();
            self.allocator.destroy(state);
            self.reader_state = null;
        }
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
        if (self.reader_state != null) return 0;
        const stdout = self.child.stdout orelse return error.MissingPipe;
        return try self.readInto(&self.stdout_buffer, stdout, max_bytes);
    }

    pub fn readStderrChunk(self: *Transport, max_bytes: usize) !usize {
        if (self.reader_state != null) return 0;
        const stderr = self.child.stderr orelse return error.MissingPipe;
        return try self.readInto(&self.stderr_buffer, stderr, max_bytes);
    }

    pub fn nextStdoutFrame(self: *Transport) !?lsp_framing.OwnedFrame {
        if (self.reader_state) |state| {
            state.lock();
            defer state.unlock();
            return try self.nextFrameFromBuffer(&state.stdout_buffer);
        }
        return try self.nextFrameFromBuffer(&self.stdout_buffer);
    }

    pub fn takeStderrPreview(self: *Transport, allocator: std.mem.Allocator, max_bytes: usize) !StderrPreview {
        if (self.reader_state) |state| {
            state.lock();
            defer state.unlock();
            return try takePreviewFromBuffer(allocator, &state.stderr_buffer, max_bytes);
        }
        return try takePreviewFromBuffer(allocator, &self.stderr_buffer, max_bytes);
    }

    pub fn stop(self: *Transport) void {
        if (self.reader_state) |state| state.requestStop();
        if (self.alive) {
            self.child.kill(self.io);
            self.alive = false;
        }
        self.joinReaders();
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

    fn joinReaders(self: *Transport) void {
        if (self.stdout_thread) |thread| {
            self.stdout_thread = null;
            thread.join();
        }
        if (self.stderr_thread) |thread| {
            self.stderr_thread = null;
            thread.join();
        }
    }

    fn nextFrameFromBuffer(self: *Transport, buffer: *std.array_list.Managed(u8)) !?lsp_framing.OwnedFrame {
        const frame = lsp_framing.parse(buffer.items) catch |err| switch (err) {
            error.IncompleteFrame => return null,
            else => return err,
        };
        const owned = lsp_framing.OwnedFrame{
            .allocator = self.allocator,
            .content_length = frame.content_length,
            .body = try self.allocator.dupe(u8, frame.body),
        };
        buffer.replaceRange(0, frame.header_bytes + frame.content_length, &.{}) catch unreachable;
        return owned;
    }
};

const Stream = enum { stdout, stderr };

const ReaderState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    stderr: std.Io.File,
    mutex: std.Io.Mutex = .init,
    stdout_buffer: std.array_list.Managed(u8),
    stderr_buffer: std.array_list.Managed(u8),
    stop_requested: std.atomic.Value(bool) = .init(false),
    stdout_closed: std.atomic.Value(bool) = .init(false),
    stderr_closed: std.atomic.Value(bool) = .init(false),

    fn create(allocator: std.mem.Allocator, io: std.Io, stdout: std.Io.File, stderr: std.Io.File) !*ReaderState {
        const state = try allocator.create(ReaderState);
        state.* = .{
            .allocator = allocator,
            .io = io,
            .stdout = stdout,
            .stderr = stderr,
            .stdout_buffer = std.array_list.Managed(u8).init(allocator),
            .stderr_buffer = std.array_list.Managed(u8).init(allocator),
        };
        return state;
    }

    fn deinit(self: *ReaderState) void {
        self.stderr_buffer.deinit();
        self.stdout_buffer.deinit();
        self.* = undefined;
    }

    fn requestStop(self: *ReaderState) void {
        self.stop_requested.store(true, .release);
    }

    fn shouldStop(self: *ReaderState) bool {
        return self.stop_requested.load(.acquire);
    }

    fn lock(self: *ReaderState) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *ReaderState) void {
        self.mutex.unlock(self.io);
    }

    fn bufferFor(self: *ReaderState, stream: Stream) *std.array_list.Managed(u8) {
        return switch (stream) {
            .stdout => &self.stdout_buffer,
            .stderr => &self.stderr_buffer,
        };
    }

    fn fileFor(self: *ReaderState, stream: Stream) std.Io.File {
        return switch (stream) {
            .stdout => self.stdout,
            .stderr => self.stderr,
        };
    }

    fn markClosed(self: *ReaderState, stream: Stream) void {
        switch (stream) {
            .stdout => self.stdout_closed.store(true, .release),
            .stderr => self.stderr_closed.store(true, .release),
        }
    }
};

fn readerThread(state: *ReaderState, stream: Stream) void {
    var buffer: [4096]u8 = undefined;
    while (!state.shouldStop()) {
        const file = state.fileFor(stream);
        const read_len = std.Io.File.readStreaming(file, state.io, &.{buffer[0..]}) catch |err| switch (err) {
            error.EndOfStream, error.NotOpenForReading => {
                state.markClosed(stream);
                return;
            },
            error.WouldBlock => {
                std.Io.sleep(state.io, std.Io.Duration.fromMilliseconds(8), .awake) catch {};
                continue;
            },
            else => {
                state.markClosed(stream);
                return;
            },
        };
        if (read_len == 0) {
            std.Io.sleep(state.io, std.Io.Duration.fromMilliseconds(8), .awake) catch {};
            continue;
        }
        state.lock();
        state.bufferFor(stream).appendSlice(buffer[0..read_len]) catch {};
        state.unlock();
    }
}

fn takePreviewFromBuffer(allocator: std.mem.Allocator, buffer: *std.array_list.Managed(u8), max_bytes: usize) !StderrPreview {
    const total = buffer.items.len;
    const preview_len = @min(total, max_bytes);
    const bytes = try allocator.dupe(u8, buffer.items[0..preview_len]);
    buffer.clearRetainingCapacity();
    return .{
        .total = total,
        .bytes = bytes,
    };
}

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
        .reader_state = null,
        .stdout_thread = null,
        .stderr_thread = null,
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
