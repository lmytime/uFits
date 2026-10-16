uFits shows FITS, XISF and ASDF files in Finder: Quick Look previews (select a file,
press Space) and thumbnails for images, cubes, tile-compressed `.fz` files, spectra, light
curves, catalogs and tables, with every header.

**New in 0.0.9**

- **ASDF files**, such as those of the Nancy Grace Roman Space Telescope: every array in a
  file (images, cubes such as Roman's raw ramps, and 1-D arrays) is shown, named by its
  place in the file's tree (`roman.data`, `roman.dq`, ...), the science image first.
  Arrays compressed with LZ4 (as Roman's pipeline writes them), zlib or bzip2 work too;
  of a cube, only the plane on show is decompressed. **Header** shows the whole tree, and
  Finder shows thumbnails of `.asdf` files.
- XISF previews draw several times faster.

From 0.0.3 on, uFits says when a newer version is out (**Update available** in the
preview's bar) and updates itself when you open it. From 0.0.2 or earlier, update once
with the command below. See [0.0.8](https://github.com/lmytime/uFits/releases/tag/v0.0.8)
for moving around a zoomed-in image,
[0.0.7](https://github.com/lmytime/uFits/releases/tag/v0.0.7)
for the pixel galaxy icon and the App icon setting,
[0.0.6](https://github.com/lmytime/uFits/releases/tag/v0.0.6) for thumbnails that fill
Finder's icons and the app's settings,
[0.0.5](https://github.com/lmytime/uFits/releases/tag/v0.0.5) for XISF images and
[0.0.3](https://github.com/lmytime/uFits/releases/tag/v0.0.3) for zoom and the FITS files
of X-ray missions.

**Install** with one command in Terminal:

```sh
curl -fsSL https://github.com/lmytime/uFits/releases/download/@TAG@/install.sh | sh
```

It downloads the disk image below, checks its SHA-256, copies uFits to Applications and
turns on its Quick Look extensions. Then select a FITS, XISF or ASDF file in Finder and
press Space.
To remove uFits, run the same command with `sh -s -- --uninstall` at the end.

**Or by hand:** open the disk image and drag uFits onto Applications. The app is not
notarized, so macOS blocks it at first: run
`xattr -dr com.apple.quarantine /Applications/uFits.app`, or open uFits and click
**Open Anyway** under System Settings › Privacy & Security. Then open uFits once to
register its Quick Look extensions.

Universal (Apple silicon and Intel), macOS 11 or later.
