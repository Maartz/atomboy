"""Moananas Island -- asset preparation.

Turns the licensed packs in this folder into the four-shade PNGs the game
reads. Two rules, one per kind:

- **Sprites** (hero, falling moai): banded by luma, but an opaque pixel never
  becomes shade 0 -- on the console shade 0 is transparent for sprites, and a
  cream face must not be a hole. Alpha is the only transparency.
- **Pictures** (decor): Bayer-dithered quantization, the same recipe as the
  portrait importer -- the dither carries shading into four colours.

Sources: SGQ_Dungeon by superdark (itch.io), Moai.png. Run from games/art/.
"""

import struct, subprocess, zlib

BAYER = [
    [0, 8, 2, 10],
    [12, 4, 14, 6],
    [3, 11, 1, 9],
    [15, 7, 13, 5],
]


def magick(args):
    subprocess.run(["magick"] + args, check=True)


def read_rgba(path):
    """Any image into an RGBA byte grid via a temporary PAM."""
    magick([path, "-depth", "8", "/tmp/prepare_rgba.pam"])
    data = open("/tmp/prepare_rgba.pam", "rb").read()
    head, raw = data.split(b"ENDHDR\n", 1)
    fields = dict(
        line.split(maxsplit=1)
        for line in head.decode().strip().split("\n")[1:]
        if " " in line
    )
    w, h = int(fields["WIDTH"]), int(fields["HEIGHT"])
    depth = int(fields["DEPTH"])
    pixels = []
    for i in range(w * h):
        chunk = raw[i * depth : (i + 1) * depth]
        if depth == 4:
            r, g, b, a = chunk
        elif depth == 3:
            r, g, b = chunk
            a = 255
        elif depth == 2:
            r = g = b = chunk[0]
            a = chunk[1]
        else:
            r = g = b = chunk[0]
            a = 255
        pixels.append((r, g, b, a))
    return w, h, pixels


def luma(r, g, b):
    return (299 * r + 587 * g + 114 * b) // 1000


def sprite_shades(w, h, pixels):
    """Alpha is transparency; opaque bands into the three ink shades only."""
    out = []
    for i, (r, g, b, a) in enumerate(pixels):
        if a < 128:
            out.append(0)
        else:
            y = luma(r, g, b)
            out.append(3 if y < 80 else 2 if y < 165 else 1)
    return out


def picture_shades(w, h, pixels, spread=0.5):
    """Bayer-dithered four levels; transparency reads as white."""
    out = []
    for i, (r, g, b, a) in enumerate(pixels):
        x, y = i % w, i // w
        v = 255 if a < 128 else luma(r, g, b)
        t = (BAYER[y % 4][x % 4] + 0.5) / 16.0 - 0.5
        q = round(v / 255 * 3 + t * spread * 2)
        out.append(3 - max(0, min(3, q)))
    return out


GREY = [255, 170, 100, 0]


def write_png(path, w, h, shades):
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            row.append(GREY[shades[y * w + x]])
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
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def sprite(src, dest, crop=None, resize=None):
    args = [src]
    if crop:
        args += ["-crop", crop, "+repage"]
    if resize:
        args += ["-filter", "point", "-resize", resize]
    args += ["/tmp/prepare_stage.png"]
    magick(args)
    w, h, pixels = read_rgba("/tmp/prepare_stage.png")
    write_png(dest, w, h, sprite_shades(w, h, pixels))
    print(f"{dest}: {w}x{h} sprite")


def picture(src, dest, crop=None, resize=None, spread=0.5):
    args = [src]
    if crop:
        args += ["-crop", crop, "+repage"]
    if resize:
        args += ["-resize", resize]
    args += ["/tmp/prepare_stage.png"]
    magick(args)
    w, h, pixels = read_rgba("/tmp/prepare_stage.png")
    write_png(dest, w, h, picture_shades(w, h, pixels, spread))
    print(f"{dest}: {w}x{h} picture")


# The hero: the SGQ elf's 3/4 walk row, four 16x16 frames side by side.
sprite("SGQ_Dungeon/characters/main/elf.png", "moananas_hero.png", crop="64x16+0+32")

# The falling moai: the statue's head only, averaged down then banded --
# a point-sampled shrink of the whole body was mush.
def sprite_soft(src, dest, crop=None, resize=None):
    args = [src]
    if crop:
        args += ["-crop", crop, "+repage"]
    if resize:
        args += ["-resize", resize]
    args += ["/tmp/prepare_stage.png"]
    magick(args)
    w, h, pixels = read_rgba("/tmp/prepare_stage.png")
    write_png(dest, w, h, sprite_shades(w, h, pixels))
    print(f"{dest}: {w}x{h} sprite (soft)")


sprite_soft("Moai.png", "moananas_moai16.png", crop="56x60+6+6", resize="16x16!")

# The big moai, beach decor: dithered, five tiles square.
picture("Moai.png", "moananas_moai_deco.png", resize="40x40!", spread=0.4)

# The sand: the speckled fill tile and a green-fringed surface tile from
# the SGQ ground block.
sprite(
    "SGQ_Dungeon/grounds_and_walls/grounds.png",
    "moananas_sand.png",
    crop="8x8+192+192",
)
sprite(
    "SGQ_Dungeon/grounds_and_walls/grounds.png",
    "moananas_sand_top.png",
    crop="8x8+96+192",
)


# ── The final sheet: furniture, the SGQ sand, then the hero's frames ────────
#
# `tiles` reads one PNG per cartridge, so everything is composed here into a
# single 8-tall strip. Each 16x16 hero frame contributes TL, TR, BL, BR in
# that order, so the game's names stay positional.


def tiles_of(path):
    w, h, pixels = read_rgba(path)
    cols, rows = w // 8, h // 8
    out = []
    for r in range(rows):
        for c in range(cols):
            tile = []
            for j in range(8):
                tile.append([pixels[(r * 8 + j) * w + c * 8 + i] for i in range(8)])
            out.append(tile)
    return out


def quads(path):
    """16x16 frames left to right into TL, TR, BL, BR tile runs."""
    w, h, pixels = read_rgba(path)
    out = []
    for f in range(w // 16):
        for ro, co in [(0, 0), (0, 8), (8, 0), (8, 8)]:
            tile = []
            for j in range(8):
                tile.append([pixels[(ro + j) * w + f * 16 + co + i] for i in range(8)])
            out.append(tile)
    return out


def shade_of(r, g, b, a):
    """Sprite rule again: opaque never lands on white."""
    if a < 128:
        return 255
    y = luma(r, g, b)
    if y in (0, 100, 170, 255):
        return y
    return 0 if y < 80 else 100 if y < 165 else 170


sheet = (
    tiles_of("moananas.png")
    + [tiles_of("moananas_sand.png")[0]]
    + quads("moananas_hero.png")
)

w = 8 * len(sheet)
rows = []
for j in range(8):
    row = bytearray([0])
    for tile in sheet:
        for r, g, b, a in tile[j]:
            row.append(shade_of(r, g, b, a))
    rows.append(bytes(row))

raw = b"".join(rows)


def chunk2(tag, data):
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data))
    )


png = b"\x89PNG\r\n\x1a\n"
png += chunk2(b"IHDR", struct.pack(">IIBBBBB", w, 8, 8, 0, 0, 0, 0))
png += chunk2(b"IDAT", zlib.compress(raw))
png += chunk2(b"IEND", b"")
open("moananas_sheet.png", "wb").write(png)
print(f"moananas_sheet.png: {len(sheet)} tiles")
