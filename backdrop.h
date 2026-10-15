// 卡片背景：直接从桌面壁纸上把卡片背后那块裁出来、模糊、提饱和，再画进圆角里。
// 桌面层窗口拿不到 WindowServer 的 backdrop，所以毛玻璃材质只会退化成一块深色板，
// 自己采样才能保证卡片里透出的是你桌面那个位置的实景。
#import <AppKit/AppKit.h>

@interface DeskBackdrop : NSObject
+ (instancetype)shared;
- (NSString *)wallpaperPath;   // 从系统壁纸配置里解析，nil 表示拿不到
// rect 用屏幕坐标（左下原点）。位置变化不大时复用缓存，避免拖拽时每帧重算。
- (NSImage *)imageForRect:(NSRect)rect dark:(BOOL)dark;
- (void)invalidate;
@end
