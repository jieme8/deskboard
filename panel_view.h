// 桌面小组件面板：唯一的渲染出口，只读 DeskModel，不做任何数据获取。
#import <AppKit/AppKit.h>
#import "model.h"
#import "quad.h"

typedef NS_ENUM(NSInteger, DeskStyle) {
    DeskStylePlate = 0,    // 圆角卡 + 壁纸采样模糊 + 描边
    DeskStyleFeather,      // 没有边界：一层羽化暗角垫在文字下，文字带柔和投影
    DeskStyleBare,         // 完全无底，只有文字和投影
    DeskStyleHUD,          // 贴在壁纸窗玻璃上的青色 HUD，无底板无描边
};

extern const CGFloat kDeskPanelWidth;   // 横版卡片宽度，窗口尺寸与测试都以它为准
extern const CGFloat kDeskStatColW;     // 指标左列宽

// 卡片四角各留 kDeskQuadPad 的余量，拖出去的角不会被窗口裁掉
static inline NSSize DeskWarpedWindowSize(NSSize cardSize) { return DeskQuadCanvasSize(cardSize); }

@interface DeskPanelView : NSView
@property (nonatomic, strong) DeskModel *model;
@property (nonatomic, assign) DeskStyle style;
+ (NSSize)sizeForModel:(DeskModel *)model;
// 横版把指标分两列，列几何只在这里算一次，绘制和布局断言共用，免得两边各算一遍算歪
+ (void)statColumnForIndex:(NSUInteger)idx count:(NSUInteger)count
                         x:(CGFloat *)x width:(CGFloat *)width;
@end

@interface DeskCardView : NSView
@property (nonatomic, readonly, strong) DeskPanelView *panel;
@property (nonatomic, assign) DeskStyle style;
@property (nonatomic, assign) DeskQuadOffsets quadOffsets;   // 全 0 = 没变形，走实时绘制
@property (nonatomic, assign) BOOL editing;                  // 调角模式：画把手、吃掉鼠标事件
@property (nonatomic, copy) void (^onQuadEdit)(DeskQuadOffsets);   // 拖完一个角通知外面存盘
@property (nonatomic, copy) void (^onGeometryChange)(void);        // 几何变了（拖角或拖窗口），刷坐标读数
@property (nonatomic, copy) void (^onUserMove)(void);              // 用户亲手拖动窗口：只有这里才允许写"待保存"
- (instancetype)initWithModel:(DeskModel *)model style:(DeskStyle)style;
- (instancetype)initWithModel:(DeskModel *)model style:(DeskStyle)style warped:(BOOL)warped;
- (void)updateModel:(DeskModel *)model;
- (void)refreshSource;   // 变形时：在绘制之外把平面卡片预渲染成位图
- (DeskQuad)currentQuad;
- (BOOL)isWarped;
+ (NSSize)windowSizeForModel:(DeskModel *)model style:(DeskStyle)style warped:(BOOL)warped;
@end
