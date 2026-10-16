// 弹药库离线预览：造一批假文件夹，离屏渲染成 PNG。
// 用途很实在 —— 这台机器的 CLI 没有屏幕录制权限，看不见桌面，只能靠这几张图判断视觉效果。
// 用法：preview_vault <输出目录> [放大倍数，默认2]
#import <AppKit/AppKit.h>
#import "vault.h"
#import "vault_view.h"
#import "quad.h"
#import "backdrop.h"

static DeskVaultItem *Fake(NSString *name, unsigned long long bytes, NSUInteger files, double seed,
                           long long ago) {
    DeskVaultItem *it = [DeskVaultItem new];
    it.name = name;
    it.sourceName = name;
    it.storedName = name;
    it.seed = seed;
    it.byteSize = (long long)bytes;
    it.fileCount = files;
    it.scanned = YES;
    it.ingestedAt = (long long)([[NSDate date] timeIntervalSince1970] - ago);
    return it;
}

static NSArray<DeskVaultItem *> *FakeSix(void) {
    return @[Fake(@"项目资料", 2.4e9, 1284, 0.13, 3600),
             Fake(@"2024 归档", 18.6e9, 20431, 0.47, 86400 * 3),
             Fake(@"设计稿", 843e6, 312, 0.71, 86400),
             Fake(@"客户往来", 42e6, 87, 0.28, 7200),
             Fake(@"读书笔记-很长很长很长的文件夹名字", 96e6, 1543, 0.92, 86400 * 6),
             Fake(@"临时", 0, 0, 0.05, 600)];
}

static NSArray<DeskVaultItem *> *FakeNine(void) {
    return [FakeSix() arrayByAddingObjectsFromArray:
            @[Fake(@"截图归档", 1.2e9, 3021, 0.61, 86400 * 2),
              Fake(@"旧电脑备份", 64.3e9, 88120, 0.33, 86400 * 30),
              Fake(@"播客素材", 5.7e9, 640, 0.84, 86400 * 9)]];
}

// 组件底板是"采样背后那块真实壁纸"，离屏渲染没有真窗口，
// 得告诉它摆在屏幕哪里，采样出来才是用户在桌面上看到的那一块
static NSRect StandIn(void) {
    NSScreen *sc = [NSScreen mainScreen];
    NSRect vf = sc.visibleFrame;
    return NSMakeRect(vf.origin.x + 150, vf.origin.y + 60, kVaultViewWidth, kVaultViewHeight);
}

// 四档里"无底"那两档没有底板，直接出图是透明底，看起来像惨白的纸。
// 先把组件所在位置的真实壁纸铺在下面，才是用户眼睛里真正看到的东西。
static void DrawDesktopBehind(NSRect standIn, NSRect dst) {
    NSImage *wp = [[DeskBackdrop shared] imageForRect:standIn dark:NO];
    if (wp) {
        [wp drawInRect:dst fromRect:NSZeroRect
             operation:NSCompositingOperationSourceOver fraction:1.0];
    } else {
        [[NSColor colorWithSRGBRed:0.05 green:0.07 blue:0.12 alpha:1] setFill];
        NSRectFillUsingOperation(dst, NSCompositingOperationSourceOver);
    }
}

static NSImage *Render(DeskVaultView *v, NSInteger scale) {
    NSSize s = v.bounds.size;   // 变形时视图本身就是撑大的画布
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
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法：preview_vault <输出目录> [放大倍数]\n");
            return 2;
        }
        NSString *out = @(argv[1]);
        NSInteger scale = argc > 2 ? atoi(argv[2]) : 2;
        [[NSFileManager defaultManager] createDirectoryAtPath:out
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        NSApplicationLoad();

        struct { const char *name; NSArray<DeskVaultItem *> *items;
                 NSInteger hover, dock; double hot; NSInteger drop; CGFloat scroll;
                 DeskStyle style; } cases[] = {
            {"1-plate",   FakeSix(),  1,  0, 0, 0,  0,  DeskStylePlate},
            {"2-feather", FakeSix(),  1,  0, 0, 0,  0,  DeskStyleFeather},
            {"3-bare",    FakeSix(),  1,  0, 0, 0,  0,  DeskStyleBare},
            {"4-hud",     FakeSix(),  1,  0, 0, 0,  0,  DeskStyleHUD},
            {"5-drop",    FakeSix(), -1, -1, 1, 3,  0,  DeskStylePlate},
            {"6-empty",   @[],       -1, -1, 0, 0,  0,  DeskStylePlate},
            {"7-scroll",  FakeNine(), 7, -1, 0, 0, 85,  DeskStylePlate},
            {"8-warp",    FakeSix(),  1, -1, 0, 0,  0,  DeskStylePlate},
        };

        for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
            DeskVaultView *v = [[DeskVaultView alloc] initWithItems:cases[i].items];
            v.style = cases[i].style;
            [v setStandInScreenRect:StandIn()];
            [v applyPreviewHoverCard:cases[i].hover dock:cases[i].dock dropHot:cases[i].hot
                           dropCount:cases[i].drop scroll:cases[i].scroll];
            NSString *p = [out stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"%@.png", @(cases[i].name)]];
            if (strstr(cases[i].name, "warp")) {
                DeskQuadOffsets o = DeskQuadOffsetsZero();
                o.tl = NSMakeSize(26, -20); o.tr = NSMakeSize(-14, 8);
                o.br = NSMakeSize(-6, 14); o.bl = NSMakeSize(20, -26);
                v.quadOffsets = o;
                // 变形后视图是撑开的画布，尺寸要跟着换，否则投影画到画布外
                v.frame = NSMakeRect(0, 0, kVaultViewWidth + 120, kVaultViewHeight + 120);
                [v setNeedsDisplay:YES];
            }
            WritePNG(Render(v, scale), p);
            printf("→ %s  %.0fx%.0f\n", p.UTF8String, kVaultViewWidth * scale, kVaultViewHeight * scale);
        }
        return 0;
    }
}
