// 桌面小组件面板：唯一的渲染出口，只读 DeskModel，不做任何数据获取。
#import <AppKit/AppKit.h>
#import "model.h"
#import "palette.h"
#import "quad.h"

extern const CGFloat kDeskPanelWidth;   // 单列表格宽度，窗口尺寸与测试都以它为准

// 卡片四角各留 kDeskQuadPad 的余量，拖出去的角不会被窗口裁掉
static inline NSSize DeskWarpedWindowSize(NSSize cardSize) { return DeskQuadCanvasSize(cardSize); }

// 电平条宽度：fraction < 0 表示这行不画条，0~1 之外夹紧。
// 绘制和 verify 共用这一个换算，两边不各算一遍。
CGFloat DeskPanelMeterWidth(double fraction, CGFloat rowWidth);
// 采样钟走到第几格：0..9（10 秒封顶），负数/NaN 都算 0。
NSInteger DeskPanelClockIndex(double secondsSinceSample);

// 参数档位：正常 / 偏高 / 过高；Unknown 用于没读到的指标。
// 温度计的颜色、磁盘条的三段区间和状态词都认这一套，绘制和断言共用。
typedef NS_ENUM(NSInteger, DeskPanelLevel) {
    DeskPanelLevelUnknown = -1,
    DeskPanelLevelNormal = 0,
    DeskPanelLevelWarn = 1,
    DeskPanelLevelCritical = 2,
};
// 温度取 CPU / SSD 中更高的那个：<70 正常，70–85 偏高，>85 过高。
DeskPanelLevel DeskPanelTempLevel(double cpuTemp, double ssdTemp);
double DeskPanelTempFraction(double cpuTemp, double ssdTemp);   // 同一个"更热的那个"/100
// 磁盘已用：<80% 正常，80–90% 偏高，>90% 过高。
DeskPanelLevel DeskPanelDiskLevel(double fraction);
// 电池：交流电/充电中正常；电池供电 >20% 正常，10–20% 偏低，<10% 低。
DeskPanelLevel DeskPanelBatteryLevel(double percent, BOOL onAC, BOOL charging);
// 网络 / IPv4：有接口 / 有地址就是在线，否则离线。
DeskPanelLevel DeskPanelNetworkLevel(NSString *interface);
DeskPanelLevel DeskPanelIPv4Level(NSString *address);

@interface DeskPanelView : NSView
@property (nonatomic, strong) DeskModel *model;
@property (nonatomic, assign) DeskStyle style;
// 视图要播动效了：把停掉的 60fps 动画表叫回来（和弹药库/活动监视器同一条路）
@property (nonatomic, copy) void (^onNeedFrames)(void);
+ (NSSize)sizeForModel:(DeskModel *)model;
// 系统状态是单列表格：每行都占满内容宽度。几何只在这里算一次，
// 绘制和布局断言共用，免得两边各算一遍算歪。
+ (void)rowGeometryForIndex:(NSUInteger)idx count:(NSUInteger)count
                          x:(CGFloat *)x width:(CGFloat *)width;
- (void)tick:(double)dt;
- (BOOL)needsRedraw;
- (void)settle;   // 变形/不可见：直接跳到目标值，不逐帧缓动
// 只读口：离线预览和 verify 用
- (double)meterFractionForRow:(NSInteger)row;
- (double)tempColdFraction;   // 温度行“较冷那颗”的水位；没有第二颗 = -1
- (NSInteger)clockIndex;
@end

@interface DeskCardView : NSView
@property (nonatomic, readonly, strong) DeskPanelView *panel;
@property (nonatomic, assign) DeskStyle style;
@property (nonatomic, assign) DeskQuadOffsets quadOffsets;   // 全 0 = 没变形，走实时绘制
@property (nonatomic, assign) BOOL editing;                  // 调角模式：画把手、吃掉鼠标事件
@property (nonatomic, assign) BOOL locked;                   // 全局锁定：整块不吃拖动，点击/调角照旧
@property (nonatomic, copy) void (^onQuadEdit)(DeskQuadOffsets);   // 拖完一个角通知外面存盘
@property (nonatomic, copy) void (^onGeometryChange)(void);        // 几何变了（拖角或拖窗口），刷坐标读数
@property (nonatomic, copy) void (^onUserMove)(void);              // 用户亲手拖动窗口：只有这里才允许写"待保存"
@property (nonatomic, copy) void (^onNeedFrames)(void);            // 卡片要播动效：叫回动画表
- (instancetype)initWithModel:(DeskModel *)model style:(DeskStyle)style;
- (instancetype)initWithModel:(DeskModel *)model style:(DeskStyle)style warped:(BOOL)warped;
- (void)updateModel:(DeskModel *)model;
- (void)refreshSource;   // 变形时：在绘制之外把平面卡片预渲染成位图
- (DeskQuad)currentQuad;
- (BOOL)isWarped;
- (BOOL)isDragging;      // 用户正按住拖窗口
- (void)dragWindowToMouse:(NSPoint)mouseNow;   // 只给校验/自检用：按屏幕坐标挪窗
- (void)tick:(double)dt;
- (BOOL)needsRedraw;
+ (NSSize)windowSizeForModel:(DeskModel *)model style:(DeskStyle)style warped:(BOOL)warped;
@end
