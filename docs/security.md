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

### 関数ブレークポイント境界

Zig、C/C++、Rust、Go、Python、Javaなどの関数・メソッドを、source lineとは独立したDAP `FunctionBreakpoint.name` として指定できる。ただしZIDE自身はこの文字列を評価せず、シェルcommandへ連結しない。

- selectorは256件、1件1024 byte、group depth 16までに制限し、有効UTF-8、hidden/control character、区切りの釣り合いを検査する
- qualified symbol、namespace、module path、型付きsignatureに必要な限定文字だけを受理し、トップレベルwildcard、文区切り、quote、式構文を拒否する
- adapterの `supportsFunctionBreakpoints` がtrueのときだけ `setFunctionBreakpoints` を送り、非対応時はsource breakpointへ格下げせず保存状態のままwithholdする
- DAPの全置換契約に従い、空配列による全消去を含め、`initialized` event後かつ `configurationDone` 前に送る
- 要求ごとに関数名のowned snapshotを保持し、追加・削除後に古い応答が届いても現在の別項目へ検証結果を誤対応させない
- 状態ファイルには検証済みselectorだけを保存し、adapter ID、verified、messageなどのruntime responseは保存しない
- Windows/Linux GUIは同じcore command、検証器、永続化形式を使い、configured、capability、withheld、verified/rejectedを同じ操作面に表示する

関数名の解釈と探索範囲はadapter実装に依存し、ZIDEの検証はadapter内部の副作用不在を証明しない。DAPの全置換、capability、応答順は[公式仕様](https://microsoft.github.io/debug-adapter-protocol/specification#Requests_SetFunctionBreakpoints)に従う。

### データブレークポイント境界

停止中の変数に対するread/write監視は、DAP `dataBreakpointInfo` と `setDataBreakpoints` を分離した二段階操作にする。変数を選んだだけでは監視を設定せず、adapterが返した説明とaccess typeをGUIで確認してから明示的にcommitする。

- `supportsDataBreakpoints` がtrueのadapterにだけ問い合わせ、非対応時は式評価、source breakpoint、memory addressへ変換せずwithholdする
- `variablesReference` は現在の停止状態で取得した親containerだけを使い、各変数とpending requestへ停止世代を記録する。continue、step、次のstopで候補と古いobject referenceを失効させる
- 遅延したvariables応答や `dataBreakpointInfo` 応答は、停止世代とstateが一致しなければ採用しない
- `dataId` は最大4096 byteのopaqueなadapter IDとして扱い、ZIDEで式評価、address解釈、shell連結、path解釈をしない
- data ID、description、variable nameは有効UTF-8、control/C1、bidi、default-ignorable、不可視whitespace、個数上限をZig側で検査する
- `read` / `write` / `readWrite` はadapterが候補ごとに広告した値だけをcommitできる。広告がない場合だけaccess typeを省略したadapter defaultを選べる
- `setDataBreakpoints` は空配列による全消去を含む全置換として送り、要求ごとのdata ID snapshotで遅延応答を現在の別項目へ誤対応させない
- adapterが `canPersist: true` と明示したIDだけを状態ファイルへ保存し、取得元のDAP `adapterID` にスコープする。別adapterでは同じopaque IDを送らずwithholdする。それ以外はdebug session終了時に破棄し、variable name、value、停止世代、verified、runtime breakpoint ID、messageは保存しない
- DAP `capabilities` eventは含まれたfieldだけを更新し、省略fieldをfalseへ戻さない。能力変更後は現在のsource/function/data/exception設定を各capability境界でもう一度同期する
- Windows/Linux GUIは同じcore commandとstate machineを使い、変数選択、候補確認、access commit/cancel、remove/clear、capability/withheld/persistenceを同じ順序で表示する

data breakpointはdebuggeeのmemory accessを停止させる強い操作であり、adapter自体の安全性や監視実装の副作用不在をZIDEが証明するものではない。IDの寿命、access type、永続可否、全置換の意味は[公式DAP仕様](https://microsoft.github.io/debug-adapter-protocol/specification#Requests_DataBreakpointInfo)に従う。

### 例外ブレークポイント境界

DAP adapterが初期化応答の `exceptionBreakpointFilters` で広告したフィルターだけを選択できる。adapter由来のメタデータも信頼済みUI文字列として扱わない。

- filter ID、label、descriptionは有効UTF-8、hidden/control character、個数、バイト数をZig側で上限検査する
- 重複ID、不正な要素、64件を超える広告は拒否数として記録し、GUIと `debug.status` へ露出する
- adapterの `default: true` は表示だけに使い、自動有効化しない。停止点の追加はユーザーの明示選択だけで行う
- initialize応答で一覧を受け取っても、adapterの `initialized` eventまでは設定要求を送らない
- 状態ファイルには選択済みIDだけを保存し、adapterのlabel、description、応答、式を保存しない
- 保存済みIDを次のadapterが広告しなければwithholdし、`setExceptionBreakpoints` へ送らない
- 要求ごとに送信IDのowned snapshotを保持し、遅延応答を現在の選択順へ誤対応させない
- 現段階では `supportsCondition` を表示するだけで、例外conditionをadapterへ渡さない。条件対応はrestricted expression境界を別途設計してから有効化する

DAPの初期化順序、フィルター、要求引数、応答順は[公式仕様](https://microsoft.github.io/debug-adapter-protocol/specification#Requests_SetExceptionBreakpoints)に従う。

### デバッグ状態ファイル

ウォッチ、source breakpoint、function breakpoint selector、永続可能なdata breakpoint、選択済みexception filter IDは `.zide/debug-state.json` に保存する。このファイルはユーザーごとの状態なのでGit管理から除外する。

- 読み込みは1 MiBまで、通常ファイルかつno-followのワークスペース能力経由に限定する
- 保存先の親ディレクトリをコンポーネントごとにno-followで開き、同じディレクトリ能力内の一時ファイルから原子的にrenameする
- ブレークポイントのpathはワークスペース相対形式だけを保存・受理し、絶対pathと `..` を拒否する
- 読み込んだウォッチは上記の制限付き式分類をもう一度通す
- 読み込みは一時Sessionへステージングし、検証と確保が完了してから現在のリストと交換する
- v1の通常ブレークポイントを読み込める一方、高度設定を含む保存形式はv2とし、古いbinaryによる無条件BPへの誤変換を防ぐ
- condition、hit condition、log messageは読み込み時にも上記の検証を通し、1項目でも不正ならそのブレークポイント全体を拒否する
- exception filter IDは読み込み時にも境界検証し、重複、hidden control、上限超過を個別に拒否する
- function selectorは読み込み時にも同じmulti-language境界検証を通し、重複、pattern、hidden control、上限超過を個別に拒否する
- data breakpointは `canPersist` が確認済みのadapter ID、opaque ID、description、access typeだけを保存し、読み込み時に再検証する。取得元adapterが一致しない項目は送信せず、session限定IDは保存件数と分けてreportする
- 任意のadapter引数やruntime responseは状態ファイルから読み込まない
- 状態を変更するブレークポイント／ウォッチコマンドは `workspace_write` capabilityを持ち、LOCKED_DOWNでは実行前に拒否する
- 保存失敗は `store:dirty` / `store:save-error` としてGUIへ露出し、メモリ上だけの変更になったことを隠さない
