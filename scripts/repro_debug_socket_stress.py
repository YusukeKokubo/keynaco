#!/usr/bin/env python3
"""Debug ソケットのストレステスト: 落ちる・ECONNREFUSED 再現の切り分け用。"""
from __future__ import annotations

import json
import os
import random
import socket
import subprocess
import sys
import threading
import time
from typing import Any

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")


def keynaco_pid() -> int | None:
    r = subprocess.run(["pgrep", "-x", "keynaco"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return int(r.stdout.strip().split("\n")[0])


def connect() -> tuple[socket.socket, bytearray]:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10.0)
    s.connect(SOCKET_PATH)
    return s, bytearray()


def send_recv(s: socket.socket, buf: bytearray, cmd: dict[str, Any]) -> dict[str, Any]:
    s.sendall((json.dumps(cmd, ensure_ascii=False) + "\n").encode())
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            raise ConnectionError("EOF")
        buf += chunk
    line, rest = buf.split(b"\n", 1)
    buf[:] = rest
    return json.loads(bytes(line))


def one_session(ops: list[dict[str, Any]], label: str) -> None:
    buf = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(30.0)
        s.connect(SOCKET_PATH)
        for cmd in ops:
            send_recv(s, buf, cmd)
    print(f"  [{label}] ok ({len(ops)} ops)")


def stress_sequential_roundtrips(n: int) -> None:
    buf = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(60.0)
        s.connect(SOCKET_PATH)
        send_recv(s, buf, {"reset": True})
        for i in range(n):
            r = send_recv(
                s,
                buf,
                {
                    "keyCode": 0,
                    "chars": random.choice("abcdefghijklmnopqrstuvwxyz"),
                    "base": random.choice("abcdefghijklmnopqrstuvwxyz"),
                    "mods": 0,
                },
            )
            if i % 200 == 0 and i > 0:
                send_recv(s, buf, {"reset": True})
        send_recv(s, buf, {"state": True})
    print(f"  [sequential x{n}] ok")


def stress_parallel_clients(num_clients: int, cmds_per: int) -> None:
    errors: list[str] = []
    lock = threading.Lock()

    def worker(wid: int) -> None:
        try:
            buf = bytearray()
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(30.0)
                s.connect(SOCKET_PATH)
                send_recv(s, buf, {"reset": True})
                for i in range(cmds_per):
                    send_recv(
                        s,
                        buf,
                        {
                            "keyCode": 0,
                            "chars": chr(ord("a") + (wid + i) % 26),
                            "base": chr(ord("a") + (wid + i) % 26),
                            "mods": 0,
                        },
                    )
                send_recv(s, buf, {"state": True})
        except Exception as e:
            with lock:
                errors.append(f"worker{wid}: {e!r}")

    threads = [threading.Thread(target=worker, args=(w,)) for w in range(num_clients)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        print(f"  [parallel x{num_clients}*{cmds_per}] FAIL {errors}")
    else:
        print(f"  [parallel x{num_clients}*{cmds_per}] ok")


def stress_connect_disconnect_storm(n: int) -> None:
    for i in range(n):
        buf = bytearray()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(5.0)
            s.connect(SOCKET_PATH)
            send_recv(s, buf, {"reset": True})
        if i % 50 == 0 and keynaco_pid() is None:
            print(f"  [connect storm] keynaco died at i={i}")
            return
    print(f"  [connect storm x{n}] ok")


def stress_half_line_then_full() -> None:
    """行区切りなしで送ってから改行 — サーバのバッファ処理を乱す。"""
    buf = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(10.0)
        s.connect(SOCKET_PATH)
        s.sendall(b'{"keyCode": 0, "chars": "a", "base": "a", "mods": 0')
        time.sleep(0.05)
        s.sendall(b'}\n')
        while b"\n" not in buf:
            buf += s.recv(4096)
        line, buf = buf.split(b"\n", 1)
        json.loads(bytes(line))
        send_recv(s, buf, {"state": True})
    print("  [split json line] ok")


def stress_missing_keycode() -> None:
    buf = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(5.0)
        s.connect(SOCKET_PATH)
        r = send_recv(s, buf, {"oops": True})
        assert "error" in r or r == {}
    print(f"  [bad cmd] response keys={list(r.keys())}")


def stress_large_unicode() -> None:
    buf = bytearray()
    big = "あ" * 500
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(30.0)
        s.connect(SOCKET_PATH)
        for ch in big[:50]:
            send_recv(s, buf, {"keyCode": 0, "chars": ch, "base": ch, "mods": 0})
        send_recv(s, buf, {"state": True})
    print("  [unicode burst 50] ok")


def main() -> None:
    pid_before = keynaco_pid()
    if pid_before is None:
        print("ERROR: keynaco not running. Start Debug build first.")
        sys.exit(1)
    print(f"TMPDIR={os.environ.get('TMPDIR')}")
    print(f"SOCKET_PATH={SOCKET_PATH}")
    print(f"keynaco pid before={pid_before}")

    tests = [
        ("scenario A reset+kanzi+space", [{"reset": True}] + [{"keyCode": 0, "chars": c, "base": c, "mods": 0} for c in "kanzi"] + [{"keyCode": 49, "chars": " ", "base": " ", "mods": 0}]),
        ("scenario B successor", [{"reset": True}] + [{"keyCode": 0, "chars": c, "base": c, "mods": 0} for c in "kyou"] + [{"keyCode": 36, "chars": "\r", "base": "\r", "mods": 0}]),
    ]

    print("\n-- single-connection scenarios --")
    for label, ops in tests:
        one_session(ops, label)

    print("\n-- stress --")
    # B 確定後に On-device LLM（Successor / 候補スコアラー）のコールバックが遅延で走る。
    # 数百 ms 以内に別クライアントから reset すると競合して keynaco が落ちることがある（EOF）。
    # 長すぎる待機（~1s 以上）は B 後のアイドルで別経路のクラッシュも見えた。テストは運が悪いと落ちる前提。
    time.sleep(0.2)
    stress_connect_disconnect_storm(200)
    stress_sequential_roundtrips(800)
    stress_parallel_clients(8, 40)
    stress_half_line_then_full()
    stress_missing_keycode()
    stress_large_unicode()

    pid_after = keynaco_pid()
    print(f"\nkeynaco pid after={pid_after}")
    if pid_after != pid_before:
        print("WARNING: keynaco pid changed (restart/crash?)")
    buf = bytearray()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(5.0)
            s.connect(SOCKET_PATH)
            r = send_recv(s, buf, {"state": True})
            print(f"post-check state ok: composed={r.get('composedHiragana')!r}")
    except OSError as e:
        print(f"post-check connect FAILED: {e!r}")

    print("\ndone.")


if __name__ == "__main__":
    main()
