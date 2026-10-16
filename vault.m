#import "vault.h"
#import <sys/stat.h>

NSString *const kVaultChangedNotification = @"DeskVaultChanged";

#pragma mark - 收什么

// 后缀 → 分类。白名单，不是黑名单：第一期只收"搬走绝不会出事"的那些，
// 没在表里的宁可拒掉也不冒险。以后想多收一种格式，往这张表里加一行即可。
static NSDictionary<NSString *, NSNumber *> *VaultExtKinds(void) {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        NSArray *video = @[@"mp4", @"mov", @"m4v", @"avi", @"mkv", @"wmv", @"flv",
                           @"mpg", @"mpeg", @"webm", @"m2ts"];
        NSArray *audio = @[@"mp3", @"m4a", @"wav", @"aiff", @"aif", @"flac",
                           @"aac", @"ogg", @"caf"];
        NSArray *image = @[@"jpg", @"jpeg", @"png", @"gif", @"heic", @"heif",
                           @"webp", @"tiff", @"tif", @"bmp", @"svg", @"ico"];
        NSArray *doc   = @[@"pdf", @"txt", @"md", @"rtf", @"doc", @"docx", @"xls",
                           @"xlsx", @"ppt", @"pptx", @"pages", @"numbers", @"key",
                           @"epub", @"csv"];
        NSArray *arch  = @[@"zip", @"tar", @"gz", @"bz2", @"xz", @"7z", @"rar",
                           @"dmg", @"pkg"];
        NSArray *code  = @[@"js", @"ts", @"tsx", @"jsx", @"py", @"sh", @"c", @"h",
                           @"cpp", @"hpp", @"rs", @"go", @"java", @"rb", @"php",
                           @"html", @"css", @"scss", @"sql", @"json", @"xml",
                           @"yml", @"yaml", @"toml", @"lua", @"swift", @"m"];
        NSArray<NSArray *> *groups = @[video, audio, image, doc, arch, code];
        NSArray<NSNumber *> *kinds = @[@(VaultItemVideo), @(VaultItemAudio),
                                       @(VaultItemImage), @(VaultItemDocument),
                                       @(VaultItemArchive), @(VaultItemCode)];
        for (NSUInteger i = 0; i < groups.count; i++) {
            for (NSString *e in groups[i]) m[e] = kinds[i];
        }
        map = m;
    });
    return map;
}

// 看着像文件、其实是目录的东西：搬走等于破坏应用，一律拒
static BOOL VaultIsBundleExtension(NSString *ext) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"app", @"bundle", @"framework", @"pxcarchive",
                                    @"kext", @"plugin", @"appex", @"systemextension",
                                    @"xpc", @"lproj"]];
    });
    return [set containsObject:ext];
}

VaultItemKind VaultItemKindForPath(NSString *path) {
    if (!path.length) return VaultItemKindNone;
    NSString *p = [path stringByExpandingTildeInPath];
    // .DS_Store 这类隐藏文件：拖进来只会往库里掺系统垃圾
    if ([[p lastPathComponent] hasPrefix:@"."]) return VaultItemKindNone;
    struct stat st;
    // lstat 而不是 stat：要看的是"这一条路径本身"，stat 会跟着链接走
    if (lstat(p.fileSystemRepresentation, &st) != 0) return VaultItemKindNone;
    if (S_ISLNK(st.st_mode)) return VaultItemKindNone;
    // Finder 别名不是符号链接，是一个小文件。不查这一条的话它会被当文件夹收进来，
    // 卡片上显示成一个"假文件夹"，双击打开的是别名而不是真文件夹
    NSNumber *isAlias = nil;
    if ([[NSURL fileURLWithPath:p] getResourceValue:&isAlias
                                          forKey:NSURLIsAliasFileKey error:NULL]
        && isAlias.boolValue) return VaultItemKindNone;

    NSString *ext = [p pathExtension].lowercaseString;
    if (S_ISDIR(st.st_mode)) return VaultIsBundleExtension(ext) ? VaultItemKindNone : VaultItemFolder;
    if (!S_ISREG(st.st_mode)) return VaultItemKindNone;   // 设备 / 管道 / socket：搬不走
    NSNumber *k = VaultExtKinds()[ext];
    return k ? (VaultItemKind)k.integerValue : VaultItemKindNone;
}

NSString *VaultKindLabel(VaultItemKind kind) {
    switch (kind) {
        case VaultItemFolder:   return @"文件夹";
        case VaultItemVideo:    return @"视频";
        case VaultItemAudio:    return @"音频";
        case VaultItemImage:    return @"图片";
        case VaultItemDocument: return @"文档";
        case VaultItemArchive:  return @"压缩包";
        case VaultItemCode:     return @"代码";
        default:                return @"未知";
    }
}

#pragma mark - 格式化

NSString *VaultFormatBytes(unsigned long long bytes) {
    if (bytes == 0) return @"0 B";
    static NSArray<NSString *> *units;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ units = @[@"B", @"KB", @"MB", @"GB", @"TB", @"PB"]; });
    double v = (double)bytes;
    NSUInteger u = 0;
    while (v >= 1024.0 && u + 1 < units.count) { v /= 1024.0; u++; }
    // 1023.9 MB 该显示 1.0 GB 而不是 1024 MB，不然同一个东西在库里和访达里对不上
    if (u > 0 && v >= 999.95) { v /= 1024.0; u++; }
    return [NSString stringWithFormat:u ? @"%.1f %@" : @"%.0f %@", v, units[u]];
}

NSString *VaultFormatCount(NSUInteger n) {
    if (n < 10000) return [NSString stringWithFormat:@"%lu", (unsigned long)n];
    if (n < 100000000) return [NSString stringWithFormat:@"%.1f 万", n / 10000.0];
    return [NSString stringWithFormat:@"%.1f 亿", n / 100000000.0];
}

#pragma mark - 条目

@implementation DeskVaultItem

+ (instancetype)itemWithDictionary:(NSDictionary *)d {
    NSString *stored = d[@"stored"];
    if (![stored isKindOfClass:[NSString class]] || stored.length == 0) return nil;
    DeskVaultItem *it = [DeskVaultItem new];
    it.storedName = stored;
    NSString *name = d[@"name"];
    it.name = [name isKindOfClass:[NSString class]] && name.length ? name : stored;
    NSString *src = d[@"src"];
    it.sourceName = [src isKindOfClass:[NSString class]] && src.length ? src : it.name;
    double seed = [d[@"seed"] doubleValue];
    // seed 存丢就现编一个，保证每张卡片都有配色，不会全库一个色
    it.seed = seed > 0 ? seed : ((double)arc4random_uniform(10000) / 10000.0);
    it.ingestedAt = [d[@"at"] longLongValue];
    // 老清单里没有 kind（那时只收文件夹）：缺字段或越界都按文件夹算，
    // 这样老库不需要迁移，卡片照样画文件夹图形
    NSInteger k = [d[@"kind"] integerValue];
    it.kind = (k >= VaultItemFolder && k <= VaultItemCode) ? (VaultItemKind)k : VaultItemFolder;
    return it;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{@"name": self.name ?: @"",
             @"src": self.sourceName ?: @"",
             @"stored": self.storedName ?: @"",
             @"seed": @(self.seed),
             @"kind": @(self.kind),
             @"at": @(self.ingestedAt)};
}

@end

#pragma mark - 库

@implementation DeskVault {
    NSMutableArray<DeskVaultItem *> *_items;
    dispatch_queue_t _io;        // 所有搬文件/写盘都在这条串行队列上
    NSUInteger _scanGeneration;  // 统计结果可能乱序回来，靠它丢弃过期的那批
}

+ (instancetype)shared {
    static DeskVault *v;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ v = [DeskVault new]; });
    return v;
}

- (instancetype)init {
    if ((self = [super init])) {
        _items = [NSMutableArray array];
        _io = dispatch_queue_create("com.hujie.deskboard.vault", DISPATCH_QUEUE_SERIAL);
        [self reloadFromDisk];
    }
    return self;
}

- (NSString *)supportDir {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"DeskBoard"];
}

- (NSString *)rootPath { return [[self supportDir] stringByAppendingPathComponent:@"Vault"]; }

- (NSString *)listPath { return [[self supportDir] stringByAppendingPathComponent:@"vault.json"]; }

- (NSArray<DeskVaultItem *> *)items {
    @synchronized (self) { return [_items copy]; }
}

- (NSString *)pathForItem:(DeskVaultItem *)item {
    return [self.rootPath stringByAppendingPathComponent:item.storedName];
}

#pragma mark - 落盘

- (void)persist {
    NSArray *arr;
    @synchronized (self) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:_items.count];
        for (DeskVaultItem *it in _items) [a addObject:[it dictionaryRepresentation]];
        arr = a;
    }
    NSString *path = [self listPath];
    dispatch_async(_io, ^{
        NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"items": arr}
                                                   options:NSJSONWritingPrettyPrinted error:NULL];
        if (!d) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                 withIntermediateDirectories:YES attributes:nil error:NULL];
        // 原子替换：中途被杀也不会留下半个 JSON
        [d writeToFile:path options:NSDataWritingAtomic error:NULL];
    });
}

- (void)reloadFromDisk {
    NSData *d = [NSData dataWithContentsOfFile:[self listPath]];
    NSArray *arr = nil;
    if (d) {
        id root = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([root isKindOfClass:[NSDictionary class]]) arr = root[@"items"];
    }
    NSMutableArray *live = [NSMutableArray array];
    if ([arr isKindOfClass:[NSArray class]]) {
        NSFileManager *fm = [NSFileManager defaultManager];
        for (id raw in arr) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            DeskVaultItem *it = [DeskVaultItem itemWithDictionary:raw];
            if (!it) continue;
            // 清单和真实文件对不上的（用户在 Finder 里手动删了库目录）直接丢弃，别占位置
            if (![fm fileExistsAtPath:[self pathForItem:it]]) continue;
            [live addObject:it];
        }
    }
    BOOL dirty;
    @synchronized (self) {
        dirty = live.count != _items.count;
        _items = live;
    }
    if (dirty) [self persist];
    dispatch_async(_io, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:self.rootPath
                                 withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    [self refreshStats];
}

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:kVaultChangedNotification object:self];
}

#pragma mark - 入库

// 库里撞名就加序号，"素材 2"。返回真正可用的目录名
- (NSString *)uniqueStoredNameFor:(NSString *)name {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *candidate = name;
    for (int n = 2; n < 1000; n++) {
        if (![fm fileExistsAtPath:[self.rootPath stringByAppendingPathComponent:candidate]]) break;
        candidate = [NSString stringWithFormat:@"%@ %d", name, n];
    }
    return candidate;
}

- (NSUInteger)ingestPaths:(NSArray<NSString *> *)paths {
    if (!paths.count) return 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:self.rootPath withIntermediateDirectories:YES attributes:nil error:NULL];

    NSMutableArray *added = [NSMutableArray array];
    NSMutableArray<NSString *> *rejected = [NSMutableArray array];
    for (NSString *src in paths) {
        NSString *exp = [src stringByExpandingTildeInPath];
        // 别把库自己再吞进来一层
        if ([exp hasPrefix:[self.rootPath stringByAppendingString:@"/"]]) continue;
        // 收不收由一张白名单说了算，数据层自己判，调用方忘了筛也进不来
        VaultItemKind kind = VaultItemKindForPath(exp);
        if (kind == VaultItemKindNone) {
            [rejected addObject:[exp lastPathComponent]];
            continue;
        }

        NSString *base = [exp lastPathComponent];
        NSString *stored = [self uniqueStoredNameFor:base];
        NSString *dst = [self.rootPath stringByAppendingPathComponent:stored];
        NSError *err = nil;
        if (![fm moveItemAtPath:exp toPath:dst error:&err]) {
            NSLog(@"[DeskBoard] 入库失败 %@：%@", base, err.localizedDescription);
            continue;
        }
        DeskVaultItem *it = [DeskVaultItem new];
        it.name = base;
        it.sourceName = base;
        it.storedName = stored;
        it.kind = kind;
        it.seed = (double)arc4random_uniform(100000) / 100000.0;
        it.ingestedAt = (long long)[[NSDate date] timeIntervalSince1970];
        [added addObject:it];
    }
    if (rejected.count) {
        // 拒了什么要留痕：用户拖一堆东西进来却什么都没发生时，这里是唯一的线索
        NSLog(@"[DeskBoard] 入库拒收 %lu 个：%@", (unsigned long)rejected.count,
              [rejected componentsJoinedByString:@"，"]);
    }
    if (!added.count) return 0;

    @synchronized (self) { [_items addObjectsFromArray:added]; }
    [self persist];
    [self notifyChanged];
    [self refreshStats];
    return added.count;
}

- (NSUInteger)ingestDesktopItems {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES);
    NSString *desktop = dirs.firstObject;
    if (!desktop) return 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    NSArray *names = [fm contentsOfDirectoryAtPath:desktop error:&err];
    if (!names) return 0;
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *n in names) {
        // 收不收交给白名单判：隐藏文件、.app 这类包、别名，以及不在表里的后缀都会在这里被拒
        NSString *p = [desktop stringByAppendingPathComponent:n];
        if (VaultItemKindForPath(p) != VaultItemKindNone) [paths addObject:p];
    }
    return [self ingestPaths:paths];
}

#pragma mark - 退库

// 目标位置撞名也加序号，退回去的文件名才不会覆盖掉桌面上原有的东西
static NSString *VaultUniqueDestination(NSString *dir, NSString *name) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *candidate = name;
    for (int n = 2; n < 1000; n++) {
        if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:candidate]]) break;
        candidate = [NSString stringWithFormat:@"%@ %d", name, n];
    }
    return [dir stringByAppendingPathComponent:candidate];
}

- (BOOL)ejectItem:(DeskVaultItem *)item toDesktop:(BOOL)toDesktop {
    if (!item) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *src = [self pathForItem:item];
    NSString *dstDir = toDesktop ? NSSearchPathForDirectoriesInDomains(NSDesktopDirectory,
                                                                      NSUserDomainMask, YES).firstObject
                                 : NSTemporaryDirectory();
    if (!dstDir) return NO;
    [fm createDirectoryAtPath:dstDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *dst = VaultUniqueDestination(dstDir, item.sourceName ?: item.name);
    NSError *err = nil;
    if (![fm moveItemAtPath:src toPath:dst error:&err]) {
        NSLog(@"[DeskBoard] 退库失败 %@：%@", item.name, err.localizedDescription);
        return NO;
    }
    [self removeRecord:item];
    NSLog(@"[DeskBoard] 退回 %@ → %@", item.name, dst);
    return YES;
}

- (void)removeRecord:(DeskVaultItem *)item {
    @synchronized (self) { [_items removeObject:item]; }
    [self persist];
    [self notifyChanged];
}

- (NSUInteger)ejectAllToDesktop {
    NSUInteger n = 0;
    for (DeskVaultItem *it in [self items]) {
        if ([self ejectItem:it toDesktop:YES]) n++;
    }
    return n;
}

// 拖出库外：Finder 搬成功了文件就不在原地，摘掉记录；还在原地说明没搬走，记录留着
- (void)reconcileItem:(DeskVaultItem *)item {
    if (!item) return;
    NSString *p = [self pathForItem:item];
    NSFileManager *fm = [NSFileManager defaultManager];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), _io, ^{
        if (![fm fileExistsAtPath:p]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self removeRecord:item]; });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ [self refreshStats]; });
        }
    });
}

#pragma mark - 统计

- (NSUInteger)pendingCount {
    NSUInteger n = 0;
    for (DeskVaultItem *it in [self items]) if (!it.scanned) n++;
    return n;
}

// 一棵目录树几万个文件很常见，全量遍历必须离开主线程，否则拖一下窗口就掉帧
- (void)refreshStats {
    NSArray<DeskVaultItem *> *snapshot = [self items];
    if (!snapshot.count) return;
    NSUInteger gen;
    @synchronized (self) { gen = ++_scanGeneration; }
    NSString *root = self.rootPath;
    dispatch_async(_io, ^{
        NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (DeskVaultItem *it in snapshot) {
            NSString *dir = [root stringByAppendingPathComponent:it.storedName];
            BOOL isDir = NO;
            // 单个文件没有目录可遍历：体积就是它自己，项数恒为 1。
            // 用文件系统判断而不是看 it.kind —— 老清单的 kind 一律是文件夹，
            // 但库里那个位置现在可能躺着一个文件
            if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
                NSDictionary *attrs = [fm attributesOfItemAtPath:dir error:NULL];
                sizes[it.storedName] = attrs[NSFileSize] ?: @0;
                counts[it.storedName] = @1;
                continue;
            }
            unsigned long long bytes = 0;
            NSUInteger files = 0;
            NSDirectoryEnumerator *e = [fm enumeratorAtURL:[NSURL fileURLWithPath:dir]
                                 includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsDirectoryKey]
                                                    options:NSDirectoryEnumerationSkipsHiddenFiles
                                               errorHandler:nil];
            for (NSURL *u in e) {
                NSNumber *isDir = nil;
                [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL];
                if (isDir.boolValue) continue;   // 目录本身不计入大小，文件已在各自父目录里遍历过
                NSNumber *sz = nil;
                [u getResourceValue:&sz forKey:NSURLFileSizeKey error:NULL];
                bytes += sz.unsignedLongLongValue;
                files++;
            }
            sizes[it.storedName] = @(bytes);
            counts[it.storedName] = @(files);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUInteger cur;
            @synchronized (self) { cur = self->_scanGeneration; }
            if (gen != cur) return;   // 期间又来了一批，扔掉这次的过期结果
            for (DeskVaultItem *it in snapshot) {
                NSNumber *b = sizes[it.storedName], *c = counts[it.storedName];
                if (!b || !c) continue;
                [it willChangeValueForKey:@"byteSize"];
                it.byteSize = b.longLongValue;
                it.fileCount = c.unsignedIntegerValue;
                [it didChangeValueForKey:@"byteSize"];
                it.scanned = YES;
            }
            [self notifyChanged];
        });
    });
}

- (unsigned long long)totalBytes {
    unsigned long long t = 0;
    for (DeskVaultItem *it in [self items]) t += (unsigned long long)MAX(it.byteSize, 0LL);
    return t;
}

@end
