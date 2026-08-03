"""Import the user's own concept art into the cartridge's four shades.

Crop the portrait region, downscale to the tile budget, quantize to the DMG's
four levels with ordered (Bayer 4x4) dithering -- the dither is what carries
an illustration's shading into four colours without banding it flat.
"""

import struct, subprocess, sys, zlib

SRC = "/Users/maartz/Downloads/moananas.jpg"
BASE = "/private/tmp/claude-501/-Users-maartz-Documents-elixir-projects-atomboy/c21f1dee-9f8e-4544-8dc8-3c1a6d6264ff/scratchpad/"

# Crop region (in the 1024x1024 source), target size in pixels (tile multiples).
CROP = sys.argv[1] if len(sys.argv) > 1 else "380x580+50+240"
TW, TH = (int(v) for v in (sys.argv[2] if len(sys.argv) > 2 else "72x96").split("x"))
# Dither strength: how far the Bayer matrix pushes a pixel between levels.
SPREAD = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5

subprocess.run(
    [
        "magick", SRC,
        "-crop", CROP,
        "-colorspace", "Gray",
        "-normalize",
        "-resize", f"{TW}x{TH}!",
        "-depth", "8",
        f"{BASE}face_gray.pgm",
    ],
    check=True,
)

with open(f"{BASE}face_gray.pgm", "rb") as f:
    data = f.read()

# PGM: P5 <w> <h> 255\n then raw bytes.
parts = data.split(b"\n", 3)
w, h = (int(v) for v in parts[1].split())
pixels = parts[3][: w * h]

BAYER = [
    [0, 8, 2, 10],
    [12, 4, 14, 6],
    [3, 11, 1, 9],
    [15, 7, 13, 5],
]

# Quantize to 4 levels with ordered dithering: the Bayer threshold nudges each
# pixel up to half a level either way, so a flat mid-grey becomes a weave of
# the two neighbouring shades instead of a slab of one.
out = []
for y in range(h):
    row = []
    for x in range(w):
        v = pixels[y * w + x] / 255.0
        t = (BAYER[y % 4][x % 4] + 0.5) / 16.0 - 0.5
        q = round(v * 3 + t * SPREAD * 2)
        q = max(0, min(3, q))
        row.append(q)
    out.append(row)

LEVELS = [0, 100, 170, 255]  # shade 3..0 as grey values (q is brightness rank)

grid = ["".join("#+-."[q] for q in row) for row in out]


def write_png(path, grid, scale=1):
    width, height = len(grid[0]) * scale, len(grid) * scale
    rows = []
    lut = {"#": 0, "+": 100, "-": 170, ".": 255}
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            row.append(lut[grid[y // scale][x // scale]])
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data))
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


write_png(f"{BASE}face_import.png", grid)
write_png(f"{BASE}face_import_big.png", grid, scale=6)
print(f"imported {w}x{h} ({w // 8}x{h // 8} tiles), crop {CROP}, spread {SPREAD}")
