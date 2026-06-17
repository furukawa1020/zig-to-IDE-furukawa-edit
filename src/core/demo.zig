const std = @import("std");
const architecture = @import("../architecture.zig");
const cli = @import("../cli.zig");
const command = @import("command.zig");
const buffer = @import("../editor/buffer.zig");
const modes = @import("../language/modes.zig");
const tokenizer = @import("../language/zig_tokenizer.zig");
const render = @import("../ui/render.zig");

pub fn run(allocator: std.mem.Allocator, kind: cli.DemoName, stdout: anytype) !void {
    switch (kind) {
        .overview => try overview(stdout),
        .architecture => try architectureDemo(stdout),
        .languages => try languages(stdout),
        .commands => try render.renderCommands(stdout),
        .buffer => try bufferDemo(allocator, stdout),
        .zig_tokens => try zigTokens(stdout),
    }
}

fn overview(stdout: anytype) !void {
    try stdout.writeAll(
        \\zide demo
        \\---------
        \\This is the first runnable slice of the IDE:
        \\  editor model       : byte-preserving text buffer
        \\  workspace model    : local directory scan
        \\  command model      : transparent command registry
        \\  language layer     : Zig tokenizer plus generic file modes
        \\  demo runner        : internal demos without external libraries
        \\
        \\Try:
        \\  zide demo architecture
        \\  zide demo languages
        \\  zide demo commands
        \\  zide demo buffer
        \\  zide demo zig-tokens
        \\
    );
}

fn architectureDemo(stdout: anytype) !void {
    try stdout.writeAll("architecture layers\n-------------------\n");
    for (architecture.layers()) |layer| {
        try stdout.print("{s:<14} {s}\n", .{ architecture.layerName(layer.id), layer.owns });
        if (layer.may_call.len > 0) {
            try stdout.writeAll("  may call: ");
            for (layer.may_call, 0..) |callee, index| {
                if (index > 0) try stdout.writeAll(", ");
                try stdout.writeAll(architecture.layerName(callee));
            }
            try stdout.writeAll("\n");
        }
    }
}

fn languages(stdout: anytype) !void {
    try stdout.writeAll("language modes\n--------------\n");
    for (modes.all()) |mode| {
        const zig_note = if (modes.isZigFamily(mode)) "  Zig IDE features" else "  text support";
        try stdout.print("{s:<12}{s}\n", .{ modes.label(mode), zig_note });
    }
}

fn bufferDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    var text = try buffer.TextBuffer.initFromBytes(allocator,
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    std.debug.print("hello zide\n", .{});
        \\}
        \\
    );
    defer text.deinit();

    try text.insertBytes(0, "// demo buffer\n");
    try stdout.print("valid utf8: {}\n", .{text.valid_utf8});
    try stdout.print("newline   : {s}\n", .{@tagName(text.newline)});
    try stdout.print("lines     : {d}\n\n", .{text.lineCount()});

    var line: usize = 0;
    while (line < text.lineCount()) : (line += 1) {
        try stdout.print("{d:>3} | {s}\n", .{ line + 1, text.lineSlice(line) });
    }
}

fn zigTokens(stdout: anytype) !void {
    const source =
        \\const std = @import("std");
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\
    ;

    var lexer = tokenizer.Tokenizer.init(source);
    try stdout.writeAll("zig tokens\n----------\n");
    while (true) {
        const token = lexer.next();
        if (token.tag == .eof) break;
        try stdout.print("{s:<18} {s}\n", .{ @tagName(token.tag), source[token.start..token.end] });
    }
}

test "all commands are visible to demos" {
    try std.testing.expect(command.all().len > 0);
}
