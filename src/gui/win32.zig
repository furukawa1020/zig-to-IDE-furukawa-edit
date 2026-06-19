const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const app_mod = @import("../core/app.zig");
const workspace_mod = @import("../workspace/workspace.zig");

pub fn run(allocator: std.mem.Allocator, root_path: []const u8) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    var state = try GuiState.init(allocator, root_path);
    defer state.deinit();
    global_state = &state;
    defer global_state = null;

    const hmodule = GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;
    const hinstance: windows.HINSTANCE = @ptrCast(hmodule);

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zide.gui.window");
    const title = std.unicode.utf8ToUtf16LeStringLiteral("zide");

    const window_class = WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = CS_HREDRAW | CS_VREDRAW,
        .lpfnWndProc = windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };

    if (RegisterClassExW(&window_class) == 0) return error.RegisterClassFailed;

    const hwnd = CreateWindowExW(
        0,
        class_name,
        title,
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        1180,
        760,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    state.hwnd = hwnd;

    _ = ShowWindow(hwnd, SW_SHOW);
    _ = UpdateWindow(hwnd);

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) != .FALSE) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

const GuiState = struct {
    allocator: std.mem.Allocator,
    app: app_mod.App,
    hwnd: ?windows.HWND = null,
    last_error: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, root_path: []const u8) !GuiState {
        return .{
            .allocator = allocator,
            .app = try app_mod.App.init(allocator, root_path),
        };
    }

    fn deinit(self: *GuiState) void {
        if (self.last_error) |message| self.allocator.free(message);
        self.app.deinit();
    }

    fn moveSelection(self: *GuiState, delta: isize) void {
        self.app.moveFileCursor(delta);
    }

    fn openSelected(self: *GuiState) void {
        const opened = self.app.openSelectedWorkspaceEntry() catch |err| {
            self.setError(err) catch {};
            return;
        };
        if (!opened) {
            self.setMessage("Select a file to open") catch {};
        } else {
            self.clearError();
        }
    }

    fn setError(self: *GuiState, err: anyerror) !void {
        var buffer: [160]u8 = undefined;
        const message = try std.fmt.bufPrint(&buffer, "error: {s}", .{@errorName(err)});
        try self.setMessage(message);
    }

    fn setMessage(self: *GuiState, message: []const u8) !void {
        self.clearError();
        self.last_error = try self.allocator.dupe(u8, message);
    }

    fn clearError(self: *GuiState) void {
        if (self.last_error) |message| {
            self.allocator.free(message);
            self.last_error = null;
        }
    }
};

var global_state: ?*GuiState = null;

fn windowProc(hwnd: windows.HWND, msg: windows.UINT, wparam: windows.WPARAM, lparam: windows.LPARAM) callconv(.winapi) windows.LRESULT {
    switch (msg) {
        WM_KEYDOWN => {
            if (global_state) |state| {
                switch (wparam) {
                    VK_UP => state.moveSelection(-1),
                    VK_DOWN => state.moveSelection(1),
                    VK_RETURN => state.openSelected(),
                    VK_ESCAPE, 'Q' => DestroyWindow(hwnd),
                    'J' => state.moveSelection(1),
                    'K' => state.moveSelection(-1),
                    else => {},
                }
                _ = InvalidateRect(hwnd, null, .FALSE);
            }
            return 0;
        },
        WM_PAINT => {
            paint(hwnd);
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn paint(hwnd: windows.HWND) void {
    var ps: PAINTSTRUCT = undefined;
    const hdc = BeginPaint(hwnd, &ps);
    defer _ = EndPaint(hwnd, &ps);

    var client: RECT = undefined;
    _ = GetClientRect(hwnd, &client);

    fillRect(hdc, client, rgb(12, 15, 18));

    const width = client.right - client.left;
    const height = client.bottom - client.top;
    const sidebar_width = @min(@max(@divTrunc(width, 4), 280), 380);
    const status_height: c_int = 30;
    const header_height: c_int = 42;
    const gutter_width: c_int = 58;

    const sidebar = RECT{ .left = 0, .top = 0, .right = sidebar_width, .bottom = height - status_height };
    const editor = RECT{ .left = sidebar_width, .top = 0, .right = width, .bottom = height - status_height };
    const status = RECT{ .left = 0, .top = height - status_height, .right = width, .bottom = height };

    fillRect(hdc, sidebar, rgb(15, 20, 24));
    fillRect(hdc, editor, rgb(11, 13, 17));
    fillRect(hdc, status, rgb(35, 142, 203));
    fillRect(hdc, RECT{ .left = sidebar_width - 1, .top = 0, .right = sidebar_width, .bottom = height - status_height }, rgb(43, 53, 61));

    if (global_state) |state| {
        drawText(hdc, 18, 15, rgb(79, 230, 226), "FILES");
        drawFileList(hdc, state, sidebar, header_height);
        drawEditor(hdc, state, editor, header_height, gutter_width);
        drawStatus(hdc, state, status);
    } else {
        drawText(hdc, 24, 24, rgb(235, 238, 242), "zide");
    }
}

fn drawFileList(hdc: windows.HDC, state: *GuiState, sidebar: RECT, header_height: c_int) void {
    const row_height: c_int = 22;
    const visible_rows = @max(0, @divTrunc(sidebar.bottom - header_height - 10, row_height));
    const selected = if (state.app.workspace.entries.items.len == 0) 0 else @min(state.app.file_cursor, state.app.workspace.entries.items.len - 1);
    const start = scrollStart(selected, state.app.workspace.entries.items.len, @intCast(visible_rows));

    var y = header_height;
    var row: usize = 0;
    while (row < @as(usize, @intCast(visible_rows)) and start + row < state.app.workspace.entries.items.len) : (row += 1) {
        const index = start + row;
        const entry = state.app.workspace.entries.items[index];
        const selected_row = index == selected;
        if (selected_row) {
            fillRect(hdc, RECT{ .left = 0, .top = y - 1, .right = sidebar.right - 1, .bottom = y + row_height - 1 }, rgb(51, 153, 235));
        }

        const indent: c_int = @intCast(@min(entry.depth, 8) * 16);
        const marker = switch (entry.kind) {
            .directory => "+ ",
            .file => "  ",
            .other => "? ",
        };
        const color = if (selected_row)
            rgb(18, 20, 22)
        else switch (entry.kind) {
            .directory => rgb(229, 232, 236),
            .file => if (entry.language == .zig) rgb(63, 217, 84) else rgb(205, 211, 217),
            .other => rgb(121, 133, 145),
        };

        drawText(hdc, 16 + indent, y + 3, color, marker);
        drawTextClipped(hdc, 36 + indent, y + 3, sidebar.right - 12, color, entry.path);
        y += row_height;
    }

    if (state.app.workspace.entries.items.len == 0) {
        drawText(hdc, 18, header_height + 4, rgb(140, 148, 158), "No files found");
    }
}

fn drawEditor(hdc: windows.HDC, state: *GuiState, editor: RECT, header_height: c_int, gutter_width: c_int) void {
    const active = state.app.documents.active();
    if (active) |doc| {
        const title = doc.path orelse "untitled";
        drawTextClipped(hdc, editor.left + 20, 15, editor.right - 24, rgb(79, 230, 226), title);
        fillRect(hdc, RECT{ .left = editor.left, .top = header_height, .right = editor.left + gutter_width, .bottom = editor.bottom }, rgb(14, 18, 23));

        const row_height: c_int = 22;
        const max_rows = @max(0, @divTrunc(editor.bottom - header_height - 8, row_height));
        var line: usize = 0;
        var y = header_height + 7;
        while (line < @as(usize, @intCast(max_rows)) and line < doc.text.lineCount()) : (line += 1) {
            var number_buf: [32]u8 = undefined;
            const number = std.fmt.bufPrint(&number_buf, "{d}", .{line + 1}) catch "";
            drawTextRight(hdc, editor.left + 10, y, editor.left + gutter_width - 12, rgb(105, 116, 128), number);
            drawTextClipped(hdc, editor.left + gutter_width + 16, y, editor.right - 20, rgb(224, 229, 235), doc.text.lineSlice(line));
            y += row_height;
        }
    } else {
        drawText(hdc, editor.left + 22, 15, rgb(79, 230, 226), "zide workbench");
        drawText(hdc, editor.left + 22, header_height + 10, rgb(199, 206, 214), "Select a file and press Enter.");
        drawText(hdc, editor.left + 22, header_height + 38, rgb(126, 138, 150), "Use Up/Down or j/k. Press q or Esc to close.");
    }
}

fn drawStatus(hdc: windows.HDC, state: *GuiState, status: RECT) void {
    var buffer: [512]u8 = undefined;
    const mode = @tagName(state.app.mode);
    const focus = @tagName(state.app.focus);
    const message = state.last_error orelse "ready";
    const text = std.fmt.bufPrint(
        &buffer,
        " {s}/{s}  |  files:{d}  docs:{d}  zig:{d}  |  {s}",
        .{
            mode,
            focus,
            state.app.workspace.entries.items.len,
            state.app.documents.documents.items.len,
            state.app.workspace.countZigFamily(),
            message,
        },
    ) catch "zide";
    drawTextClipped(hdc, status.left + 8, status.top + 7, status.right - 8, rgb(22, 31, 38), text);
}

fn scrollStart(selected: usize, total: usize, visible: usize) usize {
    if (total <= visible or visible == 0) return 0;
    const half = visible / 2;
    if (selected <= half) return 0;
    const max_start = total - visible;
    return @min(selected - half, max_start);
}

fn drawText(hdc: windows.HDC, x: c_int, y: c_int, color: windows.COLORREF, text: []const u8) void {
    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetTextColor(hdc, color);
    if (text.len == 0) return;
    _ = TextOutA(hdc, x, y, text.ptr, @intCast(text.len));
}

fn drawTextClipped(hdc: windows.HDC, x: c_int, y: c_int, right: c_int, color: windows.COLORREF, text: []const u8) void {
    if (right <= x) return;
    const available_columns: usize = @intCast(@max(@divTrunc(right - x, 8), 1));
    const clipped = if (text.len > available_columns) text[0..available_columns] else text;
    drawText(hdc, x, y, color, clipped);
}

fn drawTextRight(hdc: windows.HDC, left: c_int, y: c_int, right: c_int, color: windows.COLORREF, text: []const u8) void {
    const width: c_int = @intCast(text.len * 8);
    drawText(hdc, @max(left, right - width), y, color, text);
}

fn fillRect(hdc: windows.HDC, rect: RECT, color: windows.COLORREF) void {
    const brush = CreateSolidBrush(color) orelse return;
    defer _ = DeleteObject(@ptrCast(brush));
    var mutable = rect;
    _ = FillRect(hdc, &mutable, brush);
}

fn rgb(r: u8, g: u8, b: u8) windows.COLORREF {
    return @as(windows.COLORREF, r) | (@as(windows.COLORREF, g) << 8) | (@as(windows.COLORREF, b) << 16);
}

const RECT = extern struct {
    left: c_int,
    top: c_int,
    right: c_int,
    bottom: c_int,
};

const POINT = extern struct {
    x: c_long,
    y: c_long,
};

const MSG = extern struct {
    hwnd: ?windows.HWND,
    message: windows.UINT,
    wParam: windows.WPARAM,
    lParam: windows.LPARAM,
    time: windows.DWORD,
    pt: POINT,
};

const PAINTSTRUCT = extern struct {
    hdc: windows.HDC,
    fErase: windows.BOOL,
    rcPaint: RECT,
    fRestore: windows.BOOL,
    fIncUpdate: windows.BOOL,
    rgbReserved: [32]u8,
};

const WNDPROC = *const fn (windows.HWND, windows.UINT, windows.WPARAM, windows.LPARAM) callconv(.winapi) windows.LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: windows.UINT,
    style: windows.UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: windows.HINSTANCE,
    hIcon: ?windows.HICON,
    hCursor: ?windows.HCURSOR,
    hbrBackground: ?windows.HBRUSH,
    lpszMenuName: ?windows.LPCWSTR,
    lpszClassName: windows.LPCWSTR,
    hIconSm: ?windows.HICON,
};

const HGDIOBJ = *opaque {};

const CS_HREDRAW: windows.UINT = 0x0002;
const CS_VREDRAW: windows.UINT = 0x0001;
const CW_USEDEFAULT: c_int = -2147483648;
const IDC_ARROW: windows.LPCWSTR = @ptrFromInt(32512);
const SW_SHOW: c_int = 5;
const TRANSPARENT: c_int = 1;
const WS_OVERLAPPEDWINDOW: windows.DWORD = 0x00CF0000;

const WM_DESTROY: windows.UINT = 0x0002;
const WM_PAINT: windows.UINT = 0x000F;
const WM_KEYDOWN: windows.UINT = 0x0100;
const VK_RETURN: windows.WPARAM = 0x0D;
const VK_ESCAPE: windows.WPARAM = 0x1B;
const VK_UP: windows.WPARAM = 0x26;
const VK_DOWN: windows.WPARAM = 0x28;

extern "kernel32" fn GetModuleHandleW(lpModuleName: ?windows.LPCWSTR) callconv(.winapi) ?windows.HMODULE;

extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) windows.ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: windows.DWORD,
    lpClassName: windows.LPCWSTR,
    lpWindowName: windows.LPCWSTR,
    dwStyle: windows.DWORD,
    x: c_int,
    y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?windows.HWND,
    hMenu: ?windows.HMENU,
    hInstance: windows.HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?windows.HWND;
extern "user32" fn DefWindowProcW(hWnd: windows.HWND, Msg: windows.UINT, wParam: windows.WPARAM, lParam: windows.LPARAM) callconv(.winapi) windows.LRESULT;
extern "user32" fn DestroyWindow(hWnd: windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn ShowWindow(hWnd: windows.HWND, nCmdShow: c_int) callconv(.winapi) windows.BOOL;
extern "user32" fn UpdateWindow(hWnd: windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?windows.HWND, wMsgFilterMin: windows.UINT, wMsgFilterMax: windows.UINT) callconv(.winapi) windows.BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) windows.BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) windows.LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
extern "user32" fn BeginPaint(hWnd: windows.HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) windows.HDC;
extern "user32" fn EndPaint(hWnd: windows.HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) windows.BOOL;
extern "user32" fn InvalidateRect(hWnd: windows.HWND, lpRect: ?*const RECT, bErase: windows.BOOL) callconv(.winapi) windows.BOOL;
extern "user32" fn GetClientRect(hWnd: windows.HWND, lpRect: *RECT) callconv(.winapi) windows.BOOL;
extern "user32" fn LoadCursorW(hInstance: ?windows.HINSTANCE, lpCursorName: windows.LPCWSTR) callconv(.winapi) ?windows.HCURSOR;
extern "user32" fn FillRect(hDC: windows.HDC, lprc: *const RECT, hbr: windows.HBRUSH) callconv(.winapi) c_int;

extern "gdi32" fn SetTextColor(hdc: windows.HDC, crColor: windows.COLORREF) callconv(.winapi) windows.COLORREF;
extern "gdi32" fn SetBkMode(hdc: windows.HDC, mode: c_int) callconv(.winapi) c_int;
extern "gdi32" fn TextOutA(hdc: windows.HDC, x: c_int, y: c_int, lpString: [*]const u8, c: c_int) callconv(.winapi) windows.BOOL;
extern "gdi32" fn CreateSolidBrush(color: windows.COLORREF) callconv(.winapi) ?windows.HBRUSH;
extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(.winapi) windows.BOOL;
