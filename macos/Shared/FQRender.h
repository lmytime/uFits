// FQRender.h - glue between the C core and Core Graphics, shared by the
// app and both Quick Look extensions.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include "fq.h"

NS_ASSUME_NONNULL_BEGIN

/// One HDU a viewer can switch to (an image, or a table that is plotted).
@interface FQHDUItem : NSObject
@property(nonatomic, readonly) int hdu;
@property(nonatomic, readonly) int kind;            // FQ_KIND_IMAGE, _PLOT or _TABLE
@property(nonatomic, readonly) BOOL isTable;        // a table, plotted or not
@property(nonatomic, readonly) long long nplanes;
@property(nonatomic, readonly, copy) NSString *extname;
@property(nonatomic, readonly, copy) NSString *title; // "HDU 1  SCI — 4096 × 4096 float32"
@end

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

/// Same, for a given HDU and cube plane (-1 = automatic). With hdus, also
/// lists the HDUs that can be shown, whether or not rendering succeeds.
/// With keep, the binned values are kept so -restretch: is quick.
+ (nullable instancetype)renderFile:(NSString *)path
                          maxPixels:(int)maxPixels
                            samples:(int)samples
                            stretch:(int)stretch
                                hdu:(int)hdu
                              plane:(long long)plane
                               keep:(BOOL)keep
                               hdus:(NSArray<FQHDUItem *> *_Nullable *_Nullable)hdus
                              error:(NSString *_Nullable *_Nullable)error;

/// Stretches an image rendered with keep again, without reading the file
/// (a few milliseconds). NO if that is not possible.
- (BOOL)restretch:(int)stretch;
@end

/// Draws a plot envelope inside rect (Core Graphics coordinates): a line,
/// or dots for a time series; magnitudes run downwards.
void FQDrawSpectrum(CGContextRef ctx, CGRect rect, const fq_image *img, CGFloat lineWidth,
                    CGColorRef color);

/// NSString from a C string that may not be valid UTF-8. Never nil.
NSString *FQString(const char *_Nullable s);

NS_ASSUME_NONNULL_END
