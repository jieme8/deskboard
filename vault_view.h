// 弹药库组件：桌面文件夹收纳架。
// 布局、绘制、拖放都在这一个 view 里；数据只从 DeskVault 读。
#import <AppKit/AppKit.h>
#import "vault.h"
#import "quad.h"
#import "panel_view.h"

extern const CGFloat kVaultViewWidth;
extern const CGFloat kVaultViewHeight;

// 库位满员的软上限，只影响容量环和"空闲 N 位"的读数，不拦着人继续存
extern const NSUInteger kVaultSlotCapacity;

NS_ASSUME_NONNULL_BEGIN

@interface DeskVaultView : NSView
@property (nonatomic, readonly, strong) DeskVault *vault;
// 调角：和卡片面板同一套四角自由变形
@property (nonatomic, assign) DeskQuadOffsets quadOffsets;
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, assign) DeskStyle style;   // 外观，直接复用卡片面板那一套
@property (nonatomic, copy) void (^onQuadEdit)(DeskQuadOffsets);
@property (nonatomic, copy) void (^onGeometryChange)(void);
@property (nonatomic, copy) void (^onHide)(void);            // 点「收起」：整块藏起来
@property (nonatomic, copy) void (^onUserMove)(void);        // 用户亲手拖过窗口：外面据此挂"待保存"
// 悬停预览：图片卡片上停一下就浮出放大图。预览画在组件外面（会盖住卡片就失去意义），
// 由外面开一块独立浮窗来接。path 为 nil 表示收起。
@property (nonatomic, copy) void (^onPreview)(NSString *_Nullable path);
@property (nonatomic, copy) void (^onLog)(NSString *message);
// 组件要开始动起来了（悬停、拖放、入库动画），外面据此把动画驱动表叫回来。
// 空闲时那张 60fps 的表是停着的，没人叫它就永远不动
@property (nonatomic, copy) void (^onNeedFrames)(void);

// 拖动时的窗口位移。单独抽成函数是因为这里出过事故：
// 视图是翻转坐标（左上原点），屏幕坐标是左下原点，
// 两者直接相减会让组件在拖动第一帧就瞬移到按下点的坐标上。
// 参数全是屏幕坐标，不涉及任何视图坐标，就不会再混。
NSRect VaultDragFrame(NSRect frameAtStart, NSPoint mouseAtStart, NSPoint mouseNow);

// 预览/校验工具用：直接塞假数据，不碰真实文件系统
- (instancetype)initWithItems:(NSArray<DeskVaultItem *> *)items;
// 离屏渲染时没有真窗口，告诉它"你在这块屏幕的这个位置"，采样才对得上
- (void)setStandInScreenRect:(NSRect)r;
// 预览/校验工具用：直接摆出悬停、投喂、滚动这些平时要真鼠标才出得来的状态
- (void)applyPreviewHoverCard:(NSInteger)card
                         dock:(NSInteger)dock
                     dropHot:(double)hot
                   dropCount:(NSInteger)count
                       scroll:(CGFloat)scroll;

+ (NSSize)windowSizeWarped:(BOOL)warped;
- (DeskQuad)currentQuad;
- (BOOL)isWarped;
- (NSRect)cardRectAtIndex:(NSInteger)idx in:(NSRect)bounds;
- (NSInteger)cardIndexAtPoint:(NSPoint)p in:(NSRect)bounds;
- (NSArray<NSValue *> *)dockButtonRectsIn:(NSRect)bounds;
- (BOOL)isDragging;            // 拖窗口 / 拖卡片 / 正在接拖放，自动隐藏要绕开
- (void)tick:(double)dt;          // 推进动画；空闲时不必每帧调用
- (BOOL)needsRedraw;              // 当前有没有非静态内容在动

@end
NS_ASSUME_NONNULL_END

