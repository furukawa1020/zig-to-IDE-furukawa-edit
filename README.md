# zide

ZigでIDEを作る。
TUIで作る。
単一バイナリで作る。
外部ライブラリなしで作る。

つまり、逃げ場はない。
作るんじゃい。

`zide` は、Zigを書くための自己完結型TUI IDEです。
でも「Zigファイルしか触れません」みたいな窮屈な道具にはしません。
READMEも設定もスクリプトもデモも、開発中に必要なものはちゃんと開ける。
ただし、魂はZigに置く。zigによるzigのためのzigide
高度な解析、補完、jump、rename、build/test/debug連携はZigに全力やる

## 何を作るのか

小さいけど強いIDEを作ります。

- ターミナルで完結する
- Zigで実装する
- 単一バイナリとして動く
- 外部TUIフレームワークに頼らない
- ZLSにもtree-sitterにもncursesにも乗らない
- Zig toolchainとは真正面から統合する
- 何を実行したか、何を読んだか、何を無視したかを隠さない
- 壊れにくく、速く、ローカルで完結する

VS Codeの小型版ではない。
JetBrainsの劣化コピーでもない。
Zigを書く人間の手元に置く、Zigっぽい作業台を作る。

## 現在の土台

まず完成形の骨を先に入れています。
あとから継ぎ足して破綻するのが嫌なので、最初からレイヤー境界を切ります。

- app / runtime / command
- platform / terminal
- ui / layout / theme / view
- editor / buffer / cursor / selection / undo / save
- workspace / file tree / session / watcher
- language / Zig tokenizer / parser / AST / symbol / semantic
- diagnostics / build / tasks
- config / persistence / security / observability
- debug / git / search

設計の地図は [docs/architecture.md](docs/architecture.md) にあります。
ここは飾りではなく、実装が迷子にならないための背骨です。

## 動かす

ZigがPATHにあるならこれで動きます。

```sh
zig build run -- .
zig build run -- demo
zig build run -- demo architecture
zig build run -- demo languages
zig build run -- demo commands
zig build run -- demo editor
zig build run -- demo buffer
zig build run -- demo zig-tokens
zig build test
```

デモは大事です。
でもデモで終わらせません。
デモは「ここまで動いた」を確認する旗であって、目的地ではありません。

## 開発方針

UIはfilesystemやprocessを直接触らない。
全部command/runtimeを通す。

外部コマンドは隠れて走らせない。
workspace trustを持つ。
untrustedなら自動実行しない。
ユーザーのファイルは壊さない。
保存はatomic writeを基本にする。
クラッシュしても復元できる道を残す。

Zig以外も開ける。
でもZigを特別扱いする。
これは汎用エディタではなく、Zigを書くためのIDEです。

## 合言葉

ちゃんと設計する。
ちゃんと動かす。
ちゃんと壊れにくくする。

そして最後まで作る。

作るんじゃい。
