#!/usr/bin/env bash
# Step 3: ドキュメントの数値主張（N テーブル・N タブ等）と実装の宣言数を照合。
#
# WHY: 数値主張はリファクタで真っ先にズレる drift の典型例。glossary.md L117
# 周辺で「4 テーブル」と書きながら実態は 5 テーブルだった事例があり、
# 新規参入者を能動的に誤誘導する。実装側の宣言を数える方が真実に近い。

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== Step 3: 数値主張の整合性 ==="
echo

mismatch=0

# docs-audit 自身のスクリプトはドキュメントではないので走査対象から除外する。
DOC_PATHS=(
  "$REPO_ROOT/CLAUDE.md"
  "$REPO_ROOT/docs"
)
for skill_dir in "$REPO_ROOT/.claude/skills"/*/; do
  [ "$(basename "$skill_dir")" = "docs-audit" ] && continue
  DOC_PATHS+=("$skill_dir")
done

check_count() {
  local label="$1"
  local code_count="$2"
  local doc_pattern="$3"
  # 第4引数が指定されたときはそのファイル群のみ検索（誤検出回避用）
  local -a search_paths=("${@:4}")
  [ "${#search_paths[@]}" -eq 0 ] && search_paths=("${DOC_PATHS[@]}")

  echo "[$label]"
  echo "  実装側: $code_count"
  echo "  ドキュメント側:"

  local matches
  matches=$(grep -rnoE "[0-9]+ ?$doc_pattern" "${search_paths[@]}" \
            --include="*.md" 2>/dev/null \
            | sed "s|$REPO_ROOT/||g" || true)

  if [ -z "$matches" ]; then
    echo "    (言及なし)"
  else
    echo "$matches" | sed 's|^|    |'
    # 実数値と異なる主張があれば mismatch
    local safe_count="${code_count:-0}"
    if echo "$matches" | grep -qE "[^0-9]([0-9]+) ?$doc_pattern" \
       && echo "$matches" | grep -vqE "[^0-9]${safe_count} ?$doc_pattern"; then
      echo "  ⚠️  実装の数値（${safe_count}）と食い違うドキュメント記述あり"
      mismatch=$((mismatch + 1))
    fi
  fi
  echo
}

# DB テーブル数
db_tables=$(grep -c "CREATE TABLE IF NOT EXISTS" \
  "$REPO_ROOT/Core/Sources/Core/DatabaseManager.swift" 2>/dev/null || true)
check_count "DB テーブル数" "$db_tables" "テーブル"

# Settings タブ数
tabs=$(grep -c "addTabViewItem(" \
  "$REPO_ROOT/keynaco/Settings/SettingsWindowController.swift" 2>/dev/null || true)
check_count "Settings タブ数" "$tabs" "タブ"

# Settings ファイル数（.swift のみ）
# CLAUDE.md 限定で検索: docs/principles.md の「2 ファイル目」「3 ファイル目」(DRY 原則の説明) との誤検出回避
files=$(find "$REPO_ROOT/keynaco/Settings/" -maxdepth 1 -name "*.swift" 2>/dev/null | wc -l | tr -d ' ')
check_count "Settings ファイル数" "$files" "ファイル" "$REPO_ROOT/CLAUDE.md"

if [ "$mismatch" -eq 0 ]; then
  echo "結果: 数値主張に矛盾なし ✓"
else
  echo "結果: $mismatch カテゴリで実装とドキュメントが矛盾"
fi
