// qlthumb - ask Quick Look for thumbnails the way Finder does (through
// QLThumbnailGenerator, so the installed extension is used) and save them,
// at scale 1 and at scale 2, as on a Retina screen.
//
// Usage: qlthumb OUTDIR FILE...
// Exits non-zero if any file does not get a real thumbnail, or one that
// does not fill its bitmap (as one drawn at scale 1 in a scale 2 bitmap).

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/// How much of img has anything drawn in it (alpha > 0): the bounding box,
/// as fractions of its width and height.
static CGSize drawnPart(CGImageRef img)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    uint8_t *px = calloc(w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    size_t x0 = w, x1 = 0, y0 = h, y1 = 0;
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w; x++)
            if (px[(y * w + x) * 4 + 3]) {
                x0 = MIN(x0, x), x1 = MAX(x1, x + 1);
                y0 = MIN(y0, y), y1 = MAX(y1, y + 1);
            }
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(px);
    return x1 > x0 ? CGSizeMake((double)(x1 - x0) / w, (double)(y1 - y0) / h) : CGSizeZero;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: qlthumb OUTDIR FILE...\n");
            return 2;
        }
        NSString *outdir = @(argv[1]);
        [NSFileManager.defaultManager createDirectoryAtPath:outdir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
        printf(".fits maps to %s\n", [UTType typeWithFilenameExtension:@"fits"].identifier.UTF8String);
        int failures = 0;
        for (int i = 2; i < argc; i++)
          for (int scale = 1; scale <= 2; scale++) {
            NSURL *url = [NSURL fileURLWithPath:@(argv[i])];
            NSString *name = scale == 1 ? url.lastPathComponent
                                        : [url.lastPathComponent stringByAppendingString:@"@2x"];
            UTType *type = nil;
            [url getResourceValue:&type forKey:NSURLContentTypeKey error:nil];
            QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc]
                  initWithFileAtURL:url
                               size:CGSizeMake(256, 256)
                              scale:scale
                representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block QLThumbnailRepresentation *rep = nil;
            __block NSError *error = nil;
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            [QLThumbnailGenerator.sharedGenerator
                generateBestRepresentationForRequest:req
                                   completionHandler:^(QLThumbnailRepresentation *r, NSError *e) {
                                       rep = r;
                                       error = e;
                                       dispatch_semaphore_signal(done);
                                   }];
            long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
            double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
            const char *tname = type ? type.identifier.UTF8String : "?";
            if (timedOut || !rep) {
                printf("FAIL %s: %s (type %s)\n", name.UTF8String,
                       timedOut ? "timed out" : error.description.UTF8String, tname);
                failures++;
                continue;
            }
            CGImageRef cg = rep.CGImage;
            NSString *png = [outdir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
            CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
                (__bridge CFURLRef)[NSURL fileURLWithPath:png], CFSTR("public.png"), 1, NULL);
            if (dest) {
                CGImageDestinationAddImage(dest, cg, NULL);
                CGImageDestinationFinalize(dest);
                CFRelease(dest);
            }
            CGSize drawn = drawnPart(cg);
            BOOL ok = rep.type == QLThumbnailRepresentationTypeThumbnail && drawn.width > 0.9 && drawn.height > 0.9;
            printf("%s %s: %zux%zu in %.0f ms, drawn on %.0f%% x %.0f%% of it (type %s)\n", ok ? "ok  " : "FAIL",
                   name.UTF8String, CGImageGetWidth(cg), CGImageGetHeight(cg), ms, drawn.width * 100,
                   drawn.height * 100, tname);
            if (!ok)
                failures++;
        }
        return failures ? 1 : 0;
    }
}
