"""Moananas Island -- the sheet. All original drawings.

The portrait is built on a 64x80 raster with drawing helpers, because a face
this size is geometry first (hair mass, glasses circles, jaw curve) and
pixel-nudging second. Shades: 0 white, 1 light, 2 dark, 3 black.
"""

import struct, zlib

W, H = 64, 80
P = [[0] * W for _ in range(H)]  # 0..3 shade indices


def px(x, y, s):
    if 0 <= x < W and 0 <= y < H:
        P[y][x] = s


def hspan(y, x0, x1, s):
    for x in range(x0, x1 + 1):
        px(x, y, s)


def vspan(x, y0, y1, s):
    for y in range(y0, y1 + 1):
        px(x, y, s)


def disc(cx, cy, r, s):
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - r, cx + r + 1):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                px(x, y, s)


def ring(cx, cy, r, s, thick=1):
    for y in range(cy - r - 1, cy + r + 2):
        for x in range(cx - r - 1, cx + r + 2):
            d2 = (x - cx) ** 2 + (y - cy) ** 2
            if (r - thick) ** 2 < d2 <= r * r:
                px(x, y, s)


# ── The hair: a long dark mass, rounded on top, falling past the jaw ──
for y in range(2, 80):
    # width of the hair silhouette by row
    if y < 6:
        x0, x1 = 14, 49
    elif y < 12:
        x0, x1 = 9, 54
    else:
        x0, x1 = 7, 56
    hspan(y, x0, x1, 2)

# a rounded crown: the silhouette widens in smooth steps, each with its
# black outline, so the top reads as a head of hair and not a hat
for y in range(2, 80):
    if y < 4:
        px(13, y, 3); px(50, y, 3)
    elif y < 6:
        px(11, y, 3); px(52, y, 3)
    elif y < 9:
        px(9, y, 3); px(54, y, 3)
    elif y < 12:
        px(8, y, 3); px(55, y, 3)
    else:
        px(6, y, 3); px(57, y, 3)
hspan(2, 14, 49, 3)
for y in range(4, 6):
    hspan(y, 12, 13, 2)
    hspan(y, 50, 51, 2)
for y in range(6, 9):
    hspan(y, 10, 11, 2)
    hspan(y, 52, 53, 2)

# ── The face: a light oval carved out of the hair ──
for y in range(14, 62):
    if y < 20:
        x0, x1 = 20, 43
    elif y < 50:
        x0, x1 = 17, 46
    elif y < 56:
        x0, x1 = 20, 43
    else:
        x0, x1 = 24, 39
    hspan(y, x0, x1, 1)

# hairline
hspan(14, 20, 43, 3)
hspan(15, 18, 45, 2)

# ── The brows: angry diagonals over the glasses ──
for i in range(7):
    px(21 + i, 22 + i // 2, 3)
    px(22 + i, 22 + i // 2, 3)
    px(42 - i, 22 + i // 2, 3)
    px(41 - i, 22 + i // 2, 3)

# ── The glasses: two rings joined at the bridge ──
ring(25, 32, 7, 3)
ring(39, 32, 7, 3)
disc(25, 32, 5, 0)
disc(39, 32, 5, 0)
# pupils looking slightly cross
disc(27, 32, 2, 3)
disc(37, 32, 2, 3)
hspan(32, 30, 33, 3)  # bridge
hspan(31, 30, 33, 3)

# ── The nose: two strokes down, nostril flick ──
vspan(31, 38, 44, 3)
px(32, 44, 3)
px(33, 45, 3)

# ── Moustache, mouth, goatee ──
hspan(49, 26, 30, 3)
hspan(49, 34, 38, 3)
hspan(48, 27, 29, 3)
hspan(48, 35, 37, 3)
hspan(52, 28, 36, 3)  # mouth line
px(28, 53, 3); px(36, 53, 3)
# goatee under the lip, down the chin
for y in range(55, 62):
    w = 3 if y < 58 else 2
    hspan(y, 32 - w, 32 + w, 2)
hspan(56, 30, 34, 3)
vspan(32, 55, 61, 3)

# ── The jaw outline where face meets hair ──
vspan(17, 20, 49, 3)
vspan(46, 20, 49, 3)
for i, y in enumerate(range(50, 56)):
    px(18 + i, y, 3)
    px(45 - i, y, 3)

# ── Neck and shirt ──
for y in range(62, 70):
    hspan(y, 27, 37, 1)
    px(26, y, 3)
    px(38, y, 3)
for y in range(70, 80):
    hspan(y, 10, 53, 2)
    px(9, y, 3)
    px(54, y, 3)
hspan(70, 10, 26, 3)
hspan(70, 38, 53, 3)
hspan(71, 24, 27, 2)
hspan(71, 37, 40, 2)

PORTRAIT = ["".join(".-+#"[s] for s in row) for row in P]

# ── The island furniture, 8x8 and 8x16 ──

TILES8 = {
    "pineapple_top": [
        "...#.#..",
        "..#-#-#.",
        ".#-#-#..",
        "..##-#-.",
        "...###..",
        "..#+-+#.",
        ".#-+-+-#",
        ".#+-+-+#",
    ],
    "pineapple_body": [
        ".#-+-+-#",
        ".#+-+-+#",
        ".#-+-+-#",
        ".#+-+-+#",
        "..#-+-#.",
        "..#+-+#.",
        "...###..",
        "........",
    ],
    "moai_head": [
        "..####..",
        ".#++++#.",
        ".#+##+#.",
        ".#++++#.",
        ".##++##.",
        ".#+##+#.",
        ".#++++#.",
        ".#+++##.",
    ],
    "moai_base": [
        ".#++++#.",
        ".#+++++#",
        ".#++++#.",
        "#++++++#",
        "#+####+#",
        "########",
        "........",
        "........",
    ],
    "palm_crown": [
        "#..##..#",
        ".##++##.",
        "#+++++#.",
        ".##++##.",
        "#..##..#",
        "...##...",
        "...##...",
        "...##...",
    ],
    "palm_trunk": [
        "...##...",
        "...+#...",
        "...##...",
        "...#+...",
        "...##...",
        "..#++#..",
        ".#++++#.",
        "########",
    ],
    "cloud": [
        "..####..",
        ".#....#.",
        "#......#",
        "#......#",
        ".######.",
        "........",
        "........",
        "........",
    ],
    "border": [
        "##-##-##",
        "#+##+##+",
        "-##-##-#",
        "##+##+##",
        "##-##-##",
        "#+##+##+",
        "-##-##-#",
        "##+##+##",
    ],
    "sand": [
        "........",
        "...-....",
        "........",
        "......-.",
        ".-......",
        "........",
        "....-...",
        "........",
    ],
    "heart": [
        ".##..##.",
        "#--##--#",
        "#------#",
        "#------#",
        ".#----#.",
        "..#--#..",
        "...##...",
        "........",
    ],
    # A plank to land on, air underneath -- the Tower's bargain, on holiday.
    "plank": [
        "########",
        "#-+--+-#",
        "########",
        "+#....#+",
        "........",
        "........",
        "........",
        "........",
    ],
    "flag_top": [
        ".##.....",
        ".#+#....",
        ".#++##..",
        ".#++++#.",
        ".#+++#..",
        ".#+#....",
        ".##.....",
        ".##.....",
    ],
    "flag_base": [
        ".##.....",
        ".##.....",
        ".##.....",
        ".##.....",
        ".##.....",
        "###.....",
        "#+#.....",
        "###.....",
    ],
}

GREY = {".": 255, "-": 170, "+": 100, "#": 0}

ORDER8 = [
    "pineapple_top",
    "pineapple_body",
    "moai_head",
    "moai_base",
    "palm_crown",
    "palm_trunk",
    "cloud",
    "border",
    "sand",
    "heart",
    "plank",
    "flag_top",
    "flag_base",
]


def cut(grid):
    """A grid of arbitrary tile-multiple size into 8x8 tiles, reading order."""
    rows, cols = len(grid) // 8, len(grid[0]) // 8
    out = []
    for r in range(rows):
        for c in range(cols):
            out.append([grid[r * 8 + j][c * 8 : c * 8 + 8] for j in range(8)])
    return out


def write_png(path, tiles):
    width, height = 8 * len(tiles), 8
    rows = []
    for y in range(height):
        row = bytearray([0])
        for tile in tiles:
            for ch in tile[y]:
                row.append(GREY[ch])
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


def write_grid_png(path, grid):
    width, height = len(grid[0]), len(grid)
    rows = []
    for y in range(height):
        row = bytearray([0])
        for ch in grid[y]:
            row.append(GREY[ch])
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


# The portrait as its own PNG (the `picture` declaration reads it whole).
write_grid_png("games/art/moananas_face.png", PORTRAIT)

# The furniture sheet.
write_png("games/art/moananas.png", [TILES8[n] for n in ORDER8])

print(f"portrait 64x80 ({64 // 8}x{80 // 8} tiles), sheet {len(ORDER8)} tiles")
