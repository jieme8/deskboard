#import "palette.h"

NSColor *DeskRGB(int r, int g, int b, double a) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

static BOOL IsDarkAppearance(NSAppearance *appearance) {
    NSString *name = appearance.name;
    return [name isEqualToString:NSAppearanceNameDarkAqua]
        || [name isEqualToString:NSAppearanceNameVibrantDark];
}

BOOL DeskViewIsDark(NSView *view) { return IsDarkAppearance(view.effectiveAppearance); }

// HUD 一套刻意不分成深浅两版：它是一块没有边框的玻璃，透的是用户自己的壁纸。
// 文字走中性近白，只有数据刻度保留雷达青 —— 玻璃本身不该有自己的颜色。
DeskPalette DeskPaletteFor(DeskStyle style, BOOL dark) {
    DeskPalette p;
    if (style == DeskStyleHUD) {
        p.glow     = [NSColor colorWithWhite:0 alpha:0.75];
        p.border   = [NSColor clearColor];
        p.sep      = [NSColor colorWithWhite:1 alpha:0.10];
        p.title    = DeskRGB(202, 222, 233, 1);
        p.primary  = DeskRGB(244, 250, 255, 1);
        p.label    = DeskRGB(184, 204, 216, 1);
        p.footer   = DeskRGB(160, 182, 198, 1);
        p.up       = DeskRGB(255, 122, 122, 1);
        p.down     = DeskRGB(120, 226, 172, 1);
        p.accent   = DeskRGB(112, 216, 255, 1);
        p.barTrack = DeskRGB(120, 214, 255, 0.16);
        return p;
    }
    if (dark) {
        p.border   = [NSColor colorWithWhite:1.00 alpha:0.09];
        p.sep      = [NSColor colorWithWhite:1.00 alpha:0.11];
        p.title    = DeskRGB(150, 184, 200, 1);
        p.primary  = DeskRGB(244, 248, 252, 1);
        p.label    = DeskRGB(140, 168, 192, 1);
        p.footer   = DeskRGB(126, 154, 178, 1);
        p.up       = DeskRGB(255, 106, 106, 1);
        p.down     = DeskRGB(98, 212, 152, 1);
        p.accent   = DeskRGB(86, 184, 250, 1);
        p.barTrack = [NSColor colorWithWhite:1.00 alpha:0.13];
    } else {
        p.border   = [NSColor colorWithWhite:0.00 alpha:0.12];
        p.sep      = [NSColor colorWithWhite:0.00 alpha:0.10];
        p.title    = DeskRGB(64, 90, 110, 1);
        p.primary  = DeskRGB(12, 26, 42, 1);
        p.label    = DeskRGB(74, 98, 118, 1);
        p.footer   = DeskRGB(96, 118, 138, 1);
        p.up       = DeskRGB(200, 46, 46, 1);
        p.down     = DeskRGB(20, 138, 82, 1);
        p.accent   = DeskRGB(10, 119, 193, 1);
        p.barTrack = [NSColor colorWithWhite:0.00 alpha:0.12];
    }
    p.glow = nil;
    return p;
}

