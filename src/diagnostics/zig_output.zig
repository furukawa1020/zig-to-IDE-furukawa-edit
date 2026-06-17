const std = @import("std");
const model = @import("model.zig");
const types = @import("../core/types.zig");

pub const ParsedLine = struct {
    path: []const u8,
    line: usize,
    column: usize,
    severity: types.Severity,
    message: []const u8,
};

pub fn parseLine(line: []const u8) ?ParsedLine {
    var parts = std.mem.splitScalar(u8, line, ':');
    const path = parts.next() orelse return null;
    const line_text = parts.next() orelse return null;
    const column_text = parts.next() orelse return null;
    const severity_text_raw = parts.next() orelse return null;
    const message_raw = parts.rest();

    const source_line = std.fmt.parseInt(usize, std.mem.trim(u8, line_text, " \t"), 10) catch return null;
    const source_column = std.fmt.parseInt(usize, std.mem.trim(u8, column_text, " \t"), 10) catch return null;
    const severity_text = std.mem.trim(u8, severity_text_raw, " \t");
    const severity: types.Severity = if (std.mem.eql(u8, severity_text, "error"))
        .err
    else if (std.mem.eql(u8, severity_text, "warning"))
        .warning
    else
        .info;

    return .{
        .path = path,
        .line = if (source_line == 0) 0 else source_line - 1,
        .column = if (source_column == 0) 0 else source_column - 1,
        .severity = severity,
        .message = std.mem.trim(u8, message_raw, " \t"),
    };
}

pub fn toDiagnostic(parsed: ParsedLine) model.Diagnostic {
    const position = types.Position{
        .line = parsed.line,
        .column = parsed.column,
        .byte_offset = 0,
    };
    return .{
        .source = .compiler,
        .severity = parsed.severity,
        .path = parsed.path,
        .range = types.Range.empty(position),
        .message = parsed.message,
    };
}

test "parse zig compiler style line" {
    const parsed = parseLine("src/main.zig:10:5: error: expected expression") orelse return error.ExpectedDiagnostic;
    try std.testing.expectEqualStrings("src/main.zig", parsed.path);
    try std.testing.expectEqual(@as(usize, 9), parsed.line);
    try std.testing.expectEqual(@as(usize, 4), parsed.column);
    try std.testing.expectEqual(types.Severity.err, parsed.severity);
    try std.testing.expectEqualStrings("expected expression", parsed.message);
}
