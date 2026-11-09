#!/bin/bash
# DeskBoard 构建 / 安装 / 实测校验
#   ./build.sh          构建 + 安装到 ~/Applications + 启动 + 桌面层窗口实测
#   ./build.sh --build  只构建到 build/DeskBoard.app，不安装不启动
#   ./build.sh --check  零警告编译 + 模型/布局断言（改完代码先跑这个）
#   ./build.sh --dump   只对正在运行的实例做窗口层级校验
#   ./build.sh --tools  只编译校验工具到 build/tools/
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DeskBoard"
BUILD_DIR="build"
# 构建暂存放临时目录：项目目录里的 .app 会被 Spotlight 索引并被 LaunchServices 注册，
# Launchpad 就会多出第二个 DeskBoard.app
STAGE_ROOT="${TMPDIR:-/tmp}/deskboard-stage"
APP="$STAGE_ROOT/$APP_NAME.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# 本机默认 SDK 可能是坏的（MacOSX27.0.sdk 的 .tbd 里有当前链接器不认的 arm64e.x1-macos 架构，
# 且其 swiftinterface 由更编译器新构建），所以逐个试哪个真能链接，而不是直接信 xcrun 默认值。
pick_sdk() {
  local cands=()
  cands+=("$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)")
  for v in 26.5 26 26.4 15.4 15; do
    cands+=("/Library/Developer/CommandLineTools/SDKs/MacOSX$v.sdk")
  done
  cands+=("$(xcrun --show-sdk-path 2>/dev/null || true)")
  local sdk test=/tmp/deskboard_sdk_test.$$.c
  for sdk in "${cands[@]}"; do
    [ -n "$sdk" ] && [ -d "$sdk" ] || continue
    printf '#include <CoreFoundation/CoreFoundation.h>\nint main(void){return (int)CFEqual(0,0);}\n' > "$test"
    if clang -isysroot "$sdk" -framework CoreFoundation -o "${test}.bin" "$test" >/dev/null 2>&1; then
      rm -f "$test" "${test}.bin" >/dev/null 2>&1 || true
      echo "$sdk"
      return 0
    fi
    rm -f "$test" "${test}.bin" >/dev/null 2>&1 || true
  done
  echo ""
  return 1
}

SDK=$(pick_sdk) || true
if [ -z "${SDK:-}" ]; then
  echo "找不到可链接的 macOS SDK。试试 xcode-select --install" >&2
  exit 1
fi
echo "→ 使用 SDK: $SDK"

BASE=( -fobjc-arc -mmacosx-version-min=13.0 -isysroot "$SDK"
       -Wall -Werror -Wno-deprecated-declarations -I. )

build_tools() {
  mkdir -p "$BUILD_DIR/tools"
  clang "${BASE[@]}" -framework AppKit -framework IOKit -framework CoreImage -framework ImageIO -framework SystemConfiguration -framework CoreWLAN -framework QuartzCore \
        -o "$BUILD_DIR/tools/verify" tools/verify.m model.m oilfeed.m palette.m panel_view.m places.m sysmon.m hidtemp.m backdrop.m quad.m vault.m vault_art.m vault_view.m history.m procs.m monitor_view.m
  clang "${BASE[@]}" -framework AppKit -framework CoreGraphics -framework CoreImage -framework ImageIO -framework QuartzCore \
        -o "$BUILD_DIR/tools/verify_thumb" tools/verify_thumb.m vault.m vault_art.m vault_view.m backdrop.m quad.m
  clang "${BASE[@]}" -framework AppKit \
        -o "$BUILD_DIR/tools/dump_window" tools/dump_window.m places.m
  clang "${BASE[@]}" -framework AppKit \
        -o "$BUILD_DIR/tools/palette" tools/palette.m
  clang "${BASE[@]}" -framework AppKit -framework CoreWLAN -framework IOKit \
        -o "$BUILD_DIR/tools/probe_sensors" tools/probe_sensors.m smc.m
  clang "${BASE[@]}" -framework IOKit \
        -o "$BUILD_DIR/tools/probe_temp" tools/probe_temp.m
  # 滚动方向的事实基准：同一个事件喂给原生 NSScrollView 和弹药库组件，比方向
  clang "${BASE[@]}" -framework AppKit -framework CoreGraphics -framework CoreImage -framework ImageIO -framework QuartzCore \
        -o "$BUILD_DIR/tools/probe_scroll" tools/probe_scroll.m vault.m vault_art.m vault_view.m backdrop.m quad.m
  clang "${BASE[@]}" -framework AppKit -framework CoreImage -framework ImageIO -framework QuartzCore -framework SystemConfiguration -framework CoreWLAN -framework IOKit \
        -o "$BUILD_DIR/tools/preview_vault" tools/preview_vault.m vault.m vault_art.m vault_view.m backdrop.m quad.m
  # 点不动到底是"事件没送到视图"还是"被人盖住了"：先查遮挡
  clang "${BASE[@]}" -framework CoreGraphics -framework Foundation \
        -o "$BUILD_DIR/tools/probe_occlusion" tools/probe_occlusion.m places.m
  # 遮挡要用 A/B 判：三块组件被同一批窗口压着，能拖的那两块也压着 —— 压着不等于吃点击
  clang "${BASE[@]}" -framework CoreGraphics -framework Foundation \
        -o "$BUILD_DIR/tools/probe_clickcatcher" tools/probe_clickcatcher.m
  # 桌面层窗口的鼠标事件到底送不送到视图：postEvent 走本进程队列，不需要辅助功能权限
  clang "${BASE[@]}" -framework AppKit -framework CoreGraphics -framework CoreImage -framework ImageIO -framework QuartzCore -framework IOKit \
        -o "$BUILD_DIR/tools/probe_drag" tools/probe_drag.m history.m procs.m palette.m monitor_view.m vault.m vault_art.m vault_view.m backdrop.m quad.m
  # 签到的「点授权没反应」：事件到底进没进视图、药丸和格子各自走哪个回调
  clang "${BASE[@]}" -framework AppKit -framework CoreImage -framework ImageIO -framework QuartzCore \
        -o "$BUILD_DIR/tools/probe_credits_click" tools/probe_credits_click.m credits.m credits_view.m trae_credits.m qoder_credits.m workbuddy_credits.m vault_art.m vault.m backdrop.m quad.m palette.m
  # 活动监视器离屏出图 + 采集层冒烟测试：CLI 看不见桌面，这两件是唯一的肉眼替身
  clang "${BASE[@]}" -framework AppKit -framework CoreImage -framework ImageIO -framework QuartzCore -framework IOKit \
        -o "$BUILD_DIR/tools/preview_monitor" tools/preview_monitor.m history.m procs.m palette.m monitor_view.m vault.m vault_art.m vault_view.m backdrop.m quad.m
  # 字缘暗不暗，不能靠肉眼猜：同一个字符串走三条真实上屏路径，各开一个窗口逐张量像素
  clang "${BASE[@]}" -framework AppKit -framework CoreGraphics \
        -o "$BUILD_DIR/tools/probe_smooth" tools/probe_smooth.m
  clang "${BASE[@]}" -framework Foundation \
        -o "$BUILD_DIR/tools/try_procs" tools/try_procs.m history.m procs.m
  # 签到：CLI 只链 Foundation；预览/断言要 AppKit 和底图那套
  clang "${BASE[@]}" -framework Foundation \
        -o "$BUILD_DIR/tools/try_credits" tools/try_credits.m credits.m trae_credits.m qoder_credits.m workbuddy_credits.m
  clang "${BASE[@]}" -framework AppKit -framework CoreImage -framework ImageIO -framework QuartzCore \
        -o "$BUILD_DIR/tools/verify_credits" tools/verify_credits.m credits.m credits_record.m credits_view.m trae_credits.m qoder_credits.m workbuddy_credits.m vault_art.m vault.m backdrop.m quad.m palette.m
  clang "${BASE[@]}" -framework AppKit -framework CoreImage -framework ImageIO -framework QuartzCore \
        -o "$BUILD_DIR/tools/preview_credits" tools/preview_credits.m credits.m credits_view.m trae_credits.m qoder_credits.m workbuddy_credits.m vault_art.m vault.m backdrop.m quad.m palette.m
  clang "${BASE[@]}" -framework AppKit \
        -o "$BUILD_DIR/tools/mkicon" tools/mkicon.m
  clang "${BASE[@]}" -framework AppKit -framework CoreImage -framework ImageIO -framework IOKit -framework SystemConfiguration -framework CoreWLAN -framework QuartzCore \
        -o "$BUILD_DIR/tools/preview" tools/preview.m model.m palette.m panel_view.m sysmon.m hidtemp.m backdrop.m quad.m vault.m vault_art.m vault_view.m
}

# 图标母版由代码画（tools/mkicon.m），这里只负责铺 iconset 的 10 个尺寸并打成 .icns。
# 好处是图标定义跟着代码走，仓库里不多一份二进制素材，改一笔就能重新出全套。
build_icon() {   # $1 = 目标 App bundle
  local set="$BUILD_DIR/AppIcon.iconset" master="$BUILD_DIR/icon-master.png"
  rm -rf "$set"; mkdir -p "$set" "$1/Contents/Resources"
  "$BUILD_DIR/tools/mkicon" "$master" 1024 >/dev/null
  local pair px name
  for pair in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
              "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    px=${pair%% *}; name=${pair##* }
    sips -z "$px" "$px" "$master" --out "$set/$name.png" >/dev/null
  done
  iconutil -c icns "$set" -o "$1/Contents/Resources/AppIcon.icns"
}

case "${1:-}" in
  --tools)
    echo "→ 编译校验工具"
    build_tools
    echo "→ 产物：build/tools/{verify,dump_window,palette,preview,preview_vault,preview_credits,try_credits,probe_sensors}"
    exit 0
    ;;
  --check)
    echo "→ 严格编译检查（-Wall -Werror，警告即失败）"
    clang -fsyntax-only "${BASE[@]}" main.m model.m oilfeed.m palette.m panel_view.m places.m hud.m sysmon.m hidtemp.m backdrop.m quad.m vault.m vault_art.m vault_view.m history.m procs.m monitor_view.m credits.m credits_record.m credits_view.m trae_credits.m qoder_credits.m workbuddy_credits.m
    echo "→ 编译校验工具"
    build_tools
    echo "→ 模型与布局断言"
    "$BUILD_DIR/tools/verify" "$(pwd -P)"
    echo "→ 签到断言"
    "$BUILD_DIR/tools/verify_credits" "$(pwd -P)"
    echo "→ 缩略图断言"
    "$BUILD_DIR/tools/verify_thumb"
    exit 0
    ;;
esac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ 编译"
clang "${BASE[@]}" \
      -framework AppKit -framework CoreGraphics -framework IOKit -framework CoreImage -framework ImageIO -framework SystemConfiguration -framework CoreWLAN -framework QuartzCore \
      -o "$APP/Contents/MacOS/$APP_NAME" main.m model.m oilfeed.m palette.m panel_view.m places.m hud.m sysmon.m hidtemp.m backdrop.m quad.m vault.m vault_art.m vault_view.m history.m procs.m monitor_view.m credits.m credits_record.m credits_view.m trae_credits.m qoder_credits.m workbuddy_credits.m

echo "→ 生成 App 图标"
build_tools
build_icon "$APP"

pick_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*\)"$/\1/p' | head -1
}
SIGN_ID="${SIGN_IDENTITY:-$(pick_identity)}"

sign_bundle() {   # $1 = bundle
  if [ -n "$SIGN_ID" ] && codesign --force --sign "$SIGN_ID" --timestamp=none "$1" >/dev/null 2>&1; then
    return 0
  fi
  codesign --force --sign - --timestamp=none "$1" >/dev/null 2>&1 || codesign --force --sign - "$1"
}

# bundle id 是「同一个 App」在系统里的身份。同一个 id 同时存在两份（暂存副本 + 安装副本、
# 开发产物 + 安装副本），macOS 会把旧的那份自动搬进 ~/.Trash 并**继续留着登记**；
# 攒到几十条之后，系统认不出「这个菜单栏项属于哪个 App」，菜单栏图标就整个不画
# （而 isVisible 仍然返回 1，只看日志会被骗过去）。2026-10-21 实测踩过这个坑。
# 所以：生产 id 只给安装出去的那一份，暂存副本和开发产物各自用别的 id。
PLIST_BUDDY=/usr/libexec/PlistBuddy
set_bundle_id() {   # $1 = bundle  $2 = 新的 bundle id
  "$PLIST_BUDDY" -c "Set :CFBundleIdentifier $2" "$1/Contents/Info.plist" >/dev/null 2>&1 \
    || "$PLIST_BUDDY" -c "Add :CFBundleIdentifier string $2" "$1/Contents/Info.plist" >/dev/null 2>&1
}
PROD_BUNDLE_ID=$("$PLIST_BUDDY" -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null)
[ -n "$PROD_BUNDLE_ID" ] || PROD_BUNDLE_ID="com.hujie.deskboard.widget"
STAGING_BUNDLE_ID="${PROD_BUNDLE_ID}.staging"
DEV_BUNDLE_ID="${PROD_BUNDLE_ID}.dev"
# 暂存副本先换成非生产 id：它待会儿要被拷去安装目录，在那之前它不该跟生产 id 撞车
set_bundle_id "$APP" "$STAGING_BUNDLE_ID"

echo "→ 签名（${SIGN_ID:-ad-hoc}）"
sign_bundle "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1

if [ "${1:-}" = "--build" ]; then
  rm -rf "$BUILD_DIR/$APP_NAME.app"
  mkdir -p "$BUILD_DIR"
  touch "$BUILD_DIR/.metadata_never_index"
  cp -R "$APP" "$BUILD_DIR/"
  # 开发产物用开发 id：它和安装出去的那份同时在盘上，不能共用生产 id
  set_bundle_id "$BUILD_DIR/$APP_NAME.app" "$DEV_BUNDLE_ID"
  sign_bundle "$BUILD_DIR/$APP_NAME.app"
  "$LSREGISTER" -u "$BUILD_DIR/$APP_NAME.app" 2>/dev/null || true
  echo "→ 只构建模式，产物：$BUILD_DIR/$APP_NAME.app（已禁止索引，bundle id=${DEV_BUNDLE_ID}）"
  exit 0
fi

if [ "${1:-}" = "--dump" ]; then
  build_tools
  "$BUILD_DIR/tools/dump_window" "$APP_NAME" ${2:-}
  exit $?
fi

echo "→ 安装到 $INSTALL_DIR"
mkdir -p "$BUILD_DIR" && touch "$BUILD_DIR/.metadata_never_index"
rm -rf "$BUILD_DIR/$APP_NAME.app"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.4
# 原地替换，路径保持不变。
# 同 id 换路径会被系统当成「装了新版本」：旧的自动搬进 ~/.Trash 并**继续留着登记**，
# 同一个 id 攒够几十条之后，系统就认不出菜单栏项属于哪个 App，整个不画（isVisible 仍返回 1）。
# 只清 Contents、保留 bundle 目录本身，登记路径就不变，也不会再产生新的旧副本。
rm -rf "$INSTALL_DIR/$APP_NAME.app/Contents"
mkdir -p "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP/Contents" "$INSTALL_DIR/$APP_NAME.app/"
# 装出去的这份才用生产 id
set_bundle_id "$INSTALL_DIR/$APP_NAME.app" "$PROD_BUNDLE_ID"
sign_bundle "$INSTALL_DIR/$APP_NAME.app"
touch "$INSTALL_DIR/$APP_NAME.app"
"$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true
# 暂存副本用完就注销，别让它在系统里留一条同源的记录
"$LSREGISTER" -u "$APP" 2>/dev/null || true
rm -rf "$APP" 2>/dev/null || true
echo "→ 已安装（bundle id=${PROD_BUNDLE_ID}）"

open "$INSTALL_DIR/$APP_NAME.app"
sleep 1.5
if ! pgrep -x "$APP_NAME" >/dev/null; then
  echo "→ 启动失败，查看：log show --predicate 'process == \"$APP_NAME\"' --last 2m" >&2
  exit 1
fi
echo "→ 已运行 pid=$(pgrep -x "$APP_NAME")  日志：~/Library/Logs/DeskBoard.log"

echo "→ 桌面层窗口实测（这台机器没有屏幕录制权限，用 WindowServer 的数据代替肉眼）"
build_tools
"$BUILD_DIR/tools/dump_window" "$APP_NAME"
