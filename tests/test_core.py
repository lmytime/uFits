#!/usr/bin/env python3
"""Check the uFits core against astropy.

Usage: test_core.py FQTOOL TESTDATA_DIR

For every image file the decoded values (full resolution), the binned
values (with and without sub-sampling) and Bayer/RGB handling are compared
with a reference computed from astropy's reading of the same file.
"""
import math
import os
import subprocess
import sys
import tempfile

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


def main():
    files = sorted(f for f in os.listdir(DATA) if f.endswith((".fits", ".fits.gz")))
    for fn in files:
        path = os.path.join(DATA, fn)
        try:
            idx, hl = reference(path)
        except Exception as e:  # not FITS, truncated: astropy refuses too
            res, err = run_dump(path)
            print(f"  --  {fn}: astropy cannot read ({type(e).__name__}); core says: {err or 'ok'}")
            continue
        if idx is None:
            res, err = run_dump(path)
            if res is not None:
                failures.append(f"{fn}: core found an image, astropy did not")
            else:
                print(f"  ok  {fn}: no image ({err})")
            continue
        h = hl[idx]
        cmp_type = getattr(h, "compression_type", "") if isinstance(h, fits.CompImageHDU) else ""
        if cmp_type == "HCOMPRESS_1":
            res, err = run_dump(path)
            if res is None and "not supported" in err:
                print(f"  ok  {fn}: HCOMPRESS reported as unsupported")
            else:
                failures.append(f"{fn}: expected an unsupported-compression error")
            continue
        data = physical(hl, idx)
        res, err = run_dump(path, "--max", "100000", "--samples", "0")
        if res is None:
            failures.append(f"{fn}: dump failed: {err}")
            continue
        got, info = res
        if int(info["hdu"]) != idx:
            failures.append(f"{fn}: core chose HDU {info['hdu']}, expected {idx}")
            continue
        nch = got.shape[0]
        hdr = h.header
        bayer = hdr.get("BAYERPAT") if nch == 3 and data.ndim == 2 else None
        if bayer:
            img = data
            xoff, yoff = hdr.get("XBAYROFF", 0), hdr.get("YBAYROFF", 0)
            exp = bayer_ref(img, bayer, xoff, yoff, 1, 1)
            compare(f"{fn} bayer full", got, exp, 1e-5)
            res, _ = run_dump(path, "--max", "40", "--samples", "0")
            compare(f"{fn} bayer binned", res[0], bayer_ref(img, bayer, xoff, yoff, 4, 4), 1e-5)
            res, _ = run_dump(path, "--max", "20", "--samples", "3")
            compare(f"{fn} bayer sampled", res[0], bayer_ref(img, bayer, xoff, yoff, 8, 3), 1e-5)
            continue
        planes = plane_of(data, hdr, nch)
        compare(f"{fn} full", got, planes, 2e-6)
        H, W = planes.shape[-2:]
        for maxdim, k in ((64, 0), (50, 2), (33, 3), (7, 1)):
            f = max(math.ceil(W / maxdim), math.ceil(H / maxdim), 1)
            kk = f if k == 0 else min(f, k)
            res, err = run_dump(path, "--max", str(maxdim), "--samples", str(k))
            if res is None:
                failures.append(f"{fn}: binned dump failed: {err}")
                continue
            exp = np.stack([bin_ref(p, f, kk) for p in planes])
            compare(f"{fn} bin f={f} k={kk}", res[0], exp, 2e-5)

    print()
    if failures:
        print(f"{len(failures)} FAILURES")
        for f in failures:
            print("  FAIL", f)
        sys.exit(1)
    print("all good")


if __name__ == "__main__":
    main()
