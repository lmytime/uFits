// qlthumb - ask Quick Look for thumbnails the way Finder does (through
// QLThumbnailGenerator, so the installed extension is used) and save them.
//
// Usage: qlthumb OUTDIR FILE...
// Exits non-zero if any file does not get a real thumbnail.

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
        for (int i = 2; i < argc; i++) {
            NSURL *url = [NSURL fileURLWithPath:@(argv[i])];
            NSString *name = url.lastPathComponent;
            UTType *type = nil;
            [url getResourceValue:&type forKey:NSURLContentTypeKey error:nil];
            QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc]
                  initWithFileAtURL:url
                               size:CGSizeMake(256, 256)
                              scale:1
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
            BOOL ok = rep.type == QLThumbnailRepresentationTypeThumbnail;
            printf("%s %s: %zux%zu in %.0f ms (type %s)\n", ok ? "ok  " : "FAIL", name.UTF8String,
                   CGImageGetWidth(cg), CGImageGetHeight(cg), ms, tname);
            if (!ok)
                failures++;
        }
        return failures ? 1 : 0;
    }
}
