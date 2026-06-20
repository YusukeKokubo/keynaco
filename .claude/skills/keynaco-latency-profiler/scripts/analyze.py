#!/usr/bin/env python3
"""keynaco latency_log.jsonl の集計分析スクリプト。"""

import json
import os
import re
import sys
import time
from collections import defaultdict


def parse_since(s):
    """`30m` / `2h` / `1d` を「現在からその秒数前の Unix 秒」に変換。"""
    m = re.fullmatch(r"(\d+)\s*([smhd])", s.strip())
    if not m:
        raise ValueError(f"--since 形式エラー: {s!r}（例: 30m, 2h, 1d）")
    n, unit = int(m.group(1)), m.group(2)
    delta = n * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]
    return int(time.time()) - delta

LOG_PATH = os.path.expanduser(
    "~/Library/Application Support/keynaco/latency_log.jsonl"
)

def load(path, ts_start=None, ts_end=None):
    data = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                d = json.loads(line)
                ts = d.get("ts", 0)
                if ts_start is not None and ts < ts_start:
                    continue
                if ts_end is not None and ts > ts_end:
                    continue
                data.append(d)
    return data

def parse_args(args):
    by_ver = False
    ts_start = None
    ts_end = None
    path = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--by-version":
            by_ver = True
        elif a == "--ts-start" and i + 1 < len(args):
            i += 1
            ts_start = int(args[i])
        elif a == "--ts-end" and i + 1 < len(args):
            i += 1
            ts_end = int(args[i])
        elif a == "--since" and i + 1 < len(args):
            i += 1
            ts_start = parse_since(args[i])
        elif not a.startswith("--"):
            path = a
        i += 1
    return by_ver, ts_start, ts_end, path

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
    print("="*55)

def print_latency(data):
    keys = [
        ("fetch_p50_ms",           "fetch p50        "),
        ("fetch_p95_ms",           "fetch p95        "),
        ("fetch_complete_p50_ms",  "fetch_complete p50"),
        ("fetch_complete_p95_ms",  "fetch_complete p95"),
        ("peek_update_p50_ms",     "peek_update p50  "),
        ("peek_update_p95_ms",     "peek_update p95  "),
        ("debounce_policy_p50_ms", "debounce policy  "),
        ("inter_key_p50_ms",       "inter_key p50    "),
        ("fetch_lock_wait_p50_ms", "lock_wait p50    "),
        ("fetch_lock_wait_p95_ms", "lock_wait p95    "),
    ]
    for key, label in keys:
        vals = [d[key] for d in data if key in d]
        if vals:
            avg = sum(vals) / len(vals)
            med = pct(vals, 50)
            mx  = max(vals)
            print(f"  {label}: avg={avg:6.1f}ms  median={med:6.1f}ms  max={mx:6.1f}ms  (n={len(vals)})")

    diffs = [
        d["fetch_complete_p50_ms"] - d["fetch_p50_ms"]
        for d in data
        if "fetch_complete_p50_ms" in d and "fetch_p50_ms" in d
    ]
    if diffs:
        print(f"\n  fetch_complete - fetch (≈実効debounce待ち):")
        print(f"    median={pct(diffs,50):.1f}ms  max={max(diffs):.1f}ms")

def print_cache(data):
    exact  = sum(d.get("cache_exact",  0) for d in data)
    prefix = sum(d.get("cache_prefix", 0) for d in data)
    miss   = sum(d.get("cache_miss",   0) for d in data)
    total  = exact + prefix + miss
    if total:
        print(f"  exact  : {exact:5d} ({exact/total*100:5.1f}%)")
        print(f"  prefix : {prefix:5d} ({prefix/total*100:5.1f}%)")
        print(f"  miss   : {miss:5d} ({miss/total*100:5.1f}%)")

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

def print_worst(data):
    worst = sorted(
        [d for d in data if "fetch_complete_p95_ms" in d],
        key=lambda d: -d["fetch_complete_p95_ms"]
    )[:5]
    for d in worst:
        print(f"  {d['fetch_complete_p95_ms']:5.0f}ms"
              f"  fetch_p95={d.get('fetch_p95_ms', 0):5.0f}ms"
              f"  debounce={d.get('debounce_policy_p50_ms', '?')}ms"
              f"  miss={d.get('cache_miss', '?')}"
              f"  peeks={d.get('total_peeks', '?')}")
    over300 = [d for d in data if d.get("fetch_complete_p95_ms", 0) >= 300]
    print(f"\n  fetch_complete_p95 ≥ 300ms: {len(over300)}/{len(data)} セッション ({len(over300)/len(data)*100:.1f}%)")

def print_selection(data):
    first_rates = [d["first_candidate_rate"] for d in data if "first_candidate_rate" in d]
    if first_rates:
        avg = sum(first_rates) / len(first_rates)
        print(f"  1位確定率: avg={avg*100:.1f}%  (n={len(first_rates)})")
    depths_p50 = [d["selection_depth_p50"] for d in data if "selection_depth_p50" in d]
    depths_p95 = [d["selection_depth_p95"] for d in data if "selection_depth_p95" in d]
    if depths_p50:
        print(f"  選択行 p50: median={pct(depths_p50, 50)}")
    if depths_p95:
        print(f"  選択行 p95: median={pct(depths_p95, 50)}")

def print_fetch_efficiency(data):
    fetch_total = sum(d.get("fetch_count", 0) for d in data)
    wasted_total = sum(d.get("wasted_fetch_count", 0) for d in data)
    sessions_with_fetch = [d for d in data if d.get("fetch_count", 0) > 0]
    if not sessions_with_fetch:
        print("  fetch_count / wasted_fetch_count を含むセッションなし（旧バージョン）")
        return
    print(f"  total fetch:  {fetch_total}")
    print(f"  wasted fetch: {wasted_total} ({wasted_total/fetch_total*100:.1f}% of total)")
    print(f"  ※ wasted = fetch が走ったが新キーで結果破棄。debounce が batch として効くと低い。")

    wasted_ratios = [
        d["wasted_fetch_count"] / d["fetch_count"]
        for d in sessions_with_fetch if d.get("wasted_fetch_count", 0) >= 0
    ]
    if wasted_ratios:
        print(f"\n  セッション別 wasted 率:")
        print(f"    median={pct(wasted_ratios, 50)*100:.1f}%  p95={pct(wasted_ratios, 95)*100:.1f}%")

def print_by_version(data):
    groups = defaultdict(list)
    for d in data:
        v = d.get("version", "unknown")
        groups[v].append(d)

    section("バージョン別比較")
    print(f"  {'バージョン':<20} {'n':>4}  {'fetch_p95':>10}  {'fc_p95':>8}  {'≥300ms':>7}  {'miss%':>6}  {'2ch_miss%':>9}")
    print(f"  {'-'*20} {'-'*4}  {'-'*10}  {'-'*8}  {'-'*7}  {'-'*6}  {'-'*9}")

    for v in sorted(groups.keys()):
        sessions = groups[v]
        n = len(sessions)

        fetch_p95_med = pct([d["fetch_p95_ms"] for d in sessions if "fetch_p95_ms" in d], 50)
        fc_p95_med    = pct([d["fetch_complete_p95_ms"] for d in sessions if "fetch_complete_p95_ms" in d], 50)

        over300 = sum(1 for d in sessions if d.get("fetch_complete_p95_ms", 0) >= 300)
        over300_pct = over300 / n * 100 if n else 0

        exact  = sum(d.get("cache_exact",  0) for d in sessions)
        prefix = sum(d.get("cache_prefix", 0) for d in sessions)
        miss   = sum(d.get("cache_miss",   0) for d in sessions)
        total  = exact + prefix + miss
        miss_pct = miss / total * 100 if total else 0

        r2_sum, r2_cnt = 0.0, 0
        for d in sessions:
            for length, rate in d.get("miss_rate_by_reading_len", {}).items():
                if str(length) == "2":
                    r2_sum += rate
                    r2_cnt += 1
        r2_str = f"{r2_sum / r2_cnt * 100:5.1f}%" if r2_cnt else "   —  "

        print(f"  {v:<20} {n:>4}  {fmt(fetch_p95_med):>10}  {fmt(fc_p95_med):>8}"
              f"  {over300_pct:>6.1f}%  {miss_pct:>5.1f}%  {r2_str:>9}")

def main():
    by_ver, ts_start, ts_end, path = parse_args(sys.argv[1:])
    path = path or LOG_PATH

    if not os.path.exists(path):
        print(f"ログが見つからないにゃ: {path}")
        sys.exit(1)

    data = load(path, ts_start=ts_start, ts_end=ts_end)
    print(f"\nセッション数: {len(data)}")
    if not data:
        sys.exit(0)

    if by_ver:
        print_by_version(data)
        print()
        return

    section("レイテンシ（全セッション集計）")
    print_latency(data)

    section("キャッシュ（全セッション合計）")
    print_cache(data)

    section("fetch_complete_p95 ワースト5セッション")
    print_worst(data)

    section("候補選択行動")
    print_selection(data)

    section("fetch invocation / waste（debounce 効果の指標）")
    print_fetch_efficiency(data)

    print()

if __name__ == "__main__":
    main()
