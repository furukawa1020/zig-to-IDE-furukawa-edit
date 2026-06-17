const std = @import("std");
const zide = @import("zide.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = zide.cli.parse(args);
    var stdout = std.io.getStdOut().writer();
    var stderr = std.io.getStdErr().writer();

    try zide.run(allocator, options, stdout, stderr);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("zide.zig");
    _ = @import("architecture.zig");
    _ = @import("cli.zig");
    _ = @import("core/app.zig");
    _ = @import("core/command.zig");
    _ = @import("core/demo.zig");
    _ = @import("core/dispatcher.zig");
    _ = @import("core/event.zig");
    _ = @import("core/event_loop.zig");
    _ = @import("core/input_handler.zig");
    _ = @import("core/loop_runner.zig");
    _ = @import("core/runtime.zig");
    _ = @import("core/types.zig");
    _ = @import("build/steps.zig");
    _ = @import("build/commands.zig");
    _ = @import("build/output.zig");
    _ = @import("build/toolchain.zig");
    _ = @import("config/keymap.zig");
    _ = @import("config/model.zig");
    _ = @import("config/parser.zig");
    _ = @import("debug/session.zig");
    _ = @import("diagnostics/model.zig");
    _ = @import("diagnostics/collection.zig");
    _ = @import("diagnostics/zig_output.zig");
    _ = @import("editor/buffer.zig");
    _ = @import("editor/cursor.zig");
    _ = @import("editor/document.zig");
    _ = @import("editor/navigation.zig");
    _ = @import("editor/save.zig");
    _ = @import("editor/selection.zig");
    _ = @import("editor/store.zig");
    _ = @import("editor/undo.zig");
    _ = @import("git/status.zig");
    _ = @import("language/modes.zig");
    _ = @import("language/semantic.zig");
    _ = @import("language/symbols.zig");
    _ = @import("language/zig_ast.zig");
    _ = @import("language/zig_parser.zig");
    _ = @import("language/zig_tokenizer.zig");
    _ = @import("observability/log.zig");
    _ = @import("persistence/journal.zig");
    _ = @import("persistence/paths.zig");
    _ = @import("platform/fs.zig");
    _ = @import("platform/process.zig");
    _ = @import("platform/terminal.zig");
    _ = @import("search/file_finder.zig");
    _ = @import("search/fuzzy.zig");
    _ = @import("search/literal.zig");
    _ = @import("search/workspace_search.zig");
    _ = @import("security/findings.zig");
    _ = @import("security/build_consent.zig");
    _ = @import("security/permissions.zig");
    _ = @import("security/output_sanitizer.zig");
    _ = @import("security/trust.zig");
    _ = @import("security/zig_scanner.zig");
    _ = @import("tasks/task.zig");
    _ = @import("tasks/console.zig");
    _ = @import("terminal/ansi.zig");
    _ = @import("terminal/input.zig");
    _ = @import("terminal/renderer.zig");
    _ = @import("terminal/session.zig");
    _ = @import("terminal/screen.zig");
    _ = @import("ui/layout.zig");
    _ = @import("ui/command_palette.zig");
    _ = @import("ui/render.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/tui.zig");
    _ = @import("ui/view.zig");
    _ = @import("workspace/file_tree.zig");
    _ = @import("workspace/session.zig");
    _ = @import("workspace/watcher.zig");
    _ = @import("workspace/workspace.zig");
}
