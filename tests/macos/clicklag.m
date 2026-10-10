// clicklag - how long the preview takes to answer a click on its HDU menu
// and on its Image/Table/Header switch: (A) in a window of this process, as
// in the app's viewer windows, and (B) in a QLPreviewView, where the
// installed extension shows the preview from its own process, as in
// Finder's Quick Look panel. Clicks go through the window server (CGEvent);
// a menu counts as open when its window is on screen, a switch as answered
// when the window's pixels change. Each kind of click is also made with the
// mouse moving a little between press and release, which ends any wait for
// a second click of a double click at once.
//
// Usage: clicklag OUTDIR FILE [TAG]   (FILE: several HDUs, its first an
// image; TAG goes into the names of the screenshots)

#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>
#import <QuartzCore/QuartzCore.h>
#import <ApplicationServices/ApplicationServices.h>
#include <signal.h>
#include <unistd.h>

#import "FQPreviewController.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // CGWindowListCreateImage

static NSString *gOut, *gTag = @"";

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

/// The deepest view whose class looks like a view of another process.
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

/// Captures the window (or the whole screen) to OUTDIR/ui-clicklag[-TAG]-name.
static void screenshot(NSWindow *w, NSString *name)
{
    NSString *png = [gOut stringByAppendingPathComponent:[NSString stringWithFormat:@"ui-clicklag%@-%@", gTag, name]];
    NSArray *args = w ? @[ @"-x", @"-o", [NSString stringWithFormat:@"-l%ld", (long)w.windowNumber], png ] : @[ @"-x", png ];
    NSTask *t = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/sbin/screencapture"]
                                            arguments:args
                                                error:nil
                                   terminationHandler:nil];
    [t waitUntilExit];
}

#pragma mark Events

static void cgMouseAt(NSPoint screen, CGEventType type)
{
    CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, CGPointMake(screen.x, top - screen.y), kCGMouseButtonLeft);
    CGEventSetIntegerValueField(e, kCGMouseEventClickState, 1);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

static void cgKey(CGKeyCode key)
{
    for (int down = 1; down >= 0; down--) {
        CGEventRef e = CGEventCreateKeyboardEvent(NULL, key, down);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
    }
}

/// A click at p (window coordinates); moving: the mouse moves 8 points
/// between press and release.
static double click(NSWindow *w, NSPoint p, BOOL moving)
{
    NSPoint s = [w convertPointToScreen:p];
    cgMouseAt(s, kCGEventMouseMoved);
    spin(0.05);
    double at = uptime();
    cgMouseAt(s, kCGEventLeftMouseDown);
    if (moving) {
        for (int i = 1; i <= 4; i++) {
            usleep(8000);
            cgMouseAt(NSMakePoint(s.x + 2 * i, s.y), kCGEventLeftMouseDragged);
        }
        cgMouseAt(NSMakePoint(s.x + 8, s.y), kCGEventLeftMouseUp);
    } else {
        usleep(30000);
        cgMouseAt(s, kCGEventLeftMouseUp);
    }
    return at;
}

#pragma mark Screen

/// On-screen windows: number -> description.
static NSDictionary<NSNumber *, NSDictionary *> *windows(void)
{
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (NSDictionary *w in (__bridge NSArray *)list)
        out[w[(__bridge id)kCGWindowNumber]] = w;
    if (list)
        CFRelease(list);
    return out;
}

static NSDictionary *newMenu(NSDictionary *before)
{
    NSDictionary *all = windows();
    int level = CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey);
    for (NSNumber *n in all)
        if (!before[n] && [all[n][(__bridge id)kCGWindowLayer] intValue] == level)
            return all[n];
    return nil;
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

/// Waits for the window to stop changing; its fingerprint then.
static uint64_t settled(NSWindow *w)
{
    uint64_t a = pixels(w);
    for (int i = 0; i < 40; i++) {
        spin(0.15);
        uint64_t b = pixels(w);
        if (a == b)
            return a;
        a = b;
    }
    return a;
}

#pragma mark Measurements

static double gMenuOpened;   // a menu of this process began tracking

static void watchMenus(void)
{
    [NSNotificationCenter.defaultCenter
        addObserverForName:NSMenuDidBeginTrackingNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
                    gMenuOpened = uptime();
                    NSMenu *menu = note.object;
                    NSTimer *t = [NSTimer timerWithTimeInterval:0.05
                                                        repeats:NO
                                                          block:^(NSTimer *timer) {
                                                              [menu cancelTracking];
                                                          }];
                    [NSRunLoop.currentRunLoop addTimer:t forMode:NSRunLoopCommonModes];
                }];
}

/// Clicks the HDU menu; ms until a menu is open (-1: none in 3 s). Closes it.
static double timeMenu(NSWindow *w, NSPoint p, BOOL moving, double *at, NSString **who)
{
    NSDictionary *before = windows();
    gMenuOpened = 0;
    double t0 = *at = click(w, p, moving);
    NSDictionary *menu = nil;
    while (!menu && !gMenuOpened && uptime() - t0 < 3) {
        spin(0.002);
        menu = newMenu(before);
    }
    double ms = menu ? (uptime() - t0) * 1000 : gMenuOpened ? (gMenuOpened - t0) * 1000 : -1;
    *who = menu ? (menu[(__bridge id)kCGWindowOwnerName] ?: @"?") : gMenuOpened ? @"this process" : @"none";
    if (menu) {
        spin(0.15);
        cgKey(53);   // Escape
        spin(0.4);
        if (newMenu(before)) {
            pid_t pid = [menu[(__bridge id)kCGWindowOwnerPID] intValue];
            printf("   (the menu stayed open: ending process %d)\n", pid);
            if (pid != getpid())
                kill(pid, SIGKILL);
            spin(1);
        }
    }
    spin(0.3);
    return ms;
}

/// Clicks p; ms until the window's pixels change (-1: no change in 3 s).
static double timePixels(NSWindow *w, NSPoint p, BOOL moving, double *at)
{
    uint64_t base = settled(w);
    double t0 = *at = click(w, p, moving);
    while (uptime() - t0 < 3) {
        spin(0.002);
        if (pixels(w) != base)
            return (uptime() - t0) * 1000;
    }
    return -1;
}

static void measure(const char *where, NSWindow *w, NSPoint hduAt, const NSPoint *segAt)
{
    for (int moving = 0; moving < 2; moving++) {
        const char *how = moving ? "click with a move" : "click";
        for (int k = 0; k < 3; k++) {
            double at;
            NSString *who;
            double ms = timeMenu(w, hduAt, moving, &at, &who);
            printf("%s %-17s HDU menu open after %7.1f ms (%s; pressed at %.3f)\n", where, how, ms, who.UTF8String, at);
        }
        for (int k = 0; k < 2; k++) {
            double at1, at2;
            double header = timePixels(w, segAt[2], moving, &at1);
            double image = timePixels(w, segAt[0], moving, &at2);
            printf("%s %-17s Header shown after %7.1f ms (pressed at %.3f), Image after %7.1f ms (pressed at %.3f)\n",
                   where, how, header, at1, image, at2);
        }
    }
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: clicklag OUTDIR FILE [TAG]\n");
            return 2;
        }
        gOut = @(argv[1]);
        NSString *path = @(argv[2]);
        if (argc > 3)
            gTag = [@"-" stringByAppendingString:@(argv[3])];
        NSURL *url = [NSURL fileURLWithPath:path];
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app finishLaunching];
        watchMenus();
        if (!CGPreflightPostEventAccess()) {
            printf("cannot post events: no measurements\n");
            return 0;
        }
        NSRect vis = NSScreen.mainScreen.visibleFrame;
        NSSize size = NSMakeSize(MIN(720, NSWidth(vis) - 40), MIN(500, NSHeight(vis) - 60));
        NSRect place = NSMakeRect(floor(NSMidX(vis) - size.width / 2), floor(NSMidY(vis) - size.height / 2 - 14),
                                  size.width, size.height);
        printf("double-click interval %.2f s; screen %s, visible %s, content at %s\n", NSEvent.doubleClickInterval,
               NSStringFromRect(NSScreen.mainScreen.frame).UTF8String, NSStringFromRect(vis).UTF8String,
               NSStringFromRect(place).UTF8String);

        // A: the preview in this process, in a panel that takes clicks
        // without this app being the active one.
        FQPreviewController *vc = [FQPreviewController new];
        NSPanel *aw = [[NSPanel alloc] initWithContentRect:place
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskNonactivatingPanel
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
        aw.becomesKeyOnlyIfNeeded = NO;
        aw.hidesOnDeactivate = NO;
        aw.contentView = vc.view;
        [aw makeKeyAndOrderFront:nil];
        __block BOOL loaded = NO;
        [vc loadFile:path completion:^{
            loaded = YES;
        }];
        for (int i = 0; i < 200 && !loaded; i++)
            spin(0.05);
        [aw setContentSize:size];
        spin(1.5);
        NSView *root = aw.contentView;
        NSPopUpButton *hdu = findView(root, NSPopUpButton.class, ^BOOL(id v) {
            return [((NSPopUpButton *)v).itemArray.firstObject.title hasPrefix:@"HDU"];
        });
        NSSegmentedControl *seg = findView(root, NSSegmentedControl.class, nil);
        if (!hdu || !seg) {
            printf("A: no HDU menu or mode switch found\n");
            return 1;
        }
        NSRect hf = [hdu convertRect:hdu.bounds toView:nil], sf = [seg convertRect:seg.bounds toView:nil];
        NSPoint hduAt = NSMakePoint(NSMidX(hf), NSMidY(hf));
        NSPoint segAt[3];
        for (int i = 0; i < 3; i++)
            segAt[i] = NSMakePoint(NSMinX(sf) + (i + 0.5) * NSWidth(sf) / 3, NSMidY(sf));
        printf("A: HDU menu at %s, switch at %s, content %s\n", NSStringFromRect(hf).UTF8String,
               NSStringFromRect(sf).UTF8String, NSStringFromSize(root.bounds.size).UTF8String);
        screenshot(aw, @"app.png");
        measure("A (app)        ", aw, hduAt, segAt);
        [aw orderOut:nil];

        // B: the extension in a QLPreviewView of the same size, clicked at
        // the same places.
        NSWindow *qw = [[NSWindow alloc] initWithContentRect:place
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
        QLPreviewView *pv = [[QLPreviewView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)
                                                           style:QLPreviewViewStyleNormal];
        qw.contentView = pv;
        [qw makeKeyAndOrderFront:nil];
        pv.previewItem = url;
        spin(5);
        NSView *remote = remoteView(pv) ?: pv;
        NSRect rframe = [remote convertRect:remote.bounds toView:nil];
        printf("B: the extension's view at %s\n", NSStringFromRect(rframe).UTF8String);
        screenshot(qw, @"ql.png");
        CGFloat dx = NSMaxX(rframe) - NSWidth(root.bounds), dy = NSMinY(rframe);
        NSPoint hduB = NSMakePoint(dx + hduAt.x, dy + hduAt.y);
        NSPoint segB[3];
        for (int i = 0; i < 3; i++)
            segB[i] = NSMakePoint(dx + segAt[i].x, dy + segAt[i].y);
        measure("B (Quick Look) ", qw, hduB, segB);
        screenshot(qw, @"ql-end.png");
        [pv close];
    }
    return 0;
}
