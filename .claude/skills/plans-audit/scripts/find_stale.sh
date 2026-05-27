#!/usr/bin/env bash
# Step 2: 長期間更新されていない draft / in-progress / unknown plan を検出する。
#
# WHY: 「あとでやる」つもりで書かれた plan が忘れ去られて滞留する問題を可視化する。
# git の最終更新日を基準にすることで、frontmatter が古くてもファイル自体は更新されている
# ケース（活きてる plan）を誤検出しないようにする。

set -uo pipefail

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

stale_count=0
for f in "$PLANS_DIR"/*.md; do
  [ ! -f "$f" ] && continue
  name=$(basename "$f")

  # status が implemented / abandoned / superseded なら終端なのでスキップ
  status=$(awk '
    NR==1 && /^---$/ {in_fm=1; next}
    in_fm && /^---$/ {exit}
    in_fm && /^status:/ {sub(/^status:[[:space:]]*/,""); print; exit}
  ' "$f")
  case "$status" in
    implemented|abandoned|superseded) continue ;;
  esac

  # markdown の状態記法も同じく
  md_status=$(grep -E '^\*?\*?状態\*?\*?:' "$f" 2>/dev/null | head -1)
  case "$md_status" in
    *完了*|*実装完了*|*採用*|*失敗*|*不採用*|*破棄*|*中断*) continue ;;
  esac

  # git の最終更新日（ファイルが追跡されていなければファイル mtime）
  last_commit_epoch=$(git -C "$REPO_ROOT" log -1 --format=%ct -- "plans/$name" 2>/dev/null || echo "")
  if [ -z "$last_commit_epoch" ]; then
    last_commit_epoch=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "$NOW")
  fi

  age_sec=$((NOW - last_commit_epoch))
  if [ "$age_sec" -ge "$THRESHOLD_SEC" ]; then
    age_days=$((age_sec / 86400))
    last_date=$(date -r "$last_commit_epoch" "+%Y-%m-%d" 2>/dev/null || echo "?")
    echo "  $name (最終更新 $last_date / $age_days 日前)"
    stale_count=$((stale_count + 1))
  fi
done

echo
if [ "$stale_count" -eq 0 ]; then
  echo "結果: stale plan なし ✓"
else
  echo "結果: $stale_count 件の plan が ${THRESHOLD_DAYS} 日以上更新なし"
  echo "（実装完了なら status: implemented に、捨てるなら status: abandoned + rejected.md エントリ化、"
  echo "  まだ生きてるなら追記して触る、のいずれかで状態を更新する）"
fi
