const std = @import("std");
const framing = @import("framing.zig");

const max_protocol_buffer_bytes = framing.max_payload_bytes + framing.max_header_bytes;
const max_stderr_buffer_bytes: usize = 256 * 1024;

pub const LaunchSpec = struct {
    argv: []const []const u8,
    cwd: []const u8,
};

pub const StderrPreview = struct {
    total: usize,
    bytes: []u8,
    truncated: bool,
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    command_label: []u8,
    stdout_buffer: std.array_list.Managed(u8),
    stderr_buffer: std.array_list.Managed(u8),
    stderr_total: usize = 0,
    stdout_overflow: bool = false,
    reader_state: ?*ReaderState = null,
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
    alive: bool = true,

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        spec: LaunchSpec,
        environ_map: ?*const std.process.Environ.Map,
    ) !Transport {
        if (spec.argv.len == 0) return error.EmptyAdapterCommand;
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
        if (!self.alive) return error.TransportStopped;
        const stdin = self.child.stdin orelse return error.MissingPipe;
        try std.Io.File.writeStreamingAll(stdin, self.io, framed_payload);
    }

    pub fn nextFrame(self: *Transport) !?framing.OwnedFrame {
        if (self.reader_state) |state| {
            state.lock();
            defer state.unlock();
            return try self.nextFrameFromBuffer(&state.stdout_buffer, &state.stdout_overflow);
        }
        return try self.nextFrameFromBuffer(&self.stdout_buffer, &self.stdout_overflow);
    }

    pub fn takeStderrPreview(self: *Transport, allocator: std.mem.Allocator, max_bytes: usize) !StderrPreview {
        if (self.reader_state) |state| {
            state.lock();
            defer state.unlock();
            const total = state.stderr_total.swap(0, .acq_rel);
            return try takePreviewFromBuffer(allocator, &state.stderr_buffer, total, max_bytes);
        }
        const total = self.stderr_total;
        self.stderr_total = 0;
        return try takePreviewFromBuffer(allocator, &self.stderr_buffer, total, max_bytes);
    }

    pub fn protocolViolated(self: *const Transport) bool {
        if (self.reader_state) |state| return state.stdout_overflow.load(.acquire);
        return self.stdout_overflow;
    }

    pub fn streamsClosed(self: *const Transport) bool {
        if (self.reader_state) |state| {
            return state.stdout_closed.load(.acquire) and state.stderr_closed.load(.acquire);
        }
        return !self.alive;
    }

    pub fn stop(self: *Transport) void {
        if (self.reader_state) |state| state.requestStop();
        if (self.alive) {
            self.child.kill(self.io);
            self.alive = false;
        }
        self.joinReaders();
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

    fn nextFrameFromBuffer(
        self: *Transport,
        buffer: *std.array_list.Managed(u8),
        overflow: anytype,
    ) !?framing.OwnedFrame {
        const frame = framing.parse(buffer.items) catch |err| switch (err) {
            error.IncompleteFrame => return null,
            error.FrameTooLarge, error.HeaderTooLarge => {
                setOverflow(overflow);
                return err;
            },
            else => return err,
        };
        const body = try self.allocator.dupe(u8, frame.body);
        errdefer self.allocator.free(body);
        buffer.replaceRange(0, frame.consumed_bytes, &.{}) catch unreachable;
        return .{ .allocator = self.allocator, .body = body };
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
    stdout_overflow: std.atomic.Value(bool) = .init(false),
    stderr_total: std.atomic.Value(usize) = .init(0),

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

    fn appendRead(self: *ReaderState, stream: Stream, bytes: []const u8) void {
        self.lock();
        defer self.unlock();
        switch (stream) {
            .stdout => {
                if (self.stdout_overflow.load(.acquire)) return;
                if (bytes.len > max_protocol_buffer_bytes -| self.stdout_buffer.items.len) {
                    self.stdout_overflow.store(true, .release);
                    return;
                }
                self.stdout_buffer.appendSlice(bytes) catch self.stdout_overflow.store(true, .release);
            },
            .stderr => {
                _ = self.stderr_total.fetchAdd(bytes.len, .monotonic);
                const remaining = max_stderr_buffer_bytes -| self.stderr_buffer.items.len;
                self.stderr_buffer.appendSlice(bytes[0..@min(remaining, bytes.len)]) catch {};
            },
        }
    }
};

fn readerThread(state: *ReaderState, stream: Stream) void {
    var buffer: [4096]u8 = undefined;
    while (!state.shouldStop()) {
        const read_len = std.Io.File.readStreaming(state.fileFor(stream), state.io, &.{buffer[0..]}) catch |err| switch (err) {
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
        state.appendRead(stream, buffer[0..read_len]);
    }
}

fn takePreviewFromBuffer(
    allocator: std.mem.Allocator,
    buffer: *std.array_list.Managed(u8),
    total: usize,
    max_bytes: usize,
) !StderrPreview {
    const preview_len = @min(buffer.items.len, max_bytes);
    const bytes = try allocator.dupe(u8, buffer.items[0..preview_len]);
    const truncated = total > preview_len;
    buffer.clearRetainingCapacity();
    return .{ .total = total, .bytes = bytes, .truncated = truncated };
}

fn setOverflow(value: anytype) void {
    const Value = @TypeOf(value.*);
    if (Value == bool) {
        value.* = true;
    } else {
        value.store(true, .release);
    }
}

fn joinArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.writer.writeByte(' ');
        if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\r\n\"") == null) {
            try out.writer.writeAll(arg);
            continue;
        }
        try out.writer.writeByte('"');
        for (arg) |byte| {
            if (byte == '"') try out.writer.writeByte('\\');
            try out.writer.writeByte(byte);
        }
        try out.writer.writeByte('"');
    }
    return out.toOwnedSlice();
}

test "transport extracts multiple bounded DAP frames" {
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

    const one = try framing.encode(std.testing.allocator, "{\"seq\":1}");
    defer std.testing.allocator.free(one);
    const two = try framing.encode(std.testing.allocator, "{\"seq\":2}");
    defer std.testing.allocator.free(two);
    try transport.stdout_buffer.appendSlice(one);
    try transport.stdout_buffer.appendSlice(two);

    var frame_one = (try transport.nextFrame()).?;
    defer frame_one.deinit();
    try std.testing.expectEqualStrings("{\"seq\":1}", frame_one.body);
    var frame_two = (try transport.nextFrame()).?;
    defer frame_two.deinit();
    try std.testing.expectEqualStrings("{\"seq\":2}", frame_two.body);
    try std.testing.expect((try transport.nextFrame()) == null);
    try std.testing.expect(transport.streamsClosed());
}
