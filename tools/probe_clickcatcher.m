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
    // 顺手把窗口号打出来：`screencapture -o -x -l<号>` 能逐窗抓像素、绕开所有遮挡，
    // 不然组件被普通层窗口压住时连"它到底长什么样"都没法核对。
    CFDictionaryRef self_ = CFArrayGetValueAtIndex(a, mine);
    int wid = (int)[(__bridge NSNumber *)CFDictionaryGetValue(self_, kCGWindowNumber) integerValue];
    printf("目标 bounds=(%.0f, %.0f, %.0fx%.0f)，在全局前到后序列里排第 %ld，窗口号 %d"
           "（逐窗抓：screencapture -o -x -l%d /tmp/w.png）\n",
           target.origin.x, target.origin.y, target.size.width, target.size.height,
           (long)mine, wid, wid);
    int hits = 0, eaters = 0; double worst = 0;
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
        if (cover > 0.99) {
            hits++;
            // 只有普通层（layer 0~10）的应用窗口真吃点击。Dock(20)、菜单栏(24) 和
            // layer≈INT32 的投屏覆盖层都吃不了 —— 后者要是吃点击，整个桌面都点不动。
            // 这条规则是踩过坑才定下来的：早先一版 probe_occlusion 把投屏层算成遮挡，
            // 结论直接把人带偏一轮。所以"压着"必须分成两种，不然工具会自己骗人。
            // 吃点击的两种：① 普通层应用窗口（layer 0~10）；② **和我们同一层、还排在前面**的
            // 窗口 —— Finder 管桌面图标的那块窗正是 -2147483603，和我们同层，同层之间比顺序，
            // 它在前头就在它那块区域把点击拿走。macOS 默认图标从右上角开始排，而活动监视器
            // 就贴右上 —— 这是三块组件里唯一可能天天和图标列重叠的一块，值得单独量出来。
            if ((lyr >= 0 && lyr <= 10) || lyr == -2147483603LL) {
                eaters++;
                if (cover > worst) worst = cover;   // 部分压住也危险：抓在那半边就点到别人
            }
        }
    }
    if (eaters && worst <= 0.99) {
        // 只报"整块被压住"是不够的：真机抓到过一次左边 40% 被别的窗口侧栏盖住，
        // 那时按 99% 判会得出"点得到"，而用户正好抓左边就点不到。
        printf("→ 有普通层窗口压着它，最狠的一块盖住 %.0f%% → 抓没被盖住的那半边拖\n\n", worst * 100.0);
        return;
    }
    printf(eaters ? "→ %d 个普通层窗口整个压着它（layer 0~10，真吃点击）→ 此刻点不到组件，不是 bug\n\n"
                  : (hits ? "→ 没有普通层窗口压着；另有 %d 个系统/覆盖层窗口（Dock、菜单栏、投屏层）——它们不吃点击\n\n"
                          : "→ 没有任何窗口整个压在它前面\n\n"),
            eaters ? eaters : hits);
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
