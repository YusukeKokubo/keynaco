#!/usr/bin/env bash
# Step 1: 各 plan ファイルの status を抽出してカテゴリ別に表示する。
#
# WHY: 76 ファイルある plans/ のライフサイクルを俯瞰できる仕組みがなく、書きっぱなしの
# legacy 状態を可視化する。新規 plan は YAML frontmatter で status を持ち、既存の
# **状態**: ... 記法も legacy 互換として認識する。

set -uo pipefail

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

# 各 plan の status を抽出
for f in "$PLANS_DIR"/*.md; do
  [ ! -f "$f" ] && continue
  name=$(basename "$f")

  # YAML frontmatter から status を抽出
  status=$(awk '
    NR==1 && /^---$/ {in_fm=1; next}
    in_fm && /^---$/ {exit}
    in_fm && /^status:/ {sub(/^status:[[:space:]]*/,""); print; exit}
  ' "$f")

  # frontmatter になければ markdown の **状態**: 行を見る
  if [ -z "$status" ]; then
    md_status=$(grep -E '^\*?\*?状態\*?\*?:' "$f" 2>/dev/null \
                | head -1 \
                | sed 's/^\*\*状態\*\*:[[:space:]]*//' \
                | sed 's/^状態:[[:space:]]*//')
    if [ -n "$md_status" ]; then
      # 既存記法を canonical status にマップ
      case "$md_status" in
        オープン*|未着手*|検討中*) status="draft (legacy)" ;;
        実装中*|進行中*|作業中*)   status="in-progress (legacy)" ;;
        完了*|実装完了*|採用*)     status="implemented (legacy)" ;;
        失敗*|不採用*|破棄*|中断*) status="abandoned (legacy)" ;;
        *)                          status="legacy: $md_status" ;;
      esac
    fi
  fi

  [ -z "$status" ] && status="unknown"
  echo "$status|$name" >> "$TMP/all.txt"
done

# カテゴリ別に集計
echo "[status 別集計]"
sort "$TMP/all.txt" | awk -F'|' '{print $1}' | sort | uniq -c | sort -rn | sed 's/^/  /'
echo

# 各 plan を一覧（unknown を先に出すと多すぎるので折りたたみ）
echo "[unknown（frontmatter も 状態 記法もない plan）]"
unknown_count=$(grep -c '^unknown|' "$TMP/all.txt" || echo "0")
if [ "$unknown_count" -gt 0 ]; then
  echo "  $unknown_count 件:"
  grep '^unknown|' "$TMP/all.txt" | cut -d'|' -f2 | sed 's/^/    /' | head -10
  [ "$unknown_count" -gt 10 ] && echo "    ... (残り $((unknown_count - 10)) 件)"
fi
echo

echo "[明示的 status を持つ plan]"
explicit=$(grep -v '^unknown|' "$TMP/all.txt" 2>/dev/null || true)
if [ -z "$explicit" ]; then
  echo "  (なし — すべて legacy)"
else
  echo "$explicit" | sort | sed 's/^/  /' | sed 's/|/  /'
fi
