#!/usr/bin/env python3
"""Exercise XISF decoding with independently generated, deterministic files.

Usage: test_xisf.py FQTOOL TESTDATA_DIR
Requires numpy, lz4 and zstandard. Fixtures remain in TESTDATA_DIR so the
same files can also exercise the macOS preview and thumbnail extensions.
"""
import base64
from itertools import product
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zlib

import lz4.block
import numpy as np
import zstandard


FORMATS = {"UInt8": "u1", "UInt16": "u2", "UInt32": "u4", "UInt64": "u8",
           "Float32": "f4", "Float64": "f8"}


def compress(raw, codec):
    if codec == "zlib":
        return zlib.compress(raw)
    if codec in ("lz4", "lz4hc"):
        return lz4.block.compress(raw, store_size=False,
                                  mode="high_compression" if codec == "lz4hc" else "default")
    return zstandard.ZstdCompressor().compress(raw)


def image(values, sample="Float32", byte_order="little", storage="Planar",
          codec=None, shuffle=False, subblocks=False, location="attachment", name="science"):
    """Return an XML Image and its attachment bytes; values are channel,y,x."""
    values = np.asarray(values)
    if values.ndim == 2:
        values = values[None]
    channels, height, width = values.shape
    dtype = np.dtype(("<" if byte_order == "little" else ">") + FORMATS[sample])
    arranged = values if storage == "Planar" else values.transpose(1, 2, 0)
    raw = arranged.astype(dtype).tobytes()
    attrs = dict(id=name, geometry=f"{width}:{height}:{channels}", sampleFormat=sample,
                 colorSpace="RGB" if channels == 3 else "Gray", pixelStorage=storage)
    if dtype.kind == "f":
        attrs["bounds"] = "0:1"
    block_attrs = {"byteOrder": byte_order}
    payload = raw
    if codec:
        if shuffle:
            payload = np.frombuffer(raw, np.uint8).reshape(-1, dtype.itemsize).T.tobytes()
        block_attrs["compression"] = f"{codec}{'+sh' if shuffle else ''}:{len(raw)}"
        if shuffle:
            block_attrs["compression"] += f":{dtype.itemsize}"
        if subblocks:
            # Split AFTER shuffling, deliberately across sample/byte-plane boundaries.
            # Include a verbatim block (compressed size == uncompressed size).
            pieces = [payload[:137], payload[137:414], payload[414:]]
            packed = [compress(pieces[0], codec), pieces[1], compress(pieces[2], codec)]
            block_attrs["subblocks"] = ":".join(f"{len(c)},{len(u)}" for c, u in zip(packed, pieces))
            payload = b"".join(packed)
        else:
            payload = compress(payload, codec)
    element = ET.Element("Image", attrs)
    if location == "attachment":
        element.attrib.update(block_attrs)
        return element, payload
    mode, encoding = location.split(":")
    assert mode == "embedded"
    text = base64.b64encode(payload).decode() if encoding == "base64" else payload.hex()
    # Whitespace is permitted in either encoding.
    text = "\n  " + "\n  ".join(text[i:i + 67] for i in range(0, len(text), 67)) + "\n"
    element.set("location", "embedded")
    ET.SubElement(element, "Data", dict(encoding=encoding, **block_attrs)).text = text
    return element, b""


def write_xisf(path, *images, xml_encoding="utf-8"):
    root = ET.Element("xisf", version="1.0", xmlns="http://www.pixinsight.com/xisf")
    offset, attachments = 32768, []
    for element, data in images:
        root.append(element)
        if "location" not in element.attrib:
            element.set("location", f"attachment:{offset}:{len(data)}")
            offset += len(data)
            attachments.append(data)
    header = ET.tostring(root, encoding=xml_encoding, xml_declaration=True)
    assert len(header) + 16 <= 32768
    path.write_bytes(struct.pack("<8sII", b"XISF0100", len(header), 0) + header
                     + bytes(32768 - 16 - len(header)) + b"".join(attachments))
    return path


def read_png(path):
    """Read fqtool's filter-free 8-bit grayscale/RGBA PNG without Pillow."""
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, compressed = 8, b""
    while pos < len(data):
        size = int.from_bytes(data[pos:pos + 4], "big")
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + size]
        if kind == b"IHDR":
            width, height = struct.unpack(">II", body[:8])
            assert body[8] == 8 and body[9] in (0, 6)
            channels = 1 if body[9] == 0 else 4
        elif kind == b"IDAT":
            compressed += body
        pos += size + 12
    rows = np.frombuffer(zlib.decompress(compressed), np.uint8).reshape(height, 1 + width * channels)
    assert np.all(rows[:, 0] == 0)
    return rows[:, 1:].reshape(height, width, channels)


def binned(values, factor, samples):
    channels, height, width = values.shape
    offsets = [(2 * i + 1) * factor // (2 * samples) for i in range(samples)]
    out = np.empty((channels, height // factor, width // factor), np.float32)
    for y in range(out.shape[1]):
        for x in range(out.shape[2]):
            block = values[:, np.asarray(offsets) + y * factor][:, :, np.asarray(offsets) + x * factor]
            out[:, y, x] = block.mean(axis=(1, 2), dtype=np.float64)
    return out


class XisfTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data.mkdir(parents=True, exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory()
        cls.scratch = Path(cls.temp.name)
        y, x = np.indices((64, 80))
        cls.mono = (x + 3 * y + (x * y % 17)).astype(np.float32)[None]
        cls.rgb = np.concatenate((cls.mono, cls.mono * 2 + 7, cls.mono * 0.25 + 19))
        cls.mono_path = write_xisf(cls.data / "xisf_mono.xisf", image(cls.mono))
        cls.rgb_path = write_xisf(cls.data / "xisf_rgb.xisf", image(cls.rgb))
        cls.multi_path = write_xisf(cls.data / "xisf_multi.xisf",
                                   image(cls.mono, name="luminance"), image(cls.rgb, name="color"))
        cls.zstd_path = write_xisf(cls.data / "xisf_zstd.xisf", image(cls.rgb, codec="zstd", shuffle=True))

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def command(self, *args):
        return subprocess.run([self.fq, *map(str, args)], capture_output=True, text=True,
                              errors="replace", timeout=20)

    def success(self, *args):
        result = self.command(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def dump(self, path, *opts):
        output = self.scratch / "pixels.f32"
        stdout = self.success("dump", path, output, "--max", "100000", *opts)
        width, height, channels = map(int, stdout.splitlines()[0].split())
        info = dict(word.split("=", 1) for word in stdout.splitlines()[1].split() if "=" in word)
        return np.fromfile(output, np.float32).reshape(channels, height, width), info

    def render(self, path, *opts):
        output = self.scratch / "pixels.png"
        stdout = self.success("render", path, output, "--max", "100000", *opts)
        info = dict(word.split("=", 1) for word in stdout.split() if "=" in word)
        return read_png(output).copy(), info

    def check_values(self, path, expected, *opts):
        actual, info = self.dump(path, *opts)
        np.testing.assert_allclose(actual, np.asarray(expected, np.float32), rtol=1e-6, atol=1e-6)
        self.assertEqual(info["flipped"], "0", "XISF uses top-down rows")
        return info

    def test_sample_formats_byte_orders_and_storage(self):
        for sample, code in FORMATS.items():
            dtype = np.dtype(code)
            if dtype.kind == "u":
                maximum = np.iinfo(dtype).max
                edge = np.array([0, 1, 3, maximum // 2, maximum // 2 + 1, maximum - 1, maximum], dtype=dtype)
            else:
                edge = np.array([-0.75, -0.01, 0, 0.01, 0.25, 0.75, 1.5], dtype=dtype)
            for byte_order in ("little", "big"):
                for channels, storage in ((1, "Planar"), (3, "Planar"), (3, "Normal")):
                    with self.subTest(sample=sample, byte_order=byte_order, channels=channels, storage=storage):
                        expected = np.resize(edge, (channels, 8, 10))
                        path = write_xisf(self.data / f"xisf_{sample}_{byte_order}_{channels}_{storage}.xisf",
                                          image(expected, sample, byte_order, storage))
                        self.check_values(path, expected)

    def test_compression_shuffle_and_subblocks(self):
        for codec in ("zlib", "lz4", "lz4hc", "zstd"):
            for shuffle in (False, True):
                for subblocks in (False, True):
                    with self.subTest(codec=codec, shuffle=shuffle, subblocks=subblocks):
                        path = write_xisf(self.data / f"xisf_{codec}_{shuffle}_{subblocks}.xisf",
                                          image(self.rgb, byte_order="big", storage="Normal", codec=codec,
                                                shuffle=shuffle, subblocks=subblocks))
                        self.check_values(path, self.rgb)
        self.check_values(self.zstd_path, self.rgb)

    def test_embedded_encodings(self):
        for encoding, byte_order, sample, codec in product(("base64", "hex"), ("little", "big"),
                                                           ("UInt16", "Float32"), (None, "zlib", "zstd")):
            with self.subTest(encoding=encoding, byte_order=byte_order, sample=sample, codec=codec):
                path = write_xisf(self.data / f"xisf_embedded_{encoding}_{byte_order}_{sample}_{codec}.xisf",
                                  image(self.mono[:, :8, :10], sample, byte_order=byte_order, codec=codec,
                                        shuffle=bool(codec), location=f"embedded:{encoding}"))
                self.check_values(path, self.mono[:, :8, :10])

    def test_utf8_xml_declaration(self):
        item = image(self.mono)
        ET.SubElement(item[0], "Property", id="Object:Name", type="String").text = "M42 星云"
        path = write_xisf(self.data / "xisf_utf8_declaration.xisf", item, xml_encoding="utf8")
        self.check_values(path, self.mono)
        header = self.success("header", path)
        self.assertIn("Object:Name", header)
        self.assertIn("M42", header)

    def test_uppercase_embedded_hex(self):
        values = np.resize(np.array([0xabcd, 0xef01, 0x2345, 0x6789], np.uint16), (1, 8, 10))
        for codec in (None, "zstd"):
            with self.subTest(codec=codec):
                item = image(values, "UInt16", codec=codec, shuffle=bool(codec), location="embedded:hex")
                data = item[0].find("Data")
                data.text = data.text.upper()
                path = write_xisf(self.data / f"xisf_uppercase_hex_{codec}.xisf", item)
                self.check_values(path, values)

    def test_default_attributes(self):
        item = image(self.mono, "UInt16")
        for key in ("pixelStorage", "colorSpace", "byteOrder"):
            del item[0].attrib[key]
        item[0].set("orientation", "0")
        path = write_xisf(self.data / "xisf_defaults.xisf", item)
        self.check_values(path, self.mono)

    def test_multiple_images_and_channel_selection(self):
        listing = self.success("hdus", self.multi_path).splitlines()
        self.assertEqual(len(listing), 2)
        self.assertTrue(listing[0].startswith("0 image ") and "luminance" in listing[0], listing)
        self.assertTrue(listing[1].startswith("1 image ") and "color" in listing[1], listing)
        self.check_values(self.multi_path, self.mono)
        info = self.check_values(self.multi_path, self.rgb, "--hdu", "1")
        self.assertEqual(info["hdu"], "1")
        for plane in range(3):
            self.check_values(self.multi_path, self.rgb[plane:plane + 1], "--hdu", "1", "--plane", str(plane))
        self.check_values(self.rgb_path, self.rgb[1:2], "--mono")

    def test_header_metadata(self):
        item = image(self.mono)
        ET.SubElement(item[0], "FITSKeyword", name="EXPTIME", value="300", comment="Exposure in seconds")
        ET.SubElement(item[0], "FITSKeyword", name="OBJECT", value="'M42 & M43'", comment="Orion")
        ET.SubElement(item[0], "Property", id="Observation:ExposureTime", type="Float64", value="300")
        ET.SubElement(item[0], "Property", id="Object:Name", type="String").text = "M42 & M43"
        path = write_xisf(self.data / "xisf_metadata.xisf", item)
        for option in ("--raw", "--cards", ""):
            with self.subTest(option=option):
                header = self.success("header", path, "0", *([option] if option else []))
                for value in ("EXPTIME", "300", "Exposure in seconds", "Object:Name", "M42 & M43"):
                    self.assertIn(value, header)

    def test_unavailable_image_preserves_other_images(self):
        unavailable = image(self.mono, name="unsupported")
        unavailable[0].set("compression", "unknown:20480")
        path = write_xisf(self.data / "xisf_unsupported_multi.xisf", unavailable, image(self.rgb))
        self.assertEqual(len(self.success("hdus", path).splitlines()), 2)
        self.assertIn("unknown", self.success("header", path, "0"))
        self.check_values(path, self.rgb, "--hdu", "1")
        self.assertEqual(self.command("dump", path, self.scratch / "bad.f32", "--hdu", "0").returncode, 1)

    def test_fits_metadata_does_not_override_xisf_pixels(self):
        item = image(self.mono)
        for key, value in (("BITPIX", "16"), ("NAXIS1", "1"), ("BSCALE", "2"),
                           ("BZERO", "100"), ("ROWORDER", "'BOTTOM-UP'")):
            ET.SubElement(item[0], "FITSKeyword", name=key, value=value)
        path = write_xisf(self.data / "xisf_fits_metadata.xisf", item)
        self.check_values(path, self.mono)
        pixels, _ = self.render(path)
        original, _ = self.render(self.mono_path)
        np.testing.assert_array_equal(pixels, original)

    def test_cfa_and_mono(self):
        raw = self.mono[0]
        for pattern in ("RGGB", "BGGR", "GRBG", "GBRG"):
            with self.subTest(pattern=pattern):
                item = image(raw)
                ET.SubElement(item[0], "ColorFilterArray", width="2", height="2", pattern=pattern)
                path = write_xisf(self.data / f"xisf_cfa_{pattern}.xisf", item)
                cells = np.stack([raw[dy::2, dx::2] for dy in (0, 1) for dx in (0, 1)])
                expected = np.stack([cells[[i for i, p in enumerate(pattern) if p == c]].mean(axis=0)
                                     for c in "RGB"])
                info = self.check_values(path, expected)
                self.assertEqual(info["bayer"], pattern)
                self.check_values(path, self.mono, "--mono")

    def test_binning(self):
        for path, values in ((self.mono_path, self.mono), (self.rgb_path, self.rgb), (self.zstd_path, self.rgb)):
            for max_dim, samples in ((20, 0), (17, 2), (10, 3)):
                with self.subTest(path=path.name, max_dim=max_dim, samples=samples):
                    factor = (80 + max_dim - 1) // max_dim
                    expected = binned(values, factor, min(factor, samples) if samples else factor)
                    self.check_values(path, expected, "--max", str(max_dim), "--samples", str(samples))

    def test_top_down_rendering(self):
        gradient = np.arange(80 * 64, dtype=np.float32).reshape(64, 80)
        path = write_xisf(self.data / "xisf_orientation.xisf", image(gradient))
        pixels, info = self.render(path, "--stretch", "minmax")
        self.assertEqual(info["flipped"], "0")
        self.assertEqual(int(pixels[0, 0, 0]), 0)
        self.assertEqual(int(pixels[-1, -1, 0]), 255)
        self.assertTrue(np.all(np.diff(pixels[:, 0, 0].astype(int)) >= 0))

    def test_restretch_and_zoom(self):
        for path in (self.mono_path, self.rgb_path, self.zstd_path, self.data / "xisf_cfa_RGGB.xisf"):
            with self.subTest(path=path.name):
                # CFA fixtures are generated here too, so tests stay independent.
                if "cfa" in path.name:
                    item = image(self.mono)
                    ET.SubElement(item[0], "ColorFilterArray", width="2", height="2", pattern="RGGB")
                    write_xisf(path, item)
                for before, after in (("auto", "linear"), ("linear", "minmax"), ("minmax", "auto")):
                    direct, _ = self.render(path, "--stretch", after)
                    changed, _ = self.render(path, "--stretch", before, "--then", after)
                    np.testing.assert_array_equal(changed, direct)
                whole, info = self.render(path)
                part, detail = self.render(path, "--region", "12,8,28,20")
                factor = int(info["bin"])
                x, y, width, height = map(int, detail["region"].split(","))
                np.testing.assert_array_equal(part, whole[y // factor:(y + height) // factor,
                                                         x // factor:(x + width) // factor])

    def test_nonfinite_samples(self):
        expected = self.mono.copy()
        expected[0, 1, :3] = np.nan
        source = expected.copy()
        source[0, 1, :3] = [np.nan, np.inf, -np.inf]
        path = write_xisf(self.data / "xisf_nonfinite.xisf", image(source, "Float64"))
        self.check_values(path, expected)
        pixels, _ = self.render(path)
        self.assertEqual(pixels.shape[2], 4)
        np.testing.assert_array_equal(pixels[1, :3, 3], [0, 0, 0])

    def test_malformed_files(self):
        valid = self.mono_path.read_bytes()
        compressed = write_xisf(self.scratch / "compressed.xisf", image(self.mono, codec="zlib")).read_bytes()
        variants = {
            "short_signature": b"XISF0100",
            "header_past_eof": valid[:8] + struct.pack("<I", 0xffffffff) + valid[12:],
            "broken_xml": valid.replace(b"</xisf>", b"</bad!>"),
            "attachment_past_eof": valid.replace(b"attachment:32768:", b"attachment:99999:"),
            "attachment_in_header": valid.replace(b"attachment:32768:", b"attachment:00016:"),
            "negative_attachment": valid.replace(b"attachment:32768:", b"attachment:-0001:"),
            "truncated_pixels": valid[:-1],
            "zero_geometry": valid.replace(b'geometry="80:64:1"', b'geometry="00:64:1"'),
            "bad_codec": compressed.replace(b"zlib:", b"zzzz:"),
            "corrupt_compressed_data": compressed[:32768] + b"!" * (len(compressed) - 32768),
        }
        for name, data in variants.items():
            with self.subTest(name=name):
                path = self.scratch / f"bad_{name}.xisf"
                path.write_bytes(data)
                result = self.command("dump", path, self.scratch / "bad.f32")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertTrue(result.stderr.strip())
        for name, attrs in (
            ("overflow", {"geometry": "9223372036854775807:9223372036854775807:3"}),
            ("bad_subblocks", {"compression": "zlib:20480", "subblocks": "1,20480:1,20480"}),
            ("bad_shuffle", {"compression": "zlib+sh:20480:0"}),
            ("wrong_uncompressed_size", {"compression": "zlib:4"}),
            ("bad_sample", {"sampleFormat": "Complex64"}),
            ("bad_storage", {"pixelStorage": "Other"}),
            ("nondefault_orientation", {"orientation": "90"}),
        ):
            with self.subTest(name=name):
                item = image(self.mono)
                item[0].attrib.update(attrs)
                path = write_xisf(self.scratch / f"bad_{name}.xisf", item)
                result = self.command("dump", path, self.scratch / "bad.f32")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for encoding, text in (("base64", "invalid!"), ("hex", "x0")):
            with self.subTest(encoding=encoding):
                item = image(self.mono, location=f"embedded:{encoding}")
                item[0].find("Data").text = text
                path = write_xisf(self.scratch / f"bad_{encoding}.xisf", item)
                self.assertEqual(self.command("dump", path, self.scratch / "bad.f32").returncode, 1)
        header = b'<!DOCTYPE xisf [<!ENTITY local "unexpected">]><xisf version="1.0">&local;</xisf>'
        path = self.scratch / "bad_doctype.xisf"
        path.write_bytes(struct.pack("<8sII", b"XISF0100", len(header), 0) + header)
        self.assertEqual(self.command("header", path).returncode, 1)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    XisfTests.fq = str(Path(sys.argv[1]).resolve())
    XisfTests.data = Path(sys.argv[2])
    unittest.main(argv=[sys.argv[0]], verbosity=2)
