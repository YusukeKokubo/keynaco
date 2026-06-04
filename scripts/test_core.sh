#!/usr/bin/env bash
# 普段の Core ユニットテスト（AzooKey 実機・境界比較は除外）。リポジトリ root から実行。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Core"
exec swift test --filter KeynacoCoreTests
