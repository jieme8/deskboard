// 每个"屏 × 点分辨率"各自一份的位置存档。
// 键 = CGDirectDisplayID + frame.size（点），同一块物理屏换缩放档位时 ID 不变、尺寸变，
// 所以两个档位各记各的；换到没见过的档位用默认锚点，切回老档位自动回到老位置。
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

typedef struct {
    NSInteger corner;   // 0 左上 1 右上 2 左下 3 右下
    CGFloat dx, dy;     // 距锚点角两条边的距离
} DeskPlace;

@interface DeskPlaceStore : NSObject
+ (DeskPlace)defaultPlace;
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

// 待保存：拖动只改这里，点「保存」才落到上面的存档。
// 系统迁移窗口永远进不了这一层，所以不保存就不会污染存档。
- (void)setPending:(DeskPlace)p forKey:(NSString *)key;
- (NSUInteger)pendingCount;
- (BOOL)commitPending;                                  // 有东西可提交才返回 YES
- (void)discardPending;
@end
