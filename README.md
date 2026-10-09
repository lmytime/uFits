# uFits

Quick Look for FITS files on macOS. Press Space on a `.fits` / `.fit` / `.fts` / `.fz`
file in Finder to see the image, and get real thumbnails in Finder windows.

uFits is built to be small and fast:

- **No frameworks, no Python, no cfitsio.** A ~3,000 line C core (zlib is the only
  dependency) plus thin Objective-C Quick Look extensions. The whole app is about 1 MB.
- **Reads only what it shows.** Files are memory mapped; images are binned straight from
  the mapping, sampling a few pixels per output pixel when shrinking a lot, so a
  thumbnail of a 256 MB image touches a small fraction of the file. For tile-compressed
  files only the tiles under the sampled rows are decompressed.
- **Uses every core.** Binning, tile decompression and the final mapping run in parallel
  (Grand Central Dispatch).

Rough timings on a 4-core Linux VM (Apple Silicon is faster):

| file | thumbnail (512 px) | preview (2048 px) |
| --- | --- | --- |
| 4096×4096 int16 (32 MB) | 2 ms | 10 ms |
| 8192×8192 float32 (256 MB) | 2 ms | 25 ms |
| 4096×4096 Rice-compressed `.fz` | 12 ms | 37 ms |

## What it shows

- The first HDU that holds an image (an empty primary HDU followed by `SCI`, as in
  HST/JWST files, works as expected).
- Every BITPIX, with `BSCALE`/`BZERO` (unsigned integers included) and `BLANK`/NaN
  as transparent pixels, so mosaics keep their footprint shape.
- An automatic midtone stretch (median/MAD based, like PixInsight's STF) that shows faint
  structure without burning out bright sources. The preview's menu switches to a linear
  0.5–99.5 % or min–max stretch; the choice is remembered.
- Cubes: the middle plane. Three-plane cubes without a spectral `CTYPE3`: an RGB image.
- One-shot-colour camera frames with `BAYERPAT` (`XBAYROFF`/`YBAYROFF`, `ROWORDER`
  honoured) are debayered to colour.
- 1-D data (spectra) as a plot, with the wavelength axis from `CRVAL1`/`CDELT1`.
- Tile-compressed images (`fpack`, `.fz`): `RICE_1`, `GZIP_1`, `GZIP_2`, `PLIO_1`,
  `NOCOMPRESS`, with all three quantization/dithering modes.
- Gzipped files (`.fits.gz`) when built with `GZIP=1` (see below).
- Rows follow the FITS convention (first row at the bottom) unless `ROWORDER = 'TOP-DOWN'`.
- The **Header** button lists every HDU and all header cards; tables and other files
  without an image open straight on the header.

Not supported: `HCOMPRESS_1` tiles (such files still open on their header), random groups.

## Install

Requirements: macOS 11 or later, the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/lmytime/uFits.git
cd uFits
make install          # builds build/uFits.app, copies it to /Applications, registers it
```

Then select a FITS file in Finder and press Space. Open uFits once from Applications
to see whether the extensions are registered and enabled; it also has a
**Reset Quick Look** button. The app does not need to keep running.

A pre-built, ad hoc signed `uFits.zip` is attached to every CI run. macOS quarantines
downloaded apps that are not notarized: after unzipping run
`xattr -dr com.apple.quarantine uFits.app`, or allow it under System Settings ›
Privacy & Security, before moving it to Applications.

### Build options

```sh
make                   # build/uFits.app only
make ARCHS=arm64       # native-only build (default is universal)
make GZIP=1 install    # also preview .gz files (claims every gzip file, see below)
make SIGN="Developer ID Application: Your Name (TEAMID)" zip   # signed for distribution
make uninstall
```

`.fits.gz` files carry the `.gz` extension, so macOS identifies them as gzip archives,
not FITS. With `GZIP=1` uFits handles every gzip file and gives up quickly on the ones
that are not FITS; this can override another app's Quick Look support for archives,
so it is off by default.

## Troubleshooting

- **Nothing happens / generic icon.** Check System Settings › General › Login Items &
  Extensions › Quick Look (macOS 15+; Extensions › Quick Look on older systems) and make
  sure uFits is enabled, then run `qlmanage -r && qlmanage -r cache` or use the app's
  **Reset Quick Look** button.
- **Another FITS app owns `.fits`.** uFits uses the type `gov.nasa.gsfc.fits`. If
  another app declares a different identifier for `.fits`, macOS may not route those
  files to uFits; the uFits window tells you which type `.fits` currently maps to.
  `mdls -name kMDItemContentType file.fits` shows the same for a single file.
- **See what the extensions are doing:**
  `log stream --predicate 'process CONTAINS "uFits"'`.

## Development

```
core/       C core: parsing, decompression, binning, stretch (portable, zlib only)
tools/      fqtool command line front end, icon generator
macos/      Objective-C: app, Quick Look preview and thumbnail extensions
tests/      astropy-based test file generator, comparisons, fuzzer, Quick Look smoke test
Makefile    builds everything with clang; no Xcode project
```

The core builds and runs anywhere, which keeps it easy to test:

```sh
make test                                     # needs python3 with numpy + astropy
make fqtool && build/fqtool render image.fits out.png --max 1024
build/fqtool info image.fits                  # HDU list and what Quick Look would show
build/fqtool header image.fits 1
```

`make test` writes about 50 FITS files covering every BITPIX, scaling, blanks, NaNs, MEF,
cubes, RGB, Bayer, spectra, every supported compression, gzip and damaged files,
and checks the decoded and binned values against astropy. `tests/fuzz.py` feeds
damaged files to a sanitizer build. CI runs both on Linux and on macOS, then installs
the app on the macOS runner and asks Quick Look for thumbnails.
