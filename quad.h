// 四角自由变形：把卡片四角各自位移一点，投影成任意四边形，透视效果由你手调。
// 坐标一律是画布坐标（y 朝上，原点在画布左下角），卡片在画布里居中留 kDeskQuadPad 的余量，
// 这样拖出去的四角不会被窗口裁掉。鼠标位置来自翻转视图，换算只在用的那一处做。
#import <AppKit/AppKit.h>

extern const CGFloat kDeskQuadPad;   // 允许把角拖出卡片边多远

typedef struct {
    NSPoint tl, tr, br, bl;   // 四个目标角（画布坐标，y 朝上）
} DeskQuad;

typedef struct {
    NSSize tl, tr, br, bl;    // 每个角相对卡片原角点的位移，点为单位
} DeskQuadOffsets;

static inline DeskQuadOffsets DeskQuadOffsetsZero(void) {
    DeskQuadOffsets o;
    o.tl = o.tr = o.br = o.bl = NSZeroSize;
    return o;
}

static inline BOOL DeskQuadOffsetsIsZero(DeskQuadOffsets o) {
    return NSEqualSizes(o.tl, NSZeroSize) && NSEqualSizes(o.tr, NSZeroSize)
        && NSEqualSizes(o.br, NSZeroSize) && NSEqualSizes(o.bl, NSZeroSize);
}

static inline NSSize DeskQuadCanvasSize(NSSize cardSize) {
    return NSMakeSize(cardSize.width + kDeskQuadPad * 2, cardSize.height + kDeskQuadPad * 2);
}

DeskQuad DeskQuadFromOffsets(NSSize cardSize, DeskQuadOffsets off);
DeskQuadOffsets DeskQuadOffsetsFromQuad(DeskQuad q, NSSize cardSize);
// 把每个角收进画布内，并限制单个角的位移幅度，防止拖到看不见的地方
DeskQuadOffsets DeskQuadOffsetsClamp(DeskQuadOffsets off, NSSize cardSize);
NSRect DeskQuadBounds(DeskQuad q);
// 命中测试：返回 0=左上 1=右上 2=右下 3=左下，都没碰到返回 -1
NSInteger DeskQuadHitTest(DeskQuad q, NSPoint p, CGFloat radius);

NSString *DeskQuadOffsetsString(DeskQuadOffsets off);
DeskQuadOffsets DeskQuadOffsetsFromString(NSString *s);

// 把已经画好的平面卡片位图按 quad 投影到 canvas 大小的透明图（y 朝上，不会翻）
NSImage *DeskQuadRender(NSBitmapImageRep *source, NSSize canvas, DeskQuad quad);
