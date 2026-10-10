# uFits

Quick Look for FITS and XISF files on macOS. Select a file in Finder and press Space to
see it, and get real thumbnails in Finder windows. Files named `.fits`, `.fit`, `.fts`,
`.fz` and `.xisf` work, and so do the FITS files of X-ray missions: `.pha`, `.pi`, `.arf`, `.rmf`,
`.rsp`, `.rsp2`, `.evt`, `.lc`, `.hk`, `.mkf`, `.dph` and `.img` (which macOS takes for
a disk image: Space shows it, but Finder icons stay plain).

Homepage: **[lmytime.github.io/uFits](https://lmytime.github.io/uFits/)**

## Install

```sh
curl -fsSL https://github.com/lmytime/uFits/releases/latest/download/install.sh | sh
```

That's all: select a FITS or XISF file in Finder and press Space. Works on macOS 11 or later,
Apple silicon and Intel.

To uninstall (the app, its settings and all it keeps in your Library):

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
- **XISF images**: 2D grayscale, RGB and Bayer images, with automatic stretch, zoom
  and an image menu for files containing multiple images. Compressed images work too.
- **Plots** of spectra and light curves (TESS, Kepler, SDSS, HST and JWST spectra, X-ray
  light curves and spectra, ...) and **sky maps** of catalogs with RA and Dec.
- **Table**: the rows of any table, even millions of them. ⌘C copies the selected rows.
- **Header**: every keyword, with values and comments lined up. ⌘F searches it.

FITS and uncompressed XISF previews are fast even for huge files: uFits reads only
the part of the file it shows.

## Using the preview

The bar at the bottom of the preview has:

- **Image** (or **Plot**), **Table**, **Header**: what to show.
- A menu of the file's HDUs (extensions such as `SCI`, `ERR`, `DQ`, or tables), or XISF
  images, when it has more than one.
- A slider for the planes of a cube.
- The stretch: automatic, linear (0.5–99.5 %) or min–max. Your choice is remembered
  (it is the same setting as in the uFits app).

To zoom into an image, pinch, ⌥-click (⇧⌥-click zooms out), or scroll with ⌘ or ⌥
held; in the uFits app ⌘+, ⌘− and ⌘0 work too. Zoomed in, the part on view is shown at
full resolution.

When a new version of uFits is out, **Update available** appears in the bar; open the
uFits app and it updates itself in a few seconds.

You can also open FITS and XISF files in the uFits app (File › Open, or drop them on its icon).

## The uFits app

Open uFits (in Applications) to see whether its Quick Look extensions are on, and to set:

- **Show thumbnails in Finder's icon and gallery views.** Small icons (list and column
  views) always keep the file's own icon.
- **Previews open with** the automatic, linear or min–max stretch.
- **Check for updates automatically (once a day)**: uFits asks GitHub, in the background,
  whether a new version is out, and offers it. **Check Now** asks at once.

## Troubleshooting

- **Space shows nothing, or Finder shows plain icons.** Open the uFits app: it tells you
  whether its Quick Look extensions are on. If not, turn uFits on under System Settings ›
  General › Login Items & Extensions › Quick Look, then click **Reset Quick Look** in the
  app.
- **Thumbnails fill only a quarter of the icon or are upside down, or the uFits app says
  "Version 1.0.0".** An old copy of uFits is still on your Mac. The first builds were
  numbered 1.0.0, higher than today's versions, and macOS 15 makes Finder's thumbnails
  with the copy numbered highest. The uFits app in Applications lists other copies and
  moves them to the Trash; the installer unregisters them too. To find them yourself:
  `pluginkit -m -A -D -v -i io.github.lmytime.uFits.Thumbnail`.
- **Another app takes over `.fits` files.** The uFits app shows which file type `.fits`
  maps to on your Mac; quitting or removing the other FITS app's Quick Look plug-in
  usually fixes it.
- **`.fits.gz` files are not previewed.** macOS treats them as gzip archives.
- **Not supported:** `HCOMPRESS_1` compressed images (their header is still shown) and
  random-groups files.
- **Some XISF variants are not supported.** See [XISF support and limits](DEVELOPMENT.md#xisf).

Building from source and how uFits works: [DEVELOPMENT.md](DEVELOPMENT.md).

## License

uFits is free and open source, under the [BSD 3-Clause License](LICENSE).
