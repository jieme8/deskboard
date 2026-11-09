// 每进程负载采集：CPU / 内存 / 能耗 / 网络。全部零权限，只覆盖当前用户的进程。
// 这台机器上实测过的边界，改之前先看：
//   · proc_pid_rusage 只能读本用户的进程（实测 567 可读 / 301 EPERM，
//     WindowServer、launchd 都在 EPERM 里）。top 能看到系统进程是因为它 setuid root。
//   · sysctl KERN_PROC_ALL 能列到 863 个进程，但 kp_proc.p_ru 对全部 863 个都是 NULL，
//     做不了后备。
//   · ri_user_time / ri_system_time 是 **mach 绝对时间刻度**，不是纳秒。本机 timebase
//     125/3 → 1 刻度 = 41.667ns。当成 ns 用会把 %CPU 少算 41.7 倍。
//   · 能耗用 ri_energy_nj 差分（瓦）。原生活动监视器的"能耗影响"是另一套加权分，
//     绝对数对不上，但实测排名和这里的瓦数一致（DeskBoard 0.34W 排第一，
//     UURemoteServer 1000+ 唤醒/s 但只有 0.014W）。内核不给计数时才退回旧估算。
//   · 每进程网络字节数：nettop 的 **持续交互模式** 实测烧 146% 单核，不能常开；
//     但 `nettop -P -x -L 1 -J bytes_in,bytes_out` 单次日志采样实测约 0.01s，
//     输出每进程累计收发字节。组件每 20 秒起一次、按拍求差，得到每进程速率。
//     NetworkStatistics 的 NStat* 符号在当前系统上已经 dlsym 不到，不走私有 API。
#import <Foundation/Foundation.h>

@interface DeskProc : NSObject
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, assign) double cpu;        // %CPU，0~100×核数；<0 = 这一拍还没基线
@property (nonatomic, assign) double mem;        // 常驻字节
@property (nonatomic, assign) double energy;     // 瓦（ri_energy_nj 差分）；<0 = 这一拍还没基线
@property (nonatomic, assign) double wakeups;    // 次/秒（能耗估算的输入，也给校验用）
@property (nonatomic, assign) NSInteger sockets; // 活跃 socket 数
@property (nonatomic, assign) double netIn;       // 累计接收字节；<0 这一拍拿不到
@property (nonatomic, assign) double netOut;      // 累计发送字节；<0 这一拍拿不到
@property (nonatomic, assign) double netInRate;   // 接收字节/秒；<0 还没基线
@property (nonatomic, assign) double netOutRate;  // 发送字节/秒；<0 还没基线
@property (nonatomic, assign) long long startedAt; // 进程启动的 unix 秒；0 = 不知道
@end

@interface DeskProcsMonitor : NSObject
// 推进一拍。内部留着上一拍的累计值，两拍求差 —— 所以第一次调用只有内存和 socket 是准的，
// cpu / energy / wakeups / net 速率会是负数表示"还不知道"，和 DeskSysMonitor 的约定一致。
- (NSArray<DeskProc *> *)sample;

@property (nonatomic, readonly) NSInteger readable;   // 这拍读到的进程数
@property (nonatomic, readonly) NSInteger denied;     // 这拍被 EPERM 挡掉的进程数
// 按某个指标取前 n 名（并列时按 pid 稳定排，免得每拍换序导致榜单抖动）
- (NSArray<DeskProc *> *)topByCPU:(NSInteger)n;
- (NSArray<DeskProc *> *)topByMem:(NSInteger)n;
- (NSArray<DeskProc *> *)topByEnergy:(NSInteger)n;
- (NSArray<DeskProc *> *)topByNet:(NSInteger)n;
// 悬停浮层按 pid 取当前这一拍的读数（没有就返回 nil，浮层自己收起）
- (DeskProc *)procWithPid:(pid_t)pid;
@end

// —— 悬停气泡里的进程介绍 ——
// 查内置表 + 按可执行路径推断，不联网、不读文件。读不出来就返回 nil，
// 气泡宁可少印一行，也不编一句「未知进程」。
// 取路径要一次系统调用，只在换行（悬停变化）时调，别塞进 10 秒一拍的采样循环。
NSString *DeskProcExecutablePath(pid_t pid);
// 一句话说清这进程是干什么的；nil = 确实认不出来
NSString *DeskProcIntroText(NSString *name, NSString *path);
// 出处：App 包路径或可执行文件全路径，家目录缩成 ~，已带「来自 」前缀
NSString *DeskProcOriginText(NSString *path);
