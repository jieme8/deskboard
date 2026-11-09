// 风格预览：把每种外观合成到你真实壁纸的那个位置上，输出成一张对比图。
// 用途很实在 —— 这台机器的 CLI 没有屏幕录制权限，我看不见桌面，只能靠这张图自己判断。
// 用法：preview <项目根目录> <输出png> [hud|quad|anim|status]
#import <AppKit/AppKit.h>
#import "model.h"
#import "panel_view.h"
#import "backdrop.h"
#import "sysmon.h"

static DeskStats *FakeStats(void) {
    DeskStats *s = [DeskStats new];
    s.cpu = 17; s.gpu = 41;
    s.memUsed = 16.7 * 1024 * 1024 * 1024; s.memTotal = 24.0 * 1024 * 1024 * 1024;
    s.diskFree = 277e9; s.diskTotal = 494e9; s.diskIsSSD = YES;
    s.diskRead = 10.8e6; s.diskWrite = 0.4e6;
    s.cpuTemp = 47.5; s.thermal = 0; s.netInterface = @"en8"; s.netAddress = @"192.168.31.23"; s.netIsWiFi = NO;
    s.netRecv = 1.24e6; s.netSend = 340e3;
    // 表尾：和实机同口径，让预览能看到电池/交换/负载三格
    s.ssdTemp = 44.0;
    s.batteryPercent = 100; s.batteryOnAC = YES; s.batteryCharged = YES;
    s.swapUsed = 949e6; s.swapTotal = 2e9;
    s.load1 = 2.07;
    return s;
}

static DeskStats *FakeStatsBefore(void) {
    // 上一拍：温度、磁盘水位都低，网络静默。用来让预览能看到条子"长过去"的过程。
    DeskStats *s = FakeStats();
    s.cpuTemp = 30.0; s.ssdTemp = 28.0;
    s.diskFree = 400e9; s.diskTotal = 494e9;
    s.netRecv = 0; s.netSend = 0;
    return s;
}

static DeskStats *FakeStatsWarn(void) {
    DeskStats *s = FakeStats();
    s.cpuTemp = 76.0; s.ssdTemp = 72.0;
    s.diskFree = 74e9; s.diskTotal = 494e9;      // 已用 85%
    s.batteryPercent = 15; s.batteryOnAC = NO;
    s.batteryCharged = NO; s.batteryCharging = NO;
    return s;
}

static DeskStats *FakeStatsCrit(void) {
    DeskStats *s = FakeStats();
    s.cpuTemp = 88.0; s.ssdTemp = 86.0;
    s.diskFree = 29e9; s.diskTotal = 494e9;      // 已用 94%
    s.batteryPercent = 8; s.batteryOnAC = NO;
    s.batteryCharged = NO; s.batteryCharging = NO;
    return s;
}

static DeskStats *FakeStatsOffline(void) {
    DeskStats *s = FakeStats();
    s.netInterface = @""; s.netAddress = @"";
    s.netRecv = 0; s.netSend = 0;
    return s;
}

// 把壁纸按 AspectFill 铺满整块屏幕，但只把"卡片实际压在上面的那块"落到格子里：
// 传入的 cellOrigin 是格子左下角，widgetRect 是卡片在屏幕上的实际位置。
static void DrawWallpaperBehind(NSString *path, NSRect screenFrame, NSRect widgetRect, NSRect cellOrigin) {
    NSImage *wp = [[NSImage alloc] initWithContentsOfFile:path];
    if (!wp) return;
    NSSize dims = wp.size;
    double scale = fmax(screenFrame.size.width / dims.width, screenFrame.size.height / dims.height);
    double drawW = dims.width * scale, drawH = dims.height * scale;
    double screenX = screenFrame.origin.x - (drawW - screenFrame.size.width) / 2.0;
    double screenY = screenFrame.origin.y - (drawH - screenFrame.size.height) / 2.0;
    double dx = cellOrigin.origin.x + 50.0 - widgetRect.origin.x;
    double dy = cellOrigin.origin.y + 22.0 + 50.0 - widgetRect.origin.y;
    [wp drawInRect:NSMakeRect(screenX + dx, screenY + dy, drawW, drawH)
          fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
}

static NSImage *RenderCard(DeskModel *model, DeskStyle style, NSRect screenRect, DeskQuadOffsets quad) {
    BOOL warped = !DeskQuadOffsetsIsZero(quad);
    NSSize win = [DeskCardView windowSizeForModel:model style:style warped:warped];
    NSRect frame = NSMakeRect(screenRect.origin.x - (win.width - screenRect.size.width) / 2.0,
                              screenRect.origin.y - (win.height - screenRect.size.height) / 2.0,
                              win.width, win.height);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];   // 只用来离屏渲染，从不上屏
    [w setBackgroundColor:[NSColor clearColor]];
    w.opaque = NO;
    DeskCardView *card = [[DeskCardView alloc] initWithModel:model style:style warped:warped];
    w.contentView = card;
    card.quadOffsets = quad;
    NSRect bounds = NSMakeRect(0, 0, win.width, win.height);
    NSBitmapImageRep *rep = [card bitmapImageRepForCachingDisplayInRect:bounds];
    [card cacheDisplayInRect:bounds toBitmapImageRep:rep];
    NSImage *img = [[NSImage alloc] initWithSize:win];
    [img addRepresentation:rep];
    return img;
}

// 动效帧：先用 from 建卡，再推 to 触发到点动效，然后按 60fps 步进 steps 帧拍一张。
// 只给离线看节奏用；正常预览路径不碰这个。
static NSImage *RenderCardFrame(DeskModel *from, DeskModel *to, DeskStyle style,
                                NSRect screenRect, int steps) {
    NSSize win = [DeskCardView windowSizeForModel:to style:style warped:NO];
    NSRect frame = NSMakeRect(screenRect.origin.x - (win.width - screenRect.size.width) / 2.0,
                              screenRect.origin.y - (win.height - screenRect.size.height) / 2.0,
                              win.width, win.height);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    [w setBackgroundColor:[NSColor clearColor]];
    w.opaque = NO;
    DeskCardView *card = [[DeskCardView alloc] initWithModel:from style:style warped:NO];
    w.contentView = card;
    [card updateModel:to];
    for (int i = 0; i < steps; i++) [card tick:1.0 / 60.0];
    NSRect bounds = NSMakeRect(0, 0, win.width, win.height);
    NSBitmapImageRep *rep = [card bitmapImageRepForCachingDisplayInRect:bounds];
    [card cacheDisplayInRect:bounds toBitmapImageRep:rep];
    NSImage *img = [[NSImage alloc] initWithSize:win];
    [img addRepresentation:rep];
    return img;
}

static void WritePNG(NSImage *img, NSString *path) {
    NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithData:[img TIFFRepresentation]];
    [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "用法：preview <项目根目录> <输出png> [hud|quad|anim|status]\n");
            return 2;
        }
        NSString *root = @(argv[1]);
        NSApplicationLoad();

        NSString *wp = [[DeskBackdrop shared] wallpaperPath];
        // 本机壁纸是程序化渲染（choice.macintosh），取不到稳定文件。
        // 预览不能因此整条罢工：无底档直接压在预览板的深灰底上，仍能核对排版。
        if (!wp.length) {
            printf("⚠ 找不到桌面壁纸文件（程序化渲染），改用深灰预览底\n");
        }
        NSScreen *screen = [NSScreen screens].firstObject;
        NSRect vf = screen.visibleFrame;
        printf("壁纸：%s\n屏幕：%.0fx%.0f 可视区 y=%.0f h=%.0f\n",
               wp.UTF8String, screen.frame.size.width, screen.frame.size.height, vf.origin.y, vf.size.height);

        NSString *mock = [[root stringByAppendingPathComponent:@"mock"] stringByAppendingPathComponent:@"mock.json"];
        DeskModel *model = [DeskModel modelFromJSONFileAtPath:mock];
        [model updateStats:FakeStats()];
        NSSize cardSize = [DeskPanelView sizeForModel:model];
        const double pad = 50.0;
        NSRect cell = NSMakeRect(0, 0, cardSize.width + pad * 2, cardSize.height + pad * 2 + 22);
        NSString *mode = argc > 3 ? @(argv[3]) : @"";

        NSMutableDictionary *labelAttrs = [NSMutableDictionary dictionary];
        labelAttrs[NSFontAttributeName] = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        labelAttrs[NSForegroundColorAttributeName] = [NSColor colorWithWhite:0.92 alpha:1];

        // 预览用位置：左下暗部（不是 App 的默认锚点）
        NSRect widget = NSMakeRect(round(vf.origin.x + 12), round(vf.origin.y + 12),
                                   cardSize.width, cardSize.height);

        if ([mode isEqualToString:@"quad"]) {
            // 手调透视的样例：右边向里退、上边收窄、整张斜躺
            DeskQuadOffsets list[4] = {
                DeskQuadOffsetsZero(),
                (DeskQuadOffsets){ .tl = { -18, 22 }, .tr = { 12, -12 }, .br = { -26, 10 }, .bl = { 22, -14 } },
                (DeskQuadOffsets){ .tl = { 40, -14 }, .tr = { -14, -14 } },
                (DeskQuadOffsets){ .tr = { 0, 26 }, .br = { -54, 16 }, .bl = { 18, -12 } },
            };
            NSArray *names = @[@"未变形", @"右退透视", @"上窄", @"斜躺"];
            NSImage *sheet = [[NSImage alloc] initWithSize:
                              NSMakeSize(cell.size.width * 4 + 50, cell.size.height + 26)];
            [sheet lockFocus];
            [[NSColor colorWithWhite:0.10 alpha:1] set];
            NSRectFill(NSMakeRect(0, 0, sheet.size.width, sheet.size.height));
            for (NSUInteger i = 0; i < 4; i++) {
                NSRect origin = NSMakeRect(10 + i * (cell.size.width + 10), 10,
                                           cell.size.width, cell.size.height);
                [NSGraphicsContext saveGraphicsState];
                NSRectClip(origin);
                DrawWallpaperBehind(wp, screen.frame, widget, origin);
                NSImage *img = RenderCard(model, DeskStyleFeather, widget, list[i]);
                [img drawInRect:NSMakeRect(origin.origin.x + pad - (img.size.width - cardSize.width) / 2.0,
                                           origin.origin.y + 22 + pad - (img.size.height - cardSize.height) / 2.0,
                                           img.size.width, img.size.height)
                       fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
                [NSGraphicsContext restoreGraphicsState];
                [names[i] drawAtPoint:NSMakePoint(origin.origin.x + 6, origin.origin.y + cell.size.height - 17)
                       withAttributes:labelAttrs];
            }
            [sheet unlockFocus];
            WritePNG(sheet, @(argv[2]));
            printf("→ %s（%.0fx%.0f）\n", argv[2], sheet.size.width, sheet.size.height);
            return 0;
        }

        if ([mode isEqualToString:@"anim"]) {
            // 四帧看节奏：到点瞬间 / 扫到一半 / 条子快到位 / 完全静止
            setenv("DESK_PANEL_FORCE_ANIMATION", "1", 1);
            DeskModel *before = [DeskModel modelFromJSONFileAtPath:mock];
            [before updateStats:FakeStatsBefore()];
            NSArray<NSString *> *times = @[@"0.00s", @"0.25s", @"0.60s", @"2.00s"];
            int steps[4] = {0, 15, 36, 120};
            NSImage *sheet = [[NSImage alloc] initWithSize:
                              NSMakeSize(cell.size.width * 4 + 10 * 5, cell.size.height + 26)];
            [sheet lockFocus];
            [[NSColor colorWithWhite:0.10 alpha:1] set];
            NSRectFill(NSMakeRect(0, 0, sheet.size.width, sheet.size.height));
            for (int i = 0; i < 4; i++) {
                NSRect origin = NSMakeRect(10 + i * (cell.size.width + 10), 10,
                                           cell.size.width, cell.size.height);
                [NSGraphicsContext saveGraphicsState];
                NSRectClip(origin);
                DrawWallpaperBehind(wp, screen.frame, widget, origin);
                NSImage *frame = RenderCardFrame(before, model, DeskStylePlate, widget, steps[i]);
                [frame drawInRect:NSMakeRect(origin.origin.x + pad,
                                             origin.origin.y + 22 + pad,
                                             frame.size.width, frame.size.height)
                       fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
                [NSGraphicsContext restoreGraphicsState];
                NSString *label = [NSString stringWithFormat:@"t = %@", times[i]];
                [label drawAtPoint:NSMakePoint(origin.origin.x + 6,
                                               origin.origin.y + cell.size.height - 17)
                    withAttributes:labelAttrs];
            }
            // 图例：离线帧没有鼠标悬停，不写清楚每个动效对应什么，看的人只能猜
            NSDictionary *legendAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: [NSColor colorWithWhite:0.72 alpha:1],
            };
            NSString *legend = @"档位 = 状态词 + 颜色（正常/偏高/过高）    温度计 / 磁盘条 = 当前水位（跨档会闪）    "
                               @"采样 = 10 秒节拍    数值闪 = 值或档位变了    网口灯闪 = 这一拍有流量";
            [legend drawAtPoint:NSMakePoint(12, cell.size.height + 14) withAttributes:legendAttrs];
            [sheet unlockFocus];
            WritePNG(sheet, @(argv[2]));
            printf("→ %s（动效四帧：0 / 0.25 / 0.60 / 2.00s）\n", argv[2]);
            return 0;
        }

        if ([mode isEqualToString:@"status"]) {
            // 四档静态对照：正常 / 偏高 / 过高 / 离线，看状态词、颜色、两支温度计和磁盘条
            NSArray<NSString *> *statusNames = @[@"正常", @"偏高", @"过高", @"离线"];
            NSArray<DeskStats *> *statusStats = @[FakeStats(), FakeStatsWarn(),
                                                 FakeStatsCrit(), FakeStatsOffline()];
            NSImage *sheet = [[NSImage alloc] initWithSize:
                              NSMakeSize(cell.size.width * 4 + 10 * 5, cell.size.height + 26)];
            [sheet lockFocus];
            [[NSColor colorWithWhite:0.10 alpha:1] set];
            NSRectFill(NSMakeRect(0, 0, sheet.size.width, sheet.size.height));
            for (NSUInteger i = 0; i < statusStats.count; i++) {
                NSRect origin = NSMakeRect(10 + i * (cell.size.width + 10), 10,
                                           cell.size.width, cell.size.height);
                [NSGraphicsContext saveGraphicsState];
                NSRectClip(origin);
                DrawWallpaperBehind(wp, screen.frame, widget, origin);
                DeskModel *m = [DeskModel modelFromJSONFileAtPath:mock];
                [m updateStats:statusStats[i]];
                NSImage *card = RenderCard(m, DeskStylePlate, widget, DeskQuadOffsetsZero());
                [card drawInRect:NSMakeRect(origin.origin.x + pad,
                                             origin.origin.y + 22 + pad,
                                             card.size.width, card.size.height)
                        fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
                [NSGraphicsContext restoreGraphicsState];
                [statusNames[i] drawAtPoint:NSMakePoint(origin.origin.x + 6,
                                                        origin.origin.y + cell.size.height - 17)
                             withAttributes:labelAttrs];
            }
            NSDictionary *legendAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: [NSColor colorWithWhite:0.72 alpha:1],
            };
            [@"青 = 正常 · 琥珀 = 偏高 · 红 = 过高/离线    温度行是 CPU/SSD 两支温度计；磁盘行「剩多少 G」是主读数，条底三段是阈值"
                drawAtPoint:NSMakePoint(12, cell.size.height + 14) withAttributes:legendAttrs];
            [sheet unlockFocus];
            WritePNG(sheet, @(argv[2]));
            printf("→ %s（状态四档：正常 / 偏高 / 过高 / 离线）\n", argv[2]);
            return 0;
        }

        NSArray *corners = @[@2, @1];
        NSArray *cornerNames = @[@"左下（暗部）", @"右上（压在发光机箱上）"];
        NSArray *styles = @[@(DeskStylePlate), @(DeskStyleFeather), @(DeskStyleBare), @(DeskStyleHUD)];
        NSArray *names = @[@"① 实底卡", @"② 羽化暗角", @"③ 无底浮字", @"④ 无边玻璃"];
        DeskQuadOffsets zero = DeskQuadOffsetsZero();

        if ([mode isEqualToString:@"hud"]) {   // 整屏合成：看 HUD 落在壁纸那扇窗上的效果
            double glassX = 275, glassTopCG = 45;      // find_region 量出来的窗玻璃位置（CG 坐标）
            NSRect hud = NSMakeRect(glassX, screen.frame.size.height - glassTopCG - cardSize.height,
                                    cardSize.width, cardSize.height);
            NSImage *shot = [[NSImage alloc] initWithSize:screen.frame.size];
            [shot lockFocus];
            [[NSColor colorWithWhite:0.10 alpha:1] setFill];
            NSRectFill(NSMakeRect(0, 0, screen.frame.size.width, screen.frame.size.height));
            NSImage *wpImg = wp.length ? [[NSImage alloc] initWithContentsOfFile:wp] : nil;
            if (wpImg) {
                NSSize dims = wpImg.size;
                double sc = fmax(screen.frame.size.width / dims.width, screen.frame.size.height / dims.height);
                double dw = dims.width * sc, dh = dims.height * sc;
                [wpImg drawInRect:NSMakeRect(screen.frame.origin.x - (dw - screen.frame.size.width) / 2.0,
                                             screen.frame.origin.y - (dh - screen.frame.size.height) / 2.0,
                                             dw, dh)
                         fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
            }
            NSImage *img = RenderCard(model, DeskStyleHUD, hud, zero);
            [img drawInRect:hud fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
            [shot unlockFocus];
            NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithData:[shot TIFFRepresentation]];
            [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:@(argv[2]) atomically:YES];
            printf("→ %s（整屏 %.0fx%.0f，HUD 落在 CG(%.0f, %.0f)）\n", argv[2],
                   shot.size.width, shot.size.height, hud.origin.x, screen.frame.size.height - NSMaxY(hud));
            return 0;
        }

        NSImage *sheet = [[NSImage alloc] initWithSize:
                          NSMakeSize(cell.size.width * styles.count + 10 * (styles.count + 1),
                                     (cell.size.height + 26) * corners.count + 10)];
        [sheet lockFocus];
        [[NSColor colorWithWhite:0.10 alpha:1] set];
        NSRectFill(NSMakeRect(0, 0, sheet.size.width, sheet.size.height));

        for (NSUInteger r = 0; r < corners.count; r++) {
            NSInteger corner = [corners[r] integerValue];
            NSRect vis = screen.visibleFrame;
            CGFloat x = (corner == 1 || corner == 3) ? NSMaxX(vis) - cardSize.width - 12 : vis.origin.x + 12;
            CGFloat y = (corner >= 2) ? vis.origin.y + 12 : NSMaxY(vis) - cardSize.height - 12;
            NSRect widget = NSMakeRect(round(x), round(y), cardSize.width, cardSize.height);
            double rowBottom = sheet.size.height - (r + 1) * (cell.size.height + 26) - 10;

            for (NSUInteger i = 0; i < styles.count; i++) {
                NSRect origin = NSMakeRect(10 + i * (cell.size.width + 10), rowBottom,
                                           cell.size.width, cell.size.height);
                [NSGraphicsContext saveGraphicsState];
                NSRectClip(origin);
                DrawWallpaperBehind(wp, screen.frame, widget, origin);
                DeskStyle style = (DeskStyle)[styles[i] integerValue];
                NSImage *card = RenderCard(model, style, widget, zero);
                [card drawInRect:NSMakeRect(origin.origin.x + pad + (widget.size.width - card.size.width) / 2.0,
                                             origin.origin.y + 22 + pad + (widget.size.height - card.size.height) / 2.0,
                                             card.size.width, card.size.height)
                        fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
                [NSGraphicsContext restoreGraphicsState];

                NSString *label = [NSString stringWithFormat:@"%@ · %@", names[i], cornerNames[r]];
                [label drawAtPoint:NSMakePoint(origin.origin.x + 6, origin.origin.y + cell.size.height - 17)
                    withAttributes:labelAttrs];
            }
        }
        [sheet unlockFocus];

        NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithData:[sheet TIFFRepresentation]];
        NSData *png = [out representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:@(argv[2]) atomically:YES]) {
            fprintf(stderr, "写不出文件：%s\n", argv[2]);
            return 1;
        }
        printf("→ %s（%.0fx%.0f）\n", argv[2], sheet.size.width, sheet.size.height);
        return 0;
    }
}
