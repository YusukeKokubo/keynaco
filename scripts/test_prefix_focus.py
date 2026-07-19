#!/usr/bin/env python3
"""打鍵中の品詞別モーラ閾値 (prefix focus) 回帰テスト。

前提: Debug ビルドの keynaco が起動し、$TMPDIR/keynaco-debug.sock で待ち受けていること。

  python3 scripts/test_prefix_focus.py

閾値（PrefixFocusPolicy）:
  名詞・固有名詞: 2 モーラ以上
  動詞:          3 モーラ以上
  形容詞:        3 モーラ以上
  助詞・助動詞:  対象外（永久にフォーカスしない）
  unknown:       5 モーラ以上
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 小仮名は直前文字と合わせて 1 モーラ扱い（ぁぃぅぇぉゃゅょ など）
SMALL_KANA = frozenset("ぁぃぅぇぉゃゅょゎァィゥェォャュョヮ")


def mora_count(s: str) -> int:
    """ひらがな/カタカナ文字列のモーラ数を返す（拗音・促音・長音を正しく計上）。

    len() ではなくこの関数を使うこと。len("きゅうり") == 4 だが mora_count == 3。
    """
    return sum(1 for c in s if c not in SMALL_KANA)


# モジュールロード時に自己テスト
_MORA_SELFTEST = [
    ("おいし",    3),
    ("おもし",    3),
    ("たべる",    3),
    ("とう",      2),
    ("きゅうり",  3),   # きゅ=1, う=1, り=1
    ("ちゃんと",  3),   # ちゃ=1, ん=1, と=1
    ("とうきょう", 4),  # と=1, う=1, きょ=1, う=1
    ("しゅう",    2),   # しゅ=1, う=1
    ("しゅ",      1),
]
for _s, _expected in _MORA_SELFTEST:
    _got = mora_count(_s)
    assert _got == _expected, f"mora_count({_s!r}): expected {_expected}, got {_got}"


def die(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def send(sock: socket.socket, buf: bytearray, cmd: dict) -> dict:
    sock.sendall((json.dumps(cmd, ensure_ascii=False) + "\n").encode())
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            die("ERROR: debug socket closed unexpectedly")
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
        cwd=REPO_ROOT, text=True,
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
            "  Run /deploy to rebuild."
        )


def run_focus_checks(sock: socket.socket, buf: bytearray) -> int:
    """品詞別モーラ閾値の境界を全パターン検証する。"""

    def probe(output: str, seed_reading: str, romaji: str, times: int = 3) -> dict:
        """history をシードして romaji を打鍵し、AzooKey 完了後の状態を返す。

        seed_history は pos/lcid を書かないため、本番の起動時バックフィル相当の
        pos_backfill を挟んで分類してから打鍵する（A1 以降、打鍵中の同期辞書
        lookup は無いので、分類なしだと品詞ランクが unknown（閾値 5）になる）。
        """
        send(sock, buf, {"reset": True})
        send(sock, buf, {"seed_history": {"input": seed_reading, "output": output, "times": times}})
        send(sock, buf, {"pos_backfill": True})
        send(sock, buf, {"type_string": romaji})
        wait = send(sock, buf, {"wait_azoo_key": {"timeoutMs": 3000}})
        if not wait.get("ok"):
            return {
                "selectedText": None,
                "candidateVisible": False,
                "composedHiragana": None,
                "waitOk": False,
            }
        state = send(sock, buf, {"state": True, "fields": ["selectedText", "candidateVisible", "composedHiragana"]})
        state["waitOk"] = True
        return state

    # (label, output, seed_reading, romaji, expected_composed, expect_focus)
    cases: list[tuple[str, str, str, str, str, bool]] = [
        # ── 形容詞（閾値 3） ────────────────────────────────────
        # おいしい (4m): 2m で弾かれ、3m でフォーカス
        ("adj  おいしい   2m  no-focus", "おいしい", "おいしい", "oi",     "おい",     False),
        ("adj  おいしい   3m  focus",    "おいしい", "おいしい", "oishi",  "おいしい", True),
        # 面白い (5m): 2m で弾かれ、3m でフォーカス
        ("adj  面白い     2m  no-focus", "面白い",   "おもしろい", "omo",    "おも",     False),
        ("adj  面白い     3m  focus",    "面白い",   "おもしろい", "omoshi", "おもし",   True),

        # ── 動詞（閾値 3・回帰） ───────────────────────────────
        # 食べる (3m): 2m で弾かれ、3m でフォーカス
        ("verb 食べる     2m  no-focus", "食べる",   "たべる",   "tabe",   "たべ",     False),
        ("verb 食べる     3m  focus",    "食べる",   "たべる",   "taberu", "たべる",   True),

        # ── 名詞・固有名詞（閾値 2・回帰） ─────────────────────
        # 東京 (4m): 1m で弾かれ、2m でフォーカス
        ("noun 東京       1m  no-focus", "東京",     "とうきょう", "to",    "と",       False),
        ("noun 東京       2m  focus",    "東京",     "とうきょう", "tou",   "とう",     True),

        # ── 拗音含む語で mora_count の境界を確認 ────────────────
        # 習慣 (しゅうかん, 4m: しゅ=1, う=1, か=1, ん=1)
        # shu → しゅ (1m), shuu → しゅう (2m)
        ("noun 習慣(拗音) 1m  no-focus", "習慣",     "しゅうかん", "shu",   "しゅ",     False),
        ("noun 習慣(拗音) 2m  focus",    "習慣",     "しゅうかん", "shuu",  "しゅう",   True),
    ]

    failures: list[str] = []
    for label, output, seed_reading, romaji, expected_composed, expect_focus in cases:
        r = probe(output, seed_reading, romaji)
        sel = r.get("selectedText", "")
        composed = r.get("composedHiragana", "")
        mc = mora_count(composed) if composed else 0

        if not r.get("waitOk", True):
            print(f"[FAIL] {label}: wait_azoo_key timed out")
            failures.append(label)
            continue

        if composed != expected_composed:
            print(
                f"[FAIL] {label}: composed mismatch expected={expected_composed!r} "
                f"actual={composed!r} (wait/prefetch race?)"
            )
            failures.append(label)
            continue

        ok = (sel == output) if expect_focus else (sel != output)
        mark = "PASS" if ok else "FAIL"

        if expect_focus:
            detail = f"selectedText={sel!r}  (composed={composed!r}, {mc}m)"
        else:
            detail = f"selectedText={sel!r}  (expected ≠ {output!r}, composed={composed!r}, {mc}m)"

        print(f"[{mark}] {label}: {detail}")
        if not ok:
            failures.append(label)

    return len(failures)


def main() -> None:
    head = preflight()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(SOCKET_PATH)
    except ConnectionRefusedError:
        die("ERROR: connection refused — keynaco debug socket not listening")

    buf = bytearray()
    verify_build(head, send(sock, buf, {"state": True}))

    print("\n=== prefix focus 品詞別モーラ閾値テスト ===\n")
    failed = run_focus_checks(sock, buf)
    sock.close()

    print()
    total = 10  # cases と合わせて手動管理
    passed = total - failed
    if failed:
        print(f"FAILED: {failed}/{total} case(s)")
        raise SystemExit(1)
    print(f"OK: {passed}/{total} all passed")


if __name__ == "__main__":
    main()
