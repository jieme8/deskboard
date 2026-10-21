// 探针：用无障碍 API 问系统「菜单栏里到底有哪些项」，包括第三方 App 的状态栏按钮。
// 这是判断「图标在不在」的权威口径 —— 截图靠肉眼，AX 是系统自己报的。
// 用法：probe_menubar_ax
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

static void DumpElement(AXUIElementRef el, int depth) {
    if (!el) return;
    CFTypeRef role = NULL, title = NULL, desc = NULL, help = NULL;
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &role);
    AXUIElementCopyAttributeValue(el, kAXTitleAttribute, &title);
    AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute, &desc);
    AXUIElementCopyAttributeValue(el, kAXHelpAttribute, &help);
    CFStringRef r = role ? CFSTR("?") : NULL;
    for (int i = 0; i < depth; i++) printf("  ");
    printf("%s", r ? CFStringGetCStringPtr(r, kCFStringEncodingUTF8) : "?");
    if (title) printf(" title=%s", CFStringGetCStringPtr((CFStringRef)title, kCFStringEncodingUTF8));
    if (desc)  printf(" desc=%s",  CFStringGetCStringPtr((CFStringRef)desc, kCFStringEncodingUTF8));
    if (help)  printf(" help=%s",  CFStringGetCStringPtr((CFStringRef)help, kCFStringEncodingUTF8));
    printf("\n");
    if (role) CFRelease(role);
    if (title) CFRelease(title);
    if (desc) CFRelease(desc);
    if (help) CFRelease(help);

    CFTypeRef kids = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &kids) == kAXErrorSuccess && kids) {
        CFIndex n = CFArrayGetCount((CFArrayRef)kids);
        for (CFIndex i = 0; i < n; i++) {
            CFTypeRef c = CFArrayGetValueAtIndex((CFArrayRef)kids, i);
            if (c && CFGetTypeID(c) == AXUIElementGetTypeID())
                DumpElement((AXUIElementRef)c, depth + 1);
        }
        CFRelease(kids);
    }
}

int main(void) {
    @autoreleasepool {
        printf("AX 权限：%s\n", AXIsProcessTrusted() ? "有" : "无（下面读不到就是没权限，不是没有图标）");
        AXUIElementRef sys = AXUIElementCreateSystemWide();
        CFTypeRef mb = NULL;
        AXError err = AXUIElementCopyAttributeValue(sys, kAXMenuBarAttribute, &mb);
        printf("读系统菜单栏 err=%d\n", (int)err);
        if (mb) {
            DumpElement((AXUIElementRef)mb, 0);
            CFRelease(mb);
        }
        CFRelease(sys);
    }
    return 0;
}
