# DeskBoard

macOS 桌面挂件。纯 Objective-C + AppKit，无第三方依赖，一条 `build.sh` 搞定编译、安装和实测校验。

桌面上常驻一张可拖拽的卡片面板，显示油价、系统状态（CPU / GPU / 内存 / 磁盘 / 读写速率）和时段问候，支持四个屏幕可用区自动定位、拖角调宽高。

## 环境要求

- macOS 13.0+
- Command Line Tools（`xcode-select --install`）
- clang

## 构建

```bash
./build.sh            # 构建 + 安装到 ~/Applications + 启动 + 桌面层窗口实测
./build.sh --build    # 只构建到 build/DeskBoard.app，不安装不启动
./build.sh --check    # 零警告编译 + 模型/布局断言（改完代码先跑这个）
./build.sh --dump     # 只对正在运行的实例做窗口层级校验
./build.sh --tools    # 只编译校验工具到 build/tools/
```

安装位置默认 `~/Applications`，可用 `INSTALL_DIR` 覆盖：

```bash
INSTALL_DIR=/Applications ./build.sh
```

### 关于 SDK 选择

本机默认 SDK 有时是坏的（`MacOSX27.0.sdk` 的 `.tbd` 含当前链接器不认的 `arm64e.x1-macos` 架构）。`build.sh` 里的 `pick_sdk` 不信 `xcrun` 默认值，逐个试候选 SDK，用一个最小链接测试挑第一个真能用的。

## 目录结构

| 路径 | 作用 |
| --- | --- |
| `main.m` | 应用入口、事件循环、托盘与全局快捷键 |
| `panel_view.m` | 卡片面板绘制（背景采样、暗角、羽化、进度条） |
| `model.m` | 数据模型与 JSON 解析 |
| `sysmon.m` | CPU / 内存 / 磁盘 / 网络实时读数 |
| `smc.m` | 经 SMC 读取温度、风扇等传感器 |
| `hidtemp.m` | HID 层温度传感器枚举 |
| `backdrop.m` | 壁纸取色与背景模糊采样 |
| `quad.m` | 四角拖拽的坐标与命中判定 |
| `places.m` | 屏幕可用区定位 |
| `hud.m` | 轻量 HUD 提示层 |
| `tools/` | 开发期校验工具（取色板、窗口 dump、探针、图标生成等） |
| `mock/` | 测试用假数据 |

图标由 `tools/mkicon.m` 在代码里绘制，`build.sh` 负责铺满 10 个尺寸并打成 `.icns`，所以仓库里不放二进制素材，改一笔图标就能重新出全套。

## 调试工具

```bash
./build/tools/verify      # 像素级校验布局与渲染结果
./build/tools/dump_window # 打印运行中实例的窗口层级
./build/tools/palette    # 采样壁纸区域配色
./build/tools/preview    # 离线渲染卡片预览
```

## License

MIT
