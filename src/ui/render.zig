const std = @import("std");
const command = @import("../core/command.zig");
const app = @import("../core/app.zig");
const modes = @import("../language/modes.zig");
const posture = @import("../security/posture.zig");

pub fn renderHelp(stdout: anytype) !void {
    try stdout.writeAll(
        \\zide - Zig-first local TUI IDE
        \\
        \\Usage:
        \\  zide [workspace]
        \\  zide commands
        \\  zide demo [overview|architecture|languages|commands|editor|palette|dispatch|diagnostics|input|loop|screen|security|buffer|zig-tokens]
        \\  zide --version
        \\
        \\The current slice has a virtual screen, input decoding, command dispatch,
        \\document editing, diagnostics parsing, approved command execution,
        \\output sanitization, and internal demos.
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
    try stdout.print("focus     : {s}\n", .{@tagName(instance.focus)});
    try stdout.print("trust     : {s}\n", .{@tagName(instance.runtime.trust_state)});
    try stdout.print("workspace : {s}\n", .{ws.root_path});
    try stdout.print("entries   : {d}\n", .{ws.entries.items.len});
    try stdout.print("zig files : {d}\n\n", .{ws.countZigFamily()});
    try stdout.print("documents : {d}\n", .{instance.documents.documents.items.len});
    try stdout.print("palette   : {s}\n", .{if (instance.palette.visible) "open" else "closed"});
    try stdout.print("diagnostic: {d} error(s), {d} warning(s)\n", .{
        instance.diagnostics.countBySeverity(.err),
        instance.diagnostics.countBySeverity(.warning),
    });
    const security = posture.summarize(&instance.security_findings, instance.runtime.trust_state);
    try stdout.print("security  : {s} ({d} finding(s), {d} high+, {d} critical)\n", .{
        security.label,
        security.total,
        security.high,
        security.critical,
    });
    try stdout.print("recommend : {s}\n", .{@tagName(security.recommended_trust)});
    try stdout.print("sanitized : {d} terminal control sequence(s)\n", .{instance.process_console.sanitized_stats.total()});
    try stdout.print("queue     : {d} approved command(s)\n", .{instance.execution_queue.queuedCount()});
    try stdout.print("history   : {d} completed command(s)\n", .{instance.execution_queue.history.items.len});
    try stdout.print("process   : {s}\n\n", .{if (instance.process_console.running) "running" else "idle"});
    if (instance.selectedWorkspaceEntry()) |entry| {
        try stdout.print("selected  : {s}\n\n", .{entry.path});
    }

    if (instance.pending_build_consent) |preview| {
        try stdout.writeAll("pending build consent\n---------------------\n");
        try stdout.print("command   : {s}\n", .{preview.command});
        try stdout.print("cwd       : {s}\n", .{preview.cwd});
        try stdout.print("trust     : {s}\n", .{@tagName(preview.trust_state)});
        try stdout.print("env/fs/net: {s} / {s} / {s}\n", .{
            @tagName(preview.consent.env_policy),
            @tagName(preview.consent.fs_policy),
            @tagName(preview.consent.network_policy),
        });
        if (preview.consent.timeout_ms) |ms| {
            try stdout.print("timeout   : {d}ms\n", .{ms});
        } else {
            try stdout.writeAll("timeout   : none\n");
        }
        try stdout.print("output cap: {d} bytes\n\n", .{preview.consent.output_limit_bytes});
    }

    if (instance.execution_queue.latest()) |ticket| {
        try stdout.writeAll("latest approved command\n-----------------------\n");
        try stdout.print("source    : {s}\n", .{ticket.source_command_id});
        try stdout.print("command   : {s}\n", .{ticket.display_command});
        try stdout.print("cwd       : {s}\n", .{ticket.cwd});
        try stdout.print("env/fs/net: {s} / {s} / {s}\n", .{
            @tagName(ticket.env_policy),
            @tagName(ticket.fs_policy),
            @tagName(ticket.network_policy),
        });
        if (ticket.timeout_ms) |ms| {
            try stdout.print("timeout   : {d}ms\n", .{ms});
        } else {
            try stdout.writeAll("timeout   : none\n");
        }
        try stdout.print("output cap: {d} bytes\n\n", .{ticket.output_limit_bytes});
    }

    if (instance.execution_queue.latestHistory()) |entry| {
        try stdout.writeAll("latest command result\n---------------------\n");
        try stdout.print("source    : {s}\n", .{entry.source_command_id});
        try stdout.print("command   : {s}\n", .{entry.display_command});
        try stdout.print("state     : {s}\n", .{@tagName(entry.state)});
        if (entry.exit_code) |code| {
            try stdout.print("exit      : {d}\n", .{code});
        } else {
            try stdout.writeAll("exit      : none\n");
        }
        try stdout.print("lines     : {d}\n", .{entry.output_lines});
        try stdout.print("sanitized : {d}\n", .{entry.sanitized_controls});
        if (entry.timeout_ms) |ms| {
            try stdout.print("timeout   : {d}ms\n", .{ms});
        } else {
            try stdout.writeAll("timeout   : none\n");
        }
        try stdout.print("output cap: {d} bytes\n\n", .{entry.output_limit_bytes});
    }

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
            try stdout.print("{s}  {s:<12} {s}\n", .{ kind, modes.label(entry.language), entry.path });
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
