// 每进程负载采集实现。约定全写在 procs.h 的注释里，那几条实测边界都是这轮量出来的，
// 别凭直觉改：刻度换算、只读得到本用户进程、能耗是估算、网络先用连接数。
#import "procs.h"
#import <libproc.h>
#import <sys/proc_info.h>
#import <sys/resource.h>
#import <sys/time.h>
#import <sys/sysctl.h>
#import <mach/mach_time.h>
#import <errno.h>

// SDK 头里只有字段 proc_fdtype，没给取值名字。实测：node 进程直方图 {0:14, 1:1, 2:2}，
// 2 就是它的两个 socket（1 = vnode）。XNU 的 fdesc 类型表里 DTYPE_SOCKET 也是 2。
#define PROC_FDTYPE_SOCKET 2u

// 上一拍的累计值。进程会退出/新建，所以按 pid 存，取不到就当新进程（这一拍不给 CPU）。
@interface PrevStat : NSObject
@property (nonatomic, assign) uint64_t cpuTicks;
@property (nonatomic, assign) uint64_t wakeups;
@end
@implementation PrevStat
@end

@implementation DeskProc
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ pid=%d cpu=%.1f mem=%.0fM e=%.1f sk=%ld>",
            self.name, (int)self.pid, self.cpu, self.mem / 1048576.0, self.energy, (long)self.sockets];
}
@end

// 每 4 拍才数一次 socket：一次 PROC_PIDLISTFDS 要两趟系统调用，567 个进程全数一遍
// 是这组件里最贵的一笔开销，而连接数本来就是慢变量，2 秒一次足够新
static const NSInteger kSocketEveryTicks = 4;

@interface DeskProcsMonitor () {
    NSMutableDictionary<NSNumber *, PrevStat *> *_prev;
    NSMutableDictionary<NSNumber *, DeskProc *> *_last;      // 上一拍结果，排序接口直接复用
    uint64_t _lastTickAt;
    NSInteger _tick;
    mach_timebase_info_data_t _tb;
}
@property (nonatomic, assign) NSInteger readable;
@property (nonatomic, assign) NSInteger denied;
@end

@implementation DeskProcsMonitor

- (instancetype)init {
    if ((self = [super init])) {
        _prev = [NSMutableDictionary dictionary];
        _last = [NSMutableDictionary dictionary];
        mach_timebase_info(&_tb);
        if (_tb.denom == 0) { _tb.numer = 1; _tb.denom = 1; }
    }
    return self;
}

// 刻度 → 纳秒。本机实测 125/3，也就是 1 刻度 ≈ 41.667ns
- (double)nsPerTick { return (double)_tb.numer / (double)_tb.denom; }

- (NSArray<DeskProc *> *)sample {
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double dt = _lastTickAt ? (now - _lastTickAt) / 1e9 : 0.0;
    _lastTickAt = now;
    _tick++;
    BOOL wantSockets = (_tick % kSocketEveryTicks) == 1;

    int cap = proc_listallpids(NULL, 0);
    if (cap <= 0) return _last.allValues;
    pid_t *pids = calloc((size_t)cap * 2 + 64, sizeof(pid_t));
    int n = proc_listallpids(pids, (int)((cap * 2 + 64) * sizeof(pid_t)));

    NSMutableDictionary<NSNumber *, DeskProc *> *fresh = [NSMutableDictionary dictionary];
    NSInteger readable = 0, denied = 0;
    double nsPerTick = [self nsPerTick];
    uint64_t ticksNow = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

    for (int i = 0; i < n; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        struct rusage_info_v6 ru;
        memset(&ru, 0, sizeof(ru));
        if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ru) != 0) { denied++; continue; }
        readable++;

        char namebuf[256] = {0};
        if (proc_name(pid, namebuf, sizeof(namebuf)) <= 0) strcpy(namebuf, "?");

        DeskProc *p = [[DeskProc alloc] init];
        p.pid = pid;
        // ri_proc_start_abstime 是 mach absolute 刻度，换算成 unix 秒要绕一下 boottime：
        // 墙上时间 = boottime + (当前绝对时刻 - 启动绝对时刻)
        if (ru.ri_proc_start_abstime && ru.ri_proc_start_abstime < ticksNow) {
            struct timeval boot; size_t bl = sizeof(boot);
            int mib[2] = { CTL_KERN, KERN_BOOTTIME };
            if (sysctl(mib, 2, &boot, &bl, NULL, 0) == 0) {
                double agoSec = (double)(ticksNow - ru.ri_proc_start_abstime) * nsPerTick / 1e9;
                p.startedAt = (long long)([[NSDate date] timeIntervalSince1970] - agoSec);
            }
        }
        p.name = [NSString stringWithUTF8String:namebuf] ?: @"?";
        p.mem = (double)ru.ri_resident_size;

        uint64_t ticks = ru.ri_user_time + ru.ri_system_time;
        uint64_t wk = ru.ri_pkg_idle_wkups + ru.ri_interrupt_wkups;
        PrevStat *prev = _prev[@(pid)];
        if (prev && dt > 0.05) {
            double cpuNs = (double)(ticks - prev.cpuTicks) * nsPerTick;
            double wallNs = dt * 1e9;
            p.cpu = cpuNs / wallNs * 100.0;
            p.wakeups = (double)(wk - prev.wakeups) / dt;
            // 能耗估算：活动监视器的口径拿不到，这里按它公开说过的两个主项加权 ——
            // 跑在 CPU 上的时间 + 把机器从空闲里叫起来的次数。系数是量出来的相对权重，
            // 不是系统给的数，所以界面上这一列必须标"（估）"。
            p.energy = p.cpu + p.wakeups * 0.08;
        } else {
            p.cpu = -1; p.wakeups = -1; p.energy = -1;
        }
        if (!prev) prev = [[PrevStat alloc] init];
        prev.cpuTicks = ticks;
        prev.wakeups = wk;
        _prev[@(pid)] = prev;

        p.sockets = -1;
        fresh[@(pid)] = p;
        if (wantSockets) {
            p.sockets = [self countSockets:pid];
        }
    }

    // 没轮到重数的进程，沿用上一次的连接数，别让榜单数字跳成 -1
    if (!wantSockets) {
        [fresh enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, DeskProc *p, BOOL *stop) {
            DeskProc *old = _last[k];
            if (old && old.sockets >= 0) p.sockets = old.sockets;
        }];
    }

    // 清掉已经退出的进程的累计值，不然字典只进不出
    [_prev enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, PrevStat *v, BOOL *stop) {
        if (!fresh[k]) [_prev removeObjectForKey:k];
    }];
    self->_last = fresh;
    self.readable = readable;
    self.denied = denied;
    return fresh.allValues;
}

- (DeskProc *)procWithPid:(pid_t)pid {
    if (pid <= 0) return nil;
    return _last[@(pid)];
}

- (NSInteger)countSockets:(pid_t)pid {
    int sz = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (sz <= 0) return 0;
    int room = sz + (int)sizeof(struct proc_fdinfo) * 8;
    struct proc_fdinfo *fds = calloc(1, (size_t)room);
    int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, room);
    NSInteger count = 0;
    if (got > 0) {
        for (int i = 0; i + (int)sizeof(struct proc_fdinfo) <= got;
             i += (int)sizeof(struct proc_fdinfo)) {
            if (fds[i].proc_fdtype == PROC_FDTYPE_SOCKET) count++;
        }
    }
    free(fds);
    return count;
}

// 并列时按 pid 稳定排：只按值排的话，两个 0.0% 的进程每拍互换位置，榜单会肉眼可见地抖
static NSArray<DeskProc *> *Ranked(NSDictionary<NSNumber *, DeskProc *> *byPid,
                                   double (^key)(DeskProc *), NSInteger n) {
    NSMutableArray<DeskProc *> *all = [NSMutableArray array];
    [byPid enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, DeskProc *p, BOOL *stop) {
        if (key(p) >= 0) [all addObject:p];
    }];
    [all sortUsingComparator:^NSComparisonResult(DeskProc *a, DeskProc *b) {
        double ka = key(a), kb = key(b);
        if (ka != kb) return ka > kb ? NSOrderedAscending : NSOrderedDescending;
        return a.pid < b.pid ? NSOrderedAscending : NSOrderedDescending;
    }];
    return n >= 0 && (NSInteger)all.count > n ? [all subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] : all;
}

- (NSArray<DeskProc *> *)topByCPU:(NSInteger)n { return Ranked(_last, ^(DeskProc *p) { return p.cpu; }, n); }
- (NSArray<DeskProc *> *)topByMem:(NSInteger)n { return Ranked(_last, ^(DeskProc *p) { return p.mem; }, n); }
- (NSArray<DeskProc *> *)topByEnergy:(NSInteger)n { return Ranked(_last, ^(DeskProc *p) { return p.energy; }, n); }
- (NSArray<DeskProc *> *)topByNet:(NSInteger)n { return Ranked(_last, ^(DeskProc *p) { return (double)p.sockets; }, n); }

@end
