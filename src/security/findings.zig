const std = @import("std");

pub const Risk = enum {
    info,
    low,
    medium,
    high,
    critical,
};

pub const Category = enum {
    workspace_trust,
    build_firewall,
    package_trust,
    safety_profile,
    ffi_boundary,
    filesystem_boundary,
    network_boundary,
    concurrency_boundary,
    secret_flow,
    output_sanitizer,
    ide_self_protection,
    text_integrity,
    path_trust,
    allocator_policy,
    git_trust,
    polyglot_trust,
};

pub const Boundary = enum {
    workspace,
    memory,
    execution,
    filesystem,
    network,
    dependency,
    secret,
    text,
    path,
    git,
    output,
};

pub const Finding = struct {
    category: Category,
    risk: Risk,
    path: []u8,
    line: usize,
    column: usize,
    message: []u8,
    evidence: []u8,

    pub fn deinit(self: *Finding, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        allocator.free(self.evidence);
        self.* = undefined;
    }
};

pub fn boundaryFor(category: Category) Boundary {
    return switch (category) {
        .workspace_trust => .workspace,
        .build_firewall => .execution,
        .package_trust => .dependency,
        .safety_profile => .memory,
        .ffi_boundary => .memory,
        .filesystem_boundary => .filesystem,
        .network_boundary => .network,
        .concurrency_boundary => .memory,
        .secret_flow => .secret,
        .output_sanitizer => .output,
        .ide_self_protection => .memory,
        .text_integrity => .text,
        .path_trust => .path,
        .allocator_policy => .memory,
        .git_trust => .git,
        .polyglot_trust => .execution,
    };
}

pub fn boundaryLabel(boundary: Boundary) []const u8 {
    return switch (boundary) {
        .workspace => "workspace",
        .memory => "memory",
        .execution => "execution",
        .filesystem => "filesystem",
        .network => "network",
        .dependency => "dependency",
        .secret => "secret",
        .text => "text",
        .path => "path",
        .git => "git",
        .output => "output",
    };
}

pub const Collection = struct {
    allocator: std.mem.Allocator,
    items: std.array_list.Managed(Finding),

    pub fn init(allocator: std.mem.Allocator) Collection {
        return .{
            .allocator = allocator,
            .items = std.array_list.Managed(Finding).init(allocator),
        };
    }

    pub fn deinit(self: *Collection) void {
        self.clear();
        self.items.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *Collection) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.clearRetainingCapacity();
    }

    pub fn clearCategory(self: *Collection, category: Category) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            if (self.items.items[index].category != category) {
                index += 1;
                continue;
            }

            var removed = self.items.orderedRemove(index);
            removed.deinit(self.allocator);
        }
    }

    pub fn clearPath(self: *Collection, path: []const u8) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            if (!std.mem.eql(u8, self.items.items[index].path, path)) {
                index += 1;
                continue;
            }

            var removed = self.items.orderedRemove(index);
            removed.deinit(self.allocator);
        }
    }

    pub fn append(
        self: *Collection,
        category: Category,
        risk: Risk,
        path: []const u8,
        line: usize,
        column: usize,
        message: []const u8,
        evidence: []const u8,
    ) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);
        const owned_evidence = try self.allocator.dupe(u8, evidence);
        errdefer self.allocator.free(owned_evidence);

        try self.items.append(.{
            .category = category,
            .risk = risk,
            .path = owned_path,
            .line = line,
            .column = column,
            .message = owned_message,
            .evidence = owned_evidence,
        });
    }

    pub fn appendFinding(self: *Collection, finding: Finding) !void {
        try self.append(
            finding.category,
            finding.risk,
            finding.path,
            finding.line,
            finding.column,
            finding.message,
            finding.evidence,
        );
    }

    pub fn countRiskAtLeast(self: *const Collection, minimum: Risk) usize {
        var count: usize = 0;
        for (self.items.items) |item| {
            if (riskRank(item.risk) >= riskRank(minimum)) count += 1;
        }
        return count;
    }
};

fn riskRank(risk: Risk) u8 {
    return switch (risk) {
        .info => 0,
        .low => 1,
        .medium => 2,
        .high => 3,
        .critical => 4,
    };
}

test "clearCategory removes only matching findings" {
    var collection = Collection.init(std.testing.allocator);
    defer collection.deinit();

    try collection.append(.git_trust, .medium, ".git/config", 0, 0, "git", "");
    try collection.append(.build_firewall, .high, "build.zig", 0, 0, "build", "");
    try collection.append(.git_trust, .high, ".git/hooks", 0, 0, "hook", "");

    collection.clearCategory(.git_trust);

    try std.testing.expectEqual(@as(usize, 1), collection.items.items.len);
    try std.testing.expectEqual(Category.build_firewall, collection.items.items[0].category);
}

test "clearPath removes only matching findings" {
    var collection = Collection.init(std.testing.allocator);
    defer collection.deinit();

    try collection.append(.ffi_boundary, .high, "src/a.zig", 0, 0, "a", "");
    try collection.append(.ffi_boundary, .high, "src/b.zig", 0, 0, "b", "");
    try collection.append(.safety_profile, .medium, "src/a.zig", 1, 0, "a2", "");

    collection.clearPath("src/a.zig");

    try std.testing.expectEqual(@as(usize, 1), collection.items.items.len);
    try std.testing.expectEqualStrings("src/b.zig", collection.items.items[0].path);
}
