// 「点授权没反应」到底是哪一段断了：事件没送到视图，还是送到了没人接。
// 窗口配置照抄 makeCreditsWindowForScreen（无边框、透明、桌面图标层、非 key），
// 事件用 [NSApp postEvent:] 塞进本进程队列，走完整派发链，不需要辅助功能权限。
// 两个落点分开测：右上角药丸（应走 onSlotCheckNow）和格子身体（应走 onSlotActivate），
// 因为生产里它们是两个不同的 block，只有都跑通才谈得上"点了没反应不是视图的锅"。
// 用法：probe_credits_click
#import <AppKit/AppKit.h>
#import "credits.h"
#import "credits_view.h"

static NSString *gLast = @"(无)";
static int gActivate = 0, gCheckNow = 0, gDblClick = 0;

static void Spin(NSApplication *app, int iterations) {
    for (int i = 0; i < iterations; i++) {
        NSEvent *e = [app nextEventMatchingMask:NSEventMaskAny
                                      untilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]
                                         inMode:NSDefaultRunLoopMode
                                        dequeue:YES];
        if (e) [app sendEvent:e];
    }
}

static NSEvent *MouseEvent(NSEventType type, NSPoint inWindow, NSInteger wid, NSInteger clicks) {
    return [NSEvent mouseEventWithType:type location:inWindow modifierFlags:0
                             timestamp:[NSDate date].timeIntervalSince1970
                          windowNumber:wid context:nil eventNumber:1
                            clickCount:clicks pressure:clicks ? 1.0 : 0.0];
}

// 落点用视图坐标（视图 flipped、原点在左上），投递前要换成窗口坐标（原点左下）。
// 注意这里测不到"点一下带 3pt 以上位移被判成拖拽"那条分支：mouseDragged 读的是
// [NSEvent mouseLocation]（真光标全局位置），合成事件改不了它，本探针里恒为 0。
static void Click(NSApplication *app, NSWindow *w, NSPoint inView, NSString *label) {
    gLast = @"(无)";
    NSPoint at = NSMakePoint(inView.x, kCreditsViewHeight - inView.y);
    NSInteger before = gActivate + gCheckNow + gDblClick;
    [NSApp postEvent:MouseEvent(NSEventTypeLeftMouseDown, at, w.windowNumber, 1) atStart:NO];
    Spin(app, 20);
    [NSApp postEvent:MouseEvent(NSEventTypeLeftMouseUp, at, w.windowNumber, 1) atStart:NO];
    Spin(app, 20);
    printf("%s 视图点(%.0f,%.0f) → 回调=%s，新增派发 %ld\n", label.UTF8String, inView.x, inView.y,
           gLast.UTF8String, (long)(gActivate + gCheckNow + gDblClick - before));
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];

        DeskCreditsSnapshot *m = [DeskCreditsSnapshot new];
        m.authorized = YES;
        m.needsAuth = YES;
        m.hasStatus = YES;
        m.balance = 19816;
        m.planTier = @"Explore";
        m.lastError = @"refresh token 已失效";
        DeskCreditsCenterSnapshot *center =
            [DeskCreditsCenterSnapshot previewFullCenterWithMiniMax:m];

        NSRect frame = NSMakeRect(300, 60, kCreditsViewWidth, kCreditsViewHeight);
        NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered defer:NO];
        [w setBackgroundColor:NSColor.clearColor];
        w.opaque = NO;
        w.hasShadow = YES;
        w.level = kCGDesktopIconWindowLevel;
        w.acceptsMouseMovedEvents = YES;
        w.title = @"DeskBoard 签到";

        DeskCreditsView *v = [[DeskCreditsView alloc] initWithFrame:NSMakeRect(0, 0, kCreditsViewWidth, kCreditsViewHeight)];
        v.style = DeskStylePlate;
        [v updateCenter:center];
        v.onSlotActivate = ^(DeskCreditsPlatform p) { gActivate++; gLast = [NSString stringWithFormat:@"onSlotActivate(%ld)", (long)p]; };
        v.onSlotCheckNow = ^(DeskCreditsPlatform p) { gCheckNow++; gLast = [NSString stringWithFormat:@"onSlotCheckNow(%ld)", (long)p]; };
        v.onSlotDoubleClick = ^(DeskCreditsPlatform p) { gDblClick++; gLast = [NSString stringWithFormat:@"onSlotDoubleClick(%ld)", (long)p]; };
        w.contentView = v;
        [w orderFrontRegardless];
        Spin(NSApp, 20);

        printf("窗口 key=%d visible=%d 层级=%ld ignoresMouseEvents=%d\n",
               w.isKeyWindow, w.isVisible, (long)w.level, w.ignoresMouseEvents);
        for (NSInteger i = 0; i < [v slotCountForVerify]; i++) {
            NSRect tile = [v slotRectForVerify:i];
            NSRect pill = [v pillRectForVerify:i];
            printf("槽 %ld %-9s 状态文字=%-22s 格=(%.0f,%.0f,%.0fx%.0f) 药丸\"%s\"=(%.0f,%.0f,%.0fx%.0f) 药丸在格内=%d\n",
                   (long)i, [v platformNameForVerify:i].UTF8String,
                   [v statusTextForVerify:i].UTF8String,
                   tile.origin.x, tile.origin.y, tile.size.width, tile.size.height,
                   [v pillTextForVerify:i].UTF8String,
                   pill.origin.x, pill.origin.y, pill.size.width, pill.size.height,
                   NSContainsRect(tile, pill));
        }

        NSRect mmTile = [v slotRectForVerify:3];
        NSRect mmPill = [v pillRectForVerify:3];
        printf("\n— 逐点投递（MiniMax 槽，登录过期态）—\n");
        Click(NSApp, w, NSMakePoint(NSMidX(mmPill), NSMidY(mmPill)), @"药丸中心");
        Click(NSApp, w, NSMakePoint(NSMidX(mmTile), NSMidY(mmTile)), @"格子身体");
        Click(NSApp, w, NSMakePoint(NSMidX(mmTile), 3), @"格子外空白");   // 负向对照：这里不该有任何回调

        int fail = !(gCheckNow >= 1 && gActivate >= 1);
        printf("\n%s 视图层派发完整：药丸走 onSlotCheckNow、格子走 onSlotActivate\n", fail ? "✗" : "✓");
        [w orderOut:nil];
        return fail ? 1 : 0;
    }
}
