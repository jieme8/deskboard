// 桌面层组件"点不动 / 拖不动"时，第一件事不是改代码，是看它是不是被普通窗口盖住了。
// 三块组件都在 kCGDesktopIconWindowLevel（负数层），任何一个 layer>=0 的普通窗口
// （浏览器、IDE…）压在上面，点击就归那个窗口，组件永远收不到 mouseDown。
//
// 两类"盖住"要分开，混在一起会得出假结论：
//   · layer 0~1000 的普通窗口 —— 真的吃点击，这才是遮挡。
//   · layer 极高（≈INT32）的全屏覆盖层（远程桌面、投屏、会议软件）—— 它若真吃点击，
//     用户整个桌面都点不动了；实测本机就有这么一个，第一版把它算成遮挡，把排查带偏一轮。
//
// 用法：probe_occlusion      退出码 0 = 没有组件被完全盖住；1 = 有
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

int main(void) {
    @autoreleasepool {
        CFArrayRef a = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        CFIndex n = CFArrayGetCount(a);

        struct { const char *name; double w, h; } kinds[3] = {
            { "卡片面板", 392, 383 }, { "活动监视器", 432, 294 }, { "弹药库", 432, 294 }
        };
        CGRect selfRect[3]; BOOL found[3] = { NO, NO, NO };
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef d = CFArrayGetValueAtIndex(a, i);
            NSString *ow = (__bridge NSString *)CFDictionaryGetValue(d, kCGWindowOwnerName);
            if (![ow isEqualToString:@"DeskBoard"]) continue;
            CGRect r = RectOf(CFDictionaryGetValue(d, kCGWindowBounds));
            for (int k = 0; k < 3; k++) {
                if (found[k]) continue;
                if (fabs(r.size.width - kinds[k].w) < 2.0 && fabs(r.size.height - kinds[k].h) < 2.0) {
                    selfRect[k] = r; found[k] = YES; break;
                }
            }
        }

        // 会吃点击的窗口：普通层，且不是组件自己
        NSMutableArray<NSValue *> *eaters = [NSMutableArray array];
        NSMutableArray<NSString *> *eaterNames = [NSMutableArray array];
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef d = CFArrayGetValueAtIndex(a, i);
            NSString *ow = (__bridge NSString *)CFDictionaryGetValue(d, kCGWindowOwnerName);
            CGRect r = RectOf(CFDictionaryGetValue(d, kCGWindowBounds));
            if (r.size.width < 5 || r.size.height < 5) continue;
            long long lyr = LayerOf(d);
            if (lyr < 0 || lyr > 1000) continue;
            if ([ow isEqualToString:@"DeskBoard"]) continue;
            [eaters addObject:[NSValue valueWithBytes:&r objCType:@encode(CGRect)]];
            [eaterNames addObject:ow ?: @"?"];
        }

        int blocked = 0;
        for (int k = 0; k < 3; k++) {
            if (!found[k]) { printf("— %-10s 当前没有可检的窗口（隐藏或被自动收起）\n", kinds[k].name); continue; }
            CGRect me = selfRect[k];
            double covered = 0; NSMutableSet *onTop = [NSMutableSet set];
            for (NSUInteger j = 0; j < eaters.count; j++) {
                CGRect o2; [eaters[j] getValue:&o2];
                if (!CGRectIntersectsRect(o2, me)) continue;
                CGRect it = CGRectIntersection(o2, me);
                covered += (it.size.width * it.size.height) / (me.size.width * me.size.height);
                [onTop addObject:eaterNames[j]];
            }
            // 抓得着的地方：四角和四条边中点各往里 12pt
            CGFloat ins = 12.0;
            CGPoint grabs[8] = { { NSMinX(me)+ins, NSMinY(me)+ins }, { NSMaxX(me)-ins, NSMinY(me)+ins },
                                 { NSMinX(me)+ins, NSMaxY(me)-ins }, { NSMaxX(me)-ins, NSMaxY(me)-ins },
                                 { CGRectGetMidX(me), NSMinY(me)+ins }, { CGRectGetMidX(me), NSMaxY(me)-ins },
                                 { NSMinX(me)+ins, CGRectGetMidY(me) }, { NSMaxX(me)-ins, CGRectGetMidY(me) } };
            int freePts = 0;
            for (int g = 0; g < 8; g++) {
                BOOL hit = NO;
                for (NSUInteger j = 0; j < eaters.count; j++) {
                    CGRect o2; [eaters[j] getValue:&o2];
                    if (CGRectContainsPoint(o2, grabs[g])) { hit = YES; break; }
                }
                if (!hit) freePts++;
            }
            covered = MIN(1.0, covered);
            NSString *who = onTop.count ? [onTop.allObjects componentsJoinedByString:@"/"] : @"-";
            if (freePts == 0) {
                blocked++;
                printf("✗ %-10s bounds=(%.0f,%.0f %.0fx%.0f) 被普通窗口盖住 %.0f%%（%s），8 个抓取点全被压住\n",
                       kinds[k].name, me.origin.x, me.origin.y, me.size.width, me.size.height, covered*100,
                       who.UTF8String);
            } else if (covered > 0.02) {
                printf("△ %-10s bounds=(%.0f,%.0f %.0fx%.0f) 盖住 %.0f%%（%s），还有 %d/8 个抓取点空着\n",
                       kinds[k].name, me.origin.x, me.origin.y, me.size.width, me.size.height, covered*100,
                       who.UTF8String, freePts);
            } else {
                printf("✓ %-10s bounds=(%.0f,%.0f %.0fx%.0f) 没被普通窗口盖住，%d/8 个抓取点可拖\n",
                       kinds[k].name, me.origin.x, me.origin.y, me.size.width, me.size.height, freePts);
            }
        }
        printf("\n%s\n", blocked ? "有组件的抓取点全被普通窗口压住 —— 先挪开那些窗口再谈拖拽代码"
                                 : "没有组件被完全压住 —— 拖不动不是遮挡，往代码里查");
        return blocked ? 1 : 0;
    }
}
