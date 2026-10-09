// uitest - drive the preview UI (FQPreviewController) in a window the way a
// user would: switch HDUs (images, plots, tables), move the cube plane
// slider, open the header and its find bar. Prints the state of the bar after every step and captures
// the window to OUTDIR/ui-<step>.png.
//
// Usage: uitest OUTDIR TESTDATA_DIR

#import <Cocoa/Cocoa.h>

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
        NSView *cell = [tv viewAtColumn:1 row:0 makeIfNecessary:YES];
        if ([cell isKindOfClass:NSTextField.class])
            first = ((NSTextField *)cell).stringValue;
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

/// Clicks segment i of the mode switch (Image/Plot, Table, Header).
static void pickMode(NSView *root, NSInteger i)
{
    NSSegmentedControl *mode = findView(root, NSSegmentedControl.class, nil);
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
        capture(@"mef", @"menu=\"HDU 1  SCI");
        pickHDU(root, 2);
        capture(@"mef-dq", @"HDU 3 DQ");

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
        pickHDU(root, 1);
        capture(@"sdss-specobj", @"grid=1 rows [#,CLASS,Z] first=\"GALAXY\"");
        capture(@"sdss-specobj-switch", @"mode=1 [Image(off)|Table|Header]");
        pickHDU(root, 0);
        capture(@"sdss-coadd", @"grid=3000 rows");
        pickMode(root, 0);
        capture(@"sdss-plot", @"mode=0 [Plot|Table|Header]");

        // A catalog: sky positions, a field across RA = 0, and its rows.
        load(vc, [data stringByAppendingPathComponent:@"catalog_wrap.fits"]);
        capture(@"catalog", @"DEC vs RA");
        pickMode(root, 1);
        capture(@"catalog-table", @"grid=3000 rows [#,ID,RA,DEC,MAG,NAME]");

        // A file of tables that cannot be plotted opens on its first table;
        // the menu switches tables; the header opens at the table picked, and
        // Cmd-F opens its find bar.
        load(vc, [data stringByAppendingPathComponent:@"tables_mixed.fits"]);
        capture(@"tables", @"menu=\"HDU 1  MIXED — 6 rows × 11 columns\" (2 items)");
        capture(@"tables-grid", @"grid=6 rows [#,NAME,FLAG,BITS");
        pickHDU(root, 1);
        capture(@"tables-ascii", @"grid=4 rows [#,ID,RA,NOTE] first=\"0\"");
        pickMode(root, 2);
        expectListing(@"tables-header", @"——— HDU 2 ———");
        capture(@"tables-header", @"mode=2");
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

        printf("%d failures\n", gFailures);
    }
    return gFailures ? 1 : 0;
}
