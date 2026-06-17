pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

pub const Split = struct {
    first: Rect,
    second: Rect,
};

pub fn splitVertical(rect: Rect, first_width: u16) Split {
    const left_width = @min(rect.width, first_width);
    return .{
        .first = .{ .x = rect.x, .y = rect.y, .width = left_width, .height = rect.height },
        .second = .{ .x = rect.x + left_width, .y = rect.y, .width = rect.width - left_width, .height = rect.height },
    };
}

pub fn splitHorizontal(rect: Rect, first_height: u16) Split {
    const top_height = @min(rect.height, first_height);
    return .{
        .first = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = top_height },
        .second = .{ .x = rect.x, .y = rect.y + top_height, .width = rect.width, .height = rect.height - top_height },
    };
}

