---
name: run-keynaco
description: |
  keynaco をビルドしてインストールし、動作確認する。
  「run」「start」「build」「動作確認」「smoke test」「スクリーンショット」と言ったとき、
  またはコード変更後に実際に動くか確認したいときに使う。
---

# keynaco の起動と動作確認

keynaco は macOS の IME（Input Method Editor）。通常のアプリと異なりシステムに登録して動く。
ビルド後の post-action が `/Library/Input Methods/` にインストール・プロセス再起動まで行う。
動作確認は `scripts/debug_ime.py` またはこのスキルの `smoke.py` でデバッグソケット経由で行う。

## ビルド＆インストール（`/deploy` スキルと同等）

```bash
xcodebuild build -scheme keynaco -configuration Debug \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO
```

`** BUILD SUCCEEDED **` が出ればインストールまで完了している。

**初回のみ ACL 設定が必要**（一度だけ）:
```bash
sudo chmod +a "$(whoami) allow list,add_file,search,add_subdirectory,delete_child,delete,read,write,execute" "/Library/Input Methods"
```

## keynaco の起動確認

ビルド後、IME プロセスが自動再起動される。起動を確認:

```bash
pgrep -x keynaco && echo "running" || echo "not running"
```

`not running` の場合は macOS の日本語入力に切り替えることでアクティベートされる。
**これだけはユーザーが手動で行う必要がある**（IMK の制約）。

## 動作確認（agent path）

smoke test スクリプトで基本動作を確認する:

```bash
python3 .claude/skills/run-keynaco/smoke.py
```

確認内容:
1. プロセス生死（`pgrep`）
2. デバッグソケット接続（`$TMPDIR/keynaco-debug.sock`）
3. バイナリが HEAD と一致しているか（stale チェック）
4. 基本変換:「kanzi」→ スペースで候補表示 → 「かんじ」が composedHiragana に入るか
5. Enter 確定で `inserted` が空でないか
6. Space で候補窓: 組成中に Space → `candidateVisible=true` かつ候補非空

```
commit: 76a5fa7 (HEAD 一致)
OK: 全 smoke test 通過
```

詳細な IME 動作調査は `keynaco-ime-sandbox` スキルを使う。

## デバッグソケットの直接操作

```python
import socket, json, os

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(SOCKET_PATH)
buf = b""

def send(cmd):
    global buf
    sock.sendall((json.dumps(cmd, ensure_ascii=False) + "\n").encode())
    while b"\n" not in buf:
        buf += sock.recv(4096)
    line, buf = buf.split(b"\n", 1)
    return json.loads(line)

send({"reset": True})
r = send({"type_string": "kanzi", "then": "space", "fields": ["candidates"]})
print(r["candidates"][:5])
```

## テスト実行

コアロジック（`KeynacoCore` SPM パッケージ）:
```bash
cd Core && swift test
```

アプリ全体:
```bash
xcodebuild test -scheme keynaco -destination "platform=macOS"
```

## Gotchas

**IME はユーザーが手動でアクティベートする必要がある**  
`xcodebuild build` はインストールまで行うが、プロセスの起動は macOS のテキスト入力切り替えに依存する。スクリプトから `open keynaco.app` しても IMK は動かない。

**ソケットファイルが残っていても接続できない場合がある**  
`$TMPDIR/keynaco-debug.sock` が存在していても、プロセスが死んでいれば `ConnectionRefusedError`。`pgrep -x keynaco` でプロセス生死を先に確認する。

**バイナリの stale 警告は docs コミット後に出る**  
ソースを変えないドキュメントコミット後はビルドが不要なため HEAD とずれる。変換ロジックを変えたコミット後だけ `/deploy` すれば十分。

**候補1位は文脈・履歴によって変わる**  
インメモリ DB ではなく `useRealDB: true` を使うと実際の変換履歴が影響する。smoke test では特定の候補を1位と決め打ちしない。

**`spctl -a` で "rejected" になるのは正常**  
Development 署名のため Gatekeeper は拒否するが、動作に問題はない。
