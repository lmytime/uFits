#!/usr/bin/env python3
"""Check the uFits core against astropy.

Usage: test_core.py FQTOOL TESTDATA_DIR

For every image file the decoded values (full resolution), the binned
values (with and without sub-sampling) and Bayer/RGB handling are compared
with a reference computed from astropy's reading of the same file. Tables
holding a light curve or a spectrum are plotted: the plot envelope is
compared with one computed by numpy, and table listings are spot-checked.
"""
import gzip
import math
import os
import re
import subprocess
import sys
import tempfile
import zlib

import numpy as np
from astropy.io import fits

FQ = sys.argv[1]
DATA = sys.argv[2]
failures = []


def run_dump(path, *opts):
    with tempfile.NamedTemporaryFile(suffix=".f32", delete=False) as t:
        out = t.name
    try:
        r = subprocess.run([FQ, "dump", path, out, *opts], capture_output=True, text=True,
                           errors="replace")
        if r.returncode != 0:
            return None, r.stderr.strip()
        w, h, nch = map(int, r.stdout.split("\n")[0].split())
        info = dict(kv.split("=", 1) for kv in r.stdout.split("\n")[1].split() if "=" in kv)
        v = np.fromfile(out, dtype=np.float32)
        return (v.reshape(nch, h, w), info), None
    finally:
        os.unlink(out)


def run_plot(path, *opts):
    with tempfile.NamedTemporaryFile(suffix=".f32", delete=False) as t:
        out = t.name
    try:
        r = subprocess.run([FQ, "plot", path, out, *opts], capture_output=True, text=True,
                           errors="replace")
        if r.returncode != 0:
            return None, r.stderr.strip()
        lines = r.stdout.split("\n")
        info = dict(kv.split("=", 1) for kv in lines[0].split() if "=" in kv)
        info.update(l.split("=", 1) for l in lines[1:] if "=" in l)
        raw = open(out, "rb").read()
        n, rows = int(info["n"]), int(info["dot_rows"])
        v = np.frombuffer(raw[:8 * n], dtype=np.float32)
        dots = np.frombuffer(raw[8 * n:], dtype=np.uint8).reshape(n, rows) if rows else None
        return (v[:n], v[n:], dots, info), None
    finally:
        os.unlink(out)


def fqtool(*args):
    r = subprocess.run([FQ, *args], capture_output=True, text=True, errors="replace")
    return r.returncode, r.stdout


# Column names that make a table a light curve or a spectrum, best first
# (the same lists as core/fq_table.c).
LC_X = ["TIME", "BTJD", "BKJD", "BJD", "BJD_TDB", "HJD", "MJD", "JD"]
LC_Y = ["PDCSAP_FLUX", "SAP_FLUX", "FLUX", "RATE", "NET_RATE", "COUNT_RATE", "MAG", "MAGNITUDE", "COUNTS"]
SP_X = ["WAVELENGTH", "WAVE", "LAMBDA", "LAM", "LOGLAM", "FREQUENCY", "FREQ", "ENERGY", "VELOCITY",
        "VELO", "CHANNEL"]
SP_Y = ["FLUX", "FLUX_DENSITY", "FLAM", "F_LAMBDA", "FNU", "F_NU", "SPEC", "SPECTRUM", "INTENSITY",
        "COUNTS", "RATE", "DATA"]
SKY = [("RA", "DEC"), ("RAJ2000", "DEJ2000"), ("_RAJ2000", "_DEJ2000"), ("RA_ICRS", "DE_ICRS"),
       ("RAJ2000", "DECJ2000"), ("RA_J2000", "DEC_J2000"), ("ALPHA_J2000", "DELTA_J2000"),
       ("ALPHAWIN_J2000", "DELTAWIN_J2000"), ("RAMEAN", "DECMEAN"), ("RA_OBJ", "DEC_OBJ"),
       ("TARGET_RA", "TARGET_DEC"), ("RA_DEG", "DEC_DEG"), ("RADEG", "DECDEG"), ("GLON", "GLAT")]


def plot_spec(h):
    """Which columns of a binary table the core plots, or None."""
    if isinstance(h, fits.CompImageHDU) or not isinstance(h, fits.BinTableHDU):
        return None
    cols = []
    for c in h.columns:
        m = re.match(r"\s*(\d*)([A-Za-z])", str(c.format))
        rep = int(m.group(1)) if m and m.group(1) else 1
        t = m.group(2).upper() if m else ""
        cols.append((c.name, rep, t in "BIJKED" and rep >= 1))

    def find(name):
        return next((i for i, c in enumerate(cols) if c[0].upper() == name and c[2]), -1)

    for xs, ys, dots in ((LC_X, LC_Y, True), (SP_X, SP_Y, False)):
        for xn in xs:
            i = find(xn)
            if i < 0:
                continue
            for yn in ys:
                j = find(yn)
                if j >= 0 and j != i and cols[j][1] == cols[i][1]:
                    if h.header["NAXIS2"] * cols[i][1] < 2:
                        return None
                    return dict(x=cols[i][0], y=cols[j][0], dots=dots,
                                xlog=cols[i][0].upper() == "LOGLAM",
                                flip=cols[j][0].upper().startswith("MAG"), sky=False)
    for xn, yn in SKY:
        i, j = find(xn), find(yn)
        if i >= 0 and j >= 0 and cols[i][1] == cols[j][1]:
            if h.header["NAXIS2"] * cols[i][1] < 2:
                return None
            return dict(x=cols[i][0], y=cols[j][0], dots=True, xlog=False, flip=False, sky=True)
    return None


def column_values(h, name):
    """Physical values of a numeric column, NaN for nulls, flattened."""
    i = [c.name for c in h.columns].index(name) + 1
    raw = np.asarray(h.data.base[name])
    v = raw.astype(np.float64) * h.header.get(f"TSCAL{i}", 1.0) + h.header.get(f"TZERO{i}", 0.0)
    if f"TNULL{i}" in h.header and raw.dtype.kind in "iu":
        v[raw == h.header[f"TNULL{i}"]] = np.nan
    return v.ravel()


def check_plot(fn, path, h, idx, spec):
    ncol_max = 300
    res, err = run_plot(path, "--max", str(ncol_max))
    if res is None:
        failures.append(f"{fn}: plot failed: {err}")
        return
    lo, hi, dots, info = res
    if int(info["hdu"]) != idx or info["table"] != "1":
        failures.append(f"{fn}: core plotted HDU {info['hdu']} (table={info['table']}), expected table {idx}")
        return
    x, y = column_values(h, spec["x"]), column_values(h, spec["y"])
    if spec["xlog"]:
        with np.errstate(over="ignore"):
            x = 10.0 ** x
    ok = np.isfinite(x) & np.isfinite(y)
    wrap = False
    if spec["sky"]:   # placeholders off the sphere are skipped; fields across RA = 0 wrap
        with np.errstate(invalid="ignore"):
            ok &= (x >= -360) & (x <= 360) & (y >= -90) & (y <= 90)
        w = np.where(x[ok] > 180, x[ok] - 360, x[ok])
        wrap = w.max() - w.min() < x[ok].max() - x[ok].min()
    x, y = x[ok], y[ok]
    if wrap:
        x = np.where(x > 180, x - 360, x)
    xmin, xmax = x.min(), x.max()
    ncol = min(ncol_max, len(x)) if xmax > xmin else 1
    span = xmax - xmin
    c = ((x - xmin) * (ncol / span)).astype(np.int64).clip(0, ncol - 1) if ncol > 1 else np.zeros(len(x), int)
    y32 = y.astype(np.float32)
    elo = np.full(ncol, np.inf, np.float32)
    ehi = np.full(ncol, -np.inf, np.float32)
    np.minimum.at(elo, c, y32)
    np.maximum.at(ehi, c, y32)
    elo[np.isinf(elo)] = np.nan
    ehi[np.isinf(ehi)] = np.nan
    want = {
        "n": str(ncol), "points": str(len(x)), "has_x": "1", "dots": str(int(spec["dots"])),
        "y_flip": str(int(spec["flip"])), "y_label": spec["y"],
        "x_flip": str(int(spec["sky"])), "x_wrap": str(int(wrap)),
        "x_label": ("wavelength" if spec["x"][0].islower() else "WAVELENGTH") if spec["xlog"] else spec["x"],
    }
    bad = [f"{k}={info.get(k)!r} (want {v!r})" for k, v in want.items() if info.get(k) != v]
    if bad:
        failures.append(f"{fn} plot: " + ", ".join(bad))
        return
    x0, x1 = (xmin + 0.5 * span / ncol, xmax - 0.5 * span / ncol) if ncol > 1 else ((xmin + xmax) / 2,) * 2
    if not (math.isclose(float(info["x_first"]), x0, rel_tol=1e-12) and
            math.isclose(float(info["x_last"]), x1, rel_tol=1e-12)):
        failures.append(f"{fn} plot: x range {info['x_first']}..{info['x_last']}, want {x0}..{x1}")
        return
    p1, p99 = np.percentile(y, [1, 99])
    if not float(info["y_min"]) <= p1 <= p99 <= float(info["y_max"]):
        failures.append(f"{fn} plot: y range {info['y_min']}..{info['y_max']} misses {p1}..{p99}")
        return
    compare(f"{fn} plot low", lo, elo, 0)
    compare(f"{fn} plot high", hi, ehi, 0)
    if spec["dots"]:
        rows = int(info["dot_rows"])
        ymin, ymax = float(info["y_min"]), float(info["y_max"])
        r = (y - ymin) * (rows / (ymax - ymin))
        on = (r >= 0) & (r < rows)
        grid = np.zeros((ncol, rows), np.int64)
        np.add.at(grid, (c[on], r[on].astype(np.int64)), 1)
        grid = grid.clip(0, 255).astype(np.uint8)
        if dots is None or dots.shape != grid.shape or not np.array_equal(dots, grid):
            failures.append(f"{fn} plot dots differ ({0 if dots is None else int((dots > 0).sum())} vs "
                            f"{int((grid > 0).sum())} cells)")
        else:
            print(f"  ok  {fn} plot dots ({int((grid > 0).sum())} cells, up to {int(grid.max())} points)")
    elif dots is not None:
        failures.append(f"{fn} plot: dots for a line plot")


def check_listings():
    """Spot checks of HDU lists and table listings."""
    def expect(name, got, want):
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")
        else:
            print(f"  ok  {name}")

    def hdus(fn):
        rc, out = fqtool("hdus", os.path.join(DATA, fn))
        return [l.split(" | ")[0] for l in out.splitlines()]

    def rows(fn, hdu, n=10):
        rc, out = fqtool("table", os.path.join(DATA, fn), str(hdu), str(n))
        return [re.split(r"\s{2,}", l.strip()) for l in out.splitlines()[5:]] if rc == 0 else None

    if not os.path.exists(os.path.join(DATA, "tables_mixed.fits")):
        return
    expect("mef.fits hdus", hdus("mef.fits"), ["1 image 1 SCI", "2 image 1 ERR", "3 image 1 DQ"])
    expect("cube5.fits hdus", hdus("cube5.fits"), ["0 image 5 -"])
    expect("lc_tess.fits hdus", hdus("lc_tess.fits"), ["1 plot 1 LIGHTCURVE", "2 image 1 APERTURE"])
    expect("spec_rows.fits hdus", hdus("spec_rows.fits"), ["0 plot 1 -"])
    expect("table_only.fits hdus", hdus("table_only.fits"), ["1 table 1 CAT"])
    expect("tables_mixed.fits hdus", hdus("tables_mixed.fits"), ["1 table 1 MIXED", "2 table 1 ASCII"])
    expect("spec_sdss.fits hdus", hdus("spec_sdss.fits"), ["1 plot 1 COADD", "2 table 1 SPECOBJ"])
    expect("catalog_wrap.fits hdus", hdus("catalog_wrap.fits"), ["1 plot 1 CATALOG"])
    r = rows("tables_mixed.fits", 1)
    expect("tables_mixed.fits row 0", r and r[0][:7] if r else r,
           ["alpha", "T", "0x0000", "0", "1", "0", "[0 1 2]"])
    expect("tables_mixed.fits null and int64", r and r[1][3:6] if r else r, ["1", "null", "1000000000000"])
    expect("tables_mixed.fits complex and VLA", r and r[2][-3:] if r else r, ["(2, 4)", "(6, -2)", "(2 values)"])
    expect("tables_mixed.fits ascii", rows("tables_mixed.fits", 2), [["0", "10.00000", "a"], ["1", "10.33333", "bb"],
                                                                    ["2", "10.66667", "ccc"], ["3", "11.00000", "dddd"]])
    r = rows("lc_scaled.fits", 1, 2)
    expect("lc_scaled.fits scaled null", r and r[0][1] if r else r, "null")
    expect("lc_scaled.fits scaled value", r and r[1][1] if r else r, "15.207")
    expect("image HDU is not a table", fqtool("table", os.path.join(DATA, "mef.fits"), "1")[0], 1)

    # Browsing a table row by row (the preview's table view).
    def cells(fn, hdu, first, n):
        rc, out = fqtool("rows", fn, str(hdu), str(first), str(n))
        lines = out.split("\n")
        return (lines[0], lines[1].split("\t"), [l.split("\t") for l in lines[2:2 + n]]) if rc == 0 else None

    cat = os.path.join(DATA, "catalog_wrap.fits")
    with fits.open(cat) as hl:
        ref = hl[1].data
        rowlen = hl[1].header["NAXIS1"]
        data_off = hl[1]._data_offset
    head, names, rws = cells(cat, 1, 2998, 3)
    expect("table rows: size and names", (head, names), ("rows=3000 cols=5", ["ID", "RA", "DEC", "MAG", "NAME"]))
    ok = all(math.isclose(float(rws[i][1]), ref["RA"][2998 + i], rel_tol=1e-11) and
             rws[i][4] == ref["NAME"][2998 + i] for i in range(2))
    expect("table rows: the last rows match astropy", ok, True)
    expect("table rows: past the end is empty", rws[2], [""] * 5)
    with tempfile.TemporaryDirectory() as tmp:
        cut = os.path.join(tmp, "cut.fits")
        open(cut, "wb").write(open(cat, "rb").read()[:data_off + 1000 * rowlen + rowlen // 2])
        expect("table rows: truncated file", cells(cut, 1, 999, 2)[0::2],
               ("rows=1000 cols=5", [cells(cat, 1, 999, 1)[2][0], [""] * 5]))
    head, names, rws = cells(os.path.join(DATA, "tables_mixed.fits"), 1, 1, 1)
    expect("table rows: null, VLA and a long array", [rws[0][4], rws[0][10], rws[0][7]],
           ["null", "(1 values)", "[1 1 1 1 1 1 1 1 ...]"])


def expected_card(card):
    """How fqtool header --cards should split an astropy card: kind, key,
    value as shown (strings quoted), comment or commentary text."""
    img = card.image
    if img[8:10] != "= " and not (img.startswith("HIERARCH ") and "=" in img[9:]):
        return "c", card.keyword, "", str(card.value)
    key = ("HIERARCH " if img.startswith("HIERARCH ") else "") + card.keyword
    v = card.value
    if isinstance(v, bool):
        v = "T" if v else "F"
    elif isinstance(v, str):
        v = "'" + v + "'"
    elif v is None or isinstance(v, fits.card.Undefined):
        v = ""
    return "v", key, v, card.comment


def same_value(got, want):
    if got == want or isinstance(want, str):
        return got == want
    try:
        if isinstance(want, complex):
            re_, im = got.strip("()").split(",")
            return complex(float(re_.replace("D", "E")), float(im.replace("D", "E"))) == want
        return float(got.replace("D", "E")) == want
    except ValueError:
        return False


def check_headers(files):
    """Every header card of every file, as split for the Header view,
    against astropy; and the layout of one header."""
    bad = checked = 0
    for fn in files:
        path = os.path.join(DATA, fn)
        try:
            with fits.open(path) as hl:
                offsets = [(h._header_offset, h._data_offset) for h in hl]
            raw = (gzip.open if fn.endswith(".gz") else open)(path, "rb").read()
            headers = [fits.Header.fromstring(raw[a:b].decode("ascii")) for a, b in offsets]
        except Exception:
            continue
        for i, hdr in enumerate(headers):
            rc, out = fqtool("header", path, str(i), "--cards")
            got = [l.split("\t") for l in out.splitlines()]
            want = [expected_card(c) for c in hdr.cards] + [("e", "END", "", "")]
            checked += 1
            if len(got) != len(want) or any(
                    g[:2] != list(w[:2]) or not same_value(g[2], w[2]) or g[3] != w[3] for g, w in zip(got, want)):
                bad += 1
                diff = next(((g, w) for g, w in zip(got, want) if g != list(w)), (len(got), len(want)))
                failures.append(f"{fn} HDU {i} header cards: first difference {diff}")
    print(f"  {'ok' if not bad else '--'}  header cards of {checked - bad} of {checked} HDUs match astropy")

    # The layout: keys in a column, values and comments lined up, and
    # spans that cover exactly the keys, separators and comments.
    path = os.path.join(DATA, "header_cards.fits")
    if not os.path.exists(path):
        return
    text = fqtool("header", path)[1]
    lines = text.splitlines()
    cards = [l.split("\t") for l in fqtool("header", path, "--cards")[1].splitlines()]
    eq = {l.index(" = ") for l, c in zip(lines, cards) if c[0] == "v" and len(c[1]) <= 36}
    slash = {l.index(" / ", len(c[1]) + 3 + len(c[2])) for l, c in zip(lines, cards)
             if c[0] == "v" and c[3] and len(c[2]) <= 30}
    texts = {l.index(c[3]) for l, c in zip(lines, cards) if c[0] == "c" and c[3]}
    ok = len(lines) == len(cards) and len(eq) == 1 and len(slash) == 1 and texts == {eq.pop() + 3}
    spans = [tuple(map(int, l.split())) for l in fqtool("header", path, "--spans")[1].splitlines()]
    raw = text.encode()
    parts = {1: [], 2: set(), 3: []}
    for kind, start, n in spans:
        part = raw[start:start + n].decode()
        parts[kind].add(part) if kind == 2 else parts[kind].append(part)
    ok = ok and parts[1] == [c[1] for c in cards if c[1]] and parts[2] == {" = ", " / "} and \
        parts[3] == [c[3] for c in cards if c[3]]
    if not ok:
        failures.append(f"header layout of header_cards.fits:\n{text}\n{spans}")
    else:
        print(f"  ok  header layout: keys in {len(lines)} lines, \"=\" and \"/\" lined up, spans")


def is_image(i, h):
    if isinstance(h, fits.CompImageHDU):
        return h.header.get("ZCMPTYPE", "") != "HCOMPRESS_1" or True
    if i == 0 or isinstance(h, fits.ImageHDU):
        return h.header.get("NAXIS", 0) >= 1 and all(
            h.header.get(f"NAXIS{a}", 0) >= 1 for a in range(1, h.header["NAXIS"] + 1))
    return False


def reference(path):
    """(hdu index, physical data as float64 with NaN for blanks, header)."""
    hl = fits.open(path)
    first1d = None
    for i, h in enumerate(hl):
        if not is_image(i, h):
            continue
        shape = h.data.shape if h.data is not None else ()
        if len(shape) >= 2 and shape[-1] >= 2 and shape[-2] >= 2:
            return i, hl
        if first1d is None and len(shape) >= 1 and shape[-1] >= 2:
            first1d = i
    return first1d, hl


def physical(hl, i):
    h = hl[i]
    data = np.asarray(h.data, dtype=np.float64)
    if not isinstance(h, fits.CompImageHDU) and "BLANK" in h.header and h.header.get("BITPIX", 0) > 0:
        raw = fits.getdata(h.fileinfo()["file"].name, ext=i, do_not_scale_image_data=True)
        data = data.copy()
        data[raw == h.header["BLANK"]] = np.nan
    data[~np.isfinite(data)] = np.nan
    return data


def plane_of(data, header, nch):
    """The 2-D plane(s) the core shows, FITS row order."""
    if data.ndim == 1:
        return data[None, None, :]
    if data.ndim == 2:
        return data[None]
    if nch == 3:
        return data[:3]
    flat = data.reshape((-1,) + data.shape[-2:])
    return flat[data.shape[-3] // 2][None]


def bin_ref(img, f, k):
    """Reference binning of a 2-D array (NaN aware)."""
    H, W = img.shape
    w, h = max(1, W // f), max(1, H // f)
    offs = [((2 * i + 1) * f) // (2 * k) for i in range(k)]
    out = np.full((h, w), np.nan)
    if k == f:
        xs = [list(range(ox * f, min((ox + 1) * f, min(w * f, W)))) for ox in range(w)]
    else:
        xs = [[ox * f + o for o in offs if ox * f + o < W] for ox in range(w)]
    for oy in range(h):
        rows = [oy * f + o for o in (range(f) if k == f else offs) if oy * f + o < H]
        for ox in range(w):
            if not rows or not xs[ox]:
                continue
            blk = img[np.ix_(rows, xs[ox])]
            good = blk[np.isfinite(blk)]
            if good.size:
                out[oy, ox] = good.mean()
    return out


def bayer_ref(img, pattern, xoff, yoff, f, k):
    H, W = img.shape
    cw, ch = W // 2, H // 2
    w, h = max(1, cw // f), max(1, ch // f)
    offs = list(range(f)) if k == f else [((2 * i + 1) * f) // (2 * k) for i in range(k)]
    chan = {"R": 0, "G": 1, "B": 2}
    out = np.full((3, h, w), np.nan)
    for oy in range(h):
        for ox in range(w):
            acc, cnt = np.zeros(3), np.zeros(3)
            for j in offs:
                for i in (offs if k != f else range(f)):
                    for dy in (0, 1):
                        for dx in (0, 1):
                            y, x = 2 * (oy * f + j) + dy, 2 * (ox * f + i) + dx
                            if y >= H or x >= W:
                                continue
                            v = img[y, x]
                            if not np.isfinite(v):
                                continue
                            c = chan[pattern[((y + yoff) & 1) * 2 + ((x + xoff) & 1)]]
                            acc[c] += v
                            cnt[c] += 1
            for c in range(3):
                if cnt[c]:
                    out[c, oy, ox] = acc[c] / cnt[c]
    return out


def compare(name, got, exp, rtol):
    exp = np.asarray(exp, dtype=np.float64)
    got = np.asarray(got, dtype=np.float64)
    if got.shape != exp.shape:
        failures.append(f"{name}: shape {got.shape} != {exp.shape}")
        return
    gn, en = np.isnan(got), np.isnan(exp)
    if not np.array_equal(gn, en):
        failures.append(f"{name}: NaN mask differs ({gn.sum()} vs {en.sum()})")
        return
    m = ~en
    if m.any():
        scale = np.nanmax(np.abs(exp[m])) + 1e-30
        err = np.max(np.abs(got[m] - exp[m])) / scale
        if err > rtol:
            idx = np.argmax(np.abs(got[m] - exp[m]))
            failures.append(f"{name}: max rel err {err:.3g} (got {got[m][idx]}, want {exp[m][idx]})")
            return
    print(f"  ok  {name}")


def check_stretch():
    """The automatic stretch puts the sky background near 25% grey."""
    with tempfile.TemporaryDirectory() as tmp:
        for fn in ("f32.fits", "i16.fits", "u16.fits", "mef.fits", "rice_f32_sd1.fits",
                   "footprint_f32.fits", "f64_offset.fits", "u32.fits"):
            if not os.path.exists(os.path.join(DATA, fn)):
                continue
            r = subprocess.run([FQ, "render", os.path.join(DATA, fn), os.path.join(tmp, "o.png"),
                                "--max", "256"], capture_output=True, text=True, errors="replace")
            line = [l for l in r.stdout.splitlines() if l.startswith("output ")]
            if r.returncode or not line:
                failures.append(f"{fn}: render failed: {r.stderr.strip()}")
                continue
            med = int(line[0].split("median=")[1].split()[0])
            if abs(med - 64) > 16:
                failures.append(f"{fn}: background grey {med}, expected about 64")
            else:
                print(f"  ok  {fn} stretch: background grey {med}")


def check_image(fn, path, hl, idx, extra):
    h = hl[idx]
    cmp_type = getattr(h, "compression_type", "") if isinstance(h, fits.CompImageHDU) else ""
    if cmp_type == "HCOMPRESS_1":
        res, err = run_dump(path, *extra)
        if res is None and "not supported" in err:
            print(f"  ok  {fn}: HCOMPRESS reported as unsupported")
        else:
            failures.append(f"{fn}: expected an unsupported-compression error")
        return
    data = physical(hl, idx)
    res, err = run_dump(path, "--max", "100000", "--samples", "0", *extra)
    if res is None:
        failures.append(f"{fn}: dump failed: {err}")
        return
    got, info = res
    if int(info["hdu"]) != idx:
        failures.append(f"{fn}: core chose HDU {info['hdu']}, expected {idx}")
        return
    nch = got.shape[0]
    hdr = h.header
    bayer = hdr.get("BAYERPAT") if nch == 3 and data.ndim == 2 else None
    if bayer:
        img = data
        xoff, yoff = hdr.get("XBAYROFF", 0), hdr.get("YBAYROFF", 0)
        exp = bayer_ref(img, bayer, xoff, yoff, 1, 1)
        compare(f"{fn} bayer full", got, exp, 1e-5)
        res, _ = run_dump(path, "--max", "40", "--samples", "0", *extra)
        compare(f"{fn} bayer binned", res[0], bayer_ref(img, bayer, xoff, yoff, 4, 4), 1e-5)
        res, _ = run_dump(path, "--max", "20", "--samples", "3", *extra)
        compare(f"{fn} bayer sampled", res[0], bayer_ref(img, bayer, xoff, yoff, 8, 3), 1e-5)
        return
    planes = plane_of(data, hdr, nch)
    compare(f"{fn} full", got, planes, 2e-6)
    H, W = planes.shape[-2:]
    for maxdim, k in ((64, 0), (50, 2), (33, 3), (7, 1)):
        f = max(math.ceil(W / maxdim), math.ceil(H / maxdim), 1)
        kk = f if k == 0 else min(f, k)
        res, err = run_dump(path, "--max", str(maxdim), "--samples", str(k), *extra)
        if res is None:
            failures.append(f"{fn}: binned dump failed: {err}")
            continue
        exp = np.stack([bin_ref(p, f, kk) for p in planes])
        compare(f"{fn} bin f={f} k={kk}", res[0], exp, 2e-5)


def check_restretch():
    """Changing the stretch of a kept rendering gives the same pixels as
    rendering with that stretch."""
    with tempfile.TemporaryDirectory() as tmp:
        for fn in ("f32.fits", "rgb.fits", "bayer_rggb.fits", "nan_f32.fits", "rice_f32_sd1.fits",
                   "cube5.fits", "all_nan.fits"):
            path = os.path.join(DATA, fn)
            if not os.path.exists(path):
                continue
            for a, b in (("auto", "linear"), ("linear", "minmax"), ("minmax", "auto")):
                direct, re_ = os.path.join(tmp, "a.png"), os.path.join(tmp, "b.png")
                r1 = subprocess.run([FQ, "render", path, direct, "--max", "300", "--stretch", b],
                                    capture_output=True, text=True)
                r2 = subprocess.run([FQ, "render", path, re_, "--max", "300", "--stretch", a, "--then", b],
                                    capture_output=True, text=True)
                if r1.returncode or r2.returncode or open(direct, "rb").read() != open(re_, "rb").read():
                    failures.append(f"{fn}: restretch {a} -> {b} differs from rendering with {b}")
                    break
            else:
                print(f"  ok  {fn} restretch")


def read_png(path):
    """Pixels of a PNG written by fqtool (8 bit grey or RGBA, no filters),
    as RGBA."""
    data = open(path, "rb").read()
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n = int.from_bytes(data[pos:pos + 4], "big")
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, ctype = int.from_bytes(body[:4], "big"), int.from_bytes(body[4:8], "big"), body[9]
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    comps = 1 if ctype == 0 else 4
    rows = np.frombuffer(zlib.decompress(idat), np.uint8).reshape(h, 1 + w * comps)[:, 1:]
    px = rows.reshape(h, w, comps)
    if comps == 1:
        px = np.concatenate([px, px, px, np.full((h, w, 1), 255, np.uint8)], axis=2)
    return px


def check_regions():
    """A part of an image rendered for the zoom (--region, with the whole
    image's stretch) has the pixels of the whole image rendered at the
    same scale, at the same place."""
    def render(path, out, *opts):
        r = subprocess.run([FQ, "render", path, out, *opts], capture_output=True, text=True)
        info = dict(kv.split("=", 1) for kv in r.stdout.split() if "=" in kv)
        return (read_png(out), info) if r.returncode == 0 else (None, r.stderr.strip())

    with tempfile.TemporaryDirectory() as tmp:
        for fn in ("f32.fits", "nan_f32.fits", "f64_offset.fits", "u16.fits", "rgb.fits", "cube5.fits",
                   "bayer_rggb.fits", "bayer_offset.fits", "rice_f32_sd1.fits", "rice_i16_tiles.fits",
                   "gzip2_i16.fits", "f32.fits.gz"):
            path = os.path.join(DATA, fn)
            if not os.path.exists(path):
                continue
            whole, info = render(path, os.path.join(tmp, "w.png"), "--max", "100000")
            if whole is None:
                failures.append(f"{fn}: render failed: {info}")
                continue
            b = int(info["bin"])
            hc = whole.shape[0]
            W, H = (int(v) for v in info["dims"].split("x")[:2])
            ok = True
            for region in ((10, 7, 37, 23), (0, 0, 16, 16), (W - 30, H - 20, 30, 20),
                           (-20, H - 9, 60, 40), (W // 3, H // 4, W // 2, H // 2)):
                part, pinfo = render(path, os.path.join(tmp, "p.png"), "--max", "100000",
                                     "--region", ",".join(str(v) for v in region))
                if part is None:
                    failures.append(f"{fn}: region {region}: {pinfo}")
                    ok = False
                    break
                rx, ry, rw, rh = (int(v) for v in pinfo["region"].split(","))
                if int(pinfo["bin"]) != b or part.shape[:2] != (rh // b, rw // b):
                    failures.append(f"{fn}: region {region} came out {pinfo['out']} at bin {pinfo['bin']}"
                                    f" for {pinfo['region']}")
                    ok = False
                    break
                x0, y0 = rx // b, ry // b
                rows = slice(hc - y0 - rh // b, hc - y0) if info["flipped"] == "1" else slice(y0, y0 + rh // b)
                want = whole[rows, x0:x0 + rw // b]
                if want.shape != part.shape or not np.array_equal(want, part):
                    bad = np.count_nonzero(np.any(want != part, axis=2)) if want.shape == part.shape else -1
                    failures.append(f"{fn}: region {region} ({pinfo['region']}) differs from the whole"
                                    f" image there ({bad} pixels)")
                    ok = False
                    break
            # Bigger than the window: binned, still inside the whole image.
            part, pinfo = render(path, os.path.join(tmp, "p.png"), "--max", "20",
                                 "--region", f"0,0,{W},{H}")
            if part is None or max(part.shape[:2]) > 20 or int(pinfo["bin"]) < 2:
                failures.append(f"{fn}: binned region: {pinfo}")
                ok = False
            if ok:
                print(f"  ok  {fn} regions")


def main():
    check_stretch()
    check_restretch()
    check_regions()
    check_listings()
    files = sorted(f for f in os.listdir(DATA) if f.endswith((".fits", ".fits.gz")))
    check_headers(files)
    for fn in files:
        path = os.path.join(DATA, fn)
        try:
            idx, hl = reference(path)
        except Exception as e:  # not FITS, truncated: astropy refuses too
            res, err = run_dump(path)
            print(f"  --  {fn}: astropy cannot read ({type(e).__name__}); core says: {err or 'ok'}")
            continue
        # The core shows the first 2-D image or plottable table, in file
        # order; a 1-D image only when there is neither.
        table = next(((i, sp) for i, h in enumerate(hl) if (sp := plot_spec(h))), None)
        first2d = idx if idx is not None and hl[idx].data is not None and hl[idx].data.ndim >= 2 else None
        if table and (first2d is None or table[0] < first2d):
            check_plot(fn, path, hl[table[0]], *table)
            if idx is not None:
                check_image(fn, path, hl, idx, ["--hdu", str(idx)])
            continue
        if idx is None:
            res, err = run_dump(path)
            if res is not None:
                failures.append(f"{fn}: core found an image, astropy did not")
            else:
                print(f"  ok  {fn}: no image ({err})")
            continue
        check_image(fn, path, hl, idx, [])

    print()
    if failures:
        print(f"{len(failures)} FAILURES")
        for f in failures:
            print("  FAIL", f)
        sys.exit(1)
    print("all good")


if __name__ == "__main__":
    main()
