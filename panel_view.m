#import "panel_view.h"
#import "backdrop.h"

const CGFloat kDeskPanelWidth  = 480.0;    // 横版：左边油价，右边两列系统指标
const CGFloat kDeskStatColW    = 118.0;    // 左列（CPU/GPU/温度/网速）值短，给窄一点

static const CGFloat kPad       = 14.0;
static const CGFloat kRadius    = 14.0;
static const CGFloat kTitleH    = 13.0;
static const CGFloat kPriceH    = 24.0;
static const CGFloat kInfoH     = 13.0;
static const CGFloat kOilW      = 150.0;   // 最宽的说明行"10月16日 24:00 · 还剩 4 天"约 133pt
static const CGFloat kEdgeGap   = 14.0;    // 文字到竖分隔线
static const CGFloat kColGap    = 16.0;
static const CGFloat kHeaderH   = 14.0;
static const CGFloat kStatRowH  = 19.0;   // 文字 15 + 底部 2px 进度条 + 间隙
static const CGFloat kBarH      = 2.0;
static const NSInteger kShortColRows = 4; // 前 4 行放左列，其余放右列：算力/网速一列，存储/网络一列


typedef struct {
    NSColor *border, *sep, *title, *primary, *label, *footer, *up, *accent, *barTrack, *glow;
} DeskPalette;

static NSColor *RGB(int r, int g, int b, double a) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

static BOOL IsDarkAppearance(NSAppearance *appearance) {
    NSString *name = appearance.name;
    return [name isEqualToString:NSAppearanceNameDarkAqua]
        || [name isEqualToString:NSAppearanceNameVibrantDark];
}

static BOOL IsDarkView(NSView *view) { return IsDarkAppearance(view.effectiveAppearance); }

// HUD 一套刻意不分成深浅两版：它是投在窗玻璃上的显示层，颜色取自壁纸里那台雷达屏的青色，
// 靠文字外发光而不是靠底板保证可读
static DeskPalette PaletteFor(DeskStyle style, BOOL dark) {
    DeskPalette p;
    if (style == DeskStyleHUD) {
        p.glow     = [NSColor colorWithWhite:0 alpha:0.75];
        p.border   = [NSColor clearColor];
        p.sep      = RGB(120, 214, 255, 0.26);
        p.title    = RGB(126, 190, 224, 1);
        p.primary  = RGB(226, 246, 255, 1);
        p.label    = RGB(140, 196, 226, 1);
        p.footer   = RGB(112, 162, 192, 1);
        p.up       = RGB(255, 122, 122, 1);
        p.accent   = RGB(112, 216, 255, 1);
        p.barTrack = RGB(120, 214, 255, 0.16);
        return p;
    }
    if (dark) {
        p.border   = [NSColor colorWithWhite:1.00 alpha:0.09];
        p.sep      = [NSColor colorWithWhite:1.00 alpha:0.11];
        p.title    = RGB(150, 184, 200, 1);
        p.primary  = RGB(244, 248, 252, 1);
        p.label    = RGB(140, 168, 192, 1);
        p.footer   = RGB(126, 154, 178, 1);
        p.up       = RGB(255, 106, 106, 1);
        p.accent   = RGB(86, 184, 250, 1);
        p.barTrack = [NSColor colorWithWhite:1.00 alpha:0.13];
    } else {
        p.border   = [NSColor colorWithWhite:0.00 alpha:0.12];
        p.sep      = [NSColor colorWithWhite:0.00 alpha:0.10];
        p.title    = RGB(64, 90, 110, 1);
        p.primary  = RGB(12, 26, 42, 1);
        p.label    = RGB(74, 98, 118, 1);
        p.footer   = RGB(96, 118, 138, 1);
        p.up       = RGB(200, 46, 46, 1);
        p.accent   = RGB(10, 119, 193, 1);
        p.barTrack = [NSColor colorWithWhite:0.00 alpha:0.12];
    }
    p.glow = nil;
    return p;
}

static NSDictionary *Attrs(NSFont *font, NSColor *color) {
    return @{NSFontAttributeName: font, NSForegroundColorAttributeName: color};
}

static CGFloat LineHeight(NSFont *font) { return font.ascender - font.descender; }

// 一层层往里叠的圆角矩形：中心叠满、边缘只叠一两层，得到没有硬边界的羽化暗角
static void DrawFeather(NSRect b, NSColor *color, double feather, double targetAlpha) {
    const int steps = 24;
    double perLayer = 1.0 - pow(1.0 - targetAlpha, 1.0 / steps);
    NSRect outer = NSInsetRect(b, -feather * 0.5, -feather * 0.5);
    for (int i = 0; i < steps; i++) {
        double t = i / (double)(steps - 1);
        NSRect r = NSInsetRect(outer, t * feather, t * feather);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r
                                                         xRadius:kRadius + feather * (1 - t)
                                                         yRadius:kRadius + feather * (1 - t)];
        [[color colorWithAlphaComponent:perLayer] setFill];
        [p fill];
    }
}

@implementation DeskPanelView

- (BOOL)isFlipped { return YES; }

+ (void)statColumnForIndex:(NSUInteger)idx count:(NSUInteger)count
                         x:(CGFloat *)x width:(CGFloat *)width {
    CGFloat divX = kPad + kOilW + kEdgeGap;
    CGFloat col0 = divX + 1.0 + kEdgeGap;
    CGFloat col1 = col0 + kDeskStatColW + kColGap;
    CGFloat right = kDeskPanelWidth - kPad;
    NSUInteger leftCount = MIN((NSUInteger)kShortColRows, count);
    BOOL inLeft = idx < leftCount;
    if (x) *x = inLeft ? col0 : col1;
    if (width) *width = (inLeft ? kDeskStatColW : right - col1);
}

+ (NSSize)sizeForModel:(DeskModel *)model {
    NSUInteger rows = model.statRows.count;
    NSUInteger leftLines = MIN((NSUInteger)kShortColRows, rows);
    NSUInteger lines = MAX(leftLines, rows - leftLines);
    CGFloat oilH = kTitleH + 3 + kPriceH + 2 + (model.infoLine.length || model.loadError.length ? kInfoH : 0);
    CGFloat statsH = rows ? kHeaderH + 3 + lines * kStatRowH : 0;
    return NSMakeSize(kDeskPanelWidth, ceil(2 * kPad + MAX(oilH, statsH)));
}

- (void)drawLabel:(NSString *)label value:(NSString *)value at:(CGFloat)y
                x:(CGFloat)x right:(CGFloat)xRight
        labelFont:(NSFont *)labelFont valueFont:(NSFont *)valueFont
       labelColor:(NSColor *)labelColor valueColor:(NSColor *)valueColor {
    NSDictionary *la = Attrs(labelFont, labelColor);
    NSDictionary *va = Attrs(valueFont, valueColor);
    [label drawAtPoint:NSMakePoint(x, y) withAttributes:la];
    CGFloat labelW = [label sizeWithAttributes:la].width;
    CGFloat avail = xRight - x - labelW - 8.0;
    CGFloat w = [value sizeWithAttributes:va].width;
    if (w > avail) {
        NSMutableDictionary *m = [va mutableCopy];
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByTruncatingMiddle;
        m[NSParagraphStyleAttributeName] = ps;
        va = m; w = avail;
    }
    [value drawInRect:NSMakeRect(xRight - w, y, w + 2, LineHeight(valueFont)) withAttributes:va];
}

- (void)drawBar:(NSRect)box fraction:(double)fraction fill:(NSColor *)fill track:(NSColor *)track {
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:box xRadius:kBarH / 2 yRadius:kBarH / 2];
    [track setFill];
    [bg fill];
    double f = MIN(MAX(fraction, 0.0), 1.0);
    if (f <= 0) return;
    NSRect knob = NSMakeRect(box.origin.x, box.origin.y, MAX(3.0, round(box.size.width * f)), box.size.height);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:knob xRadius:kBarH / 2 yRadius:kBarH / 2];
    [fill setFill];
    [path fill];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    DeskModel *m = self.model ?: [DeskModel placeholderModel];
    BOOL dark = IsDarkView(self);
    DeskPalette p = PaletteFor(self.style, dark);
    NSRect b = self.bounds;

    if (self.style == DeskStylePlate) {
        NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5)
                                                             xRadius:kRadius yRadius:kRadius];
        [p.border setStroke];
        edge.lineWidth = 1.0;
        [edge stroke];
    } else if (p.glow) {
        NSShadow *sh = [NSShadow new];
        sh.shadowColor = p.glow;
        sh.shadowBlurRadius = 7.0;
        sh.shadowOffset = CGSizeMake(0, -1.0);   // 翻转坐标下负 y 才是往下落
        [sh set];
    }

    CGFloat x = kPad;
    CGFloat top = kPad;
    CGFloat bot = NSMaxY(b) - kPad;
    NSUInteger rowCount = m.statRows.count;

    NSFont *titleFont = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    NSFont *priceFont = [NSFont monospacedDigitSystemFontOfSize:22.0 weight:NSFontWeightBold];
    NSFont *unitFont  = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    NSFont *labelFont = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    NSFont *rowFont   = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];

    // 左侧油价区：三行当成一个整体垂直居中，卡片变高也不会堆在顶上
    NSString *info = m.infoLine;
    if (m.loadError.length) {
        info = info.length ? [NSString stringWithFormat:@"%@ · %@", info, m.loadError] : m.loadError;
    }
    CGFloat groupH = kTitleH + 3 + kPriceH + 2 + (info.length ? kInfoH : 0);
    CGFloat cursor = top + roundf((bot - top - groupH) / 2.0);

    [m.title drawAtPoint:NSMakePoint(x, cursor) withAttributes:Attrs(titleFont, p.title)];
    cursor += kTitleH + 3;

    [m.price drawAtPoint:NSMakePoint(x, cursor) withAttributes:Attrs(priceFont, p.primary)];
    if (m.unit.length) {
        CGFloat priceW = [m.price sizeWithAttributes:Attrs(priceFont, p.primary)].width;
        CGFloat unitY = cursor + (priceFont.ascender - unitFont.ascender) - 3.0;
        [m.unit drawAtPoint:NSMakePoint(x + priceW + 5, unitY) withAttributes:Attrs(unitFont, p.label)];
    }
    cursor += kPriceH + 2;

    if (info.length) {
        [info drawAtPoint:NSMakePoint(x, cursor) withAttributes:Attrs(titleFont, p.label)];
    }

    if (!rowCount) return;

    CGFloat divX = kPad + kOilW + kEdgeGap;
    [p.sep setFill];
    NSRectFill(NSMakeRect(divX, top, 1.0, bot - top));

    NSUInteger leftLines = MIN((NSUInteger)kShortColRows, rowCount);
    CGFloat rowsTop = top + kHeaderH + 3;
    [m.statsHeader drawAtPoint:NSMakePoint(divX + 1.0 + kEdgeGap, top) withAttributes:Attrs(titleFont, p.title)];

    NSUInteger i = 0;
    for (DeskStatRow *row in m.statRows) {
        CGFloat cx, cw;
        [DeskPanelView statColumnForIndex:i count:rowCount x:&cx width:&cw];
        CGFloat rowY = rowsTop + (i < leftLines ? i : i - leftLines) * kStatRowH;
        CGFloat textY = rowY + (kStatRowH - kBarH - LineHeight(rowFont)) / 2.0;
        [self drawLabel:row.label value:row.value at:textY x:cx right:cx + cw
              labelFont:labelFont valueFont:rowFont labelColor:p.label valueColor:p.primary];
        if (row.fraction >= 0) {
            NSColor *fill = row.fraction > 0.85 ? p.up : p.accent;
            [self drawBar:NSMakeRect(cx, rowY + kStatRowH - kBarH - 1, cw, kBarH)
                 fraction:row.fraction fill:fill track:p.barTrack];
        }
        i++;
    }
}

@end

@implementation DeskCardView {
    DeskCardView *_source;        // 变形时的离屏素材源：先画一张正平面卡片
    NSWindow *_sourceHost;        // 脱离窗口的视图渲染朝向不确定，所以给它一个从不上屏的宿主
    NSBitmapImageRep *_flatRep;
    NSSize _cardSize;
    NSInteger _dragCorner;        // -1 = 没在拖角
    BOOL _draggingWindow;         // 用户亲手在拖窗口
    NSPoint _dragStartMouse;
    NSRect _frameAtDragStart;
}

+ (NSSize)windowSizeForModel:(DeskModel *)model style:(DeskStyle)style warped:(BOOL)warped {
    NSSize card = [DeskPanelView sizeForModel:model];
    // 变形后卡片的四角会跑到卡片矩形之外，窗口不留这一圈就会被裁掉
    return warped ? DeskWarpedWindowSize(card) : card;
}

- (instancetype)initWithModel:(DeskModel *)model style:(DeskStyle)style {
    return [self initWithModel:model style:style warped:NO];
}

- (instancetype)initWithModel:(DeskModel *)model style:(DeskStyle)style warped:(BOOL)warped {
    NSSize card = [DeskPanelView sizeForModel:model];
    NSSize win = warped ? DeskWarpedWindowSize(card) : card;
    if ((self = [super initWithFrame:NSMakeRect(0, 0, win.width, win.height)])) {
        _style = style;
        _cardSize = card;
        _dragCorner = -1;
        _panel = [[DeskPanelView alloc] initWithFrame:NSMakeRect(0, 0, card.width, card.height)];
        // 变形时面板是藏起来的（画的是投影位图），不缩放才不会一 resize 就偷偷变形
        _panel.autoresizingMask = NSViewNotSizable;
        _panel.model = model;
        _panel.style = style;
        [self addSubview:_panel];
        if (warped) [self syncWarp];
    }
    return self;
}

- (DeskQuad)currentQuad {
    return DeskQuadFromOffsets(_cardSize, _quadOffsets);
}

- (BOOL)isWarped {
    return !DeskQuadOffsetsIsZero(_quadOffsets) || _editing;
}

- (void)setQuadOffsets:(DeskQuadOffsets)offsets {
    _quadOffsets = offsets;
    [self syncWarp];
}

- (void)setEditing:(BOOL)editing {
    if (editing == _editing) return;
    _editing = editing;
    [self syncWarp];
}

// 变形和调角都走"位图投影"这一条路：面板本身画不出透视，只能先画正的去采样再 warp。
// 没变形时把面板挂回去实时绘制，文字才是原生清晰度。
- (void)syncWarp {
    BOOL warped = self.isWarped;
    _panel.hidden = warped;
    [self setNeedsDisplay:YES];
    if (!warped) { _source = nil; _sourceHost = nil; _flatRep = nil; return; }
    if (!_sourceHost) {
        NSRect inner = NSMakeRect(0, 0, _cardSize.width, _cardSize.height);
        _sourceHost = [[NSWindow alloc] initWithContentRect:inner
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered defer:NO];
        [_sourceHost setBackgroundColor:[NSColor clearColor]];
        _sourceHost.opaque = NO;
        _source = [[DeskCardView alloc] initWithModel:_panel.model style:self.style];
        _sourceHost.contentView = _source;   // 从不上屏，只当渲染素材用
        _source.autoresizingMask = NSViewNotSizable;   // 别跟着宿主窗口一起被撑开
    }
    [self refreshSource];
}

- (void)updateModel:(DeskModel *)model {
    self.panel.model = model;
    _source.panel.model = model;
    [self refreshSource];
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped { return YES; }

// 卡片要独吞所有鼠标事件：面板只是画东西的，事件落到面板上就没人处理了（鼠标事件不沿响应链上传）
- (NSView *)hitTest:(NSPoint)point { return self; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// 只有看得见的那块卡片能拖着走，变形留白处不算
- (NSRect)cardArea {
    return self.isWarped ? NSMakeRect(kDeskQuadPad, kDeskQuadPad, _cardSize.width, _cardSize.height)
                         : NSMakeRect(0, 0, _cardSize.width, _cardSize.height);
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

// 必须在没有别的视图正在绘制时调用：在别人的 drawRect 里做 cacheDisplayInRect
// 会继承那个上下文的翻转，投出来就是一张上下颠倒的卡片。
- (void)refreshSource {
    if (!self.isWarped || !_source) return;
    if (self.window) {
        // 宿主窗口只当"素材画板"用，尺寸必须始终等于卡片：一旦跟外窗一样大，
        // contentView 会被自动撑开，底板铺满而文字还留在左上角，看着就是内容缩小了。
        // 位置取外窗中心，实底卡采样壁纸时才对得上卡片背后那块。
        NSRect wf = self.window.frame;
        [_sourceHost setFrame:NSMakeRect(NSMidX(wf) - _cardSize.width / 2.0,
                                         NSMidY(wf) - _cardSize.height / 2.0,
                                         _cardSize.width, _cardSize.height)
                      display:NO];
    }
    NSRect src = NSMakeRect(0, 0, _cardSize.width, _cardSize.height);
    _source.frame = src;   // 上面 setFrame: 之后 contentView 可能已经被拉走，这里钉回来
    NSBitmapImageRep *rep = [_source bitmapImageRepForCachingDisplayInRect:src];
    [_source cacheDisplayInRect:src toBitmapImageRep:rep];
    _flatRep = rep;
}

#pragma mark - 拖四个角

- (NSPoint)canvasPointFromEvent:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    return NSMakePoint(p.x, self.bounds.size.height - p.y);   // quad 用 y 朝上，视图是翻转的
}

// 窗口拖动自己做，不用 movableByWindowBackground：这样"谁移动了窗口"是确定的 ——
// 只有 mouseDragged 是用户的手，系统切分辨率时的迁移根本不会走到这里
- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (self.editing && NSPointInRect(p, [self resetButtonRect])) {
        _quadOffsets = DeskQuadOffsetsZero();
        [self refreshSource];
        [self setNeedsDisplay:YES];
        if (self.onQuadEdit) self.onQuadEdit(_quadOffsets);
        if (self.onGeometryChange) self.onGeometryChange();
        return;
    }
    if (self.editing) {
        _dragCorner = DeskQuadHitTest(self.currentQuad, [self canvasPointFromEvent:e], 16.0);
        if (_dragCorner >= 0) return;
    }
    if (!NSPointInRect(p, [self cardArea])) return;
    _draggingWindow = YES;
    _dragStartMouse = NSEvent.mouseLocation;
    _frameAtDragStart = self.window.frame;
}

- (void)mouseDragged:(NSEvent *)e {
    if (_dragCorner >= 0) {
        DeskQuad q = self.currentQuad;
        NSPoint *pts[4] = { &q.tl, &q.tr, &q.br, &q.bl };
        *pts[_dragCorner] = [self canvasPointFromEvent:e];
        _quadOffsets = DeskQuadOffsetsClamp(DeskQuadOffsetsFromQuad(q, _cardSize), _cardSize);
        [self refreshSource];
        [self setNeedsDisplay:YES];
        if (self.onGeometryChange) self.onGeometryChange();
        return;
    }
    if (!_draggingWindow) return;
    NSPoint now = NSEvent.mouseLocation;
    NSPoint to = NSMakePoint(_frameAtDragStart.origin.x + now.x - _dragStartMouse.x,
                             _frameAtDragStart.origin.y + now.y - _dragStartMouse.y);
    [self.window setFrameOrigin:to];
    if (self.onUserMove) self.onUserMove();
}

- (void)mouseUp:(NSEvent *)e {
    BOOL wasCorner = _dragCorner >= 0, wasWindow = _draggingWindow;
    _dragCorner = -1;
    _draggingWindow = NO;
    if (!wasCorner && !wasWindow) return;
    if (wasCorner && self.onQuadEdit) self.onQuadEdit(_quadOffsets);
    if (self.onGeometryChange) self.onGeometryChange();
}

- (NSRect)resetButtonRect {
    const CGFloat w = 64, h = 22;
    CGFloat cardBottom = kDeskQuadPad + _cardSize.height;   // 翻转坐标下卡片下边缘
    return NSMakeRect(round(NSMidX(self.bounds) - w / 2),
                      round(cardBottom + (kDeskQuadPad - h) / 2.0), w, h);
}

- (void)drawHandles {
    DeskPalette p = PaletteFor(self.style, IsDarkView(self));
    DeskQuad q = self.currentQuad;
    NSPoint pts[4] = { q.tl, q.tr, q.br, q.bl };
    NSPoint viewPts[4];
    for (int i = 0; i < 4; i++) {
        viewPts[i] = NSMakePoint(pts[i].x, self.bounds.size.height - pts[i].y);
    }
    NSBezierPath *edge = [NSBezierPath bezierPath];
    [edge moveToPoint:viewPts[0]];
    for (int i = 1; i < 4; i++) [edge lineToPoint:viewPts[i]];
    [edge closePath];
    edge.lineWidth = 1.0;
    [[p.accent colorWithAlphaComponent:0.35] setStroke];
    [edge stroke];

    for (int i = 0; i < 4; i++) {
        NSRect knob = NSMakeRect(viewPts[i].x - 5, viewPts[i].y - 5, 10, 10);
        [[NSColor colorWithWhite:1.0 alpha:0.92] setFill];
        [[NSBezierPath bezierPathWithRect:knob] fill];
        [p.accent setStroke];
        NSBezierPath *ring = [NSBezierPath bezierPathWithRect:NSInsetRect(knob, -0.5, -0.5)];
        ring.lineWidth = 1.0;
        [ring stroke];
    }

    NSRect btn = [self resetButtonRect];
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:btn xRadius:btn.size.height / 2
                                                        yRadius:btn.size.height / 2];
    [[p.accent colorWithAlphaComponent:0.18] setFill];
    [pill fill];
    [[p.accent colorWithAlphaComponent:0.7] setStroke];
    pill.lineWidth = 1.0;
    [pill stroke];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: p.primary,
                            NSParagraphStyleAttributeName: ps};
    [@"重置" drawInRect:NSMakeRect(btn.origin.x, btn.origin.y + 3, btn.size.width, btn.size.height)
         withAttributes:attrs];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    BOOL dark = IsDarkView(self);
    if (self.isWarped) {
        if (!_flatRep) [self refreshSource];
        NSImage *warped = DeskQuadRender(_flatRep, b.size, self.currentQuad);
        [warped drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    } else {
        switch (self.style) {
            case DeskStylePlate: {
                NSRect sample = self.window ? self.window.frame : NSZeroRect;
                NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:b xRadius:kRadius yRadius:kRadius];
                [clip addClip];
                NSImage *bg = NSEqualRects(sample, NSZeroRect) ? nil
                            : [[DeskBackdrop shared] imageForRect:sample dark:dark];
                if (bg) {
                    [bg drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
                } else {
                    [(dark ? RGB(6, 24, 46, 0.92) : RGB(242, 246, 251, 0.94)) setFill];
                    [clip fill];
                }
                [(dark ? [NSColor colorWithWhite:0.02 alpha:0.32]
                       : [NSColor colorWithWhite:1.00 alpha:0.38]) setFill];
                [clip fill];
                break;
            }
            case DeskStyleFeather:
                DrawFeather(b, dark ? [NSColor blackColor] : [NSColor whiteColor], 40.0, dark ? 0.20 : 0.18);
                break;
            default:
                break;   // Bare / HUD：什么都不画，整块透出壁纸
        }
    }
    if (self.editing) [self drawHandles];
}

@end
