// 过去 12 小时的历史桶：把每 5 秒一拍的读数按分钟攒下来，落盘，再按窗口求平均。
// 为什么要自己攒 —— macOS 没有任何公开 API 能给"过去 12 小时"的任意指标：
// getloadavg 只到 15 分钟，host_cpu_load_info 和网卡计数都是"自开机累计"，
// 而这台机器已经开机 138 小时，since-boot 不等于 12h。
#import <Foundation/Foundation.h>

@class DeskProc;

typedef NS_ENUM(NSInteger, DeskHistMetric) {
    DeskHistCPU = 0,     // %CPU
    DeskHistMemory,      // 常驻字节
    DeskHistEnergy,      // 自算能耗影响（和界面同一套估算）
    DeskHistNetwork,     // 活跃 socket 数
    DeskHistMetricCount
};

// 窗口长度。改这个值等于改产品口径，界面上"12 小时"那几个字要跟着动。
extern const double kDeskHistoryWindow;

@interface DeskHistory : NSObject

- (instancetype)initWithPath:(NSString *)path;

// 读回上次运行攒的桶，剪掉窗口之外的。文件不存在或坏了都算成功（只是没历史），
// 因为"冷启动没数据"是正常状态，界面靠 covered 自己标出来。
- (BOOL)load;

// 推进一拍。dt 是这一拍代表多少秒（用真实时间差，不用写死的 5，定时器会漂）。
// rows 是当前这一拍读到的进程；totals 是四个榜头的系统总量，顺序同 DeskHistMetric。
- (void)noteSampleAt:(NSTimeInterval)now seconds:(double)dt
                rows:(NSArray<DeskProc *> *)rows
              totals:(const double *)totals;

// 某进程在 [now-window, now] 的平均值。coveredOut 给"窗口内真正记录到的秒数"，
// 界面必须拿它判断数据完不完整 —— 没这个口就会把 3 小时的数标成 12 小时平均。
- (double)averageForPid:(pid_t)pid metric:(DeskHistMetric)m
                    now:(NSTimeInterval)now window:(double)window
                covered:(double *)coveredOut;

// 系统总量（榜头那四个读数）的同口径平均
- (double)averageForSystemMetric:(DeskHistMetric)m
                             now:(NSTimeInterval)now window:(double)window
                         covered:(double *)coveredOut;

// 攒脏了才写。落盘频率是"每分钟一次"而不是"每拍一次"，就是为了别为这点事抢 CPU
- (BOOL)flushIfNeeded;

@property (nonatomic, readonly) double recordedSeconds;   // 目前总共攒到了多少秒
@property (nonatomic, readonly) NSUInteger trackedPids;   // 正在跟踪的进程数
@end
