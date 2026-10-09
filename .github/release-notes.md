uFits shows FITS files in Finder: Quick Look previews (select a file, press Space) and
thumbnails for images, cubes, tile-compressed `.fz` files, spectra, light curves, catalogs
and tables, with every header.

**Install**

1. Open the disk image and drag **uFits** onto **Applications**.
2. This build is not notarized by Apple, so macOS blocks it at first. Either run
   ```
   xattr -dr com.apple.quarantine /Applications/uFits.app
   ```
   in Terminal, or open uFits, then click **Open Anyway** under
   System Settings › Privacy & Security.
3. Open uFits once: it registers the Quick Look extensions and shows whether they are
   enabled. It does not need to keep running.

Universal (Apple silicon and Intel), macOS 11 or later.
