// 缩略图这一笔的独立校验：方向、contain/cover 取景、解码失败回退、缓存行为。
// 单独成一个工具而不是塞进 verify.m，是为了不和正在改 verify.m 的那条线撞车。
#import <AppKit/AppKit.h>
#import "vault_art.h"
#import "vault_view.h"
#import "vault.h"

static int gPass = 0, gFail = 0;
static void Check(BOOL ok, NSString *what) {
    printf("%s %s\n", ok ? "✓" : "✗", what.UTF8String);
    if (ok) gPass++; else gFail++;
}

// 造一张上红下蓝的图：方向对不对一看颜色就知道，比对着真人照片猜靠谱得多
static NSString *MakeProbeImage(CGFloat w, CGFloat h) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)w pixelsHigh:(NSInteger)h
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *c = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:c];
    [[NSColor redColor] setFill];   NSRectFill(NSMakeRect(0, h / 2, w, h / 2));
    [[NSColor blueColor] setFill];  NSRectFill(NSMakeRect(0, 0, w, h / 2));
    [NSGraphicsContext restoreGraphicsState];
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"probe_%.0fx%.0f.png", w, h]];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:p atomically:YES];
    return p;
}

// 和组件一样是翻转坐标的真实视图：只有这样验出来的方向结论才对得上真组件
@interface ThumbProbeView : NSView
@property (nonatomic, strong) NSImage *thumb;
@end
// 预览走的是另一个绘制函数（contain 而非 cover），要单独一个探针
@interface PreviewProbeView : NSView
@property (nonatomic, strong) NSImage *thumb;
@end
@implementation PreviewProbeView
// 必须和真实视图一样是翻转坐标：绘制函数里那道翻转是按"当前上下文是翻转的"写的，
// 漏了这个方法会二次翻转，图既上下颠倒又偏出框
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)d {
    [[NSColor colorWithWhite:0.5 alpha:1] setFill];
    NSRectFill(d);
    VaultDrawThumbPreviewIn(NSMakeRect(20.0, 20.0, 26.0, 22.1), self.thumb,
                            [NSColor colorWithSRGBRed:0.69 green:0.60 blue:0.97 alpha:1.0]);
}
@end
@implementation ThumbProbeView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)d {
    [[NSColor colorWithWhite:0.5 alpha:1] setFill];
    NSRectFill(d);
    VaultDrawThumbnailIn(NSMakeRect(20.0, 20.0, 26.0, 22.1), self.thumb,
                         [NSColor colorWithSRGBRed:0.69 green:0.60 blue:0.97 alpha:1.0]);
}
@end

// 扫描整张图里"明显偏色"的像素行区间。方向和取景都靠它断言，
// 比按猜好的行号取样稳 —— 探针图的红蓝分界落在哪一行，测试不该去猜。
typedef struct { NSInteger top, bottom; } RowSpan;
static RowSpan FindRedSpan(NSBitmapImageRep *rep) {
    RowSpan s = {NSNotFound, NSNotFound};
    for (NSInteger y = 0; y < (NSInteger)rep.pixelsHigh; y++)
        for (NSInteger x = 0; x < (NSInteger)rep.pixelsWide; x++) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (c.redComponent > 0.60 && c.blueComponent < 0.40) {
                if (s.top == NSNotFound) s.top = y;
                s.bottom = y;
            }
        }
    return s;
}
static RowSpan FindBlueSpan(NSBitmapImageRep *rep) {
    RowSpan s = {NSNotFound, NSNotFound};
    for (NSInteger y = 0; y < (NSInteger)rep.pixelsHigh; y++)
        for (NSInteger x = 0; x < (NSInteger)rep.pixelsWide; x++) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (c.blueComponent > 0.60 && c.redComponent < 0.40) {
                if (s.top == NSNotFound) s.top = y;
                s.bottom = y;
            }
        }
    return s;
}
// 记录通知实际到达时所在的线程。用 selector 形式的观察者：它同步投递，
// 落在哪个线程就是 postNotification: 当时所在的线程。
@interface ThumbThreadProbe : NSObject
@property (nonatomic, assign) BOOL delivered;
@property (nonatomic, assign) BOOL onMain;
@end
@implementation ThumbThreadProbe
- (void)got:(NSNotification *)n {
    self.delivered = YES;
    self.onMain = [NSThread isMainThread];
}
@end

// 按列扫，找偏色像素的横向区间。contain 留不留白边要看列，不看行。
static RowSpan FindRedColSpan(NSBitmapImageRep *rep) {
    RowSpan s = {NSNotFound, NSNotFound};
    for (NSInteger x = 0; x < (NSInteger)rep.pixelsWide; x++)
        for (NSInteger y = 0; y < (NSInteger)rep.pixelsHigh; y++) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (c.redComponent > 0.60 && c.blueComponent < 0.40) {
                if (s.top == NSNotFound) s.top = x;
                s.bottom = x;
            }
        }
    return s;
}

// 把一张图走一遍真实的 VaultDrawThumbnailIn，量它在图形位内部占了多少像素行。
// 分支判定（contain 还是 cover）只有从"画出来什么样"上量才靠得住。
// 采样必须避开四周：VaultDrawThumbnailIn 会沿框边描一圈色边，采到边上就
// 无论里面画的是铺满还是细条都量成"铺满"，测出来的结论会是假的。
// 返回的行数按图形位内部高度归一，1.0 = 铺满。
static double MeasureContentFill(NSImage *thumb) {
    if (!thumb) return -1.0;
    ThumbProbeView *v = [[ThumbProbeView alloc] initWithFrame:NSMakeRect(0, 0, 80, 80)];
    v.thumb = thumb;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    NSInteger H = rep.pixelsHigh, W = rep.pixelsWide;
    NSInteger bx0 = W * 20 / 80, bx1 = W * 46 / 80;        // 图形位左右
    NSInteger by0 = H * 20 / 80, by1 = H * 421 / 800;      // 图形位上下
    NSInteger sx0 = bx0 + 6, sx1 = bx1 - 6;                // 往里缩，躲开描边
    NSInteger sy0 = by0 + 4, sy1 = by1 - 4;
    if (sx1 <= sx0 || sy1 <= sy0) return -1.0;
    NSInteger hit = 0, total = 0;
    for (NSInteger y = sy0; y <= sy1; y++) {
        for (NSInteger x = sx0; x <= sx1; x++) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            total++;
            // 底色是 0.5 灰；不是灰的就是内容
            if (fabs(c.redComponent - 0.5) > 0.08 || fabs(c.greenComponent - 0.5) > 0.08 ||
                fabs(c.blueComponent - 0.5) > 0.08) hit++;
        }
    }
    return total > 0 ? (double)hit / (double)total : -1.0;
}

// 悬停预览的私有入口，测试要直接驱动它（mouseMoved: 得造 NSEvent，太绕）
@interface DeskVaultView (PreviewProbe)
- (void)updateHoverPreviewForCard:(NSInteger)card eject:(NSInteger)eject;
@end

// 真实 vault 渲染一张图，可指定"假装正悬停着第 idx 张卡、预览浓度 k"。
// 预览相关的成员是私有的，用 KVC 直接塞 —— 这些是 ivar，KVC 会直接命中。
#define NO_PREVIEW YES
static NSBitmapImageRep *RenderVaultWithPreview(NSInteger idx, CGFloat k, BOOL forceNoPreview) {
    DeskVaultView *v = [[DeskVaultView alloc]
        initWithFrame:NSMakeRect(0, 0, kVaultViewWidth, kVaultViewHeight)];
    v.style = DeskStylePlate;
    [v setStandInScreenRect:NSMakeRect(200, 120, kVaultViewWidth, kVaultViewHeight)];
    NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:4.0];
    while ([dl timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        BOOL all = YES;
        for (DeskVaultItem *it in [DeskVault shared].items) {
            if (it.kind != VaultItemImage) continue;
            if (!VaultThumbnail([[DeskVault shared] pathForItem:it])) { all = NO; break; }
        }
        if (all) break;
    }
    [v applyPreviewHoverCard:idx dock:-1 dropHot:0 dropCount:0 scroll:0];
    [v setValue:@(forceNoPreview ? -1 : idx) forKey:@"_hoverPreview"];
    [v setValue:@(k) forKey:@"_previewK"];
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    return rep;
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];

    NSString *tall = MakeProbeImage(60, 60);     // 1:1，走 cover
    NSString *wide = MakeProbeImage(200, 20);    // 10:1，走 contain
    NSString *bogus = [NSTemporaryDirectory() stringByAppendingPathComponent:@"probe_not_an_image.txt"];
    [@"这不是图片" writeToFile:bogus atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    NSImage *tallImg = VaultThumbDecode(tall, 160);
    NSImage *wideImg = VaultThumbDecode(wide, 160);
    Check(tallImg != nil, @"方图解码成功");
    Check(wideImg != nil, @"长条图解码成功");
    Check(tallImg.size.width == 60 && tallImg.size.height == 60,
          [NSString stringWithFormat:@"方图解码尺寸 %gx%g", tallImg.size.width, tallImg.size.height]);
    Check(fabs(wideImg.size.width / wideImg.size.height - 10.0) < 0.01,
          [NSString stringWithFormat:@"长条图比例保住了 %gx%g", wideImg.size.width, wideImg.size.height]);

    Check(VaultThumbDecode(bogus, 160) == nil, @"非图片文件解不出东西（调用方回退剪影图形）");
    Check(VaultThumbDecode(@"/tmp/这个文件不存在.png", 160) == nil, @"文件不存在返回 nil");
    Check(VaultThumbnail(@"") == nil, @"空路径返回 nil");

    // 方向：方图走 cover，源图上红下蓝，画完上面还得是红。
    // 组件是翻转坐标，这里若漏了那道翻转，人物就是头朝下的 —— 必须钉死。
    {
        ThumbProbeView *v = [[ThumbProbeView alloc] initWithFrame:NSMakeRect(0, 0, 80, 80)];
        v.thumb = tallImg;
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        // cacheDisplay 给的 rep 按后备存储倍率出图（这里实测 2x），断言一律用
        // rep 的实际像素换算，别把倍率写死成 1
        NSInteger H = rep.pixelsHigh, W = rep.pixelsWide;
        NSInteger boxTop = H * 20 / 80, boxBot = H * 421 / 800;   // 视图 y 20..42.1
        NSInteger boxL = W * 20 / 80, boxR = W * 46 / 80;
        RowSpan red = FindRedSpan(rep), blu = FindBlueSpan(rep);
        Check(red.top != NSNotFound && blu.top != NSNotFound, @"红蓝两半都画进了图形位");
        Check(red.bottom < blu.top,
              [NSString stringWithFormat:@"图是正立的：红色行 %ld..%ld 全在蓝色行 %ld..%ld 之上",
               (long)red.top, (long)red.bottom, (long)blu.top, (long)blu.bottom]);
        Check(red.top >= boxTop && blu.bottom <= boxBot,
              [NSString stringWithFormat:@"内容没有溢出图形位（%ld..%ld），实际 %ld..%ld",
               (long)boxTop, (long)boxBot, (long)MIN(red.top, blu.top), (long)MAX(red.bottom, blu.bottom)]);
        (void)boxL; (void)boxR;
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:@"/tmp/verify_thumb_cover.png" atomically:YES];
    }

    // 10:1 长条图走 contain：只在图形位中间画出一条，上下都留白
    {
        ThumbProbeView *v = [[ThumbProbeView alloc] initWithFrame:NSMakeRect(0, 0, 80, 80)];
        v.thumb = wideImg;
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        NSInteger H = rep.pixelsHigh;
        NSInteger boxTop = H * 20 / 80, boxBot = H * 421 / 800;
        NSInteger boxH = boxBot - boxTop;
        RowSpan red = FindRedSpan(rep);
        Check(red.top != NSNotFound,
              [NSString stringWithFormat:@"长条图在图形位中间画出了内容（行 %ld..%ld）",
               (long)red.top, (long)red.bottom]);
        NSInteger band = (red.top != NSNotFound) ? (red.bottom - red.top + 1) : boxH;
        Check(band > 0 && band * 3 < boxH,
              [NSString stringWithFormat:@"长条图 contain 后是细条不是撑满（%ld px，图形位 %ld px）",
               (long)band, (long)boxH]);
        Check(red.top > boxTop + 2,
              @"长条图上方留了底色，没有顶到图形位上边缘");
        Check(red.bottom < boxBot - 2,
              @"长条图下方留了底色，没有顶到图形位下边缘");
    }

    // 缓存：预热后拿得到、忘记后拿不到
    {
        VaultThumbInvalidateAll();
        Check(VaultThumbnail(tall) == nil, @"清空后缓存里没有");
        VaultThumbPrefetch(@[tall]);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (!VaultThumbnail(tall) && [deadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        Check(VaultThumbnail(tall) != nil, @"预热之后缩略图可取");
        NSImage *a = VaultThumbnail(tall);
        Check(a == VaultThumbnail(tall), @"重复取到的是同一个实例（绘制路径不解码）");
        VaultThumbForget(tall);
        Check(VaultThumbnail(tall) == nil, @"forget 之后缓存清掉");
    }

    // 通知必须在主线程上送达。postNotification: 是同步投递的，后台解码队列直接发的话，
    // 观察者里的 setNeedsDisplay: 就跑到后台线程上去动 AppKit 了。
    // 观察者不能用 queue:mainQueue —— 那会强制投递到主线程，正好把问题盖住。
    {
        VaultThumbInvalidateAll();
        ThumbThreadProbe *probe = [ThumbThreadProbe new];
        [[NSNotificationCenter defaultCenter] addObserver:probe selector:@selector(got:)
                                                     name:@"VaultThumbnailsReady" object:nil];
        VaultThumbPrefetch(@[tall]);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (!probe.delivered && [deadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        Check(probe.delivered, @"解码完成会发通知");
        Check(probe.onMain, @"通知在主线程送达（观察者不会在后台线程动 AppKit）");
        [[NSNotificationCenter defaultCenter] removeObserver:probe];
    }

    // 退回桌面 / 全退之后位图要跟着走，不能只进不出
    {
        VaultThumbInvalidateAll();
        VaultThumbPrefetch(@[tall, wide]);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while ((!VaultThumbnail(tall) || !VaultThumbnail(wide)) && [deadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        Check(VaultThumbnail(tall) && VaultThumbnail(wide), @"两张都预热好了");
        VaultThumbPruneTo(@[wide]);                 // 模拟 tall 被退回桌面
        Check(VaultThumbnail(wide) != nil, @"清单内的缩略图留着");
        Check(VaultThumbnail(tall) == nil, @"清单外的缩略图被裁掉（内存不会只进不出）");
    }

    // 变形（调角）时走的是另一块离屏素材视图。那块素材一旦落进预览模式，
    // 缩略图就按路径解析不出来 —— 表现为「没变形时是���图，一进调角全退回剪影」。
    // vault 为 nil 表示这块视图钉了假数据（预览模式），真实运行时必须是 nil 以外的状态。
    {
        DeskVaultView *v = [[DeskVaultView alloc]
            initWithFrame:NSMakeRect(0, 0, kVaultViewWidth, kVaultViewHeight)];
        DeskQuadOffsets zero = DeskQuadOffsetsZero();
        DeskQuadOffsets bent = zero;
        bent.tl = NSMakeSize(18.0, 0.0);
        bent.tr = NSMakeSize(0.0, 12.0);
        bent.bl = NSMakeSize(0.0, -10.0);
        v.quadOffsets = bent;                       // 会触发 syncWarp 建素材源
        DeskVaultView *src = [v valueForKey:@"flatSource"];
        Check(src != nil, @"变形后建出了离屏素材视图");
        Check(src.vault != nil,
              @"素材视图仍是真实 vault 模式（缩略图能按路径解析，不会退回剪影）");
        v.quadOffsets = zero;                       // 撤回去，别把窗口留在变形态
        Check([v valueForKey:@"flatSource"] == nil, @"撤掉变形后素材视图被释放");
    }

    // 大图必须被压到上限以内。图形位只有 26pt，真解出一张 6000px 的原图
    // 就是在 60fps 重绘里白白扛几十 MB —— 这条以前只是我口头说过，没钉住。
    {
        NSString *big = MakeProbeImage(1200, 900);
        NSImage *bi = VaultThumbDecode(big, 160);
        Check(bi != nil, @"大图解码成功");
        CGFloat longEdge = MAX(bi.size.width, bi.size.height);
        Check(longEdge <= 160.0,
              [NSString stringWithFormat:@"大图被压到长边上限内（%.0f ≤ 160），实得 %.0fx%.0f",
               longEdge, bi.size.width, bi.size.height]);
        Check(fabs(bi.size.width / bi.size.height - 4.0 / 3.0) < 0.02,
              [NSString stringWithFormat:@"压完比例不变（4:3 → %.3f）", bi.size.width / bi.size.height]);
    }

    // contain / cover 的分界就在 2.5 上（严格大于才走 contain）。边界值本身要钉住，
    // 免得以后有人把比较符或阈值改了，行为跟着变却没人发现。
    {
        // 2.5 : 1 → 不大于 2.5 → cover → 内容铺满图形位内部
        NSString *edgeOn = MakeProbeImage(500, 200);
        // 2.67 : 1 → 大于 2.5 → contain → 内容只占中间一条
        NSString *edgeOff = MakeProbeImage(400, 150);
        double on = MeasureContentFill(VaultThumbDecode(edgeOn, 160));
        double off = MeasureContentFill(VaultThumbDecode(edgeOff, 160));
        Check(on > 0.80,
              [NSString stringWithFormat:@"正好 2.5:1 走 cover，铺满图形位（填充 %.0f%%）", on * 100]);
        Check(off >= 0 && off < 0.60,
              [NSString stringWithFormat:@"2.67:1 走 contain，只占中间一条（填充 %.0f%% < 60%%）", off * 100]);
    }

    // —— 悬停预览：第二级缓存 ——
    {
        NSString *p1 = MakeProbeImage(2400, 1600);   // 大图，验证上限
        NSString *p2 = MakeProbeImage(300, 400);
        VaultThumbPreviewInvalidateAll();
        Check(VaultThumbPreview(p1) == nil, @"预览缓存一开始是空的");

        VaultThumbPreviewPrefetch(p1);
        VaultThumbPreviewPrefetch(p2);
        NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:4.0];
        while ((!VaultThumbPreview(p1) || !VaultThumbPreview(p2)) && [dl timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        NSImage *pv = VaultThumbPreview(p1);
        Check(pv != nil, @"预览级解码完成");
        CGFloat pl = pv ? MAX(pv.size.width, pv.size.height) : 9999;
        Check(pl <= 720.0, [NSString stringWithFormat:@"预览图被限到 720px 内（实得 %.0f）", pl]);
        Check(pv && fabs(pv.size.width / pv.size.height - 1.5) < 0.02,
              @"预览图比例不变（2400:1600）");
        // 反复 prefetch 同一张不该重新解码（返回的是同一个实例）
        Check(VaultThumbPreview(p1) == pv, @"重复取到同一实例，不重新解码");

        // LRU：塞够 6 张，只留 4
        NSMutableArray *six = [NSMutableArray array];
        for (int i = 0; i < 6; i++) {
            NSString *p = MakeProbeImage(200 + i, 200);
            [six addObject:p];
            VaultThumbPreviewPrefetch(p);
        }
        dl = [NSDate dateWithTimeIntervalSinceNow:6.0];
        while ([dl timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            BOOL all = YES;
            for (NSString *p in six) if (!VaultThumbPreview(p)) { all = NO; break; }
            if (all) break;
        }
        NSInteger alive = 0;
        for (NSString *p in six) if (VaultThumbPreview(p)) alive++;
        Check(alive <= 4, [NSString stringWithFormat:@"预览缓存有上限，6 张里只留 %ld 张（≤4）", (long)alive]);

        // 上面那轮 6 张把 p2 挤掉了（这本身就是 LRU 在工作），重新热一张再测 prune
        VaultThumbPreviewPrefetch(p2);
        dl = [NSDate dateWithTimeIntervalSinceNow:4.0];
        while (!VaultThumbPreview(p2) && [dl timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        VaultThumbPreviewPruneTo(@[p2]);
        Check(VaultThumbPreview(p2) != nil, @"prune 后清单内的还在");
        Check(VaultThumbPreview(p1) == nil, @"prune 后清单外的被裁掉");
    }

    // —— 悬停预览：绘制 ——
    {
        // contain + 方向：竖图在预览框里四边都该留白，且上红下蓝
        NSString *vp = MakeProbeImage(120, 300);
        NSImage *vi = VaultThumbDecode(vp, 720);
        PreviewProbeView *pv = [[PreviewProbeView alloc] initWithFrame:NSMakeRect(0, 0, 80, 80)];
        pv.thumb = vi;
        NSBitmapImageRep *rep = [pv bitmapImageRepForCachingDisplayInRect:pv.bounds];
        [pv cacheDisplayInRect:pv.bounds toBitmapImageRep:rep];
        // cacheDisplay 按后备存储倍率出图（实测 2x），坐标一律按 rep 实际像素算
        CGFloat by0 = 20 * rep.pixelsHigh / 80.0;
        CGFloat by1 = 42.1 * rep.pixelsHigh / 80.0;
        RowSpan rs = FindRedSpan(rep), bs = FindBlueSpan(rep);
        Check(rs.top != NSNotFound && bs.top != NSNotFound, @"预览图的红蓝两半都画出来了");
        Check(rs.bottom < bs.top, @"预览图是正立的：红在上、蓝在下");
        Check(rs.top >= by0 && bs.bottom <= by1, @"内容没有溢出框");
        // 120×300 竖图放进 26×22.1 的横向框：contain 的结果是"填满高度、左右留白"。
        // 所以留白要看列，不能看行 —— 查行会误判成"没留白"
        RowSpan rc = FindRedColSpan(rep);
        CGFloat bx0 = 20 * rep.pixelsWide / 80.0, bx1 = 46 * rep.pixelsWide / 80.0;
        Check(rc.top > bx0 + 2 && rc.bottom < bx1 - 2,
              [NSString stringWithFormat:@"竖图 contain 后左右留白（内容列 %.0f..%.0f，框 %.0f..%.0f）",
               (double)rc.top, (double)rc.bottom, bx0, bx1]);
    }

    // —— 悬停预览：视图落位 ——
    // 用真实 vault（不是假数据）：假数据模式下路径解析按设计返回 nil，出不了预览。
    // 办法是渲染两次求差：无预览 vs 有预览，差出来的像素范围就是预览的落位。
    {
        NSArray *items = [DeskVault shared].items;
        NSInteger imgIdx = -1, vidIdx = -1;
        for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
            DeskVaultItem *it = items[i];
            if (it.kind == VaultItemImage && imgIdx < 0) imgIdx = i;
            if (it.kind != VaultItemImage && vidIdx < 0) vidIdx = i;
        }
        if (imgIdx < 0) {
            Check(NO, @"库里没有图片卡片，跳过预览落位校验（请先往库里放一张图）");
        } else {
            VaultThumbPreviewPrefetch([[DeskVault shared] pathForItem:items[imgIdx]]);

            // 无预览 / 图片卡有预览 / 非图片卡强行悬停，三张对照
            NSBitmapImageRep *a = RenderVaultWithPreview(imgIdx, 0.0, NO_PREVIEW);
            NSBitmapImageRep *b = RenderVaultWithPreview(imgIdx, 1.0, NO);
            NSBitmapImageRep *c = nil, *cBase = nil;
            if (vidIdx >= 0) {
                c = RenderVaultWithPreview(vidIdx, 1.0, NO);
                cBase = RenderVaultWithPreview(vidIdx, 0.0, NO_PREVIEW);
            }

            NSInteger changed = 0, minX = 99999, maxX = -1, minY = 99999, maxY = -1;
            for (NSInteger y = 0; y < a.pixelsHigh; y++)
                for (NSInteger x = 0; x < a.pixelsWide; x++) {
                    NSColor *pa = [a colorAtX:x y:y], *pb = [b colorAtX:x y:y];
                    if (fabs(pa.redComponent - pb.redComponent) < 0.02 &&
                        fabs(pa.greenComponent - pb.greenComponent) < 0.02 &&
                        fabs(pa.blueComponent - pb.blueComponent) < 0.02) continue;
                    changed++;
                    if (x < minX) minX = x; if (x > maxX) maxX = x;
                    if (y < minY) minY = y; if (y > maxY) maxY = y;
                }
            // 预览已经挪到组件外面去了，组件自身的画面不该被它改动
            Check(changed == 0,
                  [NSString stringWithFormat:@"预览不画在组件内，组件画面零变化（实测 %ld）", (long)changed]);
            Check(minX == 99999 && maxX == -1 && minY == 99999 && maxY == -1,
                  @"悬停图片卡片时组件内没有任何区域被重绘");
            if (c) {
                // 基线是"同样悬停着这张非图片卡、但不设预览"，两者必须逐像素相同
                NSInteger changed2 = 0;
                for (NSInteger y = 0; y < a.pixelsHigh; y++)
                    for (NSInteger x = 0; x < a.pixelsWide; x++) {
                        NSColor *pb = [cBase colorAtX:x y:y], *pc = [c colorAtX:x y:y];
                        if (fabs(pb.redComponent - pc.redComponent) > 0.02 ||
                            fabs(pb.greenComponent - pc.greenComponent) > 0.02 ||
                            fabs(pb.blueComponent - pc.blueComponent) > 0.02) changed2++;
                    }
                Check(changed2 == 0,
                      [NSString stringWithFormat:@"非图片卡片不出预览（同样悬停下，设不设预览逐像素相同，实测差异 %ld）",
                       (long)changed2]);
            }
            // 要的是"毫秒级出现"：不做延迟也不做过渡，一进来就是终态
            __block NSString *fired = nil;
            __block NSInteger fires = 0;
            DeskVaultView *tv = [[DeskVaultView alloc]
                initWithFrame:NSMakeRect(0, 0, kVaultViewWidth, kVaultViewHeight)];
            tv.onPreview = ^(NSString *p) { fired = p; fires++; };
            [tv applyPreviewHoverCard:imgIdx dock:-1 dropHot:0 dropCount:0 scroll:0];
            [tv updateHoverPreviewForCard:imgIdx eject:-1];
            Check(fires == 1 && fired.length > 0, @"悬停图片卡片立刻回调要开预览（不等待）");
            double pk = [[tv valueForKey:@"_previewK"] doubleValue];
            Check(pk == 1.0, [NSString stringWithFormat:@"一进来就是终态 1.0，没有淡入过程（实测 %.3f）", pk]);
            [tv updateHoverPreviewForCard:-1 eject:-1];
            Check(fired == nil || fired.length == 0, @"移开后回调要关预览");
            Check([[tv valueForKey:@"_previewK"] doubleValue] == 0.0, @"关闭也是立即置 0");
        }
    }

    printf("\n缩略图校验：%d 项通过，%d 项失败\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
} }
