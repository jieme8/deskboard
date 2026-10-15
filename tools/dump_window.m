// 实测校验：证明小组件窗口确实存在于桌面层，并落在配置的屏幕角上。
// 用法：dump_window [ownerName] [--hidden]
#import <AppKit/AppKit.h>
#import "places.h"

static int gFail = 0;
static int gPass = 0;

static void Say(BOOL ok, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void Say(BOOL ok, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s %s\n", ok ? "✓" : "✗", msg.UTF8String);
    if (ok) gPass++; else gFail++;
}

static id Pref(NSString *key) {
    CFStringRef domain = CFSTR("com.hujie.deskboard");
    CFPreferencesAppSynchronize(domain);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, domain));
}

static NSString *PrefString(NSString *key) {
    id v = Pref(key);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSDictionary *PrefDict(NSString *key) {
    id v = Pref(key);
    return [v isKindOfClass:[NSDictionary class]] ? v : nil;
}

static NSRect RectOf(id obj) {
    if (![obj isKindOfClass:[NSDictionary class]]) return NSZeroRect;
    NSDictionary *d = obj;
    return NSMakeRect([d[@"X"] doubleValue], [d[@"Y"] doubleValue],
                      [d[@"Width"] doubleValue], [d[@"Height"] doubleValue]);
}

// NSScreen 用左下角原点，WindowServer 用主屏左上角向下，这里统一成后者
static NSRect ToCG(NSRect r, CGFloat mainHeight) {
    return NSMakeRect(r.origin.x, mainHeight - NSMaxY(r), r.size.width, r.size.height);
}

static NSString *CornerName(NSInteger c) {
    NSArray *names = @[@"左上", @"右上", @"左下", @"右下"];
    return (c >= 0 && c < (NSInteger)names.count) ? names[c] : @"?";
}

static NSArray<NSDictionary *> *WindowsOf(CFArrayRef list, NSString *owner) {
    NSMutableArray *out = [NSMutableArray array];
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
        if (![d[@"kCGWindowOwnerName"] isEqualToString:owner]) continue;
        // 刚启动时 WindowServer 里会先有 0x0 的过渡窗口（菜单栏项还没布局），不算我们的面板
        if (RectOf(d[@"kCGWindowBounds"]).size.width < 1) continue;
        [out addObject:d];
    }
    return out;
}

// 轮询等到"每屏一个有尺寸的窗口"出现，最多等 timeout 秒
static NSArray<NSDictionary *> *WaitForWindows(NSString *owner, NSUInteger expected, NSTimeInterval timeout) {
    NSArray<NSDictionary *> *mine = @[];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
        mine = WindowsOf(list, owner);
        CFRelease(list);
        if (expected == 0 ? mine.count > 0 : mine.count == expected) return mine;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    }
    return mine;
}

static NSInteger kLayerDesktop = kCGDesktopIconWindowLevel;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *owner = argc > 1 ? @(argv[1]) : @"DeskBoard";
        BOOL expectHidden = argc > 2 && strcmp(argv[2], "--hidden") == 0;
        NSApplicationLoad();

        if (argc > 2 && strcmp(argv[2], "--list") == 0) {   // 列出该进程所有窗口（含菜单栏项）
            CFArrayRef all = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
            for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
                NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(all, i);
                if (![d[@"kCGWindowOwnerName"] isEqualToString:owner]) continue;
                NSRect b = RectOf(d[@"kCGWindowBounds"]);
                printf("  layer=%-12ld bounds=(%.0f, %.0f) %.0fx%.0f onscreen=%d\n",
                       (long)[d[@"kCGWindowLayer"] integerValue], b.origin.x, b.origin.y,
                       b.size.width, b.size.height, [d[@"kCGWindowIsOnscreen"] boolValue]);
            }
            CFRelease(all);
            return 0;
        }

        NSArray<NSScreen *> *screens = [NSScreen screens];
        Say(screens.count > 0, @"检出 %lu 块屏幕", (unsigned long)screens.count);
        CGFloat mainH = screens.firstObject.frame.size.height;
        // 位置存档按"屏 × 分辨率"分档，期望位置要跟窗口所在的那块屏对齐
        DeskPlaceStore *store = [[DeskPlaceStore alloc] initWithDictionary:PrefDict(@"DeskBoardPlaces")];
        printf("配置：位置存档 %lu 档（按屏 × 点分辨率分键）\n", (unsigned long)store.count);

        NSArray<NSDictionary *> *mine;
        if (expectHidden) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
            CFArrayRef l = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
            mine = WindowsOf(l, owner);
            CFRelease(l);
        } else {
            mine = WaitForWindows(owner, screens.count, 8.0);
        }

        if (mine.count == 0) {
            printf("  按 owner 名没找到窗口，列出所有桌面图标层窗口供辨认：\n");
            CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
            for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
                NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
                if ([d[@"kCGWindowLayer"] integerValue] != kLayerDesktop) continue;
                NSRect b = RectOf(d[@"kCGWindowBounds"]);
                printf("    owner=%-16s bounds=(%.0f, %.0f) %.0fx%.0f onscreen=%d\n",
                       [d[@"kCGWindowOwnerName"] UTF8String] ?: "?", b.origin.x, b.origin.y,
                       b.size.width, b.size.height, [d[@"kCGWindowIsOnscreen"] boolValue]);
            }
            CFRelease(list);
        }

        if (expectHidden) {
            NSMutableArray *visible = [NSMutableArray array];
            for (NSDictionary *d in mine) if ([d[@"kCGWindowIsOnscreen"] boolValue]) [visible addObject:d];
            Say(visible.count == 0, @"隐藏状态下没有可见窗口（检出 %lu 个）", (unsigned long)mine.count);
            printf("\n%d 项通过，%d 项失败\n", gPass, gFail);
            return gFail ? 1 : 0;
        }

        // 变形时 App 会养一个从不上屏的离屏素材窗（_sourceHost），它不是第二张卡片；
        // 坐标胶囊窗口是上屏的，但它比卡片窄得多，同样不算组件本体
        NSMutableArray *shown = [NSMutableArray array], *hidden = [NSMutableArray array];
        for (NSDictionary *d in mine) {
            NSRect r = RectOf(d[@"kCGWindowBounds"]);
            if (r.size.width < 400) continue;
            [([d[@"kCGWindowIsOnscreen"] boolValue] ? shown : hidden) addObject:d];
        }
        if (hidden.count) {
            printf("  另有 %lu 个从不上屏的离屏素材窗（变形时的渲染源，按预期忽略）\n",
                   (unsigned long)hidden.count);
        }
        mine = shown;

        Say(mine.count == screens.count, @"每屏一个窗口：检出 %lu / 屏幕 %lu",
            (unsigned long)mine.count, (unsigned long)screens.count);
        if (mine.count == 0) {
            fprintf(stderr, "\n没有任何 %s 窗口，无法继续校验。\n", owner.UTF8String);
            return 1;
        }

        for (NSDictionary *d in mine) {
            NSRect b = RectOf(d[@"kCGWindowBounds"]);
            NSInteger layer = [d[@"kCGWindowLayer"] integerValue];
            printf("窗口 bounds=(%.0f, %.0f) %.0fx%.0f\n", b.origin.x, b.origin.y, b.size.width, b.size.height);
            Say(layer == kLayerDesktop, @"层级=%ld 正是桌面图标层（所有普通窗口是 0，都在它之上）", (long)layer);
            Say([d[@"kCGWindowIsOnscreen"] boolValue], @"处于上屏状态");

            NSScreen *host = nil;
            for (NSScreen *s in screens) {
                if (NSPointInRect(NSMakePoint(NSMidX(b), NSMidY(b)), ToCG(s.frame, mainH))) { host = s; break; }
            }
            Say(host != nil, @"窗口落在某块屏幕范围内");
            if (!host) continue;

            NSRect vis = ToCG(host.visibleFrame, mainH);   // visibleFrame 已排除菜单栏与 Dock
            // 变形（或正在调角）时窗口比卡片外扩一圈，先把窗口撑回卡片矩形再比
            NSString *quad = PrefString(@"DeskBoardQuad");
            double pad = (quad && ![quad isEqualToString:@"0,0;0,0;0,0;0,0"]) ? 60.0 : 0.0;
            double tol = pad > 0 ? 8.0 : 2.0;
            NSRect cb = NSInsetRect(b, pad, pad);

            // 期望位置从"这块屏这个分辨率"的存档里取（含同屏兜底），和 App 同一套规则
            DeskPlace p = [store placeForScreen:host];
            double cardW = 480.0;   // kDeskPanelWidth，横版
            CGFloat x = (p.corner == 1 || p.corner == 3) ? NSMaxX(vis) - cardW - p.dx : vis.origin.x + p.dx;
            CGFloat edgeY = (p.corner >= 2) ? NSMaxY(vis) - p.dy : vis.origin.y + p.dy;   // 该对齐的那条横边
            CGFloat gotY  = (p.corner >= 2) ? NSMaxY(cb) : cb.origin.y;
            Say(fabs(cb.origin.x - x) <= tol && fabs(gotY - edgeY) <= tol,
                @"对齐 %@ 角（档 %@）：期望卡片 x=%.0f 横边=%.0f，实测 x=%.0f 横边=%.0f（偏差 %+.1f, %+.1f）",
                CornerName(p.corner), [store keyForScreen:host] ?: @"?", x, edgeY, cb.origin.x, gotY, cb.origin.x - x, gotY - edgeY);
            Say(fabs(b.size.width - (cardW + pad * 2)) <= tol,
                @"窗口宽 %.0fpt（卡片 %.0f%@）", b.size.width, cardW,
                pad > 0 ? @" + 两侧 60 变形余量" : @"");
        }

        printf("\n%d 项通过，%d 项失败\n", gPass, gFail);
        return gFail ? 1 : 0;
    }
}
