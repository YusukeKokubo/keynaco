#!/usr/bin/env python3
"""keynaco smoke test — ビルド後の基本動作を確認する。

使い方:
  python3 .claude/skills/run-keynaco/smoke.py

終了コード:
  0 = 全テスト通過
  1 = keynaco 未起動 or ソケット接続失敗
  2 = smoke test 失敗
"""
import json
import os
import subprocess
import sys
import socket as _socket

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")


def check_process() -> bool:
    r = subprocess.run(["pgrep", "-x", "keynaco"], capture_output=True)
    return r.returncode == 0


def connect() -> _socket.socket:
    sock = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
    sock.connect(SOCKET_PATH)
    return sock


buf = b""


def send(sock: _socket.socket, cmd: dict) -> dict:
    global buf
    sock.sendall((json.dumps(cmd, ensure_ascii=False) + "\n").encode())
    while b"\n" not in buf:
        buf += sock.recv(4096)
    line, buf = buf.split(b"\n", 1)
    return json.loads(line)


def main() -> int:
    # 1. プロセス確認
    if not check_process():
        print("ERROR: keynaco is not running.")
        print("  → /deploy でビルド＆インストール後、日本語入力に切り替えてください。")
        return 1

    # 2. ソケット接続
    try:
        sock = connect()
    except (ConnectionRefusedError, FileNotFoundError):
        print("ERROR: debug socket に接続できません。")
        print(f"  socket: {SOCKET_PATH}")
        print("  → keynaco が起動直後の場合は数秒待ってから再試行してください。")
        return 1

    # 3. stale チェック
    r = send(sock, {"state": True, "fields": ["buildInfo"]})
    commit = r.get("buildInfo", {}).get("commit", "unknown")
    head = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"]).decode().strip()
    if commit == "unknown":
        print("WARNING: buildInfo.commit が取得できません（古い DebugSocketServer）。")
        print("  → /deploy で再ビルドしてください。")
    elif commit != head:
        print(f"WARNING: バイナリが古い可能性があります。running={commit} HEAD={head}")
        print("  → /deploy で再ビルドしてください。")
    else:
        print(f"commit: {commit} (HEAD 一致)")

    # 4. smoke tests
    failures = []

    send(sock, {"reset": True})

    # 基本変換
    r = send(sock, {"type_string": "kanzi", "then": "space", "fields": ["candidates", "composedHiragana"]})
    if r.get("composedHiragana") != "かんじ":
        failures.append(f"composedHiragana: expected 'かんじ' got {r.get('composedHiragana')!r}")
    if "漢字" not in r.get("candidates", []):
        failures.append(f"candidates: '漢字' が見つかりません: {r.get('candidates', [])[:5]}")

    # Enter 確定（候補1位が何であれ確定されること）
    r2 = send(sock, {"key": "enter"})
    if not r2.get("inserted"):
        failures.append(f"inserted: 確定テキストが空でした: {r2.get('inserted')}")

    # Space で候補窓表示（組成中）
    send(sock, {"reset": True})
    r3 = send(sock, {"type_string": "kanzi", "then": "space",
                     "fields": ["candidateVisible", "candidates"]})
    if not r3.get("candidateVisible"):
        failures.append("candidateVisible: Space 後に候補窓が表示されませんでした")
    if not r3.get("candidates"):
        failures.append("candidates: Space 後に候補が空でした")

    sock.close()

    if failures:
        print(f"\nFAIL: {len(failures)} 件のテストが失敗しました")
        for f in failures:
            print(f"  ✗ {f}")
        return 2

    print("OK: 全 smoke test 通過")
    return 0


if __name__ == "__main__":
    sys.exit(main())
