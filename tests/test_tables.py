#!/usr/bin/env python3
"""Plots of big tables, against numpy.

From 4M points on a plot is drawn on every core (the same bytes as on one).
Of a table bigger than 1 GiB only 16384 windows of 16 KiB are read, one at a
fixed random place in each of as many equal parts of the table, and of a
catalog sorted by position only the middle row of each window is drawn.

Usage: test_tables.py FQTOOL DIR   (DIR: room for a table of about 1.1 GB)
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

WINDOWS, WINDOW = 16384, 16 << 10   # as core/fq_table.c


def card(key, value=None):
    text = key if value is None else f"{key:<8}= {value:>20}"
    return text.ljust(80).encode()


def write_table(path, columns, nrows, fill, extra=(), chunk=1 << 22):
    """An empty primary HDU, then a binary table of columns (name, TFORM,
    numpy type) with nrows rows made by fill(start, n), chunk rows at a time.
    Returns where the rows start."""
    dtype = np.dtype([(name, kind) for name, _, kind in columns])
    head = [card("XTENSION", "'BINTABLE'"), card("BITPIX", 8), card("NAXIS", 2),
            card("NAXIS1", dtype.itemsize), card("NAXIS2", nrows), card("PCOUNT", 0),
            card("GCOUNT", 1), card("TFIELDS", len(columns))]
    for i, (name, form, _) in enumerate(columns, 1):
        head += [card(f"TTYPE{i}", f"'{name:<8}'"), card(f"TFORM{i}", f"'{form:<8}'")]
    head += [card(*kv) for kv in extra] + [card("END")]
    blocks = []
    for cards in ([card("SIMPLE", "T"), card("BITPIX", 8), card("NAXIS", 0), card("END")], head):
        b = b"".join(cards)
        blocks.append(b + b" " * (-len(b) % 2880))
    with open(path, "wb") as f:
        for b in blocks:
            f.write(b)
        for start in range(0, nrows, chunk):
            n = min(chunk, nrows - start)
            rows = np.zeros(n, dtype)
            fill(rows, start, n)
            rows.tofile(f)
        f.write(bytes(-nrows * dtype.itemsize % 2880))
    return sum(len(b) for b in blocks)


def window_rows(data_off, rowlen, rows, k):
    """Rows [r0, r1) of window k, as core/fq_table.c places it."""
    mask = (1 << 64) - 1
    part = rows * rowlen // WINDOWS
    z = k * 0x9E3779B97F4A7C15 & mask
    z = (z ^ z >> 30) * 0xBF58476D1CE4E5B9 & mask
    z = (z ^ z >> 27) * 0x94D049BB133111EB & mask
    z ^= z >> 31
    at = data_off + part * k + z % (part - WINDOW + 1)
    at = max(at - at % WINDOW, data_off)
    a = (at - data_off + rowlen - 1) // rowlen
    b = max((at + WINDOW - data_off) // rowlen, a + 1)
    return min(a, rows), min(b, rows)


class TableTests(unittest.TestCase):
    def plot(self, path, *opts):
        with tempfile.NamedTemporaryFile(suffix=".bin", dir=self.dir) as t:
            r = subprocess.run([self.fq, "plot", path, t.name, "--max", "300", *opts],
                               capture_output=True, text=True, timeout=600)
            self.assertEqual(r.returncode, 0, r.stderr)
            lines = r.stdout.splitlines()
            info = dict(kv.split("=", 1) for kv in lines[0].split() if "=" in kv)
            info.update(line.split("=", 1) for line in lines[1:] if "=" in line)
            raw = Path(t.name).read_bytes()
        return raw, info

    def check(self, raw, info, x, y, sky, drawn=None):
        """The plot of the points (x, y) read, as numpy draws it; of those
        only the drawn ones (all of them by default) go in its columns."""
        def valid(x, y):
            ok = np.isfinite(x) & np.isfinite(y)
            if sky:
                with np.errstate(invalid="ignore"):
                    ok &= (x >= -360) & (x <= 360) & (y >= -90) & (y <= 90)
            return x[ok], y[ok]

        x, y = valid(x, y)
        wrap = False
        if sky:
            w = np.where(x > 180, x - 360, x)
            wrap = w.max() - w.min() < x.max() - x.min() - 1
        xmin, xmax = (w.min(), w.max()) if wrap else (x.min(), x.max())
        ncol = min(300, len(x))
        p1, p99 = np.percentile(y, [1, 99])
        if drawn is not None:
            x, y = valid(*drawn)
        if wrap:
            x = np.where(x > 180, x - 360, x)
        self.assertEqual(int(info["points"]), len(x))
        self.assertEqual(int(info["n"]), ncol)
        self.assertEqual(info["x_wrap"], str(int(wrap)))
        span = xmax - xmin
        self.assertAlmostEqual(float(info["x_first"]), xmin + 0.5 * span / ncol, delta=1e-9 * abs(span))
        self.assertAlmostEqual(float(info["x_last"]), xmax - 0.5 * span / ncol, delta=1e-9 * abs(span))
        c = ((x - xmin) * (ncol / span)).astype(np.int64).clip(0, ncol - 1)
        y32 = y.astype(np.float32)
        lo = np.full(ncol, np.inf, np.float32)
        hi = np.full(ncol, -np.inf, np.float32)
        np.minimum.at(lo, c, y32)
        np.maximum.at(hi, c, y32)
        lo[np.isinf(lo)] = hi[np.isinf(hi)] = np.nan
        v = np.frombuffer(raw[:8 * ncol], np.float32)
        np.testing.assert_array_equal(v[:ncol], lo)
        np.testing.assert_array_equal(v[ncol:], hi)
        ymin, ymax = float(info["y_min"]), float(info["y_max"])
        self.assertTrue(ymin <= p1 <= p99 <= ymax, (ymin, ymax, p1, p99))
        rows = int(info["dot_rows"])
        r = (y - ymin) * (rows / (ymax - ymin))
        on = (r >= 0) & (r < rows)
        grid = np.zeros((ncol, rows), np.int64)
        np.add.at(grid, (c[on], r[on].astype(np.int64)), 1)
        dots = np.frombuffer(raw[8 * ncol:], np.uint8).reshape(ncol, rows)
        np.testing.assert_array_equal(dots, grid.clip(0, 255))

    def test_on_every_core(self):
        # A catalog of 4.5M rows across RA = 0, and a light curve of scaled
        # integers with nulls: every point read, the same on one core.
        rng = np.random.default_rng(5)
        n = 4_500_000
        cat = self.dir / "catalog.fits"

        def sky(rows, start, k):
            rows["RA"] = (350 + 20 * rng.random(k)) % 360
            rows["DEC"] = rng.uniform(-10, 10, k)
            rows["RA"][rng.random(k) < 0.01] = np.nan
            rows["DEC"][rng.random(k) < 0.005] = -999

        write_table(cat, [("RA", "D", ">f8"), ("DEC", "E", ">f4")], n, sky)
        lc = self.dir / "lightcurve.fits"

        def flux(rows, start, k):
            rows["TIME"] = 2000 + (start + np.arange(k)) / 1440
            rows["FLUX"] = rng.integers(-50000, 50000, k)
            rows["FLUX"][rng.random(k) < 0.02] = -99

        write_table(lc, [("TIME", "D", ">f8"), ("FLUX", "J", ">i4")], n, flux,
                    extra=[("TNULL2", -99), ("TSCAL2", 0.5), ("TZERO2", 1000.0)])
        for path, sky_ in ((cat, True), (lc, False)):
            with self.subTest(path=path.name):
                raw, info = self.plot(path)
                self.assertEqual(self.plot(path, "--threads", "1")[0], raw)
                d = np.memmap(path, np.dtype([("x", ">f8"), ("y", ">f4" if sky_ else ">i4")]), "r",
                              offset=5760, shape=(n,))
                x, y = np.asarray(d["x"], np.float64), np.asarray(d["y"], np.float64)
                if not sky_:
                    y = np.where(d["y"] == -99, np.nan, y * 0.5 + 1000)
                self.check(raw, info, x, y, sky_)
                del d
            path.unlink()

    def test_windows(self):
        # Over 1 GiB: the rows of the windows, all of them when the rows are
        # in no order, the middle one of each when they are sorted by
        # position (each window then one small patch of sky).
        n = (1 << 30) // 16 + 50_000
        path = self.dir / "big_catalog.fits"
        for order in ("random", "sorted"):
            rng = np.random.default_rng(7)

            def fill(rows, start, k):
                if order == "sorted":   # declination zones, RA along each
                    t = (start + np.arange(k) + rng.random(k)) / n * 180
                    rows["DEC"] = -90 + np.floor(t) + rng.random(k)
                    rows["RA"] = (t - np.floor(t)) * 360
                else:
                    rows["RA"] = rng.uniform(0, 360, k)
                    rows["DEC"] = np.degrees(np.arcsin(rng.uniform(-1, 1, k)))

            with self.subTest(order=order):
                off = write_table(path, [("RA", "D", ">f8"), ("DEC", "D", ">f8")], n, fill)
                raw, info = self.plot(path)
                spans = [window_rows(off, 16, n, k) for k in range(WINDOWS)]
                rows = np.concatenate([np.arange(a, b) for a, b in spans])
                middle = np.array([a + (b - a) // 2 for a, b in spans])
                d = np.memmap(path, np.dtype([("x", ">f8"), ("y", ">f8")]), "r", offset=off, shape=(n,))
                xy = (np.asarray(d["x"][rows], np.float64), np.asarray(d["y"][rows], np.float64))
                drawn = None
                if order == "sorted":
                    drawn = (np.asarray(d["x"][middle], np.float64), np.asarray(d["y"][middle], np.float64))
                self.check(raw, info, *xy, True, drawn)
                self.assertEqual(int(info["points"]), WINDOWS if order == "sorted" else len(rows))
                del d
            path.unlink()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    TableTests.fq = str(Path(sys.argv[1]).resolve())
    TableTests.dir = Path(sys.argv[2])
    TableTests.dir.mkdir(parents=True, exist_ok=True)
    unittest.main(argv=[sys.argv[0]], verbosity=2)
