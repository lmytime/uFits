#!/usr/bin/env python3
"""Draw the uFits app icon (a spiral galaxy) and write macos/App/AppIcon.icns.

Needs numpy and Pillow. The .icns is committed, so this only needs to run
when the artwork changes.
"""
import io
import struct
import sys

import numpy as np
from PIL import Image

N = 1024


def galaxy(n):
    y, x = (np.mgrid[0:n, 0:n] - n / 2 + 0.5) / (n / 2)
    # Tilt the disc.
    ang = np.deg2rad(-28)
    xr = x * np.cos(ang) - y * np.sin(ang)
    yr = (x * np.sin(ang) + y * np.cos(ang)) / 0.62
    r = np.hypot(xr, yr) + 1e-6
    th = np.arctan2(yr, xr)
    # Two logarithmic spiral arms.
    pitch = 0.32
    phase = th - np.log(r) / pitch
    arms = (0.5 + 0.5 * np.cos(2 * phase)) ** 3
    disc = np.exp(-r / 0.22)
    bulge = np.exp(-(r / 0.07) ** 1.2)
    light = disc * (0.25 + 1.6 * arms) + 3.0 * bulge
    # Dust lanes trail the arms.
    light *= 1 - 0.35 * (0.5 + 0.5 * np.cos(2 * phase - 0.9)) ** 6 * np.exp(-r / 0.5)
    return light, r, arms


def render():
    rng = np.random.default_rng(7)
    light, r, arms = galaxy(N)
    v = np.arcsinh(light * 6) / np.arcsinh(6 * 3.5)
    v = np.clip(v, 0, 1)
    # Warm core, blue arms.
    warm = np.array([1.0, 0.86, 0.66])
    blue = np.array([0.55, 0.72, 1.0])
    mix = np.clip(r / 0.35, 0, 1)[..., None]
    col = (warm * (1 - mix) + blue * mix) * v[..., None]

    # Background: deep blue gradient.
    yy = np.linspace(0, 1, N)[:, None, None]
    bg = np.array([0.02, 0.03, 0.09]) * (1 - yy) + np.array([0.06, 0.08, 0.20]) * yy
    img = bg + col * 1.15

    # A few stars.
    for _ in range(70):
        sx, sy = rng.uniform(80, N - 80, 2)
        if np.hypot(sx - N / 2, sy - N / 2) < 260:
            continue
        b = rng.uniform(0.25, 1.0) ** 2
        s = rng.uniform(1.2, 3.2)
        y0, y1 = int(sy - 12), int(sy + 13)
        x0, x1 = int(sx - 12), int(sx + 13)
        gy, gx = np.mgrid[y0:y1, x0:x1]
        g = b * np.exp(-((gx - sx) ** 2 + (gy - sy) ** 2) / (2 * s * s))
        img[y0:y1, x0:x1] += g[..., None] * np.array([0.9, 0.95, 1.0])
    img = np.clip(img, 0, 1)

    # Rounded square (macOS grid: 824 px shape, radius 185 on a 1024 canvas).
    size, rad = 824, 185.4
    c = (N - 1) / 2
    gy, gx = np.mgrid[0:N, 0:N]
    dx = np.maximum(np.abs(gx - c) - (size / 2 - rad), 0)
    dy = np.maximum(np.abs(gy - c) - (size / 2 - rad), 0)
    d = np.hypot(dx, dy) - rad
    alpha = np.clip(0.5 - d, 0, 1)
    rgba = np.dstack([img, alpha])
    # Subtle top highlight on the rim.
    rim = np.clip(1 - np.abs(d + 3) / 3, 0, 1) * (gy < c) * 0.25
    rgba[..., :3] = np.clip(rgba[..., :3] + rim[..., None], 0, 1)
    return Image.fromarray((rgba * 255 + 0.5).astype(np.uint8), "RGBA")


def png(im, px):
    out = io.BytesIO()
    im.resize((px, px), Image.LANCZOS).save(out, "PNG", optimize=True)
    return out.getvalue()


def main(path):
    im = render()
    entries = [(b"icp4", 16), (b"icp5", 32), (b"icp6", 64), (b"ic07", 128), (b"ic08", 256),
               (b"ic09", 512), (b"ic10", 1024), (b"ic11", 32), (b"ic12", 64), (b"ic13", 256),
               (b"ic14", 512)]
    cache = {}
    body = b""
    for tag, px in entries:
        data = cache.setdefault(px, png(im, px))
        body += tag + struct.pack(">I", len(data) + 8) + data
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
    im.resize((256, 256), Image.LANCZOS).save(path.replace(".icns", "-preview.png"))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "macos/App/AppIcon.icns")
