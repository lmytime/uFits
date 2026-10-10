// clicklag - checks that the preview answers clicks at once in Quick Look,
// and that its image zooms there. Shows FILE in a QLPreviewView, where the
// installed extension draws the preview from its own process as in Finder's
// Quick Look panel, clicks its HDU menu and its Image/Table/Header switch
// through the window server, and measures how long until the menu is on
// screen or the window changes. Quick Look holds clicks back for the
// double-click time (half a second) unless the preview lets them through
// (FQLetClicksThrough). Then zooms the image with Option-clicks and
// Option-scrolling (and Command + and 0, which reach the preview only when
// Quick Look passes keys on).
//
// Usage: clicklag OUTDIR FILE   (FILE: several HDUs, its first an image)
// Exit status 1 when the median time to open the menu or to switch is over
// 400 ms, or when the image did not zoom; 0 without checking when this
// process may not post events.
//
//        clicklag OUTDIR FILE --update
// With uFits 99.0.0 noted as out in the app's settings (the caller writes
// it there), checks that the preview shows "Update available" in Quick
// Look and that a click on it opens the uFits app (which it then quits) or,
// if Quick Look will not, says how to update.

#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>
#import <ApplicationServices/ApplicationServices.h>
#include <signal.h>
#include <unistd.h>

#import "FQPreviewController.h"
#import "FQUpdate.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // CGWindowListCreateImage

static const double kLimitMs = 400;   // was 520-850 ms when clicks were held back

static double uptime(void)
{
    return NSProcessInfo.processInfo.systemUptime;
}

static void spin(double seconds)
{
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static id findView(NSView *v, Class cls, BOOL (^test)(id view))
{
    if (v.hidden)
        return nil;
    if ([v isKindOfClass:cls] && (!test || test(v)))
        return v;
    for (NSView *sub in v.subviews) {
        id found = findView(sub, cls, test);
        if (found)
            return found;
    }
    return nil;
}

/// The deepest view whose class says it shows another process.
static NSView *remoteView(NSView *v)
{
    NSView *best = nil;
    for (NSView *sub in v.subviews) {
        NSView *found = remoteView(sub);
        if (found)
            best = found;
    }
    if (!best && [NSStringFromClass(v.class) rangeOfString:@"Remote"].location != NSNotFound)
        best = v;
    return best;
}

static void screenshot(NSWindow *w, NSString *png)
{
    NSTask *t = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/sbin/screencapture"]
                                            arguments:@[ @"-x", @"-o",
                                                         [NSString stringWithFormat:@"-l%ld", (long)w.windowNumber], png ]
                                                error:nil
                                   terminationHandler:nil];
    [t waitUntilExit];
}

static void post(CGEventRef e)
{
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

/// A click at p (window coordinates), held for 30 ms; the uptime of the press.
static double clickWith(NSWindow *w, NSPoint p, CGEventFlags flags)
{
    NSPoint s = [w convertPointToScreen:p];
    CGPoint at = CGPointMake(s.x, NSMaxY(NSScreen.screens.firstObject.frame) - s.y);
    post(CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, at, kCGMouseButtonLeft));
    spin(0.05);
    double pressed = uptime();
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, at, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, at, kCGMouseButtonLeft);
    if (flags) {
        CGEventSetFlags(down, flags);
        CGEventSetFlags(up, flags);
    }
    post(down);
    usleep(30000);
    post(up);
    return pressed;
}

static double click(NSWindow *w, NSPoint p)
{
    return clickWith(w, p, 0);
}

static NSSet<NSNumber *> *windowNumbers(void)
{
    NSMutableSet *out = [NSMutableSet set];
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (NSDictionary *w in (__bridge NSArray *)list)
        [out addObject:w[(__bridge id)kCGWindowNumber]];
    if (list)
        CFRelease(list);
    return out;
}

/// A pop-up menu window on screen that was not in before.
static NSDictionary *newMenu(NSSet<NSNumber *> *before)
{
    NSDictionary *found = nil;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    int level = CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey);
    for (NSDictionary *w in (__bridge NSArray *)list)
        if (!found && ![before containsObject:w[(__bridge id)kCGWindowNumber]] &&
            [w[(__bridge id)kCGWindowLayer] intValue] == level)
            found = w;
    if (list)
        CFRelease(list);
    return found;
}

/// A fingerprint of what the window shows.
static uint64_t pixels(NSWindow *w)
{
    CGImageRef img = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)w.windowNumber,
                                             kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
    if (!img)
        return 0;
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(img));
    const uint8_t *p = CFDataGetBytePtr(data);
    CFIndex n = CFDataGetLength(data);
    uint64_t h = 1469598103934665603ULL;
    for (CFIndex i = 0; i + 2 < n; i += 4) {
        h ^= (uint64_t)p[i] | (uint64_t)p[i + 1] << 8 | (uint64_t)p[i + 2] << 16;
        h *= 1099511628211ULL;
    }
    CFRelease(data);
    CGImageRelease(img);
    return h;
}

/// The uFits apps running.
static NSArray<NSRunningApplication *> *uFitsApps(void)
{
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:@"io.github.lmytime.uFits"];
}

/// A window on screen that was not in before, of the preview (or of Quick
/// Look, showing it).
static NSDictionary *newWindow(NSSet<NSNumber *> *before)
{
    NSDictionary *found = nil;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (NSDictionary *w in (__bridge NSArray *)list) {
        NSString *owner = w[(__bridge id)kCGWindowOwnerName] ?: @"";
        if (!found && ![before containsObject:w[(__bridge id)kCGWindowNumber]] &&
            [w[(__bridge id)kCGWindowOwnerPID] intValue] != getpid() &&
            ([owner hasPrefix:@"uFits"] || [owner rangeOfString:@"QuickLook"].location != NSNotFound)) {
            found = w;
            printf("     (a window of %s came up)\n", owner.UTF8String);
        }
    }
    if (list)
        CFRelease(list);
    return found;
}

/// Clicks "Update available" at p. Quick Look may open the uFits app for
/// the preview (1: then quits it again), or the preview explains in a
/// popover how to update (2); 0: neither within 8 s. *ms: when.
static int clickUpdate(NSWindow *w, NSPoint p, NSString *png, double *ms)
{
    for (NSRunningApplication *a in uFitsApps())
        [a forceTerminate];
    spin(0.5);
    NSSet *before = windowNumbers();
    double t0 = click(w, p);
    int what = 0;
    while (!what && uptime() - t0 < 8) {
        spin(0.05);
        what = uFitsApps().count ? 1 : newWindow(before) ? 2 : 0;
    }
    *ms = (uptime() - t0) * 1000;
    spin(1);   // the app's update offer, or the popover, comes up
    NSTask *t = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/sbin/screencapture"]
                                            arguments:@[ @"-x", png ]
                                                error:nil
                                   terminationHandler:nil];
    [t waitUntilExit];
    for (NSRunningApplication *a in uFitsApps())
        [a forceTerminate];
    return what;
}

/// Clicks the HDU menu: ms until it is open (-1: not in 3 s). Closes it.
static double timeMenu(NSWindow *w, NSPoint p)
{
    NSSet *before = windowNumbers();
    double t0 = click(w, p);
    NSDictionary *menu = nil;
    while (!menu && uptime() - t0 < 3) {
        spin(0.002);
        menu = newMenu(before);
    }
    double ms = menu ? (uptime() - t0) * 1000 : -1;
    if (menu) {
        spin(0.15);
        post(CGEventCreateKeyboardEvent(NULL, 53, true));   // Escape
        post(CGEventCreateKeyboardEvent(NULL, 53, false));
        spin(0.4);
        if (newMenu(before)) {
            printf("     (the menu stayed open: ending the process that shows it)\n");
            kill([menu[(__bridge id)kCGWindowOwnerPID] intValue], SIGKILL);
            spin(1);
        }
    }
    return ms;
}

/// A fingerprint of what the window shows once it stops changing.
static uint64_t stillPixels(NSWindow *w)
{
    uint64_t base = pixels(w);
    for (int i = 0; i < 40; i++) {
        spin(0.15);
        uint64_t now = pixels(w);
        if (now == base)
            break;
        base = now;
    }
    return base;
}

/// Clicks p: ms until the window changes (-1: not in 3 s).
static double timeSwitch(NSWindow *w, NSPoint p)
{
    uint64_t base = stillPixels(w);
    double t0 = click(w, p);
    while (uptime() - t0 < 3) {
        spin(0.002);
        if (pixels(w) != base)
            return (uptime() - t0) * 1000;
    }
    return -1;
}

/// A fingerprint of the part r (window coordinates) of what the window shows.
static uint64_t partPixels(NSWindow *w, NSRect r)
{
    NSRect s = [w convertRectToScreen:r];
    CGRect at = CGRectMake(NSMinX(s), NSMaxY(NSScreen.screens.firstObject.frame) - NSMaxY(s), NSWidth(s), NSHeight(s));
    CGImageRef img = CGWindowListCreateImage(at, kCGWindowListOptionIncludingWindow, (CGWindowID)w.windowNumber,
                                             kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
    if (!img)
        return 0;
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(img));
    const uint8_t *p = CFDataGetBytePtr(data);
    CFIndex n = CFDataGetLength(data);
    uint64_t h = 1469598103934665603ULL;
    for (CFIndex i = 0; i + 2 < n; i += 4) {
        h ^= (uint64_t)p[i] | (uint64_t)p[i + 1] << 8 | (uint64_t)p[i + 2] << 16;
        h *= 1099511628211ULL;
    }
    CFRelease(data);
    CGImageRelease(img);
    return h;
}

/// Waits up to 3 s for the part r of the window to differ from base (or,
/// with same, to be base again): ms since t0, -1 if it did not.
static double waitPart(NSWindow *w, NSRect r, uint64_t base, BOOL same, double t0)
{
    while (uptime() - t0 < 3) {
        spin(0.005);
        if ((partPixels(w, r) == base) == same)
            return (uptime() - t0) * 1000;
    }
    return -1;
}

/// Scrolls up at p with Option held.
static double optionScroll(NSWindow *w, NSPoint p)
{
    NSPoint s = [w convertPointToScreen:p];
    CGPoint at = CGPointMake(s.x, NSMaxY(NSScreen.screens.firstObject.frame) - s.y);
    post(CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, at, kCGMouseButtonLeft));
    spin(0.1);
    double t0 = uptime();
    for (int i = 0; i < 8; i++) {
        CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, 16);
        CGEventSetLocation(e, at);
        CGEventSetFlags(e, kCGEventFlagMaskAlternate);
        post(e);
        usleep(8000);
    }
    return t0;
}

/// A key pressed with Command held.
static double commandKey(CGKeyCode key)
{
    double t0 = uptime();
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, key, true), up = CGEventCreateKeyboardEvent(NULL, key, false);
    CGEventSetFlags(down, kCGEventFlagMaskCommand);
    CGEventSetFlags(up, kCGEventFlagMaskCommand);
    post(down);
    post(up);
    return t0;
}

/// Zooming the image in Quick Look: Option-click in, Shift-Option-click
/// out, Option-scrolling, Command + and Command 0. area: where the picture
/// is; the margin beside the image, shown whole, is covered when zoomed in.
/// The number of ways that did not zoom.
static int checkZoom(NSWindow *w, NSRect area)
{
    NSRect margin = NSMakeRect(NSMinX(area) + 8, NSMidY(area) - 40, 40, 80);
    NSPoint mid = NSMakePoint(NSMidX(area), NSMidY(area));
    stillPixels(w);
    uint64_t whole = partPixels(w, margin);
    int failed = 0;

    double in = waitPart(w, margin, whole, NO, clickWith(w, mid, kCGEventFlagMaskAlternate));
    spin(0.7);   // not a double click
    double out = waitPart(w, margin, whole, YES, clickWith(w, mid, kCGEventFlagMaskAlternate | kCGEventFlagMaskShift));
    printf("     Option-click zoomed in after %6.1f ms, Shift-Option-click out after %6.1f ms\n", in, out);
    failed += in < 0 || out < 0;
    spin(0.7);

    double scrolled = waitPart(w, margin, whole, NO, optionScroll(w, mid));
    printf("     Option-scrolling zoomed in after %6.1f ms\n", scrolled);
    failed += scrolled < 0;
    for (int i = 0; i < 4; i++) {   // back to the whole image
        clickWith(w, mid, kCGEventFlagMaskAlternate | kCGEventFlagMaskShift);
        spin(0.7);
    }
    if (waitPart(w, margin, whole, YES, uptime()) < 0) {
        printf("     (the whole image did not come back)\n");
        return failed;
    }

    // Keys reach the preview only if Quick Look passes them on (it does
    // not have to: not checked).
    double plus = waitPart(w, margin, whole, NO, commandKey(24));    // =
    double zero = plus < 0 ? -1 : waitPart(w, margin, whole, YES, commandKey(29));   // 0
    printf("     Command + zoomed in after %6.1f ms, Command 0 showed it whole after %6.1f ms%s\n", plus, zero,
           plus < 0 ? " (keys not passed on)" : "");
    return failed;
}

static double median(NSMutableArray<NSNumber *> *ms)
{
    [ms sortUsingSelector:@selector(compare:)];
    return ms.count ? ms[ms.count / 2].doubleValue : -1;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: clicklag OUTDIR FILE [--update]\n");
            return 2;
        }
        NSString *out = @(argv[1]), *path = @(argv[2]);
        BOOL update = argc > 3 && !strcmp(argv[3], "--update");
        // The layout here has "Update available" where the preview has it:
        // nowhere, or (--update) as if uFits 99.0.0 had just been seen.
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setBool:update forKey:@"FQCheckForUpdates"];
        [d setObject:@"99.0.0" forKey:@"FQUpdateLatest"];
        [d setObject:[NSDate date] forKey:@"FQUpdateChecked"];
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app finishLaunching];
        if (!CGPreflightPostEventAccess()) {
            printf("skipped: this process may not post events\n");
            return 0;
        }
        NSRect vis = NSScreen.mainScreen.visibleFrame;   // clear of the Dock
        NSSize size = NSMakeSize(MIN(720, NSWidth(vis) - 40), MIN(500, NSHeight(vis) - 60));
        NSRect place = NSMakeRect(floor(NSMidX(vis) - size.width / 2), floor(NSMidY(vis) - size.height / 2 - 14),
                                  size.width, size.height);

        // Where the controls are: the same preview laid out in this process.
        FQPreviewController *vc = [FQPreviewController new];
        NSWindow *layout = [[NSWindow alloc] initWithContentRect:place
                                                       styleMask:NSWindowStyleMaskTitled
                                                         backing:NSBackingStoreBuffered
                                                           defer:YES];
        layout.contentView = vc.view;
        __block BOOL loaded = NO;
        [vc loadFile:path completion:^{
            loaded = YES;
        }];
        for (int i = 0; i < 200 && !loaded; i++)
            spin(0.05);
        spin(0.5);
        NSView *root = vc.view;
        NSPopUpButton *hdu = findView(root, NSPopUpButton.class, ^BOOL(id v) {
            return [((NSPopUpButton *)v).itemArray.firstObject.title hasPrefix:@"HDU"];
        });
        NSSegmentedControl *seg = findView(root, NSSegmentedControl.class, nil);
        if (!hdu || !seg) {
            printf("FAIL no HDU menu or mode switch in the preview of %s\n", path.lastPathComponent.UTF8String);
            return 1;
        }
        NSButton *notice = findView(root, NSButton.class, ^BOOL(id v) {
            return [[v title] isEqualToString:@"Update available"];
        });
        // It is at the left end of the bar; if not here, say why.
        NSRect nf = notice ? [notice convertRect:notice.bounds toView:root] : NSMakeRect(10, 5, 100, 20);
        if (update && !notice) {
            printf("     (no \"Update available\" laid out here: available %s, latest %s, checks %s; the bar:)\n",
                   FQUpdate.availableVersion.UTF8String ?: "-", FQUpdate.latestVersion.UTF8String ?: "-",
                   FQUpdate.enabled ? "on" : "off");
            for (NSView *v in root.subviews) {
                NSRect f = [v convertRect:v.bounds toView:root];
                if (NSMinY(f) < 30)
                    printf("       %s%s %s %s\n", v.hidden ? "(hidden) " : "", NSStringFromClass(v.class).UTF8String,
                           NSStringFromRect(f).UTF8String,
                           [v isKindOfClass:NSButton.class] ? [(NSButton *)v title].UTF8String : "");
            }
        }
        NSRect hf = [hdu convertRect:hdu.bounds toView:root], sf = [seg convertRect:seg.bounds toView:root];

        // The extension's preview, in a QLPreviewView.
        NSWindow *w = [[NSWindow alloc] initWithContentRect:place
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        QLPreviewView *pv = [[QLPreviewView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)
                                                           style:QLPreviewViewStyleNormal];
        w.contentView = pv;
        [w makeKeyAndOrderFront:nil];
        pv.previewItem = [NSURL fileURLWithPath:path];
        spin(5);
        NSView *remote = remoteView(pv) ?: pv;
        NSRect rf = [remote convertRect:remote.bounds toView:nil];
        screenshot(w, [out stringByAppendingPathComponent:@"ui-clicks.png"]);
        // The bar is laid out from its right edge: so are the clicks.
        CGFloat dx = NSMaxX(rf) - NSWidth(root.bounds), dy = NSMinY(rf);
        NSPoint menuAt = NSMakePoint(dx + NSMidX(hf), dy + NSMidY(hf));
        if (update) {
            // "Update available" is on the left of the bar.
            screenshot(w, [out stringByAppendingPathComponent:@"ui-update-ql.png"]);
            double ms = 0;
            int what = clickUpdate(w, NSMakePoint(NSMinX(rf) + NSMidX(nf), dy + NSMidY(nf)),
                                   [out stringByAppendingPathComponent:@"ui-update-click.png"], &ms);
            [pv close];
            printf("%s update in Quick Look: a click on \"Update available\" %s\n", what ? "ok  " : "FAIL",
                   what == 1   ? [NSString stringWithFormat:@"opened uFits after %.0f ms", ms].UTF8String
                   : what == 2 ? [NSString stringWithFormat:@"explained how to update after %.0f ms (Quick Look "
                                                            @"did not open uFits)",
                                                            ms].UTF8String
                               : "neither opened uFits nor explained how to update");
            return what ? 0 : 1;
        }
        NSPoint imageAt = NSMakePoint(dx + NSMinX(sf) + NSWidth(sf) / 6, dy + NSMidY(sf));
        NSPoint headerAt = NSMakePoint(dx + NSMinX(sf) + NSWidth(sf) * 5 / 6, dy + NSMidY(sf));

        NSMutableArray<NSNumber *> *menus = [NSMutableArray array], *switches = [NSMutableArray array];
        for (int k = 0; k < 3; k++) {
            double ms = timeMenu(w, menuAt);
            printf("     HDU menu open after %6.1f ms\n", ms);
            [menus addObject:@(ms < 0 ? 1e9 : ms)];
        }
        for (int k = 0; k < 2; k++) {
            double header = timeSwitch(w, headerAt), image = timeSwitch(w, imageAt);
            printf("     Header shown after %6.1f ms, Image after %6.1f ms\n", header, image);
            [switches addObject:@(header < 0 ? 1e9 : header)];
            [switches addObject:@(image < 0 ? 1e9 : image)];
        }
        // The image (Image was clicked last) zooms.
        int zoomFailed = checkZoom(w, NSMakeRect(NSMinX(rf), NSMinY(rf) + 30, NSWidth(rf), NSHeight(rf) - 30));
        screenshot(w, [out stringByAppendingPathComponent:@"ui-clicks-zoom.png"]);
        [pv close];

        double m = median(menus), s = median(switches);
        BOOL ok = m <= kLimitMs && s <= kLimitMs;
        printf("%s clicks in Quick Look: HDU menu open after %.0f ms, mode switched after %.0f ms (medians; "
               "limit %.0f ms)\n",
               ok ? "ok  " : "FAIL", m, s, kLimitMs);
        printf("%s zoom in Quick Look: %s\n", zoomFailed ? "FAIL" : "ok  ",
               zoomFailed ? "Option-click or Option-scrolling did not zoom" : "Option-click and Option-scrolling zoom");
        return ok && !zoomFailed ? 0 : 1;
    }
}
