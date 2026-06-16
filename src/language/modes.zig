const std = @import("std");

pub const LanguageMode = enum {
    zig,
    zon,
    markdown,
    text,
    json,
    env,
    gitignore,
    makefile,
    shell,
    c,
    cpp,
    rust,
    python,
    javascript,
    typescript,
    html,
    css,
    unknown,
};

const all_modes = [_]LanguageMode{
    .zig,
    .zon,
    .markdown,
    .text,
    .json,
    .env,
    .gitignore,
    .makefile,
    .shell,
    .c,
    .cpp,
    .rust,
    .python,
    .javascript,
    .typescript,
    .html,
    .css,
    .unknown,
};

pub fn all() []const LanguageMode {
    return all_modes[0..];
}

pub fn detect(path: []const u8) LanguageMode {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "build.zig")) return .zig;
    if (std.mem.eql(u8, base, "build.zig.zon")) return .zon;
    if (std.mem.eql(u8, base, "Makefile")) return .makefile;
    if (std.mem.eql(u8, base, ".gitignore")) return .gitignore;
    if (std.mem.eql(u8, base, ".env")) return .env;

    const ext = std.fs.path.extension(base);
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".zon")) return .zon;
    if (std.mem.eql(u8, ext, ".md")) return .markdown;
    if (std.mem.eql(u8, ext, ".txt")) return .text;
    if (std.mem.eql(u8, ext, ".json")) return .json;
    if (std.mem.eql(u8, ext, ".env")) return .env;
    if (std.mem.eql(u8, ext, ".sh")) return .shell;
    if (std.mem.eql(u8, ext, ".bash")) return .shell;
    if (std.mem.eql(u8, ext, ".zsh")) return .shell;
    if (std.mem.eql(u8, ext, ".c")) return .c;
    if (std.mem.eql(u8, ext, ".h")) return .c;
    if (std.mem.eql(u8, ext, ".cpp")) return .cpp;
    if (std.mem.eql(u8, ext, ".hpp")) return .cpp;
    if (std.mem.eql(u8, ext, ".rs")) return .rust;
    if (std.mem.eql(u8, ext, ".py")) return .python;
    if (std.mem.eql(u8, ext, ".js")) return .javascript;
    if (std.mem.eql(u8, ext, ".ts")) return .typescript;
    if (std.mem.eql(u8, ext, ".html")) return .html;
    if (std.mem.eql(u8, ext, ".css")) return .css;
    return .unknown;
}

pub fn isZigFamily(mode: LanguageMode) bool {
    return mode == .zig or mode == .zon;
}

pub fn label(mode: LanguageMode) []const u8 {
    return switch (mode) {
        .zig => "zig",
        .zon => "zon",
        .markdown => "markdown",
        .text => "text",
        .json => "json",
        .env => "env",
        .gitignore => "gitignore",
        .makefile => "makefile",
        .shell => "shell",
        .c => "c",
        .cpp => "cpp",
        .rust => "rust",
        .python => "python",
        .javascript => "javascript",
        .typescript => "typescript",
        .html => "html",
        .css => "css",
        .unknown => "unknown",
    };
}

test "detect Zig and non-Zig files" {
    try std.testing.expectEqual(LanguageMode.zig, detect("src/main.zig"));
    try std.testing.expectEqual(LanguageMode.markdown, detect("README.md"));
    try std.testing.expectEqual(LanguageMode.python, detect("demo.py"));
}

