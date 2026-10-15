// 传感器探针：确认这台机器上风扇/温度/WiFi 到底能读到什么，再决定面板显示哪几项。
// 用法：probe_sensors
#import <AppKit/AppKit.h>
#import <CoreWLAN/CoreWLAN.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import "smc.h"

static void DumpKey(DeskSMC *smc, NSString *k) {
    NSNumber *v = [smc numberForKey:k];
    printf("  %-6s type=%-5s size=%2lu  value=%s\n", k.UTF8String,
           [[smc typeForKey:k] UTF8String], (unsigned long)[smc sizeForKey:k],
           v ? [[NSString stringWithFormat:@"%@", v] UTF8String] : "(读不到)");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplicationLoad();
        DeskSMC *smc = [DeskSMC new];
        printf("SMC 用户客户端打开：%s\n", [smc open] ? "成功" : "失败");
        NSArray<NSString *> *keys = [smc allKeys];
        printf("枚举到 %lu 个键\n", (unsigned long)keys.count);

        printf("\n风扇相关（F*）\n");
        for (NSString *k in keys) if ([k hasPrefix:@"F"]) DumpKey(smc, k);

        printf("\n温度相关（T*，最多列 40 个）\n");
        int shown = 0, total = 0;
        for (NSString *k in keys) {
            if (![k hasPrefix:@"T"]) continue;
            total++;
            if (shown++ < 40) DumpKey(smc, k);
        }
        printf("  …T* 键共 %d 个\n", total);

        printf("\nSCDynamicStore State:/Network/Global/IPv4\n");
        CFPropertyListRef d = SCDynamicStoreCopyValue(NULL, CFSTR("State:/Network/Global/IPv4"));
        printf("  %s\n", ((__bridge NSObject *)d).description.UTF8String ?: "(nil)");
        if (d) CFRelease(d);

        printf("\nWiFi（CoreWLAN）\n");
        CWWiFiClient *cli = [CWWiFiClient sharedWiFiClient];
        CWInterface *iface = [cli interface];
        if (!iface) {
            printf("  拿不到无线接口\n");
        } else {
            printf("  接口名   = %s\n", iface.interfaceName.UTF8String ?: "(nil)");
            printf("  SSID     = %s\n", iface.ssid.UTF8String ?: "(nil，macOS 14+ 需要定位授权)");
            printf("  BSSID    = %s\n", iface.bssid.UTF8String ?: "(nil)");
            printf("  RSSI     = %ld dBm\n", (long)iface.rssiValue);
            printf("  噪声     = %ld dBm\n", (long)iface.noiseMeasurement);
            printf("  传输速率 = %.1f Mbps\n", iface.transmitRate);
            printf("  WiFi 开关 = %d   已关联 = %d\n", iface.serviceActive, iface.ssid.length > 0);
            printf("  信道     = %ld  频段=%ld  带宽=%ld\n",
                   (long)iface.wlanChannel.channelNumber, (long)iface.wlanChannel.channelBand,
                   (long)iface.wlanChannel.channelWidth);
        }
        return 0;
    }
}
