#!/usr/bin/env python3
"""atomboy's icon: a pixel-art Game Boy, drawn at 32x32 then scaled up with
nearest-neighbour — crisp pixels are the house style.

Usage: icon.py output.icns   (needs iconutil, which ships with macOS)
"""
import subprocess
import sys
import tempfile
import zlib
import struct
import os

OUTLINE = (0x2A, 0x2A, 0x33)
CASE = (0xC5, 0xC0, 0xCE)
SHADOW = (0x8F, 0x8A, 0x9C)
PANEL = (0x8B, 0xAC, 0x0F)
PIXELS = (0x0F, 0x38, 0x0F)
BUTTON = (0x9E, 0x2A, 0x4E)

# The A from the menu font — 5x7, bit 4 on the left.
LETTER_A = [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11]


def grid():
    g = [[None] * 32 for _ in range(32)]

    def rect(x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                g[y][x] = c

    # The case, its outline, its drop shadow (right and bottom).
    rect(2, 1, 27, 29, OUTLINE)
    rect(3, 2, 26, 28, CASE)
    rect(4, 28, 26, 28, SHADOW)
    rect(26, 3, 26, 28, SHADOW)
    # Softened corners.
    for x, y in [(2, 1), (27, 1), (2, 29), (27, 29)]:
        g[y][x] = None

    # The screen: dark bezel, green panel, atomboy's A in pixels.
    rect(5, 4, 22, 15, PIXELS)
    rect(7, 6, 20, 13, PANEL)
    for dy, row in enumerate(LETTER_A):
        for dx in range(5):
            if (row >> (4 - dx)) & 1:
                g[6 + dy][11 + dx] = PIXELS

    # The d-pad.
    rect(5, 20, 9, 21, OUTLINE)
    rect(6, 19, 8, 22, OUTLINE)

    # A and B, diagonal as they should be.
    rect(21, 18, 22, 19, BUTTON)
    rect(17, 20, 18, 21, BUTTON)

    # Start/Select, and the speaker grille in diagonals.
    rect(9, 25, 11, 25, SHADOW)
    rect(13, 25, 15, 25, SHADOW)
    for i in range(4):
        g[26 - i][20 + i] = SHADOW
        if 22 + i <= 25:
            g[26 - i][22 + i] = SHADOW

    return g


def png(path, size):
    g = grid()
    rows = b""
    for y in range(size):
        row = b"\x00"
        for x in range(size):
            # Nearest-neighbour, both ways — 16 px just like 1024.
            c = g[y * 32 // size][x * 32 // size]
            row += bytes(c) + b"\xff" if c else b"\x00\x00\x00\x00"
        rows += row

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows))
            + chunk(b"IEND", b"")
        )


def main(output):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "atomboy.iconset")
        os.mkdir(iconset)
        for name, size in [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]:
            png(os.path.join(iconset, name), size)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", output], check=True)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Atomboy.icns")
