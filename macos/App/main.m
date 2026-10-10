// main.m - the uFits app. Its job is to carry the two Quick Look
// extensions; it also opens FITS and XISF files in small viewer windows, shows
// whether the extensions are registered, and updates uFits when a newer
// version is out (asked from its menu, or from the preview's "Update
// available" through ufits://update).

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "FQPreviewController.h"
#import "FQUpdate.h"

#include <unistd.h>

static NSString *const kFITSType = @"gov.nasa.gsfc.fits";
static NSString *const kXISFType = @"io.github.lmytime.ufits.xisf";

/// The extensions uFits claims (Info.plist): FITS, tile-compressed FITS,
/// the FITS files of X-ray missions, and XISF images.
static NSArray<NSString *> *FQExtensions(void)
{
    return @[ @"fits", @"fit", @"fts", @"fz", @"pha", @"pi", @"arf", @"rmf", @"rsp", @"rsp2", @"evt", @"lc", @"img",
              @"hk", @"mkf", @"dph", @"xisf" ];
}

/// Types of other files that the preview takes too, handing back those
/// that are not FITS (Preview/Info.plist): to macOS, .img is a disk image.
static BOOL FQAlsoPreviewed(UTType *t)
{
    return [t.identifier isEqualToString:@"com.apple.disk-image-udif"];
}

/// Those that macOS takes for something that Quick Look does not show with
/// uFits (another app's type), with what it takes them for.
static NSDictionary<NSString *, UTType *> *FQExtensionsElsewhere(void)
{
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    UTType *fits = [UTType typeWithIdentifier:kFITSType];
    UTType *xisf = [UTType typeWithIdentifier:kXISFType];
    for (NSString *ext in FQExtensions()) {
        UTType *t = [UTType typeWithFilenameExtension:ext];
        if (!t || !((fits && [t conformsToType:fits]) ||
                    (xisf && [t conformsToType:xisf]) || FQAlsoPreviewed(t)))
            out[ext] = t ?: UTTypeData;
    }
    return out;
}

static void FQScheduleChecks(BOOL on);

#pragma mark App icon

/// The icon setting: "auto", the app's own icon (Dusk; on macOS 26 the light
/// one in light mode), or always "dusk" or always "light".
static NSString *const kIconKey = @"FQAppIcon";
static NSArray<NSString *> *FQIconChoices(void)
{
    return @[ @"auto", @"dusk", @"light" ];
}

static NSString *FQIconChoice(void)
{
    NSString *choice = [FQSettings() stringForKey:kIconKey];
    return [FQIconChoices() containsObject:choice] ? choice : @"auto";
}

/// The icon of choice (nil for "auto"), from the app's resources.
static NSImage *FQIconImage(NSString *choice)
{
    NSString *name = [choice isEqualToString:@"light"] ? @"AppIconLight"
                     : [choice isEqualToString:@"dusk"] ? @"AppIcon"
                                                        : nil;
    return name ? [[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:name ofType:@"icns"]]
                : nil;
}

/// Whether the app has a custom icon (Finder keeps a folder's in a file
/// named "Icon\r" in it).
static BOOL FQHasCustomIcon(void)
{
    return [NSFileManager.defaultManager
        fileExistsAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Icon\r"]];
}

/// Shows the icon of choice for uFits in Finder, Launchpad and the Dock: a
/// custom icon on the app (a Mac app has no other way to change its icon),
/// none for "auto". NO when the app cannot be changed (a disk image).
static BOOL FQApplyIcon(NSString *choice)
{
    NSImage *image = FQIconImage(choice);
    if (!image && ![choice isEqualToString:@"auto"])
        return NO;
    BOOL ok = [NSWorkspace.sharedWorkspace setIcon:image forFile:NSBundle.mainBundle.bundlePath options:0];
    if (ok && NSApp)
        NSApp.applicationIconImage = image;   // the Dock, at once (nil: the app's own)
    return ok;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation AppDelegate {
    NSWindow *_welcome;
    NSTextField *_status;
    NSButton *_autoCheck, *_thumbnails, *_removeCopies;
    NSPopUpButton *_stretch, *_appIcon;
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
    // An update replaces the app, and its custom icon with it.
    if (![FQIconChoice() isEqualToString:@"auto"] && !FQHasCustomIcon())
        FQApplyIcon(FQIconChoice());
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
                       action:@selector(showAbout:)
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

/// A label wrapping at width points.
static NSTextField *FQWrappingLabel(NSString *text, CGFloat width)
{
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.preferredMaxLayoutWidth = width;
    [label.widthAnchor constraintEqualToConstant:width].active = YES;
    return label;
}

/// views side by side, centred on one line.
static NSStackView *FQRow(NSArray<NSView *> *views, CGFloat spacing)
{
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = spacing;
    return row;
}

- (void)showWelcome:(id)sender
{
    (void)sender;
    if (!_welcome) {
        const CGFloat width = 500;
        NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
        [icon.widthAnchor constraintEqualToConstant:72].active = YES;
        [icon.heightAnchor constraintEqualToConstant:72].active = YES;
        NSTextField *title = [NSTextField labelWithString:@"uFits"];
        title.font = [NSFont systemFontOfSize:26 weight:NSFontWeightSemibold];
        NSTextField *sub = [NSTextField
            labelWithString:[NSString stringWithFormat:@"Quick Look for FITS and XISF files · version %@",
                                                       FQUpdate.currentVersion]];
        sub.textColor = NSColor.secondaryLabelColor;
        NSStackView *names = [NSStackView stackViewWithViews:@[ title, sub ]];
        names.orientation = NSUserInterfaceLayoutOrientationVertical;
        names.alignment = NSLayoutAttributeLeading;
        names.spacing = 2;

        NSTextField *how = FQWrappingLabel(
            @"Select a FITS or XISF file in Finder and press Space. Finder shows thumbnails in its icon "
            @"and gallery views. Nothing needs to keep running: macOS loads the Quick Look extensions of "
            @"uFits when they are needed. If previews do not show up, check that uFits is on under "
            @"System Settings › General › Login Items & Extensions › Quick Look, then click Reset Quick Look.",
            width);

        _status = FQWrappingLabel(@"", width);
        _status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        _status.textColor = NSColor.secondaryLabelColor;
        _removeCopies = [NSButton buttonWithTitle:@"Move Other Copies to Trash…"
                                           target:self
                                           action:@selector(removeOtherCopies:)];
        _removeCopies.hidden = YES;

        NSTextField *settings = [NSTextField labelWithString:@"Settings"];
        settings.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
        _thumbnails = [NSButton checkboxWithTitle:@"Show thumbnails in Finder's icon and gallery views"
                                           target:self
                                           action:@selector(thumbnailsChanged:)];
        _stretch = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [_stretch addItemsWithTitles:@[ @"Auto stretch", @"Linear 0.5–99.5%", @"Min – max" ]];
        _stretch.target = self;
        _stretch.action = @selector(previewStretchChanged:);
        NSStackView *stretchRow = FQRow(@[ [NSTextField labelWithString:@"Previews open with:"], _stretch ], 8);
        _appIcon = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [_appIcon addItemsWithTitles:@[ @"Automatic", @"Dusk", @"Light" ]];
        for (NSUInteger k = 1; k < FQIconChoices().count; k++) {
            NSImage *image = FQIconImage(FQIconChoices()[k]);
            image.size = NSMakeSize(16, 16);
            [_appIcon itemAtIndex:k].image = image;
        }
        _appIcon.toolTip = @"Automatic: the light icon in light mode and Dusk in dark mode (macOS 26), "
                           @"Dusk on earlier versions of macOS.";
        _appIcon.target = self;
        _appIcon.action = @selector(appIconChanged:);
        NSStackView *iconRow = FQRow(@[ [NSTextField labelWithString:@"App icon:"], _appIcon ], 8);
        _autoCheck = [NSButton checkboxWithTitle:@"Check for updates automatically (once a day)"
                                          target:self
                                          action:@selector(autoCheckChanged:)];
        NSButton *checkNow = [NSButton buttonWithTitle:@"Check Now" target:self action:@selector(checkForUpdates:)];
        NSStackView *updateRow = FQRow(@[ _autoCheck, checkNow ], 12);

        NSButton *open = [NSButton buttonWithTitle:@"Open a File…" target:self action:@selector(openDocument:)];
        NSButton *extensions = [NSButton buttonWithTitle:@"Extension Settings…"
                                                  target:self
                                                  action:@selector(openSettings:)];
        NSButton *reset = [NSButton buttonWithTitle:@"Reset Quick Look" target:self action:@selector(resetQuickLook:)];
        NSStackView *buttons = FQRow(@[ open, extensions, reset ], 8);

        NSStackView *all = [NSStackView stackViewWithViews:@[
            FQRow(@[ icon, names ], 16), how, _status, _removeCopies, settings, _thumbnails, stretchRow, iconRow,
            updateRow, buttons
        ]];
        all.orientation = NSUserInterfaceLayoutOrientationVertical;
        all.alignment = NSLayoutAttributeLeading;
        all.spacing = 12;
        all.edgeInsets = NSEdgeInsetsMake(20, 24, 20, 24);
        [all.widthAnchor constraintEqualToConstant:width + 48].active = YES;   // a margin on the right too
        [all setCustomSpacing:20 afterView:_removeCopies];
        [all setCustomSpacing:20 afterView:updateRow];

        _welcome = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width + 48, 480)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable
                                                 backing:NSBackingStoreBuffered
                                                   defer:YES];
        _welcome.title = @"uFits";
        _welcome.contentView = all;
        _welcome.releasedWhenClosed = NO;
        _welcome.delegate = self;
    }
    _autoCheck.state = FQUpdate.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [_stretch selectItemAtIndex:MIN(MAX([FQSettings() integerForKey:@"stretch"], 0), _stretch.numberOfItems - 1)];
    [_appIcon selectItemAtIndex:(NSInteger)[FQIconChoices() indexOfObject:FQIconChoice()]];
    BOOL first = !_welcome.visible;
    [self refreshStatus];
    if (first)
        [_welcome center];
    [_welcome makeKeyAndOrderFront:nil];
    if (@available(macOS 14.0, *))
        [NSApp activate];
    else
        [NSApp activateIgnoringOtherApps:YES];
}

/// Fits the setup window to what it shows, keeping its top where it is.
- (void)fitWelcome
{
    if (!_welcome)
        return;
    NSView *v = _welcome.contentView;
    [v layoutSubtreeIfNeeded];
    NSSize size = v.fittingSize;
    NSRect old = _welcome.frame;
    NSRect frame = [_welcome frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
    frame.origin = NSMakePoint(NSMinX(old), NSMaxY(old) - NSHeight(frame));
    [_welcome setFrame:frame display:YES];
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

static NSString *const kLSRegister =
    @"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";

/// A Quick Look extension as pluginkit -v lists it, "+    io.github.lmytime.
/// uFits.Preview(0.0.5)<tab>uuid<tab>date<tab>path": its version and path
/// (NO for a line that is not one).
static BOOL FQParsePlugin(NSString *line, NSString **version, NSString **path)
{
    NSArray<NSString *> *f = [line componentsSeparatedByString:@"\t"];
    NSString *p = [f.lastObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (f.count < 2 || ![p hasPrefix:@"/"])
        return NO;
    NSString *head = f.firstObject;
    NSRange a = [head rangeOfString:@"("], b = [head rangeOfString:@")" options:NSBackwardsSearch];
    *version = a.location != NSNotFound && b.location != NSNotFound && b.location > a.location
                   ? [head substringWithRange:NSMakeRange(NSMaxRange(a), b.location - NSMaxRange(a))]
                   : @"?";
    *path = p;
    return YES;
}

/// Whether path is in this copy of uFits.
static BOOL FQIsMine(NSString *path)
{
    if ([path hasPrefix:@"/System/Volumes/Data/"])
        path = [path substringFromIndex:@"/System/Volumes/Data".length];
    return [path hasPrefix:[NSBundle.mainBundle.bundlePath stringByAppendingString:@"/"]];
}

/// The app a Quick Look extension (.../uFits.app/Contents/PlugIns/x.appex) is in.
static NSString *FQAppOf(NSString *appex)
{
    NSRange r = [appex rangeOfString:@"/Contents/PlugIns/" options:NSBackwardsSearch];
    return r.location == NSNotFound ? appex : [appex substringToIndex:r.location];
}

/// The Quick Look extensions of other copies of uFits that macOS knows
/// (an old build, a copy left in Downloads), path to version: one numbered
/// higher than this one can be the one Quick Look uses.
static NSDictionary<NSString *, NSString *> *FQOtherCopies(void)
{
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    for (NSString *suffix in @[ @"Preview", @"Thumbnail" ]) {
        NSString *ident = [NSString stringWithFormat:@"%@.%@", bundleID, suffix];
        NSString *list = RunTool(@"/usr/bin/pluginkit", @[ @"-m", @"-A", @"-D", @"-v", @"-i", ident ]);
        for (NSString *line in [list componentsSeparatedByString:@"\n"]) {
            NSString *version, *path;
            if (FQParsePlugin(line, &version, &path) && !FQIsMine(path))
                out[path] = version;
        }
    }
    return out;
}

/// Whether this copy of uFits is the one in Applications (not one opened
/// from the disk image, or from where it was built).
static BOOL FQInApplications(void)
{
    NSString *path = NSBundle.mainBundle.bundlePath;
    return [path hasPrefix:@"/Applications/"] ||
           [path hasPrefix:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications/"]];
}

- (void)refreshStatus
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *ident = [UTType typeWithFilenameExtension:@"fits"].identifier ?: @"?";
    NSDictionary<NSString *, UTType *> *elsewhere = FQExtensionsElsewhere();
    if ([ident hasPrefix:@"dyn."])
        [lines addObject:@"⚠︎ The FITS file type is not registered yet: move uFits to Applications and open it once."];
    else if (!elsewhere.count)
        [lines addObject:@"✓ FITS and XISF files are recognised."];
    else {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *ext in FQExtensions())
            if (elsewhere[ext])
                [names addObject:[NSString stringWithFormat:@".%@ (%@)", ext,
                                                            elsewhere[ext].localizedDescription ?: elsewhere[ext].identifier]];
        [lines addObject:[NSString stringWithFormat:@"⚠︎ Taken by other types, so Quick Look may not use uFits: %@.",
                                                    [names componentsJoinedByString:@", "]]];
    }

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    for (NSString *suffix in @[ @"Preview", @"Thumbnail" ]) {
        NSString *ext = [NSString stringWithFormat:@"%@.%@", bundleID, suffix];
        // The copy of the extension that Quick Look uses.
        NSString *out = [RunTool(@"/usr/bin/pluginkit", @[ @"-m", @"-v", @"-i", ext ])
            stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        NSString *version, *path, *state;
        if (!out.length)
            state = @"not registered";
        else if (FQParsePlugin(out, &version, &path) && !FQIsMine(path))
            state = [NSString stringWithFormat:@"Quick Look uses another copy's (uFits %@ in %@)", version,
                                               FQAppOf(path).stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath];
        else if ([out hasPrefix:@"-"])
            state = @"disabled";
        else
            state = @"enabled";
        [lines addObject:[NSString stringWithFormat:@"%@ %@ extension: %@",
                                                    [state isEqualToString:@"enabled"] ? @"✓" : @"⚠︎",
                                                    suffix, state]];
        if ([suffix isEqualToString:@"Thumbnail"]) {
            _thumbnails.state = out.length && ![out hasPrefix:@"-"] ? NSControlStateValueOn : NSControlStateValueOff;
            _thumbnails.enabled = out.length > 0;
        }
    }
    // Other copies of uFits that macOS knows (an old build, a copy in
    // Downloads): Quick Look may use them instead of this one. Say where
    // they are and offer to move them to the Trash (from the copy in
    // Applications only: opened from elsewhere, this is the other copy).
    NSMutableDictionary<NSString *, NSString *> *apps = [NSMutableDictionary dictionary];
    if (FQInApplications()) {
        NSDictionary<NSString *, NSString *> *others = FQOtherCopies();
        for (NSString *appex in others)
            apps[FQAppOf(appex)] = others[appex];
    }
    if (apps.count) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *app in [apps.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [names addObject:[NSString stringWithFormat:@"uFits %@ in %@", apps[app],
                                                        app.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath]];
        [lines addObject:[NSString stringWithFormat:@"⚠︎ Other copies of uFits, which Quick Look may use instead of "
                                                    @"this one: %@.",
                                                    [names componentsJoinedByString:@"; "]]];
    }
    _removeCopies.hidden = apps.count == 0;

    NSString *now = FQUpdate.currentVersion, *latest = FQUpdate.latestVersion;
    if (latest && [FQUpdate version:latest isNewerThan:now])
        [lines addObject:[NSString stringWithFormat:@"⬆︎ uFits %@ is out (this is %@): click Check Now to update.",
                                                    latest, now]];
    else
        [lines addObject:[NSString stringWithFormat:@"✓ uFits %@%@", now,
                                                    latest ? @" is the latest version." : @"."]];
    _status.stringValue = [lines componentsJoinedByString:@"\n"];
    [self fitWelcome];
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

/// Finder's thumbnails on or off: the thumbnail extension's election.
- (void)thumbnailsChanged:(NSButton *)sender
{
    NSString *ident = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".Thumbnail"];
    RunTool(@"/usr/bin/pluginkit",
            @[ @"-e", sender.state == NSControlStateValueOn ? @"use" : @"ignore", @"-i", ident ]);
    RunTool(@"/usr/bin/qlmanage", @[ @"-r" ]);
    RunTool(@"/usr/bin/qlmanage", @[ @"-r", @"cache" ]);   // Finder draws its icons again
    [self refreshStatus];
}

/// The stretch previews open with, in Quick Look and in the app (a
/// preview's own menu changes the same setting).
- (void)previewStretchChanged:(NSPopUpButton *)sender
{
    [FQSettings() setInteger:sender.indexOfSelectedItem forKey:@"stretch"];
}

/// The app's icon: automatic, Dusk or light.
- (void)appIconChanged:(NSPopUpButton *)sender
{
    NSString *choice = FQIconChoices()[(NSUInteger)MAX(0, sender.indexOfSelectedItem)];
    if (!FQApplyIcon(choice)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"uFits could not change its icon";
        alert.informativeText = [NSString
            stringWithFormat:@"%@ cannot be changed where it is. Install uFits in Applications, then choose again.",
                             NSBundle.mainBundle.bundlePath.stringByAbbreviatingWithTildeInPath];
        [self activate];
        [alert runModal];
        [sender selectItemAtIndex:(NSInteger)[FQIconChoices() indexOfObject:FQIconChoice()]];
        return;
    }
    [FQSettings() setObject:choice forKey:kIconKey];
}

/// Moves the other copies of uFits that macOS knows to the Trash, once
/// asked, and makes Quick Look use this one.
- (void)removeOtherCopies:(id)sender
{
    (void)sender;
    NSDictionary<NSString *, NSString *> *appexes = FQOtherCopies();
    NSMutableDictionary<NSString *, NSString *> *apps = [NSMutableDictionary dictionary];
    for (NSString *appex in appexes)
        apps[FQAppOf(appex)] = appexes[appex];
    if (!apps.count) {
        [self refreshStatus];
        return;
    }
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (NSString *app in [apps.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [list addObject:[NSString stringWithFormat:@"uFits %@: %@", apps[app], app.stringByAbbreviatingWithTildeInPath]];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Move the other copies of uFits to the Trash?";
    alert.informativeText = [NSString
        stringWithFormat:@"Quick Look may use them instead of this uFits (%@).\n\n%@", FQUpdate.currentVersion,
                         [list componentsJoinedByString:@"\n"]];
    [alert addButtonWithTitle:@"Move to Trash"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn)
        return;
    for (NSString *appex in appexes)
        RunTool(@"/usr/bin/pluginkit", @[ @"-r", appex ]);
    // Copies already in the Trash, or gone, are only unregistered.
    NSString *bin = [NSHomeDirectory() stringByAppendingString:@"/.Trash/"];
    NSMutableArray<NSURL *> *trash = [NSMutableArray array];
    for (NSString *app in apps) {
        RunTool(kLSRegister, @[ @"-u", app ]);
        if (![app hasPrefix:bin] && [NSFileManager.defaultManager fileExistsAtPath:app])
            [trash addObject:[NSURL fileURLWithPath:app]];
    }
    if (!trash.count) {
        [self resetQuickLook:nil];
        return;
    }
    [NSWorkspace.sharedWorkspace recycleURLs:trash
                           completionHandler:^(NSDictionary<NSURL *, NSURL *> *moved, NSError *error) {
                               (void)moved;
                               dispatch_async(dispatch_get_main_queue(), ^{
                                   if (error)
                                       [[NSAlert alertWithError:error] runModal];
                                   [self resetQuickLook:nil];   // this copy's extensions, registered again
                               });
                           }];
}

#pragma mark About

- (void)showAbout:(id)sender
{
    (void)sender;
    NSMutableParagraphStyle *centred = [NSMutableParagraphStyle new];
    centred.alignment = NSTextAlignmentCenter;
    NSDictionary *plain = @{
        NSFontAttributeName : [NSFont systemFontOfSize:NSFont.smallSystemFontSize],
        NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
        NSParagraphStyleAttributeName : centred
    };
    NSMutableAttributedString *credits = [[NSMutableAttributedString alloc]
        initWithString:@"Quick Look for FITS and XISF files.\n"
            attributes:plain];
    NSMutableDictionary *link = [plain mutableCopy];
    link[NSLinkAttributeName] = [NSURL URLWithString:@"https://lmytime.github.io/uFits/"];
    [credits appendAttributedString:[[NSAttributedString alloc] initWithString:@"lmytime.github.io/uFits"
                                                                    attributes:link]];
    // "Version 0.0.6", without the build number after it ("(1)").
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationVersion : [@"Version " stringByAppendingString:FQUpdate.currentVersion],
        NSAboutPanelOptionVersion : @"",
        NSAboutPanelOptionCredits : credits
    }];
    [self activate];
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
        if (argc > 1 && !strcmp(argv[1], "--file-types")) {
            // What macOS takes each extension uFits claims for.
            UTType *fits = [UTType typeWithIdentifier:kFITSType];
            UTType *xisf = [UTType typeWithIdentifier:kXISFType];
            for (NSString *ext in FQExtensions()) {
                UTType *t = [UTType typeWithFilenameExtension:ext];
                printf(".%-5s %-40s %s\n", ext.UTF8String, t.identifier.UTF8String ?: "?",
                       t && fits && [t conformsToType:fits] ? "FITS"
                       : t && xisf && [t conformsToType:xisf] ? "XISF"
                       : FQAlsoPreviewed(t)                 ? "previewed (not FITS to macOS: no Finder icons)"
                                                            : "NOT RECOGNISED");
            }
            return 0;
        }
        if (argc > 2 && !strcmp(argv[1], "--set-icon")) {
            // The app's icon: auto, dusk or light (install.sh sets it again
            // after an update, as the app does when it opens).
            NSString *choice = @(argv[2]);
            if (![FQIconChoices() containsObject:choice]) {
                fprintf(stderr, "uFits --set-icon auto|dusk|light\n");
                return 2;
            }
            if (!FQApplyIcon(choice)) {
                fprintf(stderr, "could not set the icon of %s\n", NSBundle.mainBundle.bundlePath.UTF8String);
                return 1;
            }
            [FQSettings() setObject:choice forKey:kIconKey];
            return 0;
        }
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
