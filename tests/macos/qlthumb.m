// qlthumb - ask Quick Look for thumbnails the way Finder does (through
// QLThumbnailGenerator, so the installed extension is used) and save them,
// at scale 1 and at scale 2, as on a Retina screen.
//
// Usage: qlthumb [--icon] [--size POINTS] [--none] OUTDIR FILE...
//        qlthumb --corner IMAGE...
// Exits non-zero if any file does not get a real thumbnail, or one that
// does not fill its bitmap (as one drawn at scale 1 in a scale 2 bitmap)
// or has fewer pixels than its size times the scale, or, for files named
// orient-ll-* or orient-ul-* (tests/macos/make_orient_files.py), one whose
// bright block is not in the lower or upper left corner. --icon asks for
// Finder's icons (iconMode: Quick Look may frame them); --size for another
// size than 256 points; --none checks that no thumbnail comes (icons too
// small for one keep the file's icon). --corner only says where the bright
// block of each image file is.

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

/// The brightest corner of img: "ll", "ul", "lr" or "ur" (lower or upper,
/// left or right), comparing the mean grey of a square in each corner of
/// the drawn part, 10% to 35% in from its edges (clear of any frame).
static NSString *brightCorner(CGImageRef img)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    uint8_t *px = calloc(w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    // Rows of px run from the top of the image down.
    size_t x0 = w, x1 = 0, y0 = h, y1 = 0;
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w; x++)
            if (px[(y * w + x) * 4 + 3]) {
                x0 = MIN(x0, x), x1 = MAX(x1, x + 1);
                y0 = MIN(y0, y), y1 = MAX(y1, y + 1);
            }
    NSString *best = @"?";
    double bestGrey = -1;
    for (int top = 0; top < 2 && x1 > x0; top++)
        for (int left = 0; left < 2; left++) {
            size_t bw = x1 - x0, bh = y1 - y0;
            size_t ya = top ? y0 + bh / 10 : y1 - bh * 35 / 100, yb = top ? y0 + bh * 35 / 100 : y1 - bh / 10;
            size_t xa = left ? x0 + bw / 10 : x1 - bw * 35 / 100, xb = left ? x0 + bw * 35 / 100 : x1 - bw / 10;
            double sum = 0;
            size_t n = 0;
            for (size_t y = ya; y < yb; y++)
                for (size_t x = xa; x < xb; x++, n++) {
                    const uint8_t *p = px + (y * w + x) * 4;
                    sum += (p[0] + p[1] + p[2]) / 3.0;
                }
            if (n && sum / n > bestGrey) {
                bestGrey = sum / n;
                best = [NSString stringWithFormat:@"%s%s", top ? "u" : "l", left ? "l" : "r"];
            }
        }
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(px);
    return best;
}

/// The corner the bright block of a file named orient-XX-* belongs in, or nil.
static NSString *wantedCorner(NSString *name)
{
    NSRange r = [name rangeOfString:@"orient-"];
    return r.location == NSNotFound || name.length < NSMaxRange(r) + 2
               ? nil
               : [name substringWithRange:NSMakeRange(NSMaxRange(r), 2)];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        int first = 1;
        BOOL icon = NO, none = NO;
        double points = 256;
        if (argc > 1 && !strcmp(argv[1], "--corner")) {
            int failures = 0;
            for (int i = 2; i < argc; i++) {
                NSURL *url = [NSURL fileURLWithPath:@(argv[i])];
                CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
                CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
                NSString *corner = img ? brightCorner(img) : @"?", *want = wantedCorner(url.lastPathComponent);
                BOOL ok = img && (!want || [corner isEqualToString:want]);
                printf("%s %s: bright block in the %s corner%s%s\n", ok ? "ok  " : "FAIL", argv[i],
                       corner.UTF8String, want ? ", wanted " : "", want ? want.UTF8String : "");
                failures += !ok;
                if (img)
                    CGImageRelease(img);
                if (src)
                    CFRelease(src);
            }
            return failures ? 1 : 0;
        }
        for (; first < argc && !strncmp(argv[first], "--", 2); first++) {
            if (!strcmp(argv[first], "--icon"))
                icon = YES;
            else if (!strcmp(argv[first], "--none"))
                none = YES;
            else if (!strcmp(argv[first], "--size") && first + 1 < argc)
                points = atof(argv[++first]);
            else
                break;
        }
        if (argc < first + 2 || points < 1 || !strncmp(argv[first], "--", 2)) {
            fprintf(stderr, "usage: qlthumb [--icon] [--size POINTS] [--none] OUTDIR FILE...\n"
                            "       qlthumb --corner IMAGE...\n");
            return 2;
        }
        NSString *outdir = @(argv[first]);
        [NSFileManager.defaultManager createDirectoryAtPath:outdir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
        printf(".fits maps to %s\n", [UTType typeWithFilenameExtension:@"fits"].identifier.UTF8String);
        int failures = 0;
        for (int i = first + 1; i < argc; i++)
          for (int scale = 1; scale <= 2; scale++) {
            NSURL *url = [NSURL fileURLWithPath:@(argv[i])];
            NSString *name = [url.lastPathComponent stringByAppendingString:icon ? @"-icon" : @""];
            if (scale == 2)
                name = [name stringByAppendingString:@"@2x"];
            UTType *type = nil;
            [url getResourceValue:&type forKey:NSURLContentTypeKey error:nil];
            QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc]
                  initWithFileAtURL:url
                               size:CGSizeMake(points, points)
                              scale:scale
                representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
            req.iconMode = icon;
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
            if (none) {
                BOOL ok = !timedOut && (!rep || rep.type != QLThumbnailRepresentationTypeThumbnail);
                printf("%s %s: %s at %g points (type %s)\n", ok ? "ok  " : "FAIL", name.UTF8String,
                       ok ? "no thumbnail" : timedOut ? "timed out" : "a thumbnail", points, tname);
                failures += !ok;
                continue;
            }
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
            NSString *corner = brightCorner(cg), *want = wantedCorner(name);
            // As sharp as the screen: not a scale 1 image in a scale 2 icon.
            BOOL sharp = MAX(CGImageGetWidth(cg), CGImageGetHeight(cg)) >= 0.95 * points * scale;
            BOOL ok = rep.type == QLThumbnailRepresentationTypeThumbnail && sharp &&
                      (icon || (drawn.width > 0.9 && drawn.height > 0.9)) &&
                      (!want || [corner isEqualToString:want]);
            printf("%s %s: %zux%zu in %.0f ms, drawn on %.0f%% x %.0f%% of it (type %s)%s%s%s%s\n",
                   ok ? "ok  " : "FAIL", name.UTF8String, CGImageGetWidth(cg), CGImageGetHeight(cg), ms,
                   drawn.width * 100, drawn.height * 100, tname, want ? ", bright block " : "",
                   want ? corner.UTF8String : "", want ? " (wanted " : "", want ? [want stringByAppendingString:@")"].UTF8String : "");
            if (!ok)
                failures++;
        }
        return failures ? 1 : 0;
    }
}
