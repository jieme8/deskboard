// Qoder（国内版）每日 100 Credits：PT（pt-…）兑换 job token 后直连官方接口。
// PT 只存在 DeskBoard 自己的凭据目录里，绝不读写 Qoder 客户端文件。
#import <Foundation/Foundation.h>
#import "credits.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DeskQoderPhase) {
    DeskQoderPhaseUnknown = 0,   // 还没有可显示的数据
    DeskQoderPhaseReady,         // PT 有效，接口已拉通
    DeskQoderPhaseNeedsAuth,     // PT 缺失 / 被撤销
    DeskQoderPhaseError,         // PT 有效，但上次同步失败
};

@interface DeskQoderCampaign : NSObject <NSCopying>
@property (nonatomic, copy) NSString *campaignId;
@property (nonatomic, copy) NSString *campaignKey;
@property (nonatomic, assign) double amount;
@property (nonatomic, copy) NSString *claimStatus;   // CLAIMABLE / CLAIMED / …
@property (nonatomic, assign) NSTimeInterval startAt;
@property (nonatomic, assign) NSTimeInterval endAt;
@property (nonatomic, readonly) BOOL claimable;
@property (nonatomic, readonly) BOOL claimed;
- (instancetype)initWithDictionary:(NSDictionary *)d;
- (NSDictionary *)dictionaryRepresentation;
@end

@interface DeskQoderSnapshot : NSObject <NSCopying>
@property (nonatomic, assign) DeskQoderPhase phase;
@property (nonatomic, assign) BOOL hasToken;
@property (nonatomic, assign) BOOL tokenInvalid;     // 兑换 / 鉴权被拒，需要换 PT
@property (nonatomic, assign) BOOL refreshing;
@property (nonatomic, assign) BOOL claiming;
@property (nonatomic, copy) NSString *nickname;
@property (nonatomic, copy) NSString *uid;
@property (nonatomic, copy) NSString *planTier;      // userType，如 personal_standard
@property (nonatomic, assign) double balance;        // <0 未知
@property (nonatomic, assign) double quotaTotal;     // <0 未知
@property (nonatomic, assign) double quotaUsed;      // <0 未知
@property (nonatomic, assign) BOOL hasStatus;
@property (nonatomic, copy) NSArray<DeskQoderCampaign *> *campaigns;
@property (nonatomic, assign) BOOL claimable;        // 本窗口有可领活动
@property (nonatomic, assign) BOOL claimed;          // 本窗口已领
@property (nonatomic, assign) double todayAmount;    // 本窗口活动额度；<0 未知
@property (nonatomic, assign) double claimedAmount;  // 本窗口已领到；<0 未知
@property (nonatomic, assign) NSTimeInterval windowStart;
@property (nonatomic, assign) NSTimeInterval windowEnd;
@property (nonatomic, assign) NSInteger campaignCount;
@property (nonatomic, assign) BOOL claimFailed;
@property (nonatomic, assign) NSTimeInterval lastSyncAt;
@property (nonatomic, copy, nullable) NSString *lastError;
@property (nonatomic, copy) NSString *windowKey;     // 本窗口标识（起始时间戳字符串）
- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)snapshotWithDictionary:(NSDictionary *)d;
@end

// —— 纯函数：解析、窗口、领取结果 ——
NSArray<DeskQoderCampaign *> *DeskQoderCampaignsFromJSON(NSDictionary *json);
BOOL DeskQoderApplyUserinfo(DeskQoderSnapshot *s, NSDictionary *json);
BOOL DeskQoderApplyQuota(DeskQoderSnapshot *s, NSDictionary *json, NSError *_Nullable *_Nullable err);
BOOL DeskQoderApplyCampaigns(DeskQoderSnapshot *s, NSDictionary *json, NSError *_Nullable *_Nullable err);
DeskCreditsClaimResult *DeskQoderClaimResultFromResponse(NSDictionary *json);
// 自动领取：PT 有效、已拿到活动表、本窗口可领、没在领、且已进入窗口
BOOL DeskQoderShouldAutoClaim(DeskQoderSnapshot *s, NSTimeInterval now);
NSString *DeskQoderPlanName(NSString *userType);
// 领取窗口结束日 = 今天 → “今日 10:00 刷新”；否则 “明日 10:00 刷新”。
NSString *DeskQoderRefreshText(NSTimeInterval windowEnd, NSTimeInterval now);
BOOL DeskQoderTokenLooksValid(NSString *token);

@interface DeskQoderCredits : NSObject
- (instancetype)initWithDirectory:(NSString *)directory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *directory;
@property (nonatomic, readonly, strong) DeskQoderSnapshot *snapshot;
@property (nonatomic, readonly) BOOL hasToken;
// 回调都在 provider 自己的串行队列上触发；UI 侧自己切主线程。
@property (nonatomic, copy, nullable) void (^onChange)(DeskQoderSnapshot *s);
@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);

- (BOOL)load;                 // 读 PT + 上次快照；不联网
- (void)start;                // 载入 + 首次刷新（异步）
- (void)tick;                 // 每分钟调度：过期就刷；窗口内可领就自动领
- (void)refreshAsync;
- (void)claimAsync;

// 设置 / 更换 PT；返回 NO = 格式不对
- (BOOL)setPersonalToken:(NSString *)pt error:(NSError *_Nullable *_Nullable)err;

// 同步口：命令行走这条
- (BOOL)refreshSyncWithBalance:(BOOL)withBalance error:(NSError *_Nullable *_Nullable)err;
- (DeskCreditsClaimResult *)claimSync:(NSError *_Nullable *_Nullable)err;

// 校验用：把测试 JSON 直接喂进来，不联网
- (BOOL)ingestUserinfoForVerify:(NSDictionary *)json error:(NSError *_Nullable *_Nullable)err;
- (BOOL)ingestQuotaForVerify:(NSDictionary *)json error:(NSError *_Nullable *_Nullable)err;
- (BOOL)ingestCampaignsForVerify:(NSDictionary *)json error:(NSError *_Nullable *_Nullable)err;
@end

NS_ASSUME_NONNULL_END
