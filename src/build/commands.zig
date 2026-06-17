const process = @import("../platform/process.zig");
const toolchain = @import("toolchain.zig");

pub const BuildInvocation = enum {
    build,
    test_step,
    fmt,
    run,
};

pub fn makeZigCommand(tc: toolchain.ZigToolchain, invocation: BuildInvocation, extra_args: []const []const u8) process.SpawnSpec {
    return .{
        .command = .{
            .executable = tc.executable,
            .args = argsFor(invocation, extra_args),
            .cwd = null,
        },
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
    };
}

fn argsFor(invocation: BuildInvocation, extra_args: []const []const u8) []const []const u8 {
    if (extra_args.len > 0) return extra_args;
    return switch (invocation) {
        .build => &.{ "build" },
        .test_step => &.{ "build", "test" },
        .fmt => &.{ "fmt" },
        .run => &.{ "build", "run" },
    };
}

