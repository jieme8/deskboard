// 生成 DeskBoard 的 App 图标母版（默认 1024 见方 PNG）。
// 图标定义跟着代码走，不往仓库里塞二进制素材；build.sh 再用 sips + iconutil 打成 .icns。
// 用法：mkicon <输出png> [边长]
#import <AppKit/AppKit.h>

static NSColor *RGBA(int r, int g, int b, double a) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

static NSColor *Cyan(void) { return RGBA(112, 216, 255, 1); }
static NSColor *Ink(void)  { return RGBA(226, 246, 255, 1); }

static void FillRound(NSRect r, NSColor *color) {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r
                                                     xRadius:r.size.height / 2
                                                     yRadius:r.size.height / 2];
    [color setFill];
    [p fill];
}

// 小加油机：机身 + 显示屏 + 油管与油枪。按菜单栏那个 18×16 字形的比例放大重画，
// 笔画加粗到 2.6u，32px 下才不会糊成一团。
static void DrawPump(NSRect box) {
    CGFloat u = MIN(box.size.width / 18.0, box.size.height / 16.0);
    CGFloat x = box.origin.x + (box.size.width - 18 * u) / 2.0;
    CGFloat y = box.origin.y + (box.size.height - 16 * u) / 2.0;
    NSRect body = NSMakeRect(x + 2.6 * u, y + 1.2 * u, 7.4 * u, 13.2 * u);

    NSBezierPath *pump = [NSBezierPath bezierPathWithRoundedRect:body xRadius:2.0 * u yRadius:2.0 * u];
    pump.lineWidth = 2.6 * u;
    [Ink() setStroke];
    [pump stroke];

    FillRound(NSMakeRect(x + 4.6 * u, y + 9.4 * u, 3.4 * u, 3.0 * u), Cyan());

    NSBezierPath *hose = [NSBezierPath bezierPath];
    [hose moveToPoint:NSMakePoint(x + 10.0 * u, y + 11.6 * u)];
    [hose curveToPoint:NSMakePoint(x + 14.4 * u, y + 8.6 * u)
         controlPoint1:NSMakePoint(x + 13.2 * u, y + 11.6 * u)
         controlPoint2:NSMakePoint(x + 14.4 * u, y + 10.9 * u)];
    [hose lineToPoint:NSMakePoint(x + 14.4 * u, y + 4.6 * u)];
    hose.lineWidth = 2.6 * u;
    [Ink() setStroke];
    [hose stroke];

    FillRound(NSMakeRect(x + 12.7 * u, y + 1.4 * u, 3.4 * u, 3.2 * u), Cyan());
}

// 一行指标：一条数值条 + 底下一条进度条。元素刻意少 —— 32px 下多一条就糊一片
static void DrawStatRow(CGFloat x, CGFloat top, CGFloat w, CGFloat k, double frac) {
    FillRound(NSMakeRect(x, top - 30 * k, w, 30 * k), RGBA(255, 255, 255, 0.92));
    NSRect track = NSMakeRect(x, top - 62 * k, w, 12 * k);
    FillRound(track, RGBA(120, 214, 255, 0.22));
    NSRect knob = NSMakeRect(track.origin.x, track.origin.y,
                             MAX(track.size.height, round(track.size.width * frac)), track.size.height);
    FillRound(knob, Cyan());
}

static void DrawIcon(CGFloat S) {
    CGFloat k = S / 1024.0;
    // macOS 图标栅格：824×824 的圆角方块居中在 1024 画布里，圆角约 185
    CGFloat blob = round(S * 824.0 / 1024.0);
    CGFloat inset = round((S - blob) / 2.0);
    CGFloat radius = round(S * 185.0 / 1024.0);
    NSRect tile = NSMakeRect(inset, inset, blob, blob);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:radius yRadius:radius];
    [shape fill];   // 底色由下面的渐变铺满，这里先占好 alpha 形状

    [NSGraphicsContext saveGraphicsState];
    [shape addClip];
    [[[NSGradient alloc] initWithColorsAndLocations:RGBA(7, 20, 38, 1), @(0.0),
                                                    RGBA(16, 42, 68, 1), @(0.62),
                                                    RGBA(24, 60, 92, 1), @(1.0), nil]
        drawInRect:tile angle:90.0];
    // 顶部一道高光，深色底才不至于发闷
    [[[NSGradient alloc] initWithColorsAndLocations:RGBA(255, 255, 255, 0.13), @(0.0),
                                                   RGBA(255, 255, 255, 0.0), @(1.0), nil]
        drawInRect:NSMakeRect(tile.origin.x, NSMaxY(tile) - blob * 0.46, blob, blob * 0.46)
             angle:-90.0];

    // 小组件本体：一张横版圆角卡，左边加油机、右边两行指标。
    // 卡片占满图标宽度的 84%，小尺寸下"一张横卡"的轮廓才认得出来
    NSRect card = NSMakeRect(round(168 * k), round(348 * k), round(688 * k), round(328 * k));
    CGFloat cardR = 68 * k;
    NSBezierPath *cardPath = [NSBezierPath bezierPathWithRoundedRect:card xRadius:cardR yRadius:cardR];
    [RGBA(255, 255, 255, 0.10) setFill];
    [cardPath fill];
    [Cyan() setStroke];
    cardPath.lineWidth = 9 * k;
    [cardPath stroke];

    DrawPump(NSMakeRect(NSMinX(card) + 54 * k, NSMinY(card) + 64 * k, 176 * k, 200 * k));
    CGFloat colX = NSMinX(card) + 276 * k;
    CGFloat colW = NSMaxX(card) - 54 * k - colX;
    DrawStatRow(colX, NSMaxY(card) - 78 * k, colW, k, 0.42);
    DrawStatRow(colX, NSMaxY(card) - 200 * k, colW, k, 0.68);
    [NSGraphicsContext restoreGraphicsState];

    NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(tile, 2 * k, 2 * k)
                                                       xRadius:radius - 2 * k yRadius:radius - 2 * k];
    [RGBA(255, 255, 255, 0.10) setStroke];
    rim.lineWidth = 3 * k;
    [rim stroke];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "用法：mkicon <输出png> [边长]\n"); return 2; }
        CGFloat S = argc > 2 ? @(argv[2]).doubleValue : 1024.0;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)S pixelsHigh:(NSInteger)S
                         bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                           colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:ctx];
        DrawIcon(S);
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:@(argv[1]) atomically:YES]) {
            fprintf(stderr, "写不出文件：%s\n", argv[1]);
            return 1;
        }
        printf("→ %s（%.0fx%.0f）\n", argv[1], S, S);
        return 0;
    }
}
