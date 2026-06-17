const std = @import("std");

pub const LayerId = enum {
    core,
    platform,
    terminal,
    ui,
    editor,
    workspace,
    language,
    diagnostics,
    build,
    tasks,
    search,
    config,
    persistence,
    debug_layer,
    git,
    security,
    observability,
};

pub const LayerSpec = struct {
    id: LayerId,
    owns: []const u8,
    may_call: []const LayerId,
};

const no_layers = [_]LayerId{};
const core_calls = [_]LayerId{ .editor, .workspace, .language, .diagnostics, .build, .tasks, .search, .config, .persistence, .security, .observability, .platform };
const ui_calls = [_]LayerId{ .core, .editor, .workspace, .diagnostics };
const editor_calls = [_]LayerId{ .persistence };
const workspace_calls = [_]LayerId{ .platform, .persistence, .security, .observability };
const language_calls = [_]LayerId{ .editor, .workspace };
const search_calls = [_]LayerId{ .workspace, .platform };
const build_calls = [_]LayerId{ .platform, .diagnostics, .security, .observability };
const tasks_calls = [_]LayerId{ .platform, .security, .observability };
const persistence_calls = [_]LayerId{ .platform, .security };
const debug_calls = [_]LayerId{ .platform, .build, .diagnostics, .security };
const git_calls = [_]LayerId{ .platform, .security, .observability };
const config_calls = [_]LayerId{ .persistence };

const specs = [_]LayerSpec{
    .{ .id = .platform, .owns = "OS APIs, filesystem, process, terminal capability", .may_call = no_layers[0..] },
    .{ .id = .security, .owns = "workspace trust, command permissions, path protection", .may_call = no_layers[0..] },
    .{ .id = .observability, .owns = "internal log, debug dump, command history", .may_call = no_layers[0..] },
    .{ .id = .persistence, .owns = "journal, cache, session, backup formats", .may_call = persistence_calls[0..] },
    .{ .id = .terminal, .owns = "ANSI renderer, raw input, screen buffer", .may_call = no_layers[0..] },
    .{ .id = .editor, .owns = "documents, buffers, cursor, selection, undo, save", .may_call = editor_calls[0..] },
    .{ .id = .workspace, .owns = "roots, file tree, watcher, sessions", .may_call = workspace_calls[0..] },
    .{ .id = .language, .owns = "Zig tokenizer/parser/AST/symbol/semantic plus file modes", .may_call = language_calls[0..] },
    .{ .id = .diagnostics, .owns = "diagnostic model and source mapping", .may_call = no_layers[0..] },
    .{ .id = .search, .owns = "literal, pattern, workspace, fuzzy search", .may_call = search_calls[0..] },
    .{ .id = .config, .owns = "config model, parser, keymap, theme settings", .may_call = config_calls[0..] },
    .{ .id = .build, .owns = "Zig toolchain, build/test/fmt/run integration", .may_call = build_calls[0..] },
    .{ .id = .tasks, .owns = "user task runner and process console", .may_call = tasks_calls[0..] },
    .{ .id = .debug_layer, .owns = "debug sessions, breakpoints, stepping views", .may_call = debug_calls[0..] },
    .{ .id = .git, .owns = "git status, diff, commit assistance", .may_call = git_calls[0..] },
    .{ .id = .core, .owns = "app state, event loop, command dispatch", .may_call = core_calls[0..] },
    .{ .id = .ui, .owns = "layout, views, widgets, render tree", .may_call = ui_calls[0..] },
};

pub fn layers() []const LayerSpec {
    return specs[0..];
}

pub fn layerName(id: LayerId) []const u8 {
    return switch (id) {
        .core => "core",
        .platform => "platform",
        .terminal => "terminal",
        .ui => "ui",
        .editor => "editor",
        .workspace => "workspace",
        .language => "language",
        .diagnostics => "diagnostics",
        .build => "build",
        .tasks => "tasks",
        .search => "search",
        .config => "config",
        .persistence => "persistence",
        .debug_layer => "debug",
        .git => "git",
        .security => "security",
        .observability => "observability",
    };
}

test "architecture lists all major layers" {
    try std.testing.expect(layers().len >= 16);
}
