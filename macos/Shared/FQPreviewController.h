// FQPreviewController.h - the preview UI: image or spectrum plot, an info
// bar, a stretch menu and a header viewer. Used by the Quick Look preview
// extension and by the app's viewer windows.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface FQPreviewController : NSViewController

/// Longest side of the rendered image, in pixels.
@property(nonatomic) int maxPixels;

/// Suggested content size for the file shown, in points.
@property(nonatomic, readonly) NSSize fittingContentSize;

/// Renders path in the background and calls completion on the main queue.
- (void)loadFile:(NSString *)path completion:(nullable void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
