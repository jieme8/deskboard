// M 系列温度读取：CPU/GPU/SSD 温度不在 SMC 用户客户端里（本机那条路一律回
// kIOReturnUnsupported），而是作为 IOHID 传感器由 IOHIDEventSystem 发布，零权限可读。
// 这些符号在 IOKit 里没有公开头文件，所以运行时用 dlsym 取。
#import <Foundation/Foundation.h>

// 取各 die 温度（PMU tdie*）里的最大值作为 CPU 温度；读不到返回 -1
double DeskReadCPUTemp(void);
// SSD（NAND 通道）温度，读不到返回 -1
double DeskReadSSDTemp(void);
