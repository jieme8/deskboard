#import "hud.h"

static const CGFloat kHudH = 26.0;
static const CGFloat kHudPad = 12.0;
static const CGFloat kHudBtnW = 44.0;
static const CGFloat kHudBtnH = 18.0;
static const CGFloat kHudGap = 10.0;

static NSColor *RGBA(int r, int g, int b, double a) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

static NSFont *TextFont(void)   { return [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium]; }
static NSFont *StatusFont(void) { return [NSFont systemFontOfSize:10.0 weight:NSFontWeightRegular]; }
static NSFont *ButtonFont(void) { return [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold]; }

static CGFloat TextW(NSString *s, NSFont *f) {
    return s.length ? ceil([s sizeWithAttributes:@{NSFontAttributeName: f}].width) : 0;
}

@implementation DeskHudView

- (BOOL)isFlipped { return YES; }

+ (NSSize)sizeForReadout:(NSString *)readout status:(NSString *)status {
    CGFloat w = kHudPad + TextW(readout, TextFont());
    if (status.length) w += 6.0 + TextW(status, StatusFont());
    w += kHudGap + kHudBtnW + kHudPad;
    return NSMakeSize(ceil(w), kHudH);
}

- (NSRect)buttonRect {
    NSRect b = self.bounds;
    return NSMakeRect(NSMaxX(b) - kHudPad - kHudBtnW, round((b.size.height - kHudBtnH) / 2.0),
                      kHudBtnW, kHudBtnH);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    NSColor *accent = self.dirty ? RGBA(112, 216, 255, 1) : RGBA(112, 216, 255, 0.55);

    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 1, 1)
                                                        xRadius:b.size.height / 2 - 1
                                                        yRadius:b.size.height / 2 - 1];
    [RGBA(8, 20, 34, 0.82) setFill];
    [pill fill];
    [[accent colorWithAlphaComponent:self.dirty ? 0.85 : 0.4] setStroke];
    pill.lineWidth = 1.0;
    [pill stroke];

    CGFloat x = NSMinX(b) + kHudPad;
    CGFloat textY = round((b.size.height - TextFont().capHeight - 6) / 2.0);
    [self.readout drawAtPoint:NSMakePoint(x, textY)
               withAttributes:@{NSFontAttributeName: TextFont(),
                                NSForegroundColorAttributeName: RGBA(206, 236, 252, 1)}];
    x += TextW(self.readout, TextFont());
    if (self.status.length) {
        x += 6.0;
        [self.status drawAtPoint:NSMakePoint(x, round((b.size.height - StatusFont().capHeight - 6) / 2.0))
                  withAttributes:@{NSFontAttributeName: StatusFont(),
                                   NSForegroundColorAttributeName:
                                       (self.dirty ? accent : RGBA(126, 160, 186, 1))}];
    }

    NSRect btn = [self buttonRect];
    NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:btn xRadius:btn.size.height / 2
                                                      yRadius:btn.size.height / 2];
    [[accent colorWithAlphaComponent:self.dirty ? 0.28 : 0.12] setFill];
    [bp fill];
    [accent setStroke];
    bp.lineWidth = 1.0;
    [bp stroke];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    // 按钮永远叫「保存」，没东西可存时只是变暗；状态文字才负责报"已保存 13:20"
    [@"保存" drawInRect:NSMakeRect(btn.origin.x, btn.origin.y + 3,
                                                            btn.size.width, btn.size.height)
        withAttributes:@{NSFontAttributeName: ButtonFont(),
                         NSForegroundColorAttributeName:
                             (self.dirty ? RGBA(226, 246, 255, 1) : RGBA(226, 246, 255, 0.42)),
                         NSParagraphStyleAttributeName: ps}];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, [self buttonRect]) && self.onSave) self.onSave();
}

@end
