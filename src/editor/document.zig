const std = @import("std");
const buffer = @import("buffer.zig");
const cursor = @import("cursor.zig");
const modes = @import("../language/modes.zig");
const multi_cursor = @import("multi_cursor.zig");
const types = @import("../core/types.zig");
const undo_mod = @import("undo.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Newline = buffer.Newline;
pub const ContentDigest = [Sha256.digest_length]u8;

pub const Document = struct {
    allocator: std.mem.Allocator,
    path: ?[]u8,
    language: modes.LanguageMode,
    text: buffer.TextBuffer,
    cursor: cursor.Cursor = .{},
    undo_stack: undo_mod.UndoStack,
    saved_digest: ContentDigest,
    dirty: bool = false,

    pub fn fromBytes(allocator: std.mem.Allocator, path: ?[]const u8, bytes: []const u8) !Document {
        return .{
            .allocator = allocator,
            .path = if (path) |p| try allocator.dupe(u8, p) else null,
            .language = if (path) |p| modes.detect(p) else .unknown,
            .text = try buffer.TextBuffer.initFromBytes(allocator, bytes),
            .undo_stack = undo_mod.UndoStack.init(allocator),
            .saved_digest = contentDigest(bytes),
        };
    }

    pub fn deinit(self: *Document) void {
        if (self.path) |p| self.allocator.free(p);
        self.undo_stack.deinit();
        self.text.deinit();
        self.* = undefined;
    }

    pub fn insert(self: *Document, offset: usize, bytes: []const u8) !void {
        try self.text.insertBytes(offset, bytes);
        try self.undo_stack.push("insert", .insert, offset, "", bytes);
        self.cursor.position = try self.positionFromOffset(offset + bytes.len);
        self.dirty = true;
    }

    pub fn deleteRange(self: *Document, start: usize, end: usize) !void {
        const before = try self.text.slice(start, end);
        try self.undo_stack.push("delete", .delete, start, before, "");
        try self.text.deleteRange(start, end);
        self.cursor.position = try self.positionFromOffset(start);
        self.dirty = true;
    }

    pub fn replaceRange(self: *Document, start: usize, end: usize, bytes: []const u8) !void {
        const before = try self.text.slice(start, end);
        try self.undo_stack.push("replace", .replace, start, before, bytes);
        try self.text.replaceRange(start, end, bytes);
        self.cursor.position = try self.positionFromOffset(start + bytes.len);
        self.dirty = true;
    }

    pub fn editAtCursors(self: *Document, edits: []const multi_cursor.Edit) ![]usize {
        const result = try multi_cursor.apply(self.allocator, self.text.bytes, edits);
        defer self.allocator.free(result.bytes);
        errdefer self.allocator.free(result.cursor_offsets);

        if (!std.mem.eql(u8, self.text.bytes, result.bytes)) {
            try self.replaceRange(0, self.text.bytes.len, result.bytes);
        }
        if (result.cursor_offsets.len > 0) {
            self.cursor.position = try self.positionFromOffset(result.cursor_offsets[0]);
        }
        return result.cursor_offsets;
    }

    pub fn typeText(self: *Document, selection_anchor: ?usize, bytes: []const u8) !TypeResult {
        const cursor_offset = @min(self.cursor.position.byte_offset, self.text.bytes.len);
        if (selection_anchor) |raw_anchor| {
            const anchor = @min(raw_anchor, self.text.bytes.len);
            if (anchor != cursor_offset) {
                const start = @min(anchor, cursor_offset);
                const end = @max(anchor, cursor_offset);
                if (bytes.len == 1) {
                    if (closingPair(bytes[0])) |closing| {
                        var replacement: std.Io.Writer.Allocating = .init(self.allocator);
                        defer replacement.deinit();
                        try replacement.writer.writeByte(bytes[0]);
                        try replacement.writer.writeAll(self.text.bytes[start..end]);
                        try replacement.writer.writeByte(closing);
                        try self.replaceRange(start, end, replacement.written());

                        const mapped_anchor = if (anchor < cursor_offset) start + 1 else end + 1;
                        const mapped_cursor = if (anchor < cursor_offset) end + 1 else start + 1;
                        self.cursor.position = try self.positionFromOffset(mapped_cursor);
                        return .{ .selection_anchor = mapped_anchor, .changed = true, .wrapped = true };
                    }
                }

                try self.replaceRange(start, end, bytes);
                return .{ .changed = true };
            }
        }

        if (bytes.len == 1) {
            const typed = bytes[0];
            if (isClosingByte(typed) and cursor_offset < self.text.bytes.len and self.text.bytes[cursor_offset] == typed) {
                self.cursor.position = try self.positionFromOffset(cursor_offset + 1);
                return .{ .changed = false };
            }
            if (closingPair(typed)) |closing| {
                if (shouldAutoClose(self.text.bytes, cursor_offset, typed)) {
                    const pair = [_]u8{ typed, closing };
                    try self.insert(cursor_offset, &pair);
                    self.cursor.position = try self.positionFromOffset(cursor_offset + 1);
                    return .{ .changed = true };
                }
            }
        }

        try self.insert(cursor_offset, bytes);
        return .{ .changed = bytes.len > 0 };
    }

    pub fn insertSmartNewline(self: *Document, selection_anchor: ?usize, indent_width: usize) !TypeResult {
        const cursor_offset = @min(self.cursor.position.byte_offset, self.text.bytes.len);
        if (selection_anchor) |raw_anchor| {
            const anchor = @min(raw_anchor, self.text.bytes.len);
            if (anchor != cursor_offset) {
                try self.replaceRange(@min(anchor, cursor_offset), @max(anchor, cursor_offset), self.preferredNewline());
                return .{ .changed = true };
            }
        }

        const line = try self.text.offsetToLine(cursor_offset);
        const line_start = self.text.lineStart(line) orelse cursor_offset;
        var indent_end = line_start;
        while (indent_end < cursor_offset and (self.text.bytes[indent_end] == ' ' or self.text.bytes[indent_end] == '\t')) : (indent_end += 1) {}
        const base_indent = self.text.bytes[line_start..indent_end];
        const opening = previousNonWhitespace(self.text.bytes, line_start, cursor_offset);
        const closing = if (cursor_offset < self.text.bytes.len) self.text.bytes[cursor_offset] else 0;
        const expand_pair = if (opening) |byte| isStructuralOpening(byte) and closingPair(byte) == closing else false;
        const add_indent = if (opening) |byte| isStructuralOpening(byte) else false;

        var inserted: std.Io.Writer.Allocating = .init(self.allocator);
        defer inserted.deinit();
        try inserted.writer.writeAll(self.preferredNewline());
        try inserted.writer.writeAll(base_indent);
        if (add_indent) try writeIndentUnit(&inserted.writer, base_indent, indent_width);
        const cursor_after_first_line = cursor_offset + inserted.written().len;
        if (expand_pair) {
            try inserted.writer.writeAll(self.preferredNewline());
            try inserted.writer.writeAll(base_indent);
        }

        try self.insert(cursor_offset, inserted.written());
        self.cursor.position = try self.positionFromOffset(cursor_after_first_line);
        return .{ .changed = true };
    }

    pub fn deleteBackwardSmart(self: *Document) !bool {
        const current = @min(self.cursor.position.byte_offset, self.text.bytes.len);
        if (current == 0) return false;
        if (current < self.text.bytes.len and isPair(self.text.bytes[current - 1], self.text.bytes[current])) {
            try self.deleteRange(current - 1, current + 1);
            return true;
        }
        const previous = try self.text.previousByteOffset(current);
        try self.deleteRange(previous, current);
        return true;
    }

    pub fn indentLines(self: *Document, anchor_offset: usize, cursor_offset: usize, indent: []const u8) !IndentationResult {
        if (indent.len == 0) {
            return .{
                .anchor_offset = @min(anchor_offset, self.text.bytes.len),
                .cursor_offset = @min(cursor_offset, self.text.bytes.len),
                .changed = false,
            };
        }

        const selected = try self.lineRangeForOffsets(anchor_offset, cursor_offset);
        const first = self.lineRange(selected.start_line) orelse return error.InvalidLineRange;
        const last = self.lineRange(selected.end_line) orelse return error.InvalidLineRange;
        const mapped_anchor = self.mapOffsetAfterIndent(anchor_offset, selected, indent.len);
        const mapped_cursor = self.mapOffsetAfterIndent(cursor_offset, selected, indent.len);

        var replacement: std.Io.Writer.Allocating = .init(self.allocator);
        defer replacement.deinit();
        var line = selected.start_line;
        while (line <= selected.end_line) : (line += 1) {
            const range = self.lineRange(line) orelse continue;
            try replacement.writer.writeAll(indent);
            try replacement.writer.writeAll(self.text.bytes[range.start..range.end]);
        }

        try self.replaceRange(first.start, last.end, replacement.written());
        self.cursor.position = try self.positionFromOffset(mapped_cursor);
        return .{ .anchor_offset = mapped_anchor, .cursor_offset = mapped_cursor, .changed = true };
    }

    pub fn outdentLines(self: *Document, anchor_offset: usize, cursor_offset: usize, tab_width: usize) !IndentationResult {
        const width = @max(tab_width, 1);
        const selected = try self.lineRangeForOffsets(anchor_offset, cursor_offset);
        const first = self.lineRange(selected.start_line) orelse return error.InvalidLineRange;
        const last = self.lineRange(selected.end_line) orelse return error.InvalidLineRange;
        const mapped_anchor = self.mapOffsetAfterOutdent(anchor_offset, selected, width);
        const mapped_cursor = self.mapOffsetAfterOutdent(cursor_offset, selected, width);

        var replacement: std.Io.Writer.Allocating = .init(self.allocator);
        defer replacement.deinit();
        var changed = false;
        var line = selected.start_line;
        while (line <= selected.end_line) : (line += 1) {
            const range = self.lineRange(line) orelse continue;
            const remove = removableIndent(self.text.bytes[range.start..range.content_end], width);
            changed = changed or remove > 0;
            try replacement.writer.writeAll(self.text.bytes[range.start + remove .. range.end]);
        }
        if (!changed) {
            return .{ .anchor_offset = mapped_anchor, .cursor_offset = mapped_cursor, .changed = false };
        }

        try self.replaceRange(first.start, last.end, replacement.written());
        self.cursor.position = try self.positionFromOffset(mapped_cursor);
        return .{ .anchor_offset = mapped_anchor, .cursor_offset = mapped_cursor, .changed = true };
    }

    pub fn reloadFromBytes(self: *Document, bytes: []const u8) !void {
        const previous = self.cursor.position;
        var next = try buffer.TextBuffer.initFromBytes(self.allocator, bytes);
        errdefer next.deinit();

        const line = @min(previous.line, next.lineCount() - 1);
        const column = @min(previous.column, next.lineSlice(line).len);
        const offset = try next.lineColumnToOffset(line, column);
        const position: types.Position = .{ .line = line, .column = column, .byte_offset = offset };

        self.text.deinit();
        self.text = next;
        self.undo_stack.clear();
        self.cursor.position = position;
        self.saved_digest = contentDigest(bytes);
        self.dirty = false;
    }

    pub fn markSaved(self: *Document) void {
        self.saved_digest = contentDigest(self.text.bytes);
        self.dirty = false;
    }

    pub fn insertPreferredNewline(self: *Document, offset: usize) !void {
        try self.insert(offset, self.preferredNewline());
    }

    pub fn normalizeNewlines(self: *Document, target: Newline) !bool {
        const target_bytes = switch (target) {
            .lf => "\n",
            .crlf => "\r\n",
            else => return error.UnsupportedNewlineStyle,
        };

        var rewritten: std.Io.Writer.Allocating = .init(self.allocator);
        defer rewritten.deinit();

        var changed = false;
        var i: usize = 0;
        while (i < self.text.bytes.len) {
            const byte = self.text.bytes[i];
            if (byte == '\r') {
                if (i + 1 < self.text.bytes.len and self.text.bytes[i + 1] == '\n') {
                    if (!std.mem.eql(u8, self.text.bytes[i .. i + 2], target_bytes)) changed = true;
                    try rewritten.writer.writeAll(target_bytes);
                    i += 2;
                    continue;
                }

                changed = true;
                try rewritten.writer.writeAll(target_bytes);
                i += 1;
                continue;
            }

            if (byte == '\n') {
                if (!std.mem.eql(u8, self.text.bytes[i .. i + 1], target_bytes)) changed = true;
                try rewritten.writer.writeAll(target_bytes);
                i += 1;
                continue;
            }

            try rewritten.writer.writeByte(byte);
            i += 1;
        }

        if (!changed) return false;

        const before_cursor = self.cursor.position;
        try self.replaceRange(0, self.text.bytes.len, rewritten.written());
        const target_line = @min(before_cursor.line, self.text.lineCount() - 1);
        const target_column = @min(before_cursor.column, self.text.lineSlice(target_line).len);
        const target_offset = try self.text.lineColumnToOffset(target_line, target_column);
        self.cursor.position = try self.positionFromOffset(target_offset);
        return true;
    }

    pub fn preferredNewline(self: *const Document) []const u8 {
        return switch (self.text.newline) {
            .crlf => "\r\n",
            else => "\n",
        };
    }

    pub fn newlineLabel(self: *const Document) []const u8 {
        return newlineLabelFor(self.text.newline);
    }

    pub fn encodingLabel(self: *const Document) []const u8 {
        return if (self.text.valid_utf8) "UTF-8" else "BYTES";
    }

    pub fn deleteLine(self: *Document, line: usize) !bool {
        if (line >= self.text.lineCount()) return false;
        const range = self.lineRange(line) orelse return false;
        try self.deleteRange(range.start, range.end);
        const target_line = @min(line, if (self.text.lineCount() == 0) 0 else self.text.lineCount() - 1);
        const target_offset = self.text.lineColumnToOffset(target_line, 0) catch @min(range.start, self.text.bytes.len);
        self.cursor.position = try self.positionFromOffset(target_offset);
        return true;
    }

    pub fn duplicateLine(self: *Document, line: usize) !bool {
        if (line >= self.text.lineCount()) return false;
        const range = self.lineRange(line) orelse return false;
        const content = self.text.bytes[range.start..range.content_end];
        const line_ending = self.text.bytes[range.content_end..range.end];
        const column = self.cursor.position.column;

        var duplicated: std.Io.Writer.Allocating = .init(self.allocator);
        defer duplicated.deinit();
        if (line_ending.len == 0) try duplicated.writer.writeAll(self.preferredNewline());
        try duplicated.writer.writeAll(content);
        if (line_ending.len > 0) try duplicated.writer.writeAll(line_ending);

        const inserted = duplicated.written();
        try self.insert(range.end, inserted);
        const new_line = @min(line + 1, if (self.text.lineCount() == 0) 0 else self.text.lineCount() - 1);
        const target_column = @min(column, self.text.lineSlice(new_line).len);
        const target_offset = try self.text.lineColumnToOffset(new_line, target_column);
        self.cursor.position = try self.positionFromOffset(target_offset);
        return true;
    }

    pub fn moveLineUp(self: *Document, line: usize) !bool {
        if (line == 0 or line >= self.text.lineCount()) return false;
        return try self.moveAdjacentLines(line - 1, line, line - 1);
    }

    pub fn moveLineDown(self: *Document, line: usize) !bool {
        if (line + 1 >= self.text.lineCount()) return false;
        return try self.moveAdjacentLines(line, line + 1, line + 1);
    }

    pub fn toggleComment(self: *Document, start_offset: usize, end_offset: usize) !?CommentToggleResult {
        if (modes.lineComment(self.language)) |prefix| {
            const range = try self.lineRangeForOffsets(start_offset, end_offset);
            return try self.toggleLineComment(prefix, range.start_line, range.end_line);
        }
        if (modes.blockComment(self.language)) |comment| {
            return try self.toggleBlockComment(comment, start_offset, end_offset);
        }
        return null;
    }

    pub fn undo(self: *Document) !bool {
        const changed = try self.undo_stack.undo(&self.text);
        if (changed) self.dirty = true;
        return changed;
    }

    pub fn redo(self: *Document) !bool {
        const changed = try self.undo_stack.redo(&self.text);
        if (changed) self.dirty = true;
        return changed;
    }

    pub fn positionFromOffset(self: *const Document, offset: usize) !types.Position {
        const lc = try self.text.offsetToLineColumn(offset);
        return .{ .line = lc.line, .column = lc.column, .byte_offset = offset };
    }

    fn moveAdjacentLines(self: *Document, first_line: usize, second_line: usize, target_line: usize) !bool {
        const first = self.lineRange(first_line) orelse return false;
        const second = self.lineRange(second_line) orelse return false;
        const column = self.cursor.position.column;

        var replacement: std.Io.Writer.Allocating = .init(self.allocator);
        defer replacement.deinit();
        try replacement.writer.writeAll(self.text.bytes[second.start..second.content_end]);
        try replacement.writer.writeAll(self.text.bytes[first.content_end..second.start]);
        try replacement.writer.writeAll(self.text.bytes[first.start..first.content_end]);
        try replacement.writer.writeAll(self.text.bytes[second.content_end..second.end]);

        try self.replaceRange(first.start, second.end, replacement.written());
        const target_column = @min(column, self.text.lineSlice(target_line).len);
        const target_offset = try self.text.lineColumnToOffset(target_line, target_column);
        self.cursor.position = try self.positionFromOffset(target_offset);
        return true;
    }

    fn lineRangeForOffsets(self: *const Document, start_offset: usize, end_offset: usize) !LineSelection {
        const clamped_start = @min(start_offset, self.text.bytes.len);
        const clamped_end = @min(end_offset, self.text.bytes.len);
        const first = @min(clamped_start, clamped_end);
        const last_raw = @max(clamped_start, clamped_end);
        const last = if (last_raw > first) last_raw - 1 else first;
        return .{
            .start_line = try self.text.offsetToLine(first),
            .end_line = try self.text.offsetToLine(last),
        };
    }

    fn mapOffsetAfterIndent(self: *const Document, raw_offset: usize, selected: LineSelection, indent_len: usize) usize {
        const offset = @min(raw_offset, self.text.bytes.len);
        var insertions: usize = 0;
        var line = selected.start_line;
        while (line <= selected.end_line) : (line += 1) {
            const start = self.text.lineStart(line) orelse continue;
            if (start > offset) break;
            insertions += 1;
        }
        return offset + insertions * indent_len;
    }

    fn mapOffsetAfterOutdent(self: *const Document, raw_offset: usize, selected: LineSelection, tab_width: usize) usize {
        const offset = @min(raw_offset, self.text.bytes.len);
        var removed_before: usize = 0;
        var line = selected.start_line;
        while (line <= selected.end_line) : (line += 1) {
            const range = self.lineRange(line) orelse continue;
            if (offset < range.start) break;
            const remove = removableIndent(self.text.bytes[range.start..range.content_end], tab_width);
            if (offset <= range.start + remove) return range.start - removed_before;
            removed_before += remove;
        }
        return offset - removed_before;
    }

    fn toggleLineComment(self: *Document, prefix: []const u8, start_line: usize, end_line: usize) !CommentToggleResult {
        if (self.text.lineCount() == 0) return .line_commented;
        const first_line = @min(start_line, self.text.lineCount() - 1);
        const last_line = @min(@max(start_line, end_line), self.text.lineCount() - 1);
        const first = self.lineRange(first_line) orelse return .line_commented;
        const last = self.lineRange(last_line) orelse return .line_commented;

        var non_empty: usize = 0;
        var commented: usize = 0;
        var line = first_line;
        while (line <= last_line) : (line += 1) {
            const range = self.lineRange(line) orelse continue;
            const content = self.text.bytes[range.start..range.content_end];
            if (trimmedIsEmpty(content)) continue;
            non_empty += 1;
            if (commentPrefixOffset(content, prefix) != null) commented += 1;
        }
        const should_uncomment = non_empty > 0 and commented == non_empty;

        var replacement: std.Io.Writer.Allocating = .init(self.allocator);
        defer replacement.deinit();

        line = first_line;
        while (line <= last_line) : (line += 1) {
            const range = self.lineRange(line) orelse continue;
            const content = self.text.bytes[range.start..range.content_end];
            const ending = self.text.bytes[range.content_end..range.end];
            if (should_uncomment) {
                try writeUncommentedLine(&replacement.writer, content, prefix);
            } else {
                try writeCommentedLine(&replacement.writer, content, prefix);
            }
            try replacement.writer.writeAll(ending);
        }

        const cursor_line = self.cursor.position.line;
        const cursor_column = self.cursor.position.column;
        try self.replaceRange(first.start, last.end, replacement.written());
        const target_line = @min(cursor_line, self.text.lineCount() - 1);
        const target_column = @min(cursor_column, self.text.lineSlice(target_line).len);
        const target_offset = try self.text.lineColumnToOffset(target_line, target_column);
        self.cursor.position = try self.positionFromOffset(target_offset);
        return if (should_uncomment) .line_uncommented else .line_commented;
    }

    fn toggleBlockComment(self: *Document, comment: modes.BlockComment, start_offset: usize, end_offset: usize) !CommentToggleResult {
        var start = @min(start_offset, end_offset);
        var end = @max(start_offset, end_offset);
        start = @min(start, self.text.bytes.len);
        end = @min(end, self.text.bytes.len);
        if (start == end) {
            const line = try self.text.offsetToLine(start);
            const range = self.lineRange(line) orelse return .block_commented;
            start = range.start;
            end = range.content_end;
        }

        const content = self.text.bytes[start..end];
        var replacement: std.Io.Writer.Allocating = .init(self.allocator);
        defer replacement.deinit();

        const existing = blockCommentBounds(content, comment);
        if (existing) |bounds| {
            try replacement.writer.writeAll(content[0..bounds.start_prefix]);
            try replacement.writer.writeAll(content[bounds.inner_start..bounds.inner_end]);
            try replacement.writer.writeAll(content[bounds.end_suffix..]);
            try self.replaceRange(start, end, replacement.written());
            return .block_uncommented;
        }

        try replacement.writer.writeAll(comment.start);
        if (content.len > 0) try replacement.writer.writeByte(' ');
        try replacement.writer.writeAll(content);
        if (content.len > 0) try replacement.writer.writeByte(' ');
        try replacement.writer.writeAll(comment.end);
        try self.replaceRange(start, end, replacement.written());
        return .block_commented;
    }

    fn lineRange(self: *const Document, line: usize) ?LineRange {
        const start = self.text.lineStart(line) orelse return null;
        const content_end = start + self.text.lineSlice(line).len;
        const end = if (line + 1 < self.text.lineCount())
            self.text.lineStart(line + 1) orelse self.text.bytes.len
        else
            self.text.bytes.len;
        return .{ .start = start, .content_end = content_end, .end = end };
    }
};

pub fn contentDigest(bytes: []const u8) ContentDigest {
    var digest: ContentDigest = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}

const LineRange = struct {
    start: usize,
    content_end: usize,
    end: usize,
};

const LineSelection = struct {
    start_line: usize,
    end_line: usize,
};

pub const TypeResult = struct {
    selection_anchor: ?usize = null,
    changed: bool,
    wrapped: bool = false,
};

pub const IndentationResult = struct {
    anchor_offset: usize,
    cursor_offset: usize,
    changed: bool,
};

pub const CommentToggleResult = enum {
    line_commented,
    line_uncommented,
    block_commented,
    block_uncommented,
};

const BlockBounds = struct {
    start_prefix: usize,
    inner_start: usize,
    inner_end: usize,
    end_suffix: usize,
};

fn trimmedIsEmpty(bytes: []const u8) bool {
    return trimLineLeft(bytes).len == 0;
}

fn trimLineLeft(bytes: []const u8) []const u8 {
    var index: usize = 0;
    while (index < bytes.len and (bytes[index] == ' ' or bytes[index] == '\t')) : (index += 1) {}
    return bytes[index..];
}

fn commentPrefixOffset(content: []const u8, prefix: []const u8) ?usize {
    const trimmed = trimLineLeft(content);
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    return content.len - trimmed.len;
}

fn writeCommentedLine(writer: *std.Io.Writer, content: []const u8, prefix: []const u8) !void {
    const trimmed = trimLineLeft(content);
    const indent_len = content.len - trimmed.len;
    try writer.writeAll(content[0..indent_len]);
    try writer.writeAll(prefix);
    if (trimmed.len > 0) try writer.writeByte(' ');
    try writer.writeAll(trimmed);
}

fn writeUncommentedLine(writer: *std.Io.Writer, content: []const u8, prefix: []const u8) !void {
    const offset = commentPrefixOffset(content, prefix) orelse {
        try writer.writeAll(content);
        return;
    };
    try writer.writeAll(content[0..offset]);
    var rest_start = offset + prefix.len;
    if (rest_start < content.len and content[rest_start] == ' ') rest_start += 1;
    try writer.writeAll(content[rest_start..]);
}

fn blockCommentBounds(content: []const u8, comment: modes.BlockComment) ?BlockBounds {
    var left: usize = 0;
    while (left < content.len and std.ascii.isWhitespace(content[left])) : (left += 1) {}
    if (!std.mem.startsWith(u8, content[left..], comment.start)) return null;

    var right: usize = content.len;
    while (right > left and std.ascii.isWhitespace(content[right - 1])) : (right -= 1) {}
    if (right < left + comment.start.len + comment.end.len) return null;
    if (!std.mem.endsWith(u8, content[left..right], comment.end)) return null;

    var inner_start = left + comment.start.len;
    if (inner_start < right and content[inner_start] == ' ') inner_start += 1;
    var inner_end = right - comment.end.len;
    if (inner_end > inner_start and content[inner_end - 1] == ' ') inner_end -= 1;
    return .{
        .start_prefix = left,
        .inner_start = inner_start,
        .inner_end = inner_end,
        .end_suffix = right,
    };
}

fn closingPair(opening: u8) ?u8 {
    return switch (opening) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '\"' => '\"',
        '\'' => '\'',
        '`' => '`',
        else => null,
    };
}

fn isClosingByte(byte: u8) bool {
    return switch (byte) {
        ')', ']', '}', '\"', '\'', '`' => true,
        else => false,
    };
}

fn isPair(opening: u8, closing: u8) bool {
    return closingPair(opening) == closing;
}

fn isStructuralOpening(byte: u8) bool {
    return byte == '(' or byte == '[' or byte == '{';
}

fn shouldAutoClose(source: []const u8, offset: usize, opening: u8) bool {
    if (opening != '\"' and opening != '\'' and opening != '`') return true;
    if (isEscapedAt(source, offset)) return false;
    if (opening == '\'' and offset > 0 and offset < source.len and isWordByte(source[offset - 1]) and isWordByte(source[offset])) return false;
    return true;
}

fn isEscapedAt(source: []const u8, offset: usize) bool {
    var index = @min(offset, source.len);
    var backslashes: usize = 0;
    while (index > 0 and source[index - 1] == '\\') {
        backslashes += 1;
        index -= 1;
    }
    return backslashes % 2 == 1;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn removableIndent(content: []const u8, tab_width: usize) usize {
    if (content.len == 0) return 0;
    if (content[0] == '\t') return 1;
    var count: usize = 0;
    while (count < content.len and count < tab_width and content[count] == ' ') : (count += 1) {}
    return count;
}

fn previousNonWhitespace(source: []const u8, line_start: usize, cursor_offset: usize) ?u8 {
    var index = @min(cursor_offset, source.len);
    while (index > line_start) {
        index -= 1;
        if (!std.ascii.isWhitespace(source[index])) return source[index];
    }
    return null;
}

fn writeIndentUnit(writer: *std.Io.Writer, base_indent: []const u8, indent_width: usize) !void {
    if (std.mem.indexOfScalar(u8, base_indent, '\t') != null and std.mem.indexOfScalar(u8, base_indent, ' ') == null) {
        try writer.writeByte('\t');
        return;
    }
    try writer.splatByteAll(' ', @max(indent_width, 1));
}

pub fn newlineLabelFor(newline: Newline) []const u8 {
    return switch (newline) {
        .none => "NONE",
        .lf => "LF",
        .crlf => "CRLF",
        .mixed => "MIXED",
    };
}

test "document edit tracks dirty and undo" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "pub fn main() void {}\n");
    defer doc.deinit();

    try doc.insert(0, "// hello\n");
    try std.testing.expect(doc.dirty);
    try std.testing.expectEqualStrings("// hello\npub fn main() void {}\n", doc.text.bytes);

    try std.testing.expect(try doc.undo());
    try std.testing.expectEqualStrings("pub fn main() void {}\n", doc.text.bytes);
}

test "document reload replaces clean state and clears undo history" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "const old = 1;\n");
    defer doc.deinit();

    try doc.insert(0, "// local\n");
    try doc.reloadFromBytes("const fresh = 2;\n");
    try std.testing.expectEqualStrings("const fresh = 2;\n", doc.text.bytes);
    try std.testing.expect(!doc.dirty);
    try std.testing.expect(!(try doc.undo()));
}

test "document line operations duplicate delete and move" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "a\nb\nc\n");
    defer doc.deinit();

    try std.testing.expect(try doc.duplicateLine(1));
    try std.testing.expectEqualStrings("a\nb\nb\nc\n", doc.text.bytes);

    try std.testing.expect(try doc.deleteLine(1));
    try std.testing.expectEqualStrings("a\nb\nc\n", doc.text.bytes);
}

test "document line operations move distinct lines" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "a\nb\nc\n");
    defer doc.deinit();

    try std.testing.expect(try doc.moveLineUp(2));
    try std.testing.expectEqualStrings("a\nc\nb\n", doc.text.bytes);

    try std.testing.expect(try doc.moveLineDown(0));
    try std.testing.expectEqualStrings("c\na\nb\n", doc.text.bytes);
}

test "document line duplicate handles final line without newline" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "a\nb");
    defer doc.deinit();

    try std.testing.expect(try doc.duplicateLine(1));
    try std.testing.expectEqualStrings("a\nb\nb", doc.text.bytes);
}

test "document preserves preferred crlf on inserted newline" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "a\r\nb\r\n");
    defer doc.deinit();

    try doc.insertPreferredNewline(3);
    try std.testing.expectEqualStrings("a\r\n\r\nb\r\n", doc.text.bytes);
    try std.testing.expectEqual(buffer.Newline.crlf, doc.text.newline);
}

test "document normalizes mixed newlines explicitly" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "a\r\nb\nc\rd");
    defer doc.deinit();

    try std.testing.expectEqual(buffer.Newline.mixed, doc.text.newline);
    try std.testing.expect(try doc.normalizeNewlines(.lf));
    try std.testing.expectEqualStrings("a\nb\nc\nd", doc.text.bytes);
    try std.testing.expectEqual(buffer.Newline.lf, doc.text.newline);
}

test "document toggles language line comments over selected lines" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.py", "alpha\n    beta\n\n");
    defer doc.deinit();

    try std.testing.expectEqual(CommentToggleResult.line_commented, (try doc.toggleComment(0, doc.text.bytes.len)).?);
    try std.testing.expectEqualStrings("# alpha\n    # beta\n#\n", doc.text.bytes);

    try std.testing.expectEqual(CommentToggleResult.line_uncommented, (try doc.toggleComment(0, doc.text.bytes.len)).?);
    try std.testing.expectEqualStrings("alpha\n    beta\n\n", doc.text.bytes);
}

test "document toggles block comments for markup languages" {
    var doc = try Document.fromBytes(std.testing.allocator, "index.html", "<main>Hi</main>");
    defer doc.deinit();

    try std.testing.expectEqual(CommentToggleResult.block_commented, (try doc.toggleComment(0, doc.text.bytes.len)).?);
    try std.testing.expectEqualStrings("<!-- <main>Hi</main> -->", doc.text.bytes);

    try std.testing.expectEqual(CommentToggleResult.block_uncommented, (try doc.toggleComment(0, doc.text.bytes.len)).?);
    try std.testing.expectEqualStrings("<main>Hi</main>", doc.text.bytes);
}

test "document paired typing inserts skips wraps and deletes as one edit" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "value");
    defer doc.deinit();

    doc.cursor.position = try doc.positionFromOffset(0);
    var result = try doc.typeText(null, "(");
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings("()value", doc.text.bytes);
    try std.testing.expectEqual(@as(usize, 1), doc.cursor.position.byte_offset);

    result = try doc.typeText(null, ")");
    try std.testing.expect(!result.changed);
    try std.testing.expectEqual(@as(usize, 2), doc.cursor.position.byte_offset);

    doc.cursor.position = try doc.positionFromOffset(doc.text.bytes.len);
    result = try doc.typeText(2, "[");
    try std.testing.expect(result.wrapped);
    try std.testing.expectEqual(@as(?usize, 3), result.selection_anchor);
    try std.testing.expectEqualStrings("()[value]", doc.text.bytes);
    try std.testing.expectEqual(@as(usize, 8), doc.cursor.position.byte_offset);

    var empty = try Document.fromBytes(std.testing.allocator, "main.zig", "{}");
    defer empty.deinit();
    empty.cursor.position = try empty.positionFromOffset(1);
    try std.testing.expect(try empty.deleteBackwardSmart());
    try std.testing.expectEqualStrings("", empty.text.bytes);
    try std.testing.expect(try empty.undo());
    try std.testing.expectEqualStrings("{}", empty.text.bytes);
}

test "document quote pairing does not split apostrophes or escaped quotes" {
    var doc = try Document.fromBytes(std.testing.allocator, "notes.txt", "dont");
    defer doc.deinit();

    doc.cursor.position = try doc.positionFromOffset(3);
    _ = try doc.typeText(null, "'");
    try std.testing.expectEqualStrings("don't", doc.text.bytes);

    var escaped = try Document.fromBytes(std.testing.allocator, "main.zig", "\\");
    defer escaped.deinit();
    escaped.cursor.position = try escaped.positionFromOffset(1);
    _ = try escaped.typeText(null, "\"");
    try std.testing.expectEqualStrings("\\\"", escaped.text.bytes);
}

test "document indents and outdents selected lines with mapped selection" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "alpha\n  beta\n\tgamma\n");
    defer doc.deinit();

    const indented = try doc.indentLines(0, 13, "    ");
    try std.testing.expect(indented.changed);
    try std.testing.expectEqualStrings("    alpha\n      beta\n\tgamma\n", doc.text.bytes);
    try std.testing.expectEqual(@as(usize, 4), indented.anchor_offset);
    try std.testing.expectEqual(@as(usize, 21), indented.cursor_offset);
    try std.testing.expect(try doc.undo());
    try std.testing.expectEqualStrings("alpha\n  beta\n\tgamma\n", doc.text.bytes);

    const outdented = try doc.outdentLines(0, doc.text.bytes.len, 4);
    try std.testing.expect(outdented.changed);
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", doc.text.bytes);
    try std.testing.expectEqual(@as(usize, 0), outdented.anchor_offset);
    try std.testing.expectEqual(@as(usize, 17), outdented.cursor_offset);
}

test "document smart newline expands structural pairs as one undo step" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "fn main() void {}");
    defer doc.deinit();

    const opening = std.mem.indexOfScalar(u8, doc.text.bytes, '{').?;
    doc.cursor.position = try doc.positionFromOffset(opening + 1);
    const result = try doc.insertSmartNewline(null, 4);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings("fn main() void {\n    \n}", doc.text.bytes);
    try std.testing.expectEqual(opening + 1 + "\n    ".len, doc.cursor.position.byte_offset);
    try std.testing.expect(try doc.undo());
    try std.testing.expectEqualStrings("fn main() void {}", doc.text.bytes);
}

test "document smart newline preserves crlf and tab indentation" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "\tif (ready) {}");
    defer doc.deinit();

    doc.text.newline = .crlf;
    const opening = std.mem.indexOfScalar(u8, doc.text.bytes, '{').?;
    doc.cursor.position = try doc.positionFromOffset(opening + 1);
    _ = try doc.insertSmartNewline(null, 4);
    try std.testing.expectEqualStrings("\tif (ready) {\r\n\t\t\r\n\t}", doc.text.bytes);
}

test "document smart newline does not expand quote pairs as blocks" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "\"\"");
    defer doc.deinit();

    doc.cursor.position = try doc.positionFromOffset(1);
    _ = try doc.insertSmartNewline(null, 4);
    try std.testing.expectEqualStrings("\"\n\"", doc.text.bytes);
    try std.testing.expectEqual(@as(usize, 2), doc.cursor.position.byte_offset);
}

test "document multi cursor edit is one undo step" {
    var doc = try Document.fromBytes(std.testing.allocator, "main.zig", "alpha\nbeta\n");
    defer doc.deinit();

    const edits = [_]multi_cursor.Edit{
        .{ .start = 5, .end = 5, .replacement = "!", .cursor_in_replacement = 1 },
        .{ .start = 10, .end = 10, .replacement = "!", .cursor_in_replacement = 1 },
    };
    const cursors = try doc.editAtCursors(&edits);
    defer std.testing.allocator.free(cursors);

    try std.testing.expectEqualStrings("alpha!\nbeta!\n", doc.text.bytes);
    try std.testing.expectEqualSlices(usize, &.{ 6, 12 }, cursors);
    try std.testing.expect(try doc.undo());
    try std.testing.expectEqualStrings("alpha\nbeta\n", doc.text.bytes);
    try std.testing.expect(!(try doc.undo()));
}
