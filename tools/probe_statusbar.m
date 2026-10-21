// 探针：问系统「DeskBoard 的状态栏项到底在不在、画在哪」。
// 用法：probe_statusbar [进程名，默认 DeskBoard]
// 1) 列出该进程名下所有窗口（含状态栏项所在窗口）：bounds / layer / 可见性
// 2) 列出屏幕上「菜单栏带」内的窗口做对照，看本进程的项在不在其中
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

static double Num(NSDictionary *w, NSString *key) {
    NSDictionary *d = w[key];
    return d ? [d[@"X"] doubleValue] : 0;
}

static CGRect WinRect(NSDictionary *w) {
    NSDictionary *b = w[(id)kCGWindowBounds];
    if (![b isKindOfClass:[NSDictionary class]]) return CGRectZero;
    return CGRectMake([b[@"X"] doubleValue], [b[@"Y"] doubleValue],
                      [b[@"Width"] doubleValue], [b[@"Height"] doubleValue]);
}

static BOOL IsMenuBarBand(CGRect r) {
    for (NSScreen *s in [NSScreen screens]) {
        CGRect f = [s frame];
        CGFloat top = CGRectGetMaxY(f);
        if (r.origin.y + r.size.height >= top - 60 && r.origin.y <= top &&
            CGRectGetMaxX(r) > CGRectGetMinX(f) && CGRectGetMinX(r) < CGRectGetMaxX(f)) {
            return YES;
        }
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *procName = argc > 1 ? @(argv[1]) : @"DeskBoard";
        // pid 直接从 pgrep 拿：LSUIElement 的 App 在 NSRunningApplication 里有时认不出 bundle
        pid_t target = 0;
        {
            FILE *f = popen([[NSString stringWithFormat:@"pgrep -x %@", procName] UTF8String], "r");
            char buf[64] = {0};
            if (f && fgets(buf, sizeof buf, f)) target = (pid_t)atoi(buf);
            if (f) pclose(f);
        }
        if (target == 0) {
            FILE *f = popen([[NSString stringWithFormat:@"pgrep -f %@", procName] UTF8String], "r");
            char buf[64] = {0};
            if (f && fgets(buf, sizeof buf, f)) target = (pid_t)atoi(buf);
            if (f) pclose(f);
        }
        printf("进程 %s: pid=%d\n", procName.UTF8String, target);
        if (target == 0) { printf("✗ 没有该进程在跑\n"); return 2; }

        CFArrayRef raw = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
        NSArray *all = (__bridge NSArray *)raw;
        printf("\n=== 该进程的所有窗口 ===\n");
        int inBand = 0;
        for (NSDictionary *w in all) {
            if ([w[(id)kCGWindowOwnerPID] intValue] != target) continue;
            CGRect b = WinRect(w);
            int layer = [w[(id)kCGWindowLayer] intValue];
            BOOL onscreen = [w[(id)kCGWindowIsOnscreen] boolValue];
            NSString *name = w[(id)kCGWindowName];
            BOOL band = IsMenuBarBand(b);
            if (band) inBand++;
            printf("  layer=%-3d onscreen=%d 带内=%d bounds=(%.0f,%.0f %.0fx%.0f) name=%s\n",
                   layer, onscreen ? 1 : 0, band ? 1 : 0,
                   b.origin.x, b.origin.y, b.size.width, b.size.height,
                   (name ?: @"(无名)").UTF8String);
        }
        printf("=> 菜单栏带内的窗口数：%d\n", inBand);

        printf("\n=== 菜单栏带内所有窗口（对照） ===\n");
        for (NSDictionary *w in all) {
            CGRect b = WinRect(w);
            if (!IsMenuBarBand(b)) continue;
            int layer = [w[(id)kCGWindowLayer] intValue];
            if (layer < 20) continue;
            NSString *owner = w[(id)kCGWindowOwnerName];
            printf("  pid=%-6d layer=%-3d onscreen=%d owner=%-24s bounds=(%.0f,%.0f %.0fx%.0f)\n",
                   [w[(id)kCGWindowOwnerPID] intValue], layer,
                   [w[(id)kCGWindowIsOnscreen] boolValue] ? 1 : 0,
                   (owner ?: @"?").UTF8String,
                   b.origin.x, b.origin.y, b.size.width, b.size.height);
        }
        CFRelease(raw);
    }
    return 0;
}
