// 每进程网络到底能不能零权限拿到：nettop 不是 setuid 却能列出 root 进程的字节数，
// 说明 NetworkStatistics 这条路不卡权限。这里把它的 C API 用 dlopen 摸出来并实测一遍，
// 拿 `nettop -P` 的输出做对照，对得上才往组件里写。
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <net/route.h>
#import <ifaddrs.h>
#import <libproc.h>

// NetworkStatistics 报表记录的头：和路由消息同一套（RTM_VERSION 5），
// 每条记录前面是 if_msghdr2 风格的长度+类型，后面跟一个名字（"进程名.pid"）。
typedef struct {
    unsigned short  len;
    u_char          type;
    u_char          flags;
    int             addrs;
    int             index;
} NStatHdr;

typedef void (*HandlerFn)(const u_char *buffer, u_int length, void *arg);
typedef void *(*AllocMonFn)(const char *name, pid_t pid, int family, int flags);
typedef void *(*AddPidsFn)(void *handle, const pid_t *pids, size_t count);
typedef int (*IterateFn)(void *handle, HandlerFn fn, void *arg);
typedef int (*IterateStyleFn)(void *handle, HandlerFn fn, int style, void *arg);
typedef void (*ReleaseFn)(void *handle);

static void *NS;
static AllocMonFn fAlloc;
static AddPidsFn fAddPids;
static IterateFn fIter;
static IterateStyleFn fIterStyle;
static ReleaseFn fRelease;

// 每个 pid 累计的字节数
static NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *gByPid;

static void OnRecords(const u_char *buf, u_int len, void *arg) {
    u_int off = 0;
    while (off + sizeof(NStatHdr) <= len) {
        NStatHdr h;
        memcpy(&h, buf + off, sizeof(h));
        if (h.len < sizeof(NStatHdr) || off + h.len > len) break;
        // 名字紧跟在头后面，NUL 结尾，形如 "Google Chrome H.84286"
        const char *name = (const char *)(buf + off + sizeof(NStatHdr));
        u_int nameMax = h.len - sizeof(NStatHdr);
        u_int nlen = 0;
        while (nlen < nameMax && name[nlen]) nlen++;
        if (nlen > 0 && nlen < 64) {
            NSString *s = [[NSString alloc] initWithBytes:name length:nlen encoding:NSUTF8StringEncoding];
            NSRange dot = [s rangeOfString:@"." options:NSBackwardsSearch];
            if (dot.location != NSNotFound) {
                pid_t pid = (pid_t)[s substringFromIndex:dot.location + 1].intValue;
                // 字节数在头后面的 if_data 里；这里先把结构整体打出来找偏移
                NSMutableArray *acc = gByPid[@(pid)];
                if (!acc) { acc = [NSMutableArray arrayWithObjects:s, @(0), @(0), nil]; gByPid[@(pid)] = acc; }
                // 扫这条记录里所有 8 字节对齐的"看起来像累计字节数"的值，先定位字段位置
                for (u_int i = sizeof(NStatHdr); i + 8 <= h.len; i += 4) {
                    uint64_t v; memcpy(&v, buf + off + i, 8);
                    if (v > 0 && v < 1e13) {
                        if (acc.count < 20) [acc addObject:@(v)];
                    }
                }
            }
        }
        off += h.len;
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NS = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_NOW);
        printf("NetworkStatistics dlopen：%s\n", NS ? "成功" : "失败");
        if (!NS) return 1;
        fAlloc = (AllocMonFn)dlsym(NS, "nstat_alloc_monitor_context");
        fAddPids = (AddPidsFn)dlsym(NS, "nstat_add_pid_monitor_context");
        fIter = (IterateFn)dlsym(NS, "net_statistics_iterate");
        fIterStyle = (IterateStyleFn)dlsym(NS, "net_statistics_iterate_with_style");
        fRelease = (ReleaseFn)dlsym(NS, "nstat_release");
        printf("符号：alloc=%p addPids=%p iterate=%p iterate_with_style=%p release=%p\n",
               (void*)fAlloc, (void*)fAddPids, (void*)fIter, (void*)fIterStyle, (void*)fRelease);
        if (!fIter || !fRelease) { printf("缺关键符号\n"); return 2; }

        int n = proc_listallpids(NULL, 0);
        pid_t *pids = calloc(n + 64, sizeof(pid_t));
        n = proc_listallpids(pids, (n + 64) * sizeof(pid_t));
        printf("给 %d 个进程建监听上下文\n", n);

        gByPid = [NSMutableDictionary dictionary];
        void *h = NULL;
        if (fAlloc && fAddPids) {
            h = fAlloc(NULL, 0, AF_INET6, 0);
            if (h) fAddPids(h, pids, n);
        }
        int r;
        if (h && fIter) r = fIter(h, OnRecords, NULL);
        else if (fIterStyle) { h = fAlloc ? fAlloc(NULL, 0, AF_INET6, 0) : NULL;
                               r = fIterStyle(h, OnRecords, 1, NULL); }
        else r = -1;
        printf("iterate 返回 %d，收到 %lu 个进程的记录\n", r, (unsigned long)gByPid.count);

        // 把每个进程前几个候选值打出来，用来定位"累计字节数"到底在第几个偏移
        __block int shown = 0;
        [gByPid enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, NSMutableArray *v, BOOL *stop) {
            if (shown++ >= 6) return;
            NSMutableArray *big = [v subarrayWithRange:NSMakeRange(1, MIN(v.count - 1, 8))];
            printf("  pid %-7d %-24s 候选值 %s\n", (int)k.intValue,
                   [v[0] UTF8String] ?: "?",
                   [[big componentsJoinedByString:@", "] UTF8String] ?: "");
        }];
        if (fRelease && h) fRelease(h);
        free(pids);
        return 0;
    }
}
