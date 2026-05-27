#!/usr/bin/env bash
# Step 4: memory ファイルが現状コードと整合しているかの概要を出す。
#
# WHY: memory は point-in-time observation で、書かれた時点では真でも今は偽になっている
# 可能性がある。各 memory に登場する識別子をコードベースに照合することで、
# stale memory を早期発見する。

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT_KEY=$(echo "$REPO_ROOT" | sed 's|/|-|g')
MEMORY_DIR="$HOME/.claude/projects/${PROJECT_KEY}/memory"

echo "=== Step 4: memory の verify ==="
echo

if [ ! -d "$MEMORY_DIR" ]; then
  echo "  (このプロジェクトの memory ディレクトリは未作成: $MEMORY_DIR)"
  exit 0
fi

echo "memory ディレクトリ: $MEMORY_DIR"
echo

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_FILE="$SKILL_DIR/references/skip-identifiers.txt"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

grep -vE '^\s*(#|$)' "$SKIP_FILE" | sed 's/[[:space:]]*$//' > "$TMP/skip.txt"

echo "[各 memory に登場する識別子の実在確認]"
echo

stale_files=0
for f in "$MEMORY_DIR"/*.md; do
  [ "$(basename "$f")" = "MEMORY.md" ] && continue
  [ ! -f "$f" ] && continue

  # バッククォート囲み識別子を抽出
  grep -oE '`[A-Za-z][A-Za-z0-9_+/.]{2,}`' "$f" 2>/dev/null \
    | sed 's/`//g' \
    | sort -u > "$TMP/ids.txt"

  # skip 適用、パスフラグメント・コミットハッシュ除外
  grep -vxFf "$TMP/skip.txt" "$TMP/ids.txt" \
    | grep -vE '/$' \
    | grep -vE '^[0-9a-f]{7,40}$' \
    > "$TMP/targets.txt" || true

  if [ ! -s "$TMP/targets.txt" ]; then
    continue
  fi

  # memory 本文に削除キーワードが含まれているか（INFO 格下げ判定用）
  has_deletion_context=false
  if grep -qE "削除済み|廃止済み|removed|deleted|不採用|廃止" "$f" 2>/dev/null; then
    has_deletion_context=true
  fi

  missing_list=""
  missing_count=0
  info_list=""
  info_count=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if [[ "$id" =~ \.(swift|md|py|json|sh)$ ]]; then
      if [[ "$id" == */* ]]; then
        exists=$([ -f "$REPO_ROOT/$id" ] && echo "1" || echo "")
      else
        exists=$(find "$REPO_ROOT" -name "$id" \
          -not -path '*/.build/*' -not -path '*/checkouts/*' \
          2>/dev/null | head -1)
      fi
      if [ -z "$exists" ]; then
        # 識別子が含まれる行が削除キーワードを含む場合は INFO に格下げ
        id_line=$(grep -m1 "\`$id\`" "$f" 2>/dev/null || true)
        if $has_deletion_context && echo "$id_line" | grep -qE "削除済み|廃止済み|removed|deleted|不採用|廃止"; then
          info_list+="      - $id (file)"$'\n'
          info_count=$((info_count + 1))
        else
          missing_list+="      - $id (file)"$'\n'
          missing_count=$((missing_count + 1))
        fi
      fi
    else
      escaped=$(echo "$id" | sed 's/[+]/\\+/g; s/[.]/\\./g')
      if ! grep -rqE "(^|[^A-Za-z0-9_])${escaped}([^A-Za-z0-9_]|$)" \
          "$REPO_ROOT/Core/Sources" "$REPO_ROOT/keynaco" "$REPO_ROOT/keynacoTests" \
          --include="*.swift" 2>/dev/null; then
        id_line=$(grep -m1 "\`$id\`" "$f" 2>/dev/null || true)
        if $has_deletion_context && echo "$id_line" | grep -qE "削除済み|廃止済み|removed|deleted|不採用|廃止"; then
          info_list+="      - $id (symbol)"$'\n'
          info_count=$((info_count + 1))
        else
          missing_list+="      - $id (symbol)"$'\n'
          missing_count=$((missing_count + 1))
        fi
      fi
    fi
  done < "$TMP/targets.txt"

  if [ "$missing_count" -gt 0 ]; then
    echo "  ⚠️  $(basename "$f"): 欠落識別子 $missing_count 件"
    printf '%s' "$missing_list"
    stale_files=$((stale_files + 1))
  fi
  if [ "$info_count" -gt 0 ]; then
    echo "  ℹ️  $(basename "$f"): 削除済み記録として言及 $info_count 件（正常）"
    printf '%s' "$info_list"
  fi
done

echo
if [ "$stale_files" -eq 0 ]; then
  echo "結果: stale な memory なし ✓"
else
  echo "結果: $stale_files ファイルに欠落識別子あり（更新検討対象）"
fi
