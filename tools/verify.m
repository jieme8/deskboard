// 模型与布局的回归断言：不依赖界面，可直接跑。用法：verify <项目根目录>
#import <Foundation/Foundation.h>
#import "model.h"
#import "panel_view.h"
#import "places.h"
#import "sysmon.h"
#import "backdrop.h"
#import "vault.h"
#import "vault_view.h"


static int gFail = 0;
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
        Say(fabs(s2.width - kDeskPanelWidth) < 0.01, @"横版宽度= %.0f", s2.width);
        Say(s2.height < 90, @"没有系统区时只有油价三行居中 = %.0fpt 高", s2.height);


        printf("\n系统指标行格式化\n");
        DeskStats *fake = [DeskStats new];
        fake.cpu = 34.2; fake.gpu = 8; fake.memUsed = 12.9e9; fake.memTotal = 25.8e9;
        fake.diskFree = 214e9; fake.diskTotal = 494e9; fake.diskIsSSD = YES;
        fake.diskRead = 3.1e6; fake.diskWrite = 12.4e6;
        fake.cpuTemp = 61.5; fake.thermal = 1; fake.netInterface = @"en8"; fake.netAddress = @"192.168.31.23"; fake.netIsWiFi = NO;
        fake.netRecv = 1.24e6; fake.netSend = 340e3;
        NSArray<DeskStatRow *> *statRows = [DeskModel statRowsForStats:fake];
        Say(statRows.count == 8, @"指标行数= %lu（新增网速行）", (unsigned long)statRows.count);
        Say([StatAt(statRows, 0).value isEqualToString:@"34%"], @"CPU= %@", StatAt(statRows, 0).value);
        Say([StatAt(statRows, 1).value isEqualToString:@"8%"], @"GPU= %@", StatAt(statRows, 1).value);
        Say([StatAt(statRows, 3).value isEqualToString:@"↓1.2M ↑340K"], @"网速= %@", StatAt(statRows, 3).value);
        Say([StatAt(statRows, 4).value isEqualToString:@"50% · 12.0/24G"], @"内存带百分比= %@", StatAt(statRows, 4).value);
        Say(fabs(StatAt(statRows, 4).fraction - 0.5) < 0.01, @"内存进度条 %.2f", StatAt(statRows, 4).fraction);
        Say([StatAt(statRows, 5).label isEqualToString:@"磁盘 SSD"], @"磁盘标签= %@", StatAt(statRows, 5).label);
        Say([StatAt(statRows, 5).value isEqualToString:@"57% · 剩 214G"], @"磁盘带百分比= %@", StatAt(statRows, 5).value);
        BOOL hasIO = NO;
        for (DeskStatRow *r in statRows) if ([r.label containsString:@"读写"]) hasIO = YES;
        Say(!hasIO, @"读写 MB/s 行不再显示");
        DeskStats *noNet = [DeskStats new];
        noNet.cpu = -1; noNet.gpu = -1; noNet.netRecv = -1; noNet.netSend = -1;
        Say([StatAt([DeskModel statRowsForStats:noNet], 3).value isEqualToString:@"—"],
            @"网络速率还没取到基准时不假报 0");
        DeskStats *unknown = [DeskStats new];
        unknown.cpu = -1; unknown.gpu = -1; unknown.diskRead = -1; unknown.diskWrite = -1;
        NSArray<DeskStatRow *> *unkRows = [DeskModel statRowsForStats:unknown];
        Say([StatAt(unkRows, 0).value isEqualToString:@"—"], @"CPU 取不到 → %@", StatAt(unkRows, 0).value);
        Say([StatAt(unkRows, 2).value isEqualToString:@"—"], @"温度取不到 → %@", StatAt(unkRows, 2).value);
        Say([StatAt(statRows, 2).value isEqualToString:@"61.5°C"], @"CPU 温度紧跟 CPU/GPU = %@", StatAt(statRows, 2).value);
        Say([StatAt(statRows, 6).value isEqualToString:@"有线 · en8"], @"网络行= %@", StatAt(statRows, 6).value);
        Say([StatAt(statRows, 7).value isEqualToString:@"192.168.31.23"], @"IPv4= %@", StatAt(statRows, 7).value);
        DeskStats *nowifi = [DeskStats new]; nowifi.cpu = -1; nowifi.gpu = -1;
        nowifi.diskRead = -1; nowifi.diskWrite = -1;
        NSArray<DeskStatRow *> *offline = [DeskModel statRowsForStats:nowifi];
        Say([StatAt(offline, 6).value isEqualToString:@"未连接"], @"没默认路由时= %@", StatAt(offline, 6).value);
        Say([DeskModel statRowsForStats:nil].count == 0, @"没有指标就一行都不画");
        (void)s2;

        printf("\n本机真硬件实测\n");
        DeskSysMonitor *mon = [DeskSysMonitor new];
        [mon sample];   // 差值型指标要先取基线
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        DeskStats *live = [mon sample];
        Say(live.cpu >= 0 && live.cpu <= 100, @"CPU 实测 %.1f%%", live.cpu);
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

        printf("\n带系统区的面板尺寸\n");
        DeskModel *withStats = [DeskModel modelFromJSONFileAtPath:[root stringByAppendingPathComponent:@"mock/mock.json"]];
        [withStats updateStats:fake];
        NSSize sStats = [DeskPanelView sizeForModel:withStats];
        Say(sStats.height <= 130, @"横版 8 行指标分 4+4 两列后 = %.0fx%.0fpt（加网速行也没变高）",
            sStats.width, sStats.height);
        NSMutableArray<DeskStatRow *> *extra = [withStats.statRows mutableCopy];
        [extra addObject:[[DeskStatRow alloc] initWithLabel:@"额外" value:@"1" fraction:-1]];
        withStats.statRows = extra;
        Say(fabs([DeskPanelView sizeForModel:withStats].height - sStats.height - 19.0) < 0.01,
            @"两列都满 4 行后再加一行才 +19pt");
        withStats.statRows = [withStats.statRows subarrayWithRange:NSMakeRange(0, 6)];
        Say([DeskPanelView sizeForModel:withStats].height == sStats.height,
            @"6 行和 8 行一样高：行是往横里长的，不是往高处");

        printf("\n列宽不溢出（横版每行只能占自己那一列）\n");
        NSFont *labFont = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
        NSFont *valFont = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
        withStats.statRows = [DeskModel statRowsForStats:fake];
        NSUInteger n = withStats.statRows.count;
        BOOL overflow = NO;
        for (NSUInteger i = 0; i < n; i++) {
            DeskStatRow *r = withStats.statRows[i];
            CGFloat cx, cw;
            [DeskPanelView statColumnForIndex:i count:n x:&cx width:&cw];
            CGFloat need = [r.label sizeWithAttributes:@{NSFontAttributeName: labFont}].width
                         + [r.value sizeWithAttributes:@{NSFontAttributeName: valFont}].width + 8.0;
            if (need > cw) {
                overflow = YES;
                printf("    溢出：第 %lu 行 %s + %s = %.0fpt > 列宽 %.0fpt\n",
                       (unsigned long)i, r.label.UTF8String, r.value.UTF8String, need, cw);
            }
        }
        CGFloat cx0, cw0, cx1, cw1;
        [DeskPanelView statColumnForIndex:0 count:n x:&cx0 width:&cw0];
        [DeskPanelView statColumnForIndex:4 count:n x:&cx1 width:&cw1];   // 第 5 行起进长列
        Say(!overflow, @"8 行的标签+数值都放进各自列宽（短列 %.0fpt @x%.0f，长列 %.0fpt @x%.0f）",
            cw0, cx0, cw1, cx1);
        Say(cx1 > cx0 + cw0 && cx1 + cw1 <= kDeskPanelWidth, @"两列互不重叠且都在卡片内");

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
        Say(dflt.corner == 2 && dflt.dx == 12 && dflt.dy == 12, @"默认锚点=左下 12/12");
        DeskPlaceStore *store = [DeskPlaceStore new];
        DeskPlace miss = [store placeForKey:@"999-1x1"];
        Say(miss.corner == 2 && miss.dx == 12, @"没见过的档位返回默认，且 %lu 档（不写表）",
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
        Say(other.corner == 2 && other.dx == 12, @"别的屏不串档，走全局默认");
        DeskPlace noID = [reloaded placeForKey:@"9-1x1" displayID:nil];
        Say(noID.corner == 2, @"拿不到 displayID 时也不猜，走全局默认");
        DeskPlaceStore *dirty = [[DeskPlaceStore alloc]
            initWithDictionary:@{ @"x": @{ @"corner": @9, @"dx": @(-5), @"dy": @3 } }];
        DeskPlace fixed = [dirty placeForKey:@"x"];
        Say(fixed.corner == 2 && fixed.dx == 12 && fixed.dy == 12,
            @"越界/负值的数据夹回默认，不拿脏数去摆窗口");
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
            @"放弃待保存后不会污染存档（回到默认 角%ld 距%.0f/%.0f）",
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

        printf("\n变形后文字仍要铺满卡片那一圈\n");
        // 宿主窗口一旦被外窗尺寸带跑，素材会变成 600x241 而卡片内容只占它左上角那一块，
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
        Say(wp.length && [[NSFileManager defaultManager] fileExistsAtPath:wp], @"解析到桌面壁纸：%@",
            wp.lastPathComponent ?: @"(无)");
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

        // 拖动窗口的位移算式
        // 出过事故：视图是翻转坐标（左上原点），屏幕坐标是左下原点，
        // 曾经把 view 坐标和屏幕坐标直接相减，组件在拖动第一帧就瞬移到按下点的坐标。
        // 这里钉死"光标走多远，窗口就走多远"这条不变量。
        printf("\n弹药库拖动位移\n");
        NSRect dStart = NSMakeRect(171, 344, 432, 294);
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

        printf("\n%d 项通过，%d 项失败\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
