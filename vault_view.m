#import "vault_view.h"
#import "vault_art.h"
#import "backdrop.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - 布局常量
// 纵向节奏：抬头 42 → 卡架两行 → 库位条 → 操作坞，窗口高度全部由这几项推出来，
// 以后想让组件高一点只改这里的数字，不会出现"画布留白"和"控件错位"两张皮。

static const CGFloat kPadX        = 15.0;
static const CGFloat kPadTop      = 13.0;
static const CGFloat kHeaderH     = 42.0;
static const CGFloat kHeaderGap   = 10.0;
static const NSInteger kCols      = 3;
static const NSInteger kRows      = 2;
static const CGFloat kCardW       = 128.0;
static const CGFloat kCardH       = 76.0;
static const CGFloat kCardGapX    = 9.0;
static const CGFloat kCardGapY    = 9.0;
static const CGFloat kGridInsetX  = 15.0;    // (432 - (128*3 + 9*2)) / 2，卡架居中
static const CGFloat kGridTop     = kPadTop + kHeaderH + kHeaderGap;   // 65
static const CGFloat kGridH       = kCardH * kRows + kCardGapY * (kRows - 1);   // 161
static const CGFloat kStripY      = kGridTop + kGridH + 6.0;          // 232
static const CGFloat kStripH      = 14.0;
static const CGFloat kDockY       = kStripY + kStripH + 10.0;         // 256
static const CGFloat kDockH       = 26.0;
static const CGFloat kDockBtnH    = 24.0;

const CGFloat kVaultViewWidth  = 432.0;
const CGFloat kVaultViewHeight = kDockY + kDockH + 12.0;               // 294

static NSSize DeskVaultViewCardSize(void) { return NSMakeSize(kVaultViewWidth, kVaultViewHeight); }
const NSUInteger kVaultSlotCapacity = 12;

// 缓动的"响应频率"：越大越快。半程大约 0.2~0.25/omega 秒。
// 入库 8.5 → 约 250ms 从下方浮上来并稳住；悬停 16 → 约 130ms，跟手但不生硬
static const double kFlashDur = 0.40;     // 白闪整段时长，进出各占一半
static const double kAppearOmega = 8.5;
static const double kHoverOmega  = 16.0;
static const CGFloat kSweepPeriod = 8.0;     // 扫描带跑完一趟的秒数，后面留一段空档
static const CGFloat kSweepRun    = 6.2;
static const CGFloat kDragThresh  = 5.0;

#define kDockCount 4                          // 扫桌面 / 开库 / 全退 / 收起

static NSColor *VC(int r, int g, int b, double a) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

// 无底 / HUD 两档没有暗角垫在下面，文字必须自带投影才读得清。
// 做成全局状态而不是逐处传参：绘制路径里有十几处 Attrs 调用，
// 每一处都判断一遍外观既啰嗦又容易漏。
static BOOL gNeedTextShadow = NO;
static DeskStyle gStyle = DeskStylePlate;

// Bare 和 HUD 两档底板几乎一样，真正拉开距离的是配色：
// Bare 是白字黑影的中性浮字，HUD 是青色描边 + 青色字的仪表感。
// 和 gNeedTextShadow 一样做成全局状态，省得十几处调用点各写一遍外观判断。
static NSColor *Pri(void) {
    return gStyle == DeskStyleHUD ? [VaultCyanBright() colorWithAlphaComponent:0.96] : VaultPaper();
}

static NSColor *Mut(void) {
    return gStyle == DeskStyleHUD ? [VaultCyan() colorWithAlphaComponent:0.88] : VaultMuted();
}

static NSDictionary *Attrs(NSFont *f, NSColor *c) {
    if (!gNeedTextShadow) return @{NSFontAttributeName: f, NSForegroundColorAttributeName: c};
    NSShadow *sh = [NSShadow new];
    sh.shadowColor = [NSColor colorWithWhite:0.0 alpha:0.8];
    sh.shadowBlurRadius = 5.0;
    sh.shadowOffset = NSMakeSize(0, -1.2);
    return @{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSShadowAttributeName: sh};
}

static NSFont *FTitle(void)  { return [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold]; }
static NSFont *FSub(void)    { return [NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightMedium]; }
static NSFont *FCardName(void) { return [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold]; }
static NSFont *FMeta(void)   { return [NSFont monospacedDigitSystemFontOfSize:9.0 weight:NSFontWeightMedium]; }
static NSFont *FTime(void)   { return [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightRegular]; }
static NSFont *FDock(void)   { return [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium]; }
static NSFont *FStrip(void)  { return [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightRegular]; }
static NSFont *FRing(void)   { return [NSFont monospacedDigitSystemFontOfSize:10.0 weight:NSFontWeightSemibold]; }
static NSFont *FBig(void)    { return [NSFont monospacedDigitSystemFontOfSize:13.0 weight:NSFontWeightSemibold]; }
static NSFont *FEmpty(void)  { return [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium]; }

// 让文字的「视觉中心」落在 centerY 上，返回给 drawAtPoint: 用的 baseline。
//
// 这个坑踩过两次，值得写清楚：本视图是翻转坐标（isFlipped=YES，y 向下增长），
// 而 NSString 的 drawAtPoint: 把参数当 baseline 用。实测（像素级扫描，不是推公式）：
// 在这个翻转上下文里，文字的着墨范围落在 baseline 的「下方」约 (ascender-descender)/2 处，
// 也就是说墨迹中心 ≈ baseline + (ascender - descender)/2。
//
// 所以想让墨迹中心对齐 centerY，baseline 必须往「上」减这么多，而不是加。
// 之前写成 centerY + ascender/2 会把文字整体推到按钮下方约 11pt，直接掉出胶囊外。
static CGFloat VaultBaselineForCenter(NSFont *font, CGFloat centerY) {
    return centerY - (font.ascender - font.descender) / 2.0;
}

static NSString *const kDockLabels[kDockCount] = { @"扫桌面", @"开库", @"全退", @"收起" };

@interface DeskVaultView () <NSDraggingSource>
@end

@implementation DeskVaultView {
    NSArray<DeskVaultItem *> *_previewItems;   // 预览模式下的假数据；正常运行是 nil
    NSMutableDictionary<NSString *, NSNumber *> *_appear;  // 入库动画进度，按入库时刻索引

    NSInteger _hoverCard, _hoverDock, _hoverEject, _selected;
    // 选中态也要过渡：点一下卡片就跳到选中样式，和悬停原本一样生硬
    CGFloat   _selectedK;
    // 悬停的平滑量：0~1，按 target 方向做指数趋近。以前 hovered 是纯布尔，
    // 填充/描边/退回按钮都是"啪"一下到位，看着生硬；改成让这些值吃这个渐变量，
    // 鼠标进出一张卡就是一次柔和的淡入淡出
    CGFloat   _hoverCardK, _hoverDockK, _hoverEjectK;
    // 悬停预览（只对图片卡片）：_hoverPreview 是正在预览的卡片序号，-1 = 无。
    // 不做延迟也不做过渡 —— 要的就是鼠标一停就立刻出现，毫秒级。
    NSInteger _hoverPreview;
    CGFloat   _previewK;
    NSInteger _dropCount;                      // 悬停时这批能收几个文件夹
    CGFloat   _dropHot;                        // 0~1，投喂区亮起的过渡
    CGFloat   _scroll, _scrollTarget;
    double    _sweepT;                         // 扫描带相位
    double    _flashT;                         // 退库/入库后的一下白闪：0→1→0 的包络时间
    double    _flashK;                         // 白闪当前强度（0~1），起落都走缓动
    NSPoint   _pressPoint;
    NSEvent  *_pressEvent;
    BOOL      _warnedNoPasteboard;
    NSArray<NSString *> *_lastRejectedDrop;  // 最近一次拖放里被白名单拒掉的那些名字
    NSInteger _pressDock;         // 按下的操作坞按钮，等松手确认
    NSInteger _traceTick;
    BOOL      _flatDirty;
    double    _flatAccum;
    NSImage  *_wallpaper;          // 组件背后那块真实桌面的采样，自带缓存
    NSRect    _wallpaperRect;
    NSDate *_wallpaperAt;
    NSRect    _standInScreenRect;  // 离屏渲染时的替身窗口位置

    DeskVaultView *_flatSource;     // 变形时的离屏素材源：先把组件画成正的一张
    NSWindow *_flatHost;
    NSBitmapImageRep *_flatRep;
    NSInteger _dragCorner;          // 调角时正在拖的那个角，-1 = 没在拖
    NSInteger _pressCard;
    DeskVaultItem *_draggingItem;              // 正在往库外拖的那一条
    BOOL      _dragCardOut;
    BOOL      _movingWindow;
    NSPoint   _dragStartMouse;        // 按下时鼠标的屏幕坐标
    NSRect    _frameAtDragStart;      // 按下时窗口的屏幕位置
    NSTrackingArea *_track;
}

#pragma mark - 生命周期

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self commonInit];
        [self prefetchThumbnails];   // 第一帧就开始在后台解缩略图
    }
    return self;
}

- (instancetype)initWithItems:(NSArray<DeskVaultItem *> *)items {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, kVaultViewWidth, kVaultViewHeight)])) {
        [self commonInit];
        _previewItems = [items copy];
        [self syncAppear];
    }
    return self;
}

- (void)commonInit {
    _appear = [NSMutableDictionary dictionary];
    _hoverCard = _hoverDock = _hoverEject = _selected = _pressDock = -1;
    _hoverCardK = _hoverDockK = _hoverEjectK = 0.0;
    _selectedK = 0.0;
    // 悬停预览的状态同样必须显式归零：_hoverPreview 是 NSInteger，默认 0 会让
    // 还没进过任何卡片时就被当成"正在预览第 0 张"
    _hoverPreview = -1;
    _previewK = 0.0;
    // _pressCard 必须一起归 -1：NSInteger 成员默认是 0，漏掉的话 isDragging 里的
    // `_pressCard >= 0` 恒真，这个方法会永远返回 YES。而自动隐藏是它的第一个调用方，
    // 一旦恒真，弹药库就永远等不到"没在拖"的时刻，被盖住时再也不会收起。
    _pressCard = -1;
    _dragCorner = -1;
    _sweepT = 0;
    _quadOffsets = DeskQuadOffsetsZero();
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSFilenamesPboardType]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vaultChanged:)
                                                 name:kVaultChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(thumbnailsReady:)
                                                 name:@"VaultThumbnailsReady" object:nil];
    [self updateTrackingAreas];
}

// NSTrackingArea 的 rect 没有公开 setter，尺寸变了只能整块重建
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_track) [self removeTrackingArea:_track];
    _track = [[NSTrackingArea alloc] initWithRect:self.bounds options:(NSTrackingMouseMoved |
                                                                    NSTrackingMouseEnteredAndExited |
                                                                    NSTrackingActiveInKeyWindow)
                                           owner:self userInfo:nil];
    [self addTrackingArea:_track];
}

// 离屏素材源没人给它 tick，入库动画会永远停在 0 进度——那就是"卡片整片消失"。
// 烘位图之前先把动画一次性推到终态。
NSRect VaultDragFrame(NSRect frameAtStart, NSPoint mouseAtStart, NSPoint mouseNow) {
    NSRect f = frameAtStart;
    f.origin = NSMakePoint(round(frameAtStart.origin.x + mouseNow.x - mouseAtStart.x),
                           round(frameAtStart.origin.y + mouseNow.y - mouseAtStart.y));
    return f;
}

- (BOOL)isDragging {
    return _movingWindow || _pressCard >= 0 || _dragCardOut || _dropCount > 0;
}

- (void)settleAppearAnimations {
    for (NSString *k in _appear.allKeys) _appear[k] = @1.0;
}

- (void)applyPreviewHoverCard:(NSInteger)card dock:(NSInteger)dock dropHot:(double)hot
                   dropCount:(NSInteger)count scroll:(CGFloat)scroll {
    _hoverCard = card;
    _hoverEject = -1;
    _hoverDock = dock;
    _dropHot = hot;
    _dropCount = count;
    _scroll = _scrollTarget = scroll;
    // 悬停量也直接推到终态，跟入库动画一个口径：预览只画最终样子，
    // 不然离线渲染永远截不到"淡入到一半"那几帧
    _hoverCardK = (card >= 0) ? 1.0 : 0.0;
    _hoverDockK = (dock >= 0) ? 1.0 : 0.0;
    _hoverEjectK = 0.0;
    [self settleAppearAnimations];   // 预览一律画终态，别截到动画中途
    [self setNeedsDisplay:YES];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
+ (NSSize)windowSizeWarped:(BOOL)warped {
    // 四角拖出去以后会超出卡片矩形，窗口不留这一圈就会被裁掉
    return warped ? DeskQuadCanvasSize(DeskVaultViewCardSize()) : DeskVaultViewCardSize();
}

- (DeskQuad)currentQuad { return DeskQuadFromOffsets(DeskVaultViewCardSize(), _quadOffsets); }
- (BOOL)isWarped { return !DeskQuadOffsetsIsZero(_quadOffsets) || _editing; }
- (NSSize)cardSize { return DeskVaultViewCardSize(); }

- (void)setStandInScreenRect:(NSRect)r { _standInScreenRect = r; [self setNeedsDisplay:YES]; }

// 组件必须独吞鼠标事件：卡架、操作坞、拖角、拖窗口全在同一个 view 里处理，
// 事件落到子视图上就没人接了（鼠标事件不沿响应链上传）
- (NSView *)hitTest:(NSPoint)point { return self; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)canBecomeKeyView { return NO; }

- (DeskVault *)vault { return _previewItems ? nil : [DeskVault shared]; }

- (NSArray<DeskVaultItem *> *)items { return _previewItems ?: [DeskVault shared].items; }

// 库里那张图的真实路径。预览模式（_previewItems）没有真实 vault，
// 那时缩略图取不到，卡片自动退回剪影图形，不会开天窗。
- (NSString *)vaultPathForItem:(DeskVaultItem *)it {
    if (!it || it.storedName.length == 0) return nil;
    if (_previewItems) return nil;
    return [[DeskVault shared] pathForItem:it];
}

// 库里图片的缩略图在后台解，60fps 的重绘路径上不碰解码。
// 清单一变就重新报一遍名单：已缓存且文件没动的自动跳过，
// 已经退回桌面 / 全退掉的顺手从缓存里摘掉，位图不会只进不出。
- (void)prefetchThumbnails {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (DeskVaultItem *it in [self items]) {
        if (it.kind != VaultItemImage) continue;
        NSString *p = [self vaultPathForItem:it];
        if (p) [paths addObject:p];
    }
    VaultThumbPruneTo(paths);
    VaultThumbPrefetch(paths);
}

- (void)vaultChanged:(NSNotification *)n {
    [self syncAppear];
    _selected = -1;
    _flatDirty = YES;
    [self prefetchThumbnails];
    [self setNeedsDisplay:YES];
}

// 后台解码完成：把已经解好的缩略图换到卡面上。
// 通知由缓存层切回主线程再发，这里只会跑在主线程上。
- (void)thumbnailsReady:(NSNotification *)n {
    if (self.superview) [self setNeedsDisplay:YES];   // 离屏渲染素材没人接收通知，不必唤醒
    // 预览大图可能刚解好，让外面重画一次预览窗（否则要等下次鼠标移动才换上清晰的）
    if (_hoverPreview >= 0) {
        NSString *p = [self vaultPathForItem:[self items][_hoverPreview]];
        [self firePreviewPath:p];
    }
}

- (NSString *)appearKeyFor:(DeskVaultItem *)it {
    return [NSString stringWithFormat:@"%lld", it.ingestedAt];
}

- (void)syncAppear {
    NSMutableSet *live = [NSMutableSet set];
    for (DeskVaultItem *it in [self items]) {
        NSString *k = [self appearKeyFor:it];
        [live addObject:k];
        if (!_appear[k]) _appear[k] = @0.0;   // 新出现的从 0 开始播入库动画
    }
    for (NSString *k in [_appear.allKeys copy]) {
        if (![live containsObject:k]) [_appear removeObjectForKey:k];
    }
}

#pragma mark - 动画

// 统一的缓动原语。
//
// 之前所有过渡都是 v += (target - v) * dt * rate 这种纯指数趋近，问题是它没有"终点"：
// 剩下的距离越小走得越慢，永远逼近不到，于是每帧都在动、鼠标一停还在微微漂，
// 观感就是"啪一下冲过去再慢慢磨"。而且 rate 调大只会让开头更突兀。
//
// 这里改成临界阻尼弹簧（跟 macOS / CSS 的 ease-out 同一思路）：
//   速度 v = (target - x) * 响应频率          —— 离目标越远越快
//   每步把速度限幅到不越过目标                  —— 不会来回振荡
//   x += v * dt
// 于是起步速度跟距离成正比（一次到位），临近目标时自然减速收住（不磨）。
// 半程大约在 0.2~0.25*omega 时间内完成，omega 越大越快。
static double VaultEaseStep(double x, double target, double dt, double omega) {
    double v = (target - x) * omega;
    double step = v * dt;
    // 不许越过目标：跨过去就正好落在 target 上，不会冲过头再弹回来
    if ((target - x > 0.0 && step > target - x) || (target - x < 0.0 && step < target - x)) {
        return target;
    }
    return x + step;
}

// 收敛判定：剩下的量小于它本身一个很小的比例就算到位，把浮点尾巴剪掉
static BOOL VaultEaseDone(double x, double target, double eps) {
    return fabs(target - x) < eps;
}

// 任何一次"我要重画"都顺手把动画表叫回来。空闲时外面把 60fps 的表停了，
// 靠这一个钩子恢复：比在每个交互入口各挂一遍省事，也不会挂漏一个就出现
// "鼠标悬停没反应"这种极难查的毛病。
- (void)setNeedsDisplay:(BOOL)flag {
    [super setNeedsDisplay:flag];
    if (flag && self.onNeedFrames) self.onNeedFrames();
}

- (void)tick:(double)dt {
    _sweepT += dt;
    [self maybeRefreshFlat:dt];
    if (_sweepT > kSweepPeriod) _sweepT -= kSweepPeriod;

    BOOL mutated = NO;
    // 入库动画：原来是 v += dt/时长 的匀速累加。线性插值在任何界面里都读作“生硬”——
    // 起步没有加速、结尾没有减速，像被人匀速推着走。改走下面那条缓动曲线。
    for (NSString *k in _appear.allKeys) {   // 要复制一份：循环体里往同一个字典写值
        double v = _appear[k].doubleValue;
        if (v < 1.0) {
            double nv = VaultEaseStep(v, 1.0, dt, kAppearOmega);
            _appear[k] = @(VaultEaseDone(nv, 1.0, 0.002) ? 1.0 : nv);
            mutated = YES;
        }
    }
    // 悬停走同一条曲线。omega 比入库小一点，鼠标扫过是柔和的淡入淡出而不是一跳
    CGFloat *hovers[4] = { &_hoverCardK, &_hoverDockK, &_hoverEjectK, &_selectedK };
    NSInteger hovTargets[4] = { _hoverCard, _hoverDock, _hoverEject, _selected };
    for (int i = 0; i < 4; i++) {
        double tgt = (hovTargets[i] >= 0) ? 1.0 : 0.0;
        double x = *hovers[i];
        if (!VaultEaseDone(x, tgt, 0.002)) {
            double nx = VaultEaseStep(x, tgt, dt, kHoverOmega);
            *hovers[i] = VaultEaseDone(nx, tgt, 0.002) ? tgt : nx;
            mutated = YES;
        }
    }
    if (!VaultEaseDone(_dropHot, _dropCount > 0 ? 1.0 : 0.0, 0.002)) {
        double tgt = (_dropCount > 0 ? 1.0 : 0.0);
        double nx = VaultEaseStep(_dropHot, tgt, dt, 12.0);
        _dropHot = VaultEaseDone(nx, tgt, 0.002) ? tgt : nx;
        mutated = YES;
    }
    if (fabs(_scroll - _scrollTarget) > 0.1) {
        double nx = VaultEaseStep(_scroll, _scrollTarget, dt, 15.0);
        _scroll = (fabs(_scrollTarget - nx) < 0.1) ? _scrollTarget : nx;
        // 滚动时卡片在动，预览会指错对象，直接收掉
        if (_hoverPreview >= 0) { _hoverPreview = -1; _previewK = 0; [self firePreviewPath:nil]; }
        mutated = YES;
    }
    // 白闪走一个 0→1→0 的包络：进场往 1 走，出场往 0 走，两段都是缓动，
    // 不再是「按下去就开始线性变淡」那种一刀切的闪
    if (_flashT > 0) {
        _flashT = MAX(0.0, _flashT - dt);
        double half = kFlashDur / 2.0;
        double tgt = (_flashT > half) ? 1.0 : 0.0;
        double nx = VaultEaseStep(_flashK, tgt, dt, 22.0);
        _flashK = VaultEaseDone(nx, tgt, 0.004) ? tgt : nx;
        if (_flashT <= 0.0) _flashK = 0.0;
        mutated = YES;
    }
    if (mutated) [self setNeedsDisplay:YES];
}

- (BOOL)needsRedraw {
    if (_dropHot > 0.001 && _dropHot < 0.999) return YES;
    if (_flashT > 0 || _flashK > 0.004) return YES;
    if (fabs(_scroll - _scrollTarget) > 0.1) return YES;
    // 悬停缓动还在跑就得继续重绘，否则降频会把淡入淡出冻在半路
    if (fabs(_hoverCardK - (_hoverCard >= 0 ? 1.0 : 0.0)) > 0.002) return YES;
    if (fabs(_hoverDockK - (_hoverDock >= 0 ? 1.0 : 0.0)) > 0.002) return YES;
    if (fabs(_hoverEjectK - (_hoverEject >= 0 ? 1.0 : 0.0)) > 0.002) return YES;
    if (fabs(_selectedK - (_selected >= 0 ? 1.0 : 0.0)) > 0.002) return YES;
    for (NSNumber *v in _appear.allValues) if (v.doubleValue < 1.0) return YES;
    return NO;   // 剩下的只有慢扫描带，由调用方按低频刷新
}

- (double)currentSweep {
    if (self.isWarped) return -1.0;   // 变形时整块已经烘成位图，扫描带动不了只会逼着重烘
    // 扫描带是"你在用它"的时候才活的装饰。它常年跑，就等于逼着组件常年重绘 ——
    // 实测 DeskBoard 因此一直按 20fps 全量重画五张卡片，能耗影响冲到 88.5
    if (![self needsRedraw] && ![self isDragging]) return -1.0;
    if (_sweepT >= kSweepRun) return -1.0;   // 空档期不画
    return -0.15 + (_sweepT / kSweepRun) * 1.3;
}

- (void)flash { _flashT = kFlashDur; _flashK = 0.0; [self setNeedsDisplay:YES]; }

#pragma mark - 几何

// 未变形时布局基准就是整个视图；变形后视图是撑出一圈余量的画布，
// 排版必须退回"卡片那块"，否则所有东西都会偏出去一圈
- (NSRect)layoutArea {
    if (!self.isWarped) return self.bounds;
    return NSMakeRect(kDeskQuadPad, kDeskQuadPad, kVaultViewWidth, kVaultViewHeight);
}

- (NSRect)cardRectAtIndex:(NSInteger)idx in:(NSRect)b {
    if (idx < 0) return NSZeroRect;
    NSInteger col = idx % kCols, row = idx / kCols;
    return NSMakeRect(NSMinX(b) + kGridInsetX + col * (kCardW + kCardGapX),
                      kGridTop + row * (kCardH + kCardGapY) - _scroll,
                      kCardW, kCardH);
}

- (NSInteger)cardIndexAtPoint:(NSPoint)p in:(NSRect)b {
    NSInteger count = (NSInteger)[self items].count;
    for (NSInteger i = 0; i < count; i++) {
        if (NSPointInRect(p, NSInsetRect([self cardRectAtIndex:i in:b], -3, -3))) return i;
    }
    return -1;
}

- (CGFloat)dockButtonWidth:(NSInteger)i {
    NSString *label = kDockLabels[i];
    CGFloat tw = [label sizeWithAttributes:Attrs(FDock(), Pri())].width;
    return ceil(9.0 + 12.0 + 5.0 + tw + 10.0);
}

- (NSArray<NSValue *> *)dockButtonRectsIn:(NSRect)b {
    NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:kDockCount];
    CGFloat x = NSMinX(b) + kGridInsetX;
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat w = [self dockButtonWidth:i];
        [out addObject:[NSValue valueWithRect:NSMakeRect(x, kDockY + 1.0, w, kDockBtnH)]];
        x += w + 7.0;
    }
    CGFloat hw = [self dockButtonWidth:3];
    [out addObject:[NSValue valueWithRect:NSMakeRect(NSMaxX(b) - kGridInsetX - hw, kDockY + 1.0, hw, kDockBtnH)]];
    return out;
}

- (NSInteger)dockIndexAtPoint:(NSPoint)p in:(NSRect)b {
    NSArray<NSValue *> *rs = [self dockButtonRectsIn:b];
    for (NSInteger i = 0; i < (NSInteger)rs.count; i++) {
        if (NSPointInRect(p, rs[i].rectValue)) return i;
    }
    return -1;
}

- (NSRect)ejectRectIn:(NSRect)card { return NSMakeRect(NSMaxX(card) - 8.0 - 16.0, NSMinY(card) + 6.0, 16.0, 16.0); }

- (CGFloat)maxScroll {
    NSInteger extra = (NSInteger)[self items].count - kCols * kRows;
    if (extra <= 0) return 0;
    return MIN(extra * (kCardH + kCardGapY), 400.0);
}

#pragma mark - 变形

- (void)setQuadOffsets:(DeskQuadOffsets)o { _quadOffsets = o; [self syncWarp]; }

- (void)setEditing:(BOOL)e {
    if (e == _editing) return;
    _editing = e;
    [self syncWarp];
}

// style 原来是个裸 property，改它什么都不触发：没重绘，也没告诉变形位图。
// 变形态下整张组件是从 _flatSource 烘出来的 _flatRep，不同步过去的话
// 进调角后无论选哪种外观，画面都是 _flatSource 自己的默认样式
- (void)setStyle:(DeskStyle)s {
    if (s == _style) return;
    _style = s;
    // 位图得重烘：光标脏，外层才会重新烘一遍 _flatRep
    [_flatSource setStyle:s];
    _flatDirty = YES;
    [self setNeedsDisplay:YES];
}

// 和卡片面板同一条路：正视图画不出透视，只能先画正的去采样再 warp。
// 没变形时走实时绘制，文字才是原生清晰度。
- (void)syncWarp {
    if (!self.isWarped) {
        _flatSource = nil;
        _flatHost = nil;
        _flatRep = nil;
        [self setNeedsDisplay:YES];
        return;
    }
    if (!_flatHost) {
        NSRect inner = NSMakeRect(0, 0, kVaultViewWidth, kVaultViewHeight);
        _flatHost = [[NSWindow alloc] initWithContentRect:inner
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered defer:NO];
        [_flatHost setBackgroundColor:[NSColor clearColor]];
        _flatHost.opaque = NO;
        // 预览工具（_previewItems）才用假数据快照；真实运行必须让素材源保持真实 vault 模式。
        // 走 initWithItems: 会把 _previewItems 钉在素材源上，缩略图按路径解析就全拿不到了 ——
        // 结果是「一进调角，图片卡片全退回剪影图形」，而没变形时又好好的。
        _flatSource = _previewItems
            ? [[DeskVaultView alloc] initWithItems:_previewItems]
            : [[DeskVaultView alloc] initWithFrame:inner];
        _flatSource.autoresizingMask = NSViewNotSizable;   // 别跟着宿主窗口被撑开
        // 素材视图得继承外观：它烘出来的位图就是变形时用户看到的那张，
        // 漏了这一句，进调角的第一帧就已经是错的样式了
        [_flatSource setStyle:self.style];
        [_flatSource setStandInScreenRect:[self cardScreenRect]];
        _flatHost.contentView = _flatSource;   // 从不上屏，只当渲染素材
    }
    [_flatSource setStandInScreenRect:[self cardScreenRect]];
    _flatDirty = YES;
    [self setNeedsDisplay:YES];
}

- (void)refreshFlat {
    if (!_flatSource) return;
    [_flatSource settleAppearAnimations];
    [_flatSource syncAppear];
    [_flatSource settleAppearAnimations];
    // 宿主窗口只当"素材画板"用，尺寸必须始终等于组件本体：
    // 一旦跟外窗一样大，contentView 会被自动撑开，底板铺满而内容缩在左上角
    NSRect wf = self.window.frame;
    [_flatHost setFrame:NSMakeRect(NSMidX(wf) - kVaultViewWidth / 2.0,
                                   NSMidY(wf) - kVaultViewHeight / 2.0,
                                   kVaultViewWidth, kVaultViewHeight) display:NO];
    NSRect src = NSMakeRect(0, 0, kVaultViewWidth, kVaultViewHeight);
    _flatSource.frame = src;
    NSBitmapImageRep *rep = [_flatSource bitmapImageRepForCachingDisplayInRect:src];
    [_flatSource cacheDisplayInRect:src toBitmapImageRep:rep];
    _flatRep = rep;
    _flatDirty = NO;
}

// 变形时整张组件已经是一张位图了，逐帧重烘一次太贵，限流到 15fps；
// 顺带把慢扫描带关掉——它在变形位图里本来就看不出移动
- (void)maybeRefreshFlat:(double)dt {
    if (!self.isWarped || !_flatSource) return;
    _flatAccum += dt;
    BOOL animating = [self needsRedraw];
    if (!_flatDirty && !animating) return;
    if (_flatAccum < (animating ? 0.0 : 0.25)) return;
    _flatAccum = 0;
    [self refreshFlat];
}

- (NSPoint)canvasPointFromEvent:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    return NSMakePoint(p.x, self.bounds.size.height - p.y);   // quad 用 y 朝上
}

- (NSRect)resetButtonRect {
    const CGFloat w = 64, h = 22;
    CGFloat bottom = kDeskQuadPad + kVaultViewHeight;   // 翻转坐标下卡片下边缘
    return NSMakeRect(round(NSMidX(self.bounds) - w / 2),
                      round(bottom + (kDeskQuadPad - h) / 2.0), w, h);
}

#pragma mark - 绘制

- (void)drawRect:(NSRect)dirtyRect {
    gNeedTextShadow = (self.style == DeskStyleBare || self.style == DeskStyleHUD);
    gStyle = self.style;
    NSRect b = self.bounds;
    if (self.isWarped) {
        if (!_flatRep) [self refreshFlat];
        NSImage *warped = DeskQuadRender(_flatRep, b.size, self.currentQuad);
        [warped drawInRect:b fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver fraction:1.0];
        if (self.editing) [self drawHandles];
        return;
    }
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:b xRadius:14.0 yRadius:14.0];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];
    [self drawPlateIn:b];
    [self drawHeaderIn:b];
    [self drawGridIn:b];
    [self drawStripIn:b];
    [self drawDockIn:b];
    [self drawDropOverlayIn:b];
    if (_flashT > 0) {
        [[VaultCyanBright() colorWithAlphaComponent:0.30 * _flashK] setFill];
        NSRectFillUsingOperation(b, NSCompositingOperationSourceOver);
    }
    [NSGraphicsContext restoreGraphicsState];

    [[VaultCyan() colorWithAlphaComponent:0.34] setStroke];
    clip.lineWidth = 1.0;
    [clip stroke];
    VaultDrawReticle(b, 6.0, 13.0, VaultCyan(), 0.45, 1.2);
}

// 卡片本身在屏幕上的位置。变形时窗口比卡片大，要从窗口推回卡片那块，
// 否则采到的是"画布外圈"的壁纸，玻璃底会和卡面对不上
- (NSRect)cardScreenRect {
    NSRect base = NSEqualRects(_standInScreenRect, NSZeroRect)
        ? (self.window ? self.window.frame : NSZeroRect) : _standInScreenRect;
    if (NSEqualRects(base, NSZeroRect)) return NSZeroRect;
    if (!self.isWarped) return base;
    return NSMakeRect(base.origin.x + kDeskQuadPad,
                      base.origin.y + (self.bounds.size.height - kDeskQuadPad - kVaultViewHeight),
                      kVaultViewWidth, kVaultViewHeight);
}

// 采样一次 CoreImage 模糊要几十毫秒，所以自己缓存：位置没动、且 6 秒内就不重采
- (NSImage *)sampledWallpaper {
    NSRect r = [self cardScreenRect];
    if (NSEqualRects(r, NSZeroRect)) return nil;
    BOOL moved = !NSEqualRects(r, _wallpaperRect);
    NSTimeInterval age = _wallpaperAt ? [[NSDate date] timeIntervalSinceDate:_wallpaperAt] : 1e9;
    if (_wallpaper && !moved && age < 6.0) return _wallpaper;
    NSImage *img = [[DeskBackdrop shared] imageForRect:r dark:YES];
    if (!img) return _wallpaper;   // 采样失败先拿旧的顶着，总比没有强
    _wallpaper = img;
    _wallpaperRect = r;
    _wallpaperAt = [NSDate date];
    return _wallpaper;
}

- (void)drawPlateIn:(NSRect)b {
    switch (self.style) {
        case DeskStylePlate:
            VaultDrawPlatePlate(b, [self sampledWallpaper], [self currentSweep], _dropHot);
            break;
        case DeskStyleFeather:
            VaultDrawPlateFeather(b);
            break;
        case DeskStyleHUD: {
            // 青色 HUD：几乎不碰壁纸，只在边缘留一圈极淡的青，靠文字发光撑可读性
            NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:b xRadius:14.0 yRadius:14.0];
            [clip addClip];
            [VC(4, 26, 50, 0.22) setFill];
            [clip fill];
            break;
        }
        case DeskStyleBare:
        default:
            break;   // 完全无底：整块透出壁纸，文字带柔和投影
    }
}

// 抬头左侧那枚芯片：外壳加引脚，中心一个发光的核
- (void)drawChipIn:(NSRect)r {
    [[VaultCyan() colorWithAlphaComponent:0.85] setStroke];
    NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 3.0, 3.0)
                                                        xRadius:2.5 yRadius:2.5];
    body.lineWidth = 1.1;
    [body stroke];
    NSBezierPath *pins = [NSBezierPath bezierPath];
    pins.lineWidth = 1.0;
    for (int i = 0; i < 3; i++) {
        CGFloat o = 5.0 + i * 3.0;
        [pins moveToPoint:NSMakePoint(NSMinX(r) + o, NSMinY(r) + 0.5)];
        [pins lineToPoint:NSMakePoint(NSMinX(r) + o, NSMinY(r) + 3.0)];
        [pins moveToPoint:NSMakePoint(NSMinX(r) + o, NSMaxY(r) - 3.0)];
        [pins lineToPoint:NSMakePoint(NSMinX(r) + o, NSMaxY(r) - 0.5)];
        [pins moveToPoint:NSMakePoint(NSMinX(r) + 0.5, NSMinY(r) + o)];
        [pins lineToPoint:NSMakePoint(NSMinX(r) + 3.0, NSMinY(r) + o)];
        [pins moveToPoint:NSMakePoint(NSMaxX(r) - 3.0, NSMinY(r) + o)];
        [pins lineToPoint:NSMakePoint(NSMaxX(r) - 0.5, NSMinY(r) + o)];
    }
    [[VaultCyan() colorWithAlphaComponent:0.6] setStroke];
    [pins stroke];
    [[VaultCyanBright() colorWithAlphaComponent:0.85 + 0.15 * sin(CACurrentMediaTime() * 2.0)] setFill];
    NSRectFillUsingOperation(NSInsetRect(r, 6.5, 6.5), NSCompositingOperationSourceOver);
}

- (void)drawHeaderIn:(NSRect)b {
    NSArray<DeskVaultItem *> *items = [self items];
    NSRect chip = NSMakeRect(kPadX, kPadTop + 1.0, 18.0, 18.0);
    [self drawChipIn:chip];

    [@"桌面弹药库" drawAtPoint:NSMakePoint(kPadX + 24.0, kPadTop)
                withAttributes:Attrs(FTitle(), Pri())];
    NSString *sub = [NSString stringWithFormat:@"DESKTOP ARMORY · VAULT-01 · %02lu",
                     (unsigned long)items.count];
    [sub drawAtPoint:NSMakePoint(kPadX + 24.0, kPadTop + 18.0)
      withAttributes:Attrs(FSub(), Mut())];

    // 右侧：库位环 + 总体积
    NSRect ring = NSMakeRect(NSMaxX(b) - kPadX - 26.0, kPadTop + 2.0, 26.0, 26.0);
    double frac = MIN((double)items.count / (double)kVaultSlotCapacity, 1.0);
    VaultDrawRing(ring, frac, [VaultCyan() colorWithAlphaComponent:0.18],
                  VaultCyan(), VaultCyanBright(),
                  [NSString stringWithFormat:@"%lu", (unsigned long)items.count], FRing());

    CGFloat rightX = NSMinX(ring) - 8.0;
    NSDictionary *sa = Attrs(FBig(), Pri());
    NSString *size = VaultFormatBytes([self vaultTotalBytes]);
    [size drawAtPoint:NSMakePoint(round(rightX - [size sizeWithAttributes:sa].width), kPadTop)
      withAttributes:sa];
    NSDictionary *la = Attrs(FSub(), Mut());
    NSString *label = @"TOTAL SIZE";
    [label drawAtPoint:NSMakePoint(round(rightX - [label sizeWithAttributes:la].width), kPadTop + 19.0)
        withAttributes:la];

    [[VaultCyan() colorWithAlphaComponent:0.16] setStroke];
    NSBezierPath *sep = [NSBezierPath bezierPath];
    sep.lineWidth = 1.0;
    [sep moveToPoint:NSMakePoint(kPadX, kGridTop - 7.0)];
    [sep lineToPoint:NSMakePoint(NSMaxX(b) - kPadX, kGridTop - 7.0)];
    [sep stroke];
}

- (unsigned long long)vaultTotalBytes {
    unsigned long long t = 0;
    for (DeskVaultItem *it in [self items]) t += (unsigned long long)MAX(it.byteSize, 0LL);
    return t;
}

#pragma mark - 卡架

// 同一条卡架上谁最沉：电平条按这个比例画，才有一眼看出"哪个最占地方"
- (double)heaviestBytes {
    long long m = 1;
    for (DeskVaultItem *it in [self items]) m = MAX(m, it.byteSize);
    return (double)m;
}

- (void)drawGridIn:(NSRect)b {
    NSArray<DeskVaultItem *> *items = [self items];
    NSRect grid = NSMakeRect(NSMinX(b) + 4.0, kGridTop - 6.0,
                             NSMaxX(b) - NSMinX(b) - 8.0, kGridH + 12.0);
    [NSGraphicsContext saveGraphicsState];
    NSBezierPath *gclip = [NSBezierPath bezierPathWithRoundedRect:grid xRadius:9.0 yRadius:9.0];
    [gclip addClip];
    if (items.count == 0) {
        [self drawEmptyStateIn:grid];
    } else {
        for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
            [self drawCard:items[i] index:i in:b];
        }
    }
    [NSGraphicsContext restoreGraphicsState];
}

// 悬停预览：整张卡架区当容纳框，contain 落位，画在卡片之上。
// 盖住别的卡片是故意的 —— 预览的用途是"看清这张图"，浮在原位的小图做不到。
// 但源卡片上的退回按钮要在最上面补画一遍，否则它被盖住就点不到了。

- (void)drawCard:(DeskVaultItem *)it index:(NSInteger)idx in:(NSRect)b {
    NSNumber *ap = _appear[[self appearKeyFor:it]];
    double a = ap ? ap.doubleValue : 1.0;
    if (a <= 0.001) return;
    NSRect r = [self cardRectAtIndex:idx in:b];
    // hov 是 0~1 的缓动悬停量，不是布尔：所有"悬停才亮"的笔都乘它，
    // 鼠标扫过时是渐亮渐暗，不是啪一下跳变
    CGFloat hov = (idx == _hoverCard) ? _hoverCardK : 0.0;
    BOOL hovered = (idx == _hoverCard);
    CGFloat selK = (idx == _selected) ? _selectedK : 0.0;   // 选中量也是渐变的，不跳

    // 入库动画：整张卡片从下方 14pt 浮上来。变换必须排在裁剪前面，
    // 否则浮起来的只有卡面，玻璃底还是钉在原地
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:0.0 yBy:(1.0 - a) * 14.0];
    [t concat];

    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:r xRadius:8.0 yRadius:8.0];
    [clip addClip];

    double shade = VaultCardFillAlpha(self.style, hov, selK);
    if (shade > 0.01) {
        NSBezierPath *glass = [NSBezierPath bezierPathWithRoundedRect:r xRadius:8.0 yRadius:8.0];
        [VC(8, 26, 46, shade) setFill];
        [glass fill];
    }

    // 这一格装的是什么，决定整张卡上"属于类型"的那几笔都取什么色：
    // 电平条、剪影图形、进度条、规格牌。再配上 meta 行里的类型词，
    // 三路信息（色 / 形 / 字）互相印证，看错的机会就很小了。
    NSColor *tint = VaultTintForKind(it.kind);

    // 左侧电平条：这个库位占了多少"容量"
    double frac = MIN((double)MAX(it.byteSize, 0LL) / [self heaviestBytes], 1.0);
    NSRect track = NSMakeRect(NSMinX(r) + 4.0, NSMinY(r) + 10.0, 2.0, kCardH - 20.0);
    [[tint colorWithAlphaComponent:0.16] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:1.0 yRadius:1.0] fill];
    if (frac > 0.001) {
        CGFloat h = MAX(3.0, (kCardH - 20.0) * frac);
        NSRect lvl = NSMakeRect(track.origin.x, NSMinY(track) + (kCardH - 20.0) - h, 2.0, h);
        [[tint colorWithAlphaComponent:0.78 + 0.17 * hov] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:lvl xRadius:1.0 yRadius:1.0] fill];
    }

    // 剪影图形比原来那套"盒子里的符号"要读得清，图形区就跟着放大到 26pt：
    // 20pt 见方的地方塞不下轮廓细节，放大之后七个格式一眼就能分开
    NSRect glyph = NSMakeRect(NSMinX(r) + 10.0, NSMinY(r) + 8.0, 26.0, 22.1);
    // 图片卡片改成画文件里那张真图，一眼就知道是什么，不必去看名字。
    // 缩略图只在后台解好之后才拿得到，这里取不到就照旧画剪影图形 ——
    // 第一帧必然是剪影，预热回来再自己换成真图，不会有空白格。
    NSImage *thumb = (it.kind == VaultItemImage) ? VaultThumbnail([self vaultPathForItem:it]) : nil;
    if (thumb) VaultDrawThumbnailIn(glyph, thumb, tint);
    else VaultDrawItemGlyph(glyph, tint, it.seed, it.kind);

    // 文件才剥扩展名：扩展名是给 chip 用的，名字本身留「是什么」（成片/录音/封面图）
    // 就行；同时避免长名字中间省略后保留下来的尾巴（例如 ".mp4"）和下方 chip 同列
    // 在视觉上叠在一起 —— 不剥就是一对重复的扩展名碰头。
    NSString *displayName = it.name;
    CGFloat chipW = 0, chipLeftX = NSMaxX(r);        // 文件夹没有 chip，左缘退到右边
    NSString *ext = nil;
    NSDictionary *extAttrs = Attrs(FMeta(), Mut());
    if (it.kind != VaultItemFolder) {
        ext = [it.name pathExtension].uppercaseString;
        if (ext.length > 0 && ext.length <= 6) {
            chipW = [ext sizeWithAttributes:extAttrs].width + 8.0;
            chipLeftX = NSMaxX(r) - 9.0 - chipW;
            NSString *deExt = [it.name stringByDeletingPathExtension];
            if (deExt.length > 0) displayName = deExt;
        }
    }

    // 悬停时才让出右侧给退回按钮，平时名字可以用满宽度
    // y 起点留到 +13：剪影图形视觉中心约在卡片 +18.3，11.5pt CJK 在 15pt rect 里
    // 默认顶对齐会让可视字身落在 rect 顶端 +11.5pt、中心 +5.75pt，把 rect 起点
    // 推到这个位置正好让名字视觉中心对齐图形，而不是贴在顶边上。
    CGFloat nameX = NSMinX(r) + 43.0;
    CGFloat nameW = kCardW - 43.0 - 9.0;
    if (hovered) nameW -= 24.0;
    NSMutableDictionary *na = [Attrs(FCardName(), Pri()) mutableCopy];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingMiddle;
    na[NSParagraphStyleAttributeName] = ps;
    [displayName drawInRect:NSMakeRect(nameX, NSMinY(r) + 13.0, nameW, 15.0) withAttributes:na];

    // 类型词留在这里：颜色和剪影是"扫一眼"的路，这个字是"停下来确认"的路，
    // 三路都在才不会出现"这个到底什么类型"的犹豫
    NSString *meta;
    if (!it.scanned) {
        meta = @"正在清点…";
    } else if (it.kind == VaultItemFolder) {
        meta = [NSString stringWithFormat:@"%@ 项 · %@", VaultFormatCount(it.fileCount),
                VaultFormatBytes((unsigned long long)MAX(it.byteSize, 0LL))];
    } else {
        meta = [NSString stringWithFormat:@"%@ · %@", VaultKindLabel(it.kind),
                VaultFormatBytes((unsigned long long)MAX(it.byteSize, 0LL))];
    }
    // meta 基线放 +38 而不是 +34：名字字形最低落到 y≈26.5（省略号带降部），
    // 11pt 高的 chip 若按 +34 那行居中（top≈23.2）就会啃进名字行 3.3pt。
    // 把这一行整体下移，chip 才有一条自己独占的横向带，同时和 meta 仍在同一行上。
    [meta drawAtPoint:NSMakePoint(NSMinX(r) + 11.0, NSMinY(r) + 38.0)
        withAttributes:Attrs(FMeta(), it.scanned ? [tint colorWithAlphaComponent:0.78]
                                                : [Mut() colorWithAlphaComponent:0.5])];
    // 右端挂一枚扩展名规格牌，像弹药箱上贴的那种。
    // meta 行已经写了"视频/音频"这类分类，再补一个真实后缀才是用户真正要认的东西。
    // top=+30：比名字字底低 3.5pt（不撞名字），chip 中心 35.5 离 meta 字身中心 34.6 只差 0.9pt，
    // 所以读起来还是同一行，但已经有独立的一条带子。
    if (chipW > 0 && ext.length > 0) {
        VaultDrawExtChip(NSMakeRect(chipLeftX, NSMinY(r) + 30.0, chipW, 11.0), ext, tint);
    }

    // 占用条：文件数在库里的相对分量。y=+49 让开 chip 底(41)，留 8pt 空隙
    NSRect bar = NSMakeRect(NSMinX(r) + 11.0, NSMinY(r) + 49.0, kCardW - 22.0, 2.5);
    [[tint colorWithAlphaComponent:0.16] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:1.25 yRadius:1.25] fill];
    NSUInteger maxFiles = 1;
    for (DeskVaultItem *o in [self items]) maxFiles = MAX(maxFiles, o.fileCount);
    if (it.scanned && it.fileCount > 0) {
        double f = MIN((double)it.fileCount / (double)maxFiles, 1.0);
        NSRect fillR = NSMakeRect(bar.origin.x, bar.origin.y, bar.size.width * f, bar.size.height);
        [[tint colorWithAlphaComponent:0.80 + 0.15 * hov] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fillR xRadius:1.25 yRadius:1.25] fill];
    }

    if (it.ingestedAt > 0) {
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)it.ingestedAt];
        static NSDateFormatter *df;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            df = [NSDateFormatter new];
            df.dateFormat = @"MM-dd HH:mm";
            df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        });
        NSString *ts = [@"入库 " stringByAppendingString:[df stringFromDate:d]];
        // 基线 +60：8pt 字身顶在 52.3，之前放 +58 时字顶 50.3 直接压在进度条(49..51.5)上
        [ts drawAtPoint:NSMakePoint(NSMinX(r) + 11.0, NSMinY(r) + 60.0)
           withAttributes:Attrs(FTime(), [Mut() colorWithAlphaComponent:0.55])];
    }

    if (hov > 0.001) [self drawEjectButtonIn:[self ejectRectIn:r] alpha:hov];
    [NSGraphicsContext restoreGraphicsState];

    // 描边画在 clip 外面，入库动画里的扫描线也不会糊掉边框
    NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:r xRadius:8.0 yRadius:8.0];
    if (hov > 0.001 || selK > 0.001) {
        // 悬停那部分按 hov 渐亮，非悬停但被选中的部分保持原来的 0.45
        [[VaultCyanBright() colorWithAlphaComponent:0.45 * selK + 0.75 * hov] setStroke];
        edge.lineWidth = 1.0 + 0.4 * hov + 0.15 * selK;
    } else {
        CGFloat idle = self.style == DeskStyleHUD ? 0.50
                    : (self.style == DeskStyleBare ? 0.30 : 0.18);
        [[VaultCyan() colorWithAlphaComponent:idle] setStroke];
        edge.lineWidth = 1.0;
    }
    edge.lineWidth *= MAX(a, 0.2);
    [edge stroke];

    if (a < 1.0) {   // 入库时的青色扫描线
        CGFloat sx = NSMinX(r) + kCardW * a;
        [[VaultCyanBright() colorWithAlphaComponent:0.85 * (1.0 - a)] setFill];
        NSRectFillUsingOperation(NSMakeRect(sx - 1.0, NSMinY(r) + 2.0, 2.0, kCardH - 4.0),
                                NSCompositingOperationSourceOver);
    }
}

// 调角把手：四边形轮廓 + 四个角块 + 复位按钮
- (void)drawHandles {
    DeskQuad q = self.currentQuad;
    NSPoint pts[4] = { q.tl, q.tr, q.br, q.bl };
    NSPoint viewPts[4];
    for (int i = 0; i < 4; i++) viewPts[i] = NSMakePoint(pts[i].x, self.bounds.size.height - pts[i].y);
    NSBezierPath *edge = [NSBezierPath bezierPath];
    [edge moveToPoint:viewPts[0]];
    for (int i = 1; i < 4; i++) [edge lineToPoint:viewPts[i]];
    [edge closePath];
    edge.lineWidth = 1.0;
    [[VaultCyan() colorWithAlphaComponent:0.38] setStroke];
    [edge stroke];

    for (int i = 0; i < 4; i++) {
        NSRect knob = NSMakeRect(viewPts[i].x - 5, viewPts[i].y - 5, 10, 10);
        [[NSColor colorWithWhite:1.0 alpha:0.92] setFill];
        [[NSBezierPath bezierPathWithRect:knob] fill];
        [VaultCyan() setStroke];
        NSBezierPath *ring = [NSBezierPath bezierPathWithRect:NSInsetRect(knob, -0.5, -0.5)];
        ring.lineWidth = 1.0;
        [ring stroke];
    }

    NSRect btn = [self resetButtonRect];
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:btn xRadius:btn.size.height / 2
                                                        yRadius:btn.size.height / 2];
    [[VaultCyan() colorWithAlphaComponent:0.18] setFill];
    [pill fill];
    [[VaultCyan() colorWithAlphaComponent:0.7] setStroke];
    pill.lineWidth = 1.0;
    [pill stroke];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    [@"复位角点" drawInRect:NSMakeRect(btn.origin.x, btn.origin.y + 4, btn.size.width, btn.size.height)
             withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                              NSForegroundColorAttributeName: Pri(),
                              NSParagraphStyleAttributeName: ps}];
}

// alpha 是悬停缓动量：按钮随指针靠近淡入，而不是悬停判定成立的瞬间整块弹出
- (void)drawEjectButtonIn:(NSRect)r alpha:(CGFloat)alpha {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:4.0 yRadius:4.0];
    [[VaultCyan() colorWithAlphaComponent:0.18 * alpha] setFill];
    [p fill];
    [[VaultCyanBright() colorWithAlphaComponent:0.8 * alpha] setStroke];
    p.lineWidth = 1.0;
    [p stroke];
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    arrow.lineWidth = 1.3;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;
    CGFloat cx = NSMidX(r), cy = NSMidY(r);
    [arrow moveToPoint:NSMakePoint(cx, cy + 4.0)];
    [arrow lineToPoint:NSMakePoint(cx, cy - 3.0)];
    [arrow moveToPoint:NSMakePoint(cx - 3.0, cy - 0.2)];
    [arrow lineToPoint:NSMakePoint(cx, cy - 3.4)];
    [arrow lineToPoint:NSMakePoint(cx + 3.0, cy - 0.2)];
    [[VaultCyanBright() colorWithAlphaComponent:0.9 * alpha] setStroke];
    [arrow stroke];
}

- (void)drawEmptyStateIn:(NSRect)grid {
    NSRect r = NSInsetRect(grid, 6.0, 2.0);

    // 先把卡片区压成一块干净的底板，空着的时候底图透上来会显得脏
    NSBezierPath *plate = [NSBezierPath bezierPathWithRoundedRect:r xRadius:10.0 yRadius:10.0];
    [VC(6, 20, 40, 0.52) setFill];
    [plate fill];

    // 六个空库位先摆出来：一眼就知道东西放进来之后会长什么样，
    // 比一大片"什么都没有"要耐看得多
    [[VaultCyan() colorWithAlphaComponent:0.13] setStroke];
    CGFloat pat[2] = {4.0, 4.0};
    for (NSInteger i = 0; i < kCols * kRows; i++) {
        NSRect slot = NSInsetRect([self cardRectAtIndex:i in:[self layoutArea]], 1.5, 1.5);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:slot xRadius:7.0 yRadius:7.0];
        [p setLineDash:pat count:2 phase:(CGFloat)(i * 3)];
        p.lineWidth = 1.0;
        [p stroke];
    }

    // 中间放一块实底提示板，文字压在虚线库位上会很脏
    CGFloat pulse = (CGFloat)(0.5 + 0.5 * sin(CACurrentMediaTime() * 1.8));
    NSRect hint = NSMakeRect(NSMidX(r) - 150.0, NSMidY(r) - 41.0, 300.0, 82.0);
    NSBezierPath *hp = [NSBezierPath bezierPathWithRoundedRect:hint xRadius:10.0 yRadius:10.0];
    [VC(8, 28, 52, 0.88) setFill];
    [hp fill];
    [[VaultCyan() colorWithAlphaComponent:0.42] setStroke];
    hp.lineWidth = 1.1;
    [hp stroke];
    VaultDrawReticle(hint, 5.0, 10.0, VaultCyan(), 0.5, 1.1);

    // 左侧靶心：两圈准星配一个呼吸的内环
    NSPoint c = NSMakePoint(NSMinX(hint) + 46.0, NSMidY(hint));
    for (int i = 0; i < 2; i++) {
        CGFloat rad = 17.0 + i * 8.0;
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:
                              NSMakeRect(c.x - rad, c.y - rad, rad * 2, rad * 2)];
        ring.lineWidth = i == 0 ? 1.2 : 0.8;
        [[VaultCyan() colorWithAlphaComponent:(i == 0 ? 0.32 + 0.24 * pulse : 0.16)] setStroke];
        [ring stroke];
    }
    VaultDrawFolderGlyph(NSMakeRect(c.x - 11.0, c.y - 9.5, 22.0, 19.0), VaultCyan(), 0.5);

    // 右侧两行说明
    CGFloat tx = NSMinX(hint) + 78.0, tw = NSMaxX(hint) - tx - 14.0;
    [@"把桌面文件夹拖进来" drawInRect:NSMakeRect(tx, c.y - 23.0, tw, 17.0)
        withAttributes:Attrs(FEmpty(), Pri())];
    NSMutableDictionary *sa = [Attrs(FSub(), Mut()) mutableCopy];
    NSMutableParagraphStyle *wrap = [NSMutableParagraphStyle new];
    wrap.lineBreakMode = NSLineBreakByWordWrapping;
    sa[NSParagraphStyleAttributeName] = wrap;
    [@"拖到这里收纳，或点左下「扫桌面」一次性入库" drawInRect:NSMakeRect(tx, c.y - 7.0, tw, 26.0)
        withAttributes:sa];

    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:r xRadius:10.0 yRadius:10.0];
    CGFloat bpat[2] = {5.0, 5.0};
    [border setLineDash:bpat count:2 phase:0];
    [[VaultCyan() colorWithAlphaComponent:0.30 + 0.10 * sin(CACurrentMediaTime() * 1.6)] setStroke];
    border.lineWidth = 1.2;
    [border stroke];
}

#pragma mark - 库位条

- (void)drawStripIn:(NSRect)b {
    NSArray<DeskVaultItem *> *items = [self items];
    NSInteger hidden = (NSInteger)items.count - kCols * kRows;

    if (hidden > 0) {
        NSString *msg = [NSString stringWithFormat:@"库位 %lu / %lu · 向下滚动还有 %ld 个",
                         (unsigned long)items.count, (unsigned long)kVaultSlotCapacity, (long)hidden];
        [msg drawAtPoint:NSMakePoint(kPadX, kStripY) withAttributes:Attrs(FStrip(), VaultCyan())];
        NSBezierPath *ch = [NSBezierPath bezierPath];
        ch.lineWidth = 1.2;
        ch.lineCapStyle = NSLineCapStyleRound;
        CGFloat cx = NSMaxX(b) - kPadX - 5.0, cy = kStripY + 4.0;
        [ch moveToPoint:NSMakePoint(cx - 4.0, cy - 1.5)];
        [ch lineToPoint:NSMakePoint(cx, cy + 2.5)];
        [ch lineToPoint:NSMakePoint(cx + 4.0, cy - 1.5)];
        [[VaultCyan() colorWithAlphaComponent:0.8] setStroke];
        [ch stroke];
        return;
    }
    NSUInteger freeSlots = kVaultSlotCapacity > items.count ? kVaultSlotCapacity - items.count : 0;
    NSString *msg = items.count ? [NSString stringWithFormat:@"库位 %lu / %lu · 空闲 %lu",
                                   (unsigned long)items.count, (unsigned long)kVaultSlotCapacity,
                                   (unsigned long)freeSlots]
                                : @"库位空置 · 等待投喂";
    [msg drawAtPoint:NSMakePoint(kPadX, kStripY)
        withAttributes:Attrs(FStrip(), [Mut() colorWithAlphaComponent:0.75])];

    // 普通拖是移动组件，拖出文件夹得按 ⌥ —— 这条不写在界面上没人知道
    if (!items.count) return;
    NSString *hint = @"拖动=移动组件 · ⌥ 拖卡片=拖到访达 · ⇩ 退回桌面";
    NSDictionary *ha = Attrs(FStrip(), [VaultCyan() colorWithAlphaComponent:0.52]);
    [hint drawAtPoint:NSMakePoint(round(NSMaxX(b) - kPadX - [hint sizeWithAttributes:ha].width),
                                  kStripY) withAttributes:ha];
}

#pragma mark - 操作坞

- (void)drawDockIn:(NSRect)b {
    NSArray<NSValue *> *rs = [self dockButtonRectsIn:b];
    for (NSInteger i = 0; i < (NSInteger)rs.count; i++) {
        NSRect r = rs[i].rectValue;
        // k 是悬停缓动量：底色、描边、字色、图标色都跟着它连续变化
        CGFloat k = (i == _hoverDock) ? _hoverDockK : 0.0;
        BOOL destructive = (i == 2);
        NSColor *accent = destructive ? VaultWarn() : VaultCyan();
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r
                                                        xRadius:r.size.height / 2.0
                                                        yRadius:r.size.height / 2.0];
        [[accent colorWithAlphaComponent:0.09 + 0.11 * k] setFill];
        [p fill];
        [[accent colorWithAlphaComponent:0.24 + 0.38 * k] setStroke];
        p.lineWidth = 1.0;
        [p stroke];

        NSRect icon = NSMakeRect(NSMinX(r) + 9.0, NSMinY(r) + (r.size.height - 12.0) / 2.0, 12.0, 12.0);
        VaultDrawDockIcon((VaultDockIcon)i, icon,
                           [accent colorWithAlphaComponent:0.75 + 0.25 * k], 1.1);
        NSString *label = kDockLabels[i];
        // baseline 让墨迹中心落在按钮中线上，详见 VaultBaselineForCenter 的注释
        [label drawAtPoint:NSMakePoint(NSMinX(icon) + 17.0,
                                       round(VaultBaselineForCenter(FDock(), NSMidY(r))))
            withAttributes:Attrs(FDock(), [Pri() colorWithAlphaComponent:0.72 + 0.28 * k])];
    }
}

#pragma mark - 投喂区

- (void)drawDropOverlayIn:(NSRect)b {
    if (_dropHot <= 0.01) return;
    double h = _dropHot;
    NSRect r = NSInsetRect(b, 3.0, 3.0);
    NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:r xRadius:11.0 yRadius:11.0];
    [VC(6, 34, 58, 0.86 * h) setFill];
    [fill fill];
    NSBezierPath *dash = [NSBezierPath bezierPathWithRoundedRect:r xRadius:11.0 yRadius:11.0];
    CGFloat pat[2] = {7.0, 6.0};
    [dash setLineDash:pat count:2 phase:-CACurrentMediaTime() * 22.0];
    [[VaultCyanBright() colorWithAlphaComponent:0.85 * h] setStroke];
    dash.lineWidth = 1.6;
    [dash stroke];

    NSRect center = NSInsetRect(b, 26.0, 26.0);
    NSRect plate = NSMakeRect(NSMinX(center) + 26.0, NSMidY(center) - 30.0,
                              NSWidth(center) - 52.0, 62.0);
    NSBezierPath *pp = [NSBezierPath bezierPathWithRoundedRect:plate xRadius:8.0 yRadius:8.0];
    [VC(5, 22, 44, 0.90 * h) setFill];
    [pp fill];
    [[VaultCyan() colorWithAlphaComponent:0.30 * h] setStroke];
    pp.lineWidth = 1.0;
    [pp stroke];

    NSMutableParagraphStyle *c = [NSMutableParagraphStyle new];
    c.alignment = NSTextAlignmentCenter;
    NSString *big = _dropCount > 0 ? @"松手入库" : @"这里收文件夹和常见文件";
    NSMutableDictionary *ba = [Attrs(FBig(), [VaultCyanBright() colorWithAlphaComponent:h]) mutableCopy];
    ba[NSParagraphStyleAttributeName] = c;
    [big drawInRect:NSMakeRect(NSMinX(center), NSMidY(center) - 12.0, NSWidth(center), 20.0)
      withAttributes:ba];
    NSString *sub = _dropCount > 0
        ? [NSString stringWithFormat:@"RELEASE TO INGEST · %ld FOLDER%@", (long)_dropCount,
           _dropCount > 1 ? @"S" : @""]
        : @"RELEASE TO INGEST";
    NSMutableDictionary *sa = [Attrs(FSub(), [Mut() colorWithAlphaComponent:h]) mutableCopy];
    sa[NSParagraphStyleAttributeName] = c;
    [sub drawInRect:NSMakeRect(NSMinX(center), NSMidY(center) + 8.0, NSWidth(center), 14.0)
      withAttributes:sa];
}

#pragma mark - 拖放

// 只收目录：丢一堆散文件进来不该被当成"收纳"，直接回 None 让 Finder 自己处理
// 拖进来的一批东西里，哪些是能收的。收不收只看 VaultItemKindForPath 的白名单：
// 普通文件夹 + 表里那些后缀的散文件。别名、符号链接、.app 这类包、隐藏文件、
// 没在表里的后缀都在这里被剔掉，剔完一个不剩就等于拒绝了这次拖放。
- (NSArray<NSString *> *)ingestablePathsIn:(id<NSDraggingInfo>)info {
    NSPasteboard *pb = info.draggingPasteboard;
    NSMutableArray<NSString *> *keep = [NSMutableArray array];
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *u in urls) if (u.path) [all addObject:u.path];
    // file-url 通道拿不到时退回文件名通道：不是每个拖拽源都填 public.file-url
    if (all.count == 0) {
        for (id raw in [pb propertyListForType:NSFilenamesPboardType] ?: @[]) {
            if ([raw isKindOfClass:[NSString class]]) [all addObject:raw];
        }
    }
    // 谁被拒了记在 ivar 上，由 updateDropState 统一打日志：
    // 悬停一次会调进来好几次，日志打在这里会把日志刷爆
    NSMutableArray *rejected = [NSMutableArray array];
    for (NSString *p in all) {
        if (VaultItemKindForPath(p) != VaultItemKindNone) [keep addObject:p];
        else [rejected addObject:[p lastPathComponent]];
    }
    _lastRejectedDrop = rejected;
    return keep;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (self.onLog) self.onLog(@"拖入悬停：收到 draggingEntered");
    return [self updateDropState:sender];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return [self updateDropState:sender]; }

- (NSDragOperation)updateDropState:(id<NSDraggingInfo>)sender {
    NSArray *keep = [self ingestablePathsIn:sender];
    _dropCount = (NSInteger)keep.count;
    if (_dropCount == 0 && !_warnedNoPasteboard && self.onLog) {
        _warnedNoPasteboard = YES;
        NSArray *types = sender.draggingPasteboard.types;
        // 两种拒法要说不一样的话：拖了一堆但都不收（白名单之外），
        // 和压根没拖文件（比如从浏览器里拖一段文字过来）
        self.onLog(_lastRejectedDrop.count
                   ? [NSString stringWithFormat:@"拖入被拒：%@ 都不收",
                      [_lastRejectedDrop componentsJoinedByString:@"、"]]
                   : [NSString stringWithFormat:@"拖入被拒：贴板里没有文件（类型 %@）",
                      types.count ? [types componentsJoinedByString:@" "] : @"空"]);
    }
    if (_dropCount > 0) _warnedNoPasteboard = NO;
    [self setNeedsDisplay:YES];
    return _dropCount > 0 ? NSDragOperationMove : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    if (self.onLog) self.onLog(@"拖入离开：draggingExited");
    _dropCount = 0;
    [self setNeedsDisplay:YES];
}

- (void)draggingEnded:(id<NSDraggingInfo>)sender {
    if (self.onLog) self.onLog(@"拖入结束：draggingEnded");
    _dropCount = 0;
    [self setNeedsDisplay:YES];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    if (self.onLog) self.onLog(@"拖入准备落点：prepareForDragOperation");
    return _dropCount > 0;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray<NSString *> *dirs = [self ingestablePathsIn:sender];
    if (!dirs.count) {
        if (self.onLog) self.onLog(@"落点已触发但没有能收的东西，放弃");
        return NO;
    }
    if (self.onLog) {
        self.onLog([NSString stringWithFormat:@"落点触发，收到 %lu 个能收的", (unsigned long)dirs.count]);
    }
    NSUInteger n = [[self vault] ingestPaths:dirs];
    _dropCount = 0;
    [self syncAppear];
    [self flash];
    [self setNeedsDisplay:YES];
    if (self.onLog) self.onLog([NSString stringWithFormat:@"入库 %lu 个", (unsigned long)n]);
    return n > 0;
}

#pragma mark - 拖出

- (void)beginCardDrag:(DeskVaultItem *)item grab:(NSPoint)inCard event:(NSEvent *)event {
    if (!self.vault || !event) return;
    NSURL *url = [NSURL fileURLWithPath:[self.vault pathForItem:item]];
    NSDraggingItem *di = [[NSDraggingItem alloc] initWithPasteboardWriter:url];
    // 拖拽图形挂在光标上时要落在当初按下的那个位置，而不是卡片左上角。
    // 拖拽 frame 用屏幕坐标（左下原点），view 里是左上原点，y 要翻。
    NSPoint cursor = NSEvent.mouseLocation;
    NSRect frame = NSMakeRect(cursor.x - inCard.x, cursor.y - (kCardH - inCard.y), kCardW, kCardH);
    [di setDraggingFrame:frame contents:[self ghostImageFor:item]];
    _draggingItem = item;
    _dragCardOut = YES;
    [self beginDraggingSessionWithItems:@[di] event:event source:self];
}

- (NSImage *)ghostImageFor:(DeskVaultItem *)item {
    NSSize s = NSMakeSize(kCardW, kCardH);
    return [NSImage imageWithSize:s flipped:YES drawingHandler:^BOOL(NSRect r) {
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1.5, 1.5)
                                                        xRadius:8.0 yRadius:8.0];
        [VC(10, 34, 58, 0.92) setFill];
        [p fill];
        [[VaultCyanBright() colorWithAlphaComponent:0.9] setStroke];
        p.lineWidth = 1.4;
        [p stroke];
        VaultDrawItemGlyph(NSMakeRect(10, 8, 26, 22.1), VaultTintForKind(item.kind), item.seed, item.kind);
        [item.name drawInRect:NSMakeRect(36, 11, kCardW - 44, 15.0)
                withAttributes:Attrs(FCardName(), Pri())];
        [VaultFormatBytes((unsigned long long)MAX(item.byteSize, 0LL))
            drawAtPoint:NSMakePoint(11, 34) withAttributes:Attrs(FMeta(), Mut())];
        return YES;
    }];
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
          sourceOperationMaskForDraggingContext:(NSDraggingContext)ctx {
    return NSDragOperationMove;
}

- (void)draggingSession:(NSDraggingSession *)session willBeginAtPoint:(NSPoint)screenPoint {
    [self setNeedsDisplay:YES];
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
    _dragCardOut = NO;
    DeskVaultItem *item = _draggingItem;
    _draggingItem = nil;
    [self setNeedsDisplay:YES];
    if (!self.vault || !item) return;
    if (operation == NSDragOperationNone) {
        // 落在空处就放回组件里。文件夹本来就没出库，不该自作主张搬到桌面上——
        // 用户想放桌面有专门的 ⇩ 按钮，那个才是明确的指令
        if (self.onLog) self.onLog([NSString stringWithFormat:@"%@ 放回组件（没拖出去）", item.name]);
    } else {
        [self.vault reconcileItem:item];
        if (self.onLog) self.onLog([NSString stringWithFormat:@"%@ 已拖出库外", item.name]);
    }
}

#pragma mark - 鼠标

- (void)mouseMoved:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect b = [self layoutArea];
    NSInteger card = [self cardIndexAtPoint:p in:b];
    NSInteger eject = -1;
    if (card >= 0 && NSPointInRect(p, [self ejectRectIn:[self cardRectAtIndex:card in:b]])) eject = card;
    NSInteger dock = -1;
    NSArray<NSValue *> *rs = [self dockButtonRectsIn:b];
    for (NSInteger i = 0; i < (NSInteger)rs.count; i++) {
        if (NSPointInRect(p, rs[i].rectValue)) { dock = i; break; }
    }
    if (card == _hoverCard && eject == _hoverEject && dock == _hoverDock) return;
    _hoverCard = card;
    _hoverEject = eject;
    _hoverDock = dock;
    [self updateHoverPreviewForCard:card eject:eject];
    [self setNeedsDisplay:YES];
}

// 决定"这张卡要不要出预览"，并把结果告诉外面（外面据此浮出/收起预览窗）。
// 不做延迟也不做过渡：鼠标一停就出，移开就收。
- (void)updateHoverPreviewForCard:(NSInteger)card eject:(NSInteger)eject {
    BOOL ok = NO;
    NSString *path = nil;
    if (card >= 0 && eject < 0 && !self.isDragging) {
        DeskVaultItem *it = (NSInteger)[self items].count > card ? [self items][card] : nil;
        if (it.kind == VaultItemImage) {
            path = [self vaultPathForItem:it];
            ok = path.length > 0 && VaultThumbnail(path) != nil;
        }
    }
    if (!ok) {
        if (_hoverPreview >= 0) {
            _hoverPreview = -1;
            _previewK = 0;
            [self firePreviewPath:nil];
        }
        return;
    }
    if (_hoverPreview != card) {
        _hoverPreview = card;
        _previewK = 1.0;              // 立刻就是终态，不做淡入
    }
    [self firePreviewPath:path];
}

- (void)firePreviewPath:(NSString *)path {
    if (!self.onPreview) return;
    self.onPreview(path);
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (_hoverCard == -1 && _hoverDock == -1 && _hoverEject == -1 && _hoverPreview < 0) return;
    _hoverCard = _hoverDock = _hoverEject = _hoverPreview = -1;
    _previewK = 0;
    [self firePreviewPath:nil];
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    if (self.onLog) {
        NSPoint lp = [self convertPoint:event.locationInWindow fromView:nil];
        self.onLog([NSString stringWithFormat:@"按下 局部(%.0f,%.0f) 窗口原点(%.0f,%.0f)",
                    lp.x, lp.y, self.window.frame.origin.x, self.window.frame.origin.y]);
    }
    // 桌面层窗口默认不抢键盘，不接管双击和 ⌘W，所以这里不抢第一响应者
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect b = self.bounds;
    if (self.editing) {
        if (NSPointInRect(p, [self resetButtonRect])) {
            _quadOffsets = DeskQuadOffsetsZero();
            [self syncWarp];
            if (self.onQuadEdit) self.onQuadEdit(_quadOffsets);
            if (self.onGeometryChange) self.onGeometryChange();
            return;
        }
        _dragCorner = DeskQuadHitTest(self.currentQuad, [self canvasPointFromEvent:event], 16.0);
        if (_dragCorner >= 0) return;   // 在拖角，这一帧和卡架操作坞都让开
    }
    _pressPoint = p;
    _pressEvent = event;
    _pressCard = -1;
    _movingWindow = NO;

    // 操作坞要等 mouseUp 再触发。压在按钮上时先记下是哪个，
    // 一旦用户往外拖就当取消——否则"全退"这种一键清空的按钮，误碰一下就没了
    _pressDock = [self dockIndexAtPoint:p in:b];
    if (_pressDock >= 0) return;
    NSInteger card = [self cardIndexAtPoint:p in:b];
    if (card >= 0) {
        DeskVaultItem *it = [self items][card];
        if (NSPointInRect(p, [self ejectRectIn:[self cardRectAtIndex:card in:b]])) {
            if ([self.vault ejectItem:it toDesktop:YES]) {
                [self flash];
                if (self.onLog) self.onLog([NSString stringWithFormat:@"%@ 已退回桌面", it.name]);
            }
            return;
        }
        _pressCard = card;
        _selected = card;
        [self setNeedsDisplay:YES];
        return;
    }
    // 空白处按下 = 拖窗口，和卡片面板一个脾气
    [self beginWindowDrag];
}

// 记起点、算增量，全程只用屏幕坐标。这是卡片面板验证过的写法。
- (void)beginWindowDrag {
    NSWindow *w = self.window;
    if (!w) return;
    _movingWindow = YES;
    _dragStartMouse = NSEvent.mouseLocation;
    _frameAtDragStart = w.frame;
}

- (void)mouseDragged:(NSEvent *)event {
    if (_dragCorner >= 0) {
        DeskQuad q = self.currentQuad;
        NSPoint *pts[4] = { &q.tl, &q.tr, &q.br, &q.bl };
        *pts[_dragCorner] = [self canvasPointFromEvent:event];
        _quadOffsets = DeskQuadOffsetsClamp(DeskQuadOffsetsFromQuad(q, DeskVaultViewCardSize()),
                                           DeskVaultViewCardSize());
        _flatDirty = YES;
        [self refreshFlat];
        [self setNeedsDisplay:YES];
        if (self.onGeometryChange) self.onGeometryChange();
        return;
    }
    if (_pressCard >= 0) {
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        if (hypot(p.x - _pressPoint.x, p.y - _pressPoint.y) < kDragThresh) return;
        // 按住 ⌥ 才是"把这个文件夹拖到访达"。普通拖动是移动整个组件的默认手势，
        // 两件事撞在一起的话，用户想挪组件却把文件夹拖没了
        BOOL wantOut = NSEvent.modifierFlags & NSEventModifierFlagOption;
        if (!wantOut) {
            [self beginWindowDrag];
            _pressCard = -1;
            if (self.onLog) self.onLog(@"卡片上未按 ⌥：转为移动组件");
            return;
        }
        NSInteger idx = _pressCard;
        _pressCard = -1;
        NSArray<DeskVaultItem *> *items = [self items];
        if (idx >= (NSInteger)items.count) return;
        NSRect cr = [self cardRectAtIndex:idx in:[self layoutArea]];
        if (self.onLog) self.onLog(@"⌥ + 拖卡片：开始拖出库");
        [self beginCardDrag:items[idx]
                       grab:NSMakePoint(_pressPoint.x - NSMinX(cr), _pressPoint.y - NSMinY(cr))
                      event:_pressEvent];
        return;
    }
    if (_movingWindow) {
        NSWindow *w = self.window;
        if (!w) return;
        [w setFrame:VaultDragFrame(_frameAtDragStart, _dragStartMouse, NSEvent.mouseLocation)
            display:YES];
        [self setNeedsDisplay:YES];
        // 每 8 帧打一次点：拖动过程里只要有跳变，日志里一眼能看出来
        if (++_traceTick % 8 == 0 && self.onLog) {
            self.onLog([NSString stringWithFormat:@"拖动中 光标(%.0f,%.0f) 窗口原点(%.0f,%.0f)",
                        NSEvent.mouseLocation.x, NSEvent.mouseLocation.y,
                        w.frame.origin.x, w.frame.origin.y]);
        }
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (_pressDock >= 0) {
        NSInteger which = _pressDock;
        _pressDock = -1;
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        // 松手时还按在同一个按钮上才算数，拖开了就是取消
        if ([self dockIndexAtPoint:p in:[self layoutArea]] == which) [self performDockAction:which];
        return;
    }
    if (_dragCorner >= 0) {
        _dragCorner = -1;
        if (self.onQuadEdit) self.onQuadEdit(_quadOffsets);
        if (self.onGeometryChange) self.onGeometryChange();
        return;
    }
    if (_movingWindow) {
        _movingWindow = NO;
        if (self.onLog) {
            self.onLog([NSString stringWithFormat:@"松手 窗口原点(%.0f,%.0f)",
                        self.window.frame.origin.x, self.window.frame.origin.y]);
        }
        if (self.onUserMove) self.onUserMove();
    }
    if (_pressCard >= 0 && event.clickCount >= 2) {
        DeskVaultItem *it = [self items][_pressCard];
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[self.vault pathForItem:it]]];
        if (self.onLog) self.onLog([NSString stringWithFormat:@"在访达中打开 %@", it.name]);
    }
    _pressCard = -1;
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat maxS = [self maxScroll];
    if (maxS <= 0) return;
    CGFloat d = event.scrollingDeltaY;
    // 滚轮一格和触控板一划的量级差几十倍，统一缩到"一次一行"的手感
    if (fabs(d) > 0 && fabs(d) < 4.0) d *= 16.0;
    _scrollTarget = MIN(MAX(_scrollTarget + d, 0), maxS);
    [self setNeedsDisplay:YES];
}

#pragma mark - 操作坞

- (void)performDockAction:(NSInteger)i {
    DeskVault *v = self.vault;
    switch (i) {
        case 0: {
            NSUInteger n = [v ingestDesktopItems];
            [self flash];
            [self syncAppear];
            if (self.onLog) {
                // 没扫到东西时要说清是被白名单滤掉的，不是桌面上真的什么都没有
                self.onLog(n ? [NSString stringWithFormat:@"扫桌面入库 %lu 个", (unsigned long)n]
                             : @"桌面上没有可入库的文件夹或常见文件");
            }
            break;
        }
        case 1: {
            NSString *root = v.rootPath;
            [[NSFileManager defaultManager] createDirectoryAtPath:root
                                     withIntermediateDirectories:YES attributes:nil error:NULL];
            [[NSWorkspace sharedWorkspace] openFile:root];
            if (self.onLog) self.onLog(@"已打开库目录");
            break;
        }
        case 2: {
            NSUInteger n = [v ejectAllToDesktop];
            [self flash];
            if (self.onLog) {
                self.onLog(n ? [NSString stringWithFormat:@"已退回 %lu 个文件夹", (unsigned long)n]
                             : @"库里是空的");
            }
            break;
        }
        case 3:
            if (self.onHide) self.onHide();
            break;
        default:
            break;
    }
    [self setNeedsDisplay:YES];
}

@end
