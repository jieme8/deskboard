// 极大空矩形（放大落点用）的回归测试。
//
// 先说清楚这个文件现在是什么：它**不在 build.sh --check 里，也不测产品代码**。
// 产品里没有这个算法 —— 「放大落到最大空地」这条路已经实测否掉了
// （40 次采样，0 次能找到能放下 1.5 倍的空地），所以算法没有进 vault_view.m。
// 这里留的是它的一份独立副本加测试，当作「如果哪天要复活这条路，别再踩同一个坑」的存档。
//
// 留着的理由：第一版算法按 y 坐标走空隙，丢掉了「哪两个坐标属于同一个窗口」的配对，
// 于是 (0,0,500,800) 这种占满的窗口会把它自己占的那段算成空地 ——
// 报出来的「最大空地 1346×603、12/12 有地方」全是这个 bug 撑起来的。
// 下面第 2/3/7 条就是钉这个的。改成按区间合并之后才对。
//
// 真要复活这条路时：把算法搬进 vault_view.m，本文件改成链接那份（像 verify_thumb
// 链接 vault_art.m 那样），再接进 build_tools。否则它守的是副本，不是产品。
#import <AppKit/AppKit.h>

static int gPass = 0, gFail = 0;
static void Check(BOOL ok, NSString *what) {
    printf("%s %s\n", ok ? "✓" : "✗", what.UTF8String);
    if (ok) gPass++; else gFail++;
}

static NSInteger CmpByMinY(id a, id b, void *ctx) {
    (void)ctx;
    CGFloat d = NSMinY(((NSValue *)a).rectValue) - NSMinY(((NSValue *)b).rectValue);
    return d < 0 ? -1 : (d > 0 ? 1 : 0);
}

static NSRect LargestFreeRect(NSRect vis, NSArray<NSValue *> *blocks) {
    NSMutableSet *xs = [NSMutableSet set];
    [xs addObject:@(NSMinX(vis))]; [xs addObject:@(NSMaxX(vis))];
    for (NSValue *v in blocks) {
        NSRect r = NSIntersectionRect(v.rectValue, vis);
        if (NSWidth(r) <= 0 || NSHeight(r) <= 0) continue;
        [xs addObject:@(NSMinX(r))]; [xs addObject:@(NSMaxX(r))];
    }
    NSArray *xsA = [[xs allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSRect best = NSZeroRect; double bestArea = 0;
    for (NSUInteger i = 0; i < xsA.count; i++)
        for (NSUInteger j = i + 1; j < xsA.count; j++) {
            CGFloat x0 = MAX([xsA[i] doubleValue], NSMinX(vis));
            CGFloat x1 = MIN([xsA[j] doubleValue], NSMaxX(vis));
            if (x1 - x0 < 1.0) continue;
            // 这条竖带里被占的纵向区间。注意要按"区间"收集再合并：
            // 只收集 y 坐标会丢掉配对，(0,0,500,800) 会被当成"y=0 到 y=800 之间是空的"，
            // 把整块占用的区域算成空地 —— 这个 bug 出过一次，测试就是为了钉死它。
            NSMutableArray<NSValue *> *iv = [NSMutableArray array];
            for (NSValue *v in blocks) {
                NSRect r = NSIntersectionRect(v.rectValue, vis);
                if (NSWidth(r) <= 0 || NSHeight(r) <= 0) continue;
                if (NSMaxX(r) <= x0 || NSMinX(r) >= x1) continue;
                [iv addObject:[NSValue valueWithRect:NSMakeRect(0, NSMinY(r), 1, NSHeight(r))]];
            }
            NSArray *ivA = [iv sortedArrayUsingFunction:CmpByMinY context:NULL];
            CGFloat cur = NSMinY(vis);
            for (NSUInteger k = 0; k < ivA.count; k++) {
                NSValue *ivv = ivA[k];
                CGFloat a = NSMinY(ivv.rectValue), b = NSMaxY(ivv.rectValue);
                if (a - cur > 1.0) {          // 到这个区间之前是空的
                    double area = (x1 - x0) * (a - cur);
                    if (area > bestArea) { bestArea = area; best = NSMakeRect(x0, cur, x1 - x0, a - cur); }
                }
                if (b > cur) cur = b;          // 合并：跨过就推进，不后退
            }
            if (NSMaxY(vis) - cur > 1.0) {
                double area = (x1 - x0) * (NSMaxY(vis) - cur);
                if (area > bestArea) { bestArea = area; best = NSMakeRect(x0, cur, x1 - x0, NSMaxY(vis) - cur); }
            }
        }
    return best;
}

static NSArray *B(NSRect *rs, int n) {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < n; i++) [a addObject:[NSValue valueWithRect:rs[i]]];
    return a;
}
static BOOL NearEq(double a, double b) { return fabs(a - b) < 0.51; }

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSRect V = NSMakeRect(0, 0, 1000, 800);

    // 1. 没有窗口 → 整块可视区都是空地
    {
        NSRect f = LargestFreeRect(V, @[]);
        Check(NearEq(NSWidth(f), 1000) && NearEq(NSHeight(f), 800),
              @"没有窗口时，空地就是整块可视区 1000x800");
    }
    // 2. 左边一半被占 → 右边一半是空地
    {
        NSRect w = NSMakeRect(0, 0, 500, 800);
        NSRect f = LargestFreeRect(V, B(&w, 1));
        Check(NearEq(NSMinX(f), 500) && NearEq(NSWidth(f), 500) && NearEq(NSHeight(f), 800),
              [NSString stringWithFormat:@"左半被占时，空地是右半 x=%.0f 宽%.0f", NSMinX(f), NSWidth(f)]);
    }
    // 3. 上下各占一半 → 中间那条横带是空地
    {
        NSRect a = NSMakeRect(0, 0, 1000, 300), b = NSMakeRect(0, 500, 1000, 300);
        NSRect rs[2] = {a, b};
        NSRect f = LargestFreeRect(V, B(rs, 2));
        Check(NearEq(NSMinY(f), 300) && NearEq(NSHeight(f), 200),
              [NSString stringWithFormat:@"上下被占时，空地是中间那条 y=%.0f 高%.0f", NSMinY(f), NSHeight(f)]);
    }
    // 4. 屏幕外的窗口不能撑出假空地（就是那个 30000pt 的坑）
    {
        NSRect far = NSMakeRect(28000, 0, 2000, 800);
        NSRect w = NSMakeRect(0, 0, 500, 800);
        NSRect rs[2] = {far, w};
        NSRect f = LargestFreeRect(V, B(rs, 2));
        Check(NSWidth(f) <= 1000.5 && NSMinX(f) >= -0.5,
              [NSString stringWithFormat:@"屏幕外的窗口不会撑出越界空地（实得 x=%.0f 宽%.0f）",
               NSMinX(f), NSWidth(f)]);
    }
    // 5. 完全被占满 → 没有空地
    {
        NSRect w = NSMakeRect(0, 0, 1000, 800);
        NSRect f = LargestFreeRect(V, B(&w, 1));
        Check(NSWidth(f) <= 0.5 || NSHeight(f) <= 0.5,
              @"整屏被占满时，算不出空地（调用方据此退回 1.0 倍）");
    }
    // 6. 结果永远不能超出可视区
    {
        NSMutableArray *bs = [NSMutableArray array];
        for (int i = 0; i < 12; i++) {
            NSRect r = NSMakeRect(-400 + i * 160, -300 + i * 120, 700, 500);
            [bs addObject:[NSValue valueWithRect:r]];
        }
        NSRect f = LargestFreeRect(V, bs);
        BOOL inside = NSMinX(f) >= -0.5 && NSMinY(f) >= -0.5
                   && NSMaxX(f) <= 1000.5 && NSMaxY(f) <= 800.5;
        Check(inside, [NSString stringWithFormat:@"乱序/越界窗口下结果仍完全落在可视区内（%.0f,%.0f %.0fx%.0f）",
               NSMinX(f), NSMinY(f), NSWidth(f), NSHeight(f)]);
    }
    // 7. 找出的空地必须真的没被任何窗口压到
    {
        NSRect a = NSMakeRect(100, 100, 300, 200);
        NSRect b = NSMakeRect(600, 50, 300, 700);
        NSRect rs[2] = {a, b};
        NSRect f = LargestFreeRect(V, B(rs, 2));
        double bad = 0;
        for (NSValue *v in B(rs, 2)) {
            NSRect i = NSIntersectionRect(f, v.rectValue);
            if (i.size.width > 0 && i.size.height > 0) bad += i.size.width * i.size.height;
        }
        Check(bad <= 0.5, [NSString stringWithFormat:@"算出的空地与所有窗口零交叠（交叠 %.1f pt²）", bad]);
    }

    printf("\n空矩形算法：%d 项通过，%d 项失败\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
} }
