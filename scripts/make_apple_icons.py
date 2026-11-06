"""Writes the app icon sets of the Mac app and of the iPhone and iPad app from the drawing of the Windows icon
(make_ico.py), drawn at each size rather than scaled. The iPhone icon is a full opaque square, which iOS rounds
itself; the Mac icons have rounded, transparent corners. Only the standard library is used.

Usage: python scripts/make_apple_icons.py
"""

import json
import struct
import zlib
from pathlib import Path

import make_ico

ROOT = Path(__file__).resolve().parent.parent
MAC = ROOT / "mac" / "LazyPDFMacApp" / "Assets.xcassets" / "AppIcon.appiconset"
IOS = ROOT / "ios" / "LazyPDFiOS" / "Assets.xcassets" / "AppIcon.appiconset"

MAC_POINTS = (16, 32, 128, 256, 512)
INFO = {"author": "xcode", "version": 1}


def write_mac():
    images = []
    for points in MAC_POINTS:
        for scale in (1, 2):
            name = "icon_%dx%d%s.png" % (points, points, "@2x" if scale == 2 else "")
            png = make_ico.draw(points * scale, corner=0.22 * make_ico.DESIGN)
            (MAC / name).write_bytes(png)
            images.append({"filename": name, "idiom": "mac", "scale": "%dx" % scale,
                           "size": "%dx%d" % (points, points)})
    (MAC / "Contents.json").write_text(json.dumps({"images": images, "info": INFO}, indent=2) + "\n")


def opaque_png(canvas):
    # The App Store rejects an iPhone icon with an alpha channel, even a fully opaque one.
    size = canvas.size
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        for i in range(y * size, (y + 1) * size):
            for channel in (canvas.r, canvas.g, canvas.b):
                raw.append(int(round(min(max(channel[i], 0.0), 1.0) * 255)))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def write_ios():
    (IOS / "AppIcon-1024.png").write_bytes(opaque_png(make_ico.paint(1024)))
    images = [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]
    (IOS / "Contents.json").write_text(json.dumps({"images": images, "info": INFO}, indent=2) + "\n")


if __name__ == "__main__":
    write_mac()
    write_ios()
