uFits shows FITS files in Finder: Quick Look previews (select a file, press Space) and
thumbnails for images, cubes, tile-compressed `.fz` files, spectra, light curves, catalogs
and tables, with every header.

**New in 0.0.3**

- Zoom into images and cubes: pinch, ⌥-click (⇧⌥-click zooms out), or scroll with ⌘ or
  ⌥ held. Zoomed in, the part on view is shown at full resolution.
- A shorter bar: the image's size and type, or the table's rows and columns. The HDU menu
  says which HDU is shown ("HDU 1 SCI") and what each holds when opened.
- In Quick Look, the HDU menu and the Image/Table/Header switch answer clicks at once
  (they waited half a second).
- The FITS files of X-ray missions open by their own names: `.pha`, `.pi`, `.arf`,
  `.rmf`, `.rsp`, `.rsp2`, `.evt`, `.lc`, `.img`, `.hk`, `.mkf` and `.dph`.
- uFits now tells you when a newer version is out (**Update available** in the bar) and
  updates itself in a few seconds when you open it. It looks on GitHub at most once a
  day; turn this off in the uFits app. (From 0.0.2, update once with the command below.)

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
