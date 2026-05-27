#!/usr/bin/env bash
# Step 2: rejected.md で削除済みと記録された機能が、コード・他ドキュメントに残骸として残っていないか確認。
#
# WHY: 削除済み機能名がデバッグスナップショット・テスト・SKILL.md などに散在すると、
# 「呼び出し箇所がなくなったコードはその場で消す」原則（principles.md）に違反する。
# 機能削除後の掃除漏れを機械的に検出する。

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
REJECTED="$REPO_ROOT/docs/rejected.md"

if [ ! -f "$REJECTED" ]; then
  echo "ERROR: $REJECTED が見つからない"
  exit 1
fi

echo "=== Step 2: 削除済み機能の残骸チェック ==="

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# rejected.md から「削除/廃止/不採用/Reject」を含む見出しに属するセクションを抽出し、
# その中からバッククォート囲み識別子を取り出す。
awk '
  /^## / { include=0 }
  /^## .*(削除|廃止|不採用|Reject)/ { include=1; next }
  include { print }
' "$REJECTED" \
  | grep -oE '`[A-Za-z][A-Za-z0-9_+/.]{2,}`' \
  | sed 's/`//g' \
  | sort -u > "$TMP/deleted-ids.txt"

# 一般的すぎる語・パスフラグメントは除外
SKIP_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/references/skip-identifiers.txt"
grep -vE '^\s*(#|$)' "$SKIP_FILE" | sed 's/[[:space:]]*$//' > "$TMP/skip.txt"
grep -vxFf "$TMP/skip.txt" "$TMP/deleted-ids.txt" \
  | grep -vE '/$' \
  | grep -vE '^[0-9a-f]{7,40}$' \
  > "$TMP/targets.txt" || true

count=$(wc -l < "$TMP/targets.txt" | tr -d ' ')
if [ "$count" -eq 0 ]; then
  echo "  (rejected.md 内に削除済み識別子の言及なし)"
  exit 0
fi

echo "(rejected.md から $count 件の削除済み識別子を抽出)"
echo

# 走査対象（rejected.md と plans/ は記録目的なので除外）
SEARCH_PATHS=(
  "$REPO_ROOT/keynaco"
  "$REPO_ROOT/Core/Sources"
  "$REPO_ROOT/.claude/skills"
  "$REPO_ROOT/CLAUDE.md"
  "$REPO_ROOT/docs"
)

residual_total=0
while IFS= read -r id; do
  [ -z "$id" ] && continue

  # 識別子がコードに実在するなら「削除済みじゃなく現役」と判定して skip。
  # rejected.md の削除セクションは「代替として使う」と現役識別子を引き合いに出すことがあり、
  # それを drift と誤判定しないため。
  escaped=$(echo "$id" | sed 's/[+]/\\+/g; s/[.]/\\./g')
  if grep -rqE "(^|[^A-Za-z0-9_])${escaped}([^A-Za-z0-9_]|$)" \
      "$REPO_ROOT/Core/Sources" "$REPO_ROOT/keynaco" "$REPO_ROOT/keynacoTests" \
      --include="*.swift" 2>/dev/null; then
    continue
  fi

  results=$(grep -rn --include="*.swift" --include="*.md" \
            "$id" "${SEARCH_PATHS[@]}" 2>/dev/null \
            | grep -v "rejected.md" \
            | grep -v "/plans/" \
            | grep -v "/principles.md" \
            | grep -v ".build/" \
            | grep -v "checkouts/" || true)
  if [ -n "$results" ]; then
    count_for_id=$(echo "$results" | wc -l | tr -d ' ')
    echo "  [$id] 残存 $count_for_id 箇所:"
    echo "$results" | head -5 | sed "s|$REPO_ROOT/|    |g"
    [ "$count_for_id" -gt 5 ] && echo "    ... (残り $((count_for_id-5)) 件)"
    residual_total=$((residual_total + count_for_id))
  fi
done < "$TMP/targets.txt"

echo
if [ "$residual_total" -eq 0 ]; then
  echo "結果: 削除済み機能の残骸なし ✓"
else
  echo "結果: $residual_total 箇所に残骸あり（rejected.md / plans/ / principles.md 以外）"
fi
