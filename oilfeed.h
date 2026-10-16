// 油价实时抓取。东方财富数据中心是唯一的真实来源。
//
// 它写出的 JSON 和 mock.json 完全同形状，所以卡片面板这条链
// （model.m 解析 → panel_view.m 绘制）一行都不用改：写回缓存文件之后，
// main.m 里那套 2 秒 mtime 轮询自己会认到这次写入并重画。
// 换句话说，这个文件只负责"把真数写进磁盘"，不碰界面。
//
// 失败策略是"什么都不做"：断网、接口改版、被限流时都不写盘，
// 磁盘上那份旧缓存继续留着，卡片照旧显示上一次真拿到的价，不会空窗。
#import <Foundation/Foundation.h>

@interface DeskOilFeed : NSObject

/// 启动抓取：立刻拉一次，之后每 30 分钟一次。cachePath 就是卡片面板读的那个
/// mock.json 路径，重复调用只会启动一次。
+ (void)startWithCachePath:(NSString *)cachePath;

@end
