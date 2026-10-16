// 弹药库的美术层：底图处理和几个反复用到的小图形都放这里，
// 视图层只管摆位置和管交互，不重复画同一套东西。
#import <AppKit/AppKit.h>
#import "panel_view.h"
#import "vault.h"

NS_ASSUME_NONNULL_BEGIN

// 配色只认青色一套，不分深浅色：底图本身就是夜里那间蓝光房，
// 亮度和对比全靠底图压暗 + 文字外发光来保证可读。
extern NSColor *VaultCyan(void);
extern NSColor *VaultCyanBright(void);
extern NSColor *VaultInk(void);
extern NSColor *VaultPaper(void);
extern NSColor *VaultMuted(void);
extern NSColor *VaultWarn(void);

// 四档外观和卡片面板完全同名同序，这样菜单文案、默认值、用户心智都能对齐。
// 底板也分四档：wallpaper 是"组件背后那块真实桌面"的采样图（视图层负责取）。
// sweep 取 0~1，是扫描带在 rect 里的相对位置；传负数表示这条不画。
void VaultDrawPlatePlate(NSRect rect, NSImage *_Nullable wallpaper, double sweep, double hot);
void VaultDrawPlateFeather(NSRect rect);
// Bare 什么都不画，由视图直接跳过

// 卡片玻璃底在四档下的不透明度：实底卡压得实，无底那两档几乎全透
double VaultCardFillAlpha(DeskStyle style, double hoverK, double selK);

// 四角准星括号，一眼就能看出这是个"瞄准框里的界面"
void VaultDrawReticle(NSRect rect, CGFloat inset, CGFloat len, NSColor *color,
                      CGFloat alpha, CGFloat lineWidth);
// 20×17 的文件夹：带背板和内容线，像一张立在架子上的卡片
void VaultDrawFolderGlyph(NSRect rect, NSColor *tint, double seed);
// 按分类画库位图形：七种格式各画各的剪影，不画统一外框，
// 让人一眼扫过去就知道这一格装的是什么，不用去看名字
void VaultDrawItemGlyph(NSRect rect, NSColor *tint, double seed, VaultItemKind kind);

// —— 图片卡片的真实缩略图 ——
// 图形位换成文件里那张图，不用看名字就知道是什么。取得到就画真图，
// 取不到（还没解码完 / 解码失败 / 不是能解码的格式）返回 nil，调用方回退剪影图形。
// 组件 60fps 重绘，所以这里只读缓存，绝不在绘制路径上解码。
NSImage *_Nullable VaultThumbnail(NSString *_Nullable path);
// 异步预热一批路径。库里换过内容后调它，绘制路径不用等解码
void VaultThumbPrefetch(NSArray<NSString *> *_Nullable paths);
// 解码失败会记下来不再重试，所以文件被替换成正常图片后要显式清一次
void VaultThumbForget(NSString *_Nullable path);
// 只保留清单上的路径。退回桌面、全退之后调它，缓存里的位图才不会只进不出
void VaultThumbPruneTo(NSArray<NSString *> *_Nullable keepPaths);
void VaultThumbInvalidateAll(void);
// 解码一张图，maxPx 是长边上限。单独暴露给离线校验工具量耗时用
NSImage *_Nullable VaultThumbDecode(NSString *path, CGFloat maxPx);
// 把缩略图画进 rect：aspect > 2.5 的长条图走 contain，其余铺满裁切。
// 长条图铺满只会裁到中间一片空白，反而什么都不剩，退回 contain 至少形状还看得见。
void VaultDrawThumbnailIn(NSRect rect, NSImage *thumb, NSColor *tint);

// —— 悬停预览用的第二级缩略图 ——
// 卡片图形位只有 26×22pt，160px 够用；预览要铺到小 400pt 宽，直接拉伸 160px 会糊。
// 所以另开一套：更大的解码上限、更少的上限张数、独立的淘汰策略，互不影响。
NSImage *_Nullable VaultThumbPreview(NSString *_Nullable path);   // 只读缓存，未就绪返回 nil
void VaultThumbPreviewPrefetch(NSString *_Nullable path);         // 异步解一张
void VaultThumbPreviewPruneTo(NSArray<NSString *> *_Nullable keepPaths);
void VaultThumbPreviewInvalidateAll(void);
// 预览按整幅 contain 画（不像卡片图形位那样对常规图 cover）：
// 预览的用途是"看清这是什么"，裁切会把边缘信息丢掉。
void VaultDrawThumbPreviewIn(NSRect rect, NSImage *thumb, NSColor *tint);
// 该格式在卡面上的专属色相（图形、电平条、进度条、规格牌都取它）
NSColor *VaultTintForKind(VaultItemKind kind);
// meta 行右端的扩展名规格牌（文件卡片才画）
void VaultDrawExtChip(NSRect rect, NSString *ext, NSColor *tint);
// 容量环：fraction 0~1，空的部分留一段缺口
void VaultDrawRing(NSRect rect, double fraction, NSColor *track, NSColor *fill,
                   NSColor *label, NSString *labelText, NSFont *labelFont);

// 操作坞按钮上的四个小图标，统一 14×14 的画布
typedef NS_ENUM(NSInteger, VaultDockIcon) {
    VaultDockIconScan = 0,   // 雷达扫描
    VaultDockIconOpen,       // 打开库目录
    VaultDockIconEject,      // 全部退回
    VaultDockIconHide,       // 收起组件
};

void VaultDrawDockIcon(VaultDockIcon icon, NSRect rect, NSColor *color, CGFloat lineWidth);

NS_ASSUME_NONNULL_END
