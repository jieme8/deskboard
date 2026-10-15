// DeskBoard — 贴在桌面层的小组件：毛玻璃卡片 + 可拖拽 + 菜单栏图标
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <fcntl.h>
#import <unistd.h>
#import "model.h"
#import "panel_view.h"
#import "places.h"
#import "hud.h"
#import "sysmon.h"

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

@interface DeskBoardApp : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation DeskBoardApp {
    NSStatusItem *_statusItem;
    NSMenu *_styleMenu;
    NSMenuItem *_editItem;
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
    BOOL _editing;              // 调角模式
    DeskQuadOffsets _quad;      // 四角位移，全 0 就是没变形
    BOOL _applying;             // 我们自己 setFrame 时别再回读位置，免得和拖拽互相触发
    int _lockFD;
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
    NSNumber *styleVal = [ud objectForKey:K(@"Style")];
    // 旧的"透视站立"已经并到调角里，存过的值越界就退到 HUD
    _style = styleVal ? MIN(styleVal.integerValue, (NSInteger)DeskStyleHUD) : DeskStyleFeather;
    _quad = DeskQuadOffsetsFromString([ud stringForKey:K(@"Quad")]);

    [self prepareDataDir];
    if (![self acquireSingleInstanceLock]) exit(0);   // 两个实例会各画一张卡，别靠运气
    _sys = [DeskSysMonitor new];
    [_sys sample];   // 先取一次基线，下一拍才有差值型指标
    [self buildStatusItem];
    [self rebuildWindows];
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

- (void)buildStatusItem {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    _statusItem.button.image = DeskStatusGlyph();
    _statusItem.button.toolTip = @"DeskBoard 桌面小组件";

    NSMenu *menu = [NSMenu new];
    NSMenuItem *toggle = [menu addItemWithTitle:@"显示/隐藏"
                                         action:@selector(toggleHidden:)
                                  keyEquivalent:@""];
    toggle.target = self;

    NSMenuItem *styleItem = [menu addItemWithTitle:@"外观" action:NULL keyEquivalent:@""];
    _styleMenu = [NSMenu new];
    NSArray *styleNames = @[@"实底卡（采样模糊）", @"羽化暗角", @"无底浮字", @"HUD 贴窗"];
    for (NSInteger i = 0; i < (NSInteger)styleNames.count; i++) {
        NSMenuItem *it = [_styleMenu addItemWithTitle:styleNames[i]
                                               action:@selector(chooseStyle:)
                                        keyEquivalent:@""];
        it.target = self;
        it.tag = i;
    }
    styleItem.submenu = _styleMenu;

    NSMenuItem *save = [menu addItemWithTitle:@"保存当前位置"
                                       action:@selector(saveCurrentPlace:)
                                keyEquivalent:@""];
    save.target = self;
    _editItem = [menu addItemWithTitle:@"调角模式" action:@selector(toggleEditing:) keyEquivalent:@""];
    _editItem.target = self;
    NSMenuItem *reset = [menu addItemWithTitle:@"复位角点" action:@selector(resetQuad:) keyEquivalent:@""];
    reset.target = self;

    NSMenuItem *reveal = [menu addItemWithTitle:@"打开数据目录…"
                                         action:@selector(openDataDir:)
                                  keyEquivalent:@""];
    reveal.target = self;

    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [menu addItemWithTitle:@"退出 DeskBoard"
                                       action:@selector(quit:)
                                keyEquivalent:@"q"];
    quit.target = self;

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
    _editItem.state = _editing ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)chooseStyle:(id)sender {
    _style = [sender tag];
    [self saveConfig];
    [self rebuildWindows];
    [self syncMenu];
    DeskLog(@"外观改为 %ld", (long)_style);
}

// 开关调角会改变窗口外框（要留出拖角余量），所以整批重建而不是原地改
- (void)toggleEditing:(id)sender {
    _editing = !_editing;
    [self rebuildWindows];
    [self syncMenu];
    DeskLog(@"调角模式：%@", _editing ? @"开" : @"关");
}

- (void)resetQuad:(id)sender {
    _quad = DeskQuadOffsetsZero();
    [self applyQuadFromCard:_quad];
    [self rebuildWindows];
    DeskLog(@"角点已复位");
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

- (void)openDataDir:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[self dataDir]]];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        DeskBoardApp *delegate = [DeskBoardApp new];
        NSApp = [NSApplication sharedApplication];
        [NSApp setDelegate:delegate];
        DeskLog(@"进程启动 pid=%d", getpid());
        [NSApp run];
    }
    return 0;
}
