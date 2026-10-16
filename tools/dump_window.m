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
                printf("  layer=%-12ld alpha=%.2f bounds=(%.0f, %.0f) %.0fx%.0f onscreen=%d\n",
                       (long)[d[@"kCGWindowLayer"] integerValue],
                       [d[@"kCGWindowAlpha"] doubleValue], b.origin.x, b.origin.y,
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
        DeskPlaceStore *vstore = [[DeskPlaceStore alloc] initWithDictionary:PrefDict(@"DeskBoardVaultPlaces")];
        printf("配置：位置存档 卡片 %lu 档 / 弹药库 %lu 档（按屏 × 点分辨率分键）\n",
               (unsigned long)store.count, (unsigned long)vstore.count);

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

        if (mine.count == 0) {
            fprintf(stderr, "\n没有任何 %s 窗口，无法继续校验。\n", owner.UTF8String);
            return 1;
        }

        // 现在桌上有两组窗口：油价卡片（宽 480 或变形时 600）和弹药库（宽 432）。
        // 断言得按组分开跑，否则弹药库会被当成"多出来的第二张卡片"，
        // 拿卡片的位置存档去比它，怎么算都不对。
        // 调角时窗口会从本体各边撑出 60pt 余量（432→552 / 480→600），
        // 分类必须认这两档，只按 432 判会把变形后的弹药库误当成第二张卡片
        const double kVaultW = 432.0, kVaultH = 294.0;
        const double kVaultPad = 60.0;
        NSMutableArray *cards = [NSMutableArray array], *vaults = [NSMutableArray array];
        for (NSDictionary *d in mine) {
            NSRect r = RectOf(d[@"kCGWindowBounds"]);
            if (fabs(r.size.width - kVaultW) <= 2.0 ||
                fabs(r.size.width - (kVaultW + kVaultPad * 2)) <= 2.0) [vaults addObject:d];
            else [cards addObject:d];
        }

        // 弹药库被用户隐藏、或因被别的窗口盖住而自动收起时，窗口根本不在上屏列表里，
        // 下面那圈位置断言一条都跑不到。以前这里什么都不说，最后照样报"全部通过"，
        // 看起来像验过了 —— 实际上最需要验的时候恰恰没验。显式讲清楚。
        if (vaults.count == 0) {
            BOOL userHidden = [Pref(@"DeskBoardVaultHidden") boolValue];
            printf("⚠ 弹药库位置校验本轮未执行：没有可检的窗口（%s）\n",
                   userHidden ? "用户已隐藏" : "多半是被别的窗口盖住触发了自动收起");
            printf("  下面卡片面板的结果不代表弹药库；要验弹药库位置，先把它挪到不会被盖住的地方。\n");
        } else {
            printf("弹药库窗口检出 %lu 个\n", (unsigned long)vaults.count);
        }

        for (NSDictionary *d in vaults) {
            NSRect b = RectOf(d[@"kCGWindowBounds"]);
            printf("弹药库 bounds=(%.0f, %.0f) %.0fx%.0f\n", b.origin.x, b.origin.y,
                   b.size.width, b.size.height);
            // 层级是硬约束：只在桌面图标层，用户所有应用窗口（全屏的也一样）都在它之上，
            // 所以任何模式下都不可能盖到窗口上
            NSInteger vlayer = [d[@"kCGWindowLayer"] integerValue];
            Say(vlayer == kLayerDesktop, @"弹药库层级=%ld（必须是桌面图标层，盖不到任何窗口上）",
                (long)vlayer);
            Say([d[@"kCGWindowIsOnscreen"] boolValue], @"弹药库处于上屏状态");
            // 透明度走窗口 alpha，WindowServer 直接报这个键；键缺失的老系统就跳过这条
            id alphaKey = d[@"kCGWindowAlpha"];
            if (alphaKey) {
                double want = [Pref(@"DeskBoardVaultAlpha") doubleValue];
                if (want <= 0) want = 1.0;
                double got = [alphaKey doubleValue];
                Say(fabs(got - want) <= 0.02, @"弹药库透明度 实测 %.2f（存档期望 %.2f）", got, want);
            }
            // 变形时窗口是撑大的画布，卡片本体在中间
            BOOL warped = fabs(b.size.width - (kVaultW + kVaultPad * 2)) <= 2.0;
            NSRect body = warped ? NSInsetRect(b, kVaultPad, kVaultPad) : b;
            Say(fabs(body.size.width - kVaultW) <= 2.0 && fabs(body.size.height - kVaultH) <= 2.0,
                @"弹药库本体 %.0fx%.0fpt（%@，窗口 %.0fx%.0f）",
                body.size.width, body.size.height, warped ? @"变形中" : @"未变形",
                b.size.width, b.size.height);
            NSScreen *host = nil;
            for (NSScreen *sc in screens) {
                if (NSPointInRect(NSMakePoint(NSMidX(b), NSMidY(b)), ToCG(sc.frame, mainH))) { host = sc; break; }
            }
            if (!host) { Say(NO, @"弹药库落在某块屏幕范围内"); continue; }
            NSRect vis = ToCG(host.visibleFrame, mainH);
            DeskPlace vp = [vstore placeForScreen:host];
            CGFloat vx = (vp.corner == 1 || vp.corner == 3) ? NSMaxX(vis) - kVaultW - vp.dx
                                                            : vis.origin.x + vp.dx;
            // 这里必须比"该对齐的那条横边"，不能把 App 的还原公式直接搬过来。
            // App 那边（main.m vaultFrameForScreen:）用的是屏幕左下原点，本工具的
            // b 和 vis 都已经是左上原点（ToCG 翻过了），y 轴方向是反的：
            //   上沿锚定 → 本体顶边 = vis.origin.y + dy
            //   下沿锚定 → 本体底边 = NSMaxY(vis) - dy
            // 照抄 App 的式子会凭空多出几百点的假偏差。别"顺手修正"这里。
            CGFloat edgeY = (vp.corner >= 2) ? NSMaxY(vis) - vp.dy : vis.origin.y + vp.dy;
            CGFloat gotY = (vp.corner >= 2) ? NSMaxY(body) : body.origin.y;
            // 变形时窗口是撑大的画布，要拿卡片本体去比，否则会拿画布左上角对期望值
            Say(fabs(body.origin.x - vx) <= 2.0 && fabs(gotY - edgeY) <= 2.0,
                @"弹药库对齐 %@ 角（档 %@）：期望 x=%.0f 横边=%.0f，实测 x=%.0f 横边=%.0f（偏差 %+.1f, %+.1f）",
                CornerName(vp.corner), [vstore keyForScreen:host] ?: @"?", vx, edgeY,
                body.origin.x, gotY, body.origin.x - vx, gotY - edgeY);
        }

        Say(cards.count == screens.count, @"每屏一个卡片窗口：检出 %lu / 屏幕 %lu",
            (unsigned long)cards.count, (unsigned long)screens.count);

        for (NSDictionary *d in cards) {
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

            // 期望位置从"这块屏这个分辨率"的存档里取（含同屏兜底），和 App 同一套规则。
            // 注意是"比该对齐的那条横边"，不是照抄 App 的还原公式：b 和 vis 已经是
            // 左上原点，y 轴和 App 的左下原点相反。理由同弹药库那段注释。
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
