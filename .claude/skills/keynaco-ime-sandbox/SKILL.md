---
name: keynaco-ime-sandbox
description: |
  keynaco IME のデバッグソケットサーバーを使って、キー入力シーケンスを送信し IME の内部状態（組成文字列・候補リスト・モードフラグ・確定履歴）を観察・調査するスキル。

  次のような場面で積極的に使うこと:
  - 「"kanzi" と入力したら何候補が出るか」など特定の入力列の挙動を確認したいとき
  - Successor モード・ブラケットモードの動作を検証したいとき
  - 候補の並び順・`candidateEntries`・`fixedEnd` を確認したいとき
  - 複数の入力パターンを比較して IME のロジックを調べたいとき
  - ユーザーが「このシーケンスを試して」「このケースをデバッグして」と言ったとき
  - Zenzai top-1 プロモーションの動作を検証したいとき（set_left_context + isZenzaiEnabled を使う）
---

# keynaco IME サンドボックスの使い方

## 前提

- keynaco（Debug ビルド）が起動していること。普段使いは Release（デバッグソケットなし）なので、ソケットが無ければ `/deploy debug` で入れる。検証後は `/deploy` で Release に戻すようユーザーに伝える
- `$TMPDIR/keynaco-debug.sock` にソケットが存在すること
- Python 3 が使えること

起動確認（**必ず最初に実行**。ファイルの有無だけでなくプロセスの生死を確認すること）:
```bash
pgrep -x keynaco && echo "keynaco running" || echo "keynaco not running — /deploy debug で Debug ビルドを入れてください"
```

ソケットファイルは前回の起動時のものが残る場合がある。`pgrep` が "not running" を返したら、ユーザーに `xcodebuild` でビルド＆起動を促してスクリプトを終了すること。

接続エラー（`Connection refused` / `ECONNREFUSED`）が出た場合も同様に keynaco 未起動が原因。ソケットファイルの有無は関係ない。

### バイナリ stale 検知（**起動確認と同時に必ず実行**）

走っている keynaco が直近のソースより古いと、テスト結果がコードと食い違う。最初の `{"state": true}` 等のレスポンスに `buildInfo.commit` が入っているので、ワークツリーの HEAD と比較する:

```python
r = send({"state": True})
running_commit = r.get("buildInfo", {}).get("commit", "unknown")
import subprocess
head = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"]).decode().strip()
if running_commit != head:
    print(f"WARNING: running={running_commit} HEAD={head}")
    print(f"  built at: {r.get('buildInfo', {}).get('builtAt')}")
    print(f"  → /deploy で再ビルドしてから再実行してください")
    sys.exit(1)
```

`buildInfo.commit` が `"unknown"` の場合は古い DebugSocketServer（buildInfo 未対応）が走っているので、同様に stale 扱いで `/deploy` を促す。ワークツリーに未コミット変更があるときは HEAD 一致だけでは不十分なので、`git status --porcelain Core/Sources keynaco/` も併せて見て、変更があれば警告する。

## ソケットクライアント

`scripts/debug_ime.py` が用意されている。対話モードとバッチモードがある。

**バッチ（コマンドから）:**
```bash
python3 scripts/debug_ime.py kanzi              # 文字列送信 → 最終状態のみ表示（デフォルト）
python3 scripts/debug_ime.py -v kanzi           # 各キー入力後の状態も表示（verbose）
python3 scripts/debug_ime.py '{"reset":true}'   # 引数が `{` で始まれば JSON コマンドとして 1 回送信
```
※ 引数が JSON 文字列の場合は `type_string` ではなく単一コマンドとして送られる。`type_string` として送りたい場合は明示的に `{"type_string":"..."}` で渡すこと。

**Python スクリプトで直接操作する（推奨）:**
```python
import socket, json, os, subprocess, sys

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")

# プロセス確認（ソケットファイルが残っていても誰も listen していない場合がある）
result = subprocess.run(["pgrep", "-x", "keynaco"], capture_output=True)
if result.returncode != 0:
    print("ERROR: keynaco is not running. Please build and launch it first.")
    sys.exit(1)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect(SOCKET_PATH)
except ConnectionRefusedError:
    print("ERROR: Connection refused. keynaco may have just started — retry in a moment.")
    sys.exit(1)
buf = b""

def send(cmd):
    global buf
    sock.sendall((json.dumps(cmd, ensure_ascii=False) + "\n").encode())
    while b"\n" not in buf:
        buf += sock.recv(4096)
    line, buf = buf.split(b"\n", 1)
    return json.loads(line)

# 必ずリセットしてから開始
send({"reset": True})
```

## コマンド形式

### 推奨: 高レベルコマンド（AI 向け）

| 用途 | コマンド例 |
|------|-----------|
| 文字列を一括送信（最終状態のみ） | `{"type_string": "kanzi"}` |
| 文字列→変換キー（最終状態のみ） | `{"type_string": "kanzi", "then": "space"}` |
| 文字列→確定（全ステップも取得） | `{"type_string": "jissou", "then": "enter", "return_steps": true}` |
| サーバースキーマ取得（AI向け） | `{"schema": true}` |
| examples 付きスキーマ取得 | `{"schema": true, "with_examples": true}` |
| 状態説明付きレスポンス | `{"state": true, "explain": true}` / `{"type_string":"kanzi","then":"space","explain":true}` |
| コマンド列を一括送信 | `{"sequence": [{cmd1}, {cmd2}, ...]}` → `{"steps": [...], "last": {...}}` |
| ステップごとの説明ラベル | `{"type_string": "kanzi", "describe": "ローマ字入力"}`（レスポンスにも `describe` が返る） |
| sequence 中間ステップ assert | `{"sequence": [{"type_string":"kanzi","assert":{"composedHiragana":"かんじ"}}, {"key":"space","assert":{"candidateVisible":true}}]}` |
| 部分一致 assert | `{"key":"space","assert_contains":{"candidates":"漢字"}}` / `{"assert_contains":{"candidates":["漢字","感じ"]}}` |
| 否定 assert | `{"state":true,"assert_not":{"isAsciiMode":true}}` |
| スキーマ assert | `{"state":true,"assert_schema":{"candidates":"array<string>","candidateEntries":"array<object>"}}` |
| 正規表現 assert | `{"state":true,"assert_regex":{"markedText":"^\\\".*\\\"$"}}` |
| 非同期待機 | `{"wait_until":{"field":"candidates","minCount":1,"timeoutMs":1500}}` |
| 非同期アサート（待機+検証） | `{"assert_eventually":{"field":"candidates","contains":"漢字","timeoutMs":1500}}` |
| 複数シナリオを一括実行 | `{"test_suite":[{"name":"kanzi変換","cmds":[...],"assert":{"inserted":["漢字"]}}]}` |
| test_suite 共通前処理/後処理 | `{"before_each":[...], "after_each":[...], "test_suite":[...]}` |
| test_suite fail-fast | `{"test_suite":[...], "fail_fast": true}`（最初の失敗で打ち切り） |
| 失敗/タイムアウト期待 | `{"test_suite":[{"expect_error":true, ...}]}` / `{"expect_timeout":true, ...}` |
| スイートの静的検証 | `{"lint_suite":[...], "before_each":[...]}`（実行せずに問題点を返す） |
| 変数展開（再利用） | `{"sequence":[...], "vars":{"needle":"漢字"}}` と `{{needle}}` |
| ステップ結果の capture | `{"capture":{"top":"selectedText","fe":"fixedEnd"}}`（`sequence` の `vars` に保存） |
| 名前付きキー | `{"key": "space"}` / `{"key": "enter"}` / `{"key": "down"}` 等 |
| Shift+名前付きキー | `{"key": "backspace", "mods": 131072}` |
| フィールド絞り込み | `{"type_string": "kanzi", "then": "space", "fields": ["candidates", "candidateEntries"]}` |
| インラインアサート | `{"type_string": "kanzi", "assert": {"composedHiragana": "かんじ"}}` |
| 履歴シード | `{"seed_history": {"input": "かんじ", "output": "漢字", "times": 3}}` |
| sessionTextBuffer 確認 | `{"state": true, "fields": ["sessionTextBuffer", "committedHistory"]}` — 文末後も buffer が残るか（[PLAN260525](../../plans/PLAN260525-session-text-buffer.md)） |
| Zenzai 左コンテキスト固定 | `{"set_left_context": "申請書を"}` — レスポンスに `leftSideContext` が返る。空文字で解除 |
| 周辺文脈設定 | `{"set_surrounding": {"before": "...", "after": "..."}}` — 同上（`sessionTextBuffer` も返る） |

`then` に指定できる名前: `space` / `enter` / `backspace` / `escape` / `tab` / `down` / `up` / `left` / `right` / `f6`–`f10` / `eisu` / `kana`

**使用例:**
```python
# "kanzi" を入力して Space で変換 → 候補だけ得る（fields で絞り込み）
r = send({"type_string": "kanzi", "then": "space", "fields": ["candidates", "candidateEntries"]})
print(r["candidates"][:5])

# assert でインライン検証 → 失敗時は {"assertion_failed": [...], "state": {...}} が返る
r = send({"type_string": "kanzi", "assert": {"composedHiragana": "かんじ"}})
if "assertion_failed" in r:
    print("FAIL:", r["assertion_failed"])

# スキーマ検証（型崩れ検知）
r_schema = send({"state": True, "assert_schema": {"candidates": "array<string>", "candidateEntries": "array<object>"}})
print("schema_ok?", "assertion_failed" not in r_schema)

# 正規表現検証（JSON化した値に対して評価）
r_regex = send({"state": True, "assert_regex": {"composedHiragana": ".*"}})
print("regex_ok?", "assertion_failed" not in r_regex)

# 履歴をシードしてから変換を確認
send({"reset": True})
send({"seed_history": {"input": "じっそう", "output": "実装", "times": 3}})
r = send({"type_string": "jissou", "then": "space", "fields": ["candidates"]})
print(r["candidates"][:3])

# 複数操作を1往復でバッチ送信
r = send({"sequence": [
    {"type_string": "kanzi", "describe": "ローマ字入力", "assert": {"composedHiragana": "かんじ"}},
    {"key": "space", "describe": "変換開始", "assert": {"candidateVisible": True}},
    {"key": "down"},
    {"key": "enter"},
]})
print(r["last"]["inserted"])

# capture/reuse: 途中結果を変数化して後続ステップで再利用
r2 = send({"sequence": [
    {"type_string": "kanzi", "then": "space", "capture": {"picked": "selectedText"}},
    {"key": "enter", "assert_contains": {"inserted": "{{picked}}"}}
]})
print(r2["vars"])  # {"picked": "..."}

# test_suite: シナリオごとに自動 reset → cmds 実行 → 最終 assert
suite = send({"test_suite": [
    {
        "name": "kanzi変換",
        "cmds": [
            {"type_string": "kanzi", "assert": {"composedHiragana": "かんじ"}},
            {"key": "space", "assert": {"candidateVisible": True}},
            {"key": "enter"},
        ],
        "assert": {"inserted": ["漢字"]},
        "return_steps": True
    }
]})
print(suite["summary"])  # {"total": 1, "passed": 1, "failed": 0}
# 失敗時は scenario.failedAssertions に stepIndex/stepDescribe/field/expected/actual が集約される
# scenario.failedAssertions には stepPhase(before_each/cmd/after_each) も入る
# scenario.compactFailures には人間/AIが読みやすい1行要約が入る

# before_each / after_each で共通セットアップを DRY にする
suite2 = send({
    "before_each": [
        {"seed_history": {"input": "あめ", "output": "雨", "times": 2}}
    ],
    "after_each": [
        {"state": True, "describe": "終了時状態確認"}
    ],
    "fail_fast": True,
    "test_suite": [
        {
            "name": "jissou→enter",
            "cmds": [{"type_string": "jissou", "then": "enter"}],
            "assert_contains": {"candidates": "する"}
        }
    ]
})
print(suite2["summary"])  # durationMs / stoppedEarly も返る

# 異常系を期待するシナリオ（エラーが出れば pass）
suite3 = send({
    "test_suite": [
        {
            "name": "invalid-key",
            "cmds": [{"key": "unknown_key"}],
            "expect_error": True
        }
    ]
})
print(suite3["results"][0]["ok"], suite3["results"][0]["hasError"])

# lint_suite: 実行前に静的チェック（cmds欠落・wait_until不足など）を検出
linted = send({
    "lint_suite": [
        {"name": "bad", "cmds": [{"wait_until": {"timeoutMs": 10}}], "expect_timeout": True}
    ]
})
print(linted["ok"], linted["summary"], linted["issues"])

# 候補表示を待つ
waited = send({
    "wait_until": {
        "field": "candidates",
        "minCount": 1,
        "timeoutMs": 1500,
        "intervalMs": 50
    },
    "describe": "候補待機"
})
print(waited["matched"], waited["state"]["candidates"])
```

---

### 低レベルコマンド（keyCode を直接指定する場合）

| 用途 | コマンド例 |
|------|-----------|
| 通常文字 | `{"keyCode": 0, "chars": "k", "base": "k", "mods": 0}` |
| Space（変換） | `{"keyCode": 49, "chars": " ", "base": " ", "mods": 0}` |
| Enter（確定） | `{"keyCode": 36, "chars": "\r", "base": "\r", "mods": 0}` |
| Backspace | `{"keyCode": 51, "chars": "\x08", "base": "\x08", "mods": 0}` |
| Escape | `{"keyCode": 53, "chars": "", "base": "", "mods": 0}` |
| ↓（候補下） | `{"keyCode": 125, "chars": "", "base": "", "mods": 0}` |
| ↑（候補上） | `{"keyCode": 126, "chars": "", "base": "", "mods": 0}` |
| ←（左矢印） | `{"keyCode": 123, "chars": "", "base": "", "mods": 0}` |
| →（右矢印） | `{"keyCode": 124, "chars": "", "base": "", "mods": 0}` |
| Tab | `{"keyCode": 48, "chars": "\t", "base": "\t", "mods": 0}` |
| Shift+Delete | `{"keyCode": 51, "chars": "\x08", "base": "\x08", "mods": 131072}` |
| リセット | `{"reset": True}`（下表のオプション可） |
| 現在状態取得 | `{"state": True}` |

### リセットオプション

| コマンド | 説明 |
|---------|------|
| `{"reset": true}` | インメモリ DB でリセット。必要なら `seed_history` でデータを注入する。 |
| `{"reset": true, "useRealDB": true}` | 実体の `~/Library/Application Support/keynaco/history.db` を `DatabaseManager.shared` 経由で直接共有する。変換履歴・ユーザー辞書などがそのまま使える。**スナップショットではない** — sandbox 内の `seed_history` や確定操作は本番 DB をそのまま書き換えるため、検証用途のシードは原則 in-memory（`useRealDB` なし）で行う。 |

ユーザーの変換履歴・語彙が含まれるため、ログ共有時は取り扱いに注意する。

**modifier フラグ（mods）:** Shift=131072、Command=1048576、Option=524288。複数は OR で合成。

**キーコード一覧（特殊キーのみ）:**
```
space=49  enter=36  backspace=51  escape=53  tab=48
↓=125  ↑=126  ←=123  →=124
f6=97  f7=98  f8=100  f9=101  f10=109
eisu(英数)=102  kana(かな)=104
```

## レスポンスの読み方

```json
{
  "protocolVersion": 1,         // デバッグプロトコルのバージョン
  "capabilities": { ... },      // このサーバーが対応する機能フラグ
  "inserted": ["漢字"],          // 確定されたテキスト（空 = まだ組成中）
  "markedText": "かんじ",        // setMarkedText に渡された文字列
  "composedHiragana": "かんじ",  // ひらがな組成バッファ
  "pendingRomaji": "",           // まだひらがなになっていないローマ字
  "composingText": "かんじ",     // composedHiragana + pendingRomaji
  "isAsciiMode": false,
  "isSuccessorCandidateActive": false, // 後続語候補表示中（組成空 + 候補 visible）
  "isBracketMode": false,        // 括弧候補モード
  "isExplicitlySelected": false, // ↑↓で明示的に候補を選択したか
  "candidateVisible": true,
  "selectedRow": 0,
  "selectedText": "漢字",
  "fixedEnd": 1,                 // 先頭から連続する hiragana preferred 行数（Zenzai 診断用）
  "candidates": ["漢字", "感じ", ...],
  "committedHistory": ["今日", "は"],
  "isZenzaiEnabled": true,
  "leftSideContext": "申請書を",
  "candidateEntries": [          // 行ごとの section（正本）。fixed / history / dictionary
    {"index": 0, "text": "漢字", "section": "history"}
  ],
  "changed": ["candidateVisible", "candidates"], // 直前のキー処理で変化した主要フィールド
  "explain": {                   // explain=true のときだけ追加される要約
    "activeModes": ["successor"],
    "composition": {"composingText":"かんじ", "composedHiragana":"かんじ", "pendingRomaji":""},
    "candidateSummary": {"visible": true, "count": 10, "selectedRow": 0, "selectedText": "漢字", "sectionCounts": {"fixed": 2, "history": 3}},
    "changedFields": ["candidates", "candidateEntries"]
  }
}
```

エラー時は後方互換で `error`（文字列）を残しつつ、`errorDetail` に構造化情報が入る:

```json
{
  "error": "missing keyCode",
  "errorDetail": {
    "code": "MISSING_KEYCODE",
    "message": "missing keyCode",
    "hint": "Use keyCode/chars/base/mods or the shorthand {\"key\":\"space\"}.",
    "suggestedFixes": [
      {"key": "space"},
      {"schema": true}
    ]
  }
}
```

`test_suite` の失敗シナリオには `reproCommand` が付く。失敗ケースだけを切り出して再実行できる（`before_each` / `after_each` / `vars` / `useRealDB` を保持）。

**候補リストの構造（flatten 後）:**
- 候補列は `CandidateScoreBuilder` のスコア降順
- 各行のセクションは `candidateEntries[].section`（= `ScoredCandidate.Source` から導出）
- Shift+Delete 可: `section == "history"` の行のみ
- `fixedEnd`: 先頭連続 hiragana preferred 行数（索引レンジではない）

## テストケース設計の落とし穴

**テストを書く前に必ずこの節を確認すること。** 以下の罠にはまると無駄な試行錯誤が発生する。

### 罠1: 特殊変換される語を避ける

一部の語は AzooKey が辞書外の特殊変換を返す。テストケースに使うと意図しない結果になる。

| 語 | 問題 |
|----|------|
| `kyou`（きょう） | 今日の日付「2026年5月24日」に変換される |
| `kinou`（きのう） | 昨日の日付に変換される可能性あり |

**代替**: 汎用名詞（`kanzi`→漢字、`jissou`→実装、`nyuuryoku`→入力）を使う。

### 罠2: ローマ字の不連続に注意する

`type_string` の文字列はキーコードを1文字ずつ送るため、ローマ字が完成しないと `composedHiragana` と `pendingRomaji` に分割される。

```
"tokyo" → composedHiragana="と", pendingRomaji="kyo"
           ↑ "と" だけ変換候補に出て意図した挙動にならない
```

**対策**: `type_string` 送信後に `composedHiragana` を確認してから assert を書く。

```python
r = send({"type_string": "tokyo", "fields": ["composedHiragana", "pendingRomaji"]})
print(r["composedHiragana"], r["pendingRomaji"])
# → 期待と違ったら読みを修正する（例: "toukyou" にする）
```

正しいローマ字が分からない場合は先に確認してから assert するとよい。

### 罠3: 1位候補を決め打ちしない

空のインメモリ DB では AzooKey の辞書順がそのまま出る。同音異義語の1位は文脈・設定によって変わるため `inserted: ["特定の語"]` のような完全一致 assert は壊れやすい。

```python
# Bad: "漢字" が1位とは限らない
"assert": {"inserted": ["漢字"]}

# Good: 候補リストに含まれることだけを確認
"assert_contains": {"candidates": "漢字"}
```

### 罠4: Successor モードはインメモリ DB では起動しない

Successor モードの起動には `leftSideContext` 末尾の名詞相当語と履歴前方一致が必要。content_bigram は 2026-05-25 に削除済み（[PLAN260525](../../plans/PLAN260525-session-text-buffer.md)）。

Zenzai 左文脈は `sessionTextBuffer`（`set_left_context` または確定の積み重ね）で検証する。

```python
# Zenzai + sessionTextBuffer: 文末後も文脈が残ること
send({"reset": True})
send({"type_string": "houkoku", "then": "space"})
send({"key": "enter", "fields": ["sessionTextBuffer"]})
send({"type_string": "。"})  # 句点は直挿入。組成なし Enter は buffer をクリアするので送らない
r = send({"state": True, "fields": ["sessionTextBuffer", "committedHistory"]})
assert r["sessionTextBuffer"] == "報告書"  # houkoku 確定が「報告書」の場合
assert r["committedHistory"] == []  # 文末で history はクリア、buffer は残る
```

### 罠6: 組成なし Enter で sessionTextBuffer が消える

組成中テキストが空の状態で Enter を送ると `sessionTextBuffer` がクリアされる（`testSessionTextBufferClearedOnBareEnter`）。句点 `。` を `type_string` で直挿入した直後に `then: "enter"` すると buffer が空になるので注意。

### 罠5: ローマ字の seed_history と type_string を揃える

`seed_history` の `input` は**ひらがな**（読み）、`type_string` は**ローマ字**。
`type_string` が変換した `composedHiragana` と `seed_history` の `input` が一致しないと履歴がヒットしない。

```python
# seed の input は type_string で作られるひらがなに合わせる
send({"seed_history": {"input": "じっそう", "output": "実装", "times": 3}})
r = send({"type_string": "jissou", "then": "space"})  # jissou → じっそう ✓
```

### 罠7: `seed_history` 後の `then: "space"` 一発は辞書候補を潰す

Debug ソケットは `deferAzooKeyWhileTyping = true`。`seed_history` のあと `{"type_string":"kanzi","then":"space"}` を**1 コマンドで**送ると、打鍵中の AzooKey prefetch が Space より先に完了せず、辞書セクションが極端に少なくなる（例: 19 件 → 2 件）。**実装バグではなく手順の問題**に見える。

**対策**: 履歴シードありの候補検証は必ず次の順序にする。

```python
send({"reset": True})
send({"seed_history": {"input": "かんじゃ", "output": "幹事", "times": 5}})
send({"type_string": "kanzi"})                    # 打鍵のみ
send({"wait_azoo_key": {"timeoutMs": 3000}})      # prefetch 完了待ち
r = send({"key": "space", "fields": ["candidates", "candidateEntries"]})
```

**健全性チェック**: ベースライン（シードなし）と比べて `len(candidates)` が桁違いに少ないときは、まず `wait_azoo_key` を挟んで再測する。

### 罠8: 検証語は AzooKey 辞書に存在することを先に確認する

履歴・辞書の出し分けを検証するとき、期待する output が AzooKey 辞書に無いと「どちらにも出ない」が**正しい挙動**に見える。例: `かんじ` 読みの `感情` は辞書候補に載らない。

```python
send({"reset": True})
r = send({"type_string": "kanzi", "then": "space", "fields": ["candidates"]})
assert "感じ" in r["candidates"]  # 検証語をここで確認してからシード設計
```

top3 漏れケースは `times` でスコア差をつけ、4 件目は**辞書にもある語**（例: `かんじめ`→`感じ`）にする。assert は `candidateEntries` の `section`（`history` / `dictionary`）で書く。

---

## 候補リスト変更の検証ワークフロー（推奨）

`CandidateScoreBuilder` / flatten 変更後は、次の順で確認する。

1. **ユニットテスト** — `CandidateScoreBuilderTests` / `InputHandlerCandidateSnapshotTests` に再現ケースを足す（正本）
2. **sandbox ベースライン** — シードなしで検証語が AzooKey に出ることを確認（罠8）
3. **sandbox シナリオ** — `seed_history` → `type_string` → `wait_azoo_key` → `key: space`（罠7）
4. **assert** — `candidateEntries[].section` と候補順（スコア interleave を許容）

```python
# top3 漏れ → 辞書に残る（c73e8d9 以降の代表例）
send({"reset": True})
for inp, out, n in [("かんじゃ","幹事",5), ("かんじゃく","弱点",5), ("かんじる","感じる",5), ("かんじめ","感じ",1)]:
    for _ in range(n):
        send({"seed_history": {"input": inp, "output": out, "times": 1}})
send({"type_string": "kanzi"})
send({"wait_azoo_key": {"timeoutMs": 3000}})
r = send({"key": "space", "fields": ["candidates", "candidateEntries"]})
entries = {e["text"]: e["section"] for e in r["candidateEntries"]}
assert entries.get("感じ") == "dictionary"
```

---

## 典型的な調査パターン

### 1. 入力列を追って状態変化を確認

```python
send({"reset": True})
# return_steps: true で各文字入力後の状態を一括取得
r = send({"type_string": "kanzi", "return_steps": True})
for i, step in enumerate(r["steps"]):
    ch = "kanzi"[i]
    print(f"'{ch}': composed={step['composedHiragana']!r}, pending={step['pendingRomaji']!r}")
```

### 2. Space で変換して候補を確認

シードなしの簡易確認:

```python
r = send({"type_string": "kanzi", "then": "space"})
print(f"candidates: {r['candidates'][:10]}")
print(f"fixedEnd={r['fixedEnd']}")
```

`seed_history` あり・辞書セクションの件数も見るときは罠7の手順（`wait_azoo_key` 挟み）を使う。

### 3. 候補を選択して確定

```python
# ↓ で3番目を選択してから Enter（sequence でバッチ送信）
r = send({"sequence": [
    {"type_string": "kanzi", "then": "space"},
    {"key": "down"},
    {"key": "down"},
    {"key": "enter"},
]})
print(f"inserted: {r['last']['inserted']}")
print(f"successor candidates: {r['last']['candidates'][:5]}")
```

### 4. Successor モードの確認（useRealDB 必須）

```python
# インメモリ DB では POS 分類が非同期のため Successor は起動しない。
# useRealDB: true で実 DB を使い、過去に入力実績のある名詞で確認する。
send({"reset": True, "useRealDB": True})
r = send({"type_string": "jissou", "then": "space"})
r2 = send({"key": "enter"})
print(f"isSuccessorCandidateActive: {r2['isSuccessorCandidateActive']}")
print(f"successor candidates: {r2['candidates'][:5]}")
```

### 5. 行単位でケースを分けてログを取る（Sandbox 連携）

Sandbox ウィンドウの左ペインは **1行 = 1テストケース**。Enter で行が確定し次の行へ進む。
`reset` は Sandbox のログもクリアするので、複数ケースを比較するときのテンプレート:

```python
send({"reset": True})   # Sandbox ログもリセット

# ケース1: こんにちは
send({"type_string": "konnitiha", "then": "enter"})   # Enter で行1確定

# ケース2: ありがとう
send({"type_string": "arigatou", "then": "enter"})    # Enter で行2確定

# ログを行単位で取得
r_all = send({"get_log": True})
for block in r_all["log"]:
    print(f"line #{block['lineIndex']+1}: {block['displayText']!r}  ({len(block['events'])} events)")

# 特定行だけ取得（lineIndex は 0 始まり）
r1 = send({"get_log": True, "line": 0})   # 行1
r2 = send({"get_log": True, "line": 1})   # 行2
print(r1["log"][0]["events"][-1]["summary"])   # 行1の最終イベント
```

`get_log` レスポンスの構造:
```json
{
  "log": [
    {
      "lineIndex": 0,
      "displayText": "こんにちは",
      "events": [ { "composedHiragana": "...", "summary": "...", "source": "ime", ... }, ... ]
    }
  ],
  "count": 1
}
```

- `displayText` — その行で確定されたテキストの結合（`insertText` の累積）
- `events` — その行に紐づく全スナップショット（`source`: `"ime"` / `"socket"` / `"annotation"`）
- Enter をソケット経由で送ると行が自動的に進む（`keyCode 36` 後に組成がなければ `finishCurrentLine` が走る）

### 6. Zenzai top-1 プロモーションの確認

Zenzai プロモーションには **isZenzaiEnabled=true** かつ **leftSideContext が非空** の両方が必要。
`set_left_context` で左コンテキストを強制セットして検証する。

```python
send({"reset": True, "useRealDB": True})
send({"set_left_context": "申請書を"})           # leftSideContext を固定（reset で解除される）
send({"seed_history": {"input": "しんせい", "output": "申請フォーム", "times": 5}})

r = send({"type_string": "shinsei", "then": "space",
          "fields": ["isZenzaiEnabled", "leftSideContext",
                     "fixedEnd", "selectedRow", "selectedText", "candidateEntries"]})

print(f"isZenzaiEnabled={r['isZenzaiEnabled']}, leftSideContext={r['leftSideContext']!r}")
print(f"fixedEnd={r['fixedEnd']}")
print(f"selectedRow={r['selectedRow']}, selectedText={r['selectedText']!r}")
# fixedEnd >= 1 かつ selectedRow == 0 なら Zenzai top-1 が初期選択されている
```

**診断チェックリスト:**
- `isZenzaiEnabled=false` → 設定画面で Zenzai をオンにする
- `leftSideContext=''` → `set_left_context` でコンテキストをセットする
- `fixedEnd=0` → Zenzai プロモートなし（上 2 点を確認）
- `fixedEnd>=1, selectedRow=0` → 正常（`.show` 直後は常に row 0。Zenzai 診断用 fixed 範囲あり）
- `fixedEnd>=1, selectedRow>0` → ユーザーが ↑↓/Space で移動済み（正常。initial row ポリシーは廃止済み）

## 注意点

- **IMK パイプラインをバイパス**するため、クライアントアプリ依存の挙動（Electron の Enter 問題など）は再現しない
- デフォルトのリセットではソケットサーバーは**インメモリ DB**。**`{"reset": true, "useRealDB": true}`** を使うと `DatabaseManager.shared` 経由で本番 `history.db` をそのまま共有する（コピーではない）。sandbox 内の `seed_history` / 確定が本番 DB を書き換える点に注意
- デフォルトの `leftSideContext` は `LeftContextSource.resolveSandbox` で `sessionTextBuffer` + `mockClient.documentBefore` を結合（`set_surrounding.before` で設定可）。`set_surrounding` / `set_left_context` / `{"state": true}` / キー処理の各レスポンスで再計算済みの `leftSideContext` が返る。確定直後 Backspace（IME 非消費）では直前確定語を `documentBefore` から削除して本番 IMK の `before` 更新を模倣する
- **LLM は Debug ビルドのサーバー上で動く**（上記「LLM（Debug ビルド）」）。完了タイミングを見るときは `{"state": true}` ポーリング
- セッションをまたぐときは必ず `{"reset": true}` を送信して状態をリセットすること（`reset` で LLM フェッチもキャンセルされ `llmEpoch` が進む）
- 調査結果を報告するときは、各キー入力後の状態を表形式か箇条書きで整理して示すと読みやすい
