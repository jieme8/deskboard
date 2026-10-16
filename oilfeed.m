#import "oilfeed.h"

#pragma mark - 配置

static NSString *const kAPI = @"https://datacenter-web.eastmoney.com/api/data/v1/get";
static NSString *const kToken = @"894050c76af8597a853f5b408b759f5d";
static NSString *const kCity = @"上海";
static NSString *const kGrade = @"92号汽油";
static NSString *const kPriceKey = @"V92";
// 调价前价与涨跌额，接口自带。卡上的涨跌标记直接用它，不靠本地推算，
// 也就不用去 diff 缓存猜"是不是调过价"。
static NSString *const kPrevPriceKey = @"QE92";
static NSString *const kDeltaKey = @"ZDE92";
static NSString *const kSource = @"datacenter-web.eastmoney.com RPTA_WEB_YJ_JH";

// 零售价是发改委定的，10 个工作日才调一次，所以半小时拉一次已经绰绰有余。
// 再密没有意义：这个接口是非公开的，频繁请求反而容易被限流。
static const NSTimeInterval kRefreshInterval = 30.0 * 60.0;
static const NSInteger kWindowWorkdays = 10;

#pragma mark - 日志
// 和 main.m 的 DeskLog 写同一个文件，但这里独立留一份。
// 为了记一行抓取日志去改外壳的日志实现，不划算。

static void OilLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void OilLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *df;
    if (!df) {
        df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    }
    NSString *line = [NSString stringWithFormat:@"[%@] 油价：%@\n",
                      [df stringFromDate:[NSDate date]], msg];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/DeskBoard.log"];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (h) {
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } else {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

#pragma mark - 下次调价窗口推算

// 和 tools/refresh.py 的 HOLIDAYS 保持一致：只扣法定假日，不建模调休上班日
// （接口不提供这个信息），所以推算值可能差一两天，以官方公布为准。
static BOOL IsHoliday(NSDateComponents *c) {
    return c.year == 2026 && c.month == 10 && c.day >= 1 && c.day <= 7;
}

// 从上次调价日起再走 10 个工作日。
static NSDate *NextWindow(NSDate *last) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSCalendarUnit comps = NSCalendarUnitWeekday | NSCalendarUnitYear |
                           NSCalendarUnitMonth | NSCalendarUnitDay;
    NSDate *d = last;
    NSInteger n = 0;
    // 兜底上限：万一日历算出异常值，也不至于在这里死循环
    for (NSInteger guard = 0; guard < 400 && n < kWindowWorkdays; guard++) {
        d = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:d options:0];
        if (!d) return last;
        NSDateComponents *c = [cal components:comps fromDate:d];
        // NSCalendarUnitWeekday：1=周日 … 7=周六，工作日是 2…6
        if (c.weekday >= 2 && c.weekday <= 6 && !IsHoliday(c)) n++;
    }
    return d;
}

#pragma mark - 抓取

@implementation DeskOilFeed {
    NSString *_cachePath;
    NSTimer *_timer;
}

+ (void)startWithCachePath:(NSString *)cachePath {
    static DeskOilFeed *feed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        feed = [DeskOilFeed new];
        [feed startWithPath:cachePath];
    });
}

- (void)startWithPath:(NSString *)cachePath {
    _cachePath = [cachePath copy];
    // CommonModes：菜单-tracking 和拖拽期间也照常触发，不会被卡住
    _timer = [NSTimer scheduledTimerWithTimeInterval:kRefreshInterval
                                             target:self
                                           selector:@selector(fetch)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [self fetch];
}

- (NSURL *)requestURL {
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"reportName"] = @"RPTA_WEB_YJ_JH";
    p[@"columns"] = @"ALL";
    p[@"sortColumns"] = @"dim_date";
    p[@"sortTypes"] = @"-1";                      // 倒序，rows[0] 就是最新一次调价
    p[@"filter"] = [NSString stringWithFormat:@"(CITYNAME=\"%@\")", kCity];
    p[@"token"] = kToken;
    p[@"pageNumber"] = @"1";
    p[@"pageSize"] = @"1";
    p[@"source"] = @"WEB";
    NSURLComponents *comp = [NSURLComponents componentsWithString:kAPI];
    comp.queryItems = [NSArray arrayWithObjects:
                       [NSURLQueryItem queryItemWithName:@"reportName" value:p[@"reportName"]],
                       [NSURLQueryItem queryItemWithName:@"columns"    value:p[@"columns"]],
                       [NSURLQueryItem queryItemWithName:@"sortColumns" value:p[@"sortColumns"]],
                       [NSURLQueryItem queryItemWithName:@"sortTypes"   value:p[@"sortTypes"]],
                       [NSURLQueryItem queryItemWithName:@"filter"      value:p[@"filter"]],
                       [NSURLQueryItem queryItemWithName:@"token"       value:p[@"token"]],
                       [NSURLQueryItem queryItemWithName:@"pageNumber"  value:p[@"pageNumber"]],
                       [NSURLQueryItem queryItemWithName:@"pageSize"    value:p[@"pageSize"]],
                       [NSURLQueryItem queryItemWithName:@"source"      value:p[@"source"]],
                       nil];
    return comp.URL;
}

// 把接口最新一行拼成和 mock.json 同形状的正文，并把这次调价的关键数字
// 顺手塞进 facts，供外层判"是不是调价了"时播报。
// 手工拼字符串而不是 NSJSONSerialization：后者走 NSDictionary 不保序，
// 写出来的键顺序每次都可能变，仓库里那份 mock/mock.json 就没法干净地 diff。
+ (NSString *)bodyFromRow:(NSDictionary *)row
                    facts:(NSMutableDictionary *)facts
                     error:(NSString **)err {
    id price = row[kPriceKey];
    if (![price isKindOfClass:[NSNumber class]] || [price doubleValue] <= 0) {
        if (err) *err = [NSString stringWithFormat:@"%@ 的 %@ 是空值", kCity, kGrade];
        return nil;
    }
    NSString *dim = [row[@"DIM_DATE"] isKindOfClass:[NSString class]] ? row[@"DIM_DATE"] : @"";
    if (dim.length < 10) {
        if (err) *err = @"接口返回的 DIM_DATE 不认识";
        return nil;
    }
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateFormatter *ymd = [NSDateFormatter new];
    ymd.dateFormat = @"yyyy-MM-dd";
    ymd.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSDate *last = [ymd dateFromString:[dim substringToIndex:10]];
    if (!last) {
        if (err) *err = @"调价日期解析失败";
        return nil;
    }

    NSDate *nxt = NextWindow(last);
    NSDateFormatter *md = [NSDateFormatter new];
    md.dateFormat = @"M月d日";
    md.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSDateFormatter *hm = [NSDateFormatter new];
    hm.dateFormat = @"HH:mm";
    hm.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSDateFormatter *iso = [NSDateFormatter new];
    iso.dateFormat = @"yyyy-MM-dd";
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    NSDate *now = [NSDate date];
    NSInteger daysLeft = [cal components:NSCalendarUnitDay
                                fromDate:[cal startOfDayForDate:now]
                                  toDate:nxt
                                 options:0].day;

    id prev = row[kPrevPriceKey];
    id delta = row[kDeltaKey];
    BOOL hasPrev = [prev isKindOfClass:[NSNumber class]];
    BOOL hasDelta = [delta isKindOfClass:[NSNumber class]] && fabs([delta doubleValue]) > 0.001;

    if (facts) {
        facts[@"lastAdjust"] = [iso stringFromDate:last];
        facts[@"price"] = price;
        if (hasPrev) facts[@"prev"] = prev;
        if (hasDelta) facts[@"delta"] = delta;
    }

    NSMutableString *js = [NSMutableString stringWithFormat:
                           @"{\n"
                           @"  \"city\": \"%@\",\n"
                           @"  \"grade\": \"%@\",\n"
                           @"  \"price\": %.2f,\n"
                           @"  \"unit\": \"元/升\",\n"
                           @"  \"nextDate\": \"%@\",\n"
                           @"  \"nextTime\": \"24:00\",\n"
                           @"  \"daysLeft\": %ld,\n"
                           @"  \"updatedAt\": \"%@\",\n"
                           @"  \"demo\": false,\n",
                           kCity, kGrade, [price doubleValue],
                           [md stringFromDate:nxt], (long)daysLeft,
                           [hm stringFromDate:now]];
    // 这两个只有接口给了才写，卡片那边也就只在有值时才画涨跌标记
    if (hasPrev) [js appendFormat:@"  \"prevPrice\": %.2f,\n", [prev doubleValue]];
    if (hasDelta) [js appendFormat:@"  \"delta\": %.2f,\n", [delta doubleValue]];
    [js appendFormat:@"  \"lastAdjust\": \"%@\",\n"
                      @"  \"from\": \"%@\"\n"
                      @"}\n",
                      [iso stringFromDate:last], kSource];
    return js;
}

- (void)fetch {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[self requestURL]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:20.0];
    [req setValue:@"DeskBoard/0.1" forHTTPHeaderField:@"User-Agent"];

    // 断网/接口改版/被限流都落这里：不写盘，保留旧缓存，卡片不会空窗
    __weak DeskOilFeed *weakSelf = self;
    [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        DeskOilFeed *self = weakSelf;
        if (!self) return;
        if (err) {
            OilLog(@"拉取失败，沿用旧缓存：%@", err.localizedDescription);
            return;
        }
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]]
                             ? ((NSHTTPURLResponse *)resp).statusCode : 200;
        if (code != 200 || !data) {
            OilLog(@"接口返回 %ld，沿用旧缓存", (long)code);
            return;
        }
        NSString *errText = nil;
        NSMutableDictionary *facts = [NSMutableDictionary dictionary];
        NSString *body = [self bodyFromResponseData:data facts:facts error:&errText];
        if (!body) {
            OilLog(@"解析失败，沿用旧缓存：%@", errText ?: @"未知原因");
            return;
        }
        // 先播报再写盘：播报要拿的是"上一次盘上的调价日"
        [self announceAdjustment:facts];
        [self commitBody:body];
    }] resume];
}

- (NSString *)bodyFromResponseData:(NSData *)data
                             facts:(NSMutableDictionary *)facts
                             error:(NSString **)err {
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (err) *err = @"返回不是 JSON 对象";
        return nil;
    }
    NSDictionary *root = json;
    if (![root[@"success"] boolValue]) {
        if (err) *err = root[@"message"] ?: @"接口报告失败";
        return nil;
    }
    NSArray *rows = [root[@"result"] isKindOfClass:[NSDictionary class]]
                        ? root[@"result"][@"data"] : nil;
    if (![rows isKindOfClass:[NSArray class]] || ![rows.firstObject isKindOfClass:[NSDictionary class]]) {
        if (err) *err = @"result.data 是空的";
        return nil;
    }
    return [DeskOilFeed bodyFromRow:rows.firstObject facts:facts error:err];
}

// 读出盘上那份缓存的调价日。拿它和接口返回的比，不一样就是真调过价了。
- (NSString *)cachedLastAdjust {
    NSData *d = [NSData dataWithContentsOfFile:_cachePath];
    if (!d) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    id v = json[@"lastAdjust"];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

// 调价日变了就单独播报一条，别混在"已更新"里被当成例行刷新划过去。
- (void)announceAdjustment:(NSDictionary *)facts {
    NSString *before = [self cachedLastAdjust];
    NSString *after = facts[@"lastAdjust"];
    // 首次运行盘上是空的，没有"上一次"可比，那就不播报——那不是调价，是初次落盘
    if (!before.length || ![after isKindOfClass:[NSString class]] || [before isEqualToString:after]) return;

    double delta = [facts[@"delta"] doubleValue];
    NSNumber *prev = facts[@"prev"];
    NSString *arrow = delta < 0 ? @"跌" : @"涨";
    if (prev) {
        OilLog(@"★ 调价：%@%@ %.2f → %.2f（%@ %.2f），自 %@ 起执行",
               kCity, kGrade, prev.doubleValue, [facts[@"price"] doubleValue],
               arrow, fabs(delta), after);
    } else {
        OilLog(@"★ 调价：%@%@ 现价 %.2f（%@ %.2f），自 %@ 起执行",
               kCity, kGrade, [facts[@"price"] doubleValue], arrow, fabs(delta), after);
    }
}

- (void)commitBody:(NSString *)body {
    // 内容一模一样就别写：每写一次 mtime 就变，卡片会白重画一趟
    NSString *old = [NSString stringWithContentsOfFile:_cachePath
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (old && [old isEqualToString:body]) return;

    NSError *err = nil;
    if (![body writeToFile:_cachePath atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        OilLog(@"写缓存失败：%@", err.localizedDescription);
        return;
    }
    OilLog(@"已更新 %@", _cachePath);
}

@end
