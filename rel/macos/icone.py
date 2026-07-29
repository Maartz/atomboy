#!/usr/bin/env python3
"""L'icône d'atomboy : une Game Boy en pixel-art, construite en 32x32 puis
agrandie au plus proche voisin — le pixel net est le style de la maison.

Usage : icone.py sortie.icns   (nécessite iconutil, présent sur macOS)
"""
import subprocess
import sys
import tempfile
import zlib
import struct
import os

CONTOUR = (0x2A, 0x2A, 0x33)
BOITIER = (0xC5, 0xC0, 0xCE)
OMBRE = (0x8F, 0x8A, 0x9C)
DALLE = (0x8B, 0xAC, 0x0F)
PIXELS = (0x0F, 0x38, 0x0F)
BOUTON = (0x9E, 0x2A, 0x4E)

# Le A de la police du menu — 5x7, bit 4 à gauche.
LETTRE_A = [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11]


def grille():
    g = [[None] * 32 for _ in range(32)]

    def rect(x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                g[y][x] = c

    # Le boîtier, son contour, son ombre portée (droite et bas).
    rect(2, 1, 27, 29, CONTOUR)
    rect(3, 2, 26, 28, BOITIER)
    rect(4, 28, 26, 28, OMBRE)
    rect(26, 3, 26, 28, OMBRE)
    # Coins adoucis.
    for x, y in [(2, 1), (27, 1), (2, 29), (27, 29)]:
        g[y][x] = None

    # L'écran : lunette sombre, dalle verte, le A d'atomboy en pixels.
    rect(5, 4, 22, 15, PIXELS)
    rect(7, 6, 20, 13, DALLE)
    for dy, rangée in enumerate(LETTRE_A):
        for dx in range(5):
            if (rangée >> (4 - dx)) & 1:
                g[6 + dy][11 + dx] = PIXELS

    # La croix.
    rect(5, 20, 9, 21, CONTOUR)
    rect(6, 19, 8, 22, CONTOUR)

    # A et B, en diagonale comme il se doit.
    rect(21, 18, 22, 19, BOUTON)
    rect(17, 20, 18, 21, BOUTON)

    # Start/Select, et la grille du haut-parleur en diagonales.
    rect(9, 25, 11, 25, OMBRE)
    rect(13, 25, 15, 25, OMBRE)
    for i in range(4):
        g[26 - i][20 + i] = OMBRE
        if 22 + i <= 25:
            g[26 - i][22 + i] = OMBRE

    return g


def png(path, taille):
    g = grille()
    rows = b""
    for y in range(taille):
        row = b"\x00"
        for x in range(taille):
            # Au plus proche voisin, dans les deux sens — 16 px comme 1024.
            c = g[y * 32 // taille][x * 32 // taille]
            row += bytes(c) + b"\xff" if c else b"\x00\x00\x00\x00"
        rows += row

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", taille, taille, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows))
            + chunk(b"IEND", b"")
        )


def main(sortie):
    with tempfile.TemporaryDirectory() as tmp:
        jeu = os.path.join(tmp, "atomboy.iconset")
        os.mkdir(jeu)
        for nom, taille in [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]:
            png(os.path.join(jeu, nom), taille)
        subprocess.run(["iconutil", "-c", "icns", jeu, "-o", sortie], check=True)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Atomboy.icns")
