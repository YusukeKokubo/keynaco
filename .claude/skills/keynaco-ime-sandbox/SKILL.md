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
| リセット | `{"reset": True}` |
| 現在状態取得 | `{"state": True}` |

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
  "focusedSegmentIndex": 0
}
```

**候補リストの構造:**
- `[0, fixedEnd)` — ひらがな・カタカナ固定候補
- `[fixedEnd, historyEnd)` — ユーザー辞書 + 履歴候補（Shift+Delete 削除可能）
- `[historyEnd, ...)` — AzooKey 辞書候補

## 典型的な調査パターン

### 1. 入力列を追って状態変化を確認

```python
send({"reset": True})
for ch in "kanzi":
    r = send({"keyCode": 0, "chars": ch, "base": ch, "mods": 0})
    print(f"'{ch}': composed={r['composedHiragana']!r}, pending={r['pendingRomaji']!r}, candidates={r['candidates'][:3]}")
```

### 2. Space で変換して候補を確認

```python
r = send({"keyCode": 49, "chars": " ", "base": " ", "mods": 0})
print(f"candidates: {r['candidates'][:10]}")
print(f"historyEnd={r['historyEnd']}, fixedEnd={r['fixedEnd']}")
```

### 3. 候補を選択して確定

```python
# ↓ で3番目を選択してから Enter
for _ in range(2):
    send({"keyCode": 125, "chars": "", "base": "", "mods": 0})
r = send({"keyCode": 36, "chars": "\r", "base": "\r", "mods": 0})
print(f"inserted: {r['inserted']}")
print(f"successor candidates: {r['candidates'][:5]}")  # 確定後の後続語
```

### 4. Successor モードの確認

```python
# 単語を確定してから後続語候補を確認
send({"reset": True})
for ch in "kyou": send({"keyCode": 0, "chars": ch, "base": ch, "mods": 0})
r = send({"keyCode": 36, "chars": "\r", "base": "\r", "mods": 0})
print(f"isSuccessorMode: {r['isSuccessorMode']}")
print(f"successor candidates: {r['candidates'][:5]}")
```

### 5. セグメントモードの確認

```python
# 長い文を入力して Space でセグメントモードへ
send({"reset": True})
for ch in "kyounohawaaidesu": send({"keyCode": 0, "chars": ch, "base": ch, "mods": 0})
r = send({"keyCode": 49, "chars": " ", "base": " ", "mods": 0})
print(f"isSegmentMode: {r['isSegmentMode']}")
print(f"segments: {r['segmentTexts']}")
```

## 注意点

- **IMK パイプラインをバイパス**するため、クライアントアプリ依存の挙動（Electron の Enter 問題など）は再現しない
- ソケットサーバーは**独立した in-memory DB** を持つ。実際の使用履歴（`~/Library/Application Support/keynaco/history.db`）は参照しない
- LLM による候補スコアリング・後続語 LLM は**起動しない**（`InputController` の非同期処理に依存するため）
- セッションをまたぐときは必ず `{"reset": True}` を送信して状態をリセットすること
- 調査結果を報告するときは、各キー入力後の状態を表形式か箇条書きで整理して示すと読みやすい
