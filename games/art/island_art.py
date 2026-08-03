"""Moananas Island — the cartridge's whole tile sheet, composed here.

`tiles from:` reads one PNG per cartridge, so every tile the beach needs is
built in this file and laid end to end into `moananas_sheet.png`. Three kinds
of tile, three ways of making one:

- **Drawn here.** Sky, sea, sand, the plank, the palm, the flag: things that
  have to tile seamlessly against their own neighbours, where a pack asset
  cropped to 8x8 would show a seam. They are written as ASCII, one character
  a pixel: `.` white, `-` light, `+` mid, `#` ink.

- **Taken from a pack.** The rock, the bush, the driftwood, the moai: organic
  shapes nobody draws better by hand at this size. Each is cropped by its own
  bounding box (see `objects.py` for how they were found), resized, then
  banded — and banding is the whole trick. A pack asset is full colour; the
  console has four shades. Levelling each object against *its own* darkest and
  lightest pixel keeps its internal contrast, and forcing every pixel on the
  silhouette's rim to ink gives it the black outline that makes a Game Boy
  sprite read at all.

- **Dressed.** The hero is Eris Esra's 16x16 template — a clean cream body
  with an ink outline, which bands perfectly — with Moananas painted onto it:
  the long hair, the dark glasses, the shirt. The template gives the
  silhouette and the animation; the overlay gives the face.

Sources, all licensed for use: Eris Esra's Character Template 4, PineTrees
(Decorations) by toadzillart-style packs, SGQ_Dungeon by superdark, Moai.png.

Run from `games/art/`:

    python3 island_art.py

It writes `moananas_sheet.png` and prints the `names:` list to paste into
`games/moananas.exs` — the order here *is* the order there.
"""

import struct, subprocess, zlib

# ── Reading and banding ────────────────────────────────────────────────────

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


def luma(r, g, b):
    return (299 * r + 587 * g + 114 * b) // 1000


def band(w, h, px, outline=True, cuts=(0.34, 0.70), fill=0):
    """Auto-levelled three-ink banding, the silhouette's rim forced to ink.

    Levelling against the object's own range rather than absolute brightness
    is what keeps a pale rock from flattening into one shade; the rim pass is
    what keeps it from dissolving into the sky behind it.

    `fill` is what transparency becomes. Zero for a sprite, where shade 0 is
    the console's transparent colour. For a background object it must be the
    shade of whatever it stands on — the background layer has no transparency,
    so a rock cut out on 0 arrives in the game as a rock in a white box.
    """
    lums = [luma(*p[:3]) for p in px if p[3] >= 128]
    if not lums:
        return [fill] * (w * h)
    lo, hi = min(lums), max(lums)
    span = max(1, hi - lo)

    out = []
    for p in px:
        if p[3] < 128:
            out.append(fill)
            continue
        t = (luma(*p[:3]) - lo) / span
        out.append(3 if t < cuts[0] else 2 if t < cuts[1] else 1)

    if outline:
        for i, p in enumerate(px):
            if p[3] < 128:
                continue
            x, y = i % w, i // w
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if not (0 <= nx < w and 0 <= ny < h) or px[ny * w + nx][3] < 128:
                    out[i] = 3
                    break
    return out


def asset(src, crop=None, size=None, outline=True, cuts=(0.34, 0.70), fill=0):
    """A pack object, cropped and banded into a grid of shades."""
    args = ["magick", src]
    if crop:
        args += ["-crop", crop, "+repage"]
    if size:
        args += ["-resize", size]
    args += ["/tmp/island_stage.png"]
    subprocess.run(args, check=True)
    w, h, px = read_rgba("/tmp/island_stage.png")
    flat = band(w, h, px, outline, cuts, fill)
    return [flat[y * w : (y + 1) * w] for y in range(h)]


def drawn(*rows):
    """An ASCII block into a grid of shades."""
    width = len(rows[0])
    for i, row in enumerate(rows):
        assert len(row) == width, f"row {i} is {len(row)} wide, not {width}"
    return [[SHADES.index(c) for c in row] for row in rows]


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

# A ring, not a disc: on a white sky the sun is what the light leaves out.
SUN = drawn(
    ".....---........",
    "...--...--......",
    "..-.......-.....",
    ".-.........-....",
    "-...........-...",
    "-............-..",
    "-............-..",
    "-.............-.",
    "-.............-.",
    "-............-..",
    "-............-..",
    ".-...........-..",
    ".-..........-...",
    "..-........-....",
    "...--....--.....",
    ".....----.......",
)

# Filled, not outlined: an outline alone on a white sky is a wire, and from
# two feet away a wire is nothing.
CLOUD = drawn(
    "......----..............",
    "....--------...----.....",
    "..-------------------...",
    ".---------------------..",
    "-----------------------.",
    ".+++++++++++++++++++++..",
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

# The island out at sea: a volcano cone, its lee side in shadow, sitting on
# the horizon line the sea's top tile draws.
ISLE = drawn(
    "..........###...........",
    "........##---##.........",
    "......##--------##......",
    "....##-----++-----##....",
    "..##---------++-----##..",
    ".#------------+++-----#.",
    "#--------------++++----#",
    "########################",
)

# ── The sea ────────────────────────────────────────────────────────────────
#
# The texture runs the whole width of the tile, and the variation is between
# the *rows*, not along them. A mark that stops inside a tile repeats every
# eight pixels in both directions, and what the eye then reads is the grid,
# not the water. A line that crosses the whole tile joins its neighbours into
# one streak thirty-two tiles long, and streaks lying flat, at three different
# heights, are what water looks like from a beach.

SEA_CREST = drawn(
    "........",
    "........",
    "........",
    "########",
    "++++++++",
    "--------",
    "++++++++",
    "++++++++",
)

SEA_A = drawn(
    "++++++++",
    "++++++++",
    "--------",
    "++++++++",
    "++++++++",
    "++++++++",
    "--------",
    "++++++++",
)

SEA_B = drawn(
    "++++++++",
    "++++++++",
    "++++++++",
    "--------",
    "++++++++",
    "++++++++",
    "++++++++",
    "++++++++",
)

# Where the water ends: two tiles of foam so the shoreline breaks up rather
# than ruling a straight line across the whole island.
SURF_A = drawn(
    "++++++++",
    "++++++++",
    "++.+++.+",
    ".--..--.",
    "--------",
    "--------",
    "--------",
    "--------",
)

SURF_B = drawn(
    "++++++++",
    "+++++++.",
    "+.+++.++",
    "-..--..-",
    "--------",
    "--------",
    "--------",
    "--------",
)

# The beach going back: flat. A texture repeated over four rows and thirty-two
# columns is a grid whatever it is made of, and sand at a distance has none.
DUNE = drawn(*["-" * 8] * 8)

# ── The floor ──────────────────────────────────────────────────────────────
#
# One tile the whole island walks on, so `touching?` asks one question. The
# ink line on top and the bright line under it are the whole of the depth:
# the sand's crest catches the light, the body of it does not.

SAND = drawn(
    "########",
    "--------",
    "++++++++",
    "++++++++",
    "++++++++",
    "++++++++",
    "++++++++",
    "++++++++",
)

SAND_DEEP = drawn(*["+" * 8] * 8)

# A board, landed on from above: its top edge is the tile's top edge, which
# is where `nrow * 8 - 16` puts the hero's feet.
PLANK = drawn(
    "########",
    "-+-+-+-+",
    "+-++-+-+",
    "+-+-+--+",
    "########",
    "--------",
    "--------",
    "--------",
)

# ── The palm ───────────────────────────────────────────────────────────────

# A canopy, not a diagram of fronds. Eight pixels of height is not enough to
# draw seven separate leaves — drawn one by one they come out as a scribble of
# single-pixel lines. Drawn as one mass with the light notched out of its edge,
# it reads as a palm from across the room.
def palm_crown():
    """Five fronds, drawn four times too big and then shrunk onto the tiles.

    Drawn straight at 24x16 a frond is a one-pixel line, and five of them are
    a scribble. Drawn at 96x64 as five outlined lobes fanning off one point
    and then reduced, the shrink itself does the shading: what was a black
    stroke against a pale fill becomes ink, mid and light, and the palm
    arrives with the roundness nobody can place by hand at this size. The rim
    pass is off here — at this scale every pixel is near an edge, and forcing
    the rim would flatten the whole canopy back into one black mass.
    """
    fronds = [(-160, 32), (-122, 30), (-90, 28), (-58, 30), (-20, 32)]
    args = [
        "magick",
        "-size",
        "96x64",
        "xc:none",
        "-fill",
        "#b8b8b8",
        "-stroke",
        "#101010",
        "-strokewidth",
        "5",
    ]
    for angle, reach in fronds:
        args += [
            "-draw",
            f"translate 48,50 rotate {angle} ellipse {reach},0 {reach},10 0,360",
        ]
    args += ["/tmp/island_palm.png"]
    subprocess.run(args, check=True)
    return asset("/tmp/island_palm.png", None, "24x16!", outline=False, fill=1)


PALM_CROWN = palm_crown()

PALM_TRUNK = drawn(
    "--#--#--",
    "--#-##--",
    "--#--#--",
    "--##-#--",
    "--#--#--",
    "--#-##--",
    "--#--#--",
    "--##-#--",
)

PALM_BASE = drawn(
    "--#--#--",
    "--#--#--",
    "-#--#-#-",
    "-#-#--#-",
    "-#----#-",
    "#--##--#",
    "#------#",
    "########",
)

# ── The flag ───────────────────────────────────────────────────────────────

FLAG_TOP = drawn(
    "-##-----",
    "-##+++#-",
    "-##++++#",
    "-##+++#-",
    "-##++#--",
    "-##-----",
    "-##-----",
    "-##-----",
)

FLAG_BASE = drawn(
    "-##-----",
    "-##-----",
    "-##-----",
    "-##-----",
    "-##-----",
    "-##-----",
    "##--##--",
    "########",
)

# ── The pineapple and the heart ────────────────────────────────────────────

PINEAPPLE = drawn(
    "...##...",
    "..#-##..",
    ".##-#-#.",
    "..###...",
    ".######.",
    "#-#-#-#-",
    "#+-#-#-#",
    "#-#-#-#-",
    "#+-#-#-#",
    "#-#-#-#-",
    "#+-#-#-#",
    ".#-#-#-.",
    ".#+-#-#.",
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

# ── The hero ───────────────────────────────────────────────────────────────
#
# The template banded, then Moananas painted on: hair over the crown and down
# the back, a bar of ink where the glasses sit, the goatee, and the shirt.
# The spans are written in the frame's own coordinates; the walk's odd frames
# ride a pixel higher, so they take the same spans shifted up by one.

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

    # Below the head the cream becomes a shirt; below the shirt it is skin
    # again — he runs a beach, not a dungeon.
    for y in range(head + dy, min(head + dy + 4, h)):
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
    """A 16x16 hero frame into TL, TR, BL, BR — the order the game names."""
    return [
        [grid[j][0:8] for j in range(8)],
        [grid[j][8:16] for j in range(8)],
        [grid[8 + j][0:8] for j in range(8)],
        [grid[8 + j][8:16] for j in range(8)],
    ]


# ── The sheet ──────────────────────────────────────────────────────────────

PACK = {
    "rock": ("PineTrees/Decorations/Rocks.png", "26x26+3+83", "16x16!"),
    "bush": ("PineTrees/Decorations/Plants.png", "27x24+3+21", "16x16!"),
    "wood": ("PineTrees/Decorations/Woods.png", "30x15+65+7", "24x8!"),
    "moai": ("Moai.png", None, "16x16!"),
}


def pack(name):
    """A pack object as background decor: what surrounds it is the beach."""
    src, crop, size = PACK[name]
    return asset(src, crop, size, fill=1)


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
    ("dune", cut(DUNE, "dune")),
    ("beach_sand", cut(SAND, "sand")),
    ("sand_deep", cut(SAND_DEEP, "sand deep")),
    ("plank", cut(PLANK, "plank")),
    ("palm_a palm_b palm_c palm_d palm_e palm_f", cut(PALM_CROWN, "palm")),
    ("trunk", cut(PALM_TRUNK, "trunk")),
    ("trunk_base", cut(PALM_BASE, "trunk base")),
    ("rock_tl rock_tr rock_bl rock_br", cut(pack("rock"), "rock")),
    ("bush_tl bush_tr bush_bl bush_br", cut(pack("bush"), "bush")),
    ("wood_l wood_m wood_r", cut(pack("wood"), "wood")),
    ("moai_hl moai_hr moai_base moai_br", cut(pack("moai"), "moai")),
    ("flag_top", cut(FLAG_TOP, "flag top")),
    ("flag_base", cut(FLAG_BASE, "flag base")),
    ("heart", cut(HEART, "heart")),
    ("pineapple_top pineapple_body", cut(PINEAPPLE, "pineapple")),
    ("m1_tl m1_tr m1_bl m1_br", quads(HERO_IDLE)),
    ("m2_tl m2_tr m2_bl m2_br", quads(HERO_STEP)),
    ("m3_tl m3_tr m3_bl m3_br", quads(HERO_JUMP)),
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
    raw = b"".join(
        bytes([0]) + bytes(GREY[s] for s in row) for row in rows_of_shades
    )

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
