pub const StepKind = enum {
    build,
    test_step,
    run,
    docs,
    custom,
};

pub const BuildStep = struct {
    name: []const u8,
    kind: StepKind,
    description: []const u8 = "",
};

pub const BuildPlan = struct {
    steps: []const BuildStep = &.{},
};

