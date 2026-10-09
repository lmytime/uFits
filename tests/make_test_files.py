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


def add_cards(path, ext, cards):
    """Insert header cards (keyword and value, or a card's text) before END,
    in place (astropy will not write some things, such as scaled integer
    columns with nulls)."""
    with fits.open(path) as hl:
        start, end = hl[ext]._header_offset, hl[ext]._data_offset
    raw = bytearray(open(path, "rb").read())
    pos = next(i for i in range(start, end, 80) if raw[i:i + 8] == b"END     ")
    new = b"".join((c if isinstance(c, str) else fits.Card(*c).image).ljust(80).encode() for c in cards)
    assert raw[pos + 80 + len(new) - 80:end].strip() == b"", "no room in the header block"
    raw[pos:pos + 80 + len(new)] = new + raw[pos:pos + 80]
    open(path, "wb").write(bytes(raw))


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

    # Tables: light curves and spectra get plotted, anything gets listed.
    n = 2000
    t = 1500.0 + np.arange(n) * (2 / 1440)
    f = 1000 + 5 * rng.standard_normal(n)
    f[(t % 3.1) < 0.12] -= 30                       # transits
    pdc = f.astype(np.float32)
    pdc[300:340] = np.nan                           # a gap
    lc = fits.BinTableHDU.from_columns([
        fits.Column("TIME", "D", unit="BJD - 2457000, days", array=t),
        fits.Column("TIMECORR", "E", array=np.zeros(n)),
        fits.Column("CADENCENO", "J", array=np.arange(n)),
        fits.Column("SAP_FLUX", "E", unit="e-/s", array=f * 1.1),
        fits.Column("PDCSAP_FLUX", "E", unit="e-/s", array=pdc),
        fits.Column("QUALITY", "J", array=np.zeros(n, np.int32)),
    ], name="LIGHTCURVE")
    write([fits.PrimaryHDU(), lc, fits.ImageHDU(np.ones((11, 13), np.int32), name="APERTURE")],
          p("lc_tess.fits"))

    loglam = np.log10(3800) + np.arange(3000) * 1e-4
    sflux = 10 + 3 * np.exp(-((10 ** loglam - 6563) / 5) ** 2) + rng.standard_normal(3000)
    coadd = fits.BinTableHDU.from_columns([
        fits.Column("flux", "E", array=sflux), fits.Column("loglam", "E", array=loglam),
        fits.Column("ivar", "E", array=np.ones(3000)), fits.Column("and_mask", "J", array=np.zeros(3000)),
    ], name="COADD")
    specobj = fits.BinTableHDU.from_columns([
        fits.Column("CLASS", "6A", array=np.array(["GALAXY"])), fits.Column("Z", "E", array=[0.1]),
    ], name="SPECOBJ")
    write([fits.PrimaryHDU(), coadd, specobj], p("spec_sdss.fits"))

    w1 = np.linspace(1150, 1450, 1024)
    x1d = fits.BinTableHDU.from_columns([
        fits.Column("SEGMENT", "4A", array=np.array(["FUVA", "FUVB"])),
        fits.Column("NELEM", "J", array=[1024, 1024]),
        fits.Column("WAVELENGTH", "1024D", unit="Angstrom", array=np.stack([w1 + 300, w1])),
        fits.Column("FLUX", "1024E", unit="erg /s /cm**2 /Angstrom",
                    array=np.stack([np.sin(w1 / 7), np.cos(w1 / 5)]) * 1e-14),
    ], name="SCI")
    write([fits.PrimaryHDU(), x1d], p("spec_x1d.fits"))

    m = 500
    mjd = 58000 + np.sort(rng.uniform(0, 400, m))
    mag = 15 + 0.5 * np.sin(mjd / 13) + 0.05 * rng.standard_normal(m)
    rate = np.round((mag - 14) * 1000).astype(np.int32)
    rate[::17] = -999                               # nulls in a scaled int column
    write([fits.PrimaryHDU(), fits.BinTableHDU.from_columns([
        fits.Column("MJD", "D", array=mjd), fits.Column("MAG", "E", unit="mag", array=mag),
        fits.Column("FILTER", "1A", array=np.array(["g"] * m)),
    ], name="PHOT")], p("lc_mag.fits"))
    write([fits.PrimaryHDU(), fits.BinTableHDU.from_columns([
        fits.Column("TIME", "D", unit="s", array=mjd * 86400.0),
        fits.Column("RATE", "J", unit="count/s", array=rate),
    ], name="RATE")], p("lc_scaled.fits"))
    add_cards(p("lc_scaled.fits"), 1, [("TSCAL2", 0.001), ("TZERO2", 14.0), ("TNULL2", -999)])

    chan = np.arange(1024, dtype=np.int16)
    counts = rng.poisson(50 * np.exp(-chan / 300.0) + 3).astype(np.int32)
    write([fits.PrimaryHDU(), fits.BinTableHDU.from_columns([
        fits.Column("CHANNEL", "I", array=chan), fits.Column("COUNTS", "J", unit="count", array=counts),
    ], name="SPECTRUM")], p("pha.fits"))

    # Catalogs: RA/Dec positions, one field across RA = 0 with placeholder
    # values (-999) and NaNs to skip, one with Gaia-style lower-case names.
    n = 3000
    ra = rng.uniform(-6, 6, n)
    dec = rng.uniform(-4, 4, n)
    ra[:600] = rng.normal(2, 0.4, 600)          # a cluster
    dec[:600] = rng.normal(1, 0.3, 600)
    ra %= 360
    ra[600:610] = -999
    dec[610:620] = -999
    ra[620:625] = np.nan
    write([fits.PrimaryHDU(), fits.BinTableHDU.from_columns([
        fits.Column("ID", "J", array=np.arange(n)), fits.Column("RA", "D", unit="deg", array=ra),
        fits.Column("DEC", "D", unit="deg", array=dec), fits.Column("MAG", "E", array=rng.normal(20, 1, n)),
        fits.Column("NAME", "10A", array=np.array([f"src{i}" for i in range(n)])),
    ], name="CATALOG")], p("catalog_wrap.fits"))
    write([fits.PrimaryHDU(), fits.BinTableHDU.from_columns([
        fits.Column("source_id", "K", array=np.arange(2000) * 7919),
        fits.Column("ra", "D", unit="deg", array=rng.uniform(120, 140, 2000)),
        fits.Column("dec", "D", unit="deg", array=rng.uniform(20, 30, 2000)),
        fits.Column("phot_g_mean_mag", "E", array=rng.normal(17, 1.5, 2000)),
    ], name="GAIA")], p("catalog_gaia.fits"))

    k = 6
    mixed = fits.BinTableHDU.from_columns([
        fits.Column("NAME", "12A", array=np.array(["alpha", "beta", "gamma", "delta", "", "zeta"])),
        fits.Column("FLAG", "L", array=np.array([True, False, True, True, False, True])),
        fits.Column("BITS", "11X", array=np.zeros((k, 11), bool)),
        fits.Column("SMALL", "B", array=np.arange(k, dtype=np.uint8)),
        fits.Column("SHORT", "I", null=-1, array=np.array([1, -1, 3, 4, 5, 6], np.int16)),
        fits.Column("BIG", "K", array=np.arange(k, dtype=np.int64) * 10 ** 12),
        fits.Column("VEC", "3E", array=np.arange(3 * k, dtype=np.float32).reshape(k, 3)),
        fits.Column("LONGVEC", "50D", array=np.ones((k, 50))),
        fits.Column("Z", "C", array=np.arange(k) * (1 + 2j)),
        fits.Column("ZZ", "M", array=np.arange(k) * (3 - 1j)),
        fits.Column("VLA", "PE()", array=[np.arange(i, dtype=np.float32) for i in range(k)]),
    ], name="MIXED")
    ascii_tab = fits.TableHDU.from_columns([
        fits.Column("ID", "I6", array=np.arange(4)), fits.Column("RA", "F10.5", array=np.linspace(10, 11, 4)),
        fits.Column("NOTE", "A8", array=np.array(["a", "bb", "ccc", "dddd"])),
    ], name="ASCII")
    write([fits.PrimaryHDU(), mixed, ascii_tab], p("tables_mixed.fits"))

    # A header with every kind of card: quotes, slashes, long strings
    # (CONTINUE), HIERARCH keywords, commentary, blank and odd cards.
    h = fits.PrimaryHDU(np.arange(600, dtype=np.int16).reshape(20, 30))
    for k, v in [("OBJECT", ("NGC 4535", "target")), ("OBSERVER", ("O'Brien", "quote inside")),
                 ("PATH", ("a/b/c", "slashes / in both")), ("EMPTY", ("", "empty string")),
                 ("UNDEF", (None, "no value")), ("FLAG", (False, "boolean")),
                 ("EXPTIME", (1200.5, "[s] exposure")), ("BIGINT", 1234567890123),
                 ("CPLX", (1 + 2j, "complex")),
                 ("LONGSTR", ("x" * 70 + " and a long tail " + "y" * 40, "comment of a long string")),
                 ("HIERARCH ESO DET CHIP1 ID", ("ccd1", "chip")),
                 ("HIERARCH ESO TEL AMBI FWHM START", (0.85, "seeing"))]:
        h.header[k] = v
    h.header.add_comment("a comment")
    h.header.add_comment("   indented comment")
    h.header.add_history("step 1: bias")
    h.header[""] = "blank keyword text"
    write([h], p("header_cards.fits"))
    add_cards(p("header_cards.fits"), 0, [
        "", "COMMENT", "NOEQUALS  this card has no value indicator",
        "AMPER   = 'ends with &' / not continued", "D_EXP   =             1.5D+03 / Fortran exponent"])

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
