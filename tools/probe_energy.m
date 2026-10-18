// 能耗列能不能和原生活动监视器同源：AM 用的是 IOReport 的 Energy 组。
// 这套符号没进 SDK 头文件，所以全部 dlsym 拿，拿不到就明确报"取不到"，不猜。
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>

typedef io_object_t IOReportChannelRef;
typedef struct { void *target; void *reference; void *function; } IOReportCallbackInfoObj;

typedef CFDictionaryRef (*CopyChannelsFn)(CFStringRef group, CFStringRef category);
typedef CFStringRef (*GetStrFn)(IOReportChannelRef);
typedef uint64_t (*GetIDFn)(IOReportChannelRef);
typedef kern_return_t (*CopyWithSourceFn)(io_connect_t, IOReportChannelRef, CFDictionaryRef *);
typedef io_registry_entry_t (*GetProviderFn)(IOReportChannelRef);

static void *IO;
static void Sym(const char *n, void **out) { *out = dlsym(IO, n); }

int main(void) {
    @autoreleasepool {
        IO = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        printf("IOKit dlopen %s\n", IO ? "成功" : "失败");
        CopyChannelsFn fCopy = NULL; GetStrFn fGroup = NULL, fSub = NULL, fName = NULL;
        GetIDFn fID = NULL; CopyWithSourceFn fSrc = NULL; GetProviderFn fProv = NULL;
        Sym("IOReportCopyChannelsInGroup", (void **)&fCopy);
        Sym("IOReportChannelGetGroup", (void **)&fGroup);
        Sym("IOReportChannelGetSubGroup", (void **)&fSub);
        Sym("IOReportChannelGetChannelName", (void **)&fName);
        Sym("IOReportChannelGetChannelID", (void **)&fID);
        Sym("IOReportCopyChannelWithSource", (void **)&fSrc);
        Sym("IOReportGetProviderForChannel", (void **)&fProv);
        printf("符号：CopyChannels=%p GetGroup=%p GetSubGroup=%p GetName=%p CopyWithSource=%p GetProvider=%p\n",
               (void*)fCopy, (void*)fGroup, (void*)fSub, (void*)fName, (void*)fSrc, (void*)fProv);
        if (!fCopy) { printf("拿不到 IOReportCopyChannelsInGroup，能耗只能自算\n"); return 2; }

        CFDictionaryRef chans = fCopy(CFSTR("Energy"), NULL);
        printf("\nEnergy 组通道：%ld 个\n", chans ? CFDictionaryGetCount(chans) : -1);
        if (!chans) { printf("枚举不到 Energy 组\n"); return 3; }

        CFIndex cnt = CFDictionaryGetCount(chans);
        const void **keys = calloc(cnt + 1, sizeof(void *));
        CFDictionaryGetKeysAndValues(chans, keys, NULL);
        io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
        printf("IOPMrootDomain 服务：%u\n", (unsigned)root);

        int shown = 0;
        for (CFIndex i = 0; i < cnt && shown < 14; i++) {
            IOReportChannelRef ch = (IOReportChannelRef)(uintptr_t)keys[i];
            CFStringRef g = fGroup ? fGroup(ch) : NULL;
            CFStringRef s = fSub ? fSub(ch) : NULL;
            CFStringRef n = fName ? fName(ch) : NULL;
            NSString *gs = g ? (__bridge NSString *)g : @"-";
            NSString *ss = s ? (__bridge NSString *)s : @"-";
            NSString *ns = n ? (__bridge NSString *)n : @"-";
            // 只关心"按进程"的那条：AM 的能耗列就是它
            BOOL perProc = [ss containsString:@"Process"] || [ns containsString:@"process"]
                        || [ss containsString:@"Task"] || [ns containsString:@"task"];
            if (shown < 6 || perProc) {
                printf("  %-10s / %-18s / %-26s %s\n", gs.UTF8String, ss.UTF8String, ns.UTF8String,
                       perProc ? "← 像是按进程的" : "");
                shown++;
            }
            if (perProc && fSrc && root) {
                CFDictionaryRef rep = NULL;
                io_connect_t prov = fProv ? (io_connect_t)fProv(ch) : (io_connect_t)root;
                kern_return_t e = fSrc(prov, ch, &rep);
                printf("      同步取报表：err=0x%x %s\n", e, e ? "" : "（成功）");
                if (!e && rep) {
                    printf("      顶层键：");
                    CFIndex kn = CFDictionaryGetCount(rep);
                    const void **ks = calloc(kn + 1, sizeof(void *));
                    CFDictionaryGetKeysAndValues(rep, ks, NULL);
                    for (CFIndex j = 0; j < kn && j < 10; j++) {
                        CFStringRef k = (CFStringRef)ks[j];
                        char buf[160]; const char *kc = CFStringGetCStringPtr(k, kCFStringEncodingUTF8);
                        if (!kc && CFStringGetCString(k, buf, sizeof(buf), kCFStringEncodingUTF8)) kc = buf;
                        printf("%s ", kc ? kc : "?");
                    }
                    printf("\n");
                    free(ks); CFRelease(rep);
                }
            }
        }
        if (root) IOObjectRelease(root);
        free(keys);
        CFRelease(chans);
        return 0;
    }
}
