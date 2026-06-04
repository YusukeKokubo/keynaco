#!/usr/bin/env python3
"""文節境界が履歴 seed で上書きされないことをデバッグソケットで確認する。"""
import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")


def send(sock, buf, cmd):
    sock.sendall((json.dumps(cmd, ensure_ascii=False) + "\n").encode())
    while b"\n" not in buf[0]:
        buf[0] += sock.recv(4096)
    line, buf[0] = buf[0].split(b"\n", 1)
    return json.loads(line)


def main():
    if subprocess.run(["pgrep", "-x", "keynaco"], capture_output=True).returncode != 0:
        print("ERROR: keynaco not running — Debug ビルドを起動してください")
        sys.exit(1)

    head = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=os.path.dirname(__file__) + "/..").decode().strip()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET_PATH)
    buf = [b""]

    r = send(sock, buf, {"state": True})
    running = r.get("buildInfo", {}).get("commit", "unknown")
    if running != head:
        print(f"ERROR: stale binary running={running} HEAD={head}")
        sys.exit(1)

    suite = {
        "fail_fast": True,
        "test_suite": [
            {
                "name": "baseline_anataha",
                "cmds": [
                    {"reset": True},
                    {"type_string": "anataha", "then": "space"},
                ],
                "assert": {"isSegmentMode": True},
                "assert_contains": {"segmentTexts": "は"},
            },
            {
                "name": "seed_full_phrase_still_splits",
                "cmds": [
                    {"reset": True},
                    {"seed_history": {"input": "あなたは", "output": "貴方は", "times": 10}},
                    {"type_string": "anataha", "then": "space", "fields": ["segmentTexts", "candidates", "selectedText"]},
                ],
                "assert": {"isSegmentMode": True},
                "assert_contains": {"segmentTexts": "は"},
            },
        ],
    }
    out = send(sock, buf, suite)
    sock.close()

    for t in out.get("test_suite", []):
        status = "PASS" if t.get("passed") else "FAIL"
        print(f"{status}: {t.get('name')}")
        if not t.get("passed"):
            print(json.dumps(t, ensure_ascii=False, indent=2))
            sys.exit(1)
    print("OK: 履歴 seed 後も segmentTexts に残り「は」あり（境界維持の目安）")


if __name__ == "__main__":
    main()
