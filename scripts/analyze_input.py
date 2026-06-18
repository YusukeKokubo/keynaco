#!/usr/bin/env python3
"""入力品質ログ (input_log.jsonl) 分析スクリプト。

使い方:
    python3 scripts/analyze_input.py
    python3 scripts/analyze_input.py --ts-start 2026-06-01
    python3 scripts/analyze_input.py --ts-start 2026-06-01 --ts-end 2026-06-18
    python3 scripts/analyze_input.py --tail 500   # 直近 N セッションのみ
"""

import json
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path


LOG_PATH = Path.home() / "Library/Application Support/keynaco/input_log.jsonl"


def parse_args():
    args = sys.argv[1:]
    ts_start = ts_end = None
    tail = None
    i = 0
    while i < len(args):
        if args[i] == "--ts-start" and i + 1 < len(args):
            ts_start = int(datetime.fromisoformat(args[i + 1]).replace(tzinfo=timezone.utc).timestamp() * 1000)
            i += 2
        elif args[i] == "--ts-end" and i + 1 < len(args):
            ts_end = int(datetime.fromisoformat(args[i + 1]).replace(tzinfo=timezone.utc).timestamp() * 1000)
            i += 2
        elif args[i] == "--tail" and i + 1 < len(args):
            tail = int(args[i + 1])
            i += 2
        else:
            i += 1
    return ts_start, ts_end, tail


def load_log(path: Path, ts_start=None, ts_end=None, tail=None) -> list[dict]:
    if not path.exists():
        print(f"ログファイルが見つかりません: {path}", file=sys.stderr)
        sys.exit(1)
    entries = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = e.get("ts", 0)
            if ts_start and ts < ts_start:
                continue
            if ts_end and ts > ts_end:
                continue
            entries.append(e)
    if tail:
        entries = entries[-tail:]
    return entries


def fmt_pct(n, total):
    return f"{n / total * 100:.1f}%" if total else "—"


def main():
    ts_start, ts_end, tail = parse_args()
    entries = load_log(LOG_PATH, ts_start=ts_start, ts_end=ts_end, tail=tail)

    if not entries:
        print("ログエントリが 0 件です。")
        return

    total = len(entries)

    # バージョン情報
    versions = Counter(e.get("version", "?") for e in entries)
    ver_str = ", ".join(f"{v}({c}件)" for v, c in versions.most_common(3))

    # 期間
    tss = [e["ts"] for e in entries if "ts" in e]
    if tss:
        start_dt = datetime.fromtimestamp(min(tss) / 1000).strftime("%Y-%m-%d %H:%M")
        end_dt = datetime.fromtimestamp(max(tss) / 1000).strftime("%Y-%m-%d %H:%M")
        period = f"{start_dt} 〜 {end_dt}"
    else:
        period = "—"

    print(f"== 入力品質ログ ({total} セッション) ==")
    print(f"   期間: {period}")
    print(f"   バージョン: {ver_str}")
    print()

    # ---- Anomaly 集計 ----
    anomaly_counter = Counter()
    for e in entries:
        for a in e.get("anomaly", []):
            anomaly_counter[a] += 1

    print("--- Anomaly 分布 ---")
    for kind, count in anomaly_counter.most_common():
        print(f"  {kind}: {count} 件 ({fmt_pct(count, total)})")
    if not anomaly_counter:
        print("  (なし)")
    print()

    # ---- 打鍵統計 ----
    key_counts = [e.get("key_count", 0) for e in entries]
    bs_counts = [e.get("bs_count", 0) for e in entries]
    total_keys = sum(key_counts)
    total_bs = sum(bs_counts)
    print("--- 打鍵統計 ---")
    print(f"  総打鍵数: {total_keys}  (平均 {total_keys / total:.1f} / セッション)")
    if total_keys > 0:
        print(f"  BS 率: {total_bs / total_keys:.1%}  ({total_bs} / {total_keys})")
    else:
        print("  BS 率: —")
    print()

    # ---- 確定 / キャンセル ----
    cancelled = sum(1 for e in entries if e.get("committed") is None)
    confirmed = total - cancelled
    print("--- 確定 / キャンセル ---")
    print(f"  確定: {confirmed} 件 ({fmt_pct(confirmed, total)})")
    print(f"  キャンセル (Escape): {cancelled} 件 ({fmt_pct(cancelled, total)})")
    print()

    # ---- 候補選択 ----
    explicit_count = sum(1 for e in entries if e.get("was_explicit", False))
    scroll_vals = [e.get("scroll_count", 0) for e in entries]
    scroll_total = sum(scroll_vals)
    depth_vals = [e.get("candidate_depth", 0) or 0 for e in entries]
    non_zero_depths = [d for d in depth_vals if d > 0]
    print("--- 候補選択 ---")
    print(f"  明示選択 (was_explicit): {explicit_count} 件 ({fmt_pct(explicit_count, total)})")
    print(f"  スクロール: 合計 {scroll_total} 回  (平均 {scroll_total / total:.1f} / セッション)")
    if non_zero_depths:
        non_zero_depths.sort()
        p50 = non_zero_depths[len(non_zero_depths) // 2]
        p95 = non_zero_depths[int(len(non_zero_depths) * 0.95)]
        print(f"  candidate_depth (>0 の {len(non_zero_depths)} 件): p50={p50}  p95={p95}")
    print()

    # ---- 組成時間 ----
    ms_vals = sorted(e.get("composition_ms", 0) for e in entries if e.get("composition_ms", 0) > 0)
    if ms_vals:
        p50 = ms_vals[len(ms_vals) // 2]
        p95 = ms_vals[int(len(ms_vals) * 0.95)]
        print("--- 組成時間 ---")
        print(f"  p50: {p50} ms  /  p95: {p95} ms  ({len(ms_vals)} 件)")
        print()

    # ---- reading 別 candidate_depth 分布（深いもの上位 10） ----
    reading_depths: dict[str, list[int]] = defaultdict(list)
    for e in entries:
        depth = e.get("candidate_depth")
        if depth is not None and depth > 0:
            reading = e.get("reading", "")
            if reading:
                reading_depths[reading].append(depth)

    deep_readings = sorted(
        ((r, depths) for r, depths in reading_depths.items() if len(depths) >= 2),
        key=lambda x: sum(x[1]) / len(x[1]),
        reverse=True,
    )[:10]

    if deep_readings:
        print("--- candidate_depth が深い読み (2 件以上) ---")
        for reading, depths in deep_readings:
            avg = sum(depths) / len(depths)
            print(f"  {reading}: 平均 {avg:.1f}  ({len(depths)} 件)")
        print()


if __name__ == "__main__":
    main()
