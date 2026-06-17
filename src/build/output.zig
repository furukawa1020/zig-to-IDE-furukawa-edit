const diagnostics = @import("../diagnostics/collection.zig");
const sanitizer = @import("../security/output_sanitizer.zig");
const zig_output = @import("../diagnostics/zig_output.zig");
const console = @import("../tasks/console.zig");

pub fn appendOutput(
    process_console: *console.ProcessConsole,
    diagnostic_collection: *diagnostics.Collection,
    stream: console.Stream,
    bytes: []const u8,
) !void {
    try process_console.appendBytes(stream, bytes);

    var start: usize = 0;
    var i: usize = 0;
    while (i <= bytes.len) : (i += 1) {
        if (i == bytes.len or bytes[i] == '\n') {
            const raw_line = bytes[start..i];
            var sanitized = try sanitizer.sanitizeAlloc(process_console.allocator, trimRight(raw_line));
            defer sanitized.deinit(process_console.allocator);
            const line = sanitized.text;
            if (zig_output.parseLine(line)) |parsed| {
                try diagnostic_collection.append(zig_output.toDiagnostic(parsed));
            }
            start = i + 1;
        }
    }
}

fn trimRight(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and (line[end - 1] == '\r' or line[end - 1] == '\n')) : (end -= 1) {}
    return line[0..end];
}

test "build output extracts diagnostics" {
    var process_console = console.ProcessConsole.init(@import("std").testing.allocator);
    defer process_console.deinit();
    var diagnostic_collection = diagnostics.Collection.init(@import("std").testing.allocator);
    defer diagnostic_collection.deinit();

    try appendOutput(&process_console, &diagnostic_collection, .stderr, "src/main.zig:1:2: error: nope\n");
    try @import("std").testing.expectEqual(@as(usize, 1), process_console.lines.items.len);
    try @import("std").testing.expectEqual(@as(usize, 1), diagnostic_collection.items.items.len);
}
