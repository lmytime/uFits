// iconsize - how big apps' icons are, as Finder and the Dock draw them
// (NSWorkspace): for each app, the box of its icon's opaque pixels as a
// share of the icon's square, and the color at the box's edge (macOS 26
// sets an icon it takes for an older design on a plate of its own).
//
// Usage: iconsize OUT.png APP...
// OUT.png gets the icons side by side, each on a gray square, for review.

#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: iconsize OUT.png APP...\n");
            return 2;
        }
        const int n = 512, pad = 16;
        int count = argc - 2;
        NSBitmapImageRep *sheet = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:count * (n + pad) + pad
                          pixelsHigh:n + 2 * pad
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:0
                        bitsPerPixel:32];
        NSGraphicsContext *sheetCtx = [NSGraphicsContext graphicsContextWithBitmapImageRep:sheet];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = sheetCtx;
        [[NSColor colorWithWhite:0.5 alpha:1] setFill];
        NSRectFill(NSMakeRect(0, 0, sheet.pixelsWide, sheet.pixelsHigh));
        [NSGraphicsContext restoreGraphicsState];

        printf("%-28s %16s %18s\n", "icon of", "opaque box", "at its edge");
        for (int k = 0; k < count; k++) {
            NSString *path = @(argv[k + 2]);
            NSString *name = path.lastPathComponent.stringByDeletingPathExtension;
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                printf("%-28s %16s\n", name.UTF8String, "(not here)");
                continue;
            }
            NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:path];
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                            pixelsWide:n
                                                                            pixelsHigh:n
                                                                         bitsPerSample:8
                                                                       samplesPerPixel:4
                                                                              hasAlpha:YES
                                                                              isPlanar:NO
                                                                        colorSpaceName:NSDeviceRGBColorSpace
                                                                           bytesPerRow:n * 4
                                                                          bitsPerPixel:32];
            rep.size = NSMakeSize(n, n);
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
            [icon drawInRect:NSMakeRect(0, 0, n, n)
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationCopy
                    fraction:1];
            [NSGraphicsContext restoreGraphicsState];

            const unsigned char *p = rep.bitmapData;
            int x0 = n, x1 = -1, y0 = n, y1 = -1;
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++)
                    if (p[(y * n + x) * 4 + 3] > 127) {
                        x0 = MIN(x0, x), x1 = MAX(x1, x);
                        y0 = MIN(y0, y), y1 = MAX(y1, y);
                    }
            if (x1 < 0) {
                printf("%-28s %16s\n", name.UTF8String, "(nothing drawn)");
                continue;
            }
            // The color just inside the middle of the box's left edge.
            const unsigned char *e = p + (((y0 + y1) / 2) * n + x0 + 3) * 4;
            printf("%-28s %6.1f%% x %5.1f%%   rgb %3d %3d %3d\n", name.UTF8String, (x1 - x0 + 1) * 100.0 / n,
                   (y1 - y0 + 1) * 100.0 / n, e[0], e[1], e[2]);

            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = sheetCtx;
            [rep drawInRect:NSMakeRect(pad + k * (n + pad), pad, n, n)
                   fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver
                   fraction:1
             respectFlipped:NO
                      hints:nil];
            [NSGraphicsContext restoreGraphicsState];
        }
        NSData *png = [sheet representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:@(argv[1]) atomically:YES];
        return 0;
    }
}
