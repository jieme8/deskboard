// 活动监视器组件实现。几何来自 2026-10-22 的第二版设计稿（四榜并列、每榜 4 名）：
// 每行是「进程 / 现在 / 12h」三列，只画一根“现在”进度条；网络第三列是该进程 12h 累计字节。
// 2026-10-29 按用户要求删掉抬头和底部图例，整块只留四榜，卡高 380 → 330（行距一点没动）。
#import "monitor_view.h"
#import "sysmon.h"
#import "vault_art.h"
#import "backdrop.h"
#import "vault_view.h"      // 借 VaultDragFrame：翻转视图 ↔ 屏幕坐标那笔账已经在那边算清并测过
#import <sys/proc_info.h>

const CGFloat kMonitorViewWidth = 560.0;
const CGFloat kMonitorViewHeight = 330.0;
const CGFloat kMonitorViewCompactWidth = 272.0;
const CGFloat kMonitorViewCompactHeight = 142.0;
const NSInteger kMonitorRowsPerQuadrant = 4;

// 上下各留 14pt：原来这 14 是抬头的上边距，现在直接就是四榜的外边距
static const CGFloat kPadX = 16.0, kPadTop = 14.0, kPadBottom = 14.0;
static const CGFloat kQuadGapX = 10.0, kQuadGapY = 10.0;
static const CGFloat kQuadPadX = 10.0, kQuadPadY = 8.0;
static const CGFloat kQuadHeaderH = 28.0;   // 指标抬头 + 列名两行
static const CGFloat kRowH = 24.0;
// 只画“现在”这一根；12h 改成右侧文字列（见 kHistW），不再有第二根淡条。
static const CGFloat kBarH = 2.5;
// 行内三列：名字占剩余宽度，右边两列固定宽；12h 列不画条。
static const CGFloat kNowW = 64.0;
static const CGFloat kHistW = 64.0;
static const CGFloat kColGap = 6.0;
static const CGFloat kGridTop = kPadTop;   // 14：四榜贴卡的上内边距

// 简略模式：和系统状态卡同尺寸；12 外边距 + 8 格间距正好铺成 2×2 的 120×55 格。
static const CGFloat kCompactPad = 12.0, kCompactGap = 8.0;
static const CGFloat kCompactTilePadX = 10.0;
static const CGFloat kCompactBarH = 2.0;
static const CGFloat kCompactBarBottom = 5.0;

static NSSize MonCardSize(BOOL compact) {
    return compact ? NSMakeSize(kMonitorViewCompactWidth, kMonitorViewCompactHeight)
                   : NSMakeSize(kMonitorViewWidth, kMonitorViewHeight);
}
static CGFloat MonCompactTileWidth(void) {
    return (kMonitorViewCompactWidth - 2 * kCompactPad - kCompactGap) / 2.0;
}
static CGFloat MonCompactTileHeight(void) {
    return (kMonitorViewCompactHeight - 2 * kCompactPad - kCompactGap) / 2.0;
}
static CGFloat MonCompactContentWidth(void) {
    return MonCompactTileWidth() - 2 * kCompactTilePadX;
}

// 逻辑核数。CPU 每行原来印的是"占一个核的百分比"，现在整块改成占整机（见 valueTextFor:），
// 这个核数就是两把尺之间的换算系数。
// 定义在文件后半（悬停浮层那边），这里前置声明，好让 historyText 这个只读口能用它
static NSString *MonHistText(NSInteger metric, double avg, double covered, double energyTotal);

static NSInteger MonCoreCount(void) {
    static NSInteger cores;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cores = (NSInteger)[NSProcessInfo.processInfo activeProcessorCount];
        if (cores < 1) cores = 1;
    });
    return cores;
}

// 单核百分点 → 占整机的百分点。
// 用户原话："总的为什么会显示 173%，CPU 总量不是应该 100% 吗"。
// 之前榜头印的是"各核加起来"（12 核满载 1200%），每行印的是"占一个核"，
// 两把尺并排放着，怎么写都看不懂。现在整块统一成"占整机"，满值 100%。
static double MonCpuShare(double singleCorePct) {
    return singleCorePct / (double)MonCoreCount();
}

// 能耗是"占全部进程的比例"，不是自造单位的绝对值（见 valueTextFor:）。分母 <=0 时给 0，
// 不给 NaN —— 榜里印一个 "nan%" 就再没人信这块组件的数了。
static double MonShare(double v, double total) {
    if (total <= 0 || v <= 0) return 0;
    return MAX(0.0, MIN(100.0, v / total * 100.0));
}

// 每进程流量按十进制 K/M/G，和磁盘容量的十进制口径一致。
// 网络榜一行要塞下 ↓ 和 ↑ 两个数，所以不加 "/s"（榜头/悬停里会写清楚）。
static NSString *MonRateText(double bps) {
    if (bps < 0) return @"—";
    double m = bps / 1e6;
    if (m >= 10) return [NSString stringWithFormat:@"%.0fM", m];
    if (m >= 1) return [NSString stringWithFormat:@"%.1fM", m];
    return [NSString stringWithFormat:@"%.0fK", bps / 1e3];
}

// 12h 累计流量按字节；和速率一样用十进制，别在同一个榜单里混两套进制。
static NSString *MonBytesText(double bytes) {
    if (bytes < 0) return @"—";
    if (bytes >= 1e9) return [NSString stringWithFormat:@"%.1fG", bytes / 1e9];
    if (bytes >= 1e6) return [NSString stringWithFormat:@"%.0fM", bytes / 1e6];
    if (bytes >= 1e3) return [NSString stringWithFormat:@"%.0fK", bytes / 1e3];
    return [NSString stringWithFormat:@"%.0fB", bytes];
}

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
        // 窗口长度写在榜头上：这一榜的 CPU 都是最近 10 秒的窗口（榜头是整机滚动平均，
        // 行内是进程在同一段时间里的 CPU 时间占比）。分母「整机」由右侧读数写明。
        case DeskMonitorMetricCPU: return [NSString stringWithFormat:@"CPU %.0fs", kDeskCPUWindowSeconds];
        // 行内只放得下 G/M，单位进制在这里写全：列里所有内存数都是 1024 制的 GiB/MiB。
        case DeskMonitorMetricMemory: return @"内存 GiB";
        case DeskMonitorMetricEnergy: return @"能耗";
        // 这一榜原来印"连接数"，用户说只看到条数、看不到流量消耗。
        // 现在榜内是每进程收发速率，连接数退到悬停气泡的 pid 行里；榜头给系统总流量。
        default: return @"网络";
    }
}

// Regular 档：卡片面板的次级文字（labelFont）就是 Regular，笔画细、边缘柔
static NSFont *MonReg(CGFloat size) { return [NSFont systemFontOfSize:size weight:NSFontWeightRegular]; }
static NSFont *MonText(CGFloat size) { return [NSFont systemFontOfSize:size weight:NSFontWeightMedium]; }
static NSFont *MonSemibold(CGFloat size) { return [NSFont systemFontOfSize:size weight:NSFontWeightSemibold]; }
// 数字一律等宽，不然每两拍刷新时小数点会左右跳
static NSFont *MonNum(CGFloat size, NSFontWeight w) { return [NSFont monospacedDigitSystemFontOfSize:size weight:w]; }

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

// 简略模式的字只有 8.5~10.5pt，完整模式那层 7pt 柔影会把字缘吃掉、看起来发虚。
// 小字改用 2pt 紧影：亮壁纸上仍有压边，暗壁纸上不会糊成一团。
static void MonStrCompact(NSString *s, NSPoint at, NSFont *f, NSColor *c, BOOL shadow) {
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    a[NSFontAttributeName] = f;
    a[NSForegroundColorAttributeName] = c;
    if (shadow) {
        NSShadow *sh = [[NSShadow alloc] init];
        sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.90];
        sh.shadowOffset = NSMakeSize(0, -1.0);
        sh.shadowBlurRadius = 2.0;
        a[NSShadowAttributeName] = sh;
    }
    [s drawAtPoint:at withAttributes:a];
}

// 12h 列不再铺深色小底：用户要的是数字直接落在卡片玻璃上。
// 文字仍是近白 13pt/10.5pt，HUD/Bare 档靠原有的文字阴影保可读性。
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
    BOOL _dragLogged;            // 本次拖拽是否已经记过日志
    NSInteger _dragTraceTick;     // 拖动过程的采样计数器：每 8 帧打一条，和弹药库同一套
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
    double _cellTotal[4][4];        // 网络行专用：该进程 12h 累计字节
    double _cellCov[4][4];          // 这一格里窗口内真正记录到的秒数（数据完不完整靠它）
    double _topShare;               // 能耗榜前四名占全部进程能耗的比例（0~1），换拍算一次
    double _energyTotal;            // 全部进程能耗分之和 = 上面那个比例的分母，和 _topShare 同一次循环算出来
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

// 独立视图（预览/校验）没有窗口替它改尺寸，这里自己缩；
// 应用里窗口由 main.m 重建，contentView 会被窗口撑到正确尺寸。
- (void)setCompact:(BOOL)compact {
    if (compact == _compact) return;
    _compact = compact;
    _flatSource = nil; _flatHost = nil; _flatRep = nil;
    _hoverMetric = _hoverRow = -1;
    _hover = NSZeroRect;
    if (!self.window) {
        // 独立视图自己缩；变形态要缩到「卡片 + 四角余量」那张画布
        NSSize s = self.isWarped ? [DeskMonitorView windowSizeWarped:YES compact:compact]
                                 : MonCardSize(compact);
        self.frame = NSMakeRect(0, 0, s.width, s.height);
    }
    [self updateRows:_all];       // 名字截断宽度和简略条份额都跟尺寸有关
    if (self.isWarped) [self syncWarp];
    [self setNeedsDisplay:YES];
}

// 桌面层窗口永远不是 key，用 NSTrackingActiveInKeyWindow 的话悬停根本不投递。
// **不要加 NSTrackingEnabledDuringMouseDrag**：那是三块组件里只有监视器带过的一项，
// 它让 tracking area 在"按住拖动"期间继续收 mouseMoved —— 而 mouseMoved: 会去弹悬停浮层
// （另一块窗口 orderFrontRegardless），正好落在鼠标按下的窗口期里。日志侧的对得上：
// 监视器的 mouseDown 到得了（10:55 双击那条），而「收到拖拽事件」整份历史一次都没有。
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_track) [self removeTrackingArea:_track];
    _track = [[NSTrackingArea alloc] initWithRect:self.bounds
                                          options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited
                                                   | NSTrackingActiveAlways | NSTrackingAssumeInside)
                                            owner:self userInfo:nil];
    [self addTrackingArea:_track];
}

// 要画就顺手把动画表叫回来：空闲时那张表是停着的，没这个钩子悬停/刷新都不会动
- (void)setNeedsDisplay:(BOOL)flag {
    if (flag && _drawSuppressed) return;   // 被盖住时数据照收，只是不把帧表叫起来
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
    lists[DeskMonitorMetricNetwork] = [self rank:byPid key:^double(DeskProc *p) {
        if (p.netInRate < 0 || p.netOutRate < 0) return -1.0;
        double total = p.netInRate + p.netOutRate;
        return total > 0 ? total : -1.0;   // 没流量的进程不占网络榜
    }];

    // 前四名占比：换拍算一次。分子直接用已经排好的能耗榜，不再遍历一遍全部进程
    {
        double total = 0, top4 = 0;
        for (DeskProc *p in _all) if (p.energy > 0) total += p.energy;
        for (DeskProc *p in lists[DeskMonitorMetricEnergy]) if (p.energy > 0) top4 += p.energy;
        _topShare = total > 0 ? top4 / total : 0;
        _energyTotal = total;
    }
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
            if (_compact) {
                // 先按"值最小会缩到 8.5pt"留宽度，这样绘制时优先缩值、不急着截进程名。
                CGFloat valW = MonWidth([self valueTextFor:p metric:m], MonNum(8.5, NSFontWeightMedium));
                CGFloat nameW = MAX(12.0, MonCompactContentWidth() - valW - 4.0);
                _cellName[m][i] = [self fitName:p.name width:nameW font:MonText(10.5)];
                _cellTarget[m][i] = [self compactShareForProc:p metric:m];
            } else {
                _cellName[m][i] = [self fitName:p.name width:[self nameWidthForMetric:m]
                                           font:MonReg(10.5)];
                _cellTarget[m][i] = MAX(0.04, MIN(1.0, [self valueOf:p metric:m] / peak));
            }
            // 12h 平均只在换拍问一次；DeskHistMetric 和 DeskMonitorMetric 四个成员顺序一致
            _cellAvg[m][i] = 0; _cellTotal[m][i] = 0; _cellCov[m][i] = 0;
            if (self.historyForPid) {
                double cov = 0;
                _cellAvg[m][i] = self.historyForPid(p.pid, (DeskHistMetric)m, &cov);
                _cellCov[m][i] = cov;
            }
            if (m == DeskMonitorMetricNetwork && self.historyTotalForPid && _cellCov[m][i] > 0) {
                double tcov = 0;
                _cellTotal[m][i] = self.historyTotalForPid(p.pid, &tcov);
                if (tcov <= 0) _cellTotal[m][i] = 0;
            }
        }
    }
    // 数据每 5 秒才换一拍，条子缓动只是好看：从旧值长到新值要整卡重画几十帧，
    // 实测这是 App 常态 CPU 的大头。这里直接落到目标值，一拍只画一帧。
    for (int m = 0; m < 4; m++)
        for (int r = 0; r < kMonitorRowsPerQuadrant; r++) _cellFrac[m][r] = _cellTarget[m][r];
    if (self.isWarped) {
        // 变形态没有"长过来"这回事：一拍一跳，顺便告诉外层位图过期了
        _flatDirty = YES;
    }
    [self setNeedsDisplay:YES];
}

- (double)valueOf:(DeskProc *)p metric:(NSInteger)m {
    switch (m) {
        case DeskMonitorMetricCPU: return MAX(0, p.cpu);
        case DeskMonitorMetricMemory: return MAX(0, p.mem);
        case DeskMonitorMetricEnergy: return MAX(0, p.energy);
        default: {
            if (p.netInRate < 0 || p.netOutRate < 0) return 0;
            return MAX(0, p.netInRate + p.netOutRate);
        }
    }
}

// 简略模式只剩一行，完整模式那根"相对本榜前 4 名峰值"的尺会让每根条都顶满。
// 这里改成占榜头分母的份额：CPU 占整机、内存占物理、能耗占全部进程、网络占系统总量。
- (double)compactShareForProc:(DeskProc *)p metric:(NSInteger)m {
    double f = 0;
    switch (m) {
        case DeskMonitorMetricCPU:
            // p.cpu < 0 是首拍哨兵：未知就是 0，不拿负数画条
            if (p.cpu >= 0) f = MonCpuShare(p.cpu) / 100.0;
            break;
        case DeskMonitorMetricMemory:
            if (_totalMemPhys > 0) f = MAX(0.0, p.mem) / _totalMemPhys;
            break;
        case DeskMonitorMetricEnergy:
            if (_energyTotal > 0) f = MAX(0.0, p.energy) / _energyTotal;
            break;
        default: {
            if (_totalNetRecv < 0 || _totalNetSend < 0) break;
            double sys = _totalNetRecv + _totalNetSend;
            if (sys <= 0 || p.netInRate < 0 || p.netOutRate < 0) break;
            f = (p.netInRate + p.netOutRate) / sys;
            break;
        }
    }
    return MAX(0.0, MIN(1.0, f));
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
    if (_compact) return MAX(12.0, MonCompactContentWidth() - 56.0 - 4.0);
    NSRect q = [self quadRectForMetric:m];
    CGFloat rowW = NSWidth(q) - 2 * kQuadPadX;
    return rowW - kNowW - kHistW - 2 * kColGap;
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
    NSSize card = MonCardSize(_compact);
    CGFloat padX = _compact ? kCompactPad : kPadX;
    CGFloat padTop = _compact ? kCompactPad : kGridTop;
    CGFloat padBottom = _compact ? kCompactPad : kPadBottom;
    CGFloat gapX = _compact ? kCompactGap : kQuadGapX;
    CGFloat gapY = _compact ? kCompactGap : kQuadGapY;
    CGFloat w = _compact ? MonCompactTileWidth() : (card.width - 2 * padX - gapX) / 2.0;
    CGFloat h = _compact ? MonCompactTileHeight() : ((card.height - padTop - padBottom - gapY) / 2.0);
    return NSMakeRect(padX + col * (w + gapX), padTop + row * (h + gapY), w, h);
}

- (NSRect)tileRectAtMetric:(NSInteger)m in:(NSRect)b {
    NSRect q = [self quadRectForMetric:m];
    NSSize card = MonCardSize(_compact);
    return NSOffsetRect(q, NSMinX(b) - (card.width - NSWidth(b)) / 2.0, 0);
}

- (NSRect)rowRectAtMetric:(NSInteger)m row:(NSInteger)r in:(NSRect)b {
    if (_compact) return r == 0 ? [self tileRectAtMetric:m in:b] : NSZeroRect;
    NSRect q = [self quadRectForMetric:m];
    q = NSOffsetRect(q, NSMinX(b) - (kMonitorViewWidth - NSWidth(b)) / 2.0, 0);
    CGFloat top = NSMinY(q) + kQuadPadY + kQuadHeaderH + 4.0;
    CGFloat area = NSHeight(q) - 2 * kQuadPadY - kQuadHeaderH - 4.0;
    CGFloat slot = area / (CGFloat)kMonitorRowsPerQuadrant;
    CGFloat y = top + r * slot + (slot - kRowH) * 0.5;
    return NSMakeRect(NSMinX(q) + kQuadPadX, y, NSWidth(q) - 2 * kQuadPadX, kRowH);
}

// 条子只铺“进程 + 现在”两列，右侧 12h 列不画条。
+ (NSRect)barRectInRow:(NSRect)row {
    return NSMakeRect(NSMinX(row), NSMaxY(row) - kBarH - 2.0,
                      NSWidth(row) - kHistW - kColGap, kBarH);
}

+ (NSRect)barRectInTile:(NSRect)tile {
    return NSMakeRect(NSMinX(tile) + kCompactTilePadX,
                      NSMaxY(tile) - kCompactBarBottom - kCompactBarH,
                      NSWidth(tile) - 2 * kCompactTilePadX, kCompactBarH);
}

- (DeskPalette)paletteSnapshot {
    return DeskPaletteFor(_style, DeskViewIsDark(self));
}

- (NSInteger)hitTestRowAt:(NSPoint)p in:(NSRect)b metric:(NSInteger *)metricOut {
    if (_compact) {
        // 一格里只有一个进程，整格都是它的悬停/双击区；格只有 120×55，再去切一条细行没必要。
        for (int m = 0; m < 4; m++) {
            if (_cell[m][0] <= 0) continue;
            if (NSPointInRect(p, NSInsetRect([self tileRectAtMetric:m in:b], -2, -1))) {
                if (metricOut) *metricOut = m;
                return 0;
            }
        }
        if (metricOut) *metricOut = -1;
        return -1;
    }
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

- (double)barFractionAtMetric:(NSInteger)m row:(NSInteger)r {
    if (m < 0 || m > 3 || r < 0 || r >= kMonitorRowsPerQuadrant) return 0;
    return MAX(0.0, MIN(1.0, _cellFrac[m][r]));
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
    NSSize card = MonCardSize(_compact);
    return NSMakeRect(NSMinX(base) + kDeskQuadPad,
                      NSMinY(base) + (NSHeight(base) - kDeskQuadPad - card.height),
                      card.width, card.height);
}

// 采一次 CoreImage 模糊要几十毫秒，位置没动就别重采
- (NSImage *)sampledWallpaper {
    NSRect r = [self cardScreenRect];
    if (NSEqualRects(r, NSZeroRect)) return nil;
    BOOL moved = !NSEqualRects(r, _wallpaperRect);
    NSTimeInterval age = _wallpaperAt ? [[NSDate date] timeIntervalSinceDate:_wallpaperAt] : 1e9;
    // 壁纸是分钟级变量；一次 CoreImage 模糊几十毫秒，6 秒一采纯属白烧。
    // 位置没动就缓存 30 秒，换壁纸/换屏由 setStandInScreenRect 或重建窗口清掉。
    if (_wallpaper && !moved && age < 30.0) return _wallpaper;
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
    BOOL textShadow = (_style == DeskStyleHUD || _style == DeskStyleBare);
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:b xRadius:14.0 yRadius:14.0];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];
    [self drawPlateIn:b];
    for (int m = 0; m < 4; m++) {
        if (_compact) [self drawCompactTile:m in:b textShadow:textShadow];
        else [self drawQuadrant:m in:b textShadow:textShadow];
    }
    [NSGraphicsContext restoreGraphicsState];

    if (_style != DeskStyleBare && _style != DeskStyleHUD) {
        NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:b xRadius:14.0 yRadius:14.0];
        edge.lineWidth = 1.0;
        CGFloat edgeA = _style == DeskStyleFeather ? 0.10 : 0.16;
        [[VaultCyan() colorWithAlphaComponent:edgeA] setStroke];
        [edge stroke];
    }
    if (_style != DeskStyleHUD) VaultDrawReticle(b, 6.0, 13.0, VaultCyan(), 0.45, 1.2);
}

// 简略模式的一格：指标名 + 榜头总量 / 第 1 名 + 现在值 / 份额条。
// 不画图标、列名和 12h —— 120pt 宽塞不下；全名和 12h 走悬停气泡。
- (void)drawCompactTile:(NSInteger)m in:(NSRect)b textShadow:(BOOL)shadow {
    NSRect tile = [self tileRectAtMetric:m in:b];
    BOOL hot = (_hoverMetric == m);
    BOOL glass = (self.style == DeskStyleHUD);
    if (!glass) {
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:8 yRadius:8];
        [[VaultInk() colorWithAlphaComponent:VaultCardFillAlpha(self.style, 0, 0)] setFill];
        [bg fill];
        if (hot) {
            [[VaultCyan() colorWithAlphaComponent:0.06] setFill];
            [bg fill];
        }
        bg.lineWidth = 1.0;
        [[VaultCyan() colorWithAlphaComponent:(hot ? 0.32 : 0.15)] setStroke];
        [bg stroke];
    } else {
        // HUD 原来整格透底，白壁纸上 8.5~10.5pt 的字直接漂没了；
        // 按签到槽补一块墨底（2026-11-09，用户拿白壁纸截图报"看不清"）。
        VaultDrawInkPlate(tile, 8.0, 0.56, 0.14);
        if (hot) {
            NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:8 yRadius:8];
            [[VaultCyan() colorWithAlphaComponent:0.06] setFill];
            [bg fill];
        }
    }

    CGFloat left = NSMinX(tile) + kCompactTilePadX;
    CGFloat right = NSMaxX(tile) - kCompactTilePadX;
    CGFloat avail = right - left;

    // 榜头：指标名 + 总量。字符串和完整模式同一套，只按格宽收字号。
    NSString *label = MonMetricLabel(m);
    NSString *agg = [self aggregateFor:m];
    NSFont *lf = MonSemibold(9.0);
    NSFont *af = MonNum(9.5, NSFontWeightSemibold);
    while (af.pointSize > 8.0 && MonWidth(label, lf) + 5.0 + MonWidth(agg, af) > avail)
        af = MonNum(af.pointSize - 0.5, NSFontWeightSemibold);
    CGFloat labW = MIN(MonWidth(label, lf), MAX(18.0, avail - MonWidth(agg, af) - 5.0));
    NSString *lab = [self fitName:label width:labW font:lf];
    MonStrCompact(lab, NSMakePoint(left, NSMinY(tile) + 5.0), lf,
                  [VaultPaper() colorWithAlphaComponent:0.96], shadow);
    MonStrCompact(agg, NSMakePoint(right - MonWidth(agg, af), NSMinY(tile) + 4.0), af,
                  MonMetricColor(m), shadow);

    // 第 1 名：进程名 + 现在值。值先缩到 8.5pt，再考虑截进程名。
    DeskProc *p = [self procAtMetric:m row:0];
    CGFloat rowY = NSMinY(tile) + 22.0;
    if (!p) {
        MonStrCompact(@"没有更多活动", NSMakePoint(left, rowY + 0.5), MonText(9.5),
                      [VaultMuted() colorWithAlphaComponent:0.78], shadow);
    } else {
        NSString *val = [self valueTextFor:p metric:m];
        NSString *name = _cellName[m][0] ?: p.name;
        NSFont *nf = MonText(10.5);
        NSFont *vf = MonNum(10.5, NSFontWeightMedium);
        while (vf.pointSize > 8.5 && MonWidth(name, nf) + 4.0 + MonWidth(val, vf) > avail)
            vf = MonNum(vf.pointSize - 0.5, NSFontWeightMedium);
        CGFloat nameMax = MAX(12.0, avail - MonWidth(val, vf) - 4.0);
        name = [self fitName:name width:nameMax font:nf];
        MonStrCompact(name, NSMakePoint(left, rowY), nf,
                      [VaultPaper() colorWithAlphaComponent:0.95], shadow);
        MonStrCompact(val, NSMakePoint(right - MonWidth(val, vf), rowY), vf, VaultPaper(), shadow);
    }

    // 条长 = 该格榜头分母的份额；未知/分母为 0 只留槽。
    NSRect bar = [DeskMonitorView barRectInTile:tile];
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:bar
                                                          xRadius:kCompactBarH / 2 yRadius:kCompactBarH / 2];
    [[VaultCyan() colorWithAlphaComponent:0.14] setFill];
    [track fill];
    double frac = MAX(0.0, MIN(1.0, _cellFrac[m][0]));
    if (frac > 0.0) {
        NSRect knob = NSMakeRect(NSMinX(bar), NSMinY(bar),
                                 MAX(3.0, round(NSWidth(bar) * frac)), kCompactBarH);
        NSBezierPath *fp = [NSBezierPath bezierPathWithRoundedRect:knob
                                                           xRadius:kCompactBarH / 2 yRadius:kCompactBarH / 2];
        [MonMetricColor(m) setFill];
        [fp fill];
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
        case DeskStyleHUD:
        case DeskStyleBare:
        default:
            // 无边玻璃按用户要求不再垫玻璃底：背后完全透出壁纸，只留文字和文字投影
            break;
    }
}

- (void)drawQuadrant:(NSInteger)m in:(NSRect)b textShadow:(BOOL)shadow {
    NSRect q = [self quadRectForMetric:m];
    BOOL hot = (_hoverMetric == m);
    // 四榜各是一张弹药库卡片：深蓝薄雾 + 青描边。
    // HUD 档原来拆掉卡片只留一条顶部分隔线，白壁纸上整片字读不出来；
    // 现在按签到槽补墨底，和其余三档一样有卡片边界（2026-11-09）。
    // 左边缘原来那根 2pt 指标色刻度已按用户要求去掉（2026-10-23），别再画回来。
    BOOL glass = (self.style == DeskStyleHUD);
    if (!glass) {
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:q xRadius:9.0 yRadius:9.0];
        [[VaultInk() colorWithAlphaComponent:VaultCardFillAlpha(self.style, 0, 0)] setFill];
        [bg fill];
        bg.lineWidth = 1.0;
        [[VaultCyan() colorWithAlphaComponent:(hot ? 0.32 : 0.15)] setStroke];
        [bg stroke];
    } else {
        VaultDrawInkPlate(q, 9.0, 0.56, 0.14);
        if (hot) {
            NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:q xRadius:9.0 yRadius:9.0];
            [[VaultCyan() colorWithAlphaComponent:0.06] setFill];
            [bg fill];
        }
    }
    [self drawMetricIcon:m in:NSMakeRect(NSMinX(q) + kQuadPadX, NSMinY(q) + kQuadPadY + 2, 11, 11)];

    NSFont *lf = MonSemibold(11.0);
    MonStr(MonMetricLabel(m), NSMakePoint(NSMinX(q) + kQuadPadX + 16, NSMinY(q) + kQuadPadY),
           lf, VaultPaper(), shadow);

    NSString *agg = [self aggregateFor:m];
    NSFont *af = MonNum(10.0, NSFontWeightMedium);
    MonStr(agg, NSMakePoint(NSMaxX(q) - kQuadPadX - MonWidth(agg, af), NSMinY(q) + kQuadPadY - 1),
           af, MonMetricColor(m), shadow);

    // 列名：进程 / 现在 / 12h。网络第三列是累计，其它三榜是平均。
    NSRect r0 = [self rowRectAtMetric:m row:0 in:b];
    CGFloat histRight = NSMaxX(r0);
    CGFloat nowRight = histRight - kHistW - kColGap;
    NSFont *cf = MonNum(8.5, NSFontWeightMedium);
    NSFont *hcf = MonNum(10.5, NSFontWeightMedium);
    CGFloat colY = NSMinY(q) + kQuadPadY + 16.0;
    NSColor *colColor = [VaultPaper() colorWithAlphaComponent:0.90];
    MonStr(@"进程", NSMakePoint(NSMinX(r0), colY), cf, colColor, shadow);
    MonStr(@"现在", NSMakePoint(nowRight - MonWidth(@"现在", cf), colY), cf, colColor, shadow);
    NSString *hl = (m == DeskMonitorMetricNetwork) ? @"12h 累计" : @"12h 均";
    MonStr(hl, NSMakePoint(histRight - 5.0 - MonWidth(hl, hcf), colY + 0.5),
           hcf, [VaultPaper() colorWithAlphaComponent:0.98], shadow);

    for (int r = 0; r < kMonitorRowsPerQuadrant; r++) {
        [self drawRow:m row:r in:b textShadow:shadow];
    }
}

- (NSString *)aggregateTextForMetric:(NSInteger)m { return [self aggregateFor:m]; }
- (NSString *)metricLabelForVerify:(NSInteger)m { return MonMetricLabel(m); }
- (double)energyShareTotal { return _energyTotal; }

- (NSString *)aggregateFor:(NSInteger)m {
    switch (m) {
        case DeskMonitorMetricCPU:
            // 整机口径，满值 100% —— 用户原话是"CPU 总量不是应该 100% 吗"。
            // 之前印"全部核加起来"（12 核满载 1200%），榜头比每行大好几倍，
            // 人第一反应是"这数不对"；现在榜头和每行都是占整机的百分比，
            // 同一把尺、满值 100%，"总 ≥ 任意一行"照样成立。
            return [NSString stringWithFormat:@"整机 %.0f%%", MAX(0.0, MIN(100.0, _totalCPU))];
        case DeskMonitorMetricMemory: {
            if (_totalMemPhys <= 0) return @"—";
            // 和卡片面板、关于本机、原生活动监视器同一进制：1024³ 的 GiB。
            return [NSString stringWithFormat:@"%.1f/%.0f GiB",
                    _totalMemUsed / 1073741824.0, _totalMemPhys / 1073741824.0];
        }
        case DeskMonitorMetricEnergy:
            // 原来这里直接印 _totalEnergy —— 全部进程的 cpu + 唤醒×0.08 之和，单位是我自己
            // 造的（原生活动监视器那个数走 IOReport，这台系统的 IOKit 没导出符号拿不到）。
            // 自造单位的绝对值求和没有任何含义，用户只会问"191 是什么"。换成有界可读、
            // 且正是这一榜用途的数：前四名吃掉多少比例。
            // 分母必须写在脸上：光一个"66%"没人知道是占谁的 —— 用户原话就是
            // "能耗这块 61% 也没懂代表什么意思"。所以明写"占全部"（= 全部进程的能耗合计）。
            if (_topShare <= 0) return @"—";   // 守卫只看 _topShare：它和读数同源，别拿外部喂的 _totalEnergy 当第二套真相
            return [NSString stringWithFormat:@"前4名占全部 %.0f%%", MAX(0.0, MIN(100.0, _topShare * 100.0))];
        default:
            // 榜头原来是"共 N 条连接"，榜内是连接数 —— 用户说只看到条数、看不到流量消耗。
            // 现在榜头是整机收发速率，榜内是每进程收发速率；连接数退到悬停气泡。
            if (_totalNetRecv < 0 || _totalNetSend < 0) return @"—";
            return [NSString stringWithFormat:@"系统 ↓%@ ↑%@",
                    MonRateText(_totalNetRecv), MonRateText(_totalNetSend)];
    }
}

- (void)drawRow:(NSInteger)m row:(NSInteger)r in:(NSRect)b textShadow:(BOOL)shadow {
    NSRect row = [self rowRectAtMetric:m row:r in:b];
    DeskProc *p = [self procAtMetric:m row:r];
    BOOL hot = (_hoverMetric == m && _hoverRow == r);

    if (hot) {
        NSBezierPath *hl = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(row, -3, -1) xRadius:5 yRadius:5];
        [[VaultCyan() colorWithAlphaComponent:0.10] setFill];
        [hl fill];
        [[VaultCyanBright() colorWithAlphaComponent:0.80] setFill];
        NSRectFill(NSMakeRect(NSMinX(row), NSMinY(row) + 2.0, 2.0, NSHeight(row) - 4.0));
    }
    if (!p) {   // 数据不足：空槽用虚线占位，和弹药库的空库位一个意思；不写假数据
        NSBezierPath *empty = [NSBezierPath bezierPath];
        empty.lineWidth = 1.0;
        CGFloat dash[2] = { 3.0, 4.0 };
        [empty setLineDash:dash count:2 phase:0];
        [empty moveToPoint:NSMakePoint(NSMinX(row), NSMidY(row))];
        [empty lineToPoint:NSMakePoint(NSMaxX(row), NSMidY(row))];
        [[VaultCyan() colorWithAlphaComponent:0.10] setStroke];
        [empty stroke];
        if (r == 0) {
            MonStr(@"没有更多活动", NSMakePoint(NSMinX(row), NSMinY(row) + 1),
                   MonText(10.5), [VaultMuted() colorWithAlphaComponent:0.62], shadow);
        }
        return;
    }

    // 只画“现在”这一根：行底一条 2.5pt 的槽 + 填充。12h 改成右侧文字列，
    // 不再用第二根淡条；两根条子叠在一起正是用户说“看不清”的主要来源。
    NSRect bar = [DeskMonitorView barRectInRow:row];
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:bar
                                                          xRadius:kBarH / 2 yRadius:kBarH / 2];
    [[VaultCyan() colorWithAlphaComponent:0.14] setFill];
    [track fill];
    double frac = MAX(0.0, MIN(1.0, _cellFrac[m][r]));
    if (frac > 0.0) {
        NSRect knob = NSMakeRect(NSMinX(bar), NSMinY(bar),
                                 MAX(3.0, round(NSWidth(bar) * frac)), kBarH);
        NSBezierPath *fp = [NSBezierPath bezierPathWithRoundedRect:knob xRadius:kBarH / 2 yRadius:kBarH / 2];
        [MonMetricColor(m) setFill];
        [fp fill];
    }

    CGFloat histRight = NSMaxX(row);
    CGFloat nowRight = histRight - kHistW - kColGap;
    NSString *name = _cellName[m][r];
    if (name.length == 0) name = p.name;
    MonStr(name, NSMakePoint(NSMinX(row), NSMinY(row) + 2.0), MonReg(10.5),
           [VaultPaper() colorWithAlphaComponent:0.84], shadow);

    NSString *val = [self valueTextFor:p metric:m];
    NSFont *vf = MonNum(10.5, NSFontWeightMedium);
    MonStr(val, NSMakePoint(nowRight - MonWidth(val, vf), NSMinY(row) + 2.0),
           vf, VaultPaper(), shadow);

    NSString *hist = [self historyTextAtMetric:m row:r];
    NSFont *hf = MonNum(13.0, NSFontWeightMedium);
    MonStr(hist, NSMakePoint(histRight - 5.0 - MonWidth(hist, hf), NSMinY(row) + 1.0),
           hf, [VaultPaper() colorWithAlphaComponent:0.98], shadow);
}

- (double)historyAverageAtMetric:(NSInteger)m row:(NSInteger)r {
    if (m < 0 || m > 3 || r < 0 || r >= kMonitorRowsPerQuadrant) return 0;
    return _cellAvg[m][r];
}

- (double)historyTotalAtMetric:(NSInteger)m row:(NSInteger)r {
    if (m < 0 || m > 3 || r < 0 || r >= kMonitorRowsPerQuadrant) return 0;
    return _cellTotal[m][r];
}

- (double)historyCoveredAtMetric:(NSInteger)m row:(NSInteger)r {
    if (m < 0 || m > 3 || r < 0 || r >= kMonitorRowsPerQuadrant) return 0;
    return _cellCov[m][r];
}

// 第三列的文字：CPU/内存/能耗是平均，网络是该进程 12h 累计字节。
// 没有记录就印“—”，不拿 0 冒充“不知道”。
- (NSString *)historyTextAtMetric:(NSInteger)m row:(NSInteger)r {
    if (m < 0 || m > 3 || r < 0 || r >= kMonitorRowsPerQuadrant) return @"—";
    if (_cellCov[m][r] <= 0) return @"—";
    if (m == DeskMonitorMetricNetwork) return MonBytesText(_cellTotal[m][r]);
    double avg = _cellAvg[m][r];
    switch (m) {
        case DeskMonitorMetricCPU: {
            double share = MonCpuShare(avg);
            if (share > 0 && share < 0.05) return @"<0.1%";
            return [NSString stringWithFormat:@"%.1f%%", share];
        }
        case DeskMonitorMetricMemory:
            if (avg >= 1073741824.0) return [NSString stringWithFormat:@"%.1fG", avg / 1073741824.0];
            if (avg >= 1048576.0) return [NSString stringWithFormat:@"%.0fM", avg / 1048576.0];
            return [NSString stringWithFormat:@"%.0fK", MAX(0.0, avg) / 1024.0];
        case DeskMonitorMetricEnergy:
            if (_energyTotal <= 0) return @"—";
            return [NSString stringWithFormat:@"%.0f%%", MonShare(avg, _energyTotal)];
        default:
            return @"—";
    }
}

- (NSString *)valueTextFor:(DeskProc *)p metric:(NSInteger)m {
    switch (m) {
        // 每行也得带单位，而且必须和榜头同一把尺。
        // CPU 行原来印"占一个核的 20.2%"、榜头印"各核加起来"，两个分母并排 ——
        // 用户看不出该拿哪个当"总量"。现在两处都是占整机（满值 100%）。
        case DeskMonitorMetricCPU: {
            // -1 是"这一拍还没有上一拍可比"的哨兵（procs.m 里首拍/间隔过短就置它）。
            // 把它当成百分比印出去会得到"-1.0%"——负的百分比。未知就是未知，印"—"。
            if (p.cpu < 0) return @"—";
            double share = MonCpuShare(p.cpu);
            // 换成占整机后数值会变得很小：机器占用 0.04% 四舍五入就是 "0.0%"，
            // 那是假零（真 idle 的进程和"小到看不见"在屏上长得一样）。宁可印 "<0.1%"。
            if (share > 0 && share < 0.05) return @"<0.1%";
            return [NSString stringWithFormat:@"%.1f%%", share];
        }
        case DeskMonitorMetricMemory: {
            // 榜头是 1024³ 的 GiB，行内也必须用同一进制；单位进制写在榜头「内存 GiB」上。
            // 小于 1 MiB 的进程印 K，不把 500KB 四舍五入成假零 "0M"。
            if (p.mem >= 1073741824.0)
                return [NSString stringWithFormat:@"%.1fG", p.mem / 1073741824.0];
            if (p.mem >= 1048576.0)
                return [NSString stringWithFormat:@"%.0fM", p.mem / 1048576.0];
            return [NSString stringWithFormat:@"%.0fK", MAX(0.0, p.mem) / 1024.0];
        }
        // 能耗每行原来是裸的分（用户撞上的就是那个 "191"）—— 单位是我按
        // "CPU% + 唤醒次数×0.08" 造的，绝对值没有任何人能解读。换成占比：分母就是
        // 榜头"前4名占全部 xx%"用的同一个 _energyTotal（同一次循环算的，不留第二套真相）。
        // p.energy < 0 是哨兵：MonShare 会把负值当 0，那就是假零 —— 印"—"。
        case DeskMonitorMetricEnergy: return p.energy < 0 ? @"—"
            : [NSString stringWithFormat:@"%.0f%%", MonShare(p.energy, _energyTotal)];
        // 行内现在是每进程收发速率；连接数在悬停气泡的 pid 行里。
        default: {
            if (p.netInRate < 0 || p.netOutRate < 0) return @"—";
            return [NSString stringWithFormat:@"↓%@ ↑%@",
                    MonRateText(p.netInRate), MonRateText(p.netOutRate)];
        }
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

+ (NSSize)cardSizeCompact:(BOOL)compact { return MonCardSize(compact); }

+ (NSSize)windowSizeWarped:(BOOL)warped {
    return [self windowSizeWarped:warped compact:NO];
}

+ (NSSize)windowSizeWarped:(BOOL)warped compact:(BOOL)compact {
    NSSize card = MonCardSize(compact);
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
    return DeskQuadFromOffsets(MonCardSize(_compact), _quadOffsets);
}
- (BOOL)isWarped { return !DeskQuadOffsetsIsZero(_quadOffsets) || _editing; }

- (void)syncWarp {
    if (!self.isWarped) {
        _flatSource = nil; _flatHost = nil; _flatRep = nil;
        [self setNeedsDisplay:YES];
        return;
    }
    if (!_flatHost) {
        NSRect inner = NSMakeRect(0, 0, MonCardSize(_compact).width, MonCardSize(_compact).height);
        _flatHost = [[NSWindow alloc] initWithContentRect:inner
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered defer:NO];
        [_flatHost setBackgroundColor:[NSColor clearColor]];
        _flatHost.opaque = NO;
        _flatSource = [[DeskMonitorView alloc] initWithFrame:inner];
        _flatSource.compact = _compact;
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
    _totalEnergy = src->_totalEnergy;
    // 能耗分母不在这份清单里，是故意的：下面那句 updateRows: 会拿 src->_all 重算一遍
    // _energyTotal / _topShare，再显式搬一次就是给同一个数留第二个来源。
    // 负向对照量过：把 `_energyTotal = src->_energyTotal` 加回来再删掉，215 条断言一条不动。
    [self updateRows:src->_all];
    for (int m = 0; m < 4; m++)
        for (int r = 0; r < kMonitorRowsPerQuadrant; r++) { _cellAvg[m][r] = src->_cellAvg[m][r];
                                                            _cellCov[m][r] = src->_cellCov[m][r]; }
    for (int m = 0; m < 4; m++)
        for (int r = 0; r < kMonitorRowsPerQuadrant; r++) _cellTotal[m][r] = src->_cellTotal[m][r];
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
    NSSize card = MonCardSize(_compact);
    [_flatHost setFrame:NSMakeRect(NSMidX(wf) - card.width / 2.0,
                                   NSMidY(wf) - card.height / 2.0,
                                   card.width, card.height) display:NO];
    NSRect src = NSMakeRect(0, 0, card.width, card.height);
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

- (DeskMonitorView *)flatSourceForVerify {
    [self syncWarp];
    [self refreshFlat];
    return _flatSource;
}

// 拖一个角：把该角挪到画布坐标 p，再夹回画布内。单独拆出来是因为真实拖拽在这台机器上
// 没法用合成事件驱动（没有辅助功能权限），这段得能被直接断言，而不是靠"看起来对"。
- (void)dragCorner:(NSInteger)corner toCanvasPoint:(NSPoint)p {
    if (corner < 0 || corner > 3) return;
    DeskQuad q = self.currentQuad;
    NSPoint *pts[4] = { &q.tl, &q.tr, &q.br, &q.bl };
    *pts[corner] = p;
    NSSize card = MonCardSize(_compact);
    _quadOffsets = DeskQuadOffsetsClamp(DeskQuadOffsetsFromQuad(q, card), card);
}

- (NSPoint)canvasPointFromEvent:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    return NSMakePoint(p.x, self.bounds.size.height - p.y);   // quad 用 y 朝上
}

- (NSRect)resetButtonRect {
    const CGFloat w = 64, h = 22;
    CGFloat bottom = kDeskQuadPad + MonCardSize(_compact).height;   // 翻转坐标下卡片下边缘
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
// 返回值 = 这一帧归不归调角。没命中角点也没命中复位按钮就交回窗口拖动，和卡片面板
// panel_view.m:334、弹药库 vault_view.m:1415 是同一套写法。原来这里在 _editing 下无条件
// return，一进调角模式整块组件就拖不动 —— 这是个真 bug，但**不是用户报"拖不动"的已证原因**：
// 日志里从来没有一条活动监视器的调角开关，他没进过这个模式。别把它写成"已找到根因"。
- (BOOL)trackCornerDrag:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, [self resetButtonRect])) {
        _quadOffsets = DeskQuadOffsetsZero();
        [self syncWarp];
        if (self.onQuadEdit) self.onQuadEdit(_quadOffsets);
        if (self.onGeometryChange) self.onGeometryChange();
        return YES;
    }
    // 只记角号，位移交给 mouseDragged:、提交交给 mouseUp:。
    // 原来这里也开着一个 8 秒模态循环，和窗口拖那处是同一个写法，一起统一掉。
    _dragCorner = DeskQuadHitTest(self.currentQuad, [self canvasPointFromEvent:event], 16.0);
    return _dragCorner >= 0;
}

#pragma mark - 交互

- (void)mouseMoved:(NSEvent *)event {
    if (self.isWarped) return;   // 变形时不响应悬停：见 -trackCornerDrag: 那段的说明
    // 按住拖动期间不许弹悬停浮层：那是在鼠标按下时把**另一块窗口**顶上来，
    // 拖拽会话正归本窗口所有，这时候动别的窗口没有道理，也正是上面那条 tracking area
    // 注释里被怀疑的行为。松手后鼠标再动一下就恢复正常悬停。
    if (_dragging || _dragCorner >= 0) return;
    [self moveHoverFromEvent:event];
}
- (void)mouseExited:(NSEvent *)event {
    if (_hoverRow >= 0) { _hoverMetric = _hoverRow = -1; _hover = NSZeroRect;
        if (self.onHover) self.onHover(-1, NSZeroRect, -1, 0, 0);
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
        self.onHover(pid, row < 0 ? NSZeroRect : [self convertRect:_hover toView:nil],
                     metric, row < 0 ? 0 : _cellAvg[metric][row], row < 0 ? 0 : _cellCov[metric][row]);
    }
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    NSWindow *w = self.window;
    if (!w) return;
    // 这条日志是"拖不动"的唯一判据，所以必须打在**任何提前 return 之前**：
    // 有这行 = 事件送到了视图，问题在算法；没这行 = 事件根本没到，问题在层序/吃点击的窗口。
    // 我这侧没有辅助功能权限，动不了真光标，只能靠这一行把两种情况分开。
    if (self.onLog) {
        // App 活不活、这块窗口是不是 key，是"拖拽事件送不送得到"最可能的开关：
        // 卡片/弹药库拖得动而监视器拖不动，静态属性已经全部比对过是一样的，
        // 那就只剩"点它那一刻的状态"不同。这一行把那个状态也记下来。
        self.onLog([NSString stringWithFormat:@"按下：调角=%d 变形=%d 双击=%ld App激活=%d 本窗key=%d 窗原点(%.0f,%.0f)",
                    _editing, self.isWarped, (long)event.clickCount,
                    [NSApp isActive], w.isKeyWindow,
                    w.frame.origin.x, w.frame.origin.y]);
    }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (_editing && [self trackCornerDrag:event]) return;
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
    // 三段式和卡片面板/弹药库一致（那两块能拖，是现成先例）。
    // 但"拖不动"的根因到现在**都还没有被证实过**，三条嫌疑全被我自己证伪或削弱了：
    // ① 模态循环：装回旧写法跑合成事件，计时断言照样 0.000s 通过，抓不到；
    // ② 遮挡：tools/probe_clickcatcher.m 量到三块组件被同一批窗口（Dock 的 layer=20 全屏窗
    //    + 远程桌面的 INT32 覆盖层）100% 压着，而卡片和弹药库照样拖得动 —— 覆盖相等不是差别；
    // ③ 调角模式里 mouseDown 无条件 return：那是个真 bug（已修），但日志里从来没有一条
    //    活动监视器的调角开关，用户没进过那个模式。
    // 三段式和卡片面板/弹药库一致（那两块能拖，是现成先例）：mouseDown 只登记起点，
    // 挪窗一律发生在 mouseDragged: 里，由我们自己按 [NSEvent mouseLocation] 算。
    // 这里**不再**调用 performWindowDragWithEvent: ——全项目只有本视图调过它，而那两块
    // 不调、照样拖得动（不对称检验通过的唯一候选）。它会就地跑 AppKit 自己的事件会话，
    // 把 mouseDragged 从我们视图里吞掉；而桌面图标层的非 key 窗它又搬不动，
    // 两头同时落空，表现就是"按住一点动静都没有"。
    if (self.locked) return;   // 全局锁定：按下照样记日志、双击照样开 AM，只是不挪窗
    _dragging = YES;
    _dragLogged = NO;
    _dragStartMouse = NSEvent.mouseLocation;
    _frameAtDragStart = w.frame;
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    if (_dragCorner >= 0) {
        [self dragCorner:_dragCorner toCanvasPoint:[self canvasPointFromEvent:event]];
        _flatDirty = YES;
        [self refreshFlat];
        [self setNeedsDisplay:YES];
        if (self.onGeometryChange) self.onGeometryChange();
        return;
    }
    if (!_dragging) return;
    // 只记第一次拖拽事件：这台机器没有辅助功能权限、我没法自己拖，所以留一条证据链 ——
    // 万一还是拖不动，日志能立刻区分"事件根本没送到视图"和"送到了但算错了"
    if (!_dragLogged) {
        _dragLogged = YES;
        if (self.onLog) self.onLog([NSString stringWithFormat:@"收到拖拽事件，开始挪窗"]);
    }
    NSPoint now = NSEvent.mouseLocation;
    [self dragWindowToMouse:now];
    // 弹药库靠这条 trace 把"拖得动"量成了事实（日志里 71 条，光标和窗口原点对得上）。
    // 监视器一条都没有过 —— 补上，用户试一次就能看出断在哪一环：
    // 有"按下"没"收到拖拽" = 拖拽事件根本没到；有"拖动中"但窗口原点不动 = 算错了；
    // 原点跟着动了但"松手"后回到原位 = 摆位被别处重新应用了一次。
    if (++_dragTraceTick % 8 == 0 && self.onLog) {
        NSRect f = self.window.frame;
        self.onLog([NSString stringWithFormat:@"拖动中 光标(%.0f,%.0f) 窗口原点(%.0f,%.0f)",
                    now.x, now.y, f.origin.x, f.origin.y]);
    }
}

- (void)dragWindowToMouse:(NSPoint)mouseNow {
    NSWindow *w = self.window;
    if (!w) return;
    // 原来这里用 `setFrame:display:animate:NO` —— 三块组件里只有它用这个带 animate 的版本：
    // 卡片是 `setFrameOrigin:`（panel_view.m:360），弹药库是 `setFrame:display:`（vault_view.m:1491），
    // 那两块真鼠标下都拖得动（弹药库日志里 71 条「拖动中」逐帧跟得上光标）。
    // animate: 那一版走的是"帧变更事务"路径：一次变更还在飞行中时，后续调用会被合并/忽略，
    // 而拖动正是每秒几十次的连续调用 —— 单次调用我的断言照样过，只有真鼠标的连续流才暴露它。
    // 这是代码里剩下的最后一处不对称，所以先对齐到能用的先例上。
    // **别把它写成"已证根因"**：负向对照量过，把这一行换回 `setFrame:display:animate:NO`，
    // 216 条断言一条都不动 —— 校验 CLI 里没有真窗口服务器事务，这条差异只有真鼠标能判。
    // 判据在日志里：拖动过程有没有「拖动中 光标… 窗口原点…」，原点跟不跟得上光标。
    [w setFrameOrigin:VaultDragFrame(_frameAtDragStart, _dragStartMouse, mouseNow).origin];
}

- (void)mouseUp:(NSEvent *)event {
    if (_dragCorner >= 0) {
        _dragCorner = -1;
        if (self.onQuadEdit) self.onQuadEdit(_quadOffsets);      // 松手才落盘，拖的过程中不写
        if (self.onGeometryChange) self.onGeometryChange();
        return;
    }
    if (!_dragging) return;
    _dragging = NO;
    if (self.onUserMove) self.onUserMove();   // 只有这条路径是"用户亲手拖过"
    if (self.onLog) {
        NSRect f = self.window.frame;
        self.onLog([NSString stringWithFormat:@"松手 位移(%+.0f,%+.0f) 拖了 %ld 帧 窗口原点(%.0f,%.0f)",
                    f.origin.x - _frameAtDragStart.origin.x,
                    f.origin.y - _frameAtDragStart.origin.y,
                    (long)_dragTraceTick, f.origin.x, f.origin.y]);
    }
    [self setNeedsDisplay:YES];
}

@end

#pragma mark - 悬停详情浮层

const NSSize kDeskMonitorHoverSize = { 240.0, 192.0 };

static NSString *MonUptime(long long startedAt) {
    if (startedAt <= 0) return @"—";
    double ago = [[NSDate date] timeIntervalSince1970] - (double)startedAt;
    if (ago < 90) return [NSString stringWithFormat:@"已运行 %.0f 秒", ago];
    if (ago < 5400) return [NSString stringWithFormat:@"已运行 %.0f 分钟", ago / 60.0];
    if (ago < 172800) return [NSString stringWithFormat:@"已运行 %.1f 小时", ago / 3600.0];
    return [NSString stringWithFormat:@"已运行 %.0f 天", ago / 86400.0];
}

// 多行文字（介绍、出处）都要用到；单行 MonStr 不够。
static void MonPara(NSString *s, NSRect r, NSFont *f, NSColor *c, NSLineBreakMode mode) {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = mode;
    [s drawWithRect:r
            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
         attributes:@{NSFontAttributeName: f,
                      NSForegroundColorAttributeName: c,
                      NSParagraphStyleAttributeName: ps}];
}

static CGFloat MonLineHeight(NSFont *f) {
    return ceil(f.ascender - f.descender + f.leading);
}

@implementation DeskMonitorHoverView {
    NSFont *_nameFont, *_metaFont, *_labelFont, *_valueFont, *_introFont, *_originFont;
}

- (NSString *)historyText {
    return MonHistText(_histMetric, _histAvg, _histCovered, self.energyTotal);
}

- (NSString *)historyFoot {
    if (_histMetric == DeskMonitorMetricNetwork) {
        if (_histTotal >= 0) {
            return [NSString stringWithFormat:@"12h 累计 %@ · 双击看原生活动监视器",
                                              MonBytesText(_histTotal)];
        }
        return @"流量=当前收发速率 · 连接数见上行 · 双击看原生活动监视器";
    }
    return _histCovered > 0 && _histCovered < kDeskHistoryWindow * 0.98
        ? [NSString stringWithFormat:@"12h 平均基于已记录的 %.1f 小时 · 双击看原生活动监视器",
                                      _histCovered / 3600.0]
        : @"12h 平均 = 过去 12 小时 · 双击看原生活动监视器";
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _nameFont = MonSemibold(11.5);
        _metaFont = MonNum(9.0, NSFontWeightRegular);
        _labelFont = MonText(9.5);
        _valueFont = MonNum(11.0, NSFontWeightBold);
        // 介绍是要读的正文，字号不能跟着 pid 那行一起缩；出处只是补充，才用 8.5。
        _introFont = MonText(9.5);
        _originFont = MonReg(8.5);
        _histTotal = -1;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSInteger)introLineCount {
    if (!_intro.length) return 0;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByWordWrapping;
    CGFloat w = NSWidth(self.bounds) - 20.0;
    if (w <= 0) return 1;
    NSRect r = [_intro boundingRectWithSize:NSMakeSize(w, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin
                                 attributes:@{NSFontAttributeName: _introFont,
                                              NSParagraphStyleAttributeName: ps}];
    CGFloat lh = MonLineHeight(_introFont);
    NSInteger n = lh > 0 ? (NSInteger)llround(r.size.height / lh) : 1;
    return MIN(2, MAX(1, n));
}

// 12h 读数必须和这一行的即时值同一单位，否则并排放着还是看不懂
static NSString *MonHistText(NSInteger metric, double avg, double covered, double energyTotal) {
    if (covered <= 0) return nil;
    switch (metric) {
        // 12h 平均必须和这一行当前值同一把尺，否则并排放着还是看不懂。
        // CPU 存的是单核百分点，屏上现在统一印占整机，这里跟着换算。
        case DeskMonitorMetricCPU: return [NSString stringWithFormat:@"12h %.1f%%", MonCpuShare(avg)];
        case DeskMonitorMetricMemory: {
            // 和行内、榜头同一进制（1024³）。单位写全，悬停里的 12h 值和当前值才是一把尺。
            if (avg >= 1073741824.0)
                return [NSString stringWithFormat:@"12h %.1f GiB", avg / 1073741824.0];
            if (avg >= 1048576.0)
                return [NSString stringWithFormat:@"12h %.0f MiB", avg / 1048576.0];
            return [NSString stringWithFormat:@"12h %.0f KiB", MAX(0.0, avg) / 1024.0];
        }
        case DeskMonitorMetricEnergy:
            // 分母没喂进来就宁可空着：印个 "12h 0%" 是假数据，比不印更糟
            if (energyTotal <= 0) return nil;
            return [NSString stringWithFormat:@"12h %.0f%%", MonShare(avg, energyTotal)];
        case DeskMonitorMetricNetwork: return [NSString stringWithFormat:@"12h %@/s", MonRateText(avg)];
        default: return nil;
    }
}

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
    MonStr([NSString stringWithFormat:@"pid %d · uid %ld · %ld 条连接 · %@", (int)_pid, (long)_uid,
            (long)_sockets, MonUptime(_startedAt)], NSMakePoint(x, y), _metaFont, MC(255, 255, 255, 0.55), NO);
    y += 16.0;

    // 进程介绍：这行是用户要的「这个进程是干什么的」。最多两行，多出来的用省略号收掉，
    // 保证气泡高度固定、不会因为某条介绍长就压到屏幕上沿。
    CGFloat innerW = NSWidth(b) - 2 * x;
    if (_intro.length) {
        NSInteger lines = [self introLineCount];
        CGFloat h = MonLineHeight(_introFont) * lines;
        MonPara(_intro, NSMakeRect(x, y, innerW, h), _introFont,
                MC(228, 238, 248, 0.88), NSLineBreakByWordWrapping);
        y += h;
    }
    if (_origin.length) {
        MonPara(_origin, NSMakeRect(x, y + 1, innerW, MonLineHeight(_originFont)), _originFont,
                MC(255, 255, 255, 0.46), NSLineBreakByTruncatingMiddle);
        y += MonLineHeight(_originFont) + 1;
    }
    y += 6.0;

    struct { NSString *label; double v; NSInteger metric; NSString *text; } lines[] = {
        // 气泡里的 CPU 跟榜内同一把尺（占整机），后面补一句"占单核"：
        // 有人会拿原生活动监视器的 31.9%（那也是占一核）来对，两个数都摆着最省事。
        // _cpu < 0 是"还没有上一拍可比"的哨兵，印百分比会变成负数，印"—"。
        // 这里不写 "CPU 10s"：值那一行还塞了「单核 x%」，10s 再挤上去会和 12h 平均文字重叠。
        // 窗口长度在 CPU 榜的行标题上始终可见（CPU 10s）。
        { @"CPU", _cpu, DeskMonitorMetricCPU,
            _cpu < 0 ? @"—"
            : [NSString stringWithFormat:@"%.1f%%（单核 %.1f%%）", MonCpuShare(_cpu), _cpu] },
        { @"内存", _mem, DeskMonitorMetricMemory,
            _mem >= 1073741824.0 ? [NSString stringWithFormat:@"%.1f GiB", _mem / 1073741824.0]
            : _mem >= 1048576.0 ? [NSString stringWithFormat:@"%.0f MiB", _mem / 1048576.0]
                                : [NSString stringWithFormat:@"%.0f KiB", MAX(0.0, _mem) / 1024.0] },
        // 能耗的分母是"全部进程的能耗合计"，气泡里也写出来（榜头已经写了"占全部"）。
        // _energy < 0 是哨兵（这一拍没法算），MonShare 会把它当 0 → 假零，改印"—"。
        { @"能耗（占全部）", _energy, DeskMonitorMetricEnergy, (self.energyTotal > 0 && _energy >= 0)
            ? [NSString stringWithFormat:@"%.0f%%", MonShare(_energy, self.energyTotal)] : @"—" },
        { @"网络·流量", (_netInRate + _netOutRate), DeskMonitorMetricNetwork,
            (_netInRate < 0 || _netOutRate < 0) ? @"—"
            : [NSString stringWithFormat:@"↓%@ ↑%@", MonRateText(_netInRate), MonRateText(_netOutRate)] },
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
        // 榜内那根淡条没有数字可读，精确值放这里 —— 用户报的就是"第二根线看不懂"。
        // 但只有**被悬停那一榜**有 12h 值：视图缓存的是"这一榜这一行"的格子，一个进程
        // 通常只出现在一榜里，拿同一个数去标另外三行就是假数据（实测错过一次：
        // histAvg=3.14 被内存行显示成 "12h 0M"、网络行显示成 "12h 3 个"）。
        NSString *hist = lines[i].metric == _histMetric
            ? MonHistText(lines[i].metric, _histAvg, _histCovered, self.energyTotal) : nil;
        if (hist.length) {
            CGFloat hx = NSMaxX(b) - 10 - MonWidth(lines[i].text, _valueFont) - 8
                         - MonWidth(hist, _metaFont);
            MonStr(hist, NSMakePoint(hx, y), _metaFont, MC(255, 255, 255, 0.45), NO);
        }
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
    // 网络那一栏现在主值是流量，底行给 12h 累计；连接数在上面的 pid 行。
    MonStr([self historyFoot], NSMakePoint(x, y), MonText(9.0), MC(255, 255, 255, 0.55), NO);
}

@end

// 浮层摆位：见 monitor_view.h 里那份约定（纯函数，好断言）
NSRect DeskHoverBubbleRect(NSPoint mouse, NSSize size, NSRect visibleFrame) {
    const CGFloat gap = 12.0;
    CGFloat x = mouse.x - size.width - gap;            // 默认：鼠标左边
    CGFloat y = mouse.y - size.height / 2.0;           // 与鼠标齐平，不压住被悬停的那一行
    if (x < NSMinX(visibleFrame)) x = mouse.x + gap;   // 左边放不下就改放右边
    if (x + size.width > NSMaxX(visibleFrame)) x = NSMaxX(visibleFrame) - size.width;
    if (x < NSMinX(visibleFrame)) x = NSMinX(visibleFrame);
    if (y < NSMinY(visibleFrame)) y = NSMinY(visibleFrame);
    if (y + size.height > NSMaxY(visibleFrame)) y = NSMaxY(visibleFrame) - size.height;
    return NSMakeRect(round(x), round(y), size.width, size.height);
}
