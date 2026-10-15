#import "model.h"
#import "sysmon.h"

@implementation DeskStatRow
- (instancetype)initWithLabel:(NSString *)label value:(NSString *)value fraction:(double)fraction {
    if ((self = [super init])) {
        _label = [label copy];
        _value = [value copy];
        _fraction = fraction;
    }
    return self;
}
@end

static NSString *StrField(NSDictionary *d, NSString *key) {
    id v = d[key];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSNumber *NumField(NSDictionary *d, NSString *key) {
    id v = d[key];
    return [v isKindOfClass:[NSNumber class]] ? v : nil;
}

static DeskStatRow *MakeStatRow(NSString *label, NSString *value, double fraction) {
    return [[DeskStatRow alloc] initWithLabel:label value:value fraction:fraction];
}

static NSString *PercentText(double v) {
    return v < 0 ? @"—" : [NSString stringWithFormat:@"%.0f%%", v];
}

// 内存按 GiB 显示（和"关于本机"里的内存容量口径一致），磁盘与速率按十进制
// （和"存储空间"一致），两套口径是系统自己的显示习惯，统一成一个反而会和你看到的数字对不上。
static NSString *GiBText(double bytes, int digits) {
    return [NSString stringWithFormat:@"%.*f", digits, bytes / (1024.0 * 1024.0 * 1024.0)];
}

static NSString *GBText(double bytes, int digits) {
    return [NSString stringWithFormat:@"%.*f", digits, bytes / 1e9];
}

static NSString *RateText(double bytesPerSec) {
    if (bytesPerSec < 0) return @"—";
    double m = bytesPerSec / 1e6;
    if (m >= 10) return [NSString stringWithFormat:@"%.0fM", m];
    if (m >= 1) return [NSString stringWithFormat:@"%.1fM", m];
    return [NSString stringWithFormat:@"%.0fK", bytesPerSec / 1e3];
}

static NSString *DaysText(NSNumber *daysLeft) {
    if (!daysLeft) return @"—";
    NSInteger d = daysLeft.integerValue;
    if (d < 0) return @"已过调价日";
    if (d == 0) return @"今天";
    return [NSString stringWithFormat:@"%ld 天", (long)d];
}

@implementation DeskModel

+ (instancetype)placeholderModel {
    DeskModel *m = [DeskModel new];
    m.title = @"油价";
    m.price = @"—";
    m.unit = @"";
    m.infoLine = @"";
    m.footer = @"暂无数据";
    return m;
}

+ (instancetype)modelFromJSONFileAtPath:(NSString *)path {
    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&err];
    if (!data) {
        DeskModel *m = [self placeholderModel];
        m.loadError = err.localizedDescription ?: @"配置文件读取失败";
        return m;
    }
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![dict isKindOfClass:[NSDictionary class]]) {
        DeskModel *m = [self placeholderModel];
        m.loadError = err.localizedDescription ?: @"配置不是 JSON 对象";
        return m;
    }
    DeskModel *m = [self modelFromDictionary:dict];
    return m;
}

+ (instancetype)modelFromDictionary:(NSDictionary *)dict {
    DeskModel *m = [DeskModel new];

    NSString *city = StrField(dict, @"city");
    NSString *grade = StrField(dict, @"grade");
    NSMutableArray *parts = [NSMutableArray array];
    if (city.length) [parts addObject:city];
    if (grade.length) [parts addObject:grade];
    m.title = parts.count ? [parts componentsJoinedByString:@" · "] : @"油价";

    NSNumber *price = NumField(dict, @"price");
    m.price = price ? [NSString stringWithFormat:@"%.2f", price.doubleValue] : @"—";
    NSString *unit = StrField(dict, @"unit");
    m.unit = unit ?: @"";

    NSString *nextDate = StrField(dict, @"nextDate");
    NSString *nextTime = StrField(dict, @"nextTime");
    NSString *days = DaysText(NumField(dict, @"daysLeft"));
    NSMutableArray *info = [NSMutableArray array];
    if (nextDate.length) {
        [info addObject:nextTime.length ? [NSString stringWithFormat:@"%@ %@", nextDate, nextTime] : nextDate];
    }
    if (days.length && ![days isEqualToString:@"\u2014"]) [info addObject:[NSString stringWithFormat:@"还剩 %@", days]];
    m.infoLine = info.count ? [info componentsJoinedByString:@" · "] : @"";

    NSString *updatedAt = StrField(dict, @"updatedAt");
    NSMutableString *footer = [NSMutableString string];
    [footer appendString:updatedAt.length ? [NSString stringWithFormat:@"更新于 %@", updatedAt]
                                          : @"更新时间未知"];
    if ([dict[@"demo"] boolValue]) [footer appendString:@" · 演示数据"];
    m.footer = [footer copy];

    return m;
}

+ (NSArray<DeskStatRow *> *)statRowsForStats:(DeskStats *)stats {
    if (!stats) return @[];
    NSMutableArray<DeskStatRow *> *rows = [NSMutableArray array];
    [rows addObject:MakeStatRow(@"CPU", PercentText(stats.cpu),
                               stats.cpu < 0 ? -1 : stats.cpu / 100.0)];
    [rows addObject:MakeStatRow(@"GPU", PercentText(stats.gpu),
                               stats.gpu < 0 ? -1 : stats.gpu / 100.0)];
    NSString *temp = stats.cpuTemp <= 0 ? @"—" : [NSString stringWithFormat:@"%.1f°C", stats.cpuTemp];
    [rows addObject:MakeStatRow(@"温度", temp, stats.cpuTemp <= 0 ? -1 : MIN(stats.cpuTemp / 100.0, 1.0))];

    NSString *rate = (stats.netRecv < 0 || stats.netSend < 0)
        ? @"—"
        : [NSString stringWithFormat:@"↓%@ ↑%@", RateText(stats.netRecv), RateText(stats.netSend)];
    [rows addObject:MakeStatRow(@"网速", rate, -1)];

    double memFrac = stats.memFraction;
    NSString *mem = memFrac < 0 ? @"—"
        : [NSString stringWithFormat:@"%.0f%% · %@/%@G", memFrac * 100.0,
           GiBText(stats.memUsed, 1), GiBText(stats.memTotal, 0)];
    [rows addObject:MakeStatRow(@"内存", mem, memFrac)];

    double diskFrac = stats.diskFraction;
    NSString *disk = diskFrac < 0 ? @"—"
        : [NSString stringWithFormat:@"%.0f%% · 剩 %@G", diskFrac * 100.0, GBText(stats.diskFree, 0)];
    [rows addObject:MakeStatRow(stats.diskIsSSD ? @"磁盘 SSD" : @"磁盘", disk, diskFrac)];

    NSString *net = stats.netInterface.length
        ? [NSString stringWithFormat:@"%@ · %@", stats.netIsWiFi ? @"Wi-Fi" : @"有线", stats.netInterface]
        : @"未连接";
    [rows addObject:MakeStatRow(@"网络", net, -1)];
    [rows addObject:MakeStatRow(@"IPv4", stats.netAddress.length ? stats.netAddress : @"—", -1)];
    return [rows copy];
}

- (void)updateStats:(DeskStats *)stats {
    self.stats = stats;
    self.statRows = [DeskModel statRowsForStats:stats];
    self.statsHeader = self.statRows.count ? @"系统状态" : nil;
}

@end
