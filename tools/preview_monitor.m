// 活动监视器离线预览：读这台机器的真实进程数据，离屏渲染成 PNG。
// 这台机器的 CLI 没有屏幕录制权限、看不见桌面，视觉效果只能靠这几张图判断。
// 用法：preview_monitor <输出目录> [放大倍数，默认2]
#import <AppKit/AppKit.h>
#import "monitor_view.h"
#import "procs.h"
#import "backdrop.h"
#import "quad.h"

static NSRect StandIn(void) {
    NSScreen *sc = [NSScreen mainScreen];
    NSRect vf = sc.visibleFrame;
    return NSMakeRect(vf.origin.x + 150, vf.origin.y + 60, kMonitorViewWidth, kMonitorViewHeight);
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

static NSImage *Render(DeskMonitorView *v, NSInteger scale) {
    NSSize s = v.bounds.size;
    return [NSImage imageWithSize:NSMakeSize(s.width * scale, s.height * scale)
                          flipped:YES
                  drawingHandler:^BOOL(NSRect r) {
        NSAffineTransform *t = [NSAffineTransform transform];
        [t scaleBy:scale];
        [t concat];
        DrawDesktopBehind(StandIn(), r);
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
        if (argc < 2) { fprintf(stderr, "用法：preview_monitor <输出目录> [放大倍数]\n"); return 2; }
        NSString *out = @(argv[1]);
        NSInteger scale = argc > 2 ? atoi(argv[2]) : 2;
        [[NSFileManager defaultManager] createDirectoryAtPath:out
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        NSApplicationLoad();

        DeskProcsMonitor *m = [[DeskProcsMonitor alloc] init];
        NSArray<DeskProc *> *rows = LiveRows(m);
        printf("真实进程 %lu 个（可读 %ld / 被拒 %ld）\n", (unsigned long)rows.count,
               (long)m.readable, (long)m.denied);

        DeskStyle styles[] = { DeskStylePlate, DeskStyleFeather, DeskStyleBare, DeskStyleHUD };
        const char *names[] = { "1-plate", "2-feather", "3-bare", "4-hud" };
        for (int i = 0; i < 4; i++) {
            DeskMonitorView *v = [[DeskMonitorView alloc] initWithRows:rows];
            v.style = styles[i];
            [v setStandInScreenRect:StandIn()];
            v.procCount = (NSInteger)rows.count;
            v.totalCPU = 37; v.totalMemUsed = 23e9; v.totalMemPhys = 24e9;
            v.totalEnergy = 89.6;
            for (int k = 0; k < 60; k++) [v tick:1.0 / 60.0];   // 让条子先长到位
            // 悬停态要跟着出厂那档（Bare）出一张：这一档的悬停不再藏指标条，得肉眼过一遍
            BOOL hoverThis = (i == 0 || i == 2);
            [v applyPreviewHover:(hoverThis ? 0 : -1) row:(hoverThis ? 1 : -1)];
            NSString *p = [out stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.png", names[i]]];
            WritePNG(Render(v, scale), p);
            printf("  写了 %s\n", p.UTF8String);
        }

        // 空数据：只有一拍基线时该长什么样（榜不能空成白块）
        DeskMonitorView *empty = [[DeskMonitorView alloc] initWithRows:@[]];
        empty.style = DeskStylePlate;
        [empty setStandInScreenRect:StandIn()];
        for (int k = 0; k < 60; k++) [empty tick:1.0 / 60.0];
        WritePNG(Render(empty, scale), [out stringByAppendingPathComponent:@"5-empty.png"]);
        printf("  写了 5-empty.png\n");
        // 悬停详情浮层单独出一张：它就是"第二根线到底是多少"的答案所在
        DeskMonitorHoverView *hv = [[DeskMonitorHoverView alloc] initWithFrame:NSMakeRect(0, 0, 214, 150)];
        hv.procName = @"UURemoteServer"; hv.pid = 4100; hv.uid = 501; hv.startedAt = 0;
        hv.cpu = 20.2; hv.mem = 486e6; hv.energy = 26.7; hv.sockets = 5;
        hv.energyTotal = 184.0;   // 占比的分母：真实值由组件那一拍喂，这里给一组对得上的假数据
        hv.histMetric = DeskMonitorMetricCPU; hv.histAvg = 3.14; hv.histCovered = 12.0 * 3600.0;
        NSImage *himg = [NSImage imageWithSize:NSMakeSize(214 * scale, 150 * scale) flipped:YES
                              drawingHandler:^BOOL(NSRect r) {
            [[NSColor colorWithSRGBRed:0.02 green:0.07 blue:0.14 alpha:1] setFill];
            NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
            [hv drawRect:hv.bounds];
            return YES;
        }];
        WritePNG(himg, [out stringByAppendingPathComponent:@"6-hover.png"]);
        printf("  写了 6-hover.png\n");
        return 0;
    }
}
