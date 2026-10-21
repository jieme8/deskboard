#!/bin/bash
# 修复「菜单栏不显示」：让系统认定的「这个 App」就是正在跑的那一份。
#
# 背景（2026-10-21 实测）：macOS 按 bundle id 记账。同一 id 出现第二份副本时
# （每次构建的暂存目录、旧版本、装到别处的副本），系统会把旧的那份自动搬进
# ~/.Trash/DeskBoard HH.MM.SS.app，**并且继续留着它的登记**。于是同一个 id 名下
# 攒了几百条记录，系统认不出「这个菜单栏项属于哪个 App」，菜单栏图标整个不画 ——
# 而 NSStatusItem.isVisible 仍然返回 1，只看日志会被骗过去。
#
# 症状：菜单栏里没有 DeskBoard 的加油机图标，但 App 在跑、桌面上的三块组件都正常。
#
# 用法：
#   tools/fix_statusbar.sh            # 清理重复登记，并把安装副本登记成「正主」
#   tools/fix_statusbar.sh --list     # 只看现状
set -uo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${DESKBOARD_BUNDLE_ID:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$HOME/Applications/DeskBoard.app/Contents/Info.plist" 2>/dev/null || echo com.hujie.deskboard.widget)}"
export DESKBOARD_APP_PATH="${INSTALL_DIR:-$HOME/Applications}/DeskBoard.app"

if [ "${1:-}" = "--list" ]; then
  python3 tools/ls_list.py "$BUNDLE_ID"
  exit 0
fi

if [ ! -d "$DESKBOARD_APP_PATH" ]; then
  echo "✗ 找不到 $DESKBOARD_APP_PATH（先跑 ./build.sh 安装）" >&2
  exit 1
fi

echo "→ bundle id：$BUNDLE_ID"
python3 tools/ls_list.py "$BUNDLE_ID" --clean
echo "✓ 完成。重新启动 App 后菜单栏图标应恢复（tools/watch_drag.sh 之外的自检也可复核）。"
