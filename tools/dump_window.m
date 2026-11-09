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

// 域必须跟 App 一致：App 换了 bundle id 之后配置域就换了，
// 这里再写死老域的话，读到的是老存档 —— 拿老存档去对 App 现在的窗口位置，
// 必然对不上（用户挪过组件之后就会报"位置对不上"）。
static NSString *DeskPrefDomain(void) {
    static NSString *domain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *plist = [NSHomeDirectory() stringByAppendingPathComponent:
                           @"Applications/DeskBoard.app/Contents/Info.plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:plist];
        id bid = d[@"CFBundleIdentifier"];
        domain = [bid isKindOfClass:[NSString class]] ? bid : @"com.hujie.deskboard.widget";
    });
    return domain;
}

static id Pref(NSString *key) {
    CFStringRef domain = (__bridge CFStringRef)DeskPrefDomain();
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
    NSString *lastSig = nil;
    NSDate *stableSince = nil;
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
        mine = WindowsOf(list, owner);
        CFRelease(list);
        // 四块组件不是同时建窗：等窗口集合稳定 0.6 秒再返回。
        // 只等"至少 N 个"会在第一块刚出现时就抓快照，后面的组件全被漏掉。
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSDictionary *d in mine) {
            NSRect r = RectOf(d[@"kCGWindowBounds"]);
            [parts addObject:[NSString stringWithFormat:@"%.0fx%.0f", r.size.width, r.size.height]];
        }
        NSString *sig = [parts componentsJoinedByString:@"|"];
        if (![sig isEqualToString:lastSig ?: @""]) {
            lastSig = sig;
            stableSince = [NSDate date];
        }
        BOOL enough = mine.count >= MAX(expected, (NSUInteger)1);
        if (enough && stableSince
            && [[NSDate date] timeIntervalSinceDate:stableSince] >= 0.6) return mine;
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
                printf("  id=%-8d layer=%-12ld alpha=%.2f bounds=(%.0f, %.0f) %.0fx%.0f onscreen=%d\n",
                       [d[@"kCGWindowNumber"] intValue],
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
        DeskPlaceStore *store = [[DeskPlaceStore alloc] initWithDictionary:PrefDict(@"DeskBoardPlaces")
                                                              defaultPlace:DeskPlaceDefaultForKind(DeskPlaceKindPanel)];
        DeskPlaceStore *vstore = [[DeskPlaceStore alloc] initWithDictionary:PrefDict(@"DeskBoardVaultPlaces")
                                                               defaultPlace:DeskPlaceDefaultForKind(DeskPlaceKindVault)];
        DeskPlaceStore *mstore = [[DeskPlaceStore alloc] initWithDictionary:PrefDict(@"DeskBoardMonitorPlaces")
                                                               defaultPlace:DeskPlaceDefaultForKind(DeskPlaceKindMonitor)];
        DeskPlaceStore *cstore = [[DeskPlaceStore alloc] initWithDictionary:PrefDict(@"DeskBoardCreditsPlaces")
                                                               defaultPlace:DeskPlaceDefaultForKind(DeskPlaceKindCredits)];
        printf("配置：位置存档 卡片 %lu 档 / 弹药库 %lu 档 / 签到 %lu 档（按屏 × 点分辨率分键）\n",
               (unsigned long)store.count, (unsigned long)vstore.count, (unsigned long)cstore.count);

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
        // 坐标胶囊（300×26）矮、悬停气泡（240×192）窄，最小那块组件也有 272 宽，按尺寸排除。
        NSMutableArray *shown = [NSMutableArray array], *hidden = [NSMutableArray array];
        for (NSDictionary *d in mine) {
            NSRect r = RectOf(d[@"kCGWindowBounds"]);
            // 坐标胶囊 300×26、悬停气泡 240×192；签到中心删掉抬头/表尾后只有 132 高，
            // 高度门槛必须低于它，否则真窗口会被当成气泡滤掉。
            if (r.size.width < 260 || r.size.height < 100) continue;
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

        // 卡片 272、弹药库 432、监视器 560（简略 272）、签到 700。
        // 简略监视器和卡片同尺寸，宽度不能再分家：先看窗口标题，再按两块各自的位置存档对距离。
        const NSSize kCardSize = { 272.0, 142.0 };
        const NSSize kVaultSize = { 432.0, 294.0 };
        BOOL monitorCompact = [Pref(@"DeskBoardMonitorCompact") boolValue];
        const NSSize kMonitorSize = monitorCompact ? (NSSize){ 272.0, 142.0 }
                                                   : (NSSize){ 560.0, 330.0 };
        const NSSize kCreditsSize = { 700.0, 132.0 };
        const double kWarpPad = 60.0;

        NSScreen *(^hostOf)(NSRect) = ^NSScreen *(NSRect b) {
            for (NSScreen *sc in screens) {
                if (NSPointInRect(NSMakePoint(NSMidX(b), NSMidY(b)), ToCG(sc.frame, mainH))) return sc;
            }
            return nil;
        };
        // 按「角 + 距边」存档复算卡片在 CG 坐标（左上原点）里的落点；和 App 的 AppKit 公式是同一套。
        NSRect (^expectedCardRect)(DeskPlaceStore *, NSSize, NSScreen *) =
            ^NSRect(DeskPlaceStore *st, NSSize card, NSScreen *sc) {
            NSRect vis = ToCG(sc.visibleFrame, mainH);
            DeskPlace p = [st placeForScreen:sc];
            CGFloat x = (p.corner == 1 || p.corner == 3) ? NSMaxX(vis) - card.width - p.dx
                                                         : vis.origin.x + p.dx;
            CGFloat top = (p.corner >= 2) ? NSMaxY(vis) - p.dy - card.height
                                          : vis.origin.y + p.dy;
            return NSMakeRect(x, top, card.width, card.height);
        };
        double (^distToPlace)(DeskPlaceStore *, NSSize, NSRect, NSScreen *) =
            ^double(DeskPlaceStore *st, NSSize card, NSRect r, NSScreen *sc) {
            NSRect want = expectedCardRect(st, card, sc);
            CGFloat padX = MAX(0.0, (r.size.width - card.width) / 2.0);
            CGFloat padY = MAX(0.0, (r.size.height - card.height) / 2.0);
            NSRect body = NSInsetRect(r, padX, padY);
            return hypot(body.origin.x - want.origin.x, body.origin.y - want.origin.y);
        };

        NSMutableArray *cards = [NSMutableArray array];
        NSMutableArray *credits = [NSMutableArray array];
        NSMutableArray *vaults = [NSMutableArray array];
        NSMutableArray *mons = [NSMutableArray array];
        for (NSDictionary *d in mine) {
            NSRect r = RectOf(d[@"kCGWindowBounds"]);
            double w = r.size.width;
            BOOL cardSized = fabs(w - kCardSize.width) <= 2.0
                          || fabs(w - (kCardSize.width + kWarpPad * 2)) <= 2.0;
            BOOL monitorDistinct = fabs(kMonitorSize.width - kCardSize.width) > 2.0;
            BOOL monitorSized = fabs(w - kMonitorSize.width) <= 2.0
                             || fabs(w - (kMonitorSize.width + kWarpPad * 2)) <= 2.0;
            if (fabs(w - kCreditsSize.width) <= 2.0) {
                [credits addObject:d];
            } else if (fabs(w - kVaultSize.width) <= 2.0 ||
                       fabs(w - (kVaultSize.width + kWarpPad * 2)) <= 2.0) {
                [vaults addObject:d];
            } else if (monitorDistinct && monitorSized) {
                [mons addObject:d];
            } else if (cardSized) {
                // 简略监视器和卡片同尺寸（272×142，变形都是 392×262）。标题拿不到时，
                // 用两块各自的摆位存档算落点，谁近算谁 —— 宽度这条路在这时已经完全失效。
                NSString *wn = d[@"kCGWindowName"];
                BOOL isMonitor = [wn isKindOfClass:[NSString class]] && [wn containsString:@"活动监视器"];
                NSScreen *host = hostOf(r);
                if (!isMonitor && host) {
                    double dc = distToPlace(store, kCardSize, r, host);
                    double dm = distToPlace(mstore, kMonitorSize, r, host);
                    if (dm + 1.0 < dc) isMonitor = YES;
                }
                if (isMonitor) [mons addObject:d]; else [cards addObject:d];
            } else {
                printf("⚠ 未知宽度的桌面层窗口 %.0fx%.0f\n", w, r.size.height);
            }
        }

        void (^checkWidget)(NSString *, DeskPlaceStore *, NSDictionary *, NSSize, BOOL, BOOL) =
            ^(NSString *name, DeskPlaceStore *st, NSDictionary *d, NSSize card, BOOL allowWarp, BOOL checkAlpha) {
            NSRect b = RectOf(d[@"kCGWindowBounds"]);
            printf("%s bounds=(%.0f, %.0f) %.0fx%.0f\n", name.UTF8String, b.origin.x, b.origin.y,
                   b.size.width, b.size.height);
            NSInteger vlayer = [d[@"kCGWindowLayer"] integerValue];
            Say(vlayer == kLayerDesktop, @"%@层级=%ld（必须是桌面图标层，盖不到任何窗口上）",
                name, (long)vlayer);
            Say([d[@"kCGWindowIsOnscreen"] boolValue], @"%@处于上屏状态", name);
            if (checkAlpha) {
                id alphaKey = d[@"kCGWindowAlpha"];
                if (alphaKey) {
                    double want = [Pref(@"DeskBoardVaultAlpha") doubleValue];
                    if (want <= 0) want = 1.0;
                    Say(fabs([alphaKey doubleValue] - want) <= 0.02,
                        @"%@透明度 实测 %.2f（存档期望 %.2f）", name, [alphaKey doubleValue], want);
                }
            }
            BOOL warped = allowWarp &&
                fabs(b.size.width - (card.width + kWarpPad * 2)) <= 2.0 &&
                fabs(b.size.height - (card.height + kWarpPad * 2)) <= 2.0;
            NSRect body = warped ? NSInsetRect(b, kWarpPad, kWarpPad) : b;
            Say(fabs(body.size.width - card.width) <= 2.0 && fabs(body.size.height - card.height) <= 2.0,
                @"%@本体 %.0fx%.0fpt（%@，窗口 %.0fx%.0f）", name, body.size.width, body.size.height,
                warped ? @"变形中" : @"未变形", b.size.width, b.size.height);
            NSScreen *host = hostOf(b);
            if (!host) { Say(NO, @"%@落在某块屏幕范围内", name); return; }
            NSRect vis = ToCG(host.visibleFrame, mainH);
            DeskPlace p = [st placeForScreen:host];
            // 这里必须比"该对齐的那条横边"，不能把 App 的还原公式直接搬过来。
            // App 那边用的是屏幕左下原点，本工具的 b 和 vis 都已经是左上原点（ToCG 翻过了）：
            //   上沿锚定 → 本体顶边 = vis.origin.y + dy
            //   下沿锚定 → 本体底边 = NSMaxY(vis) - dy
            // 照抄 App 的式子会凭空多出几百点的假偏差。别"顺手修正"这里。
            CGFloat x = (p.corner == 1 || p.corner == 3) ? NSMaxX(vis) - card.width - p.dx
                                                         : vis.origin.x + p.dx;
            CGFloat edgeY = (p.corner >= 2) ? NSMaxY(vis) - p.dy : vis.origin.y + p.dy;
            CGFloat gotY = (p.corner >= 2) ? NSMaxY(body) : body.origin.y;
            Say(fabs(body.origin.x - x) <= 2.0 && fabs(gotY - edgeY) <= 2.0,
                @"%@对齐 %@ 角（档 %@）：期望 x=%.0f 横边=%.0f，实测 x=%.0f 横边=%.0f（偏差 %+.1f, %+.1f）",
                name, CornerName(p.corner), [st keyForScreen:host] ?: @"?", x, edgeY,
                body.origin.x, gotY, body.origin.x - x, gotY - edgeY);
        };

        if (vaults.count == 0) {
            BOOL userHidden = [Pref(@"DeskBoardVaultHidden") boolValue];
            printf("⚠ 弹药库位置校验本轮未执行：没有可检的窗口（%s）\n",
                   userHidden ? "用户已隐藏" : "多半是被别的窗口盖住触发了自动收起");
        } else {
            printf("弹药库窗口检出 %lu 个\n", (unsigned long)vaults.count);
            for (NSDictionary *d in vaults) checkWidget(@"弹药库", vstore, d, kVaultSize, YES, YES);
        }
        if (mons.count == 0) {
            BOOL userHidden = [Pref(@"DeskBoardMonitorHidden") boolValue];
            printf("⚠ 活动监视器位置校验本轮未执行：没有可检的窗口（%s）\n",
                   userHidden ? "用户已隐藏" : "组件没建窗");
        } else {
            printf("活动监视器窗口检出 %lu 个\n", (unsigned long)mons.count);
            for (NSDictionary *d in mons) checkWidget(@"活动监视器", mstore, d, kMonitorSize, YES, NO);
        }
        if ([Pref(@"DeskBoardCreditsHidden") boolValue]) {
            printf("⚠ 签到组件用户已隐藏，跳过位置校验\n");
        } else {
            Say(credits.count == screens.count, @"每屏一个签到窗口：检出 %lu / 屏幕 %lu",
                (unsigned long)credits.count, (unsigned long)screens.count);
            for (NSDictionary *d in credits) checkWidget(@"签到", cstore, d, kCreditsSize, NO, NO);
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
            double cardW = 272.0;   // panel_view.m 的 kDeskPanelWidth（弹药库式卡片）
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
