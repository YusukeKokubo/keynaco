#!/usr/bin/env python3
"""Marked text 同期のデバッグソケット回帰テスト。

前提: Debug ビルドの keynaco が起動し、$TMPDIR/keynaco-debug.sock で待ち受けていること。
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MARKED_TEXT_SUITE: dict = {
    "before_each": [{"reset": True}],
    "test_suite": [
        {
            "name": "bracket-show-marked-nonempty",
            "cmds": [{"type_string": "."}],
            "assert": {"isBracketMode": True, "candidateVisible": True},
            "assert_regex": {"markedText": "."},
        },
        {
            "name": "bracket-down-syncs-marked",
            "cmds": [{"type_string": "."}, {"key": "down"}],
            "assert": {"markedText": "．", "selectedText": "．", "isExplicitlySelected": True},
        },
        {
            "name": "bracket-up-syncs-marked",
            "cmds": [{"type_string": "."}, {"key": "down"}, {"key": "up"}],
            "assert": {"markedText": "。", "selectedText": "。"},
        },
        {
            "name": "compose-marked-stays-hiragana",
            "cmds": [{"type_string": "kanzi"}],
            "assert": {"composedHiragana": "かんじ", "markedText": "かんじ"},
        },
        {
            "name": "space-keeps-hiragana-marked",
            "cmds": [{"type_string": "kanzi", "then": "space"}],
            "assert": {"markedText": "かんじ", "candidateVisible": True},
        },
        {
            "name": "down-syncs-selected-while-composing",
            "cmds": [{"type_string": "kan", "then": "space"}, {"key": "down"}],
            "assert_contains": {"markedText": "感"},
            "assert_not": {"markedText": "かん"},
        },
        {
            "name": "up-syncs-selected-while-composing",
            "cmds": [{"type_string": "kan", "then": "space"}, {"key": "down"}, {"key": "up"}],
            "assert": {"markedText": "管理", "selectedText": "管理"},
        },
        {
            "name": "enter-matches-selected-candidate",
            "cmds": [
                {"type_string": "kanzi", "then": "space", "capture": {"picked": "selectedText"}},
                {"key": "enter", "assert_contains": {"inserted": "{{picked}}"}},
            ],
        },
    ],
}


def die(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def send(sock: socket.socket, buf: bytearray, cmd: dict) -> dict:
    sock.sendall((json.dumps(cmd, ensure_ascii=False) + "\n").encode())
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            die("ERROR: debug socket closed")
        buf += chunk
    line, rest = buf.split(b"\n", 1)
    buf.clear()
    buf.extend(rest)
    return json.loads(line)


def preflight() -> str:
    if subprocess.run(["pgrep", "-x", "keynaco"], capture_output=True).returncode != 0:
        die(
            "ERROR: keynaco is not running.\n"
            "  Build & install Debug build, then switch input source to keynaco."
        )

    dirty = subprocess.check_output(
        ["git", "status", "--porcelain", "Core/Sources", "keynaco/"],
        cwd=REPO_ROOT,
        text=True,
    ).strip()
    if dirty:
        print("WARNING: uncommitted changes in Core/ or keynaco/ — binary may differ from HEAD")

    return subprocess.check_output(
        ["git", "rev-parse", "--short", "HEAD"], cwd=REPO_ROOT, text=True
    ).strip()


def verify_build(head: str, state: dict) -> None:
    commit = state.get("buildInfo", {}).get("commit", "unknown")
    built_at = state.get("buildInfo", {}).get("builtAt", "?")
    print(f"HEAD={head}  running={commit}  builtAt={built_at}")
    if commit in ("unknown", "") or commit != head:
        die(
            f"ERROR: stale keynaco binary (running={commit}, HEAD={head}).\n"
            "  Run /deploy or: xcodebuild build -scheme keynaco -configuration Debug ..."
        )


def print_results(suite: dict) -> int:
    summary = suite.get("summary", {})
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print()
    failed = 0
    for scenario in suite.get("results", []):
        ok = scenario.get("ok", False)
        name = scenario.get("name", "?")
        mark = "PASS" if ok else "FAIL"
        print(f"[{mark}] {name}")
        if not ok:
            failed += 1
            for line in scenario.get("compactFailures", []):
                print(f"       {line}")
            state = scenario.get("lastState") or {}
            print(
                f"       markedText={state.get('markedText')!r} "
                f"selectedText={state.get('selectedText')!r}"
            )
    total = summary.get("total", 0)
    passed = summary.get("passed", 0)
    print(f"\nMarked text sandbox: {passed}/{total} passed")
    return 1 if failed else 0


def main() -> None:
    head = preflight()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(SOCKET_PATH)
    except ConnectionRefusedError:
        die("ERROR: connection refused — keynaco debug socket not listening")

    buf = bytearray()
    verify_build(head, send(sock, buf, {"state": True}))
    suite = send(sock, buf, MARKED_TEXT_SUITE)
    sock.close()
    raise SystemExit(print_results(suite))


if __name__ == "__main__":
    main()
