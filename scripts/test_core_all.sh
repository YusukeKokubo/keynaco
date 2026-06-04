#!/usr/bin/env bash
# Core の全テスト（fast + slow）。CI・リリース前向け。リポジトリ root から実行。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Core"
exec swift test
