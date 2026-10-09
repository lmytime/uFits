// FQRender.h - glue between the C core and Core Graphics, shared by the
// app and both Quick Look extensions.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include "fq.h"

NS_ASSUME_NONNULL_BEGIN

/// Wraps an image rendered by the core. Owns the fq_image.
@interface FQRendering : NSObject
@property(nonatomic, readonly) int kind;              // FQ_KIND_*
@property(nonatomic, readonly) fq_info info;
@property(nonatomic, readonly, nullable) CGImageRef image;
@property(nonatomic, readonly) CGSize pixelSize;      // image size, or a 4:3 plot box
@property(nonatomic, readonly) const fq_image *raw;   // spectrum data
/// One line describing what is shown, e.g. "SCI · 4096 × 4096 · float32".
@property(nonatomic, readonly) NSString *summary;

/// Opens and renders path. maxPixels bounds both output dimensions.
+ (nullable instancetype)renderFile:(NSString *)path
                          maxPixels:(int)maxPixels
                            samples:(int)samples
                            stretch:(int)stretch
                              error:(NSString *_Nullable *_Nullable)error;
@end

/// Draws a spectrum envelope inside rect (Core Graphics coordinates).
void FQDrawSpectrum(CGContextRef ctx, CGRect rect, const fq_image *img, CGFloat lineWidth,
                    CGColorRef color);

/// NSString from a C string that may not be valid UTF-8. Never nil.
NSString *FQString(const char *_Nullable s);

/// Full header listing: HDU summary followed by every header (capped).
NSString *FQHeaderListing(NSString *path);

NS_ASSUME_NONNULL_END
