#!/bin/zsh
# Removes the input method. Your config and learned words in ~/Library/Luma are kept;
# pass --purge to delete them too.
set -euo pipefail
pkill -x LumaIME 2>/dev/null || true
rm -rf "$HOME/Library/Input Methods/LumaIME.app"
[[ "${1:-}" == "--purge" ]] && rm -rf "$HOME/Library/Luma"
echo "✓ 已卸载 Uninstalled. 请到「系统设置 → 键盘 → 文本输入」中移除 Luma 拼音。"
echo "  Remove Luma 拼音 from System Settings → Keyboard → Text Input as well."
