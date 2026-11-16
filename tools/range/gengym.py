#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez

"""
gengym.py -- generate gym.map + gym.wad, the grappling-hook swing gym.

A column hall for tuning the hook: throw, swing, release, catch the next
column. The range next door exists to MEASURE things and is deliberately
enclosed and cluttered; a swing needs the opposite, so this is its own map
rather than a wing of that one. Open air, a long drop, and nothing to clip
a swing.

Four decisions here are gameplay rather than taste:

  - A CONCRETE CEILING, NOT SKY. GrappleAnchor resets the hook the moment it
    touches a sky surface, so a sky lid would make every upward throw fail
    silently and the gym would teach the wrong lesson about the weapon. A
    ceiling is a hookable surface, which is what you actually want overhead:
    you can swing from it.

  - SPACING IS A SWING LENGTH, not how it looks on a plan. The 1408 pitch
    was picked when vr_grapple_range was still rogue's 1600, to keep every
    column inside its neighbour's reach. That reasoning is gone: the range
    ships at 24000 now and bounds nothing here, because it only sets the
    hook's self-destruct timer and the longest sight line a Quake map can
    hold is about 11600 units, so every column is reachable from every
    other one whatever the pitch. What keeps 1408 is that it reads as one
    swing rather than one step, and that FEW AND BIG below wants the face
    count down. Nothing sits closer than vr_grapple_ropemin (64).

  - FEW AND BIG rather than many and thin. The immersive renderer has
    neither a frustum nor a PVS while the immersive space is open (it draws
    the whole level every frame on purpose, so the world does not pop as
    your head turns), and a tall open hall is the exact shape that gives
    that choice nothing to lean on. Every surface here is front-facing from
    the top of any column. Fewer, larger brushes is both the cheaper map and
    the more brutalist one, which is a rare case of the two agreeing.

  - EVERY COLUMN IS DIFFERENT HEIGHT. A uniform grid teaches you one swing.
    The heights come off a fixed table rather than a random seed so the map
    is reproducible: the same command always writes the same bytes, and a
    swing you tuned yesterday is the same swing today.

Textures are generated here, in this file, as flat 8-bit concrete: greys
from Quake's palette ramp, which is the aesthetic anyway. That is the whole
reason this map can be committed when the range cannot -- the range lifts
id's pixels out of a local pak0 and carries them into its bsp, so neither
its wad nor its bsp is ever committed. Nothing in gym.wad is anyone's but
A.'s, and no pak0 is needed to build it.

Build (the map tools are installed but not on PATH, and plain `vis`
resolves to BSD vis(1), which is a text utility and would silently do
nothing -- so use absolute paths):

  python3 tools/range/gengym.py build/range
  ~/.local/ericw-tools/bin/qbsp  -subdivide 480 build/range/gym.map build/range/gym.bsp
  ~/.local/ericw-tools/bin/light build/range/gym.bsp

vis is optional and skipped: the immersive path ignores the PVS entirely.

Measured, so the next change here has a baseline to beat. At -subdivide 480
the hall compiles to 1943 faces, FEWER than the range's 3804, which matters
because the immersive renderer draws every front-facing surface in the level
every frame. Leaving qbsp at its default 240 gives 6231 faces for exactly the
same geometry, and at swing speed nobody can tell the difference, so the
larger faces are free.

The number with no headroom is LIGHTDATA: 1,023,496 bytes against the format's
documented MAX_MAP_LIGHTING of 1,048,576. That is 98 percent, and it scales
with surface AREA rather than face count, so no amount of subdividing moves
it -- more hall or more columns is what blows it. The engine hunk-allocates
the lump and does not enforce the bound, so going over would probably work,
but it would be going over.

Then fold it into the dev pak beside the range and `map gym` in the console:

  python3 tools/range/mkpak.py build/range/pak2.pak \\
      gfx/pop.lmp=build/pop.lmp \\
      maps/range.bsp=build/range/range.bsp \\
      maps/gym.bsp=build/range/gym.bsp
"""

import struct
import sys
from pathlib import Path

from genrange import box, entity

# ---------------------------------------------------------------- textures

# Quake's palette opens with a 16-step greyscale ramp, index 0 black to
# index 15 near-white, so a concrete texture is a handful of indices in that
# range and needs no palette data to author. Mid greys only: 3 reads as damp
# concrete, 11 as sun-bleached, and staying off both ends keeps the lighting
# able to darken and brighten it.
FLOOR, WALL, COLUMN, LEDGE, CEIL = "cgfloor", "cgwall", "cgcol", "cgledge", "cgceil"

# name -> (base index, speck index, period). The pattern is a deterministic
# board-form streak: brutalist concrete carries the grain of the shuttering
# it was poured against, and a vertical streak every few texels reads as
# that at a distance, which is the only distance this will be seen from.
CONCRETE = {
    FLOOR:  (5, 4, 8),
    WALL:   (7, 6, 16),
    COLUMN: (8, 6, 4),
    LEDGE:  (10, 8, 8),
    CEIL:   (4, 3, 16),
}

TEX_W, TEX_H = 64, 64


def miptex(name, w, h, pixels):
    """One WAD2 miptex lump: a 40-byte header then four mip levels, each
    half the previous. The mips are REQUIRED -- the engine indexes all four
    unconditionally, and a lump that stops after level 0 reads whatever
    follows it in the wad as pixel data."""
    if len(name) > 15:
        sys.exit(f"texture name too long for a 16-byte field: {name}")
    levels, pw, ph, src = [], w, h, pixels
    for _ in range(4):
        levels.append(bytes(src))
        nw, nh = max(pw // 2, 1), max(ph // 2, 1)
        # Point sample rather than average: these are palette INDICES, and
        # averaging two indices gives an unrelated colour, not a blend.
        src = [src[(y * 2) * pw + (x * 2)] for y in range(nh) for x in range(nw)]
        pw, ph = nw, nh

    head = struct.pack("<16siiiiii", name.encode("latin-1"), w, h,
                       40, 40 + len(levels[0]),
                       40 + len(levels[0]) + len(levels[1]),
                       40 + len(levels[0]) + len(levels[1]) + len(levels[2]))
    return head + b"".join(levels)


def concrete_pixels(base, speck, period):
    """Board-form streaks plus a sparse aggregate fleck. Deterministic: a
    pure function of (x, y), so no seed and no run-to-run drift."""
    px = []
    for y in range(TEX_H):
        for x in range(TEX_W):
            i = base
            if x % period == 0:
                i = speck                       # the shuttering seam
            elif (x * 7 + y * 13) % 97 == 0:
                i = speck + 1                   # aggregate showing through
            elif (x * 3 + y * 5) % 211 == 0:
                i = base + 1                    # a lighter patch
            px.append(max(1, min(14, i)))
    return px


def write_wad(out):
    lumps = [(n, miptex(n, TEX_W, TEX_H, concrete_pixels(*args)))
             for n, args in CONCRETE.items()]
    data, entries, pos = b"", [], 12
    for name, blob in lumps:
        entries.append((pos, len(blob), name))
        data += blob
        pos += len(blob)
    wad = b"WAD2" + struct.pack("<ii", len(entries), pos) + data
    for filepos, size, name in entries:
        # 0x44 is WAD2's miptex type; the two bytes after it are compression
        # and padding, both zero for uncompressed.
        wad += struct.pack("<iiiBBBB16s", filepos, size, size, 0x44, 0, 0, 0,
                           name.encode("latin-1"))
    (out / "gym.wad").write_bytes(wad)


# ---------------------------------------------------------------- the hall

# Interior half-extent and height. Everything, including the outside of the
# shell, stays inside +-4096: the default network protocol encodes entity
# and player coordinates as a 16-bit fixed point at 1/8 unit, so +-4095.875
# is the real ceiling, and a map that crosses it needs a non-default
# sv_protocol this port has never run.
HALF = 3328
TOP = 3072
SHELL = 64                      # wall/floor/ceiling thickness

# 1 Quake unit is 1 inch here, as everywhere else in this project, so TOP is
# 78 m of fall and the hall is 169 m across. A 2 second drop covers about
# 1600 units under Quake's gravity, which is why the columns are this tall:
# a swing needs enough air under it to be a swing rather than a stumble.

COLS = 5                        # a 5x5 grid
PITCH = 1408                    # centre to centre
COL_HALF = 128                  # 256 square: wide enough to land on

# Column top heights, one row per grid row, deliberately uneven so no two
# adjacent swings are the same, and so there is always a higher one to aim
# for. 0 means NO column at that cell: the holes are what make routes.
HEIGHTS = [
    [1024, 2048,  512, 2560, 1280],
    [2304,    0, 1536,  768, 2816],
    [ 768, 1792, 3072, 2048,  512],
    [2560, 1024,    0, 1536, 2304],
    [1280, 2816, 2048,  640, 1792],
]

# Ledges: (grid x, grid y, which side, height). A slab jutting off a column
# gives the hook something to catch that is not directly overhead, which is
# the throw that actually makes you swing rather than get winched upward.
LEDGES = [
    (0, 0, "+x",  768), (1, 0, "+y", 1792), (3, 0, "-x", 2304),
    (0, 1, "+y", 2048), (2, 1, "+x", 1280), (4, 1, "-y", 2560),
    (1, 2, "-y", 1536), (2, 2, "+y", 2816), (3, 2, "-x", 1792),
    (0, 3, "+x", 2304), (1, 3, "+y",  768), (4, 3, "-x", 2048),
    (1, 4, "-x", 2560), (2, 4, "+y", 1792), (3, 4, "+x",  448),
]
LEDGE_OUT = 448                 # how far it reaches out from the column face
LEDGE_HALF = 224                # half its width along the column face
LEDGE_THICK = 48


def col_centre(ix, iy):
    span = (COLS - 1) * PITCH
    return (ix * PITCH - span / 2, iy * PITCH - span / 2)


def build_map():
    shell, detail, ents = [], [], []

    # The shell is the only STRUCTURAL geometry: qbsp portals structural
    # brushes and a few hundred portalled columns in one open volume is a
    # leaf explosion. Everything else is func_detail, exactly as the range
    # does it.
    o = HALF + SHELL
    shell.append(box(-o, -o, -SHELL, o, o, 0, FLOOR))            # floor
    shell.append(box(-o, -o, TOP, o, o, TOP + SHELL, CEIL))      # ceiling
    shell.append(box(-o, -o, 0, -HALF, o, TOP, WALL))            # -x
    shell.append(box(HALF, -o, 0, o, o, TOP, WALL))              # +x
    shell.append(box(-HALF, -o, 0, HALF, -HALF, TOP, WALL))      # -y
    shell.append(box(-HALF, HALF, 0, HALF, o, TOP, WALL))        # +y

    # Columns.
    for iy in range(COLS):
        for ix in range(COLS):
            h = HEIGHTS[iy][ix]
            if h == 0:
                continue
            cx, cy = col_centre(ix, iy)
            detail.append(box(cx - COL_HALF, cy - COL_HALF, 0,
                              cx + COL_HALF, cy + COL_HALF, h,
                              COLUMN, top=LEDGE))

    # Ledges.
    for ix, iy, side, h in LEDGES:
        if HEIGHTS[iy][ix] == 0 or h > HEIGHTS[iy][ix]:
            sys.exit(f"ledge at ({ix},{iy}) h={h} has no column to hang on")
        cx, cy = col_centre(ix, iy)
        if side == "+x":
            x1, x2 = cx + COL_HALF, cx + COL_HALF + LEDGE_OUT
            y1, y2 = cy - LEDGE_HALF, cy + LEDGE_HALF
        elif side == "-x":
            x1, x2 = cx - COL_HALF - LEDGE_OUT, cx - COL_HALF
            y1, y2 = cy - LEDGE_HALF, cy + LEDGE_HALF
        elif side == "+y":
            x1, x2 = cx - LEDGE_HALF, cx + LEDGE_HALF
            y1, y2 = cy + COL_HALF, cy + COL_HALF + LEDGE_OUT
        else:
            x1, x2 = cx - LEDGE_HALF, cx + LEDGE_HALF
            y1, y2 = cy - COL_HALF - LEDGE_OUT, cy - COL_HALF
        detail.append(box(x1, y1, h - LEDGE_THICK, x2, y2, h, LEDGE, top=LEDGE))

    # Two beams under the ceiling, crossing the hall. They are the anchor of
    # last resort: wherever you are, something is throwable at overhead, so a
    # missed catch is recoverable rather than a fall to the floor.
    beam_z = TOP - 256
    detail.append(box(-HALF, -96, beam_z, HALF, 96, beam_z + 96, LEDGE, top=LEDGE))
    detail.append(box(-96, -HALF, beam_z, 96, HALF, beam_z + 96, LEDGE, top=LEDGE))

    # Start in a corner, on the floor, looking down the diagonal: the first
    # thing in view is the whole field of columns rather than one of them.
    start = (-HALF + 384, -HALF + 384, 40)
    ents.append(entity("info_player_start", origin=start, angle=45))

    # Weapons, because testing whether you can shoot mid-swing needs
    # something to shoot with, and because the ring needs more than one
    # entry to be worth opening. NOT because the grapple is reached through
    # the ring: it is not on the ring in any game and never was. It carries
    # a wheel identity so it can be drawn and tuned while held, but no
    # ownership bit, because rogue publishes items2 shifted into bit 23 and
    # that aliases the grapple onto green armour -- a grapple on the ring
    # would grow a phantom weapon every time you picked up armour. The
    # whole argument is at qr_weapons.c:416.
    ents.append(entity("weapon_rocketlauncher",
                       origin=(-HALF + 640, -HALF + 384, 24)))
    ents.append(entity("weapon_grenadelauncher",
                       origin=(-HALF + 768, -HALF + 384, 24)))
    ents.append(entity("weapon_nailgun",
                       origin=(-HALF + 896, -HALF + 384, 24)))
    for i in range(4):
        ents.append(entity("item_rockets",
                           origin=(-HALF + 640 + i * 96, -HALF + 512, 24),
                           spawnflags=1))

    # Light. A sparse high grid plus a floor of ambient: the point is to read
    # the geometry while moving fast, not to light it beautifully, and every
    # extra light entity is lightmap time for no gain at this speed.
    for iy in range(3):
        for ix in range(3):
            lx = (ix - 1) * 2048
            ly = (iy - 1) * 2048
            ents.append(entity("light", origin=(lx, ly, TOP - 128), light=1200))

    # The world's own brushes live INSIDE the worldspawn braces; a .map with
    # them after the closing brace is not a map with loose brushes, it is a
    # parse error two lines later with no mention of why.
    text = (
        "{\n"
        '"classname" "worldspawn"\n'
        '"wad" "gym.wad"\n'
        '"message" "swing gym"\n'
        '"_minlight" "45"\n'
        + "".join(shell) +
        "}\n"
    )
    text += ('{\n"classname" "func_detail"\n' + "".join(detail) + "}\n")
    text += "".join(ents)
    return text, len(shell) + len(detail), len(ents)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    write_wad(out)
    text, nbrushes, nents = build_map()
    (out / "gym.map").write_text(text)
    print(f"wrote {out}/gym.map ({nbrushes} brushes, {nents} entities) "
          f"and {out}/gym.wad ({len(CONCRETE)} textures)")


if __name__ == "__main__":
    main()
