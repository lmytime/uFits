# Developing uFits

How uFits is built, tested and released. To install it, see the [README](README.md).

## Design

uFits is built to be small and fast:

- **No frameworks, no Python, no cfitsio.** A ~4,000 line C core (zlib is the only
  dependency) plus thin Objective-C Quick Look extensions. The whole app, universal
  (Apple Silicon + Intel), is 1.4 MB, a third of which is its icon.
- **Reads only what it shows.** Files are memory mapped; images are binned straight from
  the mapping, sampling a few pixels per output pixel when shrinking a lot, so a
  thumbnail of a 256 MB image touches a small fraction of the file. For tile-compressed
  files only the tiles under the sampled rows are decompressed.
- **Uses every core.** Binning, tile decompression and the final mapping run in parallel
  (Grand Central Dispatch).

On an Apple Silicon CI runner, a Finder-style thumbnail request (through
`QLThumbnailGenerator`, including the round trip to the extension) takes 10–25 ms per
file once the extension is running, and about 0.2 s for the very first one.

Time spent in the core alone, measured on a 4-core Linux VM:

| file | thumbnail (512 px) | preview (2048 px) |
| --- | --- | --- |
| 4096×4096 int16 (32 MB) | 2 ms | 10 ms |
| 8192×8192 float32 (256 MB) | 2 ms | 25 ms |
| 4096×4096 Rice-compressed `.fz` | 12 ms | 37 ms |

## What the core handles

- The first HDU that holds an image or a plottable table (an empty primary HDU
  followed by `SCI`, as in HST/JWST files, works as expected). When a file has more,
  a menu in the preview's bar lists every HDU (`SCI`, `ERR`, `DQ`, tables, and those
  with only a header): picking one shows its picture, its rows or its header.
- Every BITPIX, with `BSCALE`/`BZERO` (unsigned integers included) and `BLANK`/NaN
  as transparent pixels, so mosaics keep their footprint shape.
- An automatic midtone stretch (median/MAD based, like PixInsight's STF) that shows faint
  structure without burning out bright sources. The preview's menu switches to a linear
  0.5–99.5 % or min–max stretch; the choice is remembered.
- Cubes: the middle plane first, and a slider to step through the others. Three-plane
  cubes are shown in colour unless `CTYPE3` names another axis (frequency, wavelength,
  ...).
- One-shot-colour camera frames with `BAYERPAT` (`XBAYROFF`/`YBAYROFF`, `ROWORDER`
  honoured) are debayered to colour.
- 1-D data (spectra) as a plot, with the wavelength axis from `CRVAL1`/`CDELT1`.
- Binary tables holding a light curve or a spectrum, as a plot: TESS and Kepler light
  curves (`PDCSAP_FLUX` against `TIME`), X-ray light curves (`RATE`), photometry in
  magnitudes (drawn with bright up), SDSS spectra (`flux` against `loglam`), HST/JWST
  `x1d` spectra (array columns), X-ray spectra (`COUNTS` against `CHANNEL`), and other
  tables whose columns are named like these. Only the two columns plotted are decoded.
- Catalogs as a map of their sky positions: `RA`/`DEC` (also `ra`/`dec`,
  `RAJ2000`/`DEJ2000`, `ALPHA_J2000`/`DELTA_J2000`, `GLON`/`GLAT` and other common
  pairs), right ascension growing to the left, fields across RA = 0 kept in one piece,
  placeholder values such as -999 skipped. Crowded catalogs are shaded by density. A
  5-million-row catalog plots in about 0.15 s.
- Tile-compressed images (`fpack`, `.fz`): `RICE_1`, `GZIP_1`, `GZIP_2`, `PLIO_1`,
  `NOCOMPRESS`, with all three quantization/dithering modes.
- Gzipped files (`.fits.gz`) when built with `GZIP=1` (see below).
- Rows follow the FITS convention (first row at the bottom) unless `ROWORDER = 'TOP-DOWN'`.
- **Table** shows the rows of any table, plotted or not, as a grid with fixed column
  titles: all of them, read only as they scroll into view, so a catalog of millions of
  rows opens at once. The table draws its cells itself (a cell-based `NSTableView`),
  with no view per cell, which keeps scrolling smooth, also inside Quick Look. Binary
  and ASCII tables, with array, string, logical, bit, complex and variable-length
  columns. ⌘C copies the selected rows as tab-separated text. Files whose tables have
  nothing to plot open on it.
- **Header** shows the header of the HDU picked, its cards in columns: keywords in
  bold at a fixed width, values and comments lined up, long strings (`CONTINUE`) joined
  into one line, `HIERARCH` keywords in full, `COMMENT`/`HISTORY` text under the
  values. ⌘F searches it.
- Switching between picture, rows and header is immediate: tables are opened and
  headers read in the background (right after the file opens, for the HDU on show),
  with "Loading…" shown if that takes more than a moment.
- Changing the stretch only remaps the image already binned, so it is instant even for
  big or compressed files.
- Zoom (pinch, ⌥-click, ⌘- or ⌥-scroll; ⌘+ ⌘− ⌘0 where keys reach the preview) goes up
  to 32 points per image pixel. Once an image shown binned is zoomed in past its binned
  pixels, the part on view is read again at full resolution in the background
  (`fq_render_detail`: a region, mapped with the stretch of the whole image) and laid
  over it.

## Updates

`FQUpdate` (shared by the app and the preview extension) keeps what it learns in the
app's settings, and only the app goes online: Quick Look runs previews in a sandbox
without network access, whatever their entitlements say. A launchd job,
`~/Library/LaunchAgents/io.github.lmytime.uFits.update.plist` (set up by the app when it
opens and by `install.sh`; removed when "Check for updates" is turned off, and by
`install.sh --uninstall`), runs `uFits --check-for-updates-if-due` every four hours. At
most once a day that looks where `github.com/lmytime/uFits/releases/latest` redirects
(`.../releases/tag/vX.Y.Z`, read with a `HEAD` request: no API, no rate limit). The
preview may read the app's settings (`Preview.entitlements`) and, when a newer version
is out, shows **Update available** in its bar. A preview may not open other apps either
(`deny(1) lsopen`): its click asks Quick Look to open `ufits://update` for it, and when
Quick Look declines (it does), a popover says to open the uFits app. The app offers the
update as it opens (and at once from "Update available" in its own windows), then runs
that release's `install.sh` with `UFITS_FROM_APP=1` (the installer then leaves it
running) and `UFITS_DEST` set to the folder it is in, opens the new copy and quits.
`uFits --check-for-updates` looks at once and prints what it found.

## Building

Requirements: macOS 11 or later and the Xcode command line tools
(`xcode-select --install`).

```sh
git clone https://github.com/lmytime/uFits.git
cd uFits
make install          # builds build/uFits.app, copies it to /Applications, registers it
```

### Build options

```sh
make                   # build/uFits.app only
make ARCHS=arm64       # native-only build (default is universal)
make GZIP=1 install    # also preview .gz files (claims every gzip file, see below)
make dmg               # build/uFits-0.0.3.dmg: the app and a link to Applications
make SIGN="Developer ID Application: Your Name (TEAMID)" zip   # hardened runtime, ready to notarize
make SIGN="Developer ID Application: Your Name (TEAMID)" notarize   # notarize and staple (see below)
make uninstall
```

`make notarize` sends the zip to Apple's notary service and staples the ticket, so the
app opens on other Macs without quarantine warnings. It uses a `notarytool` keychain
profile, stored once with `xcrun notarytool store-credentials uFits --apple-id ...
--team-id ...` (choose another name with `NOTARY_PROFILE=`).

`.fits.gz` files carry the `.gz` extension, so macOS identifies them as gzip archives,
not FITS. With `GZIP=1` uFits handles every gzip file and gives up quickly on the ones
that are not FITS; this can override another app's Quick Look support for archives,
so it is off by default.

### Build problems

- **`could not build module 'Cocoa'`, `_c_standard_library_obsolete`, or
  `SigTool::NotAMachOFileException` when building.** These come from tools that are not
  Apple's: a `clang` or `codesign` from conda, Nix, Homebrew or MacPorts first on `PATH`
  (conda environments with compilers install both). The Makefile calls Apple's clang through
  `xcrun` and `/usr/bin/codesign`, so update to the current version of this repository; if
  `xcrun` cannot find a compiler, run `xcode-select --install` (or
  `sudo xcode-select -s /Applications/Xcode.app`). Don't pass `CC=` to make unless it is an
  Apple clang.

## Releases

Every CI run builds the app as `uFits.zip` and as a disk image (the `uFits` and
`uFits-dmg` artifacts on the Actions page), ad hoc signed. Pushing a tag `vX.Y.Z`, or
running the build workflow by hand (Actions › build › Run workflow) with a release tag,
publishes release X.Y.Z with the disk image and the installer (`install.sh`, with its
version filled in) once all tests pass. CI runs the installer too: from the latest
release, from the disk image just built, and to uninstall. The installer also takes
`UFITS_VERSION`, `UFITS_DEST`, `UFITS_DMG` and `UFITS_FROM_APP` (see the top of
`install.sh`).

## Code and tests

```
core/       C core: parsing, decompression, binning, stretch (portable, zlib only)
tools/      fqtool command line front end, icon generator
macos/      Objective-C: app, Quick Look preview and thumbnail extensions
tests/      astropy-based test file generator, comparisons, fuzzer, Quick Look smoke test
docs/       the homepage, one static page (GitHub Pages: branch main, folder /docs)
Makefile    builds everything with clang; no Xcode project
```

The core builds and runs anywhere, which keeps it easy to test:

```sh
make test                                     # needs python3 with numpy + astropy
make fqtool && build/fqtool render image.fits out.png --max 1024
build/fqtool info image.fits                  # HDU list and what Quick Look would show
build/fqtool header image.fits 1              # header cards in columns (--raw: as in the file)
build/fqtool table catalog.fits 1 20          # columns and first rows of a table
```

`make test` writes about 60 FITS files covering every BITPIX, scaling, blanks, NaNs, MEF,
cubes, RGB, Bayer, spectra, light curves and spectra in tables, every supported
compression, gzip and damaged files, and checks the decoded and binned values and the
plotted envelopes against astropy and numpy, plus the stretch itself, the table
listings and every header card as split into keyword, value and comment.
`tests/fuzz.py` feeds damaged files to an AddressSanitizer/UBSan build. CI runs both
on Linux and on macOS, then installs the app on the macOS runner, requests
thumbnails through `QLThumbnailGenerator` and previews through `QLPreviewView` (the
machinery behind Finder's Quick Look), drives the preview's controls (HDU menu, plane
slider, find bar), times mode switches and table scrolling with big files
(`tests/macos/make_big_files.py`: a catalog of a million rows, a table 300 columns
wide, a file of 200 HDUs), clicks the HDU menu and the mode switch of a preview in
Quick Look and checks they answer within 400 ms (`tests/macos/clicklag.m`: Quick
Look's double-click recognizer would hold each click for half a second), and checks
that no extension crashed.
