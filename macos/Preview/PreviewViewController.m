// PreviewViewController.m - principal class of the Quick Look preview
// extension (press Space on a FITS or XISF file in Finder).

#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>

#import "FQPreviewController.h"

#include <string.h>

@interface PreviewViewController : FQPreviewController <QLPreviewingController>
@end

@implementation PreviewViewController

/// Whether the file starts as FITS or XISF does (or is gzipped). Some
/// extensions uFits claims are used for other files too (.img: disk
/// images): Quick Look shows those as it would without uFits.
static BOOL FQLooksLikeImageFile(NSString *path)
{
    NSFileHandle *f = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *head = [f readDataOfLength:9];
    [f closeFile];
    const uint8_t *b = head.bytes;
    return (head.length == 9 && !memcmp(b, "SIMPLE  =", 9)) ||
           (head.length >= 8 && !memcmp(b, "XISF0100", 8)) ||
           (head.length >= 2 && b[0] == 0x1f && b[1] == 0x8b);
}

- (void)preparePreviewOfFileAtURL:(NSURL *)url
                completionHandler:(void (^)(NSError *_Nullable))handler
{
    NSString *path = url.path;
    if (!FQLooksLikeImageFile(path)) {
        handler([NSError errorWithDomain:@"uFits" code:2 userInfo:@{NSLocalizedDescriptionKey : @"not a FITS or XISF file"}]);
        return;
    }
    void (^start)(void) = ^{
        [self loadFile:path
            completion:^{
                handler(nil);
            }];
    };
    if (NSThread.isMainThread)
        start();
    else
        dispatch_async(dispatch_get_main_queue(), start);
}

@end
