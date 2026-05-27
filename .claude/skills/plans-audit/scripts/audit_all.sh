#!/usr/bin/env bash
# 全 Step を順次実行するオーケストレータ。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_step() {
  local script="$1"
  echo ""
  echo "════════════════════════════════════════════════════════════"
  bash "$SCRIPT_DIR/$script" || echo "  (script exited with code $?)"
}

echo "keynaco plans-audit ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "実行日時: $(date '+%Y-%m-%d %H:%M:%S')"
echo "リポジトリ: $(git rev-parse --show-toplevel)"
echo "plans/ ファイル数: $(ls $(git rev-parse --show-toplevel)/plans/*.md 2>/dev/null | wc -l | tr -d ' ')"

run_step "extract_status.sh"
run_step "find_stale.sh"
run_step "verify_references.sh"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "全 Step 完了。triage の進め方は SKILL.md の指示に従う。"
