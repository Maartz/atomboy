"""Moananas Island — the cartridge's whole tile sheet, composed here.

`tiles from:` reads one PNG per cartridge, so every tile the beach needs is
built in this file and laid end to end into `moananas_sheet.png`. Two kinds
of tile now, and the split is the lesson of three reworks:

- **Taken from SGQ_Dungeon, pixel for pixel.** The pack is *native* Game Boy
  art: every sheet is exactly four flat colours — #D4D29B, #78A46A, #5E8549,
  #584422 — with the artist's own one-pixel ink outlines already in place.
  Such art is not "adapted"; it is *mapped*, each colour to a shade, and
  arrives untouched. (The old pipeline levelled and re-outlined it as if it
  were a photograph, which is how gorgeous sprites came out as mush.) The
  sand, the plank, the boulder, the totem, the chest, the skull, the plant
  and the slime are all the artist's pixels.

- **Drawn here.** Sky, sun, sea, surf, clouds, the far island, the palm, the
  flag: the tropical things a dungeon pack does not have. They are ASCII,
  one character a pixel — `.` light, `-` shade 1, `+` mid, `#` ink — and
  they are *flat*. The panel's shade 0 and shade 1 are the same green
  (brightness 158 and 144 of 255), so structure is light against dark; and
  the ordered dither, which an earlier pass spread across every field until
  the screen was one texture, is demoted to what the hardware's games used
  it for: a strip of wet sand where the surf ends, nothing else. Flat
  fields, sparse specks, ink silhouettes — the way the console's own
  beaches were drawn.

The hero is Eris Esra's 16x16 template with Moananas painted on: the hair,
the glasses, the shirt. Sources, all licensed: SGQ_Dungeon by superdark,
Eris Esra's Character Template 4.

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
SGQ_INK = {(212, 210, 155): ".", (120, 164, 106): "-", (94, 133, 73): "+", (88, 68, 34): "#"}

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


# ── The sky ────────────────────────────────────────────────────────────────

SKY = drawn(*["." * 8] * 8)

# A ring, not a disc: on a plain sky the sun is what the light leaves out.
SUN = drawn(
    ".....++++.......",
    "...++....++.....",
    "..+........+....",
    ".+..........+...",
    ".+..........+...",
    "+............+..",
    "+............+..",
    "+............+..",
    "+............+..",
    "+............+..",
    "+............+..",
    ".+..........+...",
    ".+..........+...",
    "..+........+....",
    "...++....++.....",
    ".....++++.......",
)

# An outline and nothing inside it: on a light sky a cloud is a line the
# light stops at, which is how Super Mario Land drew them.
CLOUD = drawn(
    "......+++++..++++.......",
    "....++.....++....++.....",
    "..++...............++...",
    ".+....................+.",
    "+......................+",
    ".++++++++++++++++++++++.",
    "........................",
    "........................",
)

GULL = drawn(
    "........",
    "........",
    ".##..##.",
    "#..##..#",
    "........",
    "........",
    "........",
    "........",
)

# The island out at sea: a flat dark cone on the horizon, no weave.
ISLE = drawn(
    "..........##............",
    "........##++##..........",
    "......##++++++##........",
    "....##++++++++++##......",
    "..##++++++++++++++##....",
    ".#++++++++++++++++++#...",
    "#++++++++++++++++++++#..",
    "########################",
)

# ── The sea ────────────────────────────────────────────────────────────────
#
# A flat mid field under an ink horizon, and the glints are short: two or
# three pixels of light, staggered so no two tiles put them in the same
# place. The full-width streak was tried and it is not water, it is a
# barcode — a line that crosses every tile joins into a 256-pixel stripe.

SEA_CREST = drawn(
    "########",
    "++++++++",
    "++++++++",
    "++++++++",
    "+..+++++",
    "++++++++",
    "++++++++",
    "++++++++",
)

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

# Where the water ends: foam over the ink scallop, and one strip of woven
# wet sand under it — the single place the dither still lives, doing the
# job the hardware's games gave it: a transition, not a fill.
SURF_A = drawn(
    "++++++++",
    "++.++++.",
    ".+++..++",
    "##.####.",
    "+.+.+.+.",
    "........",
    "........",
    "........",
)

SURF_B = drawn(
    "++++++++",
    ".++++.++",
    "++..+++.",
    ".####.##",
    ".+.+.+.+",
    "........",
    "........",
    "........",
)

# ── The beach ──────────────────────────────────────────────────────────────
#
# Flat light, the same tile as the sky — the dark sea between them is what
# keeps them apart — with the artist's own shell-marks scattered through it.
# The two speck tiles are cut straight out of SGQ's sandy ground biome.

SAND_A = sgq("grounds_and_walls/grounds.png", 72, 214, 8, 8)
SAND_B = sgq("grounds_and_walls/grounds.png", 94, 212, 8, 8)

# The front face under the hero's feet: an ink crest, the light it catches,
# and a dark body with its own sparse marks — a block of ground the way
# Super Mario Land ruled one, not a checkerboard.
SAND = drawn(
    "########",
    "........",
    "++++++++",
    "++++++++",
    "+++..+++",
    "++++++++",
    "++++++++",
    "++++++++",
)

SAND_DEEP = drawn(
    "++++++++",
    "++##++++",
    "++++++++",
    "++++++#+",
    "+#++++++",
    "++++++++",
    "++++#+++",
    "++++++++",
)

# A board, landed on from above: its top edge is the tile's top edge, which
# is where `nrow * 8 - 16` puts the hero's feet. The ink lines run the full
# width, so three tiles in a row join into one continuous board — a slice of
# the pack's beam was tried first, and its end-grain repeated every eight
# pixels into a fence. Light body, two grain ticks, nothing else.
PLANK = drawn(
    "########",
    "........",
    ".++.....",
    ".....++.",
    "........",
    "########",
    "........",
    "........",
)

# ── The palm ───────────────────────────────────────────────────────────────
#
# Silhouette first: five drooping fronds in chunky ink arcs, the light
# notched along their tops. Two tiles deep, and it must read from across
# the room — the shrunken-ellipse trick read as a splat and is gone.

PALM_CROWN = drawn(
    "........######..........",
    "......##++++++##........",
    "....##++##..##++##......",
    "...#++##..##..##++#.....",
    "..#++#..##++##..#++#....",
    ".#++#..#+#++#+#..#++#...",
    ".#+#..#+##++##+#..#+#...",
    "#++#..##.#++#.##..#++#..",
    "#+#......#++#......#+#..",
    "##.......#++#.......##..",
    "..........#++#..........",
    "..........#++#..........",
    "..........#++#..........",
    "..........#++#..........",
    "..........#++#..........",
    "..........#++#..........",
)

PALM_TRUNK = drawn(
    "..#..#..",
    "..#.##..",
    "..#..#..",
    "..##.#..",
    "..#..#..",
    "..#.##..",
    "..#..#..",
    "..##.#..",
)

PALM_BASE = drawn(
    "..#..#..",
    "..#..#..",
    ".#..#.#.",
    ".#.#..#.",
    ".#....#.",
    "#..##..#",
    "#......#",
    "########",
)

# ── The flag ───────────────────────────────────────────────────────────────

FLAG_TOP = drawn(
    ".##.....",
    ".##++...",
    ".##++++.",
    ".##+++++",
    ".##++++.",
    ".##++...",
    ".##.....",
    ".##.....",
)

FLAG_BASE = drawn(
    ".##.....",
    ".##.....",
    ".##.....",
    ".##.....",
    ".##.....",
    ".##.....",
    "##..##..",
    "########",
)

# ── The props, straight from the pack ──────────────────────────────────────

ROCK = sgq("props/props.png", 0, 64, 16, 16)
PLANT = sgq("props/props.png", 32, 32, 16, 16)
SKULL = sgq("props/props.png", 0, 48, 16, 16)
CHEST = sgq("props/animated_props.png", 64, 0, 16, 16)

# The totem: the pack's gargoyle idol, sixteen by thirty-two, the beach's
# hazard. Dark wings and an ink outline against light sand — nobody will
# mistake it for a pineapple again. Its bottom two tiles keep the old
# `moai_base`/`moai_br` names, which is all the collision ever asks about.
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
#
# The pack's slime, two frames: round, and squashed against the sand. A
# sprite's shade 0 is its transparency, so the cream speckles ride at
# shade 1 on a mid body under the artist's own outline.

SLIME_A = sgq("characters/enemies/slime.png", 0, 0, 16, 16, cmap=SPRITE)
SLIME_B = sgq("characters/enemies/slime.png", 16, 0, 16, 16, cmap=SPRITE)

# ── The hero ───────────────────────────────────────────────────────────────
#
# The template banded, then Moananas painted on: hair over the crown and down
# the back, a bar of ink where the glasses sit, and the shirt. The spans are
# written in the frame's own coordinates; the walk's odd frames ride a pixel
# higher, so they take the same spans shifted up by one.

HAIR = [
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
GLASSES = [(4, 6, 10)]


def dress(grid, dy=0, head=9):
    """Moananas onto the template: hair, glasses, shirt, bare legs.

    Two features carry a caricature at this size and no more will fit: the
    hair, and the glasses. A goatee was drawn and cut — at sixteen pixels it
    joined the glasses into one black mask.
    """
    h, w = len(grid), len(grid[0])
    out = [row[:] for row in grid]

    for row, c0, c1 in HAIR + GLASSES:
        y = row + dy
        if 0 <= y < h:
            for x in range(c0, min(c1, w - 1) + 1):
                if out[y][x] != 0:
                    out[y][x] = 3

    # Shorts, and nothing else darkened: light body, ink outline, which is
    # what every character on this console was.
    for y in range(head + dy + 3, min(head + dy + 5, h)):
        for x in range(w):
            if out[y][x] == 1:
                out[y][x] = 2

    return out


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

# The stride frames are a pixel taller than the standing ones and sit a pixel
# higher in their cell, so they are read from 55 rather than 56: the crown
# stays in frame and the trailing foot's last pixel is what the window loses.
# The jump pose's head is drawn a row lower, hence its own offsets.
HERO_IDLE = dress(template_frames(ERIS + "16x16 Walk-Sheet.png", [0], 4, 56)[0])
HERO_STEP = dress(template_frames(ERIS + "16x16 Walk-Sheet.png", [1], 4, 55)[0])
HERO_JUMP = dress(
    template_frames(ERIS + "16x16 Jump-Sheet.png", [3], 4, 47)[0], dy=1, head=10
)


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
    ("sky", cut(SKY, "sky")),
    ("sun_tl sun_tr sun_bl sun_br", cut(SUN, "sun")),
    ("cloud_l cloud_m cloud_r", cut(CLOUD, "cloud")),
    ("gull", cut(GULL, "gull")),
    ("isle_l isle_m isle_r", cut(ISLE, "isle")),
    ("sea_crest", cut(SEA_CREST, "crest")),
    ("sea_a", cut(SEA_A, "sea a")),
    ("sea_b", cut(SEA_B, "sea b")),
    ("surf_a", cut(SURF_A, "surf a")),
    ("surf_b", cut(SURF_B, "surf b")),
    ("sand_a", cut(SAND_A, "sand a")),
    ("sand_b", cut(SAND_B, "sand b")),
    ("beach_sand", cut(SAND, "sand")),
    ("sand_deep", cut(SAND_DEEP, "sand deep")),
    ("plank", cut(PLANK, "plank")),
    ("palm_a palm_b palm_c palm_d palm_e palm_f", cut(PALM_CROWN, "palm")),
    ("trunk", cut(PALM_TRUNK, "trunk")),
    ("trunk_base", cut(PALM_BASE, "trunk base")),
    ("rock_tl rock_tr rock_bl rock_br", cut(ROCK, "rock")),
    ("plant_tl plant_tr plant_bl plant_br", cut(PLANT, "plant")),
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
    ("m1_tl m1_tr m1_bl m1_br", quads(HERO_IDLE)),
    ("m2_tl m2_tr m2_bl m2_br", quads(HERO_STEP)),
    ("m3_tl m3_tr m3_bl m3_br", quads(HERO_JUMP)),
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
