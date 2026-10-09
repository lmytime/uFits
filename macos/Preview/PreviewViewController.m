// PreviewViewController.m - principal class of the Quick Look preview
// extension (press Space on a FITS file in Finder).

#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>

#import "FQPreviewController.h"

@interface PreviewViewController : FQPreviewController <QLPreviewingController>
@end

@implementation PreviewViewController

- (void)preparePreviewOfFileAtURL:(NSURL *)url
                completionHandler:(void (^)(NSError *_Nullable))handler
{
    NSString *path = url.path;
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
