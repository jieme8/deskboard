#import "places.h"

static const NSUInteger kMaxPlaces = 12;

@implementation DeskPlaceStore {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_table;
    NSMutableDictionary<NSString *, NSDictionary *> *_pending;
}

+ (DeskPlace)defaultPlace {
    DeskPlace p = { 2, 12.0, 12.0 };   // 左下角：实测壁纸那里最安静
    return p;
}

+ (NSString *)keyWithDisplayID:(NSInteger)displayID width:(NSInteger)w height:(NSInteger)h {
    return [NSString stringWithFormat:@"%ld-%ldx%ld", (long)displayID, (long)w, (long)h];
}

- (instancetype)init {
    return [self initWithDictionary:nil];
}

- (instancetype)initWithDictionary:(NSDictionary<NSString *, NSDictionary *> *)dict {
    if ((self = [super init])) {
        _table = [NSMutableDictionary dictionary];
        _pending = [NSMutableDictionary dictionary];
        for (NSString *key in dict) {
            NSDictionary *inner = dict[key];
            if ([inner isKindOfClass:[NSDictionary class]]) {
                _table[key] = [inner mutableCopy];
            }
        }
    }
    return self;
}

- (NSDictionary<NSString *, NSDictionary *> *)dictionary {
    return [_table copy];
}

- (NSUInteger)count { return _table.count; }

- (NSUInteger)pendingCount { return _pending.count; }

// 拖动只进这里；点「保存」才落到 _table。系统迁移窗口触发的移动根本不会走到这一步
- (void)setPending:(DeskPlace)p forKey:(NSString *)key {
    if (!key.length) return;
    _pending[key] = @{ @"corner": @(p.corner), @"dx": @(p.dx), @"dy": @(p.dy) };
}

- (BOOL)commitPending {
    if (_pending.count == 0) return NO;
    for (NSString *key in _pending) [self setPlace:ParsePlace(_pending[key]) forKey:key];
    [_pending removeAllObjects];
    return YES;
}

- (void)discardPending { [_pending removeAllObjects]; }

- (NSString *)keyForScreen:(NSScreen *)screen {
    NSNumber *num = screen.deviceDescription[@"NSScreenNumber"];
    if (!num) return nil;
    return [DeskPlaceStore keyWithDisplayID:num.integerValue
                                      width:(NSInteger)round(screen.frame.size.width)
                                     height:(NSInteger)round(screen.frame.size.height)];
}

static DeskPlace ParsePlace(NSDictionary *inner) {
    DeskPlace p = [DeskPlaceStore defaultPlace];
    if (!inner) return p;
    NSNumber *c = inner[@"corner"];
    NSNumber *x = inner[@"dx"];
    NSNumber *y = inner[@"dy"];
    if (c) p.corner = c.integerValue;
    if (x) p.dx = x.doubleValue;
    if (y) p.dy = y.doubleValue;
    if (p.corner < 0 || p.corner > 3 || p.dx < 0 || p.dy < 0) return [DeskPlaceStore defaultPlace];
    return p;
}

- (DeskPlace)placeForKey:(NSString *)key {
    return [self placeForKey:key displayID:nil];
}

// 没见过的档位别直接拍全局默认：同一块屏上最近用过的位置更像"原来的地方"，
// 首次切到这个分辨率时组件应该大致还在那，而不是突然跳到左下角
- (DeskPlace)placeForKey:(NSString *)key displayID:(NSNumber *)displayID {
    if (key && _table[key]) return ParsePlace(_table[key]);
    if (displayID) {
        NSString *prefix = [NSString stringWithFormat:@"%ld-", (long)displayID.integerValue];
        NSString *best = nil;
        double bestAt = 0;
        for (NSString *k in _table) {
            if (![k hasPrefix:prefix]) continue;
            NSNumber *at = _table[k][@"at"];
            double t = at ? at.doubleValue : 0;
            if (t > bestAt) { bestAt = t; best = k; }
        }
        if (best) return ParsePlace(_table[best]);
    }
    return [DeskPlaceStore defaultPlace];
}

- (DeskPlace)effectivePlaceForScreen:(NSScreen *)screen {
    NSString *key = [self keyForScreen:screen];
    NSDictionary *p = key ? _pending[key] : nil;
    return p ? ParsePlace(p) : [self placeForScreen:screen];
}

- (DeskPlace)placeForScreen:(NSScreen *)screen {
    if (!screen) return [DeskPlaceStore defaultPlace];
    return [self placeForKey:[self keyForScreen:screen]
                   displayID:screen.deviceDescription[@"NSScreenNumber"]];
}

- (void)setPlace:(DeskPlace)p forKey:(NSString *)key {
    if (!key.length) return;
    _table[key] = [@{ @"corner": @(p.corner), @"dx": @(p.dx), @"dy": @(p.dy),
                      @"at": @(CFAbsoluteTimeGetCurrent()) } mutableCopy];
    if (_table.count > kMaxPlaces) {
        NSString *oldest = nil;
        double oldestAt = DBL_MAX;
        for (NSString *k in _table) {
            NSNumber *at = _table[k][@"at"];
            double t = at ? at.doubleValue : 0;
            if (t < oldestAt) { oldestAt = t; oldest = k; }
        }
        if (oldest) [_table removeObjectForKey:oldest];
    }
}

@end
