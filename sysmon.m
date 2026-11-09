#import "sysmon.h"
#import "hidtemp.h"
#import <mach/mach.h>
#import <sys/param.h>
#import <sys/mount.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <string.h>
#import <net/if.h>
#import <net/route.h>
#import <net/if_dl.h>
#import <sys/sysctl.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOKitKeys.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreWLAN/CoreWLAN.h>
#import <stdlib.h>

@implementation DeskStats
- (instancetype)init {
    if ((self = [super init])) {
        // 慢变量的未知值：格式化层看到负数就印 "—"，不会把 0 当成"真的 0%"
        _cpuWindow = -1;
        _batteryPercent = -1;
        _batteryMinutes = -1;
        _swapUsed = -1;
        _swapTotal = -1;
        _load1 = -1;
    }
    return self;
}
- (double)memFraction {
    return self.memTotal > 0 ? self.memUsed / self.memTotal : -1;
}
- (double)diskFraction {
    return self.diskTotal > 0 ? (self.diskTotal - self.diskFree) / self.diskTotal : -1;
}
@end

static double DictNumber(CFDictionaryRef dict, CFStringRef key) {
    if (!dict) return -1;
    CFTypeRef v = CFDictionaryGetValue(dict, key);
    if (!v || CFGetTypeID(v) != CFNumberGetTypeID()) return -1;
    double out = -1;
    CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &out);
    return out;
}

// CPU tick 历史。10 秒采一拍、窗口固定 10 秒时，正好用目标时刻两侧的两拍插值，
// 所以读数覆盖的永远是整整 10 秒，而不是"两拍之间的 10 秒"或"最近的 20 秒"。
#define kCPUHistCap 8
typedef struct {
    uint64_t ticks[4];       // 各状态累计 tick（自己扩展成 64 位，32 位绕回也不会算错）
    CFAbsoluteTime at;
} DeskCPUTickSample;

@implementation DeskSysMonitor {
    host_t _host;
    io_service_t _accel;
    DeskCPUTickSample _cpuHist[kCPUHistCap];
    NSInteger _cpuHistCount;
    uint32_t _prevRawTicks[4];
    uint64_t _cpuAccumTicks[4];
    BOOL _hasCPURaw;
    unsigned long long _prevRead, _prevWrite;
    CFAbsoluteTime _prevAt;
    BOOL _hasIOBaseline;
    unsigned long long _prevRecv, _prevSend;
    CFAbsoluteTime _prevNetAt;
    BOOL _hasNetBaseline;
    CFAbsoluteTime _tempAt;       // 上一次读温度的时刻
    double _cpuTemp, _ssdTemp;    // 温度是分钟级慢变量，缓存 15 秒，别每拍去问 IOHID
}

- (instancetype)init {
    if ((self = [super init])) {
        _host = mach_host_self();
        _accel = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    }
    return self;
}

- (void)dealloc {
    if (_accel) IOObjectRelease(_accel);
}

// 介质类型在块存储驱动的上一级（provider）的 Device Characteristics 里。
// 本机实测只有 "Medium Type"="Solid State"，没有别处常见的 "Medium Rotation"。
static NSString *MediumTypeOf(io_service_t driver) {
    io_service_t parent = 0;
    if (IORegistryEntryGetParentEntry(driver, kIOServiceClass, &parent) != KERN_SUCCESS || !parent) return nil;
    NSString *type = nil;
    CFDictionaryRef chars = IORegistryEntryCreateCFProperty(parent, CFSTR("Device Characteristics"),
                                                            kCFAllocatorDefault, 0);
    if (chars) {
        CFTypeRef v = CFDictionaryGetValue(chars, CFSTR("Medium Type"));
        if (v && CFGetTypeID(v) == CFStringGetTypeID()) type = CFBridgingRelease(CFRetain(v));
        CFRelease(chars);
    }
    IOObjectRelease(parent);
    return type;
}

// 遍历所有 IOBlockStorageDriver 累加读写字节，并据介质类型判断是否全 SSD
- (void)readDiskCounters:(unsigned long long *)read outWrite:(unsigned long long *)write
                    ssd:(BOOL *)ssd {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) != KERN_SUCCESS) {
        *ssd = NO;
        return;
    }
    io_service_t svc;
    BOOL sawMediaType = NO;
    while ((svc = IOIteratorNext(it))) {
        CFDictionaryRef stats = IORegistryEntryCreateCFProperty(svc, CFSTR("Statistics"),
                                                                kCFAllocatorDefault, 0);
        if (stats) {
            *read += (unsigned long long)MAX(DictNumber(stats, CFSTR("Bytes (Read)")), 0);
            *write += (unsigned long long)MAX(DictNumber(stats, CFSTR("Bytes (Write)")), 0);
            CFRelease(stats);
        }
        NSString *type = MediumTypeOf(svc);
        if (type.length) {
            sawMediaType = YES;
            if (![type containsString:@"Solid"]) *ssd = NO;   // 有一块机械盘就不叫全 SSD
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    if (!sawMediaType) *ssd = NO;   // 读不到介质类型就别自称 SSD
}

// 默认路由走的是哪块网卡：SCDynamicStore 是公开 API，零权限，比解析 route 输出可靠。
// 注意这台系统的字典里已经没有 PrimaryAddress，本机 IPv4 要用 getifaddrs 取。
static void ReadNetwork(DeskStats *s) {
    CFPropertyListRef dict = SCDynamicStoreCopyValue(NULL, CFSTR("State:/Network/Global/IPv4"));
    if (dict && CFGetTypeID(dict) == CFDictionaryGetTypeID()) {
        id iface = (__bridge id)CFDictionaryGetValue((CFDictionaryRef)dict, CFSTR("PrimaryInterface"));
        if ([iface isKindOfClass:[NSString class]]) s.netInterface = iface;
    }
    if (dict) CFRelease(dict);

    const char *ifname = s.netInterface.UTF8String;
    struct ifaddrs *addrs = NULL;
    if (ifname && getifaddrs(&addrs) == 0) {
        for (struct ifaddrs *a = addrs; a; a = a->ifa_next) {
            if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
            if (strcmp(a->ifa_name, ifname) != 0) continue;
            char buf[INET_ADDRSTRLEN] = {0};
            struct sockaddr_in *sin = (struct sockaddr_in *)a->ifa_addr;
            if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof buf)) {
                s.netAddress = [NSString stringWithUTF8String:buf];
            }
            break;
        }
        freeifaddrs(addrs);
    }

    NSString *wifi = [[CWWiFiClient sharedWiFiClient].interface interfaceName];
    s.netIsWiFi = s.netInterface.length > 0 && [s.netInterface isEqualToString:wifi];
}

// 网卡累计收发字节。getifaddrs 给的 if_data 计数是 32 位、跑久了会绕回，
// NET_RT_IFLIST2 返回的 if_data64 才是 64 位的，且同样是公开 sysctl，零权限。
static BOOL ReadNetBytes(NSString *ifname, unsigned long long *recv, unsigned long long *send) {
    if (!ifname.length) return NO;
    unsigned int idx = if_nametoindex(ifname.UTF8String);
    if (idx == 0) return NO;
    int mib[6] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0 || len == 0) return NO;
    void *buf = malloc(len);
    if (!buf) return NO;
    BOOL ok = NO;
    if (sysctl(mib, 6, buf, &len, NULL, 0) >= 0) {
        for (char *p = buf; p < (char *)buf + len; ) {
            struct if_msghdr *ifm = (struct if_msghdr *)p;
            if (ifm->ifm_type == RTM_IFINFO2) {
                struct if_msghdr2 *if2 = (struct if_msghdr2 *)ifm;
                if ((unsigned int)if2->ifm_index == idx) {
                    *recv = if2->ifm_data.ifi_ibytes;
                    *send = if2->ifm_data.ifi_obytes;
                    ok = YES;
                    break;
                }
            }
            p += ifm->ifm_msglen;
        }
    }
    free(buf);
    return ok;
}

// 电池：IOPS 是公开、零权限的电源抽象。macOS 14+ 读 SSID 要定位授权，但读电量不需要。
// 只认内置电池，外接 UPS 不混进来；没有电池的机器所有字段保持 -1，界面印 "—"。
static void ReadPower(DeskStats *s) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return;
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    if (list) {
        for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
            CFDictionaryRef d = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
            if (!d) continue;
            NSString *type = (__bridge NSString *)CFDictionaryGetValue(d, CFSTR(kIOPSTypeKey));
            NSString *internalType = [NSString stringWithUTF8String:kIOPSInternalBatteryType];
            if (type && internalType && ![type isEqualToString:internalType]) continue;
            NSNumber *cur = (__bridge NSNumber *)CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey));
            NSNumber *max = (__bridge NSNumber *)CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey));
            if (cur && max && max.doubleValue > 0)
                s.batteryPercent = cur.doubleValue / max.doubleValue * 100.0;
            NSString *state = (__bridge NSString *)CFDictionaryGetValue(d, CFSTR(kIOPSPowerSourceStateKey));
            NSString *acPower = [NSString stringWithUTF8String:kIOPSACPowerValue];
            s.batteryOnAC = state && acPower && [state isEqualToString:acPower];
            NSNumber *charging = (__bridge NSNumber *)CFDictionaryGetValue(d, CFSTR(kIOPSIsChargingKey));
            s.batteryCharging = charging.boolValue;
            NSNumber *charged = (__bridge NSNumber *)CFDictionaryGetValue(d, CFSTR(kIOPSIsChargedKey));
            s.batteryCharged = charged.boolValue;
            NSNumber *mins = (__bridge NSNumber *)CFDictionaryGetValue(d, s.batteryCharging
                ? CFSTR(kIOPSTimeToFullChargeKey) : CFSTR(kIOPSTimeToEmptyKey));
            if (mins) s.batteryMinutes = mins.integerValue;
            break;
        }
        CFRelease(list);
    }
    CFRelease(info);
}

// 交换：和内存百分比不是一回事。机器能靠压缩内存把"已用"压回 60%，
// 但交换里躺着 949M 时，实际压力比百分比看起来大。vm.swapusage 是公开 sysctl。
static void ReadSwap(DeskStats *s) {
    struct xsw_usage swap;
    size_t len = sizeof(swap);
    int mib[2] = { CTL_VM, VM_SWAPUSAGE };
    if (sysctl(mib, 2, &swap, &len, NULL, 0) == 0) {
        s.swapTotal = (double)swap.xsu_total;
        s.swapUsed = (double)swap.xsu_used;
    }
}

// 1 分钟负载：getloadavg 是 libc 公开接口。只取 1 分钟值，表尾只放得下一个数。
static void ReadLoad(DeskStats *s) {
    double loads[3] = { 0, 0, 0 };
    if (getloadavg(loads, 3) == 3) s.load1 = loads[0];
}

- (DeskStats *)sample {
    DeskStats *s = [DeskStats new];
    s.cpu = -1; s.cpuWindow = -1; s.gpu = -1; s.diskRead = -1; s.diskWrite = -1;
    s.netRecv = -1; s.netSend = -1;
    s.batteryPercent = -1; s.batteryMinutes = -1;
    s.swapUsed = -1; s.swapTotal = -1;
    s.load1 = -1;
    s.diskIsSSD = YES;

    // CPU：维护累计 tick 的历史，用目标时刻（now - 10s）两侧的两拍插值求差。
    // 这样不管 sample 是 2 秒还是 5 秒一拍，读数覆盖的都是整整 kDeskCPUWindowSeconds。
    host_cpu_load_info_data_t cur;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (host_statistics(_host, HOST_CPU_LOAD_INFO, (host_info_t)&cur, &count) == KERN_SUCCESS) {
        uint32_t raw[4] = {
            cur.cpu_ticks[CPU_STATE_USER], cur.cpu_ticks[CPU_STATE_SYSTEM],
            cur.cpu_ticks[CPU_STATE_IDLE], cur.cpu_ticks[CPU_STATE_NICE],
        };
        if (_hasCPURaw) {
            for (int i = 0; i < 4; i++) {
                _cpuAccumTicks[i] += (uint32_t)(raw[i] - _prevRawTicks[i]);
                _prevRawTicks[i] = raw[i];
            }
        } else {
            for (int i = 0; i < 4; i++) {
                _cpuAccumTicks[i] = raw[i];
                _prevRawTicks[i] = raw[i];
            }
            _hasCPURaw = YES;
        }

        if (_cpuHistCount == kCPUHistCap) {
            memmove(&_cpuHist[0], &_cpuHist[1], sizeof(_cpuHist[0]) * (kCPUHistCap - 1));
            _cpuHistCount--;
        }
        DeskCPUTickSample *slot = &_cpuHist[_cpuHistCount++];
        for (int i = 0; i < 4; i++) slot->ticks[i] = _cpuAccumTicks[i];
        slot->at = now;

        double target = now - kDeskCPUWindowSeconds;
        if (_cpuHist[0].at <= target) {
            NSInteger lo = -1;
            for (NSInteger i = 0; i + 1 < _cpuHistCount; i++) {
                if (_cpuHist[i].at <= target && target <= _cpuHist[i + 1].at) { lo = i; break; }
            }
            if (lo >= 0) {
                const DeskCPUTickSample *a = &_cpuHist[lo], *b = &_cpuHist[lo + 1];
                double span = b->at - a->at;
                double frac = span > 0 ? (target - a->at) / span : 1.0;
                double used = 0, total = 0;
                for (int i = 0; i < 4; i++) {
                    double base = (double)a->ticks[i]
                                + ((double)b->ticks[i] - (double)a->ticks[i]) * frac;
                    double delta = (double)_cpuHist[_cpuHistCount - 1].ticks[i] - base;
                    if (delta < 0) delta = 0;
                    if (i != CPU_STATE_IDLE) used += delta;
                    total += delta;
                }
                if (total > 0) {
                    s.cpu = used / total * 100.0;
                    s.cpuWindow = kDeskCPUWindowSeconds;
                }
            }
        }
    }

    // 内存：活动监视器口径的"已使用" = 匿名内存(扣除可清除) + wired + compressed。
    // 旧写法用 active，active 里混着文件缓存，本机实测会比原生少算约 1GB。
    vm_size_t pageSize = 4096;
    host_page_size(_host, &pageSize);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t vmCount = HOST_VM_INFO64_COUNT;
    if (host_statistics64(_host, HOST_VM_INFO64, (host_info64_t)&vm, &vmCount) == KERN_SUCCESS) {
        double anonymous = (double)vm.internal_page_count - (double)vm.purgeable_count;
        if (anonymous < 0) anonymous = 0;
        s.memUsed = (anonymous + vm.wire_count + vm.compressor_page_count) * pageSize;
        s.memTotal = (double)[NSProcessInfo processInfo].physicalMemory;
    }

    // 热压力：CPU 摄氏度在 Apple Silicon 上要 SMC（本机旧协议返回 Unsupported），
    // 公开可用的只有这个等级。IOHID 读温要逐传感器 CopyEvent，实测一次几十毫秒，
    // 5 秒一拍照做会把主线程吃掉一成多；温度变化以分钟计，缓存 15 秒完全够。
    s.thermal = [NSProcessInfo processInfo].thermalState;
    if (_tempAt == 0 || now - _tempAt >= 15.0) {
        _cpuTemp = DeskReadCPUTemp();
        _ssdTemp = DeskReadSSDTemp();
        _tempAt = now;
    }
    s.cpuTemp = _cpuTemp;
    s.ssdTemp = _ssdTemp;
    ReadNetwork(s);

    // GPU：IOAccelerator 的性能统计字典，不同机型键名不完全一样，按优先级试
    if (_accel) {
        CFDictionaryRef stats = IORegistryEntryCreateCFProperty(_accel, CFSTR("PerformanceStatistics"),
                                                               kCFAllocatorDefault, 0);
        if (stats) {
            CFStringRef keys[] = {CFSTR("Device Utilization %"), CFSTR("Renderer Utilization %"),
                                  CFSTR("GPU Activity(%)")};
            for (int i = 0; i < 3; i++) {
                double v = DictNumber(stats, keys[i]);
                if (v >= 0) { s.gpu = v; break; }
            }
            CFRelease(stats);
        }
    }

    // 磁盘容量
    struct statfs st;
    if (statfs("/", &st) == 0) {
        s.diskTotal = (double)st.f_blocks * st.f_bsize;
        s.diskFree = (double)st.f_bavail * st.f_bsize;
    }

    // 磁盘读写速率：累计字节求差
    unsigned long long r = 0, w = 0;
    BOOL ssd = YES;
    [self readDiskCounters:&r outWrite:&w ssd:&ssd];
    s.diskIsSSD = ssd;
    if (_hasIOBaseline && r + w > 0) {
        double dt = now - _prevAt;
        if (dt > 0.2) {
            s.diskRead = (double)(r - _prevRead) / dt;
            s.diskWrite = (double)(w - _prevWrite) / dt;
        }
    }
    if (r + w > 0) {
        _prevRead = r; _prevWrite = w; _prevAt = now; _hasIOBaseline = YES;
    }

    // 网络收发速率：同一套"累计字节求差"，基准时间复用磁盘那一拍（同一个 now）
    s.netRecv = -1; s.netSend = -1;
    unsigned long long rv = 0, sv = 0;
    if (ReadNetBytes(s.netInterface, &rv, &sv)) {
        // 网卡计数器是 unsigned：接口重连/计数器回绕时 rv 会小于上一拍，直接减会得到一个
        // 接近 2^64 的"速率"，再乘 dt 写进 12h 历史，累计流量会被一桶带飞。
        // 这一拍当成"没有基线"，只重置基准，不产出速率。
        if (_hasNetBaseline && rv >= _prevRecv && sv >= _prevSend) {
            double dt = now - _prevNetAt;
            if (dt > 0.2) {
                s.netRecv = (double)(rv - _prevRecv) / dt;
                s.netSend = (double)(sv - _prevSend) / dt;
            }
        }
        _prevRecv = rv; _prevSend = sv; _prevNetAt = now; _hasNetBaseline = YES;
    }

    ReadPower(s);
    ReadSwap(s);
    ReadLoad(s);
    return s;
}

@end
