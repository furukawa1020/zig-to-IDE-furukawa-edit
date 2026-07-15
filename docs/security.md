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

## デバッグウォッチ境界

デバッグウォッチは、任意コードを入力できるREPLとは分離する。

- 空文字、無効UTF-8、制御文字、双方向テキスト制御、4096 byte超の式を拒否し、自動評価は64件までに制限する
- 関数呼び出し、代入、文区切り、演算子式、内部空白を含む式を拒否する
- フィールド参照、ポインター参照、添字、optional unwrapのような「値の観察」に寄せた形だけをDAP `evaluate`へ渡す
- 停止中の選択フレームだけで評価し、古い要求番号から遅れて届いた結果は破棄する
- DAP adapterは明示的に承認したargvからだけ起動し、adapter側の `runInTerminal` / `startDebugging` は拒否する
- ウォッチ単位の失敗をセッション全体の失敗と混ぜず、式の行に閉じ込めて表示する

ただし、これは**副作用が絶対にないことの証明ではない**。言語によってはproperty getter、indexer、`__getattribute__`、`__getitem__`などがフィールド参照や添字で実行される。DAP adapter自身も信頼境界の内側にある。そのため、現状のウォッチは「構文を制限した評価」であり、未信頼debuggeeに対する完全なread-only inspectionではない。任意式REPLを追加する場合は、別の明示的な同意境界として実装する。

### 高度ブレークポイント境界

DAPの `SourceBreakpoint` が持つ `condition` / `hitCondition` / `logMessage` を扱う。ただし、文字列をそのままadapterへ渡す汎用入力にはしない。

- 条件式はフィールド・添字参照、リテラル、比較、論理結合、groupingだけに制限し、関数呼び出し、代入、文、算術式を拒否する
- hit conditionはadapter固有の任意式ではなく、1以上のbase-10整数だけを受理する
- log message内の `{expression}` はデバッグウォッチと同じrestricted inspection分類を通し、callやoperator expressionを拒否する
- UTF-8、hidden control、NUL、長さ、group depth、atom数、interpolation数をZig側で上限検査する
- 実行中adapterが対応capabilityを広告していない設定は変更時に拒否する
- 保存済みの高度ブレークポイントを非対応adapterへ送る場合、そのブレークポイント全体を保留し、無条件の通常ブレークポイントへ格下げしない
- Windows/Linux GUIは同じcore commandを使い、通常、hit、condition、logpointを異なるgutter色で表示する

この制限も副作用の不在を証明しない。比較対象のproperty/indexerやdebuggerの式評価器がコードを実行する可能性は残る。adapterは引き続き信頼境界内であり、GUIには「restricted adapter evaluation」として露出する。DAPのフィールドとcapabilityの意味は[公式仕様](https://microsoft.github.io/debug-adapter-protocol/specification#Types_SourceBreakpoint)に従う。

### デバッグ状態ファイル

ウォッチとsource breakpointは `.zide/debug-state.json` に保存する。このファイルはユーザーごとの状態なのでGit管理から除外する。

- 読み込みは1 MiBまで、通常ファイルかつno-followのワークスペース能力経由に限定する
- 保存先の親ディレクトリをコンポーネントごとにno-followで開き、同じディレクトリ能力内の一時ファイルから原子的にrenameする
- ブレークポイントのpathはワークスペース相対形式だけを保存・受理し、絶対pathと `..` を拒否する
- 読み込んだウォッチは上記の制限付き式分類をもう一度通す
- 読み込みは一時Sessionへステージングし、検証と確保が完了してから現在のリストと交換する
- v1の通常ブレークポイントを読み込める一方、高度設定を含む保存形式はv2とし、古いbinaryによる無条件BPへの誤変換を防ぐ
- condition、hit condition、log messageは読み込み時にも上記の検証を通し、1項目でも不正ならそのブレークポイント全体を拒否する
- 任意のadapter引数やruntime responseは状態ファイルから読み込まない
- 状態を変更するブレークポイント／ウォッチコマンドは `workspace_write` capabilityを持ち、LOCKED_DOWNでは実行前に拒否する
- 保存失敗は `store:dirty` / `store:save-error` としてGUIへ露出し、メモリ上だけの変更になったことを隠さない
