#import "hidtemp.h"
#import <dlfcn.h>

typedef void *HIDClient;
typedef void *HIDService;
typedef void *HIDEvent;
typedef uint32_t HIDEventType;
typedef uint32_t HIDEventField;
enum { kTempType = 15 };                      // kIOHIDEventTypeTemperature
enum { kTempField = (15 << 16) };             // kIOHIDEventFieldTemperatureLevel

static HIDClient   (*CreateClient)(CFAllocatorRef);
static int         (*SetMatching)(HIDClient, CFDictionaryRef);
static CFArrayRef  (*CopyServices)(HIDClient);
static CFTypeRef   (*CopyProperty)(HIDService, CFStringRef);
static HIDEvent    (*CopyEvent)(HIDService, HIDEventType, int32_t, int64_t);
static double      (*GetFloat)(HIDEvent, HIDEventField);

static HIDClient _client;
static BOOL _tried;

static void Init(void) {
    if (_tried) return;
    _tried = YES;
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) return;
    CreateClient  = dlsym(h, "IOHIDEventSystemClientCreate");
    SetMatching   = dlsym(h, "IOHIDEventSystemClientSetMatching");
    CopyServices  = dlsym(h, "IOHIDEventSystemClientCopyServices");
    CopyProperty  = dlsym(h, "IOHIDServiceClientCopyProperty");
    CopyEvent     = dlsym(h, "IOHIDServiceClientCopyEvent");
    GetFloat      = dlsym(h, "IOHIDEventGetFloatValue");
    if (!CreateClient || !CopyServices || !CopyEvent || !GetFloat) return;

    _client = CreateClient(kCFAllocatorDefault);
    if (!_client) return;
    // 只匹配温度类传感器：usage page 0xFF00 / usage 5（IORegistry 里那些 PMU 传感器的声明）
    NSDictionary *match = @{ (__bridge NSString *)CFSTR("PrimaryUsagePage"): @(0xFF00),
                             (__bridge NSString *)CFSTR("PrimaryUsage"): @(5) };
    if (SetMatching) SetMatching(_client, (__bridge CFDictionaryRef)match);
}

static double ReadBest(BOOL wantSSD) {
    Init();
    if (!_client) return -1;
    CFArrayRef services = CopyServices(_client);
    if (!services) return -1;
    double best = -1;
    CFIndex n = CFArrayGetCount(services);
    for (CFIndex i = 0; i < n; i++) {
        HIDService svc = (HIDService)CFArrayGetValueAtIndex(services, i);
        NSString *product = nil;
        if (CopyProperty) {
            CFTypeRef p = CopyProperty(svc, CFSTR("Product"));
            if (p) product = CFBridgingRelease(p);
        }
        if (!product.length) continue;
        HIDEvent ev = CopyEvent(svc, kTempType, 0, 0);
        if (!ev) continue;
        double v = GetFloat(ev, kTempField);
        CFRelease(ev);
        if (!(v > -20.0 && v < 130.0)) continue;      // 滤掉 -9201 这类未接线的哨兵值
        BOOL hit = wantSSD ? [product containsString:@"NAND"]
                           : [product hasPrefix:@"PMU tdie"];
        if (hit && v > best) best = v;
    }
    CFRelease(services);
    return best;
}

double DeskReadCPUTemp(void) { return ReadBest(NO); }
double DeskReadSSDTemp(void) { return ReadBest(YES); }
