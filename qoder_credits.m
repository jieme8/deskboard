// Qoder（国内版）每日 100 Credits：PT（pt-…）兑换 job token 后直连官方接口。
// 端点与请求头对齐 Qoder 桌面端（Qoder App 0.2.x / CreditDaddy 验证过的同一条链路）：
//   POST /api/v1/jobToken/exchange          pt-… → jt-…（24h）
//   GET  /api/v1/userinfo                   昵称 / uid / 套餐
//   GET  /api/v2/quota/usage                额度（addOnQuota.remaining + userQuota.remaining）
//   GET  /sash/api/v1/me/campaigns?clientType=10   本窗口活动，CLAIMABLE = 可领
//   POST /sash/api/v1/me/campaigns/{id}/claim      领取（幂等）
// 国内版不校验设备风控头；国际版才需要 Cosy-MachineToken/Code/Type，这里不接。
#import "qoder_credits.h"

static NSString *const kQoderHost = @"https://openapi.qoder.com.cn";
static NSString *const kQoderUserAgent = @"Qoder";

static NSError *QoderError(DeskCreditsErrorCode code, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *QoderError(DeskCreditsErrorCode code, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:DeskCreditsErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static id QoderValue(id container, NSString *key) {
    return [container isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)container)[key] : nil;
}

static NSString *QoderString(id v) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return @"";
}

static double QoderNumber(id v, double fallback) {
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return fallback;
}

static NSInteger QoderInteger(id v, NSInteger fallback) {
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v integerValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v integerValue];
    return fallback;
}

static BOOL QoderBool(id v, BOOL fallback) {
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        if ([s isEqualToString:@"true"] || [s isEqualToString:@"yes"]) return YES;
        if ([s isEqualToString:@"false"] || [s isEqualToString:@"no"]) return NO;
    }
    return fallback;
}

BOOL DeskQoderTokenLooksValid(NSString *token) {
    if (![token isKindOfClass:[NSString class]]) return NO;
    NSString *t = [token stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [t hasPrefix:@"pt-"] && t.length >= 20;
}

NSString *DeskQoderPlanName(NSString *userType) {
    NSString *t = [userType lowercaseString];
    if ([t containsString:@"max"] || [t containsString:@"ultimate"]) return @"个人旗舰版";
    if ([t containsString:@"pro"]) return @"个人专业版";
    if ([t containsString:@"free"]) return @"免费版";
    if ([t containsString:@"standard"]) return @"个人标准版";
    if ([t containsString:@"trial"]) return @"试用版";
    return userType.length ? userType : @"个人版";
}

NSString *DeskQoderRefreshText(NSTimeInterval windowEnd, NSTimeInterval now) {
    if (windowEnd <= 0) return @"明日 10:00 刷新";
    NSString *end = DeskCreditsDayKey(windowEnd);
    NSString *today = DeskCreditsDayKey(now);
    return [end isEqualToString:today] ? @"今日 10:00 刷新" : @"明日 10:00 刷新";
}

#pragma mark - 活动

@implementation DeskQoderCampaign

- (instancetype)init {
    if ((self = [super init])) {
        _campaignId = @"";
        _campaignKey = @"";
        _claimStatus = @"";
        _amount = -1;
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    if ((self = [self init])) {
        _campaignId = [QoderString(d[@"campaignId"]) copy];
        _campaignKey = [QoderString(d[@"campaignKey"]) copy];
        _claimStatus = [QoderString(d[@"claimStatus"]) copy];
        _amount = QoderNumber(QoderValue(d[@"benefit"], @"amount"), -1);
        _startAt = QoderNumber(d[@"startAt"], 0);
        _endAt = QoderNumber(d[@"endAt"], 0);
    }
    return self;
}

- (BOOL)claimable {
    if (![_claimStatus isEqualToString:@"CLAIMABLE"]) return NO;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (_startAt > 0 && now < _startAt) return NO;
    if (_endAt > 0 && now >= _endAt) return NO;
    return YES;
}

- (BOOL)claimed {
    if (![_claimStatus isEqualToString:@"CLAIMED"]) return NO;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (_endAt > 0 && now >= _endAt) return NO;
    return YES;
}

- (id)copyWithZone:(NSZone *)zone {
    DeskQoderCampaign *c = [[DeskQoderCampaign allocWithZone:zone] init];
    c.campaignId = _campaignId;
    c.campaignKey = _campaignKey;
    c.amount = _amount;
    c.claimStatus = _claimStatus;
    c.startAt = _startAt;
    c.endAt = _endAt;
    return c;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"campaignId"] = _campaignId ?: @"";
    d[@"campaignKey"] = _campaignKey ?: @"";
    d[@"amount"] = @(_amount);
    d[@"claimStatus"] = _claimStatus ?: @"";
    d[@"startAt"] = @(_startAt);
    d[@"endAt"] = @(_endAt);
    return d;
}

@end

NSArray<DeskQoderCampaign *> *DeskQoderCampaignsFromJSON(NSDictionary *json) {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    id raw = json[@"campaigns"];
    if (![raw isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray<DeskQoderCampaign *> *out = [NSMutableArray array];
    for (id item in (NSArray *)raw) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if (![QoderString(((NSDictionary *)item)[@"actionType"]) isEqualToString:@"CLAIM_BENEFIT"]) continue;
        DeskQoderCampaign *c = [[DeskQoderCampaign alloc] initWithDictionary:item];
        if (c.campaignId.length) [out addObject:c];
    }
    return out;
}

#pragma mark - 快照

@implementation DeskQoderSnapshot

- (instancetype)init {
    if ((self = [super init])) {
        _nickname = @"";
        _uid = @"";
        _planTier = @"";
        _balance = -1;
        _quotaTotal = -1;
        _quotaUsed = -1;
        _campaigns = @[];
        _todayAmount = -1;
        _claimedAmount = -1;
        _windowKey = @"";
    }
    return self;
}


- (id)copyWithZone:(NSZone *)zone {
    DeskQoderSnapshot *c = [[DeskQoderSnapshot allocWithZone:zone] init];
    c.phase = _phase;
    c.hasToken = _hasToken;
    c.tokenInvalid = _tokenInvalid;
    c.refreshing = _refreshing;
    c.claiming = _claiming;
    c.nickname = _nickname;
    c.uid = _uid;
    c.planTier = _planTier;
    c.balance = _balance;
    c.quotaTotal = _quotaTotal;
    c.quotaUsed = _quotaUsed;
    c.hasStatus = _hasStatus;
    c.campaigns = _campaigns;
    c.claimable = _claimable;
    c.claimed = _claimed;
    c.todayAmount = _todayAmount;
    c.claimedAmount = _claimedAmount;
    c.windowStart = _windowStart;
    c.windowEnd = _windowEnd;
    c.campaignCount = _campaignCount;
    c.claimFailed = _claimFailed;
    c.lastSyncAt = _lastSyncAt;
    c.lastError = _lastError;
    c.windowKey = _windowKey;
    return c;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *cs = [NSMutableArray array];
    for (DeskQoderCampaign *c in _campaigns) [cs addObject:[c dictionaryRepresentation]];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"phase"] = @(_phase);
    d[@"hasToken"] = @(_hasToken);
    d[@"tokenInvalid"] = @(_tokenInvalid);
    d[@"nickname"] = _nickname ?: @"";
    d[@"uid"] = _uid ?: @"";
    d[@"plan"] = _planTier ?: @"";
    d[@"balance"] = @(_balance);
    d[@"quotaTotal"] = @(_quotaTotal);
    d[@"quotaUsed"] = @(_quotaUsed);
    d[@"hasStatus"] = @(_hasStatus);
    d[@"campaigns"] = cs;
    d[@"claimable"] = @(_claimable);
    d[@"claimed"] = @(_claimed);
    d[@"today"] = @(_todayAmount);
    d[@"claimedAmount"] = @(_claimedAmount);
    d[@"windowStart"] = @(_windowStart);
    d[@"windowEnd"] = @(_windowEnd);
    d[@"campaignCount"] = @(_campaignCount);
    d[@"claimFailed"] = @(_claimFailed);
    d[@"lastSyncAt"] = @(_lastSyncAt);
    d[@"windowKey"] = _windowKey ?: @"";
    if (_lastError) d[@"error"] = _lastError;
    return d;
}

+ (instancetype)snapshotWithDictionary:(NSDictionary *)d {
    DeskQoderSnapshot *s = [DeskQoderSnapshot new];
    if (![d isKindOfClass:[NSDictionary class]]) return s;
    s.phase = (DeskQoderPhase)QoderInteger(d[@"phase"], 0);
    s.hasToken = QoderBool(d[@"hasToken"], NO);
    s.tokenInvalid = QoderBool(d[@"tokenInvalid"], NO);
    s.nickname = QoderString(d[@"nickname"]);
    s.uid = QoderString(d[@"uid"]);
    s.planTier = QoderString(d[@"plan"]);
    s.balance = QoderNumber(d[@"balance"], -1);
    s.quotaTotal = QoderNumber(d[@"quotaTotal"], -1);
    s.quotaUsed = QoderNumber(d[@"quotaUsed"], -1);
    s.hasStatus = QoderBool(d[@"hasStatus"], NO);
    NSMutableArray<DeskQoderCampaign *> *cs = [NSMutableArray array];
    id raw = d[@"campaigns"];
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)raw) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            DeskQoderCampaign *c = [[DeskQoderCampaign alloc] initWithDictionary:item];
            if (c.campaignId.length) [cs addObject:c];
        }
    }
    s.campaigns = cs;
    s.claimable = QoderBool(d[@"claimable"], NO);
    s.claimed = QoderBool(d[@"claimed"], NO);
    s.todayAmount = QoderNumber(d[@"today"], -1);
    s.claimedAmount = QoderNumber(d[@"claimedAmount"], -1);
    s.windowStart = QoderNumber(d[@"windowStart"], 0);
    s.windowEnd = QoderNumber(d[@"windowEnd"], 0);
    s.campaignCount = QoderInteger(d[@"campaignCount"], (NSInteger)cs.count);
    s.claimFailed = QoderBool(d[@"claimFailed"], NO);
    s.lastSyncAt = QoderNumber(d[@"lastSyncAt"], 0);
    s.windowKey = QoderString(d[@"windowKey"]);
    s.lastError = QoderString(d[@"error"]);
    return s;
}

@end

#pragma mark - 解析

BOOL DeskQoderApplyUserinfo(DeskQoderSnapshot *s, NSDictionary *json) {
    if (![json isKindOfClass:[NSDictionary class]]) return NO;
    NSString *name = QoderString(json[@"name"]);
    if (name.length == 0) name = QoderString(json[@"username"]);
    s.nickname = name;
    NSString *uid = QoderString(json[@"id"]);
    if (uid.length == 0) uid = QoderString(json[@"userId"]);
    s.uid = uid;
    NSString *type = QoderString(json[@"userType"]);
    if (type.length == 0) type = QoderString(json[@"user_type"]);
    if (type.length) s.planTier = type;
    return YES;
}

BOOL DeskQoderApplyQuota(DeskQoderSnapshot *s, NSDictionary *json, NSError **err) {
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (err) *err = QoderError(DeskCreditsErrorJSON, @"额度接口不是 JSON 对象");
        return NO;
    }
    double userRemain = QoderNumber(QoderValue(json[@"userQuota"], @"remaining"), -1);
    double addRemain = QoderNumber(QoderValue(json[@"addOnQuota"], @"remaining"), -1);
    if (userRemain < 0 && addRemain < 0) {
        if (err) *err = QoderError(DeskCreditsErrorJSON, @"额度接口没有 remaining 字段");
        return NO;
    }
    s.balance = MAX(0.0, userRemain) + MAX(0.0, addRemain);
    double userTotal = QoderNumber(QoderValue(json[@"userQuota"], @"total"), -1);
    double addTotal = QoderNumber(QoderValue(json[@"addOnQuota"], @"total"), -1);
    double userUsed = QoderNumber(QoderValue(json[@"userQuota"], @"used"), -1);
    double addUsed = QoderNumber(QoderValue(json[@"addOnQuota"], @"used"), -1);
    s.quotaTotal = (userTotal < 0 && addTotal < 0) ? -1 : MAX(0.0, userTotal) + MAX(0.0, addTotal);
    s.quotaUsed = (userUsed < 0 && addUsed < 0) ? -1 : MAX(0.0, userUsed) + MAX(0.0, addUsed);
    NSString *type = QoderString(json[@"userType"]);
    if (type.length) s.planTier = type;
    return YES;
}

BOOL DeskQoderApplyCampaigns(DeskQoderSnapshot *s, NSDictionary *json, NSError **err) {
    NSArray<DeskQoderCampaign *> *list = DeskQoderCampaignsFromJSON(json);
    if (!list) {
        if (err) *err = QoderError(DeskCreditsErrorJSON, @"活动接口缺少 campaigns 数组");
        return NO;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    s.campaigns = list;
    s.hasStatus = YES;
    s.campaignCount = (NSInteger)list.count;
    s.claimable = NO;
    s.claimed = NO;
    s.todayAmount = -1;
    s.claimedAmount = -1;
    s.windowStart = 0;
    s.windowEnd = 0;
    for (DeskQoderCampaign *c in list) {
        BOOL inWindow = (c.startAt <= 0 || now >= c.startAt)
            && (c.endAt <= 0 || now < c.endAt);
        if (!inWindow) continue;
        if (c.claimable) {
            s.claimable = YES;
            s.todayAmount = c.amount;
            s.windowStart = c.startAt;
            s.windowEnd = c.endAt;
            s.claimFailed = NO;
        } else if (c.claimed) {
            s.claimed = YES;
            s.claimedAmount = c.amount;
            s.todayAmount = c.amount;
            s.windowStart = c.startAt;
            s.windowEnd = c.endAt;
        }
    }
    if (s.windowStart > 0) {
        s.windowKey = [NSString stringWithFormat:@"%.0f", s.windowStart];
    } else {
        s.windowKey = DeskCreditsDayKey(now);
    }
    return YES;
}

DeskCreditsClaimResult *DeskQoderClaimResultFromResponse(NSDictionary *json) {
    DeskCreditsClaimResult *r = [DeskCreditsClaimResult new];
    r.outcome = DeskCreditsClaimOutcomeFailed;
    r.points = -1;
    r.dayNo = 0;
    if (![json isKindOfClass:[NSDictionary class]]) {
        r.message = @"领取返回不是 JSON 对象";
        return r;
    }
    NSDictionary *data = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : json;
    NSString *status = QoderString(data[@"status"]);
    if (status.length == 0) status = QoderString(data[@"claimStatus"]);
    if (status.length == 0) status = QoderString(json[@"status"]);
    double amount = QoderNumber(QoderValue(QoderValue(data, @"benefit"), @"amount"), -1);
    if (amount < 0) amount = QoderNumber(QoderValue(QoderValue(json, @"benefit"), @"amount"), -1);
    BOOL replayed = QoderBool(data[@"replayed"], NO) || QoderBool(json[@"replayed"], NO);
    if ([status isEqualToString:@"CLAIMED"]) {
        r.outcome = DeskCreditsClaimOutcomeClaimed;
        r.points = amount;
        r.message = replayed ? @"幂等重复（本窗口已领）" : @"领取成功";
        return r;
    }
    NSString *message = QoderString(data[@"message"]);
    if (message.length == 0) message = QoderString(json[@"message"]);
    NSString *lower = message.lowercaseString;
    if ([status isEqualToString:@"ALREADY_CLAIMED"] || [lower containsString:@"already"]
        || [message containsString:@"已领"] || [message containsString:@"重复"]) {
        r.outcome = DeskCreditsClaimOutcomeAlready;
        r.points = amount;
        r.message = message.length ? message : @"本窗口已领";
        return r;
    }
    NSString *code = QoderString(data[@"code"]);
    if (code.length == 0) code = QoderString(json[@"code"]);
    r.message = message.length
        ? (code.length ? [NSString stringWithFormat:@"%@ %@", code, message] : message)
        : (code.length ? code : @"领取失败");
    return r;
}

BOOL DeskQoderShouldAutoClaim(DeskQoderSnapshot *s, NSTimeInterval now) {
    if (!s.hasToken || s.tokenInvalid || s.phase == DeskQoderPhaseNeedsAuth) return NO;
    if (!s.hasStatus || !s.claimable || s.claimed || s.claiming) return NO;
    if (s.windowStart > 0 && now < s.windowStart) return NO;
    if (s.windowEnd > 0 && now >= s.windowEnd) return NO;
    return DeskCreditsAutoClaimWindowOpen(now);
}

#pragma mark - Provider

@implementation DeskQoderCredits {
    dispatch_queue_t _queue;
    DeskQoderSnapshot *_snapshot;
    NSString *_statePath;
    NSString *_pt;
    NSString *_jt;
    NSTimeInterval _jtExpiresAt;
    NSTimeInterval _lastClaimAttempt;
    NSString *_lastClaimWindow;
    NSInteger _claimAttempts;
}

- (instancetype)init {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    return [self initWithDirectory:[base stringByAppendingPathComponent:@"DeskBoard/Credits"]];
}

- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.hujie.deskboard.qoder", DISPATCH_QUEUE_SERIAL);
        _snapshot = [DeskQoderSnapshot new];
        _directory = [(directory.length ? directory : NSTemporaryDirectory()) copy];
        _statePath = [_directory stringByAppendingPathComponent:@"qoder.json"];
        _pt = @"";
        _jt = @"";
        _lastClaimWindow = @"";
    }
    return self;
}

- (DeskQoderSnapshot *)snapshot {
    @synchronized (self) { return _snapshot; }
}

- (BOOL)hasToken {
    @synchronized (self) { return _pt.length > 0; }
}

- (void)note:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    void (^handler)(NSString *) = _onLog;
    if (handler) handler(msg);
}

- (void)publish:(DeskQoderSnapshot *)s {
    DeskQoderSnapshot *copy = [s copy];
    @synchronized (self) { _snapshot = copy; }
    if (_onChange) _onChange(copy);
    [self persist:copy];
}

- (void)persist:(DeskQoderSnapshot *)s {
    if (_statePath.length == 0) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"schemaVersion"] = @1;
    d[@"pt"] = _pt ?: @"";
    d[@"snapshot"] = [s dictionaryRepresentation];
    NSData *data = [NSJSONSerialization dataWithJSONObject:d
                                                   options:NSJSONWritingPrettyPrinted error:NULL];
    if (!data) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[_statePath stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES attributes:nil error:NULL];
    [data writeToFile:_statePath
              options:NSDataWritingAtomic
                error:NULL];
    [fm setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:_statePath error:NULL];
}

- (BOOL)load {
    NSData *raw = _statePath.length ? [NSData dataWithContentsOfFile:_statePath] : nil;
    NSDictionary *store = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL] : nil;
    if (![store isKindOfClass:[NSDictionary class]]) store = @{};
    NSString *pt = QoderString(store[@"pt"]);
    DeskQoderSnapshot *s = [DeskQoderSnapshot snapshotWithDictionary:
                            [store[@"snapshot"] isKindOfClass:[NSDictionary class]]
                                ? store[@"snapshot"] : @{}];
    @synchronized (self) {
        _pt = [pt copy] ?: @"";
        _jt = @"";
        _jtExpiresAt = 0;
    }
    s.hasToken = _pt.length > 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    BOOL windowOver = s.windowEnd > 0 && now >= s.windowEnd;
    if (windowOver) {
        // 跨窗口：昨天的「已领」不能冒充今天
        s.hasStatus = NO;
        s.claimable = NO;
        s.claimed = NO;
        s.claimFailed = NO;
        s.todayAmount = -1;
        s.claimedAmount = -1;
        s.windowStart = 0;
        s.windowEnd = 0;
        s.windowKey = @"";
    }
    if (s.hasToken) {
        s.phase = s.hasStatus ? DeskQoderPhaseReady : DeskQoderPhaseUnknown;
        s.lastError = nil;
        if (!s.tokenInvalid && s.phase == DeskQoderPhaseNeedsAuth) s.phase = DeskQoderPhaseUnknown;
    } else {
        s.phase = DeskQoderPhaseNeedsAuth;
        s.tokenInvalid = NO;
        s.lastError = @"未设置 Qoder PT 令牌（菜单 › 签到中心 › Qoder › 设置 PT 令牌…）";
    }
    [self publish:s];
    if (s.hasToken) {
        [self note:@"PT 已载入（%@，余额 %@）",
              s.nickname.length ? s.nickname : @"Qoder",
              s.balance >= 0 ? DeskCreditsFormatPoints(s.balance) : @"—"];
    } else {
        [self note:@"未设置 PT 令牌"];
    }
    return s.hasToken;
}

#pragma mark 网络

- (NSDictionary *)requestPath:(NSString *)path
                       method:(NSString *)method
                         body:(NSDictionary *)body
                     exchange:(BOOL)exchange
                        error:(NSError **)err {
    NSURL *url = [NSURL URLWithString:[kQoderHost stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    req.timeoutInterval = 20.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (exchange) {
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:@"qodercli/1.0.0" forHTTPHeaderField:@"User-Agent"];
        [req setValue:@"1.0.0" forHTTPHeaderField:@"Cosy-Version"];
        [req setValue:@"5" forHTTPHeaderField:@"Cosy-ClientType"];
    } else {
        NSString *jt = nil;
        @synchronized (self) { jt = _jt; }
        [req setValue:[@"Bearer " stringByAppendingString:jt ?: @""] forHTTPHeaderField:@"Authorization"];
        [req setValue:@"10" forHTTPHeaderField:@"Cosy-ClientType"];
        [req setValue:@"0.3.3" forHTTPHeaderField:@"Cosy-Version"];
        [req setValue:@"macos" forHTTPHeaderField:@"Cosy-MachineOS"];
        [req setValue:kQoderUserAgent forHTTPHeaderField:@"User-Agent"];
    }
    if (body) {
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    } else if ([method isEqualToString:@"POST"]) {
        req.HTTPBody = [NSData data];
    }

    __block NSData *payload = nil;
    __block NSInteger status = 0;
    __block NSError *netErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
            payload = data;
            netErr = e;
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) status = ((NSHTTPURLResponse *)resp).statusCode;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC));
    if (netErr) {
        if (err) *err = QoderError(DeskCreditsErrorNetwork, @"网络失败：%@", netErr.localizedDescription);
        return nil;
    }
    id obj = payload ? [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL] : nil;
    NSDictionary *json = [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
    if (status == 401 || status == 403) {
        NSString *msg = QoderString(json[@"message"]);
        if (err) *err = QoderError(DeskCreditsErrorAuth, @"HTTP %ld%@", (long)status,
                                   msg.length ? [@"：" stringByAppendingString:msg] : @"");
        return nil;
    }
    if (status < 200 || status >= 300) {
        NSString *msg = QoderString(json[@"message"]);
        if (err) *err = QoderError(DeskCreditsErrorHTTP, @"HTTP %ld%@", (long)status,
                                   msg.length ? [@"：" stringByAppendingString:msg] : @"");
        return nil;
    }
    if (!json) {
        if (err) *err = QoderError(DeskCreditsErrorJSON, @"接口返回不是 JSON 对象");
        return nil;
    }
    return json;
}

- (BOOL)ensureJobToken:(NSError **)err {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *jt = nil, *pt = nil;
    @synchronized (self) {
        jt = _jt;
        pt = _pt;
        if (jt.length && _jtExpiresAt - now > 300) return YES;
    }
    if (pt.length == 0) {
        if (err) *err = QoderError(DeskCreditsErrorAuth, @"没有 PT 令牌");
        return NO;
    }
    NSDictionary *json = [self requestPath:@"/api/v1/jobToken/exchange"
                                    method:@"POST"
                                      body:@{@"personal_token": pt}
                                  exchange:YES
                                     error:err];
    if (!json) return NO;
    NSString *token = QoderString(json[@"token"]);
    if (token.length == 0) {
        if (err) *err = QoderError(DeskCreditsErrorAuth, @"PT 兑换没有返回 job token");
        return NO;
    }
    NSTimeInterval exp = 0;
    NSString *expText = QoderString(json[@"expires_at"]);
    if (expText.length) {
        NSISO8601DateFormatter *f = [[NSISO8601DateFormatter alloc] init];
        f.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        NSDate *d = [f dateFromString:expText];
        if (d) exp = d.timeIntervalSince1970;
    }
    if (exp <= now) exp = now + 1800;
    @synchronized (self) {
        _jt = [token copy];
        _jtExpiresAt = exp;
    }
    return YES;
}

- (NSDictionary *)apiPath:(NSString *)path method:(NSString *)method error:(NSError **)err {
    if (![self ensureJobToken:err]) return nil;
    return [self requestPath:path method:method body:nil exchange:NO error:err];
}

#pragma mark 刷新

- (BOOL)applyAuthFailure:(NSError *)e to:(DeskQoderSnapshot *)s {
    if (!e || e.code != DeskCreditsErrorAuth) return NO;
    s.tokenInvalid = YES;
    s.phase = DeskQoderPhaseNeedsAuth;
    s.hasStatus = NO;
    s.claimable = NO;
    s.claimed = NO;
    return YES;
}

- (BOOL)refreshSyncWithBalance:(BOOL)withBalance error:(NSError **)err {
    DeskQoderSnapshot *s = [self.snapshot copy];
    NSString *pt = nil;
    @synchronized (self) { pt = _pt; }
    s.hasToken = pt.length > 0;
    if (!s.hasToken) {
        s.phase = DeskQoderPhaseNeedsAuth;
        s.tokenInvalid = NO;
        s.lastError = @"未设置 Qoder PT 令牌";
        [self publish:s];
        if (err) *err = QoderError(DeskCreditsErrorMissing, @"%@", s.lastError);
        return NO;
    }

    s.refreshing = YES;
    [self publish:s];

    NSError *e = nil;
    NSDictionary *userinfo = [self apiPath:@"/api/v1/userinfo" method:@"GET" error:&e];
    if (!userinfo) {
        s.refreshing = NO;
        [self applyAuthFailure:e to:s];
        if (!s.tokenInvalid) s.phase = DeskQoderPhaseError;
        s.lastError = e.localizedDescription ?: @"用户信息刷新失败";
        [self publish:s];
        if (err) *err = e;
        return NO;
    }
    DeskQoderApplyUserinfo(s, userinfo);

    if (withBalance) {
        NSError *qe = nil;
        NSDictionary *quota = [self apiPath:@"/api/v2/quota/usage" method:@"GET" error:&qe];
        if (quota) {
            NSError *pe = nil;
            if (!DeskQoderApplyQuota(s, quota, &pe)) {
                [self note:@"额度刷新失败：%@", pe.localizedDescription ?: @"字段缺失"];
            }
        } else {
            [self note:@"额度刷新失败：%@", qe.localizedDescription ?: @"未知原因"];
        }
    }

    NSError *ce = nil;
    NSDictionary *campaigns = [self apiPath:@"/sash/api/v1/me/campaigns?clientType=10"
                                     method:@"GET" error:&ce];
    if (!campaigns) {
        s.refreshing = NO;
        [self applyAuthFailure:ce to:s];
        if (!s.tokenInvalid) s.phase = DeskQoderPhaseError;
        s.lastError = ce.localizedDescription ?: @"活动刷新失败";
        [self publish:s];
        if (err) *err = ce;
        return NO;
    }
    NSError *ae = nil;
    if (!DeskQoderApplyCampaigns(s, campaigns, &ae)) {
        s.refreshing = NO;
        s.phase = DeskQoderPhaseError;
        s.lastError = ae.localizedDescription ?: @"活动解析失败";
        [self publish:s];
        if (err) *err = ae;
        return NO;
    }

    s.refreshing = NO;
    s.phase = DeskQoderPhaseReady;
    s.tokenInvalid = NO;
    s.lastError = nil;
    s.lastSyncAt = [NSDate date].timeIntervalSince1970;
    [self publish:s];
    [self note:@"状态：%@ · 余额 %@ Credits · 本窗口活动 %ld 项",
          s.claimable ? [NSString stringWithFormat:@"待领 +%@", DeskCreditsFormatPoints(s.todayAmount)]
                      : (s.claimed ? [NSString stringWithFormat:@"已领 +%@", DeskCreditsFormatPoints(s.claimedAmount)]
                                   : @"无活动"),
          s.balance >= 0 ? DeskCreditsFormatPoints(s.balance) : @"—",
          (long)s.campaignCount];
    return YES;
}

#pragma mark 领取

- (DeskCreditsClaimResult *)claimSync:(NSError **)err {
    DeskCreditsClaimResult *r = [DeskCreditsClaimResult new];
    r.outcome = DeskCreditsClaimOutcomeFailed;
    r.points = -1;
    r.dayNo = 0;

    DeskQoderSnapshot *s = [self.snapshot copy];
    NSString *pt = nil;
    @synchronized (self) { pt = _pt; }
    if (pt.length == 0) {
        r.outcome = DeskCreditsClaimOutcomeNotAuthorized;
        r.message = @"未设置 Qoder PT 令牌";
        if (err) *err = QoderError(DeskCreditsErrorMissing, @"%@", r.message);
        return r;
    }
    if (!s.hasStatus || (!s.claimable && !s.claimed)) {
        NSError *re = nil;
        [self refreshSyncWithBalance:YES error:&re];
        s = [self.snapshot copy];
        if (!s.hasStatus) {
            r.message = re.localizedDescription ?: @"拿不到活动状态";
            if (err) *err = re;
            return r;
        }
    }
    if (s.claimed) {
        r.outcome = DeskCreditsClaimOutcomeAlready;
        r.points = s.claimedAmount;
        r.message = @"本窗口已领";
        return r;
    }
    NSMutableArray<DeskQoderCampaign *> *todo = [NSMutableArray array];
    for (DeskQoderCampaign *c in s.campaigns) if (c.claimable) [todo addObject:c];
    if (todo.count == 0) {
        r.outcome = DeskCreditsClaimOutcomeAlready;
        r.message = @"本窗口没有可领活动";
        return r;
    }

    s.claiming = YES;
    s.claimFailed = NO;
    [self publish:s];

    double total = 0;
    NSInteger claimed = 0, already = 0;
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    BOOL authFailed = NO;
    for (DeskQoderCampaign *c in todo) {
        NSError *ce = nil;
        NSDictionary *json = [self apiPath:[NSString stringWithFormat:@"/sash/api/v1/me/campaigns/%@/claim",
                                            c.campaignId]
                                    method:@"POST" error:&ce];
        s = [self.snapshot copy];
        if (!json) {
            if (ce.code == DeskCreditsErrorAuth) authFailed = YES;
            [errors addObject:ce.localizedDescription ?: @"领取请求失败"];
            continue;
        }
        DeskCreditsClaimResult *one = DeskQoderClaimResultFromResponse(json);
        if (one.outcome == DeskCreditsClaimOutcomeClaimed) {
            claimed++;
            total += one.points >= 0 ? one.points : (c.amount >= 0 ? c.amount : 0);
        } else if (one.outcome == DeskCreditsClaimOutcomeAlready) {
            already++;
        } else {
            [errors addObject:one.message ?: @"领取失败"];
        }
    }

    s = [self.snapshot copy];
    s.claiming = NO;
    if (claimed > 0) {
        s.claimed = YES;
        s.claimable = NO;
        s.claimedAmount = total;
        s.todayAmount = total;
        s.claimFailed = NO;
        s.phase = DeskQoderPhaseReady;
        s.lastError = nil;
        s.lastSyncAt = [NSDate date].timeIntervalSince1970;
        [self publish:s];
        r.outcome = DeskCreditsClaimOutcomeClaimed;
        r.points = total;
        r.message = [NSString stringWithFormat:@"+%@ Credits", DeskCreditsFormatPoints(total)];
        [self note:@"领取成功：+%@ Credits（余额刷新中）", DeskCreditsFormatPoints(total)];
        [self refreshSyncWithBalance:YES error:NULL];
        return r;
    }
    if (already == todo.count) {
        s.claimed = YES;
        s.claimable = NO;
        s.claimFailed = NO;
        [self publish:s];
        r.outcome = DeskCreditsClaimOutcomeAlready;
        r.message = @"本窗口已领";
        [self note:@"本窗口已领（接口认定重复）"];
        return r;
    }
    s.claimFailed = YES;
    s.phase = authFailed ? DeskQoderPhaseNeedsAuth : DeskQoderPhaseError;
    s.tokenInvalid = authFailed;
    s.lastError = errors.count ? [errors componentsJoinedByString:@"；"] : @"领取失败";
    [self publish:s];
    r.message = s.lastError;
    [self note:@"领取失败：%@", s.lastError];
    if (err) *err = QoderError(authFailed ? DeskCreditsErrorAuth : DeskCreditsErrorAPI, @"%@", s.lastError);
    return r;
}

#pragma mark 调度

- (BOOL)claimThrottled:(NSTimeInterval)now window:(NSString *)windowKey {
    if (![_lastClaimWindow isEqualToString:windowKey ?: @""]) {
        _lastClaimWindow = [windowKey copy] ?: @"";
        _claimAttempts = 0;
        _lastClaimAttempt = 0;
    }
    if (_claimAttempts >= 3) return YES;
    if (_lastClaimAttempt > 0 && now - _lastClaimAttempt < 1800) return YES;
    _lastClaimAttempt = now;
    _claimAttempts++;
    return NO;
}

- (void)tickOnQueue {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *pt = nil;
    @synchronized (self) { pt = _pt; }
    DeskQoderSnapshot *s = [self.snapshot copy];

    if (pt.length == 0) {
        if (s.phase != DeskQoderPhaseNeedsAuth || s.hasToken) {
            s.hasToken = NO;
            s.phase = DeskQoderPhaseNeedsAuth;
            s.lastError = @"未设置 Qoder PT 令牌";
            [self publish:s];
        }
        return;
    }
    if (!s.hasToken) {
        s.hasToken = YES;
        s.phase = DeskQoderPhaseUnknown;
        s.lastError = nil;
        [self publish:s];
        s = [self.snapshot copy];
    }
    if (s.windowEnd > 0 && now >= s.windowEnd) {
        s.hasStatus = NO;
        s.claimable = NO;
        s.claimed = NO;
        s.claimFailed = NO;
        s.todayAmount = -1;
        s.claimedAmount = -1;
        s.windowStart = 0;
        s.windowEnd = 0;
        s.windowKey = @"";
        [self publish:s];
        s = [self.snapshot copy];
    }
    if (!s.hasStatus || s.phase == DeskQoderPhaseError || s.tokenInvalid
        || now - s.lastSyncAt > 600) {
        [self refreshSyncWithBalance:YES error:NULL];
        s = [self.snapshot copy];
    }
    if (!DeskQoderShouldAutoClaim(s, now)) return;
    if ([self claimThrottled:now window:s.windowKey]) return;
    [self note:@"自动领取：本窗口还有可领活动"];
    [self claimSync:NULL];
}

- (void)start {
    dispatch_async(_queue, ^{
        [self load];
        [self refreshSyncWithBalance:YES error:NULL];
        [self tickOnQueue];
    });
}

- (void)tick {
    dispatch_async(_queue, ^{ [self tickOnQueue]; });
}

- (void)refreshAsync {
    dispatch_async(_queue, ^{ [self refreshSyncWithBalance:YES error:NULL]; });
}

- (void)claimAsync {
    dispatch_async(_queue, ^{
        [self refreshSyncWithBalance:YES error:NULL];
        [self claimSync:NULL];
    });
}

#pragma mark PT

- (BOOL)setPersonalToken:(NSString *)pt error:(NSError **)err {
    NSString *t = [(pt ?: @"") stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!DeskQoderTokenLooksValid(t)) {
        if (err) *err = QoderError(DeskCreditsErrorAuth, @"PT 令牌格式不对（应以 pt- 开头）");
        return NO;
    }
    DeskQoderSnapshot *s = [self.snapshot copy];
    @synchronized (self) {
        _pt = [t copy];
        _jt = @"";
        _jtExpiresAt = 0;
    }
    _lastClaimWindow = @"";
    _claimAttempts = 0;
    _lastClaimAttempt = 0;
    s.hasToken = YES;
    s.tokenInvalid = NO;
    s.phase = s.hasStatus ? DeskQoderPhaseReady : DeskQoderPhaseUnknown;
    s.claimFailed = NO;
    s.lastError = nil;
    [self publish:s];
    [self note:@"PT 已设置（%lu 位，不落日志）", (unsigned long)t.length];
    [self refreshAsync];
    return YES;
}


#pragma mark 校验口

- (BOOL)ingestUserinfoForVerify:(NSDictionary *)json error:(NSError **)err {
    DeskQoderSnapshot *s = [self.snapshot copy];
    s.hasToken = YES;
    if (!DeskQoderApplyUserinfo(s, json)) {
        if (err) *err = QoderError(DeskCreditsErrorJSON, @"用户信息不是 JSON 对象");
        return NO;
    }
    s.phase = DeskQoderPhaseReady;
    [self publish:s];
    return YES;
}

- (BOOL)ingestQuotaForVerify:(NSDictionary *)json error:(NSError **)err {
    DeskQoderSnapshot *s = [self.snapshot copy];
    s.hasToken = YES;
    if (!DeskQoderApplyQuota(s, json, err)) return NO;
    [self publish:s];
    return YES;
}

- (BOOL)ingestCampaignsForVerify:(NSDictionary *)json error:(NSError **)err {
    DeskQoderSnapshot *s = [self.snapshot copy];
    s.hasToken = YES;
    s.tokenInvalid = NO;
    if (!DeskQoderApplyCampaigns(s, json, err)) return NO;
    s.phase = DeskQoderPhaseReady;
    s.lastSyncAt = [NSDate date].timeIntervalSince1970;
    s.lastError = nil;
    [self publish:s];
    return YES;
}

@end
