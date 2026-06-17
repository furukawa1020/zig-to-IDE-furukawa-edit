const std = @import("std");
const app_mod = @import("../core/app.zig");
const layout = @import("layout.zig");
const modes = @import("../language/modes.zig");
const screen_mod = @import("../terminal/screen.zig");

const Style = screen_mod.Style;

pub fn renderApp(allocator: std.mem.Allocator, app: *const app_mod.App, width: u16, height: u16) !screen_mod.Screen {
    var screen = try screen_mod.Screen.init(allocator, width, height);
    errdefer screen.deinit();

    const root = layout.Rect{ .x = 0, .y = 0, .width = width, .height = height };
    renderFrame(&screen, app, root);
    return screen;
}

fn renderFrame(screen: *screen_mod.Screen, app: *const app_mod.App, root: layout.Rect) void {
    const bg = Style{ .fg = 7, .bg = 0 };
    screen.clear(bg);
    if (root.width == 0 or root.height == 0) return;

    const status_height: u16 = 1;
    const body_height = if (root.height > status_height) root.height - status_height else root.height;
    const body = layout.Rect{ .x = root.x, .y = root.y, .width = root.width, .height = body_height };
    const status = layout.Rect{ .x = root.x, .y = root.y + body_height, .width = root.width, .height = status_height };

    const sidebar_width = @min(@as(u16, 28), if (body.width > 12) body.width / 3 else body.width);
    const main_split = layout.splitVertical(body, sidebar_width);
    const editor_split = layout.splitHorizontal(main_split.second, if (main_split.second.height > 6) main_split.second.height - 5 else main_split.second.height);

    renderFileTree(screen, app, main_split.first);
    renderEditor(screen, app, editor_split.first);
    renderBottomPanel(screen, app, editor_split.second);
    renderStatus(screen, app, status);
    if (app.palette.visible) renderPalette(screen, app, root);
}

fn renderFileTree(screen: *screen_mod.Screen, app: *const app_mod.App, rect: layout.Rect) void {
    if (rect.width == 0 or rect.height == 0) return;
    screen.fillRect(rect.x, rect.y, rect.width, rect.height, ' ', .{ .fg = 7, .bg = 0 });
    screen.writeTextClipped(rect.x, rect.y, rect.width, " FILES", .{ .fg = 6, .bg = 0, .bold = true });

    var row: u16 = 1;
    for (app.workspace.entries.items) |entry| {
        if (row >= rect.height) break;
        const prefix = switch (entry.kind) {
            .file => "  ",
            .directory => "+ ",
            .other => "? ",
        };
        const style = if (modes.isZigFamily(entry.language))
            Style{ .fg = 2, .bg = 0 }
        else
            Style{ .fg = 7, .bg = 0 };
        screen.writeTextClipped(rect.x, rect.y + row, rect.width, prefix, style);
        const prefix_width = @as(u16, @intCast(prefix.len));
        const name_x = rect.x + prefix_width;
        const name_width = if (rect.width > prefix_width) rect.width - prefix_width else 0;
        screen.writeTextClipped(name_x, rect.y + row, name_width, entry.path, style);
        row += 1;
    }
}

fn renderEditor(screen: *screen_mod.Screen, app: *const app_mod.App, rect: layout.Rect) void {
    if (rect.width == 0 or rect.height == 0) return;
    screen.fillRect(rect.x, rect.y, rect.width, rect.height, ' ', .{ .fg = 7, .bg = 0 });

    const doc = activeConst(app);
    if (doc == null) {
        screen.writeTextClipped(rect.x + 1, rect.y, safeWidth(rect.width, 1), "no file open", .{ .fg = 3, .bg = 0 });
        return;
    }

    const document = doc.?;
    const title = document.path orelse "(scratch)";
    screen.writeTextClipped(rect.x, rect.y, rect.width, title, .{ .fg = 6, .bg = 0, .bold = true });

    var row: u16 = 1;
    var line: usize = 0;
    while (row < rect.height and line < document.text.lineCount()) {
        var number_buf: [8]u8 = undefined;
        const number = std.fmt.bufPrint(&number_buf, "{d:>4} ", .{line + 1}) catch "";
        screen.writeTextClipped(rect.x, rect.y + row, @min(rect.width, 5), number, .{ .fg = 4, .bg = 0 });
        if (rect.width > 5) {
            screen.writeTextClipped(rect.x + 5, rect.y + row, rect.width - 5, document.text.lineSlice(line), .{ .fg = 7, .bg = 0 });
        }
        row += 1;
        line += 1;
    }
}

fn renderBottomPanel(screen: *screen_mod.Screen, app: *const app_mod.App, rect: layout.Rect) void {
    if (rect.width == 0 or rect.height == 0) return;
    screen.fillRect(rect.x, rect.y, rect.width, rect.height, ' ', .{ .fg = 7, .bg = 0 });
    screen.writeTextClipped(rect.x, rect.y, rect.width, " DIAGNOSTICS / OUTPUT", .{ .fg = 5, .bg = 0, .bold = true });

    var row: u16 = 1;
    for (app.diagnostics.items.items) |item| {
        if (row >= rect.height) break;
        var line_buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&line_buf, "{s}:{d}:{d}: {s}: {s}", .{
            item.path,
            item.range.start.line + 1,
            item.range.start.column + 1,
            @tagName(item.severity),
            item.message,
        }) catch item.message;
        screen.writeTextClipped(rect.x, rect.y + row, rect.width, text, .{ .fg = if (item.severity == .error) 1 else 3, .bg = 0 });
        row += 1;
    }

    for (app.process_console.lines.items) |line| {
        if (row >= rect.height) break;
        screen.writeTextClipped(rect.x, rect.y + row, rect.width, line.text, .{ .fg = if (line.stream == .stderr) 1 else 7, .bg = 0 });
        row += 1;
    }
}

fn renderStatus(screen: *screen_mod.Screen, app: *const app_mod.App, rect: layout.Rect) void {
    if (rect.width == 0 or rect.height == 0) return;
    screen.fillRect(rect.x, rect.y, rect.width, rect.height, ' ', .{ .fg = 0, .bg = 6, .bold = true });

    const doc = activeConst(app);
    const dirty = if (doc) |document| blk: {
        break :blk if (document.dirty) "dirty" else "clean";
    } else "no-doc";
    var status_buf: [256]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, " {s} | {s} | diag:{d} | build:{s} | {s}", .{
        @tagName(app.mode),
        dirty,
        app.diagnostics.items.items.len,
        if (app.process_console.running) "running" else "idle",
        app.workspace.root_path,
    }) catch " zide";
    screen.writeTextClipped(rect.x, rect.y, rect.width, status, .{ .fg = 0, .bg = 6, .bold = true });
}

fn renderPalette(screen: *screen_mod.Screen, app: *const app_mod.App, root: layout.Rect) void {
    if (root.width < 12 or root.height < 5) return;
    const width = @min(root.width - 4, @as(u16, 64));
    const height = @min(root.height - 2, @as(u16, 10));
    const x = (root.width - width) / 2;
    const y = (root.height - height) / 2;
    screen.drawBox(x, y, width, height, .{ .fg = 6, .bg = 0, .bold = true });

    var query_buf: [160]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buf, "> {s}", .{app.palette.query.items}) catch ">";
    screen.writeTextClipped(x + 1, y + 1, width - 2, query, .{ .fg = 7, .bg = 0, .bold = true });

    var row: u16 = 2;
    for (app.palette.matches.items, 0..) |match, index| {
        if (row + 1 >= height) break;
        const selected = index == app.palette.selected_index;
        var line_buf: [192]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s:<24} {s}", .{ match.definition.id, match.definition.title }) catch match.definition.id;
        screen.writeTextClipped(x + 1, y + row, width - 2, line, .{
            .fg = if (selected) 0 else 7,
            .bg = if (selected) 6 else 0,
            .bold = selected,
        });
        row += 1;
    }
}

fn activeConst(app: *const app_mod.App) ?*const @import("../editor/document.zig").Document {
    const index = app.documents.active_index orelse return null;
    if (index >= app.documents.documents.items.len) return null;
    return &app.documents.documents.items[index];
}

fn safeWidth(width: u16, used: u16) u16 {
    return if (width > used) width - used else 0;
}

test "tui renders app into screen" {
    var app = try app_mod.App.init(std.testing.allocator, ".");
    defer app.deinit();
    _ = try app.documents.createScratch("demo.zig", "const x = 1;\n");

    var screen = try renderApp(std.testing.allocator, &app, 40, 12);
    defer screen.deinit();

    try std.testing.expectEqual(@as(u16, 40), screen.width);
}
