const std = @import("std");
const modes = @import("../language/modes.zig");

pub const Server = struct {
    label: []const u8,
    executable: []const u8,
    args: []const []const u8 = &.{},
    install_hint: []const u8,
    security_note: []const u8 = "external language server; launch requires explicit consent",
};

pub fn serverForLanguage(mode: modes.LanguageMode) ?Server {
    return switch (mode) {
        .zig, .zon => .{
            .label = "ZLS",
            .executable = "zls",
            .install_hint = "Install zls and keep it on PATH.",
        },
        .rust => .{
            .label = "rust-analyzer",
            .executable = "rust-analyzer",
            .install_hint = "Install rust-analyzer with rustup or your package manager.",
        },
        .python => .{
            .label = "python-lsp-server",
            .executable = "pylsp",
            .install_hint = "Install python-lsp-server in the workspace environment.",
        },
        .typescript, .tsx, .javascript, .jsx => .{
            .label = "TypeScript Language Server",
            .executable = "typescript-language-server",
            .args = &.{"--stdio"},
            .install_hint = "Install typescript-language-server and typescript.",
        },
        .go => .{
            .label = "gopls",
            .executable = "gopls",
            .install_hint = "Install gopls with go install golang.org/x/tools/gopls@latest.",
        },
        .c, .cpp, .objective_c, .objective_cpp => .{
            .label = "clangd",
            .executable = "clangd",
            .install_hint = "Install clangd and provide compile_commands.json when possible.",
        },
        .java => .{
            .label = "JDT LS",
            .executable = "jdtls",
            .install_hint = "Install Eclipse JDT Language Server.",
        },
        .csharp, .fsharp => .{
            .label = "OmniSharp",
            .executable = "omnisharp",
            .install_hint = "Install OmniSharp or a compatible .NET language server.",
        },
        .php => .{
            .label = "Intelephense",
            .executable = "intelephense",
            .args = &.{"--stdio"},
            .install_hint = "Install intelephense.",
        },
        .ruby => .{
            .label = "Solargraph",
            .executable = "solargraph",
            .args = &.{"stdio"},
            .install_hint = "Install solargraph.",
        },
        .lua => .{
            .label = "lua-language-server",
            .executable = "lua-language-server",
            .install_hint = "Install lua-language-server.",
        },
        .html, .css, .json => .{
            .label = "vscode-langservers-extracted",
            .executable = extractedServerExecutable(mode),
            .args = &.{"--stdio"},
            .install_hint = "Install vscode-langservers-extracted.",
        },
        .yaml => .{
            .label = "yaml-language-server",
            .executable = "yaml-language-server",
            .args = &.{"--stdio"},
            .install_hint = "Install yaml-language-server.",
        },
        .dockerfile => .{
            .label = "dockerfile-language-server",
            .executable = "docker-langserver",
            .args = &.{"--stdio"},
            .install_hint = "Install dockerfile-language-server-nodejs.",
        },
        .haskell => .{
            .label = "haskell-language-server",
            .executable = "haskell-language-server-wrapper",
            .args = &.{"--lsp"},
            .install_hint = "Install haskell-language-server.",
        },
        .ocaml => .{
            .label = "ocamllsp",
            .executable = "ocamllsp",
            .install_hint = "Install ocaml-lsp-server.",
        },
        .elixir => .{
            .label = "ElixirLS",
            .executable = "elixir-ls",
            .install_hint = "Install ElixirLS.",
        },
        .kotlin => .{
            .label = "kotlin-language-server",
            .executable = "kotlin-language-server",
            .install_hint = "Install kotlin-language-server.",
        },
        .dart => .{
            .label = "dart analysis server",
            .executable = "dart",
            .args = &.{ "language-server", "--protocol=lsp" },
            .install_hint = "Install Dart SDK.",
        },
        else => null,
    };
}

pub fn commandLine(allocator: std.mem.Allocator, server: Server) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll(server.executable);
    for (server.args) |arg| {
        try out.writer.writeByte(' ');
        try out.writer.writeAll(arg);
    }
    return try out.toOwnedSlice();
}

fn extractedServerExecutable(mode: modes.LanguageMode) []const u8 {
    return switch (mode) {
        .html => "vscode-html-language-server",
        .css => "vscode-css-language-server",
        .json => "vscode-json-language-server",
        else => "vscode-json-language-server",
    };
}

test "Zig language selects zls" {
    const server = serverForLanguage(.zig) orelse return error.ExpectedServer;
    try std.testing.expectEqualStrings("zls", server.executable);
}

test "server command line includes arguments" {
    const server = serverForLanguage(.typescript) orelse return error.ExpectedServer;
    const line = try commandLine(std.testing.allocator, server);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("typescript-language-server --stdio", line);
}
