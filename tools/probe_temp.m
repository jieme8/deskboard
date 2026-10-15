// 温度探针：Apple Silicon 的 CPU/GPU 温度不在 SMC 用户客户端里（那条路本机回 Unsupported），
// 而是作为 IOHID 传感器（usage page 0xFF00 / usage 5，产品名 "PMU tcal"、"PMU tdev1" 等）
// 由 IOHIDEventSystem 发布。这些符号在 IOKit 里存在但没有公开头文件，所以用 dlsym 取。
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDLib.h>
#import <dlfcn.h>

// 这个 SDK 没带 IOHIDEventTypes.h，事件类型/字段常量自己定义（值取自 IOKit 头文件）
typedef uint32_t HIDEventType;
typedef uint32_t HIDEventField;
enum { kTempEventType = 15 };
enum { kTempEventField = (15 << 16) };

typedef void *HIDEventSystemClientRef;
typedef void *HIDServiceClientRef;
typedef void *HIDEventRef;

static HIDEventSystemClientRef (*CreateClient)(CFAllocatorRef);
static int (*SetMatching)(HIDEventSystemClientRef, CFDictionaryRef);
static CFArrayRef (*CopyServices)(HIDEventSystemClientRef);
static CFTypeRef (*CopyProperty)(HIDServiceClientRef, CFStringRef);
static HIDEventRef (*CopyEvent)(HIDServiceClientRef, HIDEventType, int32_t, int64_t);
static double (*GetFloatValue)(HIDEventRef, HIDEventField);
static HIDEventType (*GetEventType)(HIDEventRef);

static void LoadSymbols(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) { printf("dlopen IOKit 失败\n"); return; }
    CreateClient   = dlsym(h, "IOHIDEventSystemClientCreate");
    SetMatching    = dlsym(h, "IOHIDEventSystemClientSetMatching");
    CopyServices   = dlsym(h, "IOHIDEventSystemClientCopyServices");
    CopyProperty   = dlsym(h, "IOHIDServiceClientCopyProperty");
    CopyEvent      = dlsym(h, "IOHIDServiceClientCopyEvent");
    GetFloatValue  = dlsym(h, "IOHIDEventGetFloatValue");
    GetEventType   = dlsym(h, "IOHIDEventGetType");
    printf("符号解析：create=%d match=%d copy=%d prop=%d event=%d value=%d type=%d\n",
           CreateClient != NULL, SetMatching != NULL, CopyServices != NULL, CopyProperty != NULL,
           CopyEvent != NULL, GetFloatValue != NULL, GetEventType != NULL);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        LoadSymbols();
        if (!CreateClient || !CopyServices || !CopyEvent) return 1;

        HIDEventSystemClientRef client = CreateClient(kCFAllocatorDefault);
        if (!client) { printf("建 client 失败\n"); return 1; }
        CFDictionaryRef dict = (__bridge CFDictionaryRef)@{
            (__bridge id)CFSTR("PrimaryUsagePage"): @(0xFF00),
            (__bridge id)CFSTR("PrimaryUsage"): @(5),
        };
        int rc = SetMatching ? SetMatching(client, dict) : -1;
        printf("SetMatching rc=%d\n", rc);

        CFArrayRef services = CopyServices(client);
        printf("匹配到 %ld 个传感器服务\n", services ? CFArrayGetCount(services) : -1);
        CFIndex n = services ? CFArrayGetCount(services) : 0;
        int shown = 0;
        for (CFIndex i = 0; i < n; i++) {
            HIDServiceClientRef svc = (HIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            NSString *product = nil;
            if (CopyProperty) {
                CFTypeRef p = CopyProperty(svc, CFSTR("Product"));
                product = p ? CFBridgingRelease(p) : nil;
            }
            HIDEventRef ev = CopyEvent(svc, kTempEventType, 0, 0);
            if (!ev) continue;
            int isTemp = GetEventType ? (GetEventType(ev) == kTempEventType) : 1;
            double value = GetFloatValue ? GetFloatValue(ev, kTempEventField) : -1;
            if (isTemp && shown++ < 30) {
                printf("  %-14s %8.2f °C\n", product.UTF8String ?: "(无名)", value);
            }
            CFRelease(ev);
        }
        printf("  共 %d 个温度类读数\n", shown);
        return 0;
    }
}
