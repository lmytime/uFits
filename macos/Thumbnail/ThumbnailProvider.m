// ThumbnailProvider.m - principal class of the Quick Look thumbnail
// extension (Finder icons, column view, Spotlight).

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

#import "FQRender.h"

@interface ThumbnailProvider : QLThumbnailProvider
@end

/// image (or, for a plot, raw drawn on white) w x h pixels large.
static CGImageRef FQCreateSized(FQRendering *r, size_t w, size_t h) CF_RETURNS_RETAINED
{
    CGImageRef image = r.image;
    if (image && CGImageGetWidth(image) == w && CGImageGetHeight(image) == h)
        return CGImageRetain(image);
    BOOL gray = image && CGImageGetAlphaInfo(image) == kCGImageAlphaNone &&
                CGColorSpaceGetModel(CGImageGetColorSpace(image)) == kCGColorSpaceModelMonochrome;
    CGColorSpaceRef cs = gray ? CGColorSpaceRetain(CGImageGetColorSpace(image))
                              : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                             gray ? (CGBitmapInfo)kCGImageAlphaNone
                                                  : (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx)
        return NULL;
    CGRect all = CGRectMake(0, 0, w, h);
    if (image) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, all, image);
    } else {
        CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
        CGContextFillRect(ctx, all);
        CGFloat m = MAX(2, w * 0.06);
        CGColorRef ink = CGColorCreateGenericRGB(0.1, 0.1, 0.12, 1);
        FQDrawSpectrum(ctx, CGRectInset(all, m, m), r.raw, MAX(0.75, w / 300.0), ink);
        CGColorRelease(ink);
    }
    CGImageRef sized = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return sized;
}

/// A PNG file of image for Quick Look to read, in a folder of the
/// extension's own; files from earlier thumbnails, read long ago, go.
static NSURL *FQWritePNG(CGImageRef image)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"thumbnails"]
                            isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDate *old = [NSDate dateWithTimeIntervalSinceNow:-600];
    for (NSURL *f in [fm contentsOfDirectoryAtURL:dir
                       includingPropertiesForKeys:@[ NSURLContentModificationDateKey ]
                                          options:NSDirectoryEnumerationSkipsHiddenFiles
                                            error:nil]) {
        NSDate *when = nil;
        [f getResourceValue:&when forKey:NSURLContentModificationDateKey error:nil];
        if (when && [when compare:old] == NSOrderedAscending)
            [fm removeItemAtURL:f error:nil];
    }
    NSURL *url = [dir URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"png"]];
    CGImageDestinationRef dest =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    if (!dest)
        return nil;
    CGImageDestinationAddImage(dest, image, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? url : nil;
}

@implementation ThumbnailProvider

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request
                     completionHandler:(void (^)(QLThumbnailReply *_Nullable,
                                                 NSError *_Nullable))handler
{
    CGSize box = request.maximumSize;
    CGFloat scale = request.scale > 0 ? request.scale : 1;
    // Icons under 40 points (list and column views) keep the file's own
    // icon: a picture that small says little.
    if (MAX(box.width, box.height) < 40) {
        handler(nil, [NSError errorWithDomain:@"uFits"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey : @"no thumbnail for icons this small"}]);
        return;
    }
    int maxPixels = (int)ceil(MAX(box.width, box.height) * scale);
    maxPixels = MIN(MAX(maxPixels, 16), 2048);

    // Thumbnails sample at most 2x2 pixels per output pixel: plenty for an
    // icon, and it touches only a fraction of a large file.
    NSString *error = nil;
    FQRendering *r = [FQRendering renderFile:request.fileURL.path
                                   maxPixels:maxPixels
                                     samples:2
                                     stretch:FQ_STRETCH_AUTO
                                       error:&error];
    NSURL *png = nil;
    if (r && r.kind != FQ_KIND_NONE && !r.info.empty) {
        // The thumbnail goes to Quick Look as a file of request.scale times
        // the size asked for, and Quick Look fits it in: in the context of a
        // drawing block, Finder's Retina icons got a thumbnail in their lower
        // left quarter (what that context is varies, and says little).
        CGSize px = r.pixelSize;
        CGFloat s = MIN(box.width * scale / px.width, box.height * scale / px.height);
        size_t w = (size_t)MAX(1, round(px.width * s)), h = (size_t)MAX(1, round(px.height * s));
        CGImageRef sized = FQCreateSized(r, w, h);
        if (sized) {
            png = FQWritePNG(sized);
            CGImageRelease(sized);
        }
        if (!png)
            error = @"could not write the thumbnail";
    }
    if (!png) {
        handler(nil, [NSError errorWithDomain:@"uFits"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : error ?: @"no image in this file"
                                     }]);
        return;
    }
    QLThumbnailReply *reply = [QLThumbnailReply replyWithImageFileURL:png];
    if (@available(macOS 12.0, *))
        reply.extensionBadge =
            [request.fileURL.pathExtension caseInsensitiveCompare:@"xisf"] == NSOrderedSame ? @"XISF" : @"FITS";
    handler(reply, nil);
}

@end
