// FQRender.m - glue between the C core and Core Graphics.

#import "FQRender.h"

#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <sys/stat.h>

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

@interface FQHDUItem ()
- (instancetype)initWithEntry:(const fq_hdu_entry *)e;
@end

@implementation FQHDUItem

- (instancetype)initWithEntry:(const fq_hdu_entry *)e
{
    if ((self = [super init])) {
        _hdu = e->hdu;
        _kind = e->kind;
        _isTable = e->table != 0;
        _nplanes = e->nplanes;
        NSString *desc = [FQString(e->desc) stringByReplacingOccurrencesOfString:@" x "
                                                                      withString:@" × "];
        NSString *ext = FQString(e->extname);
        _extname = ext;
        _title = ext.length ? [NSString stringWithFormat:@"HDU %d  %@ — %@", e->hdu, ext, desc]
                            : [NSString stringWithFormat:@"HDU %d — %@", e->hdu, desc];
        _shortTitle = ext.length ? [NSString stringWithFormat:@"HDU %d %@", e->hdu, ext]
                                 : [NSString stringWithFormat:@"HDU %d", e->hdu];
    }
    return self;
}

- (instancetype)initWithHeaderOf:(int)hdu file:(fq_file *)f
{
    if ((self = [super init])) {
        _hdu = hdu;
        _kind = FQ_KIND_NONE;
        char name[72] = "", naxis[16] = "";
        fq_keyword(f, hdu, "EXTNAME", name, sizeof name);
        _extname = FQString(name);
        BOOL empty = fq_keyword(f, hdu, "NAXIS", naxis, sizeof naxis) && atoi(naxis) == 0;
        NSString *desc = empty ? @"no data" : @"header";
        _title = _extname.length ? [NSString stringWithFormat:@"HDU %d  %@ — %@", hdu, _extname, desc]
                                 : [NSString stringWithFormat:@"HDU %d — %@", hdu, desc];
        _shortTitle = _extname.length ? [NSString stringWithFormat:@"HDU %d %@", hdu, _extname]
                                      : [NSString stringWithFormat:@"HDU %d", hdu];
    }
    return self;
}

@end

/// Every HDU of f, in file order: those that can be drawn or listed, and
/// the others for their header (an empty primary HDU, say). Skipped for
/// big gzip files, where finding every header means inflating the whole
/// file.
static NSArray<FQHDUItem *> *FQListHDUs(fq_file *f, NSString *path)
{
    struct stat st;
    if ([path.pathExtension.lowercaseString isEqualToString:@"gz"] &&
        stat(path.fileSystemRepresentation, &st) == 0 && st.st_size > 64 * 1024 * 1024)
        return @[];
    enum { kMaxHDUs = 500 };
    fq_hdu_entry *e = calloc(kMaxHDUs, sizeof *e);
    if (!e)
        return @[];
    int n = fq_list_hdus(f, e, kMaxHDUs), total = MIN(fq_hdu_count(f), (int)kMaxHDUs), k = 0;
    NSMutableArray<FQHDUItem *> *items = [NSMutableArray array];
    for (int hdu = 0; hdu < total || k < n; hdu++) {
        if (k < n && e[k].hdu == hdu)
            [items addObject:[[FQHDUItem alloc] initWithEntry:&e[k++]]];
        else if (hdu < total)
            [items addObject:[[FQHDUItem alloc] initWithHeaderOf:hdu file:f]];
        else
            break;
    }
    free(e);
    return items;
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
    return [self renderFile:path
                  maxPixels:maxPixels
                    samples:samples
                    stretch:stretch
                        hdu:-1
                      plane:-1
                       keep:NO
                       hdus:NULL
                      error:error];
}

+ (instancetype)renderFile:(NSString *)path
                 maxPixels:(int)maxPixels
                   samples:(int)samples
                   stretch:(int)stretch
                       hdu:(int)hdu
                     plane:(long long)plane
                      keep:(BOOL)keep
                      hdus:(NSArray<FQHDUItem *> **)hdus
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
    o.hdu = hdu;
    o.plane = plane < 0 ? -1 : (int)MIN(plane, (long long)INT_MAX);
    o.keep = keep;
    fq_image *img = fq_render(f, &o, err, sizeof err);
    if (hdus)
        *hdus = FQListHDUs(f, path);
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

- (BOOL)restretch:(int)stretch
{
    if (!_image || fq_restretch(_img, stretch, 0) != 0)
        return NO;
    CGImageRef cg = FQCreateImage(_img);   // takes the new pixels
    if (!cg)
        return NO;
    CGImageRelease(_image);
    _image = cg;
    return YES;
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

- (fq_stretch)stretch
{
    return _img->stretch;
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
    if (in->table) {
        [parts addObject:[NSString stringWithFormat:@"%lld rows", (long long)in->naxes[0]]];
    } else {
        NSMutableArray<NSString *> *dims = [NSMutableArray array];
        for (int i = 0; i < in->naxis && i < FQ_MAXAXES; i++)
            [dims addObject:[NSString stringWithFormat:@"%lld", (long long)in->naxes[i]]];
        [parts addObject:[dims componentsJoinedByString:@" × "]];
        [parts addObject:FQTypeName(in->bitpix)];
        if (in->color == FQ_COLOR_RGB)
            [parts addObject:@"RGB"];
        else if (in->color == FQ_COLOR_BAYER)
            [parts addObject:[NSString stringWithFormat:@"Bayer %@", FQString(in->bayer)]];
    }
    if (in->truncated)
        [parts addObject:@"file is truncated"];
    return [parts componentsJoinedByString:@"  ·  "];
}

@end

@implementation FQDetailSource {
    NSString *_path;
    fq_file *_file;
}

- (instancetype)initWithPath:(NSString *)path
{
    if ((self = [super init]))
        _path = [path copy];
    return self;
}

- (void)dealloc
{
    fq_close(_file);
}

- (CGImageRef)copyDetailOfHDU:(int)hdu
                        plane:(long long)plane
                      stretch:(fq_stretch)stretch
                       region:(CGRect)region
                     maxWidth:(int)maxWidth
                    maxHeight:(int)maxHeight
                      covered:(CGRect *)covered
{
    char err[256] = "";
    if (!_file)
        _file = fq_open(_path.fileSystemRepresentation, err, sizeof err);
    if (!_file)
        return NULL;
    fq_opts o;
    fq_opts_default(&o);
    o.max_width = maxWidth;
    o.max_height = maxHeight;
    o.hdu = hdu;
    o.plane = plane < 0 ? -1 : (int)MIN(plane, (long long)INT_MAX);
    o.region[0] = (int64_t)floor(region.origin.x);
    o.region[1] = (int64_t)floor(region.origin.y);
    o.region[2] = (int64_t)ceil(CGRectGetMaxX(region)) - o.region[0];
    o.region[3] = (int64_t)ceil(CGRectGetMaxY(region)) - o.region[1];
    fq_image *img = fq_render_detail(_file, &o, &stretch, err, sizeof err);
    if (!img)
        return NULL;
    CGImageRef cg = FQCreateImage(img);
    if (covered)
        *covered = CGRectMake(img->info.region[0], img->info.region[1], img->info.region[2],
                              img->info.region[3]);
    fq_image_free(img);
    return cg;
}

@end

/// Horizontal position of plot column c of n; x_flip puts the first
/// column on the right (right ascension grows to the left).
static CGFloat FQColumnX(const fq_image *img, CGRect rect, int c)
{
    int n = img->spec_n;
    CGFloat off = n > 1 ? (CGFloat)c * rect.size.width / (CGFloat)(n - 1) : rect.size.width / 2;
    return img->x_flip ? CGRectGetMaxX(rect) - off : CGRectGetMinX(rect) + off;
}

/// Crowded plots (big catalogs): each cell of the core's grid is shaded by
/// how many points fall in it, on a log scale, so structure shows.
static void FQDrawDensity(CGContextRef ctx, CGRect rect, const fq_image *img, int peak)
{
    const int n = img->spec_n, rows = img->dot_rows;
    uint8_t *mask = malloc((size_t)n * (size_t)rows);
    if (!mask)
        return;
    const double k = 195.0 / log((double)peak);
    for (int r = 0; r < rows; r++) {   // mask row 0 is the top of the plot
        int gr = img->y_flip ? r : rows - 1 - r;
        uint8_t *out = mask + (size_t)r * (size_t)n;
        for (int c = 0; c < n; c++) {
            int gc = img->x_flip ? n - 1 - c : c;
            int count = img->dots[(size_t)gc * (size_t)rows + (size_t)gr];
            out[c] = count ? (uint8_t)(60 + k * log((double)count)) : 0;
        }
    }
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, mask, (size_t)n * (size_t)rows, FQReleasePixels);
    if (!dp) {
        free(mask);
        return;
    }
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGImageRef im = CGImageCreate((size_t)n, (size_t)rows, 8, 8, (size_t)n, gray,
                                  (CGBitmapInfo)kCGImageAlphaNone, dp, NULL, true, kCGRenderingIntentDefault);
    CGColorSpaceRelease(gray);
    CGDataProviderRelease(dp);
    if (!im)
        return;
    CGContextSaveGState(ctx);
    CGContextClipToMask(ctx, rect, im);   // white cells paint, black ones do not
    CGContextFillRect(ctx, rect);
    CGContextRestoreGState(ctx);
    CGImageRelease(im);
}

/// Points from the core's grid: one dot per occupied cell, round where
/// there are few and square (much faster to fill) where there are many;
/// a density map when the plot is crowded.
static void FQDrawDots(CGContextRef ctx, CGRect rect, const fq_image *img, CGFloat size)
{
    const int n = img->spec_n, rows = img->dot_rows;
    const size_t cells = (size_t)n * (size_t)rows;
    size_t count = 0;
    int peak = 0;
    for (size_t i = 0; i < cells; i++)
        if (img->dots[i]) {
            count++;
            if (img->dots[i] > peak)
                peak = img->dots[i];
        }
    if (count > cells / 8 && peak > 1) {
        FQDrawDensity(ctx, rect, img, peak);
        return;
    }
    const BOOL ellipses = count <= 20000;
    CGMutablePathRef path = CGPathCreateMutable();
    CGRect batch[256];
    int nb = 0;
    for (int c = 0; c < n; c++) {
        const uint8_t *col = img->dots + (size_t)c * (size_t)rows;
        CGFloat x = FQColumnX(img, rect, c);
        for (int r = 0; r < rows; r++) {
            if (!col[r])
                continue;
            CGFloat k = ((CGFloat)r + 0.5) / (CGFloat)rows * rect.size.height;
            CGFloat y = img->y_flip ? CGRectGetMaxY(rect) - k : CGRectGetMinY(rect) + k;
            CGRect dot = CGRectMake(x - size / 2, y - size / 2, size, size);
            if (ellipses) {
                CGPathAddEllipseInRect(path, NULL, dot);
            } else {
                batch[nb++] = dot;
                if (nb == 256) {
                    CGContextFillRects(ctx, batch, (size_t)nb);
                    nb = 0;
                }
            }
        }
    }
    if (nb)
        CGContextFillRects(ctx, batch, (size_t)nb);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGPathRelease(path);
}

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
    if (img->dots && img->dot_rows > 0) {
        CGContextSetFillColorWithColor(ctx, color);
        FQDrawDots(ctx, rect, img, MAX(lineWidth * 2, 1.0));
        CGContextRestoreGState(ctx);
        return;
    }
    CGMutablePathRef path = CGPathCreateMutable();
    const double sy = rect.size.height / (hi - lo);
    const CGFloat ymin = CGRectGetMinY(rect) - 4, ymax = CGRectGetMaxY(rect) + 4;
    const BOOL flip = img->y_flip != 0;
    // Short runs of empty columns come from uneven sampling and are bridged;
    // longer ones are gaps in the data.
    const int maxgap = MAX(2, n / 50);
    int gap = 0;
    BOOL open = NO;
    for (int c = 0; c < n; c++) {
        float a = img->spec_lo[c], b = img->spec_hi[c];
        if (!isfinite(a) || !isfinite(b)) {
            if (++gap > maxgap)
                open = NO;
            continue;
        }
        gap = 0;
        CGFloat x = FQColumnX(img, rect, c);
        CGFloat y0 = (CGFloat)((a - lo) * sy), y1 = (CGFloat)((b - lo) * sy);
        y0 = flip ? CGRectGetMaxY(rect) - y0 : CGRectGetMinY(rect) + y0;
        y1 = flip ? CGRectGetMaxY(rect) - y1 : CGRectGetMinY(rect) + y1;
        y0 = y0 < ymin ? ymin : (y0 > ymax ? ymax : y0);
        y1 = y1 < ymin ? ymin : (y1 > ymax ? ymax : y1);
        if (c & 1) {   // alternate direction so dense data fills as a band
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
