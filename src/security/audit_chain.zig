const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Digest = [Sha256.digest_length * 2]u8;
pub const zero_digest: Digest = [1]u8{'0'} ** (Sha256.digest_length * 2);

const prev_marker = ",\"prev_record_hash\":\"";
const record_marker = ",\"record_hash\":\"";

pub const VerifyStats = struct {
    lines: usize = 0,
    chained: usize = 0,
    legacy: usize = 0,
    broken: usize = 0,
    first_broken_line: ?usize = null,
    last_record_hash: ?Digest = null,

    pub fn ok(self: VerifyStats) bool {
        return self.broken == 0;
    }
};

pub fn hashRecord(prev_record_hash: []const u8, payload: []const u8) Digest {
    var hasher = Sha256.init(.{});
    update(&hasher, "zide-audit-chain-v1");
    update(&hasher, prev_record_hash);
    update(&hasher, payload);

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn lastRecordHash(bytes: []const u8) ?Digest {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) : (end -= 1) {}
    if (end == 0) return null;

    const start = if (std.mem.lastIndexOfScalar(u8, bytes[0..end], '\n')) |index| index + 1 else 0;
    return extractRecordHash(trimLine(bytes[start..end]));
}

pub fn verify(bytes: []const u8) VerifyStats {
    var stats: VerifyStats = .{};
    var expected_prev = zero_digest;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0) continue;

        stats.lines += 1;
        const prev = extractField(line, prev_marker);
        const record = extractField(line, record_marker);
        if (prev == null or record == null) {
            stats.legacy += 1;
            continue;
        }

        stats.chained += 1;
        const payload_end = std.mem.indexOf(u8, line, prev_marker) orelse line.len;
        const computed = hashRecord(prev.?, line[0..payload_end]);
        const prev_ok = std.mem.eql(u8, prev.?, expected_prev[0..]);
        const record_ok = std.mem.eql(u8, record.?, computed[0..]);
        if (!prev_ok or !record_ok) {
            stats.broken += 1;
            if (stats.first_broken_line == null) stats.first_broken_line = stats.lines;
        }

        if (copyDigest(record.?)) |digest| {
            expected_prev = digest;
            stats.last_record_hash = digest;
        }
    }

    return stats;
}

pub fn extractRecordHash(line: []const u8) ?Digest {
    const value = extractField(line, record_marker) orelse return null;
    return copyDigest(value);
}

fn extractField(line: []const u8, marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, marker) orelse return null;
    const value_start = start + marker.len;
    if (line.len < value_start + zero_digest.len) return null;
    const value = line[value_start .. value_start + zero_digest.len];
    if (!isHexDigest(value)) return null;
    if (line.len > value_start + zero_digest.len and line[value_start + zero_digest.len] != '"') return null;
    return value;
}

fn copyDigest(value: []const u8) ?Digest {
    if (!isHexDigest(value)) return null;
    var digest: Digest = undefined;
    @memcpy(digest[0..], value[0..zero_digest.len]);
    return digest;
}

fn isHexDigest(value: []const u8) bool {
    if (value.len != zero_digest.len) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn trimLine(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and line[end - 1] == '\r') : (end -= 1) {}
    return line[0..end];
}

fn update(hasher: *Sha256, bytes: []const u8) void {
    hasher.update(bytes);
    hasher.update(&[_]u8{0});
}

test "audit chain verifies linked records" {
    const first_payload = "{\"schema\":\"zide.run-history.v1\",\"audit_id\":\"a\"";
    const first_hash = hashRecord(zero_digest[0..], first_payload);
    const second_payload = "{\"schema\":\"zide.run-history.v1\",\"audit_id\":\"b\"";
    const second_hash = hashRecord(first_hash[0..], second_payload);

    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try text.writer.print("{s},\"prev_record_hash\":\"{s}\",\"record_hash\":\"{s}\"}}\n", .{ first_payload, zero_digest[0..], first_hash[0..] });
    try text.writer.print("{s},\"prev_record_hash\":\"{s}\",\"record_hash\":\"{s}\"}}\n", .{ second_payload, first_hash[0..], second_hash[0..] });

    const stats = verify(text.written());
    try std.testing.expect(stats.ok());
    try std.testing.expectEqual(@as(usize, 2), stats.lines);
    try std.testing.expectEqual(@as(usize, 2), stats.chained);
    try std.testing.expectEqual(@as(usize, 0), stats.broken);
    try std.testing.expect(std.mem.eql(u8, stats.last_record_hash.?[0..], second_hash[0..]));
}

test "audit chain detects payload tampering" {
    const payload = "{\"schema\":\"zide.run-history.v1\",\"audit_id\":\"a\"";
    const hash = hashRecord(zero_digest[0..], payload);

    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try text.writer.print("{{\"schema\":\"zide.run-history.v1\",\"audit_id\":\"tampered\",\"prev_record_hash\":\"{s}\",\"record_hash\":\"{s}\"}}\n", .{ zero_digest[0..], hash[0..] });

    const stats = verify(text.written());
    try std.testing.expect(!stats.ok());
    try std.testing.expectEqual(@as(usize, 1), stats.broken);
    try std.testing.expectEqual(@as(?usize, 1), stats.first_broken_line);
}
