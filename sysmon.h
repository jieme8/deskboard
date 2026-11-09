// 系统指标采集：全部走 mach / IOKit 公共 API，零权限。
// 两次 sample 之间求差，所以第一次调用只能给出基线（相关字段为负数表示未知）。
#import <Foundation/Foundation.h>

// CPU 读数的统一时间窗口：活动监视器的每进程 CPU 是 10 秒采样间隔，
// 系统总 CPU 用同一个窗口，两块面板和进程榜才是同一把尺。
// 屏上的 "10s" 标签必须从这个数生成，别在视图里另写一个字面量。
#define kDeskCPUWindowSeconds 10.0

@interface DeskStats : NSObject
@property (nonatomic, assign) double cpu;         // 0–100，<0 未知
@property (nonatomic, assign) double cpuWindow;   // 这拍 CPU 读数覆盖的秒数，<0 未知
@property (nonatomic, assign) double gpu;         // 0–100，<0 未知
@property (nonatomic, assign) double memUsed;     // 字节
@property (nonatomic, assign) double memTotal;    // 字节
@property (nonatomic, assign) double diskFree;    // 字节
@property (nonatomic, assign) double diskTotal;   // 字节
@property (nonatomic, assign) double diskRead;    // 字节/秒，<0 未知
@property (nonatomic, assign) double diskWrite;   // 字节/秒，<0 未知
@property (nonatomic, assign) BOOL diskIsSSD;
@property (nonatomic, assign) NSInteger thermal;  // NSProcessInfoThermalState 0..3
@property (nonatomic, assign) double cpuTemp;     // °C，<0 未知
@property (nonatomic, assign) double ssdTemp;     // °C，<0 未知
@property (nonatomic, copy) NSString *netInterface;
@property (nonatomic, copy) NSString *netAddress;
@property (nonatomic, assign) BOOL netIsWiFi;
@property (nonatomic, assign) double netRecv;    // 字节/秒，<0 未知

// 卡片表尾用的三个慢变量。都走公开 API、零权限：
// IOPS 拿电池，sysctl vm.swapusage 拿交换，getloadavg 拿 1 分钟负载。
@property (nonatomic, assign) double batteryPercent;  // 0–100，<0 未知/无电池
@property (nonatomic, assign) BOOL batteryOnAC;       // 交流电供电
@property (nonatomic, assign) BOOL batteryCharging;   // 正在充电
@property (nonatomic, assign) BOOL batteryCharged;    // 已充满
@property (nonatomic, assign) NSInteger batteryMinutes; // 剩余/充满分钟，-1 未知
@property (nonatomic, assign) double swapUsed;    // 字节，<0 未知
@property (nonatomic, assign) double swapTotal;   // 字节，<=0 未知
@property (nonatomic, assign) double load1;       // 1 分钟负载，<0 未知
@property (nonatomic, assign) double netSend;    // 字节/秒，<0 未知
- (double)memFraction;
- (double)diskFraction;
@end

@interface DeskSysMonitor : NSObject
- (DeskStats *)sample;
@end
