// Gives an app icon in a compiled asset catalog (Assets.car) the flattened
// images of another, the ones that macOS 15 and earlier show: actool makes an
// Icon Composer icon's from its light look, and uFits' are to be Dusk. macOS
// 26 draws the icon itself and is not changed. With CoreUI's asset storage, a
// private part of macOS (as actool's own); the Makefile goes on without this
// if it fails.
//
// Usage: flat_icon CAR NAME FROM
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/runtime.h>

struct keyfmt { uint32_t tag, version, count; uint32_t attrs[]; };
struct token { uint16_t identifier, value; };

@protocol FQCarStorage
- (id)initWithPath:(NSString *)path forWriting:(BOOL)writing;
- (NSArray *)allAssetKeys;
- (NSData *)assetForKey:(NSData *)key;
- (const struct keyfmt *)keyFormat;
- (const struct token *)renditionKeyForName:(const char *)name hotSpot:(CGPoint *)hotSpot;
- (BOOL)setAsset:(NSData *)asset forKey:(NSData *)key;
- (void)removeAssetForKey:(NSData *)key;
- (BOOL)updateBitmapInfo;
- (BOOL)writeToDiskAndCompact:(BOOL)compact;
@end

@protocol FQRenditionKey
- (const struct token *)keyList;
@end

// The attributes of a rendition's key: its name, and its look (none for the
// flattened images; macOS 26's light, dark and tinted ones for the icon).
enum { kAppearance = 7, kName = 17 };

static int attrIndex(const struct keyfmt *f, uint32_t attr)
{
    for (uint32_t i = 0; i < f->count; i++)
        if (f->attrs[i] == attr)
            return (int)i;
    return -1;
}

static int nameID(id<FQCarStorage> car, const char *name)
{
    const struct token *t = [car renditionKeyForName:name hotSpot:NULL];
    for (; t && t->identifier; t++)
        if (t->identifier == kName)
            return t->value;
    return -1;
}

/// A rendition's key as the catalog stores it: its attributes' values, in the
/// order of the catalog's key format.
static NSData *rawKey(id<FQCarStorage> car, id key)
{
    if ([key isKindOfClass:[NSData class]])
        return key;
    if (![key respondsToSelector:@selector(keyList)])
        return nil;
    const struct keyfmt *f = [car keyFormat];
    NSMutableData *raw = [NSMutableData dataWithLength:f->count * sizeof(uint16_t)];
    uint16_t *v = raw.mutableBytes;
    for (const struct token *t = [(id<FQRenditionKey>)key keyList]; t && t->identifier; t++) {
        int i = attrIndex(f, t->identifier);
        if (i >= 0)
            v[i] = t->value;
    }
    return raw;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "usage: flat_icon CAR NAME FROM\n");
            return 2;
        }
        dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW);
        Class storage = NSClassFromString(@"CUIMutableCommonAssetStorage");
        id<FQCarStorage> car = [[storage alloc] initWithPath:@(argv[1]) forWriting:YES];
        const struct keyfmt *f = car ? [car keyFormat] : NULL;
        int name = f ? attrIndex(f, kName) : -1, look = f ? attrIndex(f, kAppearance) : -1;
        int to = name >= 0 ? nameID(car, argv[2]) : -1, from = name >= 0 ? nameID(car, argv[3]) : -1;
        if (to < 0 || from < 0 || look < 0) {
            fprintf(stderr, "flat_icon: no %s and %s in %s\n", argv[2], argv[3], argv[1]);
            return 1;
        }
        // NAME's flattened images go, and FROM's are copied under its name.
        NSMutableArray<NSData *> *gone = [NSMutableArray array];
        NSMutableDictionary<NSData *, NSData *> *copies = [NSMutableDictionary dictionary];
        for (id key in [car allAssetKeys]) {
            NSData *raw = rawKey(car, key);
            if (!raw) {
                fprintf(stderr, "flat_icon: keys of an unknown kind (%s)\n", class_getName([key class]));
                return 1;
            }
            const uint16_t *v = raw.bytes;
            if (v[name] == to && v[look] == 0)
                [gone addObject:raw];
            if (v[name] == from) {
                NSMutableData *copy = [raw mutableCopy];
                ((uint16_t *)copy.mutableBytes)[name] = (uint16_t)to;
                NSData *asset = [car assetForKey:raw];
                if (!asset)
                    return 1;
                copies[copy] = asset;
            }
        }
        if (!copies.count) {
            fprintf(stderr, "flat_icon: %s has no images\n", argv[3]);
            return 1;
        }
        for (NSData *raw in gone)
            [car removeAssetForKey:raw];
        for (NSData *raw in copies)
            if (![car setAsset:copies[raw] forKey:raw])
                return 1;
        [car updateBitmapInfo];
        if (![car writeToDiskAndCompact:YES])
            return 1;
        printf("%s: %lu flattened images of %s become %s's %lu\n", argv[1], (unsigned long)gone.count, argv[2],
               argv[3], (unsigned long)copies.count);
        return 0;
    }
}
