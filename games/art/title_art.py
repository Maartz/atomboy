"""Moananas Island — the cover, imported against the panel's own ramp.

    python3 title_art.py        # writes moananas_title.png

`moananas_source.jpg` is a full-colour illustration; the cover is 160x144 in
four shades. What sits between them is one decision, and getting it wrong is
what made the first cover flat.

The obvious import bands brightness into four even steps. The DMG's four
shades are not even steps. In brightness they are

    shade 0  158      shade 2  77
    shade 1  144      shade 3  39

— shade 0 and shade 1 are fourteen apart out of two hundred and fifty-five,
which is to say they are the same green. A drawing modelled in 0 and 1
arrives on the panel as a flat cutout, so only the three levels the hardware
can tell apart are used here.

The second decision is not to dither, and it goes against the instinct. A
dither is how this console makes a tone out of two shades, and it is right
for a photograph. This is not a photograph — it is line art with flat fills,
and a dither laid over a flat fill eats the lines that were the drawing. It
was tried: the face came out a chequered mask with the eyes gone. Three flat
levels keep every line the illustrator drew.

So the cuts are set by hand rather than by nearest neighbour. The face's
green sits within a hair of the midpoint between 158 and 77, and nearest
neighbour drops it to the dark side — a caricature whose face and hair are
the same colour. The cut is put below it instead, and the face stays light,
as it is in the drawing.

The source is levelled onto the panel's range first: the illustration is
bright green throughout and would otherwise land entirely in the top level.

The third decision is to clean the paper, and it is about the *dedup*, not
the drawing. `screen` folds the cover into the tile budget by likeness, and
a three-pixel fleck on white paper is a summed distance of nine — inside
any useful tolerance. Every paper tile with a different fleck therefore
merges with the clean ones, one representative gets elected, and whatever
mark it carried is stamped across the whole page: the dash-grid the first
build shipped. So every dark cluster of a few pixels is returned to paper,
and the two bands of micro-text (the credit line, the hand-drawn PRESS
START) are erased outright — type that small cannot survive 160x144, and
the kernel's own font redraws the words that matter.
"""

import struct, subprocess, zlib

SOURCE = "moananas_source.jpg"
DEST = "moananas_title.png"
WIDTH, HEIGHT = 160, 144

# The shades the panel can be told apart by, and how bright each one is.
LEVELS = [(0, 158), (2, 77), (3, 39)]

# Where one becomes the next, on the levelled scale. Not the midpoints.
CUTS = (105, 58)

# What `Potion.Tiles.shade` reads a shade back out of: it bands absolute
# brightness in quarters, so each shade is written as a grey inside its band.
GREY = {0: 255, 1: 170, 2: 100, 3: 0}

def read_rgb(path, size):
    subprocess.run(
        ["magick", path, "-resize", size, "-depth", "8", "/tmp/title_rgb.pam"],
        check=True,
    )
    data = open("/tmp/title_rgb.pam", "rb").read()
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
        px.append((c[0], c[1], c[2]) if depth >= 3 else (c[0], c[0], c[0]))
    return w, h, px


def luma(r, g, b):
    return (299 * r + 587 * g + 114 * b) // 1000


def levelled(values):
    """The illustration's own range stretched onto the panel's.

    The white point is the *paper* — the commonest brightness in the top half
    of the image — and not the brightest pixel in it. Taken from the top of
    the range instead, the paper lands a hair under shade 0 and every pixel
    of it dithers: a page of speckle where there should be a page. Anything
    at or above the paper clamps flat.
    """
    ordered = sorted(values)
    lo = ordered[len(ordered) * 2 // 100]
    upper = ordered[len(ordered) // 2 :]
    hi = max(set(upper), key=upper.count)
    span = max(1, hi - lo)
    floor, ceiling = LEVELS[-1][1], LEVELS[0][1]

    return [
        floor + (ceiling - floor) * min(max(v - lo, 0), span) // span for v in values
    ]


def quantized(target):
    """The shade this brightness becomes."""
    if target > CUTS[0]:
        return 0
    if target > CUTS[1]:
        return 2
    return 3


def write_png(path, w, h, shades):
    raw = b"".join(
        bytes([0]) + bytes(GREY[s] for s in shades[y * w : (y + 1) * w])
        for y in range(h)
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


# The bands of type too small to survive the import, x0..x1 by y0..y1.
# The kernel's font redraws PRESS START at (5, 13); the credit line goes.
ERASED = [(64, 80, 152, 95), (72, 97, 144, 112)]


def despeckled(shades, w, h, limit=4):
    """Dark clusters of `limit` pixels or fewer, returned to paper.

    Each one is a legitimate fleck of the illustration, and each one is
    also within dedup tolerance of clean paper — which is how one elected
    tile stamped its fleck across the whole page.
    """
    out = shades[:]
    seen = [False] * (w * h)
    for start in range(w * h):
        if seen[start] or out[start] == 0:
            continue
        stack, blob = [start], []
        seen[start] = True
        while stack:
            i = stack.pop()
            blob.append(i)
            x, y = i % w, i // w
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                j = ny * w + nx
                if 0 <= nx < w and 0 <= ny < h and not seen[j] and out[j] != 0:
                    seen[j] = True
                    stack.append(j)
        if len(blob) <= limit:
            for i in blob:
                out[i] = 0
    return out


w, h, px = read_rgb(SOURCE, f"{WIDTH}x{HEIGHT}!")
targets = levelled([luma(*p) for p in px])
shades = [quantized(t) for t in targets]

for x0, y0, x1, y1 in ERASED:
    for y in range(y0, y1):
        for x in range(x0, x1):
            shades[y * w + x] = 0

shades = despeckled(shades, w, h)

# The last pass works at the dedup's own granularity, because the dashes it
# stamped across the page were never flecks — they were *tiles*. The
# illustration's dotted border quantizes to tiles whose whole deviation from
# blank paper is sixteen or twenty, inside the cartridge's tolerance of 22,
# and `screen` elects the first such tile in reading order as the
# representative for every clean paper tile behind it. So any tile that is
# almost paper becomes paper exactly, and a true blank wins the election.
SNAP = 24  # a shade past the cartridge's tolerance

for ty in range(HEIGHT // 8):
    for tx in range(WIDTH // 8):
        cells = [(ty * 8 + j) * w + tx * 8 + i for j in range(8) for i in range(8)]
        if 0 < sum(shades[i] for i in cells) <= SNAP:
            for i in cells:
                shades[i] = 0

write_png(DEST, w, h, shades)

counts = {s: shades.count(s) for s in sorted(set(shades))}
print(f"{DEST}: {w}x{h}, shades used {counts}")
