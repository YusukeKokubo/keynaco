#!/usr/bin/env python3
from __future__ import annotations

"""keynaco IME デバッグソケットクライアント。

使い方:
    python3 scripts/debug_ime.py              # 対話モード
    python3 scripts/debug_ime.py kanzi        # 文字列を一括送信

プロトコル:
    - Unix ドメインソケット: $TMPDIR/keynaco-debug.sock
    - コマンド: 改行区切りの JSON
    - レスポンス: 改行区切りの JSON

コマンド形式:
    {"keyCode": 0,  "chars": "k", "base": "k", "mods": 0}   # 通常文字
    {"keyCode": 49, "chars": " ", "base": " ", "mods": 0}   # Space
    {"keyCode": 36, "chars": "\\r","base": "\\r","mods": 0}  # Enter
    {"reset": true}                                           # ハンドラリセット
    {"state": true}                                           # 現在状態を取得

よく使うキーコード (InputHandler.swift より):
    space=49  enter=36  backspace=51  escape=53
    down=125  up=126    left=123      right=124  tab=48
    f6=97     f7=98     f8=100        f9=101     f10=109
"""

import json
import os
import socket
import sys
import readline  # noqa: F401 – enables arrow keys in input()

SOCKET_PATH = os.path.join(os.environ.get("TMPDIR", "/tmp"), "keynaco-debug.sock")

KEY_MAP: dict[str, tuple[int, str]] = {
    "space":     (49,  " "),
    "enter":     (36,  "\r"),
    "backspace": (51,  "\x08"),
    "escape":    (53,  ""),
    "down":      (125, ""),
    "up":        (126, ""),
    "left":      (123, ""),
    "right":     (124, ""),
    "tab":       (48,  "\t"),
    "f6":        (97,  ""),
    "f7":        (98,  ""),
    "f8":        (100, ""),
    "f9":        (101, ""),
    "f10":       (109, ""),
}


class IMEClient:
    def __init__(self, path: str = SOCKET_PATH) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self._buf = b""

    # ---------- 低レベル送受信 ----------

    def _send_recv(self, cmd: dict) -> dict:
        msg = (json.dumps(cmd, ensure_ascii=False) + "\n").encode()
        self.sock.sendall(msg)
        while b"\n" not in self._buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("server closed connection")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\n", 1)
        return json.loads(line)

    # ---------- 公開 API ----------

    def char(self, ch: str, mods: int = 0) -> dict:
        """1 文字を送信する（ローマ字入力など）。"""
        return self._send_recv({"keyCode": 0, "chars": ch, "base": ch, "mods": mods})

    def special(self, name: str, mods: int = 0) -> dict:
        """space / enter / backspace / escape / down / up / left / right / tab / f6–f10 を送信する。"""
        kc, chars = KEY_MAP[name]
        return self._send_recv({"keyCode": kc, "chars": chars, "base": chars, "mods": mods})

    def key(self, name: str, mods: int = 0) -> dict:
        """名前付きキーを送信する（{"key": name} ショートハンド）。"""
        return self._send_recv({"key": name, "mods": mods})

    def type(self, text: str) -> list[dict]:
        """文字列を 1 文字ずつ送信する（旧 API）。各ステップの状態リストを返す。"""
        return [self.char(c) for c in text]

    def type_string(
        self,
        text: str,
        then: str | None = None,
        return_steps: bool = False,
        describe: str | None = None,
        assert_fields: dict | None = None,
        assert_contains: dict | None = None,
        assert_not: dict | None = None,
    ) -> dict:
        """文字列を一括送信してサーバー側でまとめて処理する。最終状態を返す。
        then: 末尾に続けて送る名前付きキー（"space" / "enter" 等）。
        return_steps: True なら result["steps"] に各ステップの状態リストも付加する。
        """
        cmd: dict = {"type_string": text}
        if then:
            cmd["then"] = then
        if return_steps:
            cmd["return_steps"] = True
        if describe:
            cmd["describe"] = describe
        if assert_fields:
            cmd["assert"] = assert_fields
        if assert_contains:
            cmd["assert_contains"] = assert_contains
        if assert_not:
            cmd["assert_not"] = assert_not
        return self._send_recv(cmd)

    def sequence(
        self,
        *cmds: dict,
        fields: list[str] | None = None,
        describe: str | None = None,
        assert_fields: dict | None = None,
        assert_contains: dict | None = None,
        assert_not: dict | None = None,
        vars: dict | None = None,
    ) -> dict:
        """複数コマンドを1往復で一括送信する。result["steps"] に各状態、result["last"] に最終状態。"""
        cmd: dict = {"sequence": list(cmds)}
        if fields:
            cmd["fields"] = fields
        if describe:
            cmd["describe"] = describe
        if assert_fields:
            cmd["assert"] = assert_fields
        if assert_contains:
            cmd["assert_contains"] = assert_contains
        if assert_not:
            cmd["assert_not"] = assert_not
        if vars:
            cmd["vars"] = vars
        return self._send_recv(cmd)

    def test_suite(
        self,
        *scenarios: dict,
        use_real_db: bool = False,
        describe: str | None = None,
        before_each: list[dict] | None = None,
        after_each: list[dict] | None = None,
        fail_fast: bool = False,
        vars: dict | None = None,
    ) -> dict:
        """複数シナリオを自動 reset 付きで一括実行する。"""
        cmd: dict = {"test_suite": list(scenarios)}
        if use_real_db:
            cmd["useRealDB"] = True
        if describe:
            cmd["describe"] = describe
        if before_each:
            cmd["before_each"] = before_each
        if after_each:
            cmd["after_each"] = after_each
        if fail_fast:
            cmd["fail_fast"] = True
        if vars:
            cmd["vars"] = vars
        return self._send_recv(cmd)

    def wait_until(
        self,
        field: str,
        *,
        equals=None,
        contains=None,
        min_count: int | None = None,
        timeout_ms: int = 1000,
        interval_ms: int = 50,
        describe: str | None = None,
    ) -> dict:
        """条件を満たすまで state を待機する（LLM 非同期反映の観測向け）。"""
        wait: dict = {"field": field, "timeoutMs": timeout_ms, "intervalMs": interval_ms}
        if equals is not None:
            wait["equals"] = equals
        if contains is not None:
            wait["contains"] = contains
        if min_count is not None:
            wait["minCount"] = min_count
        cmd: dict = {"wait_until": wait}
        if describe:
            cmd["describe"] = describe
        return self._send_recv(cmd)

    def lint_suite(
        self,
        *scenarios: dict,
        before_each: list[dict] | None = None,
        after_each: list[dict] | None = None,
        describe: str | None = None,
    ) -> dict:
        """test_suite の静的チェックを行う（実行はしない）。"""
        cmd: dict = {"lint_suite": list(scenarios)}
        if before_each:
            cmd["before_each"] = before_each
        if after_each:
            cmd["after_each"] = after_each
        if describe:
            cmd["describe"] = describe
        return self._send_recv(cmd)

    def seed_bigram(self, prev: str, input: str, output: str, count: int = 1) -> dict:
        """bi-gram をテスト用に DB へ直接挿入する。"""
        return self._send_recv({"seed_bigram": {"prev": prev, "input": input, "output": output, "count": count}})

    def seed_history(self, input: str, output: str, times: int = 1) -> dict:
        """変換履歴をテスト用に DB へ直接挿入する。"""
        return self._send_recv({"seed_history": {"input": input, "output": output, "times": times}})

    def reset(self) -> dict:
        """InputHandler の状態をリセットする（in-memory DB も再生成）。"""
        return self._send_recv({"reset": True})

    def state(self) -> dict:
        """現在の状態を取得する（キー入力なし）。"""
        return self._send_recv({"state": True})

    def close(self) -> None:
        self.sock.close()

    # ---------- 表示ユーティリティ ----------

    @staticmethod
    def pretty(r: dict) -> str:
        lines: list[str] = []
        if r.get("inserted"):
            lines.append(f"  ✅ inserted       : {r['inserted']}")
        lines.append(f"  composedHiragana : {r.get('composedHiragana', '')!r}")
        lines.append(f"  pendingRomaji    : {r.get('pendingRomaji', '')!r}")
        lines.append(f"  markedText       : {r.get('markedText', '')!r}")
        modes = [k for k in ("isAsciiMode", "isSuccessorMode", "isSegmentMode", "isBracketMode") if r.get(k)]
        if modes:
            lines.append(f"  modes            : {', '.join(modes)}")
        if r.get("candidateVisible"):
            sel = r.get("selectedRow", 0)
            lines.append(f"  candidates (sel={sel}, histEnd={r.get('historyEnd',0)}, fixEnd={r.get('fixedEnd',0)}):")
            for i, c in enumerate(r.get("candidates", [])):
                mark = " ★" if i == sel else ""
                lines.append(f"    [{i}] {c}{mark}")
        if r.get("committedHistory"):
            lines.append(f"  committedHistory : {r['committedHistory']}")
        if r.get("isSegmentMode") and r.get("segmentTexts"):
            segs = r["segmentTexts"]
            fi = r.get("focusedSegmentIndex", 0)
            parts = [f"[{s}]" if i == fi else s for i, s in enumerate(segs)]
            lines.append(f"  segments         : {' | '.join(parts)}")
        return "\n".join(lines)


# ---------- CLI エントリポイント ----------

def interactive_mode(client: IMEClient) -> None:
    print("keynaco デバッグシェル  (exit / quit で終了)")
    print("  <文字列>           : 文字を1文字ずつ入力（type_string として一括送信）")
    print("  .<name>            : 特殊キー (space/enter/backspace/escape/down/up/...)")
    print("  .reset             : ハンドラリセット")
    print("  .state             : 現在状態を表示")
    print()

    while True:
        try:
            line = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break

        if not line:
            continue
        if line in ("exit", "quit"):
            break

        try:
            if line == ".reset":
                r = client.reset()
                print("  reset:", r)
            elif line == ".state":
                r = client.state()
                print(client.pretty(r))
            elif line.startswith("."):
                name = line[1:]
                if name not in KEY_MAP:
                    print(f"  unknown special key: {name!r}  (known: {', '.join(KEY_MAP)})")
                    continue
                r = client.special(name)
                print(client.pretty(r))
            else:
                r = client.type_string(line, return_steps=True)
                for i, step in enumerate(r.get("steps", [r])):
                    print(f"  '{line[i] if i < len(line) else '?'}':")
                    print(client.pretty(step))
        except Exception as exc:
            print(f"  error: {exc}")


def batch_mode(client: IMEClient, text: str) -> None:
    r = client.type_string(text, return_steps=True)
    for i, step in enumerate(r.get("steps", [r])):
        ch = text[i] if i < len(text) else "?"
        print(f"key={ch!r}:")
        print(client.pretty(step))
        print()


if __name__ == "__main__":
    try:
        c = IMEClient()
    except FileNotFoundError:
        print(f"ERROR: ソケットが見つかりません: {SOCKET_PATH}")
        print("keynaco (Debug ビルド) を起動してください。")
        sys.exit(1)
    except ConnectionRefusedError:
        print(f"ERROR: 接続拒否: {SOCKET_PATH}")
        print("keynaco (Debug ビルド) が起動しているか確認してください。")
        sys.exit(1)

    try:
        if len(sys.argv) > 1:
            batch_mode(c, " ".join(sys.argv[1:]))
        else:
            interactive_mode(c)
    finally:
        c.close()
