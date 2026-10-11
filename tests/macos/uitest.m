// uitest - drive the preview UI (FQPreviewController) in a window the way a
// user would: switch HDUs (images, plots, tables), move the cube plane
// slider, open the header (its cards in columns) and its find bar. Prints
// the state of the bar after every step and captures the window to
// OUTDIR/ui-<step>.png.
//
// Usage: uitest OUTDIR TESTDATA_DIR

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>

#import "FQPreviewController.h"
#import "FQUpdate.h"

static NSWindow *gWindow;
static NSString *gOut;
static int gFailures;

static void spin(double seconds)
{
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

/// Depth-first search for a visible view of class cls passing test.
static id findView(NSView *v, Class cls, BOOL (^test)(id view))
{
    if (!v.hidden && [v isKindOfClass:cls] && (!test || test(v)))
        return v;
    if (v.hidden)
        return nil;
    for (NSView *sub in v.subviews) {
        id found = findView(sub, cls, test);
        if (found)
            return found;
    }
    return nil;
}

/// The visible controls of the bar along the bottom of the view, as text.
static NSString *barState(NSView *root)
{
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        NSView *v = stack.lastObject;
        [stack removeLastObject];
        if (v.hidden)
            continue;
        NSRect r = [v convertRect:v.bounds toView:root];
        if ([v isKindOfClass:NSPopUpButton.class]) {
            // Not its subviews: a label of its own repeats its title.
            NSPopUpButton *p = (NSPopUpButton *)v;
            NSPopUpButtonCell *cell = p.cell;
            NSString *item = p.titleOfSelectedItem ?: @"";
            NSString *shows = cell.usesItemFromMenu ? item : cell.menuItem.title ?: @"";
            if (NSMinY(r) <= 30)
                [parts addObject:[NSString stringWithFormat:@"menu=\"%@\" (%ld items)%@", item, (long)p.numberOfItems,
                                                            [shows isEqualToString:item]
                                                                ? @""
                                                                : [NSString stringWithFormat:@" shows \"%@\"", shows]]];
            continue;
        }
        [stack addObjectsFromArray:v.subviews];
        if (NSMinY(r) > 30 || v == root)
            continue;
        if ([v isKindOfClass:NSSlider.class])
            [parts addObject:[NSString stringWithFormat:@"slider=%g of %g", ((NSSlider *)v).doubleValue,
                                                        ((NSSlider *)v).maxValue]];
        else if ([v isKindOfClass:NSSegmentedControl.class]) {
            NSSegmentedControl *sc = (NSSegmentedControl *)v;
            NSMutableArray<NSString *> *segs = [NSMutableArray array];
            for (NSInteger i = 0; i < sc.segmentCount; i++)
                [segs addObject:[NSString stringWithFormat:@"%@%@", [sc labelForSegment:i],
                                                           [sc isEnabledForSegment:i] ? @"" : @"(off)"]];
            [parts addObject:[NSString stringWithFormat:@"mode=%ld [%@]", (long)sc.selectedSegment,
                                                        [segs componentsJoinedByString:@"|"]]];
        }
        else if ([v isKindOfClass:NSTextField.class] && ((NSTextField *)v).stringValue.length)
            [parts addObject:[NSString stringWithFormat:@"\"%@\"", ((NSTextField *)v).stringValue]];
        else if ([v isKindOfClass:NSButton.class])
            [parts addObject:[NSString stringWithFormat:@"button=\"%@\"", ((NSButton *)v).title]];
    }
    return [parts componentsJoinedByString:@"  "];
}

/// The table view, if on screen: rows, column titles, first cell.
static NSString *gridState(NSView *root)
{
    NSTableView *tv = findView(root, NSTableView.class, nil);
    if (!tv)
        return @"";
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSTableColumn *c in tv.tableColumns)
        [titles addObject:c.title];
    NSString *first = @"";
    if (tv.numberOfRows > 0 && tv.numberOfColumns > 1) {
        id value = [tv.dataSource tableView:tv objectValueForTableColumn:tv.tableColumns[1] row:0];
        first = [value description] ?: @"";
    }
    return [NSString stringWithFormat:@"grid=%ld rows [%@] first=\"%@\"", (long)tv.numberOfRows,
                                      [titles componentsJoinedByString:@","], first];
}

/// Saves the window as it is now to OUTDIR/ui-<step>.png.
static void screenshot(NSString *step)
{
    NSString *png = [gOut stringByAppendingPathComponent:[NSString stringWithFormat:@"ui-%@.png", step]];
    NSTask *t = [NSTask
        launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/sbin/screencapture"]
                            arguments:@[ @"-x", @"-o",
                                         [NSString stringWithFormat:@"-l%ld", (long)gWindow.windowNumber], png ]
                                error:nil
                   terminationHandler:nil];
    [t waitUntilExit];
}

static void capture(NSString *step, NSString *expect)
{
    spin(0.6);
    NSString *state = [NSString stringWithFormat:@"%@  %@", barState(gWindow.contentView),
                                                 gridState(gWindow.contentView)];
    BOOL ok = !expect || [state rangeOfString:expect].location != NSNotFound;
    if (!ok)
        gFailures++;
    printf("%s %s: %s\n", ok ? "ok  " : "FAIL", step.UTF8String, state.UTF8String);
    if (!ok)
        printf("      expected to see: %s\n", expect.UTF8String);
    screenshot(step);
}

static void load(FQPreviewController *vc, NSString *path)
{
    __block BOOL done = NO;
    [vc loadFile:path
        completion:^{
            done = YES;
        }];
    for (int i = 0; i < 200 && !done; i++)
        spin(0.05);
    // The window follows the controller's preferred size; use a fixed one.
    vc.preferredContentSize = NSMakeSize(900, 640);
    [gWindow setContentSize:NSMakeSize(900, 640)];
    gWindow.title = path.lastPathComponent;
}

static void act(NSControl *c)
{
    [c sendAction:c.action to:c.target];
    spin(1.0);
}

/// The mode switch (Image/Plot, Table, Header), not some other segmented
/// control such as the find bar's arrows.
static NSSegmentedControl *modeSwitch(NSView *root)
{
    return findView(root, NSSegmentedControl.class, ^BOOL(id v) {
        return [v segmentCount] == 3 && [[v labelForSegment:2] isEqualToString:@"Header"];
    });
}

/// Clicks segment i of the mode switch.
static void pickMode(NSView *root, NSInteger i)
{
    NSSegmentedControl *mode = modeSwitch(root);
    if (!mode) {
        printf("FAIL no mode switch\n");
        gFailures++;
        return;
    }
    mode.selectedSegment = i;
    act(mode);
}

/// Picks item i of the HDU menu, as a user would.
static void pickHDU(NSView *root, NSInteger i)
{
    NSPopUpButton *menu = findView(root, NSPopUpButton.class, ^BOOL(id p) {
        return [[p titleOfSelectedItem] hasPrefix:@"HDU"];
    });
    if (!menu || i >= menu.numberOfItems) {
        printf("FAIL no HDU menu item %ld\n", (long)i);
        gFailures++;
        return;
    }
    [menu selectItemAtIndex:i];
    act(menu);
}

/// What FQImageView (FQPreviewController.m) shows: the image, and over it
/// the part on view in detail.
@protocol FQImageViewParts
@property(nonatomic, readonly) CGImageRef image;
@property(nonatomic, readonly) CGImageRef detail;
@property(nonatomic, readonly) NSRect detailFrame;
@end

/// A key with Command, as the keyboard sends it; whether the view took it.
static BOOL commandKey(NSView *root, NSString *key)
{
    NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                  location:NSZeroPoint
                             modifierFlags:NSEventModifierFlagCommand
                                 timestamp:0
                              windowNumber:gWindow.windowNumber
                                   context:nil
                                characters:key
               charactersIgnoringModifiers:key
                                 isARepeat:NO
                                   keyCode:0];
    BOOL took = [root performKeyEquivalent:e];
    spin(0.8);   // the detail comes after a pause
    return took;
}

static void report(NSString *step, BOOL ok, NSString *what)
{
    if (!ok)
        gFailures++;
    printf("%s %s: %s\n", ok ? "ok  " : "FAIL", step.UTF8String, what.UTF8String);
}

/// Grey levels of img, top row first.
static NSData *greys(CGImageRef img)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    NSMutableData *px = [NSMutableData dataWithLength:w * h];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(px.mutableBytes, w, h, 8, w, cs, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return px;
}

/// How well the detail, where it is laid (frame, in image pixels from the
/// bottom left), matches the image under it (of size size): the correlation
/// of their grey levels on a 24 x 24 grid of points.
static double placement(CGImageRef image, CGImageRef detail, NSRect frame, NSSize size)
{
    NSData *a = greys(image), *b = greys(detail);
    size_t aw = CGImageGetWidth(image), ah = CGImageGetHeight(image);
    size_t bw = CGImageGetWidth(detail), bh = CGImageGetHeight(detail);
    const uint8_t *pa = a.bytes, *pb = b.bytes;
    double sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0;
    int n = 0;
    for (int i = 0; i < 24; i++)
        for (int j = 0; j < 24; j++) {
            double x = NSMinX(frame) + (i + 0.5) / 24 * NSWidth(frame);
            double y = NSMinY(frame) + (j + 0.5) / 24 * NSHeight(frame);
            size_t ax = MIN(aw - 1, (size_t)(x / size.width * aw));
            size_t ay = MIN(ah - 1, (size_t)((size.height - y) / size.height * ah));
            size_t bx = MIN(bw - 1, (size_t)((x - NSMinX(frame)) / NSWidth(frame) * bw));
            size_t by = MIN(bh - 1, (size_t)((NSMaxY(frame) - y) / NSHeight(frame) * bh));
            double va = pa[ay * aw + ax], vb = pb[by * bw + bx];
            sa += va;
            sb += vb;
            saa += va * va;
            sbb += vb * vb;
            sab += va * vb;
            n++;
        }
    double cov = sab / n - sa / n * sb / n;
    double da = saa / n - sa / n * sa / n, db = sbb / n - sb / n * sb / n;
    return da > 0 && db > 0 ? cov / sqrt(da * db) : 0;
}

/// Zoom: Command + and - zoom in and out, Command 0 shows the whole image;
/// zoomed in on an image shown binned, the part on view is drawn pixel for
/// pixel over it, in its place; another cube plane keeps the zoom.
static void checkZoom(FQPreviewController *vc, NSString *data)
{
    NSString *big = [data stringByAppendingPathComponent:@"zoom_image.fits"];
    if (![NSFileManager.defaultManager fileExistsAtPath:big]) {
        printf("skip zoom: no zoom_image.fits (tests/macos/make_big_files.py makes it)\n");
        return;
    }
    NSView *root = vc.view;
    load(vc, big);   // 4000 x 3000, shown binned 2 x 2
    spin(0.5);
    NSScrollView *sv = findView(root, NSScrollView.class, ^BOOL(id v) {
        return [[v documentView] isKindOfClass:NSClassFromString(@"FQImageView")];
    });
    NSView<FQImageViewParts> *iv = (NSView<FQImageViewParts> *)sv.documentView;
    if (!iv) {
        report(@"zoom", NO, @"no image view");
        return;
    }
    NSSize view = sv.frame.size;
    CGFloat fit = MIN(view.width / 4000, view.height / 3000);
    report(@"zoom-fit",
           NSEqualSizes(iv.frame.size, NSMakeSize(4000, 3000)) && fabs(sv.magnification / fit - 1) < 1e-3 && !iv.detail,
           [NSString stringWithFormat:@"image %@ shown at %.4f points per pixel (whole: %.4f), %@",
                                      NSStringFromSize(iv.frame.size), sv.magnification, fit,
                                      iv.detail ? @"with a detail" : @"no detail"]);

    BOOL took = commandKey(root, @"=") && commandKey(root, @"=") && commandKey(root, @"=");
    CGImageRef detail = iv.detail;
    NSRect df = iv.detailFrame, vis = NSIntersectionRect(sv.documentVisibleRect, iv.bounds);
    BOOL fine = detail && CGImageGetWidth(detail) == (size_t)NSWidth(df) &&
                CGImageGetHeight(detail) == (size_t)NSHeight(df) &&
                NSContainsRect(NSInsetRect(df, 1, 1), NSInsetRect(vis, 2, 2)) &&
                NSWidth(df) <= NSWidth(vis) + 4 && NSHeight(df) <= NSHeight(vis) + 4;
    double match = detail ? placement(iv.image, detail, df, iv.bounds.size) : 0;
    report(@"zoom-in", took && fabs(sv.magnification / (8 * fit) - 1) < 1e-3 && fine && match > 0.8,
           [NSString stringWithFormat:@"Command + three times: %.4f points per pixel; detail %zux%zu over %@, "
                                      @"on view %@, matching the image under it by %.3f",
                                      sv.magnification, detail ? CGImageGetWidth(detail) : 0,
                                      detail ? CGImageGetHeight(detail) : 0, NSStringFromRect(df),
                                      NSStringFromRect(vis), match]);
    screenshot(@"zoom-detail");
    commandKey(root, @"-");
    report(@"zoom-out", fabs(sv.magnification / (4 * fit) - 1) < 1e-3,
           [NSString stringWithFormat:@"Command -: %.4f points per pixel", sv.magnification]);
    commandKey(root, @"0");
    report(@"zoom-whole", fabs(sv.magnification / fit - 1) < 1e-3 && !iv.detail,
           [NSString stringWithFormat:@"Command 0: %.4f points per pixel, %@", sv.magnification,
                                      iv.detail ? @"with a detail" : @"no detail"]);

    // A cube keeps its zoom from plane to plane.
    int maxPixels = vc.maxPixels;
    vc.maxPixels = 40;   // 160 x 120, shown binned 4 x 4
    load(vc, [data stringByAppendingPathComponent:@"cube5.fits"]);
    spin(0.5);
    commandKey(root, @"=");
    CGFloat zoom = sv.magnification;
    NSSlider *slider = findView(root, NSSlider.class, nil);
    if (slider) {
        slider.doubleValue = 4;
        act(slider);
    }
    report(@"zoom-cube", slider && fabs(sv.magnification / zoom - 1) < 1e-3 && iv.detail != NULL,
           [NSString stringWithFormat:@"plane 5 at %.3f points per pixel (was %.3f), detail %@",
                                      sv.magnification, zoom, iv.detail ? @"drawn" : @"missing"]);
    vc.maxPixels = maxPixels;
}

/// "Update available" in the bar when a newer uFits is out (as if seen
/// just now: nothing is looked up), its click handed to the app; none
/// when that version was skipped, or when looking is turned off.
static void checkUpdateNotice(FQPreviewController *vc, NSString *data)
{
    NSView *root = vc.view;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *mef = [data stringByAppendingPathComponent:@"mef.fits"];
    BOOL order = [FQUpdate version:@"0.0.10" isNewerThan:@"0.0.9"] && [FQUpdate version:@"1.0" isNewerThan:@"0.9.9"] &&
                 ![FQUpdate version:@"0.0.3" isNewerThan:@"0.0.3"] && ![FQUpdate version:@"0.0.2" isNewerThan:@"0.0.3"] &&
                 [FQUpdate version:@"0.1" isNewerThan:@"0.0.9"];
    report(@"update-versions", order, @"0.0.10 > 0.0.9, 1.0 > 0.9.9, 0.1 > 0.0.9; not 0.0.3 > 0.0.3 or 0.0.2 > 0.0.3");

    [d setBool:YES forKey:@"FQCheckForUpdates"];
    [d setObject:@"99.0.0" forKey:@"FQUpdateLatest"];
    [d setObject:[NSDate date] forKey:@"FQUpdateChecked"];
    __block NSString *asked = nil;
    vc.updateAction = ^(NSString *version) {
        asked = version;
    };
    load(vc, mef);
    capture(@"update", @"button=\"Update available\"");
    NSButton *notice = findView(root, NSButton.class, ^BOOL(id v) {
        return [[v title] isEqualToString:@"Update available"];
    });
    if (notice)
        act(notice);
    report(@"update-click", [asked isEqualToString:@"99.0.0"],
           [NSString stringWithFormat:@"the click asked for %@", asked ?: @"nothing"]);

    [d setObject:@"99.0.0" forKey:@"FQSkippedVersion"];
    load(vc, mef);
    BOOL skipped = [barState(root) rangeOfString:@"Update available"].location == NSNotFound;
    [d removeObjectForKey:@"FQSkippedVersion"];
    [d setBool:NO forKey:@"FQCheckForUpdates"];
    load(vc, mef);
    BOOL off = [barState(root) rangeOfString:@"Update available"].location == NSNotFound;
    report(@"update-quiet", skipped && off,
           [NSString stringWithFormat:@"no notice for a skipped version: %@; with checks off: %@", skipped ? @"yes" : @"NO",
                                      off ? @"yes" : @"NO"]);
    [d removeObjectForKey:@"FQUpdateLatest"];
    [d removeObjectForKey:@"FQUpdateChecked"];
    vc.updateAction = nil;
}

/// Checks that the part of the header listing in view shows text.
static void expectListing(NSString *step, NSString *text)
{
    NSTextView *tv = findView(gWindow.contentView, NSTextView.class, ^BOOL(id v) {
        return ![v isEditable];
    });
    NSString *shown = @"";
    if (tv) {
        NSRange g = [tv.layoutManager glyphRangeForBoundingRect:tv.visibleRect
                                                inTextContainer:tv.textContainer];
        shown = [tv.string substringWithRange:[tv.layoutManager characterRangeForGlyphRange:g
                                                                           actualGlyphRange:NULL]];
    }
    BOOL ok = [shown rangeOfString:text].location != NSNotFound;
    if (!ok)
        gFailures++;
    NSString *top = [shown componentsSeparatedByString:@"\n"].firstObject ?: @"";
    printf("%s %s: listing at \"%s\" (want \"%s\" in view)\n", ok ? "ok  " : "FAIL", step.UTF8String,
           top.UTF8String, text.UTF8String);
}

/// Checks the header listing's columns: the "=" of two cards in line on
/// screen, keys in another font than values (bold), comments dimmed.
static void expectColumns(NSString *step, NSString *card1, NSString *card2, NSString *comment)
{
    NSTextView *tv = findView(gWindow.contentView, NSTextView.class, ^BOOL(id v) {
        return ![v isEditable];
    });
    NSTextStorage *ts = tv.textStorage;
    NSRange r1 = [ts.string rangeOfString:card1], r2 = [ts.string rangeOfString:card2],
            rc = [ts.string rangeOfString:comment];
    BOOL found = tv && r1.location != NSNotFound && r2.location != NSNotFound && rc.location != NSNotFound;
    CGFloat x[2] = {-1, -1};
    NSUInteger eq[2] = {r1.location + [card1 rangeOfString:@"="].location,
                        r2.location + [card2 rangeOfString:@"="].location};
    for (int i = 0; i < 2 && found; i++) {
        NSRange g = [tv.layoutManager glyphRangeForCharacterRange:NSMakeRange(eq[i], 1) actualCharacterRange:NULL];
        x[i] = NSMinX([tv.layoutManager boundingRectForGlyphRange:g inTextContainer:tv.textContainer]);
    }
    NSFont *key = found ? [ts attribute:NSFontAttributeName atIndex:r1.location effectiveRange:NULL] : nil;
    NSFont *value = found ? [ts attribute:NSFontAttributeName atIndex:eq[0] + 2 effectiveRange:NULL] : nil;
    NSColor *vc = found ? [ts attribute:NSForegroundColorAttributeName atIndex:eq[0] + 2 effectiveRange:NULL] : nil;
    NSColor *cc = found ? [ts attribute:NSForegroundColorAttributeName atIndex:rc.location effectiveRange:NULL] : nil;
    BOOL ok = found && x[0] > 0 && fabs(x[0] - x[1]) < 0.5 && key && value && ![key isEqual:value] && cc &&
              ![cc isEqual:vc];
    if (!ok)
        gFailures++;
    printf("%s %s: \"=\" at x=%.1f and x=%.1f, key font %s, value font %s, comment colour %s\n", ok ? "ok  " : "FAIL",
           step.UTF8String, x[0], x[1], key.fontName.UTF8String ?: "-", value.fontName.UTF8String ?: "-",
           cc.description.UTF8String ?: "-");
}

#pragma mark Timings

static double msSince(CFTimeInterval t0)
{
    return (CACurrentMediaTime() - t0) * 1000.0;
}

/// Whether the preview shows the content of mode: a picture, a table with
/// rows, or a header listing.
static BOOL contentReady(NSInteger mode)
{
    NSView *root = gWindow.contentView;
    if (mode == 1) {
        NSTableView *tv = findView(root, NSTableView.class, nil);
        return tv && tv.numberOfRows > 0;
    }
    if (mode == 2) {
        NSTextView *tv = findView(root, NSTextView.class, ^BOOL(id v) {
            return ![v isEditable];
        });
        return tv && tv.string.length > 0;
    }
    return findView(root, NSClassFromString(@"FQImageView"), nil) ||
           findView(root, NSClassFromString(@"FQSpectrumView"), nil);
}

/// Clicks segment mode of the mode switch; reports how long the window was
/// busy (could not draw or take clicks) and how long until the content was
/// on screen.
static void timeSwitch(NSString *name, NSInteger mode)
{
    NSSegmentedControl *seg = modeSwitch(gWindow.contentView);
    if (!seg)
        return;
    seg.selectedSegment = mode;
    CFTimeInterval t0 = CACurrentMediaTime();
    [seg sendAction:seg.action to:seg.target];
    [gWindow layoutIfNeeded];
    [gWindow displayIfNeeded];
    double busy = msSince(t0);
    BOOL spinner = NO;
    while (!contentReady(mode) && msSince(t0) < 20000) {
        spin(0.005);
        spinner = spinner || findView(gWindow.contentView, NSProgressIndicator.class, nil) != nil;
    }
    [gWindow displayIfNeeded];
    double shown = msSince(t0);
    // The window must answer at once; the content may take a moment.
    BOOL ok = busy < 100 && contentReady(mode);
    if (!ok)
        gFailures++;
    printf("%s time %-31s busy %7.1f ms   on screen after %7.1f ms%s\n", ok ? "ok  " : "FAIL", name.UTF8String,
           busy, shown, spinner ? "   (showed Loading…)" : "");
}

/// Share of the pixels of rep that stand out from the background (text,
/// lines): about 0 when nothing is drawn.
static double inkShare(NSBitmapImageRep *rep)
{
    NSInteger dark = 0, light = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; y += 3)
        for (NSInteger x = 0; x < rep.pixelsWide; x += 3) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
            CGFloat l = 0.3 * c.redComponent + 0.59 * c.greenComponent + 0.11 * c.blueComponent;
            if (l < 0.5)
                dark++;
            else
                light++;
        }
    return dark + light ? (double)MIN(dark, light) / (double)(dark + light) : 0;
}

/// Draws all that is visible of the table into a bitmap, as after a jump,
/// three times; returns the milliseconds of the fastest (a busy runner can
/// hold up any one draw: 100 ms instead of 15 once) and sets *ink.
static double drawTable(NSTableView *tv, double *ink)
{
    NSRect r = tv.visibleRect;
    NSBitmapImageRep *rep = nil;
    double best = INFINITY;
    for (int i = 0; i < 3; i++) {
        rep = [tv bitmapImageRepForCachingDisplayInRect:r];
        CFTimeInterval t0 = CACurrentMediaTime();
        [tv cacheDisplayInRect:r toBitmapImageRep:rep];
        best = MIN(best, msSince(t0));
    }
    *ink = inkShare(rep);
    return best;
}

/// Scrolls the table on show a page down (or half a width across) at a
/// time, drawing each step; reports the time per step, then the time to
/// draw a whole page, and checks that the page is not blank.
static void timeScroll(NSString *name, BOOL sideways, int steps)
{
    NSTableView *tv = findView(gWindow.contentView, NSTableView.class, nil);
    if (!tv || !tv.numberOfRows) {
        printf("FAIL %s: no table on show\n", name.UTF8String);
        gFailures++;
        return;
    }
    [gWindow displayIfNeeded];
    CFTimeInterval t0 = CACurrentMediaTime();
    for (int i = 0; i < steps; i++) {
        NSRect v = tv.visibleRect;
        if (sideways) {
            CGFloat x = MIN(NSMaxX(v) + NSWidth(v) / 2, NSWidth(tv.bounds) - 1);
            NSInteger c = [tv columnAtPoint:NSMakePoint(x, NSMidY(v))];
            [tv scrollColumnToVisible:c >= 0 ? c : tv.numberOfColumns - 1];
        } else {
            NSRange rows = [tv rowsInRect:v];
            [tv scrollRowToVisible:MIN((NSInteger)(NSMaxRange(rows) + rows.length / 2), tv.numberOfRows - 1)];
        }
        [gWindow displayIfNeeded];
    }
    double ms = msSince(t0) / steps, ink = 0;
    double draw = drawTable(tv, &ink);
    BOOL ok = ms < 50 && draw < 100 && ink > 0.01;
    if (!ok)
        gFailures++;
    printf("%s time %-31s %7.2f ms per step (%d steps); a page drawn in %.1f ms, %.1f%% ink\n", ok ? "ok  " : "FAIL",
           name.UTF8String, ms, steps, draw, ink * 100);
}

/// Jumps the table on show to row, drawing it; reports the time and checks
/// that the rows there are drawn.
static void timeJump(NSString *name, NSInteger row)
{
    NSTableView *tv = findView(gWindow.contentView, NSTableView.class, nil);
    if (!tv || row >= tv.numberOfRows)
        return;
    CFTimeInterval t0 = CACurrentMediaTime();
    [tv scrollRowToVisible:row];
    [gWindow displayIfNeeded];
    double ms = msSince(t0), ink = 0;
    double draw = drawTable(tv, &ink);
    NSRange rows = [tv rowsInRect:tv.visibleRect];
    BOOL ok = NSLocationInRange((NSUInteger)row, rows) && ink > 0.01;
    if (!ok)
        gFailures++;
    printf("%s time %-31s %7.1f ms; rows %lu-%lu drawn in %.1f ms, %.1f%% ink\n", ok ? "ok  " : "FAIL",
           name.UTF8String, ms, (unsigned long)rows.location + 1, (unsigned long)NSMaxRange(rows), draw, ink * 100);
}

/// Opens path and reports how long until what it opens on is on screen (a
/// file with only tables opens on one, read in the background).
static void timeLoad(FQPreviewController *vc, NSString *name, NSString *path)
{
    CFTimeInterval t0 = CACurrentMediaTime();
    load(vc, path);
    NSSegmentedControl *seg = modeSwitch(gWindow.contentView);
    NSInteger mode = seg ? seg.selectedSegment : 0;
    while (!contentReady(mode) && msSince(t0) < 20000)
        spin(0.005);
    [gWindow displayIfNeeded];
    BOOL ok = contentReady(mode);
    if (!ok)
        gFailures++;
    printf("%s time %-31s %7.1f ms\n", ok ? "ok  " : "FAIL", name.UTF8String, msSince(t0));
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: uitest OUTDIR TESTDATA_DIR\n");
            return 2;
        }
        gOut = @(argv[1]);
        NSString *data = @(argv[2]);
        // No looking for updates (checkUpdateNotice pretends to have).
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"FQCheckForUpdates"];
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app finishLaunching];
        FQPreviewController *vc = [FQPreviewController new];
        gWindow = [NSWindow windowWithContentViewController:vc];
        [gWindow setFrameOrigin:NSMakePoint(60, 60)];
        [gWindow makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        NSView *root = vc.view;

        // XISF uses the same image, header and selection controls as FITS.
        load(vc, [data stringByAppendingPathComponent:@"xisf_multi.xisf"]);
        capture(@"xisf-multi", @"luminance");
        pickHDU(root, 1);
        capture(@"xisf-color", @"color");
        pickMode(root, 2);
        expectListing(@"xisf-header", @"sampleFormat");
        pickMode(root, 0);
        capture(@"xisf-image", @"mode=0 [Image|Table(off)|Header]");
        load(vc, [data stringByAppendingPathComponent:@"xisf_zstd.xisf"]);
        capture(@"xisf-zstd", @"mode=0 [Image|Table(off)|Header]");

        // Multi-extension file: the HDU menu switches between SCI, ERR and DQ.
        load(vc, [data stringByAppendingPathComponent:@"mef.fits"]);
        capture(@"mef", @"menu=\"HDU 1  SCI — 256 × 256 float32\" (4 items) shows \"HDU 1 SCI\"");
        pickHDU(root, 3);
        capture(@"mef-dq", @"shows \"HDU 3 DQ\"");
        // Its empty primary HDU is listed too, and shows its header.
        pickHDU(root, 0);
        expectListing(@"mef-primary", @"SIMPLE   = T");
        capture(@"mef-primary", @"menu=\"HDU 0 — no data\" (4 items) shows \"HDU 0\"  mode=2 [Image(off)|Table(off)|Header]");
        // In the Header view the menu switches headers; Image shows SCI again.
        pickHDU(root, 1);
        expectListing(@"mef-sci-header", @"——— HDU 1  SCI ———");
        pickMode(root, 0);
        capture(@"mef-sci", @"\"256 × 256  ·  float32\"");

        // Cube: the slider picks the plane.
        load(vc, [data stringByAppendingPathComponent:@"cube5.fits"]);
        capture(@"cube", @"slider=2 of 4");
        NSSlider *slider = findView(root, NSSlider.class, nil);
        if (slider) {
            slider.doubleValue = 0;
            act(slider);
        }
        capture(@"cube-plane1", @"\"1 / 5\"");

        checkZoom(vc, data);
        checkUpdateNotice(vc, data);

        // Tables: light curves (points; magnitudes upside down) and spectra,
        // each with its rows in the Table view.
        load(vc, [data stringByAppendingPathComponent:@"lc_tess.fits"]);
        capture(@"lightcurve", @"PDCSAP_FLUX vs TIME");
        pickMode(root, 1);
        capture(@"lightcurve-table", @"grid=2000 rows [#,TIME,TIMECORR");
        load(vc, [data stringByAppendingPathComponent:@"lc_mag.fits"]);
        capture(@"magnitudes", @"MAG vs MJD");
        load(vc, [data stringByAppendingPathComponent:@"spec_sdss.fits"]);
        capture(@"sdss", @"mode=0 [Plot|Table|Header]");
        pickMode(root, 1);
        capture(@"sdss-table", @"grid=3000 rows [#,flux,loglam,ivar,and_mask]");

        // Its second table has nothing to plot: the menu shows its rows; the
        // first one's rows, then its plot, come back the same way.
        pickHDU(root, 2);
        capture(@"sdss-specobj", @"grid=1 rows [#,CLASS,Z] first=\"GALAXY\"");
        capture(@"sdss-specobj-switch", @"mode=1 [Image(off)|Table|Header]");
        pickHDU(root, 1);
        capture(@"sdss-coadd", @"grid=3000 rows");
        pickMode(root, 0);
        capture(@"sdss-plot", @"mode=0 [Plot|Table|Header]");

        // A catalog: sky positions, a field across RA = 0, and its rows.
        load(vc, [data stringByAppendingPathComponent:@"catalog_wrap.fits"]);
        capture(@"catalog", @"DEC vs RA");
        pickMode(root, 1);
        capture(@"catalog-table", @"grid=3000 rows [#,ID,RA,DEC,MAG,NAME]");

        // A file of tables that cannot be plotted opens on its first table;
        // the menu switches tables; the header opens at the table picked, its
        // cards in columns, and Cmd-F opens its find bar.
        load(vc, [data stringByAppendingPathComponent:@"tables_mixed.fits"]);
        capture(@"tables", @"menu=\"HDU 1  MIXED — 6 rows × 11 columns\" (3 items)");
        capture(@"tables-grid", @"grid=6 rows [#,NAME,FLAG,BITS");
        pickHDU(root, 2);
        capture(@"tables-ascii", @"grid=4 rows [#,ID,RA,NOTE] first=\"0\"");
        pickMode(root, 2);
        expectListing(@"tables-header", @"——— HDU 2  ASCII ———");
        expectListing(@"tables-header-cards", @"XTENSION = 'TABLE' / ASCII table extension");
        expectColumns(@"tables-header-columns", @"XTENSION = 'TABLE'", @"TFORM2   = 'F10.5'",
                      @"ASCII table extension");
        capture(@"tables-header", @"menu=\"HDU 2  ASCII — 4 rows × 3 columns\" (3 items) shows \"HDU 2 ASCII\"  mode=2");
        NSEvent *cmdF = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                         location:NSZeroPoint
                                    modifierFlags:NSEventModifierFlagCommand
                                        timestamp:0
                                     windowNumber:gWindow.windowNumber
                                          context:nil
                                       characters:@"f"
                      charactersIgnoringModifiers:@"f"
                                        isARepeat:NO
                                          keyCode:3];
        BOOL handled = [gWindow performKeyEquivalent:cmdF];
        printf("%s cmd-F handled by the preview\n", handled ? "ok  " : "FAIL");
        if (!handled)
            gFailures++;
        capture(@"tables-find", nil);

        // Timings with big files (tests/macos/make_big_files.py): opening,
        // switching modes, scrolling a big table down and a wide one across.
        NSString *catalog = [data stringByAppendingPathComponent:@"big_catalog.fits"];
        if ([NSFileManager.defaultManager fileExistsAtPath:catalog]) {
            timeLoad(vc, @"open 1M-row catalog (sky plot)", catalog);
            timeSwitch(@"catalog: Plot -> Table", 1);
            timeScroll(@"catalog: scroll down", NO, 200);
            timeJump(@"catalog: jump to row 900000", 900000);
            capture(@"big-catalog-900000", @"grid=1000000 rows");
            timeScroll(@"catalog: scroll right", YES, 2);
            timeSwitch(@"catalog: Table -> Header", 2);
            timeSwitch(@"catalog: Header -> Plot", 0);
            timeSwitch(@"catalog: Plot -> Table again", 1);
            timeSwitch(@"catalog: Table -> Header again", 2);
            timeSwitch(@"catalog: Header -> Table again", 1);
            capture(@"big-catalog", nil);
            timeLoad(vc, @"open 300-column table", [data stringByAppendingPathComponent:@"wide_table.fits"]);
            timeScroll(@"wide table: scroll right", YES, 40);
            timeScroll(@"wide table: scroll down", NO, 50);
            capture(@"wide-table", nil);
            // A gzipped catalog has to be inflated to be read: "Loading…" shows
            // while it is, and the window answers all the while.
            NSString *gz = [data stringByAppendingPathComponent:@"big_catalog.fits.gz"];
            if ([NSFileManager.defaultManager fileExistsAtPath:gz]) {
                __block BOOL done = NO;
                CFTimeInterval t0 = CACurrentMediaTime();
                [vc loadFile:gz
                    completion:^{
                        done = YES;
                    }];
                BOOL spinner = NO;
                while (!done && msSince(t0) < 30000) {
                    spin(0.02);
                    if (!spinner && findView(gWindow.contentView, NSProgressIndicator.class, nil)) {
                        spinner = YES;
                        [gWindow displayIfNeeded];
                        screenshot(@"loading");
                    }
                }
                // Quick enough, it need not show (it waits 0.12 s).
                BOOL ok = done && (spinner || msSince(t0) < 300);
                printf("%s time %-31s %7.1f ms%s\n", ok ? "ok  " : "FAIL", "open gzipped catalog",
                       msSince(t0), spinner ? "   (showed Loading…)" : "   (no Loading…)");
                if (!ok)
                    gFailures++;
                timeSwitch(@"gz catalog: Plot -> Table", 1);
                timeSwitch(@"gz catalog: Table -> Header", 2);
                timeSwitch(@"gz catalog: Header -> Plot", 0);
            }
            timeLoad(vc, @"open 200-HDU file", [data stringByAppendingPathComponent:@"many_hdus.fits"]);
            timeSwitch(@"200 HDUs: Image -> Header", 2);
            timeSwitch(@"200 HDUs: Header -> Image", 0);
            timeSwitch(@"200 HDUs: Image -> Header again", 2);
        }

        printf("%d failures\n", gFailures);
    }
    return gFailures ? 1 : 0;
}
