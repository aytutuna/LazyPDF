"""Draws the Windows app icon: a white page with a folded corner and lines of text on a deep red
square. Windows does not round icons, so the square gets rounded corners, transparent outside them.
Every frame is a PNG, which .ico files may hold since Windows Vista.

Every shape is a signed distance (in pixels) to a rounded rectangle or a cut of one, and its edge is
smoothed over one pixel, so the picture is the same at any size without a drawing library. Only the
standard library is used; the output is the same bytes on every run.

Usage: python scripts/make_ico.py <out.ico> [<out.png>]   (the png is the 256-pixel frame)
"""

import math
import struct
import sys
import zlib
from array import array

# The design is laid out on a 1024-pixel square; other sizes scale it.
DESIGN = 1024.0
SIZES = (16, 20, 24, 32, 40, 48, 64, 256)
ROOT2 = math.sqrt(2.0)

BACKGROUND = "#B3261E"
PAGE = "#FFFFFF"
FOLD = "#EBC3BF"
TITLE = "#B3261E"
LINES = "#D6A29D"


def rounded_rect(px, py, cx, cy, hw, hh, r):
    """Signed distance from (px, py) to a rounded rectangle centred at (cx, cy)."""
    qx = abs(px - cx) - (hw - r)
    qy = abs(py - cy) - (hh - r)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - r


def hex_color(text):
    text = text.lstrip("#")
    return tuple(int(text[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


class Canvas:
    def __init__(self, size, color):
        self.size = size
        self.scale = size / DESIGN
        n = size * size
        cr, cg, cb = hex_color(color)
        self.r = array("d", [cr]) * n
        self.g = array("d", [cg]) * n
        self.b = array("d", [cb]) * n
        self.a = None

    def round_corners(self, radius):
        """Makes the canvas transparent outside a square with corners of `radius` (design units)."""
        size = self.size
        s = self.scale
        half = DESIGN / 2.0
        self.a = array("d", [1.0]) * (size * size)
        for y in range(size):
            py = (y + 0.5) / s
            for x in range(size):
                d = rounded_rect((x + 0.5) / s, py, half, half, half, half, radius) * s
                self.a[y * size + x] = min(max(0.5 - d, 0.0), 1.0)

    def shape(self, distance, bounds, color, opacity=1.0):
        """Paints where `distance` (design units) is negative, the edge smoothed over one pixel."""
        cr, cg, cb = hex_color(color)
        s = self.scale
        x0 = max(0, int((bounds[0] - 2.0) * s))
        y0 = max(0, int((bounds[1] - 2.0) * s))
        x1 = min(self.size, int(math.ceil((bounds[2] + 2.0) * s)) + 1)
        y1 = min(self.size, int(math.ceil((bounds[3] + 2.0) * s)) + 1)
        for y in range(y0, y1):
            py = (y + 0.5) / s
            row = y * self.size
            for x in range(x0, x1):
                d = distance((x + 0.5) / s, py) * s
                alpha = min(max(0.5 - d, 0.0), 1.0) * opacity
                if alpha <= 0.0:
                    continue
                i = row + x
                self.r[i] += (cr - self.r[i]) * alpha
                self.g[i] += (cg - self.g[i]) * alpha
                self.b[i] += (cb - self.b[i]) * alpha

    def png(self):
        size = self.size
        raw = bytearray()
        for y in range(size):
            raw.append(0)
            start = y * size
            for x in range(size):
                i = start + x
                raw.append(int(round(min(max(self.r[i], 0.0), 1.0) * 255)))
                raw.append(int(round(min(max(self.g[i], 0.0), 1.0) * 255)))
                raw.append(int(round(min(max(self.b[i], 0.0), 1.0) * 255)))
                raw.append(255 if self.a is None else int(round(self.a[i] * 255)))

        def chunk(kind, data):
            body = kind + data
            return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

        header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def rect_shape(canvas, left, top, right, bottom, radius, color, opacity=1.0):
    cx = (left + right) / 2.0
    cy = (top + bottom) / 2.0
    hw = (right - left) / 2.0
    hh = (bottom - top) / 2.0
    canvas.shape(lambda px, py: rounded_rect(px, py, cx, cy, hw, hh, radius),
                 (left, top, right, bottom), color, opacity)


def draw(size, corner=0.0):
    return paint(size, corner).png()


def paint(size, corner=0.0):
    canvas = Canvas(size, BACKGROUND)

    # The page, with its top right corner cut along a diagonal and the flap drawn where it folded over.
    left, top, right, bottom, cut = 232, 140, 792, 884, 200
    cx, cy = (left + right) / 2.0, (top + bottom) / 2.0
    hw, hh = (right - left) / 2.0, (bottom - top) / 2.0
    ax, ay = right - cut, top

    def page(px, py):
        return max(rounded_rect(px, py, cx, cy, hw, hh, 44), ((px - ax) - (py - ay)) / ROOT2)

    def flap(px, py):
        return max(ax - px, py - (ay + cut), ((px - ax) - (py - ay)) / ROOT2)

    canvas.shape(page, (left, top, right, bottom), PAGE)
    canvas.shape(flap, (ax, ay, right, ay + cut), FOLD)

    rect_shape(canvas, 316, 436, 316 + 300, 436 + 46, 23, TITLE)
    for line_top, width in ((540, 392), (620, 392), (700, 392), (780, 240)):
        rect_shape(canvas, 316, line_top, 316 + width, line_top + 32, 16, LINES)
    if corner:
        canvas.round_corners(corner)
    return canvas


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: python scripts/make_ico.py <out.ico> [<out.png>]")
    frames = [draw(size, corner=0.22 * DESIGN) for size in SIZES]
    header = struct.pack("<HHH", 0, 1, len(frames))
    offset = len(header) + 16 * len(frames)
    entries = b""
    for size, png in zip(SIZES, frames):
        # A width or height of 0 in the directory means 256.
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(png), offset)
        offset += len(png)
    with open(sys.argv[1], "wb") as out:
        out.write(header + entries + b"".join(frames))
    if len(sys.argv) == 3:
        with open(sys.argv[2], "wb") as out:
            out.write(frames[-1])
    print("wrote %s (%s)" % (sys.argv[1], ", ".join(str(size) for size in SIZES)))


if __name__ == "__main__":
    main()
