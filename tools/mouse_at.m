// 把真鼠标挪到屏幕坐标（点，Quartz 原点左上角）。
// 用来验证「悬停浮层跟着鼠标走」这类只有真光标才说得清的事：
// 合成事件进得了视图，但 [NSEvent mouseLocation] 读的是真光标的位置，
// 所以验证摆放位置必须动真光标。
// 用法：mouse_at <x> <y>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "用法：mouse_at <x> <y>\n"); return 1; }
        double x = atof(argv[1]), y = atof(argv[2]);
        CGEventRef e = CGEventCreate(NULL);
        CGEventSetType(e, kCGEventMouseMoved);
        CGEventSetLocation(e, CGPointMake(x, y));
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
        // 读回真实光标位置：挪完不等于挪到了（系统可能调整/未生效），
        // 拿它跟浮层窗口的 frame 对账才有意义
        CGEventRef cur = CGEventCreate(NULL);
        CGPoint p = CGEventGetLocation(cur);
        CFRelease(cur);
        printf("请求 (%.0f, %.0f) → 实际 (%.0f, %.0f)\n", x, y, p.x, p.y);
    }
    return 0;
}
