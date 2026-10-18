// 同一个字符串，分别用三条真实上屏路径画一遍，用 screencapture -l<窗口号> 逐窗抓真像素：
//   A 非 layer 背衬的视图直接画进窗口 backing store（= 活动监视器现在的做法）
//   B layer 背衬视图（AppKit 走灰度抗锯齿，不做字体平滑）
//   C 先画进 NSImage 再贴图（= 卡片面板变形后的做法，用户认可的那一档）
// 目的：把"字看起来带影子"归到具体的渲染路径上，而不是靠肉眼猜。
// 用法：probe_smooth [停留秒数，默认 6]
#import <AppKit/AppKit.h>

static NSString *kSample = @"活动监视器 31.8 Qoder CN";
#define kWin NSMakeSize(360, 90)

@interface TxtView : NSView
@property (nonatomic, assign) BOOL smooth;   // 仅用于日志，实际由 layer 背衬决定
@end

@implementation TxtView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r {
    (void)r;
    NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightRegular],
                        NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:244/255.0 green:248/255.0 blue:252/255.0 alpha:1]};
    [kSample drawAtPoint:NSMakePoint(10, 30) withAttributes:a];
}
@end

static long long WindowId(NSWindow *w) {
    CFArrayRef all = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    long long out = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(all, i);
        CFDictionaryRef b = CFDictionaryGetValue(d, kCGWindowBounds);
        CGRect rr = CGRectZero;
        if (b) CGRectMakeWithDictionaryRepresentation(b, &rr);
        if (!NSEqualRects(NSRectFromCGRect(rr), w.frame)) continue;
        CFNumberRef n = CFDictionaryGetValue(d, kCGWindowNumber);
        if (n) CFNumberGetValue(n, kCFNumberSInt64Type, &out);
        break;
    }
    CFRelease(all);
    return out;
}

static NSWindow *Place(NSView *v, CGFloat x) {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(x, 300, kWin.width, kWin.height)
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    [w setBackgroundColor:[NSColor colorWithWhite:0.5 alpha:1.0]];   // 中灰不透明底：字缘掺暗就能直接量化
    w.opaque = YES;
    w.hasShadow = NO;                       // 窗影会污染测量，这里必须排除
    w.level = NSScreenSaverWindowLevel;
    w.contentView = v;
    [w orderFrontRegardless];
    return w;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];

        TxtView *a = [[TxtView alloc] initWithFrame:NSMakeRect(0, 0, kWin.width, kWin.height)];
        a.smooth = YES;
        TxtView *b = [[TxtView alloc] initWithFrame:NSMakeRect(0, 0, kWin.width, kWin.height)];
        b.wantsLayer = YES;
        TxtView *c = [[TxtView alloc] initWithFrame:NSMakeRect(0, 0, kWin.width, kWin.height)];
        c.wantsLayer = YES;

        NSWindow *wa = Place(a, 60), *wb = Place(b, 480), *wc = Place(c, 900);

        // C：离屏 NSImage 再贴到非 layer 视图上（和卡片的 refreshSource 同一条路）
        NSImage *bmp = [NSImage imageWithSize:NSMakeSize(kWin.width * 2, kWin.height * 2) flipped:YES
                              drawingHandler:^BOOL(NSRect r) {
            [NSGraphicsContext saveGraphicsState];
            NSAffineTransform *t = [NSAffineTransform transform]; [t scaleBy:2]; [t concat];
            [a drawRect:NSMakeRect(0, 0, kWin.width, kWin.height)];
            [NSGraphicsContext restoreGraphicsState];
            return YES;
        }];
        NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, kWin.width, kWin.height)];
        iv.image = bmp; iv.imageScaling = NSImageScaleProportionallyUpOrDown;
        NSWindow *wd = Place(iv, 1320);

        for (int i = 0; i < 30; i++) {
            NSEvent *e;
            while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]
                                            inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:e];
        }

        printf("A 非layer直绘 %lld\nB layer背衬   %lld\nC layer+离屏图 %lld\nD NSImage贴图 %lld\n",
               WindowId(wa), WindowId(wb), WindowId(wc), WindowId(wd));
        fflush(stdout);

        int hold = argc > 1 ? atoi(argv[1]) : 6;
        [NSTimer scheduledTimerWithTimeInterval:hold repeats:NO block:^(NSTimer *t) {
            (void)t;
            [wa close]; [wb close]; [wc close]; [wd close];
            [NSApp terminate:nil];
        }];
        [NSApp run];
    }
    return 0;
}
