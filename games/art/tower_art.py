"""The Tower's sheet, second draft: a 16x16 hero and dressed-up tiles.

Original art throughout, in the late-era grammar: a closed black outline on
every silhouette, dark grey for the tunic mass, light grey for skin and
light, transparency only where the world should show through.

'.' = 255 (shade 0, transparent on sprites), '#' = 0, '+' = 100, '-' = 170.

The hero poses are 16x16, stored as four 8x8 tiles each in reading order
(TL, TR, BL, BR). The sheet is one row of 8x8 tiles; the game names them.
"""

import struct, zlib

# ── The hero, facing right ──────────────────────────────────────────────────

STAND = [
    "...########.....",
    "..#++++++++#....",
    ".#++++++++++#...",
    ".#++++++++++#...",
    ".############...",
    ".#----------#...",
    ".#-##----##-#...",
    ".#----------#...",
    "..#--------#....",
    "...########.....",
    "..#+++++++#.....",
    ".#-#++++++#-#...",
    "..##++++++##....",
    "....#+##+#......",
    "....#+##+#......",
    "...##....##.....",
]

STEP = [
    "...########.....",
    "..#++++++++#....",
    ".#++++++++++#...",
    ".#++++++++++#...",
    ".############...",
    ".#----------#...",
    ".#-##----##-#...",
    ".#----------#...",
    "..#--------#....",
    "...########.#...",
    "..#+++++++##....",
    ".#-#++++++#.....",
    "..##+++++##.....",
    "...#+##++#......",
    "..#+#...##+#....",
    ".##.......##....",
]

JUMP = [
    ".#..########..#.",
    "#-##++++++++##-#",
    "#-#++++++++++#-#",
    ".##++++++++++##.",
    ".############...",
    ".#----------#...",
    ".#-##----##-#...",
    ".#----------#...",
    "..#--------#....",
    "...########.....",
    "...#++++++#.....",
    "...#++++++#.....",
    "....#+##+#......",
    "...#+#..#+#.....",
    "...##....##.....",
    "................",
]

# ── The world's tiles, 8x8 each ─────────────────────────────────────────────

TILES8 = {
    # Brick courses: mortar every fourth row, joints staggered, a lit top
    # edge on each brick. Reads as masonry when tiled, not as scales.
    "brick": [
        "--------",
        "+##+####",
        "+##+####",
        "########",
        "----+---",
        "####+###",
        "####+###",
        "########",
    ],
    # A plank: a lit slab with grain, air underneath.
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
    # The flag, top half: the pennant flying off the pole.
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
    # The flag, bottom half: the pole into its base.
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
    # The back wall: the faintest masonry hint -- two strokes, offset, so
    # the tiling never reads as a grid.
    "backwall": [
        "........",
        "........",
        "........",
        "........",
        "........",
        ".....--.",
        "........",
        "........",
    ],
    # A slit window into the night.
    "window": [
        "..####..",
        ".#+++##.",
        ".#+##+#.",
        ".#+##+#.",
        ".#+##+#.",
        ".#++++#.",
        ".######.",
        "........",
    ],
}

GREY = {".": 255, "#": 0, "+": 100, "-": 170}


def quads(grid16):
    """A 16x16 grid into four 8x8 tiles, reading order."""
    tl = [row[:8] for row in grid16[:8]]
    tr = [row[8:] for row in grid16[:8]]
    bl = [row[:8] for row in grid16[8:]]
    br = [row[8:] for row in grid16[8:]]
    return [tl, tr, bl, br]


tiles = []
tiles += quads(STAND)  # 0..3
tiles += quads(STEP)  # 4..7
tiles += quads(JUMP)  # 8..11
for name in ["brick", "plank", "flag_top", "flag_base", "backwall", "window"]:
    tiles.append(TILES8[name])  # 12..17

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

with open("games/art/tower.png", "wb") as f:
    f.write(png)

print(f"games/art/tower.png -- {width}x{height}, {len(tiles)} tiles")
