const std = @import("std");
const findings = @import("findings.zig");
const trust = @import("trust.zig");

pub const Summary = struct {
    total: usize = 0,
    high: usize = 0,
    critical: usize = 0,
    build_firewall: usize = 0,
    package_trust: usize = 0,
    ffi_boundary: usize = 0,
    secret_flow: usize = 0,
    allocator_policy: usize = 0,
    git_trust: usize = 0,
    recommended_trust: trust.TrustState = .untrusted,
    label: []const u8 = "CLEAR",
};

pub fn summarize(collection: *const findings.Collection, current_trust: trust.TrustState) Summary {
    var summary = Summary{
        .total = collection.items.items.len,
        .recommended_trust = current_trust,
    };

    for (collection.items.items) |item| {
        switch (item.risk) {
            .critical => {
                summary.critical += 1;
                summary.high += 1;
            },
            .high => summary.high += 1,
            else => {},
        }

        switch (item.category) {
            .build_firewall => summary.build_firewall += 1,
            .package_trust => summary.package_trust += 1,
            .ffi_boundary => summary.ffi_boundary += 1,
            .secret_flow => summary.secret_flow += 1,
            .allocator_policy => summary.allocator_policy += 1,
            .git_trust => summary.git_trust += 1,
            else => {},
        }
    }

    if (summary.critical > 0) {
        summary.recommended_trust = .locked_down;
        summary.label = "LOCKED";
    } else if (summary.high > 0) {
        summary.recommended_trust = switch (current_trust) {
            .trusted, .hardened => .paranoid,
            else => current_trust,
        };
        summary.label = "REVIEW";
    } else if (summary.total > 0) {
        summary.label = "WATCH";
    }

    return summary;
}

test "posture locks down critical findings" {
    var collection = findings.Collection.init(std.testing.allocator);
    defer collection.deinit();
    try collection.append(.build_firewall, .critical, "build.zig", 0, 0, "system command", "addSystemCommand");

    const summary = summarize(&collection, .trusted);
    try std.testing.expectEqual(@as(usize, 1), summary.critical);
    try std.testing.expectEqual(trust.TrustState.locked_down, summary.recommended_trust);
}
