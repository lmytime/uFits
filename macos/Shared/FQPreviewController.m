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

#pragma mark - Table cells

/// The cell of a table column: one line of text, cut short with an
/// ellipsis, centred vertically in its row. The table draws its cells
/// itself (a cell-based table), which keeps scrolling through big tables
/// smooth: there is no view per cell to make, lay out and composite.
@interface FQGridCell : NSTextFieldCell
@property(nonatomic) CGFloat textHeight;
@end

@implementation FQGridCell

- (NSRect)drawingRectForBounds:(NSRect)rect
{
    NSRect r = [super drawingRectForBounds:rect];
    CGFloat extra = NSHeight(r) - self.textHeight;
    if (self.textHeight > 0 && extra > 1) {
        r.origin.y += floor(extra / 2);
        r.size.height = self.textHeight;
    }
    return r;
}

@end

/// A table column that knows which column of the FITS table it shows
/// (-1: the row number).
@interface FQTableColumn : NSTableColumn
@property(nonatomic) int fitsColumn;
@end

@implementation FQTableColumn
@end

/// A table opened in the background for the table view: the file, the
/// table, and how many characters wide each column's title and values are
/// (in its first and last rows: numbers such as IDs and times grow down a
/// table).
@interface FQOpenTable : NSObject
@property(nonatomic, readonly) fq_table *table;   // NULL if it could not be opened
@property(nonatomic, readonly) int ncols;         // columns shown (at most 1000)
- (int)charsOfColumn:(int)c;
@end

@implementation FQOpenTable {
    fq_file *_file;
    int *_chars;
}

- (instancetype)initWithPath:(NSString *)path hdu:(int)hdu
{
    if ((self = [super init])) {
        char err[256] = "";
        _file = fq_open(path.fileSystemRepresentation, err, sizeof err);
        _table = _file ? fq_table_open(_file, hdu) : NULL;
        int nc = _table ? MIN(fq_table_ncols(_table), 1000) : 0;
        _chars = nc ? calloc((size_t)nc, sizeof *_chars) : NULL;
        _ncols = _chars ? nc : 0;
        int64_t rows = _table ? fq_table_rows(_table) : 0;
        int64_t head = MIN(rows, (int64_t)50), tail = MAX(head, rows - 50);
        char cell[200];
        for (int c = 0; c < _ncols; c++) {
            size_t w = strlen(fq_table_column(_table, c)->name);
            for (int64_t r = 0; r < rows; r = r + 1 == head ? tail : r + 1) {
                fq_table_cell(_table, r, c, cell, sizeof cell);
                w = MAX(w, strlen(cell));
            }
            _chars[c] = (int)MIN(w, (size_t)1000);
        }
    }
    return self;
}

- (int)charsOfColumn:(int)c
{
    return c >= 0 && c < _ncols ? _chars[c] : 0;
}

- (void)dealloc
{
    fq_table_close(_table);
    fq_close(_file);
    free(_chars);
}

@end

#pragma mark - Click probe (CI diagnostics)

#ifdef FQ_CLICKPROBE
#include <os/log.h>

static os_log_t gProbe;

static double FQUptime(void)
{
    return NSProcessInfo.processInfo.systemUptime;
}

/// Logs when clicks reach this process and how late, when the window
/// server sees the mouse button change (and what is under the pointer
/// then), and when menus open (make PROBE=1; read with log show).
static void FQStartClickProbe(NSView *root)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gProbe = os_log_create("io.github.lmytime.uFits", "probe");
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
                                                      NSEventMaskLeftMouseDragged | NSEventMaskMouseMoved
                                              handler:^NSEvent *(NSEvent *e) {
                                                  double now = FQUptime();
                                                  const char *type = e.type == NSEventTypeLeftMouseDown   ? "down"
                                                                     : e.type == NSEventTypeLeftMouseUp   ? "up"
                                                                     : e.type == NSEventTypeMouseMoved    ? "moved"
                                                                                                          : "dragged";
                                                  os_log(gProbe, "probe %.3f: %{public}s of %.3f, %.1f ms late, clicks %ld, at %{public}s",
                                                         now, type, e.timestamp, (now - e.timestamp) * 1000,
                                                         (long)(e.type == NSEventTypeMouseMoved ? 0 : e.clickCount),
                                                         NSStringFromPoint(e.locationInWindow).UTF8String);
                                                  return e;
                                              }];
        __block NSUInteger last = 0;
        __weak NSView *weakRoot = root;
        NSTimer *t = [NSTimer timerWithTimeInterval:0.004
                                            repeats:YES
                                              block:^(NSTimer *timer) {
                                                  NSUInteger b = NSEvent.pressedMouseButtons;
                                                  if (b == last)
                                                      return;
                                                  last = b;
                                                  NSWindow *w = weakRoot.window;
                                                  NSPoint m = NSEvent.mouseLocation;
                                                  NSPoint p = w ? [w convertPointFromScreen:m] : NSZeroPoint;
                                                  NSView *hit = [w.contentView.superview hitTest:p];
                                                  os_log(gProbe, "probe %.3f: buttons %lu, mouse %{public}s on screen, %{public}s in window %{public}s, over %{public}s",
                                                         FQUptime(), (unsigned long)b, NSStringFromPoint(m).UTF8String,
                                                         NSStringFromPoint(p).UTF8String, NSStringFromRect(w.frame).UTF8String,
                                                         hit ? NSStringFromClass(hit.class).UTF8String : "nothing");
                                              }];
        [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
        [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidBeginTrackingNotification
                                                        object:nil
                                                         queue:nil
                                                    usingBlock:^(NSNotification *note) {
                                                        os_log(gProbe, "probe %.3f: menu opens", FQUptime());
                                                    }];
    });
}
/// Lists the gesture recognizers on view and its ancestors.
static void FQProbeRecognizers(NSView *view, const char *when)
{
    if (!gProbe)
        return;
    for (NSView *v = view; v; v = v.superview)
        for (NSGestureRecognizer *g in v.gestureRecognizers) {
            NSInteger clicks = [g isKindOfClass:NSClickGestureRecognizer.class]
                                   ? ((NSClickGestureRecognizer *)g).numberOfClicksRequired
                                   : 0;
            os_log(gProbe, "probe %.3f: %{public}s: %{public}s on %{public}s: clicks %ld, delays primary %d, "
                           "enabled %d, target %{public}s, action %{public}s, delegate %{public}s",
                   FQUptime(), when, NSStringFromClass(g.class).UTF8String, NSStringFromClass(v.class).UTF8String,
                   (long)clicks, g.delaysPrimaryMouseButtonEvents, g.enabled,
                   g.target ? NSStringFromClass([g.target class]).UTF8String : "none",
                   g.action ? NSStringFromSelector(g.action).UTF8String : "none",
                   g.delegate ? NSStringFromClass([g.delegate class]).UTF8String : "none");
        }
}

#define FQ_PROBE(...) os_log(gProbe, __VA_ARGS__)
#else
#define FQ_PROBE(...) ((void)0)
#endif

#pragma mark - Clicks in Quick Look

/// Quick Look shows the preview in a view with a gesture recognizer of its
/// own (double clicks) that holds back every click until the double-click
/// time has passed without a second one: half a second before the HDU menu
/// opens, the mode switch switches or a table row is picked. Let clicks
/// through at once: the recognizer still sees them, and still knows a
/// double click.
static void FQLetClicksThrough(NSView *view)
{
#ifdef FQ_CLICKPROBE
    FQProbeRecognizers(view, "before");
#endif
    for (NSView *v = view; v; v = v.superview)
        for (NSGestureRecognizer *g in v.gestureRecognizers)
            if (g.delaysPrimaryMouseButtonEvents)
                g.delaysPrimaryMouseButtonEvents = NO;
}

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
    CGFloat _digitWidth, _textHeight;   // of _cellFont
    NSTextField *_message;
    NSBox *_loading;      // "Loading…", over the content area
    NSProgressIndicator *_spinner;
    BOOL _loadingWanted;
    NSInteger _loadingToken;
    BOOL _focusOnReady;   // give the table or header the keyboard once shown
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
    FQOpenTable *_tableData;   // the table in the table view
    fq_table *_table;          // _tableData.table
    int _tableHDU;        // HDU in the table view (opened or not), -1 = none
    int _tableOpening;    // HDU being opened in the background, -1 = none
    NSInteger _tableGeneration;
    NSMutableDictionary<NSNumber *, NSAttributedString *> *_headers;   // built, by HDU
    NSMutableIndexSet *_headersBuilding;
    int _headerShown;     // HDU whose header is in the text view, -1 = none
    NSInteger _fileGeneration;
    BOOL _busy, _again;   // a render is running; another one is wanted after it
    NSInteger _generation;
    NSSize _fitting;
    CGFloat _hduWidth;    // natural width of the HDU menu
    id _clickMonitor;     // see FQLetClicksThrough
}

- (instancetype)initWithNibName:(NSNibName)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if ((self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil])) {
        _maxPixels = 2560;
        _fitting = NSMakeSize(800, 600);
        _hdu = -1;
        _plane = -1;
        _tableHDU = -1;
        _tableOpening = -1;
        _headerShown = -1;
        _headers = [NSMutableDictionary dictionary];
        _headersBuilding = [NSMutableIndexSet indexSet];
        _selected = -1;
    }
    return self;
}

- (void)dealloc
{
    if (_clickMonitor)
        [NSEvent removeMonitor:_clickMonitor];
    _tableView.dataSource = nil;
    _tableView.delegate = nil;
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

    // Header of the HDU picked. Non-contiguous layout keeps big ones quick.
    _headerScroll = [self scrollViewWithFrame:content];
    NSSize cs = _headerScroll.contentSize;
    _headerText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, cs.width, cs.height)];
    _headerText.editable = NO;
    _headerText.selectable = YES;
    _headerText.richText = YES;   // keys in bold, comments dimmed
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

    // Table view: every row of a table, formatted only as it scrolls in,
    // its cells drawn by the table itself (see FQGridCell).
    _cellFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _digitWidth = [@"0" sizeWithAttributes:@{NSFontAttributeName : _cellFont}].width;
    _textHeight = [[NSLayoutManager new] defaultLineHeightForFont:_cellFont];
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

    // "Loading…" while what was asked for is read or drawn.
    _loading = [[NSBox alloc] initWithFrame:NSMakeRect(floor(NSMidX(content) - 70), floor(NSMidY(content) - 38), 140, 76)];
    _loading.boxType = NSBoxCustom;
    _loading.titlePosition = NSNoTitle;
    _loading.cornerRadius = 10;
    _loading.borderWidth = 1;
    _loading.borderColor = NSColor.separatorColor;
    _loading.fillColor = NSColor.windowBackgroundColor;
    _loading.contentViewMargins = NSZeroSize;
    _loading.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    _loading.hidden = YES;
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(54, 32, 32, 32)];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.usesThreadedAnimation = YES;   // spins even while the main thread works
    _spinner.displayedWhenStopped = NO;
    [_loading.contentView addSubview:_spinner];
    NSTextField *loadingLabel = [NSTextField labelWithString:@"Loading…"];
    loadingLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    loadingLabel.textColor = NSColor.secondaryLabelColor;
    loadingLabel.alignment = NSTextAlignmentCenter;
    loadingLabel.frame = NSMakeRect(0, 10, 140, 16);
    [_loading.contentView addSubview:loadingLabel];
    [root addSubview:_loading];

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
#ifdef FQ_CLICKPROBE
    FQStartClickProbe(root);
#endif
    // Before each click is handed out, in case Quick Look adds its
    // recognizer after the view appears.
    __weak NSView *weakRoot = root;
    _clickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                                          handler:^NSEvent *(NSEvent *event) {
                                                              NSView *r = weakRoot;
                                                              if (r && event.window == r.window)
                                                                  FQLetClicksThrough(r);
                                                              return event;
                                                          }];
}

- (void)viewDidAppear
{
    [super viewDidAppear];
    FQLetClicksThrough(self.view);
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
    _fileGeneration++;
    [_headers removeAllObjects];
    [_headersBuilding removeAllIndexes];
    _headerShown = -1;
    _headerText.string = @"";
    _hdu = -1;
    _plane = -1;
    _hdus = nil;
    _selected = -1;
    [self closeTable];
    _rendering = nil;
    _imageView.image = NULL;
    _spectrumView.rendering = nil;
    _imageView.hidden = _spectrumView.hidden = _tableScroll.hidden = _headerScroll.hidden = YES;
    _message.hidden = YES;
    _renderInfo = _renderTip = nil;
    _info.stringValue = @"";
    [_hduMenu removeAllItems];
    [self layoutBar];
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
    if (first || _mode.selectedSegment == kModePicture)
        [self setLoading:YES];
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
        if (_selected < 0 && _hdus.count)
            _selected = _hdus.firstObject.hdu;
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

        // Read the header, and the table, in the background now, so that
        // the Header and Table buttons show them at once.
        [self buildHeader:[self shownHDU]];
        if ([self selectedItem].isTable)
            [self prepareTable:_selected];
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

/// The HDU whose rows or header are shown: the one picked, or the one drawn.
- (int)shownHDU
{
    return _selected >= 0 ? _selected : _rendering ? _rendering.info.hdu : 0;
}

/// Picture and Table are on for the HDU picked when it can be drawn, or is
/// a table; Header always is.
- (void)updateModeSwitch
{
    FQHDUItem *item = [self selectedItem];
    BOOL picture = item ? item.kind == FQ_KIND_IMAGE || item.kind == FQ_KIND_PLOT : _rendering != nil;
    [_mode setEnabled:picture forSegment:kModePicture];
    [_mode setEnabled:item.isTable forSegment:kModeTable];
    [_mode setLabel:item.kind == FQ_KIND_PLOT ? @"Plot" : @"Image" forSegment:kModePicture];
    [_mode sizeToFit];
}

/// Shows mode: the picture (image or plot), a table's rows, or a header,
/// falling back to what the HDU picked has. The switch is immediate: rows
/// and headers not read yet are read in the background, under "Loading…",
/// and shown when they are there (this is called again then).
- (void)showMode:(NSInteger)mode
{
    [self updateModeSwitch];
    if (![_mode isEnabledForSegment:mode])
        mode = [_mode isEnabledForSegment:kModePicture] ? kModePicture
             : [_mode isEnabledForSegment:kModeTable]   ? kModeTable
                                                          : kModeHeader;
    _mode.selectedSegment = mode;
    int hdu = [self shownHDU];
    BOOL picture = mode == kModePicture;
    BOOL rows = mode == kModeTable && [self prepareTable:hdu];
    BOOL header = mode == kModeHeader && [self prepareHeader:hdu];
    int kind = _rendering ? _rendering.kind : FQ_KIND_NONE;
    _headerScroll.hidden = !header;
    _tableScroll.hidden = !rows;
    _imageView.hidden = !picture || kind != FQ_KIND_IMAGE;
    _spectrumView.hidden = !picture || kind != FQ_KIND_PLOT;
    _message.hidden = !picture || _message.stringValue.length == 0 ||
                      (kind != FQ_KIND_NONE && !(kind == FQ_KIND_IMAGE && _rendering.info.empty));
    [self setLoading:picture ? _busy : !(rows || header)];
    if (_focusOnReady && (picture || rows || header)) {
        _focusOnReady = NO;
        if (rows)
            [self.view.window makeFirstResponder:_tableView];
        else if (header)
            [self.view.window makeFirstResponder:_headerText];
    }

    NSInteger i = [_hduMenu indexOfItemWithRepresentedObject:@(_selected)];
    if (i >= 0)
        [_hduMenu selectItemAtIndex:i];
    // The bar describes what is on show: the picture, or the table whose
    // rows or header are shown (nothing for an HDU with just a header).
    BOOL drawn = _rendering && (picture || _rendering.info.hdu == hdu);
    if (drawn && !rows) {
        _info.stringValue = _renderInfo ?: @"";
        _info.toolTip = _renderTip;
    } else {
        _info.stringValue = _table && _tableHDU == hdu ? [self tableSummary] : @"";
        _info.toolTip = nil;
    }
    [self layoutBar];
}

/// Shows "Loading…" over the content area while what was asked for is
/// read or drawn; only after a moment, so that quick changes do not flash
/// it.
- (void)setLoading:(BOOL)loading
{
    if (!loading) {
        _loadingWanted = NO;
        _loadingToken++;
        if (!_loading.hidden) {
            [_spinner stopAnimation:nil];
            _loading.hidden = YES;
        }
        return;
    }
    if (_loadingWanted)
        return;
    _loadingWanted = YES;
    NSInteger token = ++_loadingToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self->_loadingToken)
            return;
        self->_loading.hidden = NO;
        [self->_spinner startAnimation:nil];
    });
}

#pragma mark Header

/// The header of one HDU for the Header view: a heading, then the cards
/// with keys, values and comments in columns.
static NSAttributedString *FQHeaderListing(NSString *path, int hdu)
{
    NSFont *font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSFont *bold = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightSemibold];
    NSDictionary *plain = @{NSFontAttributeName : font, NSForegroundColorAttributeName : NSColor.labelColor};
    NSDictionary *heading = @{NSFontAttributeName : bold, NSForegroundColorAttributeName : NSColor.labelColor};
    // Styles of the parts fq_header_layout marks: keys, " = " and " / ", comments.
    NSDictionary *styles[] = {
        [FQ_SPAN_KEY] = @{NSFontAttributeName : bold},
        [FQ_SPAN_MARK] = @{NSForegroundColorAttributeName : NSColor.tertiaryLabelColor},
        [FQ_SPAN_COMMENT] = @{NSForegroundColorAttributeName : NSColor.secondaryLabelColor},
    };
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    char err[256] = "";
    fq_file *f = fq_open(path.fileSystemRepresentation, err, sizeof err);
    fq_span *spans = NULL;
    size_t len = 0, nspans = 0;
    char *text = f ? fq_header_layout(f, hdu, &len, &spans, &nspans) : NULL;
    if (!text) {
        NSString *msg = f ? [NSString stringWithFormat:@"No HDU %d in this file.", hdu]
                          : [NSString stringWithFormat:@"Cannot read this file: %@", FQString(err)];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:msg attributes:plain]];
        fq_close(f);
        return out;
    }
    char name[72] = "";
    NSString *title = fq_keyword(f, hdu, "EXTNAME", name, sizeof name) && name[0]
                          ? [NSString stringWithFormat:@"——— HDU %d  %@ ———\n", hdu, FQString(name)]
                          : [NSString stringWithFormat:@"——— HDU %d ———\n", hdu];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:title attributes:heading]];
    // The layout is ASCII, so its byte offsets are character offsets.
    NSString *cards = [[NSString alloc] initWithBytes:text length:len encoding:NSASCIIStringEncoding] ?: @"";
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:cards attributes:plain];
    for (size_t k = 0; k < nspans; k++)
        if (spans[k].kind >= FQ_SPAN_KEY && spans[k].kind <= FQ_SPAN_COMMENT &&
            (NSUInteger)spans[k].start + spans[k].len <= cards.length)
            [a addAttributes:styles[spans[k].kind] range:NSMakeRange(spans[k].start, spans[k].len)];
    [out appendAttributedString:a];
    free(text);
    free(spans);
    fq_close(f);
    return out;
}

/// Puts the header of hdu in the text view if it has been read (YES), or
/// starts reading it.
- (BOOL)prepareHeader:(int)hdu
{
    if (_headerShown == hdu)
        return YES;
    NSAttributedString *text = _headers[@(hdu)];
    if (!text) {
        [self buildHeader:hdu];
        return NO;
    }
    [_headerText.textStorage setAttributedString:text];
    [_headerText scrollPoint:NSZeroPoint];
    _headerShown = hdu;
    return YES;
}

/// Reads the header of hdu in the background, then shows it if it is
/// still the one wanted.
- (void)buildHeader:(int)hdu
{
    if (!_path || _headers[@(hdu)] || [_headersBuilding containsIndex:(NSUInteger)hdu])
        return;
    [_headersBuilding addIndex:(NSUInteger)hdu];
    NSString *path = _path;
    NSInteger generation = _fileGeneration;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSAttributedString *text = FQHeaderListing(path, hdu);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_fileGeneration)
                return;
            [self->_headersBuilding removeIndex:(NSUInteger)hdu];
            self->_headers[@(hdu)] = text;
            if (self->_mode.selectedSegment == kModeHeader && [self shownHDU] == hdu)
                [self showMode:kModeHeader];
        });
    });
}

#pragma mark Table view

- (void)closeTable
{
    _tableData = nil;   // closes the table and its file
    _table = NULL;
    _tableHDU = -1;
    _tableOpening = -1;
    _tableGeneration++;   // and drops any table being opened
    for (NSTableColumn *column in [_tableView.tableColumns copy])
        [_tableView removeTableColumn:column];
    [_tableView reloadData];
}

/// Whether the table view holds the rows of hdu (or found it unreadable);
/// if not, opens it in the background and shows it when it is ready.
- (BOOL)prepareTable:(int)hdu
{
    if (_tableHDU == hdu)
        return YES;
    if (_tableOpening == hdu || !_path)
        return NO;
    _tableOpening = hdu;
    NSInteger generation = ++_tableGeneration;
    NSString *path = _path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FQOpenTable *t = [[FQOpenTable alloc] initWithPath:path hdu:hdu];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_tableGeneration)
                return;   // another file or table was asked for since
            [self installTable:t hdu:hdu];
            [self showMode:self->_mode.selectedSegment];
        });
    });
    return NO;
}

/// A column's cell: monospaced, right-aligned for numbers.
- (FQGridCell *)cellWithAlignment:(NSTextAlignment)alignment color:(NSColor *)color
{
    FQGridCell *cell = [[FQGridCell alloc] initTextCell:@""];
    cell.font = _cellFont;
    cell.alignment = alignment;
    cell.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.truncatesLastVisibleLine = YES;
    cell.wraps = NO;
    cell.usesSingleLineMode = YES;
    cell.editable = NO;
    cell.selectable = NO;
    cell.textHeight = _textHeight;
    if (color)
        cell.textColor = color;
    return cell;
}

/// Puts an opened table in the table view: a column for the row number,
/// then one per column of the table, as wide as its first rows need.
- (void)installTable:(FQOpenTable *)t hdu:(int)hdu
{
    [self closeTable];
    _tableData = t;
    _table = t.table;
    _tableHDU = hdu;
    if (!_table)
        return;
    int64_t nrows = fq_table_rows(_table);
    FQTableColumn *num = [[FQTableColumn alloc] initWithIdentifier:@"#"];
    num.fitsColumn = -1;
    num.title = @"#";
    num.width = ceil(_digitWidth * (CGFloat)[NSString stringWithFormat:@"%lld", (long long)MAX(nrows, 1)].length) + 14;
    num.editable = NO;
    num.headerCell.alignment = NSTextAlignmentRight;
    num.dataCell = [self cellWithAlignment:NSTextAlignmentRight color:NSColor.tertiaryLabelColor];
    [_tableView addTableColumn:num];
    for (int c = 0; c < t.ncols; c++) {
        const fq_column *ci = fq_table_column(_table, c);
        FQTableColumn *column = [[FQTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%d", c]];
        column.fitsColumn = c;
        column.title = FQString(ci->name);
        NSString *unit = FQString(ci->unit), *form = FQString(ci->form);
        column.headerToolTip = unit.length ? [NSString stringWithFormat:@"%@  [%@]", form, unit] : form;
        column.width = MIN(MAX(ceil(_digitWidth * (CGFloat)[t charsOfColumn:c]) + 14, 40), 420);
        column.minWidth = 24;
        column.editable = NO;
        NSTextAlignment alignment = ci->numeric ? NSTextAlignmentRight : NSTextAlignmentLeft;
        column.headerCell.alignment = alignment;
        column.dataCell = [self cellWithAlignment:alignment color:nil];
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
    return _table ? (NSInteger)fq_table_rows(_table) : 0;
}

/// The text of a cell, formatted when the table draws it.
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    (void)tableView;
    int c = [column isKindOfClass:FQTableColumn.class] ? ((FQTableColumn *)column).fitsColumn : -1;
    if (c < 0)
        return [NSString stringWithFormat:@"%ld", (long)row + 1];
    char cell[200];
    fq_table_cell(_table, row, c, cell, sizeof cell);
    return FQString(cell);
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
    FQ_PROBE("probe %.3f: mode switch action", FQUptime());
    _focusOnReady = YES;
    [self showMode:_mode.selectedSegment];
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
    FQ_PROBE("probe %.3f: HDU menu action", FQUptime());
    NSNumber *n = _hduMenu.selectedItem.representedObject;
    if (!n)
        return;
    _selected = n.intValue;
    FQHDUItem *item = [self selectedItem];
    if (!item)
        return;
    // An image or a plot is drawn in the background, whatever is on show.
    BOOL drawable = item.kind == FQ_KIND_IMAGE || item.kind == FQ_KIND_PLOT;
    if (drawable && _selected != _hdu && !(_hdu < 0 && _rendering && _selected == _rendering.info.hdu)) {
        _hdu = _selected;
        _plane = -1;
        [self requestRender];
    }
    // The same mode when this HDU has it (a header always), or what it has:
    // its picture, else its rows, else its header.
    _focusOnReady = YES;
    [self showMode:_mode.selectedSegment];
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
