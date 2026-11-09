// WorkBuddy（腾讯 CodeBuddy 系）每日签到：官方浏览器授权拿 token，直连 billing/meter 接口。
// 本机客户端 5.6.2+ 把登录态加密且密钥只在客户端内存里，所以首选浏览器登录；
// 若本机 auth.info 仍是明文（老版本 / 自己导出的），也能只读导入。
#import <Foundation/Foundation.h>
#import "credits.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DeskWorkbuddyPhase) {
    DeskWorkbuddyPhaseUnknown = 0,
    DeskWorkbuddyPhaseReady,
    DeskWorkbuddyPhaseNeedsAuth,
    DeskWorkbuddyPhaseError,
};

@interface DeskWorkbuddySnapshot : NSObject <NSCopying>
@property (nonatomic, assign) DeskWorkbuddyPhase phase;
@property (nonatomic, assign) BOOL hasToken;
@property (nonatomic, assign) BOOL tokenExpired;
@property (nonatomic, assign) BOOL refreshing;
@property (nonatomic, assign) BOOL claiming;
@property (nonatomic, assign) BOOL claimFailed;
@property (nonatomic, assign) BOOL authorizing;
@property (nonatomic, copy) NSString *uid;
@property (nonatomic, copy) NSString *nickname;
@property (nonatomic, copy) NSString *host;          // www.codebuddy.cn / www.workbuddy.ai
@property (nonatomic, copy) NSString *source;        // browser / local
@property (nonatomic, assign) double balance;        // <0 未知
@property (nonatomic, assign) double quotaTotal;
@property (nonatomic, assign) double quotaUsed;
@property (nonatomic, assign) BOOL hasStatus;
@property (nonatomic, assign) BOOL checkedIn;
@property (nonatomic, assign) BOOL activityEnabled;  // 接口可用（有签到活动）
@property (nonatomic, assign) double streakDays;
@property (nonatomic, assign) double dailyCredit;    // 每日额度；<0 未知
@property (nonatomic, assign) double todayCredit;    // 今日已领；<0 未知
@property (nonatomic, assign) NSTimeInterval tokenExpiresAt;
@property (nonatomic, assign) NSTimeInterval lastSyncAt;
@property (nonatomic, copy) NSString *dayKey;
@property (nonatomic, copy, nullable) NSString *lastError;
- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)snapshotWithDictionary:(NSDictionary *)d;
@end

BOOL DeskWorkbuddyApplyStatus(DeskWorkbuddySnapshot *s, NSDictionary *json,
                              NSError *_Nullable *_Nullable err);
BOOL DeskWorkbuddyApplyResource(DeskWorkbuddySnapshot *s, NSDictionary *json,
                                NSError *_Nullable *_Nullable err);
DeskCreditsClaimResult *DeskWorkbuddyClaimResultFromResponse(NSDictionary *json);
BOOL DeskWorkbuddyShouldAutoClaim(DeskWorkbuddySnapshot *s, NSTimeInterval now);
NSString *DeskWorkbuddyPlanLine(DeskWorkbuddySnapshot *s);
// 本机明文登录态（5.6.2+ 是加密信封，返回 nil 并说明）
NSDictionary *_Nullable DeskWorkbuddyLocalSession(NSError *_Nullable *_Nullable err);

@interface DeskWorkbuddyCredits : NSObject
- (instancetype)initWithDirectory:(NSString *)directory NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

@property (nonatomic, readonly, copy) NSString *directory;
@property (nonatomic, readonly, strong) DeskWorkbuddySnapshot *snapshot;
@property (nonatomic, readonly) BOOL hasToken;
@property (nonatomic, copy, nullable) void (^onChange)(DeskWorkbuddySnapshot *s);
@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);

- (BOOL)load;
- (void)start;
- (void)tick;
- (void)refreshAsync;
- (void)claimAsync;

// 官方浏览器授权（桌面端同款 platform=WorkBuddy）：URL handler 负责打开登录页。
- (void)beginAuthorizationWithURLHandler:(void (^_Nullable)(NSString *url))urlHandler
                               completion:(void (^_Nullable)(BOOL ok, NSError *_Nullable err))completion;
- (void)cancelAuthorization;
// 尝试从本机 auth.info 导入（仅明文；加密时返回 NO 并提示用浏览器登录）
- (BOOL)importLocalSession:(NSError *_Nullable *_Nullable)err;
- (BOOL)clearCredentials:(NSError *_Nullable *_Nullable)err;

// 同步口：命令行走这条
- (BOOL)refreshSyncWithBalance:(BOOL)withBalance error:(NSError *_Nullable *_Nullable)err;
- (DeskCreditsClaimResult *)claimSync:(NSError *_Nullable *_Nullable)err;

// 校验用：把测试 JSON 直接喂进来，不联网
- (BOOL)ingestStatusForVerify:(NSDictionary *)json error:(NSError *_Nullable *_Nullable)err;
- (BOOL)ingestResourceForVerify:(NSDictionary *)json error:(NSError *_Nullable *_Nullable)err;
- (BOOL)ingestAuthStateForVerify:(NSDictionary *)json error:(NSError *_Nullable *_Nullable)err;
- (BOOL)ingestAuthTokenForVerify:(NSDictionary *)json error:(NSError *_Nullable *_Nullable)err;
@end

NS_ASSUME_NONNULL_END
