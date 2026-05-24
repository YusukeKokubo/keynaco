---
name: keynaco-ime-sandbox
description: |
  keynaco IME のデバッグソケットサーバーを使って、キー入力シーケンスを送信し IME の内部状態（組成文字列・候補リスト・モードフラグ・確定履歴）を観察・調査するスキル。

  次のような場面で積極的に使うこと:
  - 「"kanzi" と入力したら何候補が出るか」など特定の入力列の挙動を確認したいとき
  - Successor モード・セグメントモード・ブラケットモードの動作を検証したいとき
  - 候補の並び順・historyEnd・fixedEnd の値を確認したいとき
  - 複数の入力パターンを比較して IME のロジックを調べたいとき
  - ユーザーが「このシーケンスを試して」「このケースをデバッグして」と言ったとき
  - Zenzai top-1 プロモーションの動作を検証したいとき（set_left_context + isZenzaiEnabled を使う）
---

# keynaco IME サンドボックスの使い方

## 前提

- keynaco（Debug ビルド）が起動していること
- `$TMPDIR/keynaco-debug.sock` にソケットが存在すること
- Python 3 が使えること

起動確認（**必ず最初に実行**。ファイルの有無だけでなくプロセスの生死を確認すること）:
```bash
pgrep -x keynaco && echo "keynaco running" || echo "keynaco not running — Debug ビルドを起動してください"
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
| スキーマ assert | `{"state":true,"assert_schema":{"candidates":"array<string>","historyEnd":"int"}}` |
| 正規表現 assert | `{"state":true,"assert_regex":{"markedText":"^\\\".*\\\"$"}}` |
| 非同期待機 | `{"wait_until":{"field":"candidates","minCount":1,"timeoutMs":1500}}` |
| 非同期アサート（待機+検証） | `{"assert_eventually":{"field":"candidates","contains":"漢字","timeoutMs":1500}}` |
| 複数シナリオを一括実行 | `{"test_suite":[{"name":"kanzi変換","cmds":[...],"assert":{"inserted":["漢字"]}}]}` |
| test_suite 共通前処理/後処理 | `{"before_each":[...], "after_each":[...], "test_suite":[...]}` |
| test_suite fail-fast | `{"test_suite":[...], "fail_fast": true}`（最初の失敗で打ち切り） |
| 失敗/タイムアウト期待 | `{"test_suite":[{"expect_error":true, ...}]}` / `{"expect_timeout":true, ...}` |
| スイートの静的検証 | `{"lint_suite":[...], "before_each":[...]}`（実行せずに問題点を返す） |
| 変数展開（再利用） | `{"sequence":[...], "vars":{"needle":"漢字"}}` と `{{needle}}` |
| ステップ結果の capture | `{"capture":{"top":"selectedText","h":"historyEnd"}}`（`sequence` の `vars` に保存） |
| 名前付きキー | `{"key": "space"}` / `{"key": "enter"}` / `{"key": "down"}` 等 |
| Shift+名前付きキー | `{"key": "backspace", "mods": 131072}` |
| フィールド絞り込み | `{"type_string": "kanzi", "then": "space", "fields": ["candidates", "historyEnd"]}` |
| インラインアサート | `{"type_string": "kanzi", "assert": {"composedHiragana": "かんじ"}}` |
| noun-bigram シード | `{"seed_noun_bigram": {"prev": "東京", "input": "あめ", "output": "雨", "count": 5}}` |
| 履歴シード | `{"seed_history": {"input": "かんじ", "output": "漢字", "times": 3}}` |
| Zenzai 左コンテキスト固定 | `{"set_left_context": "申請書を"}` — Zenzai プロモートの有効化に必須。空文字で解除 |

`then` に指定できる名前: `space` / `enter` / `backspace` / `escape` / `tab` / `down` / `up` / `left` / `right` / `f6`–`f10` / `eisu` / `kana`

**使用例:**
```python
# "kanzi" を入力して Space で変換 → 候補だけ得る（fields で絞り込み）
r = send({"type_string": "kanzi", "then": "space", "fields": ["candidates", "historyEnd"]})
print(r["candidates"][:5])

# assert でインライン検証 → 失敗時は {"assertion_failed": [...], "state": {...}} が返る
r = send({"type_string": "kanzi", "assert": {"composedHiragana": "かんじ"}})
if "assertion_failed" in r:
    print("FAIL:", r["assertion_failed"])

# スキーマ検証（型崩れ検知）
r_schema = send({"state": True, "assert_schema": {"candidates": "array<string>", "historyEnd": "int"}})
print("schema_ok?", "assertion_failed" not in r_schema)

# 正規表現検証（JSON化した値に対して評価）
r_regex = send({"state": True, "assert_regex": {"composedHiragana": ".*"}})
print("regex_ok?", "assertion_failed" not in r_regex)

# bi-gram をシードしてから Successor を確認（useRealDB 必須。インメモリ DB では POS 分類が完了しない）
send({"reset": True, "useRealDB": True})
send({"seed_noun_bigram": {"prev": "実装", "input": "する", "output": "する", "count": 5}})
r = send({"type_string": "jissou", "then": "enter"})
print(f"isSuccessorCandidateActive: {r['isSuccessorCandidateActive']}, candidates: {r['candidates'][:3]}")

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
        {"seed_noun_bigram": {"prev": "東京", "input": "あめ", "output": "雨", "count": 5}}
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
| `{"reset": true}` | インメモリ DB でリセット。必要なら `seed_noun_bigram` / `seed_history` でデータを注入する。 |
| `{"reset": true, "useRealDB": true}` | 実体の `~/Library/Application Support/keynaco/history.db` を一時コピーして開く。変換履歴・ユーザー辞書・`boundary_pref`・学習 noun-bigram などがそのまま使える。 |

`history.db` が存在しない、またはコピー失敗（DB ロック等）のときは `useRealDB` は無視され、上と同じインメモリ DB にフォールバックする。スナップショットにはユーザーの変換履歴・語彙が含まれるため、ログ共有時は取り扱いに注意する。

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
  "isSegmentMode": false,        // 文節調整モード
  "isBracketMode": false,        // 括弧候補モード
  "isExplicitlySelected": false, // ↑↓で明示的に候補を選択したか
  "candidateVisible": true,
  "selectedRow": 0,
  "selectedText": "漢字",
  "historyEnd": 3,               // 履歴セクション末尾インデックス
  "fixedEnd": 2,                 // 固定候補（かな/カタカナ）末尾
  "candidates": ["漢字", "感じ", ...],
  "committedHistory": ["今日", "は"],
  "segmentTexts": [],            // セグメントモード中の文節テキスト
  "focusedSegmentIndex": 0,
  "predictionEnd": 0,            // 予測ブロック末尾（本番の CandidateWindow と同様）
  "isZenzaiEnabled": true,        // AzooKeyConverter の zenzaiEnabled フラグ
  "leftSideContext": "申請書を",  // 現在の leftSideContext（空なら Zenzai プロモートなし）
  "candidateEntries": [          // candidates の行ごとのメタデータ
    {"index": 0, "text": "漢字", "section": "fixed|prediction|history|dictionary_or_special"}
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

**候補リストの構造:**
- `[0, fixedEnd)` — ひらがな・カタカナ固定候補
- `[fixedEnd, historyEnd)` — ユーザー辞書 + 履歴候補（Shift+Delete 削除可能）
- `[historyEnd, ...)` — AzooKey 辞書候補

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

Successor モードの起動には2つが必要:
1. 確定語の POS が `noun`/`proper_noun` に分類されていること（Apple Intelligence による**非同期**処理）
2. その語を `prev` とする noun_bigram が DB に存在すること

sandbox のインメモリ DB でこれらを満たすには、POS 分類が完了するまで待つか、実 DB を使う必要がある。短時間セッションでは POS は完了しないため、Successor は起動しない。

```python
# Successor を確認したい場合: useRealDB + 過去に入力実績のある語を使う
send({"reset": True, "useRealDB": True})
r = send({"type_string": "jissou", "then": "space"})
r2 = send({"key": "enter"})
# isSuccessorCandidateActive が true になるのは、実 DB に bigram が蓄積された語のみ
```

### 罠5: ローマ字の seed_history と type_string を揃える

`seed_history` の `input` は**ひらがな**（読み）、`type_string` は**ローマ字**。
`type_string` が変換した `composedHiragana` と `seed_history` の `input` が一致しないと履歴がヒットしない。

```python
# seed の input は type_string で作られるひらがなに合わせる
send({"seed_history": {"input": "じっそう", "output": "実装", "times": 3}})
r = send({"type_string": "jissou", "then": "space"})  # jissou → じっそう ✓
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

```python
r = send({"type_string": "kanzi", "then": "space"})
print(f"candidates: {r['candidates'][:10]}")
print(f"historyEnd={r['historyEnd']}, fixedEnd={r['fixedEnd']}")
```

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

### 5. セグメントモードの確認

```python
send({"reset": True})
r = send({"type_string": "kyounohawaaidesu", "then": "space"})
print(f"isSegmentMode: {r['isSegmentMode']}")
print(f"segments: {r['segmentTexts']}")
```

### 6. 行単位でケースを分けてログを取る（Sandbox 連携）

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

### 7. Zenzai top-1 プロモーションの確認

Zenzai プロモーションには **isZenzaiEnabled=true** かつ **leftSideContext が非空** の両方が必要。
`set_left_context` で左コンテキストを強制セットして検証する。

```python
send({"reset": True, "useRealDB": True})
send({"set_left_context": "申請書を"})           # leftSideContext を固定（reset で解除される）
send({"seed_history": {"input": "しんせい", "output": "申請フォーム", "times": 5}})

r = send({"type_string": "shinsei", "then": "space",
          "fields": ["isZenzaiEnabled", "leftSideContext",
                     "fixedEnd", "historyEnd", "selectedRow", "selectedText", "candidateEntries"]})

print(f"isZenzaiEnabled={r['isZenzaiEnabled']}, leftSideContext={r['leftSideContext']!r}")
print(f"fixedEnd={r['fixedEnd']}, historyEnd={r['historyEnd']}")
print(f"selectedRow={r['selectedRow']}, selectedText={r['selectedText']!r}")
# fixedEnd >= 1 かつ selectedRow == 0 なら Zenzai top-1 が初期選択されている
```

**診断チェックリスト:**
- `isZenzaiEnabled=false` → 設定画面で Zenzai をオンにする
- `leftSideContext=''` → `set_left_context` でコンテキストをセットする
- `fixedEnd=0` → Zenzai プロモートなし（上 2 点を確認）
- `fixedEnd>=1, selectedRow>0` → initialRow がプロモート行をスキップしとる（バグ候補）
- `fixedEnd>=1, selectedRow=0` → 正常（Zenzai top-1 が初期表示）

## 注意点

- **IMK パイプラインをバイパス**するため、クライアントアプリ依存の挙動（Electron の Enter 問題など）は再現しない
- デフォルトのリセットではソケットサーバーは**インメモリ DB**。本番の `history.db` は **`{"reset": true, "useRealDB": true}`** を使ったときのみ一時コピーで参照する
- デフォルトの `leftSideContext` は `mockClient.documentBefore`（`insertText` 累積、`set_surrounding.before` で設定可）。確定直後 Backspace（IME 非消費）では直前確定語を `documentBefore` から削除して本番 IMK の `before` 更新を模倣する。`set_left_context` で上書き可能
- **LLM は Debug ビルドのサーバー上で動く**（上記「LLM（Debug ビルド）」）。完了タイミングを見るときは `{"state": true}` ポーリング
- セッションをまたぐときは必ず `{"reset": true}` を送信して状態をリセットすること（`reset` で LLM フェッチもキャンセルされ `llmEpoch` が進む）
- 調査結果を報告するときは、各キー入力後の状態を表形式か箇条書きで整理して示すと読みやすい
