// Trae（国内版）每日签到：只读本机 Trae CN 的 storage.json 登录态，直连官方 checkin_credits 接口。
// 刻意不续期：ExchangeToken 会轮换 refreshToken，把正开着的 IDE 踢下线。
#import <Foundation/Foundation.h>
#import "credits.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DeskTraePhase) {
    DeskTraePhaseUnknown = 0,   // 还没同步过
    DeskTraePhaseReady,         // 登录态可用，接口已拉通
    DeskTraePhaseNeedsAuth,     // 没登录态 / 令牌过期
    DeskTraePhaseError,         // 有登录态，但上次同步失败
};

@interface DeskTraeSnapshot : NSObject <NSCopying>
@property (nonatomic, assign) DeskTraePhase phase;
@property (nonatomic, assign) BOOL connected;        // storage.json 里有可用登录态
@property (nonatomic, copy)   NSString *uid;
@property (nonatomic, copy)   NSString *nickname;
@property (nonatomic, copy)   NSString *planTier;    // Free / PRO，来自 storage.json 的 entitlementInfo
@property (nonatomic, copy)   NSString *deviceId;
@property (nonatomic, assign) NSTimeInterval tokenExpiresAt;
@property (nonatomic, assign) double tokenSpanDays;  // 令牌签发到过期的天数，登录态条满格
@property (nonatomic, assign) BOOL hasStatus;
@property (nonatomic, assign) BOOL enabled;          // 服务端的签到活动开关
@property (nonatomic, assign) BOOL checkedIn;
@property (nonatomic, assign) double todayCredits;   // <0 未知
@property (nonatomic, assign) double extraCredits;   // 额外奖励，0 = 没有
@property (nonatomic, assign) double balance;        // 剩余积分，<0 未知
@property (nonatomic, assign) double consumed;
@property (nonatomic, assign) double total;
@property (nonatomic, assign) BOOL claiming;
@property (nonatomic, assign) BOOL claimFailed;
@property (nonatomic, assign) BOOL refreshing;
@property (nonatomic, assign) NSTimeInterval lastSyncAt;   // 0 = 从未同步
@property (nonatomic, copy, nullable) NSString *lastError;
@property (nonatomic, copy)   NSString *dayKey;      // UTC+8 的 yyyy-MM-dd
@property (nonatomic, readonly) double loginDays;    // 令牌还剩几天（0 = 已过期）
@property (nonatomic, readonly) BOOL loginWarn;      // 剩不到 7 天转琥珀

- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)snapshotWithDictionary:(NSDictionary *)d;
@end

// 解密 storage.json 里的 dGMFEAAA… 信封；测试可喂合成 fixture。
NSData *_Nullable DeskTraeDecryptStorageValue(NSString *base64, NSError *_Nullable *_Nullable err);
// 从 storage.json 解析 token / uid / nickname / deviceId / planTier，不联网。
NSDictionary *_Nullable DeskTraeStorageCredentials(NSDictionary *storage,
                                                   NSError *_Nullable *_Nullable err);
// 领取响应 → 统一结果（0 = 成功；9074/9095/9004 = 设备校验；含“已签” = 今日已签）
DeskCreditsClaimResult *DeskTraeClaimResultFromResponse(NSDictionary *json);
// 自动签到窗口：北京时间 00:05 后，活动开启、拿到状态、今天还没签、也不在领取中
BOOL DeskTraeShouldAutoClaim(DeskTraeSnapshot *s, NSTimeInterval now);
// storage.json 的默认搜索路径（Trae CN 优先）；第一个存在的。
NSString *_Nullable DeskTraeDefaultStoragePath(void);

@interface DeskTraeCredits : NSObject
- (instancetype)initWithStoragePath:(nullable NSString *)storagePath
                          statePath:(nullable NSString *)statePath NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

@property (nonatomic, readonly, copy) NSString *storagePath;
@property (nonatomic, readonly, strong) DeskTraeSnapshot *snapshot;
// 回调都发在 provider 自己的串行队列上；UI 侧自己切主线程。
@property (nonatomic, copy, nullable) void (^onChange)(DeskTraeSnapshot *s);
@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);

- (BOOL)load;                 // 读登录态 + 上次快照；不联网
- (void)start;                // 载入 + 首次刷新（异步）
- (void)tick;                 // 每分钟调度：过期就刷状态；过了 00:05 未签就自动领
- (void)refreshAsync;
- (void)claimAsync;

// 同步口：命令行走这条
- (BOOL)refreshSyncWithBalance:(BOOL)withBalance error:(NSError *_Nullable *_Nullable)err;
- (DeskCreditsClaimResult *)claimSync:(NSError *_Nullable *_Nullable)err;

// 校验用：把测试 JSON 直接喂进来，不联网
- (BOOL)ingestStatusForVerify:(NSDictionary *)json error:(NSError *_Nullable *_Nullable)err;
- (BOOL)ingestBalanceForVerify:(NSDictionary *)json error:(NSError *_Nullable *_Nullable)err;
@end

NS_ASSUME_NONNULL_END
