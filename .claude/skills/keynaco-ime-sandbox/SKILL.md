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

## ソケットクライアント

`scripts/debug_ime.py` が用意されている。対話モードとバッチモードがある。

**バッチ（コマンドから）:**
```bash
python3 scripts/debug_ime.py kanzi
```

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
| 文字列→確定（全ステップも取得） | `{"type_string": "kyou", "then": "enter", "return_steps": true}` |
| サーバースキーマ取得（AI向け） | `{"schema": true}` |
| コマンド列を一括送信 | `{"sequence": [{cmd1}, {cmd2}, ...]}` → `{"steps": [...], "last": {...}}` |
| ステップごとの説明ラベル | `{"type_string": "kanzi", "describe": "ローマ字入力"}`（レスポンスにも `describe` が返る） |
| sequence 中間ステップ assert | `{"sequence": [{"type_string":"kanzi","assert":{"composedHiragana":"かんじ"}}, {"key":"space","assert":{"candidateVisible":true}}]}` |
| 部分一致 assert | `{"key":"space","assert_contains":{"candidates":"漢字"}}` / `{"assert_contains":{"candidates":["漢字","感じ"]}}` |
| 否定 assert | `{"state":true,"assert_not":{"isAsciiMode":true}}` |
| スキーマ assert | `{"state":true,"assert_schema":{"candidates":"array<string>","historyEnd":"int"}}` |
| 正規表現 assert | `{"state":true,"assert_regex":{"markedText":"^\\\".*\\\"$"}}` |
| 非同期待機 | `{"wait_until":{"field":"successorLLMSurfaceExtras","minCount":1,"timeoutMs":1500}}` |
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
| bi-gram シード | `{"seed_bigram": {"prev": "今日", "input": "は", "output": "は", "count": 10}}` |
| 履歴シード | `{"seed_history": {"input": "かんじ", "output": "漢字", "times": 3}}` |

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

# bi-gram をシードしてから Successor を確認
send({"seed_bigram": {"prev": "今日", "input": "は", "output": "は", "count": 10}})
r = send({"type_string": "kyou", "then": "enter"})
print(f"isSuccessorMode: {r['isSuccessorMode']}, candidates: {r['candidates'][:3]}")

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
        {"seed_bigram": {"prev": "今日", "input": "は", "output": "は", "count": 10}}
    ],
    "after_each": [
        {"state": True, "describe": "終了時状態確認"}
    ],
    "fail_fast": True,
    "test_suite": [
        {
            "name": "kyou→enter",
            "cmds": [{"type_string": "kyou", "then": "enter"}],
            "assert_contains": {"candidates": "は"}
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

# LLM の非同期反映を待つ（state 連打せずに待機）
waited = send({
    "wait_until": {
        "field": "successorLLMSurfaceExtras",
        "minCount": 1,
        "timeoutMs": 1500,
        "intervalMs": 50
    },
    "describe": "LLM extras待機"
})
print(waited["matched"], waited["state"]["successorLLMSurfaceExtras"])
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
| `{"reset": true}` | インメモリ DB（`preset_bigram.csv` シード済み）でリセット。Successor の preset 候補が本番に近い。 |
| `{"reset": true, "useRealDB": true}` | 実体の `~/Library/Application Support/keynaco/history.db` を一時コピーして開く。変換履歴・ユーザー辞書・`boundary_pref`・学習 bigram などがそのまま使える。 |

`history.db` が存在しない、またはコピー失敗（DB ロック等）のときは `useRealDB` は無視され、上と同じインメモリ（preset シード済み）にフォールバックする。スナップショットにはユーザーの変換履歴・語彙が含まれるため、ログ共有時は取り扱いに注意する。

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
  "isSuccessorMode": false,      // 後続語予測モード
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
  "successorLLMSurfaceExtras": [] // 後続語 LLM が返した表層形（コールバック後に増える）
}
```

エラー時は後方互換で `error`（文字列）を残しつつ、`errorDetail` に構造化情報が入る:

```json
{
  "error": "missing keyCode",
  "errorDetail": {
    "code": "MISSING_KEYCODE",
    "message": "missing keyCode",
    "hint": "Use keyCode/chars/base/mods or the shorthand {\"key\":\"space\"}."
  }
}
```

## LLM（Debug ビルド）

`keynaco/Debug/DebugSocketServer.swift` は **`InputController` と同順**で `LLMSuccessorFetcher` / `LLMSegmentConverter` をスケジュールする（キー処理の直後に `applyLLMScheduling()`）。

- **非同期**: 1 行の JSON 応答は、そのキー処理直後の状態。LLM の推論完了は後から届く。
- **観察方法**: 同一ソケットで `{"state": true}` を送り **ポーリング**する。`successorLLMSurfaceExtras` の増加、セグメント全文の更新が反映されたか確認できる。
- **Successor の extras**: `pendingLowConfidence` 経路では、オンデバイス LLM の表層形はまず `successorLLMSurfaceExtras` にだけ溜まる。`candidates` へ載るのは **次のキー処理で `mergePendingSuccessorMatches` が走ったとき**（本番と同じ）。ポーリングだけでは extras は増えても一覧が変わらない場合がある。
- 設計メモ: `plans/PLAN260504f.md`

**候補リストの構造:**
- `[0, fixedEnd)` — ひらがな・カタカナ固定候補
- `[fixedEnd, historyEnd)` — ユーザー辞書 + 履歴候補（Shift+Delete 削除可能）
- `[historyEnd, ...)` — AzooKey 辞書候補

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

### 4. Successor モードの確認

```python
send({"reset": True})
r = send({"type_string": "kyou", "then": "enter"})
print(f"isSuccessorMode: {r['isSuccessorMode']}")
print(f"successor candidates: {r['candidates'][:5]}")
```

### 5. セグメントモードの確認

```python
send({"reset": True})
r = send({"type_string": "kyounohawaaidesu", "then": "space"})
print(f"isSegmentMode: {r['isSegmentMode']}")
print(f"segments: {r['segmentTexts']}")
```

## 注意点

- **IMK パイプラインをバイパス**するため、クライアントアプリ依存の挙動（Electron の Enter 問題など）は再現しない
- デフォルトのリセットではソケットサーバーは**インメモリ DB**（`preset_bigram.csv` シード済み）。本番の `history.db` は **`{"reset": true, "useRealDB": true}`** を使ったときのみ一時コピーで参照する
- **LLM は Debug ビルドのサーバー上で動く**（上記「LLM（Debug ビルド）」）。完了タイミングを見るときは `{"state": true}` ポーリング
- セッションをまたぐときは必ず `{"reset": true}` を送信して状態をリセットすること（`reset` で LLM フェッチもキャンセルされ `llmEpoch` が進む）
- 調査結果を報告するときは、各キー入力後の状態を表形式か箇条書きで整理して示すと読みやすい
