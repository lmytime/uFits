uFits shows FITS and XISF files in Finder: Quick Look previews (select a file, press
Space) and thumbnails for images, cubes, tile-compressed `.fz` files, spectra, light
curves, catalogs and tables, with every header.

**New in 0.0.6**

- Thumbnails fill Finder's icons on Retina screens, sharp at any size, in icon and
  gallery views. List and column views keep the file's own small icon.
- Settings in the uFits app: thumbnails on or off, the stretch previews open with (one
  setting for Quick Look and the app), and checking for updates, with **Check Now**.
- An old copy of uFits elsewhere on your Mac (the first builds were numbered 1.0.0) could
  make Finder's thumbnails on macOS 15, too small or upside down. The app now lists other
  copies and moves them to the Trash, and the installer takes them out of Quick Look's use.
- Uninstalling removes everything: the app, its settings and what it keeps in your Library.

From 0.0.3 on, uFits says when a newer version is out (**Update available** in the
preview's bar) and updates itself when you open it. From 0.0.2 or earlier, update once
with the command below. See [0.0.5](https://github.com/lmytime/uFits/releases/tag/v0.0.5)
for XISF images and [0.0.3](https://github.com/lmytime/uFits/releases/tag/v0.0.3) for
zoom and the FITS files of X-ray missions.

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
