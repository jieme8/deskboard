// 每个"屏 × 点分辨率"各自一份的位置存档。
// 键 = CGDirectDisplayID + frame.size（点），同一块物理屏换缩放档位时 ID 不变、尺寸变，
// 所以两个档位各记各的；换到没见过的档位用默认锚点，切回老档位自动回到老位置。
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

typedef struct {
    NSInteger corner;   // 0 左上 1 右上 2 左下 3 右下
    CGFloat dx, dy;     // 距锚点角两条边的距离
} DeskPlace;

// 存档里的 dx/dy 只保证"整块仍留在可视区内"：下限必须是 0，不能留边距。
// 曾经夹在 [16, …] —— 往边上拖过头的那一次会被夹回 16，而「屏幕参数变更 → 重申位置」
// 隔几十秒就来一次，于是拖完自己弹回原位（"拖不动"的真凶）。抽成纯函数是为了让门直接测它。
DeskPlace DeskPlaceClamp(DeskPlace p, NSSize card, NSRect visibleFrame);

// 从"看得见的卡片矩形"换算成角 + 距边摆位，并夹在可视区内。
// 四块组件的拖动落档、锁定时的位置记忆都走这一处，别再各算一遍。
DeskPlace DeskPlaceFromFrame(NSRect cardFrame, NSSize card, NSRect visibleFrame);

typedef NS_ENUM(NSInteger, DeskPlaceKind) {
    DeskPlaceKindPanel = 0,
    DeskPlaceKindMonitor,
    DeskPlaceKindVault,
    DeskPlaceKindCredits
};

// 三块的出厂锚点：系统状态右上、监视器右下、弹药库左下（左上留空）。
DeskPlace DeskPlaceDefaultForKind(DeskPlaceKind kind);

// 从屏幕指纹（currentScreenSignature）解析出每块屏上一档的 key。
// 例："1-1512x945+0+0|2-2560x1440+1512+0" → @{ @"1": @"1-1512x945", @"2": @"2-2560x1440" }
NSDictionary<NSString *, NSString *> *DeskPlaceKeysByDisplayFromSignature(NSString *signature);

@interface DeskPlaceStore : NSObject
+ (DeskPlace)defaultPlace;   // 通用兜底（老存档/测试）；组件出厂锚点用 DeskPlaceDefaultForKind
- (instancetype)initWithDictionary:(NSDictionary<NSString *, NSDictionary *> *)dict;
- (instancetype)initWithDictionary:(NSDictionary<NSString *, NSDictionary *> *)dict
                      defaultPlace:(DeskPlace)defaultPlace;
@property (nonatomic, readonly) DeskPlace fallbackPlace;
// 键格式："<displayID>-<宽>x<高>"，抽成类方法是为了让断言直接测它
+ (NSString *)keyWithDisplayID:(NSInteger)displayID width:(NSInteger)w height:(NSInteger)h;

- (instancetype)initWithDictionary:(NSDictionary<NSString *, NSDictionary *> *)dict;
@property (nonatomic, readonly) NSDictionary<NSString *, NSDictionary *> *dictionary;
@property (nonatomic, readonly) NSUInteger count;

- (NSString *)keyForScreen:(NSScreen *)screen;
- (DeskPlace)placeForKey:(NSString *)key;               // 只读，未命中返回默认，不写表
- (DeskPlace)placeForKey:(NSString *)key displayID:(NSNumber *)displayID;  // 带同屏兜底
- (DeskPlace)placeForScreen:(NSScreen *)screen;         // 屏幕版的查表 + 同屏兜底
- (DeskPlace)effectivePlaceForScreen:(NSScreen *)screen;  // 摆窗口用：待保存优先于存档
- (void)setPlace:(DeskPlace)p forKey:(NSString *)key;   // 写表；超上限淘汰最久没用的
// 把同一块屏的所有分辨率档位同步成这一套摆位（分辨率变化时用）
- (void)setPlace:(DeskPlace)p forKeysMatchingDisplayID:(NSString *)displayID;

// 待保存：拖动只改这里，点「保存」才落到上面的存档。
// 系统迁移窗口永远进不了这一层，所以不保存就不会污染存档。
- (void)setPending:(DeskPlace)p forKey:(NSString *)key;
- (NSUInteger)pendingCount;
- (BOOL)commitPending;                                  // 有东西可提交才返回 YES
- (void)discardPending;
@end
