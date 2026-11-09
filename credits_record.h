// 签到中心本地纪录：每个平台独立的 90 天总积分峰值 + 最后一次成功签到/领取日期。
// 只存余额、日期和事件，不碰 token；每日桶按北京时间自然日切。
#import <Foundation/Foundation.h>
#import "credits.h"

NS_ASSUME_NONNULL_BEGIN

@interface DeskCreditsRecord : NSObject
@property (nonatomic, assign) double maxBalance;              // <0 = 没有记录
@property (nonatomic, copy, nullable) NSString *peakDayKey;   // yyyy-MM-dd
@property (nonatomic, assign) NSInteger coverageDays;         // 窗口内有采样的天数 0..90
@property (nonatomic, assign) BOOL newHigh;                   // 峰值日就是今天（历史 > 1 天）
@property (nonatomic, copy) NSArray<NSNumber *> *rail;        // 90 个 DeskCreditsRecordRailFlag
@property (nonatomic, copy, nullable) NSString *lastCheckInDayKey;
@property (nonatomic, assign) double lastCheckInAmount;       // <0 未知
@end

@interface DeskCreditsRecordStore : NSObject
- (instancetype)initWithPath:(NSString *)path NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);

- (BOOL)load;
- (BOOL)save;

// 能拿到稳定账号标识的平台在每次同步时喂一次；变了就清掉该平台旧纪录。
- (BOOL)setAccountKey:(nullable NSString *)accountKey forPlatform:(DeskCreditsPlatform)p;

// 余额采样：同一自然日多次采样取最大值；返回 YES = 磁盘内容有变化。
- (BOOL)samplePlatform:(DeskCreditsPlatform)p balance:(double)balance at:(NSTimeInterval)t;

// 成功签到/领取事件：只接受成功事件，失败不要调用；旧日期不会覆盖新日期。
- (BOOL)markCheckInPlatform:(DeskCreditsPlatform)p amount:(double)amount dayKey:(NSString *)dayKey;

- (DeskCreditsRecord *)recordForPlatform:(DeskCreditsPlatform)p at:(NSTimeInterval)t;
- (void)applyPlatform:(DeskCreditsPlatform)p toSlot:(DeskCreditsSlot *)slot at:(NSTimeInterval)t;
- (void)resetPlatform:(DeskCreditsPlatform)p;
@end

NS_ASSUME_NONNULL_END
