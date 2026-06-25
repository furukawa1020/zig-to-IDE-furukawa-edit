const std = @import("std");

pub const LanguageMode = enum {
    zig,
    zon,
    markdown,
    text,
    json,
    yaml,
    toml,
    hcl,
    xml,
    env,
    gitignore,
    makefile,
    dockerfile,
    shell,
    powershell,
    c,
    cpp,
    go,
    rust,
    python,
    java,
    csharp,
    php,
    ruby,
    lua,
    groovy,
    javascript,
    jsx,
    typescript,
    tsx,
    html,
    css,
    sql,
    swift,
    kotlin,
    scala,
    dart,
    vue,
    svelte,
    unknown,
};

pub const LanguageFamily = enum {
    zig,
    native,
    script,
    web,
    data,
    config,
    prose,
    unknown,
};

const all_modes = [_]LanguageMode{
    .zig,
    .zon,
    .markdown,
    .text,
    .json,
    .yaml,
    .toml,
    .hcl,
    .xml,
    .env,
    .gitignore,
    .makefile,
    .dockerfile,
    .shell,
    .powershell,
    .c,
    .cpp,
    .go,
    .rust,
    .python,
    .java,
    .csharp,
    .php,
    .ruby,
    .lua,
    .groovy,
    .javascript,
    .jsx,
    .typescript,
    .tsx,
    .html,
    .css,
    .sql,
    .swift,
    .kotlin,
    .scala,
    .dart,
    .vue,
    .svelte,
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
    if (std.mem.eql(u8, base, "Dockerfile")) return .dockerfile;
    if (std.mem.startsWith(u8, base, "Dockerfile.")) return .dockerfile;
    if (std.mem.eql(u8, base, "Jenkinsfile")) return .groovy;
    if (std.mem.startsWith(u8, base, "Jenkinsfile.")) return .groovy;
    if (std.mem.eql(u8, base, ".gitignore")) return .gitignore;
    if (std.mem.eql(u8, base, ".env")) return .env;
    if (std.mem.startsWith(u8, base, ".env.")) return .env;
    if (std.mem.eql(u8, base, "go.mod")) return .go;
    if (std.mem.eql(u8, base, "go.sum")) return .text;
    if (std.mem.eql(u8, base, "Cargo.toml")) return .toml;
    if (std.mem.eql(u8, base, "pyproject.toml")) return .toml;
    if (std.mem.eql(u8, base, "tsconfig.json")) return .json;
    if (std.mem.eql(u8, base, "docker-compose.yml")) return .yaml;
    if (std.mem.eql(u8, base, "docker-compose.yaml")) return .yaml;
    if (std.mem.eql(u8, base, "terraform.tfvars")) return .hcl;

    const ext = std.fs.path.extension(base);
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".zon")) return .zon;
    if (std.mem.eql(u8, ext, ".md")) return .markdown;
    if (std.mem.eql(u8, ext, ".txt")) return .text;
    if (std.mem.eql(u8, ext, ".json")) return .json;
    if (std.mem.eql(u8, ext, ".yaml")) return .yaml;
    if (std.mem.eql(u8, ext, ".yml")) return .yaml;
    if (std.mem.eql(u8, ext, ".toml")) return .toml;
    if (std.mem.eql(u8, ext, ".tf")) return .hcl;
    if (std.mem.eql(u8, ext, ".tfvars")) return .hcl;
    if (std.mem.eql(u8, ext, ".hcl")) return .hcl;
    if (std.mem.eql(u8, ext, ".xml")) return .xml;
    if (std.mem.eql(u8, ext, ".env")) return .env;
    if (std.mem.eql(u8, ext, ".sh")) return .shell;
    if (std.mem.eql(u8, ext, ".bash")) return .shell;
    if (std.mem.eql(u8, ext, ".zsh")) return .shell;
    if (std.mem.eql(u8, ext, ".ps1")) return .powershell;
    if (std.mem.eql(u8, ext, ".psm1")) return .powershell;
    if (std.mem.eql(u8, ext, ".c")) return .c;
    if (std.mem.eql(u8, ext, ".h")) return .c;
    if (std.mem.eql(u8, ext, ".cpp")) return .cpp;
    if (std.mem.eql(u8, ext, ".cc")) return .cpp;
    if (std.mem.eql(u8, ext, ".cxx")) return .cpp;
    if (std.mem.eql(u8, ext, ".hpp")) return .cpp;
    if (std.mem.eql(u8, ext, ".go")) return .go;
    if (std.mem.eql(u8, ext, ".rs")) return .rust;
    if (std.mem.eql(u8, ext, ".py")) return .python;
    if (std.mem.eql(u8, ext, ".java")) return .java;
    if (std.mem.eql(u8, ext, ".cs")) return .csharp;
    if (std.mem.eql(u8, ext, ".php")) return .php;
    if (std.mem.eql(u8, ext, ".rb")) return .ruby;
    if (std.mem.eql(u8, ext, ".lua")) return .lua;
    if (std.mem.eql(u8, ext, ".groovy")) return .groovy;
    if (std.mem.eql(u8, ext, ".gradle")) return .groovy;
    if (std.mem.eql(u8, ext, ".js")) return .javascript;
    if (std.mem.eql(u8, ext, ".mjs")) return .javascript;
    if (std.mem.eql(u8, ext, ".cjs")) return .javascript;
    if (std.mem.eql(u8, ext, ".jsx")) return .jsx;
    if (std.mem.eql(u8, ext, ".ts")) return .typescript;
    if (std.mem.eql(u8, ext, ".tsx")) return .tsx;
    if (std.mem.eql(u8, ext, ".html")) return .html;
    if (std.mem.eql(u8, ext, ".htm")) return .html;
    if (std.mem.eql(u8, ext, ".css")) return .css;
    if (std.mem.eql(u8, ext, ".scss")) return .css;
    if (std.mem.eql(u8, ext, ".sql")) return .sql;
    if (std.mem.eql(u8, ext, ".swift")) return .swift;
    if (std.mem.eql(u8, ext, ".kt")) return .kotlin;
    if (std.mem.eql(u8, ext, ".kts")) return .kotlin;
    if (std.mem.eql(u8, ext, ".scala")) return .scala;
    if (std.mem.eql(u8, ext, ".dart")) return .dart;
    if (std.mem.eql(u8, ext, ".vue")) return .vue;
    if (std.mem.eql(u8, ext, ".svelte")) return .svelte;
    return .unknown;
}

pub fn isZigFamily(mode: LanguageMode) bool {
    return mode == .zig or mode == .zon;
}

pub fn isRecognized(mode: LanguageMode) bool {
    return mode != .unknown;
}

pub fn isCode(mode: LanguageMode) bool {
    return switch (family(mode)) {
        .zig, .native, .script, .web => true,
        else => false,
    };
}

pub fn family(mode: LanguageMode) LanguageFamily {
    return switch (mode) {
        .zig, .zon => .zig,
        .c, .cpp, .go, .rust, .java, .csharp, .swift, .kotlin, .scala => .native,
        .shell, .powershell, .python, .php, .ruby, .lua, .groovy => .script,
        .javascript, .jsx, .typescript, .tsx, .html, .css, .dart, .vue, .svelte => .web,
        .json, .yaml, .toml, .hcl, .xml, .sql => .data,
        .env, .gitignore, .makefile, .dockerfile => .config,
        .markdown, .text => .prose,
        .unknown => .unknown,
    };
}

pub fn label(mode: LanguageMode) []const u8 {
    return switch (mode) {
        .zig => "zig",
        .zon => "zon",
        .markdown => "markdown",
        .text => "text",
        .json => "json",
        .yaml => "yaml",
        .toml => "toml",
        .hcl => "hcl",
        .xml => "xml",
        .env => "env",
        .gitignore => "gitignore",
        .makefile => "makefile",
        .dockerfile => "dockerfile",
        .shell => "shell",
        .powershell => "powershell",
        .c => "c",
        .cpp => "cpp",
        .go => "go",
        .rust => "rust",
        .python => "python",
        .java => "java",
        .csharp => "csharp",
        .php => "php",
        .ruby => "ruby",
        .lua => "lua",
        .groovy => "groovy",
        .javascript => "javascript",
        .jsx => "jsx",
        .typescript => "typescript",
        .tsx => "tsx",
        .html => "html",
        .css => "css",
        .sql => "sql",
        .swift => "swift",
        .kotlin => "kotlin",
        .scala => "scala",
        .dart => "dart",
        .vue => "vue",
        .svelte => "svelte",
        .unknown => "unknown",
    };
}

test "detect Zig and non-Zig files" {
    try std.testing.expectEqual(LanguageMode.zig, detect("src/main.zig"));
    try std.testing.expectEqual(LanguageMode.markdown, detect("README.md"));
    try std.testing.expectEqual(LanguageMode.python, detect("demo.py"));
    try std.testing.expectEqual(LanguageMode.go, detect("go.mod"));
    try std.testing.expectEqual(LanguageMode.dockerfile, detect("Dockerfile.prod"));
    try std.testing.expectEqual(LanguageMode.hcl, detect("infra/main.tf"));
    try std.testing.expectEqual(LanguageMode.hcl, detect("terraform.tfvars"));
    try std.testing.expectEqual(LanguageMode.groovy, detect("Jenkinsfile"));
    try std.testing.expectEqual(LanguageMode.groovy, detect("build.gradle"));
    try std.testing.expectEqual(LanguageMode.powershell, detect("tools/install.ps1"));
    try std.testing.expectEqual(LanguageMode.tsx, detect("frontend/App.tsx"));
    try std.testing.expectEqual(LanguageFamily.web, family(.typescript));
}
