#!/usr/bin/env python3
"""Check ASDF decoding against files written by Python's asdf (and, when it
is installed, roman_datamodels, as Roman's pipeline writes them).

Usage: test_asdf.py FQTOOL TESTDATA_DIR
Requires numpy, asdf and lz4; roman_datamodels for the Roman files. Fixtures
remain in TESTDATA_DIR (asdf_*.asdf) for the macOS preview and thumbnail
checks.
"""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings

import asdf
import numpy as np

try:
    import roman_datamodels.datamodels as rdm
except ImportError:   # pragma: no cover - optional
    rdm = None

DTYPES = ["int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64",
          "float16", "float32", "float64", "bool"]


def write(path, tree, **kwargs):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        asdf.AsdfFile(tree).write_to(path, **kwargs)
    return path


def edge_values(dtype, shape):
    dtype = np.dtype(dtype)
    if dtype.kind == "b":
        values = np.array([False, True, True, False, True])
    elif dtype.kind in "iu":
        info = np.iinfo(dtype)
        values = np.array([info.min, info.min + 1, -1 if dtype.kind == "i" else 3, 0, 1,
                           info.max // 2, info.max - 1, info.max], dtype=dtype)
    else:
        values = np.array([-1.5, -0.01, 0, 0.01, 0.25, 0.75, 1.5, 1000], dtype=dtype)
    return np.resize(values, shape).astype(dtype)


class AsdfTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data.mkdir(parents=True, exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory()
        cls.scratch = Path(cls.temp.name)
        y, x = np.indices((64, 80))
        cls.image = (x + 3 * y + (x * y % 17)).astype(np.float32)
        cls.cube = np.stack([cls.image * (k + 1) + 10 * k for k in range(5)])
        # Fixtures kept for the macOS checks.
        write(cls.data / "asdf_image.asdf", {"data": cls.image})
        write(cls.data / "asdf_lz4_cube.asdf", {"cube": cls.cube}, all_array_compression="lz4")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def command(self, *args):
        return subprocess.run([self.fq, *map(str, args)], capture_output=True, text=True,
                              errors="replace", timeout=60)

    def success(self, *args):
        result = self.command(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def dump(self, path, *opts):
        output = self.scratch / "pixels.f32"
        stdout = self.success("dump", path, output, "--max", "100000", *opts)
        width, height, channels = map(int, stdout.splitlines()[0].split())
        info = dict(word.split("=", 1) for word in stdout.splitlines()[1].split() if "=" in word)
        return np.fromfile(output, np.float32).reshape(channels, height, width)[0], info

    def hdus(self, path):
        """name -> (index, kind, planes, description)"""
        out = {}
        for line in self.success("hdus", path).splitlines():
            head, desc = line.split(" | ")
            index, kind, planes, name = head.split()
            out[name] = (int(index), kind, int(planes), desc)
        return out

    def check(self, path, expected, *opts):
        actual, info = self.dump(path, *opts)
        expected = np.asarray(expected)
        if expected.ndim == 1:
            expected = expected[None]
        np.testing.assert_allclose(actual, expected.astype(np.float32), rtol=1e-6, atol=0, equal_nan=True)
        self.assertEqual(info["flipped"], "1", "the first row is drawn at the bottom, as in FITS")
        return info

    def test_types_and_byte_orders(self):
        for dtype in DTYPES:
            for order in "<>":
                with self.subTest(dtype=dtype, order=order):
                    values = edge_values(dtype, (6, 9)).astype(np.dtype(dtype).newbyteorder(order))
                    path = write(self.scratch / f"type_{dtype}_{order == '>'}.asdf", {"a": values})
                    self.check(path, values, "--hdu", "0")
        nan = self.image.copy()
        nan[3:9, 5:20] = np.nan
        self.check(write(self.scratch / "nan.asdf", {"data": nan}), nan)

    def test_compression(self):
        big = np.random.default_rng(3).normal(size=(900, 1300)).astype(np.float32)   # several LZ4 frames
        for codec in ("lz4", "zlib", "bzp2"):
            with self.subTest(codec=codec):
                path = write(self.data / f"asdf_{codec}.asdf", {"data": big}, all_array_compression=codec)
                info = self.check(path, big)
                self.assertEqual(info["compressed"], "1:" + codec)

    def test_cube_planes(self):
        for codec in (None, "lz4", "zlib"):
            path = write(self.scratch / f"cube_{codec}.asdf", {"cube": self.cube}, all_array_compression=codec)
            hdus = self.hdus(path)
            self.assertEqual(hdus["cube"][2], 5)
            self.assertIn("80 x 64 x 5 float32", hdus["cube"][3])
            for plane in range(5):
                with self.subTest(codec=codec, plane=plane):
                    self.check(path, self.cube[plane], "--plane", plane)
            self.assertEqual(self.check(path, self.cube[2])["plane"], "2/5", "the middle plane first")
        # A plane that straddles LZ4 frames of 4 MiB.
        tall = np.arange(3 * 700 * 900, dtype=np.float32).reshape(3, 700, 900)
        path = write(self.scratch / "tall.asdf", {"cube": tall}, all_array_compression="lz4")
        for plane in range(3):
            self.check(path, tall[plane], "--plane", plane)
        hyper = np.arange(2 * 3 * 4 * 5, dtype=np.int16).reshape(2, 3, 4, 5)
        path = write(self.scratch / "hyper.asdf", {"h": hyper})
        for plane in range(6):
            self.check(path, hyper.reshape(6, 4, 5)[plane], "--plane", plane)

    def test_views(self):
        base = np.arange(40 * 30, dtype=">i4").reshape(40, 30)
        tree = {"base": base, "rows": base[::2], "flipped": base[::-1], "transposed": base.T,
                "window": base[5:25, 3:20], "column": base[:, 7]}
        for codec in (None, "lz4"):
            path = write(self.scratch / f"views_{codec}.asdf", tree, all_array_compression=codec)
            hdus = self.hdus(path)
            for name, view in tree.items():
                with self.subTest(codec=codec, view=name):
                    self.check(path, view, "--hdu", hdus[name][0])

    def test_what_is_listed(self):
        from_tree = {
            "image": self.image,
            "small": np.arange(6.0).reshape(2, 3),       # inline: not listed
            "masked": np.ma.masked_array(self.image, mask=self.image > 100),
            "strings": np.array(["a", "bc"]),
            "complex": np.ones((4, 4), np.complex64),
            "scalar": np.float64(3.5),
            "spectrum": np.linspace(1, 2, 300),
            "nested": {"deeper": [{"array": self.image[:10]}]},
        }
        path = self.data / "asdf_mixed.asdf"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            af = asdf.AsdfFile(from_tree)
            af.set_array_storage(from_tree["small"], "inline")
            af.write_to(path)
        hdus = self.hdus(path)
        self.assertEqual(sorted(hdus), ["image", "masked", "nested.deeper[0].array", "spectrum"])
        self.assertEqual(hdus["spectrum"][1], "plot")
        self.check(path, self.image, "--hdu", hdus["masked"][0])   # shown without its mask
        header = self.success("header", path)
        for text in ("small", "(2, 3) float64", "inline", "masked", "complex64", "strings", "deeper",
                     "[0]", "scalar"):
            self.assertIn(text, header)
        self.assertIn("hdu=" + str(hdus["image"][0]), self.success("info", path))

    def test_streamed_block(self):
        path = self.scratch / "streamed.asdf"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            af = asdf.AsdfFile({"rows": asdf.Stream([7], np.float64)})
            with open(path, "wb") as fd:
                af.write_to(fd)
                for i in range(12):
                    fd.write((np.arange(7, dtype=np.float64) * i).tobytes())
        with asdf.open(path) as af:
            expected = np.array(af["rows"])
        self.assertEqual(expected.shape, (12, 7))
        self.check(path, expected)

    def test_quantity(self):
        try:
            import astropy.units as u
            import asdf_astropy  # noqa: F401
        except ImportError:
            self.skipTest("asdf-astropy is not installed")
        path = write(self.scratch / "quantity.asdf", {"flux": self.image * u.Jy})
        self.assertIn("flux", self.hdus(path))
        self.check(path, self.image)

    def test_header(self):
        tree = {"meta": {"name": "M31", "exposure": 120.5, "filters": ["F062", "F158"], "note": "Å ok\tx",
                         "long": list(range(300))}, "data": self.image}
        path = write(self.scratch / "header.asdf", tree)
        cards = [tuple(card.split("\t")) for card in self.success("header", path, "--cards").splitlines()]
        for card in cards:
            self.assertEqual(len(card), 4, card)
        self.assertEqual(cards[0], ("v", "data", "(64, 80) float32", "ndarray-1.1.0, block 0"))
        self.assertIn(("c", "meta", "", ""), cards)
        for card in (("v", "  name", "M31", ""), ("v", "  exposure", "120.5", ""),
                     ("v", "  filters", "[F062, F158]", ""),
                     ("v", "  note", "? ok x", ""),       # ASCII only, on one line
                     ("c", "  long", "", ""), ("v", "    [299]", "299", "")):   # a long list: a line each
            self.assertIn(card, cards)
        # What wrote the file comes last.
        keys = [card[1] for card in cards]
        self.assertLess(keys.index("  long"), keys.index("#ASDF 1.0.0"))
        self.assertLess(keys.index("#ASDF 1.0.0"), keys.index("asdf_library"))
        text = self.success("header", path)
        self.assertRegex(text, r"\n  exposure +=  ?120\.5\n")

    @unittest.skipIf(rdm is None, "roman_datamodels is not installed")
    def test_roman(self):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            l2 = rdm.ImageModel.create_fake_data(shape=(64, 80))
            l2.data = self.image
            l2.err = (self.image / 10).astype(l2.err.dtype)
            cal = l2.save(self.data / "asdf_roman_cal.asdf")
            l1 = rdm.ScienceRawModel.create_fake_data(shape=(4, 64, 80))
            l1.data = np.stack([self.image * k + 1000 for k in range(4)]).astype(np.uint16)
            uncal = l1.save(self.data / "asdf_roman_uncal.asdf")
        hdus = self.hdus(cal)
        self.assertIn("roman.data", hdus)
        self.assertIn("roman.err", hdus)
        info = self.check(cal, self.image)
        self.assertEqual(info["extname"], "roman.data", "Roman's data first")
        self.assertEqual(info["compressed"], "1:lz4")
        self.check(cal, l2.err, "--hdu", hdus["roman.err"][0])   # float16
        header = self.success("header", cal)
        self.assertTrue(header.startswith("roman "), header[:200])
        self.assertIn("    instrument", header)
        self.assertIn("      detector", header)
        for plane in range(4):
            self.check(uncal, l1.data[plane], "--plane", plane)

    def test_damaged_files(self):
        good = write(self.scratch / "good.asdf", {"data": self.cube}, all_array_compression="lz4").read_bytes()
        plain = write(self.scratch / "plain.asdf", {"data": self.image}).read_bytes()
        tree_end = good.index(b"\n...\n") + 5
        cases = {
            "truncated_block": good[:len(good) // 2],
            "truncated_tree": good[:tree_end // 2],
            "no_blocks": good[:tree_end],
            "garbled_lz4": good[:tree_end + 60] + bytes(200) + good[tree_end + 260:],
            "bad_yaml": good.replace(b"datatype: float32", b"datatype: [float32"),
            "deep": b"#ASDF 1.0.0\n%YAML 1.1\n---\na: " + b"[" * 5000 + b"]" * 5000 + b"\n...\n",
            "huge_shape": plain.replace(b"shape: [64, 80]", b"shape: [99999999999, 80]"),
            "huge_offset": plain.replace(b"byteorder: little", b"byteorder: little\n  offset: 9999999999"),
            "bad_strides": plain.replace(b"shape: [64, 80]", b"shape: [64, 80]\n  strides: [0, 4]"),
            "external": plain.replace(b"source: 0", b"source: other.asdf"),
            "zstd": good[:tree_end + 10] + b"zstd" + good[tree_end + 14:],
            "header_size": good[:tree_end + 4] + struct.pack(">H", 1) + good[tree_end + 6:],
            "only_magic": b"#ASDF 1.0.0\n",
            "no_tree": b"#ASDF 1.0.0\n" + good[tree_end:],
        }
        for name, data in cases.items():
            with self.subTest(case=name):
                path = self.scratch / f"bad_{name}.asdf"
                path.write_bytes(data)
                for args in (("info", path), ("header", path), ("dump", path, self.scratch / "x.f32")):
                    result = self.command(*args)
                    self.assertIn(result.returncode, (0, 1), (args[0], result.stderr))
        self.assertIn("nested deeper", self.success("header", self.scratch / "bad_deep.asdf"))
        self.assertIn("compression 'zstd'", self.command("dump", self.scratch / "bad_zstd.asdf",
                                                         self.scratch / "x.f32").stderr)
        self.assertIn("another file", self.command("dump", self.scratch / "bad_external.asdf",
                                                   self.scratch / "x.f32").stderr)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    AsdfTests.fq = str(Path(sys.argv[1]).resolve())
    AsdfTests.data = Path(sys.argv[2])
    unittest.main(argv=[sys.argv[0]], verbosity=2)
