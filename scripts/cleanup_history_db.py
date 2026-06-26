#!/usr/bin/env python3
"""keynaco history.db のワンショット整理。

カテゴリは 3 つ。各カテゴリは個別フラグで apply する。`--apply` 単体ではエラー。

  --prefix       同一 output で短い読みが長い読みの前方一致になっている行を削除
                 （count / used_at は最長読みへ合算）
  --particles    input==output の助詞・機能語（HiraganaPreferredBuiltins 相当）を削除
  --truncations  output が input の真の prefix（途中確定の疑い）な行を削除
                 例: (input="ないので", output="ない") — reading の最後まで打たずに途中確定

使い方:
  python3 scripts/cleanup_history_db.py                                 # ドライラン（全カテゴリ検出）
  python3 scripts/cleanup_history_db.py --apply --truncations           # truncation だけ実行
  python3 scripts/cleanup_history_db.py --apply --prefix --truncations  # 複数同時
  python3 scripts/cleanup_history_db.py --db /path/to/history.db --apply --prefix
"""

from __future__ import annotations

import argparse
import shutil
import sqlite3
import sys
import time
from collections import defaultdict
from pathlib import Path

DEFAULT_DB = Path.home() / "Library/Application Support/keynaco/history.db"

# HiraganaPreferredBuiltins.words のキー（isHiraganaPassthrough で記録スキップ対象）
PARTICLE_WORDS = frozenset({
    "の", "を", "が", "は", "に", "で", "と", "も", "へ", "より",
    "から", "まで", "にて", "にも", "には", "では", "とは", "でも",
    "など", "だけ", "とか", "なんか",
    "か", "ね", "よ", "な", "わ", "ぞ", "ぜ", "さ",
    "て", "ば", "たら", "なら", "けど", "けれど", "し", "ので", "ながら", "ても", "だと",
    "だ", "です", "ます", "ました", "ません", "した", "する",
    "そして", "しかし", "また", "ただ",
    "これ", "それ", "あれ", "ここ", "そこ", "あそこ", "この",
})

CATEGORY_FLAGS = ("prefix", "particles", "truncations")


def is_hiragana(s: str) -> bool:
    return bool(s) and all("぀" <= c <= "ゟ" for c in s)


def is_redundant_prefix(short: str, long: str) -> bool:
    """short が long の厳密な前方一致か（ラテン文字を含む場合は casefold）。"""
    if short == long or len(short) >= len(long):
        return False
    if any(c.isascii() and c.isalpha() for c in short + long):
        return long.casefold().startswith(short.casefold())
    return long.startswith(short)


def find_maximal_inputs(inputs: list[str]) -> set[str]:
    """他の読みの厳密前方一致にならない読みだけ残す。"""
    maximal: set[str] = set()
    for a in inputs:
        if not any(is_redundant_prefix(a, b) for b in inputs if b != a):
            maximal.add(a)
    return maximal


def plan_prefix_cleanup(rows: list[tuple[str, str, int, int]]) -> tuple[list[tuple[str, str]], dict[tuple[str, str], tuple[int, int]]]:
    """(input, output, count, used_at) の一覧から削除対象と合算先更新を返す。"""
    by_output: dict[str, list[tuple[str, int, int]]] = defaultdict(list)
    for inp, out, cnt, used_at in rows:
        by_output[out].append((inp, cnt, used_at))

    to_delete: list[tuple[str, str]] = []
    to_update: dict[tuple[str, str], tuple[int, int]] = {}

    for output, entries in by_output.items():
        inputs = [e[0] for e in entries]
        maximal = find_maximal_inputs(inputs)
        entry_map = {inp: (cnt, used_at) for inp, cnt, used_at in entries}

        for inp in inputs:
            if inp in maximal:
                continue
            # この短い読みを包含する最長読みへ count を合算
            candidates = [m for m in maximal if is_redundant_prefix(inp, m)]
            if not candidates:
                continue
            keeper = max(candidates, key=len)
            k_cnt, k_used = entry_map[keeper]
            i_cnt, i_used = entry_map[inp]
            merged = (k_cnt + i_cnt, max(k_used, i_used))
            to_update[(keeper, output)] = merged
            entry_map[keeper] = merged
            to_delete.append((inp, output))

    return to_delete, to_update


def plan_particle_cleanup(rows: list[tuple[str, str, int, int]]) -> list[tuple[str, str]]:
    return [
        (inp, out)
        for inp, out, _, _ in rows
        if inp == out and is_hiragana(inp) and inp in PARTICLE_WORDS
    ]


def plan_truncation_cleanup(rows: list[tuple[str, str, int, int]]) -> list[tuple[str, str, int]]:
    """output が input の真の prefix な行を返す（input != output, input が output で始まる）。

    `recordPrefixesOnQueue` の (A) longer 統合ルールに巻き取られて成長する「途中確定行」。
    reading="ないので" で output="ない" を確定 → (input="ないので", output="ない") が
    作られ、以後の reading="ない" の確定までこの行に吸収されてスコアが青天井に育つ。
    """
    return [
        (inp, out, cnt)
        for inp, out, cnt, _ in rows
        if inp != out
        and len(inp) > len(out)
        and inp.startswith(out)
    ]


def load_rows(conn: sqlite3.Connection) -> list[tuple[str, str, int, int]]:
    cur = conn.execute("SELECT input, output, count, used_at FROM history")
    return [(r[0], r[1], r[2], r[3]) for r in cur.fetchall()]


def main() -> int:
    parser = argparse.ArgumentParser(description="keynaco history.db クリーンアップ")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB, help="history.db のパス")
    parser.add_argument("--apply", action="store_true", help="実際に変更する（省略時はドライラン）")
    parser.add_argument("--prefix", action="store_true", help="冗長プレフィックス（同一 output で前方一致な行を最長読みへ統合）を削除")
    parser.add_argument("--particles", action="store_true", help="助詞・機能語の input==output を削除")
    parser.add_argument("--truncations", action="store_true", help="途中確定行（output が input の真の prefix）を削除")
    parser.add_argument("--no-backup", action="store_true", help="--apply 時にバックアップを作らない")
    args = parser.parse_args()

    db_path: Path = args.db.expanduser()
    if not db_path.is_file():
        print(f"error: DB が見つかりません: {db_path}", file=sys.stderr)
        return 1

    # --apply を付けたなら最低 1 カテゴリは必須。事故防止（過去の混在 cleanup でこける）。
    if args.apply and not any(getattr(args, c) for c in CATEGORY_FLAGS):
        flags = " / ".join(f"--{c}" for c in CATEGORY_FLAGS)
        print(f"error: --apply にはカテゴリフラグが最低 1 つ必要です: {flags}", file=sys.stderr)
        return 2

    conn = sqlite3.connect(db_path)
    rows = load_rows(conn)
    total = len(rows)

    # 全カテゴリは常に検出だけ走らせる（dry-run で見える）。apply 対象はフラグで絞る。
    to_delete, to_update = plan_prefix_cleanup(rows)
    particle_deletes = plan_particle_cleanup(rows)
    truncation_rows = plan_truncation_cleanup(rows)

    delete_set: set[tuple[str, str]] = set()
    if args.prefix:
        delete_set.update(to_delete)
    if args.particles:
        for pair in particle_deletes:
            delete_set.add(pair)
    if args.truncations:
        for inp, out, _ in truncation_rows:
            delete_set.add((inp, out))

    # prefix 合算で keeper が削除対象に入らないよう調整（prefix を apply しない場合は to_update も実行しない）
    update_targets: dict[tuple[str, str], tuple[int, int]] = to_update if args.prefix else {}
    delete_set -= set(update_targets)

    print(f"DB: {db_path}")
    print(f"総行数: {total}")

    def line(label: str, count: int, applied: bool, extra: str = "") -> None:
        mark = "→ apply" if applied else "→ 検出のみ"
        print(f"{label}: {count} 行{extra}  {mark}")

    line("冗長プレフィックス", len(to_delete), args.prefix, f"（count 合算先: {len(to_update)} 行）")
    line("助詞パススルー", len(particle_deletes), args.particles)
    truncation_total_count = sum(c for _, _, c in truncation_rows)
    line("途中確定行", len(truncation_rows), args.truncations, f" / count 合計 {truncation_total_count}")
    print(f"削除合計: {len(delete_set)} 行 → 残り約 {total - len(delete_set)} 行")

    if truncation_rows:
        print("\n途中確定行（count 降順）:")
        for inp, out, cnt in sorted(truncation_rows, key=lambda r: -r[2]):
            mark = "→削除" if args.truncations else "→保持"
            print(f"  ({inp!r}, {out!r}) count={cnt} {mark}")

    if not args.apply:
        print("\nドライランです。実行するには --apply とカテゴリフラグを付けてください。")
        if to_delete[:5]:
            print("\n冗長プレフィックス削除例（先頭5件）:")
            for inp, out in to_delete[:5]:
                print(f"  ({inp}, {out})")
        conn.close()
        return 0

    if not args.no_backup:
        backup = db_path.with_suffix(f".db.bak.{int(time.time())}")
        shutil.copy2(db_path, backup)
        print(f"\nバックアップ: {backup}")

    conn.execute("BEGIN")
    try:
        for (keeper, output), (cnt, used_at) in update_targets.items():
            conn.execute(
                "UPDATE history SET count = ?, used_at = ? WHERE input = ? AND output = ?",
                (cnt, used_at, keeper, output),
            )
        for inp, out in delete_set:
            conn.execute("DELETE FROM history WHERE input = ? AND output = ?", (inp, out))
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()

    remaining = total - len(delete_set)
    print(f"\n完了: {len(delete_set)} 行削除、{len(update_targets)} 行を count 合算更新")
    print(f"残り行数（概算）: {remaining}")
    print("keynaco を再起動すると設定画面の表示も更新されます。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
