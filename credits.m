#import "credits.h"
#import "trae_credits.h"
#import "qoder_credits.h"
#import "workbuddy_credits.h"
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

NSErrorDomain const DeskCreditsErrorDomain = @"DeskCreditsErrorDomain";

// MiniMax Code 的接口（2026-10 实测可用）。全部集中在这里，改版时只改这一处。
static NSString *const kStatusURL =
    @"https://agent.minimax.cn/minimax-cloud/api/v1/signin/status?timezone_offset=28800&is_desktop=1&client=desktop";
static NSString *const kClaimURL =
    @"https://agent.minimax.cn/minimax-cloud/api/v1/signin/claim?timezone_offset=28800&is_desktop=1&client=desktop";
static NSString *const kMembershipURL =
    @"https://agent.minimax.cn/matrix/api/v1/commerce/get_membership_info";
static NSString *const kDeviceCodeURL = @"https://account.minimax.cn/oauth2/device/code";
static NSString *const kTokenURL = @"https://account.minimax.cn/oauth2/token";

static NSString *const kClientID = @"mcode-public";
static NSString *const kScope = @"agent.default";
static NSString *const kAudience = @"agent-backend";
static NSString *const kDeviceGrant = @"urn:ietf:params:oauth:grant-type:device_code";

static const NSTimeInterval kStatusRefreshInterval = 30 * 60;
static const NSTimeInterval kStatusRetryInterval = 5 * 60;
static const NSTimeInterval kBalanceRefreshInterval = 6 * 60 * 60;
static const NSTimeInterval kBalanceRetryInterval = 30 * 60;
static const NSTimeInterval kClaimRetryInterval = 30 * 60;
static const NSTimeInterval kTokenEarlyRefresh = 5 * 60;
static const NSTimeInterval kStaleAfter = 2 * 60 * 60;
static const NSTimeInterval kAutoClaimAtSeconds = 10 * 3600 + 5 * 60;   // 北京时间每天 10:05 后才自动领

static NSError *CreditsError(DeskCreditsErrorCode code, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *CreditsError(DeskCreditsErrorCode code, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:DeskCreditsErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"未知错误"}];
}

static BOOL CheckBaseResp(NSDictionary *json, NSError **err) {
    id br = json[@"base_resp"];
    if (![br isKindOfClass:[NSDictionary class]]) return YES;
    NSInteger code = [((NSDictionary *)br)[@"status_code"] integerValue];
    if (code == 0) return YES;
    id raw = ((NSDictionary *)br)[@"status_msg"];
    NSString *msg = [raw isKindOfClass:[NSString class]] ? raw : @"未知错误";
    if (err) *err = CreditsError(DeskCreditsErrorAPI, @"接口返回 %ld：%@", (long)code, msg);
    return NO;
}

static double NumberOr(id v, double fallback) {
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [v doubleValue];
    return fallback;
}

static NSString *Base64URL(NSData *data) {
    NSString *s = [data base64EncodedStringWithOptions:0];
    s = [s stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    s = [s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    s = [s stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return s;
}

static NSString *URLEscape(NSString *s) {
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
                          @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:ok] ?: @"";
}

static NSString *FormEncode(NSDictionary<NSString *, NSString *> *fields) {
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    NSArray<NSString *> *keys = [fields.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *k in keys) {
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", URLEscape(k), URLEscape(fields[k])]];
    }
    return [pairs componentsJoinedByString:@"&"];
}

static BOOL WriteProtectedJSON(NSDictionary *dict, NSString *path, NSError **err) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:err];
    if (!data) return NO;
    if (![data writeToFile:path options:NSDataWritingAtomic error:err]) return NO;
    NSDictionary *attrs = @{NSFilePosixPermissions: @0600};
    if (![[NSFileManager defaultManager] setAttributes:attrs ofItemAtPath:path error:err]) return NO;
    return YES;
}

// —— 时间与格式化 ——

NSTimeInterval DeskCreditsDayStart(NSTimeInterval t) {
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:28800];
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:t];
    return [[cal startOfDayForDate:d] timeIntervalSince1970];
}

BOOL DeskCreditsAutoClaimWindowOpen(NSTimeInterval t) {
    return t - DeskCreditsDayStart(t) >= kAutoClaimAtSeconds;
}

NSInteger DeskCreditsHourOfDay(NSTimeInterval t) {
    NSTimeInterval sec = t - DeskCreditsDayStart(t);
    if (sec < 0) sec = 0;
    return (NSInteger)((long long)sec / 3600) % 24;
}

BOOL DeskCreditsHourlyCheckDue(NSTimeInterval t, NSInteger lastHour) {
    NSTimeInterval sec = t - DeskCreditsDayStart(t);
    if (sec < 0) return NO;
    long long intoHour = ((long long)sec) % 3600;
    NSInteger hour = DeskCreditsHourOfDay(t);
    return intoHour >= 5 * 60 && hour != lastHour;
}

NSString *DeskCreditsDayKey(NSTimeInterval t) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:28800];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]] ?: @"";
}

NSString *DeskCreditsFormatPoints(double v) {
    if (!isfinite(v) || v < 0) return @"—";
    double rounded = floor(v + 0.5);
    NSNumberFormatter *f = [NSNumberFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.numberStyle = NSNumberFormatterDecimalStyle;
    f.usesGroupingSeparator = YES;
    f.groupingSeparator = @",";
    f.maximumFractionDigits = 0;
    f.minimumFractionDigits = 0;
    return [f stringFromNumber:@(rounded)] ?: @"—";
}

NSString *DeskCreditsFormatSignedPoints(double v) {
    if (!isfinite(v) || v < 0) return @"—";
    return [@"+" stringByAppendingString:DeskCreditsFormatPoints(v)];
}

NSString *DeskCreditsSyncText(NSTimeInterval lastSyncAt, NSTimeInterval now) {
    if (!(lastSyncAt > 0)) return @"未同步";
    double age = now - lastSyncAt;
    if (age < 0) age = 0;
    if (age < 60) return @"刚刚同步";
    if (age < 3600) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm";
        return [NSString stringWithFormat:@"%@ 同步",
                [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:lastSyncAt]] ?: @"—"];
    }
    if (age < 24 * 3600) {
        return [NSString stringWithFormat:@"%ld 小时前", (long)floor(age / 3600.0)];
    }
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"MM-dd";
    return [NSString stringWithFormat:@"%@ 同步",
            [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:lastSyncAt]] ?: @"—"];
}

BOOL DeskCreditsSyncIsStale(NSTimeInterval lastSyncAt, NSTimeInterval now) {
    return !(lastSyncAt > 0) || now - lastSyncAt > kStaleAfter;
}

NSString *DeskCreditsStatusText(DeskCreditsSnapshot *s) {
    if (!s.authorized) return @"未授权";
    if (s.authorizing) return @"等待授权";
    if (s.needsAuth) return @"登录过期";
    if (s.claiming) return @"签到中…";
    if (s.claimFailed) return @"领取失败";
    if (s.phase == DeskCreditsPhaseError && !s.hasStatus) return @"接口异常";
    if (s.todayChecked) {
        return [NSString stringWithFormat:@"已签 %@", DeskCreditsFormatSignedPoints(s.todayPoints)];
    }
    if (s.hasToday) {
        return [NSString stringWithFormat:@"待签 %@", DeskCreditsFormatSignedPoints(s.todayPoints)];
    }
    if (s.refreshing) return @"同步中…";
    return @"—";
}

NSString *DeskCreditsCycleText(DeskCreditsSnapshot *s) {
    NSInteger len = [s cycleLength];
    if (len <= 0) len = 7;
    if (!s.hasToday || s.todayDayNo <= 0) {
        return [NSString stringWithFormat:@"本轮 —/%ld", (long)len];
    }
    return [NSString stringWithFormat:@"本轮 %ld/%ld", (long)s.todayDayNo, (long)len];
}

NSString *DeskCreditsNextText(DeskCreditsSnapshot *s) {
    if (!s.authorized) return @"尚未授权";
    if (s.authorizing) return @"等待浏览器授权";
    if (s.needsAuth) return @"登录已过期";
    if (s.claiming) return @"正在领取…";
    if (!s.hasToday) return s.refreshing ? @"正在同步" : @"—";
    if (!s.todayChecked) {
        if (s.todayPoints >= 0) {
            return [NSString stringWithFormat:@"今日 %@ · 现在可签",
                    DeskCreditsFormatSignedPoints(s.todayPoints)];
        }
        return @"今日 现在可签";
    }
    double next = [s nextReward];
    if (next >= 0) {
        return [NSString stringWithFormat:@"明日 %@ · 00:00",
                DeskCreditsFormatSignedPoints(next)];
    }
    NSInteger len = [s cycleLength];
    if (len > 0 && s.todayDayNo >= len) return @"明日 新一轮 · 00:00";
    return @"明日 —";
}

NSString *DeskCreditsPhaseText(DeskCreditsSnapshot *s) {
    if (!s.authorized) return @"未授权";
    if (s.authorizing) return @"等待授权";
    if (s.needsAuth) return @"登录过期";
    if (s.claiming) return @"签到中";
    if (s.claimFailed) return @"领取失败";
    if (s.phase == DeskCreditsPhaseError && !s.hasStatus) return @"接口异常";
    if (s.todayChecked) return @"已签";
    if (s.hasToday) return @"待签";
    return @"—";
}

NSString *DeskCreditsPKCEVerifier(void) {
    unsigned char buf[32];
    arc4random_buf(buf, sizeof buf);
    return Base64URL([NSData dataWithBytes:buf length:sizeof buf]);
}

NSString *DeskCreditsPKCEChallenge(NSString *verifier) {
    NSData *in = [verifier dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(in.bytes, (CC_LONG)in.length, digest);
    return Base64URL([NSData dataWithBytes:digest length:sizeof digest]);
}

// —— 数据对象 ——

@implementation DeskCreditsDay

- (instancetype)init {
    if ((self = [super init])) {
        _points = -1;
        _bonusPoints = 0;
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)d {
    if ((self = [super init])) {
        _dayNo = [d[@"day_no"] integerValue];
        _status = [d[@"status"] integerValue];
        _points = NumberOr(d[@"points"], -1);
        _bonusPoints = NumberOr(d[@"bonus_points"], 0);
        _isToday = [d[@"is_today"] boolValue];
    }
    return self;
}

- (BOOL)claimed { return _status == 3; }

- (double)total {
    if (_points < 0) return -1;
    return _points + MAX(0, _bonusPoints);
}

- (id)copyWithZone:(NSZone *)zone {
    DeskCreditsDay *c = [[DeskCreditsDay allocWithZone:zone] init];
    c.dayNo = _dayNo;
    c.status = _status;
    c.points = _points;
    c.bonusPoints = _bonusPoints;
    c.isToday = _isToday;
    return c;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"dayNo": @(_dayNo),
        @"status": @(_status),
        @"points": @(_points),
        @"bonusPoints": @(_bonusPoints),
        @"isToday": @(_isToday),
    };
}

@end

@implementation DeskCreditsSnapshot

- (instancetype)init {
    if ((self = [super init])) {
        _balance = -1;
        _freeBalance = -1;
        _purchasedBalance = -1;
        _todayPoints = -1;
        _days = @[];
        _dayKey = @"";
        _phase = DeskCreditsPhaseUnknown;
    }
    return self;
}

- (DeskCreditsDay *)today {
    for (DeskCreditsDay *d in _days) {
        if (d.isToday) return d;
    }
    return nil;
}

- (DeskCreditsDay *)nextDay {
    DeskCreditsDay *t = [self today];
    if (!t) return nil;
    for (DeskCreditsDay *d in _days) {
        if (d.dayNo > t.dayNo && !d.claimed) return d;
    }
    return nil;
}

- (double)nextReward {
    if (!_hasToday) return -1;
    if (!_todayChecked) return _todayPoints >= 0 ? _todayPoints : -1;
    DeskCreditsDay *n = [self nextDay];
    return n ? n.total : -1;
}

- (NSInteger)cycleLength { return (NSInteger)_days.count; }

- (id)copyWithZone:(NSZone *)zone {
    DeskCreditsSnapshot *c = [[DeskCreditsSnapshot allocWithZone:zone] init];
    c.phase = _phase;
    c.authorized = _authorized;
    c.needsAuth = _needsAuth;
    c.authorizing = _authorizing;
    c.refreshing = _refreshing;
    c.claiming = _claiming;
    c.hasStatus = _hasStatus;
    c.days = [_days copy];
    c.hasToday = _hasToday;
    c.todayDayNo = _todayDayNo;
    c.todayChecked = _todayChecked;
    c.todayPoints = _todayPoints;
    c.balance = _balance;
    c.freeBalance = _freeBalance;
    c.purchasedBalance = _purchasedBalance;
    c.planTier = _planTier;
    c.lastSyncAt = _lastSyncAt;
    c.lastError = _lastError;
    c.stale = _stale;
    c.claimFailed = _claimFailed;
    c.dayKey = _dayKey ?: @"";
    return c;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *days = [NSMutableArray arrayWithCapacity:_days.count];
    for (DeskCreditsDay *d in _days) [days addObject:[d dictionaryRepresentation]];
    NSMutableDictionary *d = [@{
        @"schemaVersion": @1,
        @"phase": @(_phase),
        @"hasStatus": @(_hasStatus),
        @"days": days,
        @"hasToday": @(_hasToday),
        @"todayDayNo": @(_todayDayNo),
        @"todayChecked": @(_todayChecked),
        @"todayPoints": @(_todayPoints),
        @"balance": @(_balance),
        @"freeBalance": @(_freeBalance),
        @"purchasedBalance": @(_purchasedBalance),
        @"lastSyncAt": @(_lastSyncAt),
        @"stale": @(_stale),
        @"claimFailed": @(_claimFailed),
        @"dayKey": _dayKey ?: @"",
    } mutableCopy];
    if (_planTier.length) d[@"planTier"] = _planTier;
    if (_lastError.length) d[@"lastError"] = _lastError;
    return d;
}

+ (instancetype)snapshotWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    DeskCreditsSnapshot *s = [DeskCreditsSnapshot new];
    s.phase = (DeskCreditsPhase)MIN(MAX([dict[@"phase"] integerValue], 0), (NSInteger)DeskCreditsPhaseError);
    s.hasStatus = [dict[@"hasStatus"] boolValue];
    NSMutableArray<DeskCreditsDay *> *days = [NSMutableArray array];
    id rawDays = dict[@"days"];
    if ([rawDays isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)rawDays) {
            if ([item isKindOfClass:[NSDictionary class]]) {
                [days addObject:[[DeskCreditsDay alloc] initWithDictionary:item]];
            }
        }
    }
    [days sortUsingComparator:^NSComparisonResult(DeskCreditsDay *a, DeskCreditsDay *b) {
        if (a.dayNo < b.dayNo) return NSOrderedAscending;
        if (a.dayNo > b.dayNo) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    s.days = days;
    s.hasToday = [dict[@"hasToday"] boolValue];
    s.todayDayNo = [dict[@"todayDayNo"] integerValue];
    s.todayChecked = [dict[@"todayChecked"] boolValue];
    s.todayPoints = NumberOr(dict[@"todayPoints"], -1);
    s.balance = NumberOr(dict[@"balance"], -1);
    s.freeBalance = NumberOr(dict[@"freeBalance"], -1);
    s.purchasedBalance = NumberOr(dict[@"purchasedBalance"], -1);
    id plan = dict[@"planTier"];
    s.planTier = [plan isKindOfClass:[NSString class]] && [plan length] ? plan : nil;
    s.lastSyncAt = NumberOr(dict[@"lastSyncAt"], 0);
    id le = dict[@"lastError"];
    s.lastError = [le isKindOfClass:[NSString class]] && [le length] ? le : nil;
    s.stale = [dict[@"stale"] boolValue];
    s.claimFailed = [dict[@"claimFailed"] boolValue];
    id key = dict[@"dayKey"];
    s.dayKey = [key isKindOfClass:[NSString class]] ? key : @"";
    return s;
}

@end

@implementation DeskCreditsClaimResult

- (instancetype)init {
    if ((self = [super init])) {
        _outcome = DeskCreditsClaimOutcomeUnknown;
        _points = -1;
    }
    return self;
}

@end

// —— 四平台签到中心 ——

@implementation DeskCreditsSlot

- (instancetype)init {
    if ((self = [super init])) {
        _name = @"";
        _unit = @"";
        _planLine = @"";
        _statusText = @"";
        _footerText = @"";
        _balance = -1;
        _claimCount = -1;
        _streakTotal = 7;
        _loginTotalDays = 30;
        _cycleStates = @[];
        _cycleBonuses = @[];
        _actionTitles = @[];
        _authActionTitle = @"";
        _hint = @"";
        _recordMax = -1;
        _recordCoverageDays = 0;
        _recordRail = @[];
        _lastCheckInAmount = -1;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    DeskCreditsSlot *c = [[DeskCreditsSlot allocWithZone:zone] init];
    c.platform = _platform;
    c.name = _name;
    c.unit = _unit;
    c.connected = _connected;
    c.kind = _kind;
    c.balance = _balance;
    c.planLine = _planLine;
    c.statusText = _statusText;
    c.footerText = _footerText;
    c.visual = _visual;
    c.cycleStates = [_cycleStates copy];
    c.cycleBonuses = [_cycleBonuses copy];
    c.streakCount = _streakCount;
    c.streakTotal = _streakTotal;
    c.loginDays = _loginDays;
    c.loginTotalDays = _loginTotalDays;
    c.loginWarn = _loginWarn;
    c.claimCount = _claimCount;
    c.deviceReady = _deviceReady;
    c.lastSyncAt = _lastSyncAt;
    c.authActionTitle = _authActionTitle;
    c.hint = _hint;
    c.actionTitles = [_actionTitles copy];
    c.recordMax = _recordMax;
    c.recordPeakDayKey = _recordPeakDayKey;
    c.recordCoverageDays = _recordCoverageDays;
    c.recordNewHigh = _recordNewHigh;
    c.recordRail = [_recordRail copy];
    c.lastCheckInDayKey = _lastCheckInDayKey;
    c.lastCheckInAmount = _lastCheckInAmount;
    return c;
}

@end

static NSString *MiniMaxFooterText(DeskCreditsSnapshot *m, BOOL pending) {
    NSInteger len = [m cycleLength] > 0 ? [m cycleLength] : 7;
    NSString *cycle = (m.hasToday && m.todayDayNo > 0)
        ? [NSString stringWithFormat:@"本轮 %ld/%ld", (long)m.todayDayNo, (long)len]
        : @"本轮 —/7";
    if (pending) {
        NSString *today = m.todayPoints >= 0
            ? [NSString stringWithFormat:@"今日 +%@", DeskCreditsFormatPoints(m.todayPoints)]
            : @"今日 —";
        return [NSString stringWithFormat:@"%@ · %@", cycle, today];
    }
    double next = [m nextReward];
    NSString *nextText = nil;
    if (next >= 0) {
        nextText = [NSString stringWithFormat:@"明日 +%@", DeskCreditsFormatPoints(next)];
    } else if (len > 0 && m.todayDayNo >= len) {
        nextText = @"明日 新一轮";
    } else {
        nextText = @"明日 —";
    }
    return [NSString stringWithFormat:@"%@ · %@", cycle, nextText];
}

static DeskCreditsSlot *MiniMaxSlotFromSnapshot(DeskCreditsSnapshot *m) {
    DeskCreditsSlot *s = [DeskCreditsSlot new];
    s.platform = DeskCreditsPlatformMiniMax;
    s.name = @"MiniMax";
    s.unit = @"积分";
    s.connected = m.authorized;
    s.balance = m.balance;
    s.lastSyncAt = m.lastSyncAt;
    NSString *tier = m.planTier.uppercaseString;
    if (!tier.length) tier = @"MCODE";
    s.planLine = [NSString stringWithFormat:@"%@ · 独立 OAuth", tier];
    s.visual = DeskCreditsVisualCycle;
    s.authActionTitle = @"重新授权…";
    s.hint = @"浏览器独立 OAuth · 自动续期";
    s.actionTitles = @[@"立即签到", @"立即刷新", @"重新授权…", @"打开 MiniMax Code 网页版"];

    NSMutableArray<NSNumber *> *states = [NSMutableArray arrayWithCapacity:7];
    NSMutableArray<NSNumber *> *bonuses = [NSMutableArray arrayWithCapacity:7];
    for (NSInteger i = 0; i < 7; i++) {
        DeskCreditsDay *d = i < (NSInteger)m.days.count ? m.days[(NSUInteger)i] : nil;
        NSInteger st = 0;
        if (d) {
            if (d.isToday) st = d.claimed ? 2 : 3;
            else if (d.claimed) st = 1;
        }
        [states addObject:@(st)];
        [bonuses addObject:@(d && d.bonusPoints > 0 ? 1 : 0)];
    }
    s.cycleStates = states;
    s.cycleBonuses = bonuses;

    if (!m.authorized) {
        s.kind = DeskCreditsSlotKindNeedsAuth;
        s.statusText = @"未授权 · 点此授权";
        s.footerText = @"独立 OAuth · 自动续期";
    } else if (m.needsAuth) {
        s.kind = DeskCreditsSlotKindNeedsAuth;
        s.statusText = @"登录过期 · 点此授权";
        s.footerText = @"需要重新授权";
    } else if (m.claiming) {
        s.kind = DeskCreditsSlotKindWorking;
        s.statusText = @"签到中…";
        s.footerText = @"正在领取";
    } else if (m.claimFailed) {
        s.kind = DeskCreditsSlotKindError;
        s.statusText = @"领取失败 · 点此重试";
        s.footerText = @"今日可重试";
    } else if (m.todayChecked) {
        s.kind = DeskCreditsSlotKindSigned;
        s.statusText = m.todayPoints >= 0
            ? [NSString stringWithFormat:@"已签 +%@", DeskCreditsFormatPoints(m.todayPoints)]
            : @"已签";
        s.footerText = MiniMaxFooterText(m, NO);
    } else if (m.hasToday) {
        s.kind = DeskCreditsSlotKindPending;
        s.statusText = m.todayPoints >= 0
            ? [NSString stringWithFormat:@"待签 +%@", DeskCreditsFormatPoints(m.todayPoints)]
            : @"待签";
        s.footerText = MiniMaxFooterText(m, YES);
    } else if (m.refreshing) {
        s.kind = DeskCreditsSlotKindWorking;
        s.statusText = @"同步中…";
        s.footerText = @"等待刷新";
    } else {
        s.kind = DeskCreditsSlotKindPending;
        s.statusText = @"—";
        s.footerText = @"等待同步";
    }
    return s;
}

static DeskCreditsSlot *PlaceholderSlot(DeskCreditsPlatform platform,
                                        NSString *name,
                                        NSString *unit,
                                        NSString *planLine,
                                        NSString *statusText,
                                        NSString *footerText,
                                        DeskCreditsVisualKind visual,
                                        NSString *authActionTitle,
                                        NSString *hint,
                                        NSArray<NSString *> *actions) {
    DeskCreditsSlot *s = [DeskCreditsSlot new];
    s.platform = platform;
    s.name = name;
    s.unit = unit;
    s.connected = NO;
    s.kind = DeskCreditsSlotKindUnconnected;
    s.planLine = planLine;
    s.statusText = statusText;
    s.footerText = footerText;
    s.visual = visual;
    s.authActionTitle = authActionTitle;
    s.hint = hint;
    s.actionTitles = actions;
    return s;
}

static DeskCreditsSlot *TraePlaceholder(void) {
    DeskCreditsSlot *s = PlaceholderSlot(
        DeskCreditsPlatformTrae, @"Trae", @"积分",
        @"本机 storage.json · 不自动续期", @"每日签到", @"待导入登录态",
        DeskCreditsVisualLoginLife,
        @"从本机导入登录态…", @"不自动续期（刷新会踢掉 IDE）",
        @[@"立即签到", @"刷新额度", @"从本机导入登录态…", @"打开 Trae"]);
    s.loginDays = 0;
    s.loginTotalDays = 30;
    return s;
}

// Trae 槽：余额 + 登录态条。登录态条按令牌剩余天数走，<7 天转琥珀；
// 令牌过期不等于账号失效 —— 打开 Trae 让它自己续一次，就能重新读到新令牌。
static DeskCreditsSlot *TraeSlotFromSnapshot(DeskTraeSnapshot *t) {
    DeskCreditsSlot *s = TraePlaceholder();
    s.connected = t.connected;
    s.balance = t.balance;
    s.lastSyncAt = t.lastSyncAt;
    s.planLine = [NSString stringWithFormat:@"%@ · 本机登录态",
                  t.planTier.length ? t.planTier : @"Trae"];
    s.loginTotalDays = t.tokenSpanDays > 0 ? t.tokenSpanDays : 14.0;
    s.loginDays = t.loginDays;
    s.loginWarn = t.loginWarn;
    s.authActionTitle = @"从本机重新读取登录态";
    s.actionTitles = @[@"立即签到", @"刷新额度", @"从本机重新读取登录态", @"打开 Trae"];

    NSString *left = t.tokenExpiresAt > 0
        ? [NSString stringWithFormat:@"登录态 %.0f 天", MAX(0.0, t.loginDays)]
        : @"登录态 —";
    NSString *today = t.todayCredits >= 0
        ? [NSString stringWithFormat:@"+%@", DeskCreditsFormatPoints(t.todayCredits)]
        : @"";

    if (!t.connected) {
        s.kind = DeskCreditsSlotKindNeedsAuth;
        s.statusText = @"未找到登录态";
        s.footerText = @"打开 Trae 登录后自动读取";
    } else if (t.phase == DeskTraePhaseNeedsAuth) {
        s.kind = DeskCreditsSlotKindNeedsAuth;
        s.statusText = @"登录过期 · 点此打开";
        s.footerText = @"在 Trae 里重新登录";
    } else if (t.claiming) {
        s.kind = DeskCreditsSlotKindWorking;
        s.statusText = @"签到中…";
        s.footerText = @"正在领取";
    } else if (t.claimFailed) {
        s.kind = DeskCreditsSlotKindError;
        s.statusText = @"签到失败 · 点此重试";
        s.footerText = @"今日可重试";
    } else if (t.checkedIn) {
        s.kind = DeskCreditsSlotKindSigned;
        s.statusText = [NSString stringWithFormat:@"已签 %@", today];
        s.footerText = left;
    } else if (t.hasStatus && t.enabled) {
        s.kind = DeskCreditsSlotKindPending;
        s.statusText = [NSString stringWithFormat:@"待签 %@", today];
        s.footerText = left;
    } else if (t.hasStatus && !t.enabled) {
        s.kind = DeskCreditsSlotKindPending;
        s.statusText = @"活动未开启";
        s.footerText = left;
    } else if (t.refreshing) {
        s.kind = DeskCreditsSlotKindWorking;
        s.statusText = @"同步中…";
        s.footerText = @"等待刷新";
    } else {
        s.kind = DeskCreditsSlotKindPending;
        s.statusText = @"—";
        s.footerText = left;
    }
    if (t.lastError.length) s.hint = t.lastError;
    return s;
}

static DeskCreditsSlot *WorkBuddyPlaceholder(void) {
    DeskCreditsSlot *s = PlaceholderSlot(
        DeskCreditsPlatformWorkBuddy, @"WorkBuddy", @"积分",
        @"浏览器登录 · 每日签到", @"国内签到 · 国际无", @"待登录",
        DeskCreditsVisualStreak,
        @"登录（浏览器）…", @"本机 5.6.2+ 登录态已加密，用浏览器登录一次",
        @[@"登录（浏览器）…", @"立即签到", @"刷新额度", @"从本机导入登录态", @"打开 WorkBuddy"]);
    s.streakCount = 0;
    s.streakTotal = 7;
    return s;
}

// WorkBuddy 槽：余额 + 连签点。登录态过期只提示重新登录，不自动续期客户端那份。
static DeskCreditsSlot *WorkbuddySlotFromSnapshot(DeskWorkbuddySnapshot *w) {
    DeskCreditsSlot *s = WorkBuddyPlaceholder();
    s.connected = w.hasToken && !w.tokenExpired;
    s.balance = w.balance;
    s.lastSyncAt = w.lastSyncAt;
    s.streakTotal = 7;
    s.streakCount = MAX(0, MIN(7, (NSInteger)w.streakDays));
    s.planLine = DeskWorkbuddyPlanLine(w);
    NSString *amount = w.todayCredit >= 0 ? [NSString stringWithFormat:@"+%@",
                                            DeskCreditsFormatPoints(w.todayCredit)]
        : (w.dailyCredit >= 0 ? [NSString stringWithFormat:@"+%@",
                                 DeskCreditsFormatPoints(w.dailyCredit)] : @"");
    NSString *next = w.dailyCredit >= 0
        ? [NSString stringWithFormat:@"明日 +%@", DeskCreditsFormatPoints(w.dailyCredit)] : @"明日 —";
    if (!w.hasToken) {
        s.kind = DeskCreditsSlotKindNeedsAuth;
        s.statusText = @"未登录 · 点此登录";
        s.footerText = @"浏览器登录一次";
    } else if (w.tokenExpired) {
        s.kind = DeskCreditsSlotKindNeedsAuth;
        s.statusText = @"登录过期 · 点此重新登录";
        s.footerText = @"令牌已到期";
    } else if (w.authorizing && !w.claiming) {
        s.kind = DeskCreditsSlotKindWorking;
        s.statusText = @"等待浏览器登录…";
        s.footerText = @"最多等 10 分钟";
    } else if (w.claiming) {
        s.kind = DeskCreditsSlotKindWorking;
        s.statusText = @"签到中…";
        s.footerText = @"正在领取";
    } else if (w.claimFailed) {
        s.kind = DeskCreditsSlotKindError;
        s.statusText = @"签到失败 · 点此重试";
        s.footerText = @"稍后自动重试";
    } else if (w.checkedIn) {
        s.kind = DeskCreditsSlotKindSigned;
        s.statusText = [NSString stringWithFormat:@"已签 %@", amount];
        s.footerText = [NSString stringWithFormat:@"连签 %.0f 天 · %@", w.streakDays, next];
    } else if (w.hasStatus && w.activityEnabled) {
        s.kind = DeskCreditsSlotKindPending;
        s.statusText = [NSString stringWithFormat:@"待签 %@", amount];
        s.footerText = [NSString stringWithFormat:@"连签 %.0f 天 · %@", w.streakDays, next];
    } else if (w.hasStatus && !w.activityEnabled) {
        s.kind = DeskCreditsSlotKindPending;
        s.statusText = @"无签到活动";
        s.footerText = @"当前账号未开放";
    } else if (w.refreshing) {
        s.kind = DeskCreditsSlotKindWorking;
        s.statusText = @"同步中…";
        s.footerText = @"等待刷新";
    } else {
        s.kind = DeskCreditsSlotKindPending;
        s.statusText = @"—";
        s.footerText = @"等待首次同步";
    }
    if (w.lastError.length && !w.claiming) s.hint = w.lastError;
    return s;
}

static DeskCreditsSlot *QoderPlaceholder(void) {
    DeskCreditsSlot *s = PlaceholderSlot(
        DeskCreditsPlatformQoder, @"Qoder", @"Credits",
        @"PT 令牌 · 活动领取", @"活动领取 · 每日 10:00", @"待设置 PT",
        DeskCreditsVisualClaim,
        @"设置 PT 令牌…", @"国内版无需设备 · 每天 10:00 刷新",
        @[@"立即领取", @"刷新额度", @"设置 PT 令牌…", @"打开 Qoder 用量页"]);
    s.claimCount = -1;
    s.deviceReady = NO;
    return s;
}

// Qoder 槽：余额 + 活动牌（本窗口有几项活动、点 = PT 是否可用）。
static DeskCreditsSlot *QoderSlotFromSnapshot(DeskQoderSnapshot *q) {
    DeskCreditsSlot *s = QoderPlaceholder();
    s.connected = q.hasToken && !q.tokenInvalid;
    s.balance = q.balance;
    s.lastSyncAt = q.lastSyncAt;
    s.claimCount = q.campaignCount;
    s.deviceReady = s.connected;
    s.planLine = [NSString stringWithFormat:@"Qoder CN · %@ · PT",
                  DeskQoderPlanName(q.planTier)];
    NSString *amount = q.todayAmount >= 0
        ? [NSString stringWithFormat:@"+%@", DeskCreditsFormatPoints(q.todayAmount)]
        : @"";
    if (!q.hasToken) {
        s.kind = DeskCreditsSlotKindNeedsAuth;
        s.statusText = @"未设置 PT · 点此设置";
        s.footerText = @"菜单 › Qoder › 设置 PT 令牌…";
    } else if (q.tokenInvalid || q.phase == DeskQoderPhaseNeedsAuth) {
        s.kind = DeskCreditsSlotKindNeedsAuth;
        s.statusText = @"PT 失效 · 点此更换";
        s.footerText = @"重新生成个人令牌";
    } else if (q.claiming) {
        s.kind = DeskCreditsSlotKindWorking;
        s.statusText = @"领取中…";
        s.footerText = @"正在调用官方接口";
    } else if (q.claimFailed) {
        s.kind = DeskCreditsSlotKindError;
        s.statusText = @"领取失败 · 点此重试";
        s.footerText = @"稍后自动重试";
    } else if (q.claimed) {
        s.kind = DeskCreditsSlotKindClaimed;
        s.statusText = [NSString stringWithFormat:@"已领 %@", amount];
        s.footerText = [NSString stringWithFormat:@"已领 · %@",
                        DeskQoderRefreshText(q.windowEnd, [NSDate date].timeIntervalSince1970)];
    } else if (q.claimable) {
        s.kind = DeskCreditsSlotKindPending;
        s.statusText = [NSString stringWithFormat:@"待领 %@", amount];
        s.footerText = @"每日 10:00 刷新";
    } else if (q.refreshing) {
        s.kind = DeskCreditsSlotKindWorking;
        s.statusText = @"同步中…";
        s.footerText = @"等待刷新";
    } else if (q.hasStatus) {
        s.kind = DeskCreditsSlotKindPending;
        s.statusText = @"无活动";
        s.footerText = @"活动未下发";
    } else {
        s.kind = DeskCreditsSlotKindPending;
        s.statusText = @"—";
        s.footerText = @"等待首次同步";
    }
    if (q.lastError.length && !q.claiming) s.hint = q.lastError;
    return s;
}

static void RecomputeCenterCounts(DeskCreditsCenterSnapshot *c) {
    NSInteger connected = 0, done = 0, pending = 0, errors = 0;
    NSTimeInterval oldest = 0;
    for (DeskCreditsSlot *s in c.slots) {
        if (s.connected) connected++;
        switch (s.kind) {
            case DeskCreditsSlotKindSigned:
            case DeskCreditsSlotKindClaimed:
                done++;
                break;
            case DeskCreditsSlotKindPending:
                pending++;
                break;
            case DeskCreditsSlotKindNeedsAuth:
            case DeskCreditsSlotKindError:
                errors++;
                break;
            default:
                break;
        }
        if (s.connected && s.lastSyncAt > 0 && (oldest == 0 || s.lastSyncAt < oldest)) {
            oldest = s.lastSyncAt;
        }
    }
    c.connectedCount = connected;
    c.doneCount = done;
    c.pendingCount = pending;
    c.errorCount = errors;
    c.oldestSyncAt = oldest;
}

@implementation DeskCreditsCenterSnapshot

+ (instancetype)centerWithMiniMax:(DeskCreditsSnapshot *)m {
    return [self centerWithMiniMax:m trae:nil qoder:nil workbuddy:nil];
}

+ (instancetype)centerWithMiniMax:(DeskCreditsSnapshot *)m
                             trae:(DeskTraeSnapshot *)t
                            qoder:(DeskQoderSnapshot *)q
                        workbuddy:(DeskWorkbuddySnapshot *)w {
    DeskCreditsSnapshot *snap = m ?: [DeskCreditsSnapshot new];
    DeskCreditsCenterSnapshot *c = [DeskCreditsCenterSnapshot new];
    c.minimax = snap;
    c.trae = t;
    c.qoder = q;
    c.workbuddy = w;
    DeskCreditsSlot *traeSlot = t ? TraeSlotFromSnapshot(t) : TraePlaceholder();
    DeskCreditsSlot *qoderSlot = q ? QoderSlotFromSnapshot(q) : QoderPlaceholder();
    DeskCreditsSlot *wbSlot = w ? WorkbuddySlotFromSnapshot(w) : WorkBuddyPlaceholder();
    c.slots = @[traeSlot, wbSlot, qoderSlot, MiniMaxSlotFromSnapshot(snap)];
    RecomputeCenterCounts(c);
    return c;
}

+ (instancetype)previewFullCenterWithMiniMax:(DeskCreditsSnapshot *)m {
    DeskCreditsCenterSnapshot *c = [self centerWithMiniMax:m];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSArray<NSNumber *> *(^rail)(NSInteger, NSInteger) = ^NSArray<NSNumber *> *(NSInteger coverage, NSInteger peak) {
        NSMutableArray<NSNumber *> *r = [NSMutableArray arrayWithCapacity:90];
        NSInteger start = MAX(0, 90 - coverage);
        for (NSInteger i = 0; i < 90; i++) {
            NSInteger flags = DeskCreditsRecordRailMissing;
            if (i >= start) flags |= DeskCreditsRecordRailSampled;
            if (i == peak) flags |= DeskCreditsRecordRailPeak;
            if (i == 89) flags |= DeskCreditsRecordRailToday;
            [r addObject:@(flags)];
        }
        return r;
    };

    DeskCreditsSlot *mm = [c slotForPlatform:DeskCreditsPlatformMiniMax];
    mm.recordMax = 16200;
    mm.recordPeakDayKey = DeskCreditsDayKey(now - 54 * 86400);
    mm.recordCoverageDays = 90;
    mm.recordNewHigh = NO;
    mm.recordRail = rail(90, 35);
    mm.lastCheckInDayKey = DeskCreditsDayKey(now);
    mm.lastCheckInAmount = 1000;

    DeskCreditsSlot *trae = [TraePlaceholder() copy];
    trae.connected = YES;
    trae.kind = DeskCreditsSlotKindPending;
    trae.balance = 3240;
    trae.planLine = @"PRO · 不自动续期";
    trae.statusText = @"待签 +100";
    trae.footerText = @"登录态 22 天";
    trae.loginDays = 22;
    trae.loginTotalDays = 30;
    trae.loginWarn = NO;
    trae.lastSyncAt = now - 180;
    trae.recordMax = 3420;
    trae.recordPeakDayKey = DeskCreditsDayKey(now - 40 * 86400);
    trae.recordCoverageDays = 63;
    trae.recordNewHigh = NO;
    trae.recordRail = rail(63, 49);
    trae.lastCheckInDayKey = DeskCreditsDayKey(now - 86400);
    trae.lastCheckInAmount = 100;

    DeskCreditsSlot *wb = [WorkBuddyPlaceholder() copy];
    wb.connected = YES;
    wb.kind = DeskCreditsSlotKindSigned;
    wb.balance = 860;
    wb.planLine = @"国内版 · 浏览器登录";
    wb.statusText = @"已签 +100";
    wb.footerText = @"连签 3 天 · 明日 +100";
    wb.streakCount = 3;
    wb.streakTotal = 7;
    wb.lastSyncAt = now - 300;
    wb.recordMax = 1900;
    wb.recordPeakDayKey = DeskCreditsDayKey(now - 65 * 86400);
    wb.recordCoverageDays = 90;
    wb.recordNewHigh = NO;
    wb.recordRail = rail(90, 24);
    wb.lastCheckInDayKey = DeskCreditsDayKey(now);
    wb.lastCheckInAmount = 100;

    DeskCreditsSlot *qoder = [QoderPlaceholder() copy];
    qoder.connected = YES;
    qoder.kind = DeskCreditsSlotKindClaimed;
    qoder.balance = 1200;
    qoder.planLine = @"Qoder CN · 个人标准版 · PT";
    qoder.statusText = @"已领 +100";
    qoder.footerText = @"已领 · 明日 10:00 刷新";
    qoder.claimCount = 1;
    qoder.deviceReady = YES;
    qoder.lastSyncAt = now - 240;
    qoder.recordMax = 1200;
    qoder.recordPeakDayKey = DeskCreditsDayKey(now);
    qoder.recordCoverageDays = 90;
    qoder.recordNewHigh = YES;
    qoder.recordRail = rail(90, 89);
    qoder.lastCheckInDayKey = DeskCreditsDayKey(now);
    qoder.lastCheckInAmount = 100;

    c.slots = @[trae, wb, qoder, mm];
    RecomputeCenterCounts(c);
    return c;
}

- (DeskCreditsSlot *)slotForPlatform:(DeskCreditsPlatform)p {
    for (DeskCreditsSlot *s in _slots) {
        if (s.platform == p) return s;
    }
    return _slots.firstObject;
}

@end

// —— 解析 ——

DeskCreditsSnapshot *DeskCreditsSnapshotByApplyingStatus(DeskCreditsSnapshot *base,
                                                         NSDictionary *json,
                                                         NSError **err) {
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (err) *err = CreditsError(DeskCreditsErrorJSON, @"签到状态不是 JSON 对象");
        return nil;
    }
    if (!CheckBaseResp(json, err)) return nil;
    id data = json[@"data"];
    if (![data isKindOfClass:[NSDictionary class]]) {
        if (err) *err = CreditsError(DeskCreditsErrorJSON, @"签到状态缺少 data");
        return nil;
    }
    id raw = ((NSDictionary *)data)[@"days"];
    if (![raw isKindOfClass:[NSArray class]]) {
        if (err) *err = CreditsError(DeskCreditsErrorJSON, @"签到状态缺少 days");
        return nil;
    }
    NSMutableArray<DeskCreditsDay *> *days = [NSMutableArray array];
    for (id item in (NSArray *)raw) {
        if ([item isKindOfClass:[NSDictionary class]]) {
            [days addObject:[[DeskCreditsDay alloc] initWithDictionary:item]];
        }
    }
    [days sortUsingComparator:^NSComparisonResult(DeskCreditsDay *a, DeskCreditsDay *b) {
        if (a.dayNo < b.dayNo) return NSOrderedAscending;
        if (a.dayNo > b.dayNo) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    DeskCreditsSnapshot *s = base ? [base copy] : [DeskCreditsSnapshot new];
    s.days = days;
    s.hasStatus = YES;
    s.dayKey = DeskCreditsDayKey(now);
    s.lastSyncAt = now;
    s.stale = NO;
    s.lastError = nil;
    DeskCreditsDay *today = nil;
    for (DeskCreditsDay *d in days) {
        if (d.isToday) { today = d; break; }
    }
    s.hasToday = today != nil;
    s.todayDayNo = today ? today.dayNo : 0;
    s.todayChecked = today ? today.claimed : NO;
    s.todayPoints = today ? today.total : -1;
    if (s.todayChecked) s.claimFailed = NO;
    s.phase = s.todayChecked ? DeskCreditsPhaseCheckedIn
                             : (s.hasToday ? DeskCreditsPhaseIdle : DeskCreditsPhaseUnknown);
    s.needsAuth = NO;
    return s;
}

BOOL DeskCreditsApplyMembership(DeskCreditsSnapshot *s, NSDictionary *json, NSError **err) {
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (err) *err = CreditsError(DeskCreditsErrorJSON, @"余额不是 JSON 对象");
        return NO;
    }
    if (!CheckBaseResp(json, err)) return NO;
    id summary = json[@"op_credit_summary"];
    double total = -1, free = -1, purchased = -1;
    if ([summary isKindOfClass:[NSDictionary class]]) {
        NSDictionary *sum = summary;
        total = NumberOr(sum[@"total_remaining_amount"], -1);
        free = NumberOr(sum[@"free_remaining_amount"], -1);
        purchased = NumberOr(sum[@"purchased_remaining_amount"], -1);
    }
    if (total < 0) total = NumberOr(json[@"total_remains_credit"], -1);
    if (total < 0) {
        if (err) *err = CreditsError(DeskCreditsErrorMissing, @"余额字段缺失");
        return NO;
    }
    s.balance = total;
    s.freeBalance = free;
    s.purchasedBalance = purchased;
    id plan = json[@"plan_name"];
    if (![plan isKindOfClass:[NSString class]] || [plan length] == 0) plan = json[@"token_plan_tier"];
    s.planTier = [plan isKindOfClass:[NSString class]] && [plan length] ? plan : nil;
    return YES;
}

DeskCreditsClaimResult *DeskCreditsClaimResultFromResponse(NSDictionary *json, NSError **err) {
    DeskCreditsClaimResult *r = [DeskCreditsClaimResult new];
    if (![json isKindOfClass:[NSDictionary class]]) {
        r.outcome = DeskCreditsClaimOutcomeFailed;
        r.message = @"领取返回不是 JSON 对象";
        if (err) *err = CreditsError(DeskCreditsErrorJSON, @"%@", r.message);
        return r;
    }
    if (!CheckBaseResp(json, err)) {
        r.outcome = DeskCreditsClaimOutcomeFailed;
        r.message = err && *err ? (*err).localizedDescription : @"领取失败";
        return r;
    }
    id data = json[@"data"];
    if (![data isKindOfClass:[NSDictionary class]]) {
        r.outcome = DeskCreditsClaimOutcomeFailed;
        r.message = @"领取返回缺少 data";
        if (err) *err = CreditsError(DeskCreditsErrorJSON, @"%@", r.message);
        return r;
    }
    NSDictionary *d = data;
    r.points = NumberOr(d[@"points"], -1);
    r.dayNo = [d[@"day_no"] integerValue];
    NSInteger cr = [d[@"claim_result"] integerValue];
    if (cr == 2) {
        r.outcome = DeskCreditsClaimOutcomeAlready;
        r.message = @"今日已领取";
    } else if (cr == 1) {
        r.outcome = DeskCreditsClaimOutcomeClaimed;
        r.message = @"签到成功";
    } else if (r.points >= 0) {
        // 兼容没有 claim_result 的返回：有积分就按成功处理
        r.outcome = DeskCreditsClaimOutcomeClaimed;
        r.message = @"签到成功";
    } else {
        r.outcome = DeskCreditsClaimOutcomeFailed;
        r.message = @"领取返回里没有 claim_result";
        if (err) *err = CreditsError(DeskCreditsErrorAPI, @"%@", r.message);
    }
    return r;
}

// —— Provider ——

@interface DeskCreditsProvider () {
    dispatch_queue_t _queue;
    NSURLSession *_session;
    NSMutableDictionary *_auth;          // 只在本对象的队列里读写
    DeskCreditsSnapshot *_snapshot;      // 发布后只读；每次换新对象
    BOOL _loaded;
    NSTimeInterval _lastStatusAt;
    NSTimeInterval _lastStatusAttemptAt;
    NSTimeInterval _lastBalanceAt;
    NSTimeInterval _lastBalanceAttemptAt;
    NSTimeInterval _lastClaimAttemptAt;
    NSString *_lastClaimedDayKey;
    NSMutableDictionary *_pendingDevice;
    void (^_authCompletion)(BOOL, NSError *);
    BOOL _authorizing;
}
- (void)note:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1, 2);
- (void)publish:(DeskCreditsSnapshot *)s;
- (BOOL)saveAuth:(NSDictionary *)auth;
- (BOOL)refreshToken:(NSError **)err;
- (BOOL)ensureToken:(NSError **)err;
- (NSDictionary *)JSONForRequest:(NSURLRequest *)req
                          status:(NSInteger *)outStatus
                           error:(NSError **)outErr;
- (NSDictionary *)formJSONForURL:(NSString *)url
                          fields:(NSDictionary<NSString *, NSString *> *)fields
                          status:(NSInteger *)outStatus
                           error:(NSError **)outErr;
- (NSDictionary *)authorizedJSONForURL:(NSString *)url
                                method:(NSString *)method
                                  body:(NSData *)body
                           contentType:(NSString *)contentType
                                 error:(NSError **)err;
- (BOOL)markNeedsAuth:(NSString *)why;
- (BOOL)refreshBalanceOnQueue:(NSError **)err;
- (DeskCreditsClaimResult *)claimOnQueue:(NSError **)err;
- (BOOL)refreshStatusOnQueueWithBalance:(BOOL)withBalance error:(NSError **)err;
- (void)tickOnQueue;
- (void)finishAuthorization:(BOOL)ok error:(NSError *)err;
- (void)pollDeviceOnQueue;
- (BOOL)writeAuthFileForVerify:(NSDictionary *)auth;
@end

@implementation DeskCreditsProvider

- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) {
        _directory = [directory copy];
        _queue = dispatch_queue_create("com.hujie.deskboard.credits", DISPATCH_QUEUE_SERIAL);
        _snapshot = [DeskCreditsSnapshot new];
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 20;
        cfg.timeoutIntervalForResource = 30;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.HTTPShouldSetCookies = NO;
        cfg.HTTPCookieStorage = nil;
        cfg.URLCache = nil;
        cfg.HTTPAdditionalHeaders = @{
            @"Accept": @"application/json",
            @"User-Agent": @"DeskBoard/0.1 (MiniMax Credits)",
        };
        _session = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

- (void)dealloc {
    [_session invalidateAndCancel];
}

- (DeskCreditsSnapshot *)snapshot { return _snapshot; }
- (BOOL)authorized { return _snapshot.authorized; }
- (BOOL)needsAuth { return _snapshot.needsAuth; }

- (NSString *)authPath { return [_directory stringByAppendingPathComponent:@"auth.json"]; }
- (NSString *)statePath { return [_directory stringByAppendingPathComponent:@"state.json"]; }

- (void)note:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (self.onLog) self.onLog(msg);
    else NSLog(@"[MiniMax 签到] %@", msg);
}

- (void)publish:(DeskCreditsSnapshot *)s {
    _snapshot = s;
    NSData *data = [NSJSONSerialization dataWithJSONObject:[s dictionaryRepresentation]
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:NULL];
    if (data) {
        [data writeToFile:[self statePath] options:NSDataWritingAtomic error:NULL];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                                         ofItemAtPath:[self statePath] error:NULL];
    }
    if (self.onChange) self.onChange(s);
}

- (BOOL)writeAuthFileForVerify:(NSDictionary *)auth {
    return WriteProtectedJSON(auth, [self authPath], NULL);
}

- (BOOL)load {
    @synchronized (self) {
        if (_loaded) return YES;
        _loaded = YES;
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:_directory
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0700}
                            error:NULL];
        [fm setAttributes:@{NSFilePosixPermissions: @0700} ofItemAtPath:_directory error:NULL];

        NSData *authData = [NSData dataWithContentsOfFile:[self authPath]];
        if (authData) {
            id obj = [NSJSONSerialization JSONObjectWithData:authData options:0 error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *d = obj;
                BOOL hasAT = [d[@"accessToken"] isKindOfClass:[NSString class]];
                BOOL hasRT = [d[@"refreshToken"] isKindOfClass:[NSString class]];
                if (hasAT || hasRT) _auth = [d mutableCopy];
            }
        }
        NSData *stateData = [NSData dataWithContentsOfFile:[self statePath]];
        if (stateData) {
            id obj = [NSJSONSerialization JSONObjectWithData:stateData options:0 error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                DeskCreditsSnapshot *s = [DeskCreditsSnapshot snapshotWithDictionary:obj];
                if (s) _snapshot = s;
            }
        }
        BOOL hasCred = _auth[@"accessToken"] != nil || _auth[@"refreshToken"] != nil;
        DeskCreditsSnapshot *s = [_snapshot copy];
        s.authorized = hasCred;
        s.needsAuth = hasCred && [_auth[@"needsAuth"] boolValue];
        s.authorizing = NO;
        s.refreshing = NO;
        s.claiming = NO;
        // 昨天的“今天”不能当今天显示；余额可以跨天保留，但标记为旧
        if (![s.dayKey isEqualToString:DeskCreditsDayKey([NSDate date].timeIntervalSince1970)]) {
            s.days = @[];
            s.hasStatus = NO;
            s.hasToday = NO;
            s.todayDayNo = 0;
            s.todayChecked = NO;
            s.todayPoints = -1;
            s.claimFailed = NO;
            s.phase = DeskCreditsPhaseUnknown;
            if (s.lastSyncAt > 0) s.stale = YES;
        }
        _snapshot = s;
        return YES;
    }
}

// —— HTTP ——

- (NSDictionary *)JSONForRequest:(NSURLRequest *)req
                          status:(NSInteger *)outStatus
                           error:(NSError **)outErr {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *data = nil;
    __block NSError *netErr = nil;
    __block NSInteger code = 0;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
                                             completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d;
        netErr = e;
        if ([r isKindOfClass:[NSHTTPURLResponse class]]) {
            code = ((NSHTTPURLResponse *)r).statusCode;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    long timedOut = dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)));
    if (timedOut != 0) {
        [task cancel];
        if (outStatus) *outStatus = 0;
        if (outErr) *outErr = CreditsError(DeskCreditsErrorNetwork, @"网络超时");
        return nil;
    }
    if (outStatus) *outStatus = code;
    if (netErr) {
        if (outErr) {
            *outErr = CreditsError(DeskCreditsErrorNetwork, @"网络不可用（%@）",
                                   netErr.localizedDescription ?: @"未知原因");
        }
        return nil;
    }
    if (!data || data.length == 0) {
        if (code >= 200 && code < 300) return @{};
        if (outErr) *outErr = CreditsError(DeskCreditsErrorHTTP, @"服务器返回 HTTP %ld", (long)code);
        return nil;
    }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    if (outErr) {
        NSString *snippet = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        snippet = [snippet stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        if (snippet.length > 120) snippet = [[snippet substringToIndex:120] stringByAppendingString:@"…"];
        *outErr = CreditsError(DeskCreditsErrorJSON, @"接口返回不是 JSON（HTTP %ld）%@",
                               (long)code, snippet);
    }
    return nil;
}

- (NSDictionary *)formJSONForURL:(NSString *)url
                          fields:(NSDictionary<NSString *, NSString *> *)fields
                          status:(NSInteger *)outStatus
                           error:(NSError **)outErr {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [FormEncode(fields) dataUsingEncoding:NSUTF8StringEncoding];
    return [self JSONForRequest:req status:outStatus error:outErr];
}

- (BOOL)markNeedsAuth:(NSString *)why {
    NSMutableDictionary *a = _auth ? [_auth mutableCopy] : [NSMutableDictionary dictionary];
    a[@"needsAuth"] = @YES;
    [self saveAuth:a];
    DeskCreditsSnapshot *s = [_snapshot copy];
    s.authorized = YES;
    s.needsAuth = YES;
    s.authorizing = NO;
    s.refreshing = NO;
    s.claiming = NO;
    s.lastError = why;
    [self publish:s];
    [self note:@"需要重新授权：%@", why];
    return NO;
}

- (BOOL)saveAuth:(NSDictionary *)auth {
    NSError *e = nil;
    if (!WriteProtectedJSON(auth, [self authPath], &e)) {
        [self note:@"凭据落盘失败：%@", e.localizedDescription ?: @"未知原因"];
        return NO;
    }
    _auth = [auth mutableCopy];
    return YES;
}

- (BOOL)refreshToken:(NSError **)err {
    NSString *rt = _auth[@"refreshToken"];
    if (![rt isKindOfClass:[NSString class]] || rt.length == 0) {
        [self markNeedsAuth:@"凭据里没有 refresh token"];
        if (err) *err = CreditsError(DeskCreditsErrorAuth, @"登录已过期，请重新授权");
        return NO;
    }
    NSInteger code = 0;
    NSError *e = nil;
    NSDictionary *json = [self formJSONForURL:kTokenURL
        fields:@{
            @"grant_type": @"refresh_token",
            @"refresh_token": rt,
            @"client_id": kClientID,
            @"scope": kScope,
            @"audience": kAudience,
        }
        status:&code
        error:&e];
    id oauthErr = [json isKindOfClass:[NSDictionary class]] ? json[@"error"] : nil;
    BOOL authDead = (code == 400 || code == 401);
    if (authDead && ![oauthErr isEqual:@"slow_down"]) {
        [self markNeedsAuth:@"refresh token 已失效"];
        if (err) *err = CreditsError(DeskCreditsErrorAuth, @"登录已过期，请重新授权");
        return NO;
    }
    NSString *at = [json isKindOfClass:[NSDictionary class]] ? json[@"access_token"] : nil;
    if (![at isKindOfClass:[NSString class]] || at.length == 0) {
        if (err) *err = e ?: CreditsError(DeskCreditsErrorAuth, @"刷新登录态失败");
        [self note:@"刷新登录态失败：%@", e.localizedDescription ?: @"返回里没有 access_token"];
        return NO;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableDictionary *a = _auth ? [_auth mutableCopy] : [NSMutableDictionary dictionary];
    a[@"accessToken"] = at;
    id newRT = json[@"refresh_token"];
    if ([newRT isKindOfClass:[NSString class]] && [newRT length]) a[@"refreshToken"] = newRT;
    double expiresIn = NumberOr(json[@"expires_in"], 3600);
    if (!(expiresIn > 0)) expiresIn = 3600;
    a[@"expiresAtMs"] = @((now + expiresIn) * 1000.0);
    id tt = json[@"token_type"];
    a[@"tokenType"] = [tt isKindOfClass:[NSString class]] ? tt : @"Bearer";
    a[@"generation"] = @([a[@"generation"] integerValue] + 1);
    a[@"savedAt"] = @(now * 1000.0);
    a[@"needsAuth"] = @NO;
    if (![self saveAuth:a]) {
        if (err) *err = CreditsError(DeskCreditsErrorMissing, @"登录态无法落盘");
        return NO;
    }
    DeskCreditsSnapshot *s = [_snapshot copy];
    s.authorized = YES;
    s.needsAuth = NO;
    s.lastError = nil;
    [self publish:s];
    [self note:@"登录态已刷新（第 %@ 代）", a[@"generation"] ?: @"?"];
    return YES;
}

- (BOOL)ensureToken:(NSError **)err {
    if (_snapshot.needsAuth || [_auth[@"needsAuth"] boolValue]) {
        if (err) *err = CreditsError(DeskCreditsErrorAuth, @"登录已过期，请重新授权");
        return NO;
    }
    NSString *token = _auth[@"accessToken"];
    if (![token isKindOfClass:[NSString class]] || token.length == 0) {
        if (err) *err = CreditsError(DeskCreditsErrorAuth, @"还没有授权");
        return NO;
    }
    double exp = [_auth[@"expiresAtMs"] doubleValue] / 1000.0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (exp > 0 && exp - kTokenEarlyRefresh <= now) {
        return [self refreshToken:err];
    }
    return YES;
}

- (NSDictionary *)authorizedJSONForURL:(NSString *)url
                                method:(NSString *)method
                                  body:(NSData *)body
                           contentType:(NSString *)contentType
                                 error:(NSError **)err {
    for (int attempt = 0; attempt < 2; attempt++) {
        NSError *te = nil;
        if (![self ensureToken:&te]) {
            if (err) *err = te;
            return nil;
        }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        req.HTTPMethod = method;
        req.timeoutInterval = 20;
        [req setValue:[@"Bearer " stringByAppendingString:_auth[@"accessToken"]]
            forHTTPHeaderField:@"Authorization"];
        if (body) {
            req.HTTPBody = body;
            if (contentType) [req setValue:contentType forHTTPHeaderField:@"Content-Type"];
        }
        NSInteger code = 0;
        NSError *e = nil;
        NSDictionary *json = [self JSONForRequest:req status:&code error:&e];
        if (code == 401 && attempt == 0) {
            NSError *re = nil;
            if ([self refreshToken:&re]) continue;
            if (err) *err = re;
            return nil;
        }
        if (json) return json;
        if (err) *err = e ?: CreditsError(DeskCreditsErrorHTTP, @"服务器返回 HTTP %ld", (long)code);
        return nil;
    }
    if (err) *err = CreditsError(DeskCreditsErrorAuth, @"登录已过期，请重新授权");
    return nil;
}

// —— 三个业务请求 ——

- (BOOL)refreshBalanceOnQueue:(NSError **)err {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    _lastBalanceAttemptAt = now;
    NSDictionary *json = [self authorizedJSONForURL:kMembershipURL
                                             method:@"POST"
                                               body:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]
                                        contentType:@"application/json"
                                              error:err];
    if (!json) return NO;
    DeskCreditsSnapshot *s = [_snapshot copy];
    NSError *pe = nil;
    if (!DeskCreditsApplyMembership(s, json, &pe)) {
        if (err) *err = pe;
        return NO;
    }
    s.lastError = nil;
    s.stale = NO;
    _snapshot = s;
    _lastBalanceAt = now;
    return YES;
}

- (DeskCreditsClaimResult *)claimOnQueue:(NSError **)err {
    DeskCreditsClaimResult *result = [DeskCreditsClaimResult new];
    result.outcome = DeskCreditsClaimOutcomeFailed;
    result.points = -1;
    if (!_snapshot.authorized || _snapshot.needsAuth) {
        result.outcome = DeskCreditsClaimOutcomeNotAuthorized;
        result.message = _snapshot.needsAuth ? @"登录已过期" : @"尚未授权";
        if (err) *err = CreditsError(DeskCreditsErrorAuth, @"%@", result.message);
        return result;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    _lastClaimAttemptAt = now;
    DeskCreditsSnapshot *start = [_snapshot copy];
    start.claiming = YES;
    start.claimFailed = NO;
    start.lastError = nil;
    [self publish:start];

    NSError *e = nil;
    NSDictionary *statusJSON = [self authorizedJSONForURL:kStatusURL
                                                   method:@"GET"
                                                     body:nil
                                              contentType:nil
                                                    error:&e];
    if (!statusJSON) {
        DeskCreditsSnapshot *s = [_snapshot copy];
        s.claiming = NO;
        if (!s.needsAuth) {
            s.claimFailed = YES;
            s.lastError = e.localizedDescription ?: @"查询签到状态失败";
            if (!s.hasStatus) s.phase = DeskCreditsPhaseError;
        }
        [self publish:s];
        if (err) *err = e;
        return result;
    }
    DeskCreditsSnapshot *st = DeskCreditsSnapshotByApplyingStatus(_snapshot, statusJSON, &e);
    if (!st) {
        DeskCreditsSnapshot *s = [_snapshot copy];
        s.claiming = NO;
        s.claimFailed = YES;
        s.lastError = e.localizedDescription ?: @"签到状态解析失败";
        [self publish:s];
        if (err) *err = e;
        return result;
    }
    _snapshot = st;
    _lastStatusAt = now;
    st.claiming = YES;
    [self publish:st];

    if (st.todayChecked) {
        result.outcome = DeskCreditsClaimOutcomeAlready;
        result.points = st.todayPoints;
        result.dayNo = st.todayDayNo;
        result.message = @"今日已签，无需重复领取";
        _lastClaimedDayKey = DeskCreditsDayKey(now);
        DeskCreditsSnapshot *s = [_snapshot copy];
        s.claiming = NO;
        s.claimFailed = NO;
        [self publish:s];
        NSError *be = nil;
        if ((_lastBalanceAt == 0 || now - _lastBalanceAt >= 300)
            && [self refreshBalanceOnQueue:&be]) {
            DeskCreditsSnapshot *b = [_snapshot copy];
            b.claiming = NO;
            b.stale = NO;
            b.lastError = nil;
            [self publish:b];
        }
        return result;
    }
    if (!st.hasToday) {
        result.outcome = DeskCreditsClaimOutcomeFailed;
        result.message = @"签到表里没有今天";
        DeskCreditsSnapshot *s = [_snapshot copy];
        s.claiming = NO;
        s.claimFailed = YES;
        s.lastError = result.message;
        [self publish:s];
        if (err) *err = CreditsError(DeskCreditsErrorAPI, @"%@", result.message);
        return result;
    }

    NSDictionary *claimJSON = [self authorizedJSONForURL:kClaimURL
                                                   method:@"POST"
                                                     body:nil
                                              contentType:nil
                                                    error:&e];
    if (!claimJSON) {
        DeskCreditsSnapshot *s = [_snapshot copy];
        s.claiming = NO;
        if (!s.needsAuth) {
            s.claimFailed = YES;
            s.lastError = e.localizedDescription ?: @"领取失败";
        }
        [self publish:s];
        if (err) *err = e;
        return result;
    }
    NSError *pe = nil;
    result = DeskCreditsClaimResultFromResponse(claimJSON, &pe);
    if (result.outcome == DeskCreditsClaimOutcomeClaimed
        || result.outcome == DeskCreditsClaimOutcomeAlready) {
        if (result.points < 0) result.points = st.todayPoints;
        if (result.dayNo <= 0) result.dayNo = st.todayDayNo;
        _lastClaimedDayKey = DeskCreditsDayKey(now);
        DeskCreditsSnapshot *s = [_snapshot copy];
        s.todayChecked = YES;
        if (result.points >= 0) s.todayPoints = result.points;
        if (result.dayNo > 0) s.todayDayNo = result.dayNo;
        NSMutableArray<DeskCreditsDay *> *days = [NSMutableArray arrayWithCapacity:s.days.count];
        for (DeskCreditsDay *d in s.days) {
            DeskCreditsDay *c = [d copy];
            if (c.isToday) {
                c.status = 3;
                if (result.points >= 0) c.points = result.points;
                c.bonusPoints = 0;
            }
            [days addObject:c];
        }
        s.days = days;
        s.phase = DeskCreditsPhaseCheckedIn;
        s.claiming = NO;
        s.claimFailed = NO;
        s.lastError = nil;
        s.stale = NO;
        s.lastSyncAt = now;
        [self publish:s];
        [self note:@"签到%@：+%@（本轮第 %ld 天）",
              result.outcome == DeskCreditsClaimOutcomeClaimed ? @"成功" : @"今日已签",
              DeskCreditsFormatPoints(result.points), (long)result.dayNo];
        NSError *be = nil;
        if ([self refreshBalanceOnQueue:&be]) {
            DeskCreditsSnapshot *b = [_snapshot copy];
            b.claiming = NO;
            b.stale = NO;
            b.lastError = nil;
            [self publish:b];
        } else {
            DeskCreditsSnapshot *b = [_snapshot copy];
            b.claiming = NO;
            if (!b.needsAuth) {
                b.lastError = be.localizedDescription ?: @"余额刷新失败";
                b.stale = YES;
            }
            [self publish:b];
        }
    } else {
        DeskCreditsSnapshot *s = [_snapshot copy];
        s.claiming = NO;
        s.claimFailed = YES;
        s.lastError = result.message ?: @"领取失败";
        [self publish:s];
        if (err) *err = pe ?: CreditsError(DeskCreditsErrorAPI, @"%@", s.lastError);
    }
    return result;
}

- (BOOL)refreshStatusOnQueueWithBalance:(BOOL)withBalance error:(NSError **)err {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    _lastStatusAttemptAt = now;
    DeskCreditsSnapshot *busy = [_snapshot copy];
    busy.refreshing = YES;
    [self publish:busy];

    NSError *e = nil;
    NSDictionary *json = [self authorizedJSONForURL:kStatusURL
                                             method:@"GET"
                                               body:nil
                                            contentType:nil
                                              error:&e];
    if (!json) {
        DeskCreditsSnapshot *s = [_snapshot copy];
        s.refreshing = NO;
        if (!s.needsAuth) {
            s.claiming = NO;
            s.lastError = e.localizedDescription ?: @"刷新失败";
            s.stale = YES;
            if (!s.hasStatus) s.phase = DeskCreditsPhaseError;
        }
        [self publish:s];
        if (err) *err = e;
        return NO;
    }
    NSError *pe = nil;
    DeskCreditsSnapshot *s = DeskCreditsSnapshotByApplyingStatus(_snapshot, json, &pe);
    if (!s) {
        DeskCreditsSnapshot *f = [_snapshot copy];
        f.refreshing = NO;
        f.lastError = pe.localizedDescription ?: @"签到状态解析失败";
        f.stale = YES;
        if (!f.hasStatus) f.phase = DeskCreditsPhaseError;
        [self publish:f];
        if (err) *err = pe;
        return NO;
    }
    s.refreshing = withBalance;
    _snapshot = s;
    _lastStatusAt = now;
    [self publish:s];

    if (withBalance) {
        NSError *be = nil;
        BOOL ok = [self refreshBalanceOnQueue:&be];
        DeskCreditsSnapshot *f = [_snapshot copy];
        f.refreshing = NO;
        if (ok) {
            f.stale = NO;
            f.lastError = nil;
        } else if (!f.needsAuth) {
            f.lastError = be.localizedDescription ?: @"余额刷新失败";
            f.stale = YES;
        }
        [self publish:f];
    } else {
        DeskCreditsSnapshot *f = [_snapshot copy];
        f.refreshing = NO;
        [self publish:f];
    }
    if (err) *err = nil;
    return YES;
}

// —— 调度 ——

- (void)tickOnQueue {
    if (_snapshot.authorizing || _snapshot.needsAuth || !_snapshot.authorized) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *todayKey = DeskCreditsDayKey(now);
    BOOL newDay = ![_snapshot.dayKey isEqualToString:todayKey];
    BOOL statusDue = newDay
        || ((_lastStatusAt == 0 || now - _lastStatusAt >= kStatusRefreshInterval)
            && (_lastStatusAttemptAt == 0 || now - _lastStatusAttemptAt >= kStatusRetryInterval));
    if (statusDue) {
        BOOL withBalance = (_lastBalanceAt == 0
                            || now - _lastBalanceAt >= kBalanceRefreshInterval);
        NSError *e = nil;
        [self refreshStatusOnQueueWithBalance:withBalance error:&e];
        if (e && e.code == DeskCreditsErrorAuth) return;
        now = [NSDate date].timeIntervalSince1970;
    }
    if (_snapshot.hasToday && !_snapshot.todayChecked
        && DeskCreditsAutoClaimWindowOpen(now)) {
        if (_lastClaimAttemptAt == 0 || now - _lastClaimAttemptAt >= kClaimRetryInterval) {
            NSError *e = nil;
            [self claimOnQueue:&e];
        }
        return;
    }
    BOOL balanceDue = (_snapshot.todayChecked
                       && (_lastBalanceAt == 0 || now - _lastBalanceAt >= kBalanceRefreshInterval)
                       && (_lastBalanceAttemptAt == 0
                           || now - _lastBalanceAttemptAt >= kBalanceRetryInterval));
    if (balanceDue) {
        DeskCreditsSnapshot *busy = [_snapshot copy];
        busy.refreshing = YES;
        [self publish:busy];
        NSError *e = nil;
        BOOL ok = [self refreshBalanceOnQueue:&e];
        DeskCreditsSnapshot *s = [_snapshot copy];
        s.refreshing = NO;
        if (!ok && !s.needsAuth) {
            s.lastError = e.localizedDescription ?: @"余额刷新失败";
            s.stale = YES;
        }
        [self publish:s];
    }
}

- (void)start {
    dispatch_async(_queue, ^{
        [self load];
        [self publish:self->_snapshot];
        if (self->_snapshot.authorized && !self->_snapshot.needsAuth) [self tickOnQueue];
    });
}

- (void)tick {
    dispatch_async(_queue, ^{
        [self load];
        [self tickOnQueue];
    });
}

- (void)refreshAsync {
    dispatch_async(_queue, ^{
        [self load];
        if (!self->_snapshot.authorized || self->_snapshot.needsAuth) return;
        NSError *e = nil;
        [self refreshStatusOnQueueWithBalance:YES error:&e];
    });
}

- (void)refreshBalanceAsync {
    dispatch_async(_queue, ^{
        [self load];
        if (!self->_snapshot.authorized || self->_snapshot.needsAuth) return;
        DeskCreditsSnapshot *busy = [self->_snapshot copy];
        busy.refreshing = YES;
        [self publish:busy];
        NSError *e = nil;
        BOOL ok = [self refreshBalanceOnQueue:&e];
        DeskCreditsSnapshot *s = [self->_snapshot copy];
        s.refreshing = NO;
        if (!ok && !s.needsAuth) {
            s.lastError = e.localizedDescription ?: @"余额刷新失败";
            s.stale = YES;
        }
        [self publish:s];
    });
}

- (void)claimAsync {
    dispatch_async(_queue, ^{
        [self load];
        if (!self->_snapshot.authorized || self->_snapshot.needsAuth) {
            [self note:@"尚未授权或登录已过期，无法签到"];
            return;
        }
        NSError *e = nil;
        [self claimOnQueue:&e];
        if (e) [self note:@"签到失败：%@", e.localizedDescription ?: @"未知原因"];
    });
}

// —— 设备码授权 ——

- (void)finishAuthorization:(BOOL)ok error:(NSError *)err {
    _authorizing = NO;
    _pendingDevice = nil;
    DeskCreditsSnapshot *s = [_snapshot copy];
    s.authorizing = NO;
    if (!ok && err) {
        s.lastError = err.localizedDescription;
        if (!s.authorized) s.phase = DeskCreditsPhaseUnknown;
    }
    [self publish:s];
    void (^done)(BOOL, NSError *) = _authCompletion;
    _authCompletion = nil;
    if (done) done(ok, err);
}

- (void)pollDeviceOnQueue {
    if (!_authorizing || !_pendingDevice) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    double expiresAt = [_pendingDevice[@"expiresAt"] doubleValue];
    if (expiresAt > 0 && now >= expiresAt) {
        NSError *e = CreditsError(DeskCreditsErrorAuth, @"授权已超时，请重新发起");
        [self finishAuthorization:NO error:e];
        return;
    }
    NSInteger code = 0;
    NSError *e = nil;
    NSDictionary *json = [self formJSONForURL:kTokenURL
        fields:@{
            @"grant_type": kDeviceGrant,
            @"device_code": _pendingDevice[@"deviceCode"] ?: @"",
            @"client_id": kClientID,
            @"code_verifier": _pendingDevice[@"verifier"] ?: @"",
        }
        status:&code
        error:&e];
    NSString *oauthErr = [json isKindOfClass:[NSDictionary class]] ? json[@"error"] : nil;
    if (code == 400 && ([oauthErr isEqual:@"authorization_pending"]
                        || [oauthErr isEqual:@"slow_down"])) {
        double interval = [_pendingDevice[@"interval"] doubleValue];
        if (!(interval >= 2)) interval = 3;
        if ([oauthErr isEqual:@"slow_down"]) {
            interval = MIN(interval + 5, 30);
            _pendingDevice[@"interval"] = @(interval);
        }
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                       _queue, ^{ [weakSelf pollDeviceOnQueue]; });
        return;
    }
    if ([oauthErr isEqual:@"expired_token"]) {
        [self finishAuthorization:NO
                            error:CreditsError(DeskCreditsErrorAuth, @"授权已超时，请重新发起")];
        return;
    }
    if ([oauthErr isEqual:@"access_denied"]) {
        [self finishAuthorization:NO
                            error:CreditsError(DeskCreditsErrorAuth, @"授权被拒绝")];
        return;
    }
    NSString *at = [json isKindOfClass:[NSDictionary class]] ? json[@"access_token"] : nil;
    if (![at isKindOfClass:[NSString class]] || at.length == 0) {
        [self finishAuthorization:NO
                            error:e ?: CreditsError(DeskCreditsErrorAuth, @"授权失败")];
        return;
    }
    double expiresIn = NumberOr(json[@"expires_in"], 3600);
    if (!(expiresIn > 0)) expiresIn = 3600;
    id rt = json[@"refresh_token"];
    id tt = json[@"token_type"];
    NSMutableDictionary *auth = [@{
        @"schemaVersion": @1,
        @"accessToken": at,
        @"expiresAtMs": @((now + expiresIn) * 1000.0),
        @"tokenType": [tt isKindOfClass:[NSString class]] ? tt : @"Bearer",
        @"clientId": kClientID,
        @"scopes": @[kScope],
        @"audience": kAudience,
        @"loginEpoch": [NSUUID UUID].UUIDString,
        @"generation": @1,
        @"savedAt": @(now * 1000.0),
        @"needsAuth": @NO,
    } mutableCopy];
    if ([rt isKindOfClass:[NSString class]] && [rt length]) auth[@"refreshToken"] = rt;
    if (![self saveAuth:auth]) {
        [self finishAuthorization:NO
                            error:CreditsError(DeskCreditsErrorMissing, @"授权成功但凭据无法落盘")];
        return;
    }
    DeskCreditsSnapshot *s = [_snapshot copy];
    s.authorized = YES;
    s.needsAuth = NO;
    s.authorizing = NO;
    s.claimFailed = NO;
    s.lastError = nil;
    s.days = @[];
    s.hasStatus = NO;
    s.hasToday = NO;
    s.todayDayNo = 0;
    s.todayChecked = NO;
    s.todayPoints = -1;
    s.balance = -1;
    s.freeBalance = -1;
    s.purchasedBalance = -1;
    s.planTier = nil;
    s.lastSyncAt = 0;
    s.stale = NO;
    s.phase = DeskCreditsPhaseUnknown;
    s.dayKey = @"";
    _snapshot = s;
    _lastStatusAt = 0;
    _lastStatusAttemptAt = 0;
    _lastBalanceAt = 0;
    _lastBalanceAttemptAt = 0;
    _lastClaimAttemptAt = 0;
    _lastClaimedDayKey = nil;
    [self note:@"浏览器授权完成，凭据只存本机（不影响 MiniMax Code 桌面客户端）"];
    [self finishAuthorization:YES error:nil];
    [self tickOnQueue];
}

- (void)beginAuthorizationWithURLHandler:(void (^_Nullable)(NSString *url))urlHandler
                              completion:(void (^_Nullable)(BOOL ok, NSError *_Nullable err))completion {
    dispatch_async(_queue, ^{
        [self load];
        if (self->_authorizing) {
            if (completion) {
                completion(NO, CreditsError(DeskCreditsErrorAuth, @"正在等待浏览器授权"));
            }
            return;
        }
        self->_authorizing = YES;
        self->_authCompletion = [completion copy];
        DeskCreditsSnapshot *s = [self->_snapshot copy];
        s.authorizing = YES;
        s.lastError = nil;
        [self publish:s];

        NSString *verifier = DeskCreditsPKCEVerifier();
        NSInteger code = 0;
        NSError *e = nil;
        NSDictionary *json = [self formJSONForURL:kDeviceCodeURL
            fields:@{
                @"client_id": kClientID,
                @"scope": kScope,
                @"audience": kAudience,
                @"code_challenge": DeskCreditsPKCEChallenge(verifier),
                @"code_challenge_method": @"S256",
            }
            status:&code
            error:&e];
        NSString *url = [json isKindOfClass:[NSDictionary class]]
            ? json[@"verification_uri_complete"] : nil;
        NSString *deviceCode = [json isKindOfClass:[NSDictionary class]]
            ? json[@"device_code"] : nil;
        if (![url isKindOfClass:[NSString class]] || ![url hasPrefix:@"https://"]
            || ![deviceCode isKindOfClass:[NSString class]] || deviceCode.length == 0) {
            NSString *why = e.localizedDescription
                ?: [NSString stringWithFormat:@"设备码初始化失败（HTTP %ld）", (long)code];
            [self finishAuthorization:NO
                                error:CreditsError(DeskCreditsErrorAuth, @"%@", why)];
            return;
        }
        double expiresIn = NumberOr(json[@"expires_in"], 300);
        if (!(expiresIn >= 60)) expiresIn = 300;
        double interval = NumberOr(json[@"interval"], 3);
        if (!(interval >= 2)) interval = 3;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        self->_pendingDevice = [@{
            @"deviceCode": deviceCode,
            @"verifier": verifier,
            @"interval": @(interval),
            @"expiresAt": @(now + expiresIn),
        } mutableCopy];
        [self note:@"已生成浏览器授权页，等待你完成登录（300 秒内有效）"];
        if (urlHandler) urlHandler(url);
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                       self->_queue, ^{ [weakSelf pollDeviceOnQueue]; });
    });
}

- (void)cancelAuthorization {
    dispatch_async(_queue, ^{
        if (!self->_authorizing) return;
        [self note:@"已取消等待浏览器授权"];
        [self finishAuthorization:NO
                            error:CreditsError(DeskCreditsErrorAuth, @"授权已取消")];
    });
}

// —— 同步口（命令行） ——

- (BOOL)refreshSyncWithBalance:(BOOL)withBalance error:(NSError *_Nullable *_Nullable)err {
    [self load];
    return [self refreshStatusOnQueueWithBalance:withBalance error:err];
}

- (BOOL)refreshBalanceSync:(NSError *_Nullable *_Nullable)err {
    [self load];
    DeskCreditsSnapshot *busy = [_snapshot copy];
    busy.refreshing = YES;
    [self publish:busy];
    NSError *e = nil;
    BOOL ok = [self refreshBalanceOnQueue:&e];
    DeskCreditsSnapshot *s = [_snapshot copy];
    s.refreshing = NO;
    if (!ok && !s.needsAuth) {
        s.lastError = e.localizedDescription ?: @"余额刷新失败";
        s.stale = YES;
    }
    [self publish:s];
    if (err) *err = e;
    return ok;
}

- (DeskCreditsClaimResult *)claimSync:(NSError *_Nullable *_Nullable)err {
    [self load];
    return [self claimOnQueue:err];
}

- (void)ingestStatusForVerify:(NSDictionary *)json error:(NSError *_Nullable *_Nullable)err {
    [self load];
    NSError *e = nil;
    DeskCreditsSnapshot *base = [_snapshot copy];
    base.authorized = YES;
    DeskCreditsSnapshot *s = DeskCreditsSnapshotByApplyingStatus(base, json, &e);
    if (s) {
        s.authorized = YES;
        _snapshot = s;
        [self publish:s];
    }
    if (err) *err = e;
}

@end
