const std = @import("std");

pub const Intent = struct {
    network: bool = false,
    mutating: bool = false,
    shell: bool = false,
    destructive: bool = false,
    package_manager: bool = false,
    reason: []const u8 = "none",
};

pub fn classify(executable: []const u8, args: []const []const u8) Intent {
    const basename = executableBaseName(executable);
    var intent: Intent = .{};

    if (looksNetworkExecutableBase(basename)) {
        intent.network = true;
        intent.reason = "network executable";
    }
    for (args) |arg| {
        if (std.mem.indexOf(u8, arg, "://") != null) {
            intent.network = true;
            intent.reason = "network URL argument";
        }
        if (std.mem.startsWith(u8, arg, "git@")) {
            intent.network = true;
            intent.reason = "Git SSH remote argument";
        }
    }

    if (looksAlwaysMutatingExecutableBase(basename)) {
        intent.mutating = true;
        intent.reason = "shell or file-mutating executable";
    }
    if (looksShellExecutableBase(basename)) {
        intent.shell = true;
        intent.mutating = true;
        intent.reason = "shell executable";
    }
    if (looksDestructiveExecutableBase(basename)) {
        intent.destructive = true;
        intent.mutating = true;
        intent.reason = "destructive file executable";
    }

    if (isOneOf(basename, &.{ "zig", "zig.exe" })) {
        if (firstArgIn(args, &.{ "build", "test", "fmt", "run", "cc", "c++", "ar", "objcopy", "init", "fetch" })) {
            intent.mutating = true;
            intent.reason = "Zig subcommand writes build artifacts or source";
        }
    } else if (isOneOf(basename, &.{ "git", "git.exe" })) {
        if (gitSubcommandIn(args, &.{ "add", "am", "apply", "bisect", "checkout", "clean", "clone", "commit", "fetch", "init", "merge", "mv", "pull", "push", "rebase", "reset", "restore", "rm", "stash", "submodule", "switch" })) {
            intent.mutating = true;
            intent.reason = "Git subcommand mutates repository or network state";
        }
        if (gitSubcommandIn(args, &.{ "clone", "fetch", "ls-remote", "pull", "push", "remote", "submodule" })) {
            intent.network = true;
            intent.reason = "Git subcommand may access remotes";
        }
    } else if (isOneOf(basename, &.{ "cargo", "cargo.exe" })) {
        if (!firstArgIn(args, &.{"metadata"})) {
            intent.package_manager = true;
            intent.mutating = true;
            intent.reason = "Cargo command may write target/cache";
        }
        if (firstArgIn(args, &.{ "add", "build", "fetch", "install", "run", "test", "update" })) {
            intent.network = true;
            intent.reason = "Cargo command may fetch dependencies";
        }
    } else if (isOneOf(basename, &.{ "go", "go.exe" })) {
        if (firstArgIn(args, &.{ "build", "clean", "env", "fmt", "generate", "get", "install", "mod", "run", "test", "work" })) {
            intent.mutating = true;
            intent.reason = "Go subcommand may write workspace/module/cache";
        }
        if (firstArgIn(args, &.{ "get", "install", "mod", "run", "test", "work" })) {
            intent.network = true;
            intent.reason = "Go subcommand may resolve modules";
        }
    } else if (isOneOf(basename, &.{ "npm", "npm.cmd", "pnpm", "pnpm.cmd", "yarn", "yarn.cmd", "bun", "bun.exe" })) {
        intent.package_manager = true;
        if (firstArgIn(args, &.{ "add", "build", "ci", "exec", "install", "rebuild", "remove", "run", "test", "update" })) {
            intent.mutating = true;
            intent.reason = "package manager command may write dependencies or scripts";
        }
        if (firstArgIn(args, &.{ "add", "ci", "exec", "install", "rebuild", "remove", "run", "test", "update" })) {
            intent.network = true;
            intent.reason = "package manager command may access registry";
        }
    }

    for (args) |arg| {
        if (std.mem.eql(u8, arg, ">") or std.mem.eql(u8, arg, ">>")) {
            intent.mutating = true;
            intent.reason = "shell redirection argument";
        }
        if (std.mem.indexOf(u8, arg, "--write") != null) {
            intent.mutating = true;
            intent.reason = "--write argument";
        }
        if (std.mem.indexOf(u8, arg, "--fix") != null) {
            intent.mutating = true;
            intent.reason = "--fix argument";
        }
        if (std.mem.indexOf(u8, arg, "--in-place") != null) {
            intent.mutating = true;
            intent.reason = "--in-place argument";
        }
    }

    return intent;
}

pub fn looksNetworked(executable: []const u8, args: []const []const u8) bool {
    return classify(executable, args).network;
}

pub fn looksMutating(executable: []const u8, args: []const []const u8) bool {
    return classify(executable, args).mutating;
}

fn executableBaseName(path: []const u8) []const u8 {
    var last: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '/' or byte == '\\') last = index + 1;
    }
    return path[last..];
}

fn looksNetworkExecutableBase(basename: []const u8) bool {
    return isOneOf(basename, &.{ "curl", "curl.exe", "wget", "wget.exe", "ssh", "ssh.exe", "scp", "scp.exe", "sftp", "sftp.exe" });
}

fn looksAlwaysMutatingExecutableBase(basename: []const u8) bool {
    return isOneOf(basename, &.{ "bash", "bash.exe", "cmd", "cmd.exe", "cmake", "cmake.exe", "cp", "cp.exe", "copy", "del", "make", "make.exe", "mkdir", "mkdir.exe", "move", "mv", "mv.exe", "ninja", "ninja.exe", "powershell", "powershell.exe", "pwsh", "pwsh.exe", "rm", "rm.exe", "rmdir", "rmdir.exe", "sh", "sh.exe", "tee", "tee.exe", "touch", "touch.exe" });
}

fn looksShellExecutableBase(basename: []const u8) bool {
    return isOneOf(basename, &.{ "bash", "bash.exe", "cmd", "cmd.exe", "powershell", "powershell.exe", "pwsh", "pwsh.exe", "sh", "sh.exe" });
}

fn looksDestructiveExecutableBase(basename: []const u8) bool {
    return isOneOf(basename, &.{ "del", "rm", "rm.exe", "rmdir", "rmdir.exe" });
}

fn firstArgIn(args: []const []const u8, comptime names: []const []const u8) bool {
    if (args.len == 0) return false;
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(args[0], name)) return true;
    }
    return false;
}

fn gitSubcommandIn(args: []const []const u8, comptime names: []const []const u8) bool {
    const subcommand = gitSubcommand(args) orelse return false;
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(subcommand, name)) return true;
    }
    return false;
}

fn gitSubcommand(args: []const []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            return if (index < args.len) args[index] else null;
        }
        if (gitGlobalOptionConsumesValue(arg)) {
            index += 2;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') {
            index += 1;
            continue;
        }
        return arg;
    }
    return null;
}

fn gitGlobalOptionConsumesValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-c") or
        std.mem.eql(u8, arg, "-C") or
        std.mem.eql(u8, arg, "--config-env") or
        std.mem.eql(u8, arg, "--exec-path") or
        std.mem.eql(u8, arg, "--git-dir") or
        std.mem.eql(u8, arg, "--namespace") or
        std.mem.eql(u8, arg, "--super-prefix") or
        std.mem.eql(u8, arg, "--work-tree");
}

fn isOneOf(value: []const u8, comptime names: []const []const u8) bool {
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(value, name)) return true;
    }
    return false;
}

test "command intent detects network and mutation boundaries" {
    var intent = classify("curl", &.{"https://example.test"});
    try std.testing.expect(intent.network);
    try std.testing.expect(!intent.mutating);

    intent = classify("zig", &.{"build"});
    try std.testing.expect(!intent.network);
    try std.testing.expect(intent.mutating);

    intent = classify("git", &.{ "push", "origin", "main" });
    try std.testing.expect(intent.network);
    try std.testing.expect(intent.mutating);
}

test "command intent distinguishes local git from remote and package manager commands" {
    var intent = classify("git", &.{"status"});
    try std.testing.expect(!intent.network);
    try std.testing.expect(!intent.mutating);

    intent = classify("npm", &.{"install"});
    try std.testing.expect(intent.network);
    try std.testing.expect(intent.mutating);
    try std.testing.expect(intent.package_manager);
}

test "command intent finds git subcommand after hardened global options" {
    var intent = classify("git", &.{
        "--no-optional-locks",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
        "add",
        "--",
        "src/main.zig",
    });
    try std.testing.expect(intent.mutating);
    try std.testing.expect(!intent.network);

    intent = classify("git", &.{
        "-c",
        "core.hooksPath=/dev/null",
        "push",
        "--no-verify",
    });
    try std.testing.expect(intent.mutating);
    try std.testing.expect(intent.network);
}

test "command intent handles shell and path basenames" {
    const intent = classify("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", &.{ "-Command", "Remove-Item", "x" });
    try std.testing.expect(intent.shell);
    try std.testing.expect(intent.mutating);
}
