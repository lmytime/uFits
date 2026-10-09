// main.m - the uFits app. Its job is to carry the two Quick Look
// extensions; it also opens FITS files in small viewer windows and shows
// whether the extensions are registered.

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "FQPreviewController.h"

static NSString *const kFITSType = @"gov.nasa.gsfc.fits";

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation AppDelegate {
    NSWindow *_welcome;
    NSTextField *_status;
    NSMutableArray<NSWindow *> *_viewers;
    NSPoint _cascade;
    BOOL _openedFiles;
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
    if (!_openedFiles)
        [self showWelcome:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    (void)sender;
    return YES;
}

- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls
{
    (void)app;
    _openedFiles = YES;
    for (NSURL *url in urls)
        [self openViewer:url];
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
    NSWindow *w = [NSWindow windowWithContentViewController:vc];
    w.styleMask |= NSWindowStyleMaskResizable;
    w.title = url.lastPathComponent ?: @"FITS";
    w.representedURL = url;
    w.releasedWhenClosed = NO;
    w.delegate = self;
    [_viewers addObject:w];
    [vc loadFile:url.path
        completion:^{
            [w setContentSize:vc.fittingContentSize];
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
        NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, 330)];

        NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
        icon.frame = NSMakeRect(24, 226, 80, 80);
        [v addSubview:icon];

        NSTextField *title = [NSTextField labelWithString:@"uFits"];
        title.font = [NSFont systemFontOfSize:26 weight:NSFontWeightSemibold];
        title.frame = NSMakeRect(120, 270, 380, 34);
        [v addSubview:title];

        NSTextField *sub = [NSTextField labelWithString:@"Fast Quick Look previews and thumbnails for FITS files."];
        sub.textColor = NSColor.secondaryLabelColor;
        sub.frame = NSMakeRect(120, 246, 400, 20);
        [v addSubview:sub];

        NSTextField *how = [NSTextField wrappingLabelWithString:
            @"Select a .fits, .fit, .fts or .fz file in Finder and press Space. Thumbnails appear "
            @"in Finder windows. Nothing needs to keep running: macOS loads the extensions on demand.\n\n"
            @"If previews do not show up, check that uFits is enabled under System Settings › "
            @"General › Login Items & Extensions › Quick Look, then click Reset Quick Look."];
        how.frame = NSMakeRect(24, 110, 492, 110);
        [v addSubview:how];

        _status = [NSTextField wrappingLabelWithString:@""];
        _status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        _status.textColor = NSColor.secondaryLabelColor;
        _status.frame = NSMakeRect(24, 56, 492, 48);
        [v addSubview:_status];

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

@end

int main(int argc, const char *argv[])
{
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
