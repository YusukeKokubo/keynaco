#!/usr/bin/env python3
"""keynaco latency_log.jsonl の集計分析スクリプト。"""

import json
import os
import sys
from collections import defaultdict

LOG_PATH = os.path.expanduser(
    "~/Library/Application Support/keynaco/latency_log.jsonl"
)

def load(path):
    data = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                data.append(json.loads(line))
    return data

def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    return s[min(len(s) - 1, len(s) * p // 100)]

def fmt(v, unit="ms"):
    return f"{v:.1f}{unit}" if v is not None else "—"

def section(title):
    print(f"\n{'='*55}")
    print(f"  {title}")
    print('='*55)

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else LOG_PATH
    if not os.path.exists(path):
        print(f"ログが見つからないにゃ: {path}")
        sys.exit(1)

    data = load(path)
    print(f"\nセッション数: {len(data)}")
    if not data:
        sys.exit(0)

    # ── レイテンシ ──────────────────────────────────────────
    section("レイテンシ（全セッション集計）")
    keys = [
        ("fetch_p50_ms",          "fetch p50        "),
        ("fetch_p95_ms",          "fetch p95        "),
        ("fetch_complete_p50_ms", "fetch_complete p50"),
        ("fetch_complete_p95_ms", "fetch_complete p95"),
        ("peek_update_p50_ms",    "peek_update p50  "),
        ("peek_update_p95_ms",    "peek_update p95  "),
        ("debounce_policy_p50_ms","debounce policy  "),
        ("inter_key_p50_ms",      "inter_key p50    "),
    ]
    for key, label in keys:
        vals = [d[key] for d in data if key in d]
        if vals:
            avg = sum(vals) / len(vals)
            med = pct(vals, 50)
            mx  = max(vals)
            print(f"  {label}: avg={avg:6.1f}ms  median={med:6.1f}ms  max={mx:6.1f}ms  (n={len(vals)})")

    # fetch_complete - fetch の差
    diffs = [d["fetch_complete_p50_ms"] - d["fetch_p50_ms"]
             for d in data if "fetch_complete_p50_ms" in d and "fetch_p50_ms" in d]
    if diffs:
        print(f"\n  fetch_complete - fetch (≈実効debounce待ち):")
        print(f"    median={pct(diffs,50):.1f}ms  max={max(diffs):.1f}ms")

    # ── キャッシュ ──────────────────────────────────────────
    section("キャッシュ（全セッション合計）")
    exact  = sum(d.get("cache_exact",  0) for d in data)
    prefix = sum(d.get("cache_prefix", 0) for d in data)
    miss   = sum(d.get("cache_miss",   0) for d in data)
    total  = exact + prefix + miss
    if total:
        print(f"  exact  : {exact:5d} ({exact/total*100:5.1f}%)")
        print(f"  prefix : {prefix:5d} ({prefix/total*100:5.1f}%)")
        print(f"  miss   : {miss:5d} ({miss/total*100:5.1f}%)")

    # 読み長別ミス率・件数
    rate_sum  = defaultdict(float)
    rate_cnt  = defaultdict(int)
    count_sum = defaultdict(int)
    for d in data:
        for length, rate in d.get("miss_rate_by_reading_len", {}).items():
            rate_sum[length]  += rate
            rate_cnt[length]  += 1
        for length, cnt in d.get("miss_count_by_reading_len", {}).items():
            count_sum[length] += cnt

    if rate_cnt:
        print(f"\n  読み長別ミス率（平均）& ミス件数合計:")
        for length in sorted(rate_sum.keys()):
            avg_rate = rate_sum[length] / rate_cnt[length]
            total_miss = count_sum.get(length, "—")
            bar = "█" * int(avg_rate * 20)
            print(f"    {length}文字: {avg_rate*100:5.1f}%  {bar:<20}  ミス計={total_miss}")

    # 読み長別 fetch p95
    fetch_p95_by_len = defaultdict(list)
    for d in data:
        for length, p95 in d.get("fetch_p95_by_reading_len", {}).items():
            fetch_p95_by_len[length].append(p95)
    if fetch_p95_by_len:
        print(f"\n  読み長別 fetch p95（セッション横断 median）:")
        for length in sorted(fetch_p95_by_len.keys()):
            vals = fetch_p95_by_len[length]
            med = pct(vals, 50)
            mx  = max(vals)
            print(f"    {length}文字: median={med:.1f}ms  max={mx:.1f}ms  (n={len(vals)})")

    # ── 遅いセッション ──────────────────────────────────────
    section("fetch_complete_p95 ワースト5セッション")
    worst = sorted(
        [d for d in data if "fetch_complete_p95_ms" in d],
        key=lambda d: -d["fetch_complete_p95_ms"]
    )[:5]
    for d in worst:
        print(f"  {d['fetch_complete_p95_ms']:5.0f}ms"
              f"  fetch_p95={d.get('fetch_p95_ms',0):5.0f}ms"
              f"  debounce={d.get('debounce_policy_p50_ms','?')}ms"
              f"  miss={d.get('cache_miss','?')}"
              f"  peeks={d.get('total_peeks','?')}")

    # 300ms 超セッション比率
    over300 = [d for d in data if d.get("fetch_complete_p95_ms", 0) >= 300]
    print(f"\n  fetch_complete_p95 ≥ 300ms: {len(over300)}/{len(data)} セッション ({len(over300)/len(data)*100:.1f}%)")

    # ── 選択行動 ──────────────────────────────────────────
    section("候補選択行動")
    first_rates = [d["first_candidate_rate"] for d in data if "first_candidate_rate" in d]
    if first_rates:
        avg = sum(first_rates) / len(first_rates)
        print(f"  1位確定率: avg={avg*100:.1f}%  (n={len(first_rates)})")
    depths_p50 = [d["selection_depth_p50"] for d in data if "selection_depth_p50" in d]
    depths_p95 = [d["selection_depth_p95"] for d in data if "selection_depth_p95" in d]
    if depths_p50:
        print(f"  選択行 p50: median={pct(depths_p50,50)}")
    if depths_p95:
        print(f"  選択行 p95: median={pct(depths_p95,50)}")

    print()

if __name__ == "__main__":
    main()
