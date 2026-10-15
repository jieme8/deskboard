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
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreWLAN/CoreWLAN.h>

@implementation DeskStats
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

@implementation DeskSysMonitor {
    host_t _host;
    io_service_t _accel;
    host_cpu_load_info_data_t _prevCPU;
    BOOL _hasCPUBaseline;
    unsigned long long _prevRead, _prevWrite;
    CFAbsoluteTime _prevAt;
    BOOL _hasIOBaseline;
    unsigned long long _prevRecv, _prevSend;
    CFAbsoluteTime _prevNetAt;
    BOOL _hasNetBaseline;
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

- (DeskStats *)sample {
    DeskStats *s = [DeskStats new];
    s.cpu = -1; s.gpu = -1; s.diskRead = -1; s.diskWrite = -1;
    s.diskIsSSD = YES;

    // CPU：累计 tick 求差
    host_cpu_load_info_data_t cur;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(_host, HOST_CPU_LOAD_INFO, (host_info_t)&cur, &count) == KERN_SUCCESS) {
        if (_hasCPUBaseline) {
            double user = cur.cpu_ticks[CPU_STATE_USER] - _prevCPU.cpu_ticks[CPU_STATE_USER];
            double sys = cur.cpu_ticks[CPU_STATE_SYSTEM] - _prevCPU.cpu_ticks[CPU_STATE_SYSTEM];
            double nice = cur.cpu_ticks[CPU_STATE_NICE] - _prevCPU.cpu_ticks[CPU_STATE_NICE];
            double idle = cur.cpu_ticks[CPU_STATE_IDLE] - _prevCPU.cpu_ticks[CPU_STATE_IDLE];
            double total = user + sys + nice + idle;
            if (total > 0) s.cpu = (user + sys + nice) / total * 100.0;
        }
        _prevCPU = cur;
        _hasCPUBaseline = YES;
    }

    // 内存：active + wired + compressed 是活动监视器口径的"已使用"
    vm_size_t pageSize = 4096;
    host_page_size(_host, &pageSize);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t vmCount = HOST_VM_INFO64_COUNT;
    if (host_statistics64(_host, HOST_VM_INFO64, (host_info64_t)&vm, &vmCount) == KERN_SUCCESS) {
        s.memUsed = (double)(vm.active_count + vm.wire_count + vm.compressor_page_count) * pageSize;
        s.memTotal = (double)[NSProcessInfo processInfo].physicalMemory;
    }

    // 热压力：CPU 摄氏度在 Apple Silicon 上要 SMC（本机旧协议返回 Unsupported），
    // 公开可用的只有这个等级
    s.thermal = [NSProcessInfo processInfo].thermalState;
    s.cpuTemp = DeskReadCPUTemp();
    s.ssdTemp = DeskReadSSDTemp();
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
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
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
        if (_hasNetBaseline) {
            double dt = now - _prevNetAt;
            if (dt > 0.2) {
                s.netRecv = (double)(rv - _prevRecv) / dt;
                s.netSend = (double)(sv - _prevSend) / dt;
            }
        }
        _prevRecv = rv; _prevSend = sv; _prevNetAt = now; _hasNetBaseline = YES;
    }
    return s;
}

@end
