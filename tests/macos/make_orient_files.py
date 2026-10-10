#!/usr/bin/env python3
"""Files that show which way up a thumbnail is: sky with a bright block on
the first pixels of the first rows. FITS puts its first row at the bottom,
so the block belongs in the lower left (orient-ll-*), unless ROWORDER says
TOP-DOWN; XISF puts its first row at the top (orient-ul-*). Small, big
(binned a lot for a thumbnail) and tile-compressed.

Usage: make_orient_files.py OUTDIR
"""
import os
import struct
import sys

import numpy as np
from astropy.io import fits

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rng = np.random.default_rng(3)


def sky(h, w):
    img = 100 + 5 * rng.standard_normal((h, w)).astype(np.float32)
    img[: int(h * 0.35), : int(w * 0.33)] += 1000   # the first rows, first columns
    return img


def path(name):
    return os.path.join(out, name)


fits.PrimaryHDU(sky(400, 600)).writeto(path("orient-ll.fits"), overwrite=True)
fits.PrimaryHDU(sky(3200, 4800)).writeto(path("orient-ll-big.fits"), overwrite=True)
fits.HDUList([fits.PrimaryHDU(), fits.CompImageHDU(sky(800, 1200), compression_type="RICE_1")]).writeto(
    path("orient-ll-rice.fits"), overwrite=True)
h = fits.PrimaryHDU(sky(400, 600))
h.header["ROWORDER"] = "TOP-DOWN"
h.writeto(path("orient-ul-topdown.fits"), overwrite=True)

# XISF: UInt16, uncompressed, one attachment after a 4096-byte header block.
data = np.clip(sky(400, 600) * 20, 0, 65535).astype("<u2").tobytes()
xml = ('<?xml version="1.0" encoding="UTF-8"?><xisf version="1.0" xmlns="http://www.pixinsight.com/xisf">'
       f'<Image geometry="600:400:1" sampleFormat="UInt16" colorSpace="Gray" '
       f'location="attachment:4096:{len(data)}"/></xisf>').encode()
head = struct.pack("<8sII", b"XISF0100", len(xml), 0) + xml
with open(path("orient-ul.xisf"), "wb") as f:
    f.write(head + bytes(4096 - len(head)) + data)
