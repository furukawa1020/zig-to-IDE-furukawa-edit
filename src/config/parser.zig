const std = @import("std");
const model = @import("model.zig");

pub const ParseDiagnostic = struct {
    message: []const u8,
    offset: usize,
};

pub const ParseResult = struct {
    allocator: std.mem.Allocator,
    config: model.Config,
    diagnostics: []const ParseDiagnostic = &.{},
    owned_theme_name: ?[]u8 = null,

    pub fn deinit(self: *ParseResult) void {
        if (self.owned_theme_name) |name| self.allocator.free(name);
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

const Section = enum {
    root,
    editor,
    keymap,
    theme,
    task,
};

pub fn parseConfig(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var config = model.Config{};
    var owned_theme_name: ?[]u8 = null;
    errdefer {
        if (owned_theme_name) |name| allocator.free(name);
    }
    var diagnostics = std.ArrayList(ParseDiagnostic).init(allocator);
    errdefer diagnostics.deinit();

    var section: Section = .root;
    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var offset: usize = 0;

    while (line_iter.next()) |raw_line| {
        defer offset += raw_line.len + 1;

        const line_without_comment = stripComment(raw_line);
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.endsWith(u8, line, "{")) {
            section = sectionFor(std.mem.trim(u8, line[0 .. line.len - 1], " \t")) orelse blk: {
                try diagnostics.append(.{ .message = "unknown config section", .offset = offset });
                break :blk .root;
            };
            continue;
        }

        if (std.mem.eql(u8, line, "}")) {
            section = .root;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try diagnostics.append(.{ .message = "expected key = value", .offset = offset });
            continue;
        };

        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = trimValue(line[eq + 1 ..]);
        applyValue(allocator, &config, &owned_theme_name, section, key, value) catch {
            try diagnostics.append(.{ .message = "invalid config value", .offset = offset });
        };
    }

    return .{
        .allocator = allocator,
        .config = config,
        .diagnostics = try diagnostics.toOwnedSlice(),
        .owned_theme_name = owned_theme_name,
    };
}

fn stripComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
    const slash = std.mem.indexOf(u8, line, "//") orelse line.len;
    return line[0..@min(hash, slash)];
}

fn sectionFor(name: []const u8) ?Section {
    if (std.mem.eql(u8, name, "editor")) return .editor;
    if (std.mem.eql(u8, name, "keymap")) return .keymap;
    if (std.mem.eql(u8, name, "theme")) return .theme;
    if (std.mem.eql(u8, name, "task")) return .task;
    return null;
}

fn trimValue(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t\r,");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    return value;
}

fn applyValue(
    allocator: std.mem.Allocator,
    config: *model.Config,
    owned_theme_name: *?[]u8,
    section: Section,
    key: []const u8,
    value: []const u8,
) !void {
    switch (section) {
        .editor => {
            if (std.mem.eql(u8, key, "tab_width")) {
                config.editor.tab_width = try std.fmt.parseInt(u8, value, 10);
            } else if (std.mem.eql(u8, key, "insert_spaces")) {
                config.editor.insert_spaces = try parseBool(value);
            } else if (std.mem.eql(u8, key, "format_on_save")) {
                config.editor.format_on_save = try parseBool(value);
            } else {
                return error.UnknownField;
            }
        },
        .theme => {
            if (std.mem.eql(u8, key, "name")) {
                if (owned_theme_name.*) |old| allocator.free(old);
                const name = try allocator.dupe(u8, value);
                owned_theme_name.* = name;
                config.theme.name = name;
            } else {
                return error.UnknownField;
            }
        },
        else => return error.UnsupportedSection,
    }
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBool;
}

test "parse basic config" {
    var result = try parseConfig(std.testing.allocator,
        \\editor {
        \\  tab_width = 2
        \\  insert_spaces = false
        \\  format_on_save = true
        \\}
        \\
        \\theme {
        \\  name = "quiet"
        \\}
        \\
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 2), result.config.editor.tab_width);
    try std.testing.expect(!result.config.editor.insert_spaces);
    try std.testing.expect(result.config.editor.format_on_save);
    try std.testing.expectEqualStrings("quiet", result.config.theme.name);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
