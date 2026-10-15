#import "quad.h"
#import <CoreImage/CoreImage.h>
#import <math.h>

const CGFloat kDeskQuadPad = 60.0;
static const CGFloat kDeskQuadMaxShift = 140.0;   // 单个角最多拖出 140pt，再大就烂得没法看了

// 卡片在画布里居中，所以原角点位置只由卡片尺寸决定，正反向换算共用这一处
static void CardCorners(NSSize cardSize, NSPoint *tl, NSPoint *tr, NSPoint *br, NSPoint *bl) {
    CGFloat left = kDeskQuadPad, right = kDeskQuadPad + cardSize.width;
    CGFloat bottom = kDeskQuadPad, top = kDeskQuadPad + cardSize.height;
    if (tl) { tl->x = left; tl->y = top; }
    if (tr) { tr->x = right; tr->y = top; }
    if (br) { br->x = right; br->y = bottom; }
    if (bl) { bl->x = left; bl->y = bottom; }
}

DeskQuad DeskQuadFromOffsets(NSSize cardSize, DeskQuadOffsets off) {
    DeskQuad q;
    CardCorners(cardSize, &q.tl, &q.tr, &q.br, &q.bl);
    q.tl.x += off.tl.width; q.tl.y += off.tl.height;
    q.tr.x += off.tr.width; q.tr.y += off.tr.height;
    q.br.x += off.br.width; q.br.y += off.br.height;
    q.bl.x += off.bl.width; q.bl.y += off.bl.height;
    return q;
}

DeskQuadOffsets DeskQuadOffsetsFromQuad(DeskQuad q, NSSize cardSize) {
    DeskQuad base;
    CardCorners(cardSize, &base.tl, &base.tr, &base.br, &base.bl);
    return (DeskQuadOffsets){
        NSMakeSize(q.tl.x - base.tl.x, q.tl.y - base.tl.y),
        NSMakeSize(q.tr.x - base.tr.x, q.tr.y - base.tr.y),
        NSMakeSize(q.br.x - base.br.x, q.br.y - base.br.y),
        NSMakeSize(q.bl.x - base.bl.x, q.bl.y - base.bl.y),
    };
}

static NSSize ClampShift(NSSize v) {
    return NSMakeSize(MIN(MAX(v.width, -kDeskQuadMaxShift), kDeskQuadMaxShift),
                      MIN(MAX(v.height, -kDeskQuadMaxShift), kDeskQuadMaxShift));
}

DeskQuadOffsets DeskQuadOffsetsClamp(DeskQuadOffsets off, NSSize cardSize) {
    off.tl = ClampShift(off.tl); off.tr = ClampShift(off.tr);
    off.br = ClampShift(off.br); off.bl = ClampShift(off.bl);

    // 更硬的限制是别把角拖出画布：窗口只有那么大，出去了就看不见也拖不回来。
    // 留 8pt 内缩是给把手本身留位置。
    DeskQuad q = DeskQuadFromOffsets(cardSize, off);
    NSSize canvas = DeskQuadCanvasSize(cardSize);
    const CGFloat inset = 8.0;
    NSPoint *pts[4] = { &q.tl, &q.tr, &q.br, &q.bl };
    for (int i = 0; i < 4; i++) {
        pts[i]->x = MIN(MAX(pts[i]->x, inset), canvas.width - inset);
        pts[i]->y = MIN(MAX(pts[i]->y, inset), canvas.height - inset);
    }
    return DeskQuadOffsetsFromQuad(q, cardSize);
}

NSRect DeskQuadBounds(DeskQuad q) {
    CGFloat minX = MIN(MIN(q.tl.x, q.tr.x), MIN(q.br.x, q.bl.x));
    CGFloat maxX = MAX(MAX(q.tl.x, q.tr.x), MAX(q.br.x, q.bl.x));
    CGFloat minY = MIN(MIN(q.tl.y, q.tr.y), MIN(q.br.y, q.bl.y));
    CGFloat maxY = MAX(MAX(q.tl.y, q.tr.y), MAX(q.br.y, q.bl.y));
    return NSMakeRect(minX, minY, maxX - minX, maxY - minY);
}

NSInteger DeskQuadHitTest(DeskQuad q, NSPoint p, CGFloat radius) {
    NSPoint pts[4] = { q.tl, q.tr, q.br, q.bl };
    for (NSInteger i = 0; i < 4; i++) {
        if (hypot(p.x - pts[i].x, p.y - pts[i].y) <= radius) return i;
    }
    return -1;
}

static NSString *SizeText(NSSize s) {
    return [NSString stringWithFormat:@"%g,%g", s.width, s.height];
}

static NSSize ParseSize(NSString *s) {
    NSArray<NSString *> *parts = [s componentsSeparatedByString:@","];
    if (parts.count != 2) return NSZeroSize;
    return NSMakeSize(parts[0].doubleValue, parts[1].doubleValue);
}

NSString *DeskQuadOffsetsString(DeskQuadOffsets off) {
    return [NSString stringWithFormat:@"%@;%@;%@;%@", SizeText(off.tl), SizeText(off.tr),
                                      SizeText(off.br), SizeText(off.bl)];
}

DeskQuadOffsets DeskQuadOffsetsFromString(NSString *s) {
    DeskQuadOffsets off = DeskQuadOffsetsZero();
    NSArray<NSString *> *parts = [s componentsSeparatedByString:@";"];
    if (parts.count != 4) return off;
    off.tl = ParseSize(parts[0]); off.tr = ParseSize(parts[1]);
    off.br = ParseSize(parts[2]); off.bl = ParseSize(parts[3]);
    return off;
}

NSImage *DeskQuadRender(NSBitmapImageRep *source, NSSize canvas, DeskQuad quad) {
    if (!source || canvas.width < 1 || canvas.height < 1) return nil;
    // rep.CGImage 是 +0（头里没标 CF_RETURNS_RETAINED），多 release 一次就会在 rep  dealloc 时炸
    CGImageRef cg = [source CGImage];
    if (!cg) return nil;
    CIImage *flat = [CIImage imageWithCGImage:cg];
    if (!flat || flat.extent.size.width < 1) return nil;

    // 屏幕上的视图位图是 2x 的，而 quad 是点坐标：先统一到像素，最后再按点尺寸包回 NSImage，
    // 否则投影出来的是糊的
    double scale = source.size.width > 0 ? source.pixelsWide / source.size.width : 1.0;
    NSSize px = NSMakeSize(canvas.width * scale, canvas.height * scale);
    DeskQuad q = {
        { quad.tl.x * scale, quad.tl.y * scale }, { quad.tr.x * scale, quad.tr.y * scale },
        { quad.br.x * scale, quad.br.y * scale }, { quad.bl.x * scale, quad.bl.y * scale },
    };

    // 实测结论（源图四角染色 + 逐个推角）：CIPerspectiveTransform 的四个目标角用的是 y 朝下的
    // 屏幕坐标，而 cacheDisplayInRect: 出来的位图行 0 就落在 extent 原点。两个都按 y 朝上喂，
    // 恒等投影看着完全正常（矩形对称），一拖角就变成"拖左上角、右下角动、上下还反着"。
    // 所以这里源图只做平移，四个目标角统一镜像一次 y，标签仍跟视觉角点一致。
    CGFloat dx = (px.width - flat.extent.size.width) / 2.0;
    CGFloat dy = (px.height - flat.extent.size.height) / 2.0;
    CGRect ext = flat.extent;
    CGAffineTransform placeT = CGAffineTransformMakeTranslation(dx - ext.origin.x,
                                                                dy - ext.origin.y);
    CIFilter *place = [CIFilter filterWithName:@"CIAffineTransform"];
    [place setValue:flat forKey:kCIInputImageKey];
    [place setValue:[NSValue valueWithBytes:&placeT objCType:@encode(CGAffineTransform)]
             forKey:kCIInputTransformKey];
    CIImage *centered = place.outputImage ?: flat;

    CGFloat H = px.height;
    CIFilter *warp = [CIFilter filterWithName:@"CIPerspectiveTransform"];
    [warp setValue:centered forKey:kCIInputImageKey];
    [warp setValue:[CIVector vectorWithX:q.tl.x Y:H - q.tl.y] forKey:@"inputTopLeft"];
    [warp setValue:[CIVector vectorWithX:q.tr.x Y:H - q.tr.y] forKey:@"inputTopRight"];
    [warp setValue:[CIVector vectorWithX:q.bl.x Y:H - q.bl.y] forKey:@"inputBottomLeft"];
    [warp setValue:[CIVector vectorWithX:q.br.x Y:H - q.br.y] forKey:@"inputBottomRight"];
    CIImage *out = warp.outputImage;
    if (!out) return nil;

    static CIContext *ctx;
    if (!ctx) ctx = [CIContext contextWithOptions:nil];
    CGImageRef rendered = [ctx createCGImage:out fromRect:NSMakeRect(0, 0, px.width, px.height)];
    if (!rendered) return nil;
    NSImage *img = [[NSImage alloc] initWithCGImage:rendered size:canvas];
    CGImageRelease(rendered);
    return img;
}
