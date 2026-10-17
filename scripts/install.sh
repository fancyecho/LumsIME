#!/bin/zsh
# Installs the built input method for the current user and pre-compiles the dictionaries.
set -euo pipefail
cd "${0:A:h}/.."

DEST="$HOME/Library/Input Methods/LumaIME.app"
pkill -x LumaIME 2>/dev/null || true
rm -rf "$DEST"
cp -R build/LumaIME.app "$DEST"
"$DEST/Contents/MacOS/LumaIME" --register
"$DEST/Contents/MacOS/LumaIME" --deploy
echo "installed → $DEST"
echo "首次使用：系统设置 → 键盘 → 文本输入 → 编辑 → ＋ → 简体中文 → Luma 拼音"
