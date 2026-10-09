// FQRender.m - glue between the C core and Core Graphics.

#import "FQRender.h"

#include <math.h>
#include <stdlib.h>

NSString *FQString(const char *s)
{
    if (!s)
        return @"";
    NSString *r = [NSString stringWithUTF8String:s];
    if (!r)
        r = [[NSString alloc] initWithBytes:s length:strlen(s) encoding:NSISOLatin1StringEncoding];
    return r ?: @"";
}

static void FQReleasePixels(void *info, const void *data, size_t size)
{
    (void)info;
    (void)size;
    free((void *)data);
}

/// CGImage over the pixels of img, which it takes over (no copy).
static CGImageRef FQCreateImage(fq_image *img)
{
    if (!img->pixels || img->width <= 0 || img->height <= 0)
        return NULL;
    size_t len = img->row_bytes * (size_t)img->height;
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, img->pixels, len, FQReleasePixels);
    if (!dp)
        return NULL;
    img->pixels = NULL;
    CGColorSpaceRef cs;
    CGBitmapInfo bi;
    if (img->components == 1) {
        cs = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
        bi = (CGBitmapInfo)kCGImageAlphaNone;
    } else {
        cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        bi = (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
    }
    CGImageRef cg = CGImageCreate((size_t)img->width, (size_t)img->height, 8,
                                  8 * (size_t)img->components, img->row_bytes, cs, bi, dp, NULL,
                                  false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(dp);
    return cg;
}

static NSString *FQTypeName(int bitpix)
{
    switch (bitpix) {
    case 8: return @"8-bit";
    case 16: return @"16-bit";
    case 32: return @"32-bit";
    case 64: return @"64-bit";
    case -32: return @"float32";
    case -64: return @"float64";
    }
    return @"?";
}

@implementation FQRendering {
    fq_image *_img;
    CGImageRef _image;
}

+ (instancetype)renderFile:(NSString *)path
                 maxPixels:(int)maxPixels
                   samples:(int)samples
                   stretch:(int)stretch
                     error:(NSString **)error
{
    char err[256] = "";
    fq_file *f = fq_open(path.fileSystemRepresentation, err, sizeof err);
    if (!f) {
        if (error)
            *error = FQString(err);
        return nil;
    }
    fq_opts o;
    fq_opts_default(&o);
    o.max_width = o.max_height = maxPixels > 0 ? maxPixels : 1024;
    o.max_samples = samples;
    o.stretch = stretch;
    fq_image *img = fq_render(f, &o, err, sizeof err);
    fq_close(f);
    if (!img) {
        if (error)
            *error = FQString(err);
        return nil;
    }
    return [[self alloc] initWithImage:img];
}

- (instancetype)initWithImage:(fq_image *)img
{
    if ((self = [super init])) {
        _img = img;
        if (img->info.kind == FQ_KIND_IMAGE)
            _image = FQCreateImage(img);
    }
    return self;
}

- (void)dealloc
{
    if (_image)
        CGImageRelease(_image);
    fq_image_free(_img);
}

- (int)kind
{
    if (_img->info.kind == FQ_KIND_IMAGE && !_image)
        return FQ_KIND_NONE;
    return _img->info.kind;
}

- (fq_info)info
{
    return _img->info;
}

- (CGImageRef)image
{
    return _image;
}

- (const fq_image *)raw
{
    return _img;
}

- (CGSize)pixelSize
{
    if (_image)
        return CGSizeMake(CGImageGetWidth(_image), CGImageGetHeight(_image));
    return CGSizeMake(1200, 900);
}

- (NSString *)summary
{
    const fq_info *in = &_img->info;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *ext = FQString(in->extname);
    if (in->hdu > 0 || ext.length)
        [parts addObject:ext.length ? [NSString stringWithFormat:@"HDU %d %@", in->hdu, ext]
                                    : [NSString stringWithFormat:@"HDU %d", in->hdu]];
    NSMutableArray<NSString *> *dims = [NSMutableArray array];
    for (int i = 0; i < in->naxis && i < FQ_MAXAXES; i++)
        [dims addObject:[NSString stringWithFormat:@"%lld", (long long)in->naxes[i]]];
    [parts addObject:[dims componentsJoinedByString:@" × "]];
    [parts addObject:FQTypeName(in->bitpix)];
    if (in->compressed)
        [parts addObject:FQString(in->cmptype)];
    if (in->color == FQ_COLOR_RGB)
        [parts addObject:@"RGB"];
    else if (in->color == FQ_COLOR_BAYER)
        [parts addObject:[NSString stringWithFormat:@"Bayer %@", FQString(in->bayer)]];
    else if (in->nplanes > 1)
        [parts addObject:[NSString stringWithFormat:@"plane %lld of %lld", (long long)in->plane + 1,
                                                    (long long)in->nplanes]];
    if (in->kind == FQ_KIND_SPECTRUM) {
        if (_img->has_x)
            [parts addObject:[NSString stringWithFormat:@"%g – %g %@", _img->x_first, _img->x_last,
                                                        FQString(_img->x_unit)]];
    } else if (in->bin > 1) {
        [parts addObject:[NSString stringWithFormat:@"shown at 1/%d", in->bin]];
    }
    if (in->truncated)
        [parts addObject:@"file is truncated"];
    return [parts componentsJoinedByString:@"  ·  "];
}

@end

void FQDrawSpectrum(CGContextRef ctx, CGRect rect, const fq_image *img, CGFloat lineWidth,
                    CGColorRef color)
{
    int n = img->spec_n;
    double lo = img->y_min, hi = img->y_max;
    if (n <= 0 || !isfinite(lo) || !isfinite(hi) || !(hi > lo) || rect.size.width <= 0 ||
        rect.size.height <= 0)
        return;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    CGMutablePathRef path = CGPathCreateMutable();
    const double sy = rect.size.height / (hi - lo);
    const CGFloat ymin = CGRectGetMinY(rect) - 4, ymax = CGRectGetMaxY(rect) + 4;
    BOOL open = NO;
    for (int c = 0; c < n; c++) {
        float a = img->spec_lo[c], b = img->spec_hi[c];
        if (!isfinite(a) || !isfinite(b)) {
            open = NO;
            continue;
        }
        CGFloat x = rect.origin.x +
                    (n > 1 ? (CGFloat)c * rect.size.width / (CGFloat)(n - 1) : rect.size.width / 2);
        CGFloat y0 = rect.origin.y + (CGFloat)((a - lo) * sy);
        CGFloat y1 = rect.origin.y + (CGFloat)((b - lo) * sy);
        y0 = y0 < ymin ? ymin : (y0 > ymax ? ymax : y0);
        y1 = y1 < ymin ? ymin : (y1 > ymax ? ymax : y1);
        if (c & 1) {   /* alternate direction so dense data fills as a band */
            CGFloat t = y0;
            y0 = y1;
            y1 = t;
        }
        if (open)
            CGPathAddLineToPoint(path, NULL, x, y0);
        else
            CGPathMoveToPoint(path, NULL, x, y0);
        open = YES;
        if (y1 != y0)
            CGPathAddLineToPoint(path, NULL, x, y1);
    }
    CGContextAddPath(ctx, path);
    CGContextSetStrokeColorWithColor(ctx, color);
    CGContextSetLineWidth(ctx, lineWidth);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextStrokePath(ctx);
    CGPathRelease(path);
    CGContextRestoreGState(ctx);
}

NSString *FQHeaderListing(NSString *path)
{
    char err[256] = "";
    fq_file *f = fq_open(path.fileSystemRepresentation, err, sizeof err);
    if (!f)
        return [NSString stringWithFormat:@"Cannot read this file: %@", FQString(err)];
    NSMutableString *s = [NSMutableString string];
    char *sum = fq_summary_text(f);
    [s appendString:FQString(sum)];
    free(sum);
    int n = fq_hdu_count(f), shown = 0;
    for (int i = 0; i < n && s.length < 8000000; i++, shown++) {
        char *h = fq_header_text(f, i, NULL);
        if (!h)
            break;
        [s appendFormat:@"\n——— HDU %d ———\n", i];
        [s appendString:FQString(h)];
        free(h);
    }
    if (shown < n)
        [s appendFormat:@"\n… %d more HDUs not shown\n", n - shown];
    fq_close(f);
    return s;
}
