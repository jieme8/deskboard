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
#import "procs.h"
#import "monitor_view.h"
#import "credits.h"
#import "credits_record.h"
#import "credits_view.h"
#import "trae_credits.h"
#import "qoder_credits.h"
#import "workbuddy_credits.h"
#import "backdrop.h"
#import <libproc.h>
#import <sys/proc_info.h>

// 老 bundle id 的配置域。换 id 之后老域里的值要搬过来（见 migrateLegacyDefaults）
static NSString *const kLegacyDomain = @"com.hujie.deskboard";

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
    NSMenuItem *_lockItem;       // 「全局 › 锁定位置」：四块一起锁，对勾跟着 _layoutLocked 走
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
    BOOL _layoutLocked;         // 全局锁定：四块组件都不能拖，锁定那一刻的摆位即默认位置
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
    NSTimer *_cardRaiseTimer;     // 卡片定时顶回本层最前（访达桌面窗会排到它前面吃掉点击）
    NSInteger _vaultCovered;      // 连续几次检出被盖住（防一掠而过导致闪一下）
    NSInteger _vaultClear;        // 连续几次检出空出来了
    BOOL _vaultCoverHidden;       // 因被盖住而临时收起，和用户手动隐藏分开记
    NSTimer *_widgetTick;        // 动画驱动，只在真有事做的时候挂着
    NSTimer *_widgetWatchdog;    // 空闲停表后的低频看门狗，负责把表叫回来
    NSDate *_lastWidgetTick;
    NSDate *_vaultCoverToggledAt;  // 上一次"收起/出现"切换的时刻，防来回横跳
    NSUInteger _vaultCoverTicks;   // 盖住检测的计数，用来顺手给置顶降频
    NSDate *_lastVaultStat;
    DeskStats *_lastStats;        // 最近一次系统指标，活动监视器的榜头读数从这里拿，不再多采一遍

    // 活动监视器：第三块组件，四榜并列（CPU / 内存 / 能耗 / 网络），只列当前用户的进程
    NSMutableArray<NSWindow *> *_monitorWindows;
    DeskPlaceStore *_monitorPlaces;
    DeskProcsMonitor *_procs;
    DeskHistory *_hist;             // 12 小时历史桶（自己攒，系统没有这个口径）
    NSTimeInterval _histLastAt;     // 上一拍的真实时刻，dt 由它算
    BOOL _monitorHidden;
    BOOL _monitorCompact;           // 简略模式：272×142，每榜只留第 1 名
    NSInteger _monitorStyle;
    NSMenu *_monitorStyleMenu;
    NSMenu *_monitorCornerMenu;
    NSString *_screenSig;         // 上一次见过的屏幕配置指纹（屏数 + 每屏 displayID/点尺寸/原点）
    NSMenuItem *_monitorItem;
    NSMenuItem *_monitorCompactItem;
    DeskQuadOffsets _monitorQuad;   // 活动监视器自己的四角位移，三块组件各调各的
    BOOL _monitorEditing;
    NSMenuItem *_monitorEditItem;
    NSWindow *_monitorHoverWindow;   // 悬停详情浮层：象限放不下全名，只能挪到组件外
    NSTimer *_monitorSampleTimer;   // 10 秒一拍采进程，和动画表分开：没在动也不该停采
    NSInteger _monitorCount;
    NSTimeInterval _lastStatsAt;    // 上一次系统指标采样的真实时刻；文件轮询比它快，读数不能跟着抖

    // 签到：第四块组件。MiniMax 走独立 OAuth，凭据只存在自己的目录里，
    // 绝不读写 MiniMax Code 桌面客户端的 ~/.minimax。
    NSMutableArray<NSWindow *> *_creditsWindows;
    DeskPlaceStore *_creditsPlaces;
    DeskCreditsProvider *_credits;
    DeskTraeCredits *_trae;
    DeskQoderCredits *_qoder;
    DeskWorkbuddyCredits *_workbuddy;
    DeskCreditsCenterSnapshot *_creditsCenter;
    DeskCreditsRecordStore *_creditsRecords;
    BOOL _qoderClaimSeen;
    BOOL _creditsHidden;
    NSInteger _creditsStyle;
    NSMenu *_creditsStyleMenu;
    NSMenuItem *_creditsItem;
    NSMenuItem *_creditsCenterMenuItem;
    NSMenuItem *_creditsMiniMaxMenuItem;
    NSMenuItem *_creditsTraeMenuItem;
    NSMenuItem *_creditsTraeInfoItem;
    NSMenuItem *_creditsTraeCheckInItem;
    NSMenuItem *_creditsWorkBuddyMenuItem;
    NSMenuItem *_creditsQoderMenuItem;
    NSMenuItem *_creditsQoderInfoItem;
    NSMenuItem *_creditsQoderCheckInItem;
    NSMenuItem *_creditsQoderTokenItem;
    NSMenuItem *_creditsWorkBuddyInfoItem;
    NSMenuItem *_creditsWorkBuddyCheckInItem;
    NSMenuItem *_creditsWorkBuddyLoginItem;
    NSMenuItem *_creditsMiniMaxInfoItem;
    NSMenuItem *_creditsStatusMenuItem;
    NSMenuItem *_creditsCheckInItem;
    NSMenuItem *_creditsAuthItem;
    NSTimer *_creditsTimer;
    NSInteger _lastCreditsHourlyHour;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    // 数据层自己的日志并进同一条 App 日志：库目录/清单出事时要能在交接日志里看到
    [DeskVault shared].logHandler = ^(NSString *m) { DeskLog(@"弹药库 %@", m); };
    [self migrateLegacyDefaults];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    _places = [[DeskPlaceStore alloc] initWithDictionary:[ud dictionaryForKey:K(@"Places")]
                                             defaultPlace:DeskPlaceDefaultForKind(DeskPlaceKindPanel)];
    if (_places.count == 0) {
        // 一次性迁移：老的全局位置种进主屏那条记录，之后老键废弃
        NSNumber *cornerVal = [ud objectForKey:K(@"Corner")];
        NSNumber *dxVal = [ud objectForKey:K(@"DX")];
        NSNumber *dyVal = [ud objectForKey:K(@"DY")];
        if (cornerVal) {
            DeskPlace seed = DeskPlaceDefaultForKind(DeskPlaceKindPanel);
            seed.corner = cornerVal.integerValue;
            if (dxVal) seed.dx = MAX(0, dxVal.doubleValue);
            if (dyVal) seed.dy = MAX(0, dyVal.doubleValue);
            [_places setPlace:seed forKey:[_places keyForScreen:[NSScreen mainScreen]]];
        } else {
            [_places setPlace:DeskPlaceDefaultForKind(DeskPlaceKindPanel)
                       forKey:[_places keyForScreen:[NSScreen mainScreen]]];
        }
        [ud removeObjectForKey:K(@"Corner")];
        [ud removeObjectForKey:K(@"DX")];
        [ud removeObjectForKey:K(@"DY")];
        [self saveConfig];
    }
    _hidden = [ud boolForKey:K(@"Hidden")];
    _layoutLocked = [ud boolForKey:K(@"LayoutLocked")];
    _vaultHidden = [ud boolForKey:K(@"VaultHidden")];
    _monitorHidden = [ud boolForKey:K(@"MonitorHidden")];
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
    NSNumber *msVal = [ud objectForKey:K(@"MonitorStyle")];
    _monitorStyle = msVal ? MIN(msVal.integerValue, (NSInteger)DeskStyleHUD) : (NSInteger)DeskStylePlate;
    _monitorCompact = [ud boolForKey:K(@"MonitorCompact")];
    _monitorQuad = DeskQuadOffsetsFromString([ud stringForKey:K(@"MonitorQuad")]);
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
    _vaultPlaces = [[DeskPlaceStore alloc] initWithDictionary:[ud dictionaryForKey:K(@"VaultPlaces")]
                                                 defaultPlace:DeskPlaceDefaultForKind(DeskPlaceKindVault)];
    if (_vaultPlaces.count == 0) {
        // 默认左下：系统状态右上 / 监视器右下 / 弹药库左下，左上留空
        DeskPlace seed = DeskPlaceDefaultForKind(DeskPlaceKindVault);
        [_vaultPlaces setPlace:seed forKey:[_vaultPlaces keyForScreen:[NSScreen mainScreen]]];
        [self saveConfig];
    }
    // 活动监视器再单独一份存档：三块组件各摆各的，共用会互相顶掉
    _monitorPlaces = [[DeskPlaceStore alloc] initWithDictionary:[ud dictionaryForKey:K(@"MonitorPlaces")]
                                                   defaultPlace:DeskPlaceDefaultForKind(DeskPlaceKindMonitor)];
    _procs = [DeskProcsMonitor new];
    // 12 小时历史：自己攒。macOS 没有公开 API 能给"过去 12 小时"的任意指标
    // （getloadavg 只到 15 分钟，host_cpu_load_info 和网卡计数都是自开机累计）
    _hist = [[DeskHistory alloc] initWithPath:[[self dataDir]
                                              stringByAppendingPathComponent:@"History-12h.plist"]];
    [_hist load];
    if (_monitorPlaces.count == 0) {
        // 默认右下：和右上的系统状态同侧，左下的弹药库分居另一侧
        DeskPlace mseed = DeskPlaceDefaultForKind(DeskPlaceKindMonitor);
        [_monitorPlaces setPlace:mseed forKey:[_monitorPlaces keyForScreen:[NSScreen mainScreen]]];
        [self saveConfig];
    }
    // 签到：第四块组件，位置单独一份，默认左上（另外三块占右上/右下/左下）
    _creditsPlaces = [[DeskPlaceStore alloc] initWithDictionary:[ud dictionaryForKey:K(@"CreditsPlaces")]
                                                   defaultPlace:DeskPlaceDefaultForKind(DeskPlaceKindCredits)];
    if (_creditsPlaces.count == 0) {
        DeskPlace cseed = DeskPlaceDefaultForKind(DeskPlaceKindCredits);
        [_creditsPlaces setPlace:cseed forKey:[_creditsPlaces keyForScreen:[NSScreen mainScreen]]];
        [self saveConfig];
    }
    _creditsHidden = [ud boolForKey:K(@"CreditsHidden")];
    NSNumber *csVal = [ud objectForKey:K(@"CreditsStyle")];
    _creditsStyle = csVal ? MIN(csVal.integerValue, (NSInteger)DeskStyleHUD)
                          : (NSInteger)DeskStylePlate;
    // 90 天纪录：本地日桶 + 最后一次签到事件；只有余额和日期，不含任何令牌。
    _creditsRecords = [[DeskCreditsRecordStore alloc] initWithPath:
        [[[self dataDir] stringByAppendingPathComponent:@"Credits"]
         stringByAppendingPathComponent:@"records.json"]];
    _creditsRecords.onLog = ^(NSString *m) { DeskLog(@"签到记录 %@", m); };
    [_creditsRecords load];
    _credits = [[DeskCreditsProvider alloc] initWithDirectory:
                [[self dataDir] stringByAppendingPathComponent:@"Credits"]];
    __weak typeof(self) weakCredits = self;
    _credits.onLog = ^(NSString *m) { DeskLog(@"签到 %@", m); };
    _credits.onChange = ^(DeskCreditsSnapshot *s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakCredits applyCreditsSnapshot:s];
        });
    };
    [_credits load];

    // Trae：只读本机 storage.json，绝不续期（会轮换 refreshToken 踢掉 IDE）。
    // 登录态由 IDE 自己续；我们每次同步都重读文件，IDE 换了 token 就自动跟上。
    _trae = [DeskTraeCredits new];
    _trae.onLog = ^(NSString *m) { DeskLog(@"签到 Trae %@", m); };
    _trae.onChange = ^(DeskTraeSnapshot *t) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakCredits applyTraeSnapshot:t];
        });
    };
    [_trae load];

    // Qoder：PT（pt-…）兑换 job token 后直连官方活动接口；国内版不需要设备风控头。
    // PT 只存在 DeskBoard 的 Credits 目录（0600），从不读写 Qoder 客户端凭据。
    _qoder = [[DeskQoderCredits alloc] initWithDirectory:
              [[self dataDir] stringByAppendingPathComponent:@"Credits"]];
    _qoder.onLog = ^(NSString *m) { DeskLog(@"签到 Qoder %@", m); };
    _qoder.onChange = ^(DeskQoderSnapshot *q) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakCredits applyQoderSnapshot:q];
        });
    };
    [_qoder load];
    _qoderClaimSeen = _qoder.snapshot.claimed;

    // WorkBuddy：官方浏览器授权拿 token；5.6.2+ 客户端本机登录态已加密，只读导入仅对明文有效。
    _workbuddy = [[DeskWorkbuddyCredits alloc] initWithDirectory:
                  [[self dataDir] stringByAppendingPathComponent:@"Credits"]];
    _workbuddy.onLog = ^(NSString *m) { DeskLog(@"签到 WorkBuddy %@", m); };
    _workbuddy.onChange = ^(DeskWorkbuddySnapshot *w) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakCredits applyWorkbuddySnapshot:w];
        });
    };
    [_workbuddy load];

    _creditsCenter = [DeskCreditsCenterSnapshot centerWithMiniMax:_credits.snapshot
                                                             trae:_trae.snapshot
                                                            qoder:_qoder.snapshot
                                                        workbuddy:_workbuddy.snapshot];
    [self applyCreditsRecordsToCenter:_creditsCenter];
    // 一次性布局迁移：老存档里三块的位置是旧的出厂锚点，用户已经明确要
    // 系统状态右上 / 活动监视器右下 / 弹药库左下。只在版本号落后时覆盖一次，
    // 之后用户再拖由存档接管，不会再被掰回去。
    if ([ud integerForKey:K(@"LayoutDefaultsV")] < 2) {
        for (NSScreen *scr in [NSScreen screens]) {
            [_places setPlace:DeskPlaceDefaultForKind(DeskPlaceKindPanel)
                       forKey:[_places keyForScreen:scr]];
            [_vaultPlaces setPlace:DeskPlaceDefaultForKind(DeskPlaceKindVault)
                            forKey:[_vaultPlaces keyForScreen:scr]];
            [_monitorPlaces setPlace:DeskPlaceDefaultForKind(DeskPlaceKindMonitor)
                              forKey:[_monitorPlaces keyForScreen:scr]];
        }
        [ud setInteger:2 forKey:K(@"LayoutDefaultsV")];
        [self saveConfig];
        DeskLog(@"布局默认值 v2：系统状态右上 / 活动监视器右下 / 弹药库左下");
    }
    [self buildStatusItem];
    [self rebuildWindows];
    [self rebuildVaultWindows];
    [self rebuildMonitorWindows];
    [self rebuildCreditsWindows];
    [self startWidgetTicking];
    [self startMonitorSampling];
    [self startCreditsTicking];
    [self startPolling];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenDidChange:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                          selector:@selector(systemDidWake:)
                                                              name:NSWorkspaceDidWakeNotification
                                                            object:nil];
    _screenSig = [self currentScreenSignature];   // 建完窗再记指纹：之后每条"抖动"通知都能认出配置没变
    DeskLog(@"启动完成 屏位档 %lu 隐藏=%d 屏幕指纹=%@ 布局锁定=%d", (unsigned long)_places.count, _hidden, _screenSig, _layoutLocked);
    DeskLog(@"签到组件：%@，%@", _creditsHidden ? @"已隐藏" : @"已显示",
            _credits.snapshot.authorized ? @"已授权" : @"未授权（菜单 › 签到中心 › MiniMax › 重新授权）");
    DeskLog(@"签到中心：%ld/4 已接入 · %ld 已办 / %ld 待办 / %ld 异常",
            (long)_creditsCenter.connectedCount, (long)_creditsCenter.doneCount,
            (long)_creditsCenter.pendingCount, (long)_creditsCenter.errorCount);
    DeskLog(@"弹药库根目录 %@（%lu 项）", [DeskVault shared].rootPath,
            (unsigned long)[DeskVault shared].items.count);
}

// 一次性迁移：老 bundle id（com.hujie.deskboard）域里的配置，搬到新 id 的域。
//
// 为什么要换 id：2026-10-21 实测，同一个 bundle id 在 LaunchServices 里攒了几百条
// 重复登记（macOS 每发现一份同 id 的新副本，就把旧的自动搬进 ~/.Trash 并留着登记），
// 系统就认不出「这个菜单栏项属于哪个 App」，于是整个不画 —— 而 isVisible 仍然返回 1，
// 只看日志会被骗过去。详见 README「菜单栏图标不显示」一节。
// 换 id 之后配置域会跟着变，所以这里把老域的值原样搬过来一次。
- (void)migrateLegacyDefaults {
    NSString *legacy = kLegacyDomain;
    NSString *current = [NSBundle mainBundle].bundleIdentifier;
    if (!current || [current isEqualToString:legacy]) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:K(@"Places")] || [ud objectForKey:K(@"MonitorPlaces")]) return;  // 迁过了
    CFPreferencesAppSynchronize((__bridge CFStringRef)legacy);
    NSArray<NSString *> *keys = @[K(@"Places"), K(@"MonitorPlaces"), K(@"VaultPlaces"),
                                  K(@"Style"), K(@"Quad"), K(@"MonitorQuad"), K(@"VaultQuad"),
                                  K(@"Hidden"), K(@"MonitorHidden"), K(@"VaultHidden"),
                                  K(@"VaultStyle"), K(@"MonitorStyle"), K(@"VaultAlpha"), K(@"VaultFloating")];
    // NSUserDefaults 不加前缀，键名就是 plist 里的原样（K() 已经带了 App 名前缀）；
    // CFPreferences 那边要的也正是这个原样键名 —— 之前多拼了一次前缀，全成了 nil。
    CFPreferencesAppSynchronize((__bridge CFStringRef)legacy);
    int moved = 0;
    for (NSString *key in keys) {
        CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)legacy);
        if (!v) continue;
        [ud setObject:(__bridge id)v forKey:key];
        CFRelease(v);
        moved++;
    }
    if (moved > 0) {
        [ud synchronize];
        DeskLog(@"配置迁移：%@ → %@（搬了 %d 项）", legacy, current, moved);
    }
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
    [ud setBool:_layoutLocked forKey:K(@"LayoutLocked")];
    [ud setInteger:_style forKey:K(@"Style")];
    [ud setObject:DeskQuadOffsetsString(_quad) forKey:K(@"Quad")];
    [ud setObject:[_vaultPlaces dictionary] forKey:K(@"VaultPlaces")];
    [ud setBool:_vaultHidden forKey:K(@"VaultHidden")];
    [ud setDouble:_vaultAlpha forKey:K(@"VaultAlpha")];
    [ud setObject:DeskQuadOffsetsString(_vaultQuad) forKey:K(@"VaultQuad")];
    [ud setInteger:_vaultStyle forKey:K(@"VaultStyle")];
    [ud setObject:[_monitorPlaces dictionary] forKey:K(@"MonitorPlaces")];
    [ud setBool:_monitorHidden forKey:K(@"MonitorHidden")];
    [ud setBool:_monitorCompact forKey:K(@"MonitorCompact")];
    [ud setInteger:_monitorStyle forKey:K(@"MonitorStyle")];
    [ud setObject:DeskQuadOffsetsString(_monitorQuad) forKey:K(@"MonitorQuad")];
    [ud setObject:[_creditsPlaces dictionary] forKey:K(@"CreditsPlaces")];
    [ud setBool:_creditsHidden forKey:K(@"CreditsHidden")];
    [ud setInteger:_creditsStyle forKey:K(@"CreditsStyle")];
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
    DeskLog(@"数据：%@ %@ [%@] 错误=%@ | CPU=%.0f%%（%.0fs 窗口） GPU=%.0f%% 温度=%.1f°C 内存=%.1f/%.0fGiB 磁盘剩=%.0fG SSD=%d 读=%.1f 写=%.1f MB/s",
            m.title, m.price, m.infoLine, m.loadError ?: @"无",
            s.cpu, s.cpuWindow, s.gpu, s.cpuTemp, s.memUsed / 1073741824.0, s.memTotal / 1073741824.0, s.diskFree / 1e9,
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
        p = _places.fallbackPlace;
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
    // 变形后外框是矩形，窗影会出卖它；无边玻璃也不要窗影 ——
    // WindowServer 会按窗口 alpha 轮廓算出一圈深边，看起来就像又描了一道边框。
    w.hasShadow = ![self quadActive] && _style != DeskStyleHUD;
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
    card.locked = _layoutLocked;
    __weak typeof(self) weakSelf = self;
    card.onQuadEdit = ^(DeskQuadOffsets q) {
        [weakSelf applyQuadFromCard:q];
    };
    card.onGeometryChange = ^{ [weakSelf updateHud]; };   // 拖角时窗口没动，只能靠这个刷新读数
    __weak NSWindow *weakSelfWindow = w;
    card.onUserMove = ^{ [weakSelf recordPendingPlaceInWindow:weakSelfWindow]; };
    // 卡片到点动效（每 10 秒 0.9 秒）：只在真的播的时候把停掉的 60fps 表叫回来
    card.onNeedFrames = ^{ [weakSelf resumeWidgetTicking]; };
    w.contentView = card;
    [card refreshSource];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(mainOcclusionChanged:)
                                                 name:NSWindowDidChangeOcclusionStateNotification
                                               object:w];
    [self logWindowSnapshot:w tag:@"卡片"];
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

// 同层竞争：访达的桌面图标窗和卡片同在 kCGDesktopIconWindowLevel。刷新桌面、切 Space、
// 换壁纸都会让它排到卡片前面 —— 这一层没有「置顶」可设，只能定时顶回去。
// 实测卡片整块被访达桌面窗 100% 压着（probe_clickcatcher 全部：卡片排第 19、访达第 18），
// 点击根本到不了视图，表现就是别的组件都拖得动、只有卡片按住一动不动。
// 活动的四块统一走这一拍：卡片原来完全没有顶回；监视器 30s、签到 60s 才顶一次，
// 桌面窗抢到前面之后用户会有几十秒点不动（实测 16:36 监视器就是这个状态）。
- (void)raiseSameLayerTimer:(NSTimer *)timer {
    (void)timer;
    if (!_hidden && _windows.count > 0) {
        BOOL dragging = NO;
        for (NSWindow *w in _windows) {
            NSView *v = w.contentView;
            if ([v isKindOfClass:[DeskCardView class]] && [(DeskCardView *)v isDragging]) { dragging = YES; break; }
        }
        if (!dragging) for (NSWindow *w in _windows) [w orderFrontRegardless];
    }
    [self raiseMonitorAboveSameLayer];
    [self raiseCreditsAboveSameLayer];
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
        // 落出可视区（老记录来自大屏，切到小屏）就夹回出厂锚点，别让组件摆到看不见的地方
        p = _vaultPlaces.fallbackPlace;
        DeskLog(@"弹药库档 %@ 落出可视区，夹回默认锚点（左下）", [_vaultPlaces keyForScreen:screen]);
        [_vaultPlaces setPlace:p forKey:[_vaultPlaces keyForScreen:screen]];
        [self saveConfig];
        CGFloat fx = (p.corner == 1 || p.corner == 3) ? NSMaxX(vf) - card.width - p.dx : vf.origin.x + p.dx;
        CGFloat fy = (p.corner >= 2) ? vf.origin.y + p.dy : NSMaxY(vf) - card.height - p.dy;
        r = NSMakeRect(round(fx - padX), round(fy - padY), win.width, win.height);
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
    // 无边玻璃不要窗影：窗影按窗口 alpha 轮廓计算，会在玻璃四周压出一圈深边
    w.hasShadow = _vaultStyle != DeskStyleHUD;
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
    v.locked = _layoutLocked;
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
    v.onNeedFrames = ^{ [weakSelf resumeWidgetTicking]; };
    w.contentView = v;
    [self logWindowSnapshot:w tag:@"弹药库"];
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

// 桌面层组件的窗口矩形（WindowServer 左上原点）是否被用户的应用窗口完全盖住。
// 盖住时它的重画和缓动谁都看不见，5 秒一拍还照画就是把电烧在空气里。
// 复用弹药库那套已经量过的判定：层级 0~19、非全透明、排除 Finder/Dock。
static BOOL WidgetWindowCovered(NSWindow *w) {
    if (!w || !w.isVisible) return YES;
    CGFloat mainH = [NSScreen mainScreen].frame.size.height;
    NSRect f = w.frame;
    return VaultCoveredByAppWindow(NSMakeRect(f.origin.x, mainH - NSMaxY(f),
                                              NSWidth(f), NSHeight(f)), NULL);
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
    DeskPlace p = DeskPlaceFromFrame(f, NSMakeSize(kVaultViewWidth, kVaultViewHeight), vf);
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

#pragma mark - 组件 3：活动监视器

// 只贴桌面图标层，和另两块组件同一条硬约束：任何应用窗口都在它之上
// 三块组件都拍一条同样格式的环境快照。源码看起来一样不等于运行时一样：层级、能不能成
// key、吃不吃鼠标这些都可能被 AppKit 悄悄改。在用户真拖一次之前，这三行就是唯一的对照实验。
- (void)logWindowSnapshot:(NSWindow *)w tag:(NSString *)tag {
    if (!w) return;
    NSRect f = w.frame;
    DeskLog(@"环境快照 %@：层=%ld 可成key=%d 点击穿透=%d 收移动=%d 可拖背景=%d 窗影=%d 框=(%.0f,%.0f,%.0fx%.0f) 屏数=%ld",
            tag, (long)w.level, w.canBecomeKeyWindow, w.ignoresMouseEvents,
            w.acceptsMouseMovedEvents, w.movableByWindowBackground, w.hasShadow,
            f.origin.x, f.origin.y, f.size.width, f.size.height, (long)[NSScreen screens].count);
}

- (NSRect)monitorFrameForScreen:(NSScreen *)screen {
    NSRect vf = screen.visibleFrame;
    DeskPlace p = [_monitorPlaces effectivePlaceForScreen:screen];
    NSSize card = [DeskMonitorView cardSizeCompact:_monitorCompact];
    CGFloat x = (p.corner == 1 || p.corner == 3) ? NSMaxX(vf) - card.width - p.dx
                                                 : vf.origin.x + p.dx;
    CGFloat y = (p.corner >= 2) ? vf.origin.y + p.dy : NSMaxY(vf) - card.height - p.dy;
    // 存档里的 dx/dy 描述的是**看得见的卡片**，窗口在变形时外扩一圈余量，
    // 所以先按卡片算，再按 pad 把窗口矩形撑回去
    NSSize win = [DeskMonitorView windowSizeWarped:[self monitorQuadActive] compact:_monitorCompact];
    CGFloat padX = (win.width - card.width) / 2.0, padY = (win.height - card.height) / 2.0;
    NSRect r = NSMakeRect(round(x - padX), round(y - padY), win.width, win.height);
    if (!NSIntersectsRect(r, vf)) {
        p = _monitorPlaces.fallbackPlace;
        DeskLog(@"活动监视器档 %@ 落出可视区，夹回默认锚点（右下）", [_monitorPlaces keyForScreen:screen]);
        [_monitorPlaces setPlace:p forKey:[_monitorPlaces keyForScreen:screen]];
        [self saveConfig];
        CGFloat fx = (p.corner == 1 || p.corner == 3) ? NSMaxX(vf) - card.width - p.dx : vf.origin.x + p.dx;
        CGFloat fy = (p.corner >= 2) ? vf.origin.y + p.dy : NSMaxY(vf) - card.height - p.dy;
        r = NSMakeRect(round(fx - padX), round(fy - padY), win.width, win.height);
    }
    return r;
}

- (BOOL)monitorQuadActive { return !DeskQuadOffsetsIsZero(_monitorQuad) || _monitorEditing; }

- (NSWindow *)makeMonitorWindowForScreen:(NSScreen *)screen {
    NSRect vf = [self monitorFrameForScreen:screen];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:vf
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    [w setBackgroundColor:[NSColor clearColor]];
    w.opaque = NO;
    // 和卡片面板一致：一直要窗影。卡片那档（panel_view 的窗口）就是 hasShadow=YES，
    // 无底浮字看着"字后面有一层柔边"其实来自 WindowServer 按 alpha 轮廓算的窗影，
    // 不是绘制代码画的阴影。上一版我把它关掉，结果量出来监视器字边缘压暗 1.0%
    // 而卡片是 19.2% —— 那不是"更像卡片"，是更不像。用户要的从来不是没有影子，
    // 而是"别和卡片不一样"，所以这里跟着面板留着。
    w.hasShadow = YES;
    w.level = kCGDesktopIconWindowLevel;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                         | NSWindowCollectionBehaviorStationary
                         | NSWindowCollectionBehaviorIgnoresCycle;
    w.movableByWindowBackground = NO;   // 拖动由 DeskMonitorView 自己实现，见 onUserMove
    w.animationBehavior = NSWindowAnimationBehaviorNone;
    w.excludedFromWindowsMenu = YES;
    w.acceptsMouseMovedEvents = YES;    // 不开这个，悬停高亮是死的
    w.title = @"DeskBoard 活动监视器";
    DeskMonitorView *v = [[DeskMonitorView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(vf), NSHeight(vf))];
    v.compact = _monitorCompact;
    v.style = (DeskStyle)_monitorStyle;
    v.quadOffsets = _monitorQuad;
    v.editing = _monitorEditing;
    v.locked = _layoutLocked;
    __weak typeof(self) weakSelf = self;
    __weak NSWindow *weakW = w;
    v.onUserMove = ^{ [weakSelf saveMonitorPlaceInWindow:weakW]; };
    // 弹药库和卡片都有这一句，活动监视器漏了：拖角时窗口要按新的四角包围盒重新撑位，
    // 不接就等于"角拖出去了、画布没跟着长"，四角会被窗口裁掉。
    v.onGeometryChange = ^{ [weakSelf applyMonitorFrames]; };
    // 视图不碰 DeskHistory（保持"只画不采"），只拿一个取数口；而且只在换拍时问一次
    v.historyForPid = ^double(pid_t pid, DeskHistMetric m, double *covered) {
        // 直接捕获 _hist：它不反向引用 self，所以不会成环；用 weakSelf 反而要为此开个属性
        if (!_hist) return 0;
        return [_hist averageForPid:pid metric:m now:[NSDate date].timeIntervalSince1970
                         window:kDeskHistoryWindow covered:covered];
    };
    v.historyTotalForPid = ^double(pid_t pid, double *covered) {
        if (!_hist) { if (covered) *covered = 0; return 0; }
        return [_hist totalForPid:pid metric:DeskHistNetwork
                              now:[NSDate date].timeIntervalSince1970
                           window:kDeskHistoryWindow covered:covered];
    };
    v.onLog = ^(NSString *message) { DeskLog(@"活动监视器 %@", message); };
    // 条子改成直接落位后，活动监视器不再需要逐帧动画表；只有弹药库/卡片还在用 onNeedFrames
    v.onHover = ^(pid_t pid, NSRect row, NSInteger metric, double avg, double covered) {
        [weakSelf showMonitorHover:pid rowInWindow:row metric:metric
                            histAvg:avg histCovered:covered forWindow:weakW];
    };
    w.contentView = v;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(monitorOcclusionChanged:)
                                                 name:NSWindowDidChangeOcclusionStateNotification
                                               object:w];
    [self logWindowSnapshot:w tag:@"监视器"];
    return w;
}

// 浮层放在被悬停那一行的右侧；右边放不下就放左边。层级和组件同层，
// 所以它永远盖不住用户的应用窗口，只是比卡片先画而已
- (void)showMonitorHover:(pid_t)pid rowInWindow:(NSRect)row metric:(NSInteger)metric
                    histAvg:(double)histAvg histCovered:(double)histCovered forWindow:(NSWindow *)host {
    if (pid <= 0 || !host) { [_monitorHoverWindow orderOut:nil]; return; }
    DeskProc *p = [_procs procWithPid:pid];
    if (!p) { [_monitorHoverWindow orderOut:nil]; return; }
    // 214 太窄：底部那行「12h 平均基于已记录的 0.7 小时 · 双击看原生活动监视器」
    // 会被裁掉尾巴（实测截图里就是断在「原生活动监」）。加宽到 240 让它整句放下。
    NSSize size = kDeskMonitorHoverSize;
    if (!_monitorHoverWindow) {
        _monitorHoverWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                                         styleMask:NSWindowStyleMaskBorderless
                                                           backing:NSBackingStoreBuffered defer:NO];
        [_monitorHoverWindow setBackgroundColor:[NSColor clearColor]];
        _monitorHoverWindow.opaque = NO;
        _monitorHoverWindow.hasShadow = YES;
        _monitorHoverWindow.level = kCGDesktopIconWindowLevel;
        _monitorHoverWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                               | NSWindowCollectionBehaviorStationary
                                               | NSWindowCollectionBehaviorIgnoresCycle;
        _monitorHoverWindow.ignoresMouseEvents = YES;   // 浮层不吃鼠标，不然会把悬停行本身顶掉
        _monitorHoverWindow.animationBehavior = NSWindowAnimationBehaviorNone;
        _monitorHoverWindow.excludedFromWindowsMenu = YES;
    }
    DeskMonitorHoverView *hv = [[DeskMonitorHoverView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    hv.procName = p.name;
    hv.pid = p.pid;
    hv.uid = [self uidOfPid:p.pid];
    hv.startedAt = p.startedAt;
    hv.cpu = p.cpu; hv.mem = p.mem; hv.energy = p.energy; hv.sockets = p.sockets;
    hv.netInRate = p.netInRate; hv.netOutRate = p.netOutRate;
    // 介绍与出处只在换行时查一次（proc_pidpath 是一次系统调用），不跟 10 秒采样走
    NSString *exePath = DeskProcExecutablePath(p.pid);
    hv.intro = DeskProcIntroText(p.name, exePath);
    hv.origin = DeskProcOriginText(exePath);
    hv.histMetric = metric; hv.histAvg = histAvg; hv.histCovered = histCovered;
    hv.histTotal = -1;
    if (metric == DeskMonitorMetricNetwork && _hist) {
        double cov = 0;
        double total = [_hist totalForPid:pid metric:DeskHistNetwork
                                      now:[NSDate date].timeIntervalSince1970
                                   window:kDeskHistoryWindow covered:&cov];
        if (cov > 0 && total > 0) hv.histTotal = total;
    }
    // 能耗那行报的是占比，分母必须跟组件那一拍算的一样，浮层自己再求一次和就是第二套真相
    NSView *cv = host.contentView;
    hv.energyTotal = [cv isKindOfClass:[DeskMonitorView class]] ? ((DeskMonitorView *)cv).energyShareTotal : 0;
    _monitorHoverWindow.contentView = hv;

    // 浮层跟着鼠标走、放在鼠标左边、夹在可视区里（摆位规则见 monitor_view.h 的 DeskHoverBubbleRect）
    NSPoint m = [NSEvent mouseLocation];
    NSScreen *sc = host.screen ?: [NSScreen mainScreen];
    NSRect bubble = DeskHoverBubbleRect(m, size, sc.visibleFrame);
    [_monitorHoverWindow setFrame:bubble display:YES animate:NO];
    [_monitorHoverWindow orderFrontRegardless];
}

- (NSInteger)uidOfPid:(pid_t)pid {
    struct proc_bsdinfo bi;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof(bi)) == sizeof(bi)) return bi.pbi_uid;
    return -1;
}

- (void)rebuildMonitorWindows {
    [_monitorHoverWindow orderOut:nil];
    for (NSWindow *w in _monitorWindows) [w orderOut:nil];
    _monitorWindows = [NSMutableArray array];
    for (NSScreen *screen in [NSScreen screens]) {
        NSWindow *w = [self makeMonitorWindowForScreen:screen];
        [_monitorWindows addObject:w];
    }
    [self applyMonitorShadow];
    [self applyMonitorVisibility];
    DeskLog(@"活动监视器建窗 %lu 个（读到 %ld 个进程），层级=%d（桌面图标层）",
            (unsigned long)_monitorWindows.count, (long)_monitorCount, kCGDesktopIconWindowLevel);
}

- (void)applyMonitorVisibility {
    for (NSWindow *w in _monitorWindows) {
        if (_monitorHidden) [w orderOut:nil];
        else [w orderFrontRegardless];
    }
}

// 同层竞争：访达的桌面窗和监视器同在 kCGDesktopIconWindowLevel。桌面刷新、切 Space、换壁纸都会
// 让 WindowServer 把它排到组件前面，此后每一次点击都归访达 —— 组件看着好好的，按住却一动不动。
// 弹药库早就有「定时顶回本层最前」这一手（checkVaultCover:），监视器过去只在建窗/显示时顶一次，
// 这就是三块组件里"只有这一块拖不动"的差别所在。
- (void)raiseMonitorAboveSameLayer {
    if (_monitorHidden || _monitorWindows.count == 0) return;
    for (NSWindow *w in _monitorWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskMonitorView class]] && [(DeskMonitorView *)v isDragging]) return;
    }   // 正按住拖着的时候顶一层，等于从用户手里把窗口抢走
    for (NSWindow *w in _monitorWindows) [w orderFrontRegardless];
    // 悬停气泡和组件同层：顶完组件要再把气泡顶回来，否则气泡会被组件盖住
    if (_monitorHoverWindow.isVisible) [_monitorHoverWindow orderFrontRegardless];
}

- (void)setMonitorHidden:(BOOL)hidden {
    if (_monitorHidden == hidden) return;
    _monitorHidden = hidden;
    [self applyMonitorVisibility];
    [self saveConfig];
    [self syncMenu];
    DeskLog(@"活动监视器 %@ 已存档", hidden ? @"隐藏" : @"显示");
}

- (void)toggleMonitorHidden:(id)sender { [self setMonitorHidden:!_monitorHidden]; }

- (void)openActivityMonitor:(id)sender {
    (void)sender;
    NSURL *am = [NSURL fileURLWithPath:@"/System/Applications/Utilities/Activity Monitor.app"];
    [[NSWorkspace sharedWorkspace] openURL:am];
    DeskLog(@"活动监视器 已请求打开原生活动监视器");
}

// 换外观时窗影也要跟着换：无底那档留着窗影，字后面就全是软影子
- (void)applyMonitorShadow {
    // 变形态一律没窗影：那时外框是矩形，窗影会出卖"其实是个斜的四边形"。
    // 无边玻璃也不要窗影：窗口 alpha 轮廓会被 WindowServer 压成一圈深边。
    BOOL shadow = ![self monitorQuadActive]
               && ((DeskStyle)_monitorStyle != DeskStyleBare)
               && ((DeskStyle)_monitorStyle != DeskStyleHUD);
    for (NSWindow *w in _monitorWindows) w.hasShadow = shadow;
    _monitorHoverWindow.hasShadow = shadow;
}

- (void)chooseMonitorStyle:(id)sender {
    _monitorStyle = [sender tag];
    for (NSWindow *w in _monitorWindows) {
        DeskMonitorView *v = (DeskMonitorView *)w.contentView;
        if ([v isKindOfClass:[DeskMonitorView class]]) v.style = (DeskStyle)_monitorStyle;
    }
    [self applyMonitorShadow];
    [self saveConfig];
    [self syncMenu];
}

// 简略模式和完整模式共用同一组窗口/视图，只是卡片尺寸和绘制密度不同。
// 切换时重建窗口：摆位档是"角 + 距边"，用新尺寸重算后当前角的 16pt 锚点不动。
- (void)toggleMonitorCompact:(id)sender {
    _monitorCompact = !_monitorCompact;
    if (_monitorCompact && _monitorEditing) {
        _monitorEditing = NO;
        DeskLog(@"活动监视器进入简略模式：先退出调角");
    }
    NSSize card = [DeskMonitorView cardSizeCompact:_monitorCompact];
    // 四角位移是点偏移；换成小卡片后不夹一下会把角留在画布外
    _monitorQuad = DeskQuadOffsetsClamp(_monitorQuad, card);
    [self saveConfig];
    [self rebuildMonitorWindows];
    [self syncMenu];
    DeskLog(@"活动监视器简略模式：%@（卡片 %.0fx%.0f）",
            _monitorCompact ? @"开" : @"关", card.width, card.height);
}

- (void)applyMonitorQuad:(DeskQuadOffsets)q {
    _monitorQuad = q;
    for (NSWindow *w in _monitorWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskMonitorView class]]) ((DeskMonitorView *)v).quadOffsets = q;
    }
    [self applyMonitorShadow];
    [self applyMonitorFrames];
    [self saveConfig];
    DeskLog(@"活动监视器角点已保存 %@", DeskQuadOffsetsString(q));
}

- (void)toggleMonitorEditing:(id)sender {
    (void)sender;
    _monitorEditing = !_monitorEditing;
    for (NSWindow *w in _monitorWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskMonitorView class]]) ((DeskMonitorView *)v).editing = _monitorEditing;
    }
    [self applyMonitorShadow];
    [self applyMonitorFrames];
    [self saveConfig];
    [self syncMenu];
    DeskLog(@"活动监视器调角模式：%@", _monitorEditing ? @"开" : @"关");
}

- (void)resetMonitorQuad:(id)sender {
    (void)sender;
    [self applyMonitorQuad:DeskQuadOffsetsZero()];
    DeskLog(@"活动监视器角点已复位");
}

// 拖不动的时候（被别的窗口压住、或者鼠标事件到不了桌面层），用户得有一条不依赖
// "按住组件"就能挪它的出路。摆位本来就存在 _monitorPlaces 里，这里只是给它一个菜单口。
- (void)moveMonitorToCorner:(id)sender {
    if ([self refuseMoveWhenLocked:@"活动监视器摆到四角"]) return;
    NSInteger corner = [sender tag];
    for (NSScreen *screen in [NSScreen screens]) {
        DeskPlace p = [_monitorPlaces placeForScreen:screen];
        p.corner = corner;
        [_monitorPlaces setPlace:p forKey:[_monitorPlaces keyForScreen:screen]];
    }
    [self applyMonitorFrames];
    [self saveConfig];
    [self syncMenu];
    static const char *names[4] = { "左上", "右上", "左下", "右下" };
    DeskLog(@"活动监视器摆到 %@（档位 dx/dy 保持不变）", [NSString stringWithUTF8String:names[corner & 3]]);
}

// 拖不动时的第二条出路：不靠鼠标，用菜单把组件每次挪 20pt。
// 先搬窗口、再复用 saveMonitorPlaceInWindow: 落档 —— 存档是"角 + 距边距离"，
// 自己再算一遍 dx/dy 的符号就是给同一个换算留第二套真相（那 60pt 漂移就是这么来的）。
// 九宫格一键摆位：用户已选定"被压住时靠菜单摆位"，而原来只能 20pt 一格格挪，
// 从右上角挪到屏幕中间要二十多下。这里给九个落点，一次到位（不依赖按住拖，也不怕遮挡）。
// tag = 行*3 + 列，行 0=上 1=中 2=下，列 0=左 1=中 2=右。
- (void)placeMonitorAtCell:(id)sender {
    if ([self refuseMoveWhenLocked:@"活动监视器九宫格摆位"]) return;
    NSWindow *w = _monitorWindows.firstObject;
    if (!w) { DeskLog(@"九宫格摆位：没有可摆的监视器窗口"); return; }
    NSScreen *screen = w.screen ?: [NSScreen mainScreen];
    NSRect vf = screen.visibleFrame;
    NSInteger tag = [sender tag] & 15;
    NSInteger row = tag / 3, col = tag % 3;
    const CGFloat margin = 16.0;
    NSSize card = [DeskMonitorView cardSizeCompact:_monitorCompact];
    CGFloat x = (col == 0) ? NSMinX(vf) + margin
              : (col == 1) ? NSMidX(vf) - card.width / 2.0
                           : NSMaxX(vf) - card.width - margin;
    CGFloat y = (row == 0) ? NSMaxY(vf) - card.height - margin
              : (row == 1) ? NSMidY(vf) - card.height / 2.0
                           : NSMinY(vf) + margin;
    [w setFrameOrigin:NSMakePoint(x, y)];
    [self saveMonitorPlaceInWindow:w];   // 存档是"角 + 距边"，换算只留这一处
    [self applyMonitorFrames];           // 夹边后按存档重申，窗口和存档保持一致
    static const char *rows[3] = { "上", "中", "下" };
    static const char *cols[3] = { "左", "中", "右" };
    DeskLog(@"活动监视器摆到 %s%s（九宫格，不用按住拖）→ 窗口原点(%.0f,%.0f)",
            rows[row & 3], cols[col & 3], w.frame.origin.x, w.frame.origin.y);
}

- (void)nudgeMonitor:(id)sender {
    if ([self refuseMoveWhenLocked:@"活动监视器微调"]) return;
    CGFloat dx = 0, dy = 0;
    switch ([sender tag]) {
        case 0: dx = -20; break;   // 左
        case 1: dx =  20; break;   // 右
        case 2: dy =  20; break;   // 上（Cocoa 的 y 朝上）
        default: dy = -20; break;  // 下
    }
    for (NSWindow *w in _monitorWindows) {
        NSRect f = w.frame;
        [w setFrameOrigin:NSMakePoint(f.origin.x + dx, f.origin.y + dy)];
        [self saveMonitorPlaceInWindow:w];
    }
    // 必须再按存档重申一遍：saveMonitorPlaceInWindow: 会把 dx/dy 夹在 [16, 屏宽-卡宽-16] 里，
    // 一直往同一个方向推就会推到夹界外 —— 窗口实际位置已经越界、存档却记成 16，
    // 两者不一致，下次重启会凭空跳一段。重申之后"窗口 == 存档"恒成立，推到边就干净停住。
    [self applyMonitorFrames];
    [self syncMenu];
    DeskLog(@"活动监视器微调 (%+.0f,%+.0f)pt，不用按住拖也能挪", dx, dy);
}

// 一键自检：把「按住并拖 30pt」直接喂给真窗口的真视图，走的就是生产路径
// （mouseDown → mouseDragged → dragWindowToMouse → 夹边 → onUserMove 落档 → 重申）。
// 它不依赖真鼠标，也不受遮挡影响（点的是菜单栏），所以组件被别的窗口压住时照样能出结论：
// 位移没到手 = 代码链本身还有 bug；位移到手且重申后守住 = 剩下的只可能是真事件没送进来。
// 按点扫描：把"按住哪里起得了拖"量成事实。用户报的是"没法拖拉"，如果他按的正好是一块不起拖
// 的区域（榜头、行文字、右边缘、四角留白），那和事件投递、存档夹边都无关 —— 是命中区的问题，
// 只能扫出来。每点都走生产路径：mouseDown → 看起没起拖 → 搬 10pt → mouseUp → 看窗口动没动。
- (void)selfTestMonitorPressPoints:(id)sender {
    NSWindow *w = _monitorWindows.firstObject;
    NSView *cv = w.contentView;
    if (![cv isKindOfClass:[DeskMonitorView class]]) {
        DeskLog(@"自检：没有可测的活动监视器窗口");
        return;
    }
    DeskMonitorView *mv = (DeskMonitorView *)cv;
    NSRect f0 = w.frame, b = [mv bounds];
    DeskPlace before = [_monitorPlaces placeForScreen:(w.screen ?: [NSScreen mainScreen])];
    struct { const char *where; CGFloat fx, fy; } pts[] = {
        { "榜头左", 0.06f, 0.94f }, { "榜头中", 0.50f, 0.94f }, { "榜头右", 0.94f, 0.94f },
        { "CPU标题行", 0.20f, 0.80f }, { "内存标题行", 0.72f, 0.80f },
        { "第一行名字上", 0.18f, 0.68f }, { "第一行数值上", 0.44f, 0.68f },
        { "能耗行上", 0.18f, 0.34f }, { "网络行上", 0.72f, 0.34f },
        { "最左留白", 0.01f, 0.50f }, { "最右留白", 0.99f, 0.50f },
        { "左上角", 0.02f, 0.98f }, { "右下角", 0.98f, 0.02f }, { "底部中", 0.50f, 0.02f },
    };
    NSTimeInterval ts = [NSDate date].timeIntervalSince1970;
    void (^savedLog)(NSString *) = [mv.onLog copy];
    mv.onLog = ^(NSString *line) { (void)line; };   // 别把「按下」计数灌进真人信号里
    int dead = 0;
    for (size_t i = 0; i < sizeof(pts) / sizeof(pts[0]); i++) {
        NSPoint p = NSMakePoint(NSMinX(b) + NSWidth(b) * pts[i].fx,
                                NSMinY(b) + NSHeight(b) * pts[i].fy);
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p modifierFlags:0
                                           timestamp:ts windowNumber:w.windowNumber context:nil
                                         eventNumber:241 clickCount:1 pressure:1.0];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:p modifierFlags:0
                                        timestamp:ts windowNumber:w.windowNumber context:nil
                                     eventNumber:243 clickCount:1 pressure:0.0];
        NSPoint c = NSEvent.mouseLocation;
        [mv mouseDown:down];
        BOOL started = [mv isDragging];
        [mv dragWindowToMouse:NSMakePoint(c.x + 10, c.y + 10)];
        [mv mouseUp:up];
        NSRect f1 = w.frame;
        BOOL moved = hypot(f1.origin.x - f0.origin.x, f1.origin.y - f0.origin.y) > 0.5;
        if (!started || !moved) dead++;
        DeskLog(@"自检 按点 %@（视图坐标 %.0f,%.0f）：起拖=%d 搬窗=%d",
                [NSString stringWithUTF8String:pts[i].where], p.x, p.y, started, moved);
        [w setFrameOrigin:f0.origin];
        [self applyMonitorFrames];
    }
    mv.onLog = savedLog;
    NSScreen *scr = w.screen ?: [NSScreen mainScreen];
    [_monitorPlaces setPlace:before forKey:[_monitorPlaces keyForScreen:scr]];
    [self saveConfig];
    [self applyMonitorFrames];
    DeskLog(@"自检 按点扫描：%zu 个点里 %d 个是死区", sizeof(pts) / sizeof(pts[0]), dead);
}

// 用户已选定「被压住时靠菜单摆位」，那这条替代路径本身就得可靠：微调每次 20pt，
// 连点几十次会跨过屏幕中线、让存档 corner 从右上翻成左上/左下，换边算式一错就会跳位。
// 这里按左 N 次 + 上 M 次走一遍，核对实际位移和期望位移对不对、重申后守不守得住。
- (void)selfTestMonitorNudgeWalk:(id)sender {
    NSWindow *w = _monitorWindows.firstObject;
    if (!w) { DeskLog(@"自检：没有可测的活动监视器窗口"); return; }
    NSRect f0 = w.frame;
    DeskPlace before = [_monitorPlaces placeForScreen:(w.screen ?: [NSScreen mainScreen])];
    NSInteger left = 12, up = 6;             // 期望：左 240pt、上 120pt
    for (NSInteger i = 0; i < left; i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
        it.tag = 0;                          // nudgeMonitor: 的 0 = 左移 20pt
        [self nudgeMonitor:it];
    }
    for (NSInteger i = 0; i < up; i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
        it.tag = 2;                          // 2 = 上移 20pt（Cocoa y 朝上）
        [self nudgeMonitor:it];
    }
    NSRect f1 = w.frame;
    [self applyMonitorFrames];               // 重申一次，看守不守得住
    NSRect f2 = w.frame;
    DeskLog(@"自检 微调走位：期望(%+ld,%+ld) 走成(%+.0f,%+.0f) 重申后(%+.0f,%+.0f) %@",
            (long)(-left * 20), (long)(up * 20),
            f1.origin.x - f0.origin.x, f1.origin.y - f0.origin.y,
            f2.origin.x - f0.origin.x, f2.origin.y - f0.origin.y,
            (fabs(f2.origin.x - f1.origin.x) < 0.5 && fabs(f2.origin.y - f1.origin.y) < 0.5)
                ? @"守住" : @"重申后跳位");
    NSScreen *scr = w.screen ?: [NSScreen mainScreen];
    [_monitorPlaces setPlace:before forKey:[_monitorPlaces keyForScreen:scr]];
    [self applyMonitorFrames];
    [self saveConfig];
}

// 九宫格自检：九个落点必须各自到位、且重申后不偏 —— 这是"被压住时唯一可用"的那条路径。
- (void)selfTestMonitorGrid:(id)sender {
    NSWindow *w = _monitorWindows.firstObject;
    if (!w) { DeskLog(@"自检：没有可测的活动监视器窗口"); return; }
    NSScreen *scr = w.screen ?: [NSScreen mainScreen];
    NSRect vf = scr.visibleFrame;
    DeskPlace before = [_monitorPlaces placeForScreen:scr];
    int bad = 0;
    for (int i = 0; i < 9; i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
        it.tag = i;
        [self placeMonitorAtCell:it];
        NSRect f = w.frame;
        int row = i / 3, col = i % 3;
        NSSize card = [DeskMonitorView cardSizeCompact:_monitorCompact];
        CGFloat wantX = col == 0 ? NSMinX(vf) + 16
                      : col == 1 ? NSMidX(vf) - card.width / 2.0
                                 : NSMaxX(vf) - card.width - 16;
        CGFloat wantY = row == 0 ? NSMaxY(vf) - card.height - 16
                      : row == 1 ? NSMidY(vf) - card.height / 2.0
                                 : NSMinY(vf) + 16;
        BOOL ok = fabs(f.origin.x - wantX) < 0.6 && fabs(f.origin.y - wantY) < 0.6;
        if (!ok) bad++;
        DeskLog(@"自检 九宫格 %d：期望(%.0f,%.0f) 实测(%.0f,%.0f) %@",
                i, wantX, wantY, f.origin.x, f.origin.y, ok ? @"对上" : @"偏了");
    }
    [_monitorPlaces setPlace:before forKey:[_monitorPlaces keyForScreen:scr]];
    [self saveConfig];
    [self applyMonitorFrames];
    DeskLog(@"自检 九宫格：9 个落点 %d 个对不上（跑完已还原原档位）", bad);
}

- (void)selfTestMonitorDrag:(id)sender {
    NSWindow *w = _monitorWindows.firstObject;
    NSView *cv = w.contentView;
    if (![cv isKindOfClass:[DeskMonitorView class]]) {
        DeskLog(@"自检：没有可测的活动监视器窗口");
        return;
    }
    DeskMonitorView *mv = (DeskMonitorView *)cv;
    NSRect f0 = w.frame;
    // 先报本进程眼里的壁纸：门里那 5 条红是 CLI 进程量的（域/容器都可能不一样），
    // 组件到底有没有"真模糊底"必须在 App 自己进程里量，别拿 CLI 的结论代替。
    NSString *wp = [[DeskBackdrop shared] wallpaperPath];
    NSImage *bd = [[DeskBackdrop shared] imageForRect:f0 dark:YES];   // 未变形时窗口=卡片矩形
    DeskLog(@"自检 壁纸：路径=%@ 采样=%@", wp.lastPathComponent ?: @"(无)", bd ? @"有底图" : @"无底图");
    // 进来先抄一份档位：每一发拖动都会经 onUserMove 改写存档，跑完要按这份还原
    DeskPlace before = [_monitorPlaces placeForScreen:(w.screen ?: [NSScreen mainScreen])];
    NSTimeInterval ts = [NSDate date].timeIntervalSince1970;
    NSPoint mid = NSMakePoint(NSWidth(f0) / 2, NSHeight(f0) / 2);
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:mid modifierFlags:0
                                       timestamp:ts windowNumber:w.windowNumber context:nil
                                     eventNumber:201 clickCount:1 pressure:1.0];
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:mid modifierFlags:0
                                    timestamp:ts windowNumber:w.windowNumber context:nil
                                 eventNumber:203 clickCount:1 pressure:0.0];
    // 四个方向各试一次：存档的 dx/dy 原来夹在 [16, …]，组件正贴在边距下限，朝上/朝右的位移
    // 会被夹回下限，下一次重申就把窗口拉回原位 —— 用户看到的就是"按住拖了又自己弹回来"。
    // 再加三发跨中线的：corner 一翻，dx/dy 就从"距左/距下"换成"距右/距上"，
    // 换边算式是历史事故区（那次 60pt 漂移就是这么来的），所以必须单独量。
    static const CGFloat off[][2] = { { 30, 30 }, { -30, -30 }, { 8, 8 }, { 0, -60 },
                                      { -400, 0 }, { 0, -400 }, { -400, -400 } };
    static const char *name[] = { "右上(超边距)", "左下(边距内)", "右上(边距内)", "正下 60",
                                  "跨横中线 左400", "跨纵中线 下400", "跨两线 左下400" };
    // 自检灌的是真 mouseDown/mouseUp，视图自己会打「按下」「松手」——那正是
    // tools/diagnose_drag.py 数的那几条，一次自检就把真人信号冲掉（实测按下从 0 变 37）。
    // 所以合成事件期间把这块视图的日志静音，自检的结论由下面自己的 DeskLog 出。
    void (^savedLog)(NSString *) = [mv.onLog copy];
    mv.onLog = ^(NSString *line) { (void)line; };   // 属性是 nonnull，不能直接塞 nil
    for (size_t i = 0; i < sizeof(off) / sizeof(off[0]); i++) {
        NSPoint c = NSEvent.mouseLocation;
        [mv mouseDown:down];
        // 光标没动的一次真 mouseDragged：窗口必须一步都不漂。
        // 自检此前只直接调 dragWindowToMouse:，等于绕开了用户实际走的那个处理器
        // （日志里 44 条自检按下全是「拖了 0 帧」就是证据）。
        NSEvent *drag0 = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
                                            location:NSMakePoint(NSWidth(f0) / 2, NSHeight(f0) / 2)
                                        modifierFlags:0 timestamp:ts windowNumber:w.windowNumber
                                             context:nil eventNumber:202 clickCount:1 pressure:1.0];
        [mv mouseDragged:drag0];
        NSRect fz = w.frame;
        BOOL noDrift = hypot(fz.origin.x - f0.origin.x, fz.origin.y - f0.origin.y) < 0.5;
        [mv dragWindowToMouse:NSMakePoint(c.x + off[i][0], c.y + off[i][1])];
        [mv mouseUp:up];
        NSRect f1 = w.frame;
        [self applyMonitorFrames];       // 落档守不守得住：按存档重申一次再看
        NSRect f2 = w.frame;
        // 三种结果必须分开说，不然工具会自己骗自己：
        //   守住   = 重申后停在松手处（用户要的就是这个）
        //   夹边界 = 松手处超出可视区，被合法夹到边界上并停住（不是 bug）
        //   弹回原位 = 重申后回到按下前的位置 —— 这才是"拖不动"
        CGFloat backToStart = hypot(f2.origin.x - f0.origin.x, f2.origin.y - f0.origin.y);
        CGFloat held = hypot(f2.origin.x - f1.origin.x, f2.origin.y - f1.origin.y);
        const char *verdict = held < 0.5 ? "守住" : (backToStart < 0.5 ? "弹回原位(bug)" : "夹到可视边界");
        DeskLog(@"自检 %@：拖后位移(%+.0f,%+.0f) 重申后(%+.0f,%+.0f) 零漂=%d %s",
                [NSString stringWithUTF8String:name[i]],
                f1.origin.x - f0.origin.x, f1.origin.y - f0.origin.y,
                f2.origin.x - f0.origin.x, f2.origin.y - f0.origin.y,
                noDrift, verdict);
        // 复原必须连存档一起还原：只 setFrameOrigin 的话，紧跟的 applyMonitorFrames 会按
        // 上一发写脏的存档把窗口搬回去，于是这一发的"按下前基准"根本不是 f0（实测串出 15pt）。
        [w setFrameOrigin:f0.origin];
        NSScreen *rs = w.screen ?: [NSScreen mainScreen];
        [_monitorPlaces setPlace:before forKey:[_monitorPlaces keyForScreen:rs]];
        [self applyMonitorFrames];
        NSAssert(hypot(w.frame.origin.x - f0.origin.x, w.frame.origin.y - f0.origin.y) < 1.0,
                 @"自检复原失败：基准漂了");
    }
    mv.onLog = savedLog;
    // 自检不许动用户的存档：每一发的落档都会改写档位，跑完必须还原成进来时的样子
    NSScreen *scr = w.screen ?: [NSScreen mainScreen];
    [_monitorPlaces setPlace:before forKey:[_monitorPlaces keyForScreen:scr]];
    [self saveConfig];
    [self applyMonitorFrames];
}

- (NSMenu *)cornerMenuForTitle:(NSString *)title action:(SEL)action {
    NSMenu *m = [[NSMenu alloc] initWithTitle:title];
    static const char *names[4] = { "左上角", "右上角", "左下角", "右下角" };
    for (int i = 0; i < 4; i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:[NSString stringWithUTF8String:names[i]] action:action keyEquivalent:@""];
        it.tag = i;
        [m addItem:it];
    }
    return m;
}

- (void)applyMonitorFrames {
    NSUInteger i = 0;
    for (NSScreen *screen in [NSScreen screens]) {
        if (i >= _monitorWindows.count) break;
        [_monitorWindows[i++] setFrame:[self monitorFrameForScreen:screen] display:YES animate:NO];
    }
}

- (void)saveMonitorPlaceInWindow:(NSWindow *)w {
    if (!w) return;
    NSScreen *screen = w.screen ?: [NSScreen mainScreen];
    NSRect vf = screen.visibleFrame;
    NSRect f = w.frame;
    // 存档里的 dx/dy 描述的是**看得见的卡片**。变形时窗口外扩一圈余量，
    // 不先按 pad 缩回卡片矩形的话，拖一次就漂 60pt，越拖越偏。
    NSSize mcard = [DeskMonitorView cardSizeCompact:_monitorCompact];
    NSSize mwin = [DeskMonitorView windowSizeWarped:[self monitorQuadActive] compact:_monitorCompact];
    CGFloat m_padX = (mwin.width - mcard.width) / 2.0, m_padY = (mwin.height - mcard.height) / 2.0;
    f = NSMakeRect(NSMinX(f) + m_padX, NSMinY(f) + m_padY, mcard.width, mcard.height);
    DeskPlace p = DeskPlaceFromFrame(f, mcard, vf);
    if (NSIntersectsRect(f, vf)) {
        NSString *key = [_monitorPlaces keyForScreen:screen];
        [_monitorPlaces setPlace:p forKey:key];
        [self saveConfig];
        DeskLog(@"活动监视器位置已保存 %@ → 角 %ld 偏移 %.0f,%.0f", key, (long)p.corner, p.dx, p.dy);
    } else {
        DeskLog(@"活动监视器整块拖出可视区，不存档，原地拉回");
        [w setFrame:[self monitorFrameForScreen:screen] display:YES];
    }
}

#pragma mark - 组件 4：签到 CREDITS

- (NSRect)creditsFrameForScreen:(NSScreen *)screen {
    NSRect vf = screen.visibleFrame;
    DeskPlace p = [_creditsPlaces effectivePlaceForScreen:screen];
    NSSize card = NSMakeSize(kCreditsViewWidth, kCreditsViewHeight);
    CGFloat x = (p.corner == 1 || p.corner == 3) ? NSMaxX(vf) - card.width - p.dx
                                                  : vf.origin.x + p.dx;
    CGFloat y = (p.corner >= 2) ? vf.origin.y + p.dy : NSMaxY(vf) - card.height - p.dy;
    NSRect r = NSMakeRect(round(x), round(y), card.width, card.height);
    if (!NSIntersectsRect(r, vf)) {
        p = _creditsPlaces.fallbackPlace;
        DeskLog(@"签到档 %@ 落出可视区，夹回默认锚点（左上）", [_creditsPlaces keyForScreen:screen]);
        [_creditsPlaces setPlace:p forKey:[_creditsPlaces keyForScreen:screen]];
        [self saveConfig];
        CGFloat fx = (p.corner == 1 || p.corner == 3) ? NSMaxX(vf) - card.width - p.dx
                                                       : vf.origin.x + p.dx;
        CGFloat fy = (p.corner >= 2) ? vf.origin.y + p.dy : NSMaxY(vf) - card.height - p.dy;
        r = NSMakeRect(round(fx), round(fy), card.width, card.height);
    }
    return r;
}

- (NSWindow *)makeCreditsWindowForScreen:(NSScreen *)screen {
    NSRect frame = [self creditsFrameForScreen:screen];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [w setBackgroundColor:[NSColor clearColor]];
    w.opaque = NO;
    w.hasShadow = ((DeskStyle)_creditsStyle != DeskStyleHUD);
    w.level = kCGDesktopIconWindowLevel;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                         | NSWindowCollectionBehaviorStationary
                         | NSWindowCollectionBehaviorIgnoresCycle;
    w.movableByWindowBackground = NO;
    w.animationBehavior = NSWindowAnimationBehaviorNone;
    w.excludedFromWindowsMenu = YES;
    w.acceptsMouseMovedEvents = YES;   // 让悬停 tooltip 有事件；组件本身仍只画快照
    w.title = @"DeskBoard 签到";
    DeskCreditsView *v = [[DeskCreditsView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
    v.style = (DeskStyle)_creditsStyle;
    v.locked = _layoutLocked;
    [v updateCenter:_creditsCenter ?: [DeskCreditsCenterSnapshot centerWithMiniMax:_credits.snapshot
                                                                             trae:_trae.snapshot
                                                                            qoder:_qoder.snapshot
                                                                        workbuddy:_workbuddy.snapshot]];
    __weak typeof(self) weakSelf = self;
    __weak NSWindow *weakW = w;
    v.onUserMove = ^{ [weakSelf saveCreditsPlaceInWindow:weakW]; };
    v.onSlotActivate = ^(DeskCreditsPlatform p) { [weakSelf creditsActivatePlatform:p]; };
    v.onSlotDoubleClick = ^(DeskCreditsPlatform p) { [weakSelf creditsDoubleClickPlatform:p]; };
    v.onSlotCheckNow = ^(DeskCreditsPlatform p) { [weakSelf creditsCheckNowPlatform:p]; };
    w.contentView = v;
    [self logWindowSnapshot:w tag:@"签到"];
    return w;
}

- (void)rebuildCreditsWindows {
    for (NSWindow *w in _creditsWindows) [w orderOut:nil];
    _creditsWindows = [NSMutableArray array];
    for (NSScreen *screen in [NSScreen screens]) {
        NSWindow *w = [self makeCreditsWindowForScreen:screen];
        [_creditsWindows addObject:w];
    }
    [self applyCreditsVisibility];
    DeskLog(@"签到建窗 %lu 个，%@，层级=%ld（桌面图标层）",
            (unsigned long)_creditsWindows.count, _creditsHidden ? @"已隐藏" : @"已显示",
            (long)kCGDesktopIconWindowLevel);
}

- (void)applyCreditsVisibility {
    for (NSWindow *w in _creditsWindows) {
        if (_creditsHidden) [w orderOut:nil];
        else [w orderFrontRegardless];
    }
}

// 同层竞争：访达的桌面窗和签到组件同在 kCGDesktopIconWindowLevel，它一旦排到组件前面
// （刷新桌面、切 Space、换壁纸都会重排），签到块看着好好的却一点都点不动 —— 点击被它截走。
// 弹药库和活动监视器各自有定时顶回，签到是第四块、建在它们之后，只在建窗/显隐时排过一次面。
// 这一层没有「置顶」可设，只能定时顶回去。
- (void)raiseCreditsAboveSameLayer {
    if (_creditsHidden || _creditsWindows.count == 0) return;
    for (NSWindow *w in _creditsWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskCreditsView class]] && [(DeskCreditsView *)v isDragging]) return;
    }   // 正按住拖着的时候顶一层，等于从用户手里把窗口抢走
    for (NSWindow *w in _creditsWindows) [w orderFrontRegardless];
}

- (void)applyCreditsFrames {
    if (_applying) return;
    _applying = YES;
    NSUInteger i = 0;
    for (NSScreen *screen in [NSScreen screens]) {
        if (i >= _creditsWindows.count) break;
        [_creditsWindows[i++] setFrame:[self creditsFrameForScreen:screen]
                               display:YES animate:NO];
    }
    _applying = NO;
}

- (void)saveCreditsPlaceInWindow:(NSWindow *)w {
    if (!w) return;
    NSScreen *screen = w.screen ?: [NSScreen mainScreen];
    NSRect vf = screen.visibleFrame;
    NSRect f = w.frame;
    DeskPlace p = DeskPlaceFromFrame(f, NSMakeSize(kCreditsViewWidth, kCreditsViewHeight), vf);
    if (NSIntersectsRect(f, vf)) {
        NSString *key = [_creditsPlaces keyForScreen:screen];
        [_creditsPlaces setPlace:p forKey:key];
        [self saveConfig];
        DeskLog(@"签到位置已保存 %@ → 角 %ld 偏移 %.0f,%.0f", key, (long)p.corner, p.dx, p.dy);
    } else {
        DeskLog(@"签到整块拖出可视区，不存档，原地拉回");
        [w setFrame:[self creditsFrameForScreen:screen] display:YES];
    }
}

- (void)setCreditsHidden:(BOOL)hidden {
    if (_creditsHidden == hidden) return;
    _creditsHidden = hidden;
    [self applyCreditsVisibility];
    [self saveConfig];
    [self syncMenu];
    DeskLog(@"签到组件 %@ 已存档", hidden ? @"隐藏" : @"显示");
}

- (void)toggleCreditsHidden:(id)sender {
    (void)sender;
    [self setCreditsHidden:!_creditsHidden];
}

- (void)chooseCreditsStyle:(id)sender {
    _creditsStyle = [sender tag];
    for (NSWindow *w in _creditsWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskCreditsView class]]) {
            ((DeskCreditsView *)v).style = (DeskStyle)_creditsStyle;
        }
        w.hasShadow = ((DeskStyle)_creditsStyle != DeskStyleHUD);
    }
    [self saveConfig];
    [self syncMenu];
    DeskLog(@"签到外观改为 %ld", (long)_creditsStyle);
}

- (void)resetCreditsPlace:(id)sender {
    (void)sender;
    if ([self refuseMoveWhenLocked:@"签到恢复默认位置"]) return;
    for (NSScreen *screen in [NSScreen screens]) {
        [_creditsPlaces setPlace:DeskPlaceDefaultForKind(DeskPlaceKindCredits)
                          forKey:[_creditsPlaces keyForScreen:screen]];
    }
    [self applyCreditsFrames];
    [self saveConfig];
    [self syncMenu];
    DeskLog(@"签到组件恢复默认位置（左上）");
}

- (void)applyCreditsRecordsToCenter:(DeskCreditsCenterSnapshot *)c {
    if (!c || !_creditsRecords) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    DeskCreditsSnapshot *m = _credits.snapshot;
    DeskTraeSnapshot *t = _trae.snapshot;
    DeskQoderSnapshot *q = _qoder.snapshot;
    DeskWorkbuddySnapshot *w = _workbuddy.snapshot;

    // 能拿到稳定 uid 的平台按账号分档；换号时旧纪录和最近签到一起重置。
    if (t.uid.length) [_creditsRecords setAccountKey:t.uid forPlatform:DeskCreditsPlatformTrae];
    if (q.uid.length) [_creditsRecords setAccountKey:q.uid forPlatform:DeskCreditsPlatformQoder];
    if (w.uid.length) [_creditsRecords setAccountKey:w.uid forPlatform:DeskCreditsPlatformWorkBuddy];

    // 成功事件才写：provider 明确说“今天已签/已领”才标记；失败态不会走到这里。
    if (m.todayChecked && m.dayKey.length) {
        [_creditsRecords markCheckInPlatform:DeskCreditsPlatformMiniMax
                                      amount:m.todayPoints dayKey:m.dayKey];
    }
    if (t.checkedIn && t.dayKey.length) {
        [_creditsRecords markCheckInPlatform:DeskCreditsPlatformTrae
                                      amount:t.todayCredits dayKey:t.dayKey];
    }
    if (w.checkedIn && w.dayKey.length) {
        [_creditsRecords markCheckInPlatform:DeskCreditsPlatformWorkBuddy
                                      amount:w.todayCredit dayKey:w.dayKey];
    }
    // Qoder 的“今天”按活动窗口起算：启动时若本窗口已领，窗口起始日就是领取日；
    // 运行中真正领取的那一拍会由 applyQoderSnapshot: 用今天覆盖（更新的日期优先）。
    if (q.claimed && q.windowStart > 0) {
        [_creditsRecords markCheckInPlatform:DeskCreditsPlatformQoder
                                      amount:q.claimedAmount
                                      dayKey:DeskCreditsDayKey(q.windowStart)];
    }

    for (DeskCreditsSlot *slot in c.slots) {
        if (slot.kind == DeskCreditsSlotKindUnconnected) continue;
        if (slot.balance >= 0) {
            [_creditsRecords samplePlatform:slot.platform balance:slot.balance at:now];
        }
    }
    for (DeskCreditsSlot *slot in c.slots) {
        if (slot.kind == DeskCreditsSlotKindUnconnected) continue;
        [_creditsRecords applyPlatform:slot.platform toSlot:slot at:now];
    }
}

- (void)applyCreditsSnapshot:(DeskCreditsSnapshot *)s {
    _creditsCenter = [DeskCreditsCenterSnapshot centerWithMiniMax:s trae:_trae.snapshot
                                                            qoder:_qoder.snapshot
                                                        workbuddy:_workbuddy.snapshot];
    [self applyCreditsRecordsToCenter:_creditsCenter];
    for (NSWindow *w in _creditsWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskCreditsView class]]) {
            [(DeskCreditsView *)v updateCenter:_creditsCenter];
        }
    }
    [self syncMenu];
}

- (void)applyTraeSnapshot:(DeskTraeSnapshot *)t {
    _creditsCenter = [DeskCreditsCenterSnapshot centerWithMiniMax:_credits.snapshot trae:t
                                                            qoder:_qoder.snapshot
                                                        workbuddy:_workbuddy.snapshot];
    [self applyCreditsRecordsToCenter:_creditsCenter];
    for (NSWindow *w in _creditsWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskCreditsView class]]) {
            [(DeskCreditsView *)v updateCenter:_creditsCenter];
        }
    }
    [self syncMenu];
}

- (void)applyWorkbuddySnapshot:(DeskWorkbuddySnapshot *)w {
    _creditsCenter = [DeskCreditsCenterSnapshot centerWithMiniMax:_credits.snapshot
                                                            trae:_trae.snapshot
                                                           qoder:_qoder.snapshot
                                                       workbuddy:w];
    [self applyCreditsRecordsToCenter:_creditsCenter];
    for (NSWindow *win in _creditsWindows) {
        NSView *v = win.contentView;
        if ([v isKindOfClass:[DeskCreditsView class]]) {
            [(DeskCreditsView *)v updateCenter:_creditsCenter];
        }
    }
    [self syncMenu];
}

- (void)applyQoderSnapshot:(DeskQoderSnapshot *)q {
    // 运行中从“未领”变成“已领”的那一拍：领取日就是今天。
    if (q.claimed && !_qoderClaimSeen && _creditsRecords) {
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        [_creditsRecords markCheckInPlatform:DeskCreditsPlatformQoder
                                      amount:q.claimedAmount
                                      dayKey:DeskCreditsDayKey(now)];
    }
    _qoderClaimSeen = q.claimed;
    _creditsCenter = [DeskCreditsCenterSnapshot centerWithMiniMax:_credits.snapshot
                                                            trae:_trae.snapshot
                                                           qoder:q
                                                       workbuddy:_workbuddy.snapshot];
    [self applyCreditsRecordsToCenter:_creditsCenter];
    for (NSWindow *w in _creditsWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskCreditsView class]]) {
            [(DeskCreditsView *)v updateCenter:_creditsCenter];
        }
    }
    [self syncMenu];
}

- (void)startCreditsTicking {
    if (_creditsTimer) return;
    _lastCreditsHourlyHour = -1;
    // 启动时先补一次；如果启动时已经过了本小时的 :05，就把这一小时记为已检查，
    // 避免第一次 60s 定时器又重复跑一遍。10:04 启动则保持 -1，10:05 那拍会补上。
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (DeskCreditsHourlyCheckDue(now, -1)) {
        _lastCreditsHourlyHour = DeskCreditsHourOfDay(now);
    }
    _creditsTimer = [NSTimer scheduledTimerWithTimeInterval:60.0 target:self
                                                   selector:@selector(creditsTick:)
                                                   userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_creditsTimer forMode:NSRunLoopCommonModes];
    [_credits start];
    [_trae start];
    [_qoder start];
    [_workbuddy start];
    NSTimeInterval intoDay = now - DeskCreditsDayStart(now);
    NSInteger hour = DeskCreditsHourOfDay(now);
    NSInteger minute = (NSInteger)(((long long)intoDay % 3600) / 60);
    NSInteger nextHour = minute < 5 ? hour : (hour + 1) % 24;
    DeskLog(@"签到调度：每天 10:05 自动签到，之后每小时 :05 检查一次，未签补签；下次检查 %02ld:05",
            (long)nextHour);
}

- (void)creditsHourlyCheckNow {
    [_credits tick];
    [_trae tick];
    [_qoder tick];
    [_workbuddy tick];
}

- (void)creditsTick:(NSTimer *)t {
    (void)t;
    // 每小时补签是低频活，但顶回同层得按拍来做：不按时顶，桌面窗排到前面之后
    // 这块组件就一直点不动（补签那条早退 return 会把顶回一起带走，所以放在最前面）。
    [self raiseCreditsAboveSameLayer];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (!DeskCreditsHourlyCheckDue(now, _lastCreditsHourlyHour)) return;
    _lastCreditsHourlyHour = DeskCreditsHourOfDay(now);
    DeskLog(@"签到 每小时补签检查（%02ld:05 档）", (long)_lastCreditsHourlyHour);
    [self creditsHourlyCheckNow];
}

- (void)creditsCheckNowAll:(id)sender {
    (void)sender;
    DeskLog(@"签到 手动：立即检查（补签）");
    [self creditsHourlyCheckNow];
}

- (void)checkInAllNow:(id)sender {
    (void)sender;
    DeskLog(@"签到 手动：全部平台立即签到");
    [self creditsCheckNowPlatform:DeskCreditsPlatformMiniMax];
    [self creditsCheckNowPlatform:DeskCreditsPlatformTrae];
    [self creditsCheckNowPlatform:DeskCreditsPlatformWorkBuddy];
    [self creditsCheckNowPlatform:DeskCreditsPlatformQoder];
}

- (void)creditsCheckNowPlatform:(DeskCreditsPlatform)p {
    switch (p) {
        case DeskCreditsPlatformMiniMax: [self checkInNow:nil]; break;
        case DeskCreditsPlatformTrae: [self traeCheckInNow:nil]; break;
        case DeskCreditsPlatformWorkBuddy: [self workbuddyCheckInNow:nil]; break;
        case DeskCreditsPlatformQoder: [self qoderCheckInNow:nil]; break;
    }
}

- (void)systemDidWake:(NSNotification *)note {
    (void)note;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (DeskCreditsHourlyCheckDue(now, -1)) {
        _lastCreditsHourlyHour = DeskCreditsHourOfDay(now);
    }
    DeskLog(@"系统唤醒：签到立即刷新并检查领取");
    [_credits refreshAsync];
    [_credits tick];
    [_trae refreshAsync];
    [_trae tick];
    [_qoder refreshAsync];
    [_qoder tick];
    [_workbuddy tick];
}

- (void)checkInNow:(id)sender {
    (void)sender;
    DeskCreditsSnapshot *s = _credits.snapshot;
    if (!s.authorized || s.needsAuth) {
        DeskLog(@"签到 尚未授权或登录已过期，先打开授权页");
        [self reauthorizeCredits:nil];
        return;
    }
    if (s.todayChecked) {
        DeskLog(@"签到 今日已签，无需重复领取");
        return;
    }
    if (s.claiming) {
        DeskLog(@"签到 正在领取中");
        return;
    }
    [_credits claimAsync];
    DeskLog(@"签到 已请求立即签到");
}

- (void)refreshCreditsNow:(id)sender {
    (void)sender;
    DeskLog(@"签到 手动刷新");
    [_credits refreshAsync];
}

- (void)openTraeApp:(id)sender {
    (void)sender;
    NSURL *u = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"cn.trae.app"];
    if (!u) u = [NSURL fileURLWithPath:@"/Applications/Trae CN.app"];
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:u
                                          configuration:[NSWorkspaceOpenConfiguration configuration]
                                     completionHandler:nil];
    DeskLog(@"签到 Trae 已打开客户端（续期由 IDE 自己完成，脚本不碰 refreshToken）");
}

- (void)traeCheckInNow:(id)sender {
    (void)sender;
    DeskTraeSnapshot *t = _trae.snapshot;
    if (!t.connected || t.phase == DeskTraePhaseNeedsAuth) {
        DeskLog(@"签到 Trae 没有可用登录态，先打开客户端登录");
        [self openTraeApp:nil];
        return;
    }
    if (t.checkedIn) {
        DeskLog(@"签到 Trae 今日已签，无需重复领取");
        return;
    }
    if (t.claiming) {
        DeskLog(@"签到 Trae 正在领取中");
        return;
    }
    [_trae claimAsync];
    DeskLog(@"签到 Trae 已请求立即签到");
}

- (void)traeRefreshNow:(id)sender {
    (void)sender;
    DeskLog(@"签到 Trae 手动刷新");
    [_trae refreshAsync];
}

- (void)traeReloadCredentials:(id)sender {
    (void)sender;
    DeskLog(@"签到 Trae 重新读取本机 storage.json");
    [_trae load];
    [_trae refreshAsync];
}

- (void)qoderCheckInNow:(id)sender {
    (void)sender;
    DeskQoderSnapshot *q = _qoder.snapshot;
    if (!q.hasToken || q.tokenInvalid || q.phase == DeskQoderPhaseNeedsAuth) {
        DeskLog(@"签到 Qoder 没有可用 PT，先设置令牌");
        [self qoderSetToken:nil];
        return;
    }
    if (q.claimed) {
        DeskLog(@"签到 Qoder 本窗口已领，等%@",
                DeskQoderRefreshText(q.windowEnd, [NSDate date].timeIntervalSince1970));
        return;
    }
    if (q.claiming) {
        DeskLog(@"签到 Qoder 正在领取中");
        return;
    }
    [_qoder claimAsync];
    DeskLog(@"签到 Qoder 已请求立即领取");
}

- (void)qoderRefreshNow:(id)sender {
    (void)sender;
    DeskLog(@"签到 Qoder 手动刷新");
    [_qoder refreshAsync];
}

- (void)qoderSetToken:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"设置 Qoder PT 令牌";
    alert.informativeText = @"在 Qoder 官网 / 客户端生成个人令牌（pt-…）。"
        @"令牌只保存在本机 DeskBoard/Credits/qoder.json（0600），不会写入 Qoder 客户端目录。";
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 420, 24)];
    field.placeholderString = @"pt-…";
    alert.accessoryView = field;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSError *err = nil;
    if ([_qoder setPersonalToken:field.stringValue error:&err]) {
        DeskLog(@"签到 Qoder PT 已更新，开始刷新");
        [self syncMenu];
    } else {
        DeskLog(@"签到 Qoder PT 设置失败：%@", err.localizedDescription ?: @"未知原因");
    }
}

- (void)openQoderUsage:(id)sender {
    (void)sender;
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://qoder.cn/account/usage"]];
}

- (void)workbuddyLogin:(id)sender {
    (void)sender;
    __weak typeof(self) weakSelf = self;
    [_workbuddy beginAuthorizationWithURLHandler:^(NSString *url) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *u = [NSURL URLWithString:url];
            if (u) [[NSWorkspace sharedWorkspace] openURL:u];
            DeskLog(@"签到 WorkBuddy 已打开浏览器登录页（登录一次即可，之后自动签到）");
            [weakSelf syncMenu];
        });
    } completion:^(BOOL ok, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) DeskLog(@"签到 WorkBuddy 浏览器登录完成");
            else DeskLog(@"签到 WorkBuddy 登录失败：%@", err.localizedDescription ?: @"未知原因");
            [weakSelf syncMenu];
        });
    }];
}

- (void)workbuddyCheckInNow:(id)sender {
    (void)sender;
    DeskWorkbuddySnapshot *w = _workbuddy.snapshot;
    if (!w.hasToken || w.tokenExpired) {
        DeskLog(@"签到 WorkBuddy 未登录，先打开浏览器登录");
        [self workbuddyLogin:nil];
        return;
    }
    if (w.checkedIn) {
        DeskLog(@"签到 WorkBuddy 今日已签，无需重复领取");
        return;
    }
    if (w.claiming) {
        DeskLog(@"签到 WorkBuddy 正在领取中");
        return;
    }
    [_workbuddy claimAsync];
    DeskLog(@"签到 WorkBuddy 已请求立即签到");
}

- (void)workbuddyRefreshNow:(id)sender {
    (void)sender;
    DeskLog(@"签到 WorkBuddy 手动刷新");
    [_workbuddy refreshAsync];
}

- (void)workbuddyImportLocal:(id)sender {
    (void)sender;
    NSError *err = nil;
    if ([_workbuddy importLocalSession:&err]) {
        DeskLog(@"签到 WorkBuddy 已从本机 auth.info 导入明文登录态");
    } else {
        DeskLog(@"签到 WorkBuddy 本机导入失败：%@", err.localizedDescription ?: @"未知原因");
    }
}

- (void)openWorkbuddyApp:(id)sender {
    (void)sender;
    NSURL *u = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.workbuddy.workbuddy"];
    if (!u) u = [NSURL fileURLWithPath:@"/Applications/WorkBuddy.app"];
    [[NSWorkspace sharedWorkspace] openURL:u];
}

- (void)reauthorizeCredits:(id)sender {
    (void)sender;
    __weak typeof(self) weakSelf = self;
    [_credits beginAuthorizationWithURLHandler:^(NSString *url) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *u = [NSURL URLWithString:url];
            if (u) [[NSWorkspace sharedWorkspace] openURL:u];
            DeskLog(@"签到 已打开浏览器授权页（独立登录，不回写 MiniMax Code 客户端凭据）");
            [weakSelf syncMenu];
        });
    } completion:^(BOOL ok, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) DeskLog(@"签到 浏览器授权完成");
            else DeskLog(@"签到 授权失败：%@", err.localizedDescription ?: @"未知原因");
            [weakSelf syncMenu];
        });
    }];
}

- (void)openMiniMaxWeb:(id)sender {
    (void)sender;
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://agent.minimax.cn/"]];
}

- (NSString *)creditsPlatformName:(DeskCreditsPlatform)p {
    switch (p) {
        case DeskCreditsPlatformMiniMax: return @"MiniMax";
        case DeskCreditsPlatformTrae: return @"Trae";
        case DeskCreditsPlatformWorkBuddy: return @"WorkBuddy";
        case DeskCreditsPlatformQoder: return @"Qoder";
    }
    return @"?";
}

// 组件里的授权入口：MiniMax 未授权 / 登录过期时，单击格子直接发起浏览器授权。
// 其余平台还没接入，只记日志；它们将来的本机导入授权也走同一个入口。
- (void)creditsActivatePlatform:(DeskCreditsPlatform)p {
    if (p == DeskCreditsPlatformWorkBuddy) {
        DeskWorkbuddySnapshot *w = _workbuddy.snapshot;
        if (!w.hasToken || w.tokenExpired) {
            DeskLog(@"签到 WorkBuddy 未登录 / 登录过期：打开浏览器登录");
            [self workbuddyLogin:nil];
            return;
        }
        if (w.authorizing) {
            DeskLog(@"签到 WorkBuddy 正在等待浏览器登录");
            return;
        }
        if (w.claiming) {
            DeskLog(@"签到 WorkBuddy 正在领取中");
            return;
        }
        DeskLog(@"签到 WorkBuddy 组件点击：刷新状态");
        [_workbuddy refreshAsync];
        return;
    }
    if (p == DeskCreditsPlatformQoder) {
        DeskQoderSnapshot *q = _qoder.snapshot;
        if (!q.hasToken || q.tokenInvalid || q.phase == DeskQoderPhaseNeedsAuth) {
            DeskLog(@"签到 Qoder 没有可用 PT：打开令牌设置");
            [self qoderSetToken:nil];
            return;
        }
        if (q.claiming) {
            DeskLog(@"签到 Qoder 正在领取中");
            return;
        }
        DeskLog(@"签到 Qoder 组件点击：刷新额度与活动");
        [_qoder refreshAsync];
        return;
    }
    if (p == DeskCreditsPlatformTrae) {
        DeskTraeSnapshot *t = _trae.snapshot;
        if (!t.connected || t.phase == DeskTraePhaseNeedsAuth) {
            DeskLog(@"签到 Trae 未登录 / 登录过期：打开客户端");
            [self openTraeApp:nil];
            return;
        }
        if (t.claiming) {
            DeskLog(@"签到 Trae 正在领取中");
            return;
        }
        DeskLog(@"签到 Trae 组件点击：刷新状态");
        [_trae refreshAsync];
        return;
    }
    if (p != DeskCreditsPlatformMiniMax) {
        DeskLog(@"签到 %@ 尚未接入（菜单 › 签到中心 › %@ 里已预留接入动作）",
                [self creditsPlatformName:p], [self creditsPlatformName:p]);
        return;
    }
    DeskCreditsSnapshot *s = _credits.snapshot;
    if (!s.authorized || s.needsAuth) {
        DeskLog(@"签到 从组件点击发起 MiniMax 授权");
        [self reauthorizeCredits:nil];
        return;
    }
    if (s.authorizing) {
        DeskLog(@"签到 正在等待浏览器授权");
        return;
    }
    DeskLog(@"签到 组件点击 MiniMax：刷新状态");
    [_credits refreshAsync];
}

- (void)creditsDoubleClickPlatform:(DeskCreditsPlatform)p {
    if (p == DeskCreditsPlatformWorkBuddy) {
        [self workbuddyCheckInNow:nil];
        return;
    }
    if (p == DeskCreditsPlatformQoder) {
        [self qoderCheckInNow:nil];
        return;
    }
    if (p == DeskCreditsPlatformTrae) {
        [self traeCheckInNow:nil];
        return;
    }
    if (p != DeskCreditsPlatformMiniMax) {
        DeskLog(@"签到 %@ 尚未接入（双击不动作）", [self creditsPlatformName:p]);
        return;
    }
    [self checkInNow:nil];
}

- (void)creditsPlaceholderAction:(id)sender {
    DeskLog(@"签到 占位动作（尚未接入）：%@", [sender title]);
}

- (NSString *)creditsSummaryTextForCenter:(DeskCreditsCenterSnapshot *)c {
    NSMutableString *s = [NSMutableString stringWithFormat:@"%ld 已办 · %ld 待办",
                          (long)c.doneCount, (long)c.pendingCount];
    if (c.errorCount > 0) {
        [s appendFormat:@" · %ld 异常", (long)c.errorCount];
    } else {
        NSInteger unconnected = (NSInteger)c.slots.count - c.connectedCount;
        if (unconnected > 0) [s appendFormat:@" · %ld 待接入", (long)unconnected];
    }
    return s;
}

- (NSString *)creditsMiniMaxHeadline {
    DeskCreditsSnapshot *s = _credits.snapshot;
    if (!s.authorized) return @"未授权";
    if (s.needsAuth) return @"登录过期";
    if (s.authorizing) return @"等待授权";
    if (s.claiming) return @"签到中";
    if (s.claimFailed) return @"领取失败";
    if (s.todayChecked) {
        return s.todayPoints >= 0
            ? [NSString stringWithFormat:@"已签 +%@", DeskCreditsFormatPoints(s.todayPoints)]
            : @"已签";
    }
    if (s.hasToday) {
        return s.todayPoints >= 0
            ? [NSString stringWithFormat:@"待签 +%@", DeskCreditsFormatPoints(s.todayPoints)]
            : @"待签";
    }
    if (s.refreshing) return @"同步中";
    return @"—";
}

- (NSString *)creditsMenuTitleForSlot:(DeskCreditsSlot *)s {
    if (s.kind == DeskCreditsSlotKindUnconnected) {
        return [NSString stringWithFormat:@"%@ · 待接入", s.name];
    }
    return [NSString stringWithFormat:@"%@ · %@", s.name, s.statusText];
}

- (void)startMonitorSampling {
    if (_monitorSampleTimer) return;
    // 10 秒一拍采进程榜。5 秒档实测还有一次 6% 左右的整卡重画尖峰；
    // 进程榜是桌面上的慢读，10 秒完全够用，CPU 窗口也跟着改 10s。
    _monitorSampleTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self
                                                         selector:@selector(refreshMonitor:)
                                                         userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_monitorSampleTimer forMode:NSRunLoopCommonModes];
    [self refreshMonitor:nil];
    const char *st = getenv("DESKBOARD_SELFTEST");
    if (st) {
        // 我这边没有真鼠标、也没有辅助功能权限：带这个环境变量启动，自检自己跑一遍。
        // =2 按点扫描（哪些位置起不了拖），=3 微调走位（菜单摆位这条替代路径守不守得住），
        // 其余值跑方向七发。我这边没有真鼠标、也没有辅助功能权限，所以让自检自己跑。
        NSInteger mode = atoi(st);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (mode == 2) [self selfTestMonitorPressPoints:nil];
            else if (mode == 3) [self selfTestMonitorNudgeWalk:nil];
            else if (mode == 4) [self selfTestMonitorGrid:nil];
            else if (mode == 5) {
                // 摆到指定格并**停在那里**（自检用；不收尾，方便在外面用真 HID 事件去拖它）
                const char *cell = getenv("DESKBOARD_CELL");
                NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
                it.tag = cell ? atoi(cell) : 4;
                [self placeMonitorAtCell:it];
                DeskLog(@"自检 摆到格 %ld（停在此处，等外部真事件）", (long)it.tag);
            }
            else if (mode == 6) {
                // 临时把组件抬到普通窗口之上 N 秒，让外部可以投真 HID 事件做端到端拖动验证；
                // 到点自动还原到桌面图标层。用户选的是"被压住靠菜单"，这是验证手段、不是产品行为。
                NSWindow *mw = _monitorWindows.firstObject;
                const char *secs = getenv("DESKBOARD_RAISE_SECS");
                double hold = secs ? atof(secs) : 20.0;
                if (hold < 5) hold = 5;
                DeskLog(@"自检 临时提层：%ld → %ld，%.0f 秒后还原",
                        (long)mw.level, (long)NSStatusWindowLevel, hold);
                for (NSWindow *x in _monitorWindows) x.level = NSStatusWindowLevel;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    for (NSWindow *x in self->_monitorWindows) x.level = kCGDesktopIconWindowLevel;
                    for (NSWindow *x in self->_monitorWindows) [x orderFrontRegardless];
                    DeskLog(@"自检 层级已还原：%ld", (long)self->_monitorWindows.firstObject.level);
                });
            }
            else [self selfTestMonitorDrag:nil];
        });
    }
}

// 10 秒一拍采进程。采和画是分开的：动画表空闲就停，但榜不能停，
// 不然桌面上一动不动，谁也不知道机器现在在干什么
// 隐藏时也要继续采：不然"隐藏 6 小时"会在历史里留 6 小时的空洞，而 12h 平均的分母
// 是窗口本身，那段空洞会被当成 0 计进去，恢复显示后数字长期偏低且看不出来。
- (void)refreshMonitor:(NSTimer *)t {
    BOOL live = !_monitorHidden && _monitorWindows.count > 0;
    NSArray<DeskProc *> *rows = [_procs sample];
    _monitorCount = (NSInteger)rows.count;
    double energySum = 0;
    for (DeskProc *p in rows) if (p.energy > 0) energySum += p.energy;
    if (!_monitorHidden) [self recordHistory:rows energy:energySum];

    // 隐藏时只采数据（历史不断），不更新界面：不可见的卡片重画和缓动都是白烧电
    if (!live) return;

    // 榜头总量平时由 refreshStats 每 10 秒推过来（两块同一拍）；这里再设一次是给
    // 建窗后的首拍兜底，不额外跑 IOKit。
    DeskStats *st = _lastStats;
    for (NSWindow *w in _monitorWindows) {
        DeskMonitorView *v = (DeskMonitorView *)w.contentView;
        if (![v isKindOfClass:[DeskMonitorView class]]) continue;
        // 被应用窗口完全盖住时继续更新数据（切回桌面不能是几分钟前的旧数），
        // 但不重画、不启动 60fps 缓动 —— 看不见的帧画了也没人看。
        v.drawSuppressed = WidgetWindowCovered(w);
        if (st) {
            v.totalCPU = st.cpu;
            v.totalMemUsed = st.memUsed;
            v.totalMemPhys = st.memTotal;
            v.totalNetRecv = st.netRecv;
            v.totalNetSend = st.netSend;
        }
        v.totalEnergy = energySum;
        [v updateRows:rows];
    }
}

// 喂一拍历史。dt 用真实时间差而不是写死的 10 —— 定时器会漂，系统睡眠醒来还会跳拍
- (void)recordHistory:(NSArray<DeskProc *> *)rows energy:(double)energySum {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    double dt = _histLastAt > 0 ? now - _histLastAt : 10.0;
    _histLastAt = now;
    DeskStats *st = _lastStats;
    double totals[4] = {
        (st && st.cpu >= 0) ? st.cpu : 0,
        st ? (double)st.memUsed : 0,
        energySum,
        (st && st.netRecv >= 0 && st.netSend >= 0) ? (st.netRecv + st.netSend) : 0
    };
    [_hist noteSampleAt:now seconds:dt rows:rows totals:totals];
    [_hist flushIfNeeded];      // 内部限流：每分钟最多写一次盘
    if (_hist.recordedSeconds < 3600 && fmod(now, 300) < 6.0) {
        DeskLog(@"活动监视器 12h 历史已记录 %.2f 小时（跟踪 %lu 个进程）",
                _hist.recordedSeconds / 3600.0, (unsigned long)_hist.trackedPids);
    }
}

// 动画表只在真有事做的时候挂着。
// 之前它是常开的 60fps，并且"空闲时每 3 帧也重画一次"——理由是那条慢扫描带常年要动。
// 实测后果：DeskBoard 稳定吃 39% CPU，活动监视器「对能耗的影响」88.5（同机 MiniMax Code 才 8.5），
// sample 三秒里主线程约四成时间都在 DeskVaultView drawRect → 逐张卡片 CoreText 排版。
// 现在改成：没人动组件 → 一帧都不重画，表也停掉；视图哪天要动了，自己把表叫回来。
- (void)startWidgetTicking {
    _lastWidgetTick = [NSDate date];
    _lastVaultStat = [NSDate date];
    [self resumeWidgetTicking];
    // 盖住检测单独一个慢表，不塞进动画表里：没人动组件的时候不该按帧频去问 WindowServer
    _vaultCoverTimer = [NSTimer scheduledTimerWithTimeInterval:kVaultCoverInterval target:self
                                                       selector:@selector(checkVaultCover:)
                                                       userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_vaultCoverTimer forMode:NSRunLoopCommonModes];
    // 卡片 / 监视器 / 签到都要定时顶回本层最前：访达桌面窗会整块压住它们，点击到不了视图。
    // 3s 和弹药库置顶同频；orderFrontRegardless 在窗口已在前时几乎不花钱。
    _cardRaiseTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self
                                                     selector:@selector(raiseSameLayerTimer:)
                                                     userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_cardRaiseTimer forMode:NSRunLoopCommonModes];
}

- (void)resumeWidgetTicking {
    if (_widgetTick) return;
    _lastWidgetTick = [NSDate date];
    // 60fps 而不是 30fps：缓动曲线在 33ms 一步的表上只有两三个可见台阶，
    // 看着就是"啪"地跳过去。16ms 一步才够画出连续的淡入淡出。
    _widgetTick = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0 target:self
                                                selector:@selector(widgetTick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_widgetTick forMode:NSRunLoopCommonModes];
}

// 停表不等于睡死：留一个 1Hz 的看门狗兜底，万一某个动画没走 setNeedsDisplay 这条路，
// 最多 1 秒也能把表叫回来。原来是 10Hz，空闲时每天白醒 86 万次，实测占本组件能耗的可观一份。
- (void)parkWidgetTicking {
    if (!_widgetTick) return;
    [_widgetTick invalidate];
    _widgetTick = nil;
    if (_widgetWatchdog) return;
    _widgetWatchdog = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                    selector:@selector(widgetWatchdog:)
                                                    userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_widgetWatchdog forMode:NSRunLoopCommonModes];
}

- (void)widgetWatchdog:(NSTimer *)t {
    for (NSWindow *w in _windows) {
        DeskCardView *v = (DeskCardView *)w.contentView;
        if ([v isKindOfClass:[DeskCardView class]] && [v needsRedraw]) { [self resumeWidgetTicking]; break; }
    }
    for (NSWindow *w in _vaultWindows) {
        DeskVaultView *v = (DeskVaultView *)w.contentView;
        if ([v isKindOfClass:[DeskVaultView class]] && [v needsRedraw]) { [self resumeWidgetTicking]; break; }
    }
    for (NSWindow *w in _monitorWindows) {
        DeskMonitorView *v = (DeskMonitorView *)w.contentView;
        if ([v isKindOfClass:[DeskMonitorView class]] && [v needsRedraw]) { [self resumeWidgetTicking]; break; }
    }
    // 目录统计很贵（一个文件夹几万文件），入库退库时已经刷过，
    // 这里只做兜底对账：五分钟扫一次，捡到用户在 Finder 里直接动过库的情况
    if ([[NSDate date] timeIntervalSinceDate:_lastVaultStat] > 300.0) {
        _lastVaultStat = [NSDate date];
        [[DeskVault shared] refreshStats];
    }
}

- (void)widgetTick:(NSTimer *)t {
    NSDate *now = [NSDate date];
    double dt = [now timeIntervalSinceDate:_lastWidgetTick];
    _lastWidgetTick = now;
    if (dt <= 0 || dt > 1.0) dt = 1.0 / 60.0;   // 机器睡过就按一帧算，别让动画瞬移

    BOOL busy = NO;
    // 卡片自己只有采样到点后的 0.9 秒要逐帧，平时由面板的 1Hz 采样钟自己标脏
    for (NSWindow *w in _windows) {
        DeskCardView *v = (DeskCardView *)w.contentView;
        if (![v isKindOfClass:[DeskCardView class]]) continue;
        [v tick:dt];
        if ([v needsRedraw]) busy = YES;
    }
    for (NSWindow *w in _vaultWindows) {
        DeskVaultView *v = (DeskVaultView *)w.contentView;
        if (![v isKindOfClass:[DeskVaultView class]]) continue;
        [v tick:dt];
        if ([v needsRedraw]) busy = YES;
    }
    for (NSWindow *w in _monitorWindows) {
        DeskMonitorView *v = (DeskMonitorView *)w.contentView;
        if (![v isKindOfClass:[DeskMonitorView class]]) continue;
        [v tick:dt];
        if ([v needsRedraw]) busy = YES;
    }
    // 只叫"这一帧真有东西要动"的那一块组件重画。
    // 原来这里是无条件给所有窗口 setNeedsDisplay，两块组件共用一张表之后就变成：
    // 活动监视器每 2 秒缓动那 0.3 秒，会把弹药库一起拖成 60fps 空转
    // （实测整个 App 从 2.0% 涨到 4.4%，把这段改成按需之后就回到 2.2% 上下）。
    // 收尾那一帧仍然会画：视图的 tick: 在自己还没收敛时就会标脏。
    for (NSWindow *w in _vaultWindows) {
        DeskVaultView *v = (DeskVaultView *)w.contentView;
        if ([v isKindOfClass:[DeskVaultView class]] && ([v needsRedraw] || [v isDragging])) {
            [v setNeedsDisplay:YES];
        }
    }
    for (NSWindow *w in _monitorWindows) {
        DeskMonitorView *v = (DeskMonitorView *)w.contentView;
        if ([v isKindOfClass:[DeskMonitorView class]] && [v needsRedraw]) [v setNeedsDisplay:YES];
    }
    if (!busy) [self parkWidgetTicking];
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
    NSString *status = _layoutLocked ? @"已锁定"
        : (dirty ? @"未保存" : (_savedStamp.length ? [@"已保存 " stringByAppendingString:_savedStamp] : @"已对齐存档"));
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

// 只重置当前屏位档；其他分辨率的历史档位不动
- (void)resetPlaceStore:(DeskPlaceStore *)store kind:(DeskPlaceKind)kind {
    if ([self refuseMoveWhenLocked:@"恢复默认位置"]) return;
    DeskPlace p = DeskPlaceDefaultForKind(kind);
    for (NSScreen *screen in [NSScreen screens]) {
        [store setPlace:p forKey:[store keyForScreen:screen]];
    }
    [store discardPending];
    [self saveConfig];
}

- (void)resetCardPlace:(id)sender {
    [self resetPlaceStore:_places kind:DeskPlaceKindPanel];
    [self reassertFrames];
    DeskLog(@"卡片恢复默认摆位（右上 16/16）");
}

- (void)resetVaultPlace:(id)sender {
    [self resetPlaceStore:_vaultPlaces kind:DeskPlaceKindVault];
    [self applyVaultFrames];
    DeskLog(@"弹药库恢复默认摆位（左下 16/16）");
}

- (void)resetMonitorPlace:(id)sender {
    [self resetPlaceStore:_monitorPlaces kind:DeskPlaceKindMonitor];
    [self applyMonitorFrames];
    DeskLog(@"活动监视器恢复默认摆位（右下 16/16）");
}

#pragma mark - 全局锁定与位置记忆

// 锁定的唯一出口：四块视图都不再启动窗口拖动，菜单里的搬位动作也在这里被拦住。
- (BOOL)refuseMoveWhenLocked:(NSString *)what {
    if (!_layoutLocked) return NO;
    DeskLog(@"%@：位置已锁定，先从菜单栏「锁定位置」解锁", what ?: @"移动");
    return YES;
}

- (void)applyLayoutLockToViews {
    for (NSWindow *w in _windows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskCardView class]]) ((DeskCardView *)v).locked = _layoutLocked;
    }
    for (NSWindow *w in _vaultWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskVaultView class]]) ((DeskVaultView *)v).locked = _layoutLocked;
    }
    for (NSWindow *w in _monitorWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskMonitorView class]]) ((DeskMonitorView *)v).locked = _layoutLocked;
    }
    for (NSWindow *w in _creditsWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskCreditsView class]]) ((DeskCreditsView *)v).locked = _layoutLocked;
    }
}

// 「调整位置并锁定后，该位置即作为默认位置」：
// 卡片拖动只挂"待保存"，锁定这一刻替它点一次保存；其余三块拖完即落档，这里再按
// 当前窗口校准一遍，保证"看得见的窗口"和"重启后去的地方"是同一个。
- (void)captureAllPlaces {
    // 隐藏中的窗口没有可调整的现场：不按它们回写，免得离屏窗的 w.screen 退化成主屏、
    // 把主屏档位覆盖成别块屏的坐标。卡片的"待保存"仍照常提交。
    for (NSWindow *w in _windows) if (w.isVisible) [self recordPendingPlaceInWindow:w];
    BOOL hadPending = [_places commitPending];
    for (NSWindow *w in _vaultWindows) if (w.isVisible) [self saveVaultPlaceInWindow:w];
    for (NSWindow *w in _monitorWindows) if (w.isVisible) [self saveMonitorPlaceInWindow:w];
    for (NSWindow *w in _creditsWindows) if (w.isVisible) [self saveCreditsPlaceInWindow:w];
    [self saveConfig];
    DeskLog(@"锁定位置：四块当前摆位已落档%@", hadPending ? @"（含卡片的待保存）" : @"");
}

- (void)toggleLayoutLock:(id)sender {
    (void)sender;
    _layoutLocked = !_layoutLocked;
    if (_layoutLocked) [self captureAllPlaces];
    [self applyLayoutLockToViews];
    [self saveConfig];
    [self syncMenu];
    [self updateHud];
    DeskLog(@"全局布局锁定：%@（四块组件%@拖动）",
            _layoutLocked ? @"开" : @"关", _layoutLocked ? @"不可" : @"可以");
}

- (void)applyModel {
    NSUInteger i = 0;
    _applying = YES;
    for (NSScreen *screen in [NSScreen screens]) {
        if (i >= _windows.count) break;
        NSWindow *w = _windows[i++];
        DeskCardView *card = (DeskCardView *)w.contentView;
        // 被应用窗口完全盖住时只校正窗口位置，不重排/重画卡片。
        // 卡片每 10 秒的一次全量 CoreText + 壁纸重绘在不可见时是纯白烧，
        // 实测正是盖着时那 3~4% 的尖峰。切回桌面由 occlusion 通知补一次 updateModel。
        BOOL covered = WidgetWindowCovered(w);
        if (!covered) {
            [card updateModel:_model];   // 内部会重预渲染 Stand 素材
        }
        NSRect frame = [self frameForSize:[DeskPanelView sizeForModel:_model] screen:screen];
        if (!NSEqualRects(w.frame, frame)) [w setFrame:frame display:!covered animate:NO];
        if (!covered) [card setNeedsDisplay:YES];      // 背景采样图要跟位置与壁纸变化走
    }
    _applying = NO;
    [self updateHud];
}

// 卡片重新露出来时补一次内容更新（被盖住期间跳过了 updateModel）
- (void)mainOcclusionChanged:(NSNotification *)note {
    NSWindow *w = note.object;
    if (![w isKindOfClass:[NSWindow class]]) return;
    if (!(w.occlusionState & NSWindowOcclusionStateVisible)) return;
    if ([_windows indexOfObjectIdenticalTo:w] == NSNotFound) return;
    NSView *v = w.contentView;
    if ([v isKindOfClass:[DeskCardView class]]) [(DeskCardView *)v updateModel:_model];
}

- (void)reload {
    if ([NSScreen screens].count != _windows.count) { [self rebuildWindows]; return; }
    _model = [self loadModel];
    [self applyModel];
}

// 卡片和活动监视器必须显示同一拍快照：10 秒一次的系统采样出来后，把总量读数一并推给
// 活动监视器并重绘，不再等它自己那一拍。否则并排看时，一个是刚采的、一个最多差 10 秒。
- (void)pushStatsToMonitor:(DeskStats *)st {
    if (!st || _monitorHidden) return;
    for (NSWindow *w in _monitorWindows) {
        DeskMonitorView *v = (DeskMonitorView *)w.contentView;
        if (![v isKindOfClass:[DeskMonitorView class]]) continue;
        v.totalCPU = st.cpu;
        v.totalMemUsed = st.memUsed;
        v.totalMemPhys = st.memTotal;
        v.totalNetRecv = st.netRecv;
        v.totalNetSend = st.netSend;
        // 不在这里单独重画：活动监视器自己的 10 秒那一拍会用同一份 _lastStats 更新
        // 并 updateRows；两处各画一次等于每 10 秒白画一张整卡。
    }
}

// 窗口重新露出来时先把上一拍的内容画出来，别让用户对着旧画面等下一次 10 秒采样。
// 只重画，不再采一轮 —— 采样会有几十毫秒的卡顿，下一拍马上就到了。
- (void)monitorOcclusionChanged:(NSNotification *)note {
    NSWindow *w = note.object;
    if (![w isKindOfClass:[NSWindow class]]) return;
    NSView *v = w.contentView;
    if (![v isKindOfClass:[DeskMonitorView class]]) return;
    if (w.occlusionState & NSWindowOcclusionStateVisible) {
        ((DeskMonitorView *)v).drawSuppressed = NO;
        [v setNeedsDisplay:YES];
    }
}

// 系统指标每拍都要重画，油价数据只在文件变化时重建
- (void)refreshStats {
    _lastStatsAt = [NSDate date].timeIntervalSince1970;
    DeskStats *s = [_sys sample];
    _lastStats = s;
    [_model updateStats:s];
    [self applyModel];
    [self pushStatsToMonitor:s];
    if (++_tick % 6 == 0) {   // 10 秒一拍 × 6 ≈ 每分钟留一条轨迹，证明在持续取数而不是停在某一帧
        DeskLog(@"刷新 CPU=%.0f%%（%.0fs 窗口） GPU=%.0f%% 内存=%.1f/%.0fGiB 磁盘读=%.1f 写=%.1f MB/s",
                s.cpu, s.cpuWindow, s.gpu, s.memUsed / 1073741824.0, s.memTotal / 1073741824.0,
                s.diskRead / 1e6, s.diskWrite / 1e6);
    }
}

- (void)startPolling {
    // 监听目录收不到"原地覆盖同一个文件"的写入，监听文件又会在原子替换后失效，
    // 所以轮询 mtime+size：任何写入方式（cp、编辑器保存、mv 替换）都能覆盖。
    // 文件检查 2 秒一次（很便宜）；系统指标采样重，10 秒一次，和活动监视器那一拍对齐。
    [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(pollFile)
                                   userInfo:nil repeats:YES];
}

- (void)pollFile {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *stamp = [self currentStamp];
    BOOL same = (stamp && _stamp) ? [stamp isEqualToString:_stamp] : (stamp == _stamp);
    if (!same) {
        _stamp = stamp;
        [self reload];
    }
    if (_lastStatsAt == 0 || now - _lastStatsAt >= 10.0) [self refreshStats];
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
    DeskPlace p = DeskPlaceFromFrame(cf, cardSize, vf);
    [_places setPending:p forKey:[_places keyForScreen:screen]];
    [self updateHud];
}

// 屏幕配置指纹：屏数 + 每屏的 displayID / 点尺寸 / 原点。用来判断"这次通知到底是不是真变了"。
- (NSString *)currentScreenSignature {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSScreen *s in [NSScreen screens]) {
        NSNumber *idNum = s.deviceDescription[@"NSScreenNumber"];
        NSRect f = s.frame;
        [parts addObject:[NSString stringWithFormat:@"%@-%.0fx%.0f+%.0f+%.0f",
                          idNum ?: @"?", f.size.width, f.size.height, f.origin.x, f.origin.y]];
    }
    [parts sortUsingSelector:@selector(compare:)];
    return [parts componentsJoinedByString:@"|"];
}

// 分辨率真的变了：把上一档的当前摆位搬到新档位，并同步同一块屏的所有旧档位。
// 不再让「同屏最近一条历史记录」决定新分辨率的位置 —— 那条记录可能来自旧布局，
// 会把用户刚摆好的锚点带回左下/右下之类的旧地方。
- (void)carryPlacesFromScreenSignature:(NSString *)oldSig {
    NSDictionary<NSString *, NSString *> *oldKeys =
        DeskPlaceKeysByDisplayFromSignature(oldSig ?: @"");
    if (oldKeys.count == 0) return;
    BOOL changed = NO;
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *idNum = screen.deviceDescription[@"NSScreenNumber"];
        NSString *displayID = idNum ? idNum.stringValue : nil;
        NSString *oldKey = displayID ? oldKeys[displayID] : nil;
        NSString *newKey = [_places keyForScreen:screen];
        if (!oldKey.length || !newKey.length || [oldKey isEqualToString:newKey]) continue;
        DeskPlace p = [_places placeForKey:oldKey];
        [_places setPlace:p forKey:newKey];
        [_places setPlace:p forKeysMatchingDisplayID:displayID];
        p = [_vaultPlaces placeForKey:oldKey];
        [_vaultPlaces setPlace:p forKey:newKey];
        [_vaultPlaces setPlace:p forKeysMatchingDisplayID:displayID];
        p = [_monitorPlaces placeForKey:oldKey];
        [_monitorPlaces setPlace:p forKey:newKey];
        [_monitorPlaces setPlace:p forKeysMatchingDisplayID:displayID];
        p = [_creditsPlaces placeForKey:oldKey];
        [_creditsPlaces setPlace:p forKey:newKey];
        [_creditsPlaces setPlace:p forKeysMatchingDisplayID:displayID];
        DeskLog(@"分辨率变化：%@ → %@，四块按当前锚点搬到新档位（旧档位同步）", oldKey, newKey);
        changed = YES;
    }
    if (changed) [self saveConfig];
}

// 屏幕参数变更期间（切分辨率、接拔显示器）系统会先平移现有窗口再发通知，
// 而且迁移可能滞后于我们建窗。所以：稍后按存档把窗口重申两遍，压住迟到的系统迁移。
//
// **但绝不能对每条通知都重建窗口。** 这台机器的显示配置每 8~20 秒就抖一次
// （日志实测 12:43:18 / :32 / :39 / :47 / :57 连续五次），而旧写法每次都把三块组件的
// 窗口销毁重建 —— 用户按住活动监视器拖到一半，那个视图就被换掉了，`mouseDragged:` 永远
// 送不到，这正是"mouseDown 到得了（10:55 双击那条）但整份历史没有一条拖拽日志"的成因。
// 重建还会让活动监视器每次空板几秒（榜要等下一拍才有数据）。
// 现在只有指纹真的变了才重建；否则只重申位置。
- (void)screenDidChange:(NSNotification *)note {
    NSString *sig = [self currentScreenSignature];
    if (_screenSig && [sig isEqualToString:_screenSig]) {
        DeskLog(@"屏幕参数变更（配置指纹没变，只重申位置，不重建窗口）");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self reassertAllFrames]; });
        return;
    }
    if (_screenSig) [self carryPlacesFromScreenSignature:_screenSig];
    _screenSig = sig;
    DeskLog(@"屏幕配置真的变了：%@ —— 重建四块组件的窗口", sig);
    [self rebuildWindows];
    [self rebuildVaultWindows];
    // 第三块组件也必须跟着重建：屏幕参数一变，存档里的档位可能整体落空（窗口留在旧屏幕上），
    // 上一版这里只重建了卡片和弹药库，活动监视器就成了"改完外观后不再刷新"的那种幽灵窗口
    [self rebuildMonitorWindows];
    [self rebuildCreditsWindows];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self reassertAllFrames]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self reassertAllFrames]; });
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

// 三块组件都要压住"系统迟到的迁移"。以前这件事是 rebuild 顺带做到的（重建 = 按存档重新
// 摆一遍）；现在不重建了，就得自己把三块的位置按存档重申一遍 —— 只搬窗口，不销毁视图。
- (void)reassertAllFrames {
    [self reassertFrames];
    [self applyVaultFrames];
    [self applyMonitorFrames];
    [self applyCreditsFrames];
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
    NSArray *names = @[@"实底卡（采样模糊）", @"羽化暗角", @"无底浮字", @"无边玻璃"];
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

    // ---- 组件 1：卡片面板（系统状态）----
    NSMenu *card = [[NSMenu alloc] initWithTitle:@"卡片面板"];
    _cardItem = DeskAddAction(card, @"显示 / 隐藏", self, @selector(toggleHidden:));
    [self addSubmenuTo:card title:@"外观"
                  menu:(_styleMenu = [self styleMenuForAction:@selector(chooseStyle:)
                                                         title:@"卡片外观"])];
    [card addItem:NSMenuItem.separatorItem];
    DeskAddAction(card, @"保存当前位置（拖完再点）", self, @selector(saveCurrentPlace:));
    DeskAddAction(card, @"恢复默认位置（右上）", self, @selector(resetCardPlace:));
    [card addItem:NSMenuItem.separatorItem];
    _editItem = DeskAddAction(card, @"调角模式", self, @selector(toggleEditing:));
    DeskAddAction(card, @"复位角点", self, @selector(resetQuad:));
    [self addSubmenuTo:menu title:@"卡片面板（系统状态）" menu:card];

    // ---- 组件 2：弹药库 ARMORY（文件夹收纳）----
    NSMenu *vault = [[NSMenu alloc] initWithTitle:@"弹药库 ARMORY"];
    _vaultItem = DeskAddAction(vault, @"显示 / 隐藏", self, @selector(toggleVaultHidden:));
    [self addSubmenuTo:vault title:@"外观"
                  menu:(_vaultStyleMenu = [self styleMenuForAction:@selector(chooseVaultStyle:) title:@"弹药库外观"])];
    [self addSubmenuTo:vault title:@"透明度" menu:[self vaultAlphaMenu]];
    [vault addItem:NSMenuItem.separatorItem];
    DeskAddAction(vault, @"选文件/文件夹入库…", self, @selector(pickItemsToIngest:));
    DeskAddAction(vault, @"恢复默认位置（左下）", self, @selector(resetVaultPlace:));
    [vault addItem:NSMenuItem.separatorItem];
    _vaultEditItem = DeskAddAction(vault, @"调角模式", self, @selector(toggleVaultEditing:));
    DeskAddAction(vault, @"复位角点", self, @selector(resetVaultQuad:));
    [self addSubmenuTo:menu title:@"弹药库 ARMORY（文件夹收纳）" menu:vault];

    // ---- 组件 3：活动监视器 ACTIVITY（每进程负载四榜）----
    NSMenu *mon = [[NSMenu alloc] initWithTitle:@"活动监视器 ACTIVITY"];
    _monitorItem = DeskAddAction(mon, @"显示 / 隐藏", self, @selector(toggleMonitorHidden:));
    [self addSubmenuTo:mon title:@"外观"
                  menu:(_monitorStyleMenu = [self styleMenuForAction:@selector(chooseMonitorStyle:) title:@"活动监视器外观"])];
    _monitorCompactItem = DeskAddAction(mon, @"简略模式", self, @selector(toggleMonitorCompact:));
    [mon addItem:NSMenuItem.separatorItem];
    [self addSubmenuTo:mon title:@"摆到（不用按住拖）"
                  menu:(_monitorCornerMenu = [self cornerMenuForTitle:@"摆到"
                                                              action:@selector(moveMonitorToCorner:)])];
    {   // 四角只能贴边；要到屏幕中间或半个为位置，用九宫格一次到位
        NSMenu *grid = [[NSMenu alloc] initWithTitle:@"九宫格"];
        static const char *gn[9] = { "左上", "上中", "右上", "左中", "正中", "右中", "左下", "下中", "右下" };
        for (int i = 0; i < 9; i++) {
            NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:[NSString stringWithUTF8String:gn[i]]
                                                        action:@selector(placeMonitorAtCell:) keyEquivalent:@""];
            it.tag = i;
            [grid addItem:it];
        }
        [self addSubmenuTo:mon title:@"九宫格摆位（不用按住拖）" menu:grid];
    }
    {   // 摆到只能贴四个角，微调才能放到任意位置：拖不动时这条是完整出路
        NSMenu *nudge = [[NSMenu alloc] initWithTitle:@"微调"];
        static const char *nn[4] = { "左移 20pt", "右移 20pt", "上移 20pt", "下移 20pt" };
        for (int i = 0; i < 4; i++) {
            NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:[NSString stringWithUTF8String:nn[i]]
                                                        action:@selector(nudgeMonitor:) keyEquivalent:@""];
            it.tag = i;
            [nudge addItem:it];
        }
        [self addSubmenuTo:mon title:@"微调 20pt（不用按住拖）" menu:nudge];
    }
    DeskAddAction(mon, @"恢复默认位置（右下）", self, @selector(resetMonitorPlace:));
    DeskAddAction(mon, @"自检：模拟拖 30pt（不用真鼠标）", self, @selector(selfTestMonitorDrag:));
    [mon addItem:NSMenuItem.separatorItem];
    _monitorEditItem = DeskAddAction(mon, @"调角模式", self, @selector(toggleMonitorEditing:));
    DeskAddAction(mon, @"复位角点", self, @selector(resetMonitorQuad:));
    DeskAddAction(mon, @"打开原生活动监视器", self, @selector(openActivityMonitor:));
    [self addSubmenuTo:menu title:@"活动监视器 ACTIVITY（CPU · 内存 · 能耗 · 网络）" menu:mon];

    // ---- 组件 4：签到中心 CREDITS（四平台槽）----
    NSMenu *cred = [[NSMenu alloc] initWithTitle:@"签到中心 CREDITS"];
    _creditsStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"状态：—" action:NULL keyEquivalent:@""];
    _creditsStatusMenuItem.enabled = NO;
    [cred addItem:_creditsStatusMenuItem];
    DeskAddAction(cred, @"立即签到（全部平台）", self, @selector(checkInAllNow:));
    DeskAddAction(cred, @"立即检查（补签）", self, @selector(creditsCheckNowAll:));
    [cred addItem:NSMenuItem.separatorItem];

    // MiniMax：唯一已接入，浏览器独立 OAuth、自动续期
    NSMenu *mm = [[NSMenu alloc] initWithTitle:@"MiniMax"];
    _creditsMiniMaxInfoItem = [[NSMenuItem alloc] initWithTitle:@"余额 —" action:NULL keyEquivalent:@""];
    _creditsMiniMaxInfoItem.enabled = NO;
    [mm addItem:_creditsMiniMaxInfoItem];
    _creditsCheckInItem = DeskAddAction(mm, @"立即签到", self, @selector(checkInNow:));
    DeskAddAction(mm, @"立即刷新", self, @selector(refreshCreditsNow:));
    _creditsAuthItem = DeskAddAction(mm, @"重新授权…", self, @selector(reauthorizeCredits:));
    DeskAddAction(mm, @"打开 MiniMax Code 网页版", self, @selector(openMiniMaxWeb:));
    _creditsMiniMaxMenuItem = [self addSubmenuTo:cred title:@"MiniMax · 未授权" menu:mm];

    // Trae：只读本机 storage.json，刻意不自动续期（会踢 IDE）
    NSMenu *trae = [[NSMenu alloc] initWithTitle:@"Trae"];
    _creditsTraeInfoItem = [[NSMenuItem alloc] initWithTitle:@"余额 — · 登录态 —" action:NULL keyEquivalent:@""];
    _creditsTraeInfoItem.enabled = NO;
    [trae addItem:_creditsTraeInfoItem];
    _creditsTraeCheckInItem = DeskAddAction(trae, @"立即签到", self, @selector(traeCheckInNow:));
    DeskAddAction(trae, @"刷新额度", self, @selector(traeRefreshNow:));
    DeskAddAction(trae, @"从本机重新读取登录态", self, @selector(traeReloadCredentials:));
    DeskAddAction(trae, @"打开 Trae", self, @selector(openTraeApp:));
    NSMenuItem *traeHint = [[NSMenuItem alloc] initWithTitle:@"只读 storage.json · 不自动续期（刷新会踢掉 IDE）"
                                                     action:NULL keyEquivalent:@""];
    traeHint.enabled = NO;
    [trae addItem:traeHint];
    _creditsTraeMenuItem = [self addSubmenuTo:cred title:@"Trae · 读取中" menu:trae];

    // WorkBuddy：官方浏览器登录 + 每日签到（国内版有连签）
    NSMenu *wb = [[NSMenu alloc] initWithTitle:@"WorkBuddy"];
    _creditsWorkBuddyInfoItem = [[NSMenuItem alloc] initWithTitle:@"余额 — · 每日签到"
                                                          action:NULL keyEquivalent:@""];
    _creditsWorkBuddyInfoItem.enabled = NO;
    [wb addItem:_creditsWorkBuddyInfoItem];
    _creditsWorkBuddyLoginItem = DeskAddAction(wb, @"登录（浏览器）…", self, @selector(workbuddyLogin:));
    _creditsWorkBuddyCheckInItem = DeskAddAction(wb, @"立即签到", self, @selector(workbuddyCheckInNow:));
    DeskAddAction(wb, @"刷新额度", self, @selector(workbuddyRefreshNow:));
    DeskAddAction(wb, @"从本机导入明文登录态", self, @selector(workbuddyImportLocal:));
    DeskAddAction(wb, @"打开 WorkBuddy", self, @selector(openWorkbuddyApp:));
    NSMenuItem *wbHint = [[NSMenuItem alloc] initWithTitle:@"5.6.2+ 客户端登录态已加密，优先浏览器登录"
                                                   action:NULL keyEquivalent:@""];
    wbHint.enabled = NO;
    [wb addItem:wbHint];
    _creditsWorkBuddyMenuItem = [self addSubmenuTo:cred title:@"WorkBuddy · 读取中" menu:wb];

    // Qoder：PT → job token → 官方活动领取；国内版不需要设备风控
    NSMenu *qoder = [[NSMenu alloc] initWithTitle:@"Qoder"];
    _creditsQoderInfoItem = [[NSMenuItem alloc] initWithTitle:@"余额 — · 活动领取"
                                                       action:NULL keyEquivalent:@""];
    _creditsQoderInfoItem.enabled = NO;
    [qoder addItem:_creditsQoderInfoItem];
    _creditsQoderCheckInItem = DeskAddAction(qoder, @"立即领取", self, @selector(qoderCheckInNow:));
    DeskAddAction(qoder, @"刷新额度", self, @selector(qoderRefreshNow:));
    _creditsQoderTokenItem = DeskAddAction(qoder, @"设置 PT 令牌…", self, @selector(qoderSetToken:));
    DeskAddAction(qoder, @"打开 Qoder 用量页", self, @selector(openQoderUsage:));
    NSMenuItem *qHint = [[NSMenuItem alloc] initWithTitle:@"国内版无需设备 · 每天 10:00 刷新"
                                                  action:NULL keyEquivalent:@""];
    qHint.enabled = NO;
    [qoder addItem:qHint];
    _creditsQoderMenuItem = [self addSubmenuTo:cred title:@"Qoder · 读取中" menu:qoder];

    [cred addItem:NSMenuItem.separatorItem];
    _creditsItem = DeskAddAction(cred, @"显示 / 隐藏", self, @selector(toggleCreditsHidden:));
    [self addSubmenuTo:cred title:@"外观"
                  menu:(_creditsStyleMenu = [self styleMenuForAction:@selector(chooseCreditsStyle:)
                                                                  title:@"签到外观"])];
    DeskAddAction(cred, @"恢复默认位置（左上）", self, @selector(resetCreditsPlace:));
    _creditsCenterMenuItem = [self addSubmenuTo:menu title:@"签到中心 CREDITS" menu:cred];
    DeskLog(@"签到菜单：MiniMax（OAuth 自动续期）+ Trae（只读本机 storage.json）+ Qoder（PT → 官方活动接口）+ WorkBuddy（浏览器登录 → 签到接口）；每平台独立签到");

    [menu addItem:NSMenuItem.separatorItem];

    // ---- 全局 ----
    _lockItem = DeskAddAction(menu, @"锁定位置（四块都不可拖动）", self, @selector(toggleLayoutLock:));
    [menu addItem:NSMenuItem.separatorItem];
    DeskAddAction(menu, @"打开数据目录…", self, @selector(openDataDir:));
    NSMenuItem *quit = DeskAddAction(menu, @"退出 DeskBoard", self, @selector(quit:));
    quit.keyEquivalent = @"q";

    // 临时：二分定位用。四个可辨认的形状，各测一个变量：
    //   ● circle.fill + DeskBoard 这套大菜单
    //   ■ square.fill + 简单菜单
    _statusItem.menu = menu;
    [self syncMenu];
    DeskLog(@"菜单栏项 可见=%d 宽度=%.0f 按钮=%@ 图标=%.0fx%.0f", _statusItem.isVisible,
            _statusItem.length, _statusItem.button ? @"有" : @"无",
            _statusItem.button.image.size.width, _statusItem.button.image.size.height);

    // 状态栏项的活体诊断：光看 isVisible 会被骗——菜单栏图标不显示时它照样返回 1。
    // 这里把「系统到底把这按钮摆在哪、画没画、有没有 alpha、有没有被别的窗口压住」逐项打出来。
    // 只有 DESKBOARD_STATUS_DIAG=1 时才开（5 秒一拍），产品路径不受影响。
    if (getenv("DESKBOARD_STATUS_DIAG")) {
        [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(logStatusItemDiag)
                                       userInfo:nil repeats:YES];
        [self logStatusItemDiag];
    }
}

// 诊断专用：状态栏按钮的真实状态。isVisible=1 只能证明"项还在"，证明不了"用户看得见"。
- (void)logStatusItemDiag {
    NSStatusItem *it = _statusItem;
    if (!it) { DeskLog(@"状态栏诊断: 没有状态项"); return; }
    NSButton *b = it.button;
    NSView *bv = (NSView *)b;      // SDK 里 NSStatusItem.button 的 NSButton 只有前向声明，按 NSView 用
    NSWindow *w = b.window;
    NSPoint sp = w ? [w convertPointToScreen:[bv convertPoint:NSZeroPoint toView:nil]] : NSZeroPoint;
    NSRect f = w ? w.frame : NSZeroRect;
    NSImage *img = b.image;
    DeskLog(@"状态栏诊断: itemVisible=%d len=%.0f | btn hidden=%d alpha=%.2f enabled=%d img=%.0fx%.0f tmpl=%d"
            @" | win=%@ frame=(%.0f,%.0f %.0fx%.0f) vis=%d level=%ld onActiveSpace=%d occ=%ld"
            @" | 按钮屏幕坐标=(%.0f,%.0f) | app hidden=%d policy=%ld 屏数=%lu",
            it.isVisible ? 1 : 0, it.length,
            bv.isHidden ? 1 : 0, bv.alphaValue, b.isEnabled ? 1 : 0,
            img ? img.size.width : -1, img ? img.size.height : -1, img ? (img.isTemplate ? 1 : 0) : 0,
            w ? @"有" : @"无", f.origin.x, f.origin.y, f.size.width, f.size.height,
            w ? (w.isVisible ? 1 : 0) : 0, w ? (long)w.level : 0,
            w ? (w.isOnActiveSpace ? 1 : 0) : 0, w ? (long)w.occlusionState : 0,
            sp.x, sp.y, NSApp.isHidden ? 1 : 0, (long)NSApp.activationPolicy,
            (unsigned long)[NSScreen screens].count);
}

- (void)syncMenu {
    _statusItem.button.appearsDisabled = _hidden;
    for (NSMenuItem *it in _styleMenu.itemArray) {
        it.state = it.tag == _style ? NSControlStateValueOn : NSControlStateValueOff;
    }
    _cardItem.state = _hidden ? NSControlStateValueOff : NSControlStateValueOn;
    _editItem.state = _editing ? NSControlStateValueOn : NSControlStateValueOff;
    _lockItem.state = _layoutLocked ? NSControlStateValueOn : NSControlStateValueOff;
    _lockItem.title = _layoutLocked ? @"锁定位置（已锁：四块都不能拖）"
                                    : @"锁定位置（四块都能拖）";
    _vaultItem.state = _vaultHidden ? NSControlStateValueOff : NSControlStateValueOn;
    _vaultEditItem.state = _vaultEditing ? NSControlStateValueOn : NSControlStateValueOff;
    for (NSMenuItem *it in _vaultStyleMenu.itemArray) {
        it.state = it.tag == _vaultStyle ? NSControlStateValueOn : NSControlStateValueOff;
    }
    _monitorItem.state = _monitorHidden ? NSControlStateValueOff : NSControlStateValueOn;
    _monitorCompactItem.state = _monitorCompact ? NSControlStateValueOn : NSControlStateValueOff;
    _monitorEditItem.state = _monitorEditing ? NSControlStateValueOn : NSControlStateValueOff;
    if (_monitorCornerMenu) {
        NSInteger cur = [_monitorPlaces placeForScreen:NSScreen.mainScreen ?: NSScreen.screens.firstObject].corner;
        for (NSMenuItem *it in _monitorCornerMenu.itemArray) {
            it.state = it.tag == cur ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    for (NSMenuItem *it in _monitorStyleMenu.itemArray) {
        it.state = it.tag == _monitorStyle ? NSControlStateValueOn : NSControlStateValueOff;
    }
    // 存档里的 alpha 只可能是 kVaultAlphaStep 的整数倍，四舍五入回整数再比对，避免浮点误差让勾跑掉
    NSInteger alphaPct = (NSInteger)(_vaultAlpha * 100.0 + 0.5);
    for (NSMenuItem *it in _vaultAlphaMenu.itemArray) {
        it.state = it.tag == alphaPct ? NSControlStateValueOn : NSControlStateValueOff;
    }
    _creditsItem.state = _creditsHidden ? NSControlStateValueOff : NSControlStateValueOn;
    for (NSMenuItem *it in _creditsStyleMenu.itemArray) {
        it.state = it.tag == _creditsStyle ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (_credits) {
        DeskCreditsCenterSnapshot *cc = _creditsCenter
            ?: [DeskCreditsCenterSnapshot centerWithMiniMax:_credits.snapshot
                                                       trae:_trae.snapshot
                                                      qoder:_qoder.snapshot
                                                  workbuddy:_workbuddy.snapshot];
        DeskCreditsSnapshot *cs = _credits.snapshot;
        _creditsCenterMenuItem.title = [NSString stringWithFormat:@"签到中心 CREDITS（%ld/4 已接入）",
                                        (long)cc.connectedCount];
        _creditsStatusMenuItem.title = [NSString stringWithFormat:@"状态：%@",
                                        [self creditsSummaryTextForCenter:cc]];
        _creditsMiniMaxMenuItem.title = [NSString stringWithFormat:@"MiniMax · %@",
                                         [self creditsMiniMaxHeadline]];
        _creditsTraeMenuItem.title = [self creditsMenuTitleForSlot:
                                      [cc slotForPlatform:DeskCreditsPlatformTrae]];
        DeskTraeSnapshot *tr = _trae.snapshot;
        NSString *traeBal = tr.balance >= 0
            ? [NSString stringWithFormat:@"余额 %@ 积分", DeskCreditsFormatPoints(tr.balance)]
            : @"余额 —";
        NSString *traeLife = tr.tokenExpiresAt > 0
            ? [NSString stringWithFormat:@"登录态 %.0f 天", MAX(0.0, tr.loginDays)]
            : @"登录态 —";
        _creditsTraeInfoItem.title = [NSString stringWithFormat:@"%@ · %@", traeBal, traeLife];
        _creditsTraeCheckInItem.title = tr.checkedIn ? @"立即签到（今日已签）" : @"立即签到";
        _creditsTraeCheckInItem.enabled = tr.connected
            && tr.phase != DeskTraePhaseNeedsAuth && tr.hasStatus && tr.enabled
            && !tr.checkedIn && !tr.claiming;
        _creditsWorkBuddyMenuItem.title = [self creditsMenuTitleForSlot:
                                           [cc slotForPlatform:DeskCreditsPlatformWorkBuddy]];
        DeskWorkbuddySnapshot *wr = _workbuddy.snapshot;
        NSString *wBal = wr.balance >= 0
            ? [NSString stringWithFormat:@"余额 %@ 积分", DeskCreditsFormatPoints(wr.balance)]
            : @"余额 —";
        NSString *wState = wr.checkedIn ? @"今日已签"
            : (wr.hasStatus && wr.activityEnabled ? @"今日待签"
               : (wr.hasStatus ? @"无签到活动" : @"未同步"));
        if (!wr.hasToken) wState = @"未登录";
        else if (wr.tokenExpired) wState = @"登录过期";
        _creditsWorkBuddyInfoItem.title = [NSString stringWithFormat:@"%@ · %@ · 连签 %.0f 天",
                                           wBal, wState, wr.streakDays];
        _creditsWorkBuddyCheckInItem.title = wr.checkedIn ? @"立即签到（今日已签）" : @"立即签到";
        _creditsWorkBuddyCheckInItem.enabled = wr.hasToken && !wr.tokenExpired
            && wr.hasStatus && wr.activityEnabled && !wr.checkedIn && !wr.claiming;
        _creditsWorkBuddyLoginItem.title = wr.hasToken ? @"重新登录（浏览器）…" : @"登录（浏览器）…";
        _creditsWorkBuddyLoginItem.enabled = !wr.authorizing;
        _creditsQoderMenuItem.title = [self creditsMenuTitleForSlot:
                                       [cc slotForPlatform:DeskCreditsPlatformQoder]];
        DeskQoderSnapshot *qr = _qoder.snapshot;
        NSString *qBal = qr.balance >= 0
            ? [NSString stringWithFormat:@"余额 %@ Credits", DeskCreditsFormatPoints(qr.balance)]
            : @"余额 —";
        NSString *qState = qr.claimed ? @"本窗口已领"
            : (qr.claimable ? @"待领" : (qr.hasStatus ? @"无活动" : @"未同步"));
        if (!qr.hasToken) qState = @"未设置 PT";
        else if (qr.tokenInvalid) qState = @"PT 失效";
        _creditsQoderInfoItem.title = [NSString stringWithFormat:@"%@ · %@", qBal, qState];
        _creditsQoderCheckInItem.title = qr.claimed ? @"立即领取（本窗口已领）" : @"立即领取";
        _creditsQoderCheckInItem.enabled = qr.hasToken && !qr.tokenInvalid
            && qr.claimable && !qr.claiming;
        _creditsQoderTokenItem.title = qr.hasToken ? @"更换 PT 令牌…" : @"设置 PT 令牌…";
        NSString *bal = cs.authorized
            ? [NSString stringWithFormat:@"余额 %@ 积分", DeskCreditsFormatPoints(cs.balance)]
            : @"余额 —";
        _creditsMiniMaxInfoItem.title = [NSString stringWithFormat:@"%@ · %@", bal,
                                         DeskCreditsCycleText(cs)];
        _creditsCheckInItem.title = cs.todayChecked ? @"立即签到（今日已签）" : @"立即签到";
        _creditsCheckInItem.enabled = cs.authorized && !cs.needsAuth
            && !cs.todayChecked && !cs.claiming && !cs.authorizing;
        _creditsAuthItem.title = cs.authorizing ? @"等待浏览器授权…" : @"重新授权…";
        _creditsAuthItem.enabled = !cs.authorizing;
    }
}

- (void)chooseVaultStyle:(id)sender {
    _vaultStyle = [sender tag];
    for (NSWindow *w in _vaultWindows) {
        NSView *v = w.contentView;
        if ([v isKindOfClass:[DeskVaultView class]]) ((DeskVaultView *)v).style = (DeskStyle)_vaultStyle;
        w.hasShadow = (DeskStyle)_vaultStyle != DeskStyleHUD;
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

- (void)quit:(id)sender { [_hist flushIfNeeded]; [NSApp terminate:nil]; }

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