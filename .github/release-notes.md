uFits shows FITS and XISF files in Finder: Quick Look previews (select a file, press
Space) and thumbnails for images, cubes, tile-compressed `.fz` files, spectra, light
curves, catalogs and tables, with every header.

**New in 0.0.5**

- XISF images (PixInsight's format): previews and thumbnails of grayscale, RGB and Bayer
  images, compressed (zlib, LZ4, Zstandard) or not, with their properties and FITS
  keywords in Header. Contributed by Shihao Wang.
- Thumbnails look like the preview: their automatic stretch now comes from the image as
  the preview shows it, whatever their size (shrunk a lot, a big image used to look
  brighter in its thumbnail).
- uFits is open source under the BSD 3-Clause license.

From 0.0.3 on, uFits says when a newer version is out (**Update available** in the
preview's bar) and updates itself when you open it. From 0.0.2 or earlier, update once
with the command below. See [0.0.3](https://github.com/lmytime/uFits/releases/tag/v0.0.3)
for zoom, the shorter bar and the FITS files of X-ray missions, and
[0.0.4](https://github.com/lmytime/uFits/releases/tag/v0.0.4) for full-size thumbnails
on Retina screens.

**Install** with one command in Terminal:

```sh
curl -fsSL https://github.com/lmytime/uFits/releases/download/@TAG@/install.sh | sh
```

It downloads the disk image below, checks its SHA-256, copies uFits to Applications and
turns on its Quick Look extensions. Then select a FITS or XISF file in Finder and press
Space.
To remove uFits, run the same command with `sh -s -- --uninstall` at the end.

**Or by hand:** open the disk image and drag uFits onto Applications. The app is not
notarized, so macOS blocks it at first: run
`xattr -dr com.apple.quarantine /Applications/uFits.app`, or open uFits and click
**Open Anyway** under System Settings › Privacy & Security. Then open uFits once to
register its Quick Look extensions.

Universal (Apple silicon and Intel), macOS 11 or later.
