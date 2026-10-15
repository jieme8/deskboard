// 找壁纸里那扇"窗"：HUD 要贴在窗玻璃上，得先量出玻璃在屏幕坐标里的位置，别靠目测。
// 判据：窗玻璃是画面里最亮、最偏蓝的那片连续区域（城市夜景散景），房间和显示器都更暗。
// 用法：find_region <图片> <屏幕宽> <屏幕高> <卡片宽> <卡片高>
#import <AppKit/AppKit.h>

static double Luma(NSColor *c) {
    NSColor *s = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    double f[3] = {s.redComponent, s.greenComponent, s.blueComponent}, lin[3];
    for (int i = 0; i < 3; i++) lin[i] = f[i] <= 0.03928 ? f[i] / 12.92 : pow((f[i] + 0.055) / 1.055, 2.4);
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 6) { fprintf(stderr, "用法：find_region <图片> <屏幕宽> <屏幕高> <卡片宽> <卡片高>\n"); return 2; }
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithData:[NSData dataWithContentsOfFile:@(argv[1])]];
        if (!rep) { fprintf(stderr, "读不到图片\n"); return 1; }
        double screenW = atof(argv[2]), screenH = atof(argv[3]);
        double cardW = atof(argv[4]), cardH = atof(argv[5]);
        double imgW = rep.pixelsWide, imgH = rep.pixelsHigh;
        double scale = fmax(screenW / imgW, screenH / imgH);
        double cutX = (imgW * scale - screenW) / 2.0 / scale, cutY = (imgH * scale - screenH) / 2.0 / scale;

        const int cols = 44, rows = 22;
        double *score = calloc(cols * rows, sizeof(double));
        printf("亮度/蓝度分布图（. 暗  o 中  O 亮蓝窗玻璃  # 过曝）\n");
        for (int j = 0; j < rows; j++) {
            char line[512]; int p = 0;
            for (int i = 0; i < cols; i++) {
                double sx = cutX + (i + 0.5) / cols * screenW;
                double sy = cutY + (j + 0.5) / rows * screenH;
                NSColor *raw = [rep colorAtX:(NSInteger)((sx - cutX) / screenW * imgW)
                                          y:(NSInteger)((sy - cutY) / screenH * imgH)];
                NSColor *c = [raw colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
                double l = Luma(c);
                double blue = c.blueComponent - (c.redComponent + c.greenComponent) / 2.0;
                // 窗玻璃：够亮 + 明显偏蓝；房间暗、显示器黑屏蓝度也低
                score[j * cols + i] = (l > 0.035 && l < 0.45 && blue > 0.10) ? l + blue : 0;
                const char *glyph = l > 0.30 ? "#" : (l > 0.035 && blue > 0.10 ? "O" : (l > 0.02 ? "o" : "."));
                p += snprintf(line + p, sizeof(line) - p, "%s", glyph);
            }
            printf("  %s\n", line);
        }

        // 在评分图上滑窗找能容纳卡片的最佳位置（按屏幕点换算，网格是等分的）
        double cellW = screenW / cols, cellH = screenH / rows;
        int needW = (int)ceil(cardW / cellW), needH = (int)ceil(cardH / cellH);
        int bestI = 0, bestJ = 0; double best = -1;
        for (int j = 0; j + needH <= rows; j++) {
            for (int i = 0; i + needW <= cols; i++) {
                double sum = 0; int zero = 0;
                for (int dj = 0; dj < needH; dj++) {
                    for (int di = 0; di < needW; di++) {
                        double v = score[(j + dj) * cols + i + di];
                        sum += v; if (v == 0) zero++;
                    }
                }
                // 覆盖率优先：整块都落在玻璃上才给高分
                double s = sum / (needW * needH) * (1.0 - zero / (double)(needW * needH));
                if (s > best) { best = s; bestI = i; bestJ = j; }
            }
        }
        double x = bestI * cellW, y = bestJ * cellH;
        printf("\n最佳窗玻璃位置（CG 坐标，左上原点）：(%.0f, %.0f) 放 %.0fx%.0f 卡片，得分 %.4f\n",
               x, y, cardW, cardH, best);
        printf("换算成 AppKit 屏幕坐标（左下原点）：y = %.0f\n", screenH - y - cardH);
        // 在这块玻璃上做边缘朝向直方图：窗框线的倾角就是 HUD 该"歪"多少
        {
            NSRect zone = NSMakeRect(x, y, cardW, cardH);
            const int gc = 100, gr = 150;
            double *g = calloc((size_t)gc * gr, sizeof(double));
            for (int j = 0; j < gr; j++) {
                for (int i = 0; i < gc; i++) {
                    double sx = zone.origin.x + (i + 0.5) / gc * zone.size.width;
                    double sy = zone.origin.y + (j + 0.5) / gr * zone.size.height;
                    NSColor *raw = [rep colorAtX:(NSInteger)((sx - cutX) / screenW * imgW)
                                              y:(NSInteger)((sy - cutY) / screenH * imgH)];
                    g[(size_t)j * gc + i] = raw ? Luma(raw) : 0;
                }
            }
            double hist[180] = {0}, tot = 0;
            for (int j = 1; j < gr - 1; j++) {
                for (int i = 1; i < gc - 1; i++) {
                    double gx = (g[(size_t)j * gc + i + 1] - g[(size_t)j * gc + i - 1]) * 0.5;
                    double gy = -(g[(size_t)(j + 1) * gc + i] - g[(size_t)(j - 1) * gc + i]) * 0.5;
                    double mag = hypot(gx, gy);
                    if (mag < 0.012) continue;
                    double a = atan2(gy, gx) * 180.0 / M_PI + 90.0;
                    while (a < 0) a += 180.0;
                    while (a >= 180.0) a -= 180.0;
                    hist[(int)a] += mag; tot += mag;
                }
            }
            free(g);
            printf("\n窗玻璃里的边缘朝向（前 6 名，角度=相对水平，正为向右上斜）\n");
            for (int k = 0; k < 6; k++) {
                int b = 0;
                for (int a = 1; a < 180; a++) if (hist[a] > hist[b]) b = a;
                double dev = b > 90 ? b - 180 : b;
                printf("  %+6.1f°  占 %.1f%%%s\n", dev, tot > 0 ? hist[b] / tot * 100 : 0,
                       fabs(dev) < 25 ? @"  ← 近水平（窗框横边）".UTF8String : @"  ← 近垂直（窗框竖边）".UTF8String);
                for (int a = MAX(0, b - 5); a <= MIN(179, b + 5); a++) hist[a] = 0;
            }
        }
        printf("建议配置：贴 %s 半区，dx=%.0f dy=%.0f\n",
               x + cardW / 2 < screenW / 2 ? "左" : "右",
               x + cardW / 2 < screenW / 2 ? x : screenW - (x + cardW),
               y + cardH / 2 < screenH / 2 ? y : screenH - (y + cardH));
        free(score);
        return 0;
    }
}
