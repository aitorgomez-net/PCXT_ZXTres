#!/usr/bin/env python3
"""Build the ZXTRES+ boot splash from the MiSTer one.

  make_splash.py

Reads SW/splash_320x200_source.png and redraws the striped, slanted "MiSTer"
beside the PCXT title as "ZXTres", in the same lettering: ten stripes on
every other line, 8-pixel strokes, the slant of the original. T, r and e are
taken from the original word; Z, X and s are drawn here. As in the PCAT-286
ZXTres splash, the top stripes are white and the rest yellow.

Writes zxtres/splash/splash_320x200.png (the picture, 320x200),
zxtres/splash/splash_320x200_preview.png (at 4:3, as a monitor shows it) and
the ROM image zxtres/splash/splash_320x200.hex, which has the same format as
SW/make_splash_rom.py writes: two 4-bit RGBI pixels per byte, the left one in
bits 7:4. build_pcxt.sh uses it in place of rtl/video/splash_320x200.hex.
"""
from pathlib import Path
import sys

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'SW'))
from make_splash_rom import PALETTE, nearest_colour  # noqa: E402

SOURCE = ROOT / 'SW' / 'splash_320x200_source.png'
OUT = ROOT / 'zxtres' / 'splash'
WIDTH, HEIGHT = 320, 200

X0, Y0 = 180, 19            # left edge of the area, first stripe of the word
STRIPES = 10                # one on every other line, Y0 to Y0 + 18
AREA = 130                  # columns from X0 that hold the word
YELLOW, WHITE, BLACK = 14, 15, 0
# Slant: shift of each stripe, top to bottom, measured on the left edge of
# the M. Column c of the upright letters is at X0 + c + SLANT[k].
SLANT = (5, 5, 4, 4, 3, 3, 2, 2, 1, 0)
INK = (WHITE, WHITE) + (YELLOW,) * 8

DRAWN = {
    # Capitals use all ten stripes; the lower case s uses the last eight, as
    # the original e and r do.
    'Z': ['###################',
          '###################',
          '...........########',
          '.........########..',
          '.......########....',
          '.....########......',
          '...########........',
          '.########..........',
          '###################',
          '###################'],
    'X': ['########....########',
          '.########..########.',
          '..#######..#######..',
          '....############....',
          '.....##########.....',
          '.....##########.....',
          '....############....',
          '..#######..#######..',
          '.########..########.',
          '########....########'],
    's': ['................',
          '................',
          '...#############',
          '.###############',
          '#######.........',
          '##############..',
          '..##############',
          '.........#######',
          '###############.',
          '############....'],
}
TAKEN = {'T': (68, 86), 'e': (87, 103), 'r': (106, 120)}   # upright columns in "MiSTer"
WORD = (('Z', 7), ('X', 28), ('T', 50), ('r', 70), ('e', 86), ('s', 104))   # letter, first column


def main():
    image = Image.open(SOURCE).convert('RGB')
    if image.size != (WIDTH, HEIGHT):
        raise SystemExit(f'{SOURCE}: expected {WIDTH}x{HEIGHT}')
    pixels = [[nearest_colour(image.getpixel((x, y))) for x in range(WIDTH)] for y in range(HEIGHT)]

    def upright(k, c):
        return X0 + c + SLANT[k], Y0 + 2 * k

    glyphs = dict(DRAWN)
    for letter, (first, last) in TAKEN.items():
        glyphs[letter] = [''.join('#' if pixels[upright(k, c)[1]][upright(k, c)[0]] == YELLOW else '.'
                                  for c in range(first, last + 1)) for k in range(STRIPES)]

    # Remove the old word, which lies on black: its stripes, a drop below the
    # hook of the r on line 28, and a grey edge pixel of the e.
    for y in range(Y0, Y0 + 2 * STRIPES):
        for x in range(X0, X0 + AREA):
            if pixels[y][x] == YELLOW:
                pixels[y][x] = BLACK
    pixels[23][285] = BLACK

    for letter, first in WORD:
        for k, line in enumerate(glyphs[letter]):
            for c, dot in enumerate(line):
                if dot == '#':
                    x, y = upright(k, first + c)
                    pixels[y][x] = INK[k]

    OUT.mkdir(parents=True, exist_ok=True)
    indices = [value for row in pixels for value in row]
    picture = Image.new('RGB', (WIDTH, HEIGHT))
    picture.putdata([PALETTE[index] for index in indices])
    picture.save(OUT / 'splash_320x200.png')
    picture.resize((WIDTH * 4, HEIGHT * 24 // 5), Image.Resampling.NEAREST).save(
        OUT / 'splash_320x200_preview.png')
    rom = [f'{(indices[i] << 4) | indices[i + 1]:02X}\n' for i in range(0, len(indices), 2)]
    (OUT / 'splash_320x200.hex').write_bytes(''.join(rom).encode('ascii'))
    print(f'wrote {OUT.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
