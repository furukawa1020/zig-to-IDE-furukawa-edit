const std = @import("std");
const client = @import("client.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    live: ?client.LiveOverview = null,
    issues: []client.Issue = &.{},
    issues_loaded: bool = false,
    latest_failure: ?client.FailureLog = null,
    last_created_pull: ?client.PullRequest = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        self.clearLive();
        self.clearIssues();
        self.clearLatestFailure();
        self.clearLastCreatedPull();
        self.* = undefined;
    }

    pub fn replaceLive(self: *State, live: client.LiveOverview) void {
        self.clearLive();
        self.live = live;
    }

    pub fn replaceIssues(self: *State, issues: []client.Issue) void {
        self.clearIssues();
        self.issues = issues;
        self.issues_loaded = true;
    }

    pub fn replaceLatestFailure(self: *State, failure: client.FailureLog) void {
        self.clearLatestFailure();
        self.latest_failure = failure;
    }

    pub fn replaceLastCreatedPull(self: *State, pull: client.PullRequest) void {
        self.clearLastCreatedPull();
        self.last_created_pull = pull;
    }

    pub fn issueCount(self: *const State) usize {
        var count: usize = 0;
        for (self.issues) |issue| {
            if (!issue.pull_request) count += 1;
        }
        return count;
    }

    pub fn pullRequestCount(self: *const State) usize {
        var count: usize = 0;
        for (self.issues) |issue| {
            if (issue.pull_request) count += 1;
        }
        return count;
    }

    fn clearLive(self: *State) void {
        if (self.live) |*live| live.deinit();
        self.live = null;
    }

    fn clearIssues(self: *State) void {
        for (self.issues) |*issue| issue.deinit(self.allocator);
        if (self.issues.len > 0) self.allocator.free(self.issues);
        self.issues = &.{};
        self.issues_loaded = false;
    }

    fn clearLatestFailure(self: *State) void {
        if (self.latest_failure) |*failure| failure.deinit(self.allocator);
        self.latest_failure = null;
    }

    fn clearLastCreatedPull(self: *State) void {
        if (self.last_created_pull) |*pull| pull.deinit(self.allocator);
        self.last_created_pull = null;
    }
};

test "GitHub GUI state distinguishes issues from pull requests" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    const issues = try std.testing.allocator.alloc(client.Issue, 2);
    issues[0] = .{
        .number = 1,
        .title = try std.testing.allocator.dupe(u8, "Issue"),
        .user = try std.testing.allocator.dupe(u8, "alice"),
        .html_url = try std.testing.allocator.dupe(u8, "https://github.com/o/r/issues/1"),
    };
    issues[1] = .{
        .number = 2,
        .title = try std.testing.allocator.dupe(u8, "Pull"),
        .user = try std.testing.allocator.dupe(u8, "bob"),
        .html_url = try std.testing.allocator.dupe(u8, "https://github.com/o/r/pull/2"),
        .pull_request = true,
    };
    state.replaceIssues(issues);

    try std.testing.expect(state.issues_loaded);
    try std.testing.expectEqual(@as(usize, 1), state.issueCount());
    try std.testing.expectEqual(@as(usize, 1), state.pullRequestCount());
}
