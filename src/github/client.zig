const std = @import("std");

pub const TokenSource = enum {
    none,
    github_token,
    gh_token,
};

pub const Token = struct {
    value: []u8,
    source: TokenSource,

    pub fn deinit(self: *Token, allocator: std.mem.Allocator) void {
        secureZero(self.value);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const Repository = struct {
    owner: []u8,
    name: []u8,
    full_name: []u8,
    html_url: []u8,
    default_branch: []u8,
    private: bool = false,
    open_issues_count: usize = 0,
    stargazers_count: usize = 0,
    forks_count: usize = 0,

    pub fn deinit(self: *Repository, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.name);
        allocator.free(self.full_name);
        allocator.free(self.html_url);
        allocator.free(self.default_branch);
        self.* = undefined;
    }
};

pub const PullRequest = struct {
    number: u64,
    title: []u8,
    user: []u8,
    html_url: []u8,
    draft: bool = false,

    pub fn deinit(self: *PullRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.user);
        allocator.free(self.html_url);
        self.* = undefined;
    }
};

pub const Issue = struct {
    number: u64,
    title: []u8,
    user: []u8,
    html_url: []u8,
    comments: usize = 0,
    pull_request: bool = false,

    pub fn deinit(self: *Issue, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.user);
        allocator.free(self.html_url);
        self.* = undefined;
    }
};

pub const WorkflowRun = struct {
    id: u64,
    name: []u8,
    status: []u8,
    conclusion: []u8,
    html_url: []u8,

    pub fn deinit(self: *WorkflowRun, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.status);
        allocator.free(self.conclusion);
        allocator.free(self.html_url);
        self.* = undefined;
    }
};

pub const WorkflowJob = struct {
    id: u64,
    name: []u8,
    status: []u8,
    conclusion: []u8,
    html_url: []u8,

    pub fn deinit(self: *WorkflowJob, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.status);
        allocator.free(self.conclusion);
        allocator.free(self.html_url);
        self.* = undefined;
    }
};

pub const FailureLog = struct {
    run: WorkflowRun,
    job: WorkflowJob,
    log_excerpt: []u8,
    truncated: bool = false,

    pub fn deinit(self: *FailureLog, allocator: std.mem.Allocator) void {
        self.run.deinit(allocator);
        self.job.deinit(allocator);
        allocator.free(self.log_excerpt);
        self.* = undefined;
    }
};

pub const LiveOverview = struct {
    allocator: std.mem.Allocator,
    repository: Repository,
    pulls: []PullRequest,
    runs: []WorkflowRun,
    token_source: TokenSource,
    status_code: u16 = 200,

    pub fn deinit(self: *LiveOverview) void {
        self.repository.deinit(self.allocator);
        for (self.pulls) |*pull| pull.deinit(self.allocator);
        if (self.pulls.len > 0) self.allocator.free(self.pulls);
        for (self.runs) |*run| run.deinit(self.allocator);
        if (self.runs.len > 0) self.allocator.free(self.runs);
        self.* = undefined;
    }
};

pub const FetchOptions = struct {
    token: ?[]const u8 = null,
    token_source: TokenSource = .none,
    max_body_bytes: usize = 512 * 1024,
};

pub const CreatePullRequestInput = struct {
    title: []const u8,
    head: []const u8,
    base: []const u8,
    body: []const u8 = "",
    draft: bool = true,
};

const EndpointOptions = struct {
    method: std.http.Method = .GET,
    payload: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

const LogExcerpt = struct {
    text: []u8,
    truncated: bool,
};

pub fn tokenFromEnv(allocator: std.mem.Allocator, environ: std.process.Environ) !?Token {
    var map = try std.process.Environ.createMap(environ, allocator);
    defer map.deinit();

    if (try tokenFromMap(allocator, &map, "GITHUB_TOKEN", .github_token)) |token| return token;
    if (try tokenFromMap(allocator, &map, "GH_TOKEN", .gh_token)) |token| return token;
    return null;
}

pub fn fetchRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: []const u8,
    repo: []const u8,
    options: FetchOptions,
) !Repository {
    var http_client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer http_client.deinit();

    const repo_json = try fetchEndpoint(allocator, &http_client, owner, repo, "", options, .{});
    defer allocator.free(repo_json.body);
    return try parseRepository(allocator, repo_json.body);
}

pub fn fetchLiveOverview(
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: []const u8,
    repo: []const u8,
    options: FetchOptions,
) !LiveOverview {
    var http_client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer http_client.deinit();

    const repo_json = try fetchEndpoint(allocator, &http_client, owner, repo, "", options, .{});
    defer allocator.free(repo_json.body);
    var repository = try parseRepository(allocator, repo_json.body);
    errdefer repository.deinit(allocator);

    const pulls_json = try fetchEndpoint(allocator, &http_client, owner, repo, "/pulls?state=open&per_page=20", options, .{});
    defer allocator.free(pulls_json.body);
    const pulls = try parsePulls(allocator, pulls_json.body, 20);
    errdefer {
        for (pulls) |*pull| pull.deinit(allocator);
        if (pulls.len > 0) allocator.free(pulls);
    }

    const runs_json = try fetchEndpoint(allocator, &http_client, owner, repo, "/actions/runs?per_page=5", options, .{});
    defer allocator.free(runs_json.body);
    const runs = try parseWorkflowRuns(allocator, runs_json.body, 5);
    errdefer {
        for (runs) |*run| run.deinit(allocator);
        if (runs.len > 0) allocator.free(runs);
    }

    return .{
        .allocator = allocator,
        .repository = repository,
        .pulls = pulls,
        .runs = runs,
        .token_source = options.token_source,
        .status_code = repo_json.status_code,
    };
}

pub fn fetchIssues(
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: []const u8,
    repo: []const u8,
    options: FetchOptions,
) ![]Issue {
    var http_client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer http_client.deinit();

    const issues_json = try fetchEndpoint(allocator, &http_client, owner, repo, "/issues?state=open&per_page=20", options, .{});
    defer allocator.free(issues_json.body);
    return try parseIssues(allocator, issues_json.body, 20);
}

pub fn fetchLatestFailureLog(
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: []const u8,
    repo: []const u8,
    options: FetchOptions,
) !FailureLog {
    var http_client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer http_client.deinit();

    const runs_json = try fetchEndpoint(allocator, &http_client, owner, repo, "/actions/runs?status=failure&per_page=10", options, .{});
    defer allocator.free(runs_json.body);
    const runs = try parseWorkflowRuns(allocator, runs_json.body, 10);
    if (runs.len == 0) return error.GitHubNoFailedWorkflowRun;

    const selected_run_index = findFailureRun(runs);
    defer {
        for (runs, 0..) |*run, index| {
            if (index != selected_run_index) run.deinit(allocator);
        }
        allocator.free(runs);
    }

    var selected_run = runs[selected_run_index];
    errdefer selected_run.deinit(allocator);

    const jobs_suffix = try std.fmt.allocPrint(allocator, "/actions/runs/{d}/jobs?per_page=20", .{selected_run.id});
    defer allocator.free(jobs_suffix);
    const jobs_json = try fetchEndpoint(allocator, &http_client, owner, repo, jobs_suffix, options, .{});
    defer allocator.free(jobs_json.body);
    const jobs = try parseWorkflowJobs(allocator, jobs_json.body, 20);
    if (jobs.len == 0) return error.GitHubNoWorkflowJobs;

    const selected_job_index = findFailureJob(jobs);
    defer {
        for (jobs, 0..) |*job, index| {
            if (index != selected_job_index) job.deinit(allocator);
        }
        allocator.free(jobs);
    }

    var selected_job = jobs[selected_job_index];
    errdefer selected_job.deinit(allocator);

    const logs_suffix = try std.fmt.allocPrint(allocator, "/actions/jobs/{d}/logs", .{selected_job.id});
    defer allocator.free(logs_suffix);
    const logs = try fetchEndpoint(allocator, &http_client, owner, repo, logs_suffix, options, .{});
    defer allocator.free(logs.body);

    const excerpt = try tailExcerpt(allocator, logs.body, 64 * 1024);
    errdefer allocator.free(excerpt.text);

    return .{
        .run = selected_run,
        .job = selected_job,
        .log_excerpt = excerpt.text,
        .truncated = excerpt.truncated,
    };
}

pub fn createDraftPullRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: []const u8,
    repo: []const u8,
    options: FetchOptions,
    input: CreatePullRequestInput,
) !PullRequest {
    if (options.token == null) return error.GitHubTokenRequired;

    var http_client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer http_client.deinit();

    const payload = try makeCreatePullRequestPayload(allocator, input);
    defer allocator.free(payload);

    const pull_json = try fetchEndpoint(allocator, &http_client, owner, repo, "/pulls", options, .{
        .method = .POST,
        .payload = payload,
        .content_type = "application/json",
    });
    defer allocator.free(pull_json.body);

    return try parsePullRequest(allocator, pull_json.body);
}

pub const ResponseBody = struct {
    status_code: u16,
    body: []u8,
};

fn fetchEndpoint(
    allocator: std.mem.Allocator,
    http_client: *std.http.Client,
    owner: []const u8,
    repo: []const u8,
    suffix: []const u8,
    options: FetchOptions,
    endpoint: EndpointOptions,
) !ResponseBody {
    const url = try apiUrl(allocator, owner, repo, suffix);
    defer allocator.free(url);

    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();

    var header_count: usize = 0;
    var headers: [5]std.http.Header = undefined;
    headers[header_count] = .{ .name = "Accept", .value = "application/vnd.github+json" };
    header_count += 1;
    headers[header_count] = .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" };
    header_count += 1;
    headers[header_count] = .{ .name = "User-Agent", .value = "zide-secure-ide" };
    header_count += 1;
    if (endpoint.content_type) |content_type| {
        headers[header_count] = .{ .name = "Content-Type", .value = content_type };
        header_count += 1;
    }

    var auth_buf: [512]u8 = undefined;
    if (options.token) |token| {
        headers[header_count] = .{
            .name = "Authorization",
            .value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return error.TokenTooLong,
        };
        header_count += 1;
    }

    const result = try http_client.fetch(.{
        .location = .{ .url = url },
        .method = endpoint.method,
        .payload = endpoint.payload,
        .response_writer = &body_writer.writer,
        .extra_headers = headers[0..header_count],
        .keep_alive = false,
    });
    if (body_writer.written().len > options.max_body_bytes) return error.GitHubResponseTooLarge;
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) return error.GitHubHttpStatus;

    return .{
        .status_code = @intCast(@intFromEnum(result.status)),
        .body = try body_writer.toOwnedSlice(),
    };
}

pub fn apiUrl(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8, suffix: []const u8) ![]u8 {
    if (!isSafeSlug(owner) or !isSafeSlug(repo)) return error.InvalidGitHubRepository;
    return try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}{s}", .{ owner, repo, suffix });
}

pub fn parseRepository(allocator: std.mem.Allocator, bytes: []const u8) !Repository {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const full_name = try dupeStringField(allocator, object, "full_name", "(unknown)");
    errdefer allocator.free(full_name);
    const name = try dupeStringField(allocator, object, "name", "(unknown)");
    errdefer allocator.free(name);
    const html_url = try dupeStringField(allocator, object, "html_url", "");
    errdefer allocator.free(html_url);
    const default_branch = try dupeStringField(allocator, object, "default_branch", "");
    errdefer allocator.free(default_branch);
    const owner = try ownerFromRepositoryJson(allocator, object);
    errdefer allocator.free(owner);
    return .{
        .owner = owner,
        .name = name,
        .full_name = full_name,
        .html_url = html_url,
        .default_branch = default_branch,
        .private = boolField(object, "private", false),
        .open_issues_count = intField(object, "open_issues_count", 0),
        .stargazers_count = intField(object, "stargazers_count", 0),
        .forks_count = intField(object, "forks_count", 0),
    };
}

pub fn parsePullRequest(allocator: std.mem.Allocator, bytes: []const u8) !PullRequest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    return try parsePullObject(allocator, parsed.value.object);
}

pub fn parsePulls(allocator: std.mem.Allocator, bytes: []const u8, limit: usize) ![]PullRequest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const array = parsed.value.array;
    var pulls = std.array_list.Managed(PullRequest).init(allocator);
    errdefer {
        for (pulls.items) |*pull| pull.deinit(allocator);
        pulls.deinit();
    }
    for (array.items, 0..) |value, index| {
        if (index >= limit) break;
        {
            var pull = try parsePullObject(allocator, value.object);
            errdefer pull.deinit(allocator);
            try pulls.append(pull);
        }
    }
    return try pulls.toOwnedSlice();
}

pub fn parseIssues(allocator: std.mem.Allocator, bytes: []const u8, limit: usize) ![]Issue {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const array = parsed.value.array;
    var issues = std.array_list.Managed(Issue).init(allocator);
    errdefer {
        for (issues.items) |*issue| issue.deinit(allocator);
        issues.deinit();
    }
    for (array.items, 0..) |value, index| {
        if (index >= limit) break;
        {
            var issue = try parseIssueObject(allocator, value.object);
            errdefer issue.deinit(allocator);
            try issues.append(issue);
        }
    }
    return try issues.toOwnedSlice();
}

pub fn parseWorkflowRuns(allocator: std.mem.Allocator, bytes: []const u8, limit: usize) ![]WorkflowRun {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const runs_value = object.get("workflow_runs") orelse return &.{};
    const array = runs_value.array;
    var runs = std.array_list.Managed(WorkflowRun).init(allocator);
    errdefer {
        for (runs.items) |*run| run.deinit(allocator);
        runs.deinit();
    }
    for (array.items, 0..) |value, index| {
        if (index >= limit) break;
        {
            var run = try parseWorkflowRunObject(allocator, value.object);
            errdefer run.deinit(allocator);
            try runs.append(run);
        }
    }
    return try runs.toOwnedSlice();
}

pub fn parseWorkflowJobs(allocator: std.mem.Allocator, bytes: []const u8, limit: usize) ![]WorkflowJob {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const jobs_value = object.get("jobs") orelse return &.{};
    const array = jobs_value.array;
    var jobs = std.array_list.Managed(WorkflowJob).init(allocator);
    errdefer {
        for (jobs.items) |*job| job.deinit(allocator);
        jobs.deinit();
    }
    for (array.items, 0..) |value, index| {
        if (index >= limit) break;
        {
            var job = try parseWorkflowJobObject(allocator, value.object);
            errdefer job.deinit(allocator);
            try jobs.append(job);
        }
    }
    return try jobs.toOwnedSlice();
}

pub fn makeCreatePullRequestPayload(allocator: std.mem.Allocator, input: CreatePullRequestInput) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try json.beginObject();
    try json.objectField("title");
    try json.write(input.title);
    try json.objectField("head");
    try json.write(input.head);
    try json.objectField("base");
    try json.write(input.base);
    try json.objectField("body");
    try json.write(input.body);
    try json.objectField("draft");
    try json.write(input.draft);
    try json.endObject();

    return try out.toOwnedSlice();
}

fn parsePullObject(allocator: std.mem.Allocator, object: std.json.ObjectMap) !PullRequest {
    const title = try dupeStringField(allocator, object, "title", "(untitled)");
    errdefer allocator.free(title);
    const html_url = try dupeStringField(allocator, object, "html_url", "");
    errdefer allocator.free(html_url);
    const user = try userLogin(allocator, object);
    errdefer allocator.free(user);
    return .{
        .number = intFieldU64(object, "number", 0),
        .title = title,
        .user = user,
        .html_url = html_url,
        .draft = boolField(object, "draft", false),
    };
}

fn parseIssueObject(allocator: std.mem.Allocator, object: std.json.ObjectMap) !Issue {
    const title = try dupeStringField(allocator, object, "title", "(untitled)");
    errdefer allocator.free(title);
    const html_url = try dupeStringField(allocator, object, "html_url", "");
    errdefer allocator.free(html_url);
    const user = try userLogin(allocator, object);
    errdefer allocator.free(user);
    return .{
        .number = intFieldU64(object, "number", 0),
        .title = title,
        .user = user,
        .html_url = html_url,
        .comments = intField(object, "comments", 0),
        .pull_request = object.get("pull_request") != null,
    };
}

fn parseWorkflowRunObject(allocator: std.mem.Allocator, object: std.json.ObjectMap) !WorkflowRun {
    const name = try dupeStringField(allocator, object, "name", "(workflow)");
    errdefer allocator.free(name);
    const status = try dupeStringField(allocator, object, "status", "");
    errdefer allocator.free(status);
    const conclusion = try dupeOptionalStringField(allocator, object, "conclusion", "none");
    errdefer allocator.free(conclusion);
    const html_url = try dupeStringField(allocator, object, "html_url", "");
    errdefer allocator.free(html_url);
    return .{
        .id = intFieldU64(object, "id", 0),
        .name = name,
        .status = status,
        .conclusion = conclusion,
        .html_url = html_url,
    };
}

fn parseWorkflowJobObject(allocator: std.mem.Allocator, object: std.json.ObjectMap) !WorkflowJob {
    const name = try dupeStringField(allocator, object, "name", "(job)");
    errdefer allocator.free(name);
    const status = try dupeStringField(allocator, object, "status", "");
    errdefer allocator.free(status);
    const conclusion = try dupeOptionalStringField(allocator, object, "conclusion", "none");
    errdefer allocator.free(conclusion);
    const html_url = try dupeStringField(allocator, object, "html_url", "");
    errdefer allocator.free(html_url);
    return .{
        .id = intFieldU64(object, "id", 0),
        .name = name,
        .status = status,
        .conclusion = conclusion,
        .html_url = html_url,
    };
}

fn findFailureRun(runs: []const WorkflowRun) usize {
    for (runs, 0..) |run, index| {
        if (isFailureConclusion(run.conclusion)) return index;
    }
    return 0;
}

fn findFailureJob(jobs: []const WorkflowJob) usize {
    for (jobs, 0..) |job, index| {
        if (isFailureConclusion(job.conclusion)) return index;
    }
    return 0;
}

fn isFailureConclusion(value: []const u8) bool {
    return std.mem.eql(u8, value, "failure") or
        std.mem.eql(u8, value, "timed_out") or
        std.mem.eql(u8, value, "cancelled") or
        std.mem.eql(u8, value, "action_required");
}

fn tailExcerpt(allocator: std.mem.Allocator, bytes: []const u8, limit: usize) !LogExcerpt {
    const truncated = bytes.len > limit;
    const start = if (truncated) bytes.len - limit else 0;
    return .{
        .text = try allocator.dupe(u8, bytes[start..]),
        .truncated = truncated,
    };
}

fn tokenFromMap(
    allocator: std.mem.Allocator,
    map: *const std.process.Environ.Map,
    name: []const u8,
    source: TokenSource,
) !?Token {
    const raw = map.get(name) orelse return null;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return null;
    return .{
        .value = try allocator.dupe(u8, value),
        .source = source,
    };
}

fn ownerFromRepositoryJson(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    if (object.get("owner")) |owner_value| {
        return try dupeStringField(allocator, owner_value.object, "login", "(unknown)");
    }
    return try allocator.dupe(u8, "(unknown)");
}

fn userLogin(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    if (object.get("user")) |user_value| {
        return try dupeStringField(allocator, user_value.object, "login", "(unknown)");
    }
    return try allocator.dupe(u8, "(unknown)");
}

fn dupeStringField(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, fallback: []const u8) ![]u8 {
    const value = object.get(key) orelse return try allocator.dupe(u8, fallback);
    return switch (value) {
        .string => |text| try allocator.dupe(u8, text),
        else => try allocator.dupe(u8, fallback),
    };
}

fn dupeOptionalStringField(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, fallback: []const u8) ![]u8 {
    const value = object.get(key) orelse return try allocator.dupe(u8, fallback);
    return switch (value) {
        .string => |text| try allocator.dupe(u8, text),
        .null => try allocator.dupe(u8, fallback),
        else => try allocator.dupe(u8, fallback),
    };
}

fn boolField(object: std.json.ObjectMap, key: []const u8, fallback: bool) bool {
    const value = object.get(key) orelse return fallback;
    return switch (value) {
        .bool => |flag| flag,
        else => fallback,
    };
}

fn intField(object: std.json.ObjectMap, key: []const u8, fallback: usize) usize {
    const value = object.get(key) orelse return fallback;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else fallback,
        else => fallback,
    };
}

fn intFieldU64(object: std.json.ObjectMap, key: []const u8, fallback: u64) u64 {
    const value = object.get(key) orelse return fallback;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else fallback,
        else => fallback,
    };
}

fn isSafeSlug(value: []const u8) bool {
    if (value.len == 0 or value.len > 100) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') continue;
        return false;
    }
    return true;
}

fn secureZero(bytes: []u8) void {
    @memset(bytes, 0);
    std.mem.doNotOptimizeAway(bytes.ptr);
}

test "github api url validates owner and repo slugs" {
    const url = try apiUrl(std.testing.allocator, "owner-name", "repo.name", "/pulls?state=open");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.github.com/repos/owner-name/repo.name/pulls?state=open", url);
    try std.testing.expectError(error.InvalidGitHubRepository, apiUrl(std.testing.allocator, "../owner", "repo", ""));
}

test "parse repository summary" {
    var repo = try parseRepository(std.testing.allocator,
        \\{
        \\  "full_name": "owner/repo",
        \\  "name": "repo",
        \\  "html_url": "https://github.com/owner/repo",
        \\  "default_branch": "main",
        \\  "private": false,
        \\  "open_issues_count": 7,
        \\  "stargazers_count": 42,
        \\  "forks_count": 3,
        \\  "owner": { "login": "owner" }
        \\}
        \\
    );
    defer repo.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("owner", repo.owner);
    try std.testing.expectEqualStrings("owner/repo", repo.full_name);
    try std.testing.expectEqual(@as(usize, 7), repo.open_issues_count);
    try std.testing.expectEqual(@as(usize, 42), repo.stargazers_count);
}

test "parse pull requests and workflow runs" {
    const pulls = try parsePulls(std.testing.allocator,
        \\[
        \\  {
        \\    "number": 12,
        \\    "title": "Ship it",
        \\    "html_url": "https://github.com/owner/repo/pull/12",
        \\    "draft": true,
        \\    "user": { "login": "alice" }
        \\  }
        \\]
        \\
    , 10);
    defer {
        for (pulls) |*pull| pull.deinit(std.testing.allocator);
        std.testing.allocator.free(pulls);
    }
    try std.testing.expectEqual(@as(usize, 1), pulls.len);
    try std.testing.expectEqual(@as(u64, 12), pulls[0].number);
    try std.testing.expectEqualStrings("alice", pulls[0].user);
    try std.testing.expect(pulls[0].draft);

    const runs = try parseWorkflowRuns(std.testing.allocator,
        \\{
        \\  "workflow_runs": [
        \\    {
        \\      "id": 1001,
        \\      "name": "CI",
        \\      "status": "completed",
        \\      "conclusion": "success",
        \\      "html_url": "https://github.com/owner/repo/actions/runs/1"
        \\    }
        \\  ]
        \\}
        \\
    , 5);
    defer {
        for (runs) |*run| run.deinit(std.testing.allocator);
        std.testing.allocator.free(runs);
    }
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try std.testing.expectEqual(@as(u64, 1001), runs[0].id);
    try std.testing.expectEqualStrings("CI", runs[0].name);
    try std.testing.expectEqualStrings("success", runs[0].conclusion);
}

test "parse issues and workflow jobs" {
    const issues = try parseIssues(std.testing.allocator,
        \\[
        \\  {
        \\    "number": 3,
        \\    "title": "Fix thing",
        \\    "html_url": "https://github.com/owner/repo/issues/3",
        \\    "comments": 2,
        \\    "user": { "login": "bob" }
        \\  },
        \\  {
        \\    "number": 4,
        \\    "title": "Draft PR",
        \\    "html_url": "https://github.com/owner/repo/pull/4",
        \\    "comments": 0,
        \\    "pull_request": {},
        \\    "user": { "login": "alice" }
        \\  }
        \\]
        \\
    , 10);
    defer {
        for (issues) |*issue| issue.deinit(std.testing.allocator);
        std.testing.allocator.free(issues);
    }
    try std.testing.expectEqual(@as(usize, 2), issues.len);
    try std.testing.expect(!issues[0].pull_request);
    try std.testing.expect(issues[1].pull_request);

    const jobs = try parseWorkflowJobs(std.testing.allocator,
        \\{
        \\  "jobs": [
        \\    {
        \\      "id": 222,
        \\      "name": "test",
        \\      "status": "completed",
        \\      "conclusion": "failure",
        \\      "html_url": "https://github.com/owner/repo/actions/runs/1/job/222"
        \\    }
        \\  ]
        \\}
        \\
    , 10);
    defer {
        for (jobs) |*job| job.deinit(std.testing.allocator);
        std.testing.allocator.free(jobs);
    }
    try std.testing.expectEqual(@as(usize, 1), jobs.len);
    try std.testing.expectEqual(@as(u64, 222), jobs[0].id);
    try std.testing.expectEqualStrings("failure", jobs[0].conclusion);
}

test "create pull request payload is explicit JSON" {
    const payload = try makeCreatePullRequestPayload(std.testing.allocator, .{
        .title = "Draft: feature",
        .head = "feature",
        .base = "main",
        .body = "Created by ZIDE",
        .draft = true,
    });
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"title\":\"Draft: feature\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"head\":\"feature\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"base\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"draft\":true") != null);
}
