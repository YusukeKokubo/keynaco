#!/usr/bin/env python3
"""input_log・divergence_log・fetch_log を横断して pain ケースを抽出する補助スクリプト。

`analyze.py` は latency_log 集計に特化しとる。本スクリプトは UX 損失（BS・scroll・迷い時間）と
divergence・fetch_log を join して「直すべき確定」を機械的に並べる。

使い方:
    python3 pain_analysis.py                  # 直近 1 時間
    python3 pain_analysis.py --since 30m      # 直近 30 分
"""

from __future__ import annotations

import json
import os
import re
import sys
import time

BASE = os.path.expanduser("~/Library/Application Support/keynaco")
INPUT_LOG = os.path.join(BASE, "input_log.jsonl")
DIVERGENCE_LOG = os.path.join(BASE, "divergence_log.jsonl")
FETCH_LOG = os.path.join(BASE, "fetch_log.jsonl")


def parse_since(s):
    m = re.fullmatch(r"(\d+)\s*([smhd])", s.strip())
    if not m:
        raise ValueError(f"--since 形式エラー: {s!r}（例: 30m, 2h, 1d）")
    n, unit = int(m.group(1)), m.group(2)
    return int(time.time()) - n * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]


def load_jsonl(path, threshold_ms=None):
    if not os.path.exists(path):
        return []
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if threshold_ms is not None and r.get("ts", 0) < threshold_ms:
                continue
            rows.append(r)
    return rows


KANJI = re.compile(r"[一-鿿々]+")


def kanji_clusters(text):
    """連続漢字を 1 つの cluster として数える。「聞く耳」→ ['聞', '耳'] で 2 cluster。"""
    if not text:
        return []
    return KANJI.findall(text)


def is_compound(committed):
    """漢字 cluster が 2 つ以上あれば複合語と見なす。"""
    return len(kanji_clusters(committed or "")) >= 2


def main():
    args = sys.argv[1:]
    threshold_ms = int((time.time() - 3600) * 1000)
    i = 0
    while i < len(args):
        if args[i] == "--since" and i + 1 < len(args):
            threshold_ms = parse_since(args[i + 1]) * 1000
            i += 2
        else:
            i += 1

    input_rows = load_jsonl(INPUT_LOG, threshold_ms=threshold_ms)
    div_rows = load_jsonl(DIVERGENCE_LOG, threshold_ms=threshold_ms)
    fetch_rows = load_jsonl(FETCH_LOG, threshold_ms=threshold_ms)

    print(f"対象期間: 直近 {(int(time.time()) - threshold_ms // 1000) // 60} 分")
    print(f"input_log: {len(input_rows)} / divergence_log: {len(div_rows)} / fetch_log: {len(fetch_rows)}")
    if not input_rows:
        print("input_log にデータなし")
        return

    print()
    print("=" * 60)
    print("  pain ケース（BS≥2 or scroll>0 or composition_ms>3000）")
    print("=" * 60)
    pain = [r for r in input_rows if
            r.get("bs_count", 0) >= 2 or
            r.get("scroll_count", 0) > 0 or
            r.get("composition_ms", 0) > 3000]
    print(f"件数: {len(pain)} / 全確定 {len(input_rows)} （{len(pain)/len(input_rows)*100:.1f}%）")
    print()
    pain_sorted = sorted(pain, key=lambda r: -r.get("composition_ms", 0))
    for r in pain_sorted[:20]:
        iso = (r.get("ts_iso") or "")[11:19]
        c = r.get("committed") or ""
        comp_mark = "🔗" if is_compound(c) else "  "
        print(f"  [{iso}] {comp_mark} key={r['key_count']:2d} bs={r.get('bs_count',0):2d} "
              f"scroll={r.get('scroll_count',0)} ms={r['composition_ms']:5d}  "
              f"'{r['reading']}' → '{c}'")

    print()
    print("=" * 60)
    print("  複合語 pain（🔗= 漢字 cluster ≥2 = 複合語の苦戦）")
    print("=" * 60)
    compound_pain = [r for r in pain if is_compound(r.get("committed") or "")]
    print(f"件数: {len(compound_pain)} / pain {len(pain)} （{len(compound_pain)/max(len(pain),1)*100:.1f}%）")
    if compound_pain:
        total_ms = sum(r["composition_ms"] for r in compound_pain)
        avg_ms = total_ms / len(compound_pain)
        print(f"平均 composition_ms: {avg_ms:.0f}ms")
        # 複合語の clusters
        cluster_sizes = [len(kanji_clusters(r["committed"])) for r in compound_pain]
        if cluster_sizes:
            print(f"漢字 cluster 数の分布: min={min(cluster_sizes)} max={max(cluster_sizes)} "
                  f"avg={sum(cluster_sizes)/len(cluster_sizes):.1f}")

    print()
    print("=" * 60)
    print("  divergence と input_log の対応（同読みで join）")
    print("=" * 60)
    div_by_reading = {}
    for d in div_rows:
        div_by_reading.setdefault(d.get("reading", ""), []).append(d)
    matched = 0
    for r in pain[:15]:
        ds = div_by_reading.get(r.get("reading", ""), [])
        if not ds:
            continue
        matched += 1
        d = ds[0]
        rescued = d.get("rescued_by")
        mark = f"[救:{rescued}]" if rescued else "[UX損失]"
        print(f"  '{r['reading']}' pain={r['composition_ms']}ms / divergence Z1={d.get('z1')} → {d['confirmed']} {mark}")
    if matched == 0:
        print("  pain と divergence の reading で一致なし")

    print()
    print("=" * 60)
    print("  fetch_log から lock_wait 上位（reading 単位の queue 詰まり）")
    print("=" * 60)
    if not fetch_rows:
        print("  fetch_log 未生成 or データなし")
    else:
        sorted_fetch = sorted(fetch_rows, key=lambda r: -r.get("lock_wait_ms", 0))[:15]
        for f in sorted_fetch:
            iso = (f.get("ts_iso") or "")[11:19]
            print(f"  [{iso}] lock_wait={f['lock_wait_ms']:4d}ms  fetch={f['fetch_ms']:4d}ms  "
                  f"reading_len={f['reading_len']}  rich={f.get('rich')}  zenzai={f.get('zenzai')}  "
                  f"'{f['reading']}'")
        # 統計
        lock_waits = [f.get("lock_wait_ms", 0) for f in fetch_rows]
        if lock_waits:
            srt = sorted(lock_waits)
            p50 = srt[len(srt)//2]
            p95 = srt[len(srt)*95//100]
            print(f"\n  fetch 全体 lock_wait: median={p50}ms p95={p95}ms max={max(lock_waits)}ms (n={len(lock_waits)})")
        # rich vs non-rich
        rich = [f for f in fetch_rows if f.get("rich")]
        nonrich = [f for f in fetch_rows if not f.get("rich")]
        print(f"  rich fetch: {len(rich)} / non-rich: {len(nonrich)}")


if __name__ == "__main__":
    main()
