pub const Confidence = enum {
    exact,
    inferred,
    partial,
    unknown,
};

pub const TypeKind = enum {
    integer,
    float,
    bool,
    void_type,
    pointer,
    slice,
    array,
    optional,
    error_union,
    function,
    container,
    comptime_value,
    unknown,
};

pub const TypeInfo = struct {
    kind: TypeKind,
    display: []const u8,
    confidence: Confidence = .unknown,
};

