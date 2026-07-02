const std = @import("std");
const workspace_mod = @import("../workspace/workspace.zig");

pub const Capability = enum {
    ui,
    workspace_read,
    workspace_write,
    process,
    network_read,
    network_write,
    git,
    github,
    task,
    terminal,
    unknown,
};

pub const Risk = enum {
    low,
    medium,
    high,
};

pub const Status = enum {
    loaded,
    invalid,
};

pub const Extension = struct {
    id: []u8,
    name: []u8,
    version: []u8,
    description: []u8,
    manifest_path: []u8,
    entry: []u8,
    capabilities: []Capability,
    commands: usize,
    integrations: usize,
    status: Status,
    message: []u8,

    pub fn deinit(self: *Extension, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.manifest_path);
        allocator.free(self.entry);
        allocator.free(self.capabilities);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const ScanOptions = struct {
    max_manifests: usize = 128,
    max_manifest_bytes: usize = 256 * 1024,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    items: std.array_list.Managed(Extension),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .items = std.array_list.Managed(Extension).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit();
        self.* = undefined;
    }

    pub fn scan(allocator: std.mem.Allocator, workspace: *const workspace_mod.Workspace, options: ScanOptions) !Registry {
        var registry = Registry.init(allocator);
        errdefer registry.deinit();

        for (workspace.entries.items) |entry| {
            if (registry.items.items.len >= options.max_manifests) break;
            if (entry.kind != .file) continue;
            if (!isManifestPath(entry.path)) continue;

            const absolute = try std.fs.path.join(allocator, &.{ workspace.root_path, entry.path });
            defer allocator.free(absolute);

            const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, absolute, allocator, .limited(options.max_manifest_bytes)) catch |err| {
                try registry.appendInvalid(entry.path, @errorName(err));
                continue;
            };
            defer allocator.free(bytes);

            var extension = parseManifest(allocator, entry.path, bytes) catch |err| {
                try registry.appendInvalid(entry.path, @errorName(err));
                continue;
            };
            errdefer extension.deinit(allocator);
            try registry.items.append(extension);
        }

        return registry;
    }

    fn appendInvalid(self: *Registry, path: []const u8, message: []const u8) !void {
        const empty_caps = try self.allocator.alloc(Capability, 0);
        errdefer self.allocator.free(empty_caps);

        var extension = Extension{
            .id = try self.allocator.dupe(u8, std.fs.path.basename(path)),
            .name = try self.allocator.dupe(u8, std.fs.path.basename(path)),
            .version = try self.allocator.dupe(u8, "invalid"),
            .description = try self.allocator.dupe(u8, ""),
            .manifest_path = try self.allocator.dupe(u8, path),
            .entry = try self.allocator.dupe(u8, ""),
            .capabilities = empty_caps,
            .commands = 0,
            .integrations = 0,
            .status = .invalid,
            .message = try self.allocator.dupe(u8, message),
        };
        errdefer extension.deinit(self.allocator);
        try self.items.append(extension);
    }

    pub fn countStatus(self: *const Registry, status: Status) usize {
        var count: usize = 0;
        for (self.items.items) |item| {
            if (item.status == status) count += 1;
        }
        return count;
    }

    pub fn countRisk(self: *const Registry, risk: Risk) usize {
        var count: usize = 0;
        for (self.items.items) |item| {
            if (extensionRisk(item) == risk) count += 1;
        }
        return count;
    }
};

pub fn parseManifest(allocator: std.mem.Allocator, manifest_path: []const u8, bytes: []const u8) !Extension {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidManifestRoot,
    };

    const id = try dupeStringField(allocator, object, "id", std.fs.path.basename(manifest_path));
    errdefer allocator.free(id);
    const name = try dupeStringField(allocator, object, "name", id);
    errdefer allocator.free(name);
    const version = try dupeStringField(allocator, object, "version", "0.0.0");
    errdefer allocator.free(version);
    const description = try dupeStringField(allocator, object, "description", "");
    errdefer allocator.free(description);
    const path = try allocator.dupe(u8, manifest_path);
    errdefer allocator.free(path);
    const entry = try dupeStringField(allocator, object, "entry", "");
    errdefer allocator.free(entry);
    const capabilities = try parseCapabilities(allocator, object);
    errdefer allocator.free(capabilities);
    const message = try allocator.dupe(u8, "manifest loaded read-only; extension code was not executed");
    errdefer allocator.free(message);

    return .{
        .id = id,
        .name = name,
        .version = version,
        .description = description,
        .manifest_path = path,
        .entry = entry,
        .capabilities = capabilities,
        .commands = countArrayField(object, "commands"),
        .integrations = countArrayField(object, "integrations"),
        .status = .loaded,
        .message = message,
    };
}

pub fn extensionRisk(extension: Extension) Risk {
    if (extension.status == .invalid) return .medium;
    var risk: Risk = .low;
    for (extension.capabilities) |capability| {
        switch (capability) {
            .process, .workspace_write, .network_write, .terminal => return .high,
            .network_read, .git, .github, .task, .unknown => risk = .medium,
            .ui, .workspace_read => {},
        }
    }
    return risk;
}

pub fn capabilityLabel(capability: Capability) []const u8 {
    return switch (capability) {
        .ui => "ui",
        .workspace_read => "workspace.read",
        .workspace_write => "workspace.write",
        .process => "process",
        .network_read => "network.read",
        .network_write => "network.write",
        .git => "git",
        .github => "github",
        .task => "task",
        .terminal => "terminal",
        .unknown => "unknown",
    };
}

pub fn riskLabel(risk: Risk) []const u8 {
    return switch (risk) {
        .low => "low",
        .medium => "medium",
        .high => "high",
    };
}

fn parseCapabilities(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]Capability {
    const value = object.get("capabilities") orelse return allocator.alloc(Capability, 0);
    const array = switch (value) {
        .array => |array| array,
        else => return allocator.alloc(Capability, 0),
    };

    var capabilities = std.array_list.Managed(Capability).init(allocator);
    errdefer capabilities.deinit();

    for (array.items) |item| {
        const name = switch (item) {
            .string => |value_string| value_string,
            else => continue,
        };
        try capabilities.append(parseCapability(name));
    }

    return try capabilities.toOwnedSlice();
}

fn parseCapability(name: []const u8) Capability {
    if (asciiEql(name, "ui")) return .ui;
    if (asciiEql(name, "workspace.read") or asciiEql(name, "workspace_read")) return .workspace_read;
    if (asciiEql(name, "workspace.write") or asciiEql(name, "workspace_write")) return .workspace_write;
    if (asciiEql(name, "process") or asciiEql(name, "external_command")) return .process;
    if (asciiEql(name, "network.read") or asciiEql(name, "network_read")) return .network_read;
    if (asciiEql(name, "network.write") or asciiEql(name, "network_write")) return .network_write;
    if (asciiEql(name, "git")) return .git;
    if (asciiEql(name, "github")) return .github;
    if (asciiEql(name, "task") or asciiEql(name, "tasks")) return .task;
    if (asciiEql(name, "terminal")) return .terminal;
    return .unknown;
}

fn dupeStringField(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, fallback: []const u8) ![]u8 {
    if (object.get(key)) |value| {
        switch (value) {
            .string => |text| return allocator.dupe(u8, text),
            else => {},
        }
    }
    return allocator.dupe(u8, fallback);
}

fn countArrayField(object: std.json.ObjectMap, key: []const u8) usize {
    if (object.get(key)) |value| {
        return switch (value) {
            .array => |array| array.items.len,
            else => 0,
        };
    }
    return 0;
}

fn isManifestPath(path: []const u8) bool {
    return endsWithIgnoreCase(path, "zide-extension.json") or endsWithIgnoreCase(path, "zide.extension.json");
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (suffix.len > value.len) return false;
    return asciiEql(value[value.len - suffix.len ..], suffix);
}

fn asciiEql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "extension manifest parser classifies capabilities" {
    var extension = try parseManifest(std.testing.allocator, ".zide/extensions/git/zide-extension.json",
        \\{
        \\  "id": "zide.git-tools",
        \\  "name": "Git Tools",
        \\  "version": "0.1.0",
        \\  "description": "Git panel helpers",
        \\  "entry": "main.zig",
        \\  "capabilities": ["ui", "git", "workspace.write"],
        \\  "commands": [{"id": "git.refresh"}],
        \\  "integrations": [{"type": "github"}]
        \\}
    );
    defer extension.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("zide.git-tools", extension.id);
    try std.testing.expectEqual(@as(usize, 3), extension.capabilities.len);
    try std.testing.expectEqual(@as(usize, 1), extension.commands);
    try std.testing.expectEqual(@as(usize, 1), extension.integrations);
    try std.testing.expectEqual(Risk.high, extensionRisk(extension));
}
