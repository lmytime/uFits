#!/usr/bin/env python3
"""Generate FITS files that exercise the uFits core.

Usage: make_test_files.py OUTDIR

Needs numpy and astropy. Every file is small, so the whole set takes a
second or two to write.
"""
import gzip
import os
import shutil
import sys

import numpy as np
from astropy.io import fits

rng = np.random.default_rng(42)


def sky(h, w, sky_level=100.0, noise=5.0, nstars=60, dtype=np.float32):
    """A synthetic star field with a galaxy and a gradient."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    img = sky_level + noise * rng.standard_normal((h, w)).astype(np.float32)
    img += 0.02 * x + 0.01 * y
    for _ in range(nstars):
        cx, cy = rng.uniform(0, w), rng.uniform(0, h)
        amp = rng.uniform(50, 5000)
        s = rng.uniform(1.0, 2.5)
        img += amp * np.exp(-((x - cx) ** 2 + (y - cy) ** 2) / (2 * s * s))
    r = np.hypot((x - w * 0.6) / 1.0, (y - h * 0.4) / 0.6)
    img += 800 * np.exp(-r / (0.05 * max(w, h)))
    return img.astype(dtype)


def write(hdus, path):
    fits.HDUList(hdus).writeto(path, overwrite=True)


def main(out):
    os.makedirs(out, exist_ok=True)
    p = lambda name: os.path.join(out, name)

    base = sky(300, 400)

    # Plain images in every BITPIX.
    write([fits.PrimaryHDU(np.clip(base / 20, 0, 255).astype(np.uint8))], p("u8.fits"))
    write([fits.PrimaryHDU((base - 200).astype(np.int16))], p("i16.fits"))
    write([fits.PrimaryHDU((base * 1000).astype(np.int32))], p("i32.fits"))
    write([fits.PrimaryHDU((base * 1e6).astype(np.int64))], p("i64.fits"))
    write([fits.PrimaryHDU(base.astype(np.float32))], p("f32.fits"))
    write([fits.PrimaryHDU(base.astype(np.float64) + 1e10)], p("f64_offset.fits"))

    # Unsigned and scaled integers.
    write([fits.PrimaryHDU((base * 10).astype(np.uint16))], p("u16.fits"))
    write([fits.PrimaryHDU((base * 10).astype(np.uint32))], p("u32.fits"))
    write([fits.PrimaryHDU((base - 128).clip(-128, 127).astype(np.int8))], p("i8.fits"))
    h = fits.PrimaryHDU(base.astype(np.float64))
    h.scale("int16", bscale=0.25, bzero=1000.0)
    write([h], p("scaled_i16.fits"))

    # Missing data: BLANK for integers, NaN for floats.
    d = (base - 200).astype(np.int16)
    d[10:40, 50:90] = -32768
    h = fits.PrimaryHDU(d)
    h.header["BLANK"] = -32768
    write([h], p("blank_i16.fits"))
    d = (base * 100).astype(np.int32)
    d[:, :30] = -999
    h = fits.PrimaryHDU(d)
    h.header["BLANK"] = -999
    write([h], p("blank_i32.fits"))
    d = base.copy()
    d[50:120, 200:260] = np.nan
    d[::7, ::5] = np.nan
    d[0, 0] = np.inf
    write([fits.PrimaryHDU(d)], p("nan_f32.fits"))
    d = base.copy()
    yy, xx = np.mgrid[0:300, 0:400]
    d[(xx + yy) % 400 > 330] = np.nan   # a tilted footprint, like a mosaic
    write([fits.PrimaryHDU(d)], p("footprint_f32.fits"))
    write([fits.PrimaryHDU(np.full((50, 60), np.nan, np.float32))], p("all_nan.fits"))
    write([fits.PrimaryHDU(np.full((50, 60), 7, np.int16))], p("constant.fits"))
    d = np.zeros((200, 300), np.float32)
    d[50:150, 100:200] = sky(100, 100, 10, 1)
    write([fits.PrimaryHDU(d)], p("mostly_zero.fits"))

    # Multi-extension files.
    sci = sky(256, 256)
    write([fits.PrimaryHDU(), fits.ImageHDU(sci, name="SCI"),
           fits.ImageHDU(np.sqrt(np.abs(sci)), name="ERR"),
           fits.ImageHDU(np.zeros((256, 256), np.int32), name="DQ")], p("mef.fits"))
    cols = fits.ColDefs([fits.Column("a", "E", array=np.arange(10.0)),
                         fits.Column("b", "10A", array=np.array(["x"] * 10))])
    write([fits.PrimaryHDU(), fits.BinTableHDU.from_columns(cols, name="CAT")], p("table_only.fits"))
    write([fits.PrimaryHDU(), fits.BinTableHDU.from_columns(cols, name="CAT"),
           fits.ImageHDU(sci, name="IMG")], p("table_then_image.fits"))

    # Cubes, colour.
    cube = np.stack([sky(120, 160) * (i + 1) for i in range(5)])
    write([fits.PrimaryHDU(cube)], p("cube5.fits"))
    rgb = np.stack([sky(150, 200), sky(150, 200) * 0.8, sky(150, 200) * 1.3])
    write([fits.PrimaryHDU(rgb.astype(np.float32))], p("rgb.fits"))
    h = fits.PrimaryHDU(rgb.astype(np.float32))
    h.header["CTYPE3"] = "FREQ"
    write([h], p("cube3_freq.fits"))

    # Bayer mosaics (RGGB) as a camera would write them.
    hh, ww = 240, 320
    r, g, b = sky(hh, ww, 300, 8), sky(hh, ww, 900, 12), sky(hh, ww, 200, 6)
    mosaic = np.empty((hh, ww), np.float32)
    mosaic[0::2, 0::2] = r[0::2, 0::2]
    mosaic[0::2, 1::2] = g[0::2, 1::2]
    mosaic[1::2, 0::2] = g[1::2, 0::2]
    mosaic[1::2, 1::2] = b[1::2, 1::2]
    h = fits.PrimaryHDU(mosaic.clip(0, 65535).astype(np.uint16))
    h.header["BAYERPAT"] = "RGGB"
    h.header["ROWORDER"] = "TOP-DOWN"
    write([h], p("bayer_rggb.fits"))
    h = fits.PrimaryHDU(mosaic.clip(0, 65535).astype(np.uint16))
    h.header["BAYERPAT"] = "RGGB"
    h.header["XBAYROFF"] = 1
    write([h], p("bayer_offset.fits"))

    # Spectra.
    wave = 4000 + np.arange(3000) * 1.5
    flux = 1 + 0.2 * np.sin(wave / 300) + 0.02 * rng.standard_normal(3000)
    flux += 3 * np.exp(-((wave - 6563) / 4) ** 2)
    h = fits.PrimaryHDU(flux.astype(np.float32))
    h.header.update(CRVAL1=4000.0, CDELT1=1.5, CRPIX1=1.0, CUNIT1="Angstrom", BUNIT="erg/s/cm2/A")
    write([h], p("spec1d.fits"))
    write([fits.PrimaryHDU(np.stack([flux, flux * 0.1, wave, flux * 0, flux * 0]).astype(np.float32))],
          p("spec_rows.fits"))

    # Tile compressed images.
    big = sky(500, 600)
    ints = (big * 10).astype(np.int16)
    comp = [
        ("rice_i16", ints, dict(compression_type="RICE_1")),
        ("rice_i16_tiles", ints, dict(compression_type="RICE_1", tile_shape=(64, 100))),
        ("rice_u16", (big * 10).astype(np.uint16), dict(compression_type="RICE_1")),
        ("rice_u8", np.clip(big / 10, 0, 255).astype(np.uint8), dict(compression_type="RICE_1")),
        ("rice_i32", (big * 1000).astype(np.int32), dict(compression_type="RICE_1")),
        ("rice_f32_nodither", big, dict(compression_type="RICE_1", quantize_method=-1)),
        ("rice_f32_sd1", big, dict(compression_type="RICE_1", quantize_method=1, dither_seed=17)),
        ("rice_f32_sd2", big, dict(compression_type="RICE_1", quantize_method=2, dither_seed=9999)),
        ("gzip1_i32", (big * 1000).astype(np.int32), dict(compression_type="GZIP_1")),
        ("gzip1_f32_lossless", big, dict(compression_type="GZIP_1", quantize_level=0.0)),
        ("gzip2_f32_lossless", big, dict(compression_type="GZIP_2", quantize_level=0.0)),
        ("gzip2_i16", ints, dict(compression_type="GZIP_2")),
        ("gzip2_f64_lossless", big.astype(np.float64), dict(compression_type="GZIP_2", quantize_level=0.0)),
        ("gzip1_f32_sd1", big, dict(compression_type="GZIP_1", quantize_method=1, dither_seed=5)),
        ("plio_mask", (big > 300).astype(np.int16) * 3 + (big > 1000).astype(np.int16), dict(compression_type="PLIO_1")),
        ("hcomp_i16", ints, dict(compression_type="HCOMPRESS_1")),
        ("nocomp_i16", ints, dict(compression_type="NOCOMPRESS")),
    ]
    for name, data, kw in comp:
        try:
            write([fits.PrimaryHDU(), fits.CompImageHDU(data, **kw)], p(name + ".fits"))
        except Exception as e:  # some astropy versions lack a codec
            print("skip", name, e)
    nanbig = big.copy()
    nanbig[100:200, 100:300] = np.nan
    write([fits.PrimaryHDU(), fits.CompImageHDU(nanbig, compression_type="RICE_1",
                                                quantize_method=2, dither_seed=3)], p("rice_f32_nan.fits"))
    ccube = np.stack([sky(100, 120) * (i + 1) for i in range(4)])
    write([fits.PrimaryHDU(), fits.CompImageHDU(ccube, compression_type="RICE_1", quantize_method=1,
                                                dither_seed=2)], p("rice_cube.fits"))
    write([fits.PrimaryHDU(), fits.CompImageHDU(ccube, compression_type="GZIP_1", quantize_level=0.0,
                                                tile_shape=(2, 50, 60))], p("gzip_cube_3dtiles.fits"))

    # Whole-file gzip, and damaged files.
    with open(p("f32.fits"), "rb") as fi, gzip.open(p("f32.fits.gz"), "wb") as fo:
        shutil.copyfileobj(fi, fo)
    with open(p("mef.fits"), "rb") as fi, gzip.open(p("mef.fits.gz"), "wb") as fo:
        shutil.copyfileobj(fi, fo)
    raw = open(p("i16.fits"), "rb").read()
    open(p("truncated.fits"), "wb").write(raw[: len(raw) // 2])
    raw = open(p("rice_i16.fits"), "rb").read()
    open(p("truncated_rice.fits"), "wb").write(raw[: int(len(raw) * 0.7)])
    open(p("not_fits.fits"), "wb").write(b"hello world" * 400)
    open(p("header_only.fits"), "wb").write(open(p("i16.fits"), "rb").read()[:2880])

    # Big images for timing.
    if os.environ.get("FQ_BIG"):
        b = sky(4096, 4096, nstars=400)
        write([fits.PrimaryHDU(b)], p("big_f32_4k.fits"))
        write([fits.PrimaryHDU((b * 10).astype(np.uint16))], p("big_u16_4k.fits"))
        bb = np.tile(b, (2, 2))
        write([fits.PrimaryHDU(bb)], p("big_f32_8k.fits"))
        write([fits.PrimaryHDU(), fits.CompImageHDU((b * 10).astype(np.int16), compression_type="RICE_1")],
              p("big_rice_i16_4k.fits"))
        write([fits.PrimaryHDU(), fits.CompImageHDU(b, compression_type="RICE_1", quantize_method=2)],
              p("big_rice_f32_4k.fits"))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/testdata")
