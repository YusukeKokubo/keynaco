#!/usr/bin/env python3
"""keynaco デバッグソケットで文節境界チェックリスト 7 項目を一括取得。"""
import json
import os
import subprocess
import sys

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main() -> int:
    if subprocess.run(["pgrep", "-x", "keynaco"], capture_output=True).returncode != 0:
        print("ERROR: keynaco not running — build & activate IME first", file=sys.stderr)
        return 1

    import socket

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(SOCKET_PATH)
    except ConnectionRefusedError:
        print("ERROR: debug socket refused", file=sys.stderr)
        return 1

    buf = b""

    def send(cmd):
        nonlocal buf
        sock.sendall((json.dumps(cmd, ensure_ascii=False) + "\n").encode())
        while b"\n" not in buf:
            buf += sock.recv(4096)
        line, buf = buf.split(b"\n", 1)
        return json.loads(line)

    head = subprocess.check_output(
        ["git", "rev-parse", "--short", "HEAD"], cwd=REPO
    ).decode().strip()
    r0 = send({"state": True})
    running = r0.get("buildInfo", {}).get("commit", "unknown")
    print(f"KEYNACO|commit|HEAD={head}|running={running}")

    scenarios = [
        ("1_anataha", "anataha", None),
        ("2_gakuseidesu", "gakuseidesu", None),
        ("3_watashihagakusei", "watashihagakusei", None),
        ("4_konnitiha", "konnitiha", None),
        ("5_gakusei_single", "gakusei", None),
        ("6_history", "gakuseidesu", {"seed_history": {"input": "がくせい", "output": "学部生", "times": 3}}),
        ("7_shift_expand", "gakuseidesu", "shift_expand"),
    ]

    for name, romaji, extra in scenarios:
        send({"reset": True})
        if isinstance(extra, dict):
            send(extra)
        if extra == "shift_expand":
            send({"type_string": romaji, "then": "space"})
            send({"key": "right", "mods": 131072})
            r = send({
                "state": True,
                "fields": [
                    "isSegmentMode", "composedHiragana", "candidates", "selectedText",
                    "segmentTexts", "markedText", "candidateVisible",
                ],
            })
        else:
            r = send({
                "type_string": romaji,
                "then": "space",
                "fields": [
                    "isSegmentMode", "composedHiragana", "candidates", "selectedText",
                    "segmentTexts", "markedText", "candidateVisible", "historyEnd", "fixedEnd",
                ],
            })
            if name == "1_anataha":
                r2 = send({
                    "sequence": [
                        {"type_string": romaji, "then": "space"},
                        {"key": "enter", "fields": ["composedHiragana", "inserted", "isSegmentMode"]},
                    ],
                })
                last = r2.get("last") or {}
                print(
                    f"KEYNACO|{name}_enter1|inserted={last.get('inserted')}|composed={last.get('composedHiragana')!r}|seg={last.get('isSegmentMode')}"
                )

        cands = (r.get("candidates") or [])[:8]
        print(
            f"KEYNACO|{name}|segMode={r.get('isSegmentMode')}|visible={r.get('candidateVisible')}|"
            f"selected={r.get('selectedText')!r}|segments={r.get('segmentTexts')}|"
            f"marked={r.get('markedText')!r}|cands={cands}|histEnd={r.get('historyEnd')}|fixedEnd={r.get('fixedEnd')}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
