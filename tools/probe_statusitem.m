// 探针：独立建一个状态栏项，用和 DeskBoard 完全相同的图标代码。
// 用来回答「图标画不出来」还是「DeskBoard 那个 App 的状态栏项另有原因」。
// 用法：probe_statusitem [秒数，默认 25]
#import <AppKit/AppKit.h>

// —— 与 main.m 里 DeskStatusGlyph() 逐字一致 ——
static NSImage *DeskStatusGlyph(void) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(18, 16) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [NSColor.blackColor setStroke];
        [NSColor.blackColor setFill];

        NSBezierPath *pump = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2.6, 2.0, 7.4, 12.4)
                                                             xRadius:2.0 yRadius:2.0];
        pump.lineWidth = 1.5;
        [pump stroke];

        NSBezierPath *screen = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(4.8, 9.6, 3.0, 2.8)
                                                              xRadius:0.7 yRadius:0.7];
        [screen fill];

        NSBezierPath *hose = [NSBezierPath bezierPath];
        [hose moveToPoint:NSMakePoint(10.0, 11.0)];
        [hose curveToPoint:NSMakePoint(14.2, 8.6)
         controlPoint1:NSMakePoint(13.0, 11.0) controlPoint2:NSMakePoint(14.2, 10.4)];
        [hose lineToPoint:NSMakePoint(14.2, 5.0)];
        hose.lineWidth = 1.5;
        [hose stroke];

        NSBezierPath *nozzle = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(12.7, 2.2, 3.0, 2.8)
                                                              xRadius:0.9 yRadius:0.9];
        [nozzle fill];
        return YES;
    }];
    img.template = YES;
    return img;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int secs = argc > 1 ? atoi(argv[1]) : 25;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];  // 等价 LSUIElement
        [NSApp finishLaunching];

        NSStatusItem *item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
        item.button.image = DeskStatusGlyph();
        item.button.toolTip = @"DeskBoard 探针";

        NSMenu *menu = [NSMenu new];
        [menu addItemWithTitle:@"探针项" action:NULL keyEquivalent:@""];
        item.menu = menu;

        // —— 问系统：这个按钮到底被摆在哪、画在哪个窗口里 ——
        printf("屏幕数：%lu\n", (unsigned long)[NSScreen screens].count);
        for (NSScreen *s in [NSScreen screens]) {
            printf("  屏 frame=(%.0f,%.0f %.0fx%.0f) visibleFrame=(%.0f,%.0f %.0fx%.0f) scale=%.2f\n",
                   NSMinX(s.frame), NSMinY(s.frame), NSWidth(s.frame), NSHeight(s.frame),
                   NSMinX(s.visibleFrame), NSMinY(s.visibleFrame), NSWidth(s.visibleFrame), NSHeight(s.visibleFrame),
                   s.backingScaleFactor);
        }
        NSWindow *btnWin = item.button.window;
        printf("按钮 window=%@ frame=(%.0f,%.0f %.0fx%.0f) visible=%d onscreen=%d level=%ld\n",
               btnWin ? @"有" : @"无",
               btnWin ? NSMinX(btnWin.frame) : 0, btnWin ? NSMinY(btnWin.frame) : 0,
               btnWin ? NSWidth(btnWin.frame) : 0, btnWin ? NSHeight(btnWin.frame) : 0,
               btnWin ? (btnWin.isVisible ? 1 : 0) : 0,
               btnWin ? (btnWin.isOnActiveSpace ? 1 : 0) : 0,
               btnWin ? (long)btnWin.level : 0);
        printf("按钮 hidden=%d alpha=%.2f enabled=%d image=%@ imageSize=(%.0f,%.0f) template=%d\n",
               item.button.isHidden ? 1 : 0, item.button.alphaValue, item.button.isEnabled ? 1 : 0,
               item.button.image ? @"有" : @"无", item.button.image.size.width, item.button.image.size.height,
               item.button.image ? (item.button.image.isTemplate ? 1 : 0) : 0);
        printf("状态项 visible=%d length=%.0f\n", item.isVisible ? 1 : 0, item.length);

        // 状态栏里一共有几个项、各自多宽（看系统给不给你位置）
        NSStatusBar *bar = [NSStatusBar systemStatusBar];
        printf("状态栏 thickness=%.0f\n", bar.thickness);
        fflush(stdout);

        // 顺便把图标画成 PNG，方便肉眼比对
        NSImage *img = DeskStatusGlyph();
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:
            [img CGImageForProposedRect:NULL context:nil hints:nil]];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:@"/tmp/probe_glyph.png" atomically:YES];

        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
    }
    return 0;
}
