// main.m - the uFits app. Its job is to carry the two Quick Look
// extensions; it also opens FITS files in small viewer windows, shows
// whether the extensions are registered, and updates uFits when a newer
// version is out (asked from its menu, or from the preview's "Update
// available" through ufits://update).

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "FQPreviewController.h"
#import "FQUpdate.h"

#include <unistd.h>

static NSString *const kFITSType = @"gov.nasa.gsfc.fits";

static void FQScheduleChecks(BOOL on);

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation AppDelegate {
    NSWindow *_welcome;
    NSTextField *_status;
    NSButton *_autoCheck;
    NSMutableArray<NSWindow *> *_viewers;
    NSPoint _cascade;
    BOOL _openedFiles, _launched;
    NSString *_updateAsked;   // ufits://update before the launch was done
    NSWindow *_updating;      // while an update runs
}

#pragma mark Launch

- (void)applicationWillFinishLaunching:(NSNotification *)note
{
    (void)note;
    _viewers = [NSMutableArray array];
    [self buildMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    (void)note;
    _launched = YES;
    if (!_openedFiles)
        [self showWelcome:nil];
    FQScheduleChecks(FQUpdate.enabled);   // in case uFits moved
    if (_updateAsked) {
        [self offerUpdate:_updateAsked.length ? _updateAsked : nil];
        _updateAsked = nil;
        return;
    }
    // Once a day: say so when a newer version is out.
    [FQUpdate check:NO
               done:^(NSString *newer, NSError *error) {
                   if (self->_welcome.visible)
                       [self refreshStatus];
                   if (FQUpdate.availableVersion && !self->_updating)
                       [self offerUpdate:FQUpdate.availableVersion];
               }];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    (void)sender;
    return YES;
}

- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls
{
    (void)app;
    for (NSURL *url in urls) {
        if ([url.scheme isEqualToString:@"ufits"]) {
            if ([url.host isEqualToString:@"update"])
                [self updateAsked:url];
            continue;
        }
        _openedFiles = YES;
        [self openViewer:url];
    }
}

/// ufits://update?version=X, from the preview's "Update available".
- (void)updateAsked:(NSURL *)url
{
    NSString *version = @"";
    for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems)
        if ([q.name isEqualToString:@"version"] && q.value.length)
            version = q.value;
    if (!_launched) {   // still launching: once it is done
        _updateAsked = version;
        return;
    }
    [self offerUpdate:version.length ? version : nil];
}

#pragma mark Menu

- (void)buildMenu
{
    NSMenu *bar = [NSMenu new];
    NSString *name = NSProcessInfo.processInfo.processName;

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:name];
    [appMenu addItemWithTitle:[@"About " stringByAppendingString:name]
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItemWithTitle:@"Check for Updates…" action:@selector(checkForUpdates:) keyEquivalent:@""];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:[@"Hide " stringByAppendingString:name]
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    [appMenu addItemWithTitle:[@"Quit " stringByAppendingString:name]
                       action:@selector(terminate:)
                keyEquivalent:@"q"];

    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Open…" action:@selector(openDocument:) keyEquivalent:@"o"];
    [fileMenu addItemWithTitle:@"Quick Look Setup" action:@selector(showWelcome:) keyEquivalent:@""];
    [fileMenu addItem:NSMenuItem.separatorItem];
    [fileMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];

    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:NSMenuItem.separatorItem];
    NSArray *finds = @[ @[ @"Find…", @"f", @(NSTextFinderActionShowFindInterface) ],
                        @[ @"Find Next", @"g", @(NSTextFinderActionNextMatch) ],
                        @[ @"Find Previous", @"G", @(NSTextFinderActionPreviousMatch) ] ];
    for (NSArray *f in finds) {
        NSMenuItem *item = [editMenu addItemWithTitle:f[0]
                                               action:@selector(performTextFinderAction:)
                                        keyEquivalent:f[1]];
        item.tag = [f[2] integerValue];
    }

    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];

    for (NSMenu *m in @[ appMenu, fileMenu, editMenu, windowMenu ]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:m.title action:NULL keyEquivalent:@""];
        item.submenu = m;
        [bar addItem:item];
    }
    NSApp.mainMenu = bar;
    NSApp.windowsMenu = windowMenu;
}

#pragma mark Viewer windows

- (void)openDocument:(id)sender
{
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    if ([panel runModal] == NSModalResponseOK)
        for (NSURL *url in panel.URLs)
            [self openViewer:url];
}

- (void)openViewer:(NSURL *)url
{
    FQPreviewController *vc = [FQPreviewController new];
    vc.maxPixels = 4096;
    __weak AppDelegate *weakSelf = self;
    vc.updateAction = ^(NSString *version) {
        [weakSelf offerUpdate:version];
    };
    NSWindow *w = [NSWindow windowWithContentViewController:vc];
    w.styleMask |= NSWindowStyleMaskResizable;
    w.title = url.lastPathComponent ?: @"FITS";
    w.representedURL = url;
    w.releasedWhenClosed = NO;
    w.delegate = self;
    [_viewers addObject:w];
    [vc loadFile:url.path
        completion:^{
            // Keep the window on screen, shrinking it with its aspect ratio.
            NSSize size = vc.fittingContentSize;
            NSRect vis = (w.screen ?: NSScreen.mainScreen).visibleFrame;
            NSRect frame = [w frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
            CGFloat chrome = NSHeight(frame) - size.height;
            CGFloat k = MIN(1.0, MIN(NSWidth(vis) * 0.92 / size.width,
                                     (NSHeight(vis) * 0.92 - chrome) / size.height));
            NSSize fit = NSMakeSize(floor(size.width * k), floor(size.height * k));
            vc.preferredContentSize = fit;   // the window follows this size
            [w setContentSize:fit];
            if (NSEqualPoints(self->_cascade, NSZeroPoint)) {
                [w center];
                self->_cascade = NSMakePoint(NSMinX(w.frame), NSMaxY(w.frame));
            }
            self->_cascade = [w cascadeTopLeftFromPoint:self->_cascade];
            [w makeKeyAndOrderFront:nil];
        }];
    [NSDocumentController.sharedDocumentController noteNewRecentDocumentURL:url];
}

- (void)windowWillClose:(NSNotification *)note
{
    NSWindow *w = note.object;
    if (w != _welcome)
        [_viewers removeObject:w];
}

#pragma mark Setup window

- (void)showWelcome:(id)sender
{
    (void)sender;
    if (!_welcome) {
        NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, 362)];

        NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
        icon.frame = NSMakeRect(24, 258, 80, 80);
        [v addSubview:icon];

        NSTextField *title = [NSTextField labelWithString:@"uFits"];
        title.font = [NSFont systemFontOfSize:26 weight:NSFontWeightSemibold];
        title.frame = NSMakeRect(120, 302, 380, 34);
        [v addSubview:title];

        NSTextField *sub = [NSTextField labelWithString:@"Fast Quick Look previews and thumbnails for FITS files."];
        sub.textColor = NSColor.secondaryLabelColor;
        sub.frame = NSMakeRect(120, 278, 400, 20);
        [v addSubview:sub];

        NSTextField *how = [NSTextField wrappingLabelWithString:
            @"Select a .fits, .fit, .fts or .fz file in Finder and press Space. Thumbnails appear "
            @"in Finder windows. Nothing needs to keep running: macOS loads the extensions on demand.\n\n"
            @"If previews do not show up, check that uFits is enabled under System Settings › "
            @"General › Login Items & Extensions › Quick Look, then click Reset Quick Look."];
        how.frame = NSMakeRect(24, 142, 492, 110);
        [v addSubview:how];

        _status = [NSTextField wrappingLabelWithString:@""];
        _status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        _status.textColor = NSColor.secondaryLabelColor;
        _status.frame = NSMakeRect(24, 74, 492, 64);
        [v addSubview:_status];

        _autoCheck = [NSButton checkboxWithTitle:@"Check for updates automatically (once a day)"
                                          target:self
                                          action:@selector(autoCheckChanged:)];
        _autoCheck.frame = NSMakeRect(22, 48, 492, 20);
        [v addSubview:_autoCheck];

        NSButton *open = [NSButton buttonWithTitle:@"Open a FITS File…" target:self action:@selector(openDocument:)];
        NSButton *settings = [NSButton buttonWithTitle:@"Extension Settings…" target:self action:@selector(openSettings:)];
        NSButton *reset = [NSButton buttonWithTitle:@"Reset Quick Look" target:self action:@selector(resetQuickLook:)];
        CGFloat x = 24;
        for (NSButton *b in @[ open, settings, reset ]) {
            [b sizeToFit];
            b.frame = NSMakeRect(x, 16, NSWidth(b.frame) + 8, NSHeight(b.frame));
            x = NSMaxX(b.frame) + 8;
            [v addSubview:b];
        }

        _welcome = [[NSWindow alloc] initWithContentRect:v.frame
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable
                                                 backing:NSBackingStoreBuffered
                                                   defer:YES];
        _welcome.title = @"uFits";
        _welcome.contentView = v;
        _welcome.releasedWhenClosed = NO;
        _welcome.delegate = self;
        [_welcome center];
    }
    _autoCheck.state = FQUpdate.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshStatus];
    [_welcome makeKeyAndOrderFront:nil];
    if (@available(macOS 14.0, *))
        [NSApp activate];
    else
        [NSApp activateIgnoringOtherApps:YES];
}

/// Runs a command line tool and returns what it printed.
static NSString *RunTool(NSString *path, NSArray<NSString *> *args)
{
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    if (![task launchAndReturnError:nil])
        return @"";
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

- (void)refreshStatus
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *ident = [UTType typeWithFilenameExtension:@"fits"].identifier ?: @"?";
    if ([ident isEqualToString:kFITSType])
        [lines addObject:@"✓ .fits files are recognised as FITS."];
    else if ([ident hasPrefix:@"dyn."])
        [lines addObject:@"⚠︎ The FITS file type is not registered yet: move uFits to Applications and open it once."];
    else
        [lines addObject:[NSString stringWithFormat:@"⚠︎ Another app declares .fits as “%@”; Quick Look may not use uFits.", ident]];

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    for (NSString *suffix in @[ @"Preview", @"Thumbnail" ]) {
        NSString *ext = [NSString stringWithFormat:@"%@.%@", bundleID, suffix];
        NSString *out = [RunTool(@"/usr/bin/pluginkit", @[ @"-m", @"-i", ext ])
            stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        NSString *state;
        if (!out.length)
            state = @"not registered";
        else if ([out hasPrefix:@"-"])
            state = @"disabled";
        else
            state = @"enabled";
        [lines addObject:[NSString stringWithFormat:@"%@ %@ extension: %@",
                                                    [state isEqualToString:@"enabled"] ? @"✓" : @"⚠︎",
                                                    suffix, state]];
    }
    NSString *now = FQUpdate.currentVersion, *latest = FQUpdate.latestVersion;
    if (latest && [FQUpdate version:latest isNewerThan:now])
        [lines addObject:[NSString stringWithFormat:@"⬆︎ uFits %@ is out (this is %@): uFits › Check for Updates…",
                                                    latest, now]];
    else
        [lines addObject:[NSString stringWithFormat:@"✓ uFits %@%@", now,
                                                    latest ? @" is the latest version." : @"."]];
    _status.stringValue = [lines componentsJoinedByString:@"\n"];
}

- (void)openSettings:(id)sender
{
    (void)sender;
    NSString *pane = @"x-apple.systempreferences:com.apple.ExtensionsPreferences";
    if (@available(macOS 15.0, *))
        pane = @"x-apple.systempreferences:com.apple.LoginItems-Settings.extension";
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:pane]];
}

- (void)resetQuickLook:(id)sender
{
    (void)sender;
    NSURL *plugins = NSBundle.mainBundle.builtInPlugInsURL;
    for (NSString *name in @[ @"uFitsPreview.appex", @"uFitsThumbnail.appex" ])
        RunTool(@"/usr/bin/pluginkit", @[ @"-a", [plugins URLByAppendingPathComponent:name].path ]);
    RunTool(@"/usr/bin/qlmanage", @[ @"-r" ]);
    RunTool(@"/usr/bin/qlmanage", @[ @"-r", @"cache" ]);
    [self refreshStatus];
}

#pragma mark Updates

- (void)autoCheckChanged:(NSButton *)sender
{
    FQUpdate.enabled = sender.state == NSControlStateValueOn;
    FQScheduleChecks(FQUpdate.enabled);
}

/// uFits › Check for Updates…: looks now, and says what it found.
- (void)checkForUpdates:(id)sender
{
    (void)sender;
    FQUpdate.skippedVersion = nil;   // asked for: offer it even if skipped
    [FQUpdate check:YES
               done:^(NSString *newer, NSError *error) {
                   if (self->_welcome.visible)
                       [self refreshStatus];
                   if (newer) {
                       [self offerUpdate:newer];
                       return;
                   }
                   NSAlert *alert = [NSAlert new];
                   if (error) {
                       alert.messageText = @"Could not check for updates";
                       alert.informativeText = error.localizedDescription;
                   } else {
                       alert.messageText = @"uFits is up to date";
                       alert.informativeText = [NSString stringWithFormat:@"%@ is the latest version.",
                                                                          FQUpdate.currentVersion];
                   }
                   [self activate];
                   [alert runModal];
               }];
}

- (void)activate
{
    if (@available(macOS 14.0, *))
        [NSApp activate];
    else
        [NSApp activateIgnoringOtherApps:YES];
}

/// Offers to update to version (nil: the newest seen, looked for first).
- (void)offerUpdate:(NSString *)version
{
    if (_updating)
        return;
    if (!version.length) {
        [FQUpdate check:YES
                   done:^(NSString *newer, NSError *error) {
                       if (newer)
                           [self offerUpdate:newer];
                       else
                           [self checkForUpdates:nil];   // says why not
                   }];
        return;
    }
    if (![FQUpdate version:version isNewerThan:FQUpdate.currentVersion])
        return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"uFits %@ is available", version];
    alert.informativeText = [NSString stringWithFormat:@"You have %@. Updating takes a few seconds: uFits downloads "
                                                       @"the new version, puts it in place of this one and opens it.",
                                                       FQUpdate.currentVersion];
    [alert addButtonWithTitle:@"Update"];
    [alert addButtonWithTitle:@"Not Now"];
    [alert addButtonWithTitle:@"What’s New"];
    alert.showsSuppressionButton = YES;
    alert.suppressionButton.title = @"Skip this version";
    [self activate];
    NSModalResponse answer = [alert runModal];
    if (alert.suppressionButton.state == NSControlStateValueOn)
        FQUpdate.skippedVersion = version;
    if (answer == NSAlertFirstButtonReturn)
        [self runUpdate:version];
    else if (answer == NSAlertThirdButtonReturn)
        [NSWorkspace.sharedWorkspace openURL:[FQUpdate releasePage:version]];
}

/// Where uFits is: updated in place when it can be written to (not, say,
/// a disk image), else where the installer puts it.
- (NSString *)updateFolder
{
    NSString *here = NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent;
    if ([NSFileManager.defaultManager isWritableFileAtPath:here] && ![here hasPrefix:@"/Volumes/"] &&
        [here rangeOfString:@"/AppTranslocation/"].location == NSNotFound)
        return here;
    if ([NSFileManager.defaultManager isWritableFileAtPath:@"/Applications"])
        return @"/Applications";
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
}

/// Runs the installer that comes with release version (install.sh, as the
/// README's one command does), leaving this copy running, then opens the
/// new one and quits.
- (void)runUpdate:(NSString *)version
{
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 84)];
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 34, 16, 16)];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    [spinner startAnimation:nil];
    [v addSubview:spinner];
    NSTextField *label = [NSTextField labelWithString:[NSString stringWithFormat:@"Updating uFits to %@…", version]];
    label.frame = NSMakeRect(46, 33, 300, 18);
    [v addSubview:label];
    _updating = [[NSWindow alloc] initWithContentRect:v.frame
                                            styleMask:NSWindowStyleMaskTitled
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    _updating.title = @"uFits";
    _updating.contentView = v;
    _updating.releasedWhenClosed = NO;
    [_updating center];
    [_updating makeKeyAndOrderFront:nil];
    [NSProcessInfo.processInfo disableAutomaticTermination:@"updating"];
    [NSProcessInfo.processInfo disableSuddenTermination];

    NSString *folder = [self updateFolder];
    NSString *script = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                   [NSString stringWithFormat:@"ufits-install-%@.sh",
                                                                              NSUUID.UUID.UUIDString]];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"UFITS_DEST"] = folder;
    env[@"UFITS_FROM_APP"] = @"1";
    env[@"UFITS_VERSION"] = version;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[ @"-c", @"curl -fsSL --retry 2 -o \"$2\" \"$1\" && /bin/sh \"$2\"; s=$?; rm -f \"$2\"; exit $s",
                        @"sh", [FQUpdate installer:version].absoluteString, script ];
    task.environment = env;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        [self updateFailed:version output:error.localizedDescription];
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *out = [pipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        int status = task.terminationStatus;
        NSString *text = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != 0) {
                [self updateFailed:version output:text];
                return;
            }
            NSURL *app = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"uFits.app"]];
            NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
            config.createsNewApplicationInstance = YES;
            [NSWorkspace.sharedWorkspace openApplicationAtURL:app
                                                configuration:config
                                            completionHandler:^(NSRunningApplication *running, NSError *err) {
                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                    [NSApp terminate:nil];
                                                });
                                            }];
        });
    });
}

- (void)updateFailed:(NSString *)version output:(NSString *)output
{
    [_updating orderOut:nil];
    _updating = nil;
    [NSProcessInfo.processInfo enableAutomaticTermination:@"updating"];
    [NSProcessInfo.processInfo enableSuddenTermination];
    NSArray<NSString *> *lines = [[output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByString:@"\n"];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"uFits could not be updated";
    alert.informativeText = [NSString stringWithFormat:@"%@\n\nThe new version can also be downloaded from its page.",
                                                       lines.lastObject.length ? lines.lastObject : @"The installer failed."];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Open Its Page"];
    [self activate];
    if ([alert runModal] == NSAlertSecondButtonReturn)
        [NSWorkspace.sharedWorkspace openURL:[FQUpdate releasePage:version]];
}

@end

#pragma mark - Looking for updates in the background

/// A launchd job runs uFits --check-for-updates-if-due every four hours
/// (it goes online once a day at most), so that a newer version shows in
/// the preview, which may not go online itself:
/// ~/Library/LaunchAgents/<bundle id>.update.plist.
static NSString *FQAgentLabel(void)
{
    return [NSBundle.mainBundle.bundleIdentifier ?: @"io.github.lmytime.uFits" stringByAppendingString:@".update"];
}

/// Sets up (on) or removes (off) that job, for this copy of uFits.
static void FQScheduleChecks(BOOL on)
{
    NSString *path = [NSString stringWithFormat:@"%@/Library/LaunchAgents/%@.plist", NSHomeDirectory(), FQAgentLabel()];
    NSString *domain = [NSString stringWithFormat:@"gui/%u", getuid()];
    NSString *service = [NSString stringWithFormat:@"%@/%@", domain, FQAgentLabel()];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!on) {
        if ([fm fileExistsAtPath:path]) {
            RunTool(@"/bin/launchctl", @[ @"bootout", service ]);
            [fm removeItemAtPath:path error:nil];
        }
        return;
    }
    // Only where uFits is installed: not from a disk image or a copy that
    // macOS moved aside (App Translocation).
    NSString *exe = NSBundle.mainBundle.executablePath;
    if (!exe || [exe hasPrefix:@"/Volumes/"] || [exe rangeOfString:@"/AppTranslocation/"].location != NSNotFound)
        return;
    NSDictionary *job = @{
        @"Label" : FQAgentLabel(),
        @"ProgramArguments" : @[ exe, @"--check-for-updates-if-due" ],
        @"StartInterval" : @(4 * 3600),
        @"RunAtLoad" : @YES,
        @"ProcessType" : @"Background",
        @"LowPriorityIO" : @YES,
    };
    if ([[NSDictionary dictionaryWithContentsOfFile:path] isEqualToDictionary:job])
        return;   // as it should be (launchd loads it at login)
    [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    if (![job writeToURL:[NSURL fileURLWithPath:path] error:nil])
        return;
    RunTool(@"/bin/launchctl", @[ @"bootout", service ]);
    RunTool(@"/bin/launchctl", @[ @"bootstrap", domain, path ]);
}

/// uFits --check-for-updates: says whether a newer version is out.
static int CheckForUpdates(BOOL force)
{
    __block int status = -1;
    [FQUpdate check:force
               done:^(NSString *newer, NSError *error) {
                   if (error)
                       fprintf(stderr, "uFits: %s\n", error.localizedDescription.UTF8String);
                   else if (newer)
                       printf("uFits %s is out (this is %s)\n", newer.UTF8String, FQUpdate.currentVersion.UTF8String);
                   else
                       printf("uFits %s is the latest version (%s is out)\n", FQUpdate.currentVersion.UTF8String,
                              FQUpdate.latestVersion.UTF8String);
                   status = error ? 1 : 0;
               }];
    while (status < 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    return status;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        // From the command line (and launchd, and install.sh).
        if (argc > 1 && !strcmp(argv[1], "--check-for-updates"))
            return CheckForUpdates(YES);
        if (argc > 1 && !strcmp(argv[1], "--check-for-updates-if-due"))
            return FQUpdate.due ? CheckForUpdates(NO) : 0;
        if (argc > 1 && !strcmp(argv[1], "--schedule-update-checks")) {
            FQScheduleChecks(FQUpdate.enabled);
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
