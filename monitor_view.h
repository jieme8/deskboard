// 活动监视器组件：四榜并列（CPU / 内存 / 能耗 / 网络），每榜 4 个进程。
// 只画不采 —— 数据一律从 DeskProcsMonitor 拿，视图里绝不做系统调用。
#import <AppKit/AppKit.h>
#import "panel_view.h"
#import "procs.h"
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
// 系统总量（榜头那四个读数）：CPU 0~100、内存已用/物理字节、能耗合计、网络 B/s
@property (nonatomic, assign) double totalCPU;
@property (nonatomic, assign) double totalMemUsed;
@property (nonatomic, assign) double totalMemPhys;
@property (nonatomic, assign) double totalEnergy;
@property (nonatomic, assign) double totalNetIn;
@property (nonatomic, assign) double totalNetOut;
@property (nonatomic, assign) NSInteger procCount;         // "你的进程 N 个"
@property (nonatomic, assign) DeskStyle style;
@property (nonatomic, copy) void (^onLog)(NSString *message);
@property (nonatomic, copy) void (^onUserMove)(void);
// 空闲时那张 60fps 的表是停着的，视图要动就自己把表叫回来（和弹药库同一套，别再犯 39% CPU 那个病）
@property (nonatomic, copy) void (^onNeedFrames)(void);
// 悬停某个进程：main.m 据此开/收卡外浮层。pid < 0 = 移开
@property (nonatomic, copy) void (^onHover)(pid_t pid, NSRect rowInWindow);

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
// 只给校验用：把「我用的就是卡片面板那一套取色」变成能断言的东西
- (DeskPalette)paletteSnapshot;
- (NSInteger)hitTestRowAt:(NSPoint)p in:(NSRect)b metric:(NSInteger *)metric;
- (pid_t)pidAtMetric:(NSInteger)metric row:(NSInteger)row;
- (BOOL)isDragging;

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
- (void)dragCorner:(NSInteger)corner toCanvasPoint:(NSPoint)p;
- (NSBitmapImageRep *)bakedFlatBitmap;
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
@end

NS_ASSUME_NONNULL_END
