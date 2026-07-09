const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const command_intent = @import("../security/command_intent.zig");
const execution_queue = @import("../tasks/execution_queue.zig");
const permissions = @import("../security/permissions.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("pty.zig is Linux-only");
}

pub const Size = struct {
    rows: u16 = 24,
    cols: u16 = 80,
};

pub const Options = struct {
    workspace_root: []const u8,
    environ: std.process.Environ,
    size: Size = .{},
};

pub const ExitStatus = struct {
    exit_code: i32,
    raw_status: u32,
};

pub const ReadResult = union(enum) {
    data: usize,
    would_block,
    closed,
};

pub const Session = struct {
    master_fd: i32,
    pid: linux.pid_t,

    pub fn close(self: *Session) void {
        if (self.master_fd >= 0) {
            _ = linux.close(self.master_fd);
            self.master_fd = -1;
        }
    }

    pub fn deinit(self: *Session) void {
        self.close();
        self.* = undefined;
    }

    pub fn read(self: *Session, buffer: []u8) !ReadResult {
        const rc = linux.read(self.master_fd, buffer.ptr, buffer.len);
        return switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) .closed else .{ .data = rc },
            .AGAIN => .would_block,
            .IO => .closed,
            else => error.ReadFailed,
        };
    }

    pub fn write(self: *Session, bytes: []const u8) !usize {
        const rc = linux.write(self.master_fd, bytes.ptr, bytes.len);
        return switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .AGAIN => error.WouldBlock,
            else => error.WriteFailed,
        };
    }

    pub fn terminate(self: *Session) void {
        _ = linux.kill(-self.pid, .TERM);
        _ = linux.kill(self.pid, .TERM);
    }

    pub fn kill(self: *Session) void {
        _ = linux.kill(-self.pid, .KILL);
        _ = linux.kill(self.pid, .KILL);
    }

    pub fn pollExit(self: *Session) ?ExitStatus {
        var status: u32 = 0;
        const rc = linux.waitpid(self.pid, &status, linux.W.NOHANG);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return null;
        return .{ .exit_code = exitCodeFromStatus(status), .raw_status = status };
    }
};

pub fn validateTicket(ticket: *const execution_queue.Ticket, workspace_root: []const u8) ?[]const u8 {
    if (!permissions.allowsWorkspacePath(ticket.fs_policy, workspace_root, ticket.cwd)) {
        return "approved command cwd is outside the permitted workspace boundary";
    }
    const intent = command_intent.classify(ticket.executable, ticket.args.items);
    if (intent.network and !permissions.allowsNetwork(ticket.network_policy)) {
        return "approved command looks networked but network policy is deny";
    }
    if (ticket.fs_policy == .read_only_workspace and intent.mutating) {
        return "approved command looks mutating but file system policy is read_only_workspace";
    }
    return null;
}

pub fn spawnTicket(allocator: std.mem.Allocator, ticket: *const execution_queue.Ticket, options: Options) !Session {
    var env_map = try environmentMapForPolicy(allocator, options.environ, ticket.env_policy, options.size);
    defer env_map.deinit();

    const env_block = try env_map.createPosixBlock(allocator, .{});
    defer env_block.deinit(allocator);

    var argv = try ArgvZ.fromTicket(allocator, ticket);
    defer argv.deinit();

    var exec_paths = try ExecPaths.fromExecutable(allocator, ticket.executable, env_map.get("PATH"));
    defer exec_paths.deinit();

    const cwd_z = try allocator.dupeZ(u8, ticket.cwd);
    defer allocator.free(cwd_z);

    const master_fd = try openPtyMaster();
    errdefer _ = linux.close(master_fd);

    const slave_path = try slavePath(allocator, master_fd);
    defer allocator.free(slave_path);

    const slave_fd = try openPtySlave(slave_path);
    errdefer _ = linux.close(slave_fd);

    _ = setWindowSize(slave_fd, options.size);

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) return error.ForkFailed;

    if (fork_rc == 0) {
        childExec(master_fd, slave_fd, cwd_z.ptr, argv.argv.ptr, env_block.slice.ptr, exec_paths.ptrs.items);
    }

    const pid: linux.pid_t = @intCast(fork_rc);
    _ = linux.close(slave_fd);
    return .{ .master_fd = master_fd, .pid = pid };
}

fn openPtyMaster() !i32 {
    const fd_rc = linux.open("/dev/ptmx", .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .NONBLOCK = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return error.OpenPtyMasterFailed;
    const fd: i32 = @intCast(fd_rc);
    errdefer _ = linux.close(fd);

    var unlock: c_int = 0;
    const unlock_rc = linux.ioctl(fd, linux.T.IOCSPTLCK, @intFromPtr(&unlock));
    if (linux.errno(unlock_rc) != .SUCCESS) return error.UnlockPtyFailed;

    return fd;
}

fn slavePath(allocator: std.mem.Allocator, master_fd: i32) ![:0]u8 {
    var pty_number: c_uint = 0;
    const rc = linux.ioctl(master_fd, linux.T.IOCGPTN, @intFromPtr(&pty_number));
    if (linux.errno(rc) != .SUCCESS) return error.PtyNameFailed;
    return std.fmt.allocPrintSentinel(allocator, "/dev/pts/{d}", .{pty_number}, 0);
}

fn openPtySlave(path: [:0]const u8) !i32 {
    const fd_rc = linux.open(path.ptr, .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return error.OpenPtySlaveFailed;
    return @intCast(fd_rc);
}

fn setWindowSize(fd: i32, size: Size) bool {
    var ws: std.posix.winsize = .{
        .row = size.rows,
        .col = size.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    return linux.errno(linux.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws))) == .SUCCESS;
}

fn childExec(
    master_fd: i32,
    slave_fd: i32,
    cwd_z: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    exec_paths: []const [*:0]const u8,
) noreturn {
    _ = linux.close(master_fd);
    _ = linux.setsid();
    _ = linux.ioctl(slave_fd, linux.T.IOCSCTTY, 0);
    _ = linux.dup2(slave_fd, 0);
    _ = linux.dup2(slave_fd, 1);
    _ = linux.dup2(slave_fd, 2);
    if (slave_fd > 2) _ = linux.close(slave_fd);
    if (linux.errno(linux.chdir(cwd_z)) != .SUCCESS) linux.exit(125);

    for (exec_paths) |path| {
        _ = linux.execve(path, argv, envp);
    }
    linux.exit(127);
}

fn exitCodeFromStatus(status: u32) i32 {
    if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
    return 128 + @as(i32, @intCast(@intFromEnum(linux.W.TERMSIG(status))));
}

const ArgvZ = struct {
    allocator: std.mem.Allocator,
    owned: std.array_list.Managed([:0]u8),
    argv: [:null]?[*:0]const u8,

    fn fromTicket(allocator: std.mem.Allocator, ticket: *const execution_queue.Ticket) !ArgvZ {
        var owned = std.array_list.Managed([:0]u8).init(allocator);
        errdefer {
            for (owned.items) |item| allocator.free(item);
            owned.deinit();
        }

        try owned.append(try allocator.dupeZ(u8, ticket.executable));
        for (ticket.args.items) |arg| {
            try owned.append(try allocator.dupeZ(u8, arg));
        }

        const argv = try allocator.allocSentinel(?[*:0]const u8, owned.items.len, null);
        errdefer allocator.free(argv);
        for (owned.items, 0..) |item, index| argv[index] = item.ptr;

        return .{ .allocator = allocator, .owned = owned, .argv = argv };
    }

    fn deinit(self: *ArgvZ) void {
        for (self.owned.items) |item| self.allocator.free(item);
        self.owned.deinit();
        self.allocator.free(self.argv);
        self.* = undefined;
    }
};

const ExecPaths = struct {
    allocator: std.mem.Allocator,
    owned: std.array_list.Managed([:0]u8),
    ptrs: std.array_list.Managed([*:0]const u8),

    fn fromExecutable(allocator: std.mem.Allocator, executable: []const u8, path_env: ?[]const u8) !ExecPaths {
        var self = ExecPaths{
            .allocator = allocator,
            .owned = std.array_list.Managed([:0]u8).init(allocator),
            .ptrs = std.array_list.Managed([*:0]const u8).init(allocator),
        };
        errdefer self.deinit();

        if (std.mem.indexOfScalar(u8, executable, '/') != null) {
            try self.append(executable);
            return self;
        }

        const search = path_env orelse "/usr/local/bin:/usr/bin:/bin";
        var iter = std.mem.splitScalar(u8, search, ':');
        while (iter.next()) |dir| {
            const base = if (dir.len == 0) "." else dir;
            const candidate = try std.fs.path.join(allocator, &.{ base, executable });
            defer allocator.free(candidate);
            try self.append(candidate);
        }
        if (self.ptrs.items.len == 0) try self.append(executable);
        return self;
    }

    fn append(self: *ExecPaths, path: []const u8) !void {
        const z = try self.allocator.dupeZ(u8, path);
        errdefer self.allocator.free(z);
        try self.owned.append(z);
        try self.ptrs.append(z.ptr);
    }

    fn deinit(self: *ExecPaths) void {
        for (self.owned.items) |item| self.allocator.free(item);
        self.owned.deinit();
        self.ptrs.deinit();
        self.* = undefined;
    }
};

fn environmentMapForPolicy(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    policy: permissions.EnvPolicy,
    size: Size,
) !std.process.Environ.Map {
    var map = switch (policy) {
        .empty => std.process.Environ.Map.init(allocator),
        .inherit_all, .allowlist => try std.process.Environ.createMap(environ, allocator),
    };
    errdefer map.deinit();

    if (policy == .allowlist) {
        var filtered = std.process.Environ.Map.init(allocator);
        errdefer filtered.deinit();
        for (map.keys(), map.values()) |key, value| {
            if (permissions.allowsEnv(.allowlist, key)) try filtered.put(key, value);
        }
        map.deinit();
        map = filtered;
    }

    try map.put("TERM", map.get("TERM") orelse "xterm-256color");
    try map.put("ZIDE_PTY", "1");
    var rows_buf: [12]u8 = undefined;
    var cols_buf: [12]u8 = undefined;
    try map.put("LINES", std.fmt.bufPrint(rows_buf[0..], "{d}", .{size.rows}) catch "24");
    try map.put("COLUMNS", std.fmt.bufPrint(cols_buf[0..], "{d}", .{size.cols}) catch "80");
    return map;
}
