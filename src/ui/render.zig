const std = @import("std");
const command = @import("../core/command.zig");
const app = @import("../core/app.zig");
const modes = @import("../language/modes.zig");

pub fn renderHelp(stdout: anytype) !void {
    try stdout.writeAll(
        \\zide - Zig-first local TUI IDE
        \\
        \\Usage:
        \\  zide [workspace]
        \\  zide commands
        \\  zide demo [overview|architecture|languages|commands|buffer|zig-tokens]
        \\  zide --version
        \\
        \\The current slice renders a TUI-style overview and internal demos.
        \\Raw terminal mode, panels, process streaming, and editing UI come next.
        \\
    );
}

pub fn renderCommands(stdout: anytype) !void {
    try stdout.writeAll("command palette seed\n--------------------\n");
    for (command.all()) |definition| {
        const key = if (definition.default_key.len == 0) "-" else definition.default_key;
        try stdout.print("{s:<24} {s:<10} {s}\n", .{ definition.id, key, definition.description });
    }
}

pub fn renderWorkspace(stdout: anytype, instance: *const app.App) !void {
    const ws = &instance.workspace;

    try stdout.writeAll("\x1b[1mzide\x1b[0m\n");
    try stdout.writeAll("----\n");
    try stdout.print("mode      : {s}\n", .{@tagName(instance.mode)});
    try stdout.print("trust     : {s}\n", .{@tagName(instance.runtime.trust_state)});
    try stdout.print("workspace : {s}\n", .{ws.root_path});
    try stdout.print("entries   : {d}\n", .{ws.entries.items.len});
    try stdout.print("zig files : {d}\n\n", .{ws.countZigFamily()});

    try stdout.writeAll("file tree preview\n-----------------\n");
    if (ws.entries.items.len == 0) {
        try stdout.writeAll("(empty or not scannable)\n");
    } else {
        const limit = @min(ws.entries.items.len, 16);
        for (ws.entries.items[0..limit]) |entry| {
            const kind = switch (entry.kind) {
                .file => "file",
                .directory => "dir ",
                .other => "misc",
            };
            try stdout.print("{s}  {s:<12} {s}\n", .{ kind, modes.label(entry.language), entry.name });
        }
        if (ws.entries.items.len > limit) {
            try stdout.print("... {d} more\n", .{ws.entries.items.len - limit});
        }
    }

    try stdout.writeAll(
        \\
        \\status line seed
        \\----------------
        \\NORMAL | dirty:no | diagnostics:0 | build:idle | git:unknown | target:native
        \\
        \\Next controls will hang off the command model. Try `zide commands`.
        \\
    );
}
