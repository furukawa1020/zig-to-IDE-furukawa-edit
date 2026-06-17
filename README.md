# zide

`zide` は、Zigで作る単一バイナリTUI IDEです。

元の要件は「Zigを書くための自己完結型TUI workbench」ですが、この実装では最初から以下も視野に入れます。

- Zig以外のテキスト/設定/スクリプトも開ける
- 高度なIDE機能はZigに集中する
- デモやタスクをIDE内から動かせる
- 外部ライブラリには依存しない
- 実行コマンド、設定、状態をユーザーに見える形で扱う

## いま入っているもの

- 完全版を見据えたレイヤードアーキテクチャ
- Zigプロジェクトのビルド骨格
- CLIエントリポイント
- 完成形を先取りしたコマンドカタログと権限モデル
- ワークスペースのトップレベル走査
- 言語モード判定
- テキストバッファと行インデックス
- Zig tokenizerの初期版
- TUI風のデモ表示

詳しいレイヤー設計は [docs/architecture.md](docs/architecture.md) を参照してください。

## 使い方

ZigがPATHにある環境では以下で実行できます。

```sh
zig build run -- .
zig build run -- demo
zig build run -- demo architecture
zig build run -- demo languages
zig build run -- demo commands
zig build run -- demo buffer
zig build run -- demo zig-tokens
zig build test
```

## 開発方針

最初から完成形の境界を崩さないように作ります。
UIは直接filesystemやprocessを触らず、command/runtime層を通します。
Zig以外の言語はテキスト編集・検索・実行デモの対象にし、高度な解析・補完・renameはZigに集中します。
