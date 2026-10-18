// 采集可行性实测：不靠 top/nettop 这些命令行工具，直接用我们组件能调的 API，
// 量一遍"每进程 CPU / 内存 / 能耗 / 网络"到底拿不拿得到、要不要 root。
// 用法：probe_procs [采样秒数]
#import <Foundation/Foundation.h>
#import <libproc.h>
#import <sys/proc_info.h>
#import <sys/resource.h>
#import <mach/mach_time.h>
#import <pwd.h>
#import <time.h>

typedef struct {
    pid_t    pid;
    char     name[256];
    uint64_t cpu;      // 累计 CPU 时间（ns）
    uint64_t billed;   // 计费能耗
    uint64_t serviced; // 代付能耗（别的进程替它出的）
    uint64_t wkups;    // 唤醒次数
    uint64_t mem;      // 常驻内存
    int      uid;
} Snap;

static uint64_t MonoNs(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// 两次快照之间，谁涨得快就是谁在吃资源；组件里也是这么算的
static int TakeSnapshots(Snap **outA, int *outN) {
    int cap = proc_listallpids(NULL, 0);
    if (cap <= 0) return -1;
    pid_t *pids = calloc(cap * 2 + 64, sizeof(pid_t));
    int n = proc_listallpids(pids, (cap * 2 + 64) * sizeof(pid_t));
    Snap *s = calloc(n + 1, sizeof(Snap));
    int kept = 0, denied = 0;
    for (int i = 0; i < n; i++) {
        struct rusage_info_v6 ru;
        memset(&ru, 0, sizeof(ru));
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&ru) != 0) { denied++; continue; }
        s[kept].pid = pids[i];
        s[kept].cpu = ru.ri_user_time + ru.ri_system_time;
        s[kept].billed = ru.ri_billed_energy;
        s[kept].serviced = ru.ri_serviced_energy;
        s[kept].wkups = ru.ri_pkg_idle_wkups + ru.ri_interrupt_wkups;
        s[kept].mem = ru.ri_resident_size;
        proc_name(pids[i], s[kept].name, sizeof(s[kept].name));
        struct proc_bsdinfo bi;
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &bi, sizeof(bi)) == sizeof(bi)) s[kept].uid = bi.pbi_uid;
        kept++;
    }
    free(pids);
    *outA = s; *outN = kept;
    printf("  可读进程 %d 个，被拒 %d 个（不是自己的进程会 EPERM）\n", kept, denied);
    return kept;
}

static void DumpTop(const char *title, Snap *a, Snap *b, int n, double secs,
                    double (*pick)(Snap *x, Snap *y, double secs), const char *unit, double scale) {
    printf("\n  按%s排（%g 秒增量）\n", title, secs);
    typedef struct { double v; Snap *s; } Row;
    Row *rows = calloc(n, sizeof(Row));
    for (int i = 0; i < n; i++) { Row r; r.s = &b[i]; r.v = pick(&a[i], &b[i], secs); rows[i] = r; }
    for (int i = 1; i < n; i++) for (int j = i; j > 0 && rows[j-1].v < rows[j].v; j--) { Row t = rows[j]; rows[j] = rows[j-1]; rows[j-1] = t; }
    for (int i = 0; i < n && i < 6; i++) {
        char nm[34]; strncpy(nm, rows[i].s->name[0] ? rows[i].s->name : "?", 32); nm[32] = 0;
        printf("    %-32s %8.1f %s   (pid %d, uid %d)\n", nm, rows[i].v / scale, unit,
               rows[i].s->pid, rows[i].s->uid);
    }
    free(rows);
}

static double MachTicksToNs(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)tb.numer / (double)tb.denom;   // 刻度 → ns
}
static double PickCPU(Snap *a, Snap *b, double secs)   { return (b->cpu - a->cpu) * MachTicksToNs() / (secs * 1e7); }
static double PickMem(Snap *a, Snap *b, double secs)   { return b->mem / 1e6; }
static double PickEnergy(Snap *a, Snap *b, double secs){ return (b->billed + b->serviced - a->billed - a->serviced) / secs; }
static double PickWkups(Snap *a, Snap *b, double secs) { return (b->wkups - a->wkups) / secs; }

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        double secs = argc > 1 ? atof(argv[1]) : 2.0;
        uid_t me = getuid();
        printf("当前用户 uid=%d（非 root），mach timebase %u/%u（1 刻度 = %.3f ns）\n", me,
           (unsigned)(MachTicksToNs()*1000/8), 0, MachTicksToNs());

        int n = 0; Snap *a = NULL;
        if (TakeSnapshots(&a, &n) <= 0) { printf("一次都没读到\n"); return 1; }
        Snap *a2 = calloc(n, sizeof(Snap)); memcpy(a2, a, n * sizeof(Snap));
        uint64_t t0 = MonoNs();
        usleep((useconds_t)(secs * 1e6));
        int m = 0; Snap *b = NULL;
        // 进程会退出/新建，两次快照按 pid 对齐，只比两边都在的
        TakeSnapshots(&b, &m);
        double dt = (MonoNs() - t0) / 1e9;

        Snap *A = calloc(n + 1, sizeof(Snap)); int k = 0;
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < m; j++) {
                if (a2[i].pid == b[j].pid) { A[k] = a2[i]; b[k] = b[j]; k++; break; }
            }
        }
        printf("  两次都在的进程 %d 个，实际间隔 %.2fs\n", k, dt);

        printf("\n── CPU（和 top 的 %%CPU 同口径：CPU 时间 / 墙钟）\n");
        DumpTop("CPU", A, b, k, dt, PickCPU, "%", 1.0);
        printf("\n── 内存（ri_resident_size）\n");
        DumpTop("内存", A, b, k, dt, PickMem, "MB", 1.0);
        printf("\n── 能耗（ri_billed_energy + ri_serviced_energy 的增速）\n");
        DumpTop("能耗", A, b, k, dt, PickEnergy, "u/s", 1.0);
        printf("\n── 唤醒（能耗影响里的第二项，AM 也算它）\n");
        DumpTop("唤醒", A, b, k, dt, PickWkups, "次/s", 1.0);

        free(a); free(a2); free(b); free(A);
        return 0;
    }
}
