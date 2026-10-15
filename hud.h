// 卡片之外的坐标胶囊：实时读数 + 「保存」按钮。
// 读数不属于组件本身，所以它是独立窗口，不参与变形投影，也不会被斜切。
#import <AppKit/AppKit.h>

@interface DeskHudView : NSView
@property (nonatomic, copy) NSString *readout;   // 例：372,77 · 480×121 · 屏 1512×945
@property (nonatomic, copy) NSString *status;    // 例：未保存 / 已保存 13:20
@property (nonatomic, assign) BOOL dirty;        // 有未保存的拖动
@property (nonatomic, copy) void (^onSave)(void);
+ (NSSize)sizeForReadout:(NSString *)readout status:(NSString *)status;
@end
