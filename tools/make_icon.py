#!/usr/bin/env python3
"""Draw the uFits icon, a pixel-art spiral galaxy, in its dark (Dusk) and
light versions, and write

  macos/App/AppIcon.icns          the app's icon: Dusk (macOS 15 and earlier)
  macos/App/AppIconLight.icns     the light one, for the app's icon setting
  macos/App/AppIcon.icon          both, for macOS 26 to follow light and dark
                                  mode (Icon Composer's format)
  macos/App/Assets.xcassets       Dusk as an icon of its own, whose images the
                                  build gives the icon for macOS 15 and earlier
  docs/icon.png, docs/icon-light.png, docs/favicon.png, docs/favicon-light.png

The galaxy is drawn cell by cell from the maps below: 32 cells across the
1024 x 1024 icon, so that every size from 32 px up is drawn exactly (one cell
a pixel at 32 px), and a map of its own for 16 px. The icon's shape is
Apple's (824 of 1024, corners of radius 185.4), cut smoothly at each size.

Needs numpy and Pillow. What it writes is committed, so this only needs to
run when the artwork changes.
"""
import io
import json
import os
import struct
import sys

import numpy as np
from PIL import Image

# Cells: . night, , faint disc, 0-3 arms (dim to bright), A C W the core
# (amber, cream, white), * star-forming knots, s S stars. F, the cells along
# the icon's edge, is added below.
ART32 = """
................................
................................
................................
................................
.......................s........
......................sSs.......
..........,,,,,,,......s........
........,000000000,,............
.......,000000,,,,,,,,,.........
......,0100,,......,,,,,,.......
......0110,............,,,s.....
......0*10...,,,.........,,.....
......0110,,0122110.............
......,110,0232111210...........
.......011,022ACA11110..........
........011,1ACWWA2,111,........
........,111,2AWWCA1,110........
..........01111ACA220,110.......
...........0121112320,011,......
.............0112210,,0110......
.....s,.........,,,...01*0......
......,,,............,0110......
.......,,,,,,......,,0010,......
.........,,,,,,,,,000000,.......
............,,000000000,........
........S......,,,,,,,..........
................................
...................s............
................................
................................
................................
................................
"""

ART16 = """
................
................
................
....,0000,..S...
...0100,,,......
...11,..........
...1102321......
...,10AWW210....
....012WWA01,...
......1232011...
..........,11...
......,,,0010...
...s..,0000,....
................
................
................
"""

PALETTES = {
    # Dark: muted lavender arms and a soft gold core on indigo.
    "dusk": {
        ".": "#161825", "F": "#232740", ",": "#1e2133",
        "0": "#32375a", "1": "#525a89", "2": "#8890be", "3": "#c3c8e6",
        "A": "#d8b886", "C": "#efdcb8", "W": "#fff8ea",
        "*": "#e39ab0", "s": "#6c74a2", "S": "#eceef8",
    },
    # Light: the same galaxy in indigo ink on pale lavender, with a gold core.
    "light": {
        ".": "#f0eff6", "F": "#dedcea", ",": "#e1dfec",
        "0": "#bbb9d6", "1": "#8988ba", "2": "#5a5d98", "3": "#363a71",
        "A": "#b07a2c", "C": "#d49d3a", "W": "#f0c457",
        "*": "#cc7093", "s": "#a5a4c8", "S": "#33376b",
    },
}

SHAPE, RADIUS = 824 / 1024, 185.4 / 1024  # of the icon's width


def cells(text):
    rows = [r for r in text.split("\n") if r]
    g = len(rows)
    assert all(len(r) == g for r in rows), "a map must be square"
    # 180-degree symmetric, but for the stars and knots.
    for i in range(g):
        for j in range(g):
            a, b = rows[i][j], rows[g - 1 - i][g - 1 - j]
            assert a == b or {a, b} & set("sS*"), f"not symmetric at {i},{j}"
    # The night along the icon's edge is a shade lighter: the edge shows on
    # any background.
    out = [list(r) for r in rows]
    half, rad = SHAPE * g / 2, RADIUS * g
    edge = 1.0 if g >= 32 else 0.5  # cells
    for i in range(g):
        for j in range(g):
            dx = max(abs(j + 0.5 - g / 2) - (half - rad), 0)
            dy = max(abs(i + 0.5 - g / 2) - (half - rad), 0)
            if out[i][j] == "." and rad - np.hypot(dx, dy) < edge:
                out[i][j] = "F"
    return out


def shape(n):
    """The icon's shape at n x n pixels, antialiased."""
    size, rad = SHAPE * n, RADIUS * n
    c = (n - 1) / 2
    gy, gx = np.mgrid[0:n, 0:n]
    dx = np.maximum(np.abs(gx - c) - (size / 2 - rad), 0)
    dy = np.maximum(np.abs(gy - c) - (size / 2 - rad), 0)
    return np.clip(0.5 - (np.hypot(dx, dy) - rad), 0, 1)


def render(palette, n):
    """The icon at n pixels (16, or a multiple of 32), cells drawn exactly."""
    art = cells(ART16 if n < 32 else ART32)
    g = len(art)
    assert n % g == 0, n
    rgb = {k: [int(v[i:i + 2], 16) for i in (1, 3, 5)] for k, v in PALETTES[palette].items()}
    a = np.array([[rgb[c] for c in row] for row in art], np.uint8)
    a = a.repeat(n // g, axis=0).repeat(n // g, axis=1)
    alpha = (shape(n) * 255 + 0.5).astype(np.uint8)
    return Image.fromarray(np.dstack([a, alpha]), "RGBA")


def png(im):
    out = io.BytesIO()
    im.save(out, "PNG", optimize=True)
    return out.getvalue()


def icns(palette, path):
    entries = [(b"icp4", 16), (b"icp5", 32), (b"icp6", 64), (b"ic07", 128), (b"ic08", 256),
               (b"ic09", 512), (b"ic10", 1024), (b"ic11", 32), (b"ic12", 64), (b"ic13", 256),
               (b"ic14", 512)]
    body = b""
    for tag, px in entries:
        data = png(render(palette, px))
        body += tag + struct.pack(">I", len(data) + 8) + data
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)


def full_bleed(palette, n=1024):
    """The icon's shape filled edge to edge, as Icon Composer's layers are
    (macOS 26 cuts the shape): the cells inside the shape, scaled to n."""
    art = cells(ART32)
    g = len(art)
    rgb = {k: [int(v[i:i + 2], 16) for i in (1, 3, 5)] for k, v in PALETTES[palette].items()}
    a = np.array([[rgb[c] for c in row] for row in art], np.uint8)
    margin = (1 - SHAPE) / 2 * g  # cells outside the shape, on each side
    k = np.floor(margin + (np.arange(n) + 0.5) / n * SHAPE * g).astype(int)
    return Image.fromarray(a[k][:, k], "RGB")


def icon_composer(path):
    """Icon Composer's icon: the light one over Dusk, hidden in dark mode;
    flat (no glass, shadow or highlights)."""
    os.makedirs(os.path.join(path, "Assets"), exist_ok=True)
    for palette in ("light", "dusk"):
        full_bleed(palette).save(os.path.join(path, "Assets", f"{palette}.png"), optimize=True)
    flat = {"glass": False}
    icon = {
        "fill": {"solid": "srgb:0.08627,0.09412,0.14510,1.00000"},
        "groups": [{
            "layers": [
                dict(flat, **{"image-name": "light.png", "name": "light",
                              "hidden-specializations": [{"appearance": "dark", "value": True}]}),
                dict(flat, **{"image-name": "dusk.png", "name": "dusk"}),
            ],
            "shadow": {"kind": "none", "opacity": 0},
            "specular": False,
            "translucency": {"enabled": False, "value": 0},
        }],
        "supported-platforms": {"squares": ["macOS"]},
    }
    with open(os.path.join(path, "icon.json"), "w") as f:
        json.dump(icon, f, indent=2)
        f.write("\n")


def catalog(path):
    """An asset catalog with Dusk as an app icon of its own: the build gives
    AppIcon.icon its images, the ones macOS 15 and earlier show (actool makes
    them from the light look; tools/flat_icon.m)."""
    iconset = os.path.join(path, "Dusk.appiconset")
    os.makedirs(iconset, exist_ok=True)
    with open(os.path.join(path, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"dusk-{px}.png"
            render("dusk", px).save(os.path.join(iconset, name), optimize=True)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
    with open(os.path.join(iconset, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")


def main(root):
    app = os.path.join(root, "macos", "App")
    docs = os.path.join(root, "docs")
    icns("dusk", os.path.join(app, "AppIcon.icns"))
    icns("light", os.path.join(app, "AppIconLight.icns"))
    icon_composer(os.path.join(app, "AppIcon.icon"))
    catalog(os.path.join(app, "Assets.xcassets"))
    for palette, suffix in (("dusk", ""), ("light", "-light")):
        render(palette, 256).save(os.path.join(docs, f"icon{suffix}.png"), optimize=True)
        render(palette, 64).save(os.path.join(docs, f"favicon{suffix}.png"), optimize=True)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
