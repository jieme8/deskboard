// 变体矩阵：同一个进程里建多个状态项，每个换一种做法，量出「系统到底给不给我宽度」。
// 目的：把「图标建法」「template 标记」「length 取值」三个变量分开，定位 0 宽的真凶。
// 用法：probe_statusitem_matrix [秒数，默认 20]
#import <AppKit/AppKit.h>

static NSImage *GlyphHandler(BOOL asTemplate) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(18, 16) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [NSColor.blackColor setStroke];
        [NSColor.blackColor setFill];
        NSBezierPath *pump = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2.6, 2.0, 7.4, 12.4)
                                                             xRadius:2.0 yRadius:2.0];
        pump.lineWidth = 1.5;
        [pump stroke];
        NSBezierPath *scr = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(4.8, 9.6, 3.0, 2.8)
                                                            xRadius:0.7 yRadius:0.7];
        [scr fill];
        return YES;
    }];
    if (asTemplate) img.template = YES;
    return img;
}

static NSImage *GlyphBitmap(BOOL asTemplate) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(18, 16) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[NSColor blackColor] set];
        NSRectFill(r);
        return YES;
    }];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:[img CGImageForProposedRect:NULL context:nil hints:nil]];
    NSImage *out = [[NSImage alloc] initWithSize:NSMakeSize(18, 16)];
    [out addRepresentation:rep];
    if (asTemplate) out.template = YES;
    return out;
}

static void Report(NSString *tag, NSStatusItem *item) {
    NSButton *b = item.button;
    NSWindow *w = b.window;
    NSRect f = w ? w.frame : NSZeroRect;
    NSImage *im = b.image;
    NSView *bv = (NSView *)b;
    NSPoint sp = w ? [w convertPointToScreen:[bv convertPoint:NSZeroPoint toView:nil]] : NSZeroPoint;
    printf("%-34s itemVisible=%d length=%7.1f | btnWin=(%.0f,%.0f %.0fx%.0f) winVis=%d level=%ld onActiveSpace=%d occ=%ld | 屏幕坐标=(%.0f,%.0f) imgSize=(%.0f,%.0f) tmpl=%d hidden=%d\n",
           tag.UTF8String, item.isVisible ? 1 : 0, item.length,
           f.origin.x, f.origin.y, f.size.width, f.size.height,
           w ? (w.isVisible ? 1 : 0) : 0, w ? (long)w.level : 0,
           w ? (w.isOnActiveSpace ? 1 : 0) : 0, w ? (long)w.occlusionState : 0,
           sp.x, sp.y,
           im ? im.size.width : -1, im ? im.size.height : -1,
           im ? (im.isTemplate ? 1 : 0) : 0, b.isHidden ? 1 : 0);
    fflush(stdout);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int secs = argc > 1 ? atoi(argv[1]) : 20;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];

        NSStatusBar *bar = [NSStatusBar systemStatusBar];
        printf("thickness=%.0f 屏幕数=%lu pid=%d\n", bar.thickness, (unsigned long)[NSScreen screens].count, getpid());
        printf("---- 变体 ----\n");

        // 1. 原样：handler 图 + template + NSSquareStatusItemLength
        {
            NSStatusItem *it = [bar statusItemWithLength:NSSquareStatusItemLength];
            it.button.image = GlyphHandler(YES);
            Report(@"1 handler+template+square", it);
        }
        // 2. handler 图 + 不设 template + square
        {
            NSStatusItem *it = [bar statusItemWithLength:NSSquareStatusItemLength];
            it.button.image = GlyphHandler(NO);
            Report(@"2 handler+NOTemplate+square", it);
        }
        // 3. handler 图 + template + 明确宽度 24
        {
            NSStatusItem *it = [bar statusItemWithLength:24];
            it.button.image = GlyphHandler(YES);
            Report(@"3 handler+template+width24", it);
        }
        // 4. 位图图（真 bitmap）+ template + square
        {
            NSStatusItem *it = [bar statusItemWithLength:NSSquareStatusItemLength];
            it.button.image = GlyphBitmap(YES);
            Report(@"4 bitmap+template+square", it);
        }
        // 5. 不用图，只给标题
        {
            NSStatusItem *it = [bar statusItemWithLength:NSVariableStatusItemLength];
            it.button.title = @"DB";
            Report(@"5 title+variable", it);
        }
        // 6. 系统符号图（SF Symbol）+ template
        {
            NSStatusItem *it = [bar statusItemWithLength:NSSquareStatusItemLength];
            NSImage *sf = [NSImage imageWithSystemSymbolName:@"fuelpump.fill" accessibilityDescription:nil];
            it.button.image = sf;
            Report(@"6 SF Symbol+template+square", it);
        }
        // 7. 再建一个「什么都不做」的对照项
        {
            NSStatusItem *it = [bar statusItemWithLength:NSSquareStatusItemLength];
            Report(@"7 空项（什么都没设）", it);
        }
        // 8. 和 1 完全一样，但**挂一个菜单**（DeskBoard 就是这一种）
        {
            NSStatusItem *it = [bar statusItemWithLength:NSSquareStatusItemLength];
            it.button.image = GlyphHandler(YES);
            NSMenu *m = [NSMenu new];
            [m addItemWithTitle:@"子项一" action:NULL keyEquivalent:@""];
            it.menu = m;
            Report(@"8 handler+template+square+菜单", it);
        }
        // 9. 挂菜单 + 明确宽度
        {
            NSStatusItem *it = [bar statusItemWithLength:24];
            it.button.image = GlyphHandler(YES);
            NSMenu *m = [NSMenu new];
            [m addItemWithTitle:@"子项一" action:NULL keyEquivalent:@""];
            it.menu = m;
            Report(@"9 handler+template+width24+菜单", it);
        }
        // 10. 挂菜单 + toolTip（DeskBoard 还设了 toolTip）
        {
            NSStatusItem *it = [bar statusItemWithLength:NSSquareStatusItemLength];
            it.button.image = GlyphHandler(YES);
            it.button.toolTip = @"DeskBoard 探针";
            NSMenu *m = [NSMenu new];
            [m addItemWithTitle:@"子项一" action:NULL keyEquivalent:@""];
            it.menu = m;
            Report(@"10 同 8 再加 toolTip", it);
        }

        printf("---- 再等 2 秒，量一次（有些系统要等它布局完） ----\n");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.0]];
        printf("---- 起完，各项再量一次 ----\n");

        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
    }
    return 0;
}
