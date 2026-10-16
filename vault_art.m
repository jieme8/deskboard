#import "vault_art.h"
#import <ImageIO/ImageIO.h>

#pragma mark - 配色

static NSColor *VC(int r, int g, int b, double a) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

NSColor *VaultCyan(void)       { return VC(112, 216, 255, 1.0); }  // 主色，和面板 HUD 同一支青
NSColor *VaultCyanBright(void) { return VC(178, 238, 255, 1.0); }  // 高亮和选中
NSColor *VaultInk(void)        { return VC(10, 26, 42, 1.0); }     // 深色底
NSColor *VaultPaper(void)      { return VC(226, 246, 255, 1.0); }  // 主文字
NSColor *VaultMuted(void)      { return VC(126, 176, 206, 1.0); }  // 次要文字
NSColor *VaultWarn(void)       { return VC(255, 138, 122, 1.0); }  // 退回/清空这类破坏性动作

#pragma mark - 底图

// 底图缺失时也要是个像样的界面：深蓝渐变 + 透视网格，总比一块空白强
static void DrawFallbackArt(NSRect rect) {
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:VC(12, 34, 62, 1.0)
                                                 endingColor:VC(4, 12, 24, 1.0)];
    [g drawInBezierPath:[NSBezierPath bezierPathWithRect:rect] angle:90];
    [VC(112, 216, 255, 0.10) setStroke];
    CGFloat step = 26.0;
    for (CGFloat x = rect.origin.x - rect.size.height; x < NSMaxX(rect) + rect.size.height; x += step) {
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p moveToPoint:NSMakePoint(x, NSMaxY(rect))];
        [p lineToPoint:NSMakePoint(x + rect.size.height * 0.5, NSMinY(rect))];
        p.lineWidth = 0.5;
        [p stroke];
    }
}

// 扫描线：每 3px 一根 1px 的暗线，是"这是个显示屏"最省事也最像的信号
static void DrawScanlines(NSRect rect, double alpha) {
    [VC(0, 8, 18, alpha) setFill];
    CGFloat y = floor(rect.origin.y);
    while (y < NSMaxY(rect)) {
        NSRectFillUsingOperation(NSMakeRect(rect.origin.x, y, rect.size.width, 1.0),
                                NSCompositingOperationSourceOver);
        y += 3.0;
    }
}

// 四边向内收的暗角，把注意力压到中间的内容上
static void DrawInnerShadow(NSRect rect, CGFloat depth, double alpha) {
    const int steps = 14;
    double per = 1.0 - pow(1.0 - alpha, 1.0 / steps);
    for (int i = 0; i < steps; i++) {
        double t = (double)i / (steps - 1);
        NSRect r = NSInsetRect(rect, -depth * (1.0 - t), -depth * (1.0 - t));
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:14 + depth * (1 - t)
                                                          yRadius:14 + depth * (1 - t)];
        [VC(2, 10, 22, per) setStroke];
        p.lineWidth = depth / steps + 0.5;
        [p stroke];
    }
}

static void DrawSweepBand(NSRect rect, double sweep, double hot) {
    if (sweep < 0) return;
    CGFloat y = NSMinY(rect) + rect.size.height * sweep;
    CGFloat bandH = 42.0;
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[VaultCyan() colorWithAlphaComponent:0]
                                                 endingColor:[VaultCyan() colorWithAlphaComponent:0.16 + 0.10 * hot]];
    [g drawInBezierPath:[NSBezierPath bezierPathWithRect:NSMakeRect(NSMinX(rect), y, rect.size.width, bandH)]
                  angle:90];
    [VC(190, 244, 255, 0.22 + 0.3 * hot) setFill];
    NSRectFillUsingOperation(NSMakeRect(NSMinX(rect), y, rect.size.width, 0.8),
                            NSCompositingOperationSourceOver);
}

// 纵向压暗：抬头透一点，文字区压实，底部最沉。
// 幅度刻意留得比"深色卡片"浅得多 —— 桌面组件的价值就在于它还是桌面，
// 压过头就变成贴在桌面上的另一块屏幕了。
static void DrawVerticalScrim(NSRect r) {
    NSArray<NSColor *> *cols = @[VC(4, 16, 34, 0.46), VC(4, 16, 34, 0.38),
                                 VC(5, 22, 46, 0.24), VC(5, 22, 46, 0.14)];
    const CGFloat locs[4] = {0.0, 0.16, 0.52, 1.0};
    NSGradient *g = [[NSGradient alloc] initWithColors:cols atLocations:locs
                                             colorSpace:[NSColorSpace genericRGBColorSpace]];
    [g drawInBezierPath:[NSBezierPath bezierPathWithRoundedRect:r xRadius:14.0 yRadius:14.0]
                   angle:90];
}

// 实底卡：采样背后那块真实桌面，压成能压住文字的玻璃
void VaultDrawPlatePlate(NSRect rect, NSImage *wallpaper, double sweep, double hot) {
    if (wallpaper) {
        [wallpaper drawInRect:rect fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver fraction:1.0];
    } else {
        DrawFallbackArt(rect);
    }
    DrawVerticalScrim(rect);
    DrawScanlines(rect, 0.08);
    DrawInnerShadow(rect, 14.0, 0.42);
    if (hot > 0.001) {
        [VC(112, 216, 255, 0.12 * hot) setFill];
        NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
    }
    DrawSweepBand(rect, sweep, hot);
}

// 羽化暗角：不碰壁纸，一层层往里叠出没有硬边界的暗区，文字浮在上面
static void DrawFeatherPlate(NSRect rect, CGFloat feather, double targetAlpha) {
    const int steps = 22;
    double per = 1.0 - pow(1.0 - targetAlpha, 1.0 / steps);
    NSRect outer = NSInsetRect(rect, -feather * 0.5, -feather * 0.5);
    for (int i = 0; i < steps; i++) {
        double t = i / (double)(steps - 1);
        NSRect r = NSInsetRect(outer, t * feather, t * feather);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r
                                                        xRadius:14.0 + feather * (1 - t)
                                                        yRadius:14.0 + feather * (1 - t)];
        [VC(3, 12, 26, per) setFill];
        [p fill];
    }
}

void VaultDrawPlateFeather(NSRect rect) {
    DrawFeatherPlate(rect, 34.0, 0.62);
    DrawScanlines(rect, 0.06);
}

// hover 不再传 BOOL 而是传 0~1 的缓动量：填充亮度跟着鼠标连续变化，
// 硬切会让整张卡在指针扫过时闪一下
double VaultCardFillAlpha(DeskStyle style, double hoverK, double selK) {
    CGFloat hov = (CGFloat)MAX(0.0, MIN(1.0, hoverK));
    CGFloat sel = (CGFloat)MAX(0.0, MIN(1.0, selK));
    switch (style) {
        case DeskStyleBare:      // 无底：卡片只剩一丝描边内的薄雾，文字靠投影撑住
        case DeskStyleHUD:
            return 0.12 + (hov * 0.14) + (sel * 0.08);
        case DeskStyleFeather:
            return 0.30 + (hov * 0.14);
        default:                 // 实底卡
            return 0.54 + (hov * 0.16) + (sel * 0.10);
    }
}

#pragma mark - 小图形

void VaultDrawReticle(NSRect rect, CGFloat inset, CGFloat len, NSColor *color,
                      CGFloat alpha, CGFloat lineWidth) {
    NSRect r = NSInsetRect(rect, inset, inset);
    [[color colorWithAlphaComponent:alpha] setStroke];
    NSBezierPath *p = [NSBezierPath bezierPath];
    p.lineWidth = lineWidth;
    p.lineCapStyle = NSLineCapStyleRound;
    CGFloat xs[2] = { NSMinX(r), NSMaxX(r) }, ys[2] = { NSMinY(r), NSMaxY(r) };
    for (int i = 0; i < 2; i++) {
        for (int j = 0; j < 2; j++) {
            CGFloat x = xs[i], y = ys[j];
            CGFloat sx = (i == 0) ? 1 : -1, sy = (j == 0) ? 1 : -1;
            [p moveToPoint:NSMakePoint(x, y + sy * len)];
            [p lineToPoint:NSMakePoint(x, y)];
            [p lineToPoint:NSMakePoint(x + sx * len, y)];
        }
    }
    [p stroke];
}

// 二十点宽的文件夹：背板往后错开一点，前板压在上面，内容线暗示里面有料
void VaultDrawFolderGlyph(NSRect rect, NSColor *tint, double seed) {
    CGFloat w = rect.size.width, h = rect.size.height;
    CGFloat unit = w / 20.0;
    CGFloat backX = rect.origin.x + 1.4 * unit, backY = rect.origin.y + 2.2 * unit;
    CGFloat backW = w - 2.0 * unit, backH = h - 3.4 * unit;
    CGFloat bodyX = rect.origin.x, bodyY = rect.origin.y;
    CGFloat bodyW = w - 3.0 * unit, bodyH = h - 5.0 * unit;

    // 背板
    [[tint colorWithAlphaComponent:0.16] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(backX, backY, backW, backH)
                                    xRadius:1.8 * unit yRadius:1.8 * unit] fill];

    // 凸耳
    [[tint colorWithAlphaComponent:0.30] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bodyX + 0.6 * unit, bodyY + bodyH - 1.4 * unit,
                                                       7.0 * unit, 3.4 * unit)
                                    xRadius:1.2 * unit yRadius:1.2 * unit] fill];

    // 前板
    NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bodyX, bodyY, bodyW, bodyH)
                                                        xRadius:2.0 * unit yRadius:2.0 * unit];
    [[tint colorWithAlphaComponent:0.52] setFill];
    [body fill];
    [[VaultCyanBright() colorWithAlphaComponent:0.42] setStroke];
    body.lineWidth = MAX(unit * 0.9, 0.7);
    [body stroke];

    // 内容线：条数跟着 seed 走，同一个文件夹每次打开长得一样
    NSUInteger lines = 2 + (NSUInteger)(seed * 2.999);
    for (NSUInteger i = 0; i < lines; i++) {
        CGFloat ly = bodyY + bodyH - (3.2 + 2.4 * i) * unit;
        if (ly < bodyY + 1.2 * unit) break;
        CGFloat lw = (bodyW - (4.0 + 2.2 * i) * unit);
        if (lw < 2.0 * unit) continue;
        [[VaultCyanBright() colorWithAlphaComponent:0.30 - 0.06 * i] setFill];
        NSRectFillUsingOperation(NSMakeRect(bodyX + 1.8 * unit, ly, lw, 1.1 * unit),
                                NSCompositingOperationSourceOver);
    }
}

void VaultDrawRing(NSRect rect, double fraction, NSColor *track, NSColor *fill,
                   NSColor *label, NSString *labelText, NSFont *labelFont) {
    CGFloat lw = 2.4;
    CGFloat r = MIN(rect.size.width, rect.size.height) / 2.0 - lw / 2.0 - 0.5;
    NSPoint c = NSMakePoint(NSMidX(rect), NSMidY(rect));
    double f = MIN(MAX(fraction, 0.0), 1.0);
    // 底下留 40° 缺口，像仪表而不是饼图
    CGFloat start = 110.0, sweepMax = 320.0;

    NSBezierPath *t = [NSBezierPath bezierPath];
    t.lineWidth = lw;
    t.lineCapStyle = NSLineCapStyleRound;
    [t appendBezierPathWithArcWithCenter:c radius:r startAngle:start endAngle:start + sweepMax];
    [track setStroke];
    [t stroke];

    if (f > 0.001) {
        NSBezierPath *p = [NSBezierPath bezierPath];
        p.lineWidth = lw;
        p.lineCapStyle = NSLineCapStyleRound;
        [p appendBezierPathWithArcWithCenter:c radius:r startAngle:start
                                    endAngle:start + sweepMax * f];
        [fill setStroke];
        [p stroke];
    }
    if (labelText.length) {
        NSDictionary *a = @{NSFontAttributeName: labelFont, NSForegroundColorAttributeName: label};
        NSSize s = [labelText sizeWithAttributes:a];
        [labelText drawAtPoint:NSMakePoint(round(c.x - s.width / 2.0), round(c.y - s.height / 2.0))
                withAttributes:a];
    }
}

void VaultDrawDockIcon(VaultDockIcon icon, NSRect rect, NSColor *color, CGFloat lineWidth) {
    [[color colorWithAlphaComponent:0.9] setStroke];
    [[color colorWithAlphaComponent:0.9] setFill];
    CGFloat x = NSMinX(rect), y = NSMinY(rect), w = rect.size.width, h = rect.size.height;
    CGFloat cx = NSMidX(rect), cy = NSMidY(rect);

    // 像素实测：四个图标原本的着墨中心都比 rect 中心偏上 0.5~2.0pt（收起那个最偏，
    // 因为折线箭头本身就不对称）。这里把整个图形统一下移半个 pt 补掉，
    // 收起再单独把顶点压下来一点，让它自己和另外三个站在同一水平线上。
    const CGFloat dy = 0.5;
    y += dy; cy += dy;   // y/cy 供下面的绝对坐标分支使用

    switch (icon) {
        case VaultDockIconScan: {
            CGFloat r = MIN(w, h) / 2.0 - 1.2;
            NSBezierPath *arc = [NSBezierPath bezierPath];
            arc.lineWidth = lineWidth;
            arc.lineCapStyle = NSLineCapStyleRound;
            [arc appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:r
                                        startAngle:28 endAngle:330];
            [arc stroke];
            NSBezierPath *ray = [NSBezierPath bezierPath];
            ray.lineWidth = lineWidth;
            ray.lineCapStyle = NSLineCapStyleRound;
            [ray moveToPoint:NSMakePoint(cx, cy)];
            [ray lineToPoint:NSMakePoint(cx + cos(28 * M_PI / 180) * r, cy + sin(28 * M_PI / 180) * r)];
            [ray stroke];
            NSRectFillUsingOperation(NSMakeRect(cx - 0.9, cy - 0.9, 1.8, 1.8), NSCompositingOperationSourceOver);
            break;
        }
        case VaultDockIconOpen: {
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x + 1.2, y + 2.2, w - 2.4, h - 4.4)
                                                            xRadius:1.8 yRadius:1.8];
            p.lineWidth = lineWidth;
            [p stroke];
            NSRectFillUsingOperation(NSMakeRect(x + 1.8, y + h * 0.58, w - 3.6, 1.2), NSCompositingOperationSourceOver);
            break;
        }
        case VaultDockIconEject: {
            // 上方托盘 + 下方箭头的组合体，实测着墨中心比 rect 中心高 0.5pt，
            // 比另外三个低一档。再补半 pt 让四个图标站在同一水平线上。
            const CGFloat edy = 0.5;
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:
                NSMakeRect(x + 1.2, y + 1.6 + edy, w - 2.4, h * 0.42)
                                                        xRadius:1.6 yRadius:1.6];
            p.lineWidth = lineWidth;
            [p stroke];
            NSBezierPath *up = [NSBezierPath bezierPath];
            up.lineWidth = lineWidth;
            up.lineCapStyle = NSLineCapStyleRound;
            up.lineJoinStyle = NSLineJoinStyleRound;
            [up moveToPoint:NSMakePoint(cx, y + h - 2.4 + edy)];
            [up lineToPoint:NSMakePoint(cx, y + h * 0.56 + edy)];
            [up moveToPoint:NSMakePoint(cx - 3.0, y + h * 0.56 + 3.0 + edy)];
            [up lineToPoint:NSMakePoint(cx, y + h * 0.56 + edy)];
            [up lineToPoint:NSMakePoint(cx + 3.0, y + h * 0.56 + 3.0 + edy)];
            [up stroke];
            break;
        }
        case VaultDockIconHide: {
            NSBezierPath *p = [NSBezierPath bezierPath];
            p.lineWidth = lineWidth;
            p.lineCapStyle = NSLineCapStyleRound;
            p.lineJoinStyle = NSLineJoinStyleRound;
            // 顶点原来写死 y+1.8、两臂在 y+h*0.62，三点不对称，着墨中心比 rect 中心
            // 高 2pt（实测）。改成：两臂落在中心下方 r 处，顶点镜像到中心上方 r 处，
            // 这样整条折线的包围盒正好以 rect 中心对称。
            CGFloat r = h * 0.26;
            [p moveToPoint:NSMakePoint(x + 1.8, cy + r)];
            [p lineToPoint:NSMakePoint(cx, cy - r)];
            [p lineToPoint:NSMakePoint(x + w - 1.8, cy + r)];
            [p stroke];
            break;
        }
    }
}

#pragma mark - 分类图形

// 库位只有 20~26pt 见方，这点地方塞不进"两座山加一个太阳"那种细节——
// 所以七种格式一律走剪影：不画统一外框，每种格式一个自己的轮廓，
// 靠形状本身区分，而不是靠"同一个盒子里换符号"。
// 笔触统一：轮廓线 1.45u、内部实块 0.42u 亮青，文件夹也改成线条剪影，
// 和其它六个摆在一起才是同一套画法（旧的实心文件夹凸耳还画在底部，像个倒扣的托盘）。
//
// 注意：库位视图是翻转的（isFlipped = YES），这里 y 向下增长，
// NSMinY 才是视觉顶边。写坐标时按"顶/底"想，别按数学坐标想。

static void VaultGlyphFolder(NSRect r, NSColor *t) {
    CGFloat u = r.size.width / 20.0, top = NSMinY(r), bot = NSMaxY(r);
    CGFloat tabW = 7.0 * u, tabH = 2.6 * u;
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(NSMinX(r), bot)];
    [p lineToPoint:NSMakePoint(NSMinX(r), top + 4.2 * u)];
    [p lineToPoint:NSMakePoint(NSMinX(r) + tabW * 0.35, top + 4.2 * u)];
    [p lineToPoint:NSMakePoint(NSMinX(r) + tabW, top + 4.2 * u - tabH)];
    [p lineToPoint:NSMakePoint(NSMaxX(r), top + 4.2 * u - tabH)];
    [p lineToPoint:NSMakePoint(NSMaxX(r), bot)];
    [p closePath];
    [[t colorWithAlphaComponent:0.86] setStroke];
    p.lineWidth = MAX(1.45 * u, 0.8);
    p.lineJoinStyle = NSLineJoinStyleRound;
    [p stroke];
    for (int i = 0; i < 2; i++) {
        [[t colorWithAlphaComponent:0.42 - 0.10 * i] setFill];
        NSRectFillUsingOperation(NSMakeRect(NSMinX(r) + 3.0 * u, top + 6.4 * u + i * 3.0 * u,
                                            11.0 * u - i * 3.0 * u, 1.15 * u),
                                 NSCompositingOperationSourceOver);
    }
}

// 视频：胶片框，上下各一排齿孔，中间一个播放三角
static void VaultGlyphVideo(NSRect r, NSColor *t) {
    CGFloat u = r.size.width / 20.0, top = NSMinY(r), bot = NSMaxY(r);
    NSBezierPath *f = [NSBezierPath bezierPathWithRoundedRect:r xRadius:2.0 * u yRadius:2.0 * u];
    [[t colorWithAlphaComponent:0.86] setStroke];
    f.lineWidth = MAX(1.45 * u, 0.8);
    [f stroke];
    for (int i = 0; i < 4; i++) {
        CGFloat hx = NSMinX(r) + 2.0 * u + i * 4.2 * u;
        if (hx + 1.5 * u > NSMaxX(r) - 8.0 * u) break;
        [[t colorWithAlphaComponent:0.70] setFill];
        NSRectFillUsingOperation(NSMakeRect(hx, top + 1.6 * u, 1.5 * u, 2.4 * u), NSCompositingOperationSourceOver);
        NSRectFillUsingOperation(NSMakeRect(hx, bot - 4.0 * u, 1.5 * u, 2.4 * u), NSCompositingOperationSourceOver);
    }
    CGFloat my = (top + bot) / 2.0;
    NSBezierPath *tri = [NSBezierPath bezierPath];
    [tri moveToPoint:NSMakePoint(NSMidX(r) - 2.4 * u, my - 3.6 * u)];
    [tri lineToPoint:NSMakePoint(NSMidX(r) - 2.4 * u, my + 3.6 * u)];
    [tri lineToPoint:NSMakePoint(NSMidX(r) + 3.6 * u, my)];
    [tri closePath];
    [[t colorWithAlphaComponent:0.80] setFill];
    [tri fill];
}

// 音频：五根波形柱从底边长上来，高矮跟着 seed 走，同一个文件每次打开一样
static void VaultGlyphAudio(NSRect r, NSColor *t, double seed) {
    CGFloat u = r.size.width / 20.0, top = NSMinY(r);
    CGFloat b = NSMaxY(r) - 0.5 * u;
    for (int i = 0; i < 5; i++) {
        double ph = fabs(sin((seed + i * 0.31) * M_PI));
        CGFloat h = (b - top) * (0.24 + 0.70 * ph);
        [[t colorWithAlphaComponent:0.50 + 0.09 * i] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(r) + 1.6 * u + i * 3.7 * u,
                                                             b - h, 1.8 * u, h)
                                        xRadius:0.9 * u yRadius:0.9 * u] fill];
    }
}

// 图片：相框 + 一个太阳 + 一座贴底边的山
static void VaultGlyphImage(NSRect r, NSColor *t) {
    CGFloat u = r.size.width / 20.0, top = NSMinY(r), bot = NSMaxY(r);
    NSBezierPath *f = [NSBezierPath bezierPathWithRoundedRect:r xRadius:2.0 * u yRadius:2.0 * u];
    [[t colorWithAlphaComponent:0.86] setStroke];
    f.lineWidth = MAX(1.45 * u, 0.8);
    [f stroke];
    [[t colorWithAlphaComponent:0.78] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(NSMinX(r) + 3.0 * u, top + 2.8 * u, 2.8 * u, 2.8 * u)] fill];
    NSBezierPath *hill = [NSBezierPath bezierPath];
    [hill moveToPoint:NSMakePoint(NSMinX(r) + 1.8 * u, bot - 2.0 * u)];
    [hill lineToPoint:NSMakePoint(NSMinX(r) + 8.4 * u, top + 6.4 * u)];
    [hill lineToPoint:NSMakePoint(NSMaxX(r) - 1.6 * u, bot - 2.0 * u)];
    [hill closePath];
    [[t colorWithAlphaComponent:0.50] setFill];
    [hill fill];
}

// 文档：一张纸，顶上折掉一角，里面三行字
static void VaultGlyphDocument(NSRect r, NSColor *t) {
    CGFloat u = r.size.width / 20.0, top = NSMinY(r), bot = NSMaxY(r);
    CGFloat fo = 5.0 * u;
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(NSMinX(r), bot)];
    [p lineToPoint:NSMakePoint(NSMinX(r), top)];
    [p lineToPoint:NSMakePoint(NSMaxX(r) - fo, top)];
    [p lineToPoint:NSMakePoint(NSMaxX(r), top + fo)];
    [p lineToPoint:NSMakePoint(NSMaxX(r), bot)];
    [p closePath];
    [[t colorWithAlphaComponent:0.86] setStroke];
    p.lineWidth = MAX(1.45 * u, 0.8);
    p.lineJoinStyle = NSLineJoinStyleRound;
    [p stroke];
    NSBezierPath *fold = [NSBezierPath bezierPath];
    [fold moveToPoint:NSMakePoint(NSMaxX(r) - fo, top)];
    [fold lineToPoint:NSMakePoint(NSMaxX(r) - fo, top + fo)];
    [fold lineToPoint:NSMakePoint(NSMaxX(r), top + fo)];
    [[t colorWithAlphaComponent:0.30] setFill];
    [fold fill];
    for (int i = 0; i < 3; i++) {
        CGFloat w = (i == 2) ? 8.0 * u : 11.6 * u;
        [[t colorWithAlphaComponent:0.62 - 0.10 * i] setFill];
        NSRectFillUsingOperation(NSMakeRect(NSMinX(r) + 2.6 * u, top + 6.2 * u + i * 2.8 * u, w, 1.15 * u),
                                 NSCompositingOperationSourceOver);
    }
}

// 压缩包：盒身轮廓 + 上盖 + 露在顶上的拉链头
static void VaultGlyphArchive(NSRect r, NSColor *t) {
    CGFloat u = r.size.width / 20.0, top = NSMinY(r);
    CGFloat lid = 4.2 * u;
    NSBezierPath *b = [NSBezierPath bezierPathWithRoundedRect:
        NSMakeRect(NSMinX(r), top + lid, r.size.width, r.size.height - lid)
                                                   xRadius:1.6 * u yRadius:1.6 * u];
    [[t colorWithAlphaComponent:0.86] setStroke];
    b.lineWidth = MAX(1.45 * u, 0.8);
    [b stroke];
    [[t colorWithAlphaComponent:0.72] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(r), top, r.size.width, lid)
                                    xRadius:1.2 * u yRadius:1.2 * u] fill];
    [[t colorWithAlphaComponent:0.90] setFill];
    NSRectFillUsingOperation(NSMakeRect(NSMidX(r) - 0.5 * u, top - 3.2 * u, 1.0 * u, 3.2 * u),
                             NSCompositingOperationSourceOver);
    [[NSBezierPath bezierPathWithRoundedRect:
        NSMakeRect(NSMidX(r) - 2.2 * u, top - 3.8 * u, 4.4 * u, 2.8 * u)
                                    xRadius:1.0 * u yRadius:1.0 * u] fill];
}

// 代码：尖括号
static void VaultGlyphCode(NSRect r, NSColor *t) {
    CGFloat u = r.size.width / 20.0, top = NSMinY(r), bot = NSMaxY(r);
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(NSMinX(r) + 7.2 * u, top + 3.2 * u)];
    [p lineToPoint:NSMakePoint(NSMinX(r) + 2.8 * u, (top + bot) / 2.0)];
    [p lineToPoint:NSMakePoint(NSMinX(r) + 7.2 * u, bot - 3.2 * u)];
    [p moveToPoint:NSMakePoint(NSMaxX(r) - 7.2 * u, top + 3.2 * u)];
    [p lineToPoint:NSMakePoint(NSMaxX(r) - 2.8 * u, (top + bot) / 2.0)];
    [p lineToPoint:NSMakePoint(NSMaxX(r) - 7.2 * u, bot - 3.2 * u)];
    [[t colorWithAlphaComponent:0.88] setStroke];
    p.lineWidth = MAX(1.6 * u, 0.9);
    p.lineCapStyle = NSLineCapStyleRound;
    p.lineJoinStyle = NSLineJoinStyleRound;
    [p stroke];
}

// 每种格式一个色相。只靠形状区分是不够的：卡片只有 26pt 见方，
// 七种轮廓挤在一起时人会犹豫"这到底是视频还是图片"。
// 颜色是最快的那一路——扫视的时候先认出颜色，再看形状，两边对上才算真的认出来了。
// 色相都挑的是深蓝底上跳得起来的亮色，文件夹沿用琥珀，和整个组件的青色底盘不打架。
NSColor *VaultTintForKind(VaultItemKind kind) {
    switch (kind) {
        case VaultItemFolder:   return [NSColor colorWithSRGBRed:0.92 green:0.66 blue:0.36 alpha:1];
        case VaultItemVideo:    return [NSColor colorWithSRGBRed:0.94 green:0.47 blue:0.67 alpha:1];
        case VaultItemAudio:    return [NSColor colorWithSRGBRed:0.37 green:0.85 blue:0.72 alpha:1];
        case VaultItemImage:    return [NSColor colorWithSRGBRed:0.69 green:0.60 blue:0.97 alpha:1];
        case VaultItemDocument: return [NSColor colorWithSRGBRed:0.87 green:0.91 blue:0.96 alpha:1];
        case VaultItemArchive:  return [NSColor colorWithSRGBRed:0.93 green:0.81 blue:0.38 alpha:1];
        default:                return [NSColor colorWithSRGBRed:0.46 green:0.69 blue:0.98 alpha:1];
    }
}

void VaultDrawItemGlyph(NSRect rect, NSColor *tint, double seed, VaultItemKind kind) {
    switch (kind) {
        case VaultItemVideo:    VaultGlyphVideo(rect, tint); break;
        case VaultItemAudio:    VaultGlyphAudio(rect, tint, seed); break;
        case VaultItemImage:    VaultGlyphImage(rect, tint); break;
        case VaultItemDocument: VaultGlyphDocument(rect, tint); break;
        case VaultItemArchive:  VaultGlyphArchive(rect, tint); break;
        case VaultItemCode:     VaultGlyphCode(rect, tint); break;
        default:                VaultGlyphFolder(rect, tint); break;    }
}

// meta 行右端的扩展名规格牌：文件卡片才画，文件夹没有扩展名
void VaultDrawExtChip(NSRect rect, NSString *ext, NSColor *tint) {
    if (ext.length == 0 || NSWidth(rect) < 16) return;
    NSDictionary *a = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:6.5
                                                                        weight:NSFontWeightSemibold]};
    NSSize ts = [ext sizeWithAttributes:a];
    CGFloat padx = 4.0, wid = MIN(NSWidth(rect), ts.width + padx * 2), hei = 11.0;
    NSRect chip = NSMakeRect(NSMinX(rect), NSMinY(rect), wid, hei);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:chip xRadius:2.5 yRadius:2.5];
    [[tint colorWithAlphaComponent:0.16] setFill];
    [p fill];
    [[tint colorWithAlphaComponent:0.40] setStroke];
    p.lineWidth = 0.8;
    [p stroke];
    NSMutableParagraphStyle *c = [NSMutableParagraphStyle new];
    c.alignment = NSTextAlignmentCenter;
    NSMutableDictionary *na = [a mutableCopy];
    na[NSParagraphStyleAttributeName] = c;
    na[NSForegroundColorAttributeName] = [tint colorWithAlphaComponent:0.92];
    [ext drawInRect:NSMakeRect(NSMinX(chip), NSMinY(chip) + 1.0, wid, hei - 1.0) withAttributes:na];
}

#pragma mark - 图片卡片的真实缩略图

// 图形位只有 26×22.1pt，2x 屏上约 52×44px。解码按 160px 长边留余量：
// 既够画满，又不会为了一张 26pt 的小图把六千像素的原图整个读进内存。
static const CGFloat kThumbMaxPx = 160.0;
// 宽高比超过这个值就当长条图（截图、裁剪条）。这类图铺满框只会裁到中间一片空白，
// 什么都不剩还显得像坏了，退回 contain 至少图的形状本身还认得出来。
static const CGFloat kThumbWideRatio = 2.5;

NSImage *VaultThumbDecode(NSString *path, CGFloat maxPx) {
    if (path.length == 0) return nil;
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    NSDictionary *opts = @{
        (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxPx),
        (NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        // 只留缩略图，原图不进内存缓存；顺带避免解码器把整张 6000px 的 JPEG 留下
        (NSString *)kCGImageSourceShouldCacheImmediately: @NO,
    };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!cg) return nil;
    NSImage *img = [[NSImage alloc] initWithCGImage:cg
                                              size:NSMakeSize(CGImageGetWidth(cg), CGImageGetHeight(cg))];
    CGImageRelease(cg);
    return img;
}

// 缓存条目带一个修改时间：库里同一个路径的文件被换掉时，预热会看出 mtime 变了并重解码。
// 绘制路径不 stat 文件，只按路径查表，所以 60fps 重绘的开销仍是一次字典查找。
@interface VaultThumbEntry : NSObject
@property (nonatomic, strong) NSImage *image;
@property (nonatomic, assign) NSTimeInterval mtime;
@end
@implementation VaultThumbEntry
@end

static NSMutableDictionary<NSString *, VaultThumbEntry *> *ThumbCache(void) {
    static NSMutableDictionary *c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [NSMutableDictionary dictionary]; });
    return c;
}
static NSMutableSet<NSString *> *ThumbFailed(void) {
    static NSMutableSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}
static NSLock *ThumbLock(void) {
    static NSLock *l; static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [NSLock new]; });
    return l;
}
// 串行队列：解码是有 IO 和 CPU 的活，串行跑就不会和拖拽、入库动画抢核
static dispatch_queue_t ThumbQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("vault.thumb", DISPATCH_QUEUE_SERIAL); });
    return q;
}

NSImage *VaultThumbnail(NSString *path) {
    if (path.length == 0) return nil;
    NSLock *l = ThumbLock(); [l lock];
    NSImage *img = ThumbCache()[path].image;
    [l unlock];
    return img;
}

void VaultThumbForget(NSString *path) {
    if (path.length == 0) return;
    NSLock *l = ThumbLock(); [l lock];
    [ThumbCache() removeObjectForKey:path];
    [ThumbFailed() removeObject:path];
    [l unlock];
}

void VaultThumbInvalidateAll(void) {
    NSLock *l = ThumbLock(); [l lock];
    [ThumbCache() removeAllObjects];
    [ThumbFailed() removeAllObjects];
    [l unlock];
}

void VaultThumbPruneTo(NSArray<NSString *> *keepPaths) {
    NSSet *keep = [NSSet setWithArray:keepPaths ?: @[]];
    NSLock *l = ThumbLock(); [l lock];
    for (NSString *p in [ThumbCache().allKeys copy])
        if (![keep containsObject:p]) [ThumbCache() removeObjectForKey:p];
    for (NSString *p in [ThumbFailed().allObjects copy])
        if (![keep containsObject:p]) [ThumbFailed() removeObject:p];
    [l unlock];
    // 预览缓存跟着同一份存活清单走，免得退回桌面之后还攥着大图不放
    VaultThumbPreviewPruneTo(keepPaths);
}

void VaultThumbPrefetch(NSArray<NSString *> *paths) {
    if (paths.count == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *todo = [NSMutableArray array];
    NSLock *l = ThumbLock(); [l lock];
    for (NSString *p in paths) {
        if (p.length == 0) continue;
        NSDictionary *at = [fm attributesOfItemAtPath:p error:NULL];
        if (!at) continue;
        NSTimeInterval mt = [at.fileModificationDate timeIntervalSince1970];
        VaultThumbEntry *hit = ThumbCache()[p];
        if (hit && hit.mtime == mt) continue;          // 没变，不重解码
        if ([ThumbFailed() containsObject:p]) continue;  // 解不了就不反复试
        [todo addObject:p];
    }
    [l unlock];
    if (todo.count == 0) return;

    dispatch_async(ThumbQueue(), ^{
        for (NSString *p in todo) {
            NSDictionary *at = [fm attributesOfItemAtPath:p error:NULL];
            if (!at) continue;
            NSImage *img = VaultThumbDecode(p, kThumbMaxPx);
            NSLock *ll = ThumbLock(); [ll lock];
            if (img) {
                VaultThumbEntry *e = [VaultThumbEntry new];
                e.image = img;
                e.mtime = [at.fileModificationDate timeIntervalSince1970];
                ThumbCache()[p] = e;
                [ThumbFailed() removeObject:p];
            } else {
                [ThumbFailed() addObject:p];
            }
            [ll unlock];
        }
        // 解码跑在后台，画完要把卡片换过来。通知必须切回主线程发：
        // postNotification: 是同步投递的，直接在这里发，观察者（视图的 setNeedsDisplay:）
        // 就会落在后台线程上去动 AppKit。库自己的 kVaultChanged 是主线程发的，
        // 那边没事，这里不能照抄。
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"VaultThumbnailsReady" object:nil];
        });
    });
}

void VaultDrawThumbnailIn(NSRect rect, NSImage *thumb, NSColor *tint) {
    if (!thumb) return;
    NSSize ts = thumb.size;
    if (ts.width <= 0 || ts.height <= 0) return;
    CGFloat gw = NSWidth(rect), gh = NSHeight(rect);
    // 先把 to / from 算清楚：铺满要从源图中央裁出可见那一块，只给 to 不给 from
    // 的话 drawInRect: 会直接拉伸变形
    NSRect to, from;
    if (ts.width / ts.height > kThumbWideRatio) {
        CGFloat s = MIN(gw / ts.width, gh / ts.height);
        to = NSMakeRect(NSMinX(rect) + (gw - ts.width * s) / 2.0,
                        NSMinY(rect) + (gh - ts.height * s) / 2.0, ts.width * s, ts.height * s);
        from = NSMakeRect(0, 0, ts.width, ts.height);
    } else {
        CGFloat s = MAX(gw / ts.width, gh / ts.height);
        from = NSMakeRect((ts.width - gw / s) / 2.0, (ts.height - gh / s) / 2.0, gw / s, gh / s);
        to = rect;
    }
    // 视图是翻转坐标（左上原点），NSImage 的 drawInRect: 会把图上下倒过来画。
    // 先把坐标空间翻回 y 向上再画，图才是正立的 —— 这个不处理，人物会是头朝下的。
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:0.0 yBy:NSMaxY(rect)];
    [t scaleXBy:1.0 yBy:-1.0];
    [t concat];
    [thumb drawInRect:NSMakeRect(NSMinX(to), NSMaxY(rect) - NSMaxY(to), NSWidth(to), NSHeight(to))
             fromRect:from operation:NSCompositingOperationSourceOver fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];

    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:2.5 yRadius:2.5];
    [[tint colorWithAlphaComponent:0.34] setStroke];
    box.lineWidth = 0.8;
    [box stroke];
}

#pragma mark - 悬停预览用的第二级缩略图

// 预览要铺到近 400pt 宽，2x 屏上需要 788×346px。16:9 的图按高适配是 615×346，
// 720 够用还留一点余量。
static const CGFloat kThumbPreviewMaxPx = 720.0;
// 只留 4 张：4 × 720×405×4B ≈ 4.7MB。库里图片再多，常驻占用也就这么多。
static const NSUInteger kThumbPreviewCap = 4;

static NSMutableDictionary<NSString *, VaultThumbEntry *> *PreviewCache(void) {
    static NSMutableDictionary *c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [NSMutableDictionary dictionary]; });
    return c;
}
static NSMutableSet<NSString *> *PreviewFailed(void) {
    static NSMutableSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}
// 单调递增的取用序号，淘汰时找最小的那个就是最久没用过的
static uint64_t gPreviewClock = 0;
static NSMutableDictionary<NSString *, NSNumber *> *PreviewUsed(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

NSImage *VaultThumbPreview(NSString *path) {
    if (path.length == 0) return nil;
    NSLock *l = ThumbLock(); [l lock];
    NSImage *img = PreviewCache()[path].image;
    if (img) PreviewUsed()[path] = @(++gPreviewClock);   // 读也算取用，LRU 才准
    [l unlock];
    return img;
}

void VaultThumbPreviewInvalidateAll(void) {
    NSLock *l = ThumbLock(); [l lock];
    [PreviewCache() removeAllObjects];
    [PreviewFailed() removeAllObjects];
    [PreviewUsed() removeAllObjects];
    [l unlock];
}

void VaultThumbPreviewPruneTo(NSArray<NSString *> *keepPaths) {
    NSSet *keep = [NSSet setWithArray:keepPaths ?: @[]];
    NSLock *l = ThumbLock(); [l lock];
    for (NSString *p in [PreviewCache().allKeys copy])
        if (![keep containsObject:p]) {
            [PreviewCache() removeObjectForKey:p];
            [PreviewUsed() removeObjectForKey:p];
        }
    for (NSString *p in [PreviewFailed().allObjects copy])
        if (![keep containsObject:p]) [PreviewFailed() removeObject:p];
    [l unlock];
}

void VaultThumbPreviewPrefetch(NSString *path) {
    if (path.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    {
        NSLock *l = ThumbLock(); [l lock];
        BOOL have = PreviewCache()[path] != nil;
        BOOL dead = [PreviewFailed() containsObject:path];
        [l unlock];
        if (have || dead) return;    // 有了就别重复解，解不了的也别反复试
    }
    NSDictionary *at = [fm attributesOfItemAtPath:path error:NULL];
    if (!at) return;
    NSTimeInterval mt = [at.fileModificationDate timeIntervalSince1970];

    dispatch_async(ThumbQueue(), ^{
        NSImage *img = VaultThumbDecode(path, kThumbPreviewMaxPx);
        NSLock *ll = ThumbLock(); [ll lock];
        if (img) {
            VaultThumbEntry *e = [VaultThumbEntry new];
            e.image = img;
            e.mtime = mt;
            PreviewCache()[path] = e;
            PreviewUsed()[path] = @(++gPreviewClock);
            [PreviewFailed() removeObject:path];
            // 超上限就淘汰最久没用的那张（刚放进去这张是最新的，不会被自己淘汰）
            while (PreviewCache().count > kThumbPreviewCap) {
                NSString *oldest = nil; uint64_t best = UINT64_MAX;
                for (NSString *k in PreviewUsed()) {
                    uint64_t u = [PreviewUsed()[k] unsignedLongLongValue];
                    if (u < best) { best = u; oldest = k; }
                }
                if (!oldest) break;
                [PreviewCache() removeObjectForKey:oldest];
                [PreviewUsed() removeObjectForKey:oldest];
            }
        } else {
            [PreviewFailed() addObject:path];
        }
        [ll unlock];
        // 换回主线程再发通知，理由和 VaultThumbPrefetch 里一样
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"VaultThumbnailsReady" object:nil];
        });
    });
}

void VaultDrawThumbPreviewIn(NSRect rect, NSImage *thumb, NSColor *tint) {
    if (!thumb) return;
    NSSize ts = thumb.size;
    if (ts.width <= 0 || ts.height <= 0) return;
    CGFloat gw = NSWidth(rect), gh = NSHeight(rect);
    // 整幅 contain。卡片图形位对常规图走 cover 是为了让 26pt 的小方块填满，
    // 预览反过来：它的用途就是"看清这是什么"，裁一刀就把边缘信息丢了。
    CGFloat s = MIN(gw / ts.width, gh / ts.height);
    NSRect to = NSMakeRect(NSMinX(rect) + (gw - ts.width * s) / 2.0,
                           NSMinY(rect) + (gh - ts.height * s) / 2.0, ts.width * s, ts.height * s);
    // 翻转坐标：先把空间翻回 y 向上再画，否则图是倒的
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *tf = [NSAffineTransform transform];
    [tf translateXBy:0.0 yBy:NSMaxY(rect)];
    [tf scaleXBy:1.0 yBy:-1.0];
    [tf concat];
    [thumb drawInRect:NSMakeRect(NSMinX(to), NSMaxY(rect) - NSMaxY(to), NSWidth(to), NSHeight(to))
             fromRect:NSMakeRect(0, 0, ts.width, ts.height)
            operation:NSCompositingOperationSourceOver fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
}
