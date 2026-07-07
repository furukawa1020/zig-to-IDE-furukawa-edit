const std = @import("std");

const release_zip_path = "zig-out/release/zide-windows-x86_64.zip";
const release_zip_name = "zide-windows-x86_64.zip";
const download_zip_path = "download/zide-windows-x86_64.zip";
const checksum_path = "download/CHECKSUMS.sha256";
const latest_release_url = "https://github.com/furukawa1020/zig-to-IDE-furukawa-edit/releases/latest/download/zide-windows-x86_64.zip";
const site_url = "https://furukawa1020.github.io/zig-to-IDE-furukawa-edit/";
const og_image_path = "ogp.png";
const og_image_source_path = "tools/site/ogp.png";
const og_image_url = site_url ++ og_image_path;
const share_url_encoded = "https%3A%2F%2Ffurukawa1020.github.io%2Fzig-to-IDE-furukawa-edit%2F";
const share_title_encoded = "ZIDE%20-%20Zig-native%20secure%20IDE";
const share_text_encoded = "ZIDE%20-%20Zig-native%20secure%20IDE%20with%20visible%20trust%20boundaries.%20https%3A%2F%2Ffurukawa1020.github.io%2Fzig-to-IDE-furukawa-edit%2F";
const share_text_multiline_encoded = "ZIDE%20-%20Zig-native%20secure%20IDE%20with%20visible%20trust%20boundaries.%0Ahttps%3A%2F%2Ffurukawa1020.github.io%2Fzig-to-IDE-furukawa-edit%2F";
const share_x_url = "https://x.com/intent/post?text=" ++ share_text_encoded;
const share_bluesky_url = "https://bsky.app/intent/compose?text=" ++ share_text_multiline_encoded;
const share_linkedin_url = "https://www.linkedin.com/sharing/share-offsite/?url=" ++ share_url_encoded;
const share_facebook_url = "https://www.facebook.com/sharer/sharer.php?u=" ++ share_url_encoded;
const share_email_url = "mailto:?subject=" ++ share_title_encoded ++ "&body=" ++ share_text_multiline_encoded;
const share_email_href = "mailto:?subject=" ++ share_title_encoded ++ "&amp;body=" ++ share_text_multiline_encoded;

const DownloadInfo = struct {
    href: []const u8,
    source: []const u8,
    size: ?u64,
    sha256: ?[64]u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out_dir = if (args.len > 1) args[1] else "zig-out/site";
    try generateSite(allocator, out_dir);
}

fn generateSite(allocator: std.mem.Allocator, out_dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, out_dir);
    try createSubdir(allocator, out_dir, "assets");
    try createSubdir(allocator, out_dir, "download");

    const info = try copyReleaseZipIfPresent(allocator, out_dir);
    try writeAsset(allocator, out_dir, "assets/site.css", siteCss);
    try writeHeroBitmap(allocator, out_dir);
    try copyOpenGraphImage(allocator, out_dir);
    try writeHtml(allocator, out_dir, "index.html", info);
    try writeHtml(allocator, out_dir, "404.html", info);
    try writeManifest(allocator, out_dir, info);
}

fn createSubdir(allocator: std.mem.Allocator, out_dir: []const u8, sub_path: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ out_dir, sub_path });
    defer allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, path);
}

fn copyReleaseZipIfPresent(allocator: std.mem.Allocator, out_dir: []const u8) !DownloadInfo {
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, release_zip_path, allocator, .limited(512 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{
            .href = latest_release_url,
            .source = "GitHub Releases",
            .size = null,
            .sha256 = null,
        },
        else => return err,
    };
    defer allocator.free(bytes);

    try writeAssetBytes(allocator, out_dir, download_zip_path, bytes);
    const sha = try sha256Hex(bytes);
    var checksum: std.Io.Writer.Allocating = .init(allocator);
    defer checksum.deinit();
    try checksum.writer.print("{s}  {s}\n", .{ sha[0..], release_zip_name });
    try writeAssetBytes(allocator, out_dir, checksum_path, checksum.written());

    return .{
        .href = download_zip_path,
        .source = "bundled static download",
        .size = bytes.len,
        .sha256 = sha,
    };
}

fn copyOpenGraphImage(allocator: std.mem.Allocator, out_dir: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, og_image_source_path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(bytes);
    try validateOpenGraphPng(bytes);
    try writeAssetBytes(allocator, out_dir, og_image_path, bytes);
}

fn validateOpenGraphPng(bytes: []const u8) !void {
    const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    if (bytes.len < 33) return error.InvalidOpenGraphImage;
    if (!std.mem.eql(u8, bytes[0..8], png_signature[0..])) return error.InvalidOpenGraphImage;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return error.InvalidOpenGraphImage;

    const width = readBe32(bytes[16..20]);
    const height = readBe32(bytes[20..24]);
    if (width != 1200 or height != 630) return error.InvalidOpenGraphImage;
}

fn readBe32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

fn writeHtml(allocator: std.mem.Allocator, out_dir: []const u8, file_name: []const u8, info: DownloadInfo) !void {
    var html: std.Io.Writer.Allocating = .init(allocator);
    defer html.deinit();
    const writer = &html.writer;

    const size_text = if (info.size) |size| try std.fmt.allocPrint(allocator, "{d}.{d} MB", .{ size / (1024 * 1024), (size % (1024 * 1024)) * 10 / (1024 * 1024) }) else "release asset";
    defer if (info.size != null) allocator.free(size_text);
    const sha_text = if (info.sha256) |sha| sha[0..] else "available after the first bundled release";

    try writer.print(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <meta name="color-scheme" content="dark light">
        \\  <title>ZIDE - Zig-native secure IDE</title>
        \\  <meta name="description" content="ZIDE is a Zig-native IDE/workbench for multi-language editing, visible trust boundaries, safe Git inspection, and release artifact verification.">
        \\  <link rel="canonical" href="{s}">
        \\  <meta property="og:type" content="website">
        \\  <meta property="og:url" content="{s}">
        \\  <meta property="og:title" content="ZIDE">
        \\  <meta property="og:description" content="A Zig-native secure IDE/workbench with multi-language editing and local release verification.">
        \\  <meta property="og:image" content="{s}">
        \\  <meta property="og:image:secure_url" content="{s}">
        \\  <meta property="og:image:type" content="image/png">
        \\  <meta property="og:image:width" content="1200">
        \\  <meta property="og:image:height" content="630">
        \\  <meta property="og:image:alt" content="ZIDE secure IDE website screenshot">
        \\  <meta name="twitter:card" content="summary_large_image">
        \\  <meta name="twitter:title" content="ZIDE">
        \\  <meta name="twitter:description" content="A Zig-native secure IDE/workbench with multi-language editing and local release verification.">
        \\  <meta name="twitter:image" content="{s}">
        \\  <meta name="twitter:image:alt" content="ZIDE secure IDE website screenshot">
        \\  <link rel="stylesheet" href="assets/site.css">
        \\</head>
        \\<body>
        \\  <header class="site-header" aria-label="Primary">
        \\    <a class="brand" href="#top" aria-label="ZIDE home"><span>Z</span> ZIDE</a>
        \\    <nav>
        \\      <a href="#download">Download</a>
        \\      <a href="#security">Security</a>
        \\      <a href="#languages">Languages</a>
        \\      <a href="#deploy">Deploy</a>
        \\    </nav>
        \\  </header>
        \\
        \\  <main id="top">
        \\    <section class="hero" aria-labelledby="hero-title">
        \\      <div class="hero-shade"></div>
        \\      <div class="hero-copy">
        \\        <p class="eyebrow">Zig-built workbench / visible trust boundaries / local artifact verification</p>
        \\        <h1 id="hero-title">ZIDE</h1>
        \\        <p class="lede">A secure multi-language IDE that treats every boundary as something you can see, review, and verify before it runs.</p>
        \\        <div class="hero-actions">
        \\          <a class="button primary" href="{s}" download>Download for Windows</a>
        \\          <a class="button" href="#security">See the trust model</a>
        \\        </div>
        \\        <dl class="release-strip" aria-label="Current release">
        \\          <div><dt>Artifact</dt><dd>{s}</dd></div>
        \\          <div><dt>Source</dt><dd>{s}</dd></div>
        \\          <div><dt>SHA-256</dt><dd>{s}</dd></div>
        \\        </dl>
        \\      </div>
        \\    </section>
        \\
        \\    <section class="band share-band" id="share" aria-labelledby="share-title">
        \\      <div class="section-head">
        \\        <p class="eyebrow">Share</p>
        \\        <h2 id="share-title">Spread it without tracking scripts.</h2>
        \\      </div>
        \\      <div class="share-grid" aria-label="Share ZIDE">
        \\        <a class="share-link" href="{s}" target="_blank" rel="noopener noreferrer" aria-label="Share ZIDE on X"><span>X</span><strong>X</strong><em>Open a prepared post.</em></a>
        \\        <a class="share-link" href="{s}" target="_blank" rel="noopener noreferrer" aria-label="Share ZIDE on Bluesky"><span>BS</span><strong>Bluesky</strong><em>Compose with the page URL.</em></a>
        \\        <a class="share-link" href="{s}" target="_blank" rel="noopener noreferrer" aria-label="Share ZIDE on LinkedIn"><span>in</span><strong>LinkedIn</strong><em>Share to a professional feed.</em></a>
        \\        <a class="share-link" href="{s}" target="_blank" rel="noopener noreferrer" aria-label="Share ZIDE on Facebook"><span>f</span><strong>Facebook</strong><em>Open the share dialog.</em></a>
        \\        <a class="share-link" href="{s}" aria-label="Share ZIDE by email"><span>@</span><strong>Email</strong><em>Send the verified page link.</em></a>
        \\      </div>
        \\      <div class="share-url" aria-label="Canonical share URL"><code>{s}</code></div>
        \\    </section>
        \\
        \\    <section class="band download-band" id="download" aria-labelledby="download-title">
        \\      <div class="section-head">
        \\        <p class="eyebrow">Install</p>
        \\        <h2 id="download-title">Download, verify, run.</h2>
        \\      </div>
        \\      <div class="download-grid">
        \\        <article class="download-card">
        \\          <div class="platform">Windows x86_64</div>
        \\          <h3>ZIDE bundle</h3>
        \\          <p>Includes the GUI workbench and CLI/TUI entry point in one ZIP.</p>
        \\          <a class="button primary wide" href="{s}" download>Download {s}</a>
        \\          <code>{s}</code>
        \\        </article>
        \\        <article class="terminal-card" aria-label="Install commands">
        \\          <div class="terminal-bar"><span></span><span></span><span></span></div>
        \\          <pre><code>Expand-Archive .\zide-windows-x86_64.zip
        \\.\\zide-windows-x86_64\\zide-gui.exe
        \\.\\zide-windows-x86_64\\zide.exe command release.verify</code></pre>
        \\        </article>
        \\      </div>
        \\    </section>
        \\
        \\    <section class="band security-band" id="security" aria-labelledby="security-title">
        \\      <div class="section-head">
        \\        <p class="eyebrow">Security difference</p>
        \\        <h2 id="security-title">Trust is a first-class UI surface.</h2>
        \\      </div>
        \\      <div class="feature-grid">
        \\        <article><strong>Hook-free Git</strong><span>Reads repository metadata without running git hooks, filters, fsmonitor, or shell commands.</span></article>
        \\        <article><strong>Capability labels</strong><span>Commands are classified as safe, workspace_write, network_read, network_write, or external_command.</span></article>
        \\        <article><strong>Release Gate</strong><span>ZIP structure, paths, CRC32, and embedded SHA-256 values are verified before publish.</span></article>
        \\        <article><strong>Text integrity</strong><span>Hidden controls, newline policy, and suspicious language-specific boundaries are surfaced inside the editor.</span></article>
        \\      </div>
        \\    </section>
        \\
        \\    <section class="band languages-band" id="languages" aria-labelledby="languages-title">
        \\      <div class="section-head">
        \\        <p class="eyebrow">Polyglot editing</p>
        \\        <h2 id="languages-title">Zig-first, not Zig-only.</h2>
        \\      </div>
        \\      <ul class="language-list" aria-label="Recognized languages">
        \\        <li>Zig</li><li>Rust</li><li>Go</li><li>C</li><li>C++</li><li>Python</li><li>JavaScript</li><li>TypeScript</li><li>JSON</li><li>YAML</li><li>Markdown</li><li>Shell</li>
        \\      </ul>
        \\    </section>
        \\
        \\    <section class="band deploy-band" id="deploy" aria-labelledby="deploy-title">
        \\      <div class="section-head">
        \\        <p class="eyebrow">Built by Zig</p>
        \\        <h2 id="deploy-title">The site ships the same way the IDE does.</h2>
        \\      </div>
        \\      <div class="deploy-grid">
        \\        <div>
        \\          <p>Run one command to generate the page, product visual, static download, checksum file, and deployment manifest.</p>
        \\          <pre><code>zig build site</code></pre>
        \\        </div>
        \\        <ol>
        \\          <li>Build ZIDE GUI and CLI.</li>
        \\          <li>Create the release ZIP with <code>release.bundle</code>.</li>
        \\          <li>Verify the ZIP with <code>release.verify</code>.</li>
        \\          <li>Generate and deploy this site with Zig.</li>
        \\        </ol>
        \\      </div>
        \\    </section>
        \\  </main>
        \\
        \\  <footer>
        \\    <span>ZIDE</span>
        \\    <span>Generated by Zig. No Node, no frontend build chain.</span>
        \\  </footer>
        \\</body>
        \\</html>
        \\
    , .{
        site_url,
        site_url,
        og_image_url,
        og_image_url,
        og_image_url,
        info.href,
        release_zip_name,
        info.source,
        sha_text,
        share_x_url,
        share_bluesky_url,
        share_linkedin_url,
        share_facebook_url,
        share_email_href,
        site_url,
        info.href,
        size_text,
        sha_text,
    });

    try writeAssetBytes(allocator, out_dir, file_name, html.written());
}

const siteCss =
    \\:root {
    \\  color-scheme: dark;
    \\  --ink: #f4f7f8;
    \\  --muted: #aab4b8;
    \\  --line: #273238;
    \\  --panel: #11181c;
    \\  --panel-2: #172126;
    \\  --cyan: #42d9d5;
    \\  --green: #7de38b;
    \\  --amber: #ffd166;
    \\  --coral: #ff7f6e;
    \\  --black: #050708;
    \\}
    \\* { box-sizing: border-box; }
    \\html { scroll-behavior: smooth; }
    \\body {
    \\  margin: 0;
    \\  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    \\  background: var(--black);
    \\  color: var(--ink);
    \\  letter-spacing: 0;
    \\}
    \\a { color: inherit; text-decoration: none; }
    \\code, pre { font-family: "Cascadia Mono", "SFMono-Regular", Consolas, monospace; }
    \\.site-header {
    \\  position: fixed;
    \\  top: 0;
    \\  left: 0;
    \\  right: 0;
    \\  z-index: 10;
    \\  display: flex;
    \\  align-items: center;
    \\  justify-content: space-between;
    \\  padding: 18px clamp(18px, 4vw, 56px);
    \\  background: rgba(5, 7, 8, .82);
    \\  border-bottom: 1px solid rgba(255,255,255,.08);
    \\  backdrop-filter: blur(18px);
    \\}
    \\.brand { display: inline-flex; align-items: center; gap: 10px; font-weight: 760; }
    \\.brand span {
    \\  display: grid;
    \\  place-items: center;
    \\  width: 30px;
    \\  height: 30px;
    \\  background: var(--cyan);
    \\  color: #061012;
    \\  border-radius: 6px;
    \\}
    \\nav { display: flex; gap: clamp(14px, 2vw, 30px); color: var(--muted); font-size: 14px; }
    \\nav a:hover { color: var(--ink); }
    \\.hero {
    \\  min-height: 86svh;
    \\  position: relative;
    \\  display: flex;
    \\  align-items: flex-end;
    \\  padding: 118px clamp(20px, 6vw, 78px) 44px;
    \\  overflow: hidden;
    \\  background: #0b1114 url("hero.bmp") center / cover no-repeat;
    \\}
    \\.hero-shade {
    \\  position: absolute;
    \\  inset: 0;
    \\  background: rgba(2, 4, 5, .58);
    \\}
    \\.hero-copy { position: relative; max-width: 980px; }
    \\.eyebrow {
    \\  margin: 0 0 14px;
    \\  color: var(--cyan);
    \\  text-transform: uppercase;
    \\  font-size: 12px;
    \\  font-weight: 780;
    \\}
    \\h1 {
    \\  margin: 0;
    \\  font-size: clamp(82px, 16vw, 220px);
    \\  line-height: .78;
    \\  letter-spacing: 0;
    \\}
    \\h2 { margin: 0; font-size: clamp(34px, 5vw, 74px); line-height: .95; letter-spacing: 0; max-width: 900px; }
    \\h3 { margin: 8px 0 10px; font-size: 28px; }
    \\.lede {
    \\  max-width: 760px;
    \\  margin: 26px 0 0;
    \\  font-size: clamp(21px, 3vw, 34px);
    \\  line-height: 1.12;
    \\  color: #e9f0f2;
    \\}
    \\.hero-actions { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 32px; }
    \\.button {
    \\  display: inline-flex;
    \\  min-height: 48px;
    \\  align-items: center;
    \\  justify-content: center;
    \\  border: 1px solid rgba(255,255,255,.2);
    \\  border-radius: 8px;
    \\  padding: 0 18px;
    \\  font-weight: 760;
    \\  background: rgba(255,255,255,.08);
    \\}
    \\.button.primary { background: var(--cyan); color: #051113; border-color: var(--cyan); }
    \\.button.wide { width: 100%; }
    \\.release-strip {
    \\  display: grid;
    \\  grid-template-columns: repeat(3, minmax(0, 1fr));
    \\  gap: 1px;
    \\  margin: 34px 0 0;
    \\  max-width: 980px;
    \\  border: 1px solid rgba(255,255,255,.12);
    \\  background: rgba(255,255,255,.12);
    \\}
    \\.release-strip div { min-width: 0; padding: 16px; background: rgba(8,13,15,.76); }
    \\dt { margin: 0 0 8px; color: var(--muted); font-size: 12px; text-transform: uppercase; font-weight: 740; }
    \\dd { margin: 0; word-break: break-all; font-family: "Cascadia Mono", Consolas, monospace; font-size: 13px; }
    \\.band { padding: clamp(64px, 10vw, 132px) clamp(20px, 6vw, 78px); border-top: 1px solid var(--line); }
    \\.section-head { margin-bottom: 34px; }
    \\.download-band { background: #091011; }
    \\.share-band { background: #0d1112; }
    \\.security-band { background: #101517; }
    \\.languages-band { background: #080c0e; }
    \\.deploy-band { background: #131512; }
    \\.download-grid, .deploy-grid {
    \\  display: grid;
    \\  grid-template-columns: minmax(0, .86fr) minmax(0, 1.14fr);
    \\  gap: 18px;
    \\}
    \\.download-card, .terminal-card, .feature-grid article, .deploy-grid > div, .deploy-grid ol {
    \\  border: 1px solid var(--line);
    \\  background: var(--panel);
    \\  border-radius: 8px;
    \\}
    \\.download-card { padding: 24px; }
    \\.download-card p, .deploy-grid p { color: var(--muted); line-height: 1.55; }
    \\.platform { color: var(--green); font-weight: 760; text-transform: uppercase; font-size: 12px; }
    \\.download-card code {
    \\  display: block;
    \\  margin-top: 14px;
    \\  padding: 13px;
    \\  border-radius: 6px;
    \\  background: #071012;
    \\  color: var(--green);
    \\  font-size: 12px;
    \\  word-break: break-all;
    \\}
    \\.terminal-card { overflow: hidden; background: #070a0b; }
    \\.terminal-bar { display: flex; gap: 7px; padding: 14px; border-bottom: 1px solid #1f2a2e; }
    \\.terminal-bar span { width: 10px; height: 10px; border-radius: 50%; background: var(--coral); }
    \\.terminal-bar span:nth-child(2) { background: var(--amber); }
    \\.terminal-bar span:nth-child(3) { background: var(--green); }
    \\pre { margin: 0; padding: 22px; overflow-x: auto; color: #d8e8ea; line-height: 1.7; }
    \\.share-grid {
    \\  display: grid;
    \\  grid-template-columns: repeat(5, minmax(0, 1fr));
    \\  gap: 12px;
    \\}
    \\.share-link {
    \\  display: grid;
    \\  grid-template-columns: 42px minmax(0, 1fr);
    \\  gap: 12px;
    \\  align-items: center;
    \\  min-height: 108px;
    \\  padding: 16px;
    \\  border: 1px solid var(--line);
    \\  border-radius: 8px;
    \\  background: var(--panel);
    \\}
    \\.share-link:hover { border-color: rgba(66, 217, 213, .62); background: #152126; }
    \\.share-link span {
    \\  display: grid;
    \\  place-items: center;
    \\  width: 42px;
    \\  height: 42px;
    \\  border-radius: 8px;
    \\  background: var(--cyan);
    \\  color: #061012;
    \\  font-weight: 880;
    \\}
    \\.share-link strong { display: block; min-width: 0; font-size: 17px; }
    \\.share-link em {
    \\  display: block;
    \\  min-width: 0;
    \\  margin-top: 5px;
    \\  color: var(--muted);
    \\  font-size: 13px;
    \\  font-style: normal;
    \\  line-height: 1.35;
    \\}
    \\.share-url {
    \\  margin-top: 14px;
    \\  padding: 14px;
    \\  border: 1px solid var(--line);
    \\  border-radius: 8px;
    \\  background: #071012;
    \\}
    \\.share-url code { color: var(--green); word-break: break-all; font-size: 13px; }
    \\.feature-grid {
    \\  display: grid;
    \\  grid-template-columns: repeat(4, minmax(0, 1fr));
    \\  gap: 14px;
    \\}
    \\.feature-grid article { min-height: 190px; padding: 20px; }
    \\.feature-grid strong { display: block; margin-bottom: 14px; font-size: 20px; }
    \\.feature-grid span { color: var(--muted); line-height: 1.5; }
    \\.language-list {
    \\  list-style: none;
    \\  margin: 0;
    \\  padding: 0;
    \\  display: grid;
    \\  grid-template-columns: repeat(6, minmax(0, 1fr));
    \\  gap: 10px;
    \\}
    \\.language-list li {
    \\  padding: 16px;
    \\  border: 1px solid var(--line);
    \\  border-radius: 8px;
    \\  background: var(--panel-2);
    \\  color: #e8f0f1;
    \\  font-weight: 740;
    \\}
    \\.deploy-grid > div, .deploy-grid ol { padding: 24px; }
    \\.deploy-grid ol { margin: 0; color: #d8e0e1; line-height: 1.8; }
    \\.deploy-grid li { margin-bottom: 10px; }
    \\footer {
    \\  display: flex;
    \\  justify-content: space-between;
    \\  gap: 20px;
    \\  padding: 28px clamp(20px, 6vw, 78px);
    \\  border-top: 1px solid var(--line);
    \\  color: var(--muted);
    \\}
    \\footer span:first-child { color: var(--ink); font-weight: 800; }
    \\@media (max-width: 980px) {
    \\  nav { display: none; }
    \\  .release-strip, .download-grid, .deploy-grid, .feature-grid { grid-template-columns: 1fr; }
    \\  .share-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    \\  .language-list { grid-template-columns: repeat(3, minmax(0, 1fr)); }
    \\}
    \\@media (max-width: 620px) {
    \\  .hero { min-height: 84svh; padding-top: 96px; }
    \\  .release-strip { grid-template-columns: 1fr; }
    \\  .share-grid { grid-template-columns: 1fr; }
    \\  .language-list { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    \\  footer { flex-direction: column; }
    \\}
    \\
;

fn writeManifest(allocator: std.mem.Allocator, out_dir: []const u8, info: DownloadInfo) !void {
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    const sha_text = if (info.sha256) |sha| sha[0..] else "";
    const size = info.size orelse 0;
    try json.writer.print(
        \\{{
        \\  "name": "ZIDE",
        \\  "generated_by": "tools/site_gen.zig",
        \\  "site_url": "{s}",
        \\  "og_image": "{s}",
        \\  "share": {{
        \\    "x": "{s}",
        \\    "bluesky": "{s}",
        \\    "linkedin": "{s}",
        \\    "facebook": "{s}",
        \\    "email": "{s}"
        \\  }},
        \\  "download": "{s}",
        \\  "download_source": "{s}",
        \\  "size_bytes": {d},
        \\  "sha256": "{s}"
        \\}}
        \\
    , .{ site_url, og_image_url, share_x_url, share_bluesky_url, share_linkedin_url, share_facebook_url, share_email_url, info.href, info.source, size, sha_text });
    try writeAssetBytes(allocator, out_dir, "site-manifest.json", json.written());
}

fn writeHeroBitmap(allocator: std.mem.Allocator, out_dir: []const u8) !void {
    const width = 1600;
    const height = 1000;
    const row_stride = ((width * 3 + 3) / 4) * 4;
    const image_size = row_stride * height;
    const file_size = 54 + image_size;
    var bmp = try allocator.alloc(u8, file_size);
    defer allocator.free(bmp);
    @memset(bmp, 0);

    bmp[0] = 'B';
    bmp[1] = 'M';
    writeLe32(bmp[2..6], file_size);
    writeLe32(bmp[10..14], 54);
    writeLe32(bmp[14..18], 40);
    writeLe32(bmp[18..22], width);
    writeLe32(bmp[22..26], height);
    writeLe16(bmp[26..28], 1);
    writeLe16(bmp[28..30], 24);
    writeLe32(bmp[34..38], image_size);

    fillRect(bmp, width, height, row_stride, 0, 0, width, height, rgb(8, 12, 14));
    fillRect(bmp, width, height, row_stride, 100, 84, 1500, 856, rgb(14, 20, 24));
    fillRect(bmp, width, height, row_stride, 100, 84, 1500, 132, rgb(28, 36, 42));
    fillRect(bmp, width, height, row_stride, 120, 104, 18, 18, rgb(255, 127, 110));
    fillRect(bmp, width, height, row_stride, 148, 104, 18, 18, rgb(255, 209, 102));
    fillRect(bmp, width, height, row_stride, 176, 104, 18, 18, rgb(125, 227, 139));

    fillRect(bmp, width, height, row_stride, 100, 132, 310, 808, rgb(10, 15, 18));
    fillRect(bmp, width, height, row_stride, 410, 132, 790, 608, rgb(9, 13, 16));
    fillRect(bmp, width, height, row_stride, 1200, 132, 400, 608, rgb(13, 18, 22));
    fillRect(bmp, width, height, row_stride, 410, 740, 1190, 200, rgb(8, 11, 13));

    var y: i32 = 164;
    var i: usize = 0;
    while (i < 18) : (i += 1) {
        const accent = if (i % 5 == 0) rgb(66, 217, 213) else if (i % 7 == 0) rgb(125, 227, 139) else rgb(122, 136, 142);
        fillRect(bmp, width, height, row_stride, 130, y, 20, 3, accent);
        fillRect(bmp, width, height, row_stride, 166, y - 7, 180 - @as(i32, @intCast((i * 7) % 80)), 14, rgb(46, 58, 64));
        y += 38;
    }

    y = 170;
    i = 0;
    while (i < 24) : (i += 1) {
        fillRect(bmp, width, height, row_stride, 450, y, 42, 4, rgb(66, 217, 213));
        fillRect(bmp, width, height, row_stride, 512, y - 7, 420 - @as(i32, @intCast((i * 19) % 220)), 13, rgb(210, 220, 222));
        if (i % 3 == 0) fillRect(bmp, width, height, row_stride, 730, y - 7, 150, 13, rgb(125, 227, 139));
        if (i % 4 == 0) fillRect(bmp, width, height, row_stride, 900, y - 7, 92, 13, rgb(255, 209, 102));
        y += 22;
    }

    fillRect(bmp, width, height, row_stride, 1238, 176, 300, 74, rgb(20, 38, 40));
    fillRect(bmp, width, height, row_stride, 1262, 202, 110, 10, rgb(66, 217, 213));
    fillRect(bmp, width, height, row_stride, 1262, 224, 230, 8, rgb(164, 180, 184));
    fillRect(bmp, width, height, row_stride, 1238, 274, 300, 74, rgb(30, 35, 23));
    fillRect(bmp, width, height, row_stride, 1262, 300, 132, 10, rgb(255, 209, 102));
    fillRect(bmp, width, height, row_stride, 1262, 322, 210, 8, rgb(164, 180, 184));
    fillRect(bmp, width, height, row_stride, 1238, 372, 300, 74, rgb(38, 24, 23));
    fillRect(bmp, width, height, row_stride, 1262, 398, 112, 10, rgb(255, 127, 110));
    fillRect(bmp, width, height, row_stride, 1262, 420, 230, 8, rgb(164, 180, 184));

    y = 780;
    i = 0;
    while (i < 6) : (i += 1) {
        const c = if (i % 2 == 0) rgb(66, 217, 213) else rgb(125, 227, 139);
        fillRect(bmp, width, height, row_stride, 450, y, 18, 18, c);
        fillRect(bmp, width, height, row_stride, 486, y + 3, 620 - @as(i32, @intCast(i * 64)), 10, rgb(151, 165, 171));
        y += 26;
    }

    try writeAssetBytes(allocator, out_dir, "assets/hero.bmp", bmp);
}

const Color = struct { r: u8, g: u8, b: u8 };

fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b };
}

fn fillRect(buffer: []u8, width: i32, height: i32, row_stride: i32, x: i32, y: i32, w: i32, h: i32, color: Color) void {
    const x0 = @max(0, x);
    const y0 = @max(0, y);
    const x1 = @min(width, x + w);
    const y1 = @min(height, y + h);
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const row = height - 1 - yy;
            const offset: usize = @intCast(54 + row * row_stride + xx * 3);
            buffer[offset + 0] = color.b;
            buffer[offset + 1] = color.g;
            buffer[offset + 2] = color.r;
        }
    }
}

fn writeAsset(allocator: std.mem.Allocator, out_dir: []const u8, relative: []const u8, bytes: []const u8) !void {
    try writeAssetBytes(allocator, out_dir, relative, bytes);
}

fn writeAssetBytes(allocator: std.mem.Allocator, out_dir: []const u8, relative: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ out_dir, relative });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = path, .data = bytes, .flags = .{ .truncate = true } });
}

fn sha256Hex(bytes: []const u8) ![64]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    try std.crypto.codecs.hex.encode(hex[0..], digest[0..], .lower);
    return hex;
}

fn writeLe16(dest: []u8, value: u16) void {
    dest[0] = @truncate(value);
    dest[1] = @truncate(value >> 8);
}

fn writeLe32(dest: []u8, value: u32) void {
    dest[0] = @truncate(value);
    dest[1] = @truncate(value >> 8);
    dest[2] = @truncate(value >> 16);
    dest[3] = @truncate(value >> 24);
}
