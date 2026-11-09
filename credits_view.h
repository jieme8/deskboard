// 签到中心：横向四个平台槽（Trae / WorkBuddy / Qoder / MiniMax）。
// 只画 DeskCreditsCenterSnapshot，不做网络或文件读取；每个槽的主状态视觉不同。
#import <AppKit/AppKit.h>
#import "palette.h"
#import "credits.h"

NS_ASSUME_NONNULL_BEGIN

extern const CGFloat kCreditsViewWidth;    // 700
extern const CGFloat kCreditsViewHeight;   // 132

@interface DeskCreditsView : NSView
@property (nonatomic, strong, nullable) DeskCreditsCenterSnapshot *center;
@property (nonatomic, assign) DeskStyle style;
@property (nonatomic, assign) BOOL locked;           // 全局锁定：整块不吃拖动，槽位点击照旧
@property (nonatomic, copy, nullable) void (^onUserMove)(void);
// 单击槽：miniMax 未授权时由 main 发起授权；占位槽只记日志
@property (nonatomic, copy, nullable) void (^onSlotActivate)(DeskCreditsPlatform platform);
// 双击槽：MiniMax 立即签到；占位槽只记日志
@property (nonatomic, copy, nullable) void (^onSlotDoubleClick)(DeskCreditsPlatform platform);
// 点右上角药丸（签到 / 重试 / 登录 / 授权）：手动签到当前平台
@property (nonatomic, copy, nullable) void (^onSlotCheckNow)(DeskCreditsPlatform platform);
+ (NSSize)size;
- (void)updateCenter:(DeskCreditsCenterSnapshot *)c;
// 正按住拖窗口：这时顶层级等于从用户手里把窗口抢走
- (BOOL)isDragging;
// 只给校验/自检用：按屏幕坐标挪窗
- (void)dragWindowToMouse:(NSPoint)mouseNow;
// 离线预览：没有真窗口时告诉它组件摆在哪块壁纸上
- (void)setStandInScreenRect:(NSRect)r;
// 只给校验用
- (NSInteger)slotCountForVerify;
- (NSRect)slotRectForVerify:(NSInteger)index;
- (NSRect)pillRectForVerify:(NSInteger)index;
- (NSString *)pillTextForVerify:(NSInteger)index;
- (NSString *)pillToneForVerify:(NSInteger)index;
- (DeskCreditsPlatform)platformForVerify:(NSInteger)index;
- (NSString *)platformNameForVerify:(NSInteger)index;
- (NSString *)planTextForVerify:(NSInteger)index;
- (NSString *)statusTextForVerify:(NSInteger)index;
- (NSString *)balanceTextForVerify:(NSInteger)index;
- (NSString *)unitTextForVerify:(NSInteger)index;
- (NSString *)footerTextForVerify:(NSInteger)index;
- (NSString *)recordTextForVerify:(NSInteger)index;
- (NSString *)lastEventTextForVerify:(NSInteger)index;
- (NSInteger)recordRailCountForVerify:(NSInteger)index;
- (BOOL)recordIsNewHighForVerify:(NSInteger)index;
- (DeskCreditsVisualKind)visualForVerify:(NSInteger)index;
- (NSString *)summaryTextForVerify;
- (NSString *)oldestSyncTextForVerify;
- (NSString *)tooltipTextForVerify;
@end

NS_ASSUME_NONNULL_END
