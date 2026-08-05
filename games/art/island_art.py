"""Moananas Island — the cartridge's whole tile sheet, composed here.

`tiles from:` reads one PNG per cartridge, so every tile the island needs is
built in this file and laid end to end into `moananas_sheet.png`. Two kinds
of tile, and one rule above both: **the view is from above.** SGQ_Dungeon is
a top-down tileset — the idol stands in its vasque, the chest is seen at
three-quarters, the ground is a floor — and for two reworks its sprites were
pasted into a side-scrolling composition where they could only ever look
glued on. The game now looks down at the island the way the pack looks down
at its dungeon, and every asset stands in the world it was drawn for.

- **Taken from SGQ_Dungeon, pixel for pixel.** The pack is native Game Boy
  art: exactly four flat colours — #D4D29B, #78A46A, #5E8549, #584422 —
  under the artist's own one-pixel ink outlines. Such art is not "adapted";
  it is *mapped*, each colour to a shade, and arrives untouched. The sand
  specks, the dock plank, the boulder, the totem, the chest, the skull, the
  palm-from-above (the pack's starburst plant) and the slime are all the
  artist's pixels.

- **Drawn here.** The water and the shoreline: flat mid sea with short
  staggered glints, and a ring of shore tiles — ink waterline, one strip of
  wet-sand dither — that turns the sand into an island. Flat fields, sparse
  specks, ink silhouettes; the dither is a transition, never a fill. (The
  panel's shade 0 and shade 1 are the same green — brightness 158 and 144
  of 255 — so nothing carries a shape on that pair.)

The hero is Eris Esra's 16x16 template, which walks in five directions;
down, side and up are taken, and Moananas is painted onto each facing: the
long hair, the glasses, the shirt. Sources, all licensed: SGQ_Dungeon by
superdark, Eris Esra's Character Template 4.

Run from `games/art/`:

    python3 island_art.py

It writes `moananas_sheet.png` and prints the `names:` list to paste into
`games/moananas.exs` — the order here *is* the order there.
"""

import struct, subprocess, zlib

SHADES = ".-+#"


def read_rgba(path):
    """Any image into an RGBA pixel list via a temporary PAM."""
    subprocess.run(["magick", path, "-depth", "8", "/tmp/island_rgba.pam"], check=True)
    data = open("/tmp/island_rgba.pam", "rb").read()
    head, raw = data.split(b"ENDHDR\n", 1)
    fields = dict(
        line.split(maxsplit=1)
        for line in head.decode().strip().split("\n")[1:]
        if " " in line
    )
    w, h, depth = int(fields["WIDTH"]), int(fields["HEIGHT"]), int(fields["DEPTH"])
    px = []
    for i in range(w * h):
        c = raw[i * depth : (i + 1) * depth]
        if depth == 4:
            px.append(tuple(c))
        elif depth == 3:
            px.append((c[0], c[1], c[2], 255))
        elif depth == 2:
            px.append((c[0], c[0], c[0], c[1]))
        else:
            px.append((c[0], c[0], c[0], 255))
    return w, h, px


# ── SGQ_Dungeon, mapped ────────────────────────────────────────────────────
#
# The pack's four colours, brightest to darkest. A background object maps
# cream to the light and both greens to the mid — the panel cannot tell two
# mid-greens apart any better than it tells its own shades 0 and 1 — and a
# sprite maps cream to shade 1, the only light a sprite has, shade 0 being
# its transparency.

SGQ = "SGQ_Dungeon/"
SGQ_INK = {
    (212, 210, 155): ".",
    (120, 164, 106): "-",
    (94, 133, 73): "+",
    (88, 68, 34): "#",
}

BG = {".": 0, "-": 2, "+": 3, "#": 3}
SPRITE = {".": 1, "-": 2, "+": 3, "#": 3}


def sgq(src, x0, y0, w, h, cmap=BG, fill=0):
    """A window of an SGQ sheet, each colour to its shade, nothing else done."""
    sw, sh, px = read_rgba(SGQ + src)
    grid = []
    for y in range(h):
        row = []
        for x in range(w):
            r, g, b, a = px[(y0 + y) * sw + x0 + x]
            row.append(fill if a < 128 else cmap[SGQ_INK[(r, g, b)]])
        grid.append(row)
    return grid


def luma(r, g, b):
    return (299 * r + 587 * g + 114 * b) // 1000


def drawn(*rows):
    """An ASCII block into a grid of shades: `.` `-` `+` `#`."""
    width = len(rows[0])
    grid = []
    for y, row in enumerate(rows):
        assert len(row) == width, f"row {y} is {len(row)} wide, not {width}"
        grid.append([SHADES.index(c) for c in row])
    return grid


def cut(grid, name):
    """A grid into 8x8 tiles, reading order, with its names."""
    h, w = len(grid), len(grid[0])
    assert w % 8 == 0 and h % 8 == 0, f"{name} is {w}x{h}"
    tiles = []
    for ty in range(h // 8):
        for tx in range(w // 8):
            tiles.append([grid[ty * 8 + j][tx * 8 : tx * 8 + 8] for j in range(8)])
    return tiles


# ── The ground and the water ───────────────────────────────────────────────

SAND = drawn(*["." * 8] * 8)

# Flat mid water; the glints are short — two or three pixels of light,
# staggered so no two tiles put them in the same place. A line that crosses
# a whole tile joins its neighbours into a 256-pixel stripe, which is a
# barcode and not the sea.
SEA_A = drawn(
    "++++++++",
    "++...+++",
    "++++++++",
    "++++++++",
    "++++++++",
    "+++++..+",
    "++++++++",
    "++++++++",
)

SEA_B = drawn(
    "++++++++",
    "++++++++",
    "++++++++",
    "...+++++",
    "++++++++",
    "++++++++",
    "++++..++",
    "++++++++",
)

# The shell-marks, cut straight out of SGQ's sandy ground biome.
SAND_A = sgq("grounds_and_walls/grounds.png", 72, 214, 8, 8)
SAND_B = sgq("grounds_and_walls/grounds.png", 94, 212, 8, 8)

# ── The shoreline ──────────────────────────────────────────────────────────
#
# The ring that makes the sand an island: water, a fleck of foam, the ink
# waterline, one strip of wet-sand dither — the only dither on the map,
# doing what the hardware's own games used it for — then dry sand. One edge
# is drawn; the other seven are its flips and transposes, and the corners
# are stitched along the diagonal.

SHORE_N = drawn(
    "++++++++",
    "++++++++",
    "+.++++.+",
    "########",
    "+.+.+.+.",
    "........",
    "........",
    "........",
)


def flip_v(g):
    return [row[:] for row in reversed(g)]


def flip_h(g):
    return [list(reversed(row)) for row in g]


def transpose(g):
    return [[g[x][y] for x in range(8)] for y in range(8)]


SHORE_S = flip_v(SHORE_N)
SHORE_W = transpose(SHORE_N)
SHORE_E = flip_h(SHORE_W)
SHORE_NW = [
    [SHORE_W[y][x] if x < y else SHORE_N[y][x] for x in range(8)] for y in range(8)
]
SHORE_NE = flip_h(SHORE_NW)
SHORE_SW = flip_v(SHORE_NW)
SHORE_SE = flip_h(SHORE_SW)

# A dock board, walked along from above: ink rails the full width, so the
# tiles join into one boardwalk over the water.
PLANK = drawn(
    "########",
    "........",
    ".++.....",
    "........",
    ".....++.",
    "........",
    "########",
    "++++++++",
)

# ── The flag ───────────────────────────────────────────────────────────────
#
# It flies at the end of the dock, so its tiles are the flag *over* the
# plank: everywhere the flag has nothing, the boardwalk shows through —
# a flag on its own light square punched a hole in the dock.


def over(base, top):
    return [[t if t else b for b, t in zip(br, tr)] for br, tr in zip(base, top)]


FLAG_TOP = over(
    PLANK,
    drawn(
        ".##.....",
        ".##++...",
        ".##++++.",
        ".##+++++",
        ".##++++.",
        ".##++...",
        ".##.....",
        ".##.....",
    ),
)

FLAG_BASE = over(
    PLANK,
    drawn(
        ".##.....",
        ".##.....",
        ".##.....",
        ".##.....",
        ".##.....",
        ".##.....",
        "##..##..",
        "########",
    ),
)

# ── The props, straight from the pack ──────────────────────────────────────

ROCK = sgq("props/props.png", 0, 64, 16, 16)
PALM = sgq("props/props.png", 32, 32, 16, 16)
SKULL = sgq("props/props.png", 0, 48, 16, 16)
CHEST = sgq("props/animated_props.png", 64, 0, 16, 16)

# The totem: the pack's gargoyle idol, sixteen by thirty-two, drawn by its
# artist for exactly this view — a tall thing seen from above, standing in
# its vasque. Its bottom two tiles keep the `moai_base`/`moai_br` names,
# which is all the collision ever asks about.
TOTEM = sgq("props/animated_props.png", 112, 16, 16, 32)

# ── The pineapple and the heart ────────────────────────────────────────────

PINEAPPLE = drawn(
    "...##...",
    "..#-##..",
    ".##-#-#.",
    "..####..",
    ".######.",
    "#------#",
    "#-#--#-#",
    "#------#",
    "#--#-#--",
    "#------#",
    "#-#--#-#",
    ".#----#.",
    ".#-##-#.",
    "..####..",
    "........",
    "........",
)

HEART = drawn(
    ".##..##.",
    "#--##--#",
    "#------#",
    "#------#",
    ".#----#.",
    "..#--#..",
    "...##...",
    "........",
)

# ── The slime ──────────────────────────────────────────────────────────────

SLIME_A = sgq("characters/enemies/slime.png", 0, 0, 16, 16, cmap=SPRITE)
SLIME_B = sgq("characters/enemies/slime.png", 16, 0, 16, 16, cmap=SPRITE)

# ── The hero ───────────────────────────────────────────────────────────────
#
# The template's walk sheet holds five facings in rows of four frames; the
# down row starts at 8, the side row at 56, the up row at 104, and each
# row's odd frames are drawn a pixel taller, so they are read a pixel
# higher. Moananas is painted onto each facing separately — the same hair
# and glasses land on different pixels when the head turns.


def spans(grid, marks, shorts):
    """Ink the marked spans where the template has body, then the shorts."""
    h, w = len(grid), len(grid[0])
    out = [row[:] for row in grid]

    for row, c0, c1 in marks:
        if 0 <= row < h:
            for x in range(c0, min(c1, w - 1) + 1):
                if out[row][x] != 0:
                    out[row][x] = 3

    for y in shorts:
        if 0 <= y < h:
            for x in range(w):
                if out[y][x] == 1:
                    out[y][x] = 2

    return out


# Side: hair over the crown and down the back, the glasses a bar of ink.
SIDE_HAIR = [
    (0, 4, 11),
    (1, 3, 12),
    (2, 3, 5),
    (3, 3, 4),
    (4, 3, 4),
    (5, 3, 4),
    (6, 3, 4),
    (7, 3, 4),
    (8, 4, 5),
    (9, 4, 6),
    (10, 4, 5),
]
SIDE_GLASSES = [(4, 6, 10)]

# Down: the crown, the hair falling past both cheeks, and the glasses as a
# brow-bar over the top of the template's own eyes.
DOWN_HAIR = (
    [(0, 3, 12), (1, 3, 12), (2, 3, 12)]
    + [(r, 3, 4) for r in (3, 4)]
    + [(r, 11, 12) for r in (3, 4)]
    + [(r, 2, 3) for r in (5, 6, 7, 8)]
    + [(r, 12, 13) for r in (5, 6, 7, 8)]
    + [(9, 3, 4), (9, 11, 12)]
)
DOWN_GLASSES = [(5, 4, 11)]

# Up: the back of the head is nothing but hair, down to the shoulders.
UP_HAIR = [(r, 2, 13) for r in range(0, 10)] + [(10, 5, 10)]


def dress_side(grid):
    return spans(grid, SIDE_HAIR + SIDE_GLASSES, (12, 13))


def dress_down(grid):
    return spans(grid, DOWN_HAIR + DOWN_GLASSES, (12, 13))


def dress_up(grid):
    return spans(grid, UP_HAIR, (12, 13))


def template_frames(sheet, cells, ox, oy, pitch=24):
    """16x16 windows out of an Eris sheet, banded to the console's shades."""
    w, h, px = read_rgba(sheet)
    frames = []
    for cell in cells:
        grid = []
        for y in range(16):
            row = []
            for x in range(16):
                r, g, b, a = px[(oy + y) * w + ox + cell * pitch + x]
                if a < 128:
                    row.append(0)
                else:
                    v = luma(r, g, b)
                    row.append(3 if v < 90 else 2 if v < 175 else 1)
            grid.append(row)
        frames.append(grid)
    return frames


ERIS = "Eris Esra's Character Template 4/16x16/"
WALK = ERIS + "16x16 Walk-Sheet.png"

HERO_D1 = dress_down(template_frames(WALK, [0], 4, 8)[0])
HERO_D2 = dress_down(template_frames(WALK, [1], 4, 7)[0])
HERO_S1 = dress_side(template_frames(WALK, [0], 4, 56)[0])
HERO_S2 = dress_side(template_frames(WALK, [1], 4, 55)[0])
HERO_U1 = dress_up(template_frames(WALK, [0], 4, 104)[0])
HERO_U2 = dress_up(template_frames(WALK, [1], 4, 103)[0])


def quads(grid):
    """A 16x16 frame into TL, TR, BL, BR — the order the game names."""
    return [
        [grid[j][0:8] for j in range(8)],
        [grid[j][8:16] for j in range(8)],
        [grid[8 + j][0:8] for j in range(8)],
        [grid[8 + j][8:16] for j in range(8)],
    ]


# ── The sheet ──────────────────────────────────────────────────────────────

SHEET = [
    ("sky", cut(SAND, "sand")),
    ("sea_a", cut(SEA_A, "sea a")),
    ("sea_b", cut(SEA_B, "sea b")),
    ("shore_n", cut(SHORE_N, "shore n")),
    ("shore_s", cut(SHORE_S, "shore s")),
    ("shore_w", cut(SHORE_W, "shore w")),
    ("shore_e", cut(SHORE_E, "shore e")),
    ("shore_nw", cut(SHORE_NW, "shore nw")),
    ("shore_ne", cut(SHORE_NE, "shore ne")),
    ("shore_sw", cut(SHORE_SW, "shore sw")),
    ("shore_se", cut(SHORE_SE, "shore se")),
    ("sand_a", cut(SAND_A, "sand a")),
    ("sand_b", cut(SAND_B, "sand b")),
    ("plank", cut(PLANK, "plank")),
    ("rock_tl rock_tr rock_bl rock_br", cut(ROCK, "rock")),
    ("palm_tl palm_tr palm_bl palm_br", cut(PALM, "palm")),
    ("skull_tl skull_tr skull_bl skull_br", cut(SKULL, "skull")),
    ("chest_tl chest_tr chest_bl chest_br", cut(CHEST, "chest")),
    (
        "totem_a totem_b totem_c totem_d totem_e totem_f moai_base moai_br",
        cut(TOTEM, "totem"),
    ),
    ("flag_top", cut(FLAG_TOP, "flag top")),
    ("flag_base", cut(FLAG_BASE, "flag base")),
    ("heart", cut(HEART, "heart")),
    ("pineapple_top pineapple_body", cut(PINEAPPLE, "pineapple")),
    ("md1_tl md1_tr md1_bl md1_br", quads(HERO_D1)),
    ("md2_tl md2_tr md2_bl md2_br", quads(HERO_D2)),
    ("ms1_tl ms1_tr ms1_bl ms1_br", quads(HERO_S1)),
    ("ms2_tl ms2_tr ms2_bl ms2_br", quads(HERO_S2)),
    ("mu1_tl mu1_tr mu1_bl mu1_br", quads(HERO_U1)),
    ("mu2_tl mu2_tr mu2_bl mu2_br", quads(HERO_U2)),
    ("sl1_tl sl1_tr sl1_bl sl1_br", quads(SLIME_A)),
    ("sl2_tl sl2_tr sl2_bl sl2_br", quads(SLIME_B)),
]

tiles = []
names = []
for label, group in SHEET:
    got = label.split()
    assert len(got) == len(group), f"{label}: {len(got)} names, {len(group)} tiles"
    tiles += group
    names += got

GREY = [255, 170, 100, 0]


def write_png(path, w, h, rows_of_shades):
    raw = b"".join(bytes([0]) + bytes(GREY[s] for s in row) for row in rows_of_shades)

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data))
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


rows = [[s for tile in tiles for s in tile[j]] for j in range(8)]
write_png("moananas_sheet.png", 8 * len(tiles), 8, rows)

print(f"moananas_sheet.png: {len(tiles)} tiles")
print("\n          names: [")
for i in range(0, len(names), 4):
    print("            " + ", ".join(":" + n for n in names[i : i + 4]) + ",")
print("          ]")
