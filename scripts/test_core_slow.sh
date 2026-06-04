#!/usr/bin/env bash
# AzooKey 実辞書・POS 分類など重い Core テストのみ。リポジトリ root から実行。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Core"
exec swift test --filter KeynacoCoreSlowTests
