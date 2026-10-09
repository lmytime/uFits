#!/usr/bin/env python3
"""Big files for the preview UI timings: a catalog of a million rows (a sky
plot, its rows, its header), also gzipped, a table 300 columns wide and a
file of 200 HDUs.

Usage: make_big_files.py OUTDIR
"""
import gzip
import os
import shutil
import sys

import numpy as np
from astropy.io import fits

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rng = np.random.default_rng(7)

n = 1_000_000
mag = rng.normal(22, 1.5, n).astype(np.float32)
cat = fits.BinTableHDU.from_columns([
    fits.Column("ID", "K", array=np.arange(n)),
    fits.Column("RA", "D", array=rng.uniform(150, 151, n)),
    fits.Column("DEC", "D", array=rng.uniform(2, 3, n)),
    fits.Column("MAG", "E", array=mag),
    fits.Column("MAGERR", "E", array=(0.01 * 10 ** (0.2 * (mag - 20))).astype(np.float32)),
    fits.Column("FLUX", "E", array=(10 ** (-0.4 * (mag - 23.9))).astype(np.float32)),
    fits.Column("Z", "E", array=rng.uniform(0, 3, n).astype(np.float32)),
    fits.Column("CLASS", "J", array=rng.integers(0, 5, n).astype(np.int32)),
    fits.Column("FLAG", "L", array=rng.random(n) < 0.1),
    fits.Column("NAME", "12A", array=np.char.add("src", np.arange(n).astype("U9"))),
    fits.Column("SHAPE", "3E", array=rng.normal(size=(n, 3)).astype(np.float32)),
], name="CATALOG")
fits.HDUList([fits.PrimaryHDU(), cat]).writeto(os.path.join(out, "big_catalog.fits"), overwrite=True)
# The same, gzipped: it has to be inflated to be read, which takes a while.
with open(os.path.join(out, "big_catalog.fits"), "rb") as fi, \
        gzip.open(os.path.join(out, "big_catalog.fits.gz"), "wb", compresslevel=1) as fo:
    shutil.copyfileobj(fi, fo)

wide = fits.BinTableHDU.from_columns(
    [fits.Column(f"C{i:03d}", "E", array=rng.normal(size=2000).astype(np.float32)) for i in range(300)],
    name="WIDE")
fits.HDUList([fits.PrimaryHDU(), wide]).writeto(os.path.join(out, "wide_table.fits"), overwrite=True)

hdus = [fits.PrimaryHDU()]
for i in range(200):
    h = fits.ImageHDU(np.full((4, 4), i, np.float32), name=f"EXT{i}")
    for k in range(40):
        h.header[f"KEY{k:03d}"] = (k * 1.5, f"comment number {k}")
    hdus.append(h)
fits.HDUList(hdus).writeto(os.path.join(out, "many_hdus.fits"), overwrite=True)
print("wrote big_catalog.fits(.gz), wide_table.fits, many_hdus.fits")
