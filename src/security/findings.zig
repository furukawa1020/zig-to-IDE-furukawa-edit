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
    secret_flow,
    output_sanitizer,
    ide_self_protection,
    allocator_policy,
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

pub const Collection = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Finding),

    pub fn init(allocator: std.mem.Allocator) Collection {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(Finding).init(allocator),
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
