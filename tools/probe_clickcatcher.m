// "拖不动"的真凶未必是普通窗口遮挡，也可能是**同层的桌面图标窗**。
// 三块组件都在 kCGDesktopIconWindowLevel（-2147483603），Finder 管桌面图标的那块窗
// 在同一层。同层之间比的是排列顺序：CGWindowListCopyWindowInfo(OnScreenOnly) 返回的
// 就是"从前到后"，所以落在组件矩形上、且排在它前面的第一个可点击窗口，就是真正
// 收到 mouseDown 的那个。probe_occlusion 只看 layer 0~1000，天生看不见同层对手。
//
// 用法：probe_clickcatcher [监视器|卡片|弹药库]
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

static CGRect RectOf(id b) {
    CGRect r = CGRectZero;
    if (b) CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)b, &r);
    return r;
}
static long long LayerOf(CFDictionaryRef d) {
    long long v = 0; CFNumberRef t = CFDictionaryGetValue(d, kCGWindowLayer);
    if (t) CFNumberGetValue(t, kCFNumberSInt64Type, &v);
    return v;
}

static void Scan(CFArrayRef a, CFIndex n, NSInteger mine, CGRect target) {
    printf("目标 bounds=(%.0f, %.0f, %.0fx%.0f)，在全局前到后序列里排第 %ld\n",
           target.origin.x, target.origin.y, target.size.width, target.size.height, (long)mine);
    int hits = 0;
    for (CFIndex i = 0; i < mine; i++) {     // 只看在它前面的
        CFDictionaryRef d = CFArrayGetValueAtIndex(a, i);
        NSString *ow = (__bridge NSString *)CFDictionaryGetValue(d, kCGWindowOwnerName);
        NSString *nm = (__bridge NSString *)CFDictionaryGetValue(d, kCGWindowName);
        CGRect r = RectOf(CFDictionaryGetValue(d, kCGWindowBounds));
        if (r.size.width < 5 || r.size.height < 5) continue;
        if (!CGRectIntersectsRect(r, target)) continue;
        CGRect ov = CGRectIntersection(r, target);
        double cover = (ov.size.width * ov.size.height) / (target.size.width * target.size.height);
        long long lyr = LayerOf(d);
        NSString *who = [NSString stringWithFormat:@"  前面 i=%-4ld layer=%-12lld 覆盖%.0f%%  %@ %@",
                         (long)i, lyr, cover * 100.0, ow ?: @"?", nm.length ? nm : @"-"];
        printf("%s\n", who.UTF8String);
        if (cover > 0.99) hits++;
    }
    printf(hits ? "→ 有 %d 个窗口 100%% 压在它前面\n\n" : "→ 没有任何窗口完全压在它前面\n\n", hits);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *want = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"监视器";
        BOOL all = [want isEqualToString:@"全部"];
        CFArrayRef a = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        CFIndex n = CFArrayGetCount(a);
        int shown = 0;
        // rect 模式：`probe_clickcatcher rect X Y W H`。换摆位本来要靠改存档，但 cfprefsd 会
        // 把内存里那份盖回磁盘（实测 plutil 改完重启，窗口纹丝不动），所以干脆不搬组件 ——
        // 前到后序列是全局的，"某个矩形会被谁压住"直接按候选矩形算，不用真搬过去。
        if ([want isEqualToString:@"rect"] && argc >= 6) {
            CGRect r = CGRectMake(atof(argv[2]), atof(argv[3]), atof(argv[4]), atof(argv[5]));
            CFIndex idx = n;
            for (CFIndex i = 0; i < n; i++) {
                CFDictionaryRef d = CFArrayGetValueAtIndex(a, i);
                NSString *ow = (__bridge NSString *)CFDictionaryGetValue(d, kCGWindowOwnerName);
                if ([ow isEqualToString:@"DeskBoard"] && LayerOf(d) == -2147483603) { idx = i; break; }
            }
            printf("候选矩形 (%.0f,%.0f,%.0fx%.0f)，按桌面层组件在序列里的第 %ld 位算\n",
                   r.origin.x, r.origin.y, r.size.width, r.size.height, (long)idx);
            Scan(a, n, idx, r);
            return 0;
        }
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef d = CFArrayGetValueAtIndex(a, i);
            NSString *ow = (__bridge NSString *)CFDictionaryGetValue(d, kCGWindowOwnerName);
            NSString *nm = (__bridge NSString *)CFDictionaryGetValue(d, kCGWindowName);
            if (![ow isEqualToString:@"DeskBoard"]) continue;
            CGRect r = RectOf(CFDictionaryGetValue(d, kCGWindowBounds));
            if (r.size.width < 50) continue;      // 离屏素材窗
            if (!all && !([nm containsString:want])) continue;
            Scan(a, n, i, r);
            shown++;
            if (!all) break;
        }
        if (!shown) { printf("没找到名字含“%s”的 DeskBoard 窗口\n", want.UTF8String); return 2; }
        return 0;
    }
}
