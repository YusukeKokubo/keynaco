#!/usr/bin/env python3
"""A → B → 新規接続で reset 1 回。AB 直後のクラッシュ再現用。"""
import json
import os
import socket
import sys

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")


def send_recv(s: socket.socket, buf: bytearray, cmd: dict) -> dict:
    s.sendall((json.dumps(cmd, ensure_ascii=False) + "\n").encode())
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            raise ConnectionError("EOF")
        buf += chunk
    line, rest = buf.split(b"\n", 1)
    buf[:] = rest
    return json.loads(bytes(line))


def one_session(ops: list[dict]) -> None:
    buf = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(30.0)
        s.connect(SOCKET_PATH)
        for cmd in ops:
            send_recv(s, buf, cmd)


def main(probe: bool = False) -> None:
    if probe:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5.0)
        s.connect(SOCKET_PATH)
        s.close()
    a_ops = [{"reset": True}] + [
        {"keyCode": 0, "chars": c, "base": c, "mods": 0} for c in "kanzi"
    ] + [{"keyCode": 49, "chars": " ", "base": " ", "mods": 0}]
    b_ops = [{"reset": True}] + [
        {"keyCode": 0, "chars": c, "base": c, "mods": 0} for c in "kyou"
    ] + [{"keyCode": 36, "chars": "\r", "base": "\r", "mods": 0}]
    one_session(a_ops)
    one_session(b_ops)
    buf = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(10.0)
        s.connect(SOCKET_PATH)
        send_recv(s, buf, {"reset": True})
    print("ok")


if __name__ == "__main__":
    probe = "--probe" in sys.argv
    try:
        main(probe=probe)
    except OSError as e:
        print(f"os_error {e!r}", file=sys.stderr)
        sys.exit(1)
    except ConnectionError as e:
        print(f"conn_error {e!r}", file=sys.stderr)
        sys.exit(1)
