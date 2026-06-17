# zide 完全版アーキテクチャ

`zide` は単一バイナリですが、内部は明確なレイヤーに分けます。
目的は、TUI、編集、Zig解析、build/test/debug、永続化、外部コマンド実行を混ぜないことです。

## 依存方向

基本ルールは以下です。

```text
main
  -> app/runtime
    -> command
    -> services
      -> editor / workspace / language / build / diagnostics / search
      -> persistence / security / observability
      -> platform
  -> ui
    -> command requests only
```

UIから直接filesystem、process、git、zigを叩きません。
すべて `core.command` と `core.runtime` を経由します。

## レイヤー

| レイヤー | 役割 |
| --- | --- |
| core | app状態、event loop、command registry、共通型 |
| platform | OS差分、filesystem、process、terminal capability |
| terminal | ANSI描画、raw mode、input decode、screen buffer |
| ui | layout、view、theme、widget、render tree |
| editor | document、buffer、cursor、selection、undo、atomic save |
| workspace | root、file tree、watcher、session、workspace trust |
| language | language mode、Zig tokenizer/parser/AST/symbol/semantic |
| diagnostics | compiler/build/parser由来の診断を統一 |
| build | Zig toolchain検出、build step、build/test/fmt/run |
| tasks | ユーザー定義task、process console接続 |
| search | literal search、pattern search、fuzzy scoring |
| config | 自作設定形式、keymap、theme設定 |
| persistence | journal、cache、session、backup |
| debug | debug session、breakpoint、debug views |
| git | git status/diff/commit支援の外部git統合 |
| security | workspace trust、外部コマンドpolicy、path保護 |
| observability | internal log、debug dump、command history |

## 実装の優先順

1. editor model: byte-preserving buffer、cursor、undo、atomic save
2. terminal/ui: raw mode、screen buffer、layout、command palette
3. workspace: file tree、session、trust、file watcher
4. command/runtime: 全操作のcommand化、実行履歴、precondition
5. build/diagnostics: zig build/test/fmt、出力stream、diagnostics jump
6. language: Zig tokenizer、parser、AST、symbol index、completion
7. persistence/recovery: journal、cache、crash recovery
8. debug/git/tasks: 実用範囲から段階的に統合

## Zig以外の扱い

Zig以外のファイルも開けます。
ただし高度な意味解析はZig中心です。

```text
Zig/ZON     : tokenizer/parser/symbol/completion/build integration
Markdown    : text editing, search, preview-ready model
JSON/env    : text editing, config-ish diagnostics later
Shell/Make  : task/demo execution target
Other code  : text editing, search, external task runner
```

## 外部コマンド

外部コマンドは `platform.process` と `tasks` / `build` からのみ起動します。
起動前に以下を記録・表示します。

```text
executable
argv
cwd
environment diff
workspace trust state
source command id
```

untrusted workspaceでは自動実行しません。

