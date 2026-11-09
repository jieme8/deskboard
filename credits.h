// MiniMax Code 每日签到：独立 OAuth 设备码登录 + 状态/余额/领取。
// 凭据只存在自己的目录里，绝不读写 MiniMax Code 桌面客户端的 ~/.minimax。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const DeskCreditsErrorDomain;
typedef NS_ENUM(NSInteger, DeskCreditsErrorCode) {
    DeskCreditsErrorNetwork = 1,
    DeskCreditsErrorHTTP,
    DeskCreditsErrorJSON,
    DeskCreditsErrorAPI,
    DeskCreditsErrorAuth,
    DeskCreditsErrorMissing,
};

typedef NS_ENUM(NSInteger, DeskCreditsPhase) {
    DeskCreditsPhaseUnknown = 0,   // 还没有可显示的数据
    DeskCreditsPhaseIdle,          // 今天可领
    DeskCreditsPhaseCheckedIn,     // 今天已领
    DeskCreditsPhaseError,         // 没有数据且上次刷新失败
};

// 一轮 7 天里的某一天。status: 3 = 已领，1 = 未领。
@interface DeskCreditsDay : NSObject <NSCopying>
@property (nonatomic, assign) NSInteger dayNo;
@property (nonatomic, assign) NSInteger status;
@property (nonatomic, assign) double points;        // <0 = 接口没给
@property (nonatomic, assign) double bonusPoints;
@property (nonatomic, assign) BOOL isToday;
@property (nonatomic, readonly) BOOL claimed;
@property (nonatomic, readonly) double total;       // points + bonus；未知返回 -1
- (instancetype)initWithDictionary:(NSDictionary *)d;
- (NSDictionary *)dictionaryRepresentation;
@end

// 一次发布后不再修改；provider 每次都换一个新对象，主线程读指针是安全的。
@interface DeskCreditsSnapshot : NSObject <NSCopying>
@property (nonatomic, assign) DeskCreditsPhase phase;
@property (nonatomic, assign) BOOL authorized;       // 有凭据文件
@property (nonatomic, assign) BOOL needsAuth;        // 凭据已失效，要重新授权
@property (nonatomic, assign) BOOL authorizing;      // 正在等浏览器授权
@property (nonatomic, assign) BOOL refreshing;
@property (nonatomic, assign) BOOL claiming;
@property (nonatomic, assign) BOOL hasStatus;        // 至少成功拉到过一次签到表
@property (nonatomic, copy)   NSArray<DeskCreditsDay *> *days;
@property (nonatomic, assign) BOOL hasToday;
@property (nonatomic, assign) NSInteger todayDayNo;
@property (nonatomic, assign) BOOL todayChecked;
@property (nonatomic, assign) double todayPoints;    // 今天实得/可得；<0 未知
@property (nonatomic, assign) double balance;        // <0 未知（不是 0）
@property (nonatomic, assign) double freeBalance;
@property (nonatomic, assign) double purchasedBalance;
@property (nonatomic, copy, nullable) NSString *planTier;
@property (nonatomic, assign) NSTimeInterval lastSyncAt;   // 0 = 从未同步
@property (nonatomic, copy, nullable) NSString *lastError;
@property (nonatomic, assign) BOOL stale;            // 有旧数据，但最近一次刷新失败
@property (nonatomic, assign) BOOL claimFailed;      // 上一次领取失败（不是“已签”）
@property (nonatomic, copy) NSString *dayKey;        // UTC+8 的 yyyy-MM-dd

- (nullable DeskCreditsDay *)today;
- (nullable DeskCreditsDay *)nextDay;
- (double)nextReward;        // 今天未签 = 今天奖励；已签 = 下一天奖励；<0 未知
- (NSInteger)cycleLength;    // 签到表有几天
- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)snapshotWithDictionary:(NSDictionary *)d;
@end

// —— 四平台签到中心：MiniMax 已接入，其余三个先按真实接入方式占位 ——
typedef NS_ENUM(NSInteger, DeskCreditsPlatform) {
    DeskCreditsPlatformMiniMax = 0,
    DeskCreditsPlatformTrae,
    DeskCreditsPlatformWorkBuddy,
    DeskCreditsPlatformQoder,
};

typedef NS_ENUM(NSInteger, DeskCreditsSlotKind) {
    DeskCreditsSlotKindUnconnected = 0,   // 还没接入（占位）
    DeskCreditsSlotKindSigned,            // 今日已签
    DeskCreditsSlotKindPending,           // 今日待签
    DeskCreditsSlotKindClaimed,           // 活动已领（Qoder）
    DeskCreditsSlotKindNeedsAuth,         // 未授权 / 登录过期
    DeskCreditsSlotKindError,             // 领取失败 / 接口异常
    DeskCreditsSlotKindWorking,           // 同步中 / 领取中
};

// 每个平台的主状态视觉不同：MiniMax 轮次点、Trae 登录态条、
// WorkBuddy 连签点、Qoder 活动牌 + 设备点。
typedef NS_ENUM(NSInteger, DeskCreditsVisualKind) {
    DeskCreditsVisualNone = 0,
    DeskCreditsVisualCycle,
    DeskCreditsVisualLoginLife,
    DeskCreditsVisualStreak,
    DeskCreditsVisualClaim,
};

// 90 天记录尺的一格：按位组合。没有采样 = 0；峰值日/今天可以同时成立。
typedef NS_OPTIONS(NSInteger, DeskCreditsRecordRailFlag) {
    DeskCreditsRecordRailMissing = 0,
    DeskCreditsRecordRailSampled = 1 << 0,
    DeskCreditsRecordRailPeak = 1 << 1,
    DeskCreditsRecordRailToday = 1 << 2,
};

@interface DeskCreditsSlot : NSObject <NSCopying>
@property (nonatomic, assign) DeskCreditsPlatform platform;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *unit;              // 积分 / Credits
@property (nonatomic, assign) BOOL connected;
@property (nonatomic, assign) DeskCreditsSlotKind kind;
@property (nonatomic, assign) double balance;            // <0 未知
@property (nonatomic, copy) NSString *planLine;          // 副行：套餐 / 版本 / 接入方式
@property (nonatomic, copy) NSString *statusText;        // 今日结果
@property (nonatomic, copy) NSString *footerText;        // 平台专属底部提示
@property (nonatomic, assign) DeskCreditsVisualKind visual;
// cycleStates: 0 未签 / 1 已签 / 2 今天已签 / 3 今天待签
@property (nonatomic, copy) NSArray<NSNumber *> *cycleStates;
@property (nonatomic, copy) NSArray<NSNumber *> *cycleBonuses;
@property (nonatomic, assign) NSInteger streakCount;
@property (nonatomic, assign) NSInteger streakTotal;
@property (nonatomic, assign) double loginDays;
@property (nonatomic, assign) double loginTotalDays;
@property (nonatomic, assign) BOOL loginWarn;
@property (nonatomic, assign) NSInteger claimCount;      // <0 未知 / 占位
@property (nonatomic, assign) BOOL deviceReady;
@property (nonatomic, assign) NSTimeInterval lastSyncAt;
@property (nonatomic, copy) NSString *authActionTitle;   // 菜单里的接入动作
@property (nonatomic, copy) NSString *hint;              // 平台约束提示
@property (nonatomic, copy) NSArray<NSString *> *actionTitles;

// —— 90 天总积分纪录 + 最后一次签到事件（main 用本地记录填充） ——
@property (nonatomic, assign) double recordMax;          // <0 = 没有记录 / 未知
@property (nonatomic, copy, nullable) NSString *recordPeakDayKey; // yyyy-MM-dd
@property (nonatomic, assign) NSInteger recordCoverageDays;       // 0..90 有采样的天数
@property (nonatomic, assign) BOOL recordNewHigh;        // 峰值日就是今天（且历史 > 1 天）
@property (nonatomic, copy) NSArray<NSNumber *> *recordRail;      // 90 个 DeskCreditsRecordRailFlag
@property (nonatomic, copy, nullable) NSString *lastCheckInDayKey; // yyyy-MM-dd
@property (nonatomic, assign) double lastCheckInAmount;  // <0 未知
@end

@class DeskTraeSnapshot;
@class DeskQoderSnapshot;
@class DeskWorkbuddySnapshot;

@interface DeskCreditsCenterSnapshot : NSObject
@property (nonatomic, copy) NSArray<DeskCreditsSlot *> *slots;
@property (nonatomic, strong) DeskCreditsSnapshot *minimax;
@property (nonatomic, strong, nullable) DeskTraeSnapshot *trae;
@property (nonatomic, strong, nullable) DeskQoderSnapshot *qoder;
@property (nonatomic, strong, nullable) DeskWorkbuddySnapshot *workbuddy;
@property (nonatomic, assign) NSInteger connectedCount;
@property (nonatomic, assign) NSInteger doneCount;       // 已签 + 已领
@property (nonatomic, assign) NSInteger pendingCount;
@property (nonatomic, assign) NSInteger errorCount;      // 需授权 + 失败
@property (nonatomic, assign) NSTimeInterval oldestSyncAt;
+ (instancetype)centerWithMiniMax:(DeskCreditsSnapshot *)m;
+ (instancetype)centerWithMiniMax:(DeskCreditsSnapshot *)m
                             trae:(nullable DeskTraeSnapshot *)t
                            qoder:(nullable DeskQoderSnapshot *)q
                        workbuddy:(nullable DeskWorkbuddySnapshot *)w;
// 设计预览/断言用：MiniMax 保持真实数据，另外三槽填满示例状态
+ (instancetype)previewFullCenterWithMiniMax:(DeskCreditsSnapshot *)m;
- (DeskCreditsSlot *)slotForPlatform:(DeskCreditsPlatform)p;
@end

typedef NS_ENUM(NSInteger, DeskCreditsClaimOutcome) {
    DeskCreditsClaimOutcomeUnknown = 0,
    DeskCreditsClaimOutcomeClaimed,
    DeskCreditsClaimOutcomeAlready,
    DeskCreditsClaimOutcomeNotAuthorized,
    DeskCreditsClaimOutcomeFailed,
};

@interface DeskCreditsClaimResult : NSObject
@property (nonatomic, assign) DeskCreditsClaimOutcome outcome;
@property (nonatomic, assign) double points;    // <0 未知
@property (nonatomic, assign) NSInteger dayNo;
@property (nonatomic, copy, nullable) NSString *message;
@end

// —— 纯函数：绘制、命令行和校验共用同一套口径 ——
NSString *DeskCreditsFormatPoints(double v);          // -1/NaN → "—"
NSString *DeskCreditsFormatSignedPoints(double v);    // "+1,000" / "—"
NSString *DeskCreditsDayKey(NSTimeInterval t);        // UTC+8 的日期
NSTimeInterval DeskCreditsDayStart(NSTimeInterval t); // UTC+8 当天 00:00
// 四个平台统一的自动签到窗口：北京时间每天 10:05 之后（到当天 23:59:59）
BOOL DeskCreditsAutoClaimWindowOpen(NSTimeInterval t);
// 每小时补签检查：北京时间每分钟 :05 之后，且这一小时还没跑过
BOOL DeskCreditsHourlyCheckDue(NSTimeInterval t, NSInteger lastHour);
NSInteger DeskCreditsHourOfDay(NSTimeInterval t);   // 北京时间 0..23
NSString *DeskCreditsStatusText(DeskCreditsSnapshot *s);
NSString *DeskCreditsNextText(DeskCreditsSnapshot *s);
NSString *DeskCreditsCycleText(DeskCreditsSnapshot *s);
NSString *DeskCreditsSyncText(NSTimeInterval lastSyncAt, NSTimeInterval now);
BOOL DeskCreditsSyncIsStale(NSTimeInterval lastSyncAt, NSTimeInterval now);
NSString *DeskCreditsPhaseText(DeskCreditsSnapshot *s);
NSString *DeskCreditsPKCEVerifier(void);
NSString *DeskCreditsPKCEChallenge(NSString *verifier);

// 解析：失败返回 nil / NO，并在 err 里给出可读原因。
DeskCreditsSnapshot *_Nullable DeskCreditsSnapshotByApplyingStatus(DeskCreditsSnapshot *base,
                                                                  NSDictionary *json,
                                                                  NSError *_Nullable *_Nullable err);
BOOL DeskCreditsApplyMembership(DeskCreditsSnapshot *s, NSDictionary *json,
                                NSError *_Nullable *_Nullable err);
DeskCreditsClaimResult *DeskCreditsClaimResultFromResponse(NSDictionary *json,
                                                           NSError *_Nullable *_Nullable err);

@interface DeskCreditsProvider : NSObject
- (instancetype)initWithDirectory:(NSString *)directory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *directory;
// 只读快照；主线程读到的永远是一个完整对象（provider 每次换新对象，不原地改）
@property (nonatomic, readonly, strong) DeskCreditsSnapshot *snapshot;
@property (nonatomic, readonly) BOOL authorized;
@property (nonatomic, readonly) BOOL needsAuth;

// 回调都在 provider 自己的串行队列上触发；UI 侧自己切主线程。
@property (nonatomic, copy, nullable) void (^onChange)(DeskCreditsSnapshot *s);
@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);

- (BOOL)load;                    // 读凭据与上次快照；可重复调用
- (void)start;                   // 载入 + 首次刷新（异步）
- (void)tick;                    // 每日调度：按需刷新/领取（异步）
- (void)refreshAsync;            // 状态 + 余额
- (void)refreshBalanceAsync;
- (void)claimAsync;              // 手动“立即签到”

// 设备码授权：URL handler 在拿到授权页时调用一次，completion 在流程结束时调用。
- (void)beginAuthorizationWithURLHandler:(void (^_Nullable)(NSString *url))urlHandler
                               completion:(void (^_Nullable)(BOOL ok, NSError *_Nullable err))completion;
- (void)cancelAuthorization;

// 同步口：命令行走这条；不要在 provider 的异步队列之外并发调用。
- (BOOL)refreshSyncWithBalance:(BOOL)withBalance error:(NSError *_Nullable *_Nullable)err;
- (BOOL)refreshBalanceSync:(NSError *_Nullable *_Nullable)err;
- (DeskCreditsClaimResult *)claimSync:(NSError *_Nullable *_Nullable)err;

// 校验/预览用：把测试 JSON 直接喂进来，不联网
- (void)ingestStatusForVerify:(NSDictionary *)json error:(NSError *_Nullable *_Nullable)err;
@end

NS_ASSUME_NONNULL_END
