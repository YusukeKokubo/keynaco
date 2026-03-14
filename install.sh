#!/bin/bash
# ビルド済みの ykey.app を Input Methods へコピーして登録する

set -e

APP_NAME="ykey.app"
BUILD_DIR="build/Build/Products/Debug"
INSTALL_DIR="$HOME/Library/Input Methods"

if [ ! -d "$BUILD_DIR/$APP_NAME" ]; then
    echo "エラー: $BUILD_DIR/$APP_NAME が見つかりません。先にビルドしてください。"
    exit 1
fi

echo "→ $INSTALL_DIR にコピー中..."
cp -r "$BUILD_DIR/$APP_NAME" "$INSTALL_DIR/"

echo "→ 入力ソースを登録中..."
/usr/bin/python3 - <<'EOF'
import subprocess, os
app_path = os.path.expanduser("~/Library/Input Methods/ykey.app")
subprocess.run([
    "/System/Library/Frameworks/Carbon.framework/Versions/A/Support/TISUtilities",
    "--register", app_path
], check=False)
EOF

echo "→ IME プロセスを再起動中..."
killall -9 ykey 2>/dev/null || true

echo "完了。システム設定 → キーボード → 入力ソース で ykey を追加してください。"
