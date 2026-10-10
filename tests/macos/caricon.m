// Probe (temporary): edits an app icon's renditions in a compiled asset
// catalog (Assets.car), with CoreUI's asset storage.
//   caricon dump CAR             every rendition: its key, layout, size
//   caricon strip CAR NAME       removes NAME's flattened images (older macOS)
//   caricon swap CAR NAME FROM   NAME's flattened images become FROM's
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

struct keyfmt { uint32_t tag, version, count; uint32_t attrs[]; };
struct token { uint16_t identifier, value; };

@protocol CarStorage
- (id)initWithPath:(NSString *)path forWriting:(BOOL)writing;
- (NSArray<NSData *> *)allAssetKeys;
- (NSData *)assetForKey:(NSData *)key;
- (const struct keyfmt *)keyFormat;
- (const struct token *)renditionKeyForName:(const char *)name hotSpot:(CGPoint *)hotSpot;
- (BOOL)setAsset:(NSData *)asset forKey:(NSData *)key;
- (void)removeAssetForKey:(NSData *)key;
- (BOOL)updateBitmapInfo;
- (BOOL)writeToDiskAndCompact:(BOOL)compact;
@end

enum { kAppearance = 7, kName = 17 };

static int attrIndex(const struct keyfmt *f, uint32_t attr)
{
    for (uint32_t i = 0; i < f->count; i++)
        if (f->attrs[i] == attr)
            return (int)i;
    return -1;
}

static int nameID(id<CarStorage> s, const char *name)
{
    const struct token *t = [s renditionKeyForName:name hotSpot:NULL];
    for (; t && t->identifier; t++)
        if (t->identifier == kName)
            return t->value;
    return -1;
}

static void dump(id<CarStorage> s)
{
    const struct keyfmt *f = [s keyFormat];
    printf("key format:");
    for (uint32_t i = 0; i < f->count; i++)
        printf(" %u", f->attrs[i]);
    printf("\n");
    for (NSData *key in [s allAssetKeys]) {
        const uint16_t *v = key.bytes;
        NSData *data = [s assetForKey:key];
        const uint8_t *b = data.bytes;
        printf("  ");
        for (uint32_t i = 0; i < f->count && i < key.length / 2; i++)
            if (v[i])
                printf("%u=%u ", f->attrs[i], v[i]);
        if (data.length >= 168 && !memcmp(b, "ISTC", 4)) {
            uint32_t w, h;
            uint16_t layout;
            memcpy(&w, b + 12, 4);
            memcpy(&h, b + 16, 4);
            memcpy(&layout, b + 36, 2);
            printf("| layout %u %ux%u %.128s", layout, w, h, (const char *)b + 40);
        }
        printf(" | %lu bytes\n", (unsigned long)data.length);
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 3)
            return 2;
        dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW);
        BOOL write = strcmp(argv[1], "dump") != 0;
        id<CarStorage> s = [[NSClassFromString(@"CUIMutableCommonAssetStorage") alloc]
            initWithPath:[NSString stringWithUTF8String:argv[2]] forWriting:write];
        if (!s) {
            fprintf(stderr, "caricon: cannot open %s\n", argv[2]);
            return 1;
        }
        if (!write) {
            dump(s);
            return 0;
        }
        const struct keyfmt *f = [s keyFormat];
        int ni = attrIndex(f, kName), ai = attrIndex(f, kAppearance);
        int to = nameID(s, argv[3]);
        int from = argc > 4 ? nameID(s, argv[4]) : -1;
        printf("name at %d, appearance at %d; %s is %d, %s is %d\n", ni, ai, argv[3], to,
               argc > 4 ? argv[4] : "-", from);
        if (ni < 0 || ai < 0 || to < 0 || (argc > 4 && from < 0))
            return 1;
        NSMutableArray<NSData *> *gone = [NSMutableArray array];
        NSMutableDictionary<NSData *, NSData *> *added = [NSMutableDictionary dictionary];
        for (NSData *key in [s allAssetKeys]) {
            const uint16_t *v = key.bytes;
            if (v[ni] == to && v[ai] == 0)
                [gone addObject:key];
            if (from >= 0 && v[ni] == from) {
                NSMutableData *k = [key mutableCopy];
                ((uint16_t *)k.mutableBytes)[ni] = (uint16_t)to;
                added[k] = [s assetForKey:key];
            }
        }
        for (NSData *key in gone)
            [s removeAssetForKey:key];
        for (NSData *key in added)
            if (![s setAsset:added[key] forKey:key])
                return 1;
        printf("removed %lu, added %lu\n", (unsigned long)gone.count, (unsigned long)added.count);
        if (![s updateBitmapInfo])
            printf("(no bitmap info)\n");
        return [s writeToDiskAndCompact:YES] ? 0 : 1;
    }
}
