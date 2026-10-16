// DeskBoard 数据模型：把外部 JSON 归一化成界面可直接铺的行。
#import <Foundation/Foundation.h>

@class DeskStats;
@interface DeskStatRow : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, assign) double fraction;   // <0 表示这一行不画进度条
- (instancetype)initWithLabel:(NSString *)label value:(NSString *)value fraction:(double)fraction;
@end

@interface DeskModel : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *price;
@property (nonatomic, copy) NSString *unit;
@property (nonatomic, copy) NSString *infoLine;   // 油价区只留一行说明，紧凑
@property (nonatomic, copy) NSString *trendText;  // 涨跌标记，例：▲0.32；接口没给涨跌数据时为空
@property (nonatomic, assign) BOOL trendUp;       // 涨红跌绿，决定 trendText 用哪个颜色
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, copy) NSString *loadError;   // nil 表示数据可用
@property (nonatomic, copy) NSString *statsHeader;
@property (nonatomic, copy) NSArray<DeskStatRow *> *statRows;
@property (nonatomic, strong) DeskStats *stats;
+ (instancetype)modelFromDictionary:(NSDictionary *)dict;
+ (instancetype)modelFromJSONFileAtPath:(NSString *)path;
+ (instancetype)placeholderModel;
- (void)updateStats:(DeskStats *)stats;
+ (NSArray<DeskStatRow *> *)statRowsForStats:(DeskStats *)stats;
@end
