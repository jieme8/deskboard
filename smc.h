// AppleSMC 用户客户端读取：风扇转速与温度只在这里能拿到。
// 探针工具和 App 共用同一份，避免"探针能读到、App 读不到"这种口径分裂。
#import <Foundation/Foundation.h>

@interface DeskSMC : NSObject
@property (nonatomic, readonly) BOOL available;
- (BOOL)open;
- (void)close;
- (NSArray<NSString *> *)allKeys;
- (NSNumber *)numberForKey:(NSString *)key;   // 自动解码 flt / sp78 / ui8 / ui16 / ui32
- (NSString *)typeForKey:(NSString *)key;
- (NSUInteger)sizeForKey:(NSString *)key;
@end
