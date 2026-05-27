#!/usr/bin/env bash
# Step 2: 長期間更新されていない draft / in-progress / unknown plan を検出する。
#
# WHY: 「あとでやる」つもりで書かれた plan が忘れ去られて滞留する問題を可視化する。
# 終端状態（implemented / abandoned / superseded）の plan はスキップ対象。
#
# 判定基準は「plan ファイル自体への git commit の最終日」のみ。機能を実装したけど
# plan ファイルを update し忘れたケースは意図的に stale 扱いになる（plan を
# maintain する責任を促す設計）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
PLANS_DIR="$REPO_ROOT/plans"
THRESHOLD_DAYS="${PLANS_AUDIT_STALE_DAYS:-30}"

echo "=== Step 2: stale plan 検出（${THRESHOLD_DAYS} 日以上更新なし） ==="
echo

if [ ! -d "$PLANS_DIR" ]; then
  echo "  ($PLANS_DIR が見つからない)"
  exit 0
fi

NOW=$(date +%s)
THRESHOLD_SEC=$((THRESHOLD_DAYS * 86400))

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for f in "$PLANS_DIR"/*.md; do
  [ ! -f "$f" ] && continue
  name=$(basename "$f")

  # 終端状態ならスキップ
  status=$(get_plan_status "$f")
  if is_terminal_status "$status"; then
    continue
  fi

  # git の最終更新日（ファイルが追跡されていなければファイル mtime）
  last_commit_epoch=$(git -C "$REPO_ROOT" log -1 --format=%ct -- "plans/$name" 2>/dev/null || echo "")
  if [ -z "$last_commit_epoch" ]; then
    last_commit_epoch=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "$NOW")
  fi

  age_sec=$((NOW - last_commit_epoch))
  if [ "$age_sec" -ge "$THRESHOLD_SEC" ]; then
    age_days=$((age_sec / 86400))
    last_date=$(date -r "$last_commit_epoch" "+%Y-%m-%d" 2>/dev/null || echo "?")
    # age_days をプレフィックスにして後でソートできるようにする
    printf "%06d|%s|%s\n" "$age_days" "$name" "$last_date" >> "$TMP/stale.txt"
  fi
done

stale_count=0
if [ -f "$TMP/stale.txt" ]; then
  stale_count=$(wc -l < "$TMP/stale.txt" | tr -d ' ')
  # 古い順（age_days 降順）に並べる
  sort -rn "$TMP/stale.txt" | while IFS='|' read -r age_pad name last_date; do
    age=$((10#$age_pad))  # ゼロパディング除去
    echo "  $name (最終更新 $last_date / $age 日前)"
  done
fi

echo
if [ "$stale_count" -eq 0 ]; then
  echo "結果: stale plan なし ✓"
else
  echo "結果: $stale_count 件の plan が ${THRESHOLD_DAYS} 日以上更新なし"
  echo "（実装完了なら status: implemented に、捨てるなら status: abandoned + rejected.md エントリ化、"
  echo "  まだ生きてるなら追記して触る、のいずれかで状態を更新する）"
fi
