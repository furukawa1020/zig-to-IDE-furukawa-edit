# zide Security Workbench

`zide` のセキュリティは2層で考える。

```text
Layer 1: zide自体と開発者マシンを守る
Layer 2: zideで開発しているZigプログラムを攻撃者入力から守る
```

この2つを混ぜない。
知らないrepoの `build.zig` からSSH keyを守る話と、Zigアプリ内の `@ptrCast` 由来の脆弱性を見つける話は別物です。

## 中心原則

```text
Open is not execute.
```

workspaceを開いただけで、workspace内のコードを実行してはいけない。

```text
build.zig is code.
```

`build.zig` は設定ファイルではなく、実行可能なZigプログラムとして扱う。

```text
Output is untrusted.
```

compiler output、test output、file name、branch nameはterminal escapeを含む可能性がある。
IDEのoutput panelはterminal emulatorではなく、安全なログビューアにする。

## Trust States

```text
UNTRUSTED
  初めて開いたworkspace。静的解析、検索、編集だけ許可。

REVIEWED
  build.zig / deps / generated filesを確認済み。まだ外部実行は自動許可しない。

TRUSTED
  build / test / fmt / taskを許可。ただし実行内容を表示する。

HARDENED
  信頼済みだが制限付き実行。env allowlist、timeout、output sanitizeなどを強める。

PARANOID
  サプライチェーン監査。toolchain hash、dependency fingerprint、generated diffを重視。

LOCKED_DOWN
  危険兆候を検出。実行を再ブロックする。
```

## ZigならではのSecurity Workbench

Zig向けに最初から見るべき危険境界:

- `build.zig` execution boundary
- `build.zig.zon` dependency fingerprint
- `@ptrCast`, `@alignCast`, `@ptrFromInt`, `@intFromPtr`
- `@setRuntimeSafety(false)`
- `catch unreachable`
- `undefined`
- `@embedFile` と `.env` / key / token / pem
- `extern`, `export`, `callconv(.c)`
- allocator quota / leak / secret zeroize
- Debug / ReleaseSafe / ReleaseFast / ReleaseSmall の安全性差分
- subprocess output escape sequence

`zide` は「安全です」と嘘をつかない。
代わりに、今どの安全網が効いていて、どこで外れていて、どこで外部世界に触っているかを見せる。

