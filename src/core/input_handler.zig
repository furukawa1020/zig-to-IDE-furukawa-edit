const app_mod = @import("app.zig");
const build_output = @import("../build/output.zig");
const command = @import("command.zig");
const dispatcher = @import("dispatcher.zig");
const event = @import("event.zig");

pub const Outcome = union(enum) {
    ignored,
    redraw,
    command_result: dispatcher.Result,
};

pub fn handle(app: *app_mod.App, input: event.Event) !Outcome {
    switch (input) {
        .key => |key| return handleKey(app, key),
        .paste => |bytes| {
            if (app.palette.visible) {
                try app.palette.insertText(bytes);
                return .redraw;
            }
            return .ignored;
        },
        .command_requested => |id| {
            return .{ .command_result = try dispatcher.dispatch(app, .{ .id = id }) };
        },
        .process_output => |output| {
            try build_output.appendOutput(
                &app.process_console,
                &app.diagnostics,
                if (output.stream == .stdout) .stdout else .stderr,
                output.bytes,
            );
            return .redraw;
        },
        else => return .ignored,
    }
}

fn handleKey(app: *app_mod.App, key: event.KeyEvent) !Outcome {
    if (app.palette.visible) {
        return handlePaletteKey(app, key);
    }

    if (app.mode == .insert) {
        return handleInsertKey(app, key);
    }

    switch (key.code) {
        .enter => if (app.focus == .files) {
            return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "workspace.open_selected", .source = .keybinding }) };
        } else return .ignored,
        .tab => {
            app.focus = if (app.focus == .files) .editor else .files;
            return .redraw;
        },
        .arrow_left => return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "editor.move_left", .source = .keybinding }) },
        .arrow_right => return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "editor.move_right", .source = .keybinding }) },
        .arrow_up => if (fileTreeHasControl(app)) {
            return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "workspace.previous_file", .source = .keybinding }) };
        } else return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "editor.move_up", .source = .keybinding }) },
        .arrow_down => if (fileTreeHasControl(app)) {
            return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "workspace.next_file", .source = .keybinding }) };
        } else return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "editor.move_down", .source = .keybinding }) },
        .char => |char| {
            if (key.modifiers.ctrl and (char == 'p' or char == 'P')) {
                return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "view.command_palette", .source = .keybinding }) };
            }
            if (key.modifiers.ctrl and (char == 'e' or char == 'E')) {
                app.focus = .files;
                return .redraw;
            }
            if (fileTreeHasControl(app) and (char == 'j' or char == 'J')) {
                return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "workspace.next_file", .source = .keybinding }) };
            }
            if (fileTreeHasControl(app) and (char == 'k' or char == 'K')) {
                return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "workspace.previous_file", .source = .keybinding }) };
            }
            if (fileTreeHasControl(app) and (char == 'o' or char == 'O')) {
                return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "workspace.open_selected", .source = .keybinding }) };
            }
            if (char == 'i') {
                if (app.documents.active_index == null) return .ignored;
                app.focus = .editor;
                return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "editor.enter_insert", .source = .keybinding }) };
            }
            return .ignored;
        },
        else => return .ignored,
    }
}

fn fileTreeHasControl(app: *const app_mod.App) bool {
    return app.focus == .files or app.documents.active_index == null;
}

fn handleInsertKey(app: *app_mod.App, key: event.KeyEvent) !Outcome {
    switch (key.code) {
        .escape => return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "editor.exit_insert", .source = .keybinding }) },
        .enter => return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "editor.insert", .argument = "\n", .source = .keybinding }) },
        .tab => return .{ .command_result = try dispatcher.dispatch(app, .{ .id = "editor.insert", .argument = "\t", .source = .keybinding }) },
        .char => |char| {
            var bytes: [4]u8 = undefined;
            const len = encodeUtf8(char, &bytes) catch return .ignored;
            return .{ .command_result = try dispatcher.dispatch(app, .{
                .id = "editor.insert",
                .argument = bytes[0..len],
                .source = .keybinding,
            }) };
        },
        else => return .ignored,
    }
}

fn handlePaletteKey(app: *app_mod.App, key: event.KeyEvent) !Outcome {
    switch (key.code) {
        .escape => {
            app.palette.close();
            app.mode = .normal;
            return .redraw;
        },
        .backspace => {
            try app.palette.deleteBackward();
            return .redraw;
        },
        .arrow_up => {
            app.palette.moveSelection(-1);
            return .redraw;
        },
        .arrow_down => {
            app.palette.moveSelection(1);
            return .redraw;
        },
        .enter => {
            const selected = app.palette.selected() orelse return .ignored;
            app.palette.close();
            app.mode = .normal;
            return .{ .command_result = try dispatcher.dispatch(app, .{
                .id = selected.id,
                .source = .command_palette,
            }) };
        },
        .char => |char| {
            var bytes: [4]u8 = undefined;
            const len = encodeUtf8(char, &bytes) catch return .ignored;
            try app.palette.insertText(bytes[0..len]);
            return .redraw;
        },
        else => return .ignored,
    }
}

fn encodeUtf8(char: u21, out: *[4]u8) !usize {
    if (char <= 0x7f) {
        out[0] = @as(u8, @intCast(char));
        return 1;
    }
    if (char <= 0x7ff) {
        out[0] = @as(u8, @intCast(0xc0 | (char >> 6)));
        out[1] = @as(u8, @intCast(0x80 | (char & 0x3f)));
        return 2;
    }
    if (char <= 0xffff) {
        out[0] = @as(u8, @intCast(0xe0 | (char >> 12)));
        out[1] = @as(u8, @intCast(0x80 | ((char >> 6) & 0x3f)));
        out[2] = @as(u8, @intCast(0x80 | (char & 0x3f)));
        return 3;
    }
    if (char <= 0x10ffff) {
        out[0] = @as(u8, @intCast(0xf0 | (char >> 18)));
        out[1] = @as(u8, @intCast(0x80 | ((char >> 12) & 0x3f)));
        out[2] = @as(u8, @intCast(0x80 | ((char >> 6) & 0x3f)));
        out[3] = @as(u8, @intCast(0x80 | (char & 0x3f)));
        return 4;
    }
    return error.InvalidCodepoint;
}

test "ctrl-p opens command palette through input handler" {
    var app = try app_mod.App.init(@import("std").testing.allocator, ".");
    defer app.deinit();

    const outcome = try handle(&app, .{ .key = .{
        .code = .{ .char = 'p' },
        .modifiers = .{ .ctrl = true },
    } });
    try @import("std").testing.expect(@import("std").meta.activeTag(outcome) == .command_result);
    try @import("std").testing.expect(app.palette.visible);
}

test "enter opens selected file from focused file tree" {
    var app = try app_mod.App.init(@import("std").testing.allocator, ".");
    defer app.deinit();

    app.focus = .files;
    const outcome = try handle(&app, .{ .key = .{ .code = .enter } });
    try @import("std").testing.expect(@import("std").meta.activeTag(outcome) == .command_result);
    try @import("std").testing.expect(app.documents.active() != null);
    try @import("std").testing.expectEqual(app_mod.Focus.editor, app.focus);
}
