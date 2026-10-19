// 活动监视器组件实现。几何全部来自定稿的那张设计稿（432×294、四榜并列、每榜 4 名），
// 数值改动都要回 tools/verify.m 的布局断言里对一遍。
#import "monitor_view.h"
#import "vault_art.h"
#import "backdrop.h"
#import "vault_view.h"      // 借 VaultDragFrame：翻转视图 ↔ 屏幕坐标那笔账已经在那边算清并测过
#import <sys/proc_info.h>

const CGFloat kMonitorViewWidth = 432.0;
const CGFloat kMonitorViewHeight = 294.0;
const NSInteger kMonitorRowsPerQuadrant = 4;

static const CGFloat kPadX = 14.0, kPadTop = 13.0;
// 表头与榜单之间只靠留白分开（卡片面板四个档里都没有横线），所以这里不再有表头高度/间隙常量
static const CGFloat kQuadGapX = 11.0, kQuadGapY = 9.0;
static const CGFloat kQuadPadX = 8.0, kQuadPadY = 7.0;
static const CGFloat kQuadHeaderH = 15.0;
static const CGFloat kRowH = 19.0;
// 指标条照抄卡片面板：整行宽、2pt 高、贴在文字下面（panel_view.m 的 kStatRowH/kBarH 就是这套）
static const CGFloat kBarH = 2.0;
static const CGFloat kValueW = 34.0;
static const CGFloat kGridTop = 48.0;          // 顶栏 + 分隔线 + 间距之后的第一格上沿

#define MC(r, g, b, a) [NSColor colorWithSRGBRed:(r) / 255.0 green:(g) / 255.0 blue:(b) / 255.0 alpha:(a)]

// 悬停浮层自带一块固定深底（MC(4,18,36,.86)），底色不随系统外观翻，
// 所以它的墨色也必须是写死的近白 —— 这里**不该**用 DeskPaletteFor。
static NSColor *MonBubbleInk(void) { return MC(244, 248, 252, 1.0); }
static NSColor *MonMetricColor(NSInteger m) {
    switch (m) {
        case DeskMonitorMetricCPU: return MC(91, 184, 255, 1.0);
        case DeskMonitorMetricMemory: return MC(134, 224, 191, 1.0);
        case DeskMonitorMetricEnergy: return MC(255, 178, 107, 1.0);
        default: return MC(180, 164, 255, 1.0);
    }
}
static NSString *MonMetricLabel(NSInteger m) {
    switch (m) {
        case DeskMonitorMetricCPU: return @"CPU";
        case DeskMonitorMetricMemory: return @"内存";
        case DeskMonitorMetricEnergy: return @"能耗（估）";
        // 榜头是系统总速率，榜内每行是"活跃 socket 数"——每进程字节数这条路暂时接不了
        // （nettop 实测烧 146% 单核，NetworkStatistics 的 NStat* 管理器未文档化），
        // 所以这一榜的名字必须把口径写清楚，不能让人把 4 看成 4MB/s
        default: return @"网络·连接";
    }
}

// Regular 档：卡片面板的次级文字（labelFont）就是 Regular，笔画细、边缘柔
static NSFont *MonReg(CGFloat size) { return [NSFont systemFontOfSize:size weight:NSFontWeightRegular]; }
static NSFont *MonText(CGFloat size) { return [NSFont systemFontOfSize:size weight:NSFontWeightMedium]; }
static NSFont *MonSemibold(CGFloat size) { return [NSFont systemFontOfSize:size weight:NSFontWeightSemibold]; }
// 数字一律等宽，不然每两拍刷新时小数点会左右跳
static NSFont *MonNum(CGFloat size, NSFontWeight w) { return [NSFont monospacedDigitSystemFontOfSize:size weight:w]; }

// 一分钟才变一次的东西，别在 drawRect 里建 formatter（NSDateFormatter 单笔就要几十微秒）
static NSString *_monClock;
static NSTimeInterval _monClockAt;
static NSString *MonClock(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (_monClock && now - _monClockAt < 20.0) return _monClock;
    static NSDateFormatter *df;
    if (!df) { df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm"; }
    _monClock = [df stringFromDate:[NSDate date]];
    _monClockAt = now;
    return _monClock;
}

static void MonStr(NSString *s, NSPoint at, NSFont *f, NSColor *c, BOOL shadow) {
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    a[NSFontAttributeName] = f;
    a[NSForegroundColorAttributeName] = c;
    // 参数照抄卡片面板：黑 0.75、blur 7.0、翻转坐标下 -1 才是往下落
    if (shadow) {
        NSShadow *sh = [[NSShadow alloc] init];
        sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.75];
        sh.shadowOffset = NSMakeSize(0, -1.0);
        sh.shadowBlurRadius = 7.0;
        a[NSShadowAttributeName] = sh;
    }
    [s drawAtPoint:at withAttributes:a];
}
static CGFloat MonWidth(NSString *s, NSFont *f) {
    return [s sizeWithAttributes:@{NSFontAttributeName: f}].width;
}

// 指数缓动：和弹药库同一套（那边是 static，这里不为了复用去改已经测稳的文件）
static double MonEaseStep(double now, double target, double dt, double rate) {
    return now + (target - now) * MIN(1.0, dt * rate);
}
static BOOL MonEaseDone(double x, double target, double eps) { return fabs(x - target) <= eps; }

@interface DeskMonitorView () {
    // 每格 4 行 × 4 榜：存 pid 和"当前画到哪"，值本身从 _rowsByPid 现取
    pid_t _cell[4][4];
    double _cellFrac[4][4];         // 进度条当前长度 0~1
    double _cellTarget[4][4];
    NSArray<DeskProc *> *_all;
    NSRect _hover;                  // 空矩形 = 没悬停
    NSInteger _hoverMetric, _hoverRow;
    BOOL _dragging;
    NSPoint _dragStartMouse;      // 按下时鼠标的屏幕坐标
    NSRect _frameAtDragStart;     // 按下时窗口的位置
    NSRect _standInScreenRect;
    NSImage *_wallpaper;
    NSRect _wallpaperRect;
    NSDate *_wallpaperAt;
    NSTrackingArea *_track;
    DeskPalette _pal;         // 每次 drawRect 按系统外观重取，和卡片面板同一个 DeskPaletteFor
    NSString *_cellName[4][4];    // 截断在数据变更时算一次，绘制路径只贴字
    double _cellAvg[4][4];          // 12h 平均：同样只在换拍时算一次，绘制路径只读
    double _cellCov[4][4];          // 这一格里窗口内真正记录到的秒数（数据完不完整靠它）
    // 调角模式：变形时整张组件先画成正的、烘成位图，再按四角投影（和弹药库同一条路）
    DeskQuadOffsets _quadOffsets;
    BOOL _editing;
    NSInteger _dragCorner;
    DeskMonitorView *_flatSource;
    NSWindow *_flatHost;
    NSBitmapImageRep *_flatRep;
    BOOL _flatDirty;
}
@end

@implementation DeskMonitorView

- (instancetype)initWithFrame:(NSRect)f { return [self initWithRows:@[]]; }

- (instancetype)initWithRows:(NSArray<DeskProc *> *)rows {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, kMonitorViewWidth, kMonitorViewHeight)])) {
        _style = DeskStylePlate;
        _hoverMetric = _hoverRow = -1;
        _quadOffsets = DeskQuadOffsetsZero();
        _dragCorner = -1;
        [self updateRows:rows];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

// 桌面层窗口永远不是 key，用 NSTrackingActiveInKeyWindow 的话悬停根本不投递
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_track) [self removeTrackingArea:_track];
    _track = [[NSTrackingArea alloc] initWithRect:self.bounds
                                          options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited
                                                   | NSTrackingActiveAlways | NSTrackingAssumeInside
                                                   | NSTrackingEnabledDuringMouseDrag)
                                            owner:self userInfo:nil];
    [self addTrackingArea:_track];
}

// 要画就顺手把动画表叫回来：空闲时那张表是停着的，没这个钩子悬停/刷新都不会动
- (void)setNeedsDisplay:(BOOL)flag {
    [super setNeedsDisplay:flag];
    if (flag && self.onNeedFrames) self.onNeedFrames();
}

#pragma mark - 数据

- (void)updateRows:(NSArray<DeskProc *> *)rows {
    _all = rows ?: @[];
    NSMutableDictionary<NSNumber *, DeskProc *> *byPid = [NSMutableDictionary dictionary];
    for (DeskProc *p in _all) byPid[@(p.pid)] = p;

    // 四榜各取前 4：并列按 pid 稳定排，不然两个 0.0% 的进程会每拍互换位置，肉眼看着就是抖
    NSArray<DeskProc *> *lists[4];
    lists[DeskMonitorMetricCPU] = [self rank:byPid key:^double(DeskProc *p) { return p.cpu; }];
    lists[DeskMonitorMetricMemory] = [self rank:byPid key:^double(DeskProc *p) { return p.mem; }];
    lists[DeskMonitorMetricEnergy] = [self rank:byPid key:^double(DeskProc *p) { return p.energy; }];
    lists[DeskMonitorMetricNetwork] = [self rank:byPid key:^double(DeskProc *p) { return (double)p.sockets; }];

    // 名字截断要量字宽，每帧 16 行都量一遍就是肉眼可见的开销，所以只在数据变更时算一次
    for (int m = 0; m < 4; m++) {
        double peak = 1.0;
        for (DeskProc *p in lists[m]) {
            double v = [self valueOf:p metric:m];
            if (v > peak) peak = v;
        }
        for (int i = 0; i < kMonitorRowsPerQuadrant; i++) {
            if (i >= (NSInteger)lists[m].count) {
                _cell[m][i] = -1; _cellTarget[m][i] = 0;
                _cellName[m][i] = nil;
                continue;
            }
            DeskProc *p = lists[m][i];
            _cell[m][i] = p.pid;
            _cellName[m][i] = [self fitName:p.name width:[self nameWidthForMetric:m]
                                       font:MonReg(10.5)];
            _cellTarget[m][i] = MAX(0.04, MIN(1.0, [self valueOf:p metric:m] / peak));
            // 12h 平均只在换拍问一次；DeskHistMetric 和 DeskMonitorMetric 四个成员顺序一致
            _cellAvg[m][i] = 0; _cellCov[m][i] = 0;
            if (self.historyForPid) {
                double cov = 0;
                _cellAvg[m][i] = self.historyForPid(p.pid, (DeskHistMetric)m, &cov);
                _cellCov[m][i] = cov;
            }
        }
    }
    if (self.isWarped) {
        // 变形态没有"长过来"这回事：一拍一跳，顺便告诉外层位图过期了
        for (int m = 0; m < 4; m++)
            for (int r = 0; r < kMonitorRowsPerQuadrant; r++) _cellFrac[m][r] = _cellTarget[m][r];
        _flatDirty = YES;
    }
    [self setNeedsDisplay:YES];
}

- (double)valueOf:(DeskProc *)p metric:(NSInteger)m {
    switch (m) {
        case DeskMonitorMetricCPU: return MAX(0, p.cpu);
        case DeskMonitorMetricMemory: return MAX(0, p.mem);
        case DeskMonitorMetricEnergy: return MAX(0, p.energy);
        default: return MAX(0, (double)p.sockets);
    }
}

- (NSArray<DeskProc *> *)rank:(NSDictionary<NSNumber *, DeskProc *> *)byPid
                          key:(double (^)(DeskProc *))key {
    NSMutableArray<DeskProc *> *a = [NSMutableArray array];
    [byPid enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, DeskProc *p, BOOL *stop) {
        if (key(p) >= 0) [a addObject:p];
    }];
    [a sortUsingComparator:^NSComparisonResult(DeskProc *x, DeskProc *y) {
        double kx = key(x), ky = key(y);
        if (kx != ky) return kx > ky ? NSOrderedAscending : NSOrderedDescending;
        return x.pid < y.pid ? NSOrderedAscending : NSOrderedDescending;
    }];
    if ((NSInteger)a.count > kMonitorRowsPerQuadrant)
        return [a subarrayWithRange:NSMakeRange(0, (NSUInteger)kMonitorRowsPerQuadrant)];
    return a;
}

- (CGFloat)nameWidthForMetric:(NSInteger)m {
    NSRect q = [self quadRectForMetric:m];
    CGFloat rowW = NSWidth(q) - 2 * kQuadPadX;
    // 行右端固定留给数值；指标条已经挪到文字下面，不再占横向空间
    return rowW - kValueW - 6;
}

- (NSString *)fitName:(NSString *)full width:(CGFloat)w font:(NSFont *)f {
    NSString *name = full ?: @"";
    while (MonWidth(name, f) > w && name.length > 3)
        name = [[name substringToIndex:(NSInteger)name.length - 2] stringByAppendingString:@"…"];
    return name;
}

- (DeskProc *)procAtMetric:(NSInteger)m row:(NSInteger)r {
    if (m < 0 || m > 3 || r < 0 || r >= kMonitorRowsPerQuadrant) return nil;
    pid_t pid = _cell[m][r];
    if (pid <= 0) return nil;
    for (DeskProc *p in _all) if (p.pid == pid) return p;
    return nil;
}

- (pid_t)pidAtMetric:(NSInteger)m row:(NSInteger)r {
    DeskProc *p = [self procAtMetric:m row:r];
    return p ? p.pid : -1;
}

#pragma mark - 几何

- (NSRect)quadRectForMetric:(NSInteger)m {
    int col = (int)m % 2, row = (int)m / 2;
    CGFloat w = (kMonitorViewWidth - 2 * kPadX - kQuadGapX) / 2.0;
    CGFloat bodyH = kMonitorViewHeight - kGridTop - kPadTop;
    CGFloat h = (bodyH - kQuadGapY) / 2.0;
    return NSMakeRect(kPadX + col * (w + kQuadGapX),
                      kGridTop + row * (h + kQuadGapY), w, h);
}

- (NSRect)rowRectAtMetric:(NSInteger)m row:(NSInteger)r in:(NSRect)b {
    NSRect q = [self quadRectForMetric:m];
    q = NSOffsetRect(q, NSMinX(b) - (kMonitorViewWidth - NSWidth(b)) / 2.0, 0);
    CGFloat top = NSMinY(q) + kQuadPadY + kQuadHeaderH + 4.0;
    CGFloat area = NSHeight(q) - 2 * kQuadPadY - kQuadHeaderH - 4.0;
    CGFloat slot = area / (CGFloat)kMonitorRowsPerQuadrant;
    CGFloat y = top + r * slot + (slot - kRowH) * 0.5;
    return NSMakeRect(NSMinX(q) + kQuadPadX, y, NSWidth(q) - 2 * kQuadPadX, kRowH);
}

// 抄 panel_view.m:244：行底往上留 1pt 缝，条子本身 2pt，圆角取半高
+ (NSRect)barRectInRow:(NSRect)row {
    return NSMakeRect(NSMinX(row), NSMaxY(row) - kBarH - 1, NSWidth(row), kBarH);
}

+ (NSRect)nowBarRectInRow:(NSRect)row {
    return NSMakeRect(NSMinX(row), NSMaxY(row) - kBarH * 2 - 2, NSWidth(row), kBarH);
}

- (DeskPalette)paletteSnapshot {
    return DeskPaletteFor(_style, DeskViewIsDark(self));
}

- (NSInteger)hitTestRowAt:(NSPoint)p in:(NSRect)b metric:(NSInteger *)metricOut {
    for (int m = 0; m < 4; m++) {
        for (int r = 0; r < kMonitorRowsPerQuadrant; r++) {
            if (_cell[m][r] <= 0) continue;
            if (NSPointInRect(p, NSInsetRect([self rowRectAtMetric:m row:r in:b], -2, -1))) {
                if (metricOut) *metricOut = m;
                return r;
            }
        }
    }
    if (metricOut) *metricOut = -1;
    return -1;
}

- (void)applyPreviewHover:(NSInteger)metric row:(NSInteger)row {
    _hoverMetric = metric; _hoverRow = row;
    _hover = row < 0 ? NSZeroRect : [self rowRectAtMetric:metric row:row in:self.bounds];
    [self setNeedsDisplay:YES];
}

#pragma mark - 动画

- (void)tick:(double)dt {
    if (self.isWarped) return;   // 变形时整张是位图，逐帧重烘太贵，换拍数据直接跳到位
    BOOL moving = NO;
    for (int m = 0; m < 4; m++) {
        for (int r = 0; r < kMonitorRowsPerQuadrant; r++) {
            if (MonEaseDone(_cellFrac[m][r], _cellTarget[m][r], 0.004)) { _cellFrac[m][r] = _cellTarget[m][r]; continue; }
            // 两拍之间只差一两个百分点就不重播动画：榜要"活着"，但没必要为此每两拍全量重画
            _cellFrac[m][r] = MonEaseStep(_cellFrac[m][r], _cellTarget[m][r], dt, 18.0);
            moving = YES;
        }
    }
    // 只在条子真的还在长的时候标脏。悬停本身不产生动画，状态切换那一下已经画过了
    if (moving) [self setNeedsDisplay:YES];
}

- (BOOL)needsRedraw {
    if (self.isWarped) return NO;
    for (int m = 0; m < 4; m++)
        for (int r = 0; r < kMonitorRowsPerQuadrant; r++)
            if (!MonEaseDone(_cellFrac[m][r], _cellTarget[m][r], 0.004)) return YES;
    return NO;
}

- (BOOL)isDragging { return _dragging; }

#pragma mark - 壁纸采样

- (NSRect)cardScreenRect {
    NSRect base = !NSEqualRects(_standInScreenRect, NSZeroRect) ? _standInScreenRect
                 : (self.window ? self.window.frame : NSZeroRect);
    if (NSEqualRects(base, NSZeroRect) || !self.isWarped) return base;
    // 变形时窗口比卡片大 kDeskQuadPad 一圈，直接采会采到"画布外圈"的壁纸，
    // 底板和卡面对不上 —— 先按 pad 缩回真正那块卡片矩形
    return NSMakeRect(NSMinX(base) + kDeskQuadPad,
                      NSMinY(base) + (NSHeight(base) - kDeskQuadPad - kMonitorViewHeight),
                      kMonitorViewWidth, kMonitorViewHeight);
}

// 采一次 CoreImage 模糊要几十毫秒，位置没动就别重采
- (NSImage *)sampledWallpaper {
    NSRect r = [self cardScreenRect];
    if (NSEqualRects(r, NSZeroRect)) return nil;
    BOOL moved = !NSEqualRects(r, _wallpaperRect);
    NSTimeInterval age = _wallpaperAt ? [[NSDate date] timeIntervalSinceDate:_wallpaperAt] : 1e9;
    if (_wallpaper && !moved && age < 6.0) return _wallpaper;
    NSImage *img = [[DeskBackdrop shared] imageForRect:r dark:YES];
    if (!img) return _wallpaper;
    _wallpaper = img; _wallpaperRect = r; _wallpaperAt = [NSDate date];
    return _wallpaper;
}

- (void)setStandInScreenRect:(NSRect)r { _standInScreenRect = r; _wallpaperAt = nil; }

#pragma mark - 绘制

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    _pal = DeskPaletteFor(_style, DeskViewIsDark(self));
    if (self.isWarped) {
        // 正视图画不出透视：烘一张正的再投影。这条路上文字是位图，清晰度让给形状自由。
        if (!_flatRep || _flatDirty) [self refreshFlat];
        NSImage *warped = DeskQuadRender(_flatRep, b.size, self.currentQuad);
        [warped drawInRect:b fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1.0];
        if (_editing) [self drawHandles];
        return;
    }
    // 和 panel_view.m 完全对齐：PaletteFor 只给 HUD 设 glow，Plate / Feather / Bare 三档
    // 的 glow 都是 nil —— 也就是说卡片面板的"无底浮字"文字上其实一点阴影都没有。
    // 上一版我给 Bare 留了 blur 7 的软外发光（理由是壁纸亮处对比度只有 1.27:1），
    // 但用户要的就是"和卡片一样"，所以这里跟着去掉；真要在亮壁纸上看得清，
    // 该走的是 Feather 那档的羽化暗底（背景层），不是往字上叠影子。
    BOOL textShadow = (_style == DeskStyleHUD);
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:b xRadius:14.0 yRadius:14.0];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];
    [self drawPlateIn:b];
    [self drawHeaderIn:b textShadow:textShadow];
    for (int m = 0; m < 4; m++) [self drawQuadrant:m in:b textShadow:textShadow];
    [NSGraphicsContext restoreGraphicsState];

    if (_style == DeskStylePlate || _style == DeskStyleHUD) {
        NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:b xRadius:14.0 yRadius:14.0];
        edge.lineWidth = 1.0;
        [_style == DeskStyleHUD ? MC(90, 230, 255, 0.34) : MC(255, 255, 255, 0.10) setStroke];
        [edge stroke];
    }
}

- (void)drawPlateIn:(NSRect)b {
    switch (_style) {
        case DeskStylePlate:
            VaultDrawPlatePlate(b, [self sampledWallpaper], -1.0, 0.0);
            break;
        case DeskStyleFeather:
            VaultDrawPlateFeather(b);
            break;
        case DeskStyleHUD: {
            NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:b xRadius:14.0 yRadius:14.0];
            [clip addClip];
            [MC(4, 26, 50, 0.22) setFill];
            [clip fill];
            break;
        }
        case DeskStyleBare:
        default:
            break;   // 完全无底：整块透出壁纸，靠文字投影撑可读性
    }
}

- (void)drawHeaderIn:(NSRect)b textShadow:(BOOL)shadow {
    CGFloat y = kPadTop;
    NSFont *titleFont = MonSemibold(12.5);
    NSString *title = @"活动监视器";
    MonStr(title, NSMakePoint(kPadX, y), titleFont, _pal.title, shadow);
    CGFloat x = kPadX + MonWidth(title, titleFont) + 9.0;
    // 第二根条子必须在这里说明白 —— 用户反馈"看不懂那根线是什么意思"，而版面里之前
    // 没有任何地方交代过它。图例挂在表头这句后面，不额外占一行，也不动四榜的格子。
    NSString *cnt = [NSString stringWithFormat:@"你的进程 %ld 个 · 亮条=现在 淡条=12小时平均",
                     (long)_procCount];
    MonStr(cnt, NSMakePoint(x, y + 2), MonText(10.0), _pal.label, shadow);
    NSString *stamp = [NSString stringWithFormat:@"%@ 采样", MonClock() ?: @"--:--"];
    MonStr(stamp, NSMakePoint(NSMaxX(b) - kPadX - MonWidth(stamp, MonNum(10.0, NSFontWeightRegular)), y + 2),
           MonNum(10.0, NSFontWeightRegular), _pal.footer, shadow);

    // 这里原来还有一根横贯整宽的表头分隔线（p.sep）。卡片面板四个档里**任何一档都没有
    // 横线**：它只用一根竖分隔线分栏（panel_view.m 的 divX）。无底那档浮字下面横一条线，
    // 读起来就是"字底下压着一条影"，而且它是这块组件里最后一个贴在文字正下方的非文字元素，
    // 所以整根去掉，表头与榜单之间只靠留白分开。
}

- (void)drawQuadrant:(NSInteger)m in:(NSRect)b textShadow:(BOOL)shadow {
    NSRect q = [self quadRectForMetric:m];
    if (_style != DeskStyleBare && _style != DeskStyleFeather) {
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:q xRadius:9.0 yRadius:9.0];
        [MC(255, 255, 255, _style == DeskStyleHUD ? 0.02 : 0.030) setFill];
        [bg fill];
        if (_style == DeskStyleHUD) {
            bg.lineWidth = 1.0;
            [MC(90, 230, 255, 0.16) setStroke];
            [bg stroke];
        }
    }
    [self drawMetricIcon:m in:NSMakeRect(NSMinX(q) + kQuadPadX, NSMinY(q) + kQuadPadY + 2, 11, 11)];

    NSFont *lf = MonReg(10.0);
    MonStr(MonMetricLabel(m), NSMakePoint(NSMinX(q) + kQuadPadX + 16, NSMinY(q) + kQuadPadY),
           lf, _style == DeskStyleHUD ? MC(190, 240, 255, 0.82) : _pal.title, shadow);

    NSString *agg = [self aggregateFor:m];
    NSFont *af = MonNum(11.0, NSFontWeightMedium);
    MonStr(agg, NSMakePoint(NSMaxX(q) - kQuadPadX - MonWidth(agg, af), NSMinY(q) + kQuadPadY - 1),
           af, MonMetricColor(m), shadow);

    for (int r = 0; r < kMonitorRowsPerQuadrant; r++) {
        [self drawRow:m row:r in:b textShadow:shadow];
    }
}

- (NSString *)aggregateFor:(NSInteger)m {
    switch (m) {
        case DeskMonitorMetricCPU: return [NSString stringWithFormat:@"%.0f%%", MAX(0, _totalCPU)];
        case DeskMonitorMetricMemory: {
            if (_totalMemPhys <= 0) return @"—";
            return [NSString stringWithFormat:@"%.0fG/%.0fG", _totalMemUsed / 1e9, _totalMemPhys / 1e9];
        }
        case DeskMonitorMetricEnergy: return [NSString stringWithFormat:@"%.1f", MAX(0, _totalEnergy)];
        default: {
            double kb = (MAX(0, _totalNetIn) + MAX(0, _totalNetOut)) / 1024.0;
            if (kb < 1.0) return @"静默";
            if (kb < 1024.0) return [NSString stringWithFormat:@"%.0fK/s", kb];
            return [NSString stringWithFormat:@"%.1fM/s", kb / 1024.0];
        }
    }
}

- (void)drawRow:(NSInteger)m row:(NSInteger)r in:(NSRect)b textShadow:(BOOL)shadow {
    NSRect row = [self rowRectAtMetric:m row:r in:b];
    DeskProc *p = [self procAtMetric:m row:r];
    BOOL hot = (_hoverMetric == m && _hoverRow == r);

    if (hot) {
        NSBezierPath *hl = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(row, -3, -1) xRadius:5 yRadius:5];
        [MC(255, 255, 255, 0.10) setFill];
        [hl fill];
    }
    if (!p) {   // 数据不足：画淡占位，格子不能塌（铺满度是硬要求）
        MonStr(r == 0 ? @"没有更多活动" : @"", NSMakePoint(NSMinX(row), NSMinY(row) + 1),
               MonText(10.5), [_pal.label colorWithAlphaComponent:0.62], shadow);
        return;
    }

    // 指标条：整行宽、2pt 高、贴在文字下面 —— 和卡片面板 panel_view.m:244 是同一个元素。
    // 它原来是"名字右侧一段 44pt 胶囊 + 一截灰细线"，横在字旁边；压在深浅不一的壁纸上
    // 就是一团灰，用户说的"字体下面有阴影"其实是这个，不是任何一处 NSShadow。
    // 两根 2pt 条上下分开画，不重叠所以不会看混：上=现在，下=过去 12 小时平均。
    // 下面那根自带轨道，长度不足就是"长期比现在闲"，一眼读得出来。
    NSRect bar = [DeskMonitorView barRectInRow:row];            // 下：12h
    NSRect nowBar = [DeskMonitorView nowBarRectInRow:row];   // 上：现在
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:bar xRadius:kBarH / 2 yRadius:kBarH / 2];
    [_pal.barTrack setFill];
    [track fill];
    double frac = MAX(0.0, MIN(1.0, _cellFrac[m][r]));
    if (frac > 0.0) {
        NSRect knob = NSMakeRect(NSMinX(nowBar), NSMinY(nowBar),
                                 MAX(3.0, round(NSWidth(nowBar) * frac)), kBarH);
        NSBezierPath *fp = [NSBezierPath bezierPathWithRoundedRect:knob xRadius:kBarH / 2 yRadius:kBarH / 2];
        [MonMetricColor(m) setFill];
        [fp fill];
    }
    // 12h 条按"同一把尺"画：分母用现在这条的满刻度换算，两根条子才可直接比长短
    double histFrac = 0.0;
    if (_cellCov[m][r] > 0 && _cellFrac[m][r] > 0.001) {
        double live = [self valueTextScaleForMetric:m row:r];
        if (live > 0) histFrac = MAX(0.0, MIN(1.0, _cellAvg[m][r] / live));
    }
    if (histFrac > 0.0) {
        NSRect knob = NSMakeRect(NSMinX(bar), NSMinY(bar),
                                 MAX(3.0, round(NSWidth(bar) * histFrac)), kBarH);
        NSBezierPath *fp = [NSBezierPath bezierPathWithRoundedRect:knob xRadius:kBarH / 2 yRadius:kBarH / 2];
        [[MonMetricColor(m) colorWithAlphaComponent:0.45] setFill];
        [fp fill];
    }

    CGFloat nameX = NSMinX(row);
    NSString *name = _cellName[m][r];
    NSFont *nf = MonReg(10.5);
    if (name.length == 0) name = p.name;
    // 角色色照抄卡片面板 drawLabel:value:：label 走 p.label 蓝灰、value 走 p.primary 近白。
    // 之前这里名字也用近白，是因为我把"字下面有阴影"错判成字色太淡；真凶是横在字旁边那段
    // 胶囊+灰细线（已换成行底 2pt 细条）。现在按面板的信息层级对号入座：白=数据、蓝灰=标签。
    // 实机量过这块壁纸：监视器底下 p95 亮度 44，卡片底下 p95 94 —— 卡片在更亮的地方都还敢用
    // 蓝灰标签，这里更没有理由不用。
    // 文字顶对齐到行内 +2，给下面的 2pt 指标条留出 1pt 缝，和卡片面板同一套算法。
    MonStr(name, NSMakePoint(nameX, NSMinY(row) + 1), nf, _pal.label, shadow);

    NSString *val = [self valueTextFor:p metric:m];
    NSFont *vf = MonNum(11.0, NSFontWeightMedium);   // 对齐面板的 rowFont（等宽 Medium）
    MonStr(val, NSMakePoint(NSMaxX(row) - MonWidth(val, vf), NSMinY(row) + 1), vf, _pal.primary, shadow);
}

// 现在这根条子的满刻度对应的原始量值：12h 条要和它同一把尺，长短才可比
- (double)valueTextScaleForMetric:(NSInteger)m row:(NSInteger)r {
    DeskProc *p = [self procAtMetric:m row:r];
    if (!p) return 0;
    double v = [self valueOf:p metric:m];
    return v > 0 ? v / MAX(0.04, _cellTarget[m][r]) : 0;
}

- (double)historyAverageAtMetric:(NSInteger)m row:(NSInteger)r {
    if (m < 0 || m > 3 || r < 0 || r >= kMonitorRowsPerQuadrant) return 0;
    return _cellAvg[m][r];
}
- (double)historyCoveredAtMetric:(NSInteger)m row:(NSInteger)r {
    if (m < 0 || m > 3 || r < 0 || r >= kMonitorRowsPerQuadrant) return 0;
    return _cellCov[m][r];
}

- (NSString *)valueTextFor:(DeskProc *)p metric:(NSInteger)m {
    switch (m) {
        case DeskMonitorMetricCPU: return [NSString stringWithFormat:@"%.1f", p.cpu];
        case DeskMonitorMetricMemory: {
            double mb = p.mem / 1048576.0;
            return mb >= 1024.0 ? [NSString stringWithFormat:@"%.1fG", mb / 1024.0]
                                : [NSString stringWithFormat:@"%.0fM", mb];
        }
        case DeskMonitorMetricEnergy: return [NSString stringWithFormat:@"%.1f", p.energy];
        default: return [NSString stringWithFormat:@"%ld", (long)p.sockets];
    }
}

// 四个指标图标全用线条画，不引外部图形：芯片 / 两条内存 / 闪电 / 上下行
- (void)drawMetricIcon:(NSInteger)m in:(NSRect)r {
    NSColor *c = MonMetricColor(m);
    [c set];
    NSBezierPath *p = [NSBezierPath bezierPath];
    p.lineWidth = 1.3;
    switch (m) {
        case DeskMonitorMetricCPU: {
            NSRect body = NSInsetRect(r, 1.5, 1.5);
            [[NSBezierPath bezierPathWithRoundedRect:body xRadius:2 yRadius:2] stroke];
            [MC(255, 255, 255, 0.95) setFill];
            [NSBezierPath fillRect:NSMakeRect(NSMidX(r) - 1.5, NSMidY(r) - 1.5, 3, 3)];
            break;
        }
        case DeskMonitorMetricMemory:
            [NSBezierPath fillRect:NSMakeRect(NSMinX(r), NSMinY(r) + 2, NSWidth(r), 2.2)];
            [MC(134, 224, 191, 0.6) setFill];
            [NSBezierPath fillRect:NSMakeRect(NSMinX(r), NSMaxY(r) - 4.2, NSWidth(r), 2.2)];
            break;
        case DeskMonitorMetricEnergy: {
            [p moveToPoint:NSMakePoint(NSMinX(r) + 6, NSMinY(r))];
            [p lineToPoint:NSMakePoint(NSMaxX(r), NSMinY(r))];
            [p lineToPoint:NSMakePoint(NSMinX(r) + 5.6, NSMidY(r) + 1)];
            [p lineToPoint:NSMakePoint(NSMinX(r) + 8.6, NSMidY(r) + 1)];
            [p lineToPoint:NSMakePoint(NSMinX(r) + 2.4, NSMaxY(r))];
            [p lineToPoint:NSMakePoint(NSMinX(r) + 4.2, NSMidY(r))];
            [p lineToPoint:NSMakePoint(NSMinX(r) + 1, NSMidY(r))];
            [p closePath];
            [p fill];
            break;
        }
        default: {
            NSBezierPath *up = [NSBezierPath bezierPath];
            [up moveToPoint:NSMakePoint(NSMinX(r) + 1, NSMidY(r) + 1)];
            [up lineToPoint:NSMakePoint(NSMinX(r) + 4.4, NSMinY(r))];
            [up lineToPoint:NSMakePoint(NSMinX(r) + 7.8, NSMidY(r) + 1)];
            up.lineWidth = 1.4;
            [up stroke];
            NSBezierPath *dn = [NSBezierPath bezierPath];
            [dn moveToPoint:NSMakePoint(NSMinX(r) + 1, NSMidY(r) + 2)];
            [dn lineToPoint:NSMakePoint(NSMaxX(r) - 4.4, NSMaxY(r))];
            [dn lineToPoint:NSMakePoint(NSMaxX(r) - 1, NSMidY(r) + 2)];
            [MC(180, 164, 255, 0.75) set];
            [dn stroke];
            break;
        }
    }
}

#pragma mark - 调角模式

+ (NSSize)windowSizeWarped:(BOOL)warped {
    NSSize card = NSMakeSize(kMonitorViewWidth, kMonitorViewHeight);
    return warped ? DeskQuadCanvasSize(card) : card;
}

- (DeskQuadOffsets)quadOffsets { return _quadOffsets; }
- (void)setQuadOffsets:(DeskQuadOffsets)o { _quadOffsets = o; [self syncWarp]; }
- (BOOL)editing { return _editing; }
- (void)setEditing:(BOOL)e { if (e == _editing) return; _editing = e; [self syncWarp]; }

// style 必须同时转给素材源：变形态用户看到的那张就是它烘出来的，
// 漏了这一句就是"一进调角，无论选哪种外观都退回默认样式"（弹药库踩过）
- (void)setStyle:(DeskStyle)st {
    if (st == _style) return;
    _style = st;
    if (_flatSource) { _flatSource.style = st; _flatDirty = YES; }
    [self setNeedsDisplay:YES];
}

- (DeskQuad)currentQuad {
    return DeskQuadFromOffsets(NSMakeSize(kMonitorViewWidth, kMonitorViewHeight), _quadOffsets);
}
- (BOOL)isWarped { return !DeskQuadOffsetsIsZero(_quadOffsets) || _editing; }

- (void)syncWarp {
    if (!self.isWarped) {
        _flatSource = nil; _flatHost = nil; _flatRep = nil;
        [self setNeedsDisplay:YES];
        return;
    }
    if (!_flatHost) {
        NSRect inner = NSMakeRect(0, 0, kMonitorViewWidth, kMonitorViewHeight);
        _flatHost = [[NSWindow alloc] initWithContentRect:inner
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered defer:NO];
        [_flatHost setBackgroundColor:[NSColor clearColor]];
        _flatHost.opaque = NO;
        _flatSource = [[DeskMonitorView alloc] initWithFrame:inner];
        _flatSource.autoresizingMask = NSViewNotSizable;   // 别跟着宿主窗口被撑开
        _flatSource.style = _style;
        _flatHost.contentView = _flatSource;               // 从不上屏，只当渲染素材
    }
    [_flatSource setStandInScreenRect:[self cardScreenRect]];
    _flatDirty = YES;
    [self setNeedsDisplay:YES];
}

// 素材源只要"这一拍该画什么"，不要动画过程：数据、总量、榜头读数原样搬过去，
// 缓动值直接钉到目标。监视器是"只画不采"，所以搬的就是这几个口。
- (void)takeSnapshotFrom:(DeskMonitorView *)src {
    _style = src->_style;
    _totalCPU = src->_totalCPU; _totalMemUsed = src->_totalMemUsed; _totalMemPhys = src->_totalMemPhys;
    _totalEnergy = src->_totalEnergy; _totalNetIn = src->_totalNetIn; _totalNetOut = src->_totalNetOut;
    _procCount = src->_procCount;
    [self updateRows:src->_all];
    for (int m = 0; m < 4; m++)
        for (int r = 0; r < kMonitorRowsPerQuadrant; r++) { _cellAvg[m][r] = src->_cellAvg[m][r];
                                                            _cellCov[m][r] = src->_cellCov[m][r]; }
    // 必须在这里显式钉一次：updateRows: 末尾那个 snap 走的是"我自己 isWarped"，而素材源
    // 自己从没变形（它就是张正的），于是条子会停在 0 —— 实机烘出来就是只有灰轨道没进度条
    for (int m = 0; m < 4; m++)
        for (int r = 0; r < kMonitorRowsPerQuadrant; r++) _cellFrac[m][r] = _cellTarget[m][r];
}

- (void)refreshFlat {
    if (!_flatSource) return;
    [_flatSource takeSnapshotFrom:self];
    [_flatSource setStandInScreenRect:[self cardScreenRect]];
    // 宿主窗口只当"素材画板"，尺寸必须始终等于卡片本体：一旦跟外窗一样大，
    // contentView 会被自动撑开，底板铺满而内容缩在左上角
    NSRect wf = self.window.frame;
    [_flatHost setFrame:NSMakeRect(NSMidX(wf) - kMonitorViewWidth / 2.0,
                                   NSMidY(wf) - kMonitorViewHeight / 2.0,
                                   kMonitorViewWidth, kMonitorViewHeight) display:NO];
    NSRect src = NSMakeRect(0, 0, kMonitorViewWidth, kMonitorViewHeight);
    _flatSource.frame = src;
    NSBitmapImageRep *rep = [_flatSource bitmapImageRepForCachingDisplayInRect:src];
    [_flatSource cacheDisplayInRect:src toBitmapImageRep:rep];
    _flatRep = rep;
    _flatDirty = NO;
}

- (NSBitmapImageRep *)bakedFlatBitmap {
    [self syncWarp];
    [self refreshFlat];
    return _flatRep;
}

// 拖一个角：把该角挪到画布坐标 p，再夹回画布内。单独拆出来是因为真实拖拽在这台机器上
// 没法用合成事件驱动（没有辅助功能权限），这段得能被直接断言，而不是靠"看起来对"。
- (void)dragCorner:(NSInteger)corner toCanvasPoint:(NSPoint)p {
    if (corner < 0 || corner > 3) return;
    DeskQuad q = self.currentQuad;
    NSPoint *pts[4] = { &q.tl, &q.tr, &q.br, &q.bl };
    *pts[corner] = p;
    NSSize card = NSMakeSize(kMonitorViewWidth, kMonitorViewHeight);
    _quadOffsets = DeskQuadOffsetsClamp(DeskQuadOffsetsFromQuad(q, card), card);
}

- (NSPoint)canvasPointFromEvent:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    return NSMakePoint(p.x, self.bounds.size.height - p.y);   // quad 用 y 朝上
}

- (NSRect)resetButtonRect {
    const CGFloat w = 64, h = 22;
    CGFloat bottom = kDeskQuadPad + kMonitorViewHeight;   // 翻转坐标下卡片下边缘
    return NSMakeRect(round(NSMidX(self.bounds) - w / 2.0),
                      round(bottom + (kDeskQuadPad - h) / 2.0), w, h);
}

- (void)drawHandles {
    DeskQuad q = self.currentQuad;
    NSPoint pts[4] = { q.tl, q.tr, q.br, q.bl };
    NSPoint vp[4];
    for (int i = 0; i < 4; i++) vp[i] = NSMakePoint(pts[i].x, self.bounds.size.height - pts[i].y);
    NSBezierPath *edge = [NSBezierPath bezierPath];
    [edge moveToPoint:vp[0]];
    for (int i = 1; i < 4; i++) [edge lineToPoint:vp[i]];
    [edge closePath];
    edge.lineWidth = 1.0;
    [MC(90, 230, 255, 0.38) setStroke];
    [edge stroke];
    for (int i = 0; i < 4; i++) {
        NSRect knob = NSMakeRect(vp[i].x - 5, vp[i].y - 5, 10, 10);
        [[NSColor colorWithWhite:1.0 alpha:0.92] setFill];
        [[NSBezierPath bezierPathWithRect:knob] fill];
        [MC(90, 230, 255, 1.0) setStroke];
        NSBezierPath *ring = [NSBezierPath bezierPathWithRect:NSInsetRect(knob, -0.5, -0.5)];
        ring.lineWidth = 1.0;
        [ring stroke];
    }
    NSRect btn = [self resetButtonRect];
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:btn
                                                         xRadius:btn.size.height / 2
                                                        yRadius:btn.size.height / 2];
    [MC(90, 230, 255, 0.18) setFill];
    [pill fill];
    pill.lineWidth = 1.0;
    [MC(90, 230, 255, 0.5) setStroke];
    [pill stroke];
    NSDictionary *ta = @{NSFontAttributeName: MonText(10.5),
                         NSForegroundColorAttributeName: MC(190, 240, 255, 0.9)};
    NSString *lab = @"复位角点";
    NSSize ts = [lab sizeWithAttributes:ta];
    [lab drawAtPoint:NSMakePoint(NSMidX(btn) - ts.width / 2.0,
                                 NSMidY(btn) - ts.height / 2.0) withAttributes:ta];
}

// 调角时整条鼠标轨迹只用来拖角。命中测试按未变形的矩形算，所以变形态下悬停是关掉的
// （用户已确认这个取舍）—— 恢复成正的，悬停和双击看原生活动监视器都回来。
- (void)trackCornerDrag:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, [self resetButtonRect])) {
        _quadOffsets = DeskQuadOffsetsZero();
        [self syncWarp];
        if (self.onQuadEdit) self.onQuadEdit(_quadOffsets);
        if (self.onGeometryChange) self.onGeometryChange();
        return;
    }
    NSInteger corner = DeskQuadHitTest(self.currentQuad, [self canvasPointFromEvent:event], 16.0);
    if (corner < 0) return;
    _dragCorner = corner;
    NSWindow *w = self.window;
    while (YES) {
        NSEvent *e = [w nextEventMatchingMask:(NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged)
                                    untilDate:[NSDate dateWithTimeIntervalSinceNow:8.0]
                                       inMode:NSEventTrackingRunLoopMode dequeue:YES];
        if (!e) break;
        if (e.type == NSEventTypeLeftMouseDragged) {
            [self dragCorner:_dragCorner toCanvasPoint:[self canvasPointFromEvent:e]];
            _flatDirty = YES;
            [self refreshFlat];
            [self setNeedsDisplay:YES];
            if (self.onGeometryChange) self.onGeometryChange();
        } else break;
    }
    _dragCorner = -1;
    if (self.onQuadEdit) self.onQuadEdit(_quadOffsets);
    if (self.onGeometryChange) self.onGeometryChange();
}

#pragma mark - 交互

- (void)mouseMoved:(NSEvent *)event {
    if (self.isWarped) return;   // 变形时不响应悬停：见 -trackCornerDrag: 那段的说明
    [self moveHoverFromEvent:event];
}
- (void)mouseExited:(NSEvent *)event {
    if (_hoverRow >= 0) { _hoverMetric = _hoverRow = -1; _hover = NSZeroRect;
        if (self.onHover) self.onHover(-1, NSZeroRect);
        [self setNeedsDisplay:YES]; }
}

- (void)moveHoverFromEvent:(NSEvent *)event {
    NSInteger metric = -1;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self hitTestRowAt:p in:self.bounds metric:&metric];
    if (row == _hoverRow && metric == _hoverMetric) return;
    _hoverRow = row; _hoverMetric = metric;
    _hover = row < 0 ? NSZeroRect : [self rowRectAtMetric:metric row:row in:self.bounds];
    if (self.onHover) {
        pid_t pid = row < 0 ? -1 : [self pidAtMetric:metric row:row];
        self.onHover(pid, row < 0 ? NSZeroRect : [self convertRect:_hover toView:nil]);
    }
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    NSWindow *w = self.window;
    if (!w) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (_editing) { [self trackCornerDrag:event]; return; }
    NSInteger metric = -1;
    NSInteger row = [self hitTestRowAt:p in:self.bounds metric:&metric];
    if (row >= 0 && event.clickCount >= 2 && !self.isWarped) {
        // 双击 = 在原生活动监视器里看这个进程。组件只做入口，不重造一个 AM
        pid_t pid = [self pidAtMetric:metric row:row];
        NSWorkspace *ws = [NSWorkspace sharedWorkspace];
        NSURL *am = [NSURL fileURLWithPath:@"/System/Applications/Utilities/Activity Monitor.app"];
        [ws openURLs:@[am] withApplicationAtURL:am
             configuration:[NSWorkspaceOpenConfiguration configuration]
       completionHandler:^(NSRunningApplication *app, NSError *err) { if (err) return; (void)pid; }];
        if (self.onLog) self.onLog([NSString stringWithFormat:@"打开活动监视器看 pid %d", (int)pid]);
        return;
    }
    // 只记下起点，真正挪窗口交给 mouseDragged:。
    // 原来这里是在 mouseDown 里自己开一个 nextEventMatchingMask 模态循环 —— 无边框、
    // 非 key、宿主又是 LSUIElement 从不激活的窗口根本收不到那条队列里的拖拽事件，
    // 循环只能干等到 8 秒超时，用户看到的就是"拖不动"。卡片面板和弹药库都是
    // mouseDown/mouseDragged/mouseUp 三段式，跟着它们走才对。
    _dragging = YES;
    _dragStartMouse = NSEvent.mouseLocation;
    _frameAtDragStart = w.frame;
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragging) return;
    NSWindow *w = self.window;
    if (!w) return;
    [w setFrame:VaultDragFrame(_frameAtDragStart, _dragStartMouse, NSEvent.mouseLocation)
        display:YES animate:NO];
}

- (void)mouseUp:(NSEvent *)event {
    if (!_dragging) return;
    _dragging = NO;
    if (self.onUserMove) self.onUserMove();   // 只有这条路径是"用户亲手拖过"
    [self setNeedsDisplay:YES];
}

@end

#pragma mark - 悬停详情浮层

static NSString *MonUptime(long long startedAt) {
    if (startedAt <= 0) return @"—";
    double ago = [[NSDate date] timeIntervalSince1970] - (double)startedAt;
    if (ago < 90) return [NSString stringWithFormat:@"已运行 %.0f 秒", ago];
    if (ago < 5400) return [NSString stringWithFormat:@"已运行 %.0f 分钟", ago / 60.0];
    if (ago < 172800) return [NSString stringWithFormat:@"已运行 %.1f 小时", ago / 3600.0];
    return [NSString stringWithFormat:@"已运行 %.0f 天", ago / 86400.0];
}

@implementation DeskMonitorHoverView {
    NSFont *_nameFont, *_metaFont, *_labelFont, *_valueFont;
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _nameFont = MonSemibold(11.5);
        _metaFont = MonNum(9.0, NSFontWeightRegular);
        _labelFont = MonText(9.5);
        _valueFont = MonNum(11.0, NSFontWeightBold);
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:11.0 yRadius:11.0];
    [MC(4, 18, 36, 0.86) setFill];
    [bg fill];
    bg.lineWidth = 1.0;
    [MC(255, 255, 255, 0.14) setStroke];
    [bg stroke];

    CGFloat x = 10.0, y = 9.0;
    MonStr(_procName.length ? _procName : @"—", NSMakePoint(x, y), _nameFont, MonBubbleInk(), NO);
    y += 16.0;
    MonStr([NSString stringWithFormat:@"pid %d · uid %ld · %@", (int)_pid, (long)_uid,
            MonUptime(_startedAt)], NSMakePoint(x, y), _metaFont, MC(255, 255, 255, 0.55), NO);
    y += 16.0;

    struct { NSString *label; double v; NSInteger metric; NSString *text; } lines[] = {
        { @"CPU", _cpu, DeskMonitorMetricCPU, [NSString stringWithFormat:@"%.1f%%", _cpu] },
        { @"内存", _mem, DeskMonitorMetricMemory,
            _mem >= 1e9 ? [NSString stringWithFormat:@"%.1fG", _mem / 1e9]
                        : [NSString stringWithFormat:@"%.0fM", _mem / 1048576.0] },
        { @"能耗（估）", _energy, DeskMonitorMetricEnergy, [NSString stringWithFormat:@"%.1f", _energy] },
        { @"网络·连接", (double)_sockets, DeskMonitorMetricNetwork, [NSString stringWithFormat:@"%ld", (long)_sockets] },
    };
    for (int i = 0; i < 4; i++) {
        y += 6.0;
        [[NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:0] set];
        NSBezierPath *dot = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y + 2, 7, 7)
                                                            xRadius:2 yRadius:2];
        [MonMetricColor(lines[i].metric) setFill];
        [dot fill];
        MonStr(lines[i].label, NSMakePoint(x + 12, y), _labelFont, MC(255, 255, 255, 0.62), NO);
        MonStr(lines[i].text, NSMakePoint(NSMaxX(b) - 10 - MonWidth(lines[i].text, _valueFont), y - 1),
               _valueFont, MonBubbleInk(), NO);
        y += 12.0;
    }
    y += 6.0;
    NSBezierPath *sep = [NSBezierPath bezierPath];
    [sep moveToPoint:NSMakePoint(x, y)];
    [sep lineToPoint:NSMakePoint(NSMaxX(b) - x, y)];
    sep.lineWidth = 1.0;
    [MC(255, 255, 255, 0.10) setStroke];
    [sep stroke];
    y += 6.0;
    MonStr(@"双击组件 → 打开原生活动监视器", NSMakePoint(x, y), MonText(9.0),
           MC(255, 255, 255, 0.55), NO);
}

@end
