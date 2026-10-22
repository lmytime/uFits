# Developing uFits

How uFits is built, tested and released. To install it, see the [README](README.md).

## Design

uFits is built to be small and fast:

- **No Python or cfitsio at runtime.** A portable C core plus thin Objective-C Quick
  Look extensions. It uses system zlib, bzip2 and Expat, and includes the upstream
  Zstandard decompressor under its BSD license in `third_party/zstd` and libyaml's
  parser under its MIT license in `third_party/libyaml`. Both Apple Silicon and Intel
  builds need only Xcode command line tools.
- **Reads only what it shows.** Files are memory mapped; images are binned straight from
  the mapping, sampling a few pixels per output pixel when shrinking a lot, so a
  thumbnail of a 256 MB image touches a small fraction of the file. When every row of
  the part shown is read (a cube's plane, a zoomed-in part), each chunk of the binning
  asks for read-ahead of its own rows only: since macOS 15.4 the hint faults in its
  whole range before it returns, so a hint over the whole data unit would read all of a
  cube to show one plane (`tests/macos/bigfile_check.sh` times that). An image so big
  that the rows sampled would add up to more than 2 GiB (a terabyte mosaic) is sampled
  on fewer rows, down to one per output row. For tile-compressed files only the tiles
  under the sampled rows, and of a zoomed-in part only those under it, are decompressed.
  XISF compression is block based: the selected image is decompressed in full (its
  subblocks on every core) and cached until another image is selected or the file is
  closed. Of a compressed ASDF array only the plane shown is decompressed (see
  [ASDF](#asdf)).
- **Uses every core.** Binning, tile decompression and the final mapping run in parallel
  (Grand Central Dispatch).
- **Reuses its biggest buffer.** Memory written for the first time costs a page fault
  a page: for 64 MB about as long as decompressing LZ4. A decompressed XISF image or
  ASDF plane, or the tile bands of a render, go into the buffer the last one left
  (`fqi_big_alloc`: up to 256 MiB, kept for the next file), so thumbnails of a folder
  of images of one size decode into memory already there. It is freed 20 s after the
  last file is closed, or at once when memory is short (`fq_trim`).
- **Opens a file once.** A preview's renders, zoomed-in details and headers share one
  open file (`FQFile`), and with it what the core keeps of it: the HDUs found, a
  decompressed XISF image or ASDF plane, where inflating a zlib block got to, a gzip
  file inflated so far. They take turns on a queue of the file's own; work that is no
  longer wanted when its turn comes (the detail of a part scrolled past, anything of a
  preview closed) is dropped. The table view reads cells on the main thread, from the
  same open file once its bytes stay where they are (mapped, or a gzip file inflated to
  its end), else from the file opened again. A preview starts reading its file before it
  makes its views, and makes the header and table views only when they are first shown.
  Thumbnails go to Quick Look as uncompressed TIFF files, quicker to write and to read
  than PNG.

On an Apple Silicon CI runner, a Finder-style thumbnail request (through
`QLThumbnailGenerator`, including the round trip to the extension) takes 10–25 ms per
file once the extension is running, and about 0.2 s for the very first one.

Time spent in the core alone, measured on a 4-core Linux VM:

| file | thumbnail (512 px) | preview (2560 px) |
| --- | --- | --- |
| 4096×4096 int16 (32 MB) | 3 ms | 7 ms |
| 8192×8192 float32 (256 MB) | 4 ms | 21 ms |
| 4096×4096 Rice-compressed `.fz` | 15 ms | 34 ms |
| 4088×4088 float32, Roman's L2 (ASDF, LZ4, 70 MB) | 17 ms | 21 ms |
| 8000×6000 float32 XISF, zstd and byte shuffled (143 MB) | 210 ms | 226 ms |

Those are of a file on its own. In a folder of images of one size (`fqtool render …
--repeat 8 --reopen`), every file after the first decodes into the buffer the one before
left: the Roman thumbnail then takes 8 ms, the XISF one 115 ms, the `.fz` preview 30 ms.

## What the core handles

- The first HDU that holds an image or a plottable table (an empty primary HDU
  followed by `SCI`, as in HST/JWST files, works as expected). When a file has more,
  a menu in the preview's bar lists every HDU (`SCI`, `ERR`, `DQ`, tables, and those
  with only a header): picking one shows its picture, its rows or its header.
- Every BITPIX, with `BSCALE`/`BZERO` (unsigned integers included) and `BLANK`/NaN
  as transparent pixels, so mosaics keep their footprint shape.
- An automatic midtone stretch (median/MAD based, like PixInsight's STF) that shows faint
  structure without burning out bright sources. The preview's menu switches to a linear
  0.5–99.5 % or min–max stretch; the choice is remembered. Thumbnails always use the
  automatic stretch. Whatever the size an image is drawn at, its stretch is worked out from
  the image as Quick Look's preview shows it (binned to fit 2560 pixels, up to 4×4 samples
  a pixel), from 128 or more of that view's rows: a thumbnail reads those rows again (a few
  milliseconds) and then looks like the preview.
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
  placeholder values such as -999 skipped. Crowded catalogs are shaded by density.
  Plots of more than 4 million points are drawn on every core (a 5-million-row catalog
  in about 0.04 s). Of a table bigger than 1 GiB only 16384 windows of 16 KiB are read,
  256 MiB whatever its size: one at a fixed random place in each of as many equal parts
  of the table, so that no regular step beats with the order of the rows, read on every
  core and without the read-ahead meant for reading on. The rows of a catalog sorted by
  position make each window a small patch of sky; then only the middle row of each
  window is drawn. Previews open a catalog on its rows and draw the map only when
  **Plot** is picked (`fq_default_hdu` tells from the headers what a file opens on).
  Finder's thumbnails of catalogs are still maps.
- Tile-compressed images (`fpack`, `.fz`): `RICE_1`, `GZIP_1`, `GZIP_2`, `PLIO_1`,
  `NOCOMPRESS`, with all three quantization/dithering modes.
- Gzipped files (`.fits.gz`) when built with `GZIP=1` (see below).
- Rows follow the FITS convention (first row at the bottom) unless `ROWORDER = 'TOP-DOWN'`.
- **Table** shows the rows of any table, plotted or not, as a grid with fixed column
  titles: all of them, read only as they scroll into view, so a catalog of millions of
  rows opens at once. The table draws its cells itself (a cell-based `NSTableView`),
  with no view per cell, which keeps scrolling smooth, also inside Quick Look. Binary
  and ASCII tables, with array, string, logical, bit, complex and variable-length
  columns. ⌘C copies the selected rows as tab-separated text, read in the background.
  Files whose tables have nothing to plot, and catalogs, open on it.
- **Header** shows the header of the HDU picked, its cards in columns: keywords in
  bold at a fixed width, values and comments lined up, long strings (`CONTINUE`) joined
  into one line, `HIERARCH` keywords in full, `COMMENT`/`HISTORY` text under the
  values. ⌘F searches it.
- Switching between picture, rows and header is immediate: tables are opened and
  headers read and styled in the background (right after the file opens, for the HDU on
  show; for ASDF once, since its arrays share one tree), with "Loading…" shown if that
  takes more than a moment.
- Changing the stretch only remaps the image already binned, so it is instant even for
  big or compressed files.
- Zoom (pinch, ⌥-click, ⌘- or ⌥-scroll; ⌘+ ⌘− ⌘0 where keys reach the preview) goes up
  to 32 points per image pixel. A drag with the middle button or with ⌥ held moves the
  image (an ⌥-click without a drag still zooms; a middle-click centres the view there). Once an image shown binned is zoomed in past its binned
  pixels, the part on view is read again at full resolution in the background
  (`fq_render_detail`: a region, mapped with the stretch of the whole image) and laid
  over it, with a margin of up to a quarter of the view on each side so that small
  moves need no new read.

## XISF

The reader supports monolithic XISF 1.0 files containing 2D Gray/RGB images or
2×2 Bayer mosaics. UInt8/16/32/64 and Float32/64 samples, little/big endian and
planar/interleaved storage feed the same renderer as FITS. Pixels may be attached
or embedded as base64/hex; zlib, LZ4/LZ4HC and Zstandard compression, byte shuffling
and mixed compressed/raw subblocks are supported. Each image's attributes, FITS
keywords and scalar properties are available in Header.

Raw attachments are sampled directly from the mapped file. Compressed XISF images
must be decompressed in full before sampling, so large compressed files take longer.
Only the selected decoded image is cached. Shuffled bytes are sampled where they lie,
a byte from each byte plane, so they need no second image-sized buffer (unless the
shuffle's item size is not the sample size). XML headers are limited to 16 MiB,
a property's text to its first 1 MiB, and decoded compressed/embedded images to
512 MiB.

Complex samples, alpha channels, other color spaces, higher-dimensional images and
explicit non-default orientation transforms are not rendered. Other CFA patterns
are shown as raw grayscale. Stored display functions and ICC profiles are not
applied; the preview uses uFits' stretch controls. Checksums are not verified.
See the [XISF specification](https://pixinsight.com/doc/docs/XISF-1.0-spec/XISF-1.0-spec.html)
for the file format.

## ASDF

ASDF files (the [Advanced Scientific Data Format](https://asdf-standard.readthedocs.io/);
the Roman Space Telescope's data products are ASDF files) hold a YAML tree, then
binary blocks. The tree is read with libyaml's event parser, as Python's asdf reads it
(through PyYAML), up to 64 MiB and 100 levels deep. Each array in it of a numeric type
is an "HDU": int8 to uint64, float16/32/64 and bool, in either byte order, with any
number of dimensions (cubes get the slider; 1-D arrays are plotted), views of other
arrays (offsets and strides) included. Arrays are named by their place in the tree
(`roman.data`); one named `data` is shown first, and the value of a quantity is named
for the quantity. The tree is the header of every array: a line per key, nested keys
indented, tags as comments, arrays as their shape and type (as numpy gives them: rows,
then columns), and what wrote the file (`asdf_library`, `history`) last. Arrays are
drawn as FITS images are, the first row at the bottom.

Blocks may be stored as they are, and are then read straight from the mapped file
like FITS images, or compressed with LZ4 (in pieces of 4 MiB, as Python's asdf
frames it; Roman's pipeline compresses every array so), zlib or bzip2. Of a compressed
block only the part with the plane shown is decompressed (LZ4 pieces on every core;
zlib from the nearest plane already passed, as the inflater's state is kept where
planes start, so stepping through a cube does not start over each time; bzip2 from
the start of the block), and kept until another plane or array is shown; a plane may
take up to 512 MiB decompressed. Streamed blocks and blocks counted
from the end (`source: -1`) work.

Not shown: arrays written inline in the tree (they are small; the tree has their
values), arrays in other files, string, record and complex arrays, tables (their
columns stay in the tree), the arrays of transforms and WCS (gwcs), and masks (an
array is shown without its mask). Compression that extensions add (zstd, blosc, ...)
is reported as not supported. Checksums are not verified.

## Licenses

The app bundles uFits' BSD 3-Clause license as `Contents/Resources/LICENSE`, the
Zstandard notice as `Contents/Resources/zstd-LICENSE` and libyaml's as
`Contents/Resources/libyaml-LICENSE`. The Zstandard decoder is compiled at `-O2` like
the rest: its upstream size options (`-Os`, `ZSTD_NO_INLINE`, ...) saved about 90 KB per
architecture and binary but made decoding float images about twice as slow.

## Updates

`FQUpdate` (shared by the app and the preview extension) keeps what it learns in the
app's settings, and only the app goes online: Quick Look runs previews in a sandbox
without network access, whatever their entitlements say. The app looks as it opens, at
most once a day (unless "Check for updates" is off), where
`github.com/lmytime/uFits/releases/latest` redirects (`.../releases/tag/vX.Y.Z`, read
with a `HEAD` request: no API, no rate limit). The preview may read and write the app's
settings (`Preview.entitlements`; the stretch that previews open with is one setting for
Quick Look and the app) and, when the app has seen a newer version, shows **Update
available** in its bar. A preview may not open other apps either
(`deny(1) lsopen`): its click asks Quick Look to open `ufits://update` for it, and when
Quick Look declines (it does), a popover says to open the uFits app. The app offers the
update as it opens (and at once from "Update available" in its own windows), then runs
that release's `install.sh` with `UFITS_FROM_APP=1` (the installer then leaves it
running) and `UFITS_DEST` set to the folder it is in, opens the new copy and quits.
`uFits --check-for-updates` looks at once and prints what it found.

uFits 0.0.9 and earlier also had a launchd job,
`~/Library/LaunchAgents/io.github.lmytime.uFits.update.plist`, run
`uFits --check-for-updates-if-due` every four hours, so that previews said when a new
version was out even if the app was never opened. macOS kept announcing that job as a
new background item ("Background Items Added"), it seems after every update: uFits is
ad-hoc signed, so each new version is a new app to macOS. The job is gone: the app
removes it as it opens, `install.sh` as it installs, and the job itself when it runs a
later uFits (`tests/macos/update_job_check.sh`).

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
make dmg               # build/uFits-0.0.9.dmg: the app and a link to Applications
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

## The icon

The icon is pixel art, drawn cell by cell by `tools/make_icon.py` from two maps: 32
cells across the 1024 x 1024 icon (one cell a pixel at 32 px, exact at every size above)
and 16 cells for 16 px. It comes in two palettes, Dusk (the app's icon) and a light one,
and the script writes `macos/App/AppIcon.icns` (Dusk), `AppIconLight.icns`,
`macos/App/AppIcon.icon`, `macos/App/Assets.xcassets` (Dusk) and the homepage's icons
and favicons. `AppIcon.icon` is in Icon Composer's format, the only one in which a Mac
app's icon has a dark look (`actool` drops the dark and light app icons of an asset
catalog): the light icon over Dusk, hidden when icons are dark (System Settings ›
Appearance › Icon & widget style), flat. The Makefile compiles it with the `actool` of
Xcode 26 or later, which also makes flattened images of it, from the light look, for
macOS 15 and earlier; `tools/flat_icon.m` then gives it Dusk's instead, compiled from
`Assets.xcassets` beside it, with CoreUI's asset storage (a private part of macOS, as
actool's own). If that fails, the build goes on and earlier versions show the light
icon; without Xcode 26, the app has `AppIcon.icns`, Dusk, everywhere. CI checks the
icon each version draws, and that macOS 26 draws the release build's (made on macOS
15) light, and Dusk when icons are dark.

The app's **App icon** setting, Dusk or Light, sets a custom icon on the app
(`NSWorkspace setIcon:forFile:`, as `uFits --set-icon auto|dusk|light` does); the app,
and the installer, set it again after an update replaces the app.

## Code and tests

```
core/       C core: parsing, decompression, binning, stretch (portable C)
third_party/zstd/  upstream single-file Zstandard decompressor and license
third_party/libyaml/  libyaml's YAML parser (for ASDF trees) and license
tools/      fqtool command line front end, icon generator and flat_icon (macOS 15's icon)
macos/      Objective-C: app, Quick Look preview and thumbnail extensions
tests/      astropy-based test file generator, comparisons, fuzzer, Quick Look smoke test
docs/       the homepage, one static page (GitHub Pages: branch main, folder /docs)
Makefile    builds everything with clang; no Xcode project
```

The core builds and runs anywhere, which keeps it easy to test:

```sh
make test                                     # needs numpy, astropy, lz4, zstandard, asdf
                                              # (and roman_datamodels for Roman's files)
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
`tests/test_xisf.py` generates XISF fixtures independently with NumPy and the Python
compression libraries, checking sample values, byte order, storage order, compression
and shuffling, multiple images, display orientation, metadata, and malformed inputs.
`tests/test_asdf.py` writes ASDF files with Python's asdf (and Roman's own, with
roman_datamodels, when it is installed) and checks every type and byte order, the
three compressions, cubes plane by plane, views, streamed blocks, quantities, which
arrays are listed, the header, and damaged files. `tests/test_tables.py` checks the
plots of big tables against numpy: drawn on every core, and sampled in windows (it
writes a table of 1.1 GB, then deletes it).
On Linux install the zlib, bzip2 and Expat development packages before building the core.
`tests/fuzz.py` feeds damaged files to an AddressSanitizer/UBSan build. CI runs both
on Linux and on macOS 15 (and 26, when run by hand or for a release: see the top of
`.github/workflows/build.yml` for what runs when), then installs the app on the macOS
runners, requests
thumbnails through `QLThumbnailGenerator` (also as Finder asks for its icons) and
previews through `QLPreviewView` (the machinery behind Finder's Quick Look), checks
that thumbnails are the right way up (`tests/macos/make_orient_files.py`: a bright
block on the first pixels belongs in the lower left of a FITS image or an ASDF
array, the upper left of an XISF one) and as sharp as the screen, and that icons under 40 points (list and
column views) keep the file's icon, takes a picture of Finder's icons, drives the preview's controls (HDU menu, plane
slider, find bar), times mode switches and table scrolling with big files
(`tests/macos/make_big_files.py`: a catalog of a million rows, a table 300 columns
wide, a file of 200 HDUs), clicks the HDU menu and the mode switch of a preview in
Quick Look and checks they answer within 400 ms (`tests/macos/clicklag.m`: Quick
Look's double-click recognizer would hold each click for half a second), and checks
that no extension crashed. It also plants an old copy of uFits numbered 1.0.0 and
checks that the installer takes it out of Quick Look's hands, lets a copy of the build
numbered 0.0.1 update itself to the latest release as a user would
(`tests/macos/update_check.sh`: its offer, **Update**, the new copy running), checks
that the launchd job of uFits 0.0.9 and earlier goes (`tests/macos/update_job_check.sh`),
and uninstalls, checking that nothing of uFits is left in `~/Library`
(`tests/macos/uninstall_check.sh`). After a release is published, a last job has the
previous release update itself to the new one.
