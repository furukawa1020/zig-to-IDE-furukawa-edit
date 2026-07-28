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

    pub fn formatScmSummary(self: *const State, buffer: []u8) []const u8 {
        const issue_count = if (self.issues_loaded) self.issueCount() else null;
        const pull_count = if (self.live) |live|
            live.pulls.len
        else if (self.issues_loaded)
            self.pullRequestCount()
        else
            null;
        const repository = if (self.live) |live| live.repository.full_name else "not loaded";
        const authentication = if (self.live) |live| @tagName(live.token_source) else "-";
        const action = if (self.live) |live|
            if (live.runs.len > 0)
                if (live.runs[0].conclusion.len > 0)
                    live.runs[0].conclusion
                else
                    live.runs[0].status
            else
                "none"
        else
            "not loaded";

        var issues_buf: [32]u8 = undefined;
        const issues = if (issue_count) |count|
            std.fmt.bufPrint(issues_buf[0..], "{d}", .{count}) catch "?"
        else
            "-";
        var pulls_buf: [32]u8 = undefined;
        const pulls = if (pull_count) |count|
            std.fmt.bufPrint(pulls_buf[0..], "{d}", .{count}) catch "?"
        else
            "-";
        var draft_buf: [32]u8 = undefined;
        const draft = if (self.last_created_pull) |pull|
            std.fmt.bufPrint(draft_buf[0..], "#{d}", .{pull.number}) catch "yes"
        else
            "-";

        return std.fmt.bufPrint(
            buffer,
            "GITHUB  {s}  PR:{s}  issues:{s}  actions:{s}  draft:{s}  auth:{s}",
            .{ repository, pulls, issues, action, draft, authentication },
        ) catch "GITHUB  live status unavailable";
    }

    pub fn hasFailure(self: *const State) bool {
        if (self.latest_failure != null) return true;
        const live = self.live orelse return false;
        return live.runs.len > 0 and isFailureConclusion(live.runs[0].conclusion);
    }

    pub fn primaryUrl(self: *const State) ?[]const u8 {
        if (self.last_created_pull) |pull| {
            if (isSafeGitHubWebUrl(pull.html_url)) return pull.html_url;
        }
        if (self.live) |live| {
            if (isSafeGitHubWebUrl(live.repository.html_url)) return live.repository.html_url;
        }
        return null;
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

pub fn isSafeGitHubWebUrl(url: []const u8) bool {
    const prefix = "https://github.com/";
    if (url.len > 4096 or !std.unicode.utf8ValidateSlice(url)) return false;
    if (!std.mem.startsWith(u8, url, prefix) or url.len == prefix.len) return false;
    for (url[prefix.len..]) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\\') return false;
    }
    return true;
}

fn isFailureConclusion(value: []const u8) bool {
    return std.mem.eql(u8, value, "failure") or
        std.mem.eql(u8, value, "timed_out") or
        std.mem.eql(u8, value, "cancelled") or
        std.mem.eql(u8, value, "action_required") or
        std.mem.eql(u8, value, "startup_failure");
}

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

    var summary_buffer: [256]u8 = undefined;
    const summary = state.formatScmSummary(summary_buffer[0..]);
    try std.testing.expect(std.mem.indexOf(u8, summary, "PR:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "issues:1") != null);
}

test "GitHub GUI state only exposes exact HTTPS github.com URLs" {
    try std.testing.expect(isSafeGitHubWebUrl("https://github.com/owner/repo"));
    try std.testing.expect(isSafeGitHubWebUrl("https://github.com/owner/repo/pull/7"));
    try std.testing.expect(!isSafeGitHubWebUrl("http://github.com/owner/repo"));
    try std.testing.expect(!isSafeGitHubWebUrl("https://github.com.evil.example/owner/repo"));
    try std.testing.expect(!isSafeGitHubWebUrl("https://github.com/owner/repo\n--inject"));
    try std.testing.expect(!isSafeGitHubWebUrl("https://github.com/owner\\repo"));
    try std.testing.expect(!isSafeGitHubWebUrl("https://github.com/\xff"));
}
