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
        [stack addObjectsFromArray:v.subviews];
        NSRect r = [v convertRect:v.bounds toView:root];
        if (NSMinY(r) > 30 || v == root)
            continue;
        if ([v isKindOfClass:NSPopUpButton.class])
            [parts addObject:[NSString stringWithFormat:@"menu=\"%@\" (%ld items)",
                                                        ((NSPopUpButton *)v).titleOfSelectedItem,
                                                        (long)((NSPopUpButton *)v).numberOfItems]];
        else if ([v isKindOfClass:NSSlider.class])
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
    NSString *png = [gOut stringByAppendingPathComponent:[NSString stringWithFormat:@"ui-%@.png", step]];
    NSTask *t = [NSTask
        launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/sbin/screencapture"]
                            arguments:@[ @"-x", @"-o",
                                         [NSString stringWithFormat:@"-l%ld", (long)gWindow.windowNumber], png ]
                                error:nil
                   terminationHandler:nil];
    [t waitUntilExit];
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

/// Scrolls the table on show a page down (or half a width sideways) at a
/// time, drawing each step; reports the time per step.
static void timeScroll(NSString *name, BOOL sideways, int steps)
{
    NSTableView *tv = findView(gWindow.contentView, NSTableView.class, nil);
    if (!tv || !tv.numberOfRows) {
        printf("FAIL %s: no table on show\n", name.UTF8String);
        gFailures++;
        return;
    }
    NSScrollView *sv = tv.enclosingScrollView;
    NSClipView *clip = sv.contentView;
    [gWindow displayIfNeeded];
    CFTimeInterval t0 = CACurrentMediaTime();
    for (int i = 0; i < steps; i++) {
        NSPoint p = clip.bounds.origin;
        if (sideways)
            p.x += NSWidth(clip.bounds) / 2;
        else
            p.y += NSHeight(clip.bounds);
        [clip scrollToPoint:p];
        [sv reflectScrolledClipView:clip];
        [gWindow displayIfNeeded];
    }
    double ms = msSince(t0) / steps;
    BOOL ok = ms < 50;
    if (!ok)
        gFailures++;
    printf("%s time %-31s %7.2f ms per step (%d steps)\n", ok ? "ok  " : "FAIL", name.UTF8String, ms, steps);
}

/// Jumps the table on show to row, drawing it; reports the time.
static void timeJump(NSString *name, NSInteger row)
{
    NSTableView *tv = findView(gWindow.contentView, NSTableView.class, nil);
    if (!tv || row >= tv.numberOfRows)
        return;
    CFTimeInterval t0 = CACurrentMediaTime();
    [tv scrollRowToVisible:row];
    [gWindow displayIfNeeded];
    printf("ok   time %-31s %7.1f ms\n", name.UTF8String, msSince(t0));
}

/// Opens path and reports how long until it is on screen.
static void timeLoad(FQPreviewController *vc, NSString *name, NSString *path)
{
    CFTimeInterval t0 = CACurrentMediaTime();
    load(vc, path);
    [gWindow displayIfNeeded];
    printf("ok   time %-31s %7.1f ms\n", name.UTF8String, msSince(t0));
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
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app finishLaunching];
        FQPreviewController *vc = [FQPreviewController new];
        gWindow = [NSWindow windowWithContentViewController:vc];
        [gWindow setFrameOrigin:NSMakePoint(60, 60)];
        [gWindow makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        NSView *root = vc.view;

        // Multi-extension file: the HDU menu switches between SCI, ERR and DQ.
        load(vc, [data stringByAppendingPathComponent:@"mef.fits"]);
        capture(@"mef", @"menu=\"HDU 1  SCI — 256 × 256 float32\" (4 items)");
        pickHDU(root, 3);
        capture(@"mef-dq", @"HDU 3 DQ");
        // Its empty primary HDU is listed too, and shows its header.
        pickHDU(root, 0);
        expectListing(@"mef-primary", @"SIMPLE   = T");
        capture(@"mef-primary", @"menu=\"HDU 0 — no data\" (4 items)  \"HDU 0 — no data\"  mode=2 [Image(off)|Table(off)|Header]");
        // In the Header view the menu switches headers; Image shows SCI again.
        pickHDU(root, 1);
        expectListing(@"mef-sci-header", @"——— HDU 1  SCI ———");
        pickMode(root, 0);
        capture(@"mef-sci", @"\"HDU 1 SCI  ·  256 × 256  ·  float32\"");

        // Cube: the slider picks the plane.
        load(vc, [data stringByAppendingPathComponent:@"cube5.fits"]);
        capture(@"cube", @"slider=2 of 4");
        NSSlider *slider = findView(root, NSSlider.class, nil);
        if (slider) {
            slider.doubleValue = 0;
            act(slider);
        }
        capture(@"cube-plane1", @"plane 1 of 5");

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
        capture(@"tables-header", @"\"HDU 2 ASCII  ·  4 rows × 3 columns\"  menu=\"HDU 2  ASCII — 4 rows × 3 "
                                  @"columns\" (3 items)  \"HDU 2  ASCII — 4 rows × 3 columns\"  mode=2");
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
            timeScroll(@"catalog: scroll right", YES, 4);
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
            timeLoad(vc, @"open 200-HDU file", [data stringByAppendingPathComponent:@"many_hdus.fits"]);
            timeSwitch(@"200 HDUs: Image -> Header", 2);
            timeSwitch(@"200 HDUs: Header -> Image", 0);
            timeSwitch(@"200 HDUs: Image -> Header again", 2);
        }

        printf("%d failures\n", gFailures);
    }
    return gFailures ? 1 : 0;
}
