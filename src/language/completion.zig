const std = @import("std");
const modes = @import("modes.zig");
const symbols = @import("symbols.zig");

pub const Kind = enum {
    keyword,
    symbol,
    snippet,
    builtin,
    word,
    command,
};

pub const Prefix = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

pub const Context = struct {
    source: []const u8,
    cursor_offset: usize,
    file_path: []const u8 = "(scratch)",
    language: modes.LanguageMode = .unknown,
    query_override: ?[]const u8 = null,
    max_items: usize = 64,
};

pub const Item = struct {
    label: []u8,
    insert_text: []u8,
    detail: []u8,
    kind: Kind,
    score: i32,

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.insert_text);
        allocator.free(self.detail);
        self.* = undefined;
    }
};

const Seed = struct {
    label: []const u8,
    insert_text: []const u8,
    detail: []const u8,
    kind: Kind,
};

pub fn prefixAt(source: []const u8, cursor_offset: usize) Prefix {
    const end = @min(cursor_offset, source.len);
    var start = end;
    while (start > 0 and isIdentifierContinue(source[start - 1])) : (start -= 1) {}
    if (start < end and !isIdentifierStart(source[start])) start = end;
    return .{
        .text = source[start..end],
        .start = start,
        .end = end,
    };
}

pub fn complete(allocator: std.mem.Allocator, context: Context) ![]Item {
    const prefix = prefixAt(context.source, context.cursor_offset);
    const query = context.query_override orelse prefix.text;
    const limit = if (context.max_items == 0) 64 else context.max_items;

    var items = std.array_list.Managed(Item).init(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }

    try appendSeeds(allocator, &items, query, modeSeeds(context.language));
    try appendSeeds(allocator, &items, query, familySeeds(modes.family(context.language)));
    try appendModeAffordances(allocator, &items, query, context.language);
    try appendDocumentSymbols(allocator, &items, query, context);
    try appendDocumentWords(allocator, &items, query, context.source, limit * 3);

    sortItems(items.items);
    if (items.items.len > limit) {
        var index = limit;
        while (index < items.items.len) : (index += 1) {
            items.items[index].deinit(allocator);
        }
        items.shrinkRetainingCapacity(limit);
    }

    return try items.toOwnedSlice();
}

pub fn deinitItems(allocator: std.mem.Allocator, items: []Item) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn mergeLspItems(
    allocator: std.mem.Allocator,
    base: []Item,
    lsp_items: []const Item,
    query: []const u8,
    max_items: usize,
) ![]Item {
    var base_transferred = false;
    errdefer if (!base_transferred) deinitItems(allocator, base);

    var items = std.array_list.Managed(Item).init(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }

    try items.appendSlice(base);
    allocator.free(base);
    base_transferred = true;

    for (lsp_items) |item| {
        if (containsLabel(items.items, item.label)) continue;
        const item_score = score(query, item.label) orelse if (query.len == 0) @as(i32, 900) else continue;
        try appendOwned(allocator, &items, item.label, item.insert_text, item.detail, item.kind, item_score + 90);
    }

    sortItems(items.items);
    const limit = if (max_items == 0) items.items.len else max_items;
    if (items.items.len > limit) {
        var index = limit;
        while (index < items.items.len) : (index += 1) {
            items.items[index].deinit(allocator);
        }
        items.shrinkRetainingCapacity(limit);
    }

    return try items.toOwnedSlice();
}

fn appendSeeds(allocator: std.mem.Allocator, items: *std.array_list.Managed(Item), query: []const u8, seeds: []const Seed) !void {
    for (seeds) |seed| {
        const item_score = score(query, seed.label) orelse continue;
        try appendOwned(allocator, items, seed.label, seed.insert_text, seed.detail, seed.kind, item_score);
    }
}

fn appendModeAffordances(allocator: std.mem.Allocator, items: *std.array_list.Managed(Item), query: []const u8, language: modes.LanguageMode) !void {
    if (modes.lineComment(language)) |prefix| {
        const label = "line comment";
        const item_score = score(query, label) orelse if (query.len == 0) @as(i32, 20) else return;
        var insert_buf: [24]u8 = undefined;
        const insert_text = std.fmt.bufPrint(insert_buf[0..], "{s} ", .{prefix}) catch prefix;
        try appendOwned(allocator, items, label, insert_text, "comment token", .snippet, item_score);
    }
    if (modes.runProfile(language)) |profile| {
        const item_score = score(query, profile.label) orelse if (query.len == 0) @as(i32, 18) else return;
        try appendOwned(allocator, items, profile.label, profile.command, "run profile", .command, item_score);
    }
}

fn appendDocumentSymbols(allocator: std.mem.Allocator, items: *std.array_list.Managed(Item), query: []const u8, context: Context) !void {
    var index = try symbols.collectDocument(allocator, context.source, context.file_path, context.language);
    defer index.deinit();

    for (index.symbols) |symbol| {
        const item_score = score(query, symbol.name) orelse continue;
        var detail_buf: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(detail_buf[0..], "{s} {d}:{d}", .{
            @tagName(symbol.kind),
            symbol.range.start.line + 1,
            symbol.range.start.column + 1,
        }) catch @tagName(symbol.kind);
        try appendOwned(allocator, items, symbol.name, symbol.name, detail, .symbol, item_score + 60);
    }
}

fn appendDocumentWords(allocator: std.mem.Allocator, items: *std.array_list.Managed(Item), query: []const u8, source: []const u8, max_scan: usize) !void {
    if (query.len < 2) return;
    var index: usize = 0;
    var scanned: usize = 0;
    while (index < source.len and scanned < max_scan) {
        if (!isIdentifierStart(source[index])) {
            index += 1;
            continue;
        }
        const start = index;
        index += 1;
        while (index < source.len and isIdentifierContinue(source[index])) : (index += 1) {}
        const word = source[start..index];
        if (word.len < 3 or isNoiseWord(word)) continue;
        const item_score = score(query, word) orelse continue;
        try appendOwned(allocator, items, word, word, "word in buffer", .word, item_score);
        scanned += 1;
    }
}

fn appendOwned(
    allocator: std.mem.Allocator,
    items: *std.array_list.Managed(Item),
    label: []const u8,
    insert_text: []const u8,
    detail: []const u8,
    kind: Kind,
    item_score: i32,
) !void {
    if (containsLabel(items.items, label)) return;
    var item = Item{
        .label = try allocator.dupe(u8, label),
        .insert_text = undefined,
        .detail = undefined,
        .kind = kind,
        .score = item_score,
    };
    errdefer allocator.free(item.label);
    item.insert_text = try allocator.dupe(u8, insert_text);
    errdefer allocator.free(item.insert_text);
    item.detail = try allocator.dupe(u8, detail);
    errdefer allocator.free(item.detail);
    try items.append(item);
}

fn containsLabel(items: []const Item, label: []const u8) bool {
    for (items) |item| {
        if (std.ascii.eqlIgnoreCase(item.label, label)) return true;
    }
    return false;
}

fn sortItems(items: []Item) void {
    if (items.len < 2) return;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and itemLessThan(items[j], items[j - 1])) : (j -= 1) {
            const tmp = items[j - 1];
            items[j - 1] = items[j];
            items[j] = tmp;
        }
    }
}

fn itemLessThan(a: Item, b: Item) bool {
    if (a.score != b.score) return a.score > b.score;
    return compareIgnoreCase(a.label, b.label) < 0;
}

fn score(query: []const u8, candidate: []const u8) ?i32 {
    if (candidate.len == 0) return null;
    if (query.len == 0) return kindlessBaseScore(candidate);
    if (std.ascii.eqlIgnoreCase(query, candidate)) return 1200;
    if (startsWithIgnoreCase(candidate, query)) return 1000 - @as(i32, @intCast(@min(candidate.len - query.len, 400)));
    if (containsIgnoreCase(candidate, query)) return 780 - @as(i32, @intCast(@min(candidate.len, 240)));
    if (subsequenceScore(query, candidate)) |value| return value;
    return null;
}

fn kindlessBaseScore(candidate: []const u8) i32 {
    return 100 - @as(i32, @intCast(@min(candidate.len, 80)));
}

fn subsequenceScore(query: []const u8, candidate: []const u8) ?i32 {
    var q_index: usize = 0;
    var c_index: usize = 0;
    var gaps: usize = 0;
    while (q_index < query.len and c_index < candidate.len) : (c_index += 1) {
        if (lower(query[q_index]) == lower(candidate[c_index])) {
            q_index += 1;
        } else {
            gaps += 1;
        }
    }
    if (q_index != query.len) return null;
    return 560 - @as(i32, @intCast(@min(gaps, 400)));
}

fn startsWithIgnoreCase(candidate: []const u8, query: []const u8) bool {
    if (candidate.len < query.len) return false;
    return std.ascii.eqlIgnoreCase(candidate[0..query.len], query);
}

fn containsIgnoreCase(candidate: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (candidate.len < query.len) return false;
    var index: usize = 0;
    while (index + query.len <= candidate.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(candidate[index .. index + query.len], query)) return true;
    }
    return false;
}

fn compareIgnoreCase(a: []const u8, b: []const u8) i32 {
    const len = @min(a.len, b.len);
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const ac = lower(a[index]);
        const bc = lower(b[index]);
        if (ac < bc) return -1;
        if (ac > bc) return 1;
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

fn lower(byte: u8) u8 {
    return std.ascii.toLower(byte);
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '@' or byte == '$';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}

fn isNoiseWord(word: []const u8) bool {
    return inList(word, &.{
        "the",   "and", "for", "with", "from", "this",   "that",  "true",   "false",    "null", "undefined",
        "const", "var", "let", "pub",  "fn",   "return", "class", "struct", "function", "def",
    });
}

fn modeSeeds(mode: modes.LanguageMode) []const Seed {
    return switch (mode) {
        .zig => zig_seeds[0..],
        .zon => zon_seeds[0..],
        .python => python_seeds[0..],
        .javascript, .jsx => javascript_seeds[0..],
        .typescript, .tsx => typescript_seeds[0..],
        .html, .vue, .svelte => html_seeds[0..],
        .css => css_seeds[0..],
        .json, .yaml, .toml, .hcl, .xml, .graphql, .proto, .csv => data_seeds[0..],
        .dockerfile => docker_seeds[0..],
        .shell, .powershell, .batch => shell_seeds[0..],
        .c, .cpp, .objective_c, .objective_cpp => c_family_seeds[0..],
        .rust => rust_seeds[0..],
        .go => go_seeds[0..],
        .java, .csharp, .fsharp, .swift, .kotlin, .scala, .dart, .php => managed_seeds[0..],
        .ruby, .lua, .groovy, .r, .julia, .perl, .elixir, .erlang, .clojure => script_seeds[0..],
        .haskell, .ocaml, .nim, .crystal, .solidity, .assembly => native_seeds[0..],
        else => &.{},
    };
}

fn familySeeds(family: modes.LanguageFamily) []const Seed {
    return switch (family) {
        .zig => zig_family_seeds[0..],
        .native => native_seeds[0..],
        .script => script_seeds[0..],
        .web => web_family_seeds[0..],
        .data => data_seeds[0..],
        .config => config_seeds[0..],
        .prose => prose_seeds[0..],
        .unknown => &.{},
    };
}

fn inList(word: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.ascii.eqlIgnoreCase(word, candidate)) return true;
    }
    return false;
}

const zig_seeds = [_]Seed{
    .{ .label = "const", .insert_text = "const ", .detail = "Zig immutable binding", .kind = .keyword },
    .{ .label = "var", .insert_text = "var ", .detail = "Zig mutable binding", .kind = .keyword },
    .{ .label = "pub fn", .insert_text = "pub fn ", .detail = "public function", .kind = .snippet },
    .{ .label = "fn", .insert_text = "fn ", .detail = "function", .kind = .keyword },
    .{ .label = "test", .insert_text = "test \"\" {\n    \n}", .detail = "test block", .kind = .snippet },
    .{ .label = "struct", .insert_text = "struct {\n    \n}", .detail = "anonymous struct", .kind = .snippet },
    .{ .label = "enum", .insert_text = "enum {\n    \n}", .detail = "enum type", .kind = .snippet },
    .{ .label = "union", .insert_text = "union(enum) {\n    \n}", .detail = "tagged union", .kind = .snippet },
    .{ .label = "error", .insert_text = "error{ }", .detail = "error set", .kind = .snippet },
    .{ .label = "defer", .insert_text = "defer ", .detail = "scope cleanup", .kind = .keyword },
    .{ .label = "errdefer", .insert_text = "errdefer ", .detail = "error cleanup", .kind = .keyword },
    .{ .label = "try", .insert_text = "try ", .detail = "error propagation", .kind = .keyword },
    .{ .label = "catch", .insert_text = "catch |err| ", .detail = "error handler", .kind = .snippet },
    .{ .label = "comptime", .insert_text = "comptime ", .detail = "compile-time boundary", .kind = .keyword },
    .{ .label = "@import", .insert_text = "@import(\"\")", .detail = "import module", .kind = .builtin },
    .{ .label = "@This", .insert_text = "@This()", .detail = "current type", .kind = .builtin },
    .{ .label = "@TypeOf", .insert_text = "@TypeOf()", .detail = "type introspection", .kind = .builtin },
    .{ .label = "@ptrCast", .insert_text = "@ptrCast()", .detail = "explicit pointer boundary", .kind = .builtin },
    .{ .label = "@alignCast", .insert_text = "@alignCast()", .detail = "alignment boundary", .kind = .builtin },
    .{ .label = "@intCast", .insert_text = "@intCast()", .detail = "integer boundary", .kind = .builtin },
};

const zig_family_seeds = [_]Seed{
    .{ .label = "allocator", .insert_text = "allocator", .detail = "allocation boundary", .kind = .keyword },
    .{ .label = "deinit", .insert_text = "deinit", .detail = "lifetime cleanup", .kind = .keyword },
    .{ .label = "errdefer cleanup", .insert_text = "errdefer ", .detail = "cleanup on error", .kind = .snippet },
};

const zon_seeds = [_]Seed{
    .{ .label = "name", .insert_text = ".name = \"\",", .detail = "package name", .kind = .snippet },
    .{ .label = "version", .insert_text = ".version = \"0.0.0\",", .detail = "package version", .kind = .snippet },
    .{ .label = "dependencies", .insert_text = ".dependencies = .{\n    \n},", .detail = "dependency map", .kind = .snippet },
    .{ .label = "paths", .insert_text = ".paths = .{\n    \"src\",\n},", .detail = "package paths", .kind = .snippet },
};

const python_seeds = [_]Seed{
    .{ .label = "def", .insert_text = "def ", .detail = "function", .kind = .keyword },
    .{ .label = "class", .insert_text = "class ", .detail = "class", .kind = .keyword },
    .{ .label = "async def", .insert_text = "async def ", .detail = "async function", .kind = .snippet },
    .{ .label = "import", .insert_text = "import ", .detail = "module import", .kind = .keyword },
    .{ .label = "from import", .insert_text = "from  import ", .detail = "selective import", .kind = .snippet },
    .{ .label = "with", .insert_text = "with ", .detail = "context manager", .kind = .keyword },
    .{ .label = "try except", .insert_text = "try:\n    \nexcept Exception as err:\n    ", .detail = "exception boundary", .kind = .snippet },
    .{ .label = "print", .insert_text = "print()", .detail = "debug output", .kind = .builtin },
};

const javascript_seeds = [_]Seed{
    .{ .label = "const", .insert_text = "const ", .detail = "binding", .kind = .keyword },
    .{ .label = "let", .insert_text = "let ", .detail = "binding", .kind = .keyword },
    .{ .label = "function", .insert_text = "function ", .detail = "function", .kind = .keyword },
    .{ .label = "async function", .insert_text = "async function ", .detail = "async function", .kind = .snippet },
    .{ .label = "import", .insert_text = "import ", .detail = "module import", .kind = .keyword },
    .{ .label = "export", .insert_text = "export ", .detail = "module export", .kind = .keyword },
    .{ .label = "console.log", .insert_text = "console.log()", .detail = "debug output", .kind = .builtin },
};

const typescript_seeds = [_]Seed{
    .{ .label = "interface", .insert_text = "interface ", .detail = "type contract", .kind = .keyword },
    .{ .label = "type", .insert_text = "type ", .detail = "type alias", .kind = .keyword },
    .{ .label = "implements", .insert_text = "implements ", .detail = "class contract", .kind = .keyword },
    .{ .label = "readonly", .insert_text = "readonly ", .detail = "immutable member", .kind = .keyword },
    .{ .label = "as const", .insert_text = "as const", .detail = "literal narrowing", .kind = .snippet },
};

const web_family_seeds = [_]Seed{
    .{ .label = "await", .insert_text = "await ", .detail = "async boundary", .kind = .keyword },
    .{ .label = "try catch", .insert_text = "try {\n    \n} catch (err) {\n    \n}", .detail = "error boundary", .kind = .snippet },
    .{ .label = "fetch", .insert_text = "fetch()", .detail = "network boundary", .kind = .builtin },
};

const html_seeds = [_]Seed{
    .{ .label = "div", .insert_text = "<div></div>", .detail = "element", .kind = .snippet },
    .{ .label = "button", .insert_text = "<button type=\"button\"></button>", .detail = "button", .kind = .snippet },
    .{ .label = "script", .insert_text = "<script>\n</script>", .detail = "script boundary", .kind = .snippet },
    .{ .label = "link stylesheet", .insert_text = "<link rel=\"stylesheet\" href=\"\">", .detail = "stylesheet", .kind = .snippet },
};

const css_seeds = [_]Seed{
    .{ .label = "display", .insert_text = "display: ", .detail = "layout", .kind = .keyword },
    .{ .label = "grid", .insert_text = "display: grid;", .detail = "layout", .kind = .snippet },
    .{ .label = "flex", .insert_text = "display: flex;", .detail = "layout", .kind = .snippet },
    .{ .label = "color", .insert_text = "color: ", .detail = "paint", .kind = .keyword },
    .{ .label = "background", .insert_text = "background: ", .detail = "paint", .kind = .keyword },
};

const data_seeds = [_]Seed{
    .{ .label = "true", .insert_text = "true", .detail = "boolean", .kind = .keyword },
    .{ .label = "false", .insert_text = "false", .detail = "boolean", .kind = .keyword },
    .{ .label = "null", .insert_text = "null", .detail = "empty value", .kind = .keyword },
    .{ .label = "version", .insert_text = "version", .detail = "common metadata key", .kind = .keyword },
    .{ .label = "services", .insert_text = "services:", .detail = "compose/service key", .kind = .keyword },
};

const config_seeds = [_]Seed{
    .{ .label = "PATH", .insert_text = "PATH=", .detail = "environment path", .kind = .keyword },
    .{ .label = "HOME", .insert_text = "HOME=", .detail = "environment home", .kind = .keyword },
    .{ .label = "include", .insert_text = "include ", .detail = "config include", .kind = .keyword },
};

const docker_seeds = [_]Seed{
    .{ .label = "FROM", .insert_text = "FROM ", .detail = "base image", .kind = .keyword },
    .{ .label = "RUN", .insert_text = "RUN ", .detail = "execution boundary", .kind = .keyword },
    .{ .label = "COPY", .insert_text = "COPY ", .detail = "filesystem boundary", .kind = .keyword },
    .{ .label = "USER", .insert_text = "USER ", .detail = "privilege boundary", .kind = .keyword },
};

const shell_seeds = [_]Seed{
    .{ .label = "if", .insert_text = "if ; then\n    \nfi", .detail = "conditional", .kind = .snippet },
    .{ .label = "for", .insert_text = "for item in ; do\n    \ndone", .detail = "loop", .kind = .snippet },
    .{ .label = "set -euo pipefail", .insert_text = "set -euo pipefail", .detail = "strict shell", .kind = .snippet },
    .{ .label = "export", .insert_text = "export ", .detail = "environment", .kind = .keyword },
};

const c_family_seeds = [_]Seed{
    .{ .label = "include", .insert_text = "#include ", .detail = "preprocessor include", .kind = .keyword },
    .{ .label = "struct", .insert_text = "struct ", .detail = "type", .kind = .keyword },
    .{ .label = "enum", .insert_text = "enum ", .detail = "type", .kind = .keyword },
    .{ .label = "static", .insert_text = "static ", .detail = "storage", .kind = .keyword },
    .{ .label = "nullptr", .insert_text = "nullptr", .detail = "null pointer", .kind = .keyword },
};

const rust_seeds = [_]Seed{
    .{ .label = "fn", .insert_text = "fn ", .detail = "function", .kind = .keyword },
    .{ .label = "let mut", .insert_text = "let mut ", .detail = "mutable binding", .kind = .snippet },
    .{ .label = "impl", .insert_text = "impl ", .detail = "implementation", .kind = .keyword },
    .{ .label = "Result", .insert_text = "Result<, >", .detail = "error boundary", .kind = .snippet },
    .{ .label = "unsafe", .insert_text = "unsafe ", .detail = "unsafe boundary", .kind = .keyword },
};

const go_seeds = [_]Seed{
    .{ .label = "func", .insert_text = "func ", .detail = "function", .kind = .keyword },
    .{ .label = "defer", .insert_text = "defer ", .detail = "cleanup", .kind = .keyword },
    .{ .label = "go", .insert_text = "go ", .detail = "goroutine boundary", .kind = .keyword },
    .{ .label = "if err", .insert_text = "if err != nil {\n    return err\n}", .detail = "error boundary", .kind = .snippet },
};

const native_seeds = [_]Seed{
    .{ .label = "return", .insert_text = "return ", .detail = "control flow", .kind = .keyword },
    .{ .label = "struct", .insert_text = "struct ", .detail = "type", .kind = .keyword },
    .{ .label = "enum", .insert_text = "enum ", .detail = "type", .kind = .keyword },
    .{ .label = "unsafe", .insert_text = "unsafe ", .detail = "explicit hazard", .kind = .keyword },
};

const managed_seeds = [_]Seed{
    .{ .label = "class", .insert_text = "class ", .detail = "class", .kind = .keyword },
    .{ .label = "interface", .insert_text = "interface ", .detail = "interface", .kind = .keyword },
    .{ .label = "public", .insert_text = "public ", .detail = "visibility", .kind = .keyword },
    .{ .label = "private", .insert_text = "private ", .detail = "visibility", .kind = .keyword },
    .{ .label = "try catch", .insert_text = "try {\n    \n} catch (Exception err) {\n    \n}", .detail = "exception boundary", .kind = .snippet },
};

const script_seeds = [_]Seed{
    .{ .label = "function", .insert_text = "function ", .detail = "function", .kind = .keyword },
    .{ .label = "def", .insert_text = "def ", .detail = "function", .kind = .keyword },
    .{ .label = "class", .insert_text = "class ", .detail = "class", .kind = .keyword },
    .{ .label = "require", .insert_text = "require ", .detail = "dependency boundary", .kind = .keyword },
    .{ .label = "print", .insert_text = "print", .detail = "output", .kind = .builtin },
};

const prose_seeds = [_]Seed{
    .{ .label = "TODO", .insert_text = "TODO: ", .detail = "note marker", .kind = .keyword },
    .{ .label = "SECURITY", .insert_text = "SECURITY: ", .detail = "security note", .kind = .keyword },
};

test "Zig completion includes keyword prefix" {
    const source = "pub fn main() void { con }";
    const cursor = std.mem.indexOf(u8, source, "con").? + 3;
    const items = try complete(std.testing.allocator, .{
        .source = source,
        .cursor_offset = cursor,
        .language = .zig,
    });
    defer deinitItems(std.testing.allocator, items);

    try std.testing.expect(containsLabel(items, "const"));
}

test "completion includes document symbols" {
    const source =
        \\pub fn renderPanel() void {}
        \\pub const theme = 1;
        \\ren
    ;
    const cursor = source.len;
    const items = try complete(std.testing.allocator, .{
        .source = source,
        .cursor_offset = cursor,
        .language = .zig,
    });
    defer deinitItems(std.testing.allocator, items);

    try std.testing.expect(containsLabel(items, "renderPanel"));
}

test "Python completion includes def keyword" {
    const source = "de";
    const items = try complete(std.testing.allocator, .{
        .source = source,
        .cursor_offset = source.len,
        .language = .python,
    });
    defer deinitItems(std.testing.allocator, items);

    try std.testing.expect(containsLabel(items, "def"));
}

test "merge LSP completion items into local items" {
    const source = "std.Ar";
    const local = try complete(std.testing.allocator, .{
        .source = source,
        .cursor_offset = source.len,
        .language = .zig,
        .query_override = "Ar",
    });
    const lsp = [_]Item{.{
        .label = try std.testing.allocator.dupe(u8, "ArrayList"),
        .insert_text = try std.testing.allocator.dupe(u8, "std.ArrayList"),
        .detail = try std.testing.allocator.dupe(u8, "LSP type"),
        .kind = .symbol,
        .score = 950,
    }};
    var lsp_owned = lsp;
    defer lsp_owned[0].deinit(std.testing.allocator);

    const merged = try mergeLspItems(std.testing.allocator, local, lsp_owned[0..], "Ar", 16);
    defer deinitItems(std.testing.allocator, merged);

    try std.testing.expect(containsLabel(merged, "ArrayList"));
}
