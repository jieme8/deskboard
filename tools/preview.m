// 风格预览：把每种外观合成到你真实壁纸的那个位置上，输出成一张对比图。
// 用途很实在 —— 这台机器的 CLI 没有屏幕录制权限，我看不见桌面，只能靠这张图自己判断。
// 用法：preview <项目根目录> <输出png> [hud|quad]
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

static void WritePNG(NSImage *img, NSString *path) {
    NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithData:[img TIFFRepresentation]];
    [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "用法：preview <项目根目录> <输出png> [hud|quad]\n");
            return 2;
        }
        NSString *root = @(argv[1]);
        NSApplicationLoad();

        NSString *wp = [[DeskBackdrop shared] wallpaperPath];
        if (!wp) { fprintf(stderr, "找不到桌面壁纸文件\n"); return 1; }
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

        // 默认位置：左下，App 的初始锚点就在这
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

        NSArray *corners = @[@2, @1];
        NSArray *cornerNames = @[@"左下（暗部）", @"右上（压在发光机箱上）"];
        NSArray *styles = @[@(DeskStylePlate), @(DeskStyleFeather), @(DeskStyleBare), @(DeskStyleHUD)];
        NSArray *names = @[@"① 实底卡", @"② 羽化暗角", @"③ 无底浮字", @"④ HUD 贴窗"];
        DeskQuadOffsets zero = DeskQuadOffsetsZero();

        if ([mode isEqualToString:@"hud"]) {   // 整屏合成：看 HUD 落在壁纸那扇窗上的效果
            double glassX = 275, glassTopCG = 45;      // find_region 量出来的窗玻璃位置（CG 坐标）
            NSRect hud = NSMakeRect(glassX, screen.frame.size.height - glassTopCG - cardSize.height,
                                    cardSize.width, cardSize.height);
            NSImage *shot = [[NSImage alloc] initWithSize:screen.frame.size];
            [shot lockFocus];
            NSImage *wpImg = [[NSImage alloc] initWithContentsOfFile:wp];
            NSSize dims = wpImg.size;
            double sc = fmax(screen.frame.size.width / dims.width, screen.frame.size.height / dims.height);
            double dw = dims.width * sc, dh = dims.height * sc;
            [wpImg drawInRect:NSMakeRect(screen.frame.origin.x - (dw - screen.frame.size.width) / 2.0,
                                         screen.frame.origin.y - (dh - screen.frame.size.height) / 2.0,
                                         dw, dh)
                     fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
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
