// 验证"鼠标事件到底能不能送到桌面层组件的视图"。
// 这台机器没有辅助功能权限，CGEventPost / AppleScript / cliclick 全都用不了，
// 所以不能拿真鼠标拖。但 [NSApplication postEvent:atStart:] 是把事件塞进**本进程自己**
// 的队列，不碰系统事件流，因此不需要任何权限 —— 之后照常跑一遍 run loop，
// 让 AppKit 走完整的派发链：NSApp → 窗口 → hitTest → 视图的 mouseDown/mouseDragged。
// 窗口配置照抄生产：无边框、透明、非 key、accessory（等价 LSUIElement）、桌面图标层。
// 用法：probe_drag
#import <AppKit/AppKit.h>
#import "monitor_view.h"
#import "procs.h"

static int gDown = 0, gDrag = 0, gUp = 0;

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

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];   // 和 LSUIElement 同类
        [NSApp finishLaunching];

        NSRect frame = NSMakeRect(900, 60, kMonitorViewWidth, kMonitorViewHeight);
        NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered defer:NO];
        [w setBackgroundColor:NSColor.clearColor];
        w.opaque = NO;
        w.hasShadow = NO;
        w.level = kCGDesktopIconWindowLevel;          // 生产同款层级
        w.acceptsMouseMovedEvents = YES;
        NSMutableArray<DeskProc *> *rows = [NSMutableArray array];
        for (int i = 0; i < 8; i++) {
            DeskProc *p = [DeskProc new];
            p.pid = (pid_t)(4100 + i); p.name = [NSString stringWithFormat:@"probe%d", i];
            p.cpu = 30.0 - i; p.mem = 2e8; p.energy = 20.0 - i; p.wakeups = 4; p.sockets = 3;
            [rows addObject:p];
        }
        DeskMonitorView *v = [[DeskMonitorView alloc] initWithRows:rows];
        v.totalCPU = 11.1; v.totalMemUsed = 18e9; v.totalMemPhys = 26e9; v.totalEnergy = 191.0;
        v.onLog = ^(NSString *msg) { if ([msg containsString:@"收到拖拽事件"]) gDrag++; };
        w.contentView = v;
        [w orderFrontRegardless];
        Spin(NSApp, 20);

        printf("窗口 key=%d visible=%d 层级=%d\n", w.isKeyWindow, w.isVisible, (int)w.level);
        // 按在顶部留白处（避开进程行免得走双击分支）
        NSPoint at = NSMakePoint(200, kMonitorViewHeight - 8);
        [NSApp postEvent:MouseEvent(NSEventTypeLeftMouseDown, at, w.windowNumber, 1) atStart:NO];
        Spin(NSApp, 20);
        gDown = [v isDragging];
        printf("送 mouseDown 后：视图收到并进入拖窗态 = %s\n", gDown ? "是" : "否");

        for (int i = 1; i <= 4; i++) {
            [NSApp postEvent:MouseEvent(NSEventTypeLeftMouseDragged,
                                        NSMakePoint(200 + i, kMonitorViewHeight - 8 - i),
                                        w.windowNumber, 1) atStart:NO];
            Spin(NSApp, 12);
        }
        printf("送 4 个 mouseDragged 后：视图收到拖拽事件 %d 次（0 = 事件根本没派发进来）\n", gDrag);

        [NSApp postEvent:MouseEvent(NSEventTypeLeftMouseUp, NSMakePoint(204, kMonitorViewHeight - 12),
                                    w.windowNumber, 1) atStart:NO];
        Spin(NSApp, 20);
        gUp = ![v isDragging];
        printf("送 mouseUp 后：退出拖窗态 = %s\n", gUp ? "是" : "否");

        int fail = !(gDown && gDrag >= 1 && gUp);
        printf("\n%s 桌面层窗口的鼠标事件派发链完整（down→dragged→up 全部送到视图）\n",
               fail ? "✗" : "✓");
        [w orderOut:nil];
        return fail ? 1 : 0;
    }
}
