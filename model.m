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

// 磁盘与速率按十进制（和"存储空间"一致）。
static NSString *GBText(double bytes, int digits) {
    return [NSString stringWithFormat:@"%.*f", digits, bytes / 1e9];
}

// 交换量按十进制 G/M，和内存/磁盘同一套习惯，不用 GiB。
static NSString *SwapSizeText(double bytes) {
    if (bytes >= 1e9) return [NSString stringWithFormat:@"%.1fG", bytes / 1e9];
    return [NSString stringWithFormat:@"%.0fM", MAX(0.0, bytes) / 1e6];
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

    // 涨跌额是接口自带的（调价那天才有），卡片靠它画红涨绿跌。
    // 缺这个字段说明还看不出涨跌，留空比画一个 ▲0.00 诚实。
    NSNumber *delta = NumField(dict, @"delta");
    if (delta && fabs(delta.doubleValue) > 0.001) {
        BOOL up = delta.doubleValue > 0;
        m.trendUp = up;
        m.trendText = [NSString stringWithFormat:@"%@%.2f", up ? @"▲" : @"▼", fabs(delta.doubleValue)];
    }

    NSString *nextDate = StrField(dict, @"nextDate");
    NSString *nextTime = StrField(dict, @"nextTime");
    NSString *days = DaysText(NumField(dict, @"daysLeft"));
    NSString *pending = StrField(dict, @"pendingWindow");
    NSMutableArray *info = [NSMutableArray array];
    // 说明行已经不上屏（卡片只剩系统状态），但这条数据还在；仍按"一行说得清"的口径拼，
    // 避免三个事实挤成一长句。上期待发布时让位：时间和倒计时都不留，只留日期 + 最该看见的话。
    if (pending.length && nextDate.length) {
        [info addObject:nextDate];
        [info addObject:@"上期待发布"];
    } else if (nextDate.length) {
        [info addObject:nextTime.length ? [NSString stringWithFormat:@"%@ %@", nextDate, nextTime] : nextDate];
    }
    // "还剩"只跟在真的还有几天后面：daysLeft=0 是"今天"、负数是"已过调价日"，
    // 无脑加前缀会拼出"还剩 今天"这种读不通的话
    if (!pending.length && days.length && ![days isEqualToString:@"\u2014"])
        [info addObject:days.integerValue > 0 ? [NSString stringWithFormat:@"还剩 %@", days] : days];
    m.infoLine = info.count ? [info componentsJoinedByString:@" · "] : @"";

    NSString *updatedAt = StrField(dict, @"updatedAt");
    NSMutableString *footer = [NSMutableString string];
    [footer appendString:updatedAt.length ? [NSString stringWithFormat:@"更新于 %@", updatedAt]
                                          : @"更新时间未知"];
    if ([dict[@"demo"] boolValue]) [footer appendString:@" · 演示数据"];
    // 标明这一版价是几号调出来的。价格本身不动声色的日子全靠它区分
    NSString *lastAdjust = StrField(dict, @"lastAdjust");
    if (lastAdjust.length >= 10) {
        [footer appendFormat:@" · %@ 调价", [lastAdjust substringWithRange:NSMakeRange(5, 5)]];
    }
    m.footer = [footer copy];

    return m;
}

+ (NSArray<DeskStatRow *> *)statRowsForStats:(DeskStats *)stats {
    if (!stats) return @[];
    NSMutableArray<DeskStatRow *> *rows = [NSMutableArray array];
    NSString *temp;
    // 温度条和状态词取 CPU / SSD 里更高的那个，不然会出现"条子还在正常段、
    // 状态却说偏高"的自相矛盾。两个都读不到才留 -1。
    double hotTemp = -1;
    if (stats.cpuTemp > 0) hotTemp = stats.cpuTemp;
    if (stats.ssdTemp > 0) hotTemp = MAX(hotTemp, stats.ssdTemp);
    double tempFrac = hotTemp > 0 ? MIN(hotTemp / 100.0, 1.0) : -1;
    if (stats.cpuTemp > 0) {
        temp = [NSString stringWithFormat:@"CPU %.1f°C", stats.cpuTemp];
    } else {
        temp = @"—";
    }
    // 两个温度必须各自带名，光印一个裸数字看不出是 CPU 还是 SSD。
    if (stats.ssdTemp > 0) {
        temp = stats.cpuTemp > 0
            ? [NSString stringWithFormat:@"CPU %.1f°C · SSD %.0f°C", stats.cpuTemp, stats.ssdTemp]
            : [NSString stringWithFormat:@"SSD %.0f°C", stats.ssdTemp];
    }
    [rows addObject:MakeStatRow(@"温度", temp, tempFrac)];

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
}

// 表尾左格。句式跟原生电源菜单一致：交流电/充电中/剩余 x:xx。
// 分钟为 0 或 -1 时不硬编时间，免得出现"剩余 0:00"。
+ (NSString *)batteryStatusTextForStats:(DeskStats *)stats {
    if (!stats || stats.batteryPercent < 0) return @"—";
    NSString *pct = [NSString stringWithFormat:@"%.0f%%",
                     MIN(100.0, MAX(0.0, stats.batteryPercent))];
    if (!stats.batteryOnAC) {
        if (stats.batteryMinutes > 0) {
            NSInteger h = stats.batteryMinutes / 60;
            NSInteger m = stats.batteryMinutes % 60;
            NSString *left = h > 0
                ? [NSString stringWithFormat:@"%ld:%02ld", (long)h, (long)m]
                : [NSString stringWithFormat:@"%ld 分", (long)m];
            return [NSString stringWithFormat:@"%@ · 剩余 %@", pct, left];
        }
        return [NSString stringWithFormat:@"%@ · 电池供电", pct];
    }
    if (stats.batteryCharging) return [NSString stringWithFormat:@"%@ · 充电中", pct];
    return [NSString stringWithFormat:@"%@ · 交流电", pct];
}

// 表尾右格之一：只印已用交换量，单位写出来。总量不塞进窄格，留给以后需要时再谈。
+ (NSString *)swapTextForStats:(DeskStats *)stats {
    if (!stats || stats.swapUsed < 0 || stats.swapTotal <= 0) return @"—";
    return SwapSizeText(stats.swapUsed);
}

// 表尾右格之二：1 分钟负载；三个负载值放不进 196pt 的格宽。
+ (NSString *)loadTextForStats:(DeskStats *)stats {
    if (!stats || stats.load1 < 0) return @"—";
    return [NSString stringWithFormat:@"%.2f", stats.load1];
}

@end
