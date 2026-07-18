#!/usr/bin/env python3
"""Marked text / 候補 UI のデバッグソケット回帰テスト。

前提: Debug ビルドの keynaco が起動し、$TMPDIR/keynaco-debug.sock で待ち受けていること。

  ./scripts/test_marked_text_sandbox.sh
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHIFT = 131072

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
        # 以下 3 本は row 0 のテキストをハードコードしない（実 DB + AzooKey エンジン学習で
        # 並びが正当に変わるため）。意図は「marked が選択行に追従する」等の不変条件で固定する。
        {
            "name": "space-marked-follows-selection",
            "cmds": [
                {"type_string": "kanzi"},
                {"wait_azoo_key": True},
                {"key": "space", "capture": {"picked": "selectedText"}},
                {
                    "state": True,
                    "assert": {
                        "candidateVisible": True,
                        "selectedRow": 0,
                        "markedText": "{{picked}}",
                        "selectedText": "{{picked}}",
                    },
                },
            ],
        },
        {
            "name": "down-syncs-selected-while-composing",
            "cmds": [
                {"type_string": "kanzi"},
                {"wait_azoo_key": True},
                {"key": "space"},
                {"key": "down", "capture": {"row1": "selectedText"}},
                {
                    "state": True,
                    "assert": {
                        "isExplicitlySelected": True,
                        "selectedRow": 1,
                        "markedText": "{{row1}}",
                        "selectedText": "{{row1}}",
                    },
                },
            ],
        },
        {
            "name": "space-enter-commits-selected-candidate",
            "cmds": [
                {"type_string": "kanzi"},
                {"wait_azoo_key": True},
                {"key": "space", "capture": {"picked": "selectedText"}},
                {"key": "enter", "assert_contains": {"inserted": "{{picked}}"}},
            ],
            "assert": {"candidateVisible": False},
        },
        {
            "name": "shift-delete-removes-history-candidate",
            "cmds": [
                {"seed_history": {"input": "じっそう", "output": "実装", "times": 5}},
                {"type_string": "jissou", "then": "space", "assert_contains": {"candidates": "実装"}},
                {"key": "backspace", "mods": SHIFT},
            ],
            "assert_not": {"assert_contains": {"candidates": "実装"}},
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


def assert_marked_equals_selected(state: dict, label: str) -> str | None:
    marked = state.get("markedText")
    selected = state.get("selectedText")
    if marked != selected:
        return f"{label}: markedText={marked!r} selectedText={selected!r}"
    return None


def run_integrity_checks(sock: socket.socket, buf: bytearray) -> int:
    """test_suite で表現しにくい cross-field / リスト不変チェック。"""
    failures: list[str] = []
    send(sock, buf, {"reset": True})

    send(sock, buf, {"type_string": "kanzi"})
    send(sock, buf, {"wait_azoo_key": True})
    r_passive = send(sock, buf, {"state": True})
    r_space = send(sock, buf, {"key": "space"})
    cands_before = list(r_passive.get("candidates", []))
    cands_after = list(r_space.get("candidates", []))
    if cands_before != cands_after:
        failures.append(
            f"passive-to-explicit-space: candidates changed\n  before={cands_before[:5]}\n  after={cands_after[:5]}"
        )
    if not r_space.get("isExplicitlySelected"):
        failures.append("passive-to-explicit-space: expected isExplicitlySelected=true after Space")
    if r_space.get("selectedRow", 0) != 0:
        failures.append(
            f"passive-to-explicit-space: expected explicit rebuild at row 0, got row {r_space.get('selectedRow')}"
        )
    if err := assert_marked_equals_selected(r_space, "after-passive-space"):
        failures.append(err)

    send(sock, buf, {"reset": True})
    send(sock, buf, {"seed_history": {"input": "じっそう", "output": "実装", "times": 5}})
    r_j = send(sock, buf, {"type_string": "jissou", "then": "space"})
    cands = r_j.get("candidates", [])
    if "実装" not in cands:
        failures.append(f"shift-delete-setup: 実装 not in candidates: {cands[:6]}")
    else:
        target = cands.index("実装")
        state = r_j
        for _ in range(len(cands) * 2):
            if state.get("selectedRow") == target:
                break
            state = send(sock, buf, {"key": "down"})
        else:
            failures.append("shift-delete-setup: could not select 実装 row")
            state = r_j
        if state.get("selectedText") == "実装":
            r_del = send(sock, buf, {"key": "backspace", "mods": SHIFT})
            if "実装" in r_del.get("candidates", []):
                failures.append("shift-delete: 実装 still in candidates after Shift+Backspace")
            if err := assert_marked_equals_selected(r_del, "after-shift-delete"):
                failures.append(err)

    for msg in failures:
        print(f"  FAIL  {msg}")
    if not failures:
        print("  PASS  integrity checks (passive→explicit Space + shift-delete marked)")
    return len(failures)


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
            state = scenario.get("lastState") or scenario.get("last") or {}
            print(
                f"       markedText={state.get('markedText')!r} "
                f"selectedText={state.get('selectedText')!r}"
            )
    total = summary.get("total", 0)
    passed = summary.get("passed", 0)
    print(f"\nMarked text sandbox suite: {passed}/{total} passed")
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
    suite_failed = print_results(send(sock, buf, MARKED_TEXT_SUITE))
    print()
    print("Integrity checks:")
    integrity_failed = run_integrity_checks(sock, buf)
    sock.close()

    total_fail = suite_failed + integrity_failed
    if total_fail:
        print(f"\nFAILED: {total_fail} issue(s)")
        raise SystemExit(1)
    print("\nOK: marked text / candidate sandbox regression passed")


if __name__ == "__main__":
    main()
