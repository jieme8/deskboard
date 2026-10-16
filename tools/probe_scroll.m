// 诊断工具：同一个滚动事件，分别喂给原生 NSScrollView 和弹药库组件，
// 量出两者把"正 delta"翻译成哪个方向。不靠文档措辞，靠实测。
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "vault_view.h"
#import "quad.h"

@interface DeskVaultView (ProbeScroll)
- (NSRect)cardRectAtIndex:(NSInteger)idx in:(NSRect)b;
- (CGFloat)maxScroll;
@end

@interface ProbeDocView : NSView
@property (nonatomic, assign) BOOL flipDoc;
@end
@implementation ProbeDocView
- (BOOL)isFlipped { return self.flipDoc; }
@end

static const CGFloat kDocH = 2000.0, kPortH = 200.0;

// 原生：翻转文档 + 视口停在文档中段，正负两个方向都有得动
static NSScrollView *NativeScroll(NSClipView **outClip, NSWindow **outWin) {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, kPortH)];
    sv.hasVerticalScroller = YES;
    sv.scrollerStyle = NSScrollerStyleLegacy;
    ProbeDocView *doc = [[ProbeDocView alloc] initWithFrame:NSMakeRect(0, 0, 200, kDocH)];
    doc.flipDoc = YES;
    sv.documentView = doc;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 200, kPortH)
                                             styleMask:NSWindowStyleMaskBorderless
                                               backing:NSBackingStoreBuffered
                                                 defer:YES];
    w.contentView = sv;
    NSClipView *clip = sv.contentView;
    [clip scrollToPoint:NSMakePoint(0, (kDocH - kPortH) / 2.0)];
    [sv reflectScrolledClipView:clip];
    *outClip = clip;
    *outWin = w;
    return sv;
}

// CGEvent 造滚轮事件，再用公开的 +[NSEvent eventWithCGEvent:] 转成 NSEvent。
// pixel 单位 = 触控板那种精确增量，line 单位 = 滚轮一格。
static NSEvent *MakeScrollEvent(CGFloat deltaY, BOOL precise, NSPoint loc) {
    CGEventRef cg = CGEventCreateScrollWheelEvent(
        NULL, precise ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine, 1, (int32_t)deltaY);
    if (!cg) return nil;
    CGEventSetLocation(cg, loc);
    NSEvent *e = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    return e;
}

// 原生控件可能只认"从窗口派发进来的"事件，逐个投递路径试一遍
static CGFloat TryNative(NSClipView *clip, NSWindow *win, NSEvent *e, const char **which) {
    CGFloat base = clip.bounds.origin.y;

    [clip scrollWheel:e];
    CGFloat d = clip.bounds.origin.y - base;
    if (fabs(d) > 0.01) { *which = "clip scrollWheel:"; return d; }

    [win makeFirstResponder:clip];
    [win sendEvent:e];
    d = clip.bounds.origin.y - base;
    if (fabs(d) > 0.01) { *which = "window sendEvent:"; return d; }

    [NSApp sendEvent:e];
    d = clip.bounds.origin.y - base;
    if (fabs(d) > 0.01) { *which = "NSApp sendEvent:"; return d; }

    // 最后再试：让 App 真活过一轮主循环，窗口成为 key 后事件才会被认
    [win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    for (int i = 0; i < 5; i++) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    [win sendEvent:e];
    d = clip.bounds.origin.y - base;
    [win orderOut:nil];
    if (fabs(d) > 0.01) { *which = "主循环后 window sendEvent:"; return d; }

    printf("    [诊断] 窗口可见=%d 事件 window=%s bounds.origin.y %.1f→%.1f\n",
           [win isVisible], e.window ? "有" : "无", base, clip.bounds.origin.y);
    *which = "全部无响应";
    return 0;
}

// 组件：从文档中段开始滚，正负方向都看得见
static void MeasureWidget(CGFloat deltaY, BOOL precise, CGFloat *outDeltaY,
                          CGFloat *outScrollTarget, CGFloat *outScroll) {
    NSMutableArray<DeskVaultItem *> *items = [NSMutableArray array];
    for (int i = 0; i < 12; i++) {
        DeskVaultItem *it = [[DeskVaultItem alloc] init];
        it.name = [NSString stringWithFormat:@"探针%02d", i];
        it.kind = VaultItemFolder;
        [items addObject:it];
    }
    DeskVaultView *v = [[DeskVaultView alloc] initWithItems:items];
    [v setStandInScreenRect:NSMakeRect(0, 0, kVaultViewWidth, kVaultViewHeight)];
    CGFloat mid = [v maxScroll] / 2.0;
    [v setValue:@(mid) forKey:@"_scroll"];
    [v setValue:@(mid) forKey:@"_scrollTarget"];
    NSRect r0 = [v cardRectAtIndex:0 in:v.bounds];
    NSEvent *e = MakeScrollEvent(deltaY, precise, NSMakePoint(100, 100));
    [v scrollWheel:e];
    *outScrollTarget = [[v valueForKey:@"_scrollTarget"] floatValue] - mid;
    for (int i = 0; i < 200; i++) [v tick:1.0 / 60.0];   // 等缓动跟上
    *outScroll = [[v valueForKey:@"_scroll"] floatValue] - mid;
    NSRect r1 = [v cardRectAtIndex:0 in:v.bounds];
    *outDeltaY = r1.origin.y - r0.origin.y;
}

static void Report(const char *tag, BOOL precise, CGFloat deltaY) {
    NSClipView *clip = nil;
    NSWindow *win = nil;
    NativeScroll(&clip, &win);
    NSEvent *e = MakeScrollEvent(deltaY, precise, NSMakePoint(250, 250));
    if (!e) { printf("\n── %s：造不出事件\n", tag); return; }

    const char *which = "?";
    CGFloat native = TryNative(clip, win, e, &which);
    CGFloat dy = 0, st = 0, sc = 0;
    MeasureWidget(deltaY, precise, &dy, &st, &sc);

    printf("\n── %s：scrollingDeltaY=%+.1f hasPrecise=%d\n", tag, e.scrollingDeltaY,
           e.hasPreciseScrollingDeltas);
    printf("  原生 NSScrollView（%s）：可视区 origin.y %+.1f\n", which, native);
    printf("  弹药库：_scrollTarget %+.1f，缓动后 _scroll %+.1f，卡片 view-y %+.1f\n", st, sc, dy);

    // 翻转文档里 origin.y 变大 = 视口往文档下方走 = 内容在屏幕上往上移
    // 卡片 view-y 变小 = 内容在屏幕上往上移
    const char *nativeMove = fabs(native) < 0.01 ? "没动" : (native > 0 ? "上移" : "下移");
    const char *ourMove    = fabs(dy)   < 0.01 ? "没动" : (dy < 0 ? "上移" : "下移");
    printf("  内容位移：原生=%s  组件=%s  → %s\n", nativeMove, ourMove,
           (fabs(native) < 0.01 || fabs(dy) < 0.01) ? "无法比较"
                                                    : (strcmp(nativeMove, ourMove) == 0
                                                           ? "一致" : "相反"));
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        BOOL natural = [[NSUserDefaults standardUserDefaults]
                        boolForKey:@"com.apple.swipescrolldirection"];
        printf("系统「自然滚动」com.apple.swipescrolldirection = %s\n", natural ? "开" : "关");
        Report("滚轮式：正 delta", NO, 10.0);
        Report("滚轮式：负 delta", NO, -10.0);
        Report("触控板式：正 delta", YES, 10.0);
        Report("触控板式：负 delta", YES, -10.0);
    }
    return 0;
}
