// WorkBuddy 每日签到：官方浏览器授权（platform=WorkBuddy）+ billing/meter 接口。
//   POST {host}/v2/plugin/auth/state?platform=WorkBuddy   拿 state / authUrl
//   GET  {host}/v2/plugin/auth/token?state=…              code 11217 = 等待
//   GET  {host}/v2/plugin/login/account?state=…           账号信息（best-effort）
//   POST {host}/v2/billing/meter/checkin-activity-status  连签 / 今日是否已签 / 每日额度
//   POST {host}/v2/billing/meter/daily-checkin            签到（10001 / “已签到” = 今日已签）
//   POST {host}/v2/billing/meter/get-user-resource        积分包
// 5.6.2+ 客户端的 auth.info 是加密信封，密钥只在客户端内存里，所以这里优先浏览器登录。
#import "workbuddy_credits.h"

static NSString *const kWorkbuddyUserAgent = @"CLI/2.108.1 CodeBuddy/2.108.1";
static NSString *const kWorkbuddyCNHost = @"www.codebuddy.cn";
static NSString *const kWorkbuddyIntlHost = @"www.workbuddy.ai";

static NSError *WbError(DeskCreditsErrorCode code, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *WbError(DeskCreditsErrorCode code, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:DeskCreditsErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static id WbValue(id container, NSString *key) {
    return [container isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)container)[key] : nil;
}

static NSString *WbString(id v) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return @"";
}

static double WbNumber(id v, double fallback) {
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return fallback;
}

static NSInteger WbInteger(id v, NSInteger fallback) {
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v integerValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v integerValue];
    return fallback;
}

static BOOL WbBool(id v, BOOL fallback) {
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        if ([s isEqualToString:@"true"] || [s isEqualToString:@"yes"]) return YES;
        if ([s isEqualToString:@"false"] || [s isEqualToString:@"no"]) return NO;
    }
    return fallback;
}

static NSString *WbNil(NSString *s) { return s.length ? s : nil; }

static NSString *WbHostFromToken(NSString *token, NSString *fallback) {
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count < 2) return fallback;
    NSString *p = [parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    p = [p stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (p.length % 4) p = [p stringByAppendingString:@"="];
    NSData *d = [[NSData alloc] initWithBase64EncodedString:p options:0];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    if (![obj isKindOfClass:[NSDictionary class]]) return fallback;
    NSString *iss = WbString(((NSDictionary *)obj)[@"iss"]);
    NSURL *u = iss.length ? [NSURL URLWithString:iss] : nil;
    NSString *host = u.host;
    if (host.length == 0) return fallback;
    if ([host hasSuffix:@"codebuddy.cn"] || [host hasSuffix:@"workbuddy.cn"]
        || [host isEqualToString:@"copilot.tencent.com"]) return host;
    if ([host hasSuffix:@"codebuddy.ai"] || [host hasSuffix:@"workbuddy.ai"]
        || [host hasSuffix:@"workbuddy.cc"]) return host;
    return fallback;
}

// 兼容毫秒 / 秒时间戳与 ISO / "yyyy-MM-dd HH:mm:ss" 字符串
static NSTimeInterval WbTime(id v) {
    if (v == nil || v == [NSNull null]) return 0;
    if ([v isKindOfClass:[NSNumber class]]) {
        double n = [v doubleValue];
        return n > 1e12 ? n / 1000.0 : (n > 1e9 ? n : 0);
    }
    NSString *s = WbString(v);
    if (s.length == 0) return 0;
    NSTimeInterval n = s.doubleValue;
    if (n > 1e9) return n > 1e12 ? n / 1000.0 : n;
    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSDate *d = [iso dateFromString:s];
    if (!d) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        df.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
        d = [df dateFromString:s];
    }
    return d ? d.timeIntervalSince1970 : 0;
}

#pragma mark - 快照

@implementation DeskWorkbuddySnapshot

- (instancetype)init {
    if ((self = [super init])) {
        _uid = @"";
        _nickname = @"";
        _host = kWorkbuddyCNHost;
        _source = @"";
        _balance = -1;
        _quotaTotal = -1;
        _quotaUsed = -1;
        _dailyCredit = -1;
        _todayCredit = -1;
        _dayKey = @"";
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    DeskWorkbuddySnapshot *c = [[DeskWorkbuddySnapshot allocWithZone:zone] init];
    c.phase = _phase;
    c.hasToken = _hasToken;
    c.tokenExpired = _tokenExpired;
    c.refreshing = _refreshing;
    c.claiming = _claiming;
    c.claimFailed = _claimFailed;
    c.authorizing = _authorizing;
    c.uid = _uid;
    c.nickname = _nickname;
    c.host = _host;
    c.source = _source;
    c.balance = _balance;
    c.quotaTotal = _quotaTotal;
    c.quotaUsed = _quotaUsed;
    c.hasStatus = _hasStatus;
    c.checkedIn = _checkedIn;
    c.activityEnabled = _activityEnabled;
    c.streakDays = _streakDays;
    c.dailyCredit = _dailyCredit;
    c.todayCredit = _todayCredit;
    c.tokenExpiresAt = _tokenExpiresAt;
    c.lastSyncAt = _lastSyncAt;
    c.dayKey = _dayKey;
    c.lastError = _lastError;
    return c;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"phase"] = @(_phase);
    d[@"hasToken"] = @(_hasToken);
    d[@"tokenExpired"] = @(_tokenExpired);
    d[@"uid"] = _uid ?: @"";
    d[@"nickname"] = _nickname ?: @"";
    d[@"host"] = _host ?: kWorkbuddyCNHost;
    d[@"source"] = _source ?: @"";
    d[@"balance"] = @(_balance);
    d[@"quotaTotal"] = @(_quotaTotal);
    d[@"quotaUsed"] = @(_quotaUsed);
    d[@"hasStatus"] = @(_hasStatus);
    d[@"checkedIn"] = @(_checkedIn);
    d[@"enabled"] = @(_activityEnabled);
    d[@"streak"] = @(_streakDays);
    d[@"daily"] = @(_dailyCredit);
    d[@"today"] = @(_todayCredit);
    d[@"tokenExpiresAt"] = @(_tokenExpiresAt);
    d[@"lastSyncAt"] = @(_lastSyncAt);
    d[@"dayKey"] = _dayKey ?: @"";
    if (_lastError) d[@"error"] = _lastError;
    return d;
}

+ (instancetype)snapshotWithDictionary:(NSDictionary *)d {
    DeskWorkbuddySnapshot *s = [DeskWorkbuddySnapshot new];
    if (![d isKindOfClass:[NSDictionary class]]) return s;
    s.phase = (DeskWorkbuddyPhase)WbInteger(d[@"phase"], 0);
    s.hasToken = WbBool(d[@"hasToken"], NO);
    s.tokenExpired = WbBool(d[@"tokenExpired"], NO);
    s.uid = WbString(d[@"uid"]);
    s.nickname = WbString(d[@"nickname"]);
    s.host = WbString(d[@"host"]);
    if (s.host.length == 0) s.host = kWorkbuddyCNHost;
    s.source = WbString(d[@"source"]);
    s.balance = WbNumber(d[@"balance"], -1);
    s.quotaTotal = WbNumber(d[@"quotaTotal"], -1);
    s.quotaUsed = WbNumber(d[@"quotaUsed"], -1);
    s.hasStatus = WbBool(d[@"hasStatus"], NO);
    s.checkedIn = WbBool(d[@"checkedIn"], NO);
    s.activityEnabled = WbBool(d[@"enabled"], NO);
    s.streakDays = WbNumber(d[@"streak"], 0);
    s.dailyCredit = WbNumber(d[@"daily"], -1);
    s.todayCredit = WbNumber(d[@"today"], -1);
    s.tokenExpiresAt = WbNumber(d[@"tokenExpiresAt"], 0);
    s.lastSyncAt = WbNumber(d[@"lastSyncAt"], 0);
    s.dayKey = WbString(d[@"dayKey"]);
    s.lastError = WbNil(WbString(d[@"error"]));
    return s;
}

@end

NSString *DeskWorkbuddyPlanLine(DeskWorkbuddySnapshot *s) {
    BOOL intl = [s.host containsString:@".ai"] || [s.host hasSuffix:@"workbuddy.cc"];
    NSString *region = intl ? @"国际版" : @"国内版";
    NSString *how = [s.source isEqualToString:@"local"] ? @"本机登录态" : @"浏览器登录";
    return [NSString stringWithFormat:@"%@ · %@", region, how];
}

#pragma mark - 解析

BOOL DeskWorkbuddyApplyStatus(DeskWorkbuddySnapshot *s, NSDictionary *json, NSError **err) {
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (err) *err = WbError(DeskCreditsErrorJSON, @"签到状态不是 JSON 对象");
        return NO;
    }
    NSInteger code = WbInteger(json[@"code"], -1);
    if (code != 0) {
        if (err) *err = WbError(DeskCreditsErrorAPI, @"签到状态失败：%ld %@",
                                (long)code, WbString(json[@"msg"]));
        return NO;
    }
    NSDictionary *data = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : @{};
    s.hasStatus = YES;
    s.activityEnabled = YES;
    s.checkedIn = WbBool(data[@"today_checked_in"], WbBool(data[@"checked_in"], NO));
    s.streakDays = WbNumber(data[@"streak_days"], 0);
    s.dailyCredit = WbNumber(data[@"daily_credit"], -1);
    s.todayCredit = WbNumber(data[@"today_credit"], s.checkedIn ? s.dailyCredit : -1);
    s.dayKey = DeskCreditsDayKey([NSDate date].timeIntervalSince1970);
    return YES;
}


BOOL DeskWorkbuddyApplyResource(DeskWorkbuddySnapshot *s, NSDictionary *json, NSError **err) {
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (err) *err = WbError(DeskCreditsErrorJSON, @"积分接口不是 JSON 对象");
        return NO;
    }
    NSInteger code = WbInteger(json[@"code"], -1);
    if (code != 0) {
        if (err) *err = WbError(DeskCreditsErrorAPI, @"积分查询失败：%ld %@",
                                (long)code, WbString(json[@"msg"]));
        return NO;
    }
    id accounts = WbValue(WbValue(WbValue(json[@"data"], @"Response"), @"Data"), @"Accounts");
    if (![accounts isKindOfClass:[NSArray class]]) {
        if (err) *err = WbError(DeskCreditsErrorJSON, @"积分接口缺少 Accounts");
        return NO;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    double total = 0, used = 0, remain = 0;
    BOOL any = NO;
    for (id item in (NSArray *)accounts) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *a = item;
        NSTimeInterval cycleEnd = WbTime(a[@"CycleEndTime"]);
        NSTimeInterval deductEnd = WbTime(a[@"DeductionEndTime"]);
        BOOL recurring = cycleEnd > 0 && deductEnd > 0 && (deductEnd - cycleEnd) > 2 * 86400.0;
        double t = WbNumber(a[recurring ? @"CycleCapacitySizePrecise" : @"CapacitySizePrecise"],
                            WbNumber(a[recurring ? @"CycleCapacitySize" : @"CapacitySize"], 0));
        if (t <= 0) continue;
        NSTimeInterval expire = recurring ? cycleEnd : (deductEnd > 0 ? deductEnd : cycleEnd);
        if (expire > 0 && expire <= now) continue;
        double u = WbNumber(a[recurring ? @"CycleCapacityUsedPrecise" : @"CapacityUsedPrecise"],
                            WbNumber(a[recurring ? @"CycleCapacityUsed" : @"CapacityUsed"], 0));
        double r = WbNumber(a[recurring ? @"CycleCapacityRemainPrecise" : @"CapacityRemainPrecise"],
                            WbNumber(a[recurring ? @"CycleCapacityRemain" : @"CapacityRemain"], 0));
        total += t;
        used += u;
        remain += r;
        any = YES;
    }
    s.balance = any ? MAX(0.0, remain) : -1;
    s.quotaTotal = any ? total : -1;
    s.quotaUsed = any ? used : -1;
    return YES;
}

DeskCreditsClaimResult *DeskWorkbuddyClaimResultFromResponse(NSDictionary *json) {
    DeskCreditsClaimResult *r = [DeskCreditsClaimResult new];
    r.outcome = DeskCreditsClaimOutcomeFailed;
    r.points = -1;
    r.dayNo = 0;
    if (![json isKindOfClass:[NSDictionary class]]) {
        r.message = @"领取返回不是 JSON 对象";
        return r;
    }
    NSInteger code = WbInteger(json[@"code"], -1);
    NSString *msg = WbString(json[@"msg"]);
    if (msg.length == 0) msg = WbString(json[@"message"]);
    if (code == 0) {
        NSDictionary *data = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : @{};
        double amount = WbNumber(data[@"credit"],
                                 WbNumber(data[@"today_credit"], WbNumber(data[@"daily_credit"], -1)));
        r.outcome = DeskCreditsClaimOutcomeClaimed;
        r.points = amount;
        r.message = @"签到成功";
        return r;
    }
    BOOL already = code == 10001
        || [msg containsString:@"已签到"] || [msg containsString:@"签到过"]
        || [msg containsString:@"重复"] || [msg.lowercaseString containsString:@"already"];
    if (already) {
        r.outcome = DeskCreditsClaimOutcomeAlready;
        r.message = msg.length ? msg : @"今日已签";
        return r;
    }
    r.message = msg.length ? [NSString stringWithFormat:@"%ld %@", (long)code, msg]
                           : [NSString stringWithFormat:@"领取失败（code %ld）", (long)code];
    return r;
}

BOOL DeskWorkbuddyShouldAutoClaim(DeskWorkbuddySnapshot *s, NSTimeInterval now) {
    if (!s.hasToken || s.tokenExpired || s.phase == DeskWorkbuddyPhaseNeedsAuth) return NO;
    if (!s.hasStatus || s.checkedIn || s.claiming) return NO;
    return DeskCreditsAutoClaimWindowOpen(now);
}

#pragma mark - 本机登录态

static NSString *WbLocalAuthPath(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    return [[base stringByAppendingPathComponent:@"CodeBuddyExtension/Data/Public/auth"]
            stringByAppendingPathComponent:@"workbuddy-desktop.info"];
}

NSDictionary *DeskWorkbuddyLocalSession(NSError **err) {
    NSString *path = WbLocalAuthPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        if (err) *err = WbError(DeskCreditsErrorMissing, @"没找到 WorkBuddy 本机登录态");
        return nil;
    }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (err) *err = WbError(DeskCreditsErrorJSON, @"本机登录态解析失败");
        return nil;
    }
    NSDictionary *auth = WbValue(obj, @"auth");
    id token = WbValue(auth, @"accessToken");
    if ([token isKindOfClass:[NSDictionary class]]) {
        if (err) *err = WbError(DeskCreditsErrorAuth,
            @"WorkBuddy 客户端把登录态加密了（5.6.2+），请用浏览器登录");
        return nil;
    }
    NSString *accessToken = WbString(token);
    if (accessToken.length == 0) {
        if (err) *err = WbError(DeskCreditsErrorAuth, @"本机登录态里没有 accessToken");
        return nil;
    }
    NSDictionary *account = WbValue(obj, @"account");
    NSString *uid = WbString(WbValue(account, @"uid"));
    id nick = WbValue(account, @"nickname");
    NSString *nickname = [nick isKindOfClass:[NSString class]] ? nick : @"";
    NSString *domain = WbString(WbValue(auth, @"domain"));
    NSTimeInterval expires = WbTime(WbValue(auth, @"expiresAt"));
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"accessToken"] = accessToken;
    NSString *refresh = WbString(WbValue(auth, @"refreshToken"));
    if (refresh.length) out[@"refreshToken"] = refresh;
    if (uid.length) out[@"uid"] = uid;
    if (nickname.length) out[@"nickname"] = nickname;
    out[@"host"] = WbHostFromToken(accessToken, domain.length ? domain : kWorkbuddyCNHost);
    out[@"expiresAt"] = @(expires);
    out[@"source"] = @"local";
    return out;
}

#pragma mark - Provider

@implementation DeskWorkbuddyCredits {
    dispatch_queue_t _queue;
    DeskWorkbuddySnapshot *_snapshot;
    NSString *_statePath;
    NSString *_accessToken, *_refreshToken, *_uid, *_nickname, *_host, *_source;
    NSTimeInterval _tokenExpiresAt, _refreshExpiresAt;
    NSTimeInterval _lastLoadModification;
    NSTimeInterval _lastClaimAttempt;
    NSString *_lastClaimDay;
    NSInteger _claimAttempts;

    BOOL _authorizing;
    BOOL _authHasToken;
    NSString *_authState;
    NSString *_authAccessToken, *_authRefreshToken, *_authUid, *_authNickname, *_authHost;
    NSTimeInterval _authTokenExpiresAt, _authRefreshExpiresAt, _authDeadline;
    BOOL (^_authCompletion)(BOOL, NSError *);
    void (^_authURLHandler)(NSString *);
}

- (instancetype)init {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    return [self initWithDirectory:[base stringByAppendingPathComponent:@"DeskBoard/Credits"]];
}

- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.hujie.deskboard.workbuddy", DISPATCH_QUEUE_SERIAL);
        _snapshot = [DeskWorkbuddySnapshot new];
        _directory = [(directory.length ? directory : NSTemporaryDirectory()) copy];
        _statePath = [_directory stringByAppendingPathComponent:@"workbuddy.json"];
        _accessToken = @"";
        _refreshToken = @"";
        _uid = @"";
        _nickname = @"";
        _host = kWorkbuddyCNHost;
        _source = @"";
        _authState = @"";
        _lastClaimDay = @"";
    }
    return self;
}

- (DeskWorkbuddySnapshot *)snapshot {
    @synchronized (self) { return _snapshot; }
}

- (BOOL)hasToken {
    @synchronized (self) { return _accessToken.length > 0; }
}

- (void)note:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    void (^handler)(NSString *) = _onLog;
    if (handler) handler(msg);
}

- (void)publish:(DeskWorkbuddySnapshot *)s {
    DeskWorkbuddySnapshot *copy = [s copy];
    @synchronized (self) { _snapshot = copy; }
    if (_onChange) _onChange(copy);
    [self persist:copy];
}

- (void)persist:(DeskWorkbuddySnapshot *)s {
    if (_statePath.length == 0) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"version"] = @1;
    d[@"accessToken"] = _accessToken ?: @"";
    d[@"refreshToken"] = _refreshToken ?: @"";
    d[@"uid"] = _uid ?: @"";
    d[@"nickname"] = _nickname ?: @"";
    d[@"host"] = _host ?: kWorkbuddyCNHost;
    d[@"source"] = _source ?: @"";
    d[@"expiresAt"] = @(_tokenExpiresAt);
    d[@"refreshExpiresAt"] = @(_refreshExpiresAt);
    d[@"snapshot"] = [s dictionaryRepresentation];
    NSData *data = [NSJSONSerialization dataWithJSONObject:d
                                                   options:NSJSONWritingPrettyPrinted error:NULL];
    if (!data) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[_statePath stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES attributes:nil error:NULL];
    [data writeToFile:_statePath options:NSDataWritingAtomic error:NULL];
    [fm setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:_statePath error:NULL];
}

- (void)applyCredentialsTo:(DeskWorkbuddySnapshot *)s {
    @synchronized (self) {
        s.hasToken = _accessToken.length > 0;
        s.uid = _uid ?: @"";
        s.nickname = _nickname ?: @"";
        s.host = _host.length ? _host : kWorkbuddyCNHost;
        s.source = _source ?: @"";
        s.tokenExpiresAt = _tokenExpiresAt;
        s.tokenExpired = _tokenExpiresAt > 0 && _tokenExpiresAt <= [NSDate date].timeIntervalSince1970;
    }
}

- (BOOL)load {
    NSDictionary *fileAttrs = _statePath.length
        ? [[NSFileManager defaultManager] attributesOfItemAtPath:_statePath error:NULL] : nil;
    NSTimeInterval mtime = [fileAttrs[NSFileModificationDate] timeIntervalSince1970];
    _lastLoadModification = mtime;
    NSData *raw = _statePath.length ? [NSData dataWithContentsOfFile:_statePath] : nil;
    NSDictionary *store = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL] : nil;
    if (![store isKindOfClass:[NSDictionary class]]) store = @{};
    DeskWorkbuddySnapshot *s = [DeskWorkbuddySnapshot snapshotWithDictionary:
        [store[@"snapshot"] isKindOfClass:[NSDictionary class]] ? store[@"snapshot"] : @{}];
    @synchronized (self) {
        _accessToken = [WbString(store[@"accessToken"]) copy] ?: @"";
        _refreshToken = [WbString(store[@"refreshToken"]) copy] ?: @"";
        _uid = [WbString(store[@"uid"]) copy] ?: @"";
        _nickname = [WbString(store[@"nickname"]) copy] ?: @"";
        _host = [WbString(store[@"host"]) copy] ?: kWorkbuddyCNHost;
        _source = [WbString(store[@"source"]) copy] ?: @"";
        _tokenExpiresAt = WbNumber(store[@"expiresAt"], 0);
        _refreshExpiresAt = WbNumber(store[@"refreshExpiresAt"], 0);
    }
    if (_accessToken.length == 0) {
        // 老版本客户端 / 自己导出的明文登录态可以直接用；加密的直接忽略，等浏览器登录。
        NSError *le = nil;
        NSDictionary *local = DeskWorkbuddyLocalSession(&le);
        if (local) {
            @synchronized (self) {
                _accessToken = [local[@"accessToken"] copy];
                _refreshToken = [WbString(local[@"refreshToken"]) copy] ?: @"";
                _uid = [WbString(local[@"uid"]) copy] ?: @"";
                _nickname = [WbString(local[@"nickname"]) copy] ?: @"";
                _host = [WbString(local[@"host"]) copy] ?: kWorkbuddyCNHost;
                _source = @"local";
                _tokenExpiresAt = WbNumber(local[@"expiresAt"], 0);
            }
            [self note:@"已导入本机明文登录态（%@）", _source];
        } else if (le.code == DeskCreditsErrorAuth) {
            [self note:@"本机登录态不可用：%@", le.localizedDescription];
        }
    }
    [self applyCredentialsTo:s];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (!s.hasToken) {
        s.phase = DeskWorkbuddyPhaseNeedsAuth;
        s.lastError = @"未登录 WorkBuddy（菜单 › 签到中心 › WorkBuddy › 登录（浏览器）…）";
    } else if (s.tokenExpired && _refreshToken.length == 0) {
        s.phase = DeskWorkbuddyPhaseNeedsAuth;
        s.lastError = @"WorkBuddy 登录已过期，重新登录一次";
    } else if (s.phase == DeskWorkbuddyPhaseUnknown || s.phase == DeskWorkbuddyPhaseNeedsAuth) {
        s.phase = s.hasStatus ? DeskWorkbuddyPhaseReady : DeskWorkbuddyPhaseUnknown;
        s.lastError = nil;
    }
    // 跨天：昨天已签不能冒充今天
    NSString *today = DeskCreditsDayKey(now);
    if ([s.dayKey isEqualToString:today] == NO) {
        s.checkedIn = NO;
        s.todayCredit = -1;
        s.hasStatus = NO;
        s.dayKey = today;
    }
    [self publish:s];
    if (s.hasToken) {
        [self note:@"登录态：%@@%@ · 连签 %.0f 天 · 余额 %@",
              s.nickname.length ? s.nickname : @"WorkBuddy", s.host,
              s.streakDays, s.balance >= 0 ? DeskCreditsFormatPoints(s.balance) : @"—"];
    } else {
        [self note:@"未登录（本机 5.6.2+ 登录态已加密，需浏览器登录一次）"];
    }
    return s.hasToken;
}

#pragma mark 网络

- (NSDictionary *)requestHost:(NSString *)host
                         path:(NSString *)path
                       method:(NSString *)method
                         body:(NSDictionary *)body
                        token:(NSString *)token
                        error:(NSError **)err
                     httpCode:(NSInteger *)httpCode {
    NSURL *url = [NSURL URLWithString:[@"https://" stringByAppendingString:
                                      [host stringByAppendingString:path]]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    req.timeoutInterval = 15.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:kWorkbuddyUserAgent forHTTPHeaderField:@"User-Agent"];
    [req setValue:host forHTTPHeaderField:@"X-Domain"];
    [req setValue:@"SaaS" forHTTPHeaderField:@"X-Product"];
    if (token.length) {
        [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        NSString *uid = nil;
        @synchronized (self) { uid = _uid; }
        if (uid.length) [req setValue:uid forHTTPHeaderField:@"X-User-Id"];
    } else {
        [req setValue:@"true" forHTTPHeaderField:@"X-No-Authorization"];
        [req setValue:@"true" forHTTPHeaderField:@"X-No-User-Id"];
    }
    if (body) {
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    } else if ([method isEqualToString:@"POST"]) {
        req.HTTPBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
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
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    if (httpCode) *httpCode = status;
    if (netErr) {
        if (err) *err = WbError(DeskCreditsErrorNetwork, @"网络失败：%@", netErr.localizedDescription);
        return nil;
    }
    id obj = payload ? [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL] : nil;
    NSDictionary *json = [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
    if (status == 401 || status == 403) {
        if (err) *err = WbError(DeskCreditsErrorAuth, @"HTTP %ld：登录已失效", (long)status);
        return json;
    }
    if (status < 200 || status >= 300) {
        if (err) *err = WbError(DeskCreditsErrorHTTP, @"HTTP %ld %@", (long)status,
                                WbString(WbValue(json, @"msg")));
        return json;
    }
    if (!json) {
        if (err) *err = WbError(DeskCreditsErrorJSON, @"接口返回不是 JSON 对象");
        return nil;
    }
    return json;
}

- (BOOL)refreshAccessTokenOnQueue:(NSError **)err {
    NSString *rt = nil, *host = nil;
    @synchronized (self) {
        rt = _refreshToken;
        host = _host.length ? _host : kWorkbuddyCNHost;
    }
    if (rt.length == 0 || host.length == 0) {
        if (err) *err = WbError(DeskCreditsErrorAuth, @"没有 refreshToken，需要重新登录");
        return NO;
    }
    NSURL *url = [NSURL URLWithString:[@"https://" stringByAppendingString:
                                      [host stringByAppendingString:@"/v2/plugin/auth/token/refresh"]]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:kWorkbuddyUserAgent forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
    [req setValue:host forHTTPHeaderField:@"X-Domain"];
    [req setValue:rt forHTTPHeaderField:@"X-Refresh-Token"];
    [req setValue:@"plugin" forHTTPHeaderField:@"X-Auth-Refresh-Source"];
    [req setValue:@"SaaS" forHTTPHeaderField:@"X-Product"];
    req.HTTPBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];

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
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    if (netErr) {
        if (err) *err = WbError(DeskCreditsErrorNetwork, @"续期网络失败：%@", netErr.localizedDescription);
        return NO;
    }
    id obj = payload ? [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL] : nil;
    NSDictionary *json = [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
    NSDictionary *data = [WbValue(json, @"data") isKindOfClass:[NSDictionary class]]
        ? WbValue(json, @"data") : @{};
    NSString *token = WbString(data[@"accessToken"]);
    NSInteger code = WbInteger(WbValue(json, @"code"), -1);
    if (token.length == 0) {
        if (status == 401 || code == 12153) {
            if (err) *err = WbError(DeskCreditsErrorAuth, @"WorkBuddy 登录已失效，请重新登录");
        } else {
            if (err) *err = WbError(DeskCreditsErrorHTTP, @"WorkBuddy 续期失败：HTTP %ld %@",
                                    (long)status, WbString(WbValue(json, @"msg")));
        }
        return NO;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    double expiresIn = WbNumber(data[@"expiresIn"], 0);
    double refreshIn = WbNumber(data[@"refreshExpiresIn"], 0);
    NSString *newRefresh = WbString(data[@"refreshToken"]);
    @synchronized (self) {
        _accessToken = [token copy];
        if (newRefresh.length) _refreshToken = [newRefresh copy];
        _tokenExpiresAt = expiresIn > 0 ? now + expiresIn : now + 1800;
        if (refreshIn > 0) _refreshExpiresAt = now + refreshIn;
    }
    return YES;
}

- (BOOL)ensureAccessToken:(NSError **)err {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *token = nil;
    @synchronized (self) { token = _accessToken; }
    if (token.length == 0) {
        if (err) *err = WbError(DeskCreditsErrorAuth, @"没有 WorkBuddy 登录令牌");
        return NO;
    }
    NSTimeInterval exp = 0;
    BOOL hasRefresh = NO;
    @synchronized (self) {
        exp = _tokenExpiresAt;
        hasRefresh = _refreshToken.length > 0;
    }
    if (exp > 0 && exp - now < 300 && hasRefresh) {
        NSError *re = nil;
        if ([self refreshAccessTokenOnQueue:&re]) return YES;
        if (err) *err = re;
        return NO;
    }
    return YES;
}

- (NSDictionary *)apiPost:(NSString *)path body:(NSDictionary *)body error:(NSError **)err
                 httpCode:(NSInteger *)httpCode {
    NSString *token = nil, *host = nil;
    @synchronized (self) {
        token = _accessToken;
        host = _host.length ? _host : kWorkbuddyCNHost;
    }
    NSInteger status = 0;
    NSDictionary *json = [self requestHost:host path:path method:@"POST" body:body
                                     token:token error:err httpCode:&status];
    if (status == 401 || status == 403) {
        NSError *re = nil;
        if ([self refreshAccessTokenOnQueue:&re]) {
            @synchronized (self) { token = _accessToken; }
            json = [self requestHost:host path:path method:@"POST" body:body
                               token:token error:err httpCode:&status];
        }
    }
    if (httpCode) *httpCode = status;
    return json;
}

#pragma mark 刷新

- (BOOL)applyAuthFailure:(NSError *)e to:(DeskWorkbuddySnapshot *)s {
    if (!e || e.code != DeskCreditsErrorAuth) return NO;
    s.phase = DeskWorkbuddyPhaseNeedsAuth;
    s.tokenExpired = YES;
    s.hasStatus = NO;
    s.checkedIn = NO;
    return YES;
}

- (BOOL)refreshSyncWithBalance:(BOOL)withBalance error:(NSError **)err {
    DeskWorkbuddySnapshot *s = [self.snapshot copy];
    [self applyCredentialsTo:s];
    if (!s.hasToken) {
        s.phase = DeskWorkbuddyPhaseNeedsAuth;
        s.lastError = @"未登录 WorkBuddy";
        [self publish:s];
        if (err) *err = WbError(DeskCreditsErrorMissing, @"%@", s.lastError);
        return NO;
    }
    NSError *te = nil;
    if (![self ensureAccessToken:&te]) {
        [self applyAuthFailure:te to:s];
        s.phase = DeskWorkbuddyPhaseNeedsAuth;
        s.lastError = te.localizedDescription ?: @"登录已失效";
        [self publish:s];
        if (err) *err = te;
        return NO;
    }
    [self applyCredentialsTo:s];
    s.refreshing = YES;
    [self publish:s];

    NSError *e = nil;
    NSInteger status = 0;
    NSDictionary *statusJSON = [self apiPost:@"/v2/billing/meter/checkin-activity-status"
                                        body:@{} error:&e httpCode:&status];
    if (e || !statusJSON) {
        s.refreshing = NO;
        if (![self applyAuthFailure:e to:s]) {
            if (status == 404) {
                s.phase = DeskWorkbuddyPhaseReady;
                s.hasStatus = YES;
                s.activityEnabled = NO;
                s.lastError = nil;
                s.lastSyncAt = [NSDate date].timeIntervalSince1970;
                [self publish:s];
                if (err) *err = e;
                return NO;
            }
            s.phase = DeskWorkbuddyPhaseError;
            s.lastError = e.localizedDescription ?: @"签到状态刷新失败";
        }
        [self publish:s];
        if (err) *err = e;
        return NO;
    }
    NSError *pe = nil;
    if (!DeskWorkbuddyApplyStatus(s, statusJSON, &pe)) {
        s.refreshing = NO;
        s.phase = DeskWorkbuddyPhaseError;
        s.lastError = pe.localizedDescription ?: @"签到状态解析失败";
        [self publish:s];
        if (err) *err = pe;
        return NO;
    }

    if (withBalance) {
        NSError *qe = nil;
        NSDictionary *quota = [self apiPost:@"/v2/billing/meter/get-user-resource"
                                       body:@{} error:&qe httpCode:NULL];
        if (quota) {
            if (!DeskWorkbuddyApplyResource(s, quota, NULL)) {
                [self note:@"积分刷新失败：%@", WbString(WbValue(quota, @"msg"))];
            }
        } else {
            [self note:@"积分刷新失败：%@", qe.localizedDescription ?: @"未知原因"];
        }
    }

    s.refreshing = NO;
    s.phase = DeskWorkbuddyPhaseReady;
    s.lastError = nil;
    s.lastSyncAt = [NSDate date].timeIntervalSince1970;
    s.dayKey = DeskCreditsDayKey(s.lastSyncAt);
    [self publish:s];
    [self note:@"状态：%@ · 连签 %.0f 天 · 余额 %@",
          s.checkedIn ? @"已签" : (s.activityEnabled ? @"待签" : @"无活动"),
          s.streakDays,
          s.balance >= 0 ? DeskCreditsFormatPoints(s.balance) : @"—"];
    return YES;
}

#pragma mark 签到

- (DeskCreditsClaimResult *)claimSync:(NSError **)err {
    DeskCreditsClaimResult *r = [DeskCreditsClaimResult new];
    r.outcome = DeskCreditsClaimOutcomeFailed;
    r.points = -1;
    r.dayNo = 0;

    DeskWorkbuddySnapshot *s = [self.snapshot copy];
    [self applyCredentialsTo:s];
    if (!s.hasToken) {
        r.outcome = DeskCreditsClaimOutcomeNotAuthorized;
        r.message = @"未登录 WorkBuddy";
        if (err) *err = WbError(DeskCreditsErrorMissing, @"%@", r.message);
        return r;
    }
    if (!s.hasStatus) {
        NSError *re = nil;
        [self refreshSyncWithBalance:YES error:&re];
        s = [self.snapshot copy];
        if (!s.hasStatus) {
            r.message = re.localizedDescription ?: @"拿不到签到状态";
            if (err) *err = re;
            return r;
        }
    }
    if (s.checkedIn) {
        r.outcome = DeskCreditsClaimOutcomeAlready;
        r.points = s.todayCredit;
        r.message = @"今日已签";
        return r;
    }

    s.claiming = YES;
    s.claimFailed = NO;
    [self publish:s];

    NSError *e = nil;
    NSInteger status = 0;
    NSDictionary *json = [self apiPost:@"/v2/billing/meter/daily-checkin"
                                   body:@{} error:&e httpCode:&status];
    s = [self.snapshot copy];
    s.claiming = NO;
    if (!json && !e) e = WbError(DeskCreditsErrorAPI, @"签到请求失败");
    if (status == 404) {
        s.phase = DeskWorkbuddyPhaseReady;
        s.activityEnabled = NO;
        s.lastError = nil;
        [self publish:s];
        r.message = @"当前账号暂无签到活动";
        if (err) *err = WbError(DeskCreditsErrorAPI, @"%@", r.message);
        return r;
    }
    if (!json) {
        if ([self applyAuthFailure:e to:s]) {
            s.lastError = e.localizedDescription;
        } else {
            s.claimFailed = YES;
            s.phase = DeskWorkbuddyPhaseError;
            s.lastError = e.localizedDescription ?: @"签到请求失败";
        }
        [self publish:s];
        r.message = s.lastError;
        if (err) *err = e;
        return r;
    }

    DeskCreditsClaimResult *parsed = DeskWorkbuddyClaimResultFromResponse(json);
    r.outcome = parsed.outcome;
    r.message = parsed.message;
    if (parsed.outcome == DeskCreditsClaimOutcomeClaimed) {
        r.points = parsed.points >= 0 ? parsed.points
            : (s.dailyCredit >= 0 ? s.dailyCredit : -1);
        s.checkedIn = YES;
        s.activityEnabled = YES;
        s.claimFailed = NO;
        s.lastError = nil;
        s.todayCredit = r.points;
        s.streakDays += 1;
        s.dayKey = DeskCreditsDayKey([NSDate date].timeIntervalSince1970);
        s.lastSyncAt = [NSDate date].timeIntervalSince1970;
        [self publish:s];
        [self note:@"签到成功：+%@（连签 %.0f 天）",
              r.points >= 0 ? DeskCreditsFormatPoints(r.points) : @"—", s.streakDays];
        [self refreshSyncWithBalance:YES error:NULL];
        return r;
    }
    if (parsed.outcome == DeskCreditsClaimOutcomeAlready) {
        s.checkedIn = YES;
        s.claimFailed = NO;
        s.dayKey = DeskCreditsDayKey([NSDate date].timeIntervalSince1970);
        [self publish:s];
        [self note:@"今日已签（%@）", r.message ?: @"接口认定已签"];
        return r;
    }
    s.claimFailed = YES;
    s.phase = DeskWorkbuddyPhaseError;
    s.lastError = r.message;
    [self publish:s];
    [self note:@"签到失败：%@", r.message];
    if (err) *err = WbError(DeskCreditsErrorAPI, @"%@", r.message);
    return r;
}

#pragma mark 调度

- (BOOL)claimThrottled:(NSTimeInterval)now {
    NSString *today = DeskCreditsDayKey(now);
    if (![_lastClaimDay isEqualToString:today]) {
        _lastClaimDay = [today copy];
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
    // 外部（CLI / 另一个入口）刚登录时，下一拍就能接上，不用重启组件。
    // 只在文件真的变过时重读，避免未登录时每分钟刷同一条日志。
    BOOL needReload = _accessToken.length == 0;
    if (!needReload) {
        @synchronized (self) {
            needReload = _tokenExpiresAt > 0 && _tokenExpiresAt <= now && _refreshToken.length == 0;
        }
    }
    if (needReload) {
        NSDictionary *attrs = [[NSFileManager defaultManager]
                               attributesOfItemAtPath:_statePath error:NULL];
        NSTimeInterval mtime = [attrs[NSFileModificationDate] timeIntervalSince1970];
        if (mtime > _lastLoadModification) [self load];
    }
    DeskWorkbuddySnapshot *s = [self.snapshot copy];
    [self applyCredentialsTo:s];
    if (!s.hasToken) {
        if (s.phase != DeskWorkbuddyPhaseNeedsAuth) {
            s.phase = DeskWorkbuddyPhaseNeedsAuth;
            s.lastError = @"未登录 WorkBuddy";
            [self publish:s];
        }
        return;
    }
    BOOL hasRefresh = NO;
    @synchronized (self) { hasRefresh = _refreshToken.length > 0; }
    if (s.tokenExpired && !hasRefresh) {
        if (s.phase != DeskWorkbuddyPhaseNeedsAuth) {
            s.phase = DeskWorkbuddyPhaseNeedsAuth;
            s.lastError = @"WorkBuddy 登录已过期，重新登录一次";
            [self publish:s];
        }
        return;
    }
    NSString *today = DeskCreditsDayKey(now);
    BOOL dayChanged = ![s.dayKey isEqualToString:today];
    if (!s.hasStatus || dayChanged || s.phase == DeskWorkbuddyPhaseError
        || s.phase == DeskWorkbuddyPhaseNeedsAuth || now - s.lastSyncAt > 600) {
        [self refreshSyncWithBalance:YES error:NULL];
        s = [self.snapshot copy];
    }
    if (!DeskWorkbuddyShouldAutoClaim(s, now)) return;
    if ([self claimThrottled:now]) return;
    [self note:@"自动签到：今天还没签"];
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

#pragma mark 浏览器登录

- (void)finishAuthorization:(BOOL)ok error:(NSError *)err {
    if (!_authorizing) return;
    _authorizing = NO;
    _authState = @"";
    BOOL (^cb)(BOOL, NSError *) = _authCompletion;
    _authCompletion = nil;
    _authURLHandler = nil;
    DeskWorkbuddySnapshot *s = [self.snapshot copy];
    [self applyCredentialsTo:s];
    s.authorizing = NO;
    if (ok) {
        s.phase = DeskWorkbuddyPhaseReady;
        s.lastError = nil;
    } else {
        s.phase = DeskWorkbuddyPhaseNeedsAuth;
        s.lastError = err.localizedDescription ?: @"登录失败";
    }
    [self publish:s];
    if (cb) cb(ok, err);
    if (ok) [self refreshSyncWithBalance:YES error:NULL];
}

- (void)beginAuthorizationWithURLHandler:(void (^)(NSString *url))urlHandler
                               completion:(void (^)(BOOL, NSError *))completion {
    dispatch_async(_queue, ^{
        if (self->_authorizing) {
            if (completion) completion(NO, WbError(DeskCreditsErrorAuth, @"已经在等待 WorkBuddy 登录"));
            return;
        }
        self->_authorizing = YES;
        self->_authHasToken = NO;
        self->_authState = @"";
        self->_authAccessToken = @"";
        self->_authRefreshToken = @"";
        self->_authUid = @"";
        self->_authNickname = @"";
        self->_authHost = kWorkbuddyCNHost;
        self->_authDeadline = [NSDate date].timeIntervalSince1970 + 600;
        self->_authURLHandler = [urlHandler copy];
        self->_authCompletion = [completion copy];
        DeskWorkbuddySnapshot *s = [self.snapshot copy];
        s.authorizing = YES;
        s.lastError = nil;
        [self publish:s];

        NSError *e = nil;
        NSDictionary *json = [self requestHost:kWorkbuddyCNHost
                                          path:@"/v2/plugin/auth/state?platform=WorkBuddy"
                                        method:@"POST" body:@{} token:@"" error:&e httpCode:NULL];
        NSDictionary *data = [WbValue(json, @"data") isKindOfClass:[NSDictionary class]]
            ? WbValue(json, @"data") : nil;
        NSString *state = WbString(data[@"state"]);
        NSString *url = WbString(data[@"authUrl"]);
        if (!json || WbInteger(WbValue(json, @"code"), -1) != 0 || state.length == 0 || url.length == 0) {
            NSString *msg = e.localizedDescription ?: WbString(WbValue(json, @"msg"));
            [self finishAuthorization:NO
                                error:WbError(DeskCreditsErrorAPI, @"WorkBuddy 登录初始化失败：%@",
                                              msg.length ? msg : @"未知原因")];
            return;
        }
        self->_authState = [state copy];
        void (^handler)(NSString *) = self->_authURLHandler;
        if (handler) handler(url);
        self->_authDeadline = [NSDate date].timeIntervalSince1970 + 600;
        [self pollAuthorization];
    });
}

- (void)pollAuthorization {
    if (!_authorizing) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now > _authDeadline) {
        [self finishAuthorization:NO error:WbError(DeskCreditsErrorAuth, @"WorkBuddy 登录超时")];
        return;
    }
    if (!_authHasToken) {
        NSError *e = nil;
        NSString *path = [NSString stringWithFormat:@"/v2/plugin/auth/token?state=%@",
                          [_authState stringByAddingPercentEncodingWithAllowedCharacters:
                           [NSCharacterSet URLQueryAllowedCharacterSet]]];
        NSDictionary *json = [self requestHost:kWorkbuddyCNHost path:path method:@"GET"
                                          body:nil token:@"" error:&e httpCode:NULL];
        NSInteger code = WbInteger(WbValue(json, @"code"), -1);
        NSDictionary *data = [WbValue(json, @"data") isKindOfClass:[NSDictionary class]]
            ? WbValue(json, @"data") : @{};
        NSString *token = WbString(data[@"accessToken"]);
        if (json && code == 0 && token.length > 0) {
            _authHasToken = YES;
            _authAccessToken = [token copy];
            _authRefreshToken = [WbString(data[@"refreshToken"]) copy] ?: @"";
            double exp = WbNumber(data[@"expiresIn"], 0);
            double rexp = WbNumber(data[@"refreshExpiresIn"], 0);
            _authTokenExpiresAt = exp > 0 ? now + exp : 0;
            _authRefreshExpiresAt = rexp > 0 ? now + rexp : 0;
            NSString *domain = WbString(data[@"domain"]);
            _authHost = [WbHostFromToken(token, domain.length ? domain : kWorkbuddyCNHost) copy];
        } else if (json && code != 11217 && e.code != DeskCreditsErrorHTTP) {
            // 11217 = 等待用户浏览器授权；其余明确错误才收尾
            if (code != 11217 && code != 0 && code != -1) {
                NSString *msg = WbString(WbValue(json, @"msg"));
                [self finishAuthorization:NO
                                    error:WbError(DeskCreditsErrorAuth, @"WorkBuddy 授权失败：%@",
                                                  msg.length ? msg : [NSString stringWithFormat:@"code %ld", (long)code])];
                return;
            }
        }
    }
    if (_authHasToken) {
        // 账号信息 best-effort：拿不到也不影响签到
        NSString *path = [NSString stringWithFormat:@"/v2/plugin/login/account?state=%@",
                          [_authState stringByAddingPercentEncodingWithAllowedCharacters:
                           [NSCharacterSet URLQueryAllowedCharacterSet]]];
        NSError *e = nil;
        NSDictionary *json = [self requestHost:_authHost path:path method:@"GET"
                                          body:nil token:_authAccessToken error:&e httpCode:NULL];
        NSDictionary *data = [WbValue(json, @"data") isKindOfClass:[NSDictionary class]]
            ? WbValue(json, @"data") : nil;
        if (WbInteger(WbValue(json, @"code"), -1) == 0 && data) {
            NSString *uid = WbString(data[@"uid"]);
            id nick = data[@"nickname"];
            NSString *nickname = [nick isKindOfClass:[NSString class]] ? nick : @"";
            _authUid = [uid copy] ?: @"";
            _authNickname = [nickname copy] ?: @"";
        }
        @synchronized (self) {
            _accessToken = [_authAccessToken copy];
            _refreshToken = [_authRefreshToken copy] ?: @"";
            _uid = [_authUid copy] ?: @"";
            _nickname = [_authNickname copy] ?: @"";
            _host = [_authHost copy];
            _source = @"browser";
            _tokenExpiresAt = _authTokenExpiresAt;
            _refreshExpiresAt = _authRefreshExpiresAt;
        }
        [self note:@"浏览器登录成功（%@，uid %@）",
              _authHost, _authUid.length ? _authUid : @"—"];
        [self finishAuthorization:YES error:nil];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), _queue, ^{
        [weakSelf pollAuthorization];
    });
}

- (void)cancelAuthorization {
    dispatch_async(_queue, ^{
        if (!self->_authorizing) return;
        [self finishAuthorization:NO error:WbError(DeskCreditsErrorAuth, @"已取消 WorkBuddy 登录")];
    });
}

- (BOOL)importLocalSession:(NSError **)err {
    NSError *le = nil;
    NSDictionary *local = DeskWorkbuddyLocalSession(&le);
    if (!local) {
        if (err) *err = le;
        return NO;
    }
    DeskWorkbuddySnapshot *s = [self.snapshot copy];
    @synchronized (self) {
        _accessToken = [local[@"accessToken"] copy];
        _refreshToken = [WbString(local[@"refreshToken"]) copy] ?: @"";
        _uid = [WbString(local[@"uid"]) copy] ?: @"";
        _nickname = [WbString(local[@"nickname"]) copy] ?: @"";
        _host = [WbString(local[@"host"]) copy] ?: kWorkbuddyCNHost;
        _source = @"local";
        _tokenExpiresAt = WbNumber(local[@"expiresAt"], 0);
        _refreshExpiresAt = 0;
    }
    [self applyCredentialsTo:s];
    s.phase = DeskWorkbuddyPhaseUnknown;
    s.lastError = nil;
    [self publish:s];
    [self note:@"已从本机 auth.info 导入明文登录态"];
    [self refreshAsync];
    return YES;
}

- (BOOL)clearCredentials:(NSError **)err {
    DeskWorkbuddySnapshot *s = [self.snapshot copy];
    @synchronized (self) {
        _accessToken = @"";
        _refreshToken = @"";
        _uid = @"";
        _nickname = @"";
        _source = @"";
        _tokenExpiresAt = 0;
        _refreshExpiresAt = 0;
    }
    s.hasToken = NO;
    s.tokenExpired = NO;
    s.hasStatus = NO;
    s.checkedIn = NO;
    s.activityEnabled = NO;
    s.balance = -1;
    s.phase = DeskWorkbuddyPhaseNeedsAuth;
    s.lastError = @"未登录 WorkBuddy";
    [self publish:s];
    (void)err;
    return YES;
}

#pragma mark 校验口

- (BOOL)ingestStatusForVerify:(NSDictionary *)json error:(NSError **)err {
    DeskWorkbuddySnapshot *s = [self.snapshot copy];
    s.hasToken = YES;
    s.host = s.host.length ? s.host : kWorkbuddyCNHost;
    s.source = s.source.length ? s.source : @"browser";
    if (!DeskWorkbuddyApplyStatus(s, json, err)) return NO;
    s.phase = DeskWorkbuddyPhaseReady;
    s.lastSyncAt = [NSDate date].timeIntervalSince1970;
    [self publish:s];
    return YES;
}

- (BOOL)ingestResourceForVerify:(NSDictionary *)json error:(NSError **)err {
    DeskWorkbuddySnapshot *s = [self.snapshot copy];
    if (!DeskWorkbuddyApplyResource(s, json, err)) return NO;
    [self publish:s];
    return YES;
}

- (BOOL)ingestAuthStateForVerify:(NSDictionary *)json error:(NSError **)err {
    NSDictionary *data = [WbValue(json, @"data") isKindOfClass:[NSDictionary class]]
        ? WbValue(json, @"data") : nil;
    if (WbInteger(WbValue(json, @"code"), -1) != 0
        || WbString(data[@"state"]).length == 0 || WbString(data[@"authUrl"]).length == 0) {
        if (err) *err = WbError(DeskCreditsErrorAPI, @"授权初始化返回不完整");
        return NO;
    }
    return YES;
}

- (BOOL)ingestAuthTokenForVerify:(NSDictionary *)json error:(NSError **)err {
    NSDictionary *data = [WbValue(json, @"data") isKindOfClass:[NSDictionary class]]
        ? WbValue(json, @"data") : nil;
    if (WbInteger(WbValue(json, @"code"), -1) != 0 || WbString(data[@"accessToken"]).length == 0) {
        if (err) *err = WbError(DeskCreditsErrorAuth, @"授权返回没有 accessToken");
        return NO;
    }
    DeskWorkbuddySnapshot *s = [self.snapshot copy];
    @synchronized (self) {
        _accessToken = [WbString(data[@"accessToken"]) copy];
        _refreshToken = [WbString(data[@"refreshToken"]) copy] ?: @"";
        _host = [WbHostFromToken(_accessToken, kWorkbuddyCNHost) copy];
        _source = @"browser";
    }
    [self applyCredentialsTo:s];
    s.phase = DeskWorkbuddyPhaseUnknown;
    [self publish:s];
    return YES;
}

@end
