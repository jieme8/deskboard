// 活动监视器组件：四榜并列（CPU / 内存 / 能耗 / 网络），每榜 4 个进程。
// 只画不采 —— 数据一律从 DeskProcsMonitor 拿，视图里绝不做系统调用。
#import <AppKit/AppKit.h>
#import "panel_view.h"
#import "procs.h"
#import "history.h"
#import "quad.h"

NS_ASSUME_NONNULL_BEGIN

extern const CGFloat kMonitorViewWidth;
extern const CGFloat kMonitorViewHeight;
extern const NSInteger kMonitorRowsPerQuadrant;

typedef NS_ENUM(NSInteger, DeskMonitorMetric) {
    DeskMonitorMetricCPU = 0,
    DeskMonitorMetricMemory,
    DeskMonitorMetricEnergy,
    DeskMonitorMetricNetwork,
};

@interface DeskMonitorView : NSView
// 系统总量（榜头读数）：CPU 是整机 0~100（榜头自己换算成全核），内存是已用/物理字节。
// 网络榜头不再吃系统 B/s —— 那是"速率"，和榜内每行的"连接数"不是同一个量，
// 并排放着就会重演"总 CPU 比单进程还小"那个困惑。整机网速在卡片面板上有（↓41K ↑12K）。
@property (nonatomic, assign) double totalCPU;
@property (nonatomic, assign) double totalMemUsed;
@property (nonatomic, assign) double totalMemPhys;
@property (nonatomic, assign) double totalEnergy;
@property (nonatomic, assign) NSInteger procCount;         // "你的进程 N 个"
@property (nonatomic, assign) DeskStyle style;
@property (nonatomic, copy) void (^onLog)(NSString *message);
@property (nonatomic, copy) void (^onUserMove)(void);
// 空闲时那张 60fps 的表是停着的，视图要动就自己把表叫回来（和弹药库同一套，别再犯 39% CPU 那个病）
@property (nonatomic, copy) void (^onNeedFrames)(void);
// 12 小时平均的取数口。由 main.m 注入（视图不碰 DeskHistory，保持"只画不采"）。
// 关键约束：这个块只在**数据换拍**时被调用一次，绝不能在 drawRect 里现问 ——
// 一次窗口求和要遍历 720 个桶，16 行乘上 60fps 就是白白把 CPU 送掉。
@property (nonatomic, copy, nullable) double (^historyForPid)(pid_t pid, DeskHistMetric m, double *covered);
//// 悬停某个进程：main.m 据此开/收卡外浮层。pid < 0 = 移开。
// 连着那一格的 12 小时平均值和"窗口内真正记录到的秒数"一起给出去 —— 浮层要显示精确数字，
// 而只有视图缓存着它（换拍算一次），别让 main.m 再回头问视图要格号。
@property (nonatomic, copy) void (^onHover)(pid_t pid, NSRect rowInWindow, NSInteger metric,
                                            double histAvg, double histCovered);

// 塞假数据给预览/校验工具用，不碰真实系统
- (instancetype)initWithRows:(NSArray<DeskProc *> *)rows;
- (void)updateRows:(NSArray<DeskProc *> *)rows;
// 离屏渲染时没有真窗口，告诉它"你在这块屏幕的这个位置"，采样壁纸才对得上
- (void)setStandInScreenRect:(NSRect)r;
// 校验/预览工具用：直接摆出悬停态
- (void)applyPreviewHover:(NSInteger)metric row:(NSInteger)row;
- (NSRect)rowRectAtMetric:(NSInteger)metric row:(NSInteger)row in:(NSRect)b;
// 指标条几何：整行宽、贴在文字下面，和卡片面板 panel_view.m 的 drawBar 同一套算法。
// 单独露出来是给 verify 用的 —— 这条几何就是"和卡片一样"的全部内容，飘回去就得被发现。
+ (NSRect)barRectInRow:(NSRect)row;
// 现在这根条画在 12h 那根的上方 3pt 处。两个口都露出来是给 verify 用的：
// 三样东西挤在 19pt 一行里（文字 12pt + 两根 2pt 条 + 两条缝），飘一pt 就压字。
+ (NSRect)nowBarRectInRow:(NSRect)row;
// 只给校验用：把「我用的就是卡片面板那一套取色」变成能断言的东西
- (DeskPalette)paletteSnapshot;
- (NSInteger)hitTestRowAt:(NSPoint)p in:(NSRect)b metric:(NSInteger *)metric;
- (pid_t)pidAtMetric:(NSInteger)metric row:(NSInteger)row;
- (BOOL)isDragging;
// 悬停浮层要显示精确的 12h 数字和"已记录多久"，这两个口就是给它用的
- (double)historyAverageAtMetric:(NSInteger)m row:(NSInteger)r;
- (double)historyBarFractionAtMetric:(NSInteger)m row:(NSInteger)r;
- (double)nowBarFractionAtMetric:(NSInteger)m row:(NSInteger)r;
- (BOOL)showsHistoryTrackAtMetric:(NSInteger)m row:(NSInteger)r;
- (double)historyCoveredAtMetric:(NSInteger)m row:(NSInteger)r;
// 只给校验用：榜头那串读数。两条不变量（总≥任意一行、能耗榜头是比例不是自造单位绝对值）
// 全靠它断言，不然改口径没人拦得住。
- (NSString *)aggregateTextForMetric:(NSInteger)m;
// 只给校验用：榜内某一行右端那串读数。"带不带单位、能耗是占比还是裸分"全靠这条钉住
- (NSString *)valueTextFor:(DeskProc *)p metric:(NSInteger)m;
// 能耗那一榜的分母（全部进程能耗分之和）。浮层和榜头、每行共用它，别各算各的。
- (double)energyShareTotal;

#pragma mark - 调角模式（和卡片面板 / 弹药库同一条路）
// 变形时整张组件先画成正的、烘成位图，再按四角投影；没变形时走实时绘制，文字才是原生清晰度。
@property (nonatomic, assign) DeskQuadOffsets quadOffsets;
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, copy) void (^onQuadEdit)(DeskQuadOffsets);
@property (nonatomic, copy) void (^onGeometryChange)(void);
+ (NSSize)windowSizeWarped:(BOOL)warped;
- (DeskQuad)currentQuad;
- (BOOL)isWarped;
- (NSRect)resetButtonRect;
// 只给校验/预览用：把"变形时烘的那张位图"要回来。烘 = syncWarp + refreshFlat，
// 所以这条口能端到端验到素材源的状态对不对（条子空不空、外观换没换）。
// 按"鼠标现在在屏幕上的哪里"把窗口挪过去。单独拆出来是因为 mouseDragged: 只能拿
// NSEvent.mouseLocation（真实光标），而这台机器没有辅助功能权限、我没法动真光标 ——
// 拆成参数之后"窗口到底会不会跟着动、动得对不对"就能被断言，而不是只能靠人手拖。
- (void)dragWindowToMouse:(NSPoint)mouseNow;
- (void)dragCorner:(NSInteger)corner toCanvasPoint:(NSPoint)p;
- (NSBitmapImageRep *)bakedFlatBitmap;
// 只给校验用：素材源本体。变形态画的是它烘出来的位图，凡是"读数依赖的数"没拷过去，
// 位图上就是另一个值（能耗占比曾经就差点全印 0%，因为分母没跟着过桥），所以得过这道。
- (nullable DeskMonitorView *)flatSourceForVerify;
- (void)tick:(double)dt;
- (BOOL)needsRedraw;

@end

// 悬停详情浮层：象限只有 196pt，30 字的进程名放不进去，全名和 pid 只能挪到组件外面。
// 和弹药库的图片预览同一套做法 —— 独立的一块无边框窗，点击穿透、不抢激活。
@interface DeskMonitorHoverView : NSView
@property (nonatomic, copy)   NSString *procName;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) NSInteger uid;
@property (nonatomic, assign) long long startedAt;      // 进程启动时刻（unix 秒），0 = 不知道
@property (nonatomic, assign) double cpu;
@property (nonatomic, assign) double mem;
@property (nonatomic, assign) double energy;
@property (nonatomic, assign) NSInteger sockets;
// 能耗占比的分母，由组件本体喂进来（同一拍算好的 _energyTotal），浮层不再自己求和
@property (nonatomic, assign) double energyTotal;
// 悬停那一格的 12 小时平均（同一指标）与窗口内真正记录到的秒数
@property (nonatomic, assign) double histAvg;
@property (nonatomic, assign) double histCovered;
@property (nonatomic, assign) NSInteger histMetric;
@end

NS_ASSUME_NONNULL_END
