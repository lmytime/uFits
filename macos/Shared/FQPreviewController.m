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

#pragma mark - Plot view

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

/// "LABEL [unit]", or whichever of the two there is.
static NSString *FQAxisTitle(const char *label, const char *unit)
{
    NSString *l = FQString(label), *u = FQString(unit);
    if (l.length && u.length)
        return [NSString stringWithFormat:@"%@ [%@]", l, u];
    return l.length ? l : u;
}

/// Plots a spectrum or a light curve with labelled axes.
@interface FQSpectrumView : NSView
@property(nonatomic, strong, nullable) FQRendering *rendering;
@end

@implementation FQSpectrumView

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    FQRendering *r = self.rendering;
    if (!r || r.kind != FQ_KIND_PLOT)
        return;
    const fq_image *img = r.raw;
    NSRect b = self.bounds;
    NSRect plot = NSMakeRect(NSMinX(b) + 70, NSMinY(b) + 36, MAX(20, NSWidth(b) - 88),
                             MAX(20, NSHeight(b) - 56));
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
    BOOL flip = img->y_flip != 0;   // magnitudes: small values (bright) on top
    for (NSNumber *n in FQNiceTicks(ylo, yhi, 6)) {
        double t = n.doubleValue;
        CGFloat k = (CGFloat)((t - ylo) / (yhi - ylo)) * NSHeight(plot);
        CGFloat y = flip ? NSMaxY(plot) - k : NSMinY(plot) + k;
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
        CGFloat k = (CGFloat)((t - x0) / (x1 - x0)) * NSWidth(plot);
        CGFloat x = img->x_flip ? NSMaxX(plot) - k : NSMinX(plot) + k;   // RA grows leftwards
        double v = t;
        if (img->x_wrap) {   // a field across RA = 0: label -10 as 350
            v = fmod(t, 360.0);
            if (v < 0)
                v += 360;
        }
        NSString *label = [NSString stringWithFormat:@"%.6g", v];
        NSSize sz = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(x - sz.width / 2, NSMinY(plot) - 6 - sz.height)
            withAttributes:attrs];
        NSRectFill(NSMakeRect(x - 0.5, NSMinY(plot) - 3, 1, 3));
    }
    NSString *xtitle = img->has_x ? FQAxisTitle(img->x_label, img->x_unit) : @"pixel";
    if (img->x_log)
        xtitle = [@"log " stringByAppendingString:xtitle];
    NSString *ytitle = FQAxisTitle(img->y_label, img->y_unit);
    if (xtitle.length) {
        NSSize sz = [xtitle sizeWithAttributes:attrs];
        [xtitle drawAtPoint:NSMakePoint(NSMaxX(plot) - sz.width, NSMinY(b) + 2) withAttributes:attrs];
    }
    if (ytitle.length)
        [ytitle drawAtPoint:NSMakePoint(NSMinX(b) + 4, NSMaxY(plot) + 4) withAttributes:attrs];

    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    FQDrawSpectrum(ctx, NSInsetRect(plot, 1, 1), img, 1.0, NSColor.labelColor.CGColor);
}

@end

#pragma mark - Root view

/// The segments of the mode switch.
enum { kModePicture = 0, kModeTable = 1, kModeHeader = 2 };

@interface FQPreviewController () <NSTableViewDataSource, NSTableViewDelegate>
- (void)layoutBar;
- (BOOL)handleKeyEquivalent:(NSEvent *)event;
@end

/// Lays out the bar when resized, and gives the header's find bar its keys
/// where there is no menu to do it (in Quick Look).
@interface FQRootView : NSView
@property(nonatomic, weak) FQPreviewController *controller;
@end

@implementation FQRootView

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    [super resizeSubviewsWithOldSize:oldSize];
    [self.controller layoutBar];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    return [self.controller handleKeyEquivalent:event] || [super performKeyEquivalent:event];
}

@end

#pragma mark - Controller

@implementation FQPreviewController {
    FQImageView *_imageView;
    FQSpectrumView *_spectrumView;
    NSScrollView *_headerScroll;
    NSTextView *_headerText;
    NSScrollView *_tableScroll;
    NSTableView *_tableView;
    NSFont *_cellFont;
    NSTextField *_message;
    NSTextField *_info;
    NSPopUpButton *_stretchMenu;
    NSPopUpButton *_hduMenu;
    NSView *_planeBox;
    NSSlider *_planeSlider;
    NSTextField *_planeLabel;
    NSSegmentedControl *_mode;
    NSString *_path;
    FQRendering *_rendering;
    NSString *_renderInfo, *_renderTip;   // the bar's text for the picture
    NSArray<FQHDUItem *> *_hdus;
    int _hdu;             // HDU asked for, -1 = automatic
    long long _plane;     // cube plane asked for, -1 = automatic
    int _selected;        // HDU picked in the menu (drawn or listed), -1 = none
    fq_file *_tableFile;  // open while its table is in the table view
    fq_table *_table;
    int _tableHDU;        // HDU in the table view, -1 = none
    BOOL _headerLoaded, _headerReady;   // listing asked for; in the text view
    int _headerTarget;    // HDU to scroll the listing to, -1 = none
    BOOL _headerTargetRows;   // to its table rows rather than its cards
    BOOL _busy, _again;   // a render is running; another one is wanted after it
    NSInteger _generation;
    NSSize _fitting;
    CGFloat _hduWidth;    // natural width of the HDU menu
}

- (instancetype)initWithNibName:(NSNibName)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if ((self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil])) {
        _maxPixels = 2560;
        _fitting = NSMakeSize(800, 600);
        _hdu = -1;
        _plane = -1;
        _headerTarget = -1;
        _tableHDU = -1;
        _selected = -1;
    }
    return self;
}

- (void)dealloc
{
    _tableView.dataSource = nil;
    _tableView.delegate = nil;
    fq_table_close(_table);
    fq_close(_tableFile);
}

- (NSPopUpButton *)smallPopUpWithAction:(SEL)action
{
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    p.controlSize = NSControlSizeSmall;
    p.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    p.target = self;
    p.action = action;
    return p;
}

- (NSScrollView *)scrollViewWithFrame:(NSRect)frame
{
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:frame];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sv.hasVerticalScroller = YES;
    sv.hasHorizontalScroller = YES;
    sv.autohidesScrollers = YES;
    sv.borderType = NSNoBorder;
    sv.hidden = YES;
    return sv;
}

- (void)loadView
{
    const NSRect all = NSMakeRect(0, 0, 800, 600);
    const NSRect content = NSMakeRect(0, kBarHeight, 800, 600 - kBarHeight);
    FQRootView *root = [[FQRootView alloc] initWithFrame:all];
    root.controller = self;

    _imageView = [[FQImageView alloc] initWithFrame:content];
    _imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:_imageView];

    _spectrumView = [[FQSpectrumView alloc] initWithFrame:content];
    _spectrumView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _spectrumView.hidden = YES;
    [root addSubview:_spectrumView];

    // Header listing. Non-contiguous layout keeps big listings quick to show.
    _headerScroll = [self scrollViewWithFrame:content];
    NSSize cs = _headerScroll.contentSize;
    _headerText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, cs.width, cs.height)];
    _headerText.editable = NO;
    _headerText.selectable = YES;
    _headerText.richText = NO;
    _headerText.usesFindBar = YES;
    _headerText.incrementalSearchingEnabled = YES;
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
    _headerText.layoutManager.allowsNonContiguousLayout = YES;
    _headerScroll.documentView = _headerText;
    [root addSubview:_headerScroll];

    // Table view: every row of a table, formatted only as it scrolls in.
    _cellFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _tableScroll = [self scrollViewWithFrame:content];
    _tableView = [[NSTableView alloc] initWithFrame:_tableScroll.bounds];
    _tableView.style = NSTableViewStylePlain;
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.gridStyleMask = NSTableViewSolidVerticalGridLineMask;
    _tableView.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    _tableView.allowsMultipleSelection = YES;
    _tableView.rowHeight = 17;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableScroll.documentView = _tableView;
    [root addSubview:_tableScroll];

    _message = [NSTextField wrappingLabelWithString:@""];
    _message.frame = NSInsetRect(content, 40, 40);
    _message.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _message.alignment = NSTextAlignmentCenter;
    _message.textColor = NSColor.secondaryLabelColor;
    _message.hidden = YES;
    [root addSubview:_message];

    // The bar, laid out by -layoutBar: info text on the left; HDU menu,
    // plane slider, stretch menu and the mode switch on the right.
    _mode = [NSSegmentedControl segmentedControlWithLabels:@[ @"Image", @"Table", @"Header" ]
                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                    target:self
                                                    action:@selector(modeChanged:)];
    _mode.controlSize = NSControlSizeSmall;
    _mode.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _mode.selectedSegment = kModePicture;
    [_mode sizeToFit];
    [root addSubview:_mode];

    _stretchMenu = [self smallPopUpWithAction:@selector(stretchChanged:)];
    [_stretchMenu addItemsWithTitles:@[ @"Auto stretch", @"Linear 0.5–99.5%", @"Min – max" ]];
    [_stretchMenu sizeToFit];
    [root addSubview:_stretchMenu];

    _hduMenu = [self smallPopUpWithAction:@selector(hduChanged:)];
    _hduMenu.toolTip = @"HDU to show";
    _hduMenu.hidden = YES;
    [root addSubview:_hduMenu];

    _planeSlider = [NSSlider sliderWithTarget:self action:@selector(planeChanged:)];
    _planeSlider.controlSize = NSControlSizeSmall;
    _planeSlider.continuous = YES;
    _planeSlider.frame = NSMakeRect(0, 2, 130, 18);
    _planeLabel = [NSTextField labelWithString:@""];
    _planeLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize
                                                        weight:NSFontWeightRegular];
    _planeLabel.textColor = NSColor.secondaryLabelColor;
    _planeLabel.frame = NSMakeRect(136, 3, 74, 16);
    _planeBox = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 210, 22)];
    _planeBox.toolTip = @"Cube plane";
    [_planeBox addSubview:_planeSlider];
    [_planeBox addSubview:_planeLabel];
    _planeBox.hidden = YES;
    [root addSubview:_planeBox];

    _info = [NSTextField labelWithString:@""];
    _info.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _info.textColor = NSColor.secondaryLabelColor;
    _info.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [root addSubview:_info];

    self.view = root;
    [self layoutBar];
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

#pragma mark Rendering

- (void)loadFile:(NSString *)path completion:(void (^)(void))completion
{
    (void)self.view;
    _path = [path copy];
    _headerLoaded = _headerReady = NO;
    _headerText.string = @"";
    _headerTarget = -1;
    _hdu = -1;
    _plane = -1;
    _hdus = nil;
    _selected = -1;
    [self closeTable];
    [self render:YES completion:completion];
}

/// Renders _path with the current HDU, plane and stretch, keeping the
/// binned values so a new stretch is quick. The first render of a file
/// also lists its HDUs and sizes the view.
- (void)render:(BOOL)first completion:(void (^)(void))completion
{
    int stretch = [self currentStretch];
    [_stretchMenu selectItemAtIndex:stretch];
    NSString *path = _path;
    int maxPixels = _maxPixels, hdu = _hdu;
    long long plane = _plane;
    NSInteger generation = ++_generation;
    _busy = YES;
    _again = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSArray<FQHDUItem *> *hdus = nil;
        FQRendering *r;
        if (first)
            r = [FQRendering renderFile:path
                              maxPixels:maxPixels
                                samples:4
                                stretch:stretch
                                    hdu:hdu
                                  plane:plane
                                   keep:YES
                                   hdus:&hdus
                                  error:&error];
        else
            r = [FQRendering renderFile:path
                              maxPixels:maxPixels
                                samples:4
                                stretch:stretch
                                    hdu:hdu
                                  plane:plane
                                   keep:YES
                                   hdus:NULL
                                  error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == self->_generation) {
                self->_busy = NO;
                if (first)
                    self->_hdus = hdus;
                [self showRendering:r error:error first:first];
                if (self->_again)
                    [self render:NO completion:nil];
            }
            if (completion)
                completion();
        });
    });
}

/// Renders again with new settings; while a render is running, waits for
/// it and then renders once with the latest settings (slider drags).
- (void)requestRender
{
    if (!_path)
        return;
    if (_busy)
        _again = YES;
    else
        [self render:NO completion:nil];
}

/// The bar's text for the picture: what it shows, display range as tooltip.
- (void)updateRenderInfo:(NSString *)error
{
    FQRendering *r = _rendering;
    if (r) {
        fq_info in = r.info;
        _renderInfo = r.summary;
        _renderTip = r.kind == FQ_KIND_IMAGE
                         ? [NSString stringWithFormat:@"median %.6g   σ %.4g   display range %.6g … %.6g",
                                                      in.median, in.sigma, in.black, in.white]
                         : nil;
    } else {
        _renderInfo = error.length ? error : @"No image";
        _renderTip = nil;
    }
}

- (void)showRendering:(FQRendering *)r error:(NSString *)error first:(BOOL)first
{
    _rendering = r;
    int kind = r ? r.kind : FQ_KIND_NONE;
    _imageView.image = kind == FQ_KIND_IMAGE ? r.image : NULL;
    _spectrumView.rendering = kind == FQ_KIND_PLOT ? r : nil;
    _spectrumView.needsDisplay = YES;
    [self updateRenderInfo:error];
    if (kind == FQ_KIND_IMAGE && r.info.empty)
        _message.stringValue = @"Every pixel of this image is blank (NaN or BLANK).";
    else
        _message.stringValue = error.length ? error : @"";
    NSInteger mode = _mode.selectedSegment;
    if (first) {
        [_hduMenu removeAllItems];
        for (FQHDUItem *item in _hdus) {
            [_hduMenu addItemWithTitle:item.title];
            _hduMenu.lastItem.representedObject = @(item.hdu);
        }
        [_hduMenu sizeToFit];
        _hduWidth = MIN(NSWidth(_hduMenu.frame), 260);

        // Files without a picture open on their first table, or the header.
        _selected = r ? r.info.hdu : -1;
        for (FQHDUItem *item in _hdus)
            if (_selected < 0 && item.kind == FQ_KIND_TABLE)
                _selected = item.hdu;
        mode = r ? kModePicture : kModeTable;
        [self updateModeSwitch];
        _mode.selectedSegment = mode;

        // Fit 1000 x 720 points; small images grow at most 2x, or to 480
        // points. Wide enough for the bar's controls and some info text.
        CGSize px = r ? r.pixelSize : CGSizeMake(800, 600);
        CGFloat w = MAX(px.width, 1), h = MAX(px.height, 1);
        CGFloat s = MIN(MIN(1000 / w, 720 / h), MAX(2.0, 480 / MAX(w, h)));
        CGFloat bar = 20 + NSWidth(_mode.frame) + 8 + 150;
        NSArray<NSView *> *controls = [self barControls];
        BOOL wanted[3];
        [self wantedControls:wanted];
        for (NSUInteger i = 0; i < 3; i++)
            if (wanted[i])
                bar += (i == 0 ? _hduWidth : NSWidth(controls[i].frame)) + 8;
        _fitting = NSMakeSize(MAX(MAX(round(w * s), 360), bar), round(h * s) + kBarHeight);
        self.preferredContentSize = _fitting;

        [self loadHeader];   // in the background, so the Header button is instant
    }
    [self updatePlaneControls];
    [self showMode:mode];
}

#pragma mark Bar

- (BOOL)showsPlaneSlider
{
    if (!_rendering || _rendering.kind != FQ_KIND_IMAGE)
        return NO;
    fq_info in = _rendering.info;
    return in.nplanes > 1 && in.color == FQ_COLOR_MONO;
}

- (void)updatePlaneControls
{
    if (![self showsPlaneSlider])
        return;
    fq_info in = _rendering.info;
    _planeSlider.minValue = 0;
    _planeSlider.maxValue = (double)(in.nplanes - 1);
    if (!_again)   // not while the slider is being dragged further
        _planeSlider.doubleValue = (double)in.plane;
    [self updatePlaneLabel];
}

- (void)updatePlaneLabel
{
    long long n = _rendering ? _rendering.info.nplanes : 0;
    _planeLabel.stringValue =
        [NSString stringWithFormat:@"%lld / %lld", llround(_planeSlider.doubleValue) + 1, n];
}

/// The bar's controls besides the mode switch, most important first: HDU
/// menu, plane slider, stretch menu.
- (NSArray<NSView *> *)barControls
{
    return @[ _hduMenu, _planeBox, _stretchMenu ];
}

/// Which of -barControls the file and the mode call for.
- (void)wantedControls:(BOOL *)wanted
{
    BOOL picture = _mode.selectedSegment == kModePicture;
    wanted[0] = _hdus.count > 1;
    wanted[1] = picture && [self showsPlaneSlider];
    wanted[2] = picture && _rendering && _rendering.kind == FQ_KIND_IMAGE;
}

/// Right to left: the switch, then the stretch menu, plane slider and HDU
/// menu; the info text takes what is left. When the bar is too narrow,
/// the HDU menu shrinks (down to 120 points) and the least important
/// controls are hidden, keeping at least 80 points of info text.
- (void)layoutBar
{
    NSRect b = self.view.bounds;
    NSArray<NSView *> *controls = [self barControls];
    BOOL wanted[3], shown[3];
    [self wantedControls:wanted];
    CGFloat minHDU = MIN(_hduWidth, 120);
    CGFloat room = NSWidth(b) - 20 - NSWidth(_mode.frame) - 8 - 80, used = 0;
    for (NSUInteger i = 0; i < 3; i++) {
        CGFloat w = i == 0 ? minHDU : NSWidth(controls[i].frame);
        shown[i] = wanted[i] && used + w + 8 <= room;
        if (shown[i])
            used += w + 8;
    }
    CGFloat hduWidth = MIN(_hduWidth, minHDU + MAX(0, room - used));

    CGFloat x = NSMaxX(b) - 10;
    NSSize ms = _mode.frame.size;
    _mode.frame = NSMakeRect(x - ms.width, floor((kBarHeight - ms.height) / 2), ms.width, ms.height);
    x -= ms.width + 8;
    for (NSInteger i = 2; i >= 0; i--) {
        NSView *v = controls[(NSUInteger)i];
        v.hidden = !shown[i];
        if (!shown[i])
            continue;
        NSSize sz = v.frame.size;
        if (i == 0)
            sz.width = hduWidth;
        v.frame = NSMakeRect(x - sz.width, floor((kBarHeight - sz.height) / 2), sz.width, sz.height);
        x -= sz.width + 8;
    }
    CGFloat ih = 16;
    _info.frame = NSMakeRect(10, floor((kBarHeight - ih) / 2), MAX(0, x - 10), ih);
}

/// The HDU picked in the menu.
- (FQHDUItem *)selectedItem
{
    for (FQHDUItem *item in _hdus)
        if (item.hdu == _selected)
            return item;
    return nil;
}

/// Picture and Table are on for the HDU picked when it can be drawn, or is
/// a table; Header always is.
- (void)updateModeSwitch
{
    FQHDUItem *item = [self selectedItem];
    BOOL picture = item ? item.kind != FQ_KIND_TABLE : _rendering != nil;
    [_mode setEnabled:picture forSegment:kModePicture];
    [_mode setEnabled:item.isTable forSegment:kModeTable];
    [_mode setLabel:item.kind == FQ_KIND_PLOT ? @"Plot" : @"Image" forSegment:kModePicture];
    [_mode sizeToFit];
}

/// Shows mode: the picture (image or plot), a table's rows, or the header
/// listing, falling back to what the HDU picked has.
- (void)showMode:(NSInteger)mode
{
    [self updateModeSwitch];
    if (![_mode isEnabledForSegment:mode])
        mode = [_mode isEnabledForSegment:kModePicture] ? kModePicture
             : [_mode isEnabledForSegment:kModeTable]   ? kModeTable
                                                          : kModeHeader;
    _mode.selectedSegment = mode;
    int kind = _rendering ? _rendering.kind : FQ_KIND_NONE;
    BOOL picture = mode == kModePicture;
    _headerScroll.hidden = mode != kModeHeader;
    _tableScroll.hidden = mode != kModeTable;
    _imageView.hidden = !picture || kind != FQ_KIND_IMAGE;
    _spectrumView.hidden = !picture || kind != FQ_KIND_PLOT;
    _message.hidden = !picture || _message.stringValue.length == 0 ||
                      (kind != FQ_KIND_NONE && !(kind == FQ_KIND_IMAGE && _rendering.info.empty));
    if (mode == kModeTable)
        [self showTable:_selected];
    if (mode == kModeHeader)
        [self loadHeader];

    NSInteger i = [_hduMenu indexOfItemWithRepresentedObject:@(_selected)];
    if (i >= 0)
        [_hduMenu selectItemAtIndex:i];
    if (mode == kModeTable) {
        _info.stringValue = [self tableSummary];
        _info.toolTip = nil;
    } else {
        _info.stringValue = _renderInfo ?: @"";
        _info.toolTip = _renderTip;
    }
    [self layoutBar];
}

#pragma mark Header listing

/// Builds the header listing in the background, once per file, puts it in
/// the text view and scrolls to the HDU asked for.
- (void)loadHeader
{
    if (_headerLoaded || !_path) {
        [self scrollHeaderToTarget];
        return;
    }
    _headerLoaded = YES;
    NSString *path = _path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *text = FQHeaderListing(path);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![path isEqualToString:self->_path] || self->_headerReady)
                return;
            self->_headerText.string = text;
            self->_headerReady = YES;
            [self scrollHeaderToTarget];
        });
    });
}

/// Scrolls the header listing to the rows of table _headerTarget, or to
/// its header cards, once the listing is there and on screen.
- (void)scrollHeaderToTarget
{
    if (!_headerReady || _headerTarget < 0 || _headerScroll.hidden)
        return;
    NSString *text = _headerText.string;
    NSRange r = NSMakeRange(NSNotFound, 0);
    if (_headerTargetRows)
        r = [text rangeOfString:[NSString stringWithFormat:@"——— HDU %d table ———", _headerTarget]];
    if (r.location == NSNotFound)   // also when the listing was cut short
        r = [text rangeOfString:[NSString stringWithFormat:@"——— HDU %d ———", _headerTarget]];
    _headerTarget = -1;
    if (r.location == NSNotFound)
        return;
    // Lay out (and size the view for) the text down to a screenful past the
    // target first, or the scroll stops short where layout has got to.
    NSLayoutManager *lm = _headerText.layoutManager;
    [lm ensureLayoutForCharacterRange:NSMakeRange(0, MIN(text.length, NSMaxRange(r) + 20000))];
    [_headerText sizeToFit];
    NSRange glyphs = [lm glyphRangeForCharacterRange:r actualCharacterRange:NULL];
    NSRect box = [lm boundingRectForGlyphRange:glyphs inTextContainer:_headerText.textContainer];
    CGFloat y = NSMinY(box) + _headerText.textContainerOrigin.y - 6;
    [_headerText scrollPoint:NSMakePoint(0, MAX(0, y))];
    [_headerText showFindIndicatorForRange:r];
}

#pragma mark Table view

- (void)closeTable
{
    fq_table_close(_table);
    fq_close(_tableFile);
    _table = NULL;
    _tableFile = NULL;
    _tableHDU = -1;
    for (NSTableColumn *column in [_tableView.tableColumns copy])
        [_tableView removeTableColumn:column];
    [_tableView reloadData];
}

/// Puts table hdu in the table view. Opening a table reads its header only
/// (a gzip file is inflated as far as the table); cells are formatted as
/// they scroll into view.
- (void)showTable:(int)hdu
{
    if (_table && _tableHDU == hdu)
        return;
    [self closeTable];
    char err[256] = "";
    _tableFile = fq_open(_path.fileSystemRepresentation, err, sizeof err);
    _table = _tableFile ? fq_table_open(_tableFile, hdu) : NULL;
    if (!_table) {
        fq_close(_tableFile);
        _tableFile = NULL;
        return;
    }
    _tableHDU = hdu;
    NSDictionary *attrs = @{NSFontAttributeName : _cellFont};
    CGFloat digit = [@"0" sizeWithAttributes:attrs].width;
    int64_t nrows = fq_table_rows(_table), sample = MIN(nrows, (int64_t)50);
    NSTableColumn *num = [[NSTableColumn alloc] initWithIdentifier:@"#"];
    num.title = @"#";
    num.width = ceil(digit * (CGFloat)[NSString stringWithFormat:@"%lld", (long long)MAX(nrows, 1)].length) + 14;
    num.headerCell.alignment = NSTextAlignmentRight;
    [_tableView addTableColumn:num];
    int nc = fq_table_ncols(_table);
    for (int c = 0; c < nc && c < 1000; c++) {
        const fq_column *ci = fq_table_column(_table, c);
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%d", c]];
        column.title = FQString(ci->name);
        NSString *unit = FQString(ci->unit), *form = FQString(ci->form);
        column.headerToolTip = unit.length ? [NSString stringWithFormat:@"%@  [%@]", form, unit] : form;
        size_t chars = column.title.length;   // as wide as the first rows need
        char cell[200];
        for (int64_t r = 0; r < sample; r++) {
            fq_table_cell(_table, r, c, cell, sizeof cell);
            chars = MAX(chars, strlen(cell));
        }
        column.width = MIN(MAX(ceil(digit * (CGFloat)chars) + 14, 40), 420);
        column.minWidth = 24;
        column.headerCell.alignment = ci->numeric ? NSTextAlignmentRight : NSTextAlignmentLeft;
        [_tableView addTableColumn:column];
    }
    [_tableView reloadData];
    [_tableView scrollRowToVisible:0];
}

- (NSString *)tableSummary
{
    if (!_table)
        return @"Cannot read this table";
    NSString *ext = @"";
    for (FQHDUItem *item in _hdus)
        if (item.hdu == _tableHDU)
            ext = item.extname;
    long long rows = fq_table_rows(_table);
    int cols = fq_table_ncols(_table);
    return [NSString stringWithFormat:@"HDU %d%@%@  ·  %lld row%@ × %d column%@", _tableHDU,
                                      ext.length ? @" " : @"", ext, rows, rows == 1 ? @"" : @"s",
                                      cols, cols == 1 ? @"" : @"s"];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return (NSInteger)fq_table_rows(_table);
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSTextField *field = [tableView makeViewWithIdentifier:@"cell" owner:self];
    if (!field) {
        field = [NSTextField labelWithString:@""];
        field.identifier = @"cell";
        field.font = _cellFont;
        field.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    if ([column.identifier isEqualToString:@"#"]) {
        field.stringValue = [NSString stringWithFormat:@"%ld", (long)row + 1];
        field.alignment = NSTextAlignmentRight;
        field.textColor = NSColor.tertiaryLabelColor;
        return field;
    }
    int c = column.identifier.intValue;
    char cell[200];
    fq_table_cell(_table, row, c, cell, sizeof cell);
    const fq_column *ci = fq_table_column(_table, c);
    field.stringValue = FQString(cell);
    field.alignment = ci && ci->numeric ? NSTextAlignmentRight : NSTextAlignmentLeft;
    field.textColor = NSColor.labelColor;
    return field;
}

/// Copies the selected rows as tab-separated text, with a line of column
/// names first.
- (void)copy:(id)sender
{
    (void)sender;
    NSIndexSet *rows = _tableView.selectedRowIndexes;
    if (_tableScroll.hidden || !_table || !rows.count)
        return;
    NSMutableString *text = [NSMutableString string];
    int nc = fq_table_ncols(_table);
    for (int c = 0; c < nc; c++)
        [text appendFormat:@"%@%@", c ? @"\t" : @"", FQString(fq_table_column(_table, c)->name)];
    [text appendString:@"\n"];
    __block NSUInteger left = 100000;
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        char cell[200];
        for (int c = 0; c < nc; c++) {
            fq_table_cell(self->_table, (int64_t)row, c, cell, sizeof cell);
            [text appendFormat:@"%@%@", c ? @"\t" : @"", FQString(cell)];
        }
        [text appendString:@"\n"];
        if (--left == 0)
            *stop = YES;
    }];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}

#pragma mark Actions

- (void)modeChanged:(id)sender
{
    (void)sender;
    NSInteger mode = _mode.selectedSegment;
    [self showMode:mode];
    if (mode == kModeHeader)
        [self.view.window makeFirstResponder:_headerText];
    else if (mode == kModeTable)
        [self.view.window makeFirstResponder:_tableView];
}

- (void)stretchChanged:(id)sender
{
    (void)sender;
    NSInteger stretch = _stretchMenu.indexOfSelectedItem;
    [NSUserDefaults.standardUserDefaults setInteger:stretch forKey:kStretchDefaultsKey];
    // Only the mapping changes: redo it from the binned values, without
    // reading the file again.
    if (!_busy && _rendering && [_rendering restretch:(int)stretch]) {
        _imageView.image = _rendering.image;
        [self updateRenderInfo:nil];
        [self showMode:_mode.selectedSegment];
        return;
    }
    [self requestRender];
}

- (void)hduChanged:(id)sender
{
    (void)sender;
    NSNumber *n = _hduMenu.selectedItem.representedObject;
    if (!n)
        return;
    _selected = n.intValue;
    FQHDUItem *item = [self selectedItem];
    if (!item)
        return;
    // The header listing then opens at this HDU's cards.
    _headerTarget = _selected;
    _headerTargetRows = NO;
    if (item.kind == FQ_KIND_TABLE) {   // nothing to draw: its rows
        [self showMode:kModeTable];
        [self.view.window makeFirstResponder:_tableView];
        return;
    }
    // An image or a plot is drawn, unless a table's rows are on show.
    if (_selected != _hdu && !(_hdu < 0 && _rendering && _selected == _rendering.info.hdu)) {
        _hdu = _selected;
        _plane = -1;
        [self requestRender];
    }
    [self showMode:_mode.selectedSegment == kModeTable && item.isTable ? kModeTable : kModePicture];
}

- (void)planeChanged:(id)sender
{
    (void)sender;
    if (!_rendering)
        return;
    long long p = llround(_planeSlider.doubleValue);
    [self updatePlaneLabel];
    if (p == _plane || (_plane < 0 && p == _rendering.info.plane))
        return;
    _hdu = _rendering.info.hdu;
    _plane = p;
    [self requestRender];
}

/// Cmd-F, Cmd-G and Shift-Cmd-G search the header listing.
- (BOOL)handleKeyEquivalent:(NSEvent *)event
{
    if (_headerScroll.hidden)
        return NO;
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask &
                                ~NSEventModifierFlagCapsLock;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    NSInteger action = 0;
    if (mods == NSEventModifierFlagCommand && [key isEqualToString:@"f"])
        action = NSTextFinderActionShowFindInterface;
    else if (mods == NSEventModifierFlagCommand && [key isEqualToString:@"g"])
        action = NSTextFinderActionNextMatch;
    else if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift) && [key isEqualToString:@"g"])
        action = NSTextFinderActionPreviousMatch;
    if (!action)
        return NO;
    NSMenuItem *item = [NSMenuItem new];
    item.tag = action;
    [_headerText performTextFinderAction:item];
    return YES;
}

@end
