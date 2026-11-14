#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez

"""
genrange.py -- generate range.map + range.wad, the input/weapons test arena.

The range exists to exercise every M4/M5 system in one room:

  - open floor          stick locomotion, snap turn, room-scale head follow
  - freestanding wall   lean-through refusal, phase ghost-depth occlusion
  - stairs + platform   step-up/step-down during artificial and real motion
  - crates              jump
  - pillars             phase occlusion, monster cover
  - wading pool         liquid rendering, wading, underwater (blue) polyblend
  - lava + slime pools  CONTENTS_LAVA/SLIME polyblend tints (biosuit nearby)
  - powerups            Quad (blue) + Pentagram (red) screen tints
  - weapon rack         all seven weapons + ammo: the wheel offers everything
  - firing line         grunts and dogs at known positions: live targets
  - running track       an oval ringing the arena: turning without a
                        controller, and lane lines to read drift against

The track rings the arena rather than living in a second map, so one `map
range` gives both: the arena sits in the oval's infield, and you walk off
the arena floor straight onto the lanes. It is sized to the ARENA, not to
a real track: at true scale a 400 m oval reads in the headset as a huge
empty field around a small room, so the bends are folded in until the lanes
hug the arena. 1 Quake unit = 1 inch still, so a lane is a real lane width:

  straights   47.14 m  = 1856 units, the arena's own length, along X
  bend radius 18.29 m  =  720 units to lane 1's inner edge (672 + 48 clear)
  8 lanes      1.22 m  =   48 units each -> outer edge at 1104 units

A lap on lane 1's centre line is therefore 8387 units = 213 m, not 400.
That is the intent, not a rounding error. The enclosure walls and the sky
lid ring the track snugly rather than fencing a field; everything stays
inside +-4096, so the map is plain BSP29.

Textures are extracted from a local pak0.pak into range.wad -- id's
assets are not redistributable, so neither the wad nor the compiled bsp is
committed; only this generator is. Build:

  python3 tools/range/genrange.py <path-to-id1> <outdir>
  qbsp <outdir>/range.map && light <outdir>/range.bsp && vis <outdir>/range.bsp

then stage range.bsp as Documents/id1/maps/range.bsp and `map range`.
"""

import math
import struct
import sys
from pathlib import Path

# ---------------------------------------------------------------- textures

FLOOR, WALL, PILLAR = "ground1_6", "tech01_1", "metal1_4"
STAIR, PLAT, SKY = "sfloor4_2", "plat_top1", "sky4"
CRATES, CRATET, WATER = "crate0_side", "crate0_top", "*water1"
LEANWALL = "twall1_1"
# Liquid textures: qbsp assigns CONTENTS_LAVA / CONTENTS_SLIME from the "*lava"
# / "*slime" name prefix, which is what drives V_SetContentsColor's screen tint.
LAVA, SLIME = "*lava1", "*slime"
# The track: cinder-coloured lanes, a green infield around the arena floor,
# grey stone on the apron outside lane 8, a light strip for the lane lines and
# a dark one for the corner markers.
LANE, INFIELD, OUTSIDE = "ground1_2", "wswamp1_4", "stone1_3"
LINE, MARKER = "tlight11", "cop1_1"

NEEDED = {FLOOR, WALL, PILLAR, STAIR, PLAT, SKY, CRATES, CRATET, WATER, LEANWALL,
          LAVA, SLIME, LANE, INFIELD, OUTSIDE, LINE, MARKER}


def extract_wad(id1: Path, out: Path) -> None:
    """Lift the NEEDED miptexes out of the maps in id1/pak0.pak into
    out/range.wad."""
    pak = (id1 / "pak0.pak").read_bytes()
    diroff, dirlen = struct.unpack("<ii", pak[4:12])
    lumps, seen = [], set()
    for i in range(dirlen // 64):
        e = pak[diroff + i * 64 : diroff + (i + 1) * 64]
        name = e[:56].split(b"\0")[0].decode("latin-1")
        if not name.startswith("maps/") or not name.endswith(".bsp"):
            continue
        off, ln = struct.unpack("<ii", e[56:64])
        bsp = pak[off : off + ln]
        toff, tlen = struct.unpack("<ii", bsp[4 + 2 * 8 : 4 + 2 * 8 + 8])
        tex = bsp[toff : toff + tlen]
        (n,) = struct.unpack("<i", tex[:4])
        for o in struct.unpack(f"<{n}i", tex[4 : 4 + 4 * n]):
            if o < 0:
                continue
            tname = tex[o : o + 16].split(b"\0")[0].decode("latin-1")
            if tname.lower() in seen or tname.lower() not in {t.lower() for t in NEEDED}:
                continue
            w, h = struct.unpack("<ii", tex[o + 16 : o + 24])
            size = 40 + w * h + (w * h) // 4 + (w * h) // 16 + (w * h) // 64
            seen.add(tname.lower())
            lumps.append((tname, tex[o : o + size]))
    missing = {t.lower() for t in NEEDED} - seen
    if missing:
        sys.exit(f"textures not found in pak0.pak maps: {sorted(missing)}")

    data, entries, pos = b"", [], 12
    for name, blob in lumps:
        entries.append((pos, len(blob), name))
        data += blob
        pos += len(blob)
    wad = b"WAD2" + struct.pack("<ii", len(entries), pos) + data
    for filepos, size, name in entries:
        wad += struct.pack("<iiiBBBB16s", filepos, size, size, 0x44, 0, 0, 0,
                           name.encode("latin-1"))
    (out / "range.wad").write_bytes(wad)


# ---------------------------------------------------------------- geometry

# The arena. Its floor brush is AX x AY out from the origin; the infield
# tiling below abuts those same numbers, so the arena floor and the track
# infield meet on a shared plane instead of overlapping.
AX, AY = 928, 672

HALF_STRAIGHT = AX            # 928: the bend centres sit on the arena's own
                              # half-length, so each straight spans the arena
R_IN = AY + 48                # 720: lane 1's inner edge, 48 clear of the floor
LANES, LANE_W = 8, 48
R_OUT = R_IN + LANES * LANE_W # 1104: lane 8's outer edge
SEGS = 16                     # brush segments per semicircle (11.25 deg each)
LINE_W, LINE_H = 4, 2         # lane lines: 4 wide, 2 proud of the floor
START_W = 8                   # the start/finish line is twice a lane line

# Enclosure, ringing the track rather than a field around it. Inner faces
# at +-XW / +-YW, floor top at z = 0, sky at ZC. Both are on the 64 grid like
# every other coordinate here, which leaves ~270 units of apron outside lane
# 8 -- enough to walk, not a field. The outermost brush face is at
# XW + 32 = 2336, well inside the +-4096 BSP29 limit.
# Grown for the swing towers, which need air far more than floor: ZC was
# 1024, which is a room, and a hook that reaches 1600 units turns a 1024
# ceiling into a winch with nowhere to go.
#
# The footprint is trimmed to 3136 rather than the 3328 it wants, and the
# reason is LIGHTDATA, not space: at 3328 the lit bsp came to 1,052,788 bytes
# against the format's documented MAX_MAP_LIGHTING of 1,048,576. Lightdata
# scales with surface AREA, so no amount of subdividing moves it and only
# less hall does. Height was kept and width given up, because a swing needs
# air far more than it needs floor. If this map grows again, measure that
# lump before anything else: the engine hunk-allocates it and does not
# enforce the bound, so going over would probably work, and would still be
# going over.
#
# ZC is now at the CEILING OF THE PROTOCOL rather than of the budget, which
# is a nicer place to stop. The device verdict was that swinging under the
# crossbeam and up over it was the best thing in the map and that the lid cut
# it short, which it did: the beam top was 2944 and the lid 3072, so an arc
# over the walkway had 128 units to play in. The 24 ceiling plates that used
# to hang here were deleted in the same pass (they were obstacles on the
# walkway, which is the one place in the map that wants none), and the 87,524
# bytes of lightdata they cost paid for every one of these 960 new units of
# height with 13,568 to spare -- 1,035,008 measured at ZC 4032.
#
# 4032 and not more: the highest brush in the map is the sky lid's TOP at
# ZC + 16, MSG_WriteCoord16 is a signed short at 1/8 unit, so a coordinate
# reaches 4095.875 and 4096 wraps to -4096 silently (the range check in
# MSG_WriteShort is #ifdef PARANOID). 4032 + 16 = 4048 clears it on the 64
# grid the rest of this file uses.
XW, YW, ZC = 3136, 3136, 4032

# The bottom straight (y < 0) runs +X, so the bends are left turns, as on a
# real track, and the start/finish line is at the start of that straight.
START_X = -HALF_STRAIGHT

# ------------------------------------------------------------ swing towers
#
# A brutalist column field in the apron OUTSIDE the oval, which is the only
# part of this map with room for it, and which was dead space before. The
# track, the arena and every M4/M5 fixture are untouched: this is added
# around them, so one `map range` is still the one map that exercises
# everything, and now the hook as well.
#
# Spacing is set by the WEAPON, not by the plan. vr_grapple_range ships at
# 1600 units, so the centre-to-centre pitch sits under it and every
# neighbour is reachable at the shipped default; turning the range up only
# adds options. Nothing is closer than vr_grapple_ropemin (64).
#
# Few and big, for two reasons that happen to agree. The immersive renderer
# has neither a frustum nor a PVS while the immersive space is open (it draws
# the whole level every frame on purpose, so the world does not pop as your
# head turns), and a tall open field is the exact shape that gives that
# choice nothing to lean on. Fewer, larger brushes is the cheaper map, and it
# is also the more brutalist one.
TOWER_PITCH = 1408
TOWER_HALF = 128                # 256 square: wide enough to land on
TOWER_SPAN = 2                  # grid runs -TOWER_SPAN..+TOWER_SPAN

# Heights by grid cell, deliberately uneven so no two swings are the same
# and there is always a higher one to aim for. Fixed table rather than a
# random seed: the same command writes the same bytes, so a swing tuned
# yesterday is the same swing today. 0 means no tower, and the holes are
# what make routes.
TOWER_H = [
    [1536, 2560,  896, 2048, 1280],
    [2816, 1024, 1792,  640, 2560],
    [ 896, 2304,    0, 2816, 1024],
    [2048,  768, 1536, 1280, 2816],
    [1280, 2560, 2048,  896, 1792],
]

# (grid x, grid y, side, height). A slab jutting sideways is the anchor that
# makes you SWING; something straight overhead just winches you up.
TOWER_LEDGES = [
    (0, 0, "+x", 1024), (1, 0, "+y", 2048), (3, 0, "-x", 1536),
    (0, 1, "+y", 2304), (2, 1, "+x", 1280), (4, 1, "-y", 2048),
    (1, 2, "-y", 1792), (3, 2, "+y", 2304), (4, 2, "-x",  768),
    (0, 3, "+x", 1536), (2, 3, "+y", 1024), (4, 3, "-x", 2304),
    (1, 4, "-x", 2048), (2, 4, "+y", 1536), (3, 4, "+x",  640),
]
LEDGE_OUT, LEDGE_HALF, LEDGE_THICK = 448, 224, 48

# A second ring, offset half a pitch, so the apron reads as a FIELD you pick
# a route through rather than a fence around the track. On its own the
# aligned grid leaves 1408-unit corridors that all run the same two
# directions; interleaving breaks that up and roughly doubles the number of
# live anchors without moving anything closer than the hook's own minimum.
TOWER_H2 = [
    [2048, 1280, 2560,  896],
    [1024, 2816, 1536, 2304],
    [2560,  768, 2048, 1280],
    [ 896, 2304, 1024, 2816],
]
TOWER2_OFF = TOWER_PITCH // 2

# High crossbeams. The sky lid is NOT a hook anchor -- GrappleAnchor resets
# the hook the moment it touches a sky surface -- so without these there is
# nothing throwable above the tallest tower, and a missed catch at height is
# a fall to the floor with no recovery. Spider-Man's webs take buildings, not
# clouds, so this is the right shape anyway.
#
# PINNED ABSOLUTE, and it must stay that way. This was ZC - 320, which looks
# tidier and quietly defeats the entire point of raising the ceiling: the
# walkway would ride up with the lid and keep exactly the 320 units of
# headroom that were the complaint. The height the player has learned is this
# one, so the lid moves and the walkway does not.
BEAM_Z = 2752
BEAM_HALF = 96

COFFER_HALF = 256
COFFER_THICK = 96
COFFER_Z = 3200
# On the tower pitch rather than a coarser step, so a coffer sits above every
# gap in the tower grid: the device verdict on the 3x3 version was that there
# was no way up without a wall right next to you, and a ceiling you cannot
# throw at is most of why.
COFFER_STEP = 1408
COFFER_SPAN = 2

# Coffers: a grid of plates hung in open air. The lid is SKY, and
# GrappleAnchor resets the hook the moment it touches a sky surface, so
# without these a throw straight up fails silently everywhere except the two
# crossbeams -- 192 units wide in a hall 6272 across, so up was not a
# direction. The device verdict is that these are the most fun thing in the
# map to throw at, so they are not negotiable.
#
# PINNED ABSOLUTE at 3200, and the number is the whole point. They used to be
# ZC - 192, which put them at 2880..2976 while the beams ran 2752..2944: every
# plate on either axis shared 64 units of Z with the beam it crossed, so eight
# of the twenty-four stuck up through the walkway deck as a kerb you tripped
# over at a run. The generator's skip test only ever dropped the centre plate,
# because it tests XY and the clash is in Z.
#
# 3200 clears the deck at 2944 by 256, which is four times the player's
# standing height, so the walkway runs clean underneath. It also stops them
# riding the lid: with ZC at 4032 there are 736 units of empty air above the
# highest anchor in the map, which is the hang at the top of a swing that a
# ceiling 96 units up was cutting short.

FACE_TAIL = "0 0 0 1 1"


# ---------------------------------------------------------------- brushes

def box(x1, y1, z1, x2, y2, z2, tex, top=None):
    """Axis-aligned brush. qbsp derives each plane's normal as
    (p0-p1)x(p2-p1); these triples make every normal point OUT of the
    brush, which is what makes it a solid rather than an inside-out one."""
    t = tex
    tt = top or tex
    f = []
    f.append(f"( {x2} {y2} {z2} ) ( {x2} {y1} {z2} ) ( {x1} {y1} {z2} ) {tt} 0 0 0 1 1")
    f.append(f"( {x2} {y2} {z1} ) ( {x1} {y2} {z1} ) ( {x1} {y1} {z1} ) {t} 0 0 0 1 1")
    f.append(f"( {x1} {y2} {z2} ) ( {x1} {y1} {z2} ) ( {x1} {y1} {z1} ) {t} 0 0 0 1 1")
    f.append(f"( {x2} {y2} {z2} ) ( {x2} {y2} {z1} ) ( {x2} {y1} {z1} ) {t} 0 0 0 1 1")
    f.append(f"( {x2} {y1} {z2} ) ( {x2} {y1} {z1} ) ( {x1} {y1} {z1} ) {t} 0 0 0 1 1")
    f.append(f"( {x2} {y2} {z2} ) ( {x1} {y2} {z2} ) ( {x1} {y2} {z1} ) {t} 0 0 0 1 1")
    return "{\n" + "\n".join(f) + "\n}\n"


def entity(classname, origin=None, angle=None, **kv):
    lines = [f'"classname" "{classname}"']
    if origin:
        lines.append(f'"origin" "{origin[0]} {origin[1]} {origin[2]}"')
    if angle is not None:
        lines.append(f'"angle" "{angle}"')
    for k, v in kv.items():
        lines.append(f'"{k}" "{v}"')
    return "{\n" + "\n".join(lines) + "\n}\n"


def fmt(v):
    """Coordinates as qbsp reads them: integers stay integers, floats are
    rounded to a fixed 4 decimals so the same geometric plane is written with
    identical text wherever it is reused."""
    r = round(v, 4)
    return str(int(r)) if r == int(r) else f"{r:.4f}".rstrip("0").rstrip(".")


def face(p0, p1, p2, tex, inside):
    """One plane of a brush. qbsp takes the normal as (p0-p1)x(p2-p1); the
    triple is reordered so it points away from `inside`, a point known to lie
    within the brush -- a hand-derived winding on a non-axial face inverts
    silently, and qbsp does not name that mistake clearly."""
    a = [p0[i] - p1[i] for i in range(3)]
    b = [p2[i] - p1[i] for i in range(3)]
    n = (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
    d = sum(n[i] * (inside[i] - p1[i]) for i in range(3))
    if abs(d) < 1e-6:
        sys.exit(f"degenerate face through {p0} {p1} {p2}")
    if d > 0:
        p0, p2 = p2, p0
    pts = " ".join(f"( {fmt(p[0])} {fmt(p[1])} {fmt(p[2])} )" for p in (p0, p1, p2))
    return f"{pts} {tex} {FACE_TAIL}"


def brush(faces):
    return "{\n" + "\n".join(faces) + "\n}\n"


# ------------------------------------------------------------ tower helpers

def tower_centre(ix, iy):
    return (ix - TOWER_SPAN) * TOWER_PITCH, (iy - TOWER_SPAN) * TOWER_PITCH


def tower_blocked(cx, cy):
    """True where a tower would stand on the track, the arena or their
    immediate surround. The oval's own footprint is the straights' half
    length plus a bend radius in X, and lane 8's outer edge in Y; the margin
    is the tower's half width plus a body's width of clearance, so you can
    still run a lap without clipping a column."""
    margin = TOWER_HALF + 192
    return (abs(cx) < HALF_STRAIGHT + R_OUT + margin
            and abs(cy) < R_OUT + margin)


def towers():
    """The column field, the ledges hanging off it, and the high crossbeams,
    all as func_detail brushes. Floor top out here is the shell slab at
    z = -16, not 0: the track and infield tiles sit on top of the slab and
    the apron does not, which was already true before the towers arrived."""
    out = []
    z0 = -16
    for iy in range(2 * TOWER_SPAN + 1):
        for ix in range(2 * TOWER_SPAN + 1):
            h = TOWER_H[iy][ix]
            if h == 0:
                continue
            cx, cy = tower_centre(ix, iy)
            if tower_blocked(cx, cy):
                continue
            out.append(box(cx - TOWER_HALF, cy - TOWER_HALF, z0,
                           cx + TOWER_HALF, cy + TOWER_HALF, z0 + h,
                           PILLAR, top=PLAT))

    for ix, iy, side, h in TOWER_LEDGES:
        cx, cy = tower_centre(ix, iy)
        if TOWER_H[iy][ix] == 0 or tower_blocked(cx, cy):
            continue                    # its tower was skipped; so is it
        if h > TOWER_H[iy][ix]:
            sys.exit(f"ledge at ({ix},{iy}) h={h} is above its own tower")
        top = z0 + h
        if side == "+x":
            x1, x2 = cx + TOWER_HALF, cx + TOWER_HALF + LEDGE_OUT
            y1, y2 = cy - LEDGE_HALF, cy + LEDGE_HALF
        elif side == "-x":
            x1, x2 = cx - TOWER_HALF - LEDGE_OUT, cx - TOWER_HALF
            y1, y2 = cy - LEDGE_HALF, cy + LEDGE_HALF
        elif side == "+y":
            x1, x2 = cx - LEDGE_HALF, cx + LEDGE_HALF
            y1, y2 = cy + TOWER_HALF, cy + TOWER_HALF + LEDGE_OUT
        else:
            x1, x2 = cx - LEDGE_HALF, cx + LEDGE_HALF
            y1, y2 = cy - TOWER_HALF - LEDGE_OUT, cy - TOWER_HALF
        out.append(box(x1, y1, top - LEDGE_THICK, x2, y2, top, PLAT, top=PLAT))

    for iy in range(len (TOWER_H2)):
        for ix in range(len (TOWER_H2[iy])):
            h = TOWER_H2[iy][ix]
            cx = (ix - 2) * TOWER_PITCH + TOWER2_OFF
            cy = (iy - 2) * TOWER_PITCH + TOWER2_OFF
            if h == 0 or tower_blocked (cx, cy):
                continue
            out.append(box(cx - TOWER_HALF, cy - TOWER_HALF, z0,
                           cx + TOWER_HALF, cy + TOWER_HALF, z0 + h,
                           PILLAR, top=PLAT))

    # Two beams spanning the hall under the lid, clear of the oval in Y so
    # they are not a roof over the running track. One beam each way, not two:
    # a full-span beam measures 29,826 bytes of lightdata, which is 284 units
    # of ceiling height, and the second pair added nothing a swing could use
    # that the first pair did not.
    out.append(box(-XW, -BEAM_HALF, BEAM_Z, XW, BEAM_HALF,
                   BEAM_Z + 2 * BEAM_HALF, PILLAR, top=PLAT))
    out.append(box(-BEAM_HALF, -YW, BEAM_Z, BEAM_HALF, YW,
                   BEAM_Z + 2 * BEAM_HALF, PILLAR, top=PLAT))

    # The coffer grid, a clear 256 above the walkway deck. No skip test: at
    # this height nothing crosses anything, which is the point of the height.
    for iy in range(-COFFER_SPAN, COFFER_SPAN + 1):
        for ix in range(-COFFER_SPAN, COFFER_SPAN + 1):
            cx, cy = ix * COFFER_STEP, iy * COFFER_STEP
            out.append(box(cx - COFFER_HALF, cy - COFFER_HALF, COFFER_Z,
                           cx + COFFER_HALF, cy + COFFER_HALF,
                           COFFER_Z + COFFER_THICK, PLAT, top=PLAT))
    return out


class Bend:
    """One semicircular end of the oval, centred on (cx, 0), spanning the
    half-plane that faces away from the infield. Planes are built from
    canonical points (the centre, a point 2000 units out along a radial, the
    chord endpoints at a given radius) rather than from each brush's own
    vertices, so every brush that shares a radial or a chord writes the same
    plane text and qbsp merges them into one."""

    def __init__(self, cx, sign):
        self.cx, self.sign = cx, sign
        # sign=+1: the right bend, angles -90..90. sign=-1: the left, 90..270.
        base = -90 if sign > 0 else 90
        self.angles = [math.radians(base + i * 180 / SEGS) for i in range(SEGS + 1)]
        # A chord at radius r passes the segment's mid-angle at r*cos(half);
        # for a 4-wide strip that sag (~5 units) is wider than the strip, so
        # an interior point has to be taken between the chords, not at r.
        self.chord_sag = math.cos(math.pi / SEGS / 2)

    def at(self, i, r, z=0):
        a = self.angles[i]
        return (self.cx + r * math.cos(a), r * math.sin(a), z)

    def mid(self, i, r, z=0):
        a = (self.angles[i] + self.angles[i + 1]) / 2
        return (self.cx + r * math.cos(a), r * math.sin(a), z)

    def radial(self, i, tex, inside, z1, z2):
        return face((self.cx, 0, z1), self.at(i, 2000, z1), (self.cx, 0, z2), tex, inside)

    def chord(self, i, r, tex, inside, z1, z2):
        return face(self.at(i, r, z1), self.at(i + 1, r, z1), self.at(i, r, z2), tex, inside)

    def top_bottom(self, tex, inside, z1, z2):
        c = self.cx
        return [face((c, 0, z2), (c + 64, 0, z2), (c, 64, z2), tex, inside),
                face((c, 0, z1), (c + 64, 0, z1), (c, 64, z1), tex, inside)]

    def sector(self, i, r1, r2, z1, z2, tex):
        """Annular sector between radii r1 < r2 over segment i."""
        inside = self.mid(i, (r1 + r2) / 2 * self.chord_sag, (z1 + z2) / 2)
        return brush([self.radial(i, tex, inside, z1, z2),
                      self.radial(i + 1, tex, inside, z1, z2),
                      self.chord(i, r1, tex, inside, z1, z2),
                      self.chord(i, r2, tex, inside, z1, z2)]
                     + self.top_bottom(tex, inside, z1, z2))

    def half_disc(self, r, z1, z2, tex):
        """The infield cap: one convex (SEGS+1)-gon prism."""
        inside = (self.cx + self.sign * r / 2, 0, (z1 + z2) / 2)
        c = self.cx
        faces = [self.chord(i, r, tex, inside, z1, z2) for i in range(SEGS)]
        faces.append(face((c, 0, z1), (c, 64, z1), (c, 0, z2), tex, inside))
        return brush(faces + self.top_bottom(tex, inside, z1, z2))

    def outer_wedge(self, i, r, z1, z2, tex):
        """The floor beyond the bend: segment i's sector, outside the chord
        at r, cut off by whichever enclosure walls its two radials reach."""
        inside = self.mid(i, r + 64, (z1 + z2) / 2)
        faces = [self.radial(i, tex, inside, z1, z2),
                 self.radial(i + 1, tex, inside, z1, z2),
                 self.chord(i, r, tex, inside, z1, z2)]
        for wall in sorted({self.wall_hit(i), self.wall_hit(i + 1)}):
            if wall == "x":
                x = self.sign * XW
                faces.append(face((x, 0, z1), (x, 64, z1), (x, 0, z2), tex, inside))
            else:
                y = YW if wall == "+y" else -YW
                faces.append(face((0, y, z1), (64, y, z1), (0, y, z2), tex, inside))
        return brush(faces + self.top_bottom(tex, inside, z1, z2))

    def wall_hit(self, i):
        """Which enclosure wall the radial at angle i reaches first."""
        a = self.angles[i]
        dx, dy = math.cos(a), math.sin(a)
        tx = (XW - self.sign * self.cx) / abs(dx) if abs(dx) > 1e-9 else math.inf
        ty = YW / abs(dy) if abs(dy) > 1e-9 else math.inf
        if tx < ty:
            return "x"
        return "+y" if dy > 0 else "-y"


def build_map():
    hx = HALF_STRAIGHT
    bends = [Bend(hx, +1), Bend(-hx, -1)]
    b, detail = [], []

    # Structural shell: a slab under everything, four walls, a sky lid, set
    # just outside the oval's own footprint. This is all qbsp has to seal and
    # vis has to portal; the track's floor tiling, lines and markers below
    # are func_detail and cannot leak.
    fx, fy = XW + 32, YW + 32
    b.append(box(-fx, -fy, -32, fx, fy, -16, OUTSIDE))
    b.append(box(-fx, -fy, ZC, fx, fy, ZC + 16, SKY))
    b.append(box(-fx, -fy, -16, -XW, fy, ZC, WALL))
    b.append(box(XW, -fy, -16, fx, fy, ZC, WALL))
    b.append(box(-fx, -fy, -16, fx, -YW, ZC, WALL))
    b.append(box(-fx, YW, -16, fx, fy, ZC, WALL))

    # The arena floor, unmoved: the oval's infield is tiled around it, not
    # over it, so no two floor brushes share the z = 0 surface.
    b.append(box(-AX, -AY, -16, AX, AY, 0, FLOOR))

    # pillars: phase occlusion and cover
    for x in (-256, 256):
        for y in (64, 256):
            b.append(box(x - 48, y - 48, 0, x + 48, y + 48, 192, PILLAR))

    # freestanding lean wall: try to put your head through it
    b.append(box(432, 32, 0, 448, 224, 96, LEANWALL))

    # stairs up the west side: 8 risers of 16 to a 128-high platform
    for i in range(8):
        b.append(box(-896, -256 + i * 32, 0, -640, -224 + i * 32, 16 + i * 16, STAIR))
    b.append(box(-896, 32, 0, -640, 384, 128, PLAT, top=PLAT))

    # crates: one jumpable hop, one full jump
    b.append(box(96, -192, 0, 160, -128, 32, CRATES, top=CRATET))
    b.append(box(176, -192, 0, 240, -128, 64, CRATES, top=CRATET))

    # wading pool: rimmed basin, water inside (CONTENTS_WATER -> blue tint)
    b.append(box(512, -352, 0, 768, -344, 24, PILLAR))
    b.append(box(512, -136, 0, 768, -128, 24, PILLAR))
    b.append(box(512, -344, 0, 520, -136, 24, PILLAR))
    b.append(box(760, -344, 0, 768, -136, 24, PILLAR))
    b.append(box(520, -344, 0, 760, -136, 20, WATER))

    # lava pool (NE, CONTENTS_LAVA -> orange tint). Grab the biosuit first.
    b.append(box(560, 300, 0, 780, 308, 24, PILLAR))
    b.append(box(560, 492, 0, 780, 500, 24, PILLAR))
    b.append(box(560, 308, 0, 568, 492, 24, PILLAR))
    b.append(box(772, 308, 0, 780, 492, 24, PILLAR))
    b.append(box(568, 308, 0, 772, 492, 20, LAVA))

    # slime pool (SW, CONTENTS_SLIME -> green tint)
    b.append(box(-780, -500, 0, -560, -492, 24, PILLAR))
    b.append(box(-780, -308, 0, -560, -300, 24, PILLAR))
    b.append(box(-780, -492, 0, -772, -308, 24, PILLAR))
    b.append(box(-568, -492, 0, -560, -308, 24, PILLAR))
    b.append(box(-772, -492, 0, -568, -308, 20, SLIME))

    # --- the track -------------------------------------------------------
    # Floor: one flat plane at z = 0, tiled by region so each gets its own
    # texture with no overlaps. The infield is boxes AROUND the arena
    # footprint (the arena keeps its own floor brush), then the straights'
    # lanes and apron, then each bend as a half-disc of infield, 16 lane
    # sectors and 16 outer wedges that reach the walls.
    # The two side strips exist only while the bend centres sit inboard of
    # the arena's own half-length; at hx == AX the arena floor already reaches
    # the bends and these boxes would be zero-width.
    if hx > AX:
        detail.append(box(-hx, -R_IN, -16, -AX, R_IN, 0, INFIELD))
        detail.append(box(AX, -R_IN, -16, hx, R_IN, 0, INFIELD))
    detail.append(box(-AX, -R_IN, -16, AX, -AY, 0, INFIELD))
    detail.append(box(-AX, AY, -16, AX, R_IN, 0, INFIELD))
    for s in (1, -1):
        detail.append(box(-hx, min(s * R_IN, s * R_OUT), -16, hx, max(s * R_IN, s * R_OUT), 0, LANE))
        detail.append(box(-hx, min(s * R_OUT, s * YW), -16, hx, max(s * R_OUT, s * YW), 0, OUTSIDE))
    for bend in bends:
        detail.append(bend.half_disc(R_IN, -16, 0, INFIELD))
        for i in range(SEGS):
            detail.append(bend.sector(i, R_IN, R_OUT, -16, 0, LANE))
            detail.append(bend.outer_wedge(i, R_OUT, -16, 0, OUTSIDE))

    # Lane lines: nine of them, the inner and outer kerbs included, each a
    # strip LINE_W wide and LINE_H proud, centred on the lane boundary.
    for k in range(LANES + 1):
        r = R_IN + k * LANE_W
        for s in (1, -1):
            y = s * r
            detail.append(box(-hx, y - LINE_W // 2, 0, hx, y + LINE_W // 2, LINE_H, LINE))
        for bend in bends:
            for i in range(SEGS):
                detail.append(bend.sector(i, r - LINE_W / 2, r + LINE_W / 2, 0, LINE_H, LINE))

    # Start/finish line across all eight lanes at the start of the +X straight.
    detail.append(box(START_X - START_W // 2, -R_OUT, 0, START_X + START_W // 2, -R_IN,
                      LINE_H, LINE))

    # Cone stand-ins where each straight meets a bend, just outside lane 8.
    for x in (-hx, hx):
        for y in (R_OUT + 20, -(R_OUT + 20)):
            detail.append(box(x - 8, y - 8, 0, x + 8, y + 8, 48, MARKER))

    detail.extend (towers())

    world = ['"classname" "worldspawn"', '"wad" "range.wad"',
             '"message" "quake-avp input range"',
             '"_sunlight" "180"', '"_sun_mangle" "30 -70 0"',
             '"_minlight" "40"']
    ents = ["{\n" + "\n".join(world) + "\n" + "".join(b) + "}\n"]
    ents.append("{\n" + '"classname" "func_detail"' + "\n" + "".join(detail) + "}\n")

    ents.append(entity("info_player_start", (0, -448, 24), 90))

    # the rack: every weapon the wheel can offer, plus ammo and health
    weapons = ["weapon_supershotgun", "weapon_nailgun", "weapon_supernailgun",
               "weapon_grenadelauncher", "weapon_rocketlauncher", "weapon_lightning"]
    for i, w in enumerate(weapons):
        ents.append(entity(w, (-320 + i * 128, -560, 24)))
    for i, a in enumerate(["item_shells", "item_shells", "item_spikes", "item_spikes",
                           "item_rockets", "item_rockets", "item_cells", "item_cells"]):
        ents.append(entity(a, (-448 + i * 128, -608, 24), spawnflags=1))
    for i in range(4):
        ents.append(entity("item_health", (-192 + i * 128, -608, 24)))

    # polyblend props: powerups that tint the screen, and a biosuit so you can
    # stand in the lava/slime pools long enough to see their tint.
    ents.append(entity("item_artifact_super_damage", (0, 0, 24)))     # Quad -> blue
    ents.append(entity("item_artifact_invulnerability", (160, 0, 24)))# Pentagram -> red
    ents.append(entity("item_artifact_envirosuit", (670, 220, 24)))   # biosuit, by the lava
    ents.append(entity("item_artifact_envirosuit", (-670, -220, 24))) # biosuit, by the slime

    # the firing line
    for i in range(5):
        ents.append(entity("monster_army", (-256 + i * 128, 480, 24), 270))
    ents.append(entity("monster_dog", (-384, 400, 24), 270))
    ents.append(entity("monster_dog", (384, 400, 24), 270))

    # light grid: dense enough that the whole arena floor is walkable-bright,
    # since the range is for reading movement, not atmosphere. The track
    # beyond the arena is under the open sky lid and is lit by the sun, as it
    # was when it was its own map.
    for x in (-640, -320, 0, 320, 640):
        for y in (-448, -160, 160, 448):
            ents.append(entity("light", (x, y, 260), light=320))

    return "".join(ents), len(b) + len(detail)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    id1, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    extract_wad(id1, out)
    text, nbrushes = build_map()
    (out / "range.map").write_text(text)
    print(f"wrote {out}/range.map ({nbrushes} brushes) and {out}/range.wad")


if __name__ == "__main__":
    main()
