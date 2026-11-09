// 模型与布局的回归断言：不依赖界面，可直接跑。用法：verify <项目根目录>
#import <Foundation/Foundation.h>
#import "model.h"
#import "panel_view.h"
#import "places.h"
#import "sysmon.h"
#import "backdrop.h"
#import "vault.h"
#import "vault_art.h"
#import "vault_view.h"
#import "monitor_view.h"
#import "procs.h"
#import "history.h"
#import "oilfeed.h"

// oilfeed.m 的私有类方法，断言直接喂一行接口记录来验"下次窗口"的推算
@interface DeskOilFeed (VerifyOil)
+ (NSString *)bodyFromRow:(NSDictionary *)row facts:(NSMutableDictionary *)facts error:(NSString **)err;
@end

#import <math.h>

// vault_view.m 里的私有方法，断言只读它算出来的扫描带位置（-1 = 这一帧不画扫描带）
@interface DeskVaultView (VerifyEnergy)
- (double)currentSweep;
@end

// 滚动方向断言要量卡片在屏幕上的实际位移，所以借布局函数
@interface DeskVaultView (VerifyScroll)
- (NSRect)cardRectAtIndex:(NSInteger)idx in:(NSRect)b;
- (CGFloat)maxScroll;
@end

// 用 CGEvent 造滚轮事件再转成 NSEvent：pixel 单位 = 触控板的精确增量，
// line 单位 = 滚轮一格。事实基准来自 tools/probe_scroll.m —— 同一个事件喂给
// 原生 NSScrollView（翻转文档），正 scrollingDeltaY 让可视区 origin.y 变小。
static NSEvent *ScrollProbeEvent(CGFloat deltaY, BOOL precise) {
    CGEventRef cg = CGEventCreateScrollWheelEvent(
        NULL, precise ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine, 1, (int32_t)deltaY);
    if (!cg) return nil;
    CGEventSetLocation(cg, CGPointMake(100, 100));
    NSEvent *e = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    return e;
}


static int gFail = 0;

// monitor_view.m 的私有几何，断言里按同一套常量复算一遍，
// 万一两边漂了这条断言会立刻红
extern const CGFloat kMonitorViewWidth, kMonitorViewHeight;
extern const CGFloat kMonitorViewCompactWidth, kMonitorViewCompactHeight;
static const CGFloat kMonitorPadXForVerify = 16.0;
static const CGFloat kCompactPadForVerify = 12.0;
static const CGFloat kCompactGapForVerify = 8.0;
static const CGFloat kMonitorQuadGapX = 10.0, kMonitorQuadGapY = 10.0;
static const CGFloat kMonitorPadTopForVerify = 14.0;     // 上下各 14pt，抬头/表尾已删
static const CGFloat kMonitorPadBottomForVerify = 14.0;
static const CGFloat kMonitorHistWForVerify = 64.0;
static const CGFloat kMonitorColGapForVerify = 6.0;

// panel_view.m 的弹药库式卡片：13pt 上下边、4 行、8pt 瓷砖上下内边距、24pt 表尾。
// 抬头已删，断言里按同一套常量复算，两边一漂就红。
static const CGFloat kPanelPadForVerify = 13.0;
static const CGFloat kPanelSidePadForVerify = 14.0;
static const CGFloat kPanelRowHForVerify = 21.0;
static const CGFloat kPanelTilePadForVerify = 8.0;
static const CGFloat kPanelFooterHForVerify = 24.0;
static NSRect MonitorGridInnerFor(NSRect b) {
    return NSMakeRect(NSMinX(b) + kMonitorPadXForVerify, kMonitorPadTopForVerify,
                      NSWidth(b) - 2 * kMonitorPadXForVerify,
                      NSHeight(b) - kMonitorPadTopForVerify - kMonitorPadBottomForVerify);
}
static NSRect MonitorQuadFor(DeskMonitorView *v, NSInteger m) {
    NSRect inner = MonitorGridInnerFor(v.bounds);
    CGFloat w = (NSWidth(inner) - kMonitorQuadGapX) / 2.0;
    CGFloat h = (NSHeight(inner) - kMonitorQuadGapY) / 2.0;
    int col = (int)m % 2, row = (int)m / 2;
    return NSMakeRect(NSMinX(inner) + col * (w + kMonitorQuadGapX),
                      NSMinY(inner) + row * (h + kMonitorQuadGapY), w, h);
}

static int gPass = 0;

static void Say(BOOL ok, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void Say(BOOL ok, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s %s\n", ok ? "✓" : "✗", msg.UTF8String);
    if (ok) gPass++; else gFail++;
}

static DeskStatRow *StatAt(NSArray<DeskStatRow *> *a, NSUInteger i) {
    return i < a.count ? a[i] : nil;   // 越界时打印 (null) 而不是让测试脚本崩掉
}

static DeskModel *LoadMock(NSString *root, NSString *name) {
    NSString *path = [[root stringByAppendingPathComponent:@"mock"] stringByAppendingPathComponent:name];
    return [DeskModel modelFromJSONFileAtPath:path];
}

// 四角分别染色的探针源图：红=左上 绿=右上 蓝=右下 黄=左下。
// 拖哪个角、动的是哪个角，靠它就能量出来而不是靠猜。
@interface DeskCornerView : NSView
@property (nonatomic, strong) NSImage *image;
@end

@implementation DeskCornerView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    if (self.image) {
        [self.image drawInRect:self.bounds fromRect:NSZeroRect
                    operation:NSCompositingOperationCopy fraction:1.0];
        return;
    }
    [[NSColor blackColor] set];
    NSRectFill(self.bounds);
    const CGFloat k = 22;
    NSSize s = self.bounds.size;
    [[NSColor redColor] set];    NSRectFill(NSMakeRect(0, 0, k, k));
    [[NSColor greenColor] set];  NSRectFill(NSMakeRect(s.width - k, 0, k, k));
    [[NSColor blueColor] set];   NSRectFill(NSMakeRect(s.width - k, s.height - k, k, k));
    [[NSColor yellowColor] set]; NSRectFill(NSMakeRect(0, s.height - k, k, k));
}
@end

static NSPoint CentroidOf(NSBitmapImageRep *rep, double (*match)(NSColor *));
static NSPoint CentroidOf(NSBitmapImageRep *rep, double (*match)(NSColor *)) {
    double sx = 0, sy = 0; long n = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; y += 2) {
        for (NSInteger x = 0; x < rep.pixelsWide; x += 2) {
            NSColor *c = [rep colorAtX:x y:y];
            if (!match(c)) continue;
            sx += x; sy += y; n++;
        }
    }
    double scale = rep.size.width > 0 ? rep.pixelsWide / rep.size.width : 1.0;
    return n ? NSMakePoint(sx / n / scale, sy / n / scale) : NSMakePoint(-1, -1);
}

static double IsRed(NSColor *c) { return c.redComponent > .6 && c.greenComponent < .4 && c.blueComponent < .4; }
static double IsBlue(NSColor *c) { return c.blueComponent > .5 && c.redComponent < .5; }

// 朝向判定用的探针视图：翻转坐标下往左上角画一块白，"白在哪一角"就成了可测量的事实。
// 给了 image 就只画那张图，用来检查投影结果落回视图后的朝向。
@interface DeskMarkView : NSView
@property (nonatomic, strong) NSImage *image;
@end

@implementation DeskMarkView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    if (self.image) {
        [self.image drawInRect:self.bounds fromRect:NSZeroRect
                     operation:NSCompositingOperationCopy fraction:1.0];
        return;
    }
    [[NSColor blackColor] set];
    NSRectFill(self.bounds);
    [[NSColor whiteColor] set];
    NSRectFill(NSMakeRect(0, 0, 40, 40));
}
@end

// 不透明区的包围盒（点、左上原点），用来量"画面到底占了画布多大一块"
static NSRect OpaqueBox(NSView *v, double thresh) {
    NSRect bounds = v.bounds;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:bounds];
    [v cacheDisplayInRect:bounds toBitmapImageRep:rep];
    double scale = rep.size.width > 0 ? rep.pixelsWide / rep.size.width : 1.0;
    long minx = 1L << 30, miny = 1L << 30, maxx = -1, maxy = -1;
    for (NSInteger y = 0; y < rep.pixelsHigh; y += 2) {
        for (NSInteger x = 0; x < rep.pixelsWide; x += 2) {
            if ([rep colorAtX:x y:y].alphaComponent < thresh) continue;
            minx = MIN(minx, x); maxx = MAX(maxx, x);
            miny = MIN(miny, y); maxy = MAX(maxy, y);
        }
    }
    if (maxx < 0) return NSZeroRect;
    return NSMakeRect(minx / scale, miny / scale, (maxx - minx) / scale, (maxy - miny) / scale);
}

// 数一下视图上有多少"实心"像素：只要 >0 就说明文字真的画上去了，而不是只剩底板
static long InkOf(NSView *v) {
    NSRect bounds = v.bounds;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:bounds];
    [v cacheDisplayInRect:bounds toBitmapImageRep:rep];
    long ink = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; y += 2) {
        for (NSInteger x = 0; x < rep.pixelsWide; x += 2) {
            if ([rep colorAtX:x y:y].alphaComponent > 0.55) ink++;
        }
    }
    return ink;
}

// 两张画面逐点比，返回"差得超过阈值"的采样点占比。
// 位图重烘带零星抖动，靠字节相等判"变了"是不行的；这个比例既能扛住抖动，
// 又能把整套外观切换那种整片变天量出来。
static double PixelDiffRatio(NSView *a, NSView *b) {
    NSRect r = a.bounds;
    NSBitmapImageRep *ra = [a bitmapImageRepForCachingDisplayInRect:r];
    [a cacheDisplayInRect:r toBitmapImageRep:ra];
    NSBitmapImageRep *rb = [b bitmapImageRepForCachingDisplayInRect:r];
    [b cacheDisplayInRect:r toBitmapImageRep:rb];
    long total = 0, diff = 0;
    for (NSInteger y = 0; y < ra.pixelsHigh; y += 3) {
        for (NSInteger x = 0; x < ra.pixelsWide; x += 3) {
            NSColor *ca = [ra colorAtX:x y:y];
            NSColor *cb = [rb colorAtX:x y:y];
            total++;
            if (fabs(ca.redComponent - cb.redComponent) > 0.10 ||
                fabs(ca.greenComponent - cb.greenComponent) > 0.10 ||
                fabs(ca.blueComponent - cb.blueComponent) > 0.10 ||
                fabs(ca.alphaComponent - cb.alphaComponent) > 0.10) diff++;
        }
    }
    return total ? (double)diff / (double)total : 0.0;
}

// 弹药库断言用的假文件夹：只塞字段，不碰真实文件系统
static DeskVaultItem *FakeVaultItem(NSString *name, long long bytes, NSUInteger files,
                                    double seed, double ago) {
    DeskVaultItem *it = [DeskVaultItem new];
    it.name = name;
    it.sourceName = name;
    it.storedName = name;
    it.seed = seed;
    it.byteSize = bytes;
    it.fileCount = files;
    it.scanned = YES;
    it.ingestedAt = (long long)([[NSDate date] timeIntervalSince1970] - ago);
    return it;
}

static double MeanLuma(NSImage *img) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:[img TIFFRepresentation]];
    if (!rep) return -1;
    double sum = 0; int n = 0;
    for (int i = 1; i <= 4; i++) {
        for (int j = 1; j <= 4; j++) {
            NSColor *c = [rep colorAtX:(NSInteger)(rep.pixelsWide * i / 5) y:(NSInteger)(rep.pixelsHigh * j / 5)];
            sum += 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent;
            n++;
        }
    }
    return n ? sum / n : -1;
}

static double MaxPixelDelta(NSImage *a, NSImage *b) {
    NSBitmapImageRep *ra = [[NSBitmapImageRep alloc] initWithData:[a TIFFRepresentation]];
    NSBitmapImageRep *rb = [[NSBitmapImageRep alloc] initWithData:[b TIFFRepresentation]];
    if (!ra || !rb) return -1;
    double best = 0;
    for (int i = 1; i <= 6; i++) {
        for (int j = 1; j <= 6; j++) {
            NSColor *ca = [ra colorAtX:(NSInteger)(ra.pixelsWide * i / 7) y:(NSInteger)(ra.pixelsHigh * j / 7)];
            NSColor *cb = [rb colorAtX:(NSInteger)(rb.pixelsWide * i / 7) y:(NSInteger)(rb.pixelsHigh * j / 7)];
            best = MAX(best, fabs(ca.redComponent - cb.redComponent)
                             + fabs(ca.greenComponent - cb.greenComponent)
                             + fabs(ca.blueComponent - cb.blueComponent));
        }
    }
    return best;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法：verify <项目根目录>\n");
            return 2;
        }
        NSString *root = @(argv[1]);
        // 离屏窗口不会上屏，面板默认不播到点动效；断言里显式打开（只影响这一次进程）
        setenv("DESK_PANEL_FORCE_ANIMATION", "1", 1);

        printf("油价数据（mock/mock.json，由 ./tools/refresh.py 刷新）\n");
        DeskModel *oil = LoadMock(root, @"mock.json");
        // 期望值一律从这份数据自己算，别把日期和"还剩几天"钉死：
        // 这两条本来只想验"日期和倒计时并进同一行"这个结构，
        // 钉死具体值之后，每次 refresh.py 刷了新数据都会把它们打破——
        // 那是数据变了，不是代码坏了。口径跟 model.m 的 DaysText 保持一致。
        NSData *mockData = [NSData dataWithContentsOfFile:[[root stringByAppendingPathComponent:@"mock"]
                                                            stringByAppendingPathComponent:@"mock.json"]];
        id parsed = mockData ? [NSJSONSerialization JSONObjectWithData:mockData options:0 error:nil] : nil;
        NSDictionary *mockJSON = [parsed isKindOfClass:[NSDictionary class]] ? parsed : @{};
        id nextVal = mockJSON[@"nextDate"];
        NSString *mockNext = [nextVal isKindOfClass:[NSString class]] ? nextVal : nil;
        NSString *mockCountdown = nil;
        id daysVal = mockJSON[@"daysLeft"];
        if ([daysVal isKindOfClass:[NSNumber class]]) {
            NSInteger d = [daysVal integerValue];
            mockCountdown = d < 0 ? @"已过调价日" : (d == 0 ? @"今天"
                                                          : [NSString stringWithFormat:@"还剩 %ld 天", (long)d]);
        }
        Say([oil.title isEqualToString:@"上海 · 92号汽油"], @"标题= %@", oil.title);
        Say([oil.unit isEqualToString:@"元/升"], @"单位= %@", oil.unit);
        double priceVal = [oil.price doubleValue];
        Say(priceVal > 5.0 && priceVal < 12.0, @"上海 92 号现价= %@ 元/升", oil.price);
        Say(mockNext.length && [oil.infoLine containsString:mockNext], @"油价说明行= %@", oil.infoLine);
        Say(mockCountdown.length && [oil.infoLine containsString:mockCountdown],
            @"倒计时并进同一行= %@", oil.infoLine);
        Say(![oil.infoLine containsString:@"预计"] && ![oil.infoLine containsString:@"变化率"],
            @"预计与参考原油变化率已去掉");
        Say([oil.footer hasPrefix:@"更新于"], @"页脚= %@", oil.footer);
        Say(oil.loadError == nil, @"无读取错误");

        printf("\n边界输入\n");
        DeskModel *today = [DeskModel modelFromDictionary:@{@"daysLeft": @0}];
        Say([today.infoLine containsString:@"今天"], @"daysLeft=0 → %@", today.infoLine);
        DeskModel *past = [DeskModel modelFromDictionary:@{@"daysLeft": @(-2)}];
        Say([past.infoLine containsString:@"已过调价日"], @"daysLeft<0 → %@", past.infoLine);
        DeskModel *bare = [DeskModel modelFromDictionary:@{}];
        Say(bare.infoLine.length == 0, @"什么字段都没有时不硬凑占位说明（= \"%@\"）", bare.infoLine);
        Say([bare.price isEqualToString:@"—"], @"缺价格 → %@", bare.price);
        Say(bare.unit.length == 0, @"缺单位 → 空");
        DeskModel *junk = [DeskModel modelFromDictionary:@{@"price": @"七块六", @"city": @42, @"daysLeft": @"10天"}];
        Say([junk.price isEqualToString:@"—"], @"类型错误被挡住（price= %@）", junk.price);
        Say([junk.title isEqualToString:@"油价"], @"类型错误被挡住（title= %@）", junk.title);
        Say(junk.infoLine.length == 0, @"daysLeft 非数字就不显示该行");
        Say([junk.footer isEqualToString:@"更新时间未知"], @"缺时间戳 → %@", junk.footer);
        DeskModel *missing = [DeskModel modelFromJSONFileAtPath:@"/tmp/deskboard-no-such-file.json"];
        Say(missing.loadError.length > 0 && missing.infoLine.length == 0, @"文件缺失走占位模型并带错误");
        DeskModel *badJSON = [DeskModel modelFromJSONFileAtPath:[root stringByAppendingPathComponent:@"mock/broken.json"]];
        Say(badJSON.loadError.length > 0, @"非法 JSON 走占位模型（%@）", badJSON.loadError);

        printf("\n面板尺寸\n");
        NSSize s2 = [DeskPanelView sizeForModel:oil];
        Say(fabs(s2.width - kDeskPanelWidth) < 0.01, @"单列表格宽度= %.0f", s2.width);
        Say(fabs(s2.height - (2 * kPanelPadForVerify
                             + kPanelTilePadForVerify
                             + kPanelFooterHForVerify)) < 0.01,
            @"没有系统指标时只剩瓷砖 + 表尾 = %.0fpt 高", s2.height);

        printf("\n卡片内容刷新\n");
        {
            // 数据画在 DeskCardView 的 _panel 子视图里。只给卡片视图标脏的话，
            // 子视图会停在建窗第一帧：实机表现就是 CPU 永远 "—"、GPU 0。
            // AppKit 对没进 runloop 的测试窗口不维护 needsDisplay（离屏/可见窗口实测都是 0），
            // 所以这道闸守源码里的标脏行，实机行为由窗口抓图验证。
            NSString *src = [NSString stringWithContentsOfFile:@"panel_view.m"
                                                      encoding:NSUTF8StringEncoding error:NULL];
            Say(src.length > 0, @"读到了 panel_view.m 源码（这条断言的前提）");
            Say([src rangeOfString:@"[self.panel setNeedsDisplay:YES]"].location != NSNotFound,
                @"updateModel 里给 _panel 标脏的那行还在（少了它卡片会停在建窗第一帧）");
            Say([src rangeOfString:@"CPU LOAD"].location == NSNotFound,
                @"卡片不再画 CPU 大读数");
            Say([src rangeOfString:@"VaultDrawRing"].location == NSNotFound,
                @"卡片不再画 CPU 容量环");
            Say([src rangeOfString:@"SYS STATUS"].location == NSNotFound
                && [src rangeOfString:@"VaultDrawChip"].location == NSNotFound,
                @"卡片抬头（芯片 + SYS STATUS 副标题）不再上屏");
        }


        printf("\n系统指标行格式化\n");
        const double bytesPerGiB = 1024.0 * 1024.0 * 1024.0;
        DeskStats *fake = [DeskStats new];
        fake.cpu = 34.2; fake.cpuWindow = kDeskCPUWindowSeconds; fake.gpu = 8;
        fake.memUsed = 12.0 * bytesPerGiB; fake.memTotal = 24.0 * bytesPerGiB;
        fake.diskFree = 214e9; fake.diskTotal = 494e9; fake.diskIsSSD = YES;
        fake.diskRead = 3.1e6; fake.diskWrite = 12.4e6;
        fake.cpuTemp = 61.5; fake.thermal = 1; fake.netInterface = @"en8"; fake.netAddress = @"192.168.31.23"; fake.netIsWiFi = NO;
        fake.ssdTemp = 33.0;
        fake.netRecv = 1.24e6; fake.netSend = 340e3;
        NSArray<DeskStatRow *> *statRows = [DeskModel statRowsForStats:fake];
        Say(statRows.count == 4, @"指标行数= %lu（CPU/GPU/内存/网速已移除）", (unsigned long)statRows.count);
        Say([StatAt(statRows, 0).label isEqualToString:@"温度"], @"温度行= %@", StatAt(statRows, 0).label);
        Say([StatAt(statRows, 0).value isEqualToString:@"CPU 61.5°C · SSD 33°C"],
            @"两个温度各自带名 = %@", StatAt(statRows, 0).value);
        Say(fabs(StatAt(statRows, 0).fraction - 0.615) < 0.001,
            @"温度条取 CPU 61.5 / SSD 33 中更热的：%.3f", StatAt(statRows, 0).fraction);
        DeskStats *ssdHot = [DeskStats new];
        ssdHot.cpuTemp = 40.0; ssdHot.ssdTemp = 90.0;
        DeskStatRow *ssdHotRow = StatAt([DeskModel statRowsForStats:ssdHot], 0);
        Say(fabs(ssdHotRow.fraction - 0.90) < 0.001,
            @"CPU 40 / SSD 90 时温度条取 90：%.3f", ssdHotRow.fraction);
        BOOL hasRate = NO;
        for (DeskStatRow *r in statRows) if ([r.label isEqualToString:@"网速"]) hasRate = YES;
        Say(!hasRate, @"网速行不再显示");
        Say([StatAt(statRows, 1).label isEqualToString:@"磁盘 SSD"], @"磁盘标签= %@", StatAt(statRows, 1).label);
        Say([StatAt(statRows, 1).value isEqualToString:@"57% · 剩 214G"], @"磁盘带百分比= %@", StatAt(statRows, 1).value);
        Say([StatAt(statRows, 2).value isEqualToString:@"有线 · en8"], @"网络行= %@", StatAt(statRows, 2).value);
        Say([StatAt(statRows, 3).value isEqualToString:@"192.168.31.23"], @"IPv4= %@", StatAt(statRows, 3).value);
        BOOL hasRemoved = NO;
        for (DeskStatRow *r in statRows) {
            if ([r.label hasPrefix:@"CPU"] || [r.label isEqualToString:@"GPU"] ||
                [r.label hasPrefix:@"内存"]) hasRemoved = YES;
        }
        Say(!hasRemoved, @"CPU / GPU / 内存 行都已移除");
        BOOL hasIO = NO;
        for (DeskStatRow *r in statRows) if ([r.label containsString:@"读写"]) hasIO = YES;
        Say(!hasIO, @"读写 MB/s 行不再显示");
        DeskStats *noNet = [DeskStats new];
        noNet.cpu = -1; noNet.gpu = -1; noNet.netRecv = -1; noNet.netSend = -1;
        NSArray<DeskStatRow *> *noNetRows = [DeskModel statRowsForStats:noNet];
        BOOL noNetRate = NO;
        for (DeskStatRow *r in noNetRows) if ([r.label isEqualToString:@"网速"]) noNetRate = YES;
        Say(!noNetRate, @"速率还没取到基准时也不再占一行");
        DeskStats *unknown = [DeskStats new];
        unknown.cpu = -1; unknown.gpu = -1; unknown.diskRead = -1; unknown.diskWrite = -1;
        NSArray<DeskStatRow *> *unkRows = [DeskModel statRowsForStats:unknown];
        Say([StatAt(unkRows, 0).value isEqualToString:@"—"], @"温度取不到 → %@", StatAt(unkRows, 0).value);
        DeskStats *cpuOnly = [DeskStats new];
        cpuOnly.cpuTemp = 61.5;
        Say([StatAt([DeskModel statRowsForStats:cpuOnly], 0).value isEqualToString:@"CPU 61.5°C"],
            @"SSD 温度取不到时 CPU 温度也带名 = %@",
            StatAt([DeskModel statRowsForStats:cpuOnly], 0).value);
        DeskStats *nowifi = [DeskStats new]; nowifi.cpu = -1; nowifi.gpu = -1;
        nowifi.diskRead = -1; nowifi.diskWrite = -1;
        NSArray<DeskStatRow *> *offline = [DeskModel statRowsForStats:nowifi];
        Say([StatAt(offline, 2).value isEqualToString:@"未连接"], @"没默认路由时= %@", StatAt(offline, 2).value);
        Say([DeskModel statRowsForStats:nil].count == 0, @"没有指标就一行都不画");
        (void)s2;

        printf("\n卡片表尾（只剩电池）\n");
        DeskStats *power = [DeskStats new];
        power.batteryPercent = 100; power.batteryOnAC = YES; power.batteryCharged = YES;
        Say([[DeskModel batteryStatusTextForStats:power] isEqualToString:@"100% · 交流电"],
            @"满电 + 交流电 = %@", [DeskModel batteryStatusTextForStats:power]);
        power.batteryPercent = 82; power.batteryOnAC = NO;
        power.batteryCharging = NO; power.batteryMinutes = 192;
        Say([[DeskModel batteryStatusTextForStats:power] isEqualToString:@"82% · 剩余 3:12"],
            @"电池供电 + 剩余时间 = %@", [DeskModel batteryStatusTextForStats:power]);
        power.batteryOnAC = YES; power.batteryCharging = YES; power.batteryMinutes = 40;
        Say([[DeskModel batteryStatusTextForStats:power] isEqualToString:@"82% · 充电中"],
            @"交流电 + 充电中 = %@", [DeskModel batteryStatusTextForStats:power]);
        DeskStats *noPower = [DeskStats new];
        Say([[DeskModel batteryStatusTextForStats:noPower] isEqualToString:@"—"],
            @"没有电池 → %@", [DeskModel batteryStatusTextForStats:noPower]);

        DeskStats *sw = [DeskStats new];
        sw.swapUsed = 949e6; sw.swapTotal = 2e9;
        Say([[DeskModel swapTextForStats:sw] isEqualToString:@"949M"],
            @"交换 949M = %@", [DeskModel swapTextForStats:sw]);
        sw.swapUsed = 1.5e9;
        Say([[DeskModel swapTextForStats:sw] isEqualToString:@"1.5G"],
            @"交换到 G 也换单位 = %@", [DeskModel swapTextForStats:sw]);
        Say([[DeskModel swapTextForStats:noPower] isEqualToString:@"—"],
            @"交换取不到 → %@", [DeskModel swapTextForStats:noPower]);

        DeskStats *ld = [DeskStats new];
        ld.load1 = 2.07;
        Say([[DeskModel loadTextForStats:ld] isEqualToString:@"2.07"],
            @"1 分钟负载 = %@", [DeskModel loadTextForStats:ld]);
        Say([[DeskModel loadTextForStats:noPower] isEqualToString:@"—"],
            @"负载取不到 → %@", [DeskModel loadTextForStats:noPower]);

        // 表尾最长的组合：满电交流电 + 1.5G 交换 + 99.99 负载。
        // 视图用 9pt 标签 + 9.5pt 等宽值，这里按同一套字体量，超了就直接红。
        power.batteryPercent = 100; power.batteryOnAC = YES;
        power.batteryCharging = NO; power.batteryMinutes = 0;
        NSString *battText = [DeskModel batteryStatusTextForStats:power];
        NSFont *footFont = [NSFont systemFontOfSize:8.5 weight:NSFontWeightRegular];
        NSFont *footVal = [NSFont monospacedDigitSystemFontOfSize:9.0 weight:NSFontWeightMedium];
        CGFloat footL = [@"电池 " sizeWithAttributes:@{NSFontAttributeName: footFont}].width
                      + [battText sizeWithAttributes:@{NSFontAttributeName: footVal}].width;
        Say(footL <= kDeskPanelWidth - 2 * kPanelSidePadForVerify,
            @"表尾只显示电池文案，放得下：%.0f ≤ %.0fpt",
            footL, kDeskPanelWidth - 2 * kPanelSidePadForVerify);

        printf("\n本机真硬件实测\n");
        DeskSysMonitor *mon = [DeskSysMonitor new];
        DeskStats *warm = [mon sample];   // 差值型指标要先取基线
        Say(warm.cpu < 0 && warm.cpuWindow < 0,
            @"10s 窗口还没满时 CPU 是哨兵值（%.0f / %.0fs），屏上会印「—」", warm.cpu, warm.cpuWindow);
        // CPU 窗口要 10 秒历史才成立；多等 0.5 秒避开定时器抖动。
        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:kDeskCPUWindowSeconds + 0.5]];
        DeskStats *live = [mon sample];
        Say(live.cpu >= 0 && live.cpu <= 100, @"CPU 实测 %.1f%%", live.cpu);
        Say(fabs(live.cpuWindow - kDeskCPUWindowSeconds) < 0.01,
            @"CPU 读数覆盖窗口= %.2fs（断言 %.0fs）", live.cpuWindow, kDeskCPUWindowSeconds);
        Say(live.gpu >= 0 && live.gpu <= 100, @"GPU 实测 %.1f%%（IOAccelerator 键名在这台机器上取到了）", live.gpu);
        Say(live.memUsed > 0 && live.memUsed < live.memTotal, @"内存实测 %.1f / %.0f GiB（面板同款口径）",
            live.memUsed / (1024.0 * 1024.0 * 1024.0), live.memTotal / (1024.0 * 1024.0 * 1024.0));
        Say(live.diskFree > 0 && live.diskTotal > live.diskFree, @"磁盘实测 剩 %.0f / %.0f GB",
            live.diskFree / 1e9, live.diskTotal / 1e9);
        Say(live.diskIsSSD, @"介质转速判定为 SSD");
        Say(live.thermal >= 0 && live.thermal <= 3, @"热压力等级= %ld", (long)live.thermal);
        Say(live.cpuTemp > 20 && live.cpuTemp < 110, @"CPU 温度实测 %.1f°C（IOHID 传感器，零权限）", live.cpuTemp);
        Say(live.ssdTemp > 10 && live.ssdTemp < 100, @"SSD 温度实测 %.1f°C", live.ssdTemp);
        Say(live.netInterface.length > 0, @"默认路由网卡= %@（%@）", live.netInterface,
            live.netIsWiFi ? @"Wi-Fi" : @"有线");
        Say(live.netAddress.length > 0, @"IPv4= %@", live.netAddress);
        Say(live.diskRead >= 0 && live.diskWrite >= 0, @"读写速率实测 读 %.1f / 写 %.1f MB/s",
            live.diskRead / 1e6, live.diskWrite / 1e6);
        Say(live.netRecv >= 0 && live.netSend >= 0, @"网络速率实测 ↓%.1f / ↑%.1f KB/s（sysctl NET_RT_IFLIST2）",
            live.netRecv / 1e3, live.netSend / 1e3);
        Say(live.batteryPercent >= 0 && live.batteryPercent <= 100,
            @"电池实测 %.0f%%（%@）", live.batteryPercent, live.batteryOnAC ? @"交流电" : @"电池供电");
        Say([[DeskModel batteryStatusTextForStats:live] containsString:@"%"],
            @"表尾电池文案 = %@", [DeskModel batteryStatusTextForStats:live]);
        // 没有分配交换文件的机器总量就是 0（本机实测），这不是采集失败；
        // 只要求"读到的数自洽"，总量为 0 时界面印 "—" 是诚实的。
        Say(live.swapUsed >= 0 && live.swapTotal >= 0 && live.swapUsed <= live.swapTotal,
            @"交换实测 %@ / %@（总量可以为 0）", [DeskModel swapTextForStats:live],
            [NSString stringWithFormat:@"%.1fG", live.swapTotal / 1e9]);
        Say(live.load1 >= 0, @"1 分钟负载实测 %.2f", live.load1);

        printf("\n带系统区的面板尺寸\n");
        DeskModel *withStats = [DeskModel modelFromJSONFileAtPath:[root stringByAppendingPathComponent:@"mock/mock.json"]];
        [withStats updateStats:fake];
        NSSize sStats = [DeskPanelView sizeForModel:withStats];
        CGFloat expect4 = 2 * kPanelPadForVerify + 4 * kPanelRowHForVerify
                        + kPanelTilePadForVerify + kPanelFooterHForVerify;
        Say(fabs(sStats.height - expect4) < 0.01,
            @"4 行弹药库式卡片 = %.0fx%.0fpt（瓷砖 + 4 行 + 表尾，无抬头）",
            sStats.width, sStats.height);
        NSMutableArray<DeskStatRow *> *extra = [withStats.statRows mutableCopy];
        [extra addObject:[[DeskStatRow alloc] initWithLabel:@"额外" value:@"1" fraction:-1]];
        withStats.statRows = extra;
        Say(fabs([DeskPanelView sizeForModel:withStats].height - sStats.height - kPanelRowHForVerify) < 0.01,
            @"单列：再加一行就是 +%.0fpt", kPanelRowHForVerify);
        withStats.statRows = [withStats.statRows subarrayWithRange:NSMakeRange(0, 3)];
        Say(fabs([DeskPanelView sizeForModel:withStats].height
                 - (sStats.height - kPanelRowHForVerify)) < 0.01,
            @"3 行比 4 行矮一行（-%.0fpt）", kPanelRowHForVerify);

        printf("\n单列表格列宽不溢出（左标签 + 右读数）\n");
        NSFont *labFont = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
        NSFont *valFont = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
        withStats.statRows = [DeskModel statRowsForStats:fake];
        NSUInteger n = withStats.statRows.count;
        BOOL overflow = NO;
        for (NSUInteger i = 0; i < n; i++) {
            DeskStatRow *r = withStats.statRows[i];
            CGFloat cx, cw;
            [DeskPanelView rowGeometryForIndex:i count:n x:&cx width:&cw];
            CGFloat labelW = [r.label sizeWithAttributes:@{NSFontAttributeName: labFont}].width;
            CGFloat valueW = [r.value sizeWithAttributes:@{NSFontAttributeName: valFont}].width;
            // 状态词 pill 约 26pt，也要算进列宽
            CGFloat need = labelW + 26.0 + 6.0 + valueW + 8.0;
            if (need > cw) {
                overflow = YES;
                printf("    溢出：第 %lu 行 %s + 状态词 + %s = %.0fpt > 列宽 %.0fpt\n",
                       (unsigned long)i, r.label.UTF8String, r.value.UTF8String, need, cw);
            }
        }
        CGFloat cx0, cw0, cx7, cw7;
        [DeskPanelView rowGeometryForIndex:0 count:n x:&cx0 width:&cw0];
        [DeskPanelView rowGeometryForIndex:n - 1 count:n x:&cx7 width:&cw7];
        Say(!overflow, @"4 行的标签+数值都放进单列宽度（%.0fpt @x%.0f）", cw0, cx0);
        Say(cx0 == cx7 && cw0 == cw7, @"单列表格：4 行同一列，不是两列");
        Say(cx0 >= 0 && cx0 + cw0 <= kDeskPanelWidth, @"列在卡片内（右边 %.0f ≤ %.0f）",
            cx0 + cw0, kDeskPanelWidth);

        printf("\n磁盘主读数（剩多少 G）列宽\n");
        {
            NSFont *labF = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
            NSFont *smallF = [NSFont monospacedSystemFontOfSize:7.5 weight:NSFontWeightRegular];
            NSFont *freeF = [NSFont monospacedDigitSystemFontOfSize:13.5 weight:NSFontWeightSemibold];
            NSFont *unitF = [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightRegular];
            NSFont *gF = [NSFont monospacedDigitSystemFontOfSize:10.0 weight:NSFontWeightMedium];
            NSString *meta = [NSString stringWithFormat:@"%.0f%% 已用 · %.0fG  ",
                              fake.diskFraction * 100.0, fake.diskTotal / 1e9];
            NSMutableAttributedString *line = [NSMutableAttributedString new];
            [line appendAttributedString:[[NSAttributedString alloc] initWithString:meta
                attributes:@{NSFontAttributeName: smallF, NSForegroundColorAttributeName: [NSColor grayColor]}]];
            [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"剩 "
                attributes:@{NSFontAttributeName: unitF, NSForegroundColorAttributeName: [NSColor grayColor]}]];
            [line appendAttributedString:[[NSAttributedString alloc] initWithString:
                [NSString stringWithFormat:@"%.0f", fake.diskFree / 1e9]
                attributes:@{NSFontAttributeName: freeF, NSForegroundColorAttributeName: [NSColor whiteColor]}]];
            [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"G"
                attributes:@{NSFontAttributeName: gF, NSForegroundColorAttributeName: [NSColor whiteColor]}]];
            [line appendAttributedString:[[NSAttributedString alloc] initWithString:@" 可用"
                attributes:@{NSFontAttributeName: unitF, NSForegroundColorAttributeName: [NSColor grayColor]}]];
            CGFloat lineW = [line size].width;
            CGFloat labelW = [@"磁盘 SSD" sizeWithAttributes:@{NSFontAttributeName: labF}].width;
            NSFont *statusF = [NSFont systemFontOfSize:8.0 weight:NSFontWeightSemibold];
            CGFloat pillW = [@"正常" sizeWithAttributes:@{NSFontAttributeName: statusF}].width + 8.0;
            CGFloat pillEnd = 8.0 + labelW + 6.0 + pillW;
            Say(cw0 - lineW >= pillEnd + 4.0,
                @"磁盘主读数 %.0fpt + 标签/状态词不重叠（值剩 %.0fpt，词尾 %.0fpt）",
                lineW, cw0 - lineW, pillEnd);
        }

        printf("\n参数档位（正常 / 偏高 / 过高）\n");
        Say(DeskPanelTempLevel(47.5, 44) == DeskPanelLevelNormal
            && DeskPanelTempLevel(69.9, 44) == DeskPanelLevelNormal
            && DeskPanelTempLevel(70, 44) == DeskPanelLevelWarn
            && DeskPanelTempLevel(85, 44) == DeskPanelLevelWarn
            && DeskPanelTempLevel(85.1, 44) == DeskPanelLevelCritical
            && DeskPanelTempLevel(60, 90) == DeskPanelLevelCritical,
            @"温度档位：<70 正常 / 70–85 偏高 / >85 过高，取 CPU/SSD 更热的");
        Say(DeskPanelTempLevel(0, 0) == DeskPanelLevelUnknown
            && DeskPanelTempLevel(0, 44) == DeskPanelLevelNormal,
            @"温度：都没读到 = 未知；只有 SSD 也能判档");
        Say(fabs(DeskPanelTempFraction(60, 90) - 0.90) < 0.001
            && fabs(DeskPanelTempFraction(47.5, 44) - 0.475) < 0.001
            && DeskPanelTempFraction(0, 0) < 0,
            @"温度条也取更热的那个（和状态词同一个口径）");
        Say(DeskPanelDiskLevel(0.44) == DeskPanelLevelNormal
            && DeskPanelDiskLevel(0.80) == DeskPanelLevelWarn
            && DeskPanelDiskLevel(0.90) == DeskPanelLevelWarn
            && DeskPanelDiskLevel(0.91) == DeskPanelLevelCritical
            && DeskPanelDiskLevel(-1) == DeskPanelLevelUnknown,
            @"磁盘档位：<80%% 正常 / 80–90%% 偏高 / >90%% 将满");
        Say(DeskPanelBatteryLevel(100, YES, NO) == DeskPanelLevelNormal
            && DeskPanelBatteryLevel(15, NO, NO) == DeskPanelLevelWarn
            && DeskPanelBatteryLevel(8, NO, NO) == DeskPanelLevelCritical
            && DeskPanelBatteryLevel(100, NO, NO) == DeskPanelLevelNormal
            && DeskPanelBatteryLevel(15, NO, YES) == DeskPanelLevelNormal
            && DeskPanelBatteryLevel(-1, NO, NO) == DeskPanelLevelUnknown,
            @"电池：交流电/充电中正常；电池供电 >20 正常 / 10–20 偏低 / <10 低");
        Say(DeskPanelNetworkLevel(@"en8") == DeskPanelLevelNormal
            && DeskPanelNetworkLevel(nil) == DeskPanelLevelCritical
            && DeskPanelIPv4Level(@"192.168.31.23") == DeskPanelLevelNormal
            && DeskPanelIPv4Level(@"") == DeskPanelLevelCritical,
            @"网络 / IPv4 只有在线 / 离线");

        printf("\n卡片动效（电平条 / 采样钟 / 到点缓动）\n");
        // 换算函数是绘制和断言共用的，先把边界钉死
        Say(DeskPanelMeterWidth(-1, 232) == 0 && DeskPanelMeterWidth(0, 232) == 0,
            @"fraction<0 不画条（哨兵值不会印成负宽度）");
        Say(DeskPanelMeterWidth(1, 232) == 232 && DeskPanelMeterWidth(2, 232) == 232,
            @"fraction 超过 1 被夹到满格");
        Say(fabs(DeskPanelMeterWidth(0.5, 232) - 116) < 0.01, @"半格 = 116pt");
        Say(DeskPanelClockIndex(-1) == 0 && DeskPanelClockIndex(NAN) == 0
            && DeskPanelClockIndex(0.99) == 0 && DeskPanelClockIndex(1.0) == 1
            && DeskPanelClockIndex(9.9) == 9 && DeskPanelClockIndex(10.0) == 9
            && DeskPanelClockIndex(1e9) == 9,
            @"采样钟只走 0..9 格，10 秒封顶");

        DeskStats *animOldStats = [DeskStats new];
        animOldStats.cpuTemp = 30.0; animOldStats.ssdTemp = 28.0;
        animOldStats.diskFree = 400e9; animOldStats.diskTotal = 494e9; animOldStats.diskIsSSD = YES;
        animOldStats.netInterface = @"en8"; animOldStats.netAddress = @"192.168.31.23";
        animOldStats.netRecv = 0; animOldStats.netSend = 0;
        DeskModel *animOldModel = [DeskModel modelFromJSONFileAtPath:
            [root stringByAppendingPathComponent:@"mock/mock.json"]];
        [animOldModel updateStats:animOldStats];
        DeskModel *animNewModel = [DeskModel modelFromJSONFileAtPath:
            [root stringByAppendingPathComponent:@"mock/mock.json"]];
        [animNewModel updateStats:fake];

        NSSize animPanelSize = [DeskPanelView sizeForModel:animOldModel];
        NSWindow *animWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, animPanelSize.width, animPanelSize.height)
                                                        styleMask:NSWindowStyleMaskBorderless
                                                          backing:NSBackingStoreBuffered defer:NO];
        DeskPanelView *animPanel = [[DeskPanelView alloc] initWithFrame:NSMakeRect(0, 0, animPanelSize.width, animPanelSize.height)];
        animWin.contentView = animPanel;
        animPanel.model = animOldModel;
        Say(fabs([animPanel meterFractionForRow:0] - 0.30) < 0.001
            && fabs([animPanel tempColdFraction] - 0.28) < 0.001
            && fabs([animPanel meterFractionForRow:1] - (1.0 - 400e9 / 494e9)) < 0.001,
            @"第一帧条子直接到位：热 %.2f / 冷 %.2f / 磁盘 %.2f",
            [animPanel meterFractionForRow:0], [animPanel tempColdFraction],
            [animPanel meterFractionForRow:1]);
        Say(![animPanel needsRedraw], @"第一帧不播到点动效（建窗时不闪）");

        __block int animWakes = 0;
        animPanel.onNeedFrames = ^{ animWakes++; };
        animPanel.model = animNewModel;
        Say(animWakes == 1, @"到点叫回了一次动画表（animWakes=%d）", animWakes);
        Say([animPanel needsRedraw], @"到点后有缓动/闪烁要画");
        Say([animPanel clockIndex] == 0, @"采样钟到点回到第 0 格");
        [animPanel tick:0.15];
        double mid = [animPanel meterFractionForRow:0];
        Say(mid > 0.45 && mid < 0.58, @"0.15s 时热的温度计在中间：%.3f", mid);
        double coldMid = [animPanel tempColdFraction];
        Say(coldMid > 0.30 && coldMid < 0.33, @"0.15s 时冷的那支也在长：%.3f", coldMid);
        [animPanel tick:0.35];
        Say(fabs([animPanel meterFractionForRow:0] - 0.615) < 0.001
            && fabs([animPanel tempColdFraction] - 0.33) < 0.001,
            @"0.5s 两支都长到新值：热 %.3f / 冷 %.3f",
            [animPanel meterFractionForRow:0], [animPanel tempColdFraction]);
        [animPanel tick:0.3];
        Say(![animPanel needsRedraw], @"0.8s 后动效收尾，不再要求逐帧");

        // 0.4°C 的抖动不播条子动画，数字照常更新
        animPanel.model = animOldModel;
        [animPanel settle];
        DeskStats *jitterStats = [DeskStats new];
        jitterStats.cpuTemp = 30.4; jitterStats.ssdTemp = 28.0;
        jitterStats.diskFree = 400e9; jitterStats.diskTotal = 494e9; jitterStats.diskIsSSD = YES;
        jitterStats.netInterface = @"en8"; jitterStats.netAddress = @"192.168.31.23";
        jitterStats.netRecv = 0; jitterStats.netSend = 0;
        DeskModel *jitterModel = [DeskModel modelFromJSONFileAtPath:
            [root stringByAppendingPathComponent:@"mock/mock.json"]];
        [jitterModel updateStats:jitterStats];
        animPanel.model = jitterModel;
        Say(fabs([animPanel meterFractionForRow:0] - 0.304) < 0.001
            && fabs([animPanel tempColdFraction] - 0.28) < 0.001,
            @"0.4°C 抖动直接到位：热 %.3f / 冷 %.3f",
            [animPanel meterFractionForRow:0], [animPanel tempColdFraction]);
        [animPanel tick:0.35];
        Say(![animPanel needsRedraw], @"抖动不拖 60fps 表");

        // 69.9→70.0：数值只差 0.1°C，但跨进"偏高"档，条子直接到位、档位要闪一下
        DeskStats *nearStats = [DeskStats new];
        nearStats.cpuTemp = 69.9; nearStats.ssdTemp = 30.0;
        nearStats.diskFree = 400e9; nearStats.diskTotal = 494e9; nearStats.diskIsSSD = YES;
        nearStats.netInterface = @"en8"; nearStats.netAddress = @"192.168.31.23";
        nearStats.netRecv = 0; nearStats.netSend = 0;
        DeskModel *nearModel = [DeskModel modelFromJSONFileAtPath:
            [root stringByAppendingPathComponent:@"mock/mock.json"]];
        [nearModel updateStats:nearStats];
        animPanel.model = nearModel;
        [animPanel settle];

        DeskStats *crossStats = [DeskStats new];
        crossStats.cpuTemp = 70.0; crossStats.ssdTemp = 30.0;
        crossStats.diskFree = 400e9; crossStats.diskTotal = 494e9; crossStats.diskIsSSD = YES;
        crossStats.netInterface = @"en8"; crossStats.netAddress = @"192.168.31.23";
        crossStats.netRecv = 0; crossStats.netSend = 0;
        DeskModel *crossModel = [DeskModel modelFromJSONFileAtPath:
            [root stringByAppendingPathComponent:@"mock/mock.json"]];
        [crossModel updateStats:crossStats];
        animPanel.model = crossModel;
        Say(fabs([animPanel meterFractionForRow:0] - 0.700) < 0.001
            && fabs([animPanel tempColdFraction] - 0.30) < 0.001,
            @"69.9→70.0 跨档：两支温度计直接到位：热 %.3f / 冷 %.3f",
            [animPanel meterFractionForRow:0], [animPanel tempColdFraction]);
        Say([animPanel needsRedraw], @"跨档要闪一下，所以还要一帧");
        [animPanel tick:0.35];
        Say(![animPanel needsRedraw], @"档位闪完就停表");

        // 变形时整张是位图：不逐帧重烘，也不报 needsRedraw
        DeskCardView *animWarpedCard = [[DeskCardView alloc] initWithModel:animNewModel style:DeskStylePlate];
        DeskQuadOffsets cornerOff = DeskQuadOffsetsZero();
        cornerOff.tl = NSMakeSize(-20, -10);
        animWarpedCard.quadOffsets = cornerOff;
        [animWarpedCard tick:0.2];
        Say(![animWarpedCard needsRedraw], @"变形卡不逐帧重烘位图");

        NSString *panelSrc = [NSString stringWithContentsOfFile:
                              [root stringByAppendingPathComponent:@"panel_view.m"]
                                                        encoding:NSUTF8StringEncoding error:nil];
        NSString *mainSrc = [NSString stringWithContentsOfFile:
                             [root stringByAppendingPathComponent:@"main.m"]
                                                       encoding:NSUTF8StringEncoding error:nil];
        Say([panelSrc containsString:@"DeskPanelMeterWidth(frac, w)"],
            @"绘制路径真的用了电平条换算（不是只给断言看的函数）");
        Say([panelSrc rangeOfString:@"_sweepAge"].location == NSNotFound
            && [panelSrc rangeOfString:@"流量点"].location == NSNotFound,
            @"扫描带和流量点保持删除（不承载数据的动效不恢复）");
        Say([panelSrc containsString:@"DeskPanelTempLevel"] && [panelSrc containsString:@"PanelStatusColor"],
            @"卡片用了档位函数和状态色");
        Say([panelSrc containsString:@"PanelStatusText"] && [panelSrc containsString:@"底分三段"],
            @"状态词和三段条在绘制路径里");
        Say([panelSrc rangeOfString:@"_variant"].location == NSNotFound
            && [panelSrc rangeOfString:@"_scanAge"].location == NSNotFound,
            @"没选中的灯列扫描/条子光点已移除");
        Say([panelSrc containsString:@"drawDiskValueForStats"],
            @"磁盘行用混合字号：剩多少 G 是主读数");
        // 卡片 HUD/Bare 档曾经给整块设 5pt 全局柔影，7~10pt 小字被糊成一团。
        // 这里守住 2pt 紧影和提档后的字号/标签亮度，别被顺手改回柔影。
        Say([panelSrc containsString:@"sh.shadowBlurRadius = 2.0;"]
            && [panelSrc containsString:@"sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.90];"],
            @"卡片 HUD/Bare 小字用 2pt 紧影，不再用 5pt 全局柔影");
        Say([panelSrc rangeOfString:@"[sh set];"].location == NSNotFound
            && [panelSrc containsString:@"NSShadowAttributeName: gPanelTextShadow"],
            @"阴影只挂在文字属性上：药丸/电平条/瓷砖不再一起投影");
        Say([panelSrc containsString:@"NSDictionary *ta = @{NSFontAttributeName: font, NSForegroundColorAttributeName: color};"],
            @"药丸文字不叠阴影（药丸自带底，阴影会溢出成光圈）");
        Say([panelSrc containsString:@"systemFontOfSize:10.5 weight:NSFontWeightMedium"]
            && [panelSrc containsString:@"monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightSemibold"]
            && [panelSrc containsString:@"systemFontOfSize:7.5 weight:NSFontWeightSemibold"],
            @"卡片字号档位：标签 10.5 / 值 11.5 / 温度名 7.5");
        Say([panelSrc containsString:@"colorWithAlphaComponent:0.82"],
            @"卡片标签提到 paper 0.82，不再用低对比度的 muted");
        Say([panelSrc containsString:@"drawTempSensorsForStats"]
            && [panelSrc containsString:@"DrawTempGlyph"]
            && [panelSrc containsString:@"coldFrac:_coldNow"]
            && [panelSrc containsString:@"hasMeter && i != 0"]
            && [panelSrc containsString:@"const CGFloat mh = 3.5"],
            @"温度行是 CPU/SSD 两支温度计（都吃水位），底条只剩磁盘 3.5pt");
        Say([panelSrc containsString:@"timerWithTimeInterval:1.0"],
            @"采样钟是 1Hz 常驻表，不是 60fps");
        Say([mainSrc containsString:@"card.onNeedFrames = ^{ [weakSelf resumeWidgetTicking]; }"],
            @"到点动效能把停掉的动画表叫回来");
        Say([mainSrc containsString:@"DeskCardView *v = (DeskCardView *)w.contentView;"],
            @"卡片接进了 widgetTick 的逐帧循环");

        printf("\n四角变形\n");
        NSSize card = [DeskPanelView sizeForModel:oil];
        Say([DeskCardView windowSizeForModel:oil style:DeskStyleFeather warped:YES].width
                == card.width + kDeskQuadPad * 2,
            @"变形时窗口撑到 %.0f 宽（卡片 %.0f + 两侧 %.0f 余量）",
            [DeskCardView windowSizeForModel:oil style:DeskStyleFeather warped:YES].width,
            card.width, kDeskQuadPad);
        Say([DeskCardView windowSizeForModel:oil style:DeskStyleFeather warped:NO].width == card.width,
            @"没变形时窗口就是卡片大小");

        DeskQuadOffsets off = DeskQuadOffsetsZero();
        off.tl = NSMakeSize(-30, -20); off.tr = NSMakeSize(12, 8);
        NSString *round = DeskQuadOffsetsString(off);
        Say(NSEqualSizes(DeskQuadOffsetsFromString(round).tl, off.tl)
            && NSEqualSizes(DeskQuadOffsetsFromString(round).br, off.br),
            @"角点位移存取自洽：%@", round);
        DeskQuadOffsets wild = DeskQuadOffsetsFromString(@"9999,9999;0,0;0,0;0,0");
        DeskQuadOffsets clamped = DeskQuadOffsetsClamp(wild, card);
        NSRect canvasBox = NSMakeRect(0, 0, card.width + kDeskQuadPad * 2, card.height + kDeskQuadPad * 2);
        Say(NSPointInRect(DeskQuadFromOffsets(card, clamped).tl, canvasBox),
            @"往死里拖也会被夹回画布内（左上角 %.0f,%.0f）",
            DeskQuadFromOffsets(card, clamped).tl.x, DeskQuadFromOffsets(card, clamped).tl.y);
        DeskQuad q = DeskQuadFromOffsets(card, off);
        Say(DeskQuadHitTest(q, NSMakePoint(q.tl.x + 4, q.tl.y - 4), 12.0) == 0
            && DeskQuadHitTest(q, NSMakePoint(q.br.x - 4, q.br.y + 4), 12.0) == 2
            && DeskQuadHitTest(q, NSMakePoint(card.width / 2, card.height / 2), 12.0) < 0,
            @"命中测试认得出四个角，卡片中间不算角");

        printf("\n投影朝向（这里翻过一次车，必须有断言）\n");
        NSSize srcSize = NSMakeSize(200, 100);
        DeskMarkView *src = [[DeskMarkView alloc] initWithFrame:NSMakeRect(0, 0,
                                                                           srcSize.width, srcSize.height)];
        NSBitmapImageRep *mark = [src bitmapImageRepForCachingDisplayInRect:src.bounds];
        [src cacheDisplayInRect:src.bounds toBitmapImageRep:mark];
        NSSize cv = DeskQuadCanvasSize(srcSize);
        NSImage *ident = DeskQuadRender(mark, cv, DeskQuadFromOffsets(srcSize, DeskQuadOffsetsZero()));
        Say(ident != nil, @"恒等投影出图 %.0fx%.0f", ident.size.width, ident.size.height);
        DeskMarkView *dst = [[DeskMarkView alloc] initWithFrame:NSMakeRect(0, 0, cv.width, cv.height)];
        dst.image = ident;
        NSBitmapImageRep *identRep = [dst bitmapImageRepForCachingDisplayInRect:dst.bounds];
        [dst cacheDisplayInRect:dst.bounds toBitmapImageRep:identRep];
        double s = identRep.pixelsWide / cv.width;   // 位图可能是 2x 的，读像素要换算
        NSColor *atTopLeft = [identRep colorAtX:(NSInteger)((kDeskQuadPad + 5) * s)
                                             y:(NSInteger)((kDeskQuadPad + 5) * s)];
        NSColor *atBottomRight = [identRep colorAtX:(NSInteger)((kDeskQuadPad + 190) * s)
                                                 y:(NSInteger)((kDeskQuadPad + 90) * s)];
        Say(atTopLeft.redComponent > 0.8, @"白块还在左上（红 %.2f）—— 上下颠倒了就会跑到左下",
            atTopLeft.redComponent);
        Say(atBottomRight.redComponent < 0.2, @"右下仍是黑的，说明没被镜像");
        NSColor *outside = [identRep colorAtX:2 y:2];
        Say(outside.alphaComponent < 0.02, @"画布四角保持透明（alpha %.2f），不会露出矩形边",
            outside.alphaComponent);

        printf("\n拖角方向（拖哪个角就该动哪个角，读回坐标 y 朝下）\n");
        NSSize cs = NSMakeSize(200, 100);
        NSSize ccs = DeskQuadCanvasSize(cs);
        DeskCornerView *cornerView = [[DeskCornerView alloc] initWithFrame:NSMakeRect(0, 0, cs.width, cs.height)];
        NSBitmapImageRep *crep = [cornerView bitmapImageRepForCachingDisplayInRect:cornerView.bounds];
        [cornerView cacheDisplayInRect:cornerView.bounds toBitmapImageRep:crep];
        NSBitmapImageRep *(^Warp)(DeskQuadOffsets) = ^NSBitmapImageRep *(DeskQuadOffsets o) {
            NSImage *img = DeskQuadRender(crep, ccs, DeskQuadFromOffsets(cs, o));
            DeskCornerView *d = [[DeskCornerView alloc] initWithFrame:NSMakeRect(0, 0, ccs.width, ccs.height)];
            d.image = img;
            NSBitmapImageRep *r = [d bitmapImageRepForCachingDisplayInRect:d.bounds];
            [d cacheDisplayInRect:d.bounds toBitmapImageRep:r];
            return r;
        };
        NSBitmapImageRep *base = Warp(DeskQuadOffsetsZero());
        DeskQuadOffsets pushTL = DeskQuadOffsetsZero();
        pushTL.tl = NSMakeSize(30, 30);   // 把左上角往右上推（y 朝上 +30 = 往上）
        NSBitmapImageRep *moved = Warp(pushTL);
        NSPoint red0 = CentroidOf(base, IsRed), red1 = CentroidOf(moved, IsRed);
        NSPoint blue0 = CentroidOf(base, IsBlue), blue1 = CentroidOf(moved, IsBlue);
        Say(red1.y < red0.y - 10 && red1.x > red0.x + 5,
            @"推左上角 → 红块从 (%.0f,%.0f) 走到 (%.0f,%.0f)：往上往右，跟手",
            red0.x, red0.y, red1.x, red1.y);
        Say(fabs(blue1.x - blue0.x) < 12 && fabs(blue1.y - blue0.y) < 12,
            @"对角（右下蓝块）几乎不动：(%.0f,%.0f)→(%.0f,%.0f)",
            blue0.x, blue0.y, blue1.x, blue1.y);

        printf("\n按屏分档的位置存档\n");
        Say([[DeskPlaceStore keyWithDisplayID:12345 width:1512 height:982]
                isEqualToString:@"12345-1512x982"],
            @"键 = displayID-宽x高：%@",
            [DeskPlaceStore keyWithDisplayID:12345 width:1512 height:982]);
        DeskPlace dflt = [DeskPlaceStore defaultPlace];
        Say(dflt.corner == 2 && dflt.dx == 12 && dflt.dy == 12, @"通用兜底=左下 12/12");
        DeskPlaceStore *store = [DeskPlaceStore new];
        DeskPlace miss = [store placeForKey:@"999-1x1"];
        Say(miss.corner == 2 && miss.dx == 12, @"没见过的档位返回通用兜底，且 %lu 档（不写表）",
            (unsigned long)store.count);
        DeskPlace a = { 0, 360, 78 };
        [store setPlace:a forKey:@"1-1512x982"];
        [store setPlace:(DeskPlace){ 2, 12, 96 } forKey:@"1-1200x600"];
        DeskPlaceStore *reloaded = [[DeskPlaceStore alloc] initWithDictionary:store.dictionary];
        DeskPlace got = [reloaded placeForKey:@"1-1512x982"];
        Say(got.corner == 0 && got.dx == 360 && got.dy == 78,
            @"存取往返自洽：1512x982 档 = 角%ld 距 %.0f/%.0f", (long)got.corner, got.dx, got.dy);
        [reloaded setPlace:(DeskPlace){ 3, 777, 33 } forKey:@"1-1000x700"];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.003]];
        [reloaded setPlace:(DeskPlace){ 0, 360, 78 } forKey:@"1-1512x982"];   // 最近用过的同屏档
        DeskPlace fb = [reloaded placeForKey:@"1-1024x640" displayID:@1];
        Say(fb.corner == 0 && fb.dx == 360 && fb.dy == 78,
            @"没见过的同屏档位继承最近记录（1024x640 → 用 1512x982 的 角%ld 距%.0f/%.0f），不跳默认",
            (long)fb.corner, fb.dx, fb.dy);
        DeskPlace other = [reloaded placeForKey:@"2-3840x2160" displayID:@2];
        Say(other.corner == 2 && other.dx == 12, @"别的屏不串档，走通用兜底");
        DeskPlace noID = [reloaded placeForKey:@"9-1x1" displayID:nil];
        Say(noID.corner == 2, @"拿不到 displayID 时也不猜，走通用兜底");

        printf("\n三块出厂摆位（系统状态右上 / 活动监视器右下 / 弹药库左下）\n");
        DeskPlace panelDef = DeskPlaceDefaultForKind(DeskPlaceKindPanel);
        DeskPlace monitorDef = DeskPlaceDefaultForKind(DeskPlaceKindMonitor);
        DeskPlace vaultDef = DeskPlaceDefaultForKind(DeskPlaceKindVault);
        Say(panelDef.corner == 1 && panelDef.dx == 16 && panelDef.dy == 16,
            @"系统状态出厂锚点 = 右上 16/16");
        Say(monitorDef.corner == 3 && monitorDef.dx == 16 && monitorDef.dy == 16,
            @"活动监视器出厂锚点 = 右下 16/16");
        Say(vaultDef.corner == 2 && vaultDef.dx == 16 && vaultDef.dy == 16,
            @"弹药库出厂锚点 = 左下 16/16");
        DeskPlaceStore *vaultStore = [[DeskPlaceStore alloc] initWithDictionary:@{}
                                                                   defaultPlace:vaultDef];
        DeskPlace vaultMiss = [vaultStore placeForKey:@"999-1x1"];
        Say(vaultMiss.corner == 2 && vaultMiss.dx == 16 && vaultMiss.dy == 16,
            @"自定义兜底：弹药库没见过的档位走左下");
        DeskPlaceStore *badVault = [[DeskPlaceStore alloc]
            initWithDictionary:@{ @"x": @{ @"corner": @9, @"dx": @(-5), @"dy": @3 } }
                   defaultPlace:vaultDef];
        DeskPlace badFixed = [badVault placeForKey:@"x"];
        Say(badFixed.corner == 2 && badFixed.dx == 16 && badFixed.dy == 16,
            @"脏数据也回到组件自己的兜底，不串到别处");

        NSScreen *defScr = [NSScreen mainScreen];
        NSRect defVF = defScr.visibleFrame;
        NSRect (^defaultRect)(DeskPlace, NSSize) = ^NSRect(DeskPlace p, NSSize s) {
            CGFloat x = (p.corner == 1 || p.corner == 3) ? NSMaxX(defVF) - s.width - p.dx
                                                         : defVF.origin.x + p.dx;
            CGFloat y = (p.corner >= 2) ? defVF.origin.y + p.dy : NSMaxY(defVF) - s.height - p.dy;
            return NSMakeRect(x, y, s.width, s.height);
        };
        NSRect defPanel = defaultRect(panelDef, NSMakeSize(272, 200));
        NSRect defMon = defaultRect(monitorDef, NSMakeSize(560, 380));
        NSRect defVault = defaultRect(vaultDef, NSMakeSize(432, 294));
        Say(!NSIntersectsRect(defPanel, defMon) && !NSIntersectsRect(defPanel, defVault) &&
            !NSIntersectsRect(defMon, defVault),
            @"三块出厂摆位互不重叠");
        Say(NSContainsRect(defVF, defPanel) && NSContainsRect(defVF, defMon) &&
            NSContainsRect(defVF, defVault),
            @"三块出厂摆位都在可视区内");
        Say(fabs(NSMaxX(defVF) - NSMaxX(defPanel) - 16) < 0.1 &&
            fabs(NSMaxY(defVF) - NSMaxY(defPanel) - 16) < 0.1,
            @"系统状态贴右上，边距 16（x=%.0f y=%.0f）", NSMinX(defPanel), NSMinY(defPanel));
        Say(fabs(NSMaxX(defVF) - NSMaxX(defMon) - 16) < 0.1 &&
            fabs(NSMinY(defMon) - NSMinY(defVF) - 16) < 0.1,
            @"活动监视器贴右下，边距 16（x=%.0f y=%.0f）", NSMinX(defMon), NSMinY(defMon));
        Say(fabs(NSMinX(defVault) - NSMinX(defVF) - 16) < 0.1 &&
            fabs(NSMinY(defVault) - NSMinY(defVF) - 16) < 0.1,
            @"弹药库贴左下，边距 16（x=%.0f y=%.0f）", NSMinX(defVault), NSMinY(defVault));
        Say(NSMidX(defPanel) > NSMidX(defVF) && NSMidX(defMon) > NSMidX(defVF) &&
            NSMidX(defVault) < NSMidX(defVF),
            @"系统状态与活动监视器在右半屏，弹药库在左半屏");

        printf("\n分辨率变化：当前摆位搬到新档位\n");
        NSDictionary<NSString *, NSString *> *sigKeys =
            DeskPlaceKeysByDisplayFromSignature(@"1-1512x945+0+0|2-2560x1440+1512+0");
        Say([sigKeys[@"1"] isEqualToString:@"1-1512x945"] &&
            [sigKeys[@"2"] isEqualToString:@"2-2560x1440"],
            @"屏指纹解析 = %@", sigKeys);
        DeskPlaceStore *carry = [[DeskPlaceStore alloc] initWithDictionary:@{
            @"1-1512x945": @{ @"corner": @1, @"dx": @16, @"dy": @16 },
            @"1-1352x878": @{ @"corner": @2, @"dx": @84, @"dy": @42 },
            @"2-2560x1440": @{ @"corner": @0, @"dx": @10, @"dy": @10 }
        }];
        DeskPlace cur = [carry placeForKey:@"1-1512x945"];
        [carry setPlace:cur forKey:@"1-1352x845"];
        [carry setPlace:cur forKeysMatchingDisplayID:@"1"];
        DeskPlace carried = [carry placeForKey:@"1-1352x845"];
        DeskPlace oldCarried = [carry placeForKey:@"1-1352x878"];
        DeskPlace otherDisplay = [carry placeForKey:@"2-2560x1440"];
        Say(carried.corner == 1 && carried.dx == 16 && carried.dy == 16 &&
            oldCarried.corner == 1 && oldCarried.dx == 16 &&
            otherDisplay.corner == 0 && otherDisplay.dx == 10,
            @"新档位继承当前锚点，同屏旧档同步，别的屏不动（新 %ld/%.0f，旧 %ld/%.0f，别屏 %ld/%.0f）",
            (long)carried.corner, carried.dx, (long)oldCarried.corner, oldCarried.dx,
            (long)otherDisplay.corner, otherDisplay.dx);
        DeskPlaceStore *dirty = [[DeskPlaceStore alloc]
            initWithDictionary:@{ @"x": @{ @"corner": @9, @"dx": @(-5), @"dy": @3 } }];
        DeskPlace fixed = [dirty placeForKey:@"x"];
        Say(fixed.corner == 2 && fixed.dx == 12 && fixed.dy == 12,
            @"越界/负值的数据夹回通用兜底，不拿脏数去摆窗口");
        DeskPlaceStore *full = [DeskPlaceStore new];
        for (NSInteger i = 0; i < 13; i++) {
            [full setPlace:(DeskPlace){ 0, (CGFloat)i, 12 } forKey:[NSString stringWithFormat:@"k%ld", (long)i]];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
        }
        Say(full.count == 12 && [full placeForKey:@"k0"].dx == 12,
            @"超过 12 档淘汰最久没用的（k0 已被挤掉，剩 %lu 档）", (unsigned long)full.count);

        printf("\n拖动只进待保存，点保存才写档\n");
        DeskPlaceStore *pend = [[DeskPlaceStore alloc] initWithDictionary:
            @{ @"1-1512x945": @{ @"corner": @1, @"dx": @509, @"dy": @60 } }];
        [pend setPending:(DeskPlace){ 0, 120, 40 } forKey:@"1-1512x945"];
        Say(pend.pendingCount == 1 && pend.count == 1, @"拖动只挂待保存，存档还没动");
        DeskPlace stored = [pend placeForKey:@"1-1512x945"];
        Say(stored.dx == 509, @"查档看到的是已保存的旧值（%.0f），不是待保存的", stored.dx);
        Say([pend commitPending] && pend.pendingCount == 0, @"提交后清空待保存");
        DeskPlace after = [pend placeForKey:@"1-1512x945"];
        Say(after.corner == 0 && after.dx == 120 && after.dy == 40,
            @"提交后存档变成新值：角%ld 距%.0f/%.0f", (long)after.corner, after.dx, after.dy);
        Say(![pend commitPending], @"没有待保存时点保存不写档，也不谎报成功");
        [pend setPending:(DeskPlace){ 3, 1, 1 } forKey:@"2-1x1"];
        [pend discardPending];
        DeskPlace dropped = [pend placeForKey:@"2-1x1"];
        Say(pend.pendingCount == 0 && dropped.corner == 2 && dropped.dx == 12,
            @"放弃待保存后不会污染存档（回到通用兜底 角%ld 距%.0f/%.0f）",
            (long)dropped.corner, dropped.dx, dropped.dy);

        printf("\n变形态下换外观必须真的换（弹药库位图是从素材视图烘的）\n");
        // 进调角后整张组件来自 _flatSource 烘出来的 _flatRep。样式没同步到素材视图的话，
        // 不管选哪种外观，画面都停在素材自己的默认样式 —— 菜单点了像没反应。
        {
            NSArray *fake = @[FakeVaultItem(@"项目资料", 2.4e9, 1284, 0.13, 3600),
                              FakeVaultItem(@"设计稿", 843e6, 312, 0.71, 86400),
                              FakeVaultItem(@"临时", 0, 0, 0.05, 600)];
            DeskQuadOffsets vq = DeskQuadOffsetsZero();
            vq.tl = NSMakeSize(26, -20); vq.tr = NSMakeSize(-14, 8);
            vq.br = NSMakeSize(-6, 14);  vq.bl = NSMakeSize(20, -26);
            // 变形态的画布比组件本体大一圈，尺寸给错会把投影画到画布外
            NSRect canvas = NSMakeRect(0, 0, kVaultViewWidth + 120, kVaultViewHeight + 120);

            // 故意不开 editing：调角时四角手柄会叠在位图之上，而手柄样式跟着 gStyle 走，
            // 位图再怎么错，四张图照样不同——那样这条断言就废了。
            // 非零四角同样走 _flatRep 那条路径，正是要验的那条。
            DeskVaultView *(^mk)(DeskStyle) = ^DeskVaultView *(DeskStyle st) {
                DeskVaultView *v = [[DeskVaultView alloc] initWithItems:fake];
                [v setStandInScreenRect:NSMakeRect(150, 60, kVaultViewWidth, kVaultViewHeight)];
                v.style = st;               // 先定样式再变形，和菜单换外观的顺序一致
                v.quadOffsets = vq;        // 这一步才建出素材视图
                v.frame = canvas;
                return v;
            };

            // 底噪：同一份设置连渲两次。只差几个像素，所以不能拿"字节相同"当判据
            DeskVaultView *ref = mk(DeskStylePlate);
            DeskVaultView *ref2 = mk(DeskStylePlate);
            double noise = PixelDiffRatio(ref, ref2);
            Say(noise < 0.02, @"同设置两次渲染只差 %.2f%%（重烘抖动，当作底噪）", noise * 100.0);

            // 两两互比：任意两种外观都得画得不一样。样式没同步到素材视图的话，
            // 这四张全是同一张图，下面六条会一起塌成 0%
            NSMutableArray<DeskVaultView *> *all = [NSMutableArray array];
            for (NSInteger st = 0; st <= DeskStyleHUD; st++) [all addObject:mk((DeskStyle)st)];
            for (NSUInteger i = 0; i < all.count; i++) {
                for (NSUInteger j = i + 1; j < all.count; j++) {
                    double d = PixelDiffRatio(all[i], all[j]);
                    Say(d > 0.02, @"弹药库 变形态下风格 %lu 与 %lu 差 %.2f%%（外观真的切过去了）",
                        (unsigned long)i, (unsigned long)j, d * 100.0);
                }
            }
        }

        printf("\n每种风格都必须真的把文字挂上去（防止又出现'只剩底板没字'）\n");
        for (NSInteger st = 0; st <= DeskStyleHUD; st++) {
            DeskCardView *c = [[DeskCardView alloc] initWithModel:withStats style:(DeskStyle)st];
            Say([[c subviews] containsObject:c.panel], @"风格 %ld 的面板挂载正确", (long)st);
            DeskQuadOffsets wq = DeskQuadOffsetsZero();
            wq.tl = NSMakeSize(-24, -14); wq.tr = NSMakeSize(10, 10);
            DeskCardView *wc = [[DeskCardView alloc] initWithModel:withStats style:(DeskStyle)st
                                                            warped:YES];
            wc.quadOffsets = wq;
            long flatInk = InkOf(c), warpInk = InkOf(wc);
            Say(flatInk > 150, @"风格 %ld 画面上有 %ld 个实心像素（文字确实画出来了）", (long)st, flatInk);
            Say(warpInk > 150, @"风格 %ld 变形后仍有 %ld 个实心像素（投影路径没画空）", (long)st, warpInk);
        }

        printf("\n无边玻璃垫签到槽同款墨底：白壁纸上小字才读得出来\n");
        {
            // 2026-11-09：用户在白壁纸下截图报"活动监视器和卡片看不清"，要求照签到槽补底色。
            // 以前这里守的是"左侧留白必须全透明"；现在反过来守"墨底必须在"，
            // 免得以后又被当成一层可删的暗雾抹掉。
            DeskCardView *hud = [[DeskCardView alloc] initWithModel:withStats style:DeskStyleHUD];
            NSSize hs = [DeskCardView windowSizeForModel:withStats style:DeskStyleHUD warped:NO];
            hud.frame = NSMakeRect(0, 0, hs.width, hs.height);
            NSBitmapImageRep *rep = [hud bitmapImageRepForCachingDisplayInRect:hud.bounds];
            [hud cacheDisplayInRect:hud.bounds toBitmapImageRep:rep];
            NSInteger px = MAX(1, (NSInteger)(rep.pixelsWide * 0.02));
            NSInteger py = rep.pixelsHigh / 2;
            NSColor *bg = [rep colorAtX:px y:py];
            Say(bg.alphaComponent > 0.5,
                @"无边玻璃左侧留白 alpha=%.3f —— 墨底在（签到槽同款 0.56）",
                bg.alphaComponent);
        }

        printf("\n变形后文字仍要铺满卡片那一圈\n");
        // 宿主窗口一旦被外窗尺寸带跑，素材会变成和窗口一样大，卡片内容只占它左上角那一块，
        // 投影后文字就挤在框子的左上 80%×50% —— 底板是满的，所以必须量文字（用无底风格）。
        NSSize warpedCard = [DeskPanelView sizeForModel:withStats];
        DeskCardView *pc = [[DeskCardView alloc] initWithModel:withStats style:DeskStyleBare
                                                        warped:YES];
        DeskQuadOffsets tiny = DeskQuadOffsetsZero();
        tiny.tl = NSMakeSize(1, 0);   // 只差 1pt，逼它走投影路径又不至于真的改变包围盒
        pc.quadOffsets = tiny;
        NSWindow *host = [[NSWindow alloc]
            initWithContentRect:pc.frame styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered defer:NO];
        host.backgroundColor = [NSColor clearColor];
        host.opaque = NO;
        host.contentView = pc;
        [pc refreshSource];
        NSRect ink = OpaqueBox(pc, 0.5);
        CGFloat right = kDeskQuadPad + warpedCard.width, bottom = kDeskQuadPad + warpedCard.height;
        // 文字离框角本来就差一圈内边距，所以只要求"铺到附近"；素材被撑大时会差 70pt 以上
        Say(fabs(NSMaxX(ink) - right) < 30 && fabs(NSMaxY(ink) - bottom) < 30,
            @"文字铺到 (%.0f,%.0f)，卡片右下角是 (%.0f,%.0f)；素材被撑大会只到 (%.0f,%.0f) 附近",
            NSMaxX(ink), NSMaxY(ink), right, bottom,
            kDeskQuadPad + warpedCard.width * 0.8, kDeskQuadPad + warpedCard.height * 0.5);

        printf("\n壁纸采样背景\n");
        NSApplicationLoad();
        DeskBackdrop *bd = [DeskBackdrop shared];
        NSString *wp = [bd wallpaperPath];
        BOOL haveWP = wp.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:wp];
        if (!haveWP) {
            // 这台机器的壁纸提供方是 com.apple.wallpaper.choice.macintosh（程序化渲染）：
            // 系统只在应用壁纸那一刻落一张临时 jpg，随后删掉（实测 09:55 在、10:30 目录已空），
            // 取不到是环境事实、不是产品缺陷 —— 而且 Bare/Feather 档本来就不用壁纸底图。
            // 常年挂红的门等于没有门，所以这里显式跳过，并保留"有壁纸就严查"的分支。
            printf("  跳过 5 条壁纸断言：本机取不到壁纸文件（程序化渲染的 choice.macintosh）\n");
            printf("  能取到壁纸的机器上，这 5 条照常执行并严查\n");
        } else {
        Say(YES, @"解析到桌面壁纸：%@", wp.lastPathComponent);
        NSRect vf = [NSScreen screens].firstObject.visibleFrame;
        NSSize probe = [DeskPanelView sizeForModel:withStats];
        NSRect posA = NSMakeRect(vf.origin.x + 12, vf.origin.y + 12, probe.width, probe.height);      // 左下
        NSRect posB = NSMakeRect(NSMaxX(vf) - probe.width - 12, NSMaxY(vf) - probe.height - 12,
                                 probe.width, probe.height);                                          // 右上
        NSImage *bg = [bd imageForRect:posA dark:YES];
        Say(bg != nil, @"从壁纸采出背景图");
        Say(fabs(bg.size.width - probe.width) < 0.5 && fabs(bg.size.height - probe.height) < 0.5,
            @"背景图尺寸 %.0fx%.0f 与卡片一致", bg.size.width, bg.size.height);
        NSImage *near = [bd imageForRect:NSMakeRect(posA.origin.x + 6, posA.origin.y + 6,
                                                    probe.width, probe.height) dark:YES];
        Say(near == bg, @"位移在阈值内复用同一张（缓存只留一条，不重复做模糊）");
        NSImage *far = [bd imageForRect:posB dark:YES];
        Say(far != bg && far != nil, @"换到另一个位置会重新采样");
        double dA = MeanLuma(bg), dB = MeanLuma(far);
        double delta = MaxPixelDelta(bg, far);
        Say(delta > 0.05, @"两个位置采到的壁纸确实不同（最优点 RGB 差 %.3f，亮度 %.3f vs %.3f）",
            delta, dA, dB);
        }

        // 拖动窗口的位移算式
        // 出过事故：视图是翻转坐标（左上原点），屏幕坐标是左下原点，
        // 曾经把 view 坐标和屏幕坐标直接相减，组件在拖动第一帧就瞬移到按下点的坐标。
        // 这里钉死"光标走多远，窗口就走多远"这条不变量。
        printf("\n弹药库库根目录：不跟 App 残留走\n");
        // 2026-10-21 事故：清理工具按「应用残留」把 Application Support/DeskBoard 整目录删了，
        // 库文件一起没。根目录只能由 home 决定，不能再回到 Application Support。
        Say([DeskVaultRootForHome(@"/Users/x") isEqualToString:@"/Users/x/DeskBoard Vault"],
            @"库根目录 = home/DeskBoard Vault（%@）", DeskVaultRootForHome(@"/Users/x"));
        Say([DeskVaultRootForHome(@"/Users/x") rangeOfString:@"Application Support"].location == NSNotFound,
            @"库根目录不在 Application Support 下");

        printf("\n弹药库拖动位移\n");
        NSRect dStart = NSMakeRect(171, 344, 560, 380);
        NSPoint dMouse0 = NSMakePoint(396, 617);
        NSRect d0 = VaultDragFrame(dStart, dMouse0, dMouse0);
        NSRect d1 = VaultDragFrame(dStart, dMouse0, NSMakePoint(489, 633));
        NSRect d2 = VaultDragFrame(dStart, dMouse0, NSMakePoint(104, 201));
        printf("  窗口起点(171,344)，鼠标按下(396,617)\n");
        Say(NSEqualPoints(d0.origin, dStart.origin), @"光标没动，窗口也不动");
        Say(fabs((d1.origin.x - dStart.origin.x) - 93) < 0.5 &&
            fabs((d1.origin.y - dStart.origin.y) - 16) < 0.5,
            @"光标右移 93pt 上移 16pt，窗口平移 (%.0f,%.0f)",
            d1.origin.x - dStart.origin.x, d1.origin.y - dStart.origin.y);
        Say(fabs((d2.origin.x - dStart.origin.x) + 292) < 0.5 &&
            fabs((d2.origin.y - dStart.origin.y) + 416) < 0.5,
            @"往回拖按同样的增量算，不累积漂移 (%.0f,%.0f)",
            d2.origin.x - dStart.origin.x, d2.origin.y - dStart.origin.y);
        // 视图是翻转的：按下点(view 225,21) 在屏幕上比窗口原点低 (294-21)，
        // 拖动后它必须仍停在光标正下方 —— 这条正是当初写错的地方
        CGFloat pressX = 225, pressFromTop = 21;
        CGFloat px0 = dStart.origin.x + pressX;
        CGFloat py0 = dStart.origin.y + (294 - pressFromTop);
        CGFloat px1 = d1.origin.x + pressX;
        CGFloat py1 = d1.origin.y + (294 - pressFromTop);
        Say(fabs((px1 - px0) - 93) < 0.5 && fabs((py1 - py0) - 16) < 0.5,
            @"按下点跟着光标一起走，没有和光标错开");

        printf("\n弹药库动画循环：该停就停、该醒就醒（能耗回归）\n");
        // 实测过反面：这张表常开 + "空闲也每 3 帧重画"，DeskBoard 稳定 39% CPU、
        // 活动监视器能耗影响 88.5。下面四条守住"没得动就一帧都不画"这件事。
        NSArray *evItems = @[FakeVaultItem(@"能耗探针", 1.2e9, 42, 0.31, 0),
                              FakeVaultItem(@"两个卡片", 8.0e8, 17, 0.62, 0)];
        DeskVaultView *ev = [[DeskVaultView alloc] initWithItems:evItems];
        [ev setStandInScreenRect:NSMakeRect(150, 60, kVaultViewWidth, kVaultViewHeight)];
        ev.style = DeskStylePlate;
        __block int wakes = 0;
        ev.onNeedFrames = ^{ wakes++; };
        Say([ev needsRedraw], @"刚入库的卡片动画在跑，此时不许停表");
        Say([ev currentSweep] > -1.0, @"有动画在跑时扫描带才活（它绝不能再单独把组件吊着）");
        int settled = -1;
        for (int i = 1; i <= 600; i++) { [ev tick:1.0 / 60.0]; if (![ev needsRedraw]) { settled = i; break; } }
        Say(settled > 0 && settled <= 90, @"入库缓动在 %d 帧（%.2fs）内收敛到终态", settled, settled / 60.0);
        int afterSettle = wakes;
        for (int i = 0; i < 120; i++) [ev tick:1.0 / 60.0];   // 静置两秒
        Say(![ev needsRedraw] && [ev currentSweep] < -0.5,
            @"静置 2 秒后仍然一帧都不欠：扫描带已关、没有东西在动");
        Say(wakes == afterSettle, @"静置期间没人自己把表叫回来（唤醒 %d→%d 次）", afterSettle, wakes);
        [ev applyPreviewHoverCard:0 dock:-1 dropHot:0.5 dropCount:0 scroll:0];
        Say([ev needsRedraw] && [ev currentSweep] > -1.0, @"鼠标一悬停，动画立刻重新有活干");

        printf("\n弹药库滚动方向：和原生 NSScrollView 同向\n");
        // 组件的 _scroll 扮演的就是原生可视区 origin.y 的角色（翻转坐标，越大越往文档下方），
        // 原生是 origin.y -= scrollingDeltaY。写反一次，鼠标和触控板会同时反掉。
        NSMutableArray<DeskVaultItem *> *scrollItems = [NSMutableArray array];
        for (int i = 0; i < 12; i++) {
            DeskVaultItem *it = [[DeskVaultItem alloc] init];
            it.name = [NSString stringWithFormat:@"滚动探针%02d", i];
            it.kind = VaultItemFolder;
            [scrollItems addObject:it];
        }
        DeskVaultView *sv = [[DeskVaultView alloc] initWithItems:scrollItems];
        [sv setStandInScreenRect:NSMakeRect(0, 0, kVaultViewWidth, kVaultViewHeight)];
        CGFloat midScroll = [sv maxScroll] / 2.0;
        Say(midScroll > 0, @"12 个库位时 maxScroll=%.0f，从中段起步才测得出正负两个方向", midScroll);

        // expect 是 _scroll（即原生 origin.y）该变的量：原生做减法，所以它恒等于 -增量
        struct { NSString *tag; CGFloat dy; BOOL precise; CGFloat expect; } scrollCases[] = {
            { @"触控板", 10.0, YES, -10.0 },
            { @"触控板", -10.0, YES, 10.0 },
            { @"滚轮一格", 1.0, NO, 0 },   // 一格走的是"手感放大"，只查方向
            { @"滚轮一格", -1.0, NO, 0 },
        };
        for (size_t i = 0; i < sizeof(scrollCases) / sizeof(scrollCases[0]); i++) {
            NSEvent *e = ScrollProbeEvent(scrollCases[i].dy, scrollCases[i].precise);
            if (!e) { Say(NO, @"%@：造不出滚动事件", scrollCases[i].tag); continue; }
            [sv applyPreviewHoverCard:-1 dock:-1 dropHot:0 dropCount:0 scroll:midScroll];
            NSRect before = [sv cardRectAtIndex:0 in:sv.bounds];
            [sv scrollWheel:e];
            CGFloat moved = [[sv valueForKey:@"_scrollTarget"] floatValue] - midScroll;
            for (int k = 0; k < 200; k++) [sv tick:1.0 / 60.0];   // 等缓动收敛再量像素位移
            NSRect after = [sv cardRectAtIndex:0 in:sv.bounds];
            CGFloat cardShift = after.origin.y - before.origin.y;   // 翻转坐标里正 = 屏幕上往下
            CGFloat dy = e.scrollingDeltaY;
            Say(cardShift * dy > 0,
                @"%@：scrollingDeltaY=%+.0f 时卡片往%@移了 %.1fpt（原生同向）",
                scrollCases[i].tag, dy, cardShift > 0 ? @"下" : @"上", fabs(cardShift));
            Say(moved != 0, @"%@：偏移确实变了 %+.1f，没被夹死也没原地不动",
                scrollCases[i].tag, moved);
            if (scrollCases[i].expect != 0)
                Say(fabs(moved - scrollCases[i].expect) < 0.01,
                    @"触控板精确增量按 pt 原样走（%+.1f → %+.1f）", scrollCases[i].expect, moved);
            CGFloat s = [[sv valueForKey:@"_scrollTarget"] floatValue];
            Say(s >= 0 && s <= [sv maxScroll], @"偏移仍在 [0, %.0f] 内，没滚出边界", [sv maxScroll]);
        }

        printf("\n活动监视器：几何、排序与刻度换算\n");
        DeskMonitorView *mv = [[DeskMonitorView alloc] initWithRows:@[]];
        [mv setStandInScreenRect:NSMakeRect(150, 60, kMonitorViewWidth, kMonitorViewHeight)];
        Say(NSWidth(mv.bounds) == kMonitorViewWidth && NSHeight(mv.bounds) == kMonitorViewHeight,
            @"组件本体 %.0fx%.0fpt（和定稿尺寸一致）", kMonitorViewWidth, kMonitorViewHeight);
        // 四榜拼起来必须正好铺满内区：不许重叠，也不许留出空带（"铺满"是硬要求）
        NSRect quads[4], u = NSZeroRect;
        BOOL overlap = NO, escaped = NO;
        for (int m = 0; m < 4; m++) {
            quads[m] = MonitorQuadFor(mv, m);
            for (int k = 0; k < m; k++) {
                NSRect both = NSIntersectionRect(quads[k], quads[m]);
                if (NSWidth(both) > 1.0 && NSHeight(both) > 1.0) overlap = YES;
            }
            u = NSUnionRect(u, quads[m]);
        }
        NSRect inner = MonitorGridInnerFor(mv.bounds);
        Say(!overlap, @"四个象限互不重叠");
        Say(fabs(NSMinX(u) - NSMinX(inner)) <= 1.0 && fabs(NSMaxX(u) - NSMaxX(inner)) <= 1.0,
            @"横向铺满内区（象限 %.0f..%.0f，内区 %.0f..%.0f）",
            NSMinX(u), NSMaxX(u), NSMinX(inner), NSMaxX(inner));
        Say(fabs(NSMinY(u) - NSMinY(inner)) <= 1.0 && fabs(NSMaxY(u) - NSMaxY(inner)) <= 1.0,
            @"纵向铺满内区且不越界（象限 %.0f..%.0f，内区 %.0f..%.0f）",
            NSMinY(u), NSMaxY(u), NSMinY(inner), NSMaxY(inner));
        // 每一行都得待在自己那一格里：越界就是当初"第四行画到下一榜头上"那个 bug
        for (int m = 0; m < 4; m++) {
            NSRect q = MonitorQuadFor(mv, m);
            for (int r = 0; r < kMonitorRowsPerQuadrant; r++) {
                NSRect row = [mv rowRectAtMetric:m row:r in:mv.bounds];
                if (!NSContainsRect(q, NSInsetRect(row, -4, -2))) {
                    escaped = YES;
                    Say(NO, @"榜 %d 第 %d 行越出格子（行 y=%.0f..%.0f，格子 y=%.0f..%.0f）",
                        m, r, NSMinY(row), NSMaxY(row), NSMinY(q), NSMaxY(q));
                }
            }
        }
        Say(!escaped, @"16 行全部落在各自格子里");
        // "和卡片一样"的落点：指标条是贴在文字下面的一根 2pt 整行宽细条（卡片面板 kBarH=2.0），
        // 不是横在字旁边的一段胶囊 —— 用户说的"字体下面有阴影"量的就是这个元素。
        BOOL barBad = NO, colBad = NO;
        for (int m = 0; m < 4; m++) {
            for (int r = 0; r < kMonitorRowsPerQuadrant; r++) {
                NSRect row = [mv rowRectAtMetric:m row:r in:mv.bounds];
                NSRect bar = [DeskMonitorView barRectInRow:row];
                CGFloat histRight = NSMaxX(row);
                CGFloat nowRight = histRight - kMonitorHistWForVerify - kMonitorColGapForVerify;
                CGFloat barW = NSWidth(row) - kMonitorHistWForVerify - kMonitorColGapForVerify;
                if (fabs(NSHeight(bar) - 2.5) > 0.001 || fabs(NSWidth(bar) - barW) > 0.001 ||
                    !NSContainsRect(row, bar)) barBad = YES;
                if (NSMinY(bar) < NSMinY(row) + 17.0) barBad = YES;      // 文字带 10.5pt + 12h 底 18pt
                if (NSMaxX(bar) > nowRight + 0.01) barBad = YES;         // 不许拱进 12h 列
                if (nowRight <= NSMinX(row) + 30.0 || histRight <= nowRight + 20.0) colBad = YES;
                if (fabs(NSWidth(row) - 239.0) > 1.0) colBad = YES;      // 560 版四宫格行宽 ≈ 239
            }
        }
        Say(!barBad, @"16 行都只有一根行底 2.5pt 条，且不压 10.5pt 文字、不拱进 12h 列");
        Say(!colBad, @"三列几何成立：名字 / 现在 64pt / 12h 64pt（行宽 %.0f）",
            NSWidth([mv rowRectAtMetric:0 row:0 in:mv.bounds]));
        {
            // 用户原话："uu 显示 20.2 但总 cpu 显示 11.1，总数还没单个进程大"。
            // 根因是两套分母：sysmon 的 s.cpu 除以 total（整机 %），procs 的 p.cpu 除以 wall
            // （单核 %）。现在把榜头换算到同一把尺，这条断言钉住"总 ≥ 任意一行"由构造成立。
            NSMutableArray<DeskProc *> *sc = [NSMutableArray array];
            for (int i = 0; i < 8; i++) {
                DeskProc *p = [DeskProc new];
                p.pid = (pid_t)(5000 + i); p.name = [NSString stringWithFormat:@"s%d", i];
                p.cpu = 20.2 - i; p.mem = 2e8; p.energy = 30.0 - i * 2; p.wakeups = 5; p.sockets = 3;
                [sc addObject:p];
            }
            mv.totalCPU = 11.1;                       // 整机口径，和卡片面板同一个数
            [mv updateRows:sc];
            NSString *agg = [mv aggregateTextForMetric:DeskMonitorMetricCPU];
            // CPU 整块改成「占整机」的口径（满值 100%）：用户原话是
            // "总的为什么会显示 173%，CPU 总量不是应该 100% 吗"。
            // 之前榜头是"各核加起来"（12 核满载 1200%），人根本读不出那是上限。
            NSInteger cores = (NSInteger)[NSProcessInfo.processInfo activeProcessorCount];
            if (cores < 1) cores = 1;
            double aggV = [agg doubleValue];          // "整机 11%" 这种串 doubleValue 取不到数
            NSString *aggNum = [agg substringFromIndex:agg.length >= 3 ? 3 : 0];  // 跳过「整机 」
            aggV = [aggNum doubleValue];
            Say([agg hasPrefix:@"整机"], @"CPU 榜头写明分母：「%@」（整机口径，满值 100%%）", agg);
            Say(aggV >= 0 && aggV <= 100, @"CPU 榜头「%@」落在 0~100%% 之间，不再是 12 核加总的 1200%%", agg);
            Say(fabs(aggV - 11.1) <= 0.5, @"CPU 榜头就是整机负载本身（11.1%% → %@）", agg);
            Say([[mv metricLabelForVerify:DeskMonitorMetricCPU]
                    isEqualToString:[NSString stringWithFormat:@"CPU %.0fs", kDeskCPUWindowSeconds]],
                @"CPU 象限标题标出窗口= %@", [mv metricLabelForVerify:DeskMonitorMetricCPU]);
            Say([[mv metricLabelForVerify:DeskMonitorMetricMemory] isEqualToString:@"内存 GiB"],
                @"内存象限标题标出进制= %@", [mv metricLabelForVerify:DeskMonitorMetricMemory]);
            Say([[mv metricLabelForVerify:DeskMonitorMetricEnergy] isEqualToString:@"能耗"],
                @"能耗象限不再标「估」= %@", [mv metricLabelForVerify:DeskMonitorMetricEnergy]);
            {   // 被应用窗口完全盖住时：数据照收，但不把 60fps 帧表叫起来（不可见的重画纯属白烧）
                __block NSInteger frames = 0;
                void (^saved)(void) = mv.onNeedFrames;
                mv.onNeedFrames = ^{ frames++; };
                mv.drawSuppressed = YES;
                [mv updateRows:sc];
                Say(frames == 0, @"被盖住时 updateRows 收数据但不叫帧表（frames=%ld）", (long)frames);
                mv.drawSuppressed = NO;
                [mv updateRows:sc];
                Say(frames > 0, @"露出来后恢复绘制（frames=%ld）", (long)frames);
                mv.onNeedFrames = saved;
            }
            mv.totalMemUsed = 12.0 * 1024.0 * 1024.0 * 1024.0;
            mv.totalMemPhys = 24.0 * 1024.0 * 1024.0 * 1024.0;
            NSString *memAgg = [mv aggregateTextForMetric:DeskMonitorMetricMemory];
            Say([memAgg isEqualToString:@"12.0/24 GiB"],
                @"内存榜头同用 1024³ 的 GiB 并写明单位= %@", memAgg);
            // 榜头和每行现在同一把尺（占整机），所以"总 ≥ 任意一行"必须成立
            NSString *cpuRow0 = [mv valueTextFor:sc[0] metric:DeskMonitorMetricCPU];
            double row0 = [cpuRow0 doubleValue];
            Say(aggV >= row0, @"榜头「%@」≥ 榜内最大行「%@」（同一把尺：占整机）", agg, cpuRow0);
            // 能耗榜头不能再是自造单位的绝对和，而且分母必须写在脸上
            NSString *ea = [mv aggregateTextForMetric:DeskMonitorMetricEnergy];
            Say([ea hasPrefix:@"前4名占全部"], @"能耗榜头改成比例读数并写明分母：「%@」，不再印 191 那种没单位的数", ea);
            // "前4名占全部 59%"：前 7 个 UTF-16 单元是「前」「4」「名」「占」「全」「部」「空格」，跳过它们再取数
            double pct = [[ea substringFromIndex:7] doubleValue];
            double total = 0; for (DeskProc *p in sc) total += p.energy;
            double top4 = 0; for (int i = 0; i < 4; i++) top4 += sc[i].energy;
            Say(fabs(pct - top4 / total * 100.0) <= 1.0,
                @"前4名占全部 %.0f%% 与独立算出的 %.1f%% 对得上", pct, top4 / total * 100.0);
            // 网络榜：榜头是系统收发速率，每行是进程收发速率；连接数不再是主值。
            for (int i = 0; i < 8; i++) {
                DeskProc *p = sc[i];
                p.netInRate = 1.8e6 - i * 0.15e6;
                p.netOutRate = 0.9e6 - i * 0.05e6;
            }
            mv.totalNetRecv = 2.5e6;
            mv.totalNetSend = 1.2e6;
            [mv updateRows:sc];
            NSString *na = [mv aggregateTextForMetric:DeskMonitorMetricNetwork];
            Say([na isEqualToString:@"系统 ↓2.5M ↑1.2M"],
                @"网络榜头 = 系统收发速率「%@」", na);
            NSString *netRow = [mv valueTextFor:sc[0] metric:DeskMonitorMetricNetwork];
            Say([netRow isEqualToString:@"↓1.8M ↑900K"],
                @"网络每行 = 该进程收发速率「%@」", netRow);
            Say([mv pidAtMetric:DeskMonitorMetricNetwork row:0] == sc[0].pid,
                @"网络榜按流量排名：第一行是收发最大的进程");
            DeskProc *idle = [DeskProc new];
            idle.pid = 7777; idle.name = @"idle"; idle.netInRate = 0; idle.netOutRate = 0;
            Say([[mv valueTextFor:idle metric:DeskMonitorMetricNetwork] isEqualToString:@"↓0K ↑0K"],
                @"0 流量也带单位，不印裸 0");
            DeskProc *nul = [DeskProc new];
            nul.pid = 7778; nul.name = @"nul"; nul.netInRate = -1; nul.netOutRate = -1;
            Say([[mv valueTextFor:nul metric:DeskMonitorMetricNetwork] isEqualToString:@"—"],
                @"流量还没基线时印「—」，不印负速率");
            mv.totalNetRecv = -1; mv.totalNetSend = -1;
            Say([[mv aggregateTextForMetric:DeskMonitorMetricNetwork] isEqualToString:@"—"],
                @"系统流量未知时榜头印「—」");
            mv.totalNetRecv = 2.5e6; mv.totalNetSend = 1.2e6;
            // 榜内每行也得自带单位、而且和榜头同一把尺：CPU 行印的是占整机的百分比
            // （单核百分点 ÷ 核数），这样"总数 ≤ 100%"在每一行都成立
            NSString *cpuRow = cpuRow0;
            Say([cpuRow hasSuffix:@"%"], @"CPU 每行「%@」带 %%", cpuRow);
            Say(fabs(row0 - 20.2 / (double)cores) <= 0.06,
                @"CPU 每行「%@」= 单核 20.2 ÷ %ld 核 = 占整机 %.2f%%", cpuRow, (long)cores, 20.2 / (double)cores);
            Say(row0 <= 100.0, @"CPU 每行也不会超过 100%%（占整机，满值 100%%）");
            // 悬停浮层的摆位：三条规矩各有断言
            // ① 放在鼠标左边（不挡光标）；② 左边放不下才改放右边；
            // ③ 整块落在 visibleFrame 里 —— 菜单栏不在 visibleFrame 内，所以它压不到菜单栏。
            //    之前是拿行矩形换算的：行矩形已被 convertRect:toView:nil 转成窗口坐标（下原点），
            //    代码又按视图坐标（上原点）减了一次，y 轴倒了两次，位置跑到屏幕顶边外，
            //    macOS 只能把窗夹回屏幕顶端 —— 浮层于是压在菜单栏上（用户报的就是这个）。
            {
                NSRect screen = NSMakeRect(0, 0, 1512, 945);
                NSRect vf = NSMakeRect(0, 90, 1512, 825);   // visibleFrame：上沿不含菜单栏
                NSSize bs = kDeskMonitorHoverSize;
                NSPoint mid = NSMakePoint(900, 500);
                NSRect r = DeskHoverBubbleRect(mid, bs, vf);
                Say(NSMaxX(r) <= mid.x, @"浮层在鼠标左边：右边 %.0f ≤ 鼠标 x %.0f",
                    NSMaxX(r), mid.x);
                Say(NSMaxY(r) <= NSMaxY(vf), @"浮层不越过可视区上沿（%.0f ≤ %.0f），压不到菜单栏",
                    NSMaxY(r), NSMaxY(vf));
                Say(NSMinY(r) >= NSMinY(vf) && NSMinX(r) >= NSMinX(vf) && NSMaxX(r) <= NSMaxX(vf),
                    @"浮层整块落在可视区里 (%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y,
                    r.size.width, r.size.height);
                // 鼠标贴着屏幕左边缘时，左边放不下 → 必须改放右边，不能跑到屏幕外
                NSPoint edge = NSMakePoint(30, 500);
                NSRect r2 = DeskHoverBubbleRect(edge, bs, vf);
                Say(NSMinX(r2) >= NSMinX(vf) && NSMaxX(r2) <= NSMaxX(vf),
                    @"鼠标在屏幕左边缘时浮层仍留在可视区内 (x=%.0f)", NSMinX(r2));
                // 鼠标贴着顶部时，浮层整体下移，不越到菜单栏上
                NSPoint top = NSMakePoint(900, NSMaxY(vf) - 10);
                NSRect r3 = DeskHoverBubbleRect(top, bs, vf);
                Say(NSMaxY(r3) <= NSMaxY(vf) && NSMinY(r3) >= NSMinY(vf),
                    @"鼠标在可视区顶端时浮层被压回区内 (y=%.0f 高 %.0f)", NSMinY(r3), r3.size.height);
                (void)screen;
            }
            // 能耗每行原来就是那个 "191" —— 自造单位的裸分。现在是占比，且分母和榜头同一个
            NSString *enRow = [mv valueTextFor:sc[0] metric:DeskMonitorMetricEnergy];
            Say([enRow hasSuffix:@"%"] && [enRow doubleValue] <= 100.0,
                @"能耗每行「%@」是占比，不再印没单位的裸分", enRow);
            Say(fabs(mv.energyShareTotal - total) < 0.001,
                @"分母只有一套：energyShareTotal %.1f == 独立求和 %.1f", mv.energyShareTotal, total);
            Say(fabs([enRow doubleValue] - sc[0].energy / mv.energyShareTotal * 100.0) <= 1.0,
                @"每行「%@」= 这一行的分 / 全部分之和", enRow);
            {   // 全是 0 的那一拍不许把 nan% 印上屏
                NSMutableArray<DeskProc *> *zx = [NSMutableArray array];
                for (int i = 0; i < 3; i++) {
                    DeskProc *p = [DeskProc new];
                    p.pid = (pid_t)(6000 + i); p.name = [NSString stringWithFormat:@"z%d", i];
                    p.cpu = 0; p.mem = 1; p.energy = 0; p.wakeups = 0; p.sockets = 0;
                    [zx addObject:p];
                }
                [mv updateRows:zx];
                NSString *zz = [mv valueTextFor:zx[0] metric:DeskMonitorMetricEnergy];
                Say([zz hasSuffix:@"%"] && ![zz.lowercaseString containsString:@"nan"]
                    && ![zz.lowercaseString containsString:@"inf"], @"能耗全 0 时读数「%@」不是 nan", zz);
                [mv updateRows:sc];   // 恢复现场
            }
            {   // 哨兵值不许印成负数：procs.m 里"这一拍还没有上一拍可比"用 -1 表示，
                // 照着印百分比会得到 "-1.0%"（实测气泡里就出现过）。未知就是未知，印"—"。
                DeskProc *sn = [DeskProc new];
                sn.pid = 7501; sn.name = @"sn"; sn.cpu = -1; sn.energy = -1;
                sn.wakeups = -1; sn.sockets = 0;
                NSString *sc1 = [mv valueTextFor:sn metric:DeskMonitorMetricCPU];
                NSString *sc2 = [mv valueTextFor:sn metric:DeskMonitorMetricEnergy];
                Say([sc1 isEqualToString:@"—"], @"CPU 哨兵(-1)印「%@」而不是负的百分比", sc1);
                Say([sc2 isEqualToString:@"—"], @"能耗哨兵(-1)印「%@」而不是假零", sc2);
            }
            {   // 同一榜一种进制：行内内存和榜头都用 1024³ 的 GiB。
                DeskProc *mp = [DeskProc new];
                mp.pid = 7001; mp.name = @"mem"; mp.cpu = 0; mp.energy = 0;
                mp.wakeups = 0; mp.sockets = 0;
                mp.mem = 1.5 * 1073741824.0;
                NSString *big = [mv valueTextFor:mp metric:DeskMonitorMetricMemory];
                Say([big isEqualToString:@"1.5G"],
                    @"1.5 GiB →「%@」（GiB 制，和榜头同一进制）", big);
                mp.mem = 926 * 1048576.0;
                NSString *small = [mv valueTextFor:mp metric:DeskMonitorMetricMemory];
                Say([small isEqualToString:@"926M"], @"926 MiB →「%@」", small);
                mp.mem = 512 * 1024.0;
                NSString *tiny = [mv valueTextFor:mp metric:DeskMonitorMetricMemory];
                Say([tiny isEqualToString:@"512K"], @"512 KiB →「%@」（不印假零）", tiny);
            }
        }

        printf("\n活动监视器：简略模式（272×142，每榜 1 名）\n");
        {
            DeskMonitorView *cv = [[DeskMonitorView alloc] initWithRows:@[]];
            cv.compact = YES;
            Say(NSWidth(cv.bounds) == kMonitorViewCompactWidth
                && NSHeight(cv.bounds) == kMonitorViewCompactHeight,
                @"简略本体 %.0fx%.0fpt，和系统状态卡同尺寸",
                kMonitorViewCompactWidth, kMonitorViewCompactHeight);
            Say([DeskMonitorView cardSizeCompact:YES].width == kMonitorViewCompactWidth
                && [DeskMonitorView cardSizeCompact:NO].width == kMonitorViewWidth,
                @"尺寸口按模式返回：简略 %.0f / 完整 %.0f",
                [DeskMonitorView cardSizeCompact:YES].width,
                [DeskMonitorView cardSizeCompact:NO].width);

            NSRect ct[4], cu = NSZeroRect;
            BOOL cOverlap = NO, cGeoBad = NO;
            for (int m = 0; m < 4; m++) {
                ct[m] = [cv tileRectAtMetric:m in:cv.bounds];
                for (int k = 0; k < m; k++) {
                    NSRect both = NSIntersectionRect(ct[k], ct[m]);
                    if (NSWidth(both) > 1.0 && NSHeight(both) > 1.0) cOverlap = YES;
                }
                cu = NSUnionRect(cu, ct[m]);
                CGFloat wantX = kCompactPadForVerify + (m % 2) * (120.0 + kCompactGapForVerify);
                CGFloat wantY = kCompactPadForVerify + (m / 2) * (55.0 + kCompactGapForVerify);
                if (fabs(NSMinX(ct[m]) - wantX) > 0.6 || fabs(NSMinY(ct[m]) - wantY) > 0.6
                    || fabs(NSWidth(ct[m]) - 120.0) > 0.6 || fabs(NSHeight(ct[m]) - 55.0) > 0.6)
                    cGeoBad = YES;
            }
            Say(!cOverlap, @"简略四格互不重叠");
            Say(!cGeoBad, @"四格都是 120×55，落在 12pt 外边距 + 8pt 间距上");
            NSRect cInner = NSMakeRect(kCompactPadForVerify, kCompactPadForVerify,
                                       kMonitorViewCompactWidth - 2 * kCompactPadForVerify,
                                       kMonitorViewCompactHeight - 2 * kCompactPadForVerify);
            Say(fabs(NSMinX(cu) - NSMinX(cInner)) <= 0.6 && fabs(NSMaxX(cu) - NSMaxX(cInner)) <= 0.6
                && fabs(NSMinY(cu) - NSMinY(cInner)) <= 0.6 && fabs(NSMaxY(cu) - NSMaxY(cInner)) <= 0.6,
                @"四格铺满内区：%.0f..%.0f × %.0f..%.0f",
                NSMinX(cu), NSMaxX(cu), NSMinY(cu), NSMaxY(cu));
            Say(NSEqualRects([cv rowRectAtMetric:2 row:0 in:cv.bounds], ct[2])
                && NSEqualRects([cv rowRectAtMetric:2 row:1 in:cv.bounds], NSZeroRect),
                @"简略模式 row 0 就是整格，row 1 不存在");

            NSMutableArray<DeskProc *> *cp = [NSMutableArray array];
            for (int i = 0; i < 8; i++) {
                DeskProc *p = [DeskProc new];
                p.pid = (pid_t)(9000 + i);
                p.name = [NSString stringWithFormat:@"compact%d", i];
                p.cpu = 24.0 - i * 2.0;
                p.mem = (3.0 - i * 0.2) * 1073741824.0;
                p.energy = 40.0 - i * 3.0;
                p.wakeups = 2; p.sockets = 1;
                p.netInRate = 2.0e6 - i * 0.2e6;
                p.netOutRate = 1.0e6 - i * 0.1e6;
                [cp addObject:p];
            }
            cv.totalCPU = 30;
            cv.totalMemUsed = 16.0 * 1073741824.0;
            cv.totalMemPhys = 24.0 * 1073741824.0;
            cv.totalNetRecv = 2.5e6; cv.totalNetSend = 1.2e6;
            double cEnergy = 0; for (DeskProc *p in cp) cEnergy += p.energy;
            cv.totalEnergy = cEnergy;
            [cv updateRows:cp];

            NSInteger hm = -1;
            NSPoint center2 = NSMakePoint(NSMidX(ct[2]), NSMidY(ct[2]));
            Say([cv hitTestRowAt:center2 in:cv.bounds metric:&hm] == 0 && hm == 2,
                @"整格命中：点能耗格中心 → 第 2 榜第 0 行");
            Say([cv hitTestRowAt:NSMakePoint(NSMidX(cv.bounds), NSMidY(ct[0]))
                          in:cv.bounds metric:&hm] == -1 && hm == -1,
                @"格缝里不命中，不会误开悬停");

            Say([cv pidAtMetric:0 row:0] == cp[0].pid && [cv pidAtMetric:1 row:0] == cp[0].pid
                && [cv pidAtMetric:2 row:0] == cp[0].pid && [cv pidAtMetric:3 row:0] == cp[0].pid,
                @"四格各留第 1 名（本组数据四个榜都是 cp[0]）");
            Say([[cv aggregateTextForMetric:0] isEqualToString:@"整机 30%"],
                @"简略榜头和完整模式同一串：%@", [cv aggregateTextForMetric:0]);
            Say([[cv aggregateTextForMetric:1] isEqualToString:@"16.0/24 GiB"],
                @"内存榜头同一串：%@", [cv aggregateTextForMetric:1]);
            Say([[cv aggregateTextForMetric:2] hasPrefix:@"前4名占全部"],
                @"能耗榜头同一串：%@", [cv aggregateTextForMetric:2]);
            Say([[cv aggregateTextForMetric:3] isEqualToString:@"系统 ↓2.5M ↑1.2M"],
                @"网络榜头同一串：%@", [cv aggregateTextForMetric:3]);

            NSInteger cores = (NSInteger)[NSProcessInfo.processInfo activeProcessorCount];
            if (cores < 1) cores = 1;
            double wantCPU = (24.0 / (double)cores) / 100.0;
            double wantMem = 3.0 / 24.0;
            double wantEnergy = 40.0 / cEnergy;
            double wantNet = 3.0e6 / 3.7e6;
            Say(fabs([cv barFractionAtMetric:0 row:0] - wantCPU) < 1e-6,
                @"CPU 条长 = 占整机 %.4f（不是相对第 1 名顶满）", [cv barFractionAtMetric:0 row:0]);
            Say(fabs([cv barFractionAtMetric:1 row:0] - wantMem) < 1e-6,
                @"内存条长 = RSS/物理 = %.4f", [cv barFractionAtMetric:1 row:0]);
            Say(fabs([cv barFractionAtMetric:2 row:0] - wantEnergy) < 1e-6,
                @"能耗条长 = 该进程/全部 = %.4f", [cv barFractionAtMetric:2 row:0]);
            Say(fabs([cv barFractionAtMetric:3 row:0] - wantNet) < 1e-6,
                @"网络条长 = 进程/系统 = %.4f", [cv barFractionAtMetric:3 row:0]);
            Say([cv barFractionAtMetric:0 row:0] <= 1.0 && [cv barFractionAtMetric:3 row:0] <= 1.0,
                @"条长都夹在 0~1");
            NSRect cbar = [DeskMonitorView barRectInTile:ct[0]];
            Say(fabs(NSHeight(cbar) - 2.0) < 0.001
                && fabs(NSWidth(cbar) - (120.0 - 2 * 10.0)) < 0.001
                && NSContainsRect(ct[0], cbar),
                @"格内条 2pt、左右各留 10pt、落在格内 (%.0f,%.0f %.0fx%.0f)",
                cbar.origin.x, cbar.origin.y, cbar.size.width, cbar.size.height);

            // 哨兵/未知分母不许画假条。CPU 要把整组都打成 -1 才能守住"榜首行"：
            // 只改第一行的话，第二行会顶上榜单，条长照样非零（测的就不是哨兵了）。
            for (DeskProc *p in cp) p.cpu = -1;
            [cv updateRows:cp];
            Say([cv barFractionAtMetric:0 row:0] == 0, @"CPU 整榜哨兵 -1 时条长为 0");
            for (NSInteger i = 0; i < (NSInteger)cp.count; i++) cp[i].cpu = 24.0 - i * 2.0;
            [cv updateRows:cp];
            double savedPhys = cv.totalMemPhys;
            cv.totalMemPhys = 0;
            [cv updateRows:cp];
            Say([cv barFractionAtMetric:1 row:0] == 0, @"物理内存未知时内存条长为 0");
            cv.totalMemPhys = savedPhys;
            cv.totalNetRecv = -1;
            [cv updateRows:cp];
            Say([cv barFractionAtMetric:3 row:0] == 0, @"系统流量未知时网络条长为 0");
            cv.totalNetRecv = 2.5e6;
            [cv updateRows:cp];

            // 12h 数据仍按拍算好：简略不画，切回完整模式不能出现空窗
            __block double histCov = 0;
            cv.historyForPid = ^double(pid_t pid, DeskHistMetric hm, double *covered) {
                (void)pid; (void)hm;
                if (covered) *covered = 12.0 * 3600.0;
                histCov = 12.0 * 3600.0;
                return 5.0;
            };
            cv.historyTotalForPid = ^double(pid_t pid, double *covered) {
                (void)pid;
                if (covered) *covered = 12.0 * 3600.0;
                return 3.4e9;
            };
            [cv updateRows:cp];
            Say(histCov > 0 && ![[cv historyTextAtMetric:2 row:0] isEqualToString:@"—"],
                @"简略模式仍算好第 0 行的 12h：%@", [cv historyTextAtMetric:2 row:0]);
            cv.historyForPid = nil; cv.historyTotalForPid = nil;

            // 形变尺寸/素材源：简略的画布也要按 272×142 算
            NSSize cflat = [DeskMonitorView windowSizeWarped:NO compact:YES];
            NSSize cwarp = [DeskMonitorView windowSizeWarped:YES compact:YES];
            Say(cflat.width == kMonitorViewCompactWidth && cflat.height == kMonitorViewCompactHeight,
                @"简略未变形窗口 == %.0fx%.0f", cflat.width, cflat.height);
            Say(cwarp.width == kMonitorViewCompactWidth + 120.0
                && cwarp.height == kMonitorViewCompactHeight + 120.0,
                @"简略变形窗口各边外扩 60pt = %.0fx%.0f", cwarp.width, cwarp.height);
            DeskQuadOffsets co = DeskQuadOffsetsZero();
            co.tl = NSMakeSize(-10, 8); co.br = NSMakeSize(12, -6);
            cv.quadOffsets = co;
            DeskQuad cq = [cv currentQuad];
            Say(fabs(cq.tl.x - (kDeskQuadPad - 10)) < 1e-3
                && fabs(cq.tl.y - (kDeskQuadPad + kMonitorViewCompactHeight + 8)) < 1e-3,
                @"简略角点换算用 272×142：左上 (%.1f,%.1f)", cq.tl.x, cq.tl.y);
            DeskMonitorView *csrc = [cv flatSourceForVerify];
            Say(csrc != nil && csrc.isCompact
                && fabs(NSWidth(csrc.bounds) - kMonitorViewCompactWidth) < 1e-3
                && fabs(NSHeight(csrc.bounds) - kMonitorViewCompactHeight) < 1e-3,
                @"简略变形态素材源也是 272×142");
            // 小字清晰度是用户实机报的：HUD/Bare 的 7pt 柔影在 8.5~10pt 上会糊成光晕。
            // 这里守住简略专用绘制口和紧影参数，别被顺手改回完整模式那一套。
            {
                NSString *msrc = [NSString stringWithContentsOfFile:@"monitor_view.m"
                                                           encoding:NSUTF8StringEncoding error:NULL];
                Say([msrc rangeOfString:@"MonStrCompact"].location != NSNotFound,
                    @"简略文字走专用绘制口 MonStrCompact");
                Say([msrc rangeOfString:@"sh.shadowBlurRadius = 2.0;"].location != NSNotFound,
                    @"简略小字用 2pt 紧影，不用完整模式的 7pt 柔影");
                Say([msrc rangeOfString:@"MonSemibold(9.0)"].location != NSNotFound
                    && [msrc rangeOfString:@"MonNum(9.5, NSFontWeightSemibold)"].location != NSNotFound
                    && [msrc rangeOfString:@"MonText(10.5)"].location != NSNotFound,
                    @"简略字号档位在源码里：指标名 9 / 榜头 9.5 / 进程名 10.5");
            }
            cv.quadOffsets = DeskQuadOffsetsZero();
            cv.compact = NO;
            Say(NSWidth(cv.bounds) == kMonitorViewWidth && NSHeight(cv.bounds) == kMonitorViewHeight,
                @"切回完整模式：独立视图回到 %.0fx%.0f（窗口由 main.m 重建）",
                kMonitorViewWidth, kMonitorViewHeight);
        }

        printf("\n活动监视器：12h 文字列（每行各自的值）\n");
        {
            // 偶数 pid 有 12h 记录、奇数没有；网络行还要各自拿到累计字节。
            NSMutableArray<DeskProc *> *hh = [NSMutableArray array];
            for (int i2 = 0; i2 < 8; i2++) {
                DeskProc *q = [DeskProc new];
                q.pid = (pid_t)(8100 + i2); q.name = [NSString stringWithFormat:@"g%d", i2];
                q.cpu = 15.0 - i2; q.mem = 2e8; q.energy = 12.0 - i2; q.wakeups = 3; q.sockets = 2;
                q.netInRate = 10.0 - i2; q.netOutRate = 1.0;
                [hh addObject:q];
            }
            mv.historyForPid = ^double(pid_t pid, DeskHistMetric hm, double *covered) {
                BOOL known = (pid % 2) == 0;
                if (covered) *covered = known ? 12.0 * 3600.0 : 0.0;
                if (!known) return 0;
                if (hm == DeskHistCPU) return 20.0;
                if (hm == DeskHistMemory) return 900.0 * 1048576.0;
                if (hm == DeskHistEnergy) return 5.0;
                return 1000.0;   // network 平均速率，只用来证明 12h 路径有值
            };
            mv.historyTotalForPid = ^double(pid_t pid, double *covered) {
                BOOL known = (pid % 2) == 0;
                if (covered) *covered = known ? 12.0 * 3600.0 : 0.0;
                return known ? 3.4e9 : 0;
            };
            [mv updateRows:hh];
            NSString *cpu0 = [mv historyTextAtMetric:DeskMonitorMetricCPU row:0];
            Say(![cpu0 isEqualToString:@"—"] && [cpu0 hasSuffix:@"%"], @"CPU 12h 列=「%@」", cpu0);
            Say([[mv historyTextAtMetric:DeskMonitorMetricCPU row:1] isEqualToString:@"—"],
                @"没有记录的 CPU 行印「—」，不印假 0");
            Say([[mv historyTextAtMetric:DeskMonitorMetricMemory row:0] isEqualToString:@"900M"],
                @"内存 12h 列用 MiB/1024³：900M");
            Say([[mv historyTextAtMetric:DeskMonitorMetricMemory row:1] isEqualToString:@"—"],
                @"没有记录的内存行印「—」");
            Say([[mv historyTextAtMetric:DeskMonitorMetricNetwork row:0] isEqualToString:@"3.4G"],
                @"网络第 0 行有各自的 12h 累计：3.4G（不是只有榜头总量）");
            Say([[mv historyTextAtMetric:DeskMonitorMetricNetwork row:1] isEqualToString:@"—"],
                @"网络没记录的那一行印「—」");
            Say(fabs([mv historyTotalAtMetric:DeskMonitorMetricNetwork row:0] - 3.4e9) < 1.0,
                @"网络第 0 行的累计字节真的取到 %.0f", [mv historyTotalAtMetric:DeskMonitorMetricNetwork row:0]);
            mv.historyForPid = nil;
            mv.historyTotalForPid = nil;
        }
        // 取色必须和卡片面板共用同一份 DeskPaletteFor，并且跟着系统外观翻：
        // 以前监视器自己抄了一份深色档，用户哪天切 Light 就会出现「卡片深字、监视器还白字」
        void (^chk)(NSColor *, NSColor *, NSString *) = ^(NSColor *x, NSColor *y, NSString *why) {
            CGFloat r1,g1,b1,a1,r2,g2,b2,a2;
            [x getRed:&r1 green:&g1 blue:&b1 alpha:&a1]; [y getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
            Say(fabs(r1-r2)<1e-6 && fabs(g1-g2)<1e-6 && fabs(b1-b2)<1e-6 && fabs(a1-a2)<1e-6, @"%@", why);
        };
        mv.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        DeskPalette palD = [mv paletteSnapshot];
        chk(palD.label, DeskPaletteFor(DeskStyleBare, YES).label, @"深色档：监视器标签色 == 卡片面板");
        chk(palD.primary, DeskPaletteFor(DeskStyleBare, YES).primary, @"深色档：监视器数据色 == 卡片面板");
        mv.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        DeskPalette palL = [mv paletteSnapshot];
        chk(palL.label, DeskPaletteFor(DeskStyleBare, NO).label, @"浅色档：监视器跟着系统外观翻，和卡片同步");
        chk(palD.label, DeskRGB(140, 168, 192, 1.0), @"深色档实测仍是那组蓝灰 (140,168,192)");
        Say(![palD.label isEqual:palL.label], @"深浅两档确实不同 —— 这条耦合不是恒真");
        printf("\n活动监视器：调角模式\n");
        NSSize flat = [DeskMonitorView windowSizeWarped:NO];
        NSSize warp = [DeskMonitorView windowSizeWarped:YES];
        Say(flat.width == kMonitorViewWidth && flat.height == kMonitorViewHeight,
            @"未变形窗口 == 本体 %.0fx%.0f（走实时绘制，文字原生清晰）", flat.width, flat.height);
        Say(warp.width == kMonitorViewWidth + 120.0 && warp.height == kMonitorViewHeight + 120.0,
            @"变形窗口各边外扩 60pt = %.0fx%.0f（四角拖出去不会被裁）", warp.width, warp.height);
        Say(!mv.isWarped, @"新建时没变形");
        DeskQuadOffsets mo = DeskQuadOffsetsZero();
        mo.tl = NSMakeSize(-28.995, -46.609); mo.tr = NSMakeSize(-4.453, 4.141);
        mo.br = NSMakeSize(-4.403, 6.518);    mo.bl = NSMakeSize(38.516, -52.0);   // 卡片面板实际在用的那组角点
        mv.quadOffsets = mo;
        Say(mv.isWarped, @"角点非零即进入变形态");
        DeskQuad mq = [mv currentQuad];
        // 画布是 y 朝上：卡片下边缘落在 pad 上、上边缘在 pad+高度上，别把两条边写反
        Say(fabs(mq.tl.x - (kDeskQuadPad + mo.tl.width)) < 1e-3
            && fabs(mq.tl.y - (kDeskQuadPad + kMonitorViewHeight + mo.tl.height)) < 1e-3
            && fabs(mq.bl.y - (kDeskQuadPad + mo.bl.height)) < 1e-3,
            @"角点换算到画布坐标含 %.0fpt 余量：左上 (%.1f,%.1f)、左下 y=%.1f",
            kDeskQuadPad, mq.tl.x, mq.tl.y, mq.bl.y);
        Say([mv needsRedraw] == NO, @"变形态 needsRedraw 恒 NO —— 动画表不会为一张位图逐帧空转");
        DeskQuadOffsets mback = DeskQuadOffsetsFromString(DeskQuadOffsetsString(mo));
        Say(NSEqualSizes(mback.tl, mo.tl) && NSEqualSizes(mback.bl, mo.bl), @"角点存档往返不变");
        DeskQuadOffsets pulled = DeskQuadOffsetsZero();
        NSSize mcard = NSMakeSize(kMonitorViewWidth, kMonitorViewHeight);
        pulled.tl = NSMakeSize(-999, 999); pulled.tr = NSMakeSize(999, 999);
        pulled.br = NSMakeSize(999, -999); pulled.bl = NSMakeSize(-999, -999);
        NSRect mb = DeskQuadBounds(DeskQuadFromOffsets(mcard, DeskQuadOffsetsClamp(pulled, mcard)));
        Say(NSMinX(mb) >= 0 && NSMinY(mb) >= 0 && NSMaxX(mb) <= warp.width && NSMaxY(mb) <= warp.height,
            @"单个角往死里拖也被夹进画布：(%.0f,%.0f)-(%.0f,%.0f)",
            NSMinX(mb), NSMinY(mb), NSMaxX(mb), NSMaxY(mb));
        // 真实拖拽在这台机器上没法用合成事件驱动（无辅助功能权限），所以把"拖一个角"拆成
        // 可直接调用的口，在这里按真实数值断言：位移 → 跟随 → 夹取 → 非法角号不改状态。
        mv.editing = YES;
        mv.quadOffsets = DeskQuadOffsetsZero();
        DeskQuad zero = [mv currentQuad];
        [mv dragCorner:0 toCanvasPoint:NSMakePoint(zero.tl.x - 30.0, zero.tl.y + 12.0)];
        DeskQuadOffsets dr = mv.quadOffsets;
        Say(fabs(dr.tl.width + 30.0) < 1e-3 && fabs(dr.tl.height - 12.0) < 1e-3,
            @"拖左上角到 (%.1f,%.1f) 后位移 == %.1f,%.1f（画布 y 朝上，往上拖为正）",
            zero.tl.x - 30.0, zero.tl.y + 12.0, dr.tl.width, dr.tl.height);
        Say(fabs(mv.currentQuad.tl.x - (kDeskQuadPad + dr.tl.width)) < 1e-3
            && fabs(mv.currentQuad.tr.x - (kDeskQuadPad + kMonitorViewWidth)) < 1e-3,
            @"只有被拖的那个角动：左上 x=%.1f、右上 x=%.1f 仍贴画布原位在 %.0f",
            mv.currentQuad.tl.x, mv.currentQuad.tr.x, kDeskQuadPad + kMonitorViewWidth);
        [mv dragCorner:3 toCanvasPoint:NSMakePoint(-5000, -5000)];
        NSRect cb = DeskQuadBounds([mv currentQuad]);
        Say(NSMinX(cb) >= 0 && NSMinY(cb) >= 0, @"往屏幕外死拖也被夹回画布内：左上 (%.0f,%.0f)",
            NSMinX(cb), NSMinY(cb));
        DeskQuadOffsets beforeBad = mv.quadOffsets;
        [mv dragCorner:-1 toCanvasPoint:NSMakePoint(0, 0)];
        [mv dragCorner:9 toCanvasPoint:NSMakePoint(0, 0)];
        Say(NSEqualSizes(beforeBad.bl, mv.quadOffsets.bl) && NSEqualSizes(beforeBad.tl, mv.quadOffsets.tl),
            @"非法角号不改任何角点（拖到画布外也不炸）");
        mv.quadOffsets = DeskQuadOffsetsZero();
        Say(mv.isWarped, @"角点归零但调角模式还开着 —— 仍在变形态，把手才画得出来");
        mv.editing = NO;
        Say(!mv.isWarped, @"退出调角且角点为零：回到实时绘制");
        // 这一段守"按下不阻塞、拖得动、松手只报一次"。注意它守的不是当年那个模态循环：
        // 旧写法在合成事件下同样通过（已经实测证伪过一次）。真正的"拖不动"根因是调角模式
        // 里 mouseDown 无条件 return，见下面那段新增断言。
        {
            NSWindow *dw = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kMonitorViewWidth, kMonitorViewHeight)
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered defer:NO];
            DeskMonitorView *dv = [[DeskMonitorView alloc] initWithRows:@[]];
            dw.contentView = dv;
            NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                               location:NSMakePoint(200, 140)
                                          modifierFlags:0 timestamp:[NSDate date].timeIntervalSince1970
                                               windowNumber:dw.windowNumber context:nil
                                                  eventNumber:1 clickCount:1 pressure:1.0];
            NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
            [dv mouseDown:down];
            NSTimeInterval spent = [NSDate date].timeIntervalSince1970 - t0;
            // 只保证"mouseDown 自己不阻塞事件流"。它**不是**旧写法的回归网：我把旧那版模态
            // 循环装回来实测过，计时断言同样 0.000s 通过（队列里没有待处理事件时
            // nextEventMatchingMask 直接返回 nil 就 break）。别拿它当"旧代码会被抓住"。
            Say(spent < 0.5, @"mouseDown 不阻塞事件流（%.3fs；实测它抓不到旧写法，只防自己变阻塞）", spent);
            Say([dv isDragging], @"按下后进入拖窗态");
            __block int moved = 0;
            dv.onUserMove = ^{ moved++; };
            NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                             location:NSMakePoint(200, 140)
                                        modifierFlags:0 timestamp:[NSDate date].timeIntervalSince1970
                                             windowNumber:dw.windowNumber context:nil
                                            eventNumber:2 clickCount:1 pressure:0.0];
            [dv mouseUp:up];
            Say(![dv isDragging] && moved == 1, @"松手退出拖窗态，并且只报一次「用户亲手拖过」");
            // 窗口真的会跟着动吗、动得对不对 —— 把光标位置做成参数才能测这一段。
            // 基准必须用真实光标：mouseDown: 存的 _dragStartMouse 就是 NSEvent.mouseLocation，
            // 拿窗口原点当起点算期望位移是错的（我第一版就这么错过一次）。
            NSPoint cur = NSEvent.mouseLocation;
            NSRect mv0 = dw.frame;
            [dv dragWindowToMouse:NSMakePoint(cur.x + 50, cur.y - 30)];
            NSRect mv1 = dw.frame;
            Say(fabs((mv1.origin.x - mv0.origin.x) - 50.0) < 1.0
                && fabs((mv1.origin.y - mv0.origin.y) + 30.0) < 1.0,
                @"拖拽真的挪窗：窗口位移 (%+.0f,%+.0f) 跟上鼠标位移 (+50,-30)",
                mv1.origin.x - mv0.origin.x, mv1.origin.y - mv0.origin.y);
            [dv mouseUp:up];
            NSRect mv2 = dw.frame;
            // 单次调用挪对了不代表连续调用挪得对 —— 真鼠标拖动是每秒几十次连续设位。
            // 逐帧喂 30 步，要求每一步都真的落到那一步的位置。
            // 注意这条**分不出** `setFrameOrigin:` 和 `setFrame:display:animate:NO`（实测换回
            // animate: 那版照样 216/0）：它守的是挪位算术和"每步都落位"，API 差异只有真鼠标能判。
            {
                NSPoint cur2 = NSEvent.mouseLocation;
                // 先按"当前光标"落一个基准帧：dragWindowToMouse: 的算法是
                // 起点帧 + (现在光标 - 按下时光标)，而 _dragStartMouse 是上一次按下留下的，
                // 不先对齐基准就会拿错的参照去比（第一版就这么假失败了一次）。
                [dv dragWindowToMouse:cur2];
                NSRect base = dw.frame;
                int bad = 0;
                for (int s = 1; s <= 30; s++) {
                    NSPoint want = NSMakePoint(base.origin.x + s * 4.0, base.origin.y - s * 2.0);
                    [dv dragWindowToMouse:NSMakePoint(cur2.x + s * 4.0, cur2.y - s * 2.0)];
                    NSRect got = dw.frame;
                    if (fabs(got.origin.x - want.x) > 0.6 || fabs(got.origin.y - want.y) > 0.6) bad++;
                }
                Say(bad == 0, @"连续 30 步逐帧挪位，每步都落到目标位置（丢帧 %d 步）", bad);
                // 还原到这一段开始前的位置：下一条断言拿 mv2 当参照，别把现场留在别处
                [dw setFrameOrigin:mv2.origin];
            }
            NSEvent *drag2 = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
                                                location:NSMakePoint(999, 999) modifierFlags:0
                                               timestamp:[NSDate date].timeIntervalSince1970
                                            windowNumber:dw.windowNumber context:nil
                                             eventNumber:3 clickCount:1 pressure:1.0];
            [dv mouseDragged:drag2];
            Say(fabs(dw.frame.origin.x - mv2.origin.x) < 1.0,
                @"松手后 mouseDragged 不再挪窗（只有按住才拖）");
            [dv mouseUp:up];
            Say(moved == 1, @"没有按下就没有松手事件 —— 不会被误记成用户移动过");
            // 全局锁定：按下不进入拖窗态，拖拽不动窗，松手不报「用户亲手拖过」
            {
                dv.locked = YES;
                NSRect lf = dw.frame;
                int before = moved;
                [dv mouseDown:down];
                Say(![dv isDragging], @"锁定后按下不进入拖窗态");
                [dv mouseDragged:drag2];
                Say(NSEqualPoints(dw.frame.origin, lf.origin), @"锁定后 mouseDragged 不挪窗");
                [dv mouseUp:up];
                Say(moved == before, @"锁定后松手不报「用户亲手拖过」");
                dv.locked = NO;
                [dv mouseDown:down];
                Say([dv isDragging], @"解锁后按下恢复拖窗态");
                [dv mouseUp:up];
            }
            // 模式陷阱：调角模式里 mouseDown 原来无条件 return，整块组件一点都拖不动，
            // 而同样开着调角的卡片面板、弹药库一直拖得动。**注意这不是用户那次的已证原因**
            // —— 日志里从来没有一条活动监视器的调角开关，他没进过这个模式。遮挡那条也已用
            // A/B 证伪（tools/probe_clickcatcher.m 量到三块组件被同一批窗口压着）。
            {
                NSPoint midWin = [dv convertPoint:NSMakePoint(kMonitorViewWidth * 0.5,
                                                              kMonitorViewHeight * 0.5) toView:nil];
                NSEvent *mDown = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                    location:midWin modifierFlags:0
                                                   timestamp:[NSDate date].timeIntervalSince1970
                                                windowNumber:dw.windowNumber context:nil
                                                 eventNumber:7 clickCount:1 pressure:1.0];
                NSEvent *mUp = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                                  location:midWin modifierFlags:0
                                                 timestamp:[NSDate date].timeIntervalSince1970
                                              windowNumber:dw.windowNumber context:nil
                                               eventNumber:8 clickCount:1 pressure:0.0];
                dv.editing = YES;
                [dv mouseDown:mDown];
                Say([dv isDragging], @"开着调角模式按正中间，照样进入拖窗态（和卡片面板同一规矩）");
                [dv mouseUp:mUp];
                NSRect rb = [dv resetButtonRect];
                NSPoint btn = [dv convertPoint:NSMakePoint(NSMidX(rb), NSMidY(rb)) toView:nil];
                NSEvent *bDown = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                    location:btn modifierFlags:0
                                                   timestamp:[NSDate date].timeIntervalSince1970
                                                windowNumber:dw.windowNumber context:nil
                                                 eventNumber:9 clickCount:1 pressure:1.0];
                __block BOOL quadFired = NO;
                dv.onQuadEdit = ^(DeskQuadOffsets q) { (void)q; quadFired = YES; };
                [dv mouseDown:bDown];
                Say(![dv isDragging], @"按在「复位角点」按钮上不拖窗 —— 调角和挪窗不抢同一帧");
                Say(quadFired, @"复位按钮按下就提交角点归零");
                dv.editing = NO;
            }
            // tracking area 的选项集是"拖不动"最后一处事件路由不对称：三块组件里只有监视器
            // 带过 NSTrackingEnabledDuringMouseDrag（按住拖动期间还收 mouseMoved，而 mouseMoved
            // 会去弹悬停浮层 = 在鼠标按下时把另一块窗口顶上来）。这条断言钉住它不许回来。
            {
                [dv updateTrackingAreas];   // CLI 里没人调它，不手动补一次 trackingAreas 是空的
                NSTrackingAreaOptions opt = dv.trackingAreas.firstObject.options;
                Say(dv.trackingAreas.count > 0, @"视图挂着悬停用的 tracking area");
                Say(!(opt & NSTrackingEnabledDuringMouseDrag),
                    @"tracking area 不带 NSTrackingEnabledDuringMouseDrag（拖拽期间不再收 mouseMoved）");
                Say((opt & NSTrackingActiveAlways) != 0,
                    @"但保留 ActiveAlways —— 桌面层窗口永远不是 key，否则悬停是死的");
                // 两侧都要测：没按住时悬停必须真的会动，否则"按住时不动"是假通过
                NSMutableArray<DeskProc *> *hv = [NSMutableArray array];
                for (int i = 0; i < 8; i++) {
                    DeskProc *p = [DeskProc new];
                    p.pid = (pid_t)(7100 + i); p.name = [NSString stringWithFormat:@"h%d", i];
                    p.cpu = 30.0 - i; p.mem = 2e8; p.energy = 20.0 - i; p.wakeups = 4; p.sockets = 2;
                    [hv addObject:p];
                }
                [dv updateRows:hv];
                __block int hoverFired = 0;
                dv.onHover = ^(pid_t pid, NSRect row, NSInteger metric, double avg, double covered) {
                    (void)row; (void)metric; (void)avg; (void)covered; if (pid > 0) hoverFired++;
                };
                NSRect r0 = [dv rowRectAtMetric:DeskMonitorMetricCPU row:0 in:dv.bounds];
                NSPoint p0 = [dv convertPoint:NSMakePoint(NSMidX(r0), NSMidY(r0)) toView:nil];
                NSEvent *mv0 = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:p0
                                             modifierFlags:0 timestamp:[NSDate date].timeIntervalSince1970
                                              windowNumber:dw.windowNumber context:nil
                                               eventNumber:12 clickCount:1 pressure:1.0];
                [dv mouseMoved:mv0];
                Say(hoverFired == 1, @"没按住时移到某一行上，悬停回调真的会响（%d 次）", hoverFired);
                NSRect r2 = [dv rowRectAtMetric:DeskMonitorMetricCPU row:2 in:dv.bounds];
                NSPoint p2 = [dv convertPoint:NSMakePoint(NSMidX(r2), NSMidY(r2)) toView:nil];
                NSEvent *mv2 = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:p2
                                             modifierFlags:0 timestamp:[NSDate date].timeIntervalSince1970
                                              windowNumber:dw.windowNumber context:nil
                                               eventNumber:13 clickCount:1 pressure:1.0];
                [dv mouseDown:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p0
                                             modifierFlags:0 timestamp:[NSDate date].timeIntervalSince1970
                                              windowNumber:dw.windowNumber context:nil
                                               eventNumber:14 clickCount:1 pressure:1.0]];
                int before = hoverFired;
                [dv mouseMoved:mv2];
                Say(hoverFired == before && [dv isDragging],
                    @"按住拖动期间不再弹悬停浮层（回调次数停在 %d）", before);
                [dv mouseUp:up];
            }
            // 只许有一条搬窗路。mouseDown 里不许再调用 AppKit 的拖拽会话：它会吞掉
            // mouseDragged，而桌面图标层的非 key 窗它又搬不动 → 两头落空 = "按住不动"。
            // ① 按下之后窗口必须还在原地（旧写法跑会话时这一步会被搬走）；
            // ② 外部把窗口挪开后，下一个 mouseDragged 必须按自己的算式把它搬回来
            //    （旧守卫把这一步认成"AppKit 已接手"而完全不插手，窗口就永远停在 +33,+21）。
            {
                NSRect f0 = dw.frame;
                [dv mouseDown:down];
                NSRect fp = dw.frame;
                Say(NSEqualPoints(f0.origin, fp.origin),
                    @"按下不会就地搬窗（AppKit 会话已去掉）：位移 (%+.1f,%+.1f)",
                    fp.origin.x - f0.origin.x, fp.origin.y - f0.origin.y);
                [dw setFrameOrigin:NSMakePoint(f0.origin.x + 33.0, f0.origin.y + 21.0)];
                NSEvent *drag3 = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
                                                    location:NSMakePoint(120, 120) modifierFlags:0
                                                   timestamp:[NSDate date].timeIntervalSince1970
                                                windowNumber:dw.windowNumber context:nil
                                                 eventNumber:21 clickCount:1 pressure:1.0];
                [dv mouseDragged:drag3];
                NSRect f1 = dw.frame;
                // 不许拿"搬回原点"当判据：dragWindowToMouse 用的是 [NSEvent mouseLocation]
                // （真实光标），校验跑这几毫秒里你一动鼠标，落点就跟着漂 —— 实测红过 4 次。
                // 旧守卫的特征是"外部挪开之后它就冻在挪开的位置不动"，所以只断言偏移被覆盖掉。
                Say(!NSEqualPoints(f1.origin, NSMakePoint(f0.origin.x + 33.0, f0.origin.y + 21.0)),
                    @"mouseDragged 一定插手：外部挪开的 (+33,+21) 被覆盖成 (%.0f,%.0f)",
                    f1.origin.x, f1.origin.y);
                [dv mouseUp:up];
                [dw setFrameOrigin:f0.origin];
            }
            // 不 close：这个 CLI 里没有跑起来的 NSApp，关窗口会走到没有事件环境的销毁路径
            [dv mouseDown:down]; [dv mouseUp:up];
            [dw orderOut:nil];
            dw = nil; dv = nil;
        }
        printf("\n12 小时历史桶：口径、剪枝与落盘\n");
        NSTimeInterval T = [NSDate date].timeIntervalSince1970;
        NSString *hp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"deskboard-hist-%@.plist", NSUUID.UUID.UUIDString]];
        DeskHistory *H = [[DeskHistory alloc] initWithPath:hp];
        double cov = -1;
        Say(fabs([H averageForPid:4242 metric:DeskHistCPU now:T window:kDeskHistoryWindow covered:&cov]) < 1e-9
            && cov == 0, @"空历史：平均 0 且 covered 0 —— 界面据此标\"已记录 0 小时\"，不假装满 12 小时");
        DeskProc *one = [DeskProc new];
        one.pid = 4242; one.name = @"跑满一核一分钟"; one.cpu = 100.0; one.mem = 50e6;
        one.wakeups = 10.0; one.sockets = 3; one.energy = 100.8;
        one.netInRate = 1000.0; one.netOutRate = 500.0;
        double sys0[4] = { 30.0, 19e9, 160.0, 5.0 };
        [H noteSampleAt:T - 30 seconds:60.0 rows:@[one] totals:sys0];
        double c1 = -1;
        double avg = [H averageForPid:4242 metric:DeskHistCPU now:T window:kDeskHistoryWindow covered:&c1];
        // 只攒到 60 秒时，分母是 60 而不是 43200 —— 否则冷启动头一天这根条子永远是亚像素
        Say(fabs(avg - 100.0) < 1e-6,
            @"数据不足 12 小时时分母收敛到已记录秒数：刚攒 60 秒、跑满一核 → %.1f%%（不是 %.4f%%）",
            avg, 100.0 * 60.0 / kDeskHistoryWindow);
        Say(fabs([H averageForPid:4242 metric:DeskHistNetwork now:T window:kDeskHistoryWindow covered:NULL]
                 - 1500.0) < 0.01,
            @"网络历史按收+发字节/秒存：1000+500 → %.0f",
            [H averageForPid:4242 metric:DeskHistNetwork now:T window:kDeskHistoryWindow covered:NULL]);
        double tc = 0;
        double ptotal = [H totalForPid:4242 metric:DeskHistNetwork now:T window:kDeskHistoryWindow covered:&tc];
        Say(fabs(ptotal - 1500.0 * 60.0) < 1e-6,
            @"网络累计 = 1500 B/s × 60s = %.0f B（covered %.0fs）", ptotal, tc);
        double stotal = [H totalForSystemMetric:DeskHistNetwork now:T window:kDeskHistoryWindow covered:NULL];
        Say(fabs(stotal - 5.0 * 60.0) < 1e-6,
            @"系统桶网络累计 = 5 B/s × 60s = %.0f B", stotal);
        double trackedTotal = [H totalForTrackedPidsMetric:DeskHistNetwork now:T
                                                    window:kDeskHistoryWindow covered:NULL];
        Say(fabs(trackedTotal - 1500.0 * 60.0) < 1e-6,
            @"已跟踪进程网络累计 = 1500 B/s × 60s = %.0f B", trackedTotal);
        Say(fabs(c1 - 60.0) < 1e-6, @"covered 如实报 60 秒，不冒充 12 小时");
        double hcs = -1;
        double savg = [H averageForSystemMetric:DeskHistCPU now:T window:kDeskHistoryWindow covered:&hcs];
        Say(fabs(savg - 30.0) < 1e-6 && fabs(hcs - 60.0) < 1e-6,
            @"榜头系统总量同一口径：%.2f%%", savg);
        DeskProc *fresh = [DeskProc new];
        fresh.pid = 7777; fresh.name = @"刚启动没基线"; fresh.cpu = -1; fresh.mem = 20e6;
        fresh.wakeups = -1; fresh.energy = -1; fresh.sockets = 2;
        [H noteSampleAt:T - 30 seconds:5.0 rows:@[fresh] totals:sys0];
        double c2 = -1;
        [H averageForPid:7777 metric:DeskHistCPU now:T window:kDeskHistoryWindow covered:&c2];
        Say(c2 <= 0, @"cpu<0 那一拍整条跳过，不拿假 0 拉低平均（covered=%.1f）", c2);
        [H noteSampleAt:T - 13 * 3600 seconds:5.0 rows:@[one] totals:sys0];
        // covered 是"窗口内全局攒到的秒数"：60（第一拍）+ 5（cpu<0 那拍，进程没记上但
        // 系统总量记上了）。13 小时前那 5 秒被剪掉，所以是 65 而不是 70。
        double c3 = -1;
        [H averageForPid:4242 metric:DeskHistCPU now:T window:kDeskHistoryWindow covered:&c3];
        Say(fabs(c3 - 65.0) < 1e-6, @"13 小时前的采样不进窗口（covered=%.0f，不是 70）", c3);
        double avgNow = -1, covNow = -1;
        avgNow = [H averageForPid:4242 metric:DeskHistCPU now:T window:kDeskHistoryWindow covered:&covNow];
        Say([H flushIfNeeded], @"落盘成功");
        DeskHistory *H2 = [[DeskHistory alloc] initWithPath:hp];
        [H2 load];
        double c4 = -1;
        double avg2 = [H2 averageForPid:4242 metric:DeskHistCPU now:T window:kDeskHistoryWindow covered:&c4];
        Say(fabs(avg2 - avgNow) < 1e-9 && fabs(c4 - covNow) < 1e-9,
            @"重启读回后平均值与 covered 不变（%.2f%% / %.0fs）", avg2, c4);
        // 攒满 12 小时后必须收敛回字面口径：跑满一核 60 秒、其余 11.98 小时是 0
        NSMutableArray<DeskProc *> *hIdle = [NSMutableArray array];
        DeskProc *hIdleProc = [DeskProc new];
        hIdleProc.pid = 4242; hIdleProc.name = @"跑满一核一分钟"; hIdleProc.cpu = 0; hIdleProc.mem = 50e6;
        hIdleProc.wakeups = 0; hIdleProc.sockets = 3; hIdleProc.energy = 0;
        [hIdle addObject:hIdleProc];
        DeskHistory *H3 = [[DeskHistory alloc] initWithPath:hp];
        for (int i = 0; i < 720; i++) {          // 720 拍 × 60 秒 = 正好 12 小时
            one.cpu = (i == 0) ? 100.0 : 0.0;    // 只有第一拍跑满一核
            [H3 noteSampleAt:T - (719 - i) * 60.0 seconds:60.0 rows:@[one] totals:sys0];
        }
        double c5 = -1;
        double hFull = [H3 averageForPid:4242 metric:DeskHistCPU now:T window:kDeskHistoryWindow covered:&c5];
        Say(fabs(hFull - 100.0 * 60.0 / kDeskHistoryWindow) < 1e-6,
            @"攒满 12 小时后自动收敛回字面口径：%.4f%% == 100×60/43200（covered=%.0fs）", hFull, c5);
        NSMutableArray *many = [NSMutableArray array];
        for (int i = 0; i < 300; i++) {
            DeskProc *p = [DeskProc new];
            p.pid = (pid_t)(10000 + i); p.name = [NSString stringWithFormat:@"p%d", i];
            p.cpu = 300.0 / (i + 1); p.mem = 1e6 * (300 - i); p.wakeups = 5; p.sockets = i % 9; p.energy = 1.0;
            [many addObject:p];
        }
        [H2 noteSampleAt:T seconds:5.0 rows:many totals:sys0];
        Say(H2.trackedPids <= 40, @"一拍 300 个进程也只跟四榜前几名：trackedPids=%lu（文件不会无限长）",
            (unsigned long)H2.trackedPids);

        // 实机历史里抓到过 9e19 的网络桶（网卡计数器回绕），它会把 12h 累计带成 1e20。
        // 读回时用该桶的进程累计修复；不能让这个脏样本继续上屏。
        {
            NSString *badPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"deskboard-hist-bad-%@.plist", NSUUID.UUID.UUIDString]];
            long long bucket = (long long)floor([NSDate date].timeIntervalSince1970 / 60.0);
            NSDictionary *bad = @{
                @"v": @4,
                @"b": @{ [NSString stringWithFormat:@"%lld", bucket]: @{
                    @"s": @60.0,
                    @"sys": @[@0.0, @0.0, @0.0, @1e20],
                    @"p": @{ @"4242": @[@60.0, @0.0, @0.0, @0.0, @90000.0] }
                }}
            };
            NSData *bd = [NSPropertyListSerialization dataWithPropertyList:bad
                                                                     format:NSPropertyListBinaryFormat_v1_0
                                                                    options:0 error:NULL];
            [bd writeToFile:badPath atomically:YES];
            DeskHistory *BH = [[DeskHistory alloc] initWithPath:badPath];
            [BH load];
            double repaired = [BH totalForSystemMetric:DeskHistNetwork
                                                  now:[NSDate date].timeIntervalSince1970
                                               window:kDeskHistoryWindow covered:NULL];
            Say(fabs(repaired - 90000.0) < 1e-6,
                @"v4 脏网络桶读回时按进程累计修复：1e20 → %.0f", repaired);
            [[NSFileManager defaultManager] removeItemAtPath:badPath error:NULL];
        }
        // 能耗列在 v4 从"CPU%+唤醒×0.08"的估算分换成内核纳焦实测瓦数。
        // 量纲不同的旧桶必须整份丢掉，否则 12h 能耗平均会拿几十点当零点几瓦。
        {
            NSString *oldPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"deskboard-hist-old-%@.plist", NSUUID.UUID.UUIDString]];
            long long bucket = (long long)floor([NSDate date].timeIntervalSince1970 / 60.0);
            NSDictionary *oldv = @{
                @"v": @3,
                @"b": @{ [NSString stringWithFormat:@"%lld", bucket]: @{
                    @"s": @60.0,
                    @"sys": @[@0.0, @0.0, @0.0, @0.0],
                    @"p": @{ @"4242": @[@60.0, @0.0, @0.0, @35.0, @0.0] }
                }}
            };
            NSData *od = [NSPropertyListSerialization dataWithPropertyList:oldv
                                                                     format:NSPropertyListBinaryFormat_v1_0
                                                                    options:0 error:NULL];
            [od writeToFile:oldPath atomically:YES];
            DeskHistory *OH = [[DeskHistory alloc] initWithPath:oldPath];
            [OH load];
            Say(OH.recordedSeconds == 0,
                @"v3 的能耗估算分不混进 v4 的瓦数口径：旧历史整份丢弃（%.0fs）", OH.recordedSeconds);
            [[NSFileManager defaultManager] removeItemAtPath:oldPath error:NULL];
        }
        [[NSFileManager defaultManager] removeItemAtPath:hp error:NULL];
        // 实机抓到过一次：素材源自己不"变形"，所以 updateRows: 里那句按 isWarped 的
        // 缓动吸附没跑，烘出来的位图只有灰轨道、没有进度条。这条守住换拍后条子仍然满。
        mv.quadOffsets = mo;                      // 进变形态
        NSMutableArray<DeskProc *> *bake = [NSMutableArray array];
        for (int i = 0; i < 16; i++) {
            DeskProc *p = [DeskProc new];
            p.pid = (pid_t)(2000 + i);
            p.name = [NSString stringWithFormat:@"烘检进程 %02d", i];
            p.cpu = 50.0 - i; p.mem = 300e6; p.energy = 10.0; p.sockets = 3;
            [bake addObject:p];
        }
        [mv updateRows:bake];                     // 换一拍数据
        NSBitmapImageRep *baked = [mv bakedFlatBitmap];
        Say(baked != nil, @"烘得出位图（%ldx%ld）", (long)baked.pixelsWide, (long)baked.pixelsHigh);
        if (baked) {
            unsigned char *px = baked.bitmapData;
            NSUInteger spp = baked.bitsPerPixel / 8, n = baked.pixelsWide * baked.pixelsHigh, blue = 0;
            for (NSUInteger i = 0; i < n; i++) {
                unsigned char *q = px + i * spp;
                // CPU 榜那条蓝 (91,184,255)：条子要是停在 0，一个这种像素都不会有
                if (q[3] > 200 && labs((long)q[0] - 91) < 40 && labs((long)q[1] - 184) < 40
                    && labs((long)q[2] - 255) < 25) blue++;
            }
            Say(blue > 300, @"烘出来的位图里有 %lu 个进度条蓝像素 —— 素材源的条子没退回 0",
                (unsigned long)blue);
        }
        // 变形态画的是素材源烘出来的位图 —— 凡是"读数依赖的数"没搬过去，位图上就是另一个值。
        // 能耗占比差点栽在这：正形态印 41%、变形那张全印 0%。注意这条守的是"变形前后读数一致"
        // 这个不变量本身，**不是**守 takeSnapshotFrom 里某一行赋值：实测把 `_energyTotal = src->_energyTotal`
        // 加回去再删掉，215 条一条不动 —— 因为 updateRows: 会拿 _all 重算分母，那行赋值是冗余的（已删）。
        {
            DeskMonitorView *src = [mv flatSourceForVerify];
            Say(src != nil, @"变形态烘得出素材源");
            Say([src energyShareTotal] > 0 && fabs([src energyShareTotal] - [mv energyShareTotal]) < 0.001,
                @"素材源自己算出的分母 >0 且与本体相等：%.1f == %.1f",
                [src energyShareTotal], [mv energyShareTotal]);
            NSString *liveAgg = [mv aggregateTextForMetric:DeskMonitorMetricEnergy];
            NSString *flatAgg = [src aggregateTextForMetric:DeskMonitorMetricEnergy];
            Say([liveAgg isEqualToString:flatAgg], @"能耗榜头两边同一个串：「%@」/「%@」", flatAgg, liveAgg);
            NSString *liveRow = [mv valueTextFor:bake[0] metric:DeskMonitorMetricEnergy];
            NSString *flatRow = [src valueTextFor:bake[0] metric:DeskMonitorMetricEnergy];
            Say([liveRow isEqualToString:flatRow] && [liveRow hasSuffix:@"%"],
                @"同一行在正形态和变形态里读数一致：%@ / %@", liveRow, flatRow);
        }
        // 弹药库踩过这个坑：变形态画的是素材源烘出来的位图，setStyle: 不转给素材源的话
        // "一进调角，无论选哪种外观都退回默认样式"。这里换两次外观各烘一张，比像素。
        NSUInteger diff = 0;
        {
            NSBitmapImageRep *A = nil, *B = nil;
            mv.style = DeskStyleBare;  A = [mv bakedFlatBitmap];
            mv.style = DeskStylePlate; B = [mv bakedFlatBitmap];
            NSUInteger spp = A.bitsPerPixel / 8, n = A.pixelsWide * A.pixelsHigh;
            unsigned char *pa = A.bitmapData, *pb = B.bitmapData;
            for (NSUInteger k = 0; k < n; k++)
                if (pa[k * spp + 3] != pb[k * spp + 3]) diff++;
            Say(diff > n / 50, @"变形态下换外观真的换：Bare 与 Plate 有 %lu 像素 alpha 不同（%.1f%%）",
                (unsigned long)diff, (double)diff / n * 100);
        }
        mv.quadOffsets = DeskQuadOffsetsZero();

        mv.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        NSMutableArray<DeskProc *> *mk = [NSMutableArray array];
        for (int i = 0; i < 16; i++) {
            DeskProc *p = [DeskProc new];
            p.pid = (pid_t)(1000 + i);
            p.name = [NSString stringWithFormat:@"测试进程 %02d", i];
            p.cpu = 40.0 - i; p.mem = (400 - i * 20) * 1048576.0;
            p.energy = 30.0 - i; p.sockets = 8 - (i % 8);
            [mk addObject:p];
        }
        [mv updateRows:mk];
        NSRect r0 = [mv rowRectAtMetric:0 row:1 in:mv.bounds];
        NSInteger hitMetric = -1;
        Say([mv hitTestRowAt:NSMakePoint(NSMidX(r0), NSMidY(r0)) in:mv.bounds metric:&hitMetric] == 1
            && hitMetric == 0, @"命中测试认得是哪一榜的哪一行");
        NSRect otherRow = [mv rowRectAtMetric:2 row:0 in:mv.bounds];
        Say([mv hitTestRowAt:NSMakePoint(NSMidX(otherRow), NSMidY(otherRow)) in:mv.bounds
                        metric:&hitMetric] == 0 && hitMetric == 2,
            @"悬停只会点亮一行，不会四榜一起亮");

        // 刻度换算的回归哨兵：rusage 的 CPU 时间是 mach 刻度不是纳秒（本机 1 刻度 = 41.667ns）。
        // 忘了换算的话，一个跑满一核的进程只会读到 2.4%，榜就全是 0。这里自己烧一核来验。
        DeskProcsMonitor *pm = [DeskProcsMonitor new];
        [pm sample];
        volatile double burn = 0;
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.8];
        while ([until timeIntervalSinceNow] > 0) burn += sqrt(burn + 1.0001);
        NSArray<DeskProc *> *rows = [pm sample];
        DeskProc *me = nil;
        for (DeskProc *p in rows) if (p.pid == getpid()) me = p;
        Say(me != nil, @"采到了自己（pid %d）", (int)getpid());
        Say(me && me.cpu > 60.0,
            @"烧一核 0.8 秒后自报 %%CPU=%.1f（刻度算错只会读到 %.1f 上下）",
            me ? me.cpu : -1, me ? me.cpu / 41.667 : -1);
        // 能耗必须是内核 rusage 的实测瓦数，而不是旧公式 cpu + wakeups×0.08 的估算分。
        // 旧公式下同一个进程会报 ~80 分；实测瓦数应该在个位数。这条同时钉住数据来源和量纲。
        Say(me && me.energy > 0 && me.energy < 20.0,
            @"能耗取自 ri_energy_nj 实测瓦数：烧一核 0.8 秒 → %.3fW（旧估算公式会报 %.1f 分）",
            me ? me.energy : -1, me ? me.cpu + me.wakeups * 0.08 : -1);
        Say(me && me.mem > 1e6, @"内存这一拍就有值（%.0fM），不用等第二拍", me ? me.mem / 1e6 : 0);
        Say(rows.count > 50, @"这一拍读到 %lu 个本用户进程", (unsigned long)rows.count);
        NSInteger netSeen = 0;
        for (DeskProc *p in rows) if (p.netIn >= 0 && p.netOut >= 0) netSeen++;
        Say(netSeen > 0, @"nettop 单次采样读到 %ld 个进程的累计收发字节（每拍约 0.01s）", (long)netSeen);

        printf("\n油价下次窗口推算：过期就往后推，不许停在过去的日期\n");
        // 复现的就是用户报的那一幕：接口最新一行还停在 9/25，推算出来的 10/16 已经过了，
        // 数据于是长期带"10月16日 24:00 · 已过调价日"
        NSDictionary *row = @{ @"DIM_DATE": @"2026-09-25 00:00:00", @"V92": @8.57,
                               @"QE92": @8.25, @"ZDE92": @0.32 };
        NSMutableDictionary *facts = [NSMutableDictionary dictionary];
        NSString *feedErr = nil;
        NSString *body = [DeskOilFeed bodyFromRow:row facts:facts error:&feedErr];
        Say(body.length > 0 && !feedErr, @"拼得出正文（错误=%@）", feedErr ?: @"无");
        NSDictionary *out = body.length ? [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding]
                                                                         options:0 error:NULL] : nil;
        Say(out != nil, @"拼出来的 JSON 能解析（手工拼字符串容易漏逗号）");
        Say([out[@"daysLeft"] integerValue] >= 0,
            @"daysLeft=%@，不再是负数（负数就是「已过调价日」那一行）", out[@"daysLeft"]);
        NSString *nextDate = out[@"nextDate"];
        Say(nextDate.length > 0, @"下次窗口有值：%@", nextDate);
        // 关键一条：推算出的窗口必须晚于今天
        NSDateFormatter *md2 = [NSDateFormatter new];
        md2.dateFormat = @"M月d日";
        md2.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        NSString *todayText = [md2 stringFromDate:[NSDate date]];
        Say(![nextDate isEqualToString:todayText], @"下次窗口不是今天（今天=%@）", todayText);
        Say(out[@"pendingWindow"] != nil || [out[@"lastAdjust"] isEqualToString:@"2026-09-25"],
            @"过掉的窗口被记成 pendingWindow=%@，说明行会写「上期待发布」", out[@"pendingWindow"] ?: @"无");

        // 说明行已经不上屏（卡片只剩系统状态表格），这里只守数据层语义：
        // 待发布时不能把日期 + 时间 + 倒计时全叠上，正常时倒计时还得在。
        DeskModel *pm2 = [DeskModel modelFromDictionary:
                          @{ @"nextDate": @"10月30日", @"nextTime": @"24:00",
                             @"pendingWindow": @"10月16日", @"daysLeft": @13, @"price": @8.57 }];
        Say([pm2.infoLine containsString:@"上期待发布"] && ![pm2.infoLine containsString:@"还剩"],
            @"待发布时说明行换成短文案：%@", pm2.infoLine);
        DeskModel *nm2 = [DeskModel modelFromDictionary:
                          @{ @"nextDate": @"10月30日", @"nextTime": @"24:00",
                             @"daysLeft": @13, @"price": @8.57 }];
        Say([nm2.infoLine containsString:@"还剩"], @"正常时说明行带倒计时：%@", nm2.infoLine);

        // 实机对照实验（tools/probe_smooth.m，同一个字符串上屏三条路径各开一个窗口，
        // screencapture -l 逐窗抓真像素）：非 layer 直绘 / layer 背衬 / NSImage 贴图，
        // 三张的字缘暗像素都是 0.000%，亮像素完全相等 —— 图层根本不是"字带阴影"的原因。
        // 既然没差别，就跟着另外两块组件保持非 layer-backed，别单独开。
        Say(!mv.wantsLayer, @"活动监视器不是 layer-backed（实机测过：开图层不会改变字缘，纯跟着另两块走）");
        DeskVaultView *vv = [[DeskVaultView alloc] initWithItems:@[]];
        DeskPanelView *pv = [DeskPanelView new];
        Say(!vv.wantsLayer && !pv.wantsLayer, @"对照组：弹药库 / 卡片面板同样不是 layer-backed");
        DeskMonitorHoverView *hv = [DeskMonitorHoverView new];
        Say(!hv.wantsLayer, @"悬停浮层也不开图层");

        {
            // 抬头和底部图例已按用户要求整块删掉（2026-10-29），这里改成守"它们没有偷偷回来"。
            // 悬停气泡那两句解释同样是行级说明的唯一出处，被谁顺手删了就没人知道第三列是什么。
            NSString *src = [NSString stringWithContentsOfFile:@"monitor_view.m"
                                                      encoding:NSUTF8StringEncoding error:NULL];
            Say(src.length > 0, @"读到了 monitor_view.m 源码（这条断言的前提）");
            Say([src rangeOfString:@"条=现在 · 右列=12h（CPU/内存/能耗=均，网络=累计）"].location == NSNotFound,
                @"底部图例不再上屏（抬头/表尾已删）");
            Say([src rangeOfString:@"ACTIVITY MONITOR"].location == NSNotFound,
                @"抬头那行「ACTIVITY MONITOR · PROC-01 · N」不再上屏");
            Say([src rangeOfString:@"12h 平均 = 过去 12 小时"].location != NSNotFound,
                @"悬停气泡那句解释还在（①在行级的答案）");
            Say([src rangeOfString:@"双击看原生活动监视器"].location != NSNotFound,
                @"气泡里那条入口提示还在");
            Say([src rangeOfString:@"SYSTEM CPU"].location == NSNotFound,
                @"活动监视器没有 SYSTEM CPU 大读数");
            Say([src rangeOfString:@"VaultDrawRing"].location == NSNotFound,
                @"活动监视器没有整机 CPU 环");
        }
        {
            // 悬停里那行 12h 内存也必须和行内/榜头同一进制：都用 1024³ 并写明单位。
            DeskMonitorHoverView *h = [[DeskMonitorHoverView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
            h.histMetric = DeskMonitorMetricMemory;
            h.histCovered = 1.0;
            h.histAvg = 900 * 1048576.0;
            Say([[h historyText] isEqualToString:@"12h 900 MiB"],
                @"悬停 12h 内存用 MiB：「%@」", [h historyText]);
            h.histAvg = 1.5 * 1073741824.0;
            Say([[h historyText] isEqualToString:@"12h 1.5 GiB"],
                @"悬停 12h 内存 1.5 GiB →「%@」", [h historyText]);
            h.histMetric = DeskMonitorMetricNetwork;
            h.histAvg = 1.5e6;
            Say([[h historyText] isEqualToString:@"12h 1.5M/s"],
                @"悬停 12h 网络是速率不是连接数：「%@」", [h historyText]);
            h.histTotal = 3.4e9;
            Say([[h historyFoot] containsString:@"12h 累计 3.4G"],
                @"悬停网络底行给出 12h 累计：「%@」", [h historyFoot]);
            h.histTotal = -1;
            Say([[h historyFoot] containsString:@"流量=当前收发速率"],
                @"没有累计数据时底行退回速率说明：「%@」", [h historyFoot]);
        }
        {
            // 悬停气泡的「这个进程是干什么的」：查表、Helper 角色、App 包兜底、出处，
            // 以及最后一条 —— 认不出来就留白，不许编一句「未知进程」糊上去。
            Say([DeskProcIntroText(@"WindowServer", nil) containsString:@"窗口服务器"],
                @"系统进程介绍走内置表：%@", DeskProcIntroText(@"WindowServer", nil));
            NSString *chromeHelperPath = @"/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)";
            NSString *ci = DeskProcIntroText(@"Google Chrome Helper (Renderer)", chromeHelperPath);
            Say([ci containsString:@"Google Chrome"] && [ci containsString:@"渲染"],
                @"Helper 认得出所属应用与角色：%@", ci);
            NSString *unknown = DeskProcIntroText(@"Foo Studio",
                                                  @"/Applications/Foo Studio.app/Contents/MacOS/Foo Studio");
            Say([unknown containsString:@"Foo Studio"],
                @"表里没有的应用按 .app 包名兜底：%@", unknown);
            // 这家进程名是 UURemoteServer（UU + Remote），前缀里只有一个 r；
            // 写成 uurremote 时这条会退回「应用内的进程」，实机名字实测能抓出来。
            Say([DeskProcIntroText(@"UURemoteServer", @"/Applications/UURemote.app/Contents/Helpers/UURemoteServer")
                 containsString:@"UU 远程"],
                @"UU 远程按真实进程名前缀识别：%@",
                DeskProcIntroText(@"UURemoteServer", @"/Applications/UURemote.app/Contents/Helpers/UURemoteServer"));
            Say([DeskProcIntroText(@"zzz-no-such-thing", nil) length] == 0,
                @"既不在表里也拿不到路径 → 不编介绍，返回 nil");
            Say([DeskProcOriginText(@"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
                 isEqualToString:@"来自 /Applications/Google Chrome.app"],
                @"出处给 App 包路径而不是可执行文件：%@",
                DeskProcOriginText(@"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"));
            NSString *homePath = [NSHomeDirectory() stringByAppendingString:@"/bin/tool"];
            Say([DeskProcOriginText(homePath) containsString:@"~/bin/tool"],
                @"出处里的家目录缩成 ~：%@", DeskProcOriginText(homePath));
            NSString *ownPath = DeskProcExecutablePath(getpid());
            Say(ownPath.length > 0 && [ownPath hasSuffix:@"verify"],
                @"按 pid 取得到自己的可执行路径：%@", ownPath);
            Say([DeskProcIntroText(ownPath.lastPathComponent, ownPath) containsString:@"命令行"],
                @"家目录里的自建工具给诚实的兜底：%@", DeskProcIntroText(ownPath.lastPathComponent, ownPath));

            DeskMonitorHoverView *ih = [[DeskMonitorHoverView alloc]
                initWithFrame:NSMakeRect(0, 0, kDeskMonitorHoverSize.width, kDeskMonitorHoverSize.height)];
            ih.intro = @"短介绍。";
            Say([ih introLineCount] == 1, @"短介绍占 1 行");
            ih.intro = @"这是一条故意写得很长的介绍，用来确认气泡最多只给两行、多出来的会被省略号收掉，不会把下面的读数顶出气泡外。";
            Say([ih introLineCount] == 2, @"长介绍封顶 2 行（实得 %ld）", (long)[ih introLineCount]);
            Say(kDeskMonitorHoverSize.width == 240 && kDeskMonitorHoverSize.height >= 190,
                @"气泡定稿尺寸 %.0f×%.0f 容得下介绍",
                kDeskMonitorHoverSize.width, kDeskMonitorHoverSize.height);

            // 属性设了但 drawRect 没画，上面的断言照样全绿 —— 补一条源码闸
            NSString *hoverSrc = [NSString stringWithContentsOfFile:@"monitor_view.m"
                                                           encoding:NSUTF8StringEncoding error:NULL];
            Say([hoverSrc rangeOfString:@"MonPara(_intro"].location != NSNotFound,
                @"drawRect 真的把介绍画出来了（不是只存了属性）");
            Say([hoverSrc rangeOfString:@"MonPara(_origin"].location != NSNotFound,
                @"drawRect 真的把出处画出来了");
        }
        {
            // 存档夹边：只保证整块留在可视区，下限必须是 0。
            // 这条钉的是"拖不动"的真凶回归 —— 把下限改回 16，第一条立刻变红。
            NSRect vf2 = NSMakeRect(0, 0, 1512, 921);
            NSSize card = NSMakeSize(432, 294);
            DeskPlace p = DeskPlaceClamp((DeskPlace){ .corner = 1, .dx = -14, .dy = -14 }, card, vf2);
            Say(p.dx == 0 && p.dy == 0,
                @"贴边拖过头 → 夹到 0，不是 16（16 就是重申时弹回原位的真凶）：dx=%.0f dy=%.0f",
                p.dx, p.dy);
            DeskPlace q = DeskPlaceClamp((DeskPlace){ .corner = 1, .dx = 5000, .dy = 5000 }, card, vf2);
            Say(q.dx == vf2.size.width - card.width && q.dy == vf2.size.height - card.height,
                @"拖出另一侧 → 夹到整块刚好留在可视区内：dx=%.0f dy=%.0f", q.dx, q.dy);
            DeskPlace r = DeskPlaceClamp((DeskPlace){ .corner = 9, .dx = 40, .dy = 40 }, card, vf2);
            Say(r.corner == 1 && r.dx == 40 && r.dy == 40,
                @"角位越界被收敛，未越界的 dx/dy 原样保留：corner=%ld dx=%.0f dy=%.0f",
                (long)r.corner, r.dx, r.dy);
        }
        {
            // 「看得见的卡片框 → 角 + 距边」只留一套换算：四块组件落档和锁定时的位置记忆都走它。
            NSRect vf3 = NSMakeRect(0, 0, 1512, 921);
            NSSize card3 = NSMakeSize(432, 294);
            DeskPlace tr = DeskPlaceFromFrame(
                NSMakeRect(NSMaxX(vf3) - card3.width - 40, NSMaxY(vf3) - card3.height - 24,
                           card3.width, card3.height), card3, vf3);
            DeskPlace tl = DeskPlaceFromFrame(NSMakeRect(20, 600, card3.width, card3.height), card3, vf3);
            DeskPlace bl = DeskPlaceFromFrame(NSMakeRect(20, 30, card3.width, card3.height), card3, vf3);
            DeskPlace br = DeskPlaceFromFrame(
                NSMakeRect(NSMaxX(vf3) - card3.width - 12, 30, card3.width, card3.height), card3, vf3);
            Say(tr.corner == 1 && fabs(tr.dx - 40) < 0.1 && fabs(tr.dy - 24) < 0.1 &&
                tl.corner == 0 && fabs(tl.dx - 20) < 0.1 && fabs(tl.dy - 27) < 0.1 &&
                bl.corner == 2 && fabs(bl.dx - 20) < 0.1 && fabs(bl.dy - 30) < 0.1 &&
                br.corner == 3 && fabs(br.dx - 12) < 0.1 && fabs(br.dy - 30) < 0.1,
                @"窗口框 → 四角距边：右上 %.0f/%.0f 左上 %.0f/%.0f 左下 %.0f/%.0f 右下 %.0f/%.0f",
                tr.dx, tr.dy, tl.dx, tl.dy, bl.dx, bl.dy, br.dx, br.dy);
            NSRect (^rectFor)(DeskPlace) = ^NSRect(DeskPlace p) {
                CGFloat x = (p.corner == 1 || p.corner == 3) ? NSMaxX(vf3) - card3.width - p.dx
                                                             : NSMinX(vf3) + p.dx;
                CGFloat y = (p.corner >= 2) ? NSMinY(vf3) + p.dy
                                            : NSMaxY(vf3) - card3.height - p.dy;
                return NSMakeRect(x, y, card3.width, card3.height);
            };
            DeskPlace round = DeskPlaceFromFrame(rectFor(br), card3, vf3);
            Say(round.corner == br.corner && fabs(round.dx - br.dx) < 0.1 &&
                fabs(round.dy - br.dy) < 0.1,
                @"往返一致：右下保存后再摆回同一个框（角%ld %.0f/%.0f）",
                (long)round.corner, round.dx, round.dy);
            DeskPlace off = DeskPlaceFromFrame(NSMakeRect(-200, -200, card3.width, card3.height),
                                               card3, vf3);
            Say(off.corner == 2 && off.dx == 0 && off.dy == 0,
                @"拖出可视区被夹回边界，不存越界值：左下 %.0f/%.0f", off.dx, off.dy);
        }
        {
            printf("\n全局锁定：拖不动，解锁恢复\n");
            // 卡片面板：锁住后按下不进入拖窗态，连唯一的挪窗口也不动；解锁后恢复
            NSSize ps = [DeskCardView windowSizeForModel:oil style:DeskStylePlate warped:NO];
            NSWindow *pw = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, ps.width, ps.height)
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered defer:NO];
            DeskCardView *card = [[DeskCardView alloc] initWithModel:oil style:DeskStylePlate];
            pw.contentView = card;
            NSPoint mid = NSMakePoint(ps.width / 2.0, ps.height / 2.0);
            NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:mid
                                              modifierFlags:0 timestamp:[NSDate date].timeIntervalSince1970
                                           windowNumber:pw.windowNumber context:nil
                                            eventNumber:31 clickCount:1 pressure:1.0];
            NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:mid
                                            modifierFlags:0 timestamp:[NSDate date].timeIntervalSince1970
                                         windowNumber:pw.windowNumber context:nil
                                          eventNumber:32 clickCount:1 pressure:0.0];
            card.locked = YES;
            [card mouseDown:down];
            Say(![card isDragging], @"锁定后按住卡片不进入拖窗态");
            NSRect lockedFrame = pw.frame;
            [card dragWindowToMouse:NSMakePoint(NSEvent.mouseLocation.x + 60,
                                                NSEvent.mouseLocation.y + 40)];
            Say(NSEqualPoints(pw.frame.origin, lockedFrame.origin),
                @"锁定后连挪窗口也不动（锁在唯一出口上）");
            [card mouseUp:up];
            card.locked = NO;
            [card mouseDown:down];
            Say([card isDragging], @"解锁后按住卡片恢复拖窗态");
            [card dragWindowToMouse:NSMakePoint(NSEvent.mouseLocation.x + 60,
                                                NSEvent.mouseLocation.y + 40)];
            Say(fabs((pw.frame.origin.x - lockedFrame.origin.x) - 60.0) < 1.0 &&
                fabs((pw.frame.origin.y - lockedFrame.origin.y) - 40.0) < 1.0,
                @"解锁后挪窗跟上鼠标 (+60,+40)，实际 (%+.0f,%+.0f)",
                pw.frame.origin.x - lockedFrame.origin.x,
                pw.frame.origin.y - lockedFrame.origin.y);
            [card mouseUp:up];
            [pw orderOut:nil];

            // 弹药库：空白处按下被锁定拦住；解锁后恢复
            NSWindow *vw = [[NSWindow alloc] initWithContentRect:
                            NSMakeRect(200, 200, kVaultViewWidth, kVaultViewHeight)
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered defer:NO];
            DeskVaultView *vv = [[DeskVaultView alloc] initWithItems:@[]];
            vw.contentView = vv;
            NSPoint blank = NSMakePoint(NSMidX(vv.bounds), NSMidY(vv.bounds));
            NSEvent *vdown = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:blank
                                               modifierFlags:0 timestamp:[NSDate date].timeIntervalSince1970
                                            windowNumber:vw.windowNumber context:nil
                                             eventNumber:33 clickCount:1 pressure:1.0];
            NSEvent *vup = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:blank
                                             modifierFlags:0 timestamp:[NSDate date].timeIntervalSince1970
                                          windowNumber:vw.windowNumber context:nil
                                           eventNumber:34 clickCount:1 pressure:0.0];
            vv.locked = YES;
            [vv mouseDown:vdown];
            Say(![vv isDragging], @"锁定后按住弹药库空白处不进入拖窗态");
            [vv mouseUp:vup];
            vv.locked = NO;
            [vv mouseDown:vdown];
            Say([vv isDragging], @"解锁后按住弹药库空白处恢复拖窗态");
            [vv mouseUp:vup];
            [vw orderOut:nil];
        }

        printf("\n%d 项通过，%d 项失败\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
