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

    const gui_module = b.createModule(.{
        .root_source_file = b.path("src/gui_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_module.linkSystemLibrary("user32", .{});
    gui_module.linkSystemLibrary("gdi32", .{});
    gui_module.linkSystemLibrary("kernel32", .{});

    const gui_exe = b.addExecutable(.{
        .name = "zide-gui",
        .root_module = gui_module,
    });
    gui_exe.subsystem = .windows;

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
}
