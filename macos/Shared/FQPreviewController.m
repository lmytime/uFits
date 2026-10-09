// FQPreviewController.m - the preview UI shared by the Quick Look preview
// extension and the app. Everything is built in code; there are no nibs.

#import "FQPreviewController.h"

#import <QuartzCore/QuartzCore.h>

#import "FQRender.h"

#include <math.h>

static NSString *const kStretchDefaultsKey = @"stretch";
static const CGFloat kBarHeight = 30;

#pragma mark - Image view

/// Shows a CGImage scaled to fit, keeping pixels crisp when enlarged.
@interface FQImageView : NSView
@property(nonatomic, nullable) CGImageRef image;
@end

@implementation FQImageView {
    CGImageRef _image;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    }
    return self;
}

- (BOOL)wantsUpdateLayer
{
    return YES;
}

- (void)updateLayer
{
    CALayer *layer = self.layer;
    layer.contentsGravity = kCAGravityResizeAspect;
    layer.magnificationFilter = kCAFilterNearest;
    layer.minificationFilter = kCAFilterTrilinear;
    layer.contents = (__bridge id)_image;
}

- (CGImageRef)image
{
    return _image;
}

- (void)setImage:(CGImageRef)image
{
    if (image)
        CGImageRetain(image);
    if (_image)
        CGImageRelease(_image);
    _image = image;
    self.needsDisplay = YES;
}

- (void)dealloc
{
    if (_image)
        CGImageRelease(_image);
}

@end

#pragma mark - Spectrum view

static NSArray<NSNumber *> *FQNiceTicks(double lo, double hi, int target)
{
    double span = hi - lo;
    if (!(span > 0) || !isfinite(span))
        return @[];
    double raw = span / target, mag = pow(10, floor(log10(raw))), norm = raw / mag;
    double step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag;
    NSMutableArray<NSNumber *> *ticks = [NSMutableArray array];
    for (double t = ceil(lo / step) * step; t <= hi + step * 1e-6 && ticks.count < 40; t += step)
        [ticks addObject:@(fabs(t) < step * 1e-6 ? 0.0 : t)];
    return ticks;
}

/// Plots a spectrum with labelled axes.
@interface FQSpectrumView : NSView
@property(nonatomic, strong, nullable) FQRendering *rendering;
@end

@implementation FQSpectrumView

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    FQRendering *r = self.rendering;
    if (!r || r.kind != FQ_KIND_SPECTRUM)
        return;
    const fq_image *img = r.raw;
    NSRect b = self.bounds;
    NSRect plot = NSMakeRect(NSMinX(b) + 70, NSMinY(b) + 36, MAX(20, NSWidth(b) - 88),
                             MAX(20, NSHeight(b) - 52));
    NSDictionary *attrs = @{
        NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : NSColor.secondaryLabelColor
    };

    [NSColor.separatorColor setStroke];
    NSBezierPath *frame = [NSBezierPath bezierPathWithRect:NSInsetRect(plot, -0.5, -0.5)];
    frame.lineWidth = 1;
    [frame stroke];

    [NSColor.secondaryLabelColor setFill];
    double ylo = img->y_min, yhi = img->y_max;
    for (NSNumber *n in FQNiceTicks(ylo, yhi, 6)) {
        double t = n.doubleValue;
        CGFloat y = NSMinY(plot) + (CGFloat)((t - ylo) / (yhi - ylo)) * NSHeight(plot);
        NSString *label = [NSString stringWithFormat:@"%.4g", t];
        NSSize sz = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(NSMinX(plot) - 6 - sz.width, y - sz.height / 2)
            withAttributes:attrs];
        NSRectFill(NSMakeRect(NSMinX(plot) - 3, y - 0.5, 3, 1));
    }
    double x0 = 0, x1 = (double)(img->spec_points > 1 ? img->spec_points - 1 : 1);
    if (img->has_x && isfinite(img->x_first) && isfinite(img->x_last) && img->x_last != img->x_first) {
        x0 = img->x_first;
        x1 = img->x_last;
    }
    double xlo = MIN(x0, x1), xhi = MAX(x0, x1);
    for (NSNumber *n in FQNiceTicks(xlo, xhi, 8)) {
        double t = n.doubleValue;
        CGFloat x = NSMinX(plot) + (CGFloat)((t - x0) / (x1 - x0)) * NSWidth(plot);
        NSString *label = [NSString stringWithFormat:@"%.6g", t];
        NSSize sz = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(x - sz.width / 2, NSMinY(plot) - 6 - sz.height)
            withAttributes:attrs];
        NSRectFill(NSMakeRect(x - 0.5, NSMinY(plot) - 3, 1, 3));
    }
    NSString *xunit = img->has_x ? FQString(img->x_unit) : @"pixel";
    if (img->x_log)
        xunit = [NSString stringWithFormat:@"log %@", xunit];
    NSString *yunit = FQString(img->y_unit);
    if (xunit.length) {
        NSSize sz = [xunit sizeWithAttributes:attrs];
        [xunit drawAtPoint:NSMakePoint(NSMaxX(plot) - sz.width, NSMinY(b) + 2) withAttributes:attrs];
    }
    if (yunit.length)
        [yunit drawAtPoint:NSMakePoint(NSMinX(b) + 4, NSMaxY(plot) + 2) withAttributes:attrs];

    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    FQDrawSpectrum(ctx, NSInsetRect(plot, 1, 1), img, 1.0, NSColor.labelColor.CGColor);
}

@end

#pragma mark - Controller

@implementation FQPreviewController {
    FQImageView *_imageView;
    FQSpectrumView *_spectrumView;
    NSScrollView *_headerScroll;
    NSTextView *_headerText;
    NSTextField *_message;
    NSTextField *_info;
    NSPopUpButton *_stretchMenu;
    NSSegmentedControl *_mode;
    NSString *_path;
    FQRendering *_rendering;
    BOOL _headerLoaded;
    NSInteger _generation;
    NSSize _fitting;
}

- (instancetype)initWithNibName:(NSNibName)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if ((self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil])) {
        _maxPixels = 2560;
        _fitting = NSMakeSize(800, 600);
    }
    return self;
}

- (void)loadView
{
    const NSRect all = NSMakeRect(0, 0, 800, 600);
    const NSRect content = NSMakeRect(0, kBarHeight, 800, 600 - kBarHeight);
    NSView *root = [[NSView alloc] initWithFrame:all];

    _imageView = [[FQImageView alloc] initWithFrame:content];
    _imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:_imageView];

    _spectrumView = [[FQSpectrumView alloc] initWithFrame:content];
    _spectrumView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _spectrumView.hidden = YES;
    [root addSubview:_spectrumView];

    _headerScroll = [[NSScrollView alloc] initWithFrame:content];
    _headerScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _headerScroll.hasVerticalScroller = YES;
    _headerScroll.hasHorizontalScroller = YES;
    _headerScroll.autohidesScrollers = YES;
    _headerScroll.borderType = NSNoBorder;
    NSSize cs = _headerScroll.contentSize;
    _headerText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, cs.width, cs.height)];
    _headerText.editable = NO;
    _headerText.selectable = YES;
    _headerText.richText = NO;
    _headerText.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _headerText.textColor = NSColor.textColor;
    _headerText.backgroundColor = NSColor.textBackgroundColor;
    _headerText.textContainerInset = NSMakeSize(8, 8);
    _headerText.minSize = NSMakeSize(0, cs.height);
    _headerText.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    _headerText.verticallyResizable = YES;
    _headerText.horizontallyResizable = YES;
    _headerText.autoresizingMask = NSViewWidthSizable;
    _headerText.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    _headerText.textContainer.widthTracksTextView = NO;
    _headerScroll.documentView = _headerText;
    _headerScroll.hidden = YES;
    [root addSubview:_headerScroll];

    _message = [NSTextField wrappingLabelWithString:@""];
    _message.frame = NSInsetRect(content, 40, 40);
    _message.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _message.alignment = NSTextAlignmentCenter;
    _message.textColor = NSColor.secondaryLabelColor;
    _message.hidden = YES;
    [root addSubview:_message];

    _mode = [NSSegmentedControl segmentedControlWithLabels:@[ @"Image", @"Header" ]
                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                    target:self
                                                    action:@selector(modeChanged:)];
    _mode.controlSize = NSControlSizeSmall;
    _mode.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _mode.selectedSegment = 0;
    [_mode sizeToFit];
    NSSize ms = _mode.frame.size;
    _mode.frame = NSMakeRect(NSWidth(all) - ms.width - 10, floor((kBarHeight - ms.height) / 2),
                             ms.width, ms.height);
    _mode.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [root addSubview:_mode];

    _stretchMenu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _stretchMenu.controlSize = NSControlSizeSmall;
    _stretchMenu.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [_stretchMenu addItemsWithTitles:@[ @"Auto stretch", @"Linear 0.5–99.5%", @"Min – max" ]];
    _stretchMenu.target = self;
    _stretchMenu.action = @selector(stretchChanged:);
    [_stretchMenu sizeToFit];
    NSSize ps = _stretchMenu.frame.size;
    _stretchMenu.frame = NSMakeRect(NSMinX(_mode.frame) - ps.width - 8,
                                    floor((kBarHeight - ps.height) / 2), ps.width, ps.height);
    _stretchMenu.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [root addSubview:_stretchMenu];

    _info = [NSTextField labelWithString:@""];
    _info.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _info.textColor = NSColor.secondaryLabelColor;
    _info.lineBreakMode = NSLineBreakByTruncatingMiddle;
    CGFloat ih = 16;
    _info.frame = NSMakeRect(10, floor((kBarHeight - ih) / 2), NSMinX(_stretchMenu.frame) - 18, ih);
    _info.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [root addSubview:_info];

    self.view = root;
}

- (NSSize)fittingContentSize
{
    return _fitting;
}

- (int)currentStretch
{
    NSInteger s = [NSUserDefaults.standardUserDefaults integerForKey:kStretchDefaultsKey];
    return (s >= FQ_STRETCH_AUTO && s <= FQ_STRETCH_MINMAX) ? (int)s : FQ_STRETCH_AUTO;
}

- (void)loadFile:(NSString *)path completion:(void (^)(void))completion
{
    (void)self.view;
    _path = [path copy];
    _headerLoaded = NO;
    int stretch = [self currentStretch];
    [_stretchMenu selectItemAtIndex:stretch];
    int maxPixels = _maxPixels;
    NSInteger generation = ++_generation;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        FQRendering *r = [FQRendering renderFile:path
                                       maxPixels:maxPixels
                                         samples:4
                                         stretch:stretch
                                           error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == self->_generation)
                [self showRendering:r error:error];
            if (completion)
                completion();
        });
    });
}

- (void)showRendering:(FQRendering *)r error:(NSString *)error
{
    _rendering = r;
    int kind = r ? r.kind : FQ_KIND_NONE;
    _imageView.image = kind == FQ_KIND_IMAGE ? r.image : NULL;
    _spectrumView.rendering = kind == FQ_KIND_SPECTRUM ? r : nil;
    _spectrumView.needsDisplay = YES;
    if (r) {
        fq_info in = r.info;
        _info.stringValue = r.summary;
        _info.toolTip = kind == FQ_KIND_IMAGE
                            ? [NSString stringWithFormat:@"median %.6g   σ %.4g   display range %.6g … %.6g",
                                                         in.median, in.sigma, in.black, in.white]
                            : nil;
    } else {
        _info.stringValue = error.length ? error : @"No image";
        _info.toolTip = nil;
    }
    _message.stringValue = error.length ? error : @"";

    CGSize px = r ? r.pixelSize : CGSizeMake(800, 600);
    CGFloat w = MAX(px.width, 1), h = MAX(px.height, 1);
    CGFloat s = MIN(1000 / w, 720 / h);
    if (MAX(w, h) * s < 480)
        s = 480 / MAX(w, h);
    _fitting = NSMakeSize(MAX(round(w * s), 360), round(h * s) + kBarHeight);
    self.preferredContentSize = _fitting;

    // Files without a picture (tables, unsupported data) open on the header.
    BOOL header = kind == FQ_KIND_NONE;
    _mode.selectedSegment = header ? 1 : 0;
    [self showHeader:header];
}

- (void)showHeader:(BOOL)header
{
    int kind = _rendering ? _rendering.kind : FQ_KIND_NONE;
    _headerScroll.hidden = !header;
    _imageView.hidden = header || kind != FQ_KIND_IMAGE;
    _spectrumView.hidden = header || kind != FQ_KIND_SPECTRUM;
    _message.hidden = YES;
    _stretchMenu.hidden = header || kind != FQ_KIND_IMAGE;
    if (header && !_headerLoaded && _path) {
        _headerLoaded = YES;
        _headerText.string = @"";
        NSString *path = _path;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *text = FQHeaderListing(path);
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([path isEqualToString:self->_path])
                    self->_headerText.string = text;
            });
        });
    }
}

- (void)modeChanged:(id)sender
{
    (void)sender;
    [self showHeader:_mode.selectedSegment == 1];
}

- (void)stretchChanged:(id)sender
{
    (void)sender;
    NSInteger stretch = _stretchMenu.indexOfSelectedItem;
    [NSUserDefaults.standardUserDefaults setInteger:stretch forKey:kStretchDefaultsKey];
    if (_path)
        [self loadFile:_path completion:nil];
}

@end
