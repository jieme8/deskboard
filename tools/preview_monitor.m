// 活动监视器离线预览：读这台机器的真实进程数据，离屏渲染成 PNG。
// 这台机器的 CLI 没有屏幕录制权限、看不见桌面，视觉效果只能靠这几张图判断。
// 用法：preview_monitor <输出目录> [放大倍数，默认2] [compact]
#import <AppKit/AppKit.h>
#import "monitor_view.h"
#import "procs.h"
#import "backdrop.h"
#import "quad.h"

static NSRect StandIn(NSSize card) {
    NSScreen *sc = [NSScreen mainScreen];
    NSRect vf = sc.visibleFrame;
    return NSMakeRect(vf.origin.x + 150, vf.origin.y + 60, card.width, card.height);
}

// 无底那两档没有底板，直接出图是透明底；先把组件位置的真实壁纸铺在下面
static void DrawDesktopBehind(NSRect standIn, NSRect dst) {
    NSImage *wp = [[DeskBackdrop shared] imageForRect:standIn dark:NO];
    if (wp) {
        [wp drawInRect:dst fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    } else {
        [[NSColor colorWithSRGBRed:0.05 green:0.07 blue:0.12 alpha:1] setFill];
        NSRectFillUsingOperation(dst, NSCompositingOperationSourceOver);
    }
}

static NSImage *Render(DeskMonitorView *v, NSInteger scale, NSRect standIn) {
    NSSize s = v.bounds.size;
    return [NSImage imageWithSize:NSMakeSize(s.width * scale, s.height * scale)
                          flipped:YES
                  drawingHandler:^BOOL(NSRect r) {
        NSAffineTransform *t = [NSAffineTransform transform];
        [t scaleBy:scale];
        [t concat];
        DrawDesktopBehind(standIn, r);
        [v drawRect:v.bounds];
        return YES;
    }];
}

static void WritePNG(NSImage *img, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:[img TIFFRepresentation]];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

// 真实数据要两拍才知道 CPU，所以先跑一拍当基线
static NSArray<DeskProc *> *LiveRows(DeskProcsMonitor *m) {
    [m sample];
    usleep(1200000);
    return [m sample];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "用法：preview_monitor <输出目录> [放大倍数] [compact]\n"); return 2; }
        NSString *out = @(argv[1]);
        NSInteger scale = argc > 2 ? atoi(argv[2]) : 2;
        BOOL compact = argc > 3 && strcmp(argv[3], "compact") == 0;
        NSSize card = [DeskMonitorView cardSizeCompact:compact];
        [[NSFileManager defaultManager] createDirectoryAtPath:out
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        NSApplicationLoad();

        DeskProcsMonitor *m = [[DeskProcsMonitor alloc] init];
        NSArray<DeskProc *> *rows = LiveRows(m);
        printf("真实进程 %lu 个（可读 %ld / 被拒 %ld）\n", (unsigned long)rows.count,
               (long)m.readable, (long)m.denied);
        double energySum = 0;
        for (DeskProc *p in rows) if (p.energy > 0) energySum += p.energy;

        DeskStyle styles[] = { DeskStylePlate, DeskStyleFeather, DeskStyleBare, DeskStyleHUD };
        const char *names[] = { "1-plate", "2-feather", "3-bare", "4-hud" };
        for (int i = 0; i < 4; i++) {
            DeskMonitorView *v = [[DeskMonitorView alloc] initWithRows:rows];
            v.compact = compact;
            v.style = styles[i];
            [v setStandInScreenRect:StandIn(card)];
            v.totalCPU = 34;
            v.totalMemUsed = 16.4 * 1073741824.0; v.totalMemPhys = 24.0 * 1073741824.0;
            v.totalEnergy = energySum;   // 和运行时同一个分母：全部进程实测瓦数之和
            v.totalNetRecv = 1.24e6; v.totalNetSend = 340e3;
            // 受控实验：给每一格喂一个"12h 平均 = 现在的 35%"，好让淡条有确定的长度和位置，
            // 才能拿像素量它到底看不看得出来（真实数据里 12h 常常只差几个百分点，量不出结论）
            v.historyForPid = ^double(pid_t pid, DeskHistMetric hm, double *covered) {
                if (covered) *covered = 12.0 * 3600.0;
                for (DeskProc *q in rows) {
                    if (q.pid != pid) continue;
                    switch (hm) {
                        case DeskHistCPU: return q.cpu * 0.35;
                        case DeskHistMemory: return q.mem * 0.35;
                        case DeskHistEnergy: return q.energy * 0.35;
                        default: return MAX(0.0, q.netInRate + q.netOutRate) * 0.35;
                    }
                }
                return 0;
            };
            // 简略模式的条长和名字宽度都依赖 totals，必须在喂完总量后再排一次
            [v updateRows:rows];
            for (int k = 0; k < 60; k++) [v tick:1.0 / 60.0];   // 让条子先长到位
            // 悬停态要跟着出厂那档（Bare）出一张：这一档的悬停不再藏指标条，得肉眼过一遍
            BOOL hoverThis = (i == 0 || i == 2);
            [v applyPreviewHover:(hoverThis ? 0 : -1) row:(hoverThis ? (compact ? 0 : 1) : -1)];
            NSString *file = [NSString stringWithFormat:@"%s%s.png", names[i], compact ? "-compact" : ""];
            NSString *p = [out stringByAppendingPathComponent:file];
            WritePNG(Render(v, scale, StandIn(card)), p);
            printf("  写了 %s\n", p.UTF8String);
        }

        // 空数据：只有一拍基线时该长什么样（榜不能空成白块）
        DeskMonitorView *empty = [[DeskMonitorView alloc] initWithRows:@[]];
        empty.compact = compact;
        empty.style = DeskStylePlate;
        [empty setStandInScreenRect:StandIn(card)];
        for (int k = 0; k < 60; k++) [empty tick:1.0 / 60.0];
        NSString *emptyName = compact ? @"5-empty-compact.png" : @"5-empty.png";
        WritePNG(Render(empty, scale, StandIn(card)), [out stringByAppendingPathComponent:emptyName]);
        printf("  写了 %s\n", emptyName.UTF8String);
        // 悬停详情浮层单独出一张：它就是"第二根线到底是多少"的答案所在
        DeskMonitorHoverView *hv = [[DeskMonitorHoverView alloc]
            initWithFrame:NSMakeRect(0, 0, kDeskMonitorHoverSize.width, kDeskMonitorHoverSize.height)];
        hv.procName = @"UURemoteServer"; hv.pid = 4100; hv.uid = 501; hv.startedAt = 0;
        hv.cpu = 20.2; hv.mem = 486e6; hv.energy = 26.7; hv.sockets = 5;
        hv.energyTotal = 184.0;   // 占比的分母：真实值由组件那一拍喂，这里给一组对得上的假数据
        // 介绍与出处走产品同一套函数，预览里看到的文案就是实机上会出现的
        NSString *fakePath = @"/Applications/UURemote.app/Contents/Helpers/UURemoteServer";
        hv.intro = DeskProcIntroText(hv.procName, fakePath);
        hv.origin = DeskProcOriginText(fakePath);
        hv.histMetric = DeskMonitorMetricCPU; hv.histAvg = 3.14; hv.histCovered = 12.0 * 3600.0;
        void (^WriteHover)(DeskMonitorHoverView *, NSString *) = ^(DeskMonitorHoverView *h, NSString *name) {
            NSImage *img = [NSImage imageWithSize:NSMakeSize(kDeskMonitorHoverSize.width * scale,
                                                            kDeskMonitorHoverSize.height * scale) flipped:YES
                                  drawingHandler:^BOOL(NSRect r) {
                [[NSColor colorWithSRGBRed:0.02 green:0.07 blue:0.14 alpha:1] setFill];
                NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
                [h drawRect:h.bounds];
                return YES;
            }];
            WritePNG(img, [out stringByAppendingPathComponent:name]);
            printf("  写了 %s\n", name.UTF8String);
        };
        WriteHover(hv, @"6-hover.png");
        // 第二张专门试两行介绍 + 超长出处：前者不能压到读数，后者要中间省略而不是爆框
        NSString *winPath = @"/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer";
        hv.procName = @"WindowServer"; hv.pid = 395; hv.uid = 0;
        hv.intro = DeskProcIntroText(hv.procName, winPath);
        hv.origin = DeskProcOriginText(winPath);
        WriteHover(hv, @"7-hover-long.png");
        return 0;
    }
}
