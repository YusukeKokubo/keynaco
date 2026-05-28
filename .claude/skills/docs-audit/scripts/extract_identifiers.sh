#!/usr/bin/env bash
# Step 1: ドキュメント内の識別子が実コードに存在するか確認する。
#
# WHY: ドキュメントが「過去には存在した」関数名・型名を残し続けるとサイレント嘘になる。
# 機械的に拾うことで、リファクタ時の更新漏れを即座に検出する。
#
# 走査対象から除外するファイル: retrospectives.md（原則の「由来」で削除済み機能名に言及するのが正しい）、
# rejected.md（不採用機能の記録目的で削除済み機能名が登場するのが正しい）。

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_FILE="$SKILL_DIR/references/skip-identifiers.txt"

# 走査対象のドキュメント
DOC_PATHS=(
  "$REPO_ROOT/CLAUDE.md"
  "$REPO_ROOT/docs"
  "$REPO_ROOT/.claude/skills"
)

# 識別子の対象スコープ（コードベース側）
CODE_PATHS=(
  "$REPO_ROOT/Core/Sources"
  "$REPO_ROOT/keynaco"
  "$REPO_ROOT/keynacoTests"
)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. ドキュメントからバッククォート囲み識別子を抽出（英字始まり・3 文字以上）。
#    retrospectives.md と rejected.md は「過去の話」なので除外。
grep -rhoE '`[A-Za-z][A-Za-z0-9_+/.]{2,}`' "${DOC_PATHS[@]}" 2>/dev/null \
  --exclude="retrospectives.md" \
  --exclude="rejected.md" \
  | sed 's/`//g' \
  | sort -u > "$TMP/all-ids.txt"

# 2. 除外フィルタを適用:
#    - skip-identifiers.txt の語
#    - パスフラグメント（`/` で終わる、または `/` を含むディレクトリ表記）
#    - コミットハッシュ風の短い hex 文字列（[0-9a-f]{7,40}）
grep -vE '^\s*(#|$)' "$SKIP_FILE" | sed 's/[[:space:]]*$//' > "$TMP/skip.txt"
grep -vxFf "$TMP/skip.txt" "$TMP/all-ids.txt" \
  | grep -vE '/$' \
  | grep -vE '^[0-9a-f]{7,40}$' \
  | grep -vE '^(NS|IMK|TIS|CF|CG|CA|AV|WK|SK|MK|NW|SW)[A-Z][A-Za-z0-9]*\.' \
  > "$TMP/targets.txt" || true

# 3. それぞれの識別子をコードベースに照合
echo "=== Step 1: ドキュメント識別子の実在確認 ==="
echo "(走査対象: $(wc -l < "$TMP/targets.txt" | tr -d ' ') 件、retrospectives.md/rejected.md と skip 適用済み)"
echo

missing_files=0
missing_symbols=0

while IFS= read -r id; do
  [ -z "$id" ] && continue
  if [[ "$id" =~ \.(swift|md|py|json|sh)$ ]]; then
    # ファイル名: パス付きなら test -f、basename のみなら find で実在確認
    if [[ "$id" == */* ]]; then
      exists=$([ -f "$REPO_ROOT/$id" ] && echo "1" || echo "")
    else
      exists=$(find "$REPO_ROOT" -name "$id" \
        -not -path '*/.build/*' \
        -not -path '*/checkouts/*' \
        -not -path '*/DerivedData/*' \
        2>/dev/null | head -1)
    fi
    if [ -z "$exists" ]; then
      origin=$(grep -rln "\`$id\`" "${DOC_PATHS[@]}" 2>/dev/null \
              --exclude="retrospectives.md" --exclude="rejected.md" \
              | head -3 | sed "s|$REPO_ROOT/||g" | tr '\n' ' ')
      echo "  MISSING_FILE: $id (referenced in: $origin)"
      missing_files=$((missing_files+1))
    fi
  else
    # 識別子: コードベースで grep（特殊文字を escape）
    escaped=$(echo "$id" | sed 's/[+]/\\+/g; s/[.]/\\./g')
    if ! grep -rqE "(^|[^A-Za-z0-9_])${escaped}([^A-Za-z0-9_]|$)" \
        "${CODE_PATHS[@]}" --include="*.swift" 2>/dev/null; then
      origin=$(grep -rln "\`$id\`" "${DOC_PATHS[@]}" 2>/dev/null \
              --exclude="retrospectives.md" --exclude="rejected.md" \
              | head -3 | sed "s|$REPO_ROOT/||g" | tr '\n' ' ')
      echo "  MISSING_SYMBOL: $id (referenced in: $origin)"
      missing_symbols=$((missing_symbols+1))
    fi
  fi
done < "$TMP/targets.txt"

echo
echo "結果: 欠落ファイル $missing_files 件 / 欠落シンボル $missing_symbols 件"
echo "(誤検出が多ければ references/skip-identifiers.txt にエントリ追加)"
