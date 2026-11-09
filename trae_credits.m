// Trae（国内版）签到：本机 storage.json 登录态 + 官方 checkin_credits 接口。
// 只读登录态；绝不做 ExchangeToken 续期（会轮换 refreshToken 并把 IDE 踢下线）。
#import "trae_credits.h"
#import <CommonCrypto/CommonCrypto.h>

static NSError *TraeError(DeskCreditsErrorCode code, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *TraeError(DeskCreditsErrorCode code, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:DeskCreditsErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static BOOL TraeBool(id v, BOOL fallback) {
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : fallback;
}

static double TraeNumber(id v, double fallback) {
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return fallback;
}

static NSString *TraeString(id v) {
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSInteger TraeInteger(id v, NSInteger fallback) {
    if ([v isKindOfClass:[NSNumber class]]) return [v integerValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v integerValue];
    return fallback;
}

#pragma mark - storage.json 解密

// 两段常量异或后作为 SHA-512 的固定盐；信封格式：6 字节头 + 32 字节随机盐 + AES-128-CBC。
// 算法来自客户端本地解密链，已用真实 storage.json 解出可用的 Cloud-IDE-JWT 验证过。
static const unsigned char kTraeSaltA[64] = {
    82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,124,227,57,130,
    155,47,255,135,52,142,67,68,196,222,233,203,84,123,148,50,166,194,35,61,
    238,76,149,11,66,250,195,78,8,46,161,102,40,217,36,178,118,91,162,73,109,
    139,209,37
};
static const unsigned char kTraeSaltB[64] = {
    31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,96,81,127,169,25,
    181,74,13,45,229,122,159,147,201,156,239,160,224,59,77,174,42,245,176,200,
    235,187,60,131,83,153,97,23,43,4,126,186,119,214,38,225,105,20,99,85,33,
    12,125
};

NSData *DeskTraeDecryptStorageValue(NSString *base64, NSError **err) {
    if (base64.length == 0) {
        if (err) *err = TraeError(DeskCreditsErrorMissing, @"storage.json 里没有 iCubeAuthInfo 密文");
        return nil;
    }
    NSData *buf = [[NSData alloc] initWithBase64EncodedString:base64
                                                     options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (buf.length < 38 + 16) {
        if (err) *err = TraeError(DeskCreditsErrorJSON, @"登录态密文长度不对（%lu 字节）",
                                  (unsigned long)buf.length);
        return nil;
    }
    NSData *randomSalt = [buf subdataWithRange:NSMakeRange(6, 32)];
    NSData *cipher = [buf subdataWithRange:NSMakeRange(38, buf.length - 38)];

    unsigned char h[CC_SHA512_DIGEST_LENGTH];
    CC_SHA512(randomSalt.bytes, (CC_LONG)randomSalt.length, h);
    unsigned char salt[64];
    for (int i = 0; i < 64; i++) salt[i] = kTraeSaltA[i] ^ kTraeSaltB[i];
    NSMutableData *seed = [NSMutableData dataWithBytes:h length:CC_SHA512_DIGEST_LENGTH];
    [seed appendBytes:salt length:sizeof(salt)];
    unsigned char kdf[CC_SHA512_DIGEST_LENGTH];
    CC_SHA512(seed.bytes, (CC_LONG)seed.length, kdf);

    size_t outLen = 0;
    NSMutableData *plain = [NSMutableData dataWithLength:cipher.length + kCCBlockSizeAES128];
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES, 0,
                                 kdf, kCCKeySizeAES128, kdf + kCCKeySizeAES128,
                                 cipher.bytes, cipher.length,
                                 plain.mutableBytes, plain.length, &outLen);
    if (st != kCCSuccess || outLen < 65) {
        if (err) *err = TraeError(DeskCreditsErrorJSON, @"登录态解密失败");
        return nil;
    }
    [plain setLength:outLen];
    NSData *body = [plain subdataWithRange:NSMakeRange(64, plain.length - 64)];

    // 新版写盘用 PKCS7，老版本可能用零填充
    const unsigned char *b = body.bytes;
    NSUInteger n = body.length;
    unsigned char pad = n ? b[n - 1] : 0;
    if (pad >= 1 && pad <= 16) {
        n -= pad;
    } else {
        while (n > 0 && b[n - 1] == 0) n--;
    }
    return [body subdataWithRange:NSMakeRange(0, n)];
}

NSString *DeskTraeDefaultStoragePath(void) {
    NSString *home = NSHomeDirectory();
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *lib = [home stringByAppendingPathComponent:@"Library/Application Support"];
    for (NSString *name in @[@"Trae CN", @"TRAE SOLO CN", @"TRAE SOLO", @"Trae"]) {
        [paths addObject:[[lib stringByAppendingPathComponent:name]
                          stringByAppendingPathComponent:@"User/globalStorage/storage.json"]];
    }
    for (NSString *name in @[@".trae-cn", @".trae", @"Trae CN"]) {
        [paths addObject:[[home stringByAppendingPathComponent:name]
                          stringByAppendingPathComponent:@"User/globalStorage/storage.json"]];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in paths) if ([fm fileExistsAtPath:p]) return p;
    return nil;
}

static BOOL TraeLooksLikeDeviceId(NSString *s) {
    if (s.length < 12 || s.length > 20) return NO;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [s rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

static BOOL TraeDecodeJWTPayload(NSString *token, NSDictionary **out) {
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count < 2) return NO;
    NSString *p = [parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    p = [p stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (p.length % 4) p = [p stringByAppendingString:@"="];
    NSData *d = [[NSData alloc] initWithBase64EncodedString:p options:0];
    if (!d) return NO;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return NO;
    if (out) *out = obj;
    return YES;
}

NSDictionary *DeskTraeStorageCredentials(NSDictionary *storage, NSError **err) {
    if (![storage isKindOfClass:[NSDictionary class]]) {
        if (err) *err = TraeError(DeskCreditsErrorJSON, @"storage.json 不是 JSON 对象");
        return nil;
    }
    NSData *plain = DeskTraeDecryptStorageValue(TraeString(storage[@"iCubeAuthInfo://icube.cloudide"]), err);
    if (!plain) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:plain options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (err) *err = TraeError(DeskCreditsErrorJSON, @"登录态解密后不是 JSON 对象");
        return nil;
    }
    NSDictionary *auth = obj;
    NSString *token = TraeString(auth[@"token"]);
    if (token.length == 0) {
        if (err) *err = TraeError(DeskCreditsErrorAuth, @"storage.json 里没有 token（先在 Trae 里登录一次）");
        return nil;
    }
    NSString *uid = TraeString(auth[@"userId"]);
    if (uid.length == 0) {
        NSDictionary *payload = nil;
        if (TraeDecodeJWTPayload(token, &payload)) {
            NSDictionary *data = [payload[@"data"] isKindOfClass:[NSDictionary class]] ? payload[@"data"] : nil;
            uid = TraeString(data[@"user_id"]) ?: TraeString(data[@"userId"]);
        }
    }

    // 昵称在 account.username 里；老版本可能平铺在顶层
    NSString *nickname = TraeString(auth[@"username"]);
    if (nickname.length == 0) {
        id acct = auth[@"account"];
        if ([acct isKindOfClass:[NSDictionary class]]) {
            nickname = TraeString(((NSDictionary *)acct)[@"username"]);
        }
    }

    NSString *deviceId = nil;
    for (NSString *key in storage) {
        if (![key hasPrefix:@"iCubeAuthInfo://icube-dc:"]) continue;
        NSString *d = [key substringFromIndex:@"iCubeAuthInfo://icube-dc:".length];
        if (TraeLooksLikeDeviceId(d)) { deviceId = d; break; }
    }

    NSString *plan = nil;
    NSString *serverData = TraeString(storage[@"iCubeServerData://icube.cloudide"]);
    if (serverData.length) {
        id sd = [NSJSONSerialization JSONObjectWithData:[serverData dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0 error:NULL];
        if ([sd isKindOfClass:[NSDictionary class]]) {
            id ent = ((NSDictionary *)sd)[@"entitlementInfo"];
            if ([ent isKindOfClass:[NSDictionary class]]) plan = TraeString(((NSDictionary *)ent)[@"identityStr"]);
        }
    }

    NSTimeInterval exp = 0, iat = 0;
    NSDictionary *payload = nil;
    if (TraeDecodeJWTPayload(token, &payload)) {
        exp = TraeNumber(payload[@"exp"], 0);
        iat = TraeNumber(payload[@"iat"], 0);
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"token"] = token;
    if (uid.length) out[@"uid"] = uid;
    if (nickname.length) out[@"nickname"] = nickname;
    if (deviceId.length) out[@"deviceId"] = deviceId;
    if (plan.length) out[@"planTier"] = plan;
    NSString *host = TraeString(auth[@"host"]);
    if (host.length) out[@"host"] = host;
    if (exp > 0) out[@"expiresAt"] = @(exp);
    if (iat > 0) out[@"issuedAt"] = @(iat);
    return out;
}

DeskCreditsClaimResult *DeskTraeClaimResultFromResponse(NSDictionary *json) {
    DeskCreditsClaimResult *r = [DeskCreditsClaimResult new];
    r.outcome = DeskCreditsClaimOutcomeFailed;
    r.points = -1;
    r.dayNo = 0;
    if (![json isKindOfClass:[NSDictionary class]]) {
        r.message = @"领取返回不是 JSON 对象";
        return r;
    }
    NSInteger code = TraeInteger(json[@"code"], -1);
    NSString *message = TraeString(json[@"message"]) ?: @"";
    if (code == 0) {
        r.outcome = DeskCreditsClaimOutcomeClaimed;
        return r;
    }
    if ([message containsString:@"已签"] || [message.lowercaseString containsString:@"already"]) {
        r.outcome = DeskCreditsClaimOutcomeAlready;
        r.message = message.length ? message : @"今日已签";
        return r;
    }
    r.message = [NSString stringWithFormat:@"%ld %@", (long)code, message];
    if (code == 9074 || code == 9095 || code == 9004) {
        r.message = [r.message stringByAppendingString:@"（设备校验未通过）"];
    }
    return r;
}

BOOL DeskTraeShouldAutoClaim(DeskTraeSnapshot *s, NSTimeInterval now) {
    if (!s.connected || s.phase == DeskTraePhaseNeedsAuth) return NO;
    if (!s.hasStatus || !s.enabled) return NO;
    if (s.checkedIn || s.claiming) return NO;
    return DeskCreditsAutoClaimWindowOpen(now);
}

#pragma mark - 快照
@implementation DeskTraeSnapshot

- (instancetype)init {
    if ((self = [super init])) {
        _todayCredits = -1;
        _balance = -1;
        _consumed = -1;
        _total = -1;
        _planTier = @"";
        _dayKey = @"";
    }
    return self;
}

- (double)loginDays {
    if (_tokenExpiresAt <= 0) return 0;
    double left = (_tokenExpiresAt - [NSDate date].timeIntervalSince1970) / 86400.0;
    return MAX(0.0, left);
}

- (BOOL)loginWarn {
    return _tokenExpiresAt > 0 && [self loginDays] < 7.0;
}

- (id)copyWithZone:(NSZone *)zone {
    DeskTraeSnapshot *c = [DeskTraeSnapshot new];
    c.phase = _phase;
    c.connected = _connected;
    c.uid = _uid;
    c.nickname = _nickname;
    c.planTier = _planTier;
    c.deviceId = _deviceId;
    c.tokenExpiresAt = _tokenExpiresAt;
    c.tokenSpanDays = _tokenSpanDays;
    c.hasStatus = _hasStatus;
    c.enabled = _enabled;
    c.checkedIn = _checkedIn;
    c.todayCredits = _todayCredits;
    c.extraCredits = _extraCredits;
    c.balance = _balance;
    c.consumed = _consumed;
    c.total = _total;
    c.claiming = _claiming;
    c.claimFailed = _claimFailed;
    c.refreshing = _refreshing;
    c.lastSyncAt = _lastSyncAt;
    c.lastError = _lastError;
    c.dayKey = _dayKey;
    return c;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"phase"] = @(_phase);
    d[@"connected"] = @(_connected);
    if (_uid) d[@"uid"] = _uid;
    if (_nickname) d[@"nickname"] = _nickname;
    if (_planTier) d[@"plan"] = _planTier;
    d[@"exp"] = @(_tokenExpiresAt);
    d[@"span"] = @(_tokenSpanDays);
    d[@"hasStatus"] = @(_hasStatus);
    d[@"enabled"] = @(_enabled);
    d[@"checkedIn"] = @(_checkedIn);
    d[@"today"] = @(_todayCredits);
    d[@"extra"] = @(_extraCredits);
    d[@"balance"] = @(_balance);
    d[@"consumed"] = @(_consumed);
    d[@"total"] = @(_total);
    d[@"lastSyncAt"] = @(_lastSyncAt);
    d[@"dayKey"] = _dayKey ?: @"";
    if (_lastError) d[@"error"] = _lastError;
    return d;
}

+ (instancetype)snapshotWithDictionary:(NSDictionary *)d {
    DeskTraeSnapshot *s = [DeskTraeSnapshot new];
    if (![d isKindOfClass:[NSDictionary class]]) return s;
    s.phase = (DeskTraePhase)TraeInteger(d[@"phase"], 0);
    s.connected = TraeBool(d[@"connected"], NO);
    s.uid = TraeString(d[@"uid"]) ?: @"";
    s.nickname = TraeString(d[@"nickname"]) ?: @"";
    s.planTier = TraeString(d[@"plan"]) ?: @"";
    s.tokenExpiresAt = TraeNumber(d[@"exp"], 0);
    s.tokenSpanDays = TraeNumber(d[@"span"], 0);
    s.hasStatus = TraeBool(d[@"hasStatus"], NO);
    s.enabled = TraeBool(d[@"enabled"], NO);
    s.checkedIn = TraeBool(d[@"checkedIn"], NO);
    s.todayCredits = TraeNumber(d[@"today"], -1);
    s.extraCredits = TraeNumber(d[@"extra"], 0);
    s.balance = TraeNumber(d[@"balance"], -1);
    s.consumed = TraeNumber(d[@"consumed"], -1);
    s.total = TraeNumber(d[@"total"], -1);
    s.lastSyncAt = TraeNumber(d[@"lastSyncAt"], 0);
    s.dayKey = TraeString(d[@"dayKey"]) ?: @"";
    s.lastError = TraeString(d[@"error"]);
    return s;
}

@end

#pragma mark - Provider

@implementation DeskTraeCredits {
    dispatch_queue_t _queue;
    DeskTraeSnapshot *_snapshot;
    NSString *_token, *_uid, *_deviceId, *_nickname, *_planTier, *_host;
    NSTimeInterval _tokenExpiresAt, _tokenIssuedAt;
    NSString *_statePath;
    NSTimeInterval _lastClaimAttempt;
    NSString *_lastClaimDay;
    NSInteger _claimAttempts;
}

- (instancetype)init {
    return [self initWithStoragePath:nil statePath:nil];
}

- (instancetype)initWithStoragePath:(NSString *)storagePath statePath:(NSString *)statePath {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.hujie.deskboard.trae", DISPATCH_QUEUE_SERIAL);
        _snapshot = [DeskTraeSnapshot new];
        _storagePath = [(storagePath.length ? storagePath : DeskTraeDefaultStoragePath()) copy] ?: @"";
        if (statePath.length) {
            _statePath = [statePath copy];
        } else {
            NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                                 NSUserDomainMask, YES).firstObject;
            _statePath = [[[base stringByAppendingPathComponent:@"DeskBoard/Credits"]
                           stringByAppendingPathComponent:@"trae_state.json"] copy];
        }
    }
    return self;
}

- (DeskTraeSnapshot *)snapshot {
    @synchronized (self) { return _snapshot; }
}

- (void)note:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    void (^handler)(NSString *) = _onLog;
    if (handler) handler(msg);
}

- (void)publish:(DeskTraeSnapshot *)s {
    DeskTraeSnapshot *copy = [s copy];
    @synchronized (self) { _snapshot = copy; }
    if (_onChange) _onChange(copy);
    [self persist:copy];
}

- (void)persist:(DeskTraeSnapshot *)s {
    if (_statePath.length == 0) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:[s dictionaryRepresentation]
                                                options:NSJSONWritingPrettyPrinted error:NULL];
    if (!d) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:[_statePath stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    [d writeToFile:_statePath options:NSDataWritingAtomic error:NULL];
}

// 读 storage.json，把 token/uid/设备号/套餐装进 ivar。IDE 续期后这里能跟着换上新 token。
- (BOOL)reloadCredentials:(NSError **)err {
    if (_storagePath.length == 0) {
        if (err) *err = TraeError(DeskCreditsErrorMissing, @"没找到 Trae 的 storage.json（先打开 Trae 登录一次）");
        return NO;
    }
    NSData *data = [NSData dataWithContentsOfFile:_storagePath];
    if (!data) {
        if (err) *err = TraeError(DeskCreditsErrorMissing, @"读不到 %@", _storagePath.lastPathComponent);
        return NO;
    }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (err) *err = TraeError(DeskCreditsErrorJSON, @"storage.json 解析失败");
        return NO;
    }
    NSDictionary *creds = DeskTraeStorageCredentials(obj, err);
    if (!creds) return NO;
    @synchronized (self) {
        _token = creds[@"token"];
        _uid = creds[@"uid"] ?: @"";
        _deviceId = creds[@"deviceId"] ?: @"";
        _nickname = creds[@"nickname"] ?: @"";
        _planTier = creds[@"planTier"] ?: @"";
        _host = creds[@"host"] ?: @"https://api.trae.cn";
        _tokenExpiresAt = TraeNumber(creds[@"expiresAt"], 0);
        _tokenIssuedAt = TraeNumber(creds[@"issuedAt"], 0);
    }
    return YES;
}

- (void)applyCredentialsTo:(DeskTraeSnapshot *)s {
    @synchronized (self) {
        s.connected = _token.length > 0;
        s.uid = _uid ?: @"";
        s.nickname = _nickname ?: @"";
        s.planTier = _planTier.length ? _planTier : @"";
        s.deviceId = _deviceId ?: @"";
        s.tokenExpiresAt = _tokenExpiresAt;
        double span = (_tokenExpiresAt > _tokenIssuedAt && _tokenIssuedAt > 0)
            ? (_tokenExpiresAt - _tokenIssuedAt) / 86400.0 : 14.0;
        s.tokenSpanDays = span > 0 ? span : 14.0;
    }
}

- (BOOL)tokenExpired {
    @synchronized (self) {
        return _tokenExpiresAt > 0 && _tokenExpiresAt <= [NSDate date].timeIntervalSince1970;
    }
}

- (BOOL)load {
    NSError *err = nil;
    NSData *state = _statePath.length ? [NSData dataWithContentsOfFile:_statePath] : nil;
    DeskTraeSnapshot *s = state ? [DeskTraeSnapshot snapshotWithDictionary:
        ([NSJSONSerialization JSONObjectWithData:state options:0 error:NULL] ?: @{})]
        : [DeskTraeSnapshot new];
    BOOL ok = [self reloadCredentials:&err];
    [self applyCredentialsTo:s];
    if (!ok) {
        s.connected = NO;
        s.phase = DeskTraePhaseNeedsAuth;
        s.lastError = err.localizedDescription;
    } else if ([self tokenExpired]) {
        s.phase = DeskTraePhaseNeedsAuth;
        s.lastError = @"登录令牌已过期，打开 Trae 重新登录后自动恢复";
    } else if (s.phase == DeskTraePhaseUnknown) {
        s.phase = s.hasStatus ? DeskTraePhaseReady : DeskTraePhaseUnknown;
    }
    // 跨天：状态要重新拉，不能拿昨天的「已签」冒充今天
    NSString *today = DeskCreditsDayKey([NSDate date].timeIntervalSince1970);
    if (![s.dayKey isEqualToString:today]) {
        s.checkedIn = NO;
        s.todayCredits = -1;
        s.extraCredits = 0;
        s.hasStatus = NO;
        s.dayKey = today;
    }
    [self publish:s];
    if (ok) {
        [self note:@"登录态：uid=%@ 套餐=%@ 令牌剩 %.0f 天 · 设备号 %lu 位",
              s.uid.length ? s.uid : @"—",
              s.planTier.length ? s.planTier : @"—",
              s.loginDays, (unsigned long)s.deviceId.length];
    } else {
        [self note:@"登录态不可用：%@", err.localizedDescription ?: @"未知原因"];
    }
    return ok;
}

#pragma mark 网络

- (NSDictionary *)postPath:(NSString *)path
                      body:(NSDictionary *)body
                     error:(NSError **)err {
    NSString *token = nil, *deviceId = nil, *uid = nil, *host = nil;
    @synchronized (self) {
        token = _token;
        deviceId = _deviceId;
        uid = _uid;
        host = _host.length ? _host : @"https://api.trae.cn";
    }
    if (token.length == 0) {
        if (err) *err = TraeError(DeskCreditsErrorAuth, @"没有登录令牌");
        return nil;
    }
    NSURL *url = [NSURL URLWithString:[host stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Cloud-IDE-JWT " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    if (deviceId.length) [req setValue:deviceId forHTTPHeaderField:@"x-device-id"];
    if (uid.length) [req setValue:uid forHTTPHeaderField:@"x-user-id"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body ?: @{} options:0 error:NULL];

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
        if (err) *err = TraeError(DeskCreditsErrorNetwork, @"网络失败：%@", netErr.localizedDescription);
        return nil;
    }
    if (status != 200) {
        if (err) *err = TraeError(DeskCreditsErrorHTTP, @"HTTP %ld", (long)status);
        return nil;
    }
    id obj = payload ? [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL] : nil;
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (err) *err = TraeError(DeskCreditsErrorJSON, @"接口返回不是 JSON 对象");
        return nil;
    }
    return obj;
}

- (BOOL)applyStatusJSON:(NSDictionary *)json to:(DeskTraeSnapshot *)s error:(NSError **)err {
    NSInteger code = TraeInteger(json[@"code"], 0);
    NSString *message = TraeString(json[@"message"]) ?: @"";
    if (code != 0) {
        if (err) *err = TraeError(DeskCreditsErrorAPI, @"签到接口失败：%ld %@", (long)code, message);
        return NO;
    }
    s.hasStatus = YES;
    s.enabled = TraeBool(json[@"enable"], NO);
    s.checkedIn = TraeBool(json[@"checked_in"], NO);
    s.todayCredits = TraeNumber(json[@"credits"], -1);
    s.extraCredits = TraeNumber(json[@"extra_credits"], 0);
    s.dayKey = DeskCreditsDayKey([NSDate date].timeIntervalSince1970);
    return YES;
}

- (BOOL)applyBalanceJSON:(NSDictionary *)json to:(DeskTraeSnapshot *)s error:(NSError **)err {
    id summary = json[@"usage_summary"];
    if (![summary isKindOfClass:[NSDictionary class]]) {
        if (err) *err = TraeError(DeskCreditsErrorJSON, @"余额接口缺少 usage_summary");
        return NO;
    }
    double total = TraeNumber(((NSDictionary *)summary)[@"total_amount"], -1);
    double consumed = TraeNumber(((NSDictionary *)summary)[@"consumed_amount"], -1);
    if (total < 0 || consumed < 0) {
        if (err) *err = TraeError(DeskCreditsErrorJSON, @"余额字段不是数字");
        return NO;
    }
    s.total = total;
    s.consumed = consumed;
    s.balance = MAX(0.0, total - consumed);
    return YES;
}

- (BOOL)refreshSyncWithBalance:(BOOL)withBalance error:(NSError **)err {
    NSError *cerr = nil;
    DeskTraeSnapshot *s = [self.snapshot copy];
    if (![self reloadCredentials:&cerr]) {
        [self applyCredentialsTo:s];
        s.connected = NO;
        s.phase = DeskTraePhaseNeedsAuth;
        s.lastError = cerr.localizedDescription;
        [self publish:s];
        if (err) *err = cerr;
        return NO;
    }
    [self applyCredentialsTo:s];
    if ([self tokenExpired]) {
        s.phase = DeskTraePhaseNeedsAuth;
        s.lastError = @"登录令牌已过期，打开 Trae 重新登录后自动恢复";
        [self publish:s];
        if (err) *err = TraeError(DeskCreditsErrorAuth, @"%@", s.lastError);
        return NO;
    }

    s.refreshing = YES;
    s.connected = YES;
    [self publish:s];

    NSError *aerr = nil;
    NSDictionary *statusJSON = [self postPath:@"/trae/api/v2/ug/checkin_credits/status"
                                        body:@{@"req_source": @1} error:&aerr];
    if (!statusJSON || ![self applyStatusJSON:statusJSON to:s error:&aerr]) {
        s.refreshing = NO;
        s.phase = DeskTraePhaseError;
        s.lastError = aerr.localizedDescription ?: @"签到状态刷新失败";
        [self publish:s];
        if (err) *err = aerr;
        return NO;
    }
    if (withBalance) {
        NSError *berr = nil;
        NSDictionary *balanceJSON = [self postPath:@"/trae/api/v2/pay/ide_user_ent_usage"
                                             body:@{@"require_usage": @YES, @"req_source": @1}
                                            error:&berr];
        // 余额失败不推翻签到状态：状态已经拿到了，余额退化成「—」
        if (balanceJSON) [self applyBalanceJSON:balanceJSON to:s error:NULL];
        else [self note:@"余额刷新失败：%@", berr.localizedDescription ?: @"未知原因"];
    }
    s.refreshing = NO;
    s.phase = DeskTraePhaseReady;
    s.lastSyncAt = [NSDate date].timeIntervalSince1970;
    s.lastError = nil;
    s.dayKey = DeskCreditsDayKey(s.lastSyncAt);
    [self publish:s];
    [self note:@"状态：%@ · 今日 %@ · 余额 %@",
          s.checkedIn ? @"已签" : (s.enabled ? @"待签" : @"活动未开启"),
          s.todayCredits >= 0 ? [NSString stringWithFormat:@"+%.0f", s.todayCredits] : @"—",
          s.balance >= 0 ? [NSString stringWithFormat:@"%.0f 积分", s.balance] : @"—"];
    return YES;
}

- (DeskCreditsClaimResult *)claimSync:(NSError **)err {
    DeskCreditsClaimResult *r = [DeskCreditsClaimResult new];
    r.outcome = DeskCreditsClaimOutcomeFailed;
    r.points = -1;
    r.dayNo = 0;

    NSError *cerr = nil;
    DeskTraeSnapshot *s = [self.snapshot copy];
    if (![self reloadCredentials:&cerr]) {
        [self applyCredentialsTo:s];
        s.connected = NO;
        s.phase = DeskTraePhaseNeedsAuth;
        s.lastError = cerr.localizedDescription;
        [self publish:s];
        r.outcome = DeskCreditsClaimOutcomeNotAuthorized;
        r.message = cerr.localizedDescription;
        if (err) *err = cerr;
        return r;
    }
    [self applyCredentialsTo:s];
    if ([self tokenExpired]) {
        s.phase = DeskTraePhaseNeedsAuth;
        s.lastError = @"登录令牌已过期，打开 Trae 重新登录后自动恢复";
        [self publish:s];
        r.outcome = DeskCreditsClaimOutcomeNotAuthorized;
        r.message = s.lastError;
        if (err) *err = TraeError(DeskCreditsErrorAuth, @"%@", s.lastError);
        return r;
    }
    if (s.checkedIn) {
        r.outcome = DeskCreditsClaimOutcomeAlready;
        r.points = s.todayCredits;
        r.message = @"今日已签";
        return r;
    }

    s.claiming = YES;
    s.claimFailed = NO;
    [self publish:s];

    NSError *aerr = nil;
    NSDictionary *json = [self postPath:@"/trae/api/v2/ug/checkin_credits/claim"
                                   body:@{@"req_source": @1} error:&aerr];
    s = [self.snapshot copy];
    s.claiming = NO;
    if (!json) {
        s.claimFailed = YES;
        s.phase = DeskTraePhaseError;
        s.lastError = aerr.localizedDescription ?: @"签到请求失败";
        [self publish:s];
        r.message = s.lastError;
        if (err) *err = aerr;
        return r;
    }

    DeskCreditsClaimResult *parsed = DeskTraeClaimResultFromResponse(json);
    r.outcome = parsed.outcome;
    r.message = parsed.message;
    if (parsed.outcome == DeskCreditsClaimOutcomeClaimed) {
        r.points = s.todayCredits;
        s.checkedIn = YES;
        s.claimFailed = NO;
        s.lastError = nil;
        s.dayKey = DeskCreditsDayKey([NSDate date].timeIntervalSince1970);
        s.lastSyncAt = [NSDate date].timeIntervalSince1970;
        [self publish:s];
        [self note:@"签到成功：+%@%@", r.points >= 0 ? [NSString stringWithFormat:@"%.0f", r.points] : @"—",
              s.extraCredits > 0 ? [NSString stringWithFormat:@"（额外 +%.0f）", s.extraCredits] : @""];
        // 余额与今日额度跟着刷新一次
        [self refreshSyncWithBalance:YES error:NULL];
        return r;
    }
    if (parsed.outcome == DeskCreditsClaimOutcomeAlready) {
        r.points = s.todayCredits;
        s.checkedIn = YES;
        s.claimFailed = NO;
        [self publish:s];
        [self note:@"今日已签（%@）", r.message ?: @"接口认定已签"];
        return r;
    }
    s.claimFailed = YES;
    s.phase = DeskTraePhaseError;
    s.lastError = r.message;
    [self publish:s];
    [self note:@"签到失败：%@", r.message];
    if (err) *err = TraeError(DeskCreditsErrorAPI, @"%@", r.message);
    return r;
}

#pragma mark 调度

- (BOOL)claimThrottled:(NSTimeInterval)now {
    NSString *today = DeskCreditsDayKey(now);
    if (![_lastClaimDay isEqualToString:today]) {
        _lastClaimDay = today;
        _claimAttempts = 0;
        _lastClaimAttempt = 0;
    }
    if (_claimAttempts >= 3) return YES;                       // 一天最多试三次，别把 9074 刷成风控
    if (_lastClaimAttempt > 0 && now - _lastClaimAttempt < 1800) return YES;  // 失败后隔 30 分钟
    _lastClaimAttempt = now;
    _claimAttempts++;
    return NO;
}

- (void)tickOnQueue {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    DeskTraeSnapshot *s = [self.snapshot copy];

    NSError *cerr = nil;
    if (![self reloadCredentials:&cerr]) {
        if (s.phase != DeskTraePhaseNeedsAuth || s.connected) {
            [self applyCredentialsTo:s];
            s.connected = NO;
            s.phase = DeskTraePhaseNeedsAuth;
            s.lastError = cerr.localizedDescription;
            [self publish:s];
        }
        return;
    }
    BOOL credsChanged = NO;
    @synchronized (self) {
        // 只比较 uid/令牌到期，够判断 IDE 是否换了登录态
        credsChanged = ![s.uid isEqualToString:_uid] || fabs(s.tokenExpiresAt - _tokenExpiresAt) > 1;
    }
    if ([self tokenExpired]) {
        if (s.phase != DeskTraePhaseNeedsAuth) {
            [self applyCredentialsTo:s];
            s.phase = DeskTraePhaseNeedsAuth;
            s.lastError = @"登录令牌已过期，打开 Trae 重新登录后自动恢复";
            [self publish:s];
        }
        return;
    }

    NSString *today = DeskCreditsDayKey(now);
    BOOL dayChanged = ![s.dayKey isEqualToString:today];
    if (!s.hasStatus || dayChanged || s.phase == DeskTraePhaseError || now - s.lastSyncAt > 600) {
        [self refreshSyncWithBalance:YES error:NULL];
        s = [self.snapshot copy];
    } else if (credsChanged) {
        [self applyCredentialsTo:s];
        [self publish:s];
    }

    if (!DeskTraeShouldAutoClaim(s, now)) return;
    if ([self claimThrottled:now]) return;
    [self note:@"自动签到：北京时间过了 00:05，今天还没签"];
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

#pragma mark 校验口

- (BOOL)ingestStatusForVerify:(NSDictionary *)json error:(NSError **)err {
    DeskTraeSnapshot *s = [self.snapshot copy];
    s.connected = YES;
    s.deviceId = s.deviceId.length ? s.deviceId : @"123456789012345";
    s.tokenExpiresAt = s.tokenExpiresAt > 0 ? s.tokenExpiresAt
        : [NSDate date].timeIntervalSince1970 + 14 * 86400;
    s.tokenSpanDays = s.tokenSpanDays > 0 ? s.tokenSpanDays : 14;
    if (![self applyStatusJSON:json to:s error:err]) return NO;
    s.phase = DeskTraePhaseReady;
    s.lastSyncAt = [NSDate date].timeIntervalSince1970;
    [self publish:s];
    return YES;
}

- (BOOL)ingestBalanceForVerify:(NSDictionary *)json error:(NSError **)err {
    DeskTraeSnapshot *s = [self.snapshot copy];
    if (![self applyBalanceJSON:json to:s error:err]) return NO;
    [self publish:s];
    return YES;
}

@end
