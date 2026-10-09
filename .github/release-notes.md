uFits shows FITS files in Finder: Quick Look previews (select a file, press Space) and
thumbnails for images, cubes, tile-compressed `.fz` files, spectra, light curves, catalogs
and tables, with every header.

**Install** with one command in Terminal:

```sh
curl -fsSL https://github.com/lmytime/uFits/releases/download/@TAG@/install.sh | sh
```

It downloads the disk image below, checks its SHA-256, copies uFits to Applications and
turns on its Quick Look extensions. Then select a FITS file in Finder and press Space.
If the repository is private, fetch the installer with the GitHub CLI instead (after
`gh auth login`):

```sh
gh release download @TAG@ -R lmytime/uFits -p install.sh -O - | sh
```

To remove uFits, run the same command with `sh -s -- --uninstall` at the end.

**Or by hand:** open the disk image and drag uFits onto Applications. The app is not
notarized, so macOS blocks it at first: run
`xattr -dr com.apple.quarantine /Applications/uFits.app`, or open uFits and click
**Open Anyway** under System Settings › Privacy & Security. Then open uFits once to
register its Quick Look extensions.

Universal (Apple silicon and Intel), macOS 11 or later.
