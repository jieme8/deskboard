// 系统指标采集：全部走 mach / IOKit 公共 API，零权限。
// 两次 sample 之间求差，所以第一次调用只能给出基线（相关字段为负数表示未知）。
#import <Foundation/Foundation.h>

@interface DeskStats : NSObject
@property (nonatomic, assign) double cpu;         // 0–100，<0 未知
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
@property (nonatomic, assign) double netSend;    // 字节/秒，<0 未知
- (double)memFraction;
- (double)diskFraction;
@end

@interface DeskSysMonitor : NSObject
- (DeskStats *)sample;
@end
