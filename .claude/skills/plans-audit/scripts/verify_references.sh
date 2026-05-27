#!/usr/bin/env bash
# Step 3: plan の frontmatter に書かれた参照（related_commit / related_rejected / superseded_by）
# が実在するかを検証する。
#
# WHY: plan が「実装完了」と主張していてもコミットが消えていたり rebase で消滅していたら嘘になる。
# 参照の実在を機械的に確認することで、ライフサイクル記述の信頼性を担保する。

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PLANS_DIR="$REPO_ROOT/plans"
REJECTED="$REPO_ROOT/docs/rejected.md"

echo "=== Step 3: plan の参照整合性 ==="
echo

if [ ! -d "$PLANS_DIR" ]; then
  echo "  ($PLANS_DIR が見つからない)"
  exit 0
fi

issues=0

for f in "$PLANS_DIR"/*.md; do
  [ ! -f "$f" ] && continue
  name=$(basename "$f")

  # frontmatter から各フィールドを抽出
  related_commit=$(awk '
    NR==1 && /^---$/ {in_fm=1; next}
    in_fm && /^---$/ {exit}
    in_fm && /^related_commit:/ {sub(/^related_commit:[[:space:]]*/,""); print; exit}
  ' "$f")
  related_rejected=$(awk '
    NR==1 && /^---$/ {in_fm=1; next}
    in_fm && /^---$/ {exit}
    in_fm && /^related_rejected:/ {sub(/^related_rejected:[[:space:]]*/,""); print; exit}
  ' "$f")
  superseded_by=$(awk '
    NR==1 && /^---$/ {in_fm=1; next}
    in_fm && /^---$/ {exit}
    in_fm && /^superseded_by:/ {sub(/^superseded_by:[[:space:]]*/,""); print; exit}
  ' "$f")

  # related_commit: git で実在確認
  if [ -n "$related_commit" ]; then
    if ! git -C "$REPO_ROOT" cat-file -e "$related_commit^{commit}" 2>/dev/null; then
      echo "  [$name] related_commit '$related_commit' が git history に存在しない"
      issues=$((issues + 1))
    fi
  fi

  # related_rejected: rejected.md にそのアンカー/見出しがあるか
  if [ -n "$related_rejected" ] && [ -f "$REJECTED" ]; then
    # F-1 のような ID か、見出し文字列か、いずれにせよ rejected.md に含まれていればよい
    if ! grep -qF "$related_rejected" "$REJECTED" 2>/dev/null; then
      echo "  [$name] related_rejected '$related_rejected' が rejected.md に見つからない"
      issues=$((issues + 1))
    fi
  fi

  # superseded_by: そのファイルが plans/ に実在するか
  if [ -n "$superseded_by" ]; then
    if [ ! -f "$PLANS_DIR/$superseded_by" ]; then
      echo "  [$name] superseded_by '$superseded_by' が plans/ に存在しない"
      issues=$((issues + 1))
    fi
  fi
done

echo
if [ "$issues" -eq 0 ]; then
  echo "結果: 参照整合性 OK ✓"
else
  echo "結果: $issues 件の参照不整合"
fi
