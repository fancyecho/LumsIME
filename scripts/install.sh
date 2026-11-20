#!/bin/zsh
# Installs the built input method for the current user and pre-compiles the dictionaries.
set -euo pipefail
cd "${0:A:h}/.."

DEST="$HOME/Library/Input Methods/LumaIME.app"
pkill -x LumaIME 2>/dev/null || true
rm -rf "$DEST"
ditto --norsrc --noextattr build/LumaIME.app "$DEST"  # leaves Finder/iCloud metadata behind
# A grammar model already downloaded for the evals saves the app fetching 390 MB again.
MODEL=vendor/models/wanxiang-lts-zh-hans.gram
if [[ -f $MODEL && ! -f ~/Library/Luma/${MODEL:t} ]]; then
  mkdir -p ~/Library/Luma && cp $MODEL ~/Library/Luma/
fi
"$DEST/Contents/MacOS/LumaIME" --register
"$DEST/Contents/MacOS/LumaIME" --deploy
echo "installed → $DEST"
echo "首次使用：系统设置 → 键盘 → 文本输入 → 编辑 → ＋ → 简体中文 → Luma 拼音"
