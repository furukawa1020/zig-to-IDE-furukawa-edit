const std = @import("std");

pub const Scope = enum {
    editor,
    file,
    workspace,
    zig,
    view,
    task,
    demo,
};

pub const Capability = enum {
    safe,
    workspace_write,
    external_command,
};

pub const Definition = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    default_key: []const u8,
    scope: Scope,
    capability: Capability,
};

const definitions = [_]Definition{
    .{ .id = "file.open", .title = "Open File", .description = "Open a file in the workspace.", .default_key = "ctrl-o", .scope = .file, .capability = .safe },
    .{ .id = "file.save", .title = "Save File", .description = "Save the current buffer with atomic write.", .default_key = "ctrl-s", .scope = .file, .capability = .workspace_write },
    .{ .id = "editor.insert", .title = "Insert Text", .description = "Insert UTF-8 bytes into the current buffer.", .default_key = "", .scope = .editor, .capability = .safe },
    .{ .id = "editor.undo", .title = "Undo", .description = "Undo the last editing transaction.", .default_key = "ctrl-z", .scope = .editor, .capability = .safe },
    .{ .id = "editor.redo", .title = "Redo", .description = "Redo the last undone editing transaction.", .default_key = "ctrl-y", .scope = .editor, .capability = .safe },
    .{ .id = "workspace.search", .title = "Search Workspace", .description = "Search text across workspace files.", .default_key = "ctrl-f", .scope = .workspace, .capability = .safe },
    .{ .id = "workspace.find_file", .title = "Find File", .description = "Fuzzy-find a file in the workspace.", .default_key = "ctrl-p", .scope = .workspace, .capability = .safe },
    .{ .id = "zig.build", .title = "Zig Build", .description = "Run zig build for the current workspace.", .default_key = "ctrl-b", .scope = .zig, .capability = .external_command },
    .{ .id = "zig.test", .title = "Zig Test", .description = "Run Zig tests for the current context.", .default_key = "ctrl-t", .scope = .zig, .capability = .external_command },
    .{ .id = "zig.fmt", .title = "Zig Format", .description = "Format the current Zig file using zig fmt.", .default_key = "ctrl-alt-f", .scope = .zig, .capability = .external_command },
    .{ .id = "task.run", .title = "Run Task", .description = "Run a configured project task.", .default_key = "ctrl-r", .scope = .task, .capability = .external_command },
    .{ .id = "view.toggle_file_tree", .title = "Toggle File Tree", .description = "Show or hide the file tree.", .default_key = "ctrl-e", .scope = .view, .capability = .safe },
    .{ .id = "view.toggle_diagnostics", .title = "Toggle Diagnostics", .description = "Show or hide diagnostics.", .default_key = "ctrl-d", .scope = .view, .capability = .safe },
    .{ .id = "demo.run", .title = "Run Demo", .description = "Run an internal zide demo.", .default_key = "", .scope = .demo, .capability = .safe },
};

pub fn all() []const Definition {
    return definitions[0..];
}

pub fn findById(id: []const u8) ?Definition {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.id, id)) return definition;
    }
    return null;
}

pub fn fuzzyScore(query: []const u8, candidate: []const u8) ?u16 {
    if (query.len == 0) return 0;

    var q_index: usize = 0;
    var score: u16 = 0;
    var last_match: ?usize = null;

    for (candidate, 0..) |c, i| {
        if (q_index >= query.len) break;

        const qc = std.ascii.toLower(query[q_index]);
        const cc = std.ascii.toLower(c);
        if (qc != cc) continue;

        score += 2;
        if (i == 0) score += 8;
        if (i > 0 and isBoundary(candidate[i - 1])) score += 5;
        if (last_match) |last| {
            if (last + 1 == i) score += 4;
        }

        last_match = i;
        q_index += 1;
    }

    if (q_index == query.len) return score;
    return null;
}

fn isBoundary(c: u8) bool {
    return c == '.' or c == '_' or c == '-' or c == '/' or c == '\\' or std.ascii.isWhitespace(c);
}

test "find command by id" {
    const definition = findById("zig.build") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(Scope.zig, definition.scope);
}

test "fuzzy score prefers consecutive matches" {
    const compact = fuzzyScore("zb", "zig.build").?;
    const distant = fuzzyScore("zb", "workspace.zig.build").?;
    try std.testing.expect(compact >= distant);
}

