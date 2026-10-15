#import "smc.h"
#import <IOKit/IOKitLib.h>

enum {
    kSMCReadKey = 5,
    kSMCGetKeyCount = 7,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo = 9,
};

typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint16_t build;
    uint8_t  reserved[1];
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint64_t cpuPLimit;
    uint64_t gpuPLimit;
    uint64_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t     key;
    SMCVersion   vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo   keyInfo;
    uint8_t      result;
    uint8_t      status;
    uint8_t      data8;
    uint32_t     data32;
    uint8_t      bytes[32];
} SMCParamStruct;

static uint32_t KeyToUInt32(NSString *name) {
    uint32_t out = 0;
    for (int i = 0; i < 4 && i < (int)name.length; i++) {
        out = (out << 8) | (uint8_t)[name characterAtIndex:i];
    }
    return out;
}

static NSString *UInt32ToKey(uint32_t key) {
    char chars[5] = { (char)((key >> 24) & 0xFF), (char)((key >> 16) & 0xFF),
                      (char)((key >> 8) & 0xFF), (char)(key & 0xFF), 0 };
    return [NSString stringWithUTF8String:chars] ?: @"";
}

static uint64_t ReadBE(const uint8_t *p, int n) {
    uint64_t v = 0;
    for (int i = 0; i < n; i++) v = (v << 8) | p[i];
    return v;
}

@implementation DeskSMC {
    io_connect_t _conn;
    BOOL _open;
}

- (BOOL)available { return _open; }

- (BOOL)open {
    if (_open) return YES;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return NO;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &_conn);
    IOObjectRelease(svc);
    _open = (kr == KERN_SUCCESS);
    return _open;
}

- (void)close {
    if (_open) { IOServiceClose(_conn); _open = NO; }
}

- (BOOL)call:(uint32_t)selector input:(SMCParamStruct *)in output:(SMCParamStruct *)out {
    size_t inSize = sizeof(SMCParamStruct), outSize = sizeof(SMCParamStruct);
    kern_return_t kr = IOConnectCallStructMethod(_conn, selector, in, inSize, out, &outSize);
    return kr == KERN_SUCCESS && out->result == 0;
}

- (NSArray<NSString *> *)allKeys {   // 注：本机 Apple Silicon 上枚举类 selector 返回 Unsupported
    if (![self open]) return @[];
    SMCParamStruct in = {0}, out = {0};
    in.data8 = kSMCGetKeyCount;
    if (![self call:kSMCGetKeyCount input:&in output:&out]) return @[];
    uint32_t count = out.keyInfo.dataSize;

    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        in = (SMCParamStruct){0}; out = (SMCParamStruct){0};
        in.keyInfo.dataSize = i;
        in.data8 = kSMCGetKeyFromIndex;
        if ([self call:kSMCGetKeyFromIndex input:&in output:&out]) {
            [keys addObject:UInt32ToKey(out.key)];
        }
    }
    return keys;
}

- (BOOL)infoFor:(NSString *)name size:(uint32_t *)size type:(uint32_t *)type {
    SMCParamStruct in = {0}, out = {0};
    in.key = KeyToUInt32(name);
    in.data8 = kSMCGetKeyInfo;
    if (![self call:kSMCGetKeyInfo input:&in output:&out]) return NO;
    if (size) *size = out.keyInfo.dataSize;
    if (type) *type = out.keyInfo.dataType;
    return YES;
}

- (NSUInteger)sizeForKey:(NSString *)key {
    uint32_t size = 0;
    return [self infoFor:key size:&size type:NULL] ? size : 0;
}

- (NSString *)typeForKey:(NSString *)key {
    uint32_t type = 0;
    return [self infoFor:key size:NULL type:&type] ? UInt32ToKey(type) : @"";
}

- (NSNumber *)numberForKey:(NSString *)key {
    if (![self open]) return nil;
    uint32_t size = 0, type = 0;
    if (![self infoFor:key size:&size type:&type] || size == 0 || size > 32) return nil;

    SMCParamStruct in = {0}, out = {0};
    in.key = KeyToUInt32(key);
    in.keyInfo.dataSize = size;
    in.data8 = kSMCReadKey;
    if (![self call:kSMCReadKey input:&in output:&out]) return nil;
    const uint8_t *b = out.bytes;
    NSString *t = UInt32ToKey(type);

    if ([t hasPrefix:@"flt"]) {                        // 小端 IEEE float32
        float f = 0;
        memcpy(&f, b, MIN(size, 4u));
        return @(f);
    }
    if ([t hasPrefix:@"sp"] && t.length >= 4) {          // 大端定点，sp78 = 原始值 / 2^8
        int fracBits = [t characterAtIndex:3] - '0';
        int16_t raw = (int16_t)ReadBE(b, MIN(size, 2u));
        return @(raw / pow(2.0, fracBits));
    }
    if ([t hasPrefix:@"ioft"]) {                        // 小端 uint64，常见于功耗（纳瓦）
        uint64_t v = 0;
        memcpy(&v, b, MIN(size, 8u));
        return @(v);
    }
    if ([t hasPrefix:@"ui"]) {
        return @(ReadBE(b, MIN(size, 8u)));
    }
    if ([t hasPrefix:@"si"]) {
        uint64_t v = ReadBE(b, MIN(size, 8u));
        if (size == 1 && (v & 0x80)) v |= ~0xFFULL;
        if (size == 2 && (v & 0x8000)) v |= ~0xFFFFULL;
        return @((int64_t)v);
    }
    if ([t hasPrefix:@"fpe"]) {                         // Intel 机型的风扇转速编码
        uint16_t raw = (uint16_t)ReadBE(b, MIN(size, 2u));
        int shift = [t substringFromIndex:3].intValue;
        return @(raw / pow(2.0, 16 - (shift > 0 ? shift : 8)));
    }
    return @(ReadBE(b, MIN(size, 8u)));
}

@end
