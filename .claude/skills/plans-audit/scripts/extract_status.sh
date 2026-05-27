#!/usr/bin/env bash
# Step 1: 各 plan ファイルの status を抽出してカテゴリ別に表示する。
#
# WHY: plans/ のライフサイクルを俯瞰できる仕組みがなく、書きっぱなしの legacy 状態
# を可視化する。新規 plan は YAML frontmatter で status を持ち、既存の **状態**: ...
# 記法も legacy 互換として認識する。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
PLANS_DIR="$REPO_ROOT/plans"

echo "=== Step 1: plan status の俯瞰 ==="
echo

if [ ! -d "$PLANS_DIR" ]; then
  echo "  ($PLANS_DIR が見つからない)"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 各 plan の status を抽出（lib.sh の関数を経由）
for f in "$PLANS_DIR"/*.md; do
  [ ! -f "$f" ] && continue
  status=$(get_plan_status "$f")
  echo "$status|$(basename "$f")" >> "$TMP/all.txt"
done

# カテゴリ別に集計
echo "[status 別集計]"
awk -F'|' '{print $1}' "$TMP/all.txt" | sort | uniq -c | sort -rn | sed 's/^/  /'
echo

# unknown の一覧（多すぎるので head で折りたたみ、PLANS_AUDIT_FULL_LIST=1 で全件）
echo "[unknown（frontmatter も 状態 記法もない plan）]"
unknown_count=$(grep -c '^unknown|' "$TMP/all.txt" || echo "0")
if [ "$unknown_count" -gt 0 ]; then
  echo "  $unknown_count 件:"
  if [ "${PLANS_AUDIT_FULL_LIST:-0}" = "1" ]; then
    grep '^unknown|' "$TMP/all.txt" | cut -d'|' -f2 | sed 's/^/    /'
  else
    grep '^unknown|' "$TMP/all.txt" | cut -d'|' -f2 | sed 's/^/    /' | head -10
    [ "$unknown_count" -gt 10 ] && echo "    ... (残り $((unknown_count - 10)) 件。全件表示は PLANS_AUDIT_FULL_LIST=1)"
  fi
fi
echo

echo "[明示的 status を持つ plan]"
explicit=$(grep -v '^unknown|' "$TMP/all.txt" 2>/dev/null || true)
if [ -z "$explicit" ]; then
  echo "  (なし — すべて legacy)"
else
  echo "$explicit" | sort | awk -F'|' '{printf "  %-32s  %s\n", $1, $2}'
fi
