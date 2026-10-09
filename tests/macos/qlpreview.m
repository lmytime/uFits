// qlpreview - show files in a QLPreviewView (the machinery behind Finder's
// Quick Look panel, so the installed preview extension is used) and capture
// the window to OUTDIR/<name>.preview.png.
//
// Usage: qlpreview OUTDIR FILE...

#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: qlpreview OUTDIR FILE...\n");
            return 2;
        }
        NSString *outdir = @(argv[1]);
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app finishLaunching];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 900, 690)
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        QLPreviewView *pv = [[QLPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 900, 690)
                                                           style:QLPreviewViewStyleNormal];
        w.contentView = pv;
        [w makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        for (int i = 2; i < argc; i++) {
            NSURL *url = [NSURL fileURLWithPath:@(argv[i])];
            w.title = url.lastPathComponent;
            pv.previewItem = url;
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:4]];
            NSString *png = [outdir stringByAppendingPathComponent:
                                        [url.lastPathComponent stringByAppendingString:@".preview.png"]];
            NSTask *t = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/sbin/screencapture"]
                                                    arguments:@[ @"-x", @"-o",
                                                                 [NSString stringWithFormat:@"-l%ld", (long)w.windowNumber],
                                                                 png ]
                                                        error:nil
                                           terminationHandler:nil];
            [t waitUntilExit];
            printf("%s: shown, capture %s\n", url.lastPathComponent.UTF8String,
                   [NSFileManager.defaultManager fileExistsAtPath:png] ? "saved" : "failed");
        }
        [pv close];
    }
    return 0;
}
