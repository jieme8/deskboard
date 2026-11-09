// 分钟桶历史。见 history.h 顶部那段"为什么要自己攒"。
#import "history.h"
#import "procs.h"
#include <math.h>

const double kDeskHistoryWindow = 12.0 * 3600.0;

// 每分钟只攒"这一拍各榜的前几名"，不攒全部进程：这台机器一拍能读到 542 个进程，
// 全存的话 12 小时是 720×542 条记录，纯浪费 —— 界面每榜只画 4 行。
// 取前 6 而不是前 4，是为了让榜稍微有点滞后余量：一个进程从第 5 名掉出去时，
// 它这一小时的平均还留着，不会画着画着突然变成 0。
#define kTrackTopPerMetric 6   // 宏而不是 static const：要拿它当数组维度
static const NSUInteger kMaxTrackedPids = 40;
// 桶宽 60 秒。再细对"12 小时平均"没有信息增益，只会把文件撑大
static const NSTimeInterval kBucketSeconds = 60.0;
// 一个 60 秒桶的正常网络字节上限（100 GB/min ≈ 13 Gbps）。超过它只可能是
// 计数器回绕/接口重连留下的脏样本；读回时按该桶的进程值修复，别让 12h 累计被带飞。
static const double kMaxNetBytesPerBucket = 1e11;

@interface DeskHistory () {
    NSString *_path;
    // key = 桶号（unix 秒 / 60 取整）。value = @{ @"s":秒数, @"sys":四个和, @"p":{pid:@[秒,四个和]} }
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *_buckets;
    NSTimeInterval _lastAt;
    BOOL _dirty;
    NSTimeInterval _lastFlush;
    // 12h 窗口聚合缓存：组件每拍要问 16 行 × 4 榜 = 64 次，逐次重扫 720 个桶
    // 实测占刷新主线程的七成。noteSampleAt 写脏；同一拍里的 64 次只扫一遍。
    BOOL _winValid;
    NSTimeInterval _winAt;
    double _winWindow;
    double _winCovered;
    double _winSys[DeskHistMetricCount];
    NSMutableDictionary<NSString *, NSMutableArray *> *_winPid;
}
- (void)buildWindowCacheAt:(NSTimeInterval)now window:(double)window;
@end

@implementation DeskHistory

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _buckets = [NSMutableDictionary dictionary];
    }
    return self;
}

- (double)recordedSeconds {
    double s = 0;
    for (NSNumber *k in _buckets) s += [_buckets[k][@"s"] doubleValue];
    return s;
}

- (NSUInteger)trackedPids {
    NSMutableSet *seen = [NSMutableSet set];
    for (NSNumber *k in _buckets) [seen addObjectsFromArray:[_buckets[k][@"p"] allKeys]];
    return seen.count;
}

#pragma mark - 落盘 / 读回

- (BOOL)load {
    NSData *d = [NSData dataWithContentsOfFile:_path];
    if (!d) return YES;                       // 第一次运行：没历史是正常状态，不是失败
    NSError *err = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:&err];
    if (![obj isKindOfClass:NSDictionary.class]) { _dirty = YES; return YES; }  // 坏了就当没有，重写一份
    // v1 的 network 桶存的是 socket 数，v2 换成字节/秒；v3 的能耗是 "CPU% + 唤醒×0.08"
    // 的估算分，v4 换成内核 ri_energy_nj 实测瓦数。量纲不同的旧桶不能混用，
    // 否则升级后 12h 能耗平均会拿"几十点的估算分"当"零点几瓦"。
    NSNumber *ver = [(NSDictionary *)obj objectForKey:@"v"];
    NSInteger version = [ver isKindOfClass:NSNumber.class] ? ver.integerValue : 0;
    if (version != 4) { _dirty = YES; return YES; }
    NSTimeInterval floor0 = [NSDate date].timeIntervalSince1970 - kDeskHistoryWindow - kBucketSeconds * 2;
    long long floorBucket = (long long)floor(floor0 / kBucketSeconds);
    for (NSString *ks in [(NSDictionary *)obj objectForKey:@"b"]) {
        long long no = ks.longLongValue;
        if (no < floorBucket) continue;       // 窗口外的直接丢，文件不会无限长
        id v = [(NSDictionary *)obj objectForKey:@"b"][ks];
        if (![v isKindOfClass:NSDictionary.class]) continue;
        // plist 读回来全是不可变容器。浅 mutableCopy 只把最外层变可写，
        // 下一拍往同一个桶里追加就会撞上 -[__NSArrayI setObject:atIndexedSubscript:]
        // —— 而且只有"重启后正好又采到同一个 pid 的同一分钟"才炸，所以是偶发崩溃。
        NSMutableDictionary *bm = [v mutableCopy];
        NSMutableDictionary *pm = [NSMutableDictionary dictionary];
        for (NSString *pk in bm[@"p"]) pm[pk] = [bm[@"p"][pk] mutableCopy];
        bm[@"p"] = pm;
        // v2 里可能残留计数器回绕导致的超大网络桶：用该桶进程累计重算，
        // 至少是干净的下界；不修的话 12h 合计会是一个 1e20 量级的假数。
        NSArray *sys = bm[@"sys"];
        if (sys.count > DeskHistNetwork) {
            double net = [sys[DeskHistNetwork] doubleValue];
            if (net < 0 || net > kMaxNetBytesPerBucket) {
                double repaired = 0;
                NSUInteger netIdx = (NSUInteger)DeskHistNetwork + 1;   // e = [秒, CPU, 内存, 能耗, 网络]
                for (NSString *pk in pm) {
                    NSArray *e = pm[pk];
                    if (e.count > netIdx) repaired += [e[netIdx] doubleValue];
                }
                NSMutableArray *fixed = [sys mutableCopy];
                fixed[DeskHistNetwork] = @(MAX(0.0, repaired));
                bm[@"sys"] = fixed;
                _dirty = YES;
            }
        }
        _buckets[@(no)] = bm;
    }
    return YES;
}

- (BOOL)flushIfNeeded {
    if (!_dirty) return YES;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - _lastFlush < kBucketSeconds) return NO;   // 每分钟最多写一次
    _lastFlush = now;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSNumber *k in _buckets) out[k.stringValue] = _buckets[k];
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:@{ @"v": @4, @"b": out }
                                                          format:NSPropertyListBinaryFormat_v1_0
                                                         options:0 error:NULL];
    if (!d) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [_path stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![d writeToFile:_path atomically:YES]) return NO;
    _dirty = NO;
    return YES;
}

#pragma mark - 攒

// 这一拍值得记住哪些 pid：四榜各取前 6 的并集，再按总数封顶。
// 这里刻意不做 4 次 sortUsingComparator —— 一拍 542 个进程排 4 遍是 ~2 万次 block 调用，
// 实测把整个 App 从 2.9% 顶到 8.5%。改成一趟扫描 + 四个定长小数组，O(n·4·K) 且零 block。
static NSSet<NSNumber *> *leaders(NSArray<DeskProc *> *rows) {
    
    pid_t ids[4][kTrackTopPerMetric]; double keys[4][kTrackTopPerMetric]; NSInteger cnt[4] = { 0, 0, 0, 0 };
    for (DeskProc *p in rows) {
        if (p.cpu < 0) continue;                 // 没基线的一拍不参与排名
        double netRate = (p.netInRate >= 0 && p.netOutRate >= 0) ? p.netInRate + p.netOutRate : -1;
        double v[4] = { p.cpu, p.mem, p.energy, netRate };
        for (int m = 0; m < 4; m++) {
            if (v[m] < 0) continue;
            int at = cnt[m] < kTrackTopPerMetric ? cnt[m] : kTrackTopPerMetric;
            if (at == kTrackTopPerMetric) {                       // 满了就先找最差的那个位置
                int worst = 0;
                for (int i = 1; i < kTrackTopPerMetric; i++) if (keys[m][i] < keys[m][worst]) worst = i;
                if (v[m] <= keys[m][worst] && !(v[m] == keys[m][worst] && p.pid < ids[m][worst])) continue;
                at = worst;
            } else cnt[m]++;
            ids[m][at] = p.pid; keys[m][at] = v[m];
        }
    }
    NSMutableSet *keep = [NSMutableSet set];
    for (int m = 0; m < 4 && keep.count < kMaxTrackedPids; m++)
        for (int i = 0; i < cnt[m] && keep.count < kMaxTrackedPids; i++) [keep addObject:@(ids[m][i])];
    return keep;
}

- (void)noteSampleAt:(NSTimeInterval)now seconds:(double)dt
                rows:(NSArray<DeskProc *> *)rows
              totals:(const double *)totals {
    if (dt <= 0.0 || dt > kBucketSeconds * 4) { _lastAt = now; return; }  // 睡眠/跳拍：这一拍不算
    _lastAt = now;
    long long no = (long long)floor(now / kBucketSeconds);
    NSMutableDictionary *b = _buckets[@(no)];
    if (!b) {
        b = [@{ @"s": @0.0, @"sys": @[@0.0, @0.0, @0.0, @0.0], @"p": [NSMutableDictionary dictionary] } mutableCopy];
        _buckets[@(no)] = b;
    }
    b[@"s"] = @([b[@"s"] doubleValue] + dt);
    double *sys = malloc(sizeof(double) * DeskHistMetricCount);
    for (NSInteger m = 0; m < DeskHistMetricCount; m++) sys[m] = [b[@"sys"][m] doubleValue] + totals[m] * dt;
    b[@"sys"] = @[ @(sys[0]), @(sys[1]), @(sys[2]), @(sys[3]) ];
    free(sys);

    NSSet *keep = leaders(rows);
    NSMutableDictionary *p = b[@"p"];
    for (DeskProc *proc in rows) {
        if (![keep containsObject:@(proc.pid)]) continue;
        // 负数 = 这一拍还不知道（刚启动那一拍没有基线）。整条跳过，连秒数都不记 ——
        // 拿 MAX(0,...) 把"不知道"糊成 0，平均值就会被假 0 拉低，而且拉得看不出来
        if (proc.cpu < 0 || proc.energy < 0 || proc.wakeups < 0 ||
            proc.netInRate < 0 || proc.netOutRate < 0) continue;
        double vals[4] = { proc.cpu, proc.mem, proc.energy,
                          proc.netInRate + proc.netOutRate };
        // mutableCopy 而不是直接取：桶可能来自刚读回的 plist，那条路上是不可变数组
        NSMutableArray *e = [p[@(proc.pid).stringValue] mutableCopy];
        if (!e) e = [@[@0.0, @0.0, @0.0, @0.0, @0.0] mutableCopy];
        e[0] = @([e[0] doubleValue] + dt);
        for (NSInteger m = 0; m < 4; m++) e[m + 1] = @([e[m + 1] doubleValue] + vals[m] * dt);
        p[@(proc.pid).stringValue] = e;
    }

    // 剪掉窗口之外的桶
    long long floorBucket = (long long)floor((now - kDeskHistoryWindow - kBucketSeconds * 2) / kBucketSeconds);
    NSMutableArray *stale = [NSMutableArray array];
    for (NSNumber *k in _buckets) if (k.longLongValue < floorBucket) [stale addObject:k];
    [_buckets removeObjectsForKeys:stale];
    _winValid = NO;   // 这一拍的数据变了，下一次查询重扫一遍窗口
    _dirty = YES;
}

// 一次扫描出整个窗口的进程累计 + 系统累计 + covered，缓存一拍。
// now 只用来定桶范围；同一拍内 64 次调用传进来的 now 只差几毫秒，不能各扫一遍。
- (void)buildWindowCacheAt:(NSTimeInterval)now window:(double)window {
    if (_winValid && _winWindow == window && fabs(now - _winAt) < 1.0) return;
    double sys[DeskHistMetricCount] = { 0, 0, 0, 0 };
    NSMutableDictionary<NSString *, NSMutableArray *> *acc = nil;
    [self sumOverWindowEndingAt:now window:window into:sys perPid:&acc];
    _winPid = acc ?: [NSMutableDictionary dictionary];
    for (NSInteger m = 0; m < DeskHistMetricCount; m++) _winSys[m] = sys[m];
    _winCovered = [self recordedSecondsEndingAt:now window:window];
    _winAt = now;
    _winWindow = window;
    _winValid = YES;
}

#pragma mark - 查

- (void)sumOverWindowEndingAt:(NSTimeInterval)now window:(double)window
                    into:(double *)sysSeconds perPid:(NSMutableDictionary<NSString *, NSMutableArray *> **)pidOut {
    long long last = (long long)floor(now / kBucketSeconds);
    long long first = (long long)floor((now - window) / kBucketSeconds);
    NSMutableDictionary<NSString *, NSMutableArray *> *acc = [NSMutableDictionary dictionary];
    for (long long no = first; no <= last; no++) {
        NSMutableDictionary *b = _buckets[@(no)];
        if (!b) continue;
        double bs = [b[@"s"] doubleValue];
        if (bs <= 0) continue;
        if (sysSeconds) for (NSInteger m = 0; m < DeskHistMetricCount; m++) sysSeconds[m] += [b[@"sys"][m] doubleValue];
        if (pidOut) {
            for (NSString *pid in b[@"p"]) {
                NSMutableArray *src = b[@"p"][pid];
                NSMutableArray *dst = acc[pid];
                if (!dst) dst = acc[pid] = [@[@0.0, @0.0, @0.0, @0.0, @0.0] mutableCopy];
                for (NSInteger i = 0; i < 5; i++) dst[i] = @([dst[i] doubleValue] + [src[i] doubleValue]);
            }
        }
    }
    if (pidOut) *pidOut = acc;
}

// 窗口内我们真正攒到了多少秒
- (double)recordedSecondsEndingAt:(NSTimeInterval)now window:(double)window {
    long long last = (long long)floor(now / kBucketSeconds), first = (long long)floor((now - window) / kBucketSeconds);
    double secs = 0;
    for (long long no = first; no <= last; no++) {
        NSMutableDictionary *b = _buckets[@(no)];
        if (b) secs += [b[@"s"] doubleValue];
    }
    return secs;
}

// 分母 = min(窗口, 窗口内真正攒到的秒数)。
// 为什么不是写死的 43200：那样冷启动头一天分子只有几分钟、分母却是 12 小时，
// 任何进程的 12h 条都是亚像素长度 —— 等于装好之后整整一天看不到这个功能。
// 用 min 之后：攒够 12 小时它就自动等于字面口径，没攒够时它是"已记录这段时间的平均"，
// 界面拿 covered 标"已记录 X 小时"，两个阶段都不撒谎。
static double histDenominator(double window, double recorded) {
    if (recorded <= 0) return 0;
    return MIN(window, recorded);
}

- (double)averageForSystemMetric:(DeskHistMetric)m now:(NSTimeInterval)now window:(double)window
                         covered:(double *)coveredOut {
    [self buildWindowCacheAt:now window:window];
    if (coveredOut) *coveredOut = _winCovered;
    double den = histDenominator(window, _winCovered);
    return den > 0 ? _winSys[m] / den : 0;
}

- (double)averageForPid:(pid_t)pid metric:(DeskHistMetric)m now:(NSTimeInterval)now window:(double)window
                covered:(double *)coveredOut {
    [self buildWindowCacheAt:now window:window];
    NSMutableArray *e = _winPid[@(pid).stringValue];
    if (!e) { if (coveredOut) *coveredOut = 0; return 0; }
    if (coveredOut) *coveredOut = _winCovered;
    double den = histDenominator(window, _winCovered);
    return den > 0 ? [e[(NSInteger)m + 1] doubleValue] / den : 0;
}

// 窗口内的原始累计量。网络桶存的是 rate×dt（字节），所以这里不再除秒数。
- (double)totalForPid:(pid_t)pid metric:(DeskHistMetric)m now:(NSTimeInterval)now window:(double)window
              covered:(double *)coveredOut {
    [self buildWindowCacheAt:now window:window];
    NSMutableArray *e = _winPid[@(pid).stringValue];
    if (!e) { if (coveredOut) *coveredOut = 0; return 0; }
    if (coveredOut) *coveredOut = _winCovered;
    return [e[(NSInteger)m + 1] doubleValue];
}

- (double)totalForSystemMetric:(DeskHistMetric)m now:(NSTimeInterval)now window:(double)window
                       covered:(double *)coveredOut {
    [self buildWindowCacheAt:now window:window];
    if (coveredOut) *coveredOut = _winCovered;
    return _winSys[m];
}

- (double)totalForTrackedPidsMetric:(DeskHistMetric)m now:(NSTimeInterval)now window:(double)window
                            covered:(double *)coveredOut {
    [self buildWindowCacheAt:now window:window];
    double sum = 0;
    NSUInteger idx = (NSUInteger)m + 1;   // e = [秒, CPU, 内存, 能耗, 网络]
    for (NSString *pid in _winPid) {
        NSArray *e = _winPid[pid];
        if (e.count > idx) sum += [e[idx] doubleValue];
    }
    if (coveredOut) *coveredOut = _winCovered;
    return sum;
}

@end
