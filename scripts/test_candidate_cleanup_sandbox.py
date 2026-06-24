#!/usr/bin/env python3
"""候補サジェスト整理後のデバッグソケット回帰（passive/explicit Space・機能語 dismiss）。

前提: Debug ビルドの keynaco が起動し、$TMPDIR/keynaco-debug.sock で待ち受けていること。

  ./scripts/test_candidate_cleanup_sandbox.sh
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CANDIDATE_CLEANUP_SUITE: dict = {
    "before_each": [{"reset": True}],
    "test_suite": [
        {
            "name": "builtin-no-visible-whileTyping",
            "cmds": [{"type_string": "no"}],
            "assert_not": {"candidateVisible": True},
        },
        {
            "name": "builtin-ha-enter-hiragana",
            "cmds": [{"type_string": "ha"}, {"key": "enter"}],
            "assert_contains": {"inserted": "は"},
        },
        {
            "name": "space-from-hidden-starts-explicit",
            "cmds": [{"type_string": "kanzi"}, {"key": "space"}],
            "assert": {"candidateVisible": True, "isExplicitlySelected": True},
        },
        {
            "name": "passive-space-rebuilds-explicit",
            "cmds": [
                {"type_string": "ai"},
                {"wait_azoo_key": True},
                {"key": "space"},
            ],
            "assert": {"isExplicitlySelected": True, "selectedRow": 0},
        },
        {
            "name": "explicit-second-space-advances-row",
            "cmds": [
                {"type_string": "kanzi"},
                {"key": "space"},
                {"key": "space"},
            ],
            "assert": {"selectedRow": 1, "isExplicitlySelected": True},
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
            "  Run: xcodebuild build -scheme keynaco -configuration Debug ..."
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
                f"       candidateVisible={state.get('candidateVisible')!r} "
                f"isExplicitlySelected={state.get('isExplicitlySelected')!r} "
                f"selectedRow={state.get('selectedRow')!r}"
            )
    total = summary.get("total", 0)
    passed = summary.get("passed", 0)
    print(f"\nCandidate cleanup sandbox suite: {passed}/{total} passed")
    return failed


def main() -> None:
    head = preflight()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(SOCKET_PATH)
    except ConnectionRefusedError:
        die("ERROR: connection refused — keynaco debug socket not listening")

    buf = bytearray()
    verify_build(head, send(sock, buf, {"state": True}))
    failed = print_results(send(sock, buf, CANDIDATE_CLEANUP_SUITE))
    sock.close()

    if failed:
        print(f"\nFAILED: {failed} scenario(s)")
        raise SystemExit(1)
    print("\nOK: candidate cleanup sandbox regression passed")


if __name__ == "__main__":
    main()
