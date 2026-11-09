// 三块桌面组件共用的外观词汇：四档样式 + 一套角色色。
// 取值口只留这一份 —— 卡片面板和活动监视器各抄一份深色档，就会出现"改了一个另一个没改"
// 和"系统切深浅色时只有一块跟着翻"，用户看到的正是"和卡片不一样"。
#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, DeskStyle) {
    DeskStylePlate = 0,    // 圆角卡 + 壁纸采样模糊 + 描边
    DeskStyleFeather,      // 没有边界：一层羽化暗角垫在文字下，文字带柔和投影
    DeskStyleBare,         // 完全无底，只有文字和投影
    DeskStyleHUD,          // 无边玻璃：采样壁纸压雾、四周羽化，无底板无描边
};

// 组件里所有颜色都从这一个构造口走：sRGB 分量写整数，免得各处混用 deviceRGB / calibratedRGB
NSColor *DeskRGB(int r, int g, int b, double a);

// 深浅两档由**系统外观**决定（不是壁纸亮度）；HUD 那档刻意不分深浅
typedef struct {
    NSColor *border, *sep, *title, *primary, *label, *footer, *up, *down, *accent, *barTrack, *glow;
} DeskPalette;
BOOL DeskViewIsDark(NSView *view);
DeskPalette DeskPaletteFor(DeskStyle style, BOOL dark);
