#import "credits_view.h"
#import "trae_credits.h"
#import "qoder_credits.h"
#import "workbuddy_credits.h"
#import "backdrop.h"
#import "vault_art.h"

const CGFloat kCreditsViewWidth = 700.0;
const CGFloat kCreditsViewHeight = 132.0;

static const CGFloat kPadX = 12.0;
static const CGFloat kPadTop = 10.0;
static const CGFloat kPadBottom = 8.0;
static const CGFloat kTileGap = 10.0;
static const CGFloat kTilePadX = 9.0;
static const CGFloat kTilePadTop = 7.0;
static const NSInteger kSlotCount = 4;

static NSColor *CreditsRed(void) {
    return [NSColor colorWithSRGBRed:1.0 green:0.42 blue:0.42 alpha:1.0];
}

// 和卡片面板的 PanelAmber 同一支琥珀；VaultWarn 是珊瑚红，不能拿来当“待签”
static NSColor *CreditsAmber(void) {
    return [NSColor colorWithSRGBRed:1.0 green:0.77 blue:0.42 alpha:1.0];
}

static NSColor *SlotStatusColor(DeskCreditsSlot *s) {
    switch (s.kind) {
        case DeskCreditsSlotKindSigned:
        case DeskCreditsSlotKindClaimed:
            return VaultCyan();
        case DeskCreditsSlotKindPending:
        case DeskCreditsSlotKindWorking:
            return CreditsAmber();
        case DeskCreditsSlotKindNeedsAuth:
        case DeskCreditsSlotKindError:
            return CreditsRed();
        default:
            return VaultMuted();
    }
}

// 药丸回答的是“今天还要不要手动签”，不是“当前窗口领没领”。
// Qoder 的窗口是 10:00→次日 10:00：早上 10:00 前窗口仍属于昨天，
// 状态会显示“已领”，但当天其实还没签；这时药丸必须和别的平台一样是待签黄。
typedef NS_ENUM(NSInteger, DeskCreditsPillTone) {
    DeskCreditsPillToneMuted = 0,
    DeskCreditsPillToneAmber,
    DeskCreditsPillToneCyan,
    DeskCreditsPillToneRed,
};

static DeskCreditsPillTone SlotPillTone(DeskCreditsSlot *s) {
    switch (s.kind) {
        case DeskCreditsSlotKindUnconnected:
            return DeskCreditsPillToneMuted;
        case DeskCreditsSlotKindNeedsAuth:
        case DeskCreditsSlotKindError:
            return DeskCreditsPillToneRed;
        case DeskCreditsSlotKindWorking:
        case DeskCreditsSlotKindPending:
            return DeskCreditsPillToneAmber;
        case DeskCreditsSlotKindSigned:
        case DeskCreditsSlotKindClaimed: {
            if (s.platform == DeskCreditsPlatformQoder &&
                s.kind == DeskCreditsSlotKindClaimed) {
                NSString *today = DeskCreditsDayKey([NSDate date].timeIntervalSince1970);
                if (!s.lastCheckInDayKey.length ||
                    ![s.lastCheckInDayKey isEqualToString:today]) {
                    return DeskCreditsPillToneAmber;
                }
            }
            return DeskCreditsPillToneCyan;
        }
    }
    return DeskCreditsPillToneMuted;
}

static NSColor *SlotPillColor(DeskCreditsSlot *s) {
    switch (SlotPillTone(s)) {
        case DeskCreditsPillToneAmber: return CreditsAmber();
        case DeskCreditsPillToneCyan: return VaultCyan();
        case DeskCreditsPillToneRed: return CreditsRed();
        default: return VaultMuted();
    }
}

static NSString *SlotPillText(DeskCreditsSlot *s) {
    switch (s.kind) {
        case DeskCreditsSlotKindSigned: return @"签到";
        case DeskCreditsSlotKindPending: return @"签到";
        case DeskCreditsSlotKindClaimed: return @"签到";
        case DeskCreditsSlotKindNeedsAuth:
            switch (s.platform) {
                case DeskCreditsPlatformMiniMax: return @"授权";
                case DeskCreditsPlatformTrae: return @"打开";
                case DeskCreditsPlatformWorkBuddy: return @"登录";
                case DeskCreditsPlatformQoder: return @"设置";
            }
            return @"登录";
        case DeskCreditsSlotKindError: return @"重试";
        case DeskCreditsSlotKindWorking: return @"处理中";
        default: return @"待接入";
    }
}

static BOOL PillActionable(DeskCreditsSlot *s) {
    switch (s.kind) {
        case DeskCreditsSlotKindSigned:
        case DeskCreditsSlotKindClaimed:
        case DeskCreditsSlotKindPending:
        case DeskCreditsSlotKindNeedsAuth:
        case DeskCreditsSlotKindError:
            return YES;
        default:
            return NO;
    }
}

static NSDictionary *CreditsAttrs(NSFont *font, NSColor *color, BOOL shadow) {
    NSMutableDictionary *a = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    } mutableCopy];
    if (shadow) {
        NSShadow *sh = [NSShadow new];
        sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.80];
        sh.shadowBlurRadius = 5.0;
        sh.shadowOffset = CGSizeMake(0, -1.2);
        a[NSShadowAttributeName] = sh;
    }
    return a;
}

static void DrawTextIn(NSString *text, NSRect rect, NSFont *font, NSColor *color,
                       BOOL shadow, NSTextAlignment align) {
    if (!text.length || NSWidth(rect) < 1 || NSHeight(rect) < 1) return;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = align;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableDictionary *a = [CreditsAttrs(font, color, shadow) mutableCopy];
    a[NSParagraphStyleAttributeName] = ps;
    [text drawInRect:rect withAttributes:a];
}

static NSFont *Mono(CGFloat size, NSFontWeight weight) {
    return [NSFont monospacedSystemFontOfSize:size weight:weight];
}

static NSFont *MonoDigits(CGFloat size, NSFontWeight weight) {
    return [NSFont monospacedDigitSystemFontOfSize:size weight:weight];
}

static NSString *CreditsShortDay(NSString *key) {
    if (!key.length) return @"—";
    NSArray<NSString *> *parts = [key componentsSeparatedByString:@"-"];
    if (parts.count != 3) return key;
    return [NSString stringWithFormat:@"%ld/%ld",
            (long)[parts[1] integerValue], (long)[parts[2] integerValue]];
}

static NSString *CreditsRecordLabel(DeskCreditsSlot *s) {
    if (s.recordCoverageDays >= 90) return @"90天最高";
    if (s.recordCoverageDays > 0) {
        return [NSString stringWithFormat:@"%ld天最高", (long)s.recordCoverageDays];
    }
    return @"90天最高";
}

static NSString *CreditsRecordDateText(DeskCreditsSlot *s) {
    if (!s.recordPeakDayKey.length) return @"—";
    NSString *today = DeskCreditsDayKey([NSDate date].timeIntervalSince1970);
    if ([s.recordPeakDayKey isEqualToString:today]) return @"今天";
    return CreditsShortDay(s.recordPeakDayKey);
}

// 峰值日 = 最近签到日时，日期已经在状态行右侧，不在记录行重复；
// 新高例外：记录行的「今天」是新高标记，不是重复日期。
static BOOL CreditsRecordShowsDate(DeskCreditsSlot *s) {
    if (!s.recordPeakDayKey.length) return NO;
    if (s.recordNewHigh) return YES;
    if (!s.lastCheckInDayKey.length) return YES;
    return ![s.recordPeakDayKey isEqualToString:s.lastCheckInDayKey];
}

static NSString *CreditsEventVerb(DeskCreditsSlot *s) {
    return s.platform == DeskCreditsPlatformQoder ? @"领取" : @"签到";
}

static NSString *CreditsLastEventText(DeskCreditsSlot *s) {
    if (!s.lastCheckInDayKey.length) {
        return [NSString stringWithFormat:@"最近%@ —", CreditsEventVerb(s)];
    }
    return [NSString stringWithFormat:@"最近%@ %@",
            CreditsEventVerb(s), CreditsShortDay(s.lastCheckInDayKey)];
}

static NSString *CreditsLastEventFullText(DeskCreditsSlot *s) {
    if (!s.lastCheckInDayKey.length) {
        return [NSString stringWithFormat:@"最近%@ —", CreditsEventVerb(s)];
    }
    NSString *amount = s.lastCheckInAmount >= 0
        ? [NSString stringWithFormat:@" +%@", DeskCreditsFormatPoints(s.lastCheckInAmount)]
        : @"";
    return [NSString stringWithFormat:@"最近%@ %@%@",
            CreditsEventVerb(s), s.lastCheckInDayKey, amount];
}

static BOOL CreditsLastEventVisible(DeskCreditsSlot *s) {
    if (!s.connected || s.kind == DeskCreditsSlotKindUnconnected) return NO;
    return s.kind != DeskCreditsSlotKindNeedsAuth && s.kind != DeskCreditsSlotKindError;
}

static NSString *CreditsRecordVerifyText(DeskCreditsSlot *s) {
    NSString *value = s.recordMax >= 0 ? DeskCreditsFormatPoints(s.recordMax) : @"—";
    if (!CreditsRecordShowsDate(s)) {
        return [NSString stringWithFormat:@"%@ %@ %@",
                CreditsRecordLabel(s), value, s.unit];
    }
    return [NSString stringWithFormat:@"%@ %@ %@ · %@",
            CreditsRecordLabel(s), value, s.unit, CreditsRecordDateText(s)];
}

static NSString *CreditsRecordFullText(DeskCreditsSlot *s) {
    if (s.recordMax < 0) return @"90天最高 —";
    NSString *peak = s.recordPeakDayKey.length ? s.recordPeakDayKey : @"—";
    return [NSString stringWithFormat:@"%@ %@ %@ · %@ · 已记录 %ld/90 天",
            CreditsRecordLabel(s), DeskCreditsFormatPoints(s.recordMax), s.unit, peak,
            (long)MIN(90, MAX(0, s.recordCoverageDays))];
}

@interface DeskCreditsView ()
- (NSString *)summaryText;
- (NSString *)oldestSyncText;
- (NSString *)tooltipText;
- (NSImage *)sampledWallpaper;
- (void)drawSlot:(DeskCreditsSlot *)s in:(NSRect)tile shadow:(BOOL)shadow;
- (void)drawRecord:(DeskCreditsSlot *)s atX:(CGFloat)x right:(CGFloat)right top:(CGFloat)y;
- (void)drawRecordRail:(DeskCreditsSlot *)s atX:(CGFloat)x right:(CGFloat)right top:(CGFloat)y;
- (void)drawCycle:(DeskCreditsSlot *)s at:(NSPoint)p;
- (void)drawLoginLife:(DeskCreditsSlot *)s at:(NSPoint)p;
- (void)drawStreak:(DeskCreditsSlot *)s at:(NSPoint)p;
- (void)drawClaim:(DeskCreditsSlot *)s at:(NSPoint)p color:(NSColor *)color;
- (void)drawPlanLine:(NSString *)line in:(NSRect)rect shadow:(BOOL)shadow;
- (void)drawPill:(NSString *)text color:(NSColor *)color right:(CGFloat)right y:(CGFloat)y
      actionable:(BOOL)actionable;
@end

@implementation DeskCreditsView {
    NSImage *_wallpaper;
    NSRect _wallpaperRect;
    NSDate *_wallpaperAt;
    NSRect _standIn;
    NSPoint _dragStartMouse;
    NSRect _frameAtDragStart;
    BOOL _dragging;
    BOOL _pressMoved;      // 按下后位移过阈值（锁定时不挪窗，但仍要吃掉这次点击）
    BOOL _pressPill;
    NSInteger _pressSlot;
}

+ (NSSize)size { return NSMakeSize(kCreditsViewWidth, kCreditsViewHeight); }

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        _pressSlot = -1;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)isDragging { return _dragging; }

- (void)setStyle:(DeskStyle)style {
    _style = style;
    [self setNeedsDisplay:YES];
}

- (void)updateCenter:(DeskCreditsCenterSnapshot *)c {
    _center = c;
    [self setToolTip:[self tooltipText]];
    [self.window invalidateCursorRectsForView:self];
    [self setNeedsDisplay:YES];
}

- (void)resetCursorRects {
    [super resetCursorRects];
    for (NSInteger i = 0; i < (NSInteger)self.center.slots.count && i < kSlotCount; i++) {
        DeskCreditsSlot *s = self.center.slots[(NSUInteger)i];
        if (PillActionable(s)) {
            [self addCursorRect:[self pillRectForVerify:i] cursor:[NSCursor pointingHandCursor]];
        }
    }
}

- (void)setStandInScreenRect:(NSRect)r {
    _standIn = r;
    _wallpaper = nil;
    _wallpaperAt = nil;
}

- (NSRect)slotRectForVerify:(NSInteger)index {
    if (index < 0 || index >= kSlotCount) return NSZeroRect;
    NSRect b = self.bounds;
    CGFloat contentW = NSWidth(b) - 2 * kPadX;
    CGFloat tileW = (contentW - (kSlotCount - 1) * kTileGap) / (CGFloat)kSlotCount;
    CGFloat top = kPadTop;
    CGFloat h = NSHeight(b) - top - kPadBottom;
    return NSMakeRect(kPadX + index * (tileW + kTileGap), top, tileW, h);
}

- (NSRect)pillRectForVerify:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.center.slots.count) return NSZeroRect;
    DeskCreditsSlot *s = self.center.slots[(NSUInteger)index];
    NSString *text = SlotPillText(s);
    NSFont *font = Mono(7.0, PillActionable(s) ? NSFontWeightBold : NSFontWeightSemibold);
    CGFloat tw = [text sizeWithAttributes:CreditsAttrs(font, VaultPaper(), NO)].width;
    CGFloat w = MAX(34.0, tw + 11.0);
    NSRect tile = [self slotRectForVerify:index];
    CGFloat right = NSMaxX(tile) - kTilePadX;
    CGFloat y = NSMinY(tile) + kTilePadTop - 1.0;
    return NSMakeRect(right - w, y, w, 13.0);
}

- (NSString *)pillTextForVerify:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.center.slots.count) return @"";
    return SlotPillText(self.center.slots[(NSUInteger)index]);
}
- (NSString *)pillToneForVerify:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.center.slots.count) return @"";
    switch (SlotPillTone(self.center.slots[(NSUInteger)index])) {
        case DeskCreditsPillToneAmber: return @"amber";
        case DeskCreditsPillToneCyan: return @"cyan";
        case DeskCreditsPillToneRed: return @"red";
        default: return @"muted";
    }
}

- (NSInteger)slotIndexAtPoint:(NSPoint)p {
    for (NSInteger i = 0; i < kSlotCount; i++) {
        if (NSPointInRect(p, [self slotRectForVerify:i])) return i;
    }
    return -1;
}

- (NSString *)summaryText {
    DeskCreditsCenterSnapshot *c = self.center;
    if (!c) return @"0 已办 · 0 待办 · 4 待接入";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%ld 已办", (long)c.doneCount]];
    [parts addObject:[NSString stringWithFormat:@"%ld 待办", (long)c.pendingCount]];
    if (c.errorCount > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld 异常", (long)c.errorCount]];
    } else {
        NSInteger unconnected = (NSInteger)c.slots.count - c.connectedCount;
        if (unconnected > 0) {
            [parts addObject:[NSString stringWithFormat:@"%ld 待接入", (long)unconnected]];
        }
    }
    return [parts componentsJoinedByString:@" · "];
}

- (NSString *)oldestSyncText {
    NSTimeInterval t = self.center ? self.center.oldestSyncAt : 0;
    if (t <= 0) return @"未同步";
    NSString *base = DeskCreditsSyncText(t, [NSDate date].timeIntervalSince1970);
    if ([base isEqualToString:@"刚刚同步"]) return @"最旧同步 刚刚";
    base = [base stringByReplacingOccurrencesOfString:@" 同步" withString:@""];
    return [@"最旧同步 " stringByAppendingString:base];
}

- (NSString *)tooltipText {
    DeskCreditsCenterSnapshot *c = self.center;
    if (!c) return @"签到中心";
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableString *t = [NSMutableString stringWithFormat:@"签到中心 · %ld/4 已接入\n",
                          (long)c.connectedCount];
    for (DeskCreditsSlot *s in c.slots) {
        [t appendFormat:@"\n%@ · %@", s.name, s.statusText];
        if (s.kind != DeskCreditsSlotKindUnconnected && s.balance >= 0) {
            [t appendFormat:@" · %@ %@", DeskCreditsFormatPoints(s.balance), s.unit];
        }
        [t appendFormat:@"\n%@\n%@", s.planLine, s.footerText];
        if (s.kind != DeskCreditsSlotKindUnconnected) {
            [t appendFormat:@"\n%@", CreditsRecordFullText(s)];
            [t appendFormat:@"\n%@", CreditsLastEventFullText(s)];
        }
        if (s.platform == DeskCreditsPlatformMiniMax) {
            DeskCreditsSnapshot *m = c.minimax;
            if (m.days.count) {
                [t appendString:@"\n7 天："];
                for (DeskCreditsDay *d in m.days) {
                    [t appendFormat:@"%ld:%@%@%@ ", (long)d.dayNo,
                     d.claimed ? @"✓" : @"·",
                     d.points >= 0
                        ? [NSString stringWithFormat:@"+%@", DeskCreditsFormatPoints(d.points)]
                        : @"—",
                     d.bonusPoints > 0
                        ? [NSString stringWithFormat:@"(+%@)", DeskCreditsFormatPoints(d.bonusPoints)]
                        : @""];
                }
            }
            if (m.freeBalance >= 0 || m.purchasedBalance >= 0) {
                [t appendFormat:@"\n免费 %@ · 购买 %@",
                 DeskCreditsFormatPoints(m.freeBalance),
                 DeskCreditsFormatPoints(m.purchasedBalance)];
            }
            [t appendFormat:@"\n上次同步 %@",
             DeskCreditsSyncText(m.lastSyncAt, now)];
        }
        if (s.platform == DeskCreditsPlatformTrae && c.trae) {
            DeskTraeSnapshot *tr = c.trae;
            if (tr.tokenExpiresAt > 0) {
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                df.dateFormat = @"yyyy-MM-dd HH:mm";
                [t appendFormat:@"\n令牌到期 %@（剩 %.0f 天）",
                 [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:tr.tokenExpiresAt]],
                 MAX(0.0, tr.loginDays)];
            }
            if (tr.hasStatus) {
                [t appendFormat:@"\n今日 %@ +%@", tr.checkedIn ? @"已签" : @"待签",
                 tr.todayCredits >= 0 ? DeskCreditsFormatPoints(tr.todayCredits) : @"—"];
                if (tr.extraCredits > 0) {
                    [t appendFormat:@"（额外 +%@）", DeskCreditsFormatPoints(tr.extraCredits)];
                }
            }
            if (tr.balance >= 0) {
                [t appendFormat:@"\n剩余 %@", DeskCreditsFormatPoints(tr.balance)];
                if (tr.total >= 0) [t appendFormat:@" / %@", DeskCreditsFormatPoints(tr.total)];
                if (tr.consumed >= 0) [t appendFormat:@" · 已用 %@", DeskCreditsFormatPoints(tr.consumed)];
            }
            [t appendString:@"\n不自动续期（刷新会踢掉 IDE）"];
            [t appendFormat:@"\n上次同步 %@", DeskCreditsSyncText(tr.lastSyncAt, now)];
        }
        if (s.platform == DeskCreditsPlatformQoder && c.qoder) {
            DeskQoderSnapshot *q = c.qoder;
            if (q.quotaTotal >= 0 || q.quotaUsed >= 0) {
                [t appendFormat:@"\n额度 %@ 可用 · 已用 %@ / %@",
                 DeskCreditsFormatPoints(q.balance),
                 DeskCreditsFormatPoints(q.quotaUsed),
                 DeskCreditsFormatPoints(q.quotaTotal)];
            }
            if (q.claimable) {
                [t appendFormat:@"\n本窗口待领 +%@ Credits", DeskCreditsFormatPoints(q.todayAmount)];
            } else if (q.claimed) {
                [t appendFormat:@"\n本窗口已领 +%@ Credits", DeskCreditsFormatPoints(q.claimedAmount)];
            }
            if (q.windowStart > 0 && q.windowEnd > 0) {
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                df.dateFormat = @"MM-dd HH:mm";
                [t appendFormat:@"\n窗口 %@ ~ %@（北京时间）",
                 [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:q.windowStart]],
                 [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:q.windowEnd]]];
            }
            [t appendFormat:@"\n活动 %ld 项 · 每天 10:00 刷新",
             (long)q.campaignCount];
            [t appendFormat:@"\n上次同步 %@", DeskCreditsSyncText(q.lastSyncAt, now)];
        }
        if (s.platform == DeskCreditsPlatformWorkBuddy && c.workbuddy) {
            DeskWorkbuddySnapshot *w = c.workbuddy;
            if (w.quotaTotal >= 0 || w.quotaUsed >= 0) {
                [t appendFormat:@"\n积分 %@ 可用 · 已用 %@ / %@",
                 DeskCreditsFormatPoints(w.balance),
                 DeskCreditsFormatPoints(w.quotaUsed),
                 DeskCreditsFormatPoints(w.quotaTotal)];
            }
            if (w.hasStatus) {
                [t appendFormat:@"\n今日 %@", w.checkedIn ? @"已签" : (w.activityEnabled ? @"待签" : @"无活动")];
                if (w.todayCredit >= 0) {
                    [t appendFormat:@" +%@", DeskCreditsFormatPoints(w.todayCredit)];
                } else if (w.dailyCredit >= 0) {
                    [t appendFormat:@"（每日 +%@）", DeskCreditsFormatPoints(w.dailyCredit)];
                }
                [t appendFormat:@"\n连签 %.0f 天", w.streakDays];
            }
            if (w.tokenExpiresAt > 0) {
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                df.dateFormat = @"yyyy-MM-dd";
                [t appendFormat:@"\n登录到期 %@",
                 [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:w.tokenExpiresAt]]];
            }
            [t appendFormat:@"\n上次同步 %@", DeskCreditsSyncText(w.lastSyncAt, now)];
        }
        if (s.kind == DeskCreditsSlotKindNeedsAuth) {
            [t appendString:s.platform == DeskCreditsPlatformTrae
                ? @"\n点一下这一格打开 Trae" : @"\n点一下这一格发起授权"];
        }
        if (s.kind != DeskCreditsSlotKindUnconnected && s.kind != DeskCreditsSlotKindWorking) {
            [t appendString:@"\n点右上角「签到」可手动补签"];
        }
        if (s.hint.length) [t appendFormat:@"\n%@", s.hint];
    }
    [t appendFormat:@"\n\n%@ · 每平台独立签到", [self oldestSyncText]];
    return t;
}

- (NSImage *)sampledWallpaper {
    NSRect r = NSEqualRects(_standIn, NSZeroRect) ? (self.window ? self.window.frame : NSZeroRect)
                                                  : _standIn;
    if (NSEqualRects(r, NSZeroRect)) return _wallpaper;
    BOOL moved = !NSEqualRects(r, _wallpaperRect);
    NSTimeInterval age = _wallpaperAt ? [[NSDate date] timeIntervalSinceDate:_wallpaperAt] : 1e9;
    if (_wallpaper && !moved && age < 6.0) return _wallpaper;
    NSImage *img = [[DeskBackdrop shared] imageForRect:r dark:YES];
    if (!img) return _wallpaper;
    _wallpaper = img;
    _wallpaperRect = r;
    _wallpaperAt = [NSDate date];
    return _wallpaper;
}

#pragma mark - 校验口

- (NSInteger)slotCountForVerify { return self.center ? self.center.slots.count : 0; }
- (DeskCreditsPlatform)platformForVerify:(NSInteger)index {
    return (index >= 0 && index < (NSInteger)self.center.slots.count)
        ? self.center.slots[(NSUInteger)index].platform
        : DeskCreditsPlatformMiniMax;
}
- (NSString *)platformNameForVerify:(NSInteger)index {
    return (index >= 0 && index < (NSInteger)self.center.slots.count)
        ? self.center.slots[(NSUInteger)index].name : @"";
}
- (NSString *)planTextForVerify:(NSInteger)index {
    return (index >= 0 && index < (NSInteger)self.center.slots.count)
        ? self.center.slots[(NSUInteger)index].planLine : @"";
}
- (NSString *)statusTextForVerify:(NSInteger)index {
    return (index >= 0 && index < (NSInteger)self.center.slots.count)
        ? self.center.slots[(NSUInteger)index].statusText : @"";
}
- (NSString *)balanceTextForVerify:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.center.slots.count) return @"";
    DeskCreditsSlot *s = self.center.slots[(NSUInteger)index];
    if (s.kind == DeskCreditsSlotKindUnconnected) return @"待接入";
    if (s.balance < 0) return @"—";
    return DeskCreditsFormatPoints(s.balance);
}
- (NSString *)unitTextForVerify:(NSInteger)index {
    return (index >= 0 && index < (NSInteger)self.center.slots.count)
        ? self.center.slots[(NSUInteger)index].unit : @"";
}
- (NSString *)footerTextForVerify:(NSInteger)index {
    return (index >= 0 && index < (NSInteger)self.center.slots.count)
        ? self.center.slots[(NSUInteger)index].footerText : @"";
}
- (NSString *)recordTextForVerify:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.center.slots.count) return @"";
    DeskCreditsSlot *s = self.center.slots[(NSUInteger)index];
    if (s.kind == DeskCreditsSlotKindUnconnected) return @"";
    return CreditsRecordVerifyText(s);
}
- (NSString *)lastEventTextForVerify:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.center.slots.count) return @"";
    DeskCreditsSlot *s = self.center.slots[(NSUInteger)index];
    if (!CreditsLastEventVisible(s)) return @"";
    return CreditsLastEventText(s);
}
- (NSInteger)recordRailCountForVerify:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.center.slots.count) return 0;
    DeskCreditsSlot *s = self.center.slots[(NSUInteger)index];
    if (s.kind == DeskCreditsSlotKindUnconnected) return 0;
    return (NSInteger)s.recordRail.count;
}
- (BOOL)recordIsNewHighForVerify:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.center.slots.count) return NO;
    return self.center.slots[(NSUInteger)index].recordNewHigh;
}
- (DeskCreditsVisualKind)visualForVerify:(NSInteger)index {
    return (index >= 0 && index < (NSInteger)self.center.slots.count)
        ? self.center.slots[(NSUInteger)index].visual : DeskCreditsVisualNone;
}
- (NSString *)summaryTextForVerify { return [self summaryText]; }
- (NSString *)oldestSyncTextForVerify { return [self oldestSyncText]; }
- (NSString *)tooltipTextForVerify { return [self tooltipText]; }

#pragma mark - 绘制

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    DeskCreditsCenterSnapshot *c = self.center;
    if (!c) c = [DeskCreditsCenterSnapshot centerWithMiniMax:[DeskCreditsSnapshot new]];
    NSRect b = self.bounds;
    BOOL glass = (self.style == DeskStyleHUD);

    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:b
                                                        xRadius:14.0
                                                        yRadius:14.0];
    [clip addClip];
    switch (self.style) {
        case DeskStylePlate:
            VaultDrawPlatePlate(b, [self sampledWallpaper], -1, 0);
            break;
        case DeskStyleFeather:
            VaultDrawPlateFeather(b);
            break;
        case DeskStyleHUD:
        case DeskStyleBare:
        default:
            // 无边玻璃按用户要求不再垫玻璃底：背后完全透出壁纸，只留文字和文字投影
            break;
    }
    if (self.style == DeskStylePlate || self.style == DeskStyleFeather) {
        NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5)
                                                            xRadius:14.0
                                                            yRadius:14.0];
        edge.lineWidth = 1.0;
        [[VaultCyan() colorWithAlphaComponent:0.16] setStroke];
        [edge stroke];
    }
    if (!glass) VaultDrawReticle(b, 6.0, 13.0, VaultCyan(), 0.45, 1.2);

    // 四个槽：整块只有槽，没有抬头和表尾
    for (NSInteger i = 0; i < kSlotCount; i++) {
        DeskCreditsSlot *s = i < (NSInteger)c.slots.count ? c.slots[(NSUInteger)i] : nil;
        if (!s) continue;
        [self drawSlot:s in:[self slotRectForVerify:i] shadow:NO];
    }
}

- (void)drawPill:(NSString *)text color:(NSColor *)color right:(CGFloat)right y:(CGFloat)y
      actionable:(BOOL)actionable {
    NSFont *font = Mono(7.5, actionable ? NSFontWeightBold : NSFontWeightSemibold);
    NSDictionary *a = CreditsAttrs(font, color, NO);
    CGFloat tw = [text sizeWithAttributes:a].width;
    CGFloat w = MAX(34.0, tw + 11.0);
    NSRect r = NSMakeRect(right - w, y, w, 13.0);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6.5 yRadius:6.5];
    [[VaultInk() colorWithAlphaComponent:actionable ? 0.72 : 0.55] setFill];
    [p fill];
    [[color colorWithAlphaComponent:actionable ? 0.18 : 0.10] setFill];
    [p fill];
    [[color colorWithAlphaComponent:actionable ? 0.85 : 0.45] setStroke];
    p.lineWidth = actionable ? 1.2 : 1.0;
    [p stroke];
    NSSize ts = [text sizeWithAttributes:a];
    [text drawAtPoint:NSMakePoint(NSMidX(r) - ts.width / 2.0, NSMidY(r) - ts.height / 2.0)
        withAttributes:a];
}

- (void)drawPlanLine:(NSString *)line in:(NSRect)rect shadow:(BOOL)shadow {
    NSFont *font = Mono(7.4, NSFontWeightRegular);
    NSColor *base = [VaultPaper() colorWithAlphaComponent:0.72];
    NSDictionary *a = CreditsAttrs(font, base, NO);
    BOOL warn = [line containsString:@"不自动续期"];
    if (!warn) {
        DrawTextIn(line, rect, font, base, NO, NSTextAlignmentLeft);
        return;
    }
    NSRange sep = [line rangeOfString:@" · " options:NSBackwardsSearch];
    if (sep.location == NSNotFound) {
        DrawTextIn(line, rect, font, base, NO, NSTextAlignmentLeft);
        return;
    }
    NSString *head = [line substringToIndex:sep.location];
    NSString *tail = [line substringFromIndex:NSMaxRange(sep)];
    NSString *prefix = [head stringByAppendingString:@" · "];
    CGFloat pw = [prefix sizeWithAttributes:a].width;
    [prefix drawAtPoint:rect.origin withAttributes:a];
    NSRect tr = NSMakeRect(rect.origin.x + pw, rect.origin.y,
                           MAX(0, NSWidth(rect) - pw), NSHeight(rect));
    DrawTextIn(tail, tr, font, CreditsAmber(), NO, NSTextAlignmentLeft);
}

- (void)drawRecord:(DeskCreditsSlot *)s atX:(CGFloat)x right:(CGFloat)right top:(CGFloat)y {
    NSFont *labelFont = [NSFont systemFontOfSize:7.0 weight:NSFontWeightMedium];
    NSFont *valueFont = MonoDigits(9.2, NSFontWeightBold);
    NSFont *unitFont = Mono(6.8, NSFontWeightRegular);
    NSFont *dateFont = Mono(7.0, NSFontWeightMedium);
    NSString *label = CreditsRecordLabel(s);
    NSString *value = s.recordMax >= 0 ? DeskCreditsFormatPoints(s.recordMax) : @"—";
    NSString *unit = s.unit;
    BOOL showDate = CreditsRecordShowsDate(s);
    NSString *date = showDate ? CreditsRecordDateText(s) : @"";
    NSColor *valueColor = s.recordMax < 0
        ? [VaultPaper() colorWithAlphaComponent:0.45]
        : (s.recordNewHigh ? VaultCyanBright() : VaultPaper());
    NSColor *dateColor = s.recordNewHigh ? VaultCyanBright()
                                         : [VaultPaper() colorWithAlphaComponent:0.72];
    NSDictionary *la = CreditsAttrs(labelFont, [VaultPaper() colorWithAlphaComponent:0.70], NO);
    NSDictionary *va = CreditsAttrs(valueFont, valueColor, NO);
    NSDictionary *ua = CreditsAttrs(unitFont, [VaultPaper() colorWithAlphaComponent:0.68], NO);
    NSDictionary *da = CreditsAttrs(dateFont, dateColor, NO);
    NSSize ls = [label sizeWithAttributes:la];
    NSSize vs = [value sizeWithAttributes:va];
    NSSize us = [unit sizeWithAttributes:ua];
    NSSize ds = showDate ? [date sizeWithAttributes:da] : NSZeroSize;
    CGFloat dateX = showDate ? right - ds.width : right;
    CGFloat labelX = x;
    CGFloat triW = s.recordNewHigh ? 5.0 : 0.0;
    CGFloat valueX = labelX + ls.width + 3.0 + triW;
    CGFloat unitX = valueX + vs.width + 3.0;
    BOOL showLabel = YES;
    BOOL showUnit = (unitX + us.width <= dateX - 3.0);
    if (valueX + vs.width > dateX - 3.0) {
        showLabel = NO;
        showUnit = NO;
        valueX = x;
    }
    // 按基线对齐：label / unit / date 的 ascender 不同，用字体度量而不是盒高。
    CGFloat valueAsc = valueFont.ascender;
    CGFloat labelTop = y + MAX(0.0, valueAsc - labelFont.ascender);
    CGFloat unitTop = y + MAX(0.0, valueAsc - unitFont.ascender);
    CGFloat dateTop = y + MAX(0.0, valueAsc - dateFont.ascender);
    if (showLabel) {
        [label drawAtPoint:NSMakePoint(labelX, labelTop) withAttributes:la];
        if (s.recordNewHigh) {
            CGFloat tx = labelX + ls.width + 3.0;
            CGFloat ty = y + MAX(0.0, (valueAsc - 4.0) / 2.0);
            NSBezierPath *tri = [NSBezierPath bezierPath];
            [tri moveToPoint:NSMakePoint(tx, ty + 4.0)];
            [tri lineToPoint:NSMakePoint(tx + 3.2, ty + 4.0)];
            [tri lineToPoint:NSMakePoint(tx + 1.6, ty)];
            [tri closePath];
            [VaultCyanBright() setFill];
            [tri fill];
        }
    }
    [value drawAtPoint:NSMakePoint(valueX, y) withAttributes:va];
    if (showUnit) {
        [unit drawAtPoint:NSMakePoint(unitX, unitTop) withAttributes:ua];
    }
    if (showDate) {
        [date drawAtPoint:NSMakePoint(dateX, dateTop) withAttributes:da];
    }
}

- (void)drawRecordRail:(DeskCreditsSlot *)s atX:(CGFloat)x right:(CGFloat)right top:(CGFloat)y {
    const CGFloat railH = 4.0;
    CGFloat width = right - x;
    if (width <= 0) return;
    CGFloat pitch = width / 90.0;
    CGFloat tickW = MAX(0.6, pitch - 0.45);
    // 全宽轨道：只有 3 天数据时，90 个空格不会缩成右侧一撮几乎看不见的点。
    // 轨道只表示“90 天窗口”，不代表有采样；有采样的天再画短柱。
    [[VaultMuted() colorWithAlphaComponent:0.12] setFill];
    NSRectFill(NSMakeRect(x, y + railH - 1.0, width, 1.0));
    for (NSInteger i = 0; i < 90; i++) {
        NSInteger flags = i < (NSInteger)s.recordRail.count
            ? s.recordRail[(NSUInteger)i].integerValue : DeskCreditsRecordRailMissing;
        BOOL sampled = (flags & DeskCreditsRecordRailSampled) != 0;
        if (!sampled) continue;
        BOOL peak = (flags & DeskCreditsRecordRailPeak) != 0;
        BOOL today = (flags & DeskCreditsRecordRailToday) != 0;
        CGFloat h = 2.0;
        NSColor *c = [VaultCyan() colorWithAlphaComponent:0.30];
        if (today) {
            h = 3.0;
            c = CreditsAmber();
        }
        if (peak) {
            h = railH;
            c = VaultCyanBright();
        }
        CGFloat ty = y + (railH - h);
        [c setFill];
        NSRectFill(NSMakeRect(x + (CGFloat)i * pitch, ty, tickW, h));
        if (peak && today) {
            [CreditsAmber() setFill];
            NSRectFill(NSMakeRect(x + (CGFloat)i * pitch, y, tickW, 1.0));
        }
    }
}

- (void)drawCycle:(DeskCreditsSlot *)s at:(NSPoint)p {
    NSColor *dim = [VaultMuted() colorWithAlphaComponent:0.22];
    for (NSInteger i = 0; i < 7; i++) {
        NSInteger st = i < (NSInteger)s.cycleStates.count
            ? s.cycleStates[(NSUInteger)i].integerValue : 0;
        BOOL bonus = i < (NSInteger)s.cycleBonuses.count
            && s.cycleBonuses[(NSUInteger)i].boolValue;
        NSColor *c = dim;
        if (st == 1) c = bonus ? VaultCyanBright() : VaultCyan();
        if (st == 2) c = VaultCyanBright();
        if (st == 3) c = CreditsAmber();
        [c setFill];
        NSRectFill(NSMakeRect(p.x + i * 6.0, p.y, 4.0, 4.0));
        if (st == 2 || st == 3) {
            NSBezierPath *ring = [NSBezierPath bezierPathWithRect:
                                  NSMakeRect(p.x + i * 6.0 - 1.0, p.y - 1.0, 6.0, 6.0)];
            ring.lineWidth = 0.8;
            [c setStroke];
            [ring stroke];
        }
    }
}

- (void)drawLoginLife:(DeskCreditsSlot *)s at:(NSPoint)p {
    NSRect track = NSMakeRect(p.x, p.y + 3.0, 40.0, 3.0);
    [[VaultMuted() colorWithAlphaComponent:0.16] setFill];
    NSRectFill(track);
    double total = s.loginTotalDays > 0 ? s.loginTotalDays : 30.0;
    double frac = s.loginTotalDays > 0 ? MIN(1.0, MAX(0.0, s.loginDays / total)) : 0.0;
    if (frac > 0) {
        NSColor *c = s.loginWarn ? CreditsAmber() : VaultCyan();
        [c setFill];
        NSRectFill(NSMakeRect(track.origin.x, track.origin.y,
                              MAX(1.0, NSWidth(track) * frac), 3.0));
    }
}

- (void)drawStreak:(DeskCreditsSlot *)s at:(NSPoint)p {
    NSInteger lit = MAX(0, MIN(s.streakCount, 7));
    for (NSInteger i = 0; i < 7; i++) {
        NSColor *c = i < lit ? VaultCyan() : [VaultMuted() colorWithAlphaComponent:0.22];
        [c setFill];
        NSRectFill(NSMakeRect(p.x + i * 6.0, p.y, 4.0, 4.0));
    }
}

- (void)drawClaim:(DeskCreditsSlot *)s at:(NSPoint)p color:(NSColor *)color {
    NSString *txt = s.claimCount >= 0
        ? [NSString stringWithFormat:@"%ld 项活动", (long)s.claimCount]
        : @"可领 —";
    NSFont *font = Mono(6.8, NSFontWeightMedium);
    NSColor *chipColor = s.claimCount >= 0 ? VaultCyan() : VaultMuted();
    NSDictionary *a = CreditsAttrs(font, chipColor, NO);
    CGFloat tw = [txt sizeWithAttributes:a].width;
    NSRect chip = NSMakeRect(p.x, p.y - 4.0, tw + 7.0, 10.0);
    NSBezierPath *cp = [NSBezierPath bezierPathWithRoundedRect:chip xRadius:4.0 yRadius:4.0];
    [[chipColor colorWithAlphaComponent:0.05] setFill];
    [cp fill];
    [[chipColor colorWithAlphaComponent:0.26] setStroke];
    cp.lineWidth = 1.0;
    [cp stroke];
    [txt drawAtPoint:NSMakePoint(chip.origin.x + 3.5, chip.origin.y + 2.0) withAttributes:a];
    CGFloat dx = NSMaxX(chip) + 3.0;
    NSRect dot = NSMakeRect(dx, p.y - 1.0, 4.0, 4.0);
    if (s.deviceReady) {
        [VaultCyan() setFill];
        NSRectFill(dot);
    } else {
        NSBezierPath *ring = [NSBezierPath bezierPathWithRect:NSInsetRect(dot, 0.5, 0.5)];
        ring.lineWidth = 1.0;
        [[VaultMuted() colorWithAlphaComponent:0.55] setStroke];
        [ring stroke];
    }
    (void)color;
}

- (void)drawSlot:(DeskCreditsSlot *)s in:(NSRect)tile shadow:(BOOL)shadow {
    (void)shadow;
    BOOL off = (s.kind == DeskCreditsSlotKindUnconnected);
    NSColor *statusColor = SlotStatusColor(s);
    NSRect body = NSInsetRect(tile, 0.5, 0.5);
    VaultDrawInkPlate(body, 9.0, off ? 0.42 : 0.56, off ? 0.10 : 0.14);

    CGFloat x = NSMinX(tile) + kTilePadX;
    CGFloat right = NSMaxX(tile) - kTilePadX;
    CGFloat top = NSMinY(tile) + kTilePadTop;

    // 状态灯 + 平台名 + 胶囊
    NSColor *ledColor = statusColor;
    if (off) {
        NSBezierPath *ring = [NSBezierPath bezierPathWithRect:NSInsetRect(NSMakeRect(x, top + 4.0, 5.0, 5.0), 0.5, 0.5)];
        ring.lineWidth = 1.0;
        [[VaultMuted() colorWithAlphaComponent:0.55] setStroke];
        [ring stroke];
    } else {
        [ledColor setFill];
        NSRectFill(NSMakeRect(x, top + 4.0, 5.0, 5.0));
    }
    NSFont *nameFont = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
    NSColor *nameColor = off ? [VaultPaper() colorWithAlphaComponent:0.68] : VaultPaper();
    [s.name drawAtPoint:NSMakePoint(x + 9.0, top)
         withAttributes:CreditsAttrs(nameFont, nameColor, NO)];
    [self drawPill:SlotPillText(s) color:SlotPillColor(s)
              right:right y:top - 1.0 actionable:PillActionable(s)];

    // 副行：套餐 / 版本 / 接入方式
    [self drawPlanLine:s.planLine
                    in:NSMakeRect(x, top + 15.0, right - x, 10.0)
                shadow:NO];

    // 主读数
    NSFont *bigFont = MonoDigits(22.0, NSFontWeightBold);
    if (off) {
        [@"待接入" drawAtPoint:NSMakePoint(x, top + 30.0)
                 withAttributes:CreditsAttrs([NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold],
                                             VaultMuted(), NO)];
    } else if (s.balance < 0) {
        [@"—" drawAtPoint:NSMakePoint(x, top + 28.0)
            withAttributes:CreditsAttrs(bigFont, [VaultPaper() colorWithAlphaComponent:0.45], NO)];
    } else {
        NSString *bal = DeskCreditsFormatPoints(s.balance);
        NSDictionary *ba = CreditsAttrs(bigFont, VaultPaper(), NO);
        [bal drawAtPoint:NSMakePoint(x, top + 28.0) withAttributes:ba];
        NSSize bs = [bal sizeWithAttributes:ba];
        NSFont *unitFont = Mono(7.5, NSFontWeightRegular);
        [s.unit drawAtPoint:NSMakePoint(x + bs.width + 4.0,
                                        top + 28.0 + (bs.height - [unitFont ascender] - 1.0))
             withAttributes:CreditsAttrs(unitFont,
                                         [VaultPaper() colorWithAlphaComponent:0.72], NO)];
    }

    // 今日结果 + 最近签到（状态行右侧）
    NSFont *statusFont = [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold];
    NSColor *statusTextColor = off ? VaultMuted() : statusColor;
    NSString *eventText = CreditsLastEventVisible(s) ? CreditsLastEventText(s) : nil;
    NSFont *eventFont = Mono(7.8, NSFontWeightMedium);
    NSDictionary *eventAttrs = CreditsAttrs(eventFont,
        [VaultPaper() colorWithAlphaComponent:0.78], NO);
    CGFloat eventW = eventText ? [eventText sizeWithAttributes:eventAttrs].width : 0;
    CGFloat statusMax = right - x;
    if (eventText) {
        CGFloat room = statusMax - eventW - 6.0;
        if (room < 36.0) {
            eventText = nil;
            eventW = 0;
        } else {
            statusMax = room;
        }
    }
    DrawTextIn(s.statusText, NSMakeRect(x, top + 57.0, statusMax, 11.0),
               statusFont, statusTextColor, NO, NSTextAlignmentLeft);
    if (eventText) {
        [eventText drawAtPoint:NSMakePoint(right - eventW, top + 57.8)
               withAttributes:eventAttrs];
    }

    // 底部：已接入槽用 90 天记录行 + 记录尺替代原来的 1pt 分隔线
    CGFloat footY = NSMaxY(tile) - 17.0;
    if (off) {
        [[VaultCyan() colorWithAlphaComponent:0.08] setFill];
        NSRectFill(NSMakeRect(x, footY - 5.0, right - x, 1.0));
    } else {
        [self drawRecord:s atX:x right:right top:footY - 19.0];
        [self drawRecordRail:s atX:x right:right top:footY - 7.5];
    }
    CGFloat vx = x;
    switch (s.visual) {
        case DeskCreditsVisualCycle:
            [self drawCycle:s at:NSMakePoint(vx, footY + 3.0)];
            vx += 44.0;
            break;
        case DeskCreditsVisualLoginLife:
            [self drawLoginLife:s at:NSMakePoint(vx, footY + 1.0)];
            vx += 44.0;
            break;
        case DeskCreditsVisualStreak:
            [self drawStreak:s at:NSMakePoint(vx, footY + 3.0)];
            vx += 44.0;
            break;
        case DeskCreditsVisualClaim:
            [self drawClaim:s at:NSMakePoint(vx, footY + 4.0) color:statusColor];
            vx += (s.claimCount >= 0 ? 40.0 : 34.0) + 7.0;
            break;
        default:
            break;
    }
    NSColor *footColor = VaultPaper();
    if (off) footColor = VaultMuted();
    else if (s.visual == DeskCreditsVisualLoginLife && s.loginWarn) footColor = CreditsAmber();
    else if (s.visual == DeskCreditsVisualClaim) footColor = VaultMuted();
    NSFont *footFont = Mono(8.0, NSFontWeightMedium);
    DrawTextIn(s.footerText,
               NSMakeRect(vx, footY, MAX(0, right - vx), 10.0),
               footFont, footColor, NO, NSTextAlignmentLeft);
}

#pragma mark - 拖动 / 点击

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self slotIndexAtPoint:p];
    _pressSlot = idx;
    _pressPill = (idx >= 0 && idx < (NSInteger)self.center.slots.count
                  && NSPointInRect(p, [self pillRectForVerify:idx])
                  && PillActionable(self.center.slots[(NSUInteger)idx]));
    if (event.clickCount == 2 && idx >= 0 && idx < (NSInteger)self.center.slots.count) {
        DeskCreditsPlatform platform = self.center.slots[(NSUInteger)idx].platform;
        BOOL pill = _pressPill;
        _pressSlot = -1;
        _pressPill = NO;
        _dragging = NO;
        if (pill) {
            if (self.onSlotCheckNow) self.onSlotCheckNow(platform);
        } else if (self.onSlotDoubleClick) {
            self.onSlotDoubleClick(platform);
        }
        return;
    }
    _pressMoved = NO;
    _dragStartMouse = [NSEvent mouseLocation];
    _frameAtDragStart = self.window ? self.window.frame : NSZeroRect;
    _dragging = NO;
}

- (void)mouseDragged:(NSEvent *)event {
    (void)event;
    if (!self.window || NSEqualRects(_frameAtDragStart, NSZeroRect)) return;
    NSPoint p = [NSEvent mouseLocation];
    CGFloat dx = p.x - _dragStartMouse.x;
    CGFloat dy = p.y - _dragStartMouse.y;
    if (!_dragging && !_pressMoved && fabs(dx) + fabs(dy) < 3.0) return;
    _pressMoved = YES;
    if (self.locked) return;   // 全局锁定：拖动只用来取消这次点击，不挪窗
    _dragging = YES;
    [self dragWindowToMouse:p];
}

- (void)dragWindowToMouse:(NSPoint)mouseNow {
    if (!self.window || self.locked || NSEqualRects(_frameAtDragStart, NSZeroRect)) return;
    CGFloat dx = mouseNow.x - _dragStartMouse.x;
    CGFloat dy = mouseNow.y - _dragStartMouse.y;
    NSRect f = _frameAtDragStart;
    f.origin.x = round(f.origin.x + dx);
    f.origin.y = round(f.origin.y + dy);
    [self.window setFrameOrigin:f.origin];
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    NSInteger idx = _pressSlot;
    BOOL pill = _pressPill;
    _pressSlot = -1;
    _pressPill = NO;
    BOOL moved = _pressMoved;
    _pressMoved = NO;
    if (_dragging || moved) {
        _dragging = NO;
        if (!self.locked && moved && self.onUserMove) self.onUserMove();
        return;
    }
    if (idx >= 0 && idx < (NSInteger)self.center.slots.count) {
        DeskCreditsPlatform platform = self.center.slots[(NSUInteger)idx].platform;
        if (pill) {
            if (self.onSlotCheckNow) self.onSlotCheckNow(platform);
        } else if (self.onSlotActivate) {
            self.onSlotActivate(platform);
        }
    }
}

@end
