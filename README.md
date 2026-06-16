# zide

`zide` は、Zigで作る単一バイナリTUI IDEです。

元の要件は「Zigを書くための自己完結型TUI workbench」ですが、この実装では最初から以下も視野に入れます。

- Zig以外のテキスト/設定/スクリプトも開ける
- 高度なIDE機能はZigに集中する
- デモやタスクをIDE内から動かせる
- 外部ライブラリには依存しない
- 実行コマンド、設定、状態をユーザーに見える形で扱う

## いま入っているもの

- Zigプロジェクトのビルド骨格
- CLIエントリポイント
- コマンドモデルの最小実装
- ワークスペースのトップレベル走査
- 言語モード判定
- テキストバッファと行インデックス
- Zig tokenizerの初期版
- TUI風のデモ表示

## 使い方

ZigがPATHにある環境では以下で実行できます。

```sh
zig build run -- .
zig build run -- demo
zig build run -- demo languages
zig build run -- demo commands
zig build run -- demo buffer
zig build run -- demo zig-tokens
zig build test
```

## 開発方針

最初のMVPは「壊れにくい編集モデル」と「透明なコマンド実行」を優先します。
本物のraw mode TUI、非同期process runner、Zig parser、symbol index、diagnostics統合は、この土台の上に段階的に追加します。

