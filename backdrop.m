#import "backdrop.h"
#import <CoreImage/CoreImage.h>

static const CGFloat kBlurPoints = 13.0;   // 模糊半径按点算，换算到图片像素
static const CGFloat kReuseSlack = 24.0;   // 位置变化小于这个量就复用上一张

@implementation DeskBackdrop {
    CIImage *_source;
    NSString *_path;
    NSDate *_mtime;
    CIContext *_ctx;
    NSImage *_image;
    NSRect _imageRect;
    BOOL _imageDark;
}

+ (instancetype)shared {
    static DeskBackdrop *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [DeskBackdrop new]; });
    return instance;
}

- (void)invalidate {
    _image = nil;
    _imageRect = NSZeroRect;
}

// macOS 26 的壁纸配置：Index.plist 里每个 Display/Space 的 Desktop.Content.Choices[0].Configuration
// 是一段内嵌 plist，解出来形如 { type: imageFile, url: { relative: "file:///..." } }
- (NSString *)wallpaperPath {
    NSString *store = [NSHomeDirectory() stringByAppendingPathComponent:
                       @"Library/Application Support/com.apple.wallpaper/Store/Index.plist"];
    NSDictionary *idx = [NSDictionary dictionaryWithContentsOfFile:store];
    if (![idx isKindOfClass:[NSDictionary class]]) return nil;

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *dictKey in @[@"Displays", @"Spaces"]) {
        NSDictionary *dict = idx[dictKey];
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        for (id value in dict.allValues) {
            if (![value isKindOfClass:[NSDictionary class]]) continue;
            if (value[@"Desktop"]) [entries addObject:value];
            for (id inner in [value allValues]) {
                if ([inner isKindOfClass:[NSDictionary class]] && inner[@"Desktop"]) [entries addObject:inner];
            }
        }
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSDictionary *entry in entries) {
        NSArray *choices = entry[@"Desktop"][@"Content"][@"Choices"];
        if (![choices isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *choice in choices) {
            if (![choice isKindOfClass:[NSDictionary class]]) continue;
            NSData *cfg = choice[@"Configuration"];
            if (![cfg isKindOfClass:[NSData class]] || cfg.length == 0) continue;
            NSDictionary *d = [NSPropertyListSerialization propertyListWithData:cfg
                                                                        options:NSPropertyListImmutable
                                                                         format:NULL error:NULL];
            id url = [d isKindOfClass:[NSDictionary class]] ? d[@"url"] : nil;
            NSString *rel = [url isKindOfClass:[NSDictionary class]] ? url[@"relative"] : nil;
            if (![rel isKindOfClass:[NSString class]] || ![rel hasPrefix:@"file://"]) continue;
            NSString *p = [[NSURL URLWithString:rel] path];
            if (p.length && [fm fileExistsAtPath:p]) return p;
        }
    }
    return nil;
}

- (BOOL)ensureSourceForPath:(NSString *)path {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs.fileModificationDate;
    if (_source && [path isEqualToString:_path] && (mtime && [_mtime isEqualToDate:mtime])) return YES;
    NSData *data = [NSData dataWithContentsOfFile:path];
    CIImage *img = data ? [CIImage imageWithData:data] : nil;
    if (!img || img.extent.size.width < 2) return NO;
    _source = img;
    _path = [path copy];
    _mtime = mtime;
    [self invalidate];
    return YES;
}

- (NSImage *)imageForRect:(NSRect)rect dark:(BOOL)dark {
    NSString *path = [self wallpaperPath];
    if (!path || ![self ensureSourceForPath:path]) return nil;

    if (_image && NSEqualSizes(_imageRect.size, rect.size) && _imageDark == dark
        && fabs(_imageRect.origin.x - rect.origin.x) < kReuseSlack
        && fabs(_imageRect.origin.y - rect.origin.y) < kReuseSlack) {
        return _image;
    }

    NSScreen *screen = nil;
    NSPoint center = NSMakePoint(NSMidX(rect), NSMidY(rect));
    for (NSScreen *s in [NSScreen screens]) {
        if (NSPointInRect(center, s.frame)) { screen = s; break; }
    }
    if (!screen) screen = [NSScreen screens].firstObject;
    if (!screen) return nil;

    // 壁纸按 AspectFill 铺满屏幕：先算出被裁掉的边距，再把卡片的屏幕矩形换算到图片像素
    NSSize dims = _source.extent.size;
    NSRect sf = screen.frame;
    double scale = fmax(sf.size.width / dims.width, sf.size.height / dims.height);
    double cropX = (dims.width * scale - sf.size.width) / 2.0;
    double cropY = (dims.height * scale - sf.size.height) / 2.0;
    double u = (cropX + (rect.origin.x - sf.origin.x)) / scale;
    double vTop = (cropY + (NSMaxY(sf) - NSMaxY(rect))) / scale;
    double w = rect.size.width / scale;
    double h = rect.size.height / scale;
    u = MIN(MAX(u, 0), MAX(dims.width - 1, 0));
    vTop = MIN(MAX(vTop, 0), MAX(dims.height - 1, 0));
    w = MIN(w, dims.width - u);
    h = MIN(h, dims.height - vTop);
    if (w < 8 || h < 8) return nil;
    NSRect crop = NSMakeRect(u, dims.height - vTop - h, w, h);   // CoreImage 原点在左下

    CIImage *clipped = [_source imageByCroppingToRect:crop];
    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:[clipped imageByClampingToExtent] forKey:kCIInputImageKey];
    [blur setValue:@(kBlurPoints / scale) forKey:kCIInputRadiusKey];

    CIFilter *grade = [CIFilter filterWithName:@"CIColorControls"];
    [grade setValue:blur.outputImage forKey:kCIInputImageKey];
    [grade setValue:@(1.75) forKey:kCIInputSaturationKey];
    [grade setValue:@(dark ? -0.05 : 0.05) forKey:kCIInputBrightnessKey];
    CIImage *out = [grade.outputImage imageByCroppingToRect:crop];

    if (!_ctx) _ctx = [CIContext contextWithOptions:nil];
    CGImageRef rendered = [_ctx createCGImage:out fromRect:crop];
    if (!rendered) return nil;
    NSImage *img = [[NSImage alloc] initWithCGImage:rendered size:rect.size];
    CGImageRelease(rendered);

    _image = img; _imageRect = rect; _imageDark = dark;
    return img;
}

@end
