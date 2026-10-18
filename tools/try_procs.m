// procs.m 的冒烟测试：跑两拍，把四个榜单打出来，并量每次采样花多少墙钟时间。
// 组件每 2 秒采一次，这一拍要是超过几十毫秒就得挪到后台队列。
#import <Foundation/Foundation.h>
#import "procs.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        DeskProcsMonitor *m = [[DeskProcsMonitor alloc] init];
        double t0 = CFAbsoluteTimeGetCurrent();
        [m sample];
        double first = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        printf("第一拍（只有基线）%.1fms\n", first);
        usleep(2500000);
        t0 = CFAbsoluteTimeGetCurrent();
        [m sample];
        double second = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        printf("第二拍 %.1fms  可读 %ld 个 / 被拒 %ld 个\n",
               second, (long)m.readable, (long)m.denied);

        struct { const char *tag; NSArray<DeskProc *> *rows; } lists[] = {
            { "CPU %", [m topByCPU:5] },
            { "内存 MB", [m topByMem:5] },
            { "能耗（估）", [m topByEnergy:5] },
            { "网络 连接数", [m topByNet:5] },
        };
        for (size_t i = 0; i < 4; i++) {
            printf("\n── 前 5：%s\n", lists[i].tag);
            for (DeskProc *p in lists[i].rows) {
                printf("  %-30s pid %-6d  cpu=%6.1f  mem=%7.1fM  e=%6.1f  sk=%3ld\n",
                       p.name.UTF8String, (int)p.pid, p.cpu, p.mem / 1048576.0,
                       p.energy, (long)p.sockets);
            }
        }
        return 0;
    }
}
