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
    batch,
    c,
    cpp,
    objective_c,
    objective_cpp,
    assembly,
    go,
    rust,
    python,
    java,
    csharp,
    fsharp,
    php,
    ruby,
    lua,
    groovy,
    r,
    julia,
    perl,
    elixir,
    erlang,
    clojure,
    haskell,
    ocaml,
    nim,
    crystal,
    javascript,
    jsx,
    typescript,
    tsx,
    html,
    css,
    sql,
    graphql,
    proto,
    swift,
    kotlin,
    scala,
    dart,
    solidity,
    vue,
    svelte,
    cmake,
    ini,
    properties,
    csv,
    image,
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

pub const BlockComment = struct {
    start: []const u8,
    end: []const u8,
};

pub const RunProfile = struct {
    label: []const u8,
    command: []const u8,
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
    .batch,
    .c,
    .cpp,
    .objective_c,
    .objective_cpp,
    .assembly,
    .go,
    .rust,
    .python,
    .java,
    .csharp,
    .fsharp,
    .php,
    .ruby,
    .lua,
    .groovy,
    .r,
    .julia,
    .perl,
    .elixir,
    .erlang,
    .clojure,
    .haskell,
    .ocaml,
    .nim,
    .crystal,
    .javascript,
    .jsx,
    .typescript,
    .tsx,
    .html,
    .css,
    .sql,
    .graphql,
    .proto,
    .swift,
    .kotlin,
    .scala,
    .dart,
    .solidity,
    .vue,
    .svelte,
    .cmake,
    .ini,
    .properties,
    .csv,
    .image,
    .unknown,
};

pub fn all() []const LanguageMode {
    return all_modes[0..];
}

pub fn detect(path: []const u8) LanguageMode {
    const base = std.fs.path.basename(path);
    if (baseEquals(base, "build.zig")) return .zig;
    if (baseEquals(base, "build.zig.zon")) return .zon;
    if (baseEquals(base, "Makefile")) return .makefile;
    if (baseEquals(base, "CMakeLists.txt")) return .cmake;
    if (baseEquals(base, "Dockerfile")) return .dockerfile;
    if (startsWithIgnoreCase(base, "Dockerfile.")) return .dockerfile;
    if (baseEquals(base, "Jenkinsfile")) return .groovy;
    if (startsWithIgnoreCase(base, "Jenkinsfile.")) return .groovy;
    if (baseEquals(base, ".gitignore")) return .gitignore;
    if (baseEquals(base, ".env")) return .env;
    if (startsWithIgnoreCase(base, ".env.")) return .env;
    if (baseEquals(base, ".npmrc")) return .ini;
    if (baseEquals(base, ".editorconfig")) return .ini;
    if (baseEquals(base, "go.mod")) return .go;
    if (baseEquals(base, "go.sum")) return .text;
    if (baseEquals(base, "Cargo.toml")) return .toml;
    if (baseEquals(base, "Package.swift")) return .swift;
    if (baseEquals(base, "mix.exs")) return .elixir;
    if (baseEquals(base, "rebar.config")) return .erlang;
    if (baseEquals(base, "project.clj")) return .clojure;
    if (baseEquals(base, "pyproject.toml")) return .toml;
    if (baseEquals(base, "tsconfig.json")) return .json;
    if (baseEquals(base, "package-lock.json")) return .json;
    if (baseEquals(base, "pnpm-lock.yaml")) return .yaml;
    if (baseEquals(base, "docker-compose.yml")) return .yaml;
    if (baseEquals(base, "docker-compose.yaml")) return .yaml;
    if (baseEquals(base, "compose.yml")) return .yaml;
    if (baseEquals(base, "compose.yaml")) return .yaml;
    if (baseEquals(base, "terraform.tfvars")) return .hcl;

    const ext = std.fs.path.extension(base);
    if (extEquals(ext, ".zig")) return .zig;
    if (extEquals(ext, ".zon")) return .zon;
    if (extEquals(ext, ".md") or extEquals(ext, ".markdown")) return .markdown;
    if (extEquals(ext, ".txt")) return .text;
    if (extEquals(ext, ".json") or extEquals(ext, ".jsonc")) return .json;
    if (extEquals(ext, ".yaml") or extEquals(ext, ".yml")) return .yaml;
    if (extEquals(ext, ".toml")) return .toml;
    if (extEquals(ext, ".tf") or extEquals(ext, ".tfvars") or extEquals(ext, ".hcl")) return .hcl;
    if (extEquals(ext, ".xml") or extEquals(ext, ".xaml")) return .xml;
    if (extEquals(ext, ".ini") or extEquals(ext, ".cfg") or extEquals(ext, ".conf")) return .ini;
    if (extEquals(ext, ".properties")) return .properties;
    if (extEquals(ext, ".csv")) return .csv;
    if (extEquals(ext, ".png") or extEquals(ext, ".jpg") or extEquals(ext, ".jpeg") or extEquals(ext, ".gif") or extEquals(ext, ".webp") or extEquals(ext, ".bmp") or extEquals(ext, ".ico") or extEquals(ext, ".svg")) return .image;
    if (extEquals(ext, ".env")) return .env;
    if (extEquals(ext, ".sh") or extEquals(ext, ".bash") or extEquals(ext, ".zsh") or extEquals(ext, ".fish")) return .shell;
    if (extEquals(ext, ".ps1") or extEquals(ext, ".psm1")) return .powershell;
    if (extEquals(ext, ".bat") or extEquals(ext, ".cmd")) return .batch;
    if (extEquals(ext, ".c") or extEquals(ext, ".h")) return .c;
    if (extEquals(ext, ".m")) return .objective_c;
    if (extEquals(ext, ".mm")) return .objective_cpp;
    if (extEquals(ext, ".cpp") or extEquals(ext, ".cc") or extEquals(ext, ".cxx") or extEquals(ext, ".hpp") or extEquals(ext, ".hh") or extEquals(ext, ".hxx")) return .cpp;
    if (extEquals(ext, ".s") or extEquals(ext, ".asm")) return .assembly;
    if (std.mem.eql(u8, ext, ".S")) return .assembly;
    if (extEquals(ext, ".go")) return .go;
    if (extEquals(ext, ".rs")) return .rust;
    if (extEquals(ext, ".py") or extEquals(ext, ".pyw")) return .python;
    if (extEquals(ext, ".java")) return .java;
    if (extEquals(ext, ".cs")) return .csharp;
    if (extEquals(ext, ".fs") or extEquals(ext, ".fsx")) return .fsharp;
    if (extEquals(ext, ".php")) return .php;
    if (extEquals(ext, ".rb")) return .ruby;
    if (extEquals(ext, ".lua")) return .lua;
    if (extEquals(ext, ".groovy") or extEquals(ext, ".gradle")) return .groovy;
    if (extEquals(ext, ".r")) return .r;
    if (std.mem.eql(u8, ext, ".R")) return .r;
    if (extEquals(ext, ".jl")) return .julia;
    if (extEquals(ext, ".pl") or extEquals(ext, ".pm")) return .perl;
    if (extEquals(ext, ".ex") or extEquals(ext, ".exs")) return .elixir;
    if (extEquals(ext, ".erl") or extEquals(ext, ".hrl")) return .erlang;
    if (extEquals(ext, ".clj") or extEquals(ext, ".cljs") or extEquals(ext, ".cljc") or extEquals(ext, ".edn")) return .clojure;
    if (extEquals(ext, ".hs") or extEquals(ext, ".lhs")) return .haskell;
    if (extEquals(ext, ".ml") or extEquals(ext, ".mli")) return .ocaml;
    if (extEquals(ext, ".nim")) return .nim;
    if (extEquals(ext, ".cr")) return .crystal;
    if (extEquals(ext, ".js") or extEquals(ext, ".mjs") or extEquals(ext, ".cjs")) return .javascript;
    if (extEquals(ext, ".jsx")) return .jsx;
    if (extEquals(ext, ".ts")) return .typescript;
    if (extEquals(ext, ".tsx")) return .tsx;
    if (extEquals(ext, ".html") or extEquals(ext, ".htm")) return .html;
    if (extEquals(ext, ".css") or extEquals(ext, ".scss") or extEquals(ext, ".sass") or extEquals(ext, ".less")) return .css;
    if (extEquals(ext, ".sql")) return .sql;
    if (extEquals(ext, ".graphql") or extEquals(ext, ".gql")) return .graphql;
    if (extEquals(ext, ".proto")) return .proto;
    if (extEquals(ext, ".swift")) return .swift;
    if (extEquals(ext, ".kt") or extEquals(ext, ".kts")) return .kotlin;
    if (extEquals(ext, ".scala") or extEquals(ext, ".sc")) return .scala;
    if (extEquals(ext, ".dart")) return .dart;
    if (extEquals(ext, ".sol")) return .solidity;
    if (extEquals(ext, ".vue")) return .vue;
    if (extEquals(ext, ".svelte")) return .svelte;
    if (extEquals(ext, ".cmake")) return .cmake;
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

pub fn isHighlightable(mode: LanguageMode) bool {
    return isCode(mode) or family(mode) == .data or family(mode) == .config;
}

pub fn family(mode: LanguageMode) LanguageFamily {
    return switch (mode) {
        .zig, .zon => .zig,
        .c, .cpp, .objective_c, .objective_cpp, .assembly, .go, .rust, .java, .csharp, .fsharp, .swift, .kotlin, .scala, .haskell, .ocaml, .nim, .crystal, .solidity => .native,
        .shell, .powershell, .batch, .python, .php, .ruby, .lua, .groovy, .r, .julia, .perl, .elixir, .erlang, .clojure => .script,
        .javascript, .jsx, .typescript, .tsx, .html, .css, .dart, .vue, .svelte => .web,
        .json, .yaml, .toml, .hcl, .xml, .sql, .graphql, .proto, .csv, .image => .data,
        .env, .gitignore, .makefile, .dockerfile, .cmake, .ini, .properties => .config,
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
        .batch => "batch",
        .c => "c",
        .cpp => "cpp",
        .objective_c => "objective-c",
        .objective_cpp => "objective-c++",
        .assembly => "assembly",
        .go => "go",
        .rust => "rust",
        .python => "python",
        .java => "java",
        .csharp => "csharp",
        .fsharp => "fsharp",
        .php => "php",
        .ruby => "ruby",
        .lua => "lua",
        .groovy => "groovy",
        .r => "r",
        .julia => "julia",
        .perl => "perl",
        .elixir => "elixir",
        .erlang => "erlang",
        .clojure => "clojure",
        .haskell => "haskell",
        .ocaml => "ocaml",
        .nim => "nim",
        .crystal => "crystal",
        .javascript => "javascript",
        .jsx => "jsx",
        .typescript => "typescript",
        .tsx => "tsx",
        .html => "html",
        .css => "css",
        .sql => "sql",
        .graphql => "graphql",
        .proto => "proto",
        .swift => "swift",
        .kotlin => "kotlin",
        .scala => "scala",
        .dart => "dart",
        .solidity => "solidity",
        .vue => "vue",
        .svelte => "svelte",
        .cmake => "cmake",
        .ini => "ini",
        .properties => "properties",
        .csv => "csv",
        .image => "image",
        .unknown => "unknown",
    };
}

pub fn lineComment(mode: LanguageMode) ?[]const u8 {
    return switch (mode) {
        .zig, .c, .cpp, .objective_c, .objective_cpp, .go, .rust, .java, .csharp, .fsharp, .swift, .kotlin, .scala, .dart, .javascript, .jsx, .typescript, .tsx, .solidity, .proto => "//",
        .shell, .powershell, .python, .ruby, .r, .julia, .perl, .elixir, .yaml, .toml, .hcl, .dockerfile, .makefile, .cmake, .ini, .properties, .env, .gitignore => "#",
        .php => "//",
        .lua => "--",
        .sql => "--",
        .haskell => "--",
        .erlang => "%",
        .clojure => ";",
        .nim => "#",
        .crystal => "#",
        .assembly => ";",
        .batch => "REM",
        else => null,
    };
}

pub fn blockComment(mode: LanguageMode) ?BlockComment {
    return switch (mode) {
        .zig, .c, .cpp, .objective_c, .objective_cpp, .go, .rust, .java, .csharp, .fsharp, .swift, .kotlin, .scala, .dart, .javascript, .jsx, .typescript, .tsx, .css, .solidity, .sql, .php => .{ .start = "/*", .end = "*/" },
        .html, .xml, .vue, .svelte => .{ .start = "<!--", .end = "-->" },
        .haskell => .{ .start = "{-", .end = "-}" },
        .ocaml => .{ .start = "(*", .end = "*)" },
        else => null,
    };
}

pub fn runProfile(mode: LanguageMode) ?RunProfile {
    return switch (mode) {
        .zig => .{ .label = "zig", .command = "zig build run" },
        .c => .{ .label = "cc", .command = "cc file.c && ./a.out" },
        .cpp => .{ .label = "c++", .command = "c++ file.cpp && ./a.out" },
        .go => .{ .label = "go", .command = "go run ." },
        .rust => .{ .label = "cargo", .command = "cargo run" },
        .python => .{ .label = "python", .command = "python file.py" },
        .java => .{ .label = "java", .command = "javac/java" },
        .csharp, .fsharp => .{ .label = "dotnet", .command = "dotnet run" },
        .javascript, .jsx => .{ .label = "node", .command = "node file.js" },
        .typescript, .tsx => .{ .label = "ts", .command = "deno/tsx file.ts" },
        .shell => .{ .label = "sh", .command = "sh file.sh" },
        .powershell => .{ .label = "pwsh", .command = "pwsh file.ps1" },
        .batch => .{ .label = "cmd", .command = "cmd /c file.cmd" },
        .php => .{ .label = "php", .command = "php file.php" },
        .ruby => .{ .label = "ruby", .command = "ruby file.rb" },
        .lua => .{ .label = "lua", .command = "lua file.lua" },
        .r => .{ .label = "R", .command = "Rscript file.R" },
        .julia => .{ .label = "julia", .command = "julia file.jl" },
        .perl => .{ .label = "perl", .command = "perl file.pl" },
        .elixir => .{ .label = "mix", .command = "mix run" },
        .erlang => .{ .label = "rebar3", .command = "rebar3 shell" },
        .clojure => .{ .label = "clj", .command = "clj -M" },
        .haskell => .{ .label = "haskell", .command = "cabal run / runghc" },
        .ocaml => .{ .label = "ocaml", .command = "dune exec" },
        .nim => .{ .label = "nim", .command = "nim c -r file.nim" },
        .crystal => .{ .label = "crystal", .command = "crystal run file.cr" },
        .swift => .{ .label = "swift", .command = "swift run" },
        .kotlin => .{ .label = "kotlin", .command = "gradle run / kotlinc" },
        .scala => .{ .label = "scala", .command = "scala-cli / sbt run" },
        .dart => .{ .label = "dart", .command = "dart run" },
        .solidity => .{ .label = "solidity", .command = "forge test / solc" },
        .makefile => .{ .label = "make", .command = "make" },
        .dockerfile => .{ .label = "docker", .command = "docker build" },
        .cmake => .{ .label = "cmake", .command = "cmake --build" },
        .sql => .{ .label = "sql", .command = "sql client" },
        else => null,
    };
}

pub fn securityFocus(mode: LanguageMode) []const u8 {
    return switch (family(mode)) {
        .zig => "memory/build/deps",
        .native => "ffi/process/memory",
        .script => "exec/secrets/fs",
        .web => "eval/supply-chain/dom",
        .data => "schema/secrets/exposure",
        .config => "build/ci/container",
        .prose => "links/secrets",
        .unknown => "unknown",
    };
}

fn baseEquals(base: []const u8, value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(base, value);
}

fn extEquals(ext: []const u8, value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, value);
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
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

test "detect extended polyglot workspaces" {
    try std.testing.expectEqual(LanguageMode.elixir, detect("mix.exs"));
    try std.testing.expectEqual(LanguageMode.erlang, detect("src/app.erl"));
    try std.testing.expectEqual(LanguageMode.clojure, detect("project.clj"));
    try std.testing.expectEqual(LanguageMode.fsharp, detect("tool.fsx"));
    try std.testing.expectEqual(LanguageMode.haskell, detect("app/Main.hs"));
    try std.testing.expectEqual(LanguageMode.ocaml, detect("lib/main.ml"));
    try std.testing.expectEqual(LanguageMode.objective_c, detect("AppDelegate.m"));
    try std.testing.expectEqual(LanguageMode.objective_cpp, detect("Bridge.mm"));
    try std.testing.expectEqual(LanguageMode.assembly, detect("boot.S"));
    try std.testing.expectEqual(LanguageMode.nim, detect("main.nim"));
    try std.testing.expectEqual(LanguageMode.crystal, detect("server.cr"));
    try std.testing.expectEqual(LanguageMode.graphql, detect("schema.graphql"));
    try std.testing.expectEqual(LanguageMode.proto, detect("service.proto"));
    try std.testing.expectEqual(LanguageMode.solidity, detect("Token.sol"));
    try std.testing.expectEqual(LanguageMode.cmake, detect("CMakeLists.txt"));
    try std.testing.expectEqual(LanguageMode.batch, detect("build.cmd"));
    try std.testing.expectEqual(LanguageMode.image, detect("site/ogp.png"));
    try std.testing.expectEqual(LanguageMode.image, detect("logo.svg"));
}

test "language profiles expose editor affordances" {
    try std.testing.expectEqualStrings("#", lineComment(.python).?);
    try std.testing.expectEqualStrings("//", lineComment(.typescript).?);
    try std.testing.expectEqualStrings("<!--", blockComment(.html).?.start);
    try std.testing.expectEqualStrings("cargo", runProfile(.rust).?.label);
    try std.testing.expect(std.mem.indexOf(u8, securityFocus(.javascript), "eval") != null);
}
