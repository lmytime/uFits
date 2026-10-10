// clicklag - checks that the preview answers clicks at once in Quick Look.
// Shows FILE in a QLPreviewView, where the installed extension draws the
// preview from its own process as in Finder's Quick Look panel, clicks its
// HDU menu and its Image/Table/Header switch through the window server, and
// measures how long until the menu is on screen or the window changes.
// Quick Look holds clicks back for the double-click time (half a second)
// unless the preview lets them through (FQLetClicksThrough).
//
// Usage: clicklag OUTDIR FILE   (FILE: several HDUs, its first an image)
// Exit status 1 when the median time to open the menu or to switch is over
// 400 ms; 0 without checking when this process may not post events.

#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>
#import <ApplicationServices/ApplicationServices.h>
#include <signal.h>
#include <unistd.h>

#import "FQPreviewController.h"

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
static double click(NSWindow *w, NSPoint p)
{
    NSPoint s = [w convertPointToScreen:p];
    CGPoint at = CGPointMake(s.x, NSMaxY(NSScreen.screens.firstObject.frame) - s.y);
    post(CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, at, kCGMouseButtonLeft));
    spin(0.05);
    double pressed = uptime();
    post(CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, at, kCGMouseButtonLeft));
    usleep(30000);
    post(CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, at, kCGMouseButtonLeft));
    return pressed;
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

/// Clicks p: ms until the window changes (-1: not in 3 s).
static double timeSwitch(NSWindow *w, NSPoint p)
{
    uint64_t base = pixels(w);
    for (int i = 0; i < 40; i++) {   // until it is still
        spin(0.15);
        uint64_t now = pixels(w);
        if (now == base)
            break;
        base = now;
    }
    double t0 = click(w, p);
    while (uptime() - t0 < 3) {
        spin(0.002);
        if (pixels(w) != base)
            return (uptime() - t0) * 1000;
    }
    return -1;
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
            fprintf(stderr, "usage: clicklag OUTDIR FILE\n");
            return 2;
        }
        NSString *out = @(argv[1]), *path = @(argv[2]);
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
        [pv close];

        double m = median(menus), s = median(switches);
        BOOL ok = m <= kLimitMs && s <= kLimitMs;
        printf("%s clicks in Quick Look: HDU menu open after %.0f ms, mode switched after %.0f ms (medians; "
               "limit %.0f ms)\n",
               ok ? "ok  " : "FAIL", m, s, kLimitMs);
        return ok ? 0 : 1;
    }
}
