#!/bin/zsh
# One-line installer for the latest release:
#   curl -fsSL https://raw.githubusercontent.com/fancyecho/LumsIME/main/scripts/get.sh | zsh
set -euo pipefail
URL="https://github.com/fancyecho/LumsIME/releases/latest/download/LumaIME.zip"
DIR="$HOME/Library/Input Methods"
DEST="$DIR/LumaIME.app"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "↓ 下载 Downloading $URL"
curl -fL --progress-bar "$URL" -o "$tmp/LumaIME.zip"
ditto -x -k "$tmp/LumaIME.zip" "$tmp"

pkill -x LumaIME 2>/dev/null || true
mkdir -p "$DIR"
rm -rf "$DEST"
ditto "$tmp/LumaIME.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

"$DEST/Contents/MacOS/LumaIME" --register >/dev/null
echo "⚙ 正在编译词库，约需半分钟 Building dictionaries (about 30 s)…"
"$DEST/Contents/MacOS/LumaIME" --deploy >/dev/null 2>&1

echo
echo "✓ 已安装 Installed → $DEST"
echo "  下一步：系统设置 → 键盘 → 文本输入 → 编辑… → ＋ → 简体中文 → Luma 拼音"
echo "  Next:   System Settings → Keyboard → Text Input → Edit… → + → Chinese, Simplified → Luma 拼音"
