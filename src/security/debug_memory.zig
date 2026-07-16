const std = @import("std");
const text_integrity = @import("text_integrity.zig");

pub const max_memory_reference_bytes: usize = 4096;
pub const max_address_bytes: usize = 4096;
pub const max_instruction_bytes_text: usize = 4096;
pub const max_instruction_text_bytes: usize = 16 * 1024;
pub const max_symbol_bytes: usize = 4096;
pub const max_message_bytes: usize = 4096;
pub const max_source_path_bytes: usize = std.fs.max_path_bytes;
pub const max_memory_bytes: usize = 256;
pub const max_encoded_memory_bytes: usize = ((max_memory_bytes + 2) / 3) * 4;
pub const max_instructions: usize = 128;
pub const max_instruction_breakpoints: usize = 128;
pub const max_byte_offset: i64 = 1024 * 1024;
pub const max_instruction_offset: i64 = 4096;

pub const TextKind = enum {
    memory_reference,
    address,
    instruction_bytes,
    instruction,
    symbol,
    message,
    source_path,
};

pub const ValidationError = error{
    EmptyDebugMemoryText,
    DebugMemoryTextTooLong,
    InvalidDebugMemoryUtf8,
    HiddenDebugMemoryControl,
    DebugMemoryCountOutOfRange,
    DebugInstructionCountOutOfRange,
    DebugMemoryOffsetOutOfRange,
    DebugInstructionOffsetOutOfRange,
    DebugMemoryEncodingTooLarge,
    InvalidDebugMemoryEncoding,
};

/// Memory and instruction references are adapter-owned opaque strings. ZIDE
/// bounds and validates their presentation but never parses or rewrites them.
pub fn validateText(kind: TextKind, value: []const u8) ValidationError![]const u8 {
    if (value.len == 0) return error.EmptyDebugMemoryText;
    const limit: usize = switch (kind) {
        .memory_reference => max_memory_reference_bytes,
        .address => max_address_bytes,
        .instruction_bytes => max_instruction_bytes_text,
        .instruction => max_instruction_text_bytes,
        .symbol => max_symbol_bytes,
        .message => max_message_bytes,
        .source_path => max_source_path_bytes,
    };
    if (value.len > limit) return error.DebugMemoryTextTooLong;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidDebugMemoryUtf8;

    for (value, 0..) |byte, index| {
        if (text_integrity.hiddenControlLengthAt(value, index) != null) return error.HiddenDebugMemoryControl;
        if (byte < 0x20 and !(kind == .instruction and byte == '\t')) return error.HiddenDebugMemoryControl;
        if (byte == 0x7f) return error.HiddenDebugMemoryControl;
    }
    var view = std.unicode.Utf8View.init(value) catch return error.InvalidDebugMemoryUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint >= 0x80 and codepoint <= 0x9f) return error.HiddenDebugMemoryControl;
        if (isInvisibleCodepoint(codepoint)) return error.HiddenDebugMemoryControl;
    }
    return value;
}

pub fn validateReadCount(count: usize) ValidationError!usize {
    if (count == 0 or count > max_memory_bytes) return error.DebugMemoryCountOutOfRange;
    return count;
}

pub fn validateInstructionCount(count: usize) ValidationError!usize {
    if (count == 0 or count > max_instructions) return error.DebugInstructionCountOutOfRange;
    return count;
}

pub fn validateByteOffset(offset: i64) ValidationError!i64 {
    if (offset < -max_byte_offset or offset > max_byte_offset) return error.DebugMemoryOffsetOutOfRange;
    return offset;
}

pub fn validateInstructionOffset(offset: i64) ValidationError!i64 {
    if (offset < -max_instruction_offset or offset > max_instruction_offset) return error.DebugInstructionOffsetOutOfRange;
    return offset;
}

pub fn decodedMemorySize(encoded: []const u8) ValidationError!usize {
    if (encoded.len > max_encoded_memory_bytes) return error.DebugMemoryEncodingTooLarge;
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidDebugMemoryEncoding;
    if (decoded_size > max_memory_bytes) return error.DebugMemoryEncodingTooLarge;
    return decoded_size;
}

pub fn rejectionMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyDebugMemoryText => "debug memory metadata is empty",
        error.DebugMemoryTextTooLong => "debug memory metadata exceeds ZIDE's bounded size limit",
        error.InvalidDebugMemoryUtf8 => "debug memory metadata is not valid UTF-8",
        error.HiddenDebugMemoryControl => "debug memory metadata contains hidden or control characters",
        error.DebugMemoryCountOutOfRange => "memory reads must contain between 1 and 256 bytes",
        error.DebugInstructionCountOutOfRange => "disassembly requests must contain between 1 and 128 instructions",
        error.DebugMemoryOffsetOutOfRange => "memory byte offset exceeds ZIDE's bounded range",
        error.DebugInstructionOffsetOutOfRange => "instruction offset exceeds ZIDE's bounded range",
        error.DebugMemoryEncodingTooLarge => "debug adapter returned more memory than ZIDE requested",
        error.InvalidDebugMemoryEncoding => "debug adapter returned malformed base64 memory data",
        else => "invalid debug memory metadata",
    };
}

fn isInvisibleCodepoint(codepoint: u21) bool {
    return codepoint == 0x00a0 or
        codepoint == 0x00ad or
        codepoint == 0x034f or
        codepoint == 0x061c or
        codepoint == 0x1680 or
        (codepoint >= 0x115f and codepoint <= 0x1160) or
        (codepoint >= 0x17b4 and codepoint <= 0x17b5) or
        (codepoint >= 0x180b and codepoint <= 0x180e) or
        (codepoint >= 0x2000 and codepoint <= 0x200f) or
        (codepoint >= 0x2028 and codepoint <= 0x202f) or
        codepoint == 0x205f or
        (codepoint >= 0x2060 and codepoint <= 0x206f) or
        codepoint == 0x3000 or
        codepoint == 0x3164 or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
        codepoint == 0xfeff or
        codepoint == 0xffa0 or
        (codepoint >= 0xfff9 and codepoint <= 0xfffb) or
        (codepoint >= 0xe0100 and codepoint <= 0xe01ef);
}

test "debug memory boundary accepts visible opaque references and bounded requests" {
    try std.testing.expectEqualStrings("0x7fff:frame slot", try validateText(.memory_reference, "0x7fff:frame slot"));
    try std.testing.expectEqualStrings("mov\tqword ptr [rax], rbx", try validateText(.instruction, "mov\tqword ptr [rax], rbx"));
    try std.testing.expectEqual(@as(usize, 256), try validateReadCount(256));
    try std.testing.expectEqual(@as(usize, 128), try validateInstructionCount(128));
    try std.testing.expectEqual(@as(i64, -64), try validateByteOffset(-64));
    try std.testing.expectEqual(@as(usize, 4), try decodedMemorySize("AQIDBA=="));
}

test "debug memory boundary rejects hidden text oversized requests and malformed base64" {
    try std.testing.expectError(error.EmptyDebugMemoryText, validateText(.address, ""));
    try std.testing.expectError(error.HiddenDebugMemoryControl, validateText(.memory_reference, "slot\nnext"));
    try std.testing.expectError(error.HiddenDebugMemoryControl, validateText(.symbol, "rtl \xe2\x80\xae"));
    try std.testing.expectError(error.DebugMemoryCountOutOfRange, validateReadCount(max_memory_bytes + 1));
    try std.testing.expectError(error.DebugInstructionCountOutOfRange, validateInstructionCount(0));
    try std.testing.expectError(error.DebugMemoryOffsetOutOfRange, validateByteOffset(max_byte_offset + 1));
    try std.testing.expectError(error.InvalidDebugMemoryEncoding, decodedMemorySize("not base64"));
    const oversized = [_]u8{'A'} ** (max_encoded_memory_bytes + 1);
    try std.testing.expectError(error.DebugMemoryEncodingTooLarge, decodedMemorySize(&oversized));
}
