const std = @import("std");

pub const LaunchProfile = enum {
    read_only,
    safe,
    network,
    publish,
};

pub const TutorialLanguage = enum {
    ja,
    en,
};

pub const BottomPanel = enum {
    output,
    debug,
    tasks,
    git,
    extensions,
    diagnostics,
    security,
    settings,
    keybindings,
    tutorial,
    publish,
};

pub const Settings = struct {
    version: u32 = 1,
    launch_profile: LaunchProfile = .safe,
    tutorial_language: TutorialLanguage = .ja,
    bottom_panel: BottomPanel = .output,
    show_file_tree: bool = true,
};

pub fn parse(source: []const u8) Settings {
    var settings = Settings{};
    var line_iter = std.mem.splitScalar(u8, source, '\n');

    while (line_iter.next()) |raw_line| {
        const line_without_comment = stripComment(raw_line);
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (line.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = trimValue(line[eq + 1 ..]);

        if (std.mem.eql(u8, key, "version")) {
            settings.version = std.fmt.parseInt(u32, value, 10) catch settings.version;
        } else if (std.mem.eql(u8, key, "launch_profile")) {
            settings.launch_profile = parseLaunchProfile(value) orelse settings.launch_profile;
        } else if (std.mem.eql(u8, key, "tutorial_language")) {
            settings.tutorial_language = parseTutorialLanguage(value) orelse settings.tutorial_language;
        } else if (std.mem.eql(u8, key, "bottom_panel")) {
            settings.bottom_panel = parseBottomPanel(value) orelse settings.bottom_panel;
        } else if (std.mem.eql(u8, key, "show_file_tree")) {
            settings.show_file_tree = parseBool(value) orelse settings.show_file_tree;
        }
    }

    return settings;
}

pub fn write(writer: *std.Io.Writer, settings: Settings) !void {
    try writer.writeAll("# ZIDE workbench settings\n");
    try writer.writeAll("# UX state is persisted; trust state is intentionally re-earned per workspace.\n");
    try writer.print("version = {d}\n", .{settings.version});
    try writer.print("launch_profile = {s}\n", .{@tagName(settings.launch_profile)});
    try writer.print("tutorial_language = {s}\n", .{@tagName(settings.tutorial_language)});
    try writer.print("bottom_panel = {s}\n", .{@tagName(settings.bottom_panel)});
    try writer.print("show_file_tree = {}\n", .{settings.show_file_tree});
}

fn stripComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
    const slash = std.mem.indexOf(u8, line, "//") orelse line.len;
    return line[0..@min(hash, slash)];
}

fn trimValue(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t\r,");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    return value;
}

fn parseLaunchProfile(value: []const u8) ?LaunchProfile {
    if (std.mem.eql(u8, value, "read_only")) return .read_only;
    if (std.mem.eql(u8, value, "safe")) return .safe;
    if (std.mem.eql(u8, value, "network")) return .network;
    if (std.mem.eql(u8, value, "publish")) return .publish;
    return null;
}

fn parseTutorialLanguage(value: []const u8) ?TutorialLanguage {
    if (std.mem.eql(u8, value, "ja")) return .ja;
    if (std.mem.eql(u8, value, "en")) return .en;
    return null;
}

fn parseBottomPanel(value: []const u8) ?BottomPanel {
    if (std.mem.eql(u8, value, "output")) return .output;
    if (std.mem.eql(u8, value, "debug")) return .debug;
    if (std.mem.eql(u8, value, "tasks")) return .tasks;
    if (std.mem.eql(u8, value, "git")) return .git;
    if (std.mem.eql(u8, value, "extensions")) return .extensions;
    if (std.mem.eql(u8, value, "diagnostics")) return .diagnostics;
    if (std.mem.eql(u8, value, "security")) return .security;
    if (std.mem.eql(u8, value, "settings")) return .settings;
    if (std.mem.eql(u8, value, "keybindings")) return .keybindings;
    if (std.mem.eql(u8, value, "tutorial")) return .tutorial;
    if (std.mem.eql(u8, value, "publish")) return .publish;
    return null;
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

test "parse workbench settings" {
    const settings = parse(
        \\# comment
        \\version = 1
        \\launch_profile = network
        \\tutorial_language = en
        \\bottom_panel = keybindings
        \\show_file_tree = false
        \\
    );

    try std.testing.expectEqual(@as(u32, 1), settings.version);
    try std.testing.expectEqual(LaunchProfile.network, settings.launch_profile);
    try std.testing.expectEqual(TutorialLanguage.en, settings.tutorial_language);
    try std.testing.expectEqual(BottomPanel.keybindings, settings.bottom_panel);
    try std.testing.expect(!settings.show_file_tree);
}

test "invalid workbench values keep safe defaults" {
    const settings = parse(
        \\version = nope
        \\launch_profile = trusted
        \\tutorial_language = jp
        \\bottom_panel = invisible
        \\show_file_tree = maybe
        \\
    );

    try std.testing.expectEqual(@as(u32, 1), settings.version);
    try std.testing.expectEqual(LaunchProfile.safe, settings.launch_profile);
    try std.testing.expectEqual(TutorialLanguage.ja, settings.tutorial_language);
    try std.testing.expectEqual(BottomPanel.output, settings.bottom_panel);
    try std.testing.expect(settings.show_file_tree);
}

test "write workbench settings" {
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();

    try write(&text.writer, .{
        .launch_profile = .publish,
        .tutorial_language = .en,
        .bottom_panel = .publish,
        .show_file_tree = false,
    });

    const bytes = text.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "launch_profile = publish") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "tutorial_language = en") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "bottom_panel = publish") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "show_file_tree = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "trust state is intentionally") != null);
}
