// 取色与选址测量：把壁纸量化成可核对的数字，避免凭感觉配色、凭感觉挑默认位置。
// 用法：palette <图片> <屏幕宽> <屏幕高> <卡片宽> <卡片高> [边距]
// 坐标用 WindowServer 口径（主屏左上角原点、向下为正），假设壁纸按 AspectFill 居中裁剪。
#import <AppKit/AppKit.h>

static void PrintColor(const char *tag, NSColor *c) {
    NSColor *s = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    printf("  %-26s #%02X%02X%02X  (%.3f, %.3f, %.3f)\n", tag,
           (int)lround(s.redComponent * 255), (int)lround(s.greenComponent * 255),
           (int)lround(s.blueComponent * 255), s.redComponent, s.greenComponent, s.blueComponent);
}

static double Luminance(NSColor *c) {
    NSColor *s = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    double f[3] = {s.redComponent, s.greenComponent, s.blueComponent}, lin[3];
    for (int i = 0; i < 3; i++) {
        lin[i] = f[i] <= 0.03928 ? f[i] / 12.92 : pow((f[i] + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
}

static double Contrast(double a, double b) {
    return (fmax(a, b) + 0.05) / (fmin(a, b) + 0.05);
}

typedef struct { double n, r, g, b; } Accum;

static void Add(Accum *a, NSColor *c) {
    a->n += 1; a->r += c.redComponent; a->g += c.greenComponent; a->b += c.blueComponent;
}

static NSColor *Mean(Accum a) {
    double n = a.n ?: 1;
    return [NSColor colorWithRed:a.r / n green:a.g / n blue:a.b / n alpha:1];
}

typedef struct { double lum, stdev, edge; Accum avg; } RegionStats;

static double ScreenToImageX(double sx, double cutX, double screenW, double imgW) {
    return (sx - cutX) / screenW * imgW;
}
static double ScreenToImageY(double sy, double cutY, double screenH, double imgH) {
    return (sy - cutY) / screenH * imgH;
}

// 在给定屏幕矩形内按 pitch 点距采样，算亮度均值/标准差与相邻点差分能量（越大越"花"）
static RegionStats ScanRegion(NSBitmapImageRep *rep, NSRect region, double cutX, double cutY,
                              double screenW, double screenH, double pitch) {
    RegionStats out; memset(&out, 0, sizeof out);
    double imgW = rep.pixelsWide, imgH = rep.pixelsHigh;
    NSInteger cols = (NSInteger)floor(region.size.width / pitch);
    NSInteger rows = (NSInteger)floor(region.size.height / pitch);
    double *lums = calloc((size_t)cols * rows, sizeof(double));
    NSInteger n = 0;
    double sum = 0, sumSq = 0, edge = 0, edgeN = 0;
    for (NSInteger j = 0; j < rows; j++) {
        for (NSInteger i = 0; i < cols; i++) {
            double sx = region.origin.x + (i + 0.5) * pitch;
            double sy = region.origin.y + (j + 0.5) * pitch;
            NSColor *raw = [rep colorAtX:(NSInteger)ScreenToImageX(sx, cutX, screenW, imgW)
                                       y:(NSInteger)ScreenToImageY(sy, cutY, screenH, imgH)];
            if (!raw) continue;
            NSColor *c = [raw colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            Add(&out.avg, c);
            double l = Luminance(c);
            lums[n++] = l;
            sum += l; sumSq += l * l;
            if (i > 0) { edge += fabs(l - lums[n - 2]); edgeN += 1; }
            if (j > 0) { edge += fabs(l - lums[n - 1 - cols]); edgeN += 1; }
        }
    }
    double mean = n ? sum / n : 0;
    double var = n ? fmax(sumSq / n - mean * mean, 0) : 0;
    out.lum = mean;
    out.stdev = sqrt(var);
    out.edge = edgeN ? edge / edgeN : 0;
    free(lums);
    return out;
}

static NSString *CornerName(NSInteger c) {
    return (@[@"左上", @"右上", @"左下", @"右下"])[c];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 6) {
            fprintf(stderr, "用法：palette <图片> <屏幕宽> <屏幕高> <卡片宽> <卡片高> [边距]\n");
            return 2;
        }
        NSString *path = @(argv[1]);
        double screenW = atof(argv[2]), screenH = atof(argv[3]);
        double cardW = atof(argv[4]), cardH = atof(argv[5]);
        double margin = argc > 6 ? atof(argv[6]) : 12;

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:path]];
        if (!rep) {
            fprintf(stderr, "读不到图片：%s\n", path.UTF8String);
            return 1;
        }
        double imgW = rep.pixelsWide, imgH = rep.pixelsHigh;
        double scale = fmax(screenW / imgW, screenH / imgH);
        double cutX = (imgW * scale - screenW) / 2.0 / scale;
        double cutY = (imgH * scale - screenH) / 2.0 / scale;
        printf("图片 %.0fx%.0f，屏幕 %.0fx%.0f，缩放 %.4f，居中裁掉 水平 %.0fpt / 垂直 %.0fpt\n",
               imgW, imgH, screenW, screenH, scale, cutX, cutY);

        const NSInteger gx = 140, gy = 90;
        Accum whole = {0};
        NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *bins = [NSMutableDictionary dictionary];
        double lumSum = 0, darkShare = 0, lightShare = 0;
        double bestSatScore = 0;
        NSColor *bestSat = nil;

        for (NSInteger j = 0; j < gy; j++) {
            for (NSInteger i = 0; i < gx; i++) {
                double sx = cutX + (i + 0.5) / gx * screenW;
                double sy = cutY + (j + 0.5) / gy * screenH;
                NSColor *raw = [rep colorAtX:(NSInteger)ScreenToImageX(sx, cutX, screenW, imgW)
                                          y:(NSInteger)ScreenToImageY(sy, cutY, screenH, imgH)];
                if (!raw) continue;
                NSColor *c = [raw colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
                Add(&whole, c);
                NSInteger key = ((NSInteger)(c.redComponent * 7) << 8)
                              | ((NSInteger)(c.greenComponent * 7) << 4)
                              | (NSInteger)(c.blueComponent * 7);
                NSMutableArray<NSNumber *> *b = bins[@(key)];
                if (!b) {
                    b = [NSMutableArray arrayWithObjects:@(0.0), @(0.0), @(0.0), @(0.0), nil];
                    bins[@(key)] = b;
                }
                b[0] = @(b[0].doubleValue + 1);
                b[1] = @(b[1].doubleValue + c.redComponent);
                b[2] = @(b[2].doubleValue + c.greenComponent);
                b[3] = @(b[3].doubleValue + c.blueComponent);
                double mx = fmax(c.redComponent, fmax(c.greenComponent, c.blueComponent));
                double mn = fmin(c.redComponent, fmin(c.greenComponent, c.blueComponent));
                double score = (mx > 0 ? (mx - mn) / mx : 0) * (mx > 0.25 && mx < 0.92 ? 1.0 : 0.35);
                if (score > bestSatScore) { bestSatScore = score; bestSat = c; }
                double l = Luminance(c);
                lumSum += l;
                if (l < 0.12) darkShare += 1;
                if (l > 0.55) lightShare += 1;
            }
        }

        double total = whole.n ?: 1;
        printf("\n整张壁纸\n");
        PrintColor("平均色", Mean(whole));
        printf("  平均亮度 %.3f   暗区 %.0f%%   亮区 %.0f%%\n",
               lumSum / total, darkShare / total * 100, lightShare / total * 100);

        printf("\n主色板（3bit/通道分箱，占比最高的 8 箱）\n");
        NSArray<NSArray<NSNumber *> *> *sorted =
            [bins.allValues sortedArrayUsingComparator:^NSComparisonResult(NSArray<NSNumber *> *x,
                                                                           NSArray<NSNumber *> *y) {
                return [y[0] doubleValue] < [x[0] doubleValue] ? NSOrderedAscending : NSOrderedDescending;
            }];
        for (NSUInteger i = 0; i < sorted.count && i < 8; i++) {
            NSArray<NSNumber *> *b = sorted[i];
            char tag[48];
            snprintf(tag, sizeof tag, "色板 %ld  %.0f%%", (long)(i + 1), b[0].doubleValue / total * 100);
            PrintColor(tag, [NSColor colorWithRed:b[1].doubleValue / b[0].doubleValue
                                            green:b[2].doubleValue / b[0].doubleValue
                                             blue:b[3].doubleValue / b[0].doubleValue alpha:1]);
        }
        if (bestSat) PrintColor("最饱和的点缀色", bestSat);

        // 默认位置：卡片会盖住哪块，就把那块"有多花"量出来，越安静越适合放
        printf("\n四角选址扫描（卡片 %.0fx%.0f，边距 %.0f）\n", cardW, cardH, margin);
        printf("  %-6s %-8s %-8s %-8s %-8s %s\n", "角落", "亮度", "标准差", "边缘能量", "安静度", "平均色");
        RegionStats best = {0};
        NSInteger bestCorner = -1;
        double bestScore = 1e9;
        for (NSInteger corner = 0; corner < 4; corner++) {
            NSRect vis = NSMakeRect(cutX, cutY, screenW - 2 * cutX, screenH - 2 * cutY);  // 近似去掉菜单栏影响
            double x = (corner == 1 || corner == 3) ? NSMaxX(vis) - cardW - margin : vis.origin.x + margin;
            double y = (corner >= 2) ? NSMaxY(vis) - cardH - margin : vis.origin.y + margin;
            RegionStats r = ScanRegion(rep, NSMakeRect(x, y, cardW, cardH), cutX, cutY, screenW, screenH, 4.0);
            double score = r.stdev + r.edge * 3.0;   // 底纹起伏与细节一起算，细节权重更高
            char hex[16];
            NSColor *avg = Mean(r.avg);
            snprintf(hex, sizeof hex, "#%02X%02X%02X", (int)lround(avg.redComponent * 255),
                     (int)lround(avg.greenComponent * 255), (int)lround(avg.blueComponent * 255));
            printf("  %-6s %-8.3f %-8.3f %-8.3f %-8.3f %s\n", CornerName(corner).UTF8String,
                   r.lum, r.stdev, r.edge, score, hex);
            if (score < bestScore) { bestScore = score; bestCorner = corner; best = r; }
        }
        printf("  → 最安静的角落：%s（安静度 %.3f，亮度 %.3f）\n",
               CornerName(bestCorner).UTF8String, bestScore, best.lum);

        // 卡片要"站"进画面，就得跟它所在位置的那块画面的边框朝向一致 —— 所以只量局部
        printf("\n局部边缘朝向（卡片压在 %s 角那块上的边框方向，前 5 名）\n", CornerName(bestCorner).UTF8String);
        {
            NSInteger bc = bestCorner;
            NSRect vis = NSMakeRect(cutX, cutY, screenW - 2 * cutX, screenH - 2 * cutY);
            double x0 = (bc == 1 || bc == 3) ? NSMaxX(vis) - cardW - margin : vis.origin.x + margin;
            double y0 = (bc >= 2) ? NSMaxY(vis) - cardH - margin : vis.origin.y + margin;
            NSRect zone = NSMakeRect(x0, y0, cardW, cardH);

            const NSInteger cols = 200, rows = 280;
            double *gray = calloc((size_t)cols * rows, sizeof(double));
            for (NSInteger j = 0; j < rows; j++) {
                for (NSInteger i = 0; i < cols; i++) {
                    double sx = zone.origin.x + (i + 0.5) / cols * zone.size.width;
                    double sy = zone.origin.y + (j + 0.5) / rows * zone.size.height;
                    NSColor *raw = [rep colorAtX:(NSInteger)ScreenToImageX(sx, cutX, screenW, imgW)
                                               y:(NSInteger)ScreenToImageY(sy, cutY, screenH, imgH)];
                    gray[(size_t)j * cols + i] = raw ? Luminance(raw) : 0;
                }
            }
            double hist[180] = {0}, totalMag = 0;
            for (NSInteger j = 1; j < rows - 1; j++) {
                for (NSInteger i = 1; i < cols - 1; i++) {
                    double gx = (gray[(size_t)j * cols + i + 1] - gray[(size_t)j * cols + i - 1]) * 0.5;
                    double gy = -(gray[(size_t)(j + 1) * cols + i] - gray[(size_t)(j - 1) * cols + i]) * 0.5;
                    double mag = hypot(gx, gy);
                    if (mag < 0.015) continue;
                    double ang = atan2(gy, gx) * 180.0 / M_PI + 90.0;
                    while (ang < 0) ang += 180.0;
                    while (ang >= 180.0) ang -= 180.0;
                    hist[(NSInteger)ang] += mag;
                    totalMag += mag;
                }
            }
            free(gray);
            // 平滑一下（手绘风边缘抖），再取前 5 个峰
            double sm[180];
            for (int a = 0; a < 180; a++) {
                sm[a] = (hist[(a + 179) % 180] + hist[a] * 2 + hist[(a + 1) % 180]) / 4.0;
            }
            for (int k = 0; k < 5; k++) {
                int best = 0;
                for (int a = 1; a < 180; a++) if (sm[a] > sm[best]) best = a;
                double dev = best > 90 ? best - 180 : best;      // 相对水平的带符号角
                printf("  第 %d 名：%+.1f°（水平系）/ %.1f°（垂直系），占边缘能量 %.1f%%\n", k + 1,
                       dev, best - 90.0, totalMag > 0 ? sm[best] / totalMag * 100 : 0);
                for (int a = MAX(0, best - 6); a <= MIN(179, best + 6); a++) sm[a] = 0;
            }
        }

        printf("\n文字对比度候选（对最安静角落的平均亮度，WCAG 4.5:1 才算稳）\n");        struct { const char *name; double v; } cands[] = {
            {"近白 0.96", 0.96}, {"纯白 1.00", 1.00}, {"近黑 0.08", 0.08}, {"中灰 0.55", 0.55},
        };
        for (int i = 0; i < 4; i++) {
            double l = Luminance([NSColor colorWithSRGBRed:cands[i].v green:cands[i].v blue:cands[i].v alpha:1]);
            double ratio = Contrast(l, best.lum);
            printf("  %-12s 对比度 %.2f:1  %s\n", cands[i].name, ratio, ratio >= 4.5 ? "够" : "不够");
        }
        return 0;
    }
}
