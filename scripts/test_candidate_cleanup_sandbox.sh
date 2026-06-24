#!/usr/bin/env bash
# 候補サジェスト整理後のデバッグソケット回帰（keynaco Debug 起動が必要）。リポジトリ root から実行。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/test_candidate_cleanup_sandbox.py" "$@"
