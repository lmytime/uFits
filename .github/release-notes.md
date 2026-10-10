uFits shows FITS files in Finder: Quick Look previews (select a file, press Space) and
thumbnails for images, cubes, tile-compressed `.fz` files, spectra, light curves, catalogs
and tables, with every header.

**New in 0.0.4**

- Thumbnails fill their icon on Retina screens (they were drawn in its lower left
  quarter).
- Updating keeps both Quick Look extensions on: the installer checks that macOS has
  registered them, and tries again if not.

From 0.0.3 on, uFits says when a newer version is out (**Update available** in the
preview's bar) and updates itself when you open it. From 0.0.2 or earlier, update once
with the command below. See [0.0.3](https://github.com/lmytime/uFits/releases/tag/v0.0.3)
for zoom, the shorter bar and the FITS files of X-ray missions.

**Install** with one command in Terminal:

```sh
curl -fsSL https://github.com/lmytime/uFits/releases/download/@TAG@/install.sh | sh
```

It downloads the disk image below, checks its SHA-256, copies uFits to Applications and
turns on its Quick Look extensions. Then select a FITS file in Finder and press Space.
To remove uFits, run the same command with `sh -s -- --uninstall` at the end.

**Or by hand:** open the disk image and drag uFits onto Applications. The app is not
notarized, so macOS blocks it at first: run
`xattr -dr com.apple.quarantine /Applications/uFits.app`, or open uFits and click
**Open Anyway** under System Settings › Privacy & Security. Then open uFits once to
register its Quick Look extensions.

Universal (Apple silicon and Intel), macOS 11 or later.
