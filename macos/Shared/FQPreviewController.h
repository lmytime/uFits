// FQPreviewController.h - the preview UI: an image or a plot, a table's
// rows, or the headers, with an info bar holding the HDU, cube plane and
// stretch controls. Used by the Quick Look preview extension and by the
// app's viewer windows.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface FQPreviewController : NSViewController

/// Longest side of the rendered image, in pixels.
@property(nonatomic) int maxPixels;

/// Suggested content size for the file shown, in points.
@property(nonatomic, readonly) NSSize fittingContentSize;

/// Renders path in the background and calls completion on the main queue.
- (void)loadFile:(NSString *)path completion:(nullable void (^)(void))completion;

/// Called with the new version when "Update available" in the bar is
/// clicked. When unset (in Quick Look), the uFits app is asked to update
/// (ufits://update), or else the release page opens.
@property(nonatomic, copy, nullable) void (^updateAction)(NSString *version);

@end

NS_ASSUME_NONNULL_END
