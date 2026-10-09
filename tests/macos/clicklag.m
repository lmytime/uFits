// clicklag - how long the preview takes to answer a click on its HDU menu
// and on its Image/Table/Header switch: (A) in a window of this process, as
// in the app's viewer windows, and (B) in a QLPreviewView, where the
// installed extension draws the preview in its own process, as in Finder's
// Quick Look panel. Clicks are posted as events (NSEvent into this process;
// CGEvent through the window server when allowed); a menu counts as open
// when its window is on screen, a switch as answered when the window's
// pixels change.
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

static double now(void)
{
    return CACurrentMediaTime();
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

static void dumpTree(NSView *v, int depth)
{
    if (depth > 9)
        return;
    NSRect r = [v convertRect:v.bounds toView:nil];
    printf("   %*s%s %s%s\n", depth * 2, "", NSStringFromClass(v.class).UTF8String, NSStringFromRect(r).UTF8String,
           v.hidden ? " hidden" : "");
    for (NSView *sub in v.subviews)
        dumpTree(sub, depth + 1);
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

static void postMouse(NSWindow *w, NSPoint p, NSEventType type)
{
    NSEvent *e = [NSEvent mouseEventWithType:type
                                    location:p
                               modifierFlags:0
                                   timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:w.windowNumber
                                     context:nil
                                 eventNumber:0
                                  clickCount:1
                                    pressure:type == NSEventTypeLeftMouseDown ? 1 : 0];
    [NSApp postEvent:e atStart:NO];
}

static void cgMouse(NSWindow *w, NSPoint p, CGEventType type)
{
    NSPoint s = [w convertPointToScreen:p];
    CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, CGPointMake(s.x, top - s.y), kCGMouseButtonLeft);
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

static BOOL gCG;   // click with CGEvents (else NSEvents)

static void click(NSWindow *w, NSPoint p)
{
    if (gCG) {
        cgMouse(w, p, kCGEventMouseMoved);
        cgMouse(w, p, kCGEventLeftMouseDown);
        cgMouse(w, p, kCGEventLeftMouseUp);
    } else {
        postMouse(w, p, NSEventTypeLeftMouseDown);
        postMouse(w, p, NSEventTypeLeftMouseUp);
    }
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

static NSDictionary *newWindow(NSDictionary *before)
{
    NSDictionary *all = windows();
    for (NSNumber *n in all)
        if (!before[n] && [all[n][(__bridge id)kCGWindowLayer] intValue] > 0)
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
    for (CFIndex i = 0; i < n; i += 4) {
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

/// Clicks p and returns the ms until the window's pixels change (-1: no change in 3 s).
static double timePixels(NSWindow *w, NSPoint p)
{
    uint64_t base = settled(w);
    double t0 = now();
    click(w, p);
    while (now() - t0 < 3) {
        spin(0.002);
        if (pixels(w) != base)
            return (now() - t0) * 1000;
    }
    return -1;
}

#pragma mark A: in this process

static double gMenuOpened;

static void watchMenus(void)
{
    [NSNotificationCenter.defaultCenter
        addObserverForName:NSMenuDidBeginTrackingNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
                    gMenuOpened = now();
                    NSMenu *menu = note.object;
                    NSTimer *t = [NSTimer timerWithTimeInterval:0.05
                                                        repeats:NO
                                                          block:^(NSTimer *timer) {
                                                              [menu cancelTracking];
                                                          }];
                    [NSRunLoop.currentRunLoop addTimer:t forMode:NSRunLoopCommonModes];
                }];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: clicklag OUTDIR FILE\n");
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
        [app activateIgnoringOtherApps:YES];
        watchMenus();
        BOOL canPost = CGPreflightPostEventAccess();
        printf("double-click interval %.2f s; may post events: %s; accessibility: %s\n", NSEvent.doubleClickInterval,
               canPost ? "yes" : "no", AXIsProcessTrusted() ? "yes" : "no");

        // B's window first, to learn where the extension's view sits.
        NSWindow *qw = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 900, 690)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
        QLPreviewView *pv = [[QLPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 900, 690)
                                                           style:QLPreviewViewStyleNormal];
        qw.contentView = pv;
        [qw makeKeyAndOrderFront:nil];
        pv.previewItem = url;
        spin(5);
        printf("B: views of the QLPreviewView\n");
        dumpTree(pv, 0);
        NSView *remote = remoteView(pv) ?: pv;
        NSRect rframe = [remote convertRect:remote.bounds toView:nil];
        printf("B: the extension's view at %s\n", NSStringFromRect(rframe).UTF8String);
        screenshot(qw, @"ql.png");
        [qw orderOut:nil];

        // A: the same preview in this process, at the same size.
        FQPreviewController *vc = [FQPreviewController new];
        NSWindow *aw = [NSWindow windowWithContentViewController:vc];
        [aw setFrameOrigin:NSMakePoint(80, 80)];
        [aw setContentSize:rframe.size];
        [aw makeKeyAndOrderFront:nil];
        __block BOOL loaded = NO;
        [vc loadFile:path completion:^{
            loaded = YES;
        }];
        for (int i = 0; i < 200 && !loaded; i++)
            spin(0.05);
        spin(1.5);
        [aw setContentSize:rframe.size];
        spin(0.3);
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
        printf("A: HDU menu at %s, switch at %s (content %s)\n", NSStringFromRect(hf).UTF8String,
               NSStringFromRect(sf).UTF8String, NSStringFromSize(root.bounds.size).UTF8String);
        screenshot(aw, @"app.png");

        for (int method = 0; method < 2; method++) {
            gCG = method == 1;
            if (gCG && !canPost)
                break;
            const char *how = gCG ? "CGEvent" : "NSEvent";
            for (int k = 0; k < 3; k++) {
                gMenuOpened = 0;
                double t0 = now();
                click(aw, hduAt);
                while (!gMenuOpened && now() - t0 < 3)
                    spin(0.002);
                printf("A %s: HDU menu open after %7.1f ms\n", how, gMenuOpened ? (gMenuOpened - t0) * 1000 : -1);
                spin(0.4);
            }
            for (int k = 0; k < 2; k++) {
                double header = timePixels(aw, segAt[2]);
                double image = timePixels(aw, segAt[0]);
                printf("A %s: Header shown after %7.1f ms, Image after %7.1f ms (mode now %ld)\n", how, header,
                       image, (long)seg.selectedSegment);
            }
        }
        [aw orderOut:nil];

        // B: clicks on the extension's controls, at the same places.
        [qw makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        spin(1);
        NSPoint off = rframe.origin;
        NSPoint hduB = NSMakePoint(off.x + hduAt.x, off.y + hduAt.y);
        NSPoint segB[3];
        for (int i = 0; i < 3; i++)
            segB[i] = NSMakePoint(off.x + segAt[i].x, off.y + segAt[i].y);
        for (int method = 0; method < 2; method++) {
            gCG = method == 1;
            if (gCG && !canPost)
                break;
            const char *how = gCG ? "CGEvent" : "NSEvent";
            for (int k = 0; k < 3; k++) {
                NSDictionary *before = windows();
                gMenuOpened = 0;
                double t0 = now();
                click(qw, hduB);
                NSDictionary *menu = nil;
                while (!menu && !gMenuOpened && now() - t0 < 3) {
                    spin(0.002);
                    menu = newWindow(before);
                }
                double ms = menu ? (now() - t0) * 1000 : gMenuOpened ? (gMenuOpened - t0) * 1000 : -1;
                printf("B %s: HDU menu open after %7.1f ms (%s, layer %d)\n", how, ms,
                       menu ? [menu[(__bridge id)kCGWindowOwnerName] UTF8String] ?: "?" : gMenuOpened ? "this process" : "none",
                       [menu[(__bridge id)kCGWindowLayer] intValue]);
                if (k == 0 && menu) {
                    spin(0.2);
                    screenshot(nil, [NSString stringWithFormat:@"ql-menu-%s.png", how]);
                }
                // Close it: Escape, or end the process showing it.
                if (menu) {
                    if (canPost)
                        cgKey(53);
                    spin(0.3);
                    if (newWindow(before)) {
                        pid_t pid = [menu[(__bridge id)kCGWindowOwnerPID] intValue];
                        if (pid != getpid()) {
                            printf("   (menu still open: ending process %d to close it)\n", pid);
                            kill(pid, SIGKILL);
                            spin(1);
                            pv.previewItem = nil;
                            spin(0.5);
                            pv.previewItem = url;
                            spin(5);
                        }
                    }
                }
                spin(0.4);
            }
            for (int k = 0; k < 2; k++) {
                double header = timePixels(qw, segB[2]);
                double image = timePixels(qw, segB[0]);
                printf("B %s: Header shown after %7.1f ms, Image after %7.1f ms\n", how, header, image);
            }
        }
        screenshot(qw, @"ql-end.png");
        [pv close];
    }
    return 0;
}
