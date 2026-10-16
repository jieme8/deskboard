// DeskBoard — 贴在桌面层的小组件：毛玻璃卡片 + 可拖拽 + 菜单栏图标
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <fcntl.h>
#import <unistd.h>
#import <CoreGraphics/CoreGraphics.h>
#import "model.h"
#import "oilfeed.h"
#import "panel_view.h"
#import "places.h"
#import "hud.h"
#import "sysmon.h"
#import "vault.h"
#import "vault_view.h"
#import "vault_art.h"

static NSString *const kDomain = @"com.hujie.deskboard";

static void DeskLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void DeskLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *df;
    if (!df) {
        df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    }
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/DeskBoard.log"];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (h) {
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } else {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static NSString *K(NSString *name) { return [@"DeskBoard" stringByAppendingString:name]; }

// 首次运行时写入的兜底数据（真实数值由 ./tools/refresh.py 从东方财富接口刷新）。
// 标 demo=true 是因为这份是编译期快照，可能已经过期。
static NSString *const kDefaultMockJSON =
    @"{\n"
    @"  \"city\": \"上海\",\n"
    @"  \"grade\": \"92号汽油\",\n"
    @"  \"price\": 8.57,\n"
    @"  \"unit\": \"元/升\",\n"
    @"  \"nextDate\": \"10月16日\",\n"
    @"  \"nextTime\": \"24:00\",\n"
    @"  \"daysLeft\": 4,\n"
    @"  \"updatedAt\": \"17:01\",\n"
    @"  \"demo\": true\n"
    @"}\n";

// 菜单栏图标：代码画的加油机（机身 + 显示屏 + 油管与油枪），template 图自动适配深浅色菜单栏。
// 26.5 SDK 的 AppKit 没有 NSBezierPath 的圆弧分类，圆角一律用 bezierPathWithRoundedRect。
static NSImage *DeskStatusGlyph(void) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(18, 16) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [NSColor.blackColor setStroke];
        [NSColor.blackColor setFill];

        NSBezierPath *pump = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2.6, 2.0, 7.4, 12.4)
                                                             xRadius:2.0 yRadius:2.0];
        pump.lineWidth = 1.5;
        [pump stroke];

        NSBezierPath *screen = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(4.8, 9.6, 3.0, 2.8)
                                                              xRadius:0.7 yRadius:0.7];
        [screen fill];

        NSBezierPath *hose = [NSBezierPath bezierPath];
        [hose moveToPoint:NSMakePoint(10.0, 11.0)];
        [hose curveToPoint:NSMakePoint(14.2, 8.6)
         controlPoint1:NSMakePoint(13.0, 11.0) controlPoint2:NSMakePoint(14.2, 10.4)];
        [hose lineToPoint:NSMakePoint(14.2, 5.0)];
        hose.lineWidth = 1.5;
        [hose stroke];

        NSBezierPath *nozzle = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(12.7, 2.2, 3.0, 2.8)
                                                              xRadius:0.9 yRadius:0.9];
        [nozzle fill];
        return YES;
    }];
    img.template = YES;
    img.accessibilityDescription = @"DeskBoard 桌面小组件";
    return img;
}

// 预览浮窗的内容视图：普通 NSView（不翻转），NSImage 直接 drawInRect: 就是正的
@interface DeskVaultPreviewView : NSView
@property (nonatomic, strong) NSImage *image;
@property (nonatomic, strong) NSColor *tint;
@end

@implementation DeskVaultPreviewView
- (void)drawRect:(NSRect)r {
    [[NSColor colorWithSRGBRed:8.0/255.0 green:26.0/255.0 blue:46.0/255.0 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:8.0 yRadius:8.0] fill];
    if (self.image) {
        const CGFloat pad = 6.0;
        NSSize ts = self.image.size;
        CGFloat aw = NSWidth(r) - pad * 2, ah = NSHeight(r) - pad * 2;
        CGFloat s = MIN(aw / ts.width, ah / ts.height);     // 整幅 contain
        CGFloat w = ts.width * s, h = ts.height * s;
        [self.image drawInRect:NSMakeRect(NSMidX(r) - w / 2.0, NSMidY(r) - h / 2.0, w, h)
                       fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    }
    [[self.tint colorWithAlphaComponent:0.45] setStroke];
    NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:r xRadius:8.0 yRadius:8.0];
    edge.lineWidth = 1.0;
    [edge stroke];
}
@end

@interface DeskBoardApp : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

// 弹药库透明度的下限：再低就基本看不见组件了，菜单也不给更透的档。
// 注意窗口 alpha 只改画面不改命中测试，所以低档位下这块地方照样会吃掉点击
static const double kVaultAlphaMin = 0.05;
// 透明度档位：100% 起每档减 5% 一直到下限。按步长生成而不是手写死二十个数字，
// 存档里落的就是这些整数百分比之一，syncMenu 的勾也直接拿它比对
static const NSInteger kVaultAlphaMaxPct = 100;
static const NSInteger kVaultAlphaStep = 5;

// 「被应用窗口盖住就临时让开」的几个阈值。
// 层级不是事件驱动的，只能定时去 WindowServer 问一次，所以这几个数决定了这动作的手感。
// 两个方向的档数刻意不对称：
//   收起要慢（kVaultCoverStrikes 档 ≈1.8 秒）——宁可多等一会儿，也别被一掠而过的窗口骗走，
//     组件凭空消失比多露一会儿刺眼得多；
//   出现要快（1 档 ≤kVaultCoverInterval）——从全屏退到桌面时，人正要动手操作，
//     组件慢两秒才跳出来，那一下等待比闪现更让人烦躁。
// 两边都用 2 档的时候，退全屏实测要等 2~3 秒，那是把"防误判"的代价全算在了恢复上。
static const NSTimeInterval kVaultCoverInterval = 0.6;
static const NSInteger kVaultCoverStrikes = 3;
static const NSInteger kVaultCoverClearTicks = 1;
// 一次切换之后至少隔这么久才允许反向。日志里出现过 2 秒内「收起→出现→收起」的横跳：
// 每跳一次就重启一遍入库动画，把刚停下来的动画表又叫回 60fps
static const NSTimeInterval kVaultCoverDwell = 3.0;
// 没被盖住时把自己顶回本层最前的频率（按检测次数计），每 tick 都顶一次纯属白问 WindowServer
static const NSUInteger kVaultRaiseEveryTicks = 5;
// 露着的比例低于这个数才算被盖住：只压到一个角的话组件大体还能用，藏起来反而添乱
static const CGFloat kVaultCoverShare = 0.25;


@implementation DeskBoardApp {
    NSStatusItem *_statusItem;
    NSMenu *_styleMenu;
    NSMenuItem *_cardItem;       // 菜单里「卡片面板 › 显示/隐藏」，对勾跟着 _hidden 走
    NSMenuItem *_editItem;       // 「卡片面板 › 调角模式」
    NSMenuItem *_vaultItem;
    NSMenuItem *_vaultEditItem;  // 「弹药库 › 调角模式」
    NSMutableArray<NSWindow *> *_windows;
    DeskModel *_model;
    DeskSysMonitor *_sys;
    NSString *_mockPath;
    NSString *_stamp;
    NSUInteger _tick;
    NSInteger _style;           // DeskStyle
    DeskPlaceStore *_places;    // 每个"屏 × 分辨率"一份的位置存档（含待保存）
    NSWindow *_hud;             // 卡片外的坐标胶囊，只在实底卡外观下出现
    DeskHudView *_hudView;
    NSString *_savedStamp;      // 上次点保存的时刻，胶囊上显示"已保存 13:20"

    BOOL _hidden;
    BOOL _editing;              // 卡片自己的调角模式，和弹药库各切各的
    DeskQuadOffsets _quad;      // 四角位移，全 0 就是没变形
    BOOL _applying;             // 我们自己 setFrame 时别再回读位置，免得和拖拽互相触发
    int _lockFD;

    // 弹药库：独立的窗口组和独立的摆位档，拖动互不影响
    NSMutableArray<NSWindow *> *_vaultWindows;
    // 悬停预览的浮窗：整块浮在弹药库上方，鼠标移开即消失。
    // 组件只有 432×294，卡片区被 6 张卡占满，预览要挪出去只能另开一块窗。
    // 它点击穿透（ignoresMouseEvents）、不抢激活，所以既不挡卡片也不打断手上的活。
    NSWindow *_vaultPreviewWindow;
    DeskPlaceStore *_vaultPlaces;
    BOOL _vaultHidden;
    NSInteger _vaultStyle;        // 弹药库外观，与卡片同一套枚举但各存各的
    NSMenu *_vaultStyleMenu;
    NSMenu *_vaultAlphaMenu;
    DeskQuadOffsets _vaultQuad;   // 弹药库自己的四角位移，和卡片各调各的
    BOOL _vaultEditing;           // 弹药库自己的调角模式，和卡片各切各的
    double _vaultAlpha;           // 整块组件的不透明度，1.0 = 原样，菜单分档
    NSTimer *_vaultCoverTimer;    // 被盖住检测：窗口层级不是事件，只能定时问 WindowServer
    NSInteger _vaultCovered;      // 连续几次检出被盖住（防一掠而过导致闪一下）
    NSInteger _vaultClear;        // 连续几次检出空出来了
    BOOL _vaultCoverHidden;       // 因被盖住而临时收起，和用户手动隐藏分开记
    NSTimer *_vaultTick;        // 动画驱动，只在真有事做的时候挂着
    NSTimer *_vaultWatchdog;    // 空闲停表后的低频看门狗，负责把表叫回来
    NSDate *_lastVaultTick;
    NSDate *_vaultCoverToggledAt;  // 上一次"收起/出现"切换的时刻，防来回横跳
    NSUInteger _vaultCoverTicks;   // 盖住检测的计数，用来顺手给置顶降频
    NSDate *_lastVaultStat;

}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    _places = [[DeskPlaceStore alloc] initWithDictionary:[ud dictionaryForKey:K(@"Places")]];
    if (_places.count == 0) {
        // 一次性迁移：老的全局位置种进主屏那条记录，之后老键废弃
        NSNumber *cornerVal = [ud objectForKey:K(@"Corner")];
        NSNumber *dxVal = [ud objectForKey:K(@"DX")];
        NSNumber *dyVal = [ud objectForKey:K(@"DY")];
        if (cornerVal) {
            DeskPlace seed = [DeskPlaceStore defaultPlace];
            seed.corner = cornerVal.integerValue;
            if (dxVal) seed.dx = MAX(0, dxVal.doubleValue);
            if (dyVal) seed.dy = MAX(0, dyVal.doubleValue);
            [_places setPlace:seed forKey:[_places keyForScreen:[NSScreen mainScreen]]];
        }
        [ud removeObjectForKey:K(@"Corner")];
        [ud removeObjectForKey:K(@"DX")];
        [ud removeObjectForKey:K(@"DY")];
        [self saveConfig];
    }
    _hidden = [ud boolForKey:K(@"Hidden")];
    _vaultHidden = [ud boolForKey:K(@"VaultHidden")];
    // 层级现在是硬约束：弹药库只贴桌面图标层，任何应用窗口（全屏的也一样）都在它之下。
    // 旧版有个「桌面置顶」开关会把它提到 NSFloatingWindowLevel，正好浮在窗口上面，已经整个删掉；
    // 老存档在这里顺手清掉，别留个没人读的键。
    if ([ud objectForKey:K(@"VaultFloating")]) {
        [ud removeObjectForKey:K(@"VaultFloating")];
        DeskLog(@"旧的「桌面置顶」档已废弃并清除：弹药库常驻桌面图标层，不再浮到任何窗口上");
    }
    NSNumber *vaVal = [ud objectForKey:K(@"VaultAlpha")];
    _vaultAlpha = vaVal ? MIN(MAX(vaVal.doubleValue, kVaultAlphaMin), 1.0) : 1.0;
    // 菜单里只有 kVaultAlphaStep 的整数倍。存档被手改成 0.62 这种离档的值时，
    // syncMenu 会一个勾都点不上，看起来像没生效，所以读档就吸到最近的档位上
    _vaultAlpha = MIN(MAX(round(_vaultAlpha * 100.0 / kVaultAlphaStep) * kVaultAlphaStep / 100.0,
                          kVaultAlphaMin), 1.0);
    _vaultQuad = DeskQuadOffsetsFromString([ud stringForKey:K(@"VaultQuad")]);
    // 弹药库默认走实底卡：采样了真实壁纸，压得住字，也最融入桌面
    NSNumber *vsVal = [ud objectForKey:K(@"VaultStyle")];
    _vaultStyle = vsVal ? MIN(vsVal.integerValue, (NSInteger)DeskStyleHUD) : (NSInteger)DeskStylePlate;
    NSNumber *styleVal = [ud objectForKey:K(@"Style")];
    // 旧的"透视站立"已经并到调角里，存过的值越界就退到 HUD
    _style = styleVal ? MIN(styleVal.integerValue, (NSInteger)DeskStyleHUD) : DeskStyleFeather;
    _quad = DeskQuadOffsetsFromString([ud stringForKey:K(@"Quad")]);

    [self prepareDataDir];
    // 油价从东方财富实时拉，写回上面那个 mock.json；它一变，下面 2 秒的
    // mtime 轮询自己会重画，面板和绘制代码都不用动
    [DeskOilFeed startWithCachePath:_mockPath];
    if (![self acquireSingleInstanceLock]) exit(0);   // 两个实例会各画一张卡，别靠运气
    _sys = [DeskSysMonitor new];
    [_sys sample];   // 先取一次基线，下一拍才有差值型指标
    // 弹药库的位置另存一份：和卡片各摆各的，共用一个存档会互相顶掉
    _vaultPlaces = [[DeskPlaceStore alloc] initWithDictionary:[ud dictionaryForKey:K(@"VaultPlaces")]];
    if (_vaultPlaces.count == 0) {
        DeskPlace seed = [DeskPlaceStore defaultPlace];
        // 默认左下角。右下角是访达放桌面图标的地方，弹药库是块不透明的板，
        // 压上去那些图标就没法拖了；放左边则是"图标从右边拖过来"的顺手方向
        seed.corner = 2;
        seed.dx = 16.0;
        seed.dy = 16.0;
        [_vaultPlaces setPlace:seed forKey:[_vaultPlaces keyForScreen:[NSScreen mainScreen]]];
        [self saveConfig];
    }
    [self buildStatusItem];
    [self rebuildWindows];
    [self rebuildVaultWindows];
    [self startVaultTicking];
    [self startPolling];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenDidChange:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
    DeskLog(@"启动完成 屏位档 %lu 隐藏=%d", (unsigned long)_places.count, _hidden);
}

- (NSString *)dataDir {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"DeskBoard"];
}

- (void)prepareDataDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [self dataDir];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    _mockPath = [dir stringByAppendingPathComponent:@"mock.json"];
    if (![fm fileExistsAtPath:_mockPath]) {
        [kDefaultMockJSON writeToFile:_mockPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        DeskLog(@"首次运行，写入演示数据：%@", _mockPath);
    }
    _stamp = [self currentStamp];
}

- (NSString *)currentStamp {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:_mockPath error:nil];
    if (!attrs) return nil;
    return [NSString stringWithFormat:@"%@-%llu", attrs[NSFileModificationDate],
            (unsigned long long)[attrs fileSize]];
}

- (void)saveConfig {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:[_places dictionary] forKey:K(@"Places")];
    [ud setBool:_hidden forKey:K(@"Hidden")];
    [ud setInteger:_style forKey:K(@"Style")];
    [ud setObject:DeskQuadOffsetsString(_quad) forKey:K(@"Quad")];
    [ud setObject:[_vaultPlaces dictionary] forKey:K(@"VaultPlaces")];
    [ud setBool:_vaultHidden forKey:K(@"VaultHidden")];
    [ud setDouble:_vaultAlpha forKey:K(@"VaultAlpha")];
    [ud setObject:DeskQuadOffsetsString(_vaultQuad) forKey:K(@"VaultQuad")];
    [ud setInteger:_vaultStyle forKey:K(@"VaultStyle")];
}

- (BOOL)acquireSingleInstanceLock {
    NSString *path = [[self dataDir] stringByAppendingPathComponent:@".instance.lock"];
    _lockFD = open([path fileSystemRepresentation], O_CREAT | O_RDWR, 0644);
    if (_lockFD < 0) return YES;   // 锁文件都打不开就别把自己拦在门外
    struct flock fl;
    memset(&fl, 0, sizeof fl);
    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    if (fcntl(_lockFD, F_SETLK, &fl) != 0) {
        DeskLog(@"已有实例持有锁，本次退出：%s", strerror(errno));
        return NO;
    }
    return YES;
}

- (DeskModel *)loadModel {
    DeskModel *m = [DeskModel modelFromJSONFileAtPath:_mockPath];
    [m updateStats:[_sys sample]];
    DeskStats *s = m.stats;
    DeskLog(@"数据：%@ %@ [%@] 错误=%@ | CPU=%.0f%% GPU=%.0f%% 温度=%.1f°C 内存=%.1f/%.0fG 磁盘剩=%.0fG SSD=%d 读=%.1f 写=%.1f MB/s",
            m.title, m.price, m.infoLine, m.loadError ?: @"无",
            s.cpu, s.gpu, s.cpuTemp, s.memUsed / 1e9, s.memTotal / 1e9, s.diskFree / 1e9,
            s.diskIsSSD, s.diskRead / 1e6, s.diskWrite / 1e6);
    return m;
}

// 取这块屏这个分辨率下的存档位置。落出可视区的旧记录（比如大屏贴最右、切小屏后越界）
// 夹回默认锚点并覆盖掉，免得组件被摆到看不见的地方
- (DeskPlace)resolvedPlaceForScreen:(NSScreen *)screen cardSize:(NSSize)cardSize {
    DeskPlace p = [_places effectivePlaceForScreen:screen];
    NSRect vf = screen.visibleFrame;
    CGFloat x = (p.corner == 1 || p.corner == 3) ? NSMaxX(vf) - cardSize.width - p.dx
                                                 : vf.origin.x + p.dx;
    CGFloat y = (p.corner >= 2) ? vf.origin.y + p.dy : NSMaxY(vf) - cardSize.height - p.dy;
    if (!NSIntersectsRect(NSMakeRect(x, y, cardSize.width, cardSize.height), vf)) {
        DeskLog(@"档 %@ 落出可视区，夹回默认锚点", [_places keyForScreen:screen]);
        p = [DeskPlaceStore defaultPlace];
        [_places setPlace:p forKey:[_places keyForScreen:screen]];
        [self saveConfig];
    }
    return p;
}

// dx/dy 永远描述"看得见的卡片"离锚点角多远；变形时卡片的四角会跑到卡片矩形之外，
// 所以窗口往外撑一圈余量，位置语义不变。
- (BOOL)quadActive { return !DeskQuadOffsetsIsZero(_quad) || _editing; }

- (NSRect)frameForSize:(NSSize)cardSize screen:(NSScreen *)screen {
    DeskPlace p = [self resolvedPlaceForScreen:screen cardSize:cardSize];
    NSRect vf = screen.visibleFrame;
    CGFloat x = (p.corner == 1 || p.corner == 3) ? NSMaxX(vf) - cardSize.width - p.dx
                                                 : vf.origin.x + p.dx;
    CGFloat y = (p.corner >= 2) ? vf.origin.y + p.dy : NSMaxY(vf) - cardSize.height - p.dy;
    NSSize win = [DeskCardView windowSizeForModel:_model style:(DeskStyle)_style warped:[self quadActive]];
    CGFloat padX = (win.width - cardSize.width) / 2.0, padY = (win.height - cardSize.height) / 2.0;
    return NSMakeRect(round(x - padX), round(y - padY), win.width, win.height);
}

- (NSWindow *)makeWindowForScreen:(NSScreen *)screen model:(DeskModel *)model {
    NSSize size = [DeskPanelView sizeForModel:model];
    NSRect frame = [self frameForSize:size screen:screen];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [w setBackgroundColor:[NSColor clearColor]];
    w.opaque = NO;
    w.hasShadow = ![self quadActive];   // 变形后外框是矩形，窗影会出卖它
    w.level = kCGDesktopIconWindowLevel;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                         | NSWindowCollectionBehaviorStationary
                         | NSWindowCollectionBehaviorIgnoresCycle;
    // 拖动完全由 DeskCardView 实现（见 onUserMove）：这样"待保存"只可能来自用户的手，
    // 系统切分辨率时的窗口迁移不会被误记成用户摆位
    w.movableByWindowBackground = NO;
    w.animationBehavior = NSWindowAnimationBehaviorNone;
    w.excludedFromWindowsMenu = YES;
    w.delegate = self;
    DeskCardView *card = [[DeskCardView alloc] initWithModel:model style:(DeskStyle)_style
                                                      warped:[self quadActive]];
    card.quadOffsets = _quad;
    card.editing = _editing;
    __weak typeof(self) weakSelf = self;
    card.onQuadEdit = ^(DeskQuadOffsets q) {
        [weakSelf applyQuadFromCard:q];
    };
    card.onGeometryChange = ^{ [weakSelf updateHud]; };   // 拖角时窗口没动，只能靠这个刷新读数
    __weak NSWindow *weakSelfWindow = w;
    card.onUserMove = ^{ [weakSelf recordPendingPlaceInWindow:weakSelfWindow]; };
    w.contentView = card;
    [card refreshSource];
    return w;
}

// 拖完一个角就把四角位移收回来自身状态并存盘（多屏时以被拖的那张卡为准）
- (void)applyQuadFromCard:(DeskQuadOffsets)q {
    _quad = q;
    for (NSWindow *w in _windows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskCardView class]]) ((DeskCardView *)v).quadOffsets = q;
    }
    [self saveConfig];
    DeskLog(@"角点已保存 %@", DeskQuadOffsetsString(q));
}

- (void)rebuildWindows {
    for (NSWindow *w in _windows) [w orderOut:nil];
    _windows = [NSMutableArray array];
    if (!_model) _model = [self loadModel];
    for (NSScreen *screen in [NSScreen screens]) {
        NSWindow *w = [self makeWindowForScreen:screen model:_model];
        [_windows addObject:w];
        if (!_hidden) [w orderFrontRegardless];
    }
    DeskLog(@"建窗 %lu 个，%@ 层=%ld", (unsigned long)_windows.count,
            _hidden ? @"全部隐藏" : @"已显示", (long)kCGDesktopIconWindowLevel);
    [self updateHud];
}

#pragma mark - 弹药库

- (BOOL)vaultQuadActive { return !DeskQuadOffsetsIsZero(_vaultQuad) || _vaultEditing; }

- (NSRect)vaultFrameForScreen:(NSScreen *)screen {
    NSRect vf = screen.visibleFrame;
    DeskPlace p = [_vaultPlaces effectivePlaceForScreen:screen];
    CGFloat x = (p.corner == 1 || p.corner == 3) ? NSMaxX(vf) - kVaultViewWidth - p.dx
                                                 : vf.origin.x + p.dx;
    CGFloat y = (p.corner >= 2) ? vf.origin.y + p.dy : NSMaxY(vf) - kVaultViewHeight - p.dy;
    NSSize card = NSMakeSize(kVaultViewWidth, kVaultViewHeight);
    NSSize win = [DeskVaultView windowSizeWarped:[self vaultQuadActive]];
    CGFloat padX = (win.width - card.width) / 2.0, padY = (win.height - card.height) / 2.0;
    NSRect r = NSMakeRect(round(x - padX), round(y - padY), win.width, win.height);
    if (!NSIntersectsRect(r, vf)) {
        // 落出可视区（老记录来自大屏，切到小屏）就夹回右下角，别让组件摆到看不见的地方
        DeskLog(@"弹药库档 %@ 落出可视区，夹回默认锚点（左下）", [_vaultPlaces keyForScreen:screen]);
        p.corner = 2; p.dx = 16.0; p.dy = 16.0;
        [_vaultPlaces setPlace:p forKey:[_vaultPlaces keyForScreen:screen]];
        [self saveConfig];
        r = NSMakeRect(round(vf.origin.x + p.dx - padX), round(vf.origin.y + p.dy - padY),
                       win.width, win.height);
    }
    return r;
}

- (NSWindow *)makeVaultWindowForScreen:(NSScreen *)screen {
    NSRect vf = [self vaultFrameForScreen:screen];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:vf
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    [w setBackgroundColor:[NSColor clearColor]];
    w.opaque = NO;
    w.hasShadow = YES;
    // 层级是硬约束，不是可调项：只贴桌面图标层（图标之下、壁纸之上）。
    // 用户的应用窗口（含全屏窗口）一律在这层之上，所以任何模式下都盖不到窗口上。
    w.level = kCGDesktopIconWindowLevel;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                         | NSWindowCollectionBehaviorStationary
                         | NSWindowCollectionBehaviorIgnoresCycle;
    w.movableByWindowBackground = NO;   // 拖动由 DeskVaultView 自己实现，见 onUserMove
    w.animationBehavior = NSWindowAnimationBehaviorNone;
    w.excludedFromWindowsMenu = YES;
    // 不开这个，mouseMoved 根本不来，悬停高亮和按钮反馈全是死的
    w.acceptsMouseMovedEvents = YES;
    // 透明度落在窗口上：不进绘制逻辑，四档外观和变形态都自动吃这一档，
    // 也不会把预烘的位图连同缓存一起作废
    w.alphaValue = _vaultAlpha;

    // 视图尺寸必须等于窗口尺寸：变形时窗口是撑出余量的画布，
    // 视图还给组件本体的尺寸，四角投影就会画在画布外面
    DeskVaultView *v = [[DeskVaultView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(vf), NSHeight(vf))];
    v.quadOffsets = _vaultQuad;
    v.editing = _vaultEditing;
    v.style = (DeskStyle)_vaultStyle;
    __weak typeof(self) weakSelf = self;
    __weak NSWindow *weakW = w;
    v.onHide = ^{ [weakSelf setVaultHidden:YES]; };
    v.onQuadEdit = ^(DeskQuadOffsets q) { [weakSelf applyVaultQuad:q]; };
    v.onGeometryChange = ^{ [weakSelf applyVaultFrames]; };
    v.onUserMove = ^{ [weakSelf saveVaultPlaceInWindow:weakW]; };
    v.onLog = ^(NSString *message) { DeskLog(@"弹药库 %@", message); };
    v.onPreview = ^(NSString *path) { [weakSelf updateVaultPreviewWithPath:path forWindow:weakW]; };
    // 组件自己说"我要动了"，就把动画表叫回来。空闲停表之后，全靠这一条恢复
    v.onNeedFrames = ^{ [weakSelf resumeVaultTicking]; };
    w.contentView = v;
    return w;
}

// 透明度只动窗口 alpha，不重建窗口：重建会打断正在拖的卡片和进行中的动画
- (void)applyVaultAlpha {
    for (NSWindow *w in _vaultWindows) w.alphaValue = _vaultAlpha;
}

#pragma mark - 被应用窗口盖住就临时让开

// 桌面自己那些常驻 UI 都不该把组件收走：Dock、输入法候选窗、Mission Control 之类。
// 它们层级不低，窗口框又常常是整屏——本机 Dock 报的是 layer=18、bounds 0,0 1512x945，
// 只按层级筛根本分不出来（我原来把 20 当 Dock 的层级，它其实可以更矮）。
// 于是点一次「显示桌面」：Code 窗口滑走 → 判定没盖住；Dock 冒出来 → 判定盖住，
// 两秒一轮闪不停。所以这里按进程身份筛：Dock 的 bundle id 是固定的，
// 系统 UI 则都是 NSApplicationActivationPolicyProhibited（没 Dock 图标、不能被激活的那种）。
static BOOL VaultIsDesktopChrome(pid_t pid) {
    static NSMutableDictionary<NSNumber *, NSNumber *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
        NSRunningApplication *dock =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"].firstObject;
        if (dock) cache[@(dock.processIdentifier)] = @YES;
    });
    NSNumber *hit = cache[@(pid)];
    if (hit) return hit.boolValue;
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    BOOL chrome = app == nil || app.activationPolicy == NSApplicationActivationPolicyProhibited;
    cache[@(pid)] = @(chrome);
    return chrome;
}

// 这块矩形（WindowServer 坐标，左上原点）有没有被用户的应用窗口盖住。
// 层级那一步是便宜的粗筛：普通窗口 0、浮动窗 3、模态 8 都在 0~19 里，
// 而菜单栏 24/25、弹窗 101、屏保 1000+ 和某些后台程序乱报的极大层级一律不算——
// 它们要么不在屏幕上，要么是透明覆盖层，算进来只会让组件一直收不起来。
// 露着不足 kVaultCoverShare 也不算：只压到一个角的话组件大体还能用，藏起来反而添乱。
// dominant（可空）回填压住最多的那个窗口是谁，判定为没盖住时是 nil。
// 盖住判定一旦飘起来，日志里有这句才查得到是哪个进程在捣鬼，
// 光看「盖住/没盖住」的汇总等于蒙着眼睛调试。
static BOOL VaultCoveredByAppWindow(NSRect r, NSString *__autoreleasing *dominant) {
    if (dominant) *dominant = nil;
    if (NSWidth(r) < 1 || NSHeight(r) < 1) return NO;
    NSString *me = [[NSProcessInfo processInfo] processName];
    CGFloat total = NSWidth(r) * NSHeight(r);
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly
                                                 | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    CGFloat hit = 0, top = 0;
    NSString *topWho = nil;
    for (CFIndex i = 0; i < CFArrayGetCount(list) && hit < total * kVaultCoverShare; i++) {
        NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
        if ([d[@"kCGWindowOwnerName"] isEqualToString:me]) continue;
        long layer = (long)[d[@"kCGWindowLayer"] integerValue];
        if (layer < 0 || layer >= 20) continue;
        if ([d[@"kCGWindowAlpha"] doubleValue] < 0.02) continue;   // 全透明覆盖层：看得见空气
        if (VaultIsDesktopChrome((pid_t)[d[@"kCGWindowOwnerPID"] integerValue])) continue;
        NSDictionary *b = d[@"kCGWindowBounds"];
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        NSRect w = NSMakeRect([b[@"X"] doubleValue], [b[@"Y"] doubleValue],
                              [b[@"Width"] doubleValue], [b[@"Height"] doubleValue]);
        CGFloat area = NSWidth(NSIntersectionRect(w, r)) * NSHeight(NSIntersectionRect(w, r));
        hit += area;
        if (area > top) {
            top = area;
            topWho = [NSString stringWithFormat:@"%@ layer=%ld 压住 %.0f%%",
                      d[@"kCGWindowOwnerName"], layer, area / total * 100.0];
        }
    }
    CFRelease(list);
    if (dominant) *dominant = hit >= total * kVaultCoverShare ? topWho : nil;
    return hit >= total * kVaultCoverShare;
}

// 窗口层级不是事件，只能定时去问一次 WindowServer
- (void)checkVaultCover:(NSTimer *)timer {
    if (_vaultHidden) return;              // 用户自己收起的，不归这里管
    for (NSWindow *w in _vaultWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskVaultView class]] && [(DeskVaultView *)v isDragging]) return;
    }   // 正在拖窗口 / 拖卡片 / 接拖放：这时候把它收走等于从用户手里抢东西

    CGFloat mainH = [NSScreen mainScreen].frame.size.height;
    BOOL covered = NO;
    NSString *who = nil;
    for (NSWindow *w in _vaultWindows) {
        NSRect f = w.frame;   // 视图是左下原点，WindowServer 是左上原点
        NSString *one = nil;
        if (VaultCoveredByAppWindow(NSMakeRect(f.origin.x, mainH - NSMaxY(f),
                                               NSWidth(f), NSHeight(f)), &one)) {
            covered = YES;
            who = one;
        }
    }
    // 横跳防护：刚切过一次状态，短时间内不许反向
    BOOL dwellPassed = !_vaultCoverToggledAt
        || [[NSDate date] timeIntervalSinceDate:_vaultCoverToggledAt] >= kVaultCoverDwell;
    _vaultCoverTicks++;
    if (covered) {
        _vaultClear = 0;
        _vaultCovered++;
        if (dwellPassed && _vaultCovered >= kVaultCoverStrikes) [self setVaultCoverHidden:YES reason:who];
    } else {
        _vaultCovered = 0;
        _vaultClear++;
        if (dwellPassed && _vaultClear >= kVaultCoverClearTicks) [self setVaultCoverHidden:NO reason:nil];
        // 没被盖住的时候，顺手把自己顶回本层最前：访达的桌面窗和组件是同一层
        // （都是 kCGDesktopIconWindowLevel），它一旦排到组件前面——刷新桌面、切 Space、
        // 换壁纸都会重排——整块桌面就归它，组件看着好好的却一点都点不动。
        // 这一层没有「置顶」可设，只能定时顶回去。每 5 次检测顶一次就够，次次都问纯属白烧。
        if (!_vaultCoverHidden && (_vaultCoverTicks % kVaultRaiseEveryTicks) == 0) {
            for (NSWindow *w in _vaultWindows) [w orderFrontRegardless];
        }
    }
}

// 显示与否只有这一个出口：用户手动隐藏和「被盖住临时收起」都走它，
// 两个原因叠在一起时用 AND 判断，谁都别偷偷把对方打开
- (void)applyVaultVisibility {
    BOOL show = !_vaultHidden && !_vaultCoverHidden;
    for (NSWindow *w in _vaultWindows) {
        if (show) [w orderFrontRegardless]; else [w orderOut:nil];
    }
}

// reason 是把组件盖住的那个窗口，判定飘起来时全靠这句定位是谁在捣鬼
- (void)setVaultCoverHidden:(BOOL)hidden reason:(NSString *)reason {
    if (hidden == _vaultCoverHidden) return;
    _vaultCoverHidden = hidden;
    _vaultCovered = 0;
    _vaultClear = 0;
    _vaultCoverToggledAt = [NSDate date];
    [self applyVaultVisibility];
    DeskLog(@"弹药库%@（被应用窗口盖住）%@", hidden ? @"临时收起" : @"重新出现", reason ?: @"");
}

- (void)chooseVaultAlpha:(id)sender {
    _vaultAlpha = MIN(MAX([sender tag] / 100.0, kVaultAlphaMin), 1.0);
    [self applyVaultAlpha];
    [self saveConfig];
    [self syncMenu];
    DeskLog(@"弹药库透明度改为 %.0f%%", _vaultAlpha * 100.0);
}

// 拖完一个角就存盘并重算窗口尺寸（退出调角时四角归零，窗口要缩回去）
- (void)applyVaultQuad:(DeskQuadOffsets)q {
    _vaultQuad = q;
    for (NSWindow *w in _vaultWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskVaultView class]]) ((DeskVaultView *)v).quadOffsets = q;
    }
    [self applyVaultFrames];
    [self saveConfig];
    DeskLog(@"弹药库角点已保存 %@", DeskQuadOffsetsString(q));
}

- (void)applyVaultFrames {
    if (_applying) return;
    _applying = YES;
    NSUInteger i = 0;
    for (NSScreen *screen in [NSScreen screens]) {
        if (i >= _vaultWindows.count) break;
        [_vaultWindows[i++] setFrame:[self vaultFrameForScreen:screen] display:YES animate:NO];
    }
    _applying = NO;
}

- (void)rebuildVaultWindows {
    for (NSWindow *w in _vaultWindows) [w orderOut:nil];
    _vaultWindows = [NSMutableArray array];
    for (NSScreen *screen in [NSScreen screens]) {
        NSWindow *w = [self makeVaultWindowForScreen:screen];
        [_vaultWindows addObject:w];
    }
    [self applyVaultVisibility];   // 盖住检测可能已经判定该收起，不能在这里无条件上前台
    DeskLog(@"弹药库建窗 %lu 个（库内 %lu 个文件夹），%@，层级=%ld（桌面图标层），透明度 %.0f%%",
            (unsigned long)_vaultWindows.count,
            (unsigned long)[DeskVault shared].items.count, _vaultHidden ? @"已隐藏" : @"已显示",
            (long)kCGDesktopIconWindowLevel, _vaultAlpha * 100.0);
}

- (void)setVaultHidden:(BOOL)hidden {
    _vaultHidden = hidden;
    [self applyVaultVisibility];
    [self saveConfig];
    [self syncMenu];
    DeskLog(@"弹药库切换：%@", hidden ? @"隐藏" : @"显示");
}

- (void)toggleVaultHidden:(id)sender { [self setVaultHidden:!_vaultHidden]; }

// 弹药库没有"保存"按钮，拖完直接落档：摆位只可能来自 onUserMove，
// 而它只在真鼠标拖拽时才触发，系统迁移窗口走不到这里
- (void)saveVaultPlaceInWindow:(NSWindow *)w {
    if (!w) return;
    NSScreen *screen = w.screen ?: [NSScreen mainScreen];
    NSRect vf = screen.visibleFrame;
    // 变形时窗口比组件本体大出一圈余量，摆位描述的是"看得见的那块"，
    // 直接拿窗口框算会整体偏出去半个余量
    NSRect f = w.frame;
    if (self.vaultQuadActive) {
        f = NSInsetRect(f, (NSWidth(f) - kVaultViewWidth) / 2.0,
                        (NSHeight(f) - kVaultViewHeight) / 2.0);
    }
    DeskPlace p;
    p.corner = (NSMidY(f) > vf.origin.y + vf.size.height / 2.0 ? 0 : 2)
             + (NSMidX(f) > vf.origin.x + vf.size.width / 2.0 ? 1 : 0);
    p.dx = MAX(0, (p.corner == 1 || p.corner == 3) ? NSMaxX(vf) - NSMaxX(f) : f.origin.x - vf.origin.x);
    p.dy = MAX(0, (p.corner >= 2) ? f.origin.y - vf.origin.y : NSMaxY(vf) - NSMaxY(f));
    // 夹回可视区：整块拖出去就等于没了，存这种档位等于把组件弄丢
    const CGFloat margin = 16.0;
    CGFloat maxDx = MAX(margin, vf.size.width - kVaultViewWidth - margin);
    CGFloat maxDy = MAX(margin, vf.size.height - kVaultViewHeight - margin);
    p.dx = MIN(MAX(p.dx, margin), maxDx);
    p.dy = MIN(MAX(p.dy, margin), maxDy);
    if (NSIntersectsRect(f, vf)) {
        NSString *key = [_vaultPlaces keyForScreen:screen];
        [_vaultPlaces setPlace:p forKey:key];
        [self saveConfig];
        DeskLog(@"弹药库位置已保存 %@ → 角 %ld 偏移 %.0f,%.0f", key, (long)p.corner, p.dx, p.dy);
    } else {
        DeskLog(@"弹药库整块拖出可视区，不存档，原地拉回");
        [w setFrame:[self vaultFrameForScreen:screen] display:YES];
    }
}

// 动画表只在真有事做的时候挂着。
// 之前它是常开的 60fps，并且"空闲时每 3 帧也重画一次"——理由是那条慢扫描带常年要动。
// 实测后果：DeskBoard 稳定吃 39% CPU，活动监视器「对能耗的影响」88.5（同机 MiniMax Code 才 8.5），
// sample 三秒里主线程约四成时间都在 DeskVaultView drawRect → 逐张卡片 CoreText 排版。
// 现在改成：没人动组件 → 一帧都不重画，表也停掉；视图哪天要动了，自己把表叫回来。
- (void)startVaultTicking {
    _lastVaultTick = [NSDate date];
    _lastVaultStat = [NSDate date];
    [self resumeVaultTicking];
    // 盖住检测单独一个慢表，不塞进动画表里：没人动组件的时候不该按帧频去问 WindowServer
    _vaultCoverTimer = [NSTimer scheduledTimerWithTimeInterval:kVaultCoverInterval target:self
                                                       selector:@selector(checkVaultCover:)
                                                       userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_vaultCoverTimer forMode:NSRunLoopCommonModes];
}

- (void)resumeVaultTicking {
    if (_vaultTick) return;
    _lastVaultTick = [NSDate date];
    // 60fps 而不是 30fps：缓动曲线在 33ms 一步的表上只有两三个可见台阶，
    // 看着就是"啪"地跳过去。16ms 一步才够画出连续的淡入淡出。
    _vaultTick = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0 target:self
                                                selector:@selector(vaultTick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_vaultTick forMode:NSRunLoopCommonModes];
}

// 停表不等于睡死：留一个 10Hz 的看门狗兜底，万一某个动画没走 setNeedsDisplay 这条路，
// 最多 100ms 也能把表叫回来
- (void)parkVaultTicking {
    if (!_vaultTick) return;
    [_vaultTick invalidate];
    _vaultTick = nil;
    if (_vaultWatchdog) return;
    _vaultWatchdog = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
                                                    selector:@selector(vaultWatchdog:)
                                                    userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_vaultWatchdog forMode:NSRunLoopCommonModes];
}

- (void)vaultWatchdog:(NSTimer *)t {
    for (NSWindow *w in _vaultWindows) {
        DeskVaultView *v = (DeskVaultView *)w.contentView;
        if ([v isKindOfClass:[DeskVaultView class]] && [v needsRedraw]) { [self resumeVaultTicking]; break; }
    }
    // 目录统计很贵（一个文件夹几万文件），入库退库时已经刷过，
    // 这里只做兜底对账：五分钟扫一次，捡到用户在 Finder 里直接动过库的情况
    if ([[NSDate date] timeIntervalSinceDate:_lastVaultStat] > 300.0) {
        _lastVaultStat = [NSDate date];
        [[DeskVault shared] refreshStats];
    }
}

- (void)vaultTick:(NSTimer *)t {
    NSDate *now = [NSDate date];
    double dt = [now timeIntervalSinceDate:_lastVaultTick];
    _lastVaultTick = now;
    if (dt <= 0 || dt > 1.0) dt = 1.0 / 60.0;   // 机器睡过就按一帧算，别让动画瞬移

    BOOL busy = NO;
    for (NSWindow *w in _vaultWindows) {
        DeskVaultView *v = (DeskVaultView *)w.contentView;
        if (![v isKindOfClass:[DeskVaultView class]]) continue;
        [v tick:dt];
        if ([v needsRedraw]) busy = YES;
    }
    // 这一帧照画，包括动画收尾那一帧；画完发现没得动了就停表
    for (NSWindow *w in _vaultWindows) {
        DeskVaultView *v = (DeskVaultView *)w.contentView;
        if ([v isKindOfClass:[DeskVaultView class]]) [v setNeedsDisplay:YES];
    }
    if (!busy) [self parkVaultTicking];
    return;
}

#pragma mark - 坐标胶囊与保存
// 读数不属于组件本身：单独一个小窗口贴在卡片下面，只有实底卡外观下出现
- (void)updateHud {
    NSWindow *main = _windows.firstObject;
    BOOL show = !_hidden && _style == DeskStylePlate && main != nil;
    if (!show) { [_hud orderOut:nil]; return; }
    if (!_hud) {
        _hudView = [[DeskHudView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)];
        __weak typeof(self) weakSelf = self;
        _hudView.onSave = ^{ [weakSelf saveCurrentPlace:nil]; };
        _hud = [[NSWindow alloc] initWithContentRect:_hudView.frame
                                           styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered defer:NO];
        [_hud setBackgroundColor:[NSColor clearColor]];
        _hud.opaque = NO;
        _hud.hasShadow = NO;
        _hud.level = kCGDesktopIconWindowLevel;
        _hud.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                | NSWindowCollectionBehaviorStationary
                                | NSWindowCollectionBehaviorIgnoresCycle;
        _hud.animationBehavior = NSWindowAnimationBehaviorNone;
        _hud.excludedFromWindowsMenu = YES;
        _hud.contentView = _hudView;
    }
    // 报"你看到的框"，不是"存档里的框"：开着透视时卡片矩形和实际可见的四角能差几十 pt
    NSRect win = main.frame;
    NSScreen *sc = main.screen ?: [NSScreen mainScreen];
    CGFloat winCGY = sc.frame.size.height - NSMaxY(win);
    DeskCardView *cardView = (DeskCardView *)main.contentView;
    DeskQuad q = [cardView currentQuad];
    CGFloat xs[4] = { q.tl.x, q.tr.x, q.br.x, q.bl.x };
    CGFloat ys[4] = { q.tl.y, q.tr.y, q.br.y, q.bl.y };
    CGFloat minX = MIN(MIN(xs[0], xs[1]), MIN(xs[2], xs[3]));
    CGFloat maxX = MAX(MAX(xs[0], xs[1]), MAX(xs[2], xs[3]));
    CGFloat minY = MIN(MIN(ys[0], ys[1]), MIN(ys[2], ys[3]));
    CGFloat maxY = MAX(MAX(ys[0], ys[1]), MAX(ys[2], ys[3]));
    CGFloat left = win.origin.x + minX;
    CGFloat top = winCGY + (win.size.height - maxY);
    NSRect card = NSMakeRect(left, top, maxX - minX, maxY - minY);
    NSString *readout = [NSString stringWithFormat:@"%.0f,%.0f · %.0f×%.0f · 屏 %.0f×%.0f 可视 %.0f×%.0f",
                         card.origin.x, card.origin.y, card.size.width, card.size.height,
                         sc.frame.size.width, sc.frame.size.height,
                         sc.visibleFrame.size.width, sc.visibleFrame.size.height];
    BOOL dirty = _places.pendingCount > 0;
    NSString *status = dirty ? @"未保存" : (_savedStamp.length ? [@"已保存 " stringByAppendingString:_savedStamp] : @"已对齐存档");
    NSSize hs = [DeskHudView sizeForReadout:readout status:status];
    _hudView.readout = readout;
    _hudView.status = status;
    _hudView.dirty = dirty;
    [_hud setContentSize:hs];
    // 等宽数字下"372,77"和"405,131"一样宽，窗口尺寸不变就不会重画 —— 必须自己标脏
    [_hudView setNeedsDisplay:YES];
    // 胶囊贴在"可见框"下沿外 8pt：CG 的 y 朝下，转回 AppKit 的左上锚点
    CGFloat hudTop = sc.frame.size.height - NSMaxY(card) - 8.0;
    [_hud setFrameTopLeftPoint:NSMakePoint(NSMidX(card) - hs.width / 2.0, hudTop)];
    [_hud orderFrontRegardless];
}

// 拖动只进"待保存"，点保存才写档：系统迁移窗口永远进不了这一层
- (void)saveCurrentPlace:(id)sender {
    if (![_places commitPending]) {
        DeskLog(@"没有待保存的拖动");
        [self updateHud];
        return;
    }
    [self saveConfig];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm";
    _savedStamp = [df stringFromDate:[NSDate date]];
    DeskLog(@"已保存档位位置 %@", _savedStamp);
    [self updateHud];
}

- (void)applyModel {
    NSUInteger i = 0;
    _applying = YES;
    for (NSScreen *screen in [NSScreen screens]) {
        if (i >= _windows.count) break;
        NSWindow *w = _windows[i++];
        DeskCardView *card = (DeskCardView *)w.contentView;
        [card updateModel:_model];   // 内部会重预渲染 Stand 素材
        NSRect frame = [self frameForSize:[DeskPanelView sizeForModel:_model] screen:screen];
        if (!NSEqualRects(w.frame, frame)) [w setFrame:frame display:YES animate:NO];
        [card setNeedsDisplay:YES];      // 背景采样图要跟位置与壁纸变化走
    }
    _applying = NO;
    [self updateHud];
}

- (void)reload {
    if ([NSScreen screens].count != _windows.count) { [self rebuildWindows]; return; }
    _model = [self loadModel];
    [self applyModel];
}

// 系统指标每拍都要重画，油价数据只在文件变化时重建
- (void)refreshStats {
    DeskStats *s = [_sys sample];
    [_model updateStats:s];
    [self applyModel];
    if (++_tick % 30 == 0) {   // 约每分钟留一条轨迹，证明在持续取数而不是停在某一帧
        DeskLog(@"刷新 CPU=%.0f%% GPU=%.0f%% 内存=%.1f/%.0fG 磁盘读=%.1f 写=%.1f MB/s",
                s.cpu, s.gpu, s.memUsed / 1e9, s.memTotal / 1e9, s.diskRead / 1e6, s.diskWrite / 1e6);
    }
}

- (void)startPolling {
    // 监听目录收不到"原地覆盖同一个文件"的写入，监听文件又会在原子替换后失效，
    // 所以轮询 mtime+size：任何写入方式（cp、编辑器保存、mv 替换）都能覆盖。
    [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(pollFile)
                                   userInfo:nil repeats:YES];
}

- (void)pollFile {
    NSString *stamp = [self currentStamp];
    BOOL same = (stamp && _stamp) ? [stamp isEqualToString:_stamp] : (stamp == _stamp);
    if (same) { [self refreshStats]; return; }
    _stamp = stamp;
    [self reload];
}

#pragma mark - 拖拽后归位

// 只有 DeskCardView 的 mouseDragged 会调到这里，所以进来的必然是用户亲手拖的。
// 存档不动，只挂"待保存"；点「保存」才落档
- (void)recordPendingPlaceInWindow:(NSWindow *)w {
    if (!w) return;
    NSScreen *screen = w.screen ?: [NSScreen mainScreen];
    NSRect vf = screen.visibleFrame;
    NSSize cardSize = [DeskPanelView sizeForModel:_model];
    NSRect f = w.frame;
    NSRect cf = NSInsetRect(f, (f.size.width - cardSize.width) / 2.0,
                            (f.size.height - cardSize.height) / 2.0);
    DeskPlace p;
    p.corner = (NSMidY(cf) > vf.origin.y + vf.size.height / 2.0 ? 0 : 2)
             + (NSMidX(cf) > vf.origin.x + vf.size.width / 2.0 ? 1 : 0);
    p.dx = MAX(0, (p.corner == 1 || p.corner == 3) ? NSMaxX(vf) - NSMaxX(cf) : cf.origin.x - vf.origin.x);
    p.dy = MAX(0, (p.corner >= 2) ? cf.origin.y - vf.origin.y : NSMaxY(vf) - NSMaxY(cf));
    [_places setPending:p forKey:[_places keyForScreen:screen]];
    [self updateHud];
}

// 屏幕参数变更期间（切分辨率、接拔显示器）系统会先平移现有窗口再发通知，
// 而且迁移可能滞后于我们建窗。所以：冻结存档 3 秒 + 稍后按存档把窗口重申两遍，
// 压住迟到的系统迁移
- (void)screenDidChange:(NSNotification *)note {
    DeskLog(@"屏幕参数变更，按存档重申位置");
    [self rebuildWindows];
    [self rebuildVaultWindows];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self reassertFrames]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self reassertFrames]; });
}

- (void)reassertFrames {
    if (_hidden) return;
    _applying = YES;
    NSUInteger i = 0;
    for (NSScreen *screen in [NSScreen screens]) {
        if (i >= _windows.count) break;
        NSWindow *w = _windows[i++];
        [w setFrame:[self frameForSize:[DeskPanelView sizeForModel:_model] screen:screen]
             display:YES animate:NO];
    }
    _applying = NO;
}

#pragma mark - 菜单栏

// 每个带动作的项都走这里，省得 target 写十遍
static NSMenuItem *DeskAddAction(NSMenu *menu, NSString *title, id target, SEL action) {
    NSMenuItem *it = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    it.target = target;
    return it;
}

// 两套外观标题一模一样、但各存各的档，所以必须是两个独立子菜单，不能共用一个
- (NSMenu *)styleMenuForAction:(SEL)action title:(NSString *)title {
    NSMenu *m = [[NSMenu alloc] initWithTitle:title];
    NSArray *names = @[@"实底卡（采样模糊）", @"羽化暗角", @"无底浮字", @"HUD 贴窗"];
    for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
        DeskAddAction(m, names[i], self, action).tag = i;
    }
    return m;
}

// 透明度按档给：档位落进 tag，选中哪档一眼可见，不用靠记忆
- (NSMenu *)vaultAlphaMenu {
    _vaultAlphaMenu = [[NSMenu alloc] initWithTitle:@"弹药库透明度"];
    for (NSInteger pct = kVaultAlphaMaxPct; pct >= (NSInteger)(kVaultAlphaMin * 100.0);
         pct -= kVaultAlphaStep) {
        DeskAddAction(_vaultAlphaMenu, [NSString stringWithFormat:@"%ld%%", (long)pct],
                      self, @selector(chooseVaultAlpha:)).tag = pct;
    }
    return _vaultAlphaMenu;
}

- (NSMenuItem *)addSubmenuTo:(NSMenu *)parent title:(NSString *)title menu:(NSMenu *)sub {
    NSMenuItem *it = [parent addItemWithTitle:title action:NULL keyEquivalent:@""];
    it.submenu = sub;
    return it;
}

// 菜单按「作用在哪个组件上」分层：两块面板各占一组。
// 调角和复位也各归各家——四角位移本来就是各存各的，
// 共享一个开关反而会出现「只想调弹药库却把卡片也撑开了」
- (void)buildStatusItem {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    _statusItem.button.image = DeskStatusGlyph();
    _statusItem.button.toolTip = @"DeskBoard 桌面小组件";

    NSMenu *menu = [NSMenu new];

    // ---- 组件 1：卡片面板（油价 / 系统状态 / 问候）----
    NSMenu *card = [[NSMenu alloc] initWithTitle:@"卡片面板"];
    _cardItem = DeskAddAction(card, @"显示 / 隐藏", self, @selector(toggleHidden:));
    [self addSubmenuTo:card title:@"外观" menu:[self styleMenuForAction:@selector(chooseStyle:)
                                                                  title:@"卡片外观"]];
    [card addItem:NSMenuItem.separatorItem];
    DeskAddAction(card, @"保存当前位置（拖完再点）", self, @selector(saveCurrentPlace:));
    [card addItem:NSMenuItem.separatorItem];
    _editItem = DeskAddAction(card, @"调角模式", self, @selector(toggleEditing:));
    DeskAddAction(card, @"复位角点", self, @selector(resetQuad:));
    [self addSubmenuTo:menu title:@"卡片面板（油价 · 系统状态 · 问候）" menu:card];

    // ---- 组件 2：弹药库 ARMORY（文件夹收纳）----
    NSMenu *vault = [[NSMenu alloc] initWithTitle:@"弹药库 ARMORY"];
    _vaultItem = DeskAddAction(vault, @"显示 / 隐藏", self, @selector(toggleVaultHidden:));
    [self addSubmenuTo:vault title:@"外观"
                  menu:[self styleMenuForAction:@selector(chooseVaultStyle:) title:@"弹药库外观"]];
    [self addSubmenuTo:vault title:@"透明度" menu:[self vaultAlphaMenu]];
    [vault addItem:NSMenuItem.separatorItem];
    DeskAddAction(vault, @"选文件/文件夹入库…", self, @selector(pickItemsToIngest:));
    [vault addItem:NSMenuItem.separatorItem];
    _vaultEditItem = DeskAddAction(vault, @"调角模式", self, @selector(toggleVaultEditing:));
    DeskAddAction(vault, @"复位角点", self, @selector(resetVaultQuad:));
    [self addSubmenuTo:menu title:@"弹药库 ARMORY（文件夹收纳）" menu:vault];

    [menu addItem:NSMenuItem.separatorItem];

    // ---- 全局 ----
    DeskAddAction(menu, @"打开数据目录…", self, @selector(openDataDir:));
    NSMenuItem *quit = DeskAddAction(menu, @"退出 DeskBoard", self, @selector(quit:));
    quit.keyEquivalent = @"q";

    _statusItem.menu = menu;
    [self syncMenu];
    DeskLog(@"菜单栏项 可见=%d 宽度=%.0f 按钮=%@ 图标=%.0fx%.0f", _statusItem.isVisible,
            _statusItem.length, _statusItem.button ? @"有" : @"无",
            _statusItem.button.image.size.width, _statusItem.button.image.size.height);
}

- (void)syncMenu {
    _statusItem.button.appearsDisabled = _hidden;
    for (NSMenuItem *it in _styleMenu.itemArray) {
        it.state = it.tag == _style ? NSControlStateValueOn : NSControlStateValueOff;
    }
    _cardItem.state = _hidden ? NSControlStateValueOff : NSControlStateValueOn;
    _editItem.state = _editing ? NSControlStateValueOn : NSControlStateValueOff;
    _vaultItem.state = _vaultHidden ? NSControlStateValueOff : NSControlStateValueOn;
    _vaultEditItem.state = _vaultEditing ? NSControlStateValueOn : NSControlStateValueOff;
    for (NSMenuItem *it in _vaultStyleMenu.itemArray) {
        it.state = it.tag == _vaultStyle ? NSControlStateValueOn : NSControlStateValueOff;
    }
    // 存档里的 alpha 只可能是 kVaultAlphaStep 的整数倍，四舍五入回整数再比对，避免浮点误差让勾跑掉
    NSInteger alphaPct = (NSInteger)(_vaultAlpha * 100.0 + 0.5);
    for (NSMenuItem *it in _vaultAlphaMenu.itemArray) {
        it.state = it.tag == alphaPct ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)chooseVaultStyle:(id)sender {
    _vaultStyle = [sender tag];
    for (NSWindow *w in _vaultWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskVaultView class]]) ((DeskVaultView *)v).style = (DeskStyle)_vaultStyle;
    }
    [self saveConfig];
    [self syncMenu];
    DeskLog(@"弹药库外观改为 %ld", (long)_vaultStyle);
}

- (void)chooseStyle:(id)sender {
    _style = [sender tag];
    [self saveConfig];
    [self rebuildWindows];
    [self syncMenu];
    DeskLog(@"外观改为 %ld", (long)_style);
}

// 开关调角会改变窗口外框（要留出拖角余量），所以整批重建而不是原地改。
// 两块各切各的：卡片只重建卡片窗口，弹药库只重建弹药库窗口，互不牵连
- (void)toggleEditing:(id)sender {
    _editing = !_editing;
    [self rebuildWindows];
    [self syncMenu];
    DeskLog(@"卡片调角模式：%@", _editing ? @"开" : @"关");
}

- (void)toggleVaultEditing:(id)sender {
    _vaultEditing = !_vaultEditing;
    [self rebuildVaultWindows];
    [self syncMenu];
    DeskLog(@"弹药库调角模式：%@", _vaultEditing ? @"开" : @"关");
}

// 四角位移本来各存各的，复位也就各归各的：
// 只清 _quad 的话，弹药库拖出来的形变会留着不动
- (void)resetQuad:(id)sender {
    _quad = DeskQuadOffsetsZero();
    [self applyQuadFromCard:_quad];
    [self rebuildWindows];
    DeskLog(@"卡片角点已复位");
}

- (void)resetVaultQuad:(id)sender {
    _vaultQuad = DeskQuadOffsetsZero();
    [self applyVaultQuad:_vaultQuad];
    DeskLog(@"弹药库角点已复位");
}

- (void)toggleHidden:(id)sender {
    _hidden = !_hidden;
    for (NSWindow *w in _windows) {
        if (_hidden) [w orderOut:nil]; else [w orderFrontRegardless];
    }
    [self updateHud];
    [self saveConfig];
    [self syncMenu];
    DeskLog(@"切换显示：%@", _hidden ? @"隐藏" : @"显示");
}

// 访达把文件夹拖到组件上的投递路径会因窗口层级、桌面图标层机制而失效，
// 所以再给一条完全不经拖放的入口：直接开访达选文件夹。
- (void)pickItemsToIngest:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    // 文件和文件夹都让选：能不能收由数据层的白名单说了算（vault.m 的
    // VaultItemKindForPath），面板只负责让人挑，挑中的不合规的那些会被静默丢掉
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.resolvesAliases = NO;   // 别名收进来只会变成一个点开是空的"假文件夹"，不放行
    panel.prompt = @"入库";
    panel.message = @"选中的文件夹和常见文件会搬进弹药库（之后可以从组件里退回桌面）";
    if ([panel runModal] != NSModalResponseOK) return;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *u in panel.URLs) if (u.path) [paths addObject:u.path];
    NSUInteger n = [[DeskVault shared] ingestPaths:paths];
    DeskLog(@"弹药库 选单入库 %lu 个（挑了 %lu 个）", (unsigned long)n,
            (unsigned long)panel.URLs.count);
    [self syncMenu];
}

- (void)openDataDir:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[self dataDir]]];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }

#pragma mark - 悬停预览浮窗

// 预览窗的内容视图。普通 NSView（不翻转），所以 NSImage 直接 drawInRect: 就是正的，
// 不需要像组件内部那样手动翻坐标空间 —— 那边是因为视图是翻转坐标才要翻回来。

// path 为 nil 就收起预览窗
- (void)updateVaultPreviewWithPath:(NSString *)path forWindow:(NSWindow *)owner {
    if (path.length == 0 || _vaultHidden || _vaultCoverHidden) {
        [_vaultPreviewWindow orderOut:nil];
        return;
    }
    // 优先用 720px 的大图；还没解好就先拿 160px 的小图顶着，绝不留空窗
    NSImage *img = VaultThumbPreview(path) ?: VaultThumbnail(path);
    if (!img) return;

    NSScreen *scr = owner.screen ?: [NSScreen mainScreen];
    NSRect vis = scr.visibleFrame;
    const CGFloat pad = 8.0, gap = 6.0;
    const CGFloat maxW = MIN(420.0, NSWidth(vis) - 24.0);
    const CGFloat maxH = MIN(280.0, NSHeight(vis) - 24.0);
    NSSize ts = img.size;
    CGFloat s = MIN(maxW / ts.width, maxH / ts.height);
    CGFloat w = MAX(120.0, ts.width * s) + pad * 2;
    CGFloat h = MAX(90.0, ts.height * s) + pad * 2;

    // 摆位：正对弹药库、浮在它上边；顶到屏幕上沿就改挂到下边，横向夹在可视区内
    NSRect comp = owner.frame;
    CGFloat x = MAX(NSMinX(vis) + 8.0, MIN(NSMidX(comp) - w / 2.0, NSMaxX(vis) - w - 8.0));
    CGFloat y = NSMaxY(comp) + gap;
    if (y + h > NSMaxY(vis) - 8.0) y = MAX(NSMinX(vis) + 8.0, NSMinY(comp) - h - gap);
    NSRect fr = NSMakeRect(round(x), round(y), round(w), round(h));

    if (!_vaultPreviewWindow) {
        _vaultPreviewWindow = [[NSWindow alloc] initWithContentRect:fr
                                                          styleMask:NSWindowStyleMaskBorderless
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO];
        [_vaultPreviewWindow setBackgroundColor:[NSColor clearColor]];
        _vaultPreviewWindow.opaque = NO;
        _vaultPreviewWindow.hasShadow = YES;
        _vaultPreviewWindow.releasedWhenClosed = NO;
        // 预览要真的看得见就得浮在应用窗口之上 —— 组件本身永远不破"永不浮在用户窗口上方"，
        // 这块窗是例外：它点击穿透、不抢激活、只在鼠标停在图片卡上时存在、移开即消失
        _vaultPreviewWindow.level = NSFloatingWindowLevel;
        _vaultPreviewWindow.ignoresMouseEvents = YES;   // 不点穿就会挡住下面的卡片
        _vaultPreviewWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                               | NSWindowCollectionBehaviorStationary
                                               | NSWindowCollectionBehaviorIgnoresCycle;
    }
    DeskVaultPreviewView *cv = (DeskVaultPreviewView *)_vaultPreviewWindow.contentView;
    if (![cv isKindOfClass:[DeskVaultPreviewView class]]) {
        cv = [[DeskVaultPreviewView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(fr), NSHeight(fr))];
        _vaultPreviewWindow.contentView = cv;
    }
    cv.frame = NSMakeRect(0, 0, NSWidth(fr), NSHeight(fr));
    cv.image = img;
    cv.tint = VaultTintForKind(VaultItemImage);
    if (!NSEqualRects(_vaultPreviewWindow.frame, fr)) [_vaultPreviewWindow setFrame:fr display:YES];
    [_vaultPreviewWindow orderFrontRegardless];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // 必须在起 UI 之前处理完：写完就退出，不能让它占着单例锁再开一个实例
        DeskBoardApp *delegate = [DeskBoardApp new];
        NSApp = [NSApplication sharedApplication];
        [NSApp setDelegate:delegate];
        DeskLog(@"进程启动 pid=%d", getpid());
        [NSApp run];
    }
    return 0;
}