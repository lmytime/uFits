uFits shows FITS, XISF and ASDF files in Finder: Quick Look previews (select a file,
press Space) and thumbnails for images, cubes, tile-compressed `.fz` files, spectra, light
curves, catalogs and tables, with every header.

**New in 0.0.10**

- **Faster**, above all with big files. On macOS 15.4 and later, a plane of a big cube or
  a zoomed-in part of a big image no longer reads the whole file. Previews and
  thumbnails draw faster, many about twice as fast; compressed XISF images two to three
  times as fast; and the next plane of a zlib-compressed ASDF cube no longer
  decompresses the planes before it. The map of a huge catalog takes under a second,
  whatever its size, and copying many rows of a table no longer holds up the preview.
- **Catalogs open on their rows**: click **Plot** for the map of the sky. Light curves and
  spectra still open on their plot, and Finder's thumbnails of catalogs are still maps.
- **No more "Background Items Added"**: uFits looks for updates when you open it (at most
  once a day) instead of from a background job, which this version removes.
- XISF files with more than 1 MiB of text in a property (a long processing history, say)
  now open.

From 0.0.3 on, uFits says when a newer version is out (**Update available** in the
preview's bar) and updates itself when you open it. From 0.0.2 or earlier, update once
with the command below. See [0.0.9](https://github.com/lmytime/uFits/releases/tag/v0.0.9)
for ASDF files, [0.0.8](https://github.com/lmytime/uFits/releases/tag/v0.0.8) for moving
around a zoomed-in image,
[0.0.7](https://github.com/lmytime/uFits/releases/tag/v0.0.7)
for the pixel galaxy icon and the App icon setting,
[0.0.6](https://github.com/lmytime/uFits/releases/tag/v0.0.6) for thumbnails that fill
Finder's icons and the app's settings,
[0.0.5](https://github.com/lmytime/uFits/releases/tag/v0.0.5) for XISF images and
[0.0.3](https://github.com/lmytime/uFits/releases/tag/v0.0.3) for zoom and the FITS files
of X-ray missions.

**Install** with one command in Terminal:

```sh
curl -fsSL https://github.com/lmytime/uFits/releases/download/@TAG@/install.sh | sh
```

It downloads the disk image below, checks its SHA-256, copies uFits to Applications and
turns on its Quick Look extensions. Then select a FITS, XISF or ASDF file in Finder and
press Space.
To remove uFits, run the same command with `sh -s -- --uninstall` at the end.

**Or by hand:** open the disk image and drag uFits onto Applications. The app is not
notarized, so macOS blocks it at first: run
`/usr/bin/xattr -dr com.apple.quarantine /Applications/uFits.app`, or open uFits and
click **Open Anyway** under System Settings › Privacy & Security. Then open uFits once to
register its Quick Look extensions.

Universal (Apple silicon and Intel), macOS 11 or later.
