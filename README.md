# uFits

Quick Look for FITS files on macOS. Select a `.fits`, `.fit`, `.fts` or `.fz` file in
Finder and press Space to see it, and get real thumbnails in Finder windows.

## Install

```sh
curl -fsSL https://github.com/lmytime/uFits/releases/latest/download/install.sh | sh
```

That's all: select a FITS file in Finder and press Space. Works on macOS 11 or later,
Apple silicon and Intel.

While the repository is private, install with the [GitHub CLI](https://cli.github.com)
after `gh auth login`:

```sh
gh release download -R lmytime/uFits -p install.sh -O - | sh
```

To uninstall:

```sh
curl -fsSL https://github.com/lmytime/uFits/releases/latest/download/install.sh | sh -s -- --uninstall
```

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
