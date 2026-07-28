const std = @import("std");

pub const cli = @import("cli.zig");
pub const architecture = @import("architecture.zig");
pub const app = @import("core/app.zig");
pub const command = @import("core/command.zig");
pub const demo = @import("core/demo.zig");
pub const dispatcher = @import("core/dispatcher.zig");
pub const event = @import("core/event.zig");
pub const event_loop = @import("core/event_loop.zig");
pub const input_handler = @import("core/input_handler.zig");
pub const interactive = @import("core/interactive.zig");
pub const loop_runner = @import("core/loop_runner.zig");
pub const runtime = @import("core/runtime.zig");
pub const types = @import("core/types.zig");
pub const buffer = @import("editor/buffer.zig");
pub const completion = @import("language/completion.zig");
pub const modes = @import("language/modes.zig");
pub const lsp_protocol = @import("lsp/protocol.zig");
pub const zig_tokenizer = @import("language/zig_tokenizer.zig");
pub const render = @import("ui/render.zig");
pub const workspace = @import("workspace/workspace.zig");

pub const core = struct {
    pub const app = @import("core/app.zig");
    pub const command = @import("core/command.zig");
    pub const dispatcher = @import("core/dispatcher.zig");
    pub const event = @import("core/event.zig");
    pub const event_loop = @import("core/event_loop.zig");
    pub const input_handler = @import("core/input_handler.zig");
    pub const interactive = @import("core/interactive.zig");
    pub const loop_runner = @import("core/loop_runner.zig");
    pub const runtime = @import("core/runtime.zig");
    pub const types = @import("core/types.zig");
};

pub const platform = struct {
    pub const fs = @import("platform/fs.zig");
    pub const process = @import("platform/process.zig");
    pub const terminal = @import("platform/terminal.zig");
};

pub const terminal_layer = struct {
    pub const ansi = @import("terminal/ansi.zig");
    pub const input = @import("terminal/input.zig");
    pub const renderer = @import("terminal/renderer.zig");
    pub const session = @import("terminal/session.zig");
    pub const screen = @import("terminal/screen.zig");
};

pub const ui = struct {
    pub const command_palette = @import("ui/command_palette.zig");
    pub const layout = @import("ui/layout.zig");
    pub const render = @import("ui/render.zig");
    pub const theme = @import("ui/theme.zig");
    pub const tui = @import("ui/tui.zig");
    pub const view = @import("ui/view.zig");
};

pub const editor = struct {
    pub const buffer = @import("editor/buffer.zig");
    pub const cursor = @import("editor/cursor.zig");
    pub const document = @import("editor/document.zig");
    pub const multi_cursor = @import("editor/multi_cursor.zig");
    pub const navigation = @import("editor/navigation.zig");
    pub const save = @import("editor/save.zig");
    pub const selection = @import("editor/selection.zig");
    pub const store = @import("editor/store.zig");
    pub const undo = @import("editor/undo.zig");
};

pub const workspace_layer = struct {
    pub const file_tree = @import("workspace/file_tree.zig");
    pub const session = @import("workspace/session.zig");
    pub const watcher = @import("workspace/watcher.zig");
    pub const workspace = @import("workspace/workspace.zig");
};

pub const language = struct {
    pub const completion = @import("language/completion.zig");
    pub const highlight = @import("language/highlight.zig");
    pub const modes = @import("language/modes.zig");
    pub const semantic = @import("language/semantic.zig");
    pub const symbols = @import("language/symbols.zig");
    pub const zig_ast = @import("language/zig_ast.zig");
    pub const zig_parser = @import("language/zig_parser.zig");
    pub const zig_tokenizer = @import("language/zig_tokenizer.zig");
};

pub const lsp = struct {
    pub const diagnostics = @import("lsp/diagnostics.zig");
    pub const framing = @import("lsp/framing.zig");
    pub const launch_plan = @import("lsp/launch_plan.zig");
    pub const protocol = @import("lsp/protocol.zig");
    pub const registry = @import("lsp/registry.zig");
    pub const responses = @import("lsp/responses.zig");
    pub const session = @import("lsp/session.zig");
    pub const transport = @import("lsp/transport.zig");
};

pub const diagnostics = struct {
    pub const collection = @import("diagnostics/collection.zig");
    pub const model = @import("diagnostics/model.zig");
    pub const zig_output = @import("diagnostics/zig_output.zig");
};

pub const build_layer = struct {
    pub const commands = @import("build/commands.zig");
    pub const output = @import("build/output.zig");
    pub const steps = @import("build/steps.zig");
    pub const toolchain = @import("build/toolchain.zig");
};

pub const tasks = struct {
    pub const console = @import("tasks/console.zig");
    pub const execution_queue = @import("tasks/execution_queue.zig");
    pub const executor = @import("tasks/executor.zig");
    pub const registry = @import("tasks/registry.zig");
    pub const task = @import("tasks/task.zig");
};

pub const search = struct {
    pub const file_finder = @import("search/file_finder.zig");
    pub const fuzzy = @import("search/fuzzy.zig");
    pub const literal = @import("search/literal.zig");
    pub const problems = @import("search/problems.zig");
    pub const workspace_search = @import("search/workspace_search.zig");
    pub const workspace_replace = @import("search/workspace_replace.zig");
    pub const workspace_symbols = @import("search/workspace_symbols.zig");
};

pub const config = struct {
    pub const keymap = @import("config/keymap.zig");
    pub const model = @import("config/model.zig");
    pub const parser = @import("config/parser.zig");
};

pub const persistence = struct {
    pub const journal = @import("persistence/journal.zig");
    pub const paths = @import("persistence/paths.zig");
    pub const recovery = @import("persistence/recovery.zig");
};

pub const debug_layer = struct {
    pub const framing = @import("debug/framing.zig");
    pub const launch_plan = @import("debug/launch_plan.zig");
    pub const manager = @import("debug/manager.zig");
    pub const protocol = @import("debug/protocol.zig");
    pub const session = @import("debug/session.zig");
    pub const transport = @import("debug/transport.zig");
    pub const workspace_state = @import("debug/workspace_state.zig");
};

pub const git = struct {
    pub const repository = @import("git/repository.zig");
    pub const source_control = @import("git/source_control.zig");
    pub const status = @import("git/status.zig");
};

pub const github = struct {
    pub const client = @import("github/client.zig");
    pub const state = @import("github/state.zig");
};

pub const security = struct {
    pub const build_consent = @import("security/build_consent.zig");
    pub const build_firewall = @import("security/build_firewall.zig");
    pub const debug_expression = @import("security/debug_expression.zig");
    pub const debug_breakpoint = @import("security/debug_breakpoint.zig");
    pub const debug_data = @import("security/debug_data.zig");
    pub const debug_exception = @import("security/debug_exception.zig");
    pub const debug_function = @import("security/debug_function.zig");
    pub const findings = @import("security/findings.zig");
    pub const package_trust = @import("security/package_trust.zig");
    pub const polyglot_scanner = @import("security/polyglot_scanner.zig");
    pub const output_sanitizer = @import("security/output_sanitizer.zig");
    pub const permissions = @import("security/permissions.zig");
    pub const posture = @import("security/posture.zig");
    pub const trust = @import("security/trust.zig");
    pub const workspace_audit = @import("security/workspace_audit.zig");
    pub const workspace_io = @import("security/workspace_io.zig");
    pub const zig_scanner = @import("security/zig_scanner.zig");
};

pub const observability = struct {
    pub const log = @import("observability/log.zig");
};

pub fn run(
    allocator: std.mem.Allocator,
    options: cli.Options,
    stdout: anytype,
    stderr: anytype,
) !void {
    _ = try runWithProcess(allocator, options, std.Options.debug_io, std.process.Environ.empty, stdout, stderr);
}

pub fn runWithProcess(
    allocator: std.mem.Allocator,
    options: cli.Options,
    io: std.Io,
    environ: std.process.Environ,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    switch (options.action) {
        .open => |path| {
            var instance = app.App.initWithProcess(allocator, path, io, environ) catch |err| {
                try stderr.print("zide: workspace open failed for '{s}': {s}\n", .{ path, @errorName(err) });
                return err;
            };
            defer instance.deinit();
            const stdin_file = std.Io.File.stdin();
            const stdout_file = std.Io.File.stdout();
            if (@import("platform/terminal.zig").isInteractive(stdin_file, stdout_file, io)) {
                _ = try interactive.run(
                    allocator,
                    &instance,
                    io,
                    stdin_file,
                    stdout_file,
                    stdout,
                    .{},
                );
            } else {
                try instance.render(stdout);
            }
        },
        .demo => |kind| try demo.run(allocator, kind, stdout),
        .command => |invocation| return try runCommandAction(allocator, invocation, io, environ, stdout, stderr),
        .commands => try render.renderCommands(stdout),
        .version => try stdout.print("zide 0.1.0-dev\n", .{}),
        .help => try render.renderHelp(stdout),
    }
    return 0;
}

fn runCommandAction(
    allocator: std.mem.Allocator,
    invocation: cli.CommandInvocation,
    io: std.Io,
    environ: std.process.Environ,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var instance = app.App.initWithProcess(allocator, ".", io, environ) catch |err| {
        try stderr.print("zide: workspace open failed for '.': {s}\n", .{@errorName(err)});
        return err;
    };
    defer instance.deinit();

    const result = try dispatcher.dispatch(&instance, .{
        .id = invocation.id,
        .argument = invocation.argument,
        .source = .command_palette,
    });
    try writeCommandConsole(&instance, stdout, stderr);

    switch (result) {
        .completed => |message| {
            try stdout.print("completed: {s}\n", .{message});
            return 0;
        },
        .blocked => |message| try stderr.print("blocked: {s}\n", .{message}),
        .unknown_command => try stderr.print("unknown command: {s}\n", .{invocation.id}),
        .no_active_document => try stderr.print("no active document for command: {s}\n", .{invocation.id}),
        .unsupported => |message| try stderr.print("unsupported: {s}\n", .{message}),
        .external_command => |spec| {
            const display = try platform.process.appendDisplay(allocator, spec.command);
            defer allocator.free(display);
            try stderr.print("external command not launched by zide command: {s}\n", .{display});
        },
    }
    return 1;
}

fn writeCommandConsole(instance: *const app.App, stdout: anytype, stderr: anytype) !void {
    for (instance.process_console.lines.items) |line| {
        const out = switch (line.stream) {
            .stdout => stdout,
            .stderr => stderr,
        };
        try out.writeAll(line.text);
        try out.writeAll("\n");
    }
}

test "command action dispatches an internal command" {
    var stdout_buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const exit_code = try runWithProcess(
        std.testing.allocator,
        .{ .action = .{ .command = .{ .id = "release.checklist" } } },
        std.Options.debug_io,
        std.process.Environ.empty,
        &stdout_buffer.writer,
        &stderr_buffer.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.written(), "release/public launch checklist") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.written().len);
}

test "command action returns failure for an unknown command" {
    var stdout_buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const exit_code = try runWithProcess(
        std.testing.allocator,
        .{ .action = .{ .command = .{ .id = "missing.command" } } },
        std.Options.debug_io,
        std.process.Environ.empty,
        &stdout_buffer.writer,
        &stderr_buffer.writer,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.written().len);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.written(), "unknown command") != null);
}
