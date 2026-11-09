#import "panel_view.h"
#import "backdrop.h"
#import "vault_art.h"
#import "sysmon.h"
#import <math.h>

// 卡片面板按弹药库的视觉语言重画：玻璃板 + 四角准星 + 带描边的数据瓷砖，
// 表尾只留电池。CPU/GPU/内存不再上这块卡片。抬头已按需求整块删掉。
const CGFloat kDeskPanelWidth = 272.0;

static const CGFloat kPad       = 14.0;
static const CGFloat kPadTop    = 13.0;
static const CGFloat kRadius    = 14.0;
static const CGFloat kRowH      = 21.0;
static const CGFloat kTileInset = 8.0;    // 数据瓷砖距卡片左右边
static const CGFloat kTilePadX  = 12.0;   // 瓷砖内文字距瓷砖边
static const CGFloat kFooterH   = 24.0;

// 到点动效：条子 0.45s ease-out、行级错峰 40ms、闪烁 0.28s、
// 网络灯 0.5s（延迟 60ms）、采样钟 0.30s；到点总时长约 0.56s。
static const double kPanelMeterDur       = 0.45;
static const double kPanelFlashDur       = 0.28;
static const double kPanelNetBlinkDur    = 0.50;
static const double kPanelClockFlashDur  = 0.30;
static const double kPanelRowStagger     = 0.04;
static const double kPanelNetDelay       = 0.06;
static const double kPanelTempDeadband   = 0.005;   // 0.5°C 以下不当成"变了"
static const double kPanelDiskDeadband   = 0.01;    // 1% 以下不当成"变了"
// 温度行两支温度计的尺寸只在这里写一份：绘制和组宽都从这组常量算。
static const CGFloat kTempGlyphW         = 7.2;
static const CGFloat kTempInnerGap       = 3.0;
static const CGFloat kTempGroupGap       = 10.0;
enum { kPanelMaxRows = 8 };

CGFloat DeskPanelMeterWidth(double fraction, CGFloat rowWidth) {
    if (!(fraction > 0) || rowWidth <= 0) return 0;
    return (CGFloat)MIN(1.0, fraction) * rowWidth;
}

NSInteger DeskPanelClockIndex(double secondsSinceSample) {
    if (!(secondsSinceSample > 0)) return 0;   // 负数/NaN 都当刚采完
    NSInteger idx = (NSInteger)floor(secondsSinceSample);
    return MIN(9, MAX(0, idx));
}

DeskPanelLevel DeskPanelTempLevel(double cpuTemp, double ssdTemp) {
    double hot = -1;
    if (cpuTemp > 0) hot = cpuTemp;
    if (ssdTemp > 0) hot = MAX(hot, ssdTemp);
    if (hot < 0) return DeskPanelLevelUnknown;
    if (hot < 70.0) return DeskPanelLevelNormal;
    if (hot <= 85.0) return DeskPanelLevelWarn;
    return DeskPanelLevelCritical;
}

double DeskPanelTempFraction(double cpuTemp, double ssdTemp) {
    double hot = -1;
    if (cpuTemp > 0) hot = cpuTemp;
    if (ssdTemp > 0) hot = MAX(hot, ssdTemp);
    return hot > 0 ? MIN(hot / 100.0, 1.0) : -1;
}

DeskPanelLevel DeskPanelDiskLevel(double fraction) {
    if (!(fraction >= 0)) return DeskPanelLevelUnknown;
    if (fraction < 0.80) return DeskPanelLevelNormal;
    if (fraction <= 0.90) return DeskPanelLevelWarn;
    return DeskPanelLevelCritical;
}

DeskPanelLevel DeskPanelBatteryLevel(double percent, BOOL onAC, BOOL charging) {
    if (!(percent >= 0)) return DeskPanelLevelUnknown;
    if (onAC || charging) return DeskPanelLevelNormal;
    if (percent > 20.0) return DeskPanelLevelNormal;
    if (percent >= 10.0) return DeskPanelLevelWarn;
    return DeskPanelLevelCritical;
}

DeskPanelLevel DeskPanelNetworkLevel(NSString *interface) {
    return interface.length > 0 ? DeskPanelLevelNormal : DeskPanelLevelCritical;
}

DeskPanelLevel DeskPanelIPv4Level(NSString *address) {
    return address.length > 0 ? DeskPanelLevelNormal : DeskPanelLevelCritical;
}

static NSColor *PanelAmber(void) {
    return [NSColor colorWithSRGBRed:1.0 green:0.77 blue:0.42 alpha:1.0];
}

static NSColor *PanelRed(void) {
    return [NSColor colorWithSRGBRed:1.0 green:0.42 blue:0.42 alpha:1.0];
}

static NSColor *PanelStatusColor(DeskPanelLevel level) {
    switch (level) {
        case DeskPanelLevelNormal:   return VaultCyan();
        case DeskPanelLevelWarn:     return PanelAmber();
        case DeskPanelLevelCritical: return PanelRed();
        default:                     return VaultMuted();
    }
}

// 闪烁用的浅色：正常青白、偏高浅琥珀、过高浅红。状态色本身太深，闪起来不够亮。
static NSColor *PanelStatusFlashColor(DeskPanelLevel level) {
    switch (level) {
        case DeskPanelLevelNormal:   return VaultCyanBright();
        case DeskPanelLevelWarn:     return [NSColor colorWithSRGBRed:1.0 green:0.91 blue:0.70 alpha:1.0];
        case DeskPanelLevelCritical: return [NSColor colorWithSRGBRed:1.0 green:0.76 blue:0.72 alpha:1.0];
        default:                     return VaultMuted();
    }
}

static NSString *PanelStatusText(NSUInteger row, DeskPanelLevel level) {
    if (level == DeskPanelLevelUnknown) return @"—";
    if (row == 0) {
        if (level == DeskPanelLevelNormal) return @"正常";
        if (level == DeskPanelLevelWarn) return @"偏高";
        return @"过高";
    }
    if (row == 1) {
        if (level == DeskPanelLevelNormal) return @"正常";
        if (level == DeskPanelLevelWarn) return @"偏高";
        return @"将满";
    }
    // 网络 / IPv4 只有在线 / 离线
    return level == DeskPanelLevelCritical ? @"离线" : @"在线";
}

static NSString *PanelBatteryStatusText(DeskPanelLevel level) {
    switch (level) {
        case DeskPanelLevelNormal:   return @"正常";
        case DeskPanelLevelWarn:     return @"偏低";
        case DeskPanelLevelCritical: return @"低";
        default:                     return @"—";
    }
}

static double PanelEaseOutCubic(double t) {
    t = MIN(1.0, MAX(0.0, t));
    double u = 1.0 - t;
    return 1.0 - u * u * u;
}

static NSColor *PanelBlend(NSColor *a, NSColor *b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    return [a blendedColorWithFraction:t ofColor:b] ?: a;
}

// 离线预览的离屏窗口不会上屏，isVisible 永远是 NO；给预览工具一个显式开关，
// 不然帧预览永远拍不到动效。正常 App 不设这个环境变量。
static BOOL PanelForceAnimation(void) {
    static int forced = -1;
    if (forced < 0) {
        forced = [[[NSProcessInfo processInfo] environment][@"DESK_PANEL_FORCE_ANIMATION"] boolValue] ? 1 : 0;
    }
    return forced == 1;
}

// HUD/Bare 的阴影只能加在文字属性上。用 `[sh set]` 会把药丸、电平条、瓷砖一起投影，
// 整块看起来发虚；drawRect 期间挂在这里，Attrs 给每段文字自动带上，画完清掉。
static NSShadow *gPanelTextShadow = nil;
static NSDictionary *Attrs(NSFont *font, NSColor *color) {
    if (gPanelTextShadow) {
        return @{NSFontAttributeName: font, NSForegroundColorAttributeName: color,
                 NSShadowAttributeName: gPanelTextShadow};
    }
    return @{NSFontAttributeName: font, NSForegroundColorAttributeName: color};
}

static NSAttributedString *FootSeg(NSString *s, NSFont *font, NSColor *color) {
    return [[NSAttributedString alloc] initWithString:s attributes:Attrs(font, color)];
}

static CGFloat LineHeight(NSFont *font) { return font.ascender - font.descender; }

@interface DeskPanelView () {
    double _meterNow[kPanelMaxRows];      // 屏幕上现在画到哪（0~1）
    double _meterFrom[kPanelMaxRows];     // 这一拍从哪开始长
    double _meterTarget[kPanelMaxRows];   // 这一拍要长到哪
    double _meterAge[kPanelMaxRows];      // 0..kPanelMeterDur
    double _meterDelay[kPanelMaxRows];    // 行级错峰：磁盘比温度晚 40ms
    BOOL _hasMeter[kPanelMaxRows];
    // 温度行有 CPU / SSD 两支温度计。第 0 行的 meter 走热的那颗（沿用原有缓动，
    // verify 也靠 meterFractionForRow:0）；冷的那颗单独一套水位，跨档时各涨各的。
    double _coldNow, _coldFrom, _coldTarget, _coldAge, _coldDelay;
    double _rowFlash[kPanelMaxRows];      // 1 -> 0，值/档位变了的行闪一下
    DeskPanelLevel _levels[kPanelMaxRows];       // 这一拍各行的档位（正常/偏高/过高）
    DeskPanelLevel _lastLevel[kPanelMaxRows];    // 上一拍的档位，用来判断"档位变了"
    DeskPanelLevel _battLevel;                   // 表尾电池档位
    double _netBlinkAge;                  // <0 = 网络灯不闪；0..kPanelNetBlinkDur 按流量闪
    double _netBlinkDelay;                // 到点后延迟 60ms 再开始闪
    double _clockFlash;
    NSInteger _clockIndex;                // 采样钟 0..9
    NSTimeInterval _sampleAt;
    BOOL _hasSample;
    NSArray<NSString *> *_lastRowText;    // 上一次上屏的 label/value，用来判断哪些行变了
    NSTimer *_clockTimer;
}
@end

// 行内小温度计：一根玻璃管 + 球泡 + 水银柱。管底和球泡接在一起，
// 水位按 frac 从下往上长；空管（没读数）只留玻璃和暗球泡。
static void DrawTempGlyph(CGFloat x, CGFloat yTop, double frac,
                          NSColor *tint, NSColor *bright, BOOL empty) {
    const CGFloat tubeW = 3.2, tubeH = 13.0, bulbD = 6.2;
    CGFloat tx = x + (kTempGlyphW - tubeW) / 2.0;
    NSRect trackRect = NSMakeRect(tx, yTop, tubeW, tubeH);
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:trackRect
                                                          xRadius:tubeW / 2.0 yRadius:tubeW / 2.0];
    [[VaultPaper() colorWithAlphaComponent:0.22] setFill];
    [track fill];
    [[VaultPaper() colorWithAlphaComponent:0.30] setStroke];
    track.lineWidth = 0.5;
    [track stroke];

    double f = MIN(1.0, MAX(0.0, frac));
    if (!empty && f > 0.001) {
        CGFloat h = tubeH * f;
        NSRect fillRect = NSMakeRect(tx, yTop + tubeH - h, tubeW, h);
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:fillRect
                                                             xRadius:MIN(tubeW / 2.0, h / 2.0)
                                                             yRadius:MIN(tubeW / 2.0, h / 2.0)];
        [tint setFill];
        [fill fill];
        // 水银面提亮一线，条子满了也还能看出水的边缘
        [[bright colorWithAlphaComponent:0.95] setFill];
        NSRectFill(NSMakeRect(tx, yTop + tubeH - h, tubeW, 0.8));
    }

    CGFloat bx = x + (kTempGlyphW - bulbD) / 2.0;
    NSRect bulbRect = NSMakeRect(bx, yTop + tubeH, bulbD, bulbD);
    [[tint colorWithAlphaComponent:empty ? 0.55 : 1.0] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:bulbRect] fill];
    NSRect coreRect = NSInsetRect(bulbRect, 1.9, 1.9);
    [[bright colorWithAlphaComponent:empty ? 0.35 : 0.85] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:coreRect] fill];
}

@implementation DeskPanelView

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        for (NSUInteger i = 0; i < kPanelMaxRows; i++) {
            _meterNow[i] = _meterFrom[i] = _meterTarget[i] = -1;
            _meterAge[i] = kPanelMeterDur;
            _meterDelay[i] = 0;
            _hasMeter[i] = NO;
            _rowFlash[i] = 0;
            _levels[i] = _lastLevel[i] = DeskPanelLevelUnknown;
        }
        _battLevel = DeskPanelLevelUnknown;
        _coldNow = _coldFrom = _coldTarget = -1;
        _coldAge = kPanelMeterDur;
        _coldDelay = 0;
        _netBlinkAge = -1;
        _netBlinkDelay = 0;
        _clockIndex = 0;
    }
    return self;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self startClockTimer];
    else [self stopClockTimer];
}

- (void)dealloc {
    [_clockTimer invalidate];
}

#pragma mark - 采样钟（常驻 1Hz，只有这一层）

- (void)startClockTimer {
    if (_clockTimer) return;
    __weak typeof(self) weakSelf = self;
    NSTimer *t = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf clockTick];
    }];
    t.tolerance = 0.1;
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    _clockTimer = t;
}

- (void)stopClockTimer {
    [_clockTimer invalidate];
    _clockTimer = nil;
}

// 采样钟只走到"下一次采样"的节拍，不逐帧画。被隐藏/收起时直接跳过，
// 被应用窗口压住的那 1 帧/秒不值得再用 CGWindowList 去问一次。
- (void)clockTick {
    if (!_hasSample || self.hiddenOrHasHiddenAncestor) return;
    NSWindow *w = self.window;
    if (!w || !w.isVisible) return;
    NSInteger idx = DeskPanelClockIndex([NSDate timeIntervalSinceReferenceDate] - _sampleAt);
    if (idx != _clockIndex) {
        _clockIndex = idx;
        [self setNeedsDisplay:YES];
    }
}

#pragma mark - 采样到点动效

- (void)setModel:(DeskModel *)model {
    BOOL first = (_lastRowText == nil);
    _model = model;

    NSArray<DeskStatRow *> *rows = model.statRows ?: @[];
    DeskStats *st = model.stats;
    DeskPanelLevel levels[kPanelMaxRows];
    for (NSUInteger i = 0; i < kPanelMaxRows; i++) levels[i] = DeskPanelLevelUnknown;
    levels[0] = DeskPanelTempLevel(st.cpuTemp, st.ssdTemp);
    levels[1] = DeskPanelDiskLevel(rows.count > 1 ? rows[1].fraction : -1);
    levels[2] = DeskPanelNetworkLevel(st.netInterface);
    levels[3] = DeskPanelIPv4Level(st.netAddress);
    DeskPanelLevel battLevel = st
        ? DeskPanelBatteryLevel(st.batteryPercent, st.batteryOnAC, st.batteryCharging)
        : DeskPanelLevelUnknown;

    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:rows.count];
    BOOL meaningful[kPanelMaxRows] = {0};
    BOOL barAnimate[kPanelMaxRows] = {0};
    for (NSUInteger i = 0; i < rows.count && i < kPanelMaxRows; i++) {
        DeskStatRow *r = rows[i];
        NSString *text = [NSString stringWithFormat:@"%@\n%@", r.label ?: @"", r.value ?: @""];
        [texts addObject:text];
        BOOL rowChanged = NO;
        BOOL labelChanged = NO;
        if (!first && (i >= _lastRowText.count || ![text isEqualToString:_lastRowText[i]])) {
            rowChanged = YES;
            NSString *oldText = i < _lastRowText.count ? _lastRowText[i] : @"";
            NSString *oldLabel = [[oldText componentsSeparatedByString:@"\n"] firstObject] ?: @"";
            labelChanged = ![oldLabel isEqualToString:(r.label ?: @"")];
        }

        double frac = r.fraction;
        BOOL has = frac >= 0;
        _hasMeter[i] = has;
        _meterTarget[i] = has ? MIN(1.0, MAX(0.0, frac)) : -1;
        _meterFrom[i] = _meterNow[i] >= 0 ? _meterNow[i] : _meterTarget[i];
        BOOL levelChanged = !first && _lastLevel[i] != levels[i];

        // 温度/磁盘：0.1°C / 1% 的抖动不播条子动画；但跨档位（正常→偏高）要闪一下，
        // 因为"进档"比数字变了更值得注意。
        if (i == 0 || i == 1) {
            BOOL bigEnough = NO;
            if (has && _meterNow[i] < 0) {
                bigEnough = YES;
            } else if (has) {
                double deadband = (i == 0) ? kPanelTempDeadband : kPanelDiskDeadband;
                bigEnough = labelChanged || fabs(_meterTarget[i] - _meterNow[i]) >= deadband;
            }
            meaningful[i] = rowChanged || levelChanged || bigEnough;
            barAnimate[i] = has && bigEnough;
        } else {
            meaningful[i] = rowChanged || levelChanged;
        }

        if (!has || !barAnimate[i]) {
            // 没有水位、变化太小、或只是跨档但数值几乎没动：条子直接到位
            _meterNow[i] = _meterTarget[i];
            _meterFrom[i] = _meterTarget[i];
            _meterAge[i] = kPanelMeterDur;
            _meterDelay[i] = 0;
        }
    }
    for (NSUInteger i = rows.count; i < kPanelMaxRows; i++) {
        _hasMeter[i] = NO;
        _meterNow[i] = _meterFrom[i] = _meterTarget[i] = -1;
        _meterAge[i] = kPanelMeterDur;
        _meterDelay[i] = 0;
        levels[i] = DeskPanelLevelUnknown;
    }
    for (NSUInteger i = 0; i < kPanelMaxRows; i++) _levels[i] = levels[i];
    _battLevel = battLevel;
    _lastRowText = [texts copy];

    // 冷的那颗温度计：两颗都有读数时才画第二支；取了更热的当主读数之后，
    // 另一颗才是"冷"的那支，所以热源切换时这支的目标会跟着跳。
    BOOL hotIsCpu = (st.cpuTemp > 0) && (st.ssdTemp > 0 ? st.cpuTemp >= st.ssdTemp : YES);
    double coldT = hotIsCpu ? st.ssdTemp : st.cpuTemp;
    BOOL hasCold = (st.cpuTemp > 0 && st.ssdTemp > 0) && coldT > 0;
    _coldTarget = hasCold ? MIN(1.0, MAX(0.0, coldT / 100.0)) : -1;
    _coldFrom = _coldNow >= 0 ? _coldNow : _coldTarget;
    BOOL coldBigEnough = NO;
    if (_coldTarget >= 0) {
        coldBigEnough = (_coldNow < 0) || fabs(_coldTarget - _coldNow) >= kPanelTempDeadband;
    } else {
        _coldNow = _coldFrom = _coldTarget = -1;
        _coldAge = kPanelMeterDur;
        _coldDelay = 0;
    }

    double net = 0;
    if (st) {
        if (st.netRecv >= 0 && st.netSend >= 0) net = st.netRecv + st.netSend;
        else if (st.netRecv >= 0) net = st.netRecv;
        else if (st.netSend >= 0) net = st.netSend;
    }
    BOOL link = st != nil && st.netInterface.length > 0;
    _sampleAt = [NSDate timeIntervalSinceReferenceDate];
    _clockIndex = 0;

    // 第一帧、变形/隐藏、离屏素材：直接到位，不播到点动效。
    // 这台机器系统层开着「减弱动态效果」，但项目里现有动画都不接这个开关，
    // 这里保持一致；要接的话在 animate 条件里加一条即可。
    BOOL visible = self.window != nil && !self.hiddenOrHasHiddenAncestor
                && (self.window.isVisible || PanelForceAnimation());
    BOOL animate = !first && visible;

    if (animate) {
        for (NSUInteger i = 0; i < kPanelMaxRows; i++) {
            _rowFlash[i] = meaningful[i] ? 1.0 : 0.0;
            if (!_hasMeter[i]) continue;
            if (barAnimate[i] && fabs(_meterFrom[i] - _meterTarget[i]) > 1e-9) {
                _meterAge[i] = 0;
                _meterDelay[i] = (i == 1) ? kPanelRowStagger : 0;   // 温度先，磁盘晚 40ms
            } else {
                _meterNow[i] = _meterTarget[i];
                _meterFrom[i] = _meterTarget[i];
                _meterAge[i] = kPanelMeterDur;
                _meterDelay[i] = 0;
            }
        }
        _clockFlash = 1.0;
        if (_coldTarget >= 0) {
            if (coldBigEnough && fabs(_coldFrom - _coldTarget) > 1e-9) {
                _coldAge = 0;
                _coldDelay = 0;
            } else {
                _coldNow = _coldFrom = _coldTarget;
                _coldAge = kPanelMeterDur;
                _coldDelay = 0;
            }
        }
        // 网络灯只在真有流量且网卡在时闪；1KB/s 以下当没动
        BOOL netActive = link && net >= 1024.0;
        _netBlinkAge = -1;
        _netBlinkDelay = netActive ? kPanelNetDelay : 0;
        if (self.onNeedFrames) self.onNeedFrames();
    } else {
        for (NSUInteger i = 0; i < kPanelMaxRows; i++) {
            _rowFlash[i] = 0.0;
            _meterDelay[i] = 0;
            if (_hasMeter[i]) {
                _meterFrom[i] = _meterTarget[i];
                _meterNow[i] = _meterTarget[i];
                _meterAge[i] = kPanelMeterDur;
            }
        }
        _clockFlash = 0.0;
        if (_coldTarget >= 0) {
            _coldNow = _coldFrom = _coldTarget;
            _coldAge = kPanelMeterDur;
            _coldDelay = 0;
        }
        _netBlinkAge = -1;
        _netBlinkDelay = 0;
    }
    for (NSUInteger i = 0; i < kPanelMaxRows; i++) _lastLevel[i] = levels[i];
    _hasSample = YES;
    [self setNeedsDisplay:YES];
}

- (void)tick:(double)dt {
    if (!(dt > 0)) return;
    BOOL moving = NO;
    for (NSUInteger i = 0; i < kPanelMaxRows; i++) {
        if (_hasMeter[i] && fabs(_meterFrom[i] - _meterTarget[i]) > 1e-9) {
            if (_meterDelay[i] > 0) {
                _meterDelay[i] -= dt;
                if (_meterDelay[i] < 0) _meterDelay[i] = 0;
                moving = YES;
            }
            if (_meterDelay[i] <= 0 && _meterAge[i] < kPanelMeterDur) {
                _meterAge[i] += dt;
                double t = MIN(1.0, _meterAge[i] / kPanelMeterDur);
                _meterNow[i] = _meterFrom[i] + (_meterTarget[i] - _meterFrom[i]) * PanelEaseOutCubic(t);
                if (t >= 1.0) {
                    _meterNow[i] = _meterTarget[i];
                    _meterFrom[i] = _meterTarget[i];
                }
                moving = YES;
            }
        }
        if (_rowFlash[i] > 0) {
            _rowFlash[i] = MAX(0.0, _rowFlash[i] - dt / kPanelFlashDur);
            moving = YES;
        }
    }
    if (_coldTarget >= 0 && fabs(_coldFrom - _coldTarget) > 1e-9) {
        if (_coldDelay > 0) {
            _coldDelay -= dt;
            if (_coldDelay < 0) _coldDelay = 0;
            moving = YES;
        }
        if (_coldDelay <= 0 && _coldAge < kPanelMeterDur) {
            _coldAge += dt;
            double t = MIN(1.0, _coldAge / kPanelMeterDur);
            _coldNow = _coldFrom + (_coldTarget - _coldFrom) * PanelEaseOutCubic(t);
            if (t >= 1.0) {
                _coldNow = _coldTarget;
                _coldFrom = _coldTarget;
            }
            moving = YES;
        }
    }
    if (_clockFlash > 0) { _clockFlash = MAX(0.0, _clockFlash - dt / kPanelClockFlashDur); moving = YES; }
    if (_netBlinkDelay > 0) {
        _netBlinkDelay -= dt;
        if (_netBlinkDelay <= 0) { _netBlinkDelay = 0; _netBlinkAge = 0; }
        moving = YES;
    } else if (_netBlinkAge >= 0) {
        _netBlinkAge += dt;
        if (_netBlinkAge >= kPanelNetBlinkDur) _netBlinkAge = -1;
        moving = YES;
    }
    if (moving) [self setNeedsDisplay:YES];
}

- (BOOL)needsRedraw {
    for (NSUInteger i = 0; i < kPanelMaxRows; i++) {
        if (_hasMeter[i] && fabs(_meterNow[i] - _meterTarget[i]) > 1e-4) return YES;
        if (_rowFlash[i] > 0) return YES;
    }
    if (_coldTarget >= 0 && fabs(_coldNow - _coldTarget) > 1e-4) return YES;
    return _clockFlash > 0 || _netBlinkDelay > 0 || _netBlinkAge >= 0;
}

- (void)settle {
    for (NSUInteger i = 0; i < kPanelMaxRows; i++) {
        if (_hasMeter[i]) {
            _meterNow[i] = _meterTarget[i];
            _meterFrom[i] = _meterTarget[i];
            _meterAge[i] = kPanelMeterDur;
        }
        _meterDelay[i] = 0;
        _rowFlash[i] = 0;
    }
    if (_coldTarget >= 0) {
        _coldNow = _coldFrom = _coldTarget;
        _coldAge = kPanelMeterDur;
    }
    _coldDelay = 0;
    _clockFlash = 0;
    _netBlinkAge = -1;
    _netBlinkDelay = 0;
    _clockIndex = _hasSample
        ? DeskPanelClockIndex([NSDate timeIntervalSinceReferenceDate] - _sampleAt) : 0;
    [self setNeedsDisplay:YES];
}

- (double)meterFractionForRow:(NSInteger)row {
    if (row < 0 || row >= kPanelMaxRows) return -1;
    return _meterNow[row];
}

- (double)tempColdFraction { return _coldNow; }

- (NSInteger)clockIndex { return _clockIndex; }

+ (void)rowGeometryForIndex:(NSUInteger)idx count:(NSUInteger)count
                          x:(CGFloat *)x width:(CGFloat *)width {
    (void)idx; (void)count;
    if (x) *x = kTileInset + kTilePadX;
    if (width) *width = kDeskPanelWidth - 2 * (kTileInset + kTilePadX);
}

+ (NSSize)sizeForModel:(DeskModel *)model {
    NSUInteger rows = model.statRows.count;
    CGFloat h = 2 * kPadTop + rows * kRowH
              + 8.0 /* 瓷砖上下内边距 */ + kFooterH;
    return NSMakeSize(kDeskPanelWidth, ceil(h));
}

- (CGFloat)drawStatusPill:(NSString *)text color:(NSColor *)color at:(CGFloat)x y:(CGFloat)y
                   height:(CGFloat)h font:(NSFont *)font {
    if (text.length == 0) return 0;
    // 药丸自己有半透明底和描边，再叠文字阴影会溢到药丸外，看着像一个发虚的光圈。
    NSDictionary *ta = @{NSFontAttributeName: font, NSForegroundColorAttributeName: color};
    CGFloat tw = [text sizeWithAttributes:ta].width;
    CGFloat pw = tw + 8.0;
    NSRect r = NSMakeRect(x, y, pw, h);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:3.5 yRadius:3.5];
    [[color colorWithAlphaComponent:0.10] setFill];
    [p fill];
    p.lineWidth = 0.5;
    [[color colorWithAlphaComponent:0.30] setStroke];
    [p stroke];
    CGFloat ty = y + (h - LineHeight(font)) / 2.0;
    [text drawAtPoint:NSMakePoint(x + 4.0, ty) withAttributes:ta];
    return pw;
}

- (void)drawLabel:(NSString *)label value:(NSString *)value at:(CGFloat)y
                x:(CGFloat)x right:(CGFloat)xRight
        labelFont:(NSFont *)labelFont valueFont:(NSFont *)valueFont
       labelColor:(NSColor *)labelColor valueColor:(NSColor *)valueColor
       statusText:(NSString *)statusText statusColor:(NSColor *)statusColor
       statusFont:(NSFont *)statusFont {
    NSDictionary *la = Attrs(labelFont, labelColor);
    NSDictionary *va = Attrs(valueFont, valueColor);
    [label drawAtPoint:NSMakePoint(x, y) withAttributes:la];
    CGFloat labelW = [label sizeWithAttributes:la].width;
    CGFloat valueLeft = x + labelW + 8.0;
    if (statusText.length) {
        CGFloat pillH = 12.5;
        CGFloat pillX = x + labelW + 6.0;
        CGFloat pillY = y + (LineHeight(labelFont) - pillH) / 2.0;
        CGFloat pw = [self drawStatusPill:statusText color:statusColor at:pillX y:pillY
                                   height:pillH font:statusFont];
        valueLeft = pillX + pw + 6.0;
    }
    CGFloat avail = xRight - valueLeft;
    CGFloat w = [value sizeWithAttributes:va].width;
    if (w > avail) {
        NSMutableDictionary *m = [va mutableCopy];
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByTruncatingMiddle;
        m[NSParagraphStyleAttributeName] = ps;
        va = m; w = avail;
    }
    [value drawInRect:NSMakeRect(xRight - w, y, w + 2, LineHeight(valueFont)) withAttributes:va];
}

- (void)drawDiskValueForStats:(DeskStats *)st atRight:(CGFloat)right y:(CGFloat)y
                         level:(DeskPanelLevel)level flash:(double)flash {
    if (!st || st.diskFraction < 0) return;
    NSFont *small = [NSFont monospacedSystemFontOfSize:7.5 weight:NSFontWeightRegular];
    NSFont *freeFont = [NSFont monospacedDigitSystemFontOfSize:13.5 weight:NSFontWeightSemibold];
    NSFont *unitFont = [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightRegular];
    NSFont *gFont = [NSFont monospacedDigitSystemFontOfSize:10.0 weight:NSFontWeightMedium];

    NSColor *base = VaultPaper();
    if (level == DeskPanelLevelWarn) base = PanelAmber();
    else if (level == DeskPanelLevelCritical) base = PanelRed();
    NSColor *numColor = PanelBlend(base, PanelStatusFlashColor(level), flash);
    NSColor *faint = [VaultPaper() colorWithAlphaComponent:0.72];

    NSString *meta = [NSString stringWithFormat:@"%.0f%% 已用 · %.0fG  ",
                      st.diskFraction * 100.0, st.diskTotal / 1e9];
    NSMutableAttributedString *line = [NSMutableAttributedString new];
    [line appendAttributedString:FootSeg(meta, small, faint)];
    [line appendAttributedString:FootSeg(@"剩 ", unitFont, faint)];
    [line appendAttributedString:FootSeg([NSString stringWithFormat:@"%.0f", st.diskFree / 1e9],
                                         freeFont, numColor)];
    [line appendAttributedString:FootSeg(@"G", gFont, numColor)];
    [line appendAttributedString:FootSeg(@" 可用", unitFont, faint)];

    NSSize sz = [line size];
    CGFloat vx = MAX(0.0, right - sz.width);
    CGFloat vy = y + MAX(0.0, (kRowH - 3.5 - sz.height) / 2.0);
    [line drawAtPoint:NSMakePoint(vx, vy)];
}

// 温度行：CPU / SSD 各一支温度计。热的那颗当主读数——随档位变暖、变值时闪；
// 另一颗退成小字。只有一颗有读数时只画一颗，都读不到就印一个破折号。
- (void)drawTempSensorsForStats:(DeskStats *)st
                        atRight:(CGFloat)right
                            rowY:(CGFloat)rowY
                           level:(DeskPanelLevel)level
                           flash:(double)flash
                        hotFrac:(double)hotFrac
                       coldFrac:(double)coldFrac {
    if (!st) return;
    BOOL hasCpu = st.cpuTemp > 0;
    BOOL hasSsd = st.ssdTemp > 0;
    NSFont *nameFont = [NSFont systemFontOfSize:7.5 weight:NSFontWeightSemibold];
    NSFont *numFont = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightSemibold];
    NSDictionary *nameAttrs = Attrs(nameFont, [VaultPaper() colorWithAlphaComponent:0.78]);
    CGFloat nameY = rowY + (kRowH - LineHeight(nameFont)) / 2.0;
    CGFloat numY = rowY + (kRowH - LineHeight(numFont)) / 2.0;

    if (!hasCpu && !hasSsd) {
        NSDictionary *da = Attrs(numFont, VaultMuted());
        CGFloat dw = [@"—" sizeWithAttributes:da].width;
        [@"—" drawAtPoint:NSMakePoint(right - dw, numY) withAttributes:da];
        return;
    }

    BOOL hotIsCpu = hasCpu && (hasSsd ? st.cpuTemp >= st.ssdTemp : YES);
    NSColor *levelColor = PanelStatusColor(level);
    NSColor *hotBase = VaultPaper();
    if (level == DeskPanelLevelWarn || level == DeskPanelLevelCritical) {
        hotBase = PanelBlend(VaultPaper(), levelColor, 0.45);
    }
    NSColor *hotColor = PanelBlend(hotBase, PanelStatusFlashColor(level), flash);

    // 每颗的文案/颜色/水位先算好，再从右往左整组对齐，组宽按实际字宽量。
    NSMutableArray<NSDictionary *> *groups = [NSMutableArray arrayWithCapacity:2];
    if (hasCpu) {
        DeskPanelLevel l = DeskPanelTempLevel(st.cpuTemp, -1);
        NSString *name = @"CPU";
        NSString *value = [NSString stringWithFormat:@"%.1f°", st.cpuTemp];
        CGFloat nameW = [name sizeWithAttributes:nameAttrs].width;
        CGFloat valW = [value sizeWithAttributes:Attrs(numFont, VaultPaper())].width;
        [groups addObject:@{
            @"name": name, @"value": value,
            @"nameW": @(nameW), @"width": @(nameW + kTempInnerGap + kTempGlyphW + kTempInnerGap + valW),
            @"color": hotIsCpu ? hotColor : VaultMuted(),
            @"tint": PanelStatusColor(l), @"bright": PanelStatusFlashColor(l),
            @"frac": @(hotIsCpu ? hotFrac : coldFrac),
        }];
    }
    if (hasSsd) {
        DeskPanelLevel l = DeskPanelTempLevel(-1, st.ssdTemp);
        NSString *name = @"SSD";
        NSString *value = [NSString stringWithFormat:@"%.0f°", st.ssdTemp];
        CGFloat nameW = [name sizeWithAttributes:nameAttrs].width;
        CGFloat valW = [value sizeWithAttributes:Attrs(numFont, VaultPaper())].width;
        [groups addObject:@{
            @"name": name, @"value": value,
            @"nameW": @(nameW), @"width": @(nameW + kTempInnerGap + kTempGlyphW + kTempInnerGap + valW),
            @"color": !hotIsCpu ? hotColor : VaultMuted(),
            @"tint": PanelStatusColor(l), @"bright": PanelStatusFlashColor(l),
            @"frac": @(!hotIsCpu ? hotFrac : coldFrac),
        }];
    }

    const CGFloat gap = kTempGroupGap;
    CGFloat total = gap * (groups.count - 1);
    for (NSDictionary *g in groups) total += [g[@"width"] doubleValue];
    CGFloat gx = right - total;
    for (NSDictionary *g in groups) {
        CGFloat nameW = [g[@"nameW"] doubleValue];
        [g[@"name"] drawAtPoint:NSMakePoint(gx, nameY) withAttributes:nameAttrs];
        double frac = [g[@"frac"] doubleValue];
        CGFloat tx = gx + nameW + kTempInnerGap;
        DrawTempGlyph(tx, rowY + 0.7, frac, g[@"tint"], g[@"bright"], !(frac >= 0));
        [g[@"value"] drawAtPoint:NSMakePoint(tx + kTempGlyphW + kTempInnerGap, numY)
                  withAttributes:Attrs(numFont, g[@"color"])];
        gx += [g[@"width"] doubleValue] + gap;
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    DeskModel *m = self.model ?: [DeskModel placeholderModel];
    NSRect b = self.bounds;
    BOOL glass = (self.style == DeskStyleHUD);

    // 无底 / HUD 两档没有自己的瓷砖，文字靠投影撑可读性；HUD 现在垫了签到槽同款墨底。
    // 但卡片里最小的字只有 7~9pt，5pt 柔影会把字缘糊掉；改用 2pt 紧影，只加在文字属性上。
    gPanelTextShadow = nil;
    if (self.style == DeskStyleHUD || self.style == DeskStyleBare) {
        NSShadow *sh = [NSShadow new];
        sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.90];
        sh.shadowBlurRadius = 2.0;
        sh.shadowOffset = CGSizeMake(0, -1.0);
        gPanelTextShadow = sh;
    }

    CGFloat left = kPad, right = NSMaxX(b) - kPad;
    NSFont *labelFont = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    NSFont *valueFont = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightSemibold];
    NSFont *footFont = [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightRegular];
    NSFont *footValueFont = [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightMedium];
    NSColor *labelColor = [VaultPaper() colorWithAlphaComponent:0.82];

    NSInteger count = (NSInteger)m.statRows.count;

    // 数据瓷砖：和弹药库的卡片同一套描边/薄雾；左侧一条亮边是"这一格在供电"的刻度。
    // 无边玻璃这一档不要内层瓷砖：整块卡已经是墨底，再加一张小卡就又成了"卡里卡"。
    CGFloat tileY = kPadTop;
    CGFloat tileH = count * kRowH + 8.0;
    NSRect tile = NSMakeRect(kTileInset, tileY, kDeskPanelWidth - 2 * kTileInset, tileH);
    if (!glass) {
        [[VaultInk() colorWithAlphaComponent:VaultCardFillAlpha(self.style, 0, 0)] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:tile xRadius:10.0 yRadius:10.0] fill];
        NSBezierPath *tileEdge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(tile, 0.5, 0.5)
                                                                 xRadius:10.0 yRadius:10.0];
        tileEdge.lineWidth = 1.0;
        [[VaultCyan() colorWithAlphaComponent:0.15] setStroke];
        [tileEdge stroke];
        [[VaultCyanBright() colorWithAlphaComponent:0.75] setFill];
        NSRectFill(NSMakeRect(NSMinX(tile), NSMinY(tile) + 8.0, 2.0, tileH - 16.0));
    }

    CGFloat x, w;
    [DeskPanelView rowGeometryForIndex:0 count:count x:&x width:&w];
    CGFloat rowsTop = tileY + 4.0;
    NSFont *statusFont = [NSFont systemFontOfSize:8.0 weight:NSFontWeightSemibold];
    NSFont *battStatusFont = [NSFont systemFontOfSize:8.0 weight:NSFontWeightSemibold];
    BOOL hasStats = (m.stats != nil);
    NSUInteger i = 0;
    for (DeskStatRow *row in m.statRows) {
        CGFloat rowY = rowsTop + i * kRowH;
        CGFloat textY = rowY + (kRowH - LineHeight(labelFont)) / 2.0;
        BOOL hasMeter = (i < kPanelMaxRows) ? _hasMeter[i] : NO;
        double frac = (i < kPanelMaxRows) ? _meterNow[i] : -1;
        double flash = (i < kPanelMaxRows) ? _rowFlash[i] : 0;
        double flashLevel = flash * flash;   // 闪一下立刻收，尾巴不拖
        DeskPanelLevel level = (i < kPanelMaxRows) ? _levels[i] : DeskPanelLevelUnknown;
        NSColor *levelColor = PanelStatusColor(level);
        NSColor *flashColor = PanelStatusFlashColor(level);

        // 行首状态灯：颜色跟档位走；网络/IP 只有在线/离线，离线时画空心红框。
        NSColor *led = levelColor;
        double ledAlpha = 0.55;
        BOOL hollow = NO;
        double netPulse = 0;
        if (i == 0 || i == 1) {
            if (level == DeskPanelLevelUnknown) {
                led = VaultMuted(); ledAlpha = 0.35; hollow = YES;
            } else if (level == DeskPanelLevelNormal) {
                ledAlpha = 0.65;
            } else if (level == DeskPanelLevelWarn) {
                ledAlpha = 0.88;
            } else {
                ledAlpha = 1.0;
            }
        } else if (i == 2) {
            BOOL link = hasStats && m.stats.netInterface.length > 0;
            led = link ? PanelStatusColor(DeskPanelLevelNormal) : PanelStatusColor(DeskPanelLevelCritical);
            ledAlpha = link ? 0.40 : 0.75;   // 常亮 = 网口在；闪 = 有流量
            hollow = !link;
            if (link && _netBlinkAge >= 0) {
                double phase = MIN(1.0, _netBlinkAge / kPanelNetBlinkDur);
                netPulse = 0.5 + 0.5 * cos(2.0 * M_PI * 3.0 * phase);
                ledAlpha = 0.15 + 0.80 * netPulse;
            }
        } else if (i == 3) {
            BOOL link = hasStats && m.stats.netAddress.length > 0;
            led = link ? PanelStatusColor(DeskPanelLevelNormal) : PanelStatusColor(DeskPanelLevelCritical);
            ledAlpha = link ? 0.75 : 0.85;
            hollow = !link;
        } else {
            led = VaultMuted(); ledAlpha = 0.35;
        }

        led = PanelBlend(led, flashColor, flashLevel);
        CGFloat ledY = rowY + kRowH / 2.0 - 2.0;
        double halo = MAX(flashLevel, i == 2 ? netPulse * 0.7 : 0.0) * 0.35;
        if (halo > 0.01) {
            [[led colorWithAlphaComponent:halo] setFill];
            NSRectFill(NSMakeRect(x - 2.0, ledY - 2.0, 8.0, 8.0));
        }
        if (hollow) {
            NSBezierPath *ring = [NSBezierPath bezierPathWithRect:
                                  NSInsetRect(NSMakeRect(x, ledY, 4.0, 4.0), 0.5, 0.5)];
            ring.lineWidth = 1.0;
            [[led colorWithAlphaComponent:ledAlpha] setStroke];
            [ring stroke];
        } else {
            [[led colorWithAlphaComponent:ledAlpha] setFill];
            NSRectFill(NSMakeRect(x, ledY, 4.0, 4.0));
        }

        if (i == 0 && hasStats) {
            // 温度行：标签和状态词照旧，数值换成 CPU / SSD 两支温度计。
            [self drawLabel:row.label value:@"" at:textY x:x + 8.0 right:x + w
                  labelFont:labelFont valueFont:valueFont
                 labelColor:labelColor
                 valueColor:VaultPaper()
                 statusText:PanelStatusText(i, level)
                 statusColor:levelColor
                 statusFont:statusFont];
            [self drawTempSensorsForStats:m.stats atRight:x + w rowY:rowY
                                    level:level flash:flashLevel
                                  hotFrac:frac coldFrac:_coldNow];
        } else if (i == 1 && hasStats && hasMeter) {
            // 磁盘行：标签/状态词照旧，数值改成混合字号——
            // 「剩 277G」是主读数，已用%/总量退成小字。
            [self drawLabel:row.label value:@"" at:textY x:x + 8.0 right:x + w
                  labelFont:labelFont valueFont:valueFont
                 labelColor:labelColor
                 valueColor:VaultPaper()
                 statusText:PanelStatusText(i, level)
                 statusColor:levelColor
                 statusFont:statusFont];
            [self drawDiskValueForStats:m.stats atRight:x + w y:rowY level:level flash:flashLevel];
        } else {
            [self drawLabel:row.label value:row.value at:textY x:x + 8.0 right:x + w
                  labelFont:labelFont valueFont:valueFont
                 labelColor:labelColor
                 valueColor:PanelBlend(VaultPaper(), flashColor, flashLevel)
                 statusText:PanelStatusText(i, level)
                 statusColor:levelColor
                 statusFont:statusFont];
        }

        if (hasMeter && i != 0) {
            // 行底电平条只剩磁盘一根（3.5pt）；温度行改成两支温度计。
            // 底分三段，刻度就是阈值。
            const CGFloat mh = 3.5, b1 = 0.80, b2 = 0.90;
            CGFloat my = rowY + kRowH - mh;
            [[VaultCyan() colorWithAlphaComponent:0.10] setFill];
            NSRectFill(NSMakeRect(x, my, w * b1, mh));
            [[PanelAmber() colorWithAlphaComponent:0.12] setFill];
            NSRectFill(NSMakeRect(x + w * b1, my, w * (b2 - b1), mh));
            [[PanelRed() colorWithAlphaComponent:0.13] setFill];
            NSRectFill(NSMakeRect(x + w * b2, my, w * (1.0 - b2), mh));

            CGFloat fw = DeskPanelMeterWidth(frac, w);
            if (fw > 0.5) {
                [[levelColor colorWithAlphaComponent:0.90] setFill];
                NSRectFill(NSMakeRect(x, my, fw, mh));
                CGFloat capW = MIN(3.0, fw);
                CGFloat capH = mh + 2.0;
                CGFloat capY = my - (capH - mh) / 2.0;
                [[flashColor colorWithAlphaComponent:0.98] setFill];
                NSRectFill(NSMakeRect(x + fw - capW, capY, capW, capH));
            }
            // 阈值刻度画在填充上面：值跨进哪一段，刻度和颜色都能对上。
            [[PanelAmber() colorWithAlphaComponent:0.75] setFill];
            NSRectFill(NSMakeRect(x + w * b1 - 0.75, my - 1.0, 1.5, mh + 2.0));
            [[PanelRed() colorWithAlphaComponent:0.80] setFill];
            NSRectFill(NSMakeRect(x + w * b2 - 0.75, my - 1.0, 1.5, mh + 2.0));
        } else if (i + 1 < count) {
            NSColor *rowLine = glass ? [NSColor colorWithWhite:1.0 alpha:0.055]
                                     : [VaultCyan() colorWithAlphaComponent:0.07];
            [rowLine setFill];
            NSRectFill(NSMakeRect(x, rowY + kRowH - 1.0, w, 1.0));
        }
        i++;
    }

    // 表尾：和弹药库底部"库位 6 / 12 · 空闲 6"同一条 8.5pt 等宽状态带。
    CGFloat footerLineY = tileY + tileH + 4.0;
    NSColor *footerLine = glass ? [NSColor colorWithWhite:1.0 alpha:0.09]
                                : [VaultCyan() colorWithAlphaComponent:0.14];
    NSColor *footerAccent = glass ? [NSColor colorWithWhite:1.0 alpha:0.32]
                                  : [VaultCyan() colorWithAlphaComponent:0.55];
    [footerLine setFill];
    NSRectFill(NSMakeRect(left, footerLineY, right - left, 1.0));
    [footerAccent setFill];
    NSRectFill(NSMakeRect(left, footerLineY, 24.0, 1.0));

    CGFloat footY = footerLineY + 6.0;
    NSString *battery = [DeskModel batteryStatusTextForStats:m.stats];
    NSMutableAttributedString *leftFoot = [NSMutableAttributedString new];
    [leftFoot appendAttributedString:FootSeg(@"电池 ", footFont,
                                              [VaultPaper() colorWithAlphaComponent:0.75])];
    [leftFoot appendAttributedString:FootSeg(battery, footValueFont, VaultPaper())];
    [leftFoot drawAtPoint:NSMakePoint(left, footY)];

    // 电池档位：交流电/充电中算正常；电池供电低于 20% 才提示偏低。
    CGFloat footW = [leftFoot size].width;
    CGFloat bpY = footY + (LineHeight(footValueFont) - 11.5) / 2.0;
    [self drawStatusPill:PanelBatteryStatusText(_battLevel)
                   color:PanelStatusColor(_battLevel)
                      at:left + footW + 6.0
                       y:bpY
                  height:11.5
                    font:battStatusFont];

    // 采样钟：10 格，1 秒亮一格；到点整排快闪一下再从头走。
    CGFloat segW = 3.0, segH = 7.0, segGap = 2.0;
    CGFloat clockW = 10 * segW + 9 * segGap;
    CGFloat clockX = right - clockW;
    CGFloat clockY = footY + 1.5;
    double cf = _clockFlash * _clockFlash;
    for (NSInteger k = 0; k < 10; k++) {
        BOOL lit = _hasSample && (k <= _clockIndex);
        NSColor *c = lit ? VaultCyan() : VaultMuted();
        double a = lit ? 0.85 : 0.20;
        if (cf > 0) {
            c = PanelBlend(c, VaultCyanBright(), cf);
            a = MAX(a, 0.35 + 0.45 * cf);
        }
        [[c colorWithAlphaComponent:a] setFill];
        NSRectFill(NSMakeRect(clockX + k * (segW + segGap), clockY, segW, segH));
    }

    if (!glass) VaultDrawReticle(b, 6.0, 13.0, VaultCyan(), 0.45, 1.2);
    gPanelTextShadow = nil;
}

@end

@implementation DeskCardView {
    DeskCardView *_source;        // 变形时的离屏素材源：先画一张正平面卡片
    NSWindow *_sourceHost;        // 脱离窗口的视图渲染朝向不确定，所以给它一个从不上屏的宿主
    NSBitmapImageRep *_flatRep;
    NSSize _cardSize;
    NSInteger _dragCorner;        // -1 = 没在拖角
    BOOL _draggingWindow;         // 用户亲手在拖窗口
    NSPoint _dragStartMouse;
    NSRect _frameAtDragStart;
    NSImage *_wallpaper;          // 弹药库式玻璃底：采样一次，位置/时间没变就复用
    NSRect _wallpaperRect;
    NSDate *_wallpaperAt;
}

+ (NSSize)windowSizeForModel:(DeskModel *)model style:(DeskStyle)style warped:(BOOL)warped {
    NSSize card = [DeskPanelView sizeForModel:model];
    // 变形后卡片的四角会跑到卡片矩形之外，窗口不留这一圈就会被裁掉
    return warped ? DeskWarpedWindowSize(card) : card;
}

- (instancetype)initWithModel:(DeskModel *)model style:(DeskStyle)style {
    return [self initWithModel:model style:style warped:NO];
}

- (instancetype)initWithModel:(DeskModel *)model style:(DeskStyle)style warped:(BOOL)warped {
    NSSize card = [DeskPanelView sizeForModel:model];
    NSSize win = warped ? DeskWarpedWindowSize(card) : card;
    if ((self = [super initWithFrame:NSMakeRect(0, 0, win.width, win.height)])) {
        _style = style;
        _cardSize = card;
        _dragCorner = -1;
        _panel = [[DeskPanelView alloc] initWithFrame:NSMakeRect(0, 0, card.width, card.height)];
        // 变形时面板是藏起来的（画的是投影位图），不缩放才不会一 resize 就偷偷变形
        _panel.autoresizingMask = NSViewNotSizable;
        // 面板播到点动效时把卡片外层的 60fps 表叫回来（外层再交给 main 的动画表）
        __weak typeof(self) weakSelf = self;
        _panel.onNeedFrames = ^{
            if (weakSelf.onNeedFrames) weakSelf.onNeedFrames();
        };
        _panel.model = model;
        _panel.style = style;
        [self addSubview:_panel];
        if (warped) [self syncWarp];
    }
    return self;
}

- (DeskQuad)currentQuad {
    return DeskQuadFromOffsets(_cardSize, _quadOffsets);
}

- (BOOL)isWarped {
    return !DeskQuadOffsetsIsZero(_quadOffsets) || _editing;
}

- (void)setQuadOffsets:(DeskQuadOffsets)offsets {
    _quadOffsets = offsets;
    [self syncWarp];
}

- (void)setEditing:(BOOL)editing {
    if (editing == _editing) return;
    _editing = editing;
    [self syncWarp];
}

// 变形和调角都走"位图投影"这一条路：面板本身画不出透视，只能先画正的去采样再 warp。
// 没变形时把面板挂回去实时绘制，文字才是原生清晰度。
- (void)syncWarp {
    BOOL warped = self.isWarped;
    _panel.hidden = warped;
    [self setNeedsDisplay:YES];
    if (!warped) { _source = nil; _sourceHost = nil; _flatRep = nil; [_panel settle]; return; }
    if (!_sourceHost) {
        NSRect inner = NSMakeRect(0, 0, _cardSize.width, _cardSize.height);
        _sourceHost = [[NSWindow alloc] initWithContentRect:inner
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered defer:NO];
        [_sourceHost setBackgroundColor:[NSColor clearColor]];
        _sourceHost.opaque = NO;
        _source = [[DeskCardView alloc] initWithModel:_panel.model style:self.style];
        _sourceHost.contentView = _source;   // 从不上屏，只当渲染素材用
        _source.autoresizingMask = NSViewNotSizable;   // 别跟着宿主窗口一起被撑开
    }
    [self refreshSource];
}

- (void)updateModel:(DeskModel *)model {
    self.panel.model = model;
    // 数据画在 panel 子视图里，不是这张卡片的 drawRect 里：只给 self 标脏的话，
    // 子视图会一直停在建窗第一帧（实测 CPU 永远显示 "—"、GPU 0），看起来像"系统状态不显示了"。
    [self.panel setNeedsDisplay:YES];
    _source.panel.model = model;
    [_source.panel setNeedsDisplay:YES];
    [self refreshSource];
    [self setNeedsDisplay:YES];
}

// 60fps 表走到这里。变形时整张是位图，逐帧重烘太贵，换拍数据直接跳到位。
- (void)tick:(double)dt {
    if (self.isWarped) return;
    [self.panel tick:dt];
}

- (BOOL)needsRedraw {
    if (self.isWarped) return NO;
    return [self.panel needsRedraw];
}

- (BOOL)isFlipped { return YES; }

// 卡片要独吞所有鼠标事件：面板只是画东西的，事件落到面板上就没人处理了（鼠标事件不沿响应链上传）
- (NSView *)hitTest:(NSPoint)point { return self; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

// 必须在没有别的视图正在绘制时调用：在别人的 drawRect 里做 cacheDisplayInRect
// 会继承那个上下文的翻转，投出来就是一张上下颠倒的卡片。
- (void)refreshSource {
    if (!self.isWarped || !_source) return;
    if (self.window) {
        // 宿主窗口只当"素材画板"用，尺寸必须始终等于卡片：一旦跟外窗一样大，
        // contentView 会被自动撑开，底板铺满而文字还留在左上角，看着就是内容缩小了。
        // 位置取外窗中心，实底卡采样壁纸时才对得上卡片背后那块。
        NSRect wf = self.window.frame;
        [_sourceHost setFrame:NSMakeRect(NSMidX(wf) - _cardSize.width / 2.0,
                                         NSMidY(wf) - _cardSize.height / 2.0,
                                         _cardSize.width, _cardSize.height)
                      display:NO];
    }
    NSRect src = NSMakeRect(0, 0, _cardSize.width, _cardSize.height);
    _source.frame = src;   // 上面 setFrame: 之后 contentView 可能已经被拉走，这里钉回来
    NSBitmapImageRep *rep = [_source bitmapImageRepForCachingDisplayInRect:src];
    [_source cacheDisplayInRect:src toBitmapImageRep:rep];
    _flatRep = rep;
}

#pragma mark - 拖四个角

- (NSPoint)canvasPointFromEvent:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    return NSMakePoint(p.x, self.bounds.size.height - p.y);   // quad 用 y 朝上，视图是翻转的
}

// 窗口拖动自己做，不用 movableByWindowBackground：这样"谁移动了窗口"是确定的 ——
// 只有 mouseDragged 是用户的手，系统切分辨率时的迁移根本不会走到这里
- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (self.editing && NSPointInRect(p, [self resetButtonRect])) {
        _quadOffsets = DeskQuadOffsetsZero();
        [self refreshSource];
        [self setNeedsDisplay:YES];
        if (self.onQuadEdit) self.onQuadEdit(_quadOffsets);
        if (self.onGeometryChange) self.onGeometryChange();
        return;
    }
    if (self.editing) {
        _dragCorner = DeskQuadHitTest(self.currentQuad, [self canvasPointFromEvent:e], 16.0);
        if (_dragCorner >= 0) return;
    }
    // 全局拖动：整块窗口（含变形留白）都能按住拖；全局锁定后只保留调角，不再挪窗
    if (self.locked) return;
    if (!NSPointInRect(p, self.bounds)) return;
    _draggingWindow = YES;
    _dragStartMouse = NSEvent.mouseLocation;
    _frameAtDragStart = self.window.frame;
}

- (void)mouseDragged:(NSEvent *)e {
    if (_dragCorner >= 0) {
        DeskQuad q = self.currentQuad;
        NSPoint *pts[4] = { &q.tl, &q.tr, &q.br, &q.bl };
        *pts[_dragCorner] = [self canvasPointFromEvent:e];
        _quadOffsets = DeskQuadOffsetsClamp(DeskQuadOffsetsFromQuad(q, _cardSize), _cardSize);
        [self refreshSource];
        [self setNeedsDisplay:YES];
        if (self.onGeometryChange) self.onGeometryChange();
        return;
    }
    if (!_draggingWindow) return;
    [self dragWindowToMouse:NSEvent.mouseLocation];
    if (self.onUserMove) self.onUserMove();
}

- (BOOL)isDragging { return _draggingWindow; }

- (void)dragWindowToMouse:(NSPoint)mouseNow {
    if (!self.window || self.locked) return;
    NSPoint to = NSMakePoint(_frameAtDragStart.origin.x + mouseNow.x - _dragStartMouse.x,
                             _frameAtDragStart.origin.y + mouseNow.y - _dragStartMouse.y);
    [self.window setFrameOrigin:to];
}

- (void)mouseUp:(NSEvent *)e {
    BOOL wasCorner = _dragCorner >= 0, wasWindow = _draggingWindow;
    _dragCorner = -1;
    _draggingWindow = NO;
    if (!wasCorner && !wasWindow) return;
    if (wasCorner && self.onQuadEdit) self.onQuadEdit(_quadOffsets);
    if (self.onGeometryChange) self.onGeometryChange();
}

- (NSRect)resetButtonRect {
    const CGFloat w = 64, h = 22;
    CGFloat cardBottom = kDeskQuadPad + _cardSize.height;   // 翻转坐标下卡片下边缘
    return NSMakeRect(round(NSMidX(self.bounds) - w / 2),
                      round(cardBottom + (kDeskQuadPad - h) / 2.0), w, h);
}

- (void)drawHandles {
    DeskPalette p = DeskPaletteFor(self.style, DeskViewIsDark(self));
    DeskQuad q = self.currentQuad;
    NSPoint pts[4] = { q.tl, q.tr, q.br, q.bl };
    NSPoint viewPts[4];
    for (int i = 0; i < 4; i++) {
        viewPts[i] = NSMakePoint(pts[i].x, self.bounds.size.height - pts[i].y);
    }
    NSBezierPath *edge = [NSBezierPath bezierPath];
    [edge moveToPoint:viewPts[0]];
    for (int i = 1; i < 4; i++) [edge lineToPoint:viewPts[i]];
    [edge closePath];
    edge.lineWidth = 1.0;
    [[p.accent colorWithAlphaComponent:0.35] setStroke];
    [edge stroke];

    for (int i = 0; i < 4; i++) {
        NSRect knob = NSMakeRect(viewPts[i].x - 5, viewPts[i].y - 5, 10, 10);
        [[NSColor colorWithWhite:1.0 alpha:0.92] setFill];
        [[NSBezierPath bezierPathWithRect:knob] fill];
        [p.accent setStroke];
        NSBezierPath *ring = [NSBezierPath bezierPathWithRect:NSInsetRect(knob, -0.5, -0.5)];
        ring.lineWidth = 1.0;
        [ring stroke];
    }

    NSRect btn = [self resetButtonRect];
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:btn xRadius:btn.size.height / 2
                                                        yRadius:btn.size.height / 2];
    [[p.accent colorWithAlphaComponent:0.18] setFill];
    [pill fill];
    [[p.accent colorWithAlphaComponent:0.7] setStroke];
    pill.lineWidth = 1.0;
    [pill stroke];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: p.primary,
                            NSParagraphStyleAttributeName: ps};
    [@"重置" drawInRect:NSMakeRect(btn.origin.x, btn.origin.y + 3, btn.size.width, btn.size.height)
         withAttributes:attrs];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    if (self.isWarped) {
        if (!_flatRep) [self refreshSource];
        NSImage *warped = DeskQuadRender(_flatRep, b.size, self.currentQuad);
        [warped drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    } else {
        NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:b xRadius:kRadius yRadius:kRadius];
        [clip addClip];
        switch (self.style) {
            case DeskStylePlate:
                VaultDrawPlatePlate(b, [self sampledWallpaper], -1, 0);
                break;
            case DeskStyleFeather:
                VaultDrawPlateFeather(b);
                break;
            case DeskStyleHUD:
                // 原来整块完全透底，白壁纸上行值和表尾都读不出来；
                // 按签到槽补一层墨底（2026-11-09），内容直接落在上面，不再加内层瓷砖。
                VaultDrawInkPlate(b, kRadius, 0.56, 0.14);
                break;
            case DeskStyleBare:
            default:
                break;
        }
        if (self.style != DeskStyleBare && self.style != DeskStyleHUD) {
            NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5)
                                                                 xRadius:kRadius yRadius:kRadius];
            edge.lineWidth = 1.0;
            [[VaultCyan() colorWithAlphaComponent:0.16] setStroke];
            [edge stroke];
        }
    }
    if (self.editing) [self drawHandles];
}

// 采样壁纸只做一次，位置没动且 6 秒内复用 —— 和弹药库/活动监视器同一条缓存规则。
// 采样失败时返回旧图；从没采到就返回 nil，VaultDrawPlatePlate 会退到它的程序化底图。
- (NSImage *)sampledWallpaper {
    NSRect r = self.window ? self.window.frame : NSZeroRect;
    if (NSEqualRects(r, NSZeroRect)) return nil;
    BOOL moved = !NSEqualRects(r, _wallpaperRect);
    NSTimeInterval age = _wallpaperAt ? [[NSDate date] timeIntervalSinceDate:_wallpaperAt] : 1e9;
    if (_wallpaper && !moved && age < 6.0) return _wallpaper;
    NSImage *img = [[DeskBackdrop shared] imageForRect:r dark:YES];
    if (!img) return _wallpaper;
    _wallpaper = img; _wallpaperRect = r; _wallpaperAt = [NSDate date];
    return _wallpaper;
}

@end
