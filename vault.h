// 弹药库数据层：一个被"入库"的桌面文件夹 = 一条记录 + 库里一份真实文件。
// 组件只读这里，不直接碰文件系统细节；入库/退库都走 DeskVault，失败不写记录。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const kVaultChangedNotification;   // 清单增删后广播，视图据此重排

// 库位上的东西按什么分类。卡片画哪个图形、统计怎么算、meta 行怎么写，都看这个字段。
typedef NS_ENUM(NSInteger, VaultItemKind) {
    VaultItemFolder = 0,   // 文件夹
    VaultItemVideo,        // 视频
    VaultItemAudio,        // 音频
    VaultItemImage,        // 图片
    VaultItemDocument,     // 文档
    VaultItemArchive,      // 压缩包 / 磁盘镜像
    VaultItemCode,         // 代码 / 纯文本
    VaultItemKindNone = -1 // 不收
};

// 分类名，给卡片上的 meta 行用
extern NSString *VaultKindLabel(VaultItemKind kind);

// 这条路径能不能入库。能收就返回分类，不能收返回 VaultItemKindNone。
// 判定分三步，顺序有讲究：
//   1. 隐藏文件、符号链接、Finder 别名、设备文件 —— 一律拒；
//   2. 目录：只有普通文件夹放行，.app / .bundle / .framework 这类"看着像文件、
//      其实是目录"的包要拒，搬走等于破坏应用；
//   3. 普通文件：按后缀白名单认分类。
// 白名单不是黑名单：没在表里的后缀宁可拒掉也不冒险。以后想多收一种格式，
// 往表里加一行就行，别的代码一行都不用动。
extern VaultItemKind VaultItemKindForPath(NSString *path);

@interface DeskVaultItem : NSObject
@property (nonatomic, copy)   NSString *name;        // 卡片上显示的名字
@property (nonatomic, copy)   NSString *sourceName;  // 从桌面拖进来时的原名，退库时还原
@property (nonatomic, copy)   NSString *storedName;  // 库里真实的目录名（重名时加过序号）
@property (nonatomic, assign) double   seed;         // 0~1 稳定随机数，决定卡片配色和波形相位
@property (nonatomic, assign) long long ingestedAt;
@property (nonatomic, assign) VaultItemKind kind;    // 老清单没这个字段，按文件夹处理
@property (atomic, assign)    long long byteSize;
@property (atomic, assign)    NSUInteger fileCount;
@property (atomic, assign)    BOOL     scanned;      // 统计跑完了才为真，未完成时卡片显示占位

- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)itemWithDictionary:(NSDictionary *)d;

@end

NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN

@interface DeskVault : NSObject
+ (instancetype)shared;

@property (nonatomic, readonly, copy) NSArray<DeskVaultItem *> *items;
@property (nonatomic, readonly, copy) NSString *rootPath;      // 库的真实目录
@property (nonatomic, readonly) unsigned long long totalBytes;
@property (nonatomic, readonly) NSUInteger pendingCount;       // 还没统计完的条目数

// 入库：把外部目录搬进库里并登记。返回真正收下的文件夹数，只收目录不收文件。
// 单个文件夹失败不影响其它，最后统一对账（记录只在文件真的落地后才写）。
- (NSUInteger)ingestPaths:(NSArray<NSString *> *)paths;
- (BOOL)ejectItem:(DeskVaultItem *)item toDesktop:(BOOL)toDesktop;
- (NSUInteger)ingestDesktopItems;        // 一键把桌面上的文件夹和合规矩的文件全扫进来
- (NSUInteger)ejectAllToDesktop;

- (NSString *)pathForItem:(DeskVaultItem *)item;
// 拖出库外之后核账：文件确实不在库里了就把记录摘掉，还在那儿就当没动过
- (void)reconcileItem:(DeskVaultItem *)item;
// 目录树统计比较慢，放后台串行跑；同一代只认最后一次结果
- (void)refreshStats;
- (void)reloadFromDisk;
@end
NS_ASSUME_NONNULL_END

// 字节数 → "2.4 GB"，走 1024 进制，和系统设置里看到的一致
NS_ASSUME_NONNULL_BEGIN
extern NSString *VaultFormatBytes(unsigned long long bytes);
extern NSString *VaultFormatCount(NSUInteger n);
NS_ASSUME_NONNULL_END
