#!/usr/bin/env bash
# 全 Step を順次実行するオーケストレータ。
# 個別に走らせたい場合は scripts/<step_name>.sh を直接実行する。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_step() {
  local script="$1"
  echo ""
  echo "════════════════════════════════════════════════════════════"
  bash "$SCRIPT_DIR/$script" || echo "  (script exited with code $?)"
}

echo "keynaco docs-audit ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "実行日時: $(date '+%Y-%m-%d %H:%M:%S')"
echo "リポジトリ: $(git rev-parse --show-toplevel)"
echo "コミット: $(git rev-parse --short HEAD) ($(git log -1 --format=%s))"

run_step "extract_identifiers.sh"
run_step "check_deleted.sh"
run_step "check_counts.sh"
run_step "verify_memory.sh"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "全 Step 完了。重大度別の判断とサマリ化はスキル本体（SKILL.md）の指示に従って行う。"
