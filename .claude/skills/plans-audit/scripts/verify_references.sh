#!/usr/bin/env bash
# Step 3: plan の status と frontmatter の整合性を検証する。
#
# WHY: plan が「実装完了」と主張していてもコミットが消えていたり rebase で消滅していたら嘘になる。
# また、status: implemented なのに related_commit が無い・status: abandoned なのに
# related_rejected が無いといった「不変条件違反」も検出する。SKILL.md の主張と
# 実装が一致するようにこのスクリプトが担保する。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
PLANS_DIR="$REPO_ROOT/plans"
REJECTED="$REPO_ROOT/docs/rejected.md"

echo "=== Step 3: plan の status / 参照整合性 ==="
echo

if [ ! -d "$PLANS_DIR" ]; then
  echo "  ($PLANS_DIR が見つからない)"
  exit 0
fi

issues=0

for f in "$PLANS_DIR"/*.md; do
  [ ! -f "$f" ] && continue
  name=$(basename "$f")

  status=$(extract_frontmatter_field "$f" "status")
  related_commit=$(extract_frontmatter_field "$f" "related_commit")
  related_rejected=$(extract_frontmatter_field "$f" "related_rejected")
  superseded_by=$(extract_frontmatter_field "$f" "superseded_by")

  # 完全性チェック: implemented なら related_commit が必須
  if [ "$status" = "implemented" ] && [ -z "$related_commit" ]; then
    echo "  [$name] status: implemented だが related_commit が未指定"
    issues=$((issues + 1))
  fi

  # 完全性チェック: abandoned なら related_rejected が必須
  if [ "$status" = "abandoned" ] && [ -z "$related_rejected" ]; then
    echo "  [$name] status: abandoned だが related_rejected が未指定（rejected.md エントリへの link が要る）"
    issues=$((issues + 1))
  fi

  # 完全性チェック: superseded なら superseded_by が必須
  if [ "$status" = "superseded" ] && [ -z "$superseded_by" ]; then
    echo "  [$name] status: superseded だが superseded_by が未指定"
    issues=$((issues + 1))
  fi

  # 参照実在: related_commit
  if [ -n "$related_commit" ]; then
    if ! git -C "$REPO_ROOT" cat-file -e "$related_commit^{commit}" 2>/dev/null; then
      echo "  [$name] related_commit '$related_commit' が git history に存在しない"
      issues=$((issues + 1))
    fi
  fi

  # 参照実在: related_rejected が rejected.md にあるか
  if [ -n "$related_rejected" ] && [ -f "$REJECTED" ]; then
    if ! grep -qF "$related_rejected" "$REJECTED" 2>/dev/null; then
      echo "  [$name] related_rejected '$related_rejected' が rejected.md に見つからない"
      issues=$((issues + 1))
    fi
  fi

  # 参照実在: superseded_by が plans/ にあるか
  if [ -n "$superseded_by" ]; then
    if [ ! -f "$PLANS_DIR/$superseded_by" ]; then
      echo "  [$name] superseded_by '$superseded_by' が plans/ に存在しない"
      issues=$((issues + 1))
    fi
  fi
done

echo
if [ "$issues" -eq 0 ]; then
  echo "結果: status / 参照整合性 OK ✓"
else
  echo "結果: $issues 件の不整合"
fi
