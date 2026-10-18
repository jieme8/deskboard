// 每进程负载采集：CPU / 内存 / 能耗（估）/ 网络。全部零权限，只覆盖当前用户的进程。
// 这台机器上实测过的边界，改之前先看：
//   · proc_pid_rusage 只能读本用户的进程（实测 567 可读 / 301 EPERM，
//     WindowServer、launchd 都在 EPERM 里）。top 能看到系统进程是因为它 setuid root。
//   · sysctl KERN_PROC_ALL 能列到 863 个进程，但 kp_proc.p_ru 对全部 863 个都是 NULL，
//     做不了后备。
//   · ri_user_time / ri_system_time 是 **mach 绝对时间刻度**，不是纳秒。本机 timebase
//     125/3 → 1 刻度 = 41.667ns。当成 ns 用会把 %CPU 少算 41.7 倍。
//   · 原生活动监视器的"能耗影响"走 IOReport，而这台系统上 IOKit 没导出 IOReport 符号
//     （dyld_info -exports 零命中，dlsym 全 NULL），所以能耗这一列只能自算，界面上标"（估）"。
//   · 每进程网络字节数：nettop 能零权限看全系统，但它实测烧 **146% 单核**，
//     绝不能拿来当组件数据源；NetworkStatistics 的公开面是未文档化的 NStat* 管理器，
//     结构体布局要猜。所以这一列先用"活跃 socket 连接数"排名，榜头给系统总速率。
#import <Foundation/Foundation.h>

@interface DeskProc : NSObject
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, assign) double cpu;        // %CPU，0~100×核数；<0 = 这一拍还没基线
@property (nonatomic, assign) double mem;        // 常驻字节
@property (nonatomic, assign) double energy;     // 自算能耗影响，相对值
@property (nonatomic, assign) double wakeups;    // 次/秒（能耗估算的输入，也给校验用）
@property (nonatomic, assign) NSInteger sockets; // 活跃 socket 数
@property (nonatomic, assign) long long startedAt; // 进程启动的 unix 秒；0 = 不知道
@end

@interface DeskProcsMonitor : NSObject
// 推进一拍。内部留着上一拍的累计值，两拍求差 —— 所以第一次调用只有内存和 socket 是准的，
// cpu / energy / wakeups 会是负数表示"还不知道"，和 DeskSysMonitor 的约定一致。
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
