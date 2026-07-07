const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zide",
        .root_module = main_module,
    });

    b.installArtifact(exe);

    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    const linux_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = linux_target,
        .optimize = optimize,
    });
    const linux_exe = b.addExecutable(.{
        .name = "zide",
        .root_module = linux_module,
    });
    const install_linux_cmd = b.addInstallArtifact(linux_exe, .{
        .dest_dir = .{ .override = .{ .custom = "linux-x86_64/bin" } },
    });
    const install_linux_step = b.step("install-linux", "Install Linux x86_64 CLI/TUI zide");
    install_linux_step.dependOn(&install_linux_cmd.step);

    const linux_gui_module = b.createModule(.{
        .root_source_file = b.path("src/gui_main.zig"),
        .target = linux_target,
        .optimize = optimize,
    });
    const linux_gui_exe = b.addExecutable(.{
        .name = "zide-gui",
        .root_module = linux_gui_module,
    });
    const install_linux_gui_cmd = b.addInstallArtifact(linux_gui_exe, .{
        .dest_dir = .{ .override = .{ .custom = "linux-x86_64/bin" } },
    });
    const install_linux_gui_step = b.step("install-linux-gui", "Install Linux x86_64 GUI zide");
    install_linux_gui_step.dependOn(&install_linux_gui_cmd.step);

    const gui_module = b.createModule(.{
        .root_source_file = b.path("src/gui_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .windows) {
        gui_module.linkSystemLibrary("user32", .{});
        gui_module.linkSystemLibrary("gdi32", .{});
        gui_module.linkSystemLibrary("kernel32", .{});
        gui_module.linkSystemLibrary("shell32", .{});
        gui_module.linkSystemLibrary("ole32", .{});
    }

    const gui_exe = b.addExecutable(.{
        .name = "zide-gui",
        .root_module = gui_module,
    });
    if (target.result.os.tag == .windows) {
        gui_exe.subsystem = .windows;
    }

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zide");
    run_step.dependOn(&run_cmd.step);

    const run_gui_cmd = b.addRunArtifact(gui_exe);
    if (b.args) |args| {
        run_gui_cmd.addArgs(args);
    }

    const gui_step = b.step("gui", "Run zide GUI");
    gui_step.dependOn(&run_gui_cmd.step);

    const install_gui_cmd = b.addInstallArtifact(gui_exe, .{});
    const install_gui_step = b.step("install-gui", "Install zide GUI");
    install_gui_step.dependOn(&install_gui_cmd.step);

    const tests = b.addTest(.{
        .root_module = main_module,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const site_module = b.createModule(.{
        .root_source_file = b.path("tools/site_gen.zig"),
        .target = target,
        .optimize = optimize,
    });
    const site_gen = b.addExecutable(.{
        .name = "zide-site-gen",
        .root_module = site_module,
    });
    const run_site = b.addRunArtifact(site_gen);
    run_site.addArg("zig-out/site");

    const site_step = b.step("site", "Generate the ZIDE website with Zig only");
    site_step.dependOn(&run_site.step);
}
