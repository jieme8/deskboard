// 签到中心离线预览：读 mock/credits_*.json，离屏渲染成 PNG。
// 用法：preview_credits <输出目录> <mock 目录> [放大倍数，默认2]
#import <AppKit/AppKit.h>
#import "credits.h"
#import "credits_view.h"
#import "workbuddy_credits.h"
#import "backdrop.h"

static NSDictionary *LoadJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static NSRect StandIn(void) {
    NSScreen *sc = [NSScreen mainScreen];
    NSRect vf = sc.visibleFrame;
    return NSMakeRect(vf.origin.x + 16, NSMaxY(vf) - 16 - kCreditsViewHeight,
                      kCreditsViewWidth, kCreditsViewHeight);
}

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

static NSImage *Render(DeskCreditsView *v, NSInteger scale) {
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
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];
}

static DeskCreditsSnapshot *SignedSnapshot(NSDictionary *status, NSDictionary *balance) {
    DeskCreditsSnapshot *s = [DeskCreditsSnapshot new];
    s.authorized = YES;
    NSError *e = nil;
    DeskCreditsSnapshot *parsed = DeskCreditsSnapshotByApplyingStatus(s, status, &e);
    if (!parsed) {
        fprintf(stderr, "解析签到 fixture 失败：%s\n", e.localizedDescription.UTF8String);
        return s;
    }
    DeskCreditsApplyMembership(parsed, balance, NULL);
    return parsed;
}

static DeskCreditsSnapshot *NeedsAuthSnapshot(DeskCreditsSnapshot *s) {
    DeskCreditsSnapshot *n = [s copy];
    n.authorized = YES;
    n.needsAuth = YES;
    n.lastError = @"登录状态已失效";
    return n;
}

static void RenderOne(NSString *out, NSString *name, DeskCreditsCenterSnapshot *center,
                      DeskStyle style, NSInteger scale) {
    DeskCreditsView *v = [[DeskCreditsView alloc] initWithFrame:NSMakeRect(0, 0, kCreditsViewWidth, kCreditsViewHeight)];
    v.style = style;
    [v updateCenter:center];
    [v setStandInScreenRect:StandIn()];
    NSString *path = [out stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
    WritePNG(Render(v, scale), path);
    printf("  %s\n    汇总：%s\n", path.UTF8String, v.summaryTextForVerify.UTF8String);
    for (NSInteger i = 0; i < [v slotCountForVerify]; i++) {
        printf("    槽 %ld %-9s | %-28s | %-10s %-6s | %s\n", (long)i,
               [v platformNameForVerify:i].UTF8String,
               [v statusTextForVerify:i].UTF8String,
               [v balanceTextForVerify:i].UTF8String,
               [v unitTextForVerify:i].UTF8String,
               [v footerTextForVerify:i].UTF8String);
        printf("        记录 %-30s | %s\n",
               [v recordTextForVerify:i].UTF8String,
               [v lastEventTextForVerify:i].UTF8String);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "用法：preview_credits <输出目录> <mock 目录> [放大倍数]\n");
            return 2;
        }
        NSString *out = @(argv[1]);
        NSString *mock = @(argv[2]);
        NSInteger scale = argc > 3 ? atoi(argv[3]) : 2;
        [[NSFileManager defaultManager] createDirectoryAtPath:out
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        NSApplicationLoad();

        NSDictionary *status = LoadJSON([mock stringByAppendingPathComponent:@"credits_status.json"]);
        NSDictionary *balance = LoadJSON([mock stringByAppendingPathComponent:@"credits_balance.json"]);
        if (!status || !balance) {
            fprintf(stderr, "读不到 mock/credits_status.json 或 credits_balance.json\n");
            return 2;
        }
        DeskCreditsSnapshot *mm = SignedSnapshot(status, balance);
        DeskCreditsCenterSnapshot *current = [DeskCreditsCenterSnapshot centerWithMiniMax:mm];
        DeskCreditsCenterSnapshot *full = [DeskCreditsCenterSnapshot previewFullCenterWithMiniMax:mm];
        DeskCreditsCenterSnapshot *needsAuth = [DeskCreditsCenterSnapshot centerWithMiniMax:NeedsAuthSnapshot(mm)];
        DeskWorkbuddySnapshot *wbPending = [DeskWorkbuddySnapshot new];
        wbPending.hasToken = YES;
        wbPending.host = @"www.codebuddy.cn";
        wbPending.source = @"browser";
        wbPending.phase = DeskWorkbuddyPhaseReady;
        wbPending.hasStatus = YES;
        wbPending.activityEnabled = YES;
        wbPending.streakDays = 3;
        wbPending.dailyCredit = 100;
        wbPending.balance = 1900;
        wbPending.quotaTotal = 2500;
        wbPending.quotaUsed = 600;
        wbPending.lastSyncAt = [NSDate date].timeIntervalSince1970;
        DeskCreditsCenterSnapshot *pending =
            [DeskCreditsCenterSnapshot centerWithMiniMax:mm trae:nil qoder:nil workbuddy:wbPending];

        printf("签到中心离线预览（%ld 档，%0.f×%0.f）\n", (long)scale,
               kCreditsViewWidth, kCreditsViewHeight);
        RenderOne(out, @"1-current-plate", current, DeskStylePlate, scale);
        RenderOne(out, @"2-full-plate", full, DeskStylePlate, scale);
        RenderOne(out, @"3-needsauth-plate", needsAuth, DeskStylePlate, scale);
        RenderOne(out, @"4-current-feather", current, DeskStyleFeather, scale);
        RenderOne(out, @"5-full-hud", full, DeskStyleHUD, scale);
        RenderOne(out, @"6-pending-workbuddy", pending, DeskStylePlate, scale);
    }
    return 0;
}
