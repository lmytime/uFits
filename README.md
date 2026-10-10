# uFits

Quick Look for FITS files on macOS. Select a FITS file in Finder and press Space to see
it, and get real thumbnails in Finder windows. Files named `.fits`, `.fit`, `.fts` and
`.fz` work, and so do the FITS files of X-ray missions: `.pha`, `.pi`, `.arf`, `.rmf`,
`.rsp`, `.rsp2`, `.evt`, `.lc`, `.img`, `.hk`, `.mkf` and `.dph`.

Homepage: **[lmytime.github.io/uFits](https://lmytime.github.io/uFits/)**

## Install

```sh
curl -fsSL https://github.com/lmytime/uFits/releases/latest/download/install.sh | sh
```

That's all: select a FITS file in Finder and press Space. Works on macOS 11 or later,
Apple silicon and Intel.

To uninstall:

```sh
curl -fsSL https://github.com/lmytime/uFits/releases/latest/download/install.sh | sh -s -- --uninstall
```

Prefer to install by hand? Download `uFits-<version>.dmg` from
[Releases](https://github.com/lmytime/uFits/releases), drag uFits onto Applications,
run `xattr -dr com.apple.quarantine /Applications/uFits.app` (the app is not notarized
by Apple), then open uFits once.

## What you see

- **Images** in any format FITS allows, with blank pixels transparent and an automatic
  stretch that brings out faint detail. Cubes get a slider to step through their planes;
  RGB cubes and colour camera frames (Bayer) are shown in colour; tile-compressed `.fz`
  files work too.
- **Plots** of spectra and light curves (TESS, Kepler, SDSS, HST and JWST spectra, X-ray
  light curves and spectra, ...) and **sky maps** of catalogs with RA and Dec.
- **Table**: the rows of any table, even millions of them. ⌘C copies the selected rows.
- **Header**: every keyword, with values and comments lined up. ⌘F searches it.

Previews are fast even for huge files: uFits reads only the part of the file it shows.

## Using the preview

The bar at the bottom of the preview has:

- **Image** (or **Plot**), **Table**, **Header**: what to show.
- A menu of the file's HDUs (extensions such as `SCI`, `ERR`, `DQ`, or tables), when it
  has more than one.
- A slider for the planes of a cube.
- The stretch: automatic, linear (0.5–99.5 %) or min–max. Your choice is remembered.

To zoom into an image, pinch, ⌥-click (⇧⌥-click zooms out), or scroll with ⌘ or ⌥
held; in the uFits app ⌘+, ⌘− and ⌘0 work too. Zoomed in, the part on view is shown at
full resolution.

When a new version of uFits is out, **Update available** appears in the bar: click it to
update in a few seconds. uFits looks for new versions on GitHub at most once a day, in
the background; turn this off in the uFits app.

You can also open FITS files in the uFits app (File › Open, or drop them on its icon).

## Troubleshooting

- **Space shows nothing, or Finder shows plain icons.** Open the uFits app: it tells you
  whether its Quick Look extensions are on. If not, turn uFits on under System Settings ›
  General › Login Items & Extensions › Quick Look, then click **Reset Quick Look** in the
  app.
- **Another app takes over `.fits` files.** The uFits app shows which file type `.fits`
  maps to on your Mac; quitting or removing the other FITS app's Quick Look plug-in
  usually fixes it.
- **`.fits.gz` files are not previewed.** macOS treats them as gzip archives.
- **Not supported:** `HCOMPRESS_1` compressed images (their header is still shown) and
  random-groups files.

Building from source and how uFits works: [DEVELOPMENT.md](DEVELOPMENT.md).
