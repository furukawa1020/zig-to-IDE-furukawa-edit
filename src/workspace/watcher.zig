pub const WatchBackend = enum {
    native,
    polling,
    disabled,
};

pub const WatchConfig = struct {
    backend: WatchBackend = .polling,
    poll_interval_ms: u32 = 1000,
};

