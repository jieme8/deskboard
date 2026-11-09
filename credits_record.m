#import "credits_record.h"

static const NSInteger kRecordWindowDays = 90;

@implementation DeskCreditsRecord

- (instancetype)init {
    if ((self = [super init])) {
        _maxBalance = -1;
        _coverageDays = 0;
        _rail = @[];
        _lastCheckInAmount = -1;
    }
    return self;
}

@end

@interface DeskCreditsRecordEntry : NSObject
@property (nonatomic, copy, nullable) NSString *accountKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *days;
@property (nonatomic, copy, nullable) NSString *lastCheckInDayKey;
@property (nonatomic, assign) double lastCheckInAmount;
@end

@implementation DeskCreditsRecordEntry
- (instancetype)init {
    if ((self = [super init])) {
        _days = [NSMutableDictionary dictionary];
        _lastCheckInAmount = -1;
    }
    return self;
}
@end

static NSArray<NSString *> *DeskRecordPlatformKeys(void) {
    return @[@"minimax", @"trae", @"workbuddy", @"qoder"];
}

static NSString *DeskRecordPlatformKey(DeskCreditsPlatform p) {
    switch (p) {
        case DeskCreditsPlatformMiniMax: return @"minimax";
        case DeskCreditsPlatformTrae: return @"trae";
        case DeskCreditsPlatformWorkBuddy: return @"workbuddy";
        case DeskCreditsPlatformQoder: return @"qoder";
    }
    return @"minimax";
}

static NSArray<NSString *> *DeskRecordWindowKeys(NSTimeInterval now) {
    NSTimeInterval todayStart = DeskCreditsDayStart(now);
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:kRecordWindowDays];
    for (NSInteger i = kRecordWindowDays - 1; i >= 0; i--) {
        [keys addObject:DeskCreditsDayKey(todayStart - (NSTimeInterval)i * 86400.0)];
    }
    return keys;
}

static BOOL DeskRecordDayKeyLooksValid(NSString *key) {
    if (key.length != 10) return NO;
    return [key characterAtIndex:4] == '-' && [key characterAtIndex:7] == '-';
}

@interface DeskCreditsRecordStore ()
@property (nonatomic, readwrite, copy) NSString *path;
@end

@implementation DeskCreditsRecordStore {
    NSMutableDictionary<NSString *, DeskCreditsRecordEntry *> *_entries;
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _entries = [NSMutableDictionary dictionaryWithCapacity:4];
        for (NSString *key in DeskRecordPlatformKeys()) {
            _entries[key] = [DeskCreditsRecordEntry new];
        }
    }
    return self;
}

- (void)log:(NSString *)format, ... {
    if (!self.onLog) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    self.onLog(message);
}

- (DeskCreditsRecordEntry *)entry:(DeskCreditsPlatform)p {
    NSString *key = DeskRecordPlatformKey(p);
    DeskCreditsRecordEntry *e = _entries[key];
    if (!e) {
        e = [DeskCreditsRecordEntry new];
        _entries[key] = e;
    }
    return e;
}

- (BOOL)ensureDirectory {
    NSString *dir = [_path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) return YES;
    NSError *err = nil;
    BOOL ok = [fm createDirectoryAtPath:dir
            withIntermediateDirectories:YES
                             attributes:@{NSFilePosixPermissions: @0700}
                                  error:&err];
    if (!ok) [self log:@"创建目录失败：%@", err.localizedDescription ?: @"未知原因"];
    return ok;
}

- (BOOL)load {
    for (NSString *key in DeskRecordPlatformKeys()) {
        _entries[key] = [DeskCreditsRecordEntry new];
    }
    NSData *data = [NSData dataWithContentsOfFile:_path];
    if (!data.length) return YES;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        [self log:@"记录文件不是 JSON 对象，先按空记录启动"];
        return NO;
    }
    id platforms = ((NSDictionary *)obj)[@"platforms"];
    if (![platforms isKindOfClass:[NSDictionary class]]) {
        [self log:@"记录文件缺少 platforms，先按空记录启动"];
        return NO;
    }
    NSDictionary *pdict = (NSDictionary *)platforms;
    for (NSString *key in DeskRecordPlatformKeys()) {
        id raw = pdict[key];
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = (NSDictionary *)raw;
        DeskCreditsRecordEntry *e = _entries[key];
        id account = d[@"account"];
        if ([account isKindOfClass:[NSString class]] && [account length]) {
            e.accountKey = account;
        }
        id days = d[@"days"];
        if ([days isKindOfClass:[NSDictionary class]]) {
            [(NSDictionary *)days enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSNumber class]]) return;
                if (!DeskRecordDayKeyLooksValid((NSString *)k)) return;
                double value = [(NSNumber *)v doubleValue];
                if (!isfinite(value) || value < 0) return;
                e.days[(NSString *)k] = @(value);
            }];
        }
        id event = d[@"lastCheckIn"];
        if ([event isKindOfClass:[NSDictionary class]]) {
            NSDictionary *ev = (NSDictionary *)event;
            id day = ev[@"d"];
            if ([day isKindOfClass:[NSString class]] && DeskRecordDayKeyLooksValid(day)) {
                e.lastCheckInDayKey = day;
                id amount = ev[@"amount"];
                e.lastCheckInAmount = [amount isKindOfClass:[NSNumber class]]
                    ? [(NSNumber *)amount doubleValue] : -1;
            }
        }
    }
    return YES;
}

- (BOOL)save {
    if (![self ensureDirectory]) return NO;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSArray<NSString *> *window = DeskRecordWindowKeys(now);
    NSSet<NSString *> *keep = [NSSet setWithArray:window];
    NSMutableDictionary *platforms = [NSMutableDictionary dictionaryWithCapacity:4];
    for (NSString *key in DeskRecordPlatformKeys()) {
        DeskCreditsRecordEntry *e = _entries[key];
        NSMutableDictionary<NSString *, NSNumber *> *days = [NSMutableDictionary dictionary];
        [e.days enumerateKeysAndObjectsUsingBlock:^(NSString *day, NSNumber *value, BOOL *stop) {
            if ([keep containsObject:day]) days[day] = value;
        }];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        if (e.accountKey.length) d[@"account"] = e.accountKey;
        d[@"days"] = days;
        if (e.lastCheckInDayKey.length) {
            d[@"lastCheckIn"] = @{@"d": e.lastCheckInDayKey,
                                  @"amount": @(e.lastCheckInAmount)};
        }
        platforms[key] = d;
    }
    NSDictionary *root = @{@"schemaVersion": @1, @"platforms": platforms};
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:(NSJSONWritingPrettyPrinted |
                                                            NSJSONWritingSortedKeys)
                                                     error:&err];
    if (!data) {
        [self log:@"编码记录失败：%@", err.localizedDescription ?: @"未知原因"];
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:_path]) {
        NSString *bak = [_path stringByAppendingString:@".bak"];
        [fm removeItemAtPath:bak error:NULL];
        [fm copyItemAtPath:_path toPath:bak error:NULL];
    }
    if (![data writeToFile:_path options:NSDataWritingAtomic error:&err]) {
        [self log:@"写记录失败：%@", err.localizedDescription ?: @"未知原因"];
        return NO;
    }
    [fm setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:_path error:NULL];
    return YES;
}

- (BOOL)setAccountKey:(NSString *)accountKey forPlatform:(DeskCreditsPlatform)p {
    if (!accountKey.length) return NO;
    DeskCreditsRecordEntry *e = [self entry:p];
    if ([e.accountKey isEqualToString:accountKey]) return NO;
    BOOL hadOld = e.accountKey.length > 0;
    e.accountKey = [accountKey copy];
    if (hadOld) {
        [e.days removeAllObjects];
        e.lastCheckInDayKey = nil;
        e.lastCheckInAmount = -1;
        [self log:@"%@ 账号变化，90 天记录从今天重新开始",
         DeskRecordPlatformKey(p)];
    }
    [self save];
    return hadOld;
}

- (BOOL)samplePlatform:(DeskCreditsPlatform)p balance:(double)balance at:(NSTimeInterval)t {
    if (!isfinite(balance) || balance < 0) return NO;
    DeskCreditsRecordEntry *e = [self entry:p];
    NSString *today = DeskCreditsDayKey(t);
    NSNumber *oldToday = e.days[today];
    BOOL changed = (oldToday == nil || balance > oldToday.doubleValue);
    if (changed) e.days[today] = @(balance);

    NSSet<NSString *> *window = [NSSet setWithArray:DeskRecordWindowKeys(t)];
    NSArray<NSString *> *stale = [e.days.allKeys filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSString *day, NSDictionary *bindings) {
            return ![window containsObject:day];
        }]];
    if (stale.count) {
        [e.days removeObjectsForKeys:stale];
        changed = YES;
    }
    if (changed) [self save];
    return changed;
}

- (BOOL)markCheckInPlatform:(DeskCreditsPlatform)p amount:(double)amount dayKey:(NSString *)dayKey {
    if (!DeskRecordDayKeyLooksValid(dayKey)) return NO;
    DeskCreditsRecordEntry *e = [self entry:p];
    NSComparisonResult cmp = e.lastCheckInDayKey
        ? [dayKey compare:e.lastCheckInDayKey] : NSOrderedDescending;
    if (cmp == NSOrderedAscending) return NO;
    if (cmp == NSOrderedSame) {
        if (amount >= 0 && amount != e.lastCheckInAmount) {
            e.lastCheckInAmount = amount;
            [self save];
            return YES;
        }
        return NO;
    }
    e.lastCheckInDayKey = [dayKey copy];
    e.lastCheckInAmount = amount >= 0 ? amount : -1;
    [self save];
    return YES;
}

- (DeskCreditsRecord *)recordForPlatform:(DeskCreditsPlatform)p at:(NSTimeInterval)t {
    DeskCreditsRecordEntry *e = [self entry:p];
    NSString *today = DeskCreditsDayKey(t);
    NSArray<NSString *> *window = DeskRecordWindowKeys(t);
    NSMutableArray<NSNumber *> *rail = [NSMutableArray arrayWithCapacity:window.count];
    double maxBalance = -1;
    NSString *peakDay = nil;
    NSInteger coverage = 0;
    for (NSString *day in window) {
        NSNumber *value = e.days[day];
        NSInteger flags = DeskCreditsRecordRailMissing;
        if (value) {
            coverage++;
            flags |= DeskCreditsRecordRailSampled;
            if (maxBalance < 0 || value.doubleValue > maxBalance) {
                maxBalance = value.doubleValue;
                peakDay = day;
            }
        }
        [rail addObject:@(flags)];
    }
    // 第二遍补峰值/今天标记，保证并列时峰值落在最早那一天。
    for (NSInteger i = 0; i < (NSInteger)window.count; i++) {
        NSInteger flags = rail[(NSUInteger)i].integerValue;
        if (peakDay && [window[(NSUInteger)i] isEqualToString:peakDay]) {
            flags |= DeskCreditsRecordRailPeak;
        }
        if ([window[(NSUInteger)i] isEqualToString:today]) {
            flags |= DeskCreditsRecordRailToday;
        }
        rail[(NSUInteger)i] = @(flags);
    }
    DeskCreditsRecord *r = [DeskCreditsRecord new];
    r.maxBalance = maxBalance;
    r.peakDayKey = peakDay;
    r.coverageDays = coverage;
    r.newHigh = peakDay != nil && [peakDay isEqualToString:today] && coverage > 1;
    r.rail = rail;
    r.lastCheckInDayKey = e.lastCheckInDayKey;
    r.lastCheckInAmount = e.lastCheckInAmount;
    return r;
}

- (void)applyPlatform:(DeskCreditsPlatform)p toSlot:(DeskCreditsSlot *)slot at:(NSTimeInterval)t {
    DeskCreditsRecord *r = [self recordForPlatform:p at:t];
    slot.recordMax = r.maxBalance;
    slot.recordPeakDayKey = r.peakDayKey;
    slot.recordCoverageDays = r.coverageDays;
    slot.recordNewHigh = r.newHigh;
    slot.recordRail = r.rail;
    slot.lastCheckInDayKey = r.lastCheckInDayKey;
    slot.lastCheckInAmount = r.lastCheckInAmount;
}

- (void)resetPlatform:(DeskCreditsPlatform)p {
    DeskCreditsRecordEntry *e = [self entry:p];
    [e.days removeAllObjects];
    e.lastCheckInDayKey = nil;
    e.lastCheckInAmount = -1;
    [self save];
}

@end
