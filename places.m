#import "places.h"

static const NSUInteger kMaxPlaces = 12;

DeskPlace DeskPlaceDefaultForKind(DeskPlaceKind kind) {
    DeskPlace p = { 0, 16.0, 16.0 };
    if (kind == DeskPlaceKindPanel) p.corner = 1;    // 系统状态：右上
    if (kind == DeskPlaceKindMonitor) p.corner = 3;  // 活动监视器：右下
    if (kind == DeskPlaceKindVault) p.corner = 2;    // 弹药库：左下
    if (kind == DeskPlaceKindCredits) p.corner = 0;  // 签到：左上
    return p;
}

NSDictionary<NSString *, NSString *> *DeskPlaceKeysByDisplayFromSignature(NSString *signature) {
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    for (NSString *part in [signature componentsSeparatedByString:@"|"]) {
        NSRange dash = [part rangeOfString:@"-"];
        if (dash.location == NSNotFound) continue;
        NSString *displayID = [part substringToIndex:dash.location];
        NSString *rest = [part substringFromIndex:NSMaxRange(dash)];
        NSRange plus = [rest rangeOfString:@"+"];
        NSString *size = plus.location == NSNotFound ? rest : [rest substringToIndex:plus.location];
        if (displayID.length && size.length) {
            out[displayID] = [NSString stringWithFormat:@"%@-%@", displayID, size];
        }
    }
    return out;
}

@implementation DeskPlaceStore {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_table;
    NSMutableDictionary<NSString *, NSDictionary *> *_pending;
    DeskPlace _fallback;
}

DeskPlace DeskPlaceClamp(DeskPlace p, NSSize card, NSRect vf) {
    p.corner &= 3;
    CGFloat maxDx = MAX(0, vf.size.width - card.width);
    CGFloat maxDy = MAX(0, vf.size.height - card.height);
    p.dx = MIN(MAX(p.dx, 0), maxDx);
    p.dy = MIN(MAX(p.dy, 0), maxDy);
    return p;
}

// 卡片中心落在哪半屏就归哪个角；dx/dy 永远描述"看得见的那块"离锚点角多远。
// 先算再夹，贴边/拖过头都收敛到"整块仍留在可视区内"，下限 0 不再弹回 16。
DeskPlace DeskPlaceFromFrame(NSRect f, NSSize card, NSRect vf) {
    DeskPlace p;
    p.corner = (NSMidY(f) > NSMidY(vf) ? 0 : 2)
             + (NSMidX(f) > NSMidX(vf) ? 1 : 0);
    p.dx = MAX(0, (p.corner == 1 || p.corner == 3) ? NSMaxX(vf) - NSMaxX(f)
                                                    : NSMinX(f) - NSMinX(vf));
    p.dy = MAX(0, (p.corner >= 2) ? NSMinY(f) - NSMinY(vf)
                                  : NSMaxY(vf) - NSMaxY(f));
    return DeskPlaceClamp(p, card, vf);
}

+ (DeskPlace)defaultPlace {    DeskPlace p = { 2, 12.0, 12.0 };   // 通用兜底；组件锚点见 DeskPlaceDefaultForKind
    return p;
}

+ (NSString *)keyWithDisplayID:(NSInteger)displayID width:(NSInteger)w height:(NSInteger)h {
    return [NSString stringWithFormat:@"%ld-%ldx%ld", (long)displayID, (long)w, (long)h];
}

- (instancetype)init {
    return [self initWithDictionary:nil defaultPlace:[DeskPlaceStore defaultPlace]];
}

- (instancetype)initWithDictionary:(NSDictionary<NSString *, NSDictionary *> *)dict {
    return [self initWithDictionary:dict defaultPlace:[DeskPlaceStore defaultPlace]];
}

- (instancetype)initWithDictionary:(NSDictionary<NSString *, NSDictionary *> *)dict
                      defaultPlace:(DeskPlace)defaultPlace {
    if ((self = [super init])) {
        _fallback = defaultPlace;
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

- (DeskPlace)fallbackPlace { return _fallback; }

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
    for (NSString *key in _pending) [self setPlace:ParsePlace(_pending[key], _fallback) forKey:key];
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

static DeskPlace ParsePlace(NSDictionary *inner, DeskPlace fallback) {
    DeskPlace p = fallback;
    if (!inner) return p;
    NSNumber *c = inner[@"corner"];
    NSNumber *x = inner[@"dx"];
    NSNumber *y = inner[@"dy"];
    if (c) p.corner = c.integerValue;
    if (x) p.dx = x.doubleValue;
    if (y) p.dy = y.doubleValue;
    if (p.corner < 0 || p.corner > 3 || p.dx < 0 || p.dy < 0) return fallback;
    return p;
}

- (DeskPlace)placeForKey:(NSString *)key {
    return [self placeForKey:key displayID:nil];
}

// 没见过的档位别直接拍全局默认：同一块屏上最近用过的位置更像"原来的地方"，
// 首次切到这个分辨率时组件应该大致还在那，而不是突然跳到左下角
- (DeskPlace)placeForKey:(NSString *)key displayID:(NSNumber *)displayID {
    if (key && _table[key]) return ParsePlace(_table[key], _fallback);
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
        if (best) return ParsePlace(_table[best], _fallback);
    }
    return _fallback;
}

- (DeskPlace)effectivePlaceForScreen:(NSScreen *)screen {
    NSString *key = [self keyForScreen:screen];
    NSDictionary *p = key ? _pending[key] : nil;
    return p ? ParsePlace(p, _fallback) : [self placeForScreen:screen];
}

- (DeskPlace)placeForScreen:(NSScreen *)screen {
    if (!screen) return _fallback;
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

- (void)setPlace:(DeskPlace)p forKeysMatchingDisplayID:(NSString *)displayID {
    if (!displayID.length) return;
    NSString *prefix = [displayID stringByAppendingString:@"-"];
    for (NSString *k in [_table.allKeys copy]) {
        if ([k hasPrefix:prefix]) [self setPlace:p forKey:k];
    }
}

@end
