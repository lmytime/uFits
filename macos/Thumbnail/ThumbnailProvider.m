// ThumbnailProvider.m - principal class of the Quick Look thumbnail
// extension (Finder icons, column view, Spotlight).

#import <Foundation/Foundation.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

#import "FQRender.h"

@interface ThumbnailProvider : QLThumbnailProvider
@end

/// The whole bitmap that Quick Look gives to draw in, in the context's user
/// space. It is request.scale times the size asked for, whether or not the
/// context's transform says so: drawn at the size asked for, a thumbnail
/// filled only the lower left quarter of a Retina icon.
static CGRect FQWholeContext(CGContextRef ctx, CGSize size)
{
    size_t w = CGBitmapContextGetWidth(ctx), h = CGBitmapContextGetHeight(ctx);
    if (!w || !h)
        return CGRectMake(0, 0, size.width, size.height);
    return CGContextConvertRectToUserSpace(ctx, CGRectMake(0, 0, w, h));
}

@implementation ThumbnailProvider

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request
                     completionHandler:(void (^)(QLThumbnailReply *_Nullable,
                                                 NSError *_Nullable))handler
{
    CGSize box = request.maximumSize;
    CGFloat scale = request.scale > 0 ? request.scale : 1;
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
    if (!r || r.kind == FQ_KIND_NONE || r.info.empty) {
        handler(nil, [NSError errorWithDomain:@"uFits"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : error ?: @"no image in this file"
                                     }]);
        return;
    }

    CGSize px = r.pixelSize;
    CGFloat s = MIN(box.width / px.width, box.height / px.height);
    CGSize size = CGSizeMake(MAX(1, round(px.width * s)), MAX(1, round(px.height * s)));
    QLThumbnailReply *reply;
    if (r.kind == FQ_KIND_IMAGE) {
        reply = [QLThumbnailReply replyWithContextSize:size
                                          drawingBlock:^BOOL(CGContextRef ctx) {
                                              CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
                                              CGContextDrawImage(ctx, FQWholeContext(ctx, size), r.image);
                                              return YES;
                                          }];
    } else {
        reply = [QLThumbnailReply replyWithContextSize:size
                                          drawingBlock:^BOOL(CGContextRef ctx) {
                                              CGRect all = FQWholeContext(ctx, size);
                                              CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
                                              CGContextFillRect(ctx, all);
                                              CGFloat m = MAX(2, all.size.width * 0.06);
                                              CGColorRef ink = CGColorCreateGenericRGB(0.1, 0.1, 0.12, 1);
                                              FQDrawSpectrum(ctx, CGRectInset(all, m, m), r.raw,
                                                             MAX(0.75, all.size.width / 300), ink);
                                              CGColorRelease(ink);
                                              return YES;
                                          }];
    }
    if (@available(macOS 12.0, *))
        reply.extensionBadge = @"FITS";
    handler(reply, nil);
}

@end
