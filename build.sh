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
        -o "$BUILD_DIR/tools/verify" tools/verify.m model.m panel_view.m places.m sysmon.m hidtemp.m backdrop.m quad.m vault.m vault_art.m vault_view.m
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
  clang "${BASE[@]}" -framework AppKit \
        -o "$BUILD_DIR/tools/mkicon" tools/mkicon.m
  clang "${BASE[@]}" -framework AppKit -framework CoreImage -framework ImageIO -framework IOKit -framework SystemConfiguration -framework CoreWLAN -framework QuartzCore \
        -o "$BUILD_DIR/tools/preview" tools/preview.m model.m panel_view.m sysmon.m hidtemp.m backdrop.m quad.m vault.m vault_art.m vault_view.m
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
    echo "→ 产物：build/tools/{verify,dump_window,palette,preview,preview_vault,probe_sensors}"
    exit 0
    ;;
  --check)
    echo "→ 严格编译检查（-Wall -Werror，警告即失败）"
    clang -fsyntax-only "${BASE[@]}" main.m model.m oilfeed.m panel_view.m places.m hud.m sysmon.m hidtemp.m backdrop.m quad.m vault.m vault_art.m vault_view.m
    echo "→ 编译校验工具"
    build_tools
    echo "→ 模型与布局断言"
    "$BUILD_DIR/tools/verify" "$(pwd -P)"
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
      -o "$APP/Contents/MacOS/$APP_NAME" main.m model.m oilfeed.m panel_view.m places.m hud.m sysmon.m hidtemp.m backdrop.m quad.m vault.m vault_art.m vault_view.m

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

echo "→ 签名（${SIGN_ID:-ad-hoc}）"
sign_bundle "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1

if [ "${1:-}" = "--build" ]; then
  rm -rf "$BUILD_DIR/$APP_NAME.app"
  mkdir -p "$BUILD_DIR"
  touch "$BUILD_DIR/.metadata_never_index"
  cp -R "$APP" "$BUILD_DIR/"
  "$LSREGISTER" -u "$BUILD_DIR/$APP_NAME.app" 2>/dev/null || true
  echo "→ 只构建模式，产物：$BUILD_DIR/$APP_NAME.app（已禁止索引）"
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
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"
sign_bundle "$INSTALL_DIR/$APP_NAME.app"
touch "$INSTALL_DIR/$APP_NAME.app"
"$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

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
