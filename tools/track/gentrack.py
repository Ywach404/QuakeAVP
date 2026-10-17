#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez

"""
gentrack.py -- generate track.map + track.wad, a 400 m running track.

A flat, open oval for turning without a controller: long straights to run,
wide constant-radius bends to turn through, lane lines to read drift
against, and nothing to shoot. It doubles as a possible first level where a
player settles on a turn rate before the game asks anything else of them.

True scale, 1 Quake unit = 1 inch, so a lap is a real 400 m and the
distances feel like the real thing in the headset. The whole oval sits
inside +-4096 on every axis, so the standard BSP29 format is enough.

  straights   84.39 m  = 3322 units, along X, centred on the origin
  bend radius 36.50 m  = 1437 units to lane 1's inner edge
  8 lanes     1.22 m   =   48 units each -> outer edge at 1821 units

Textures are lifted from a local pak0.pak into track.wad by the range
generator's extractor -- id's assets are not redistributable, so neither
the wad nor the compiled bsp is committed; only this generator is. Build:

  python3 tools/track/gentrack.py <path-to-id1> <outdir>
  qbsp <outdir>/track.map && light <outdir>/track.bsp && vis <outdir>/track.bsp

then pack track.bsp into the dev pak beside range.bsp (tools/track/README.md).
"""

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "range"))
from genrange import box, entity, extract_wad  # noqa: E402

# ---------------------------------------------------------------- textures

LANE, INFIELD, OUTSIDE = "ground1_2", "wswamp1_4", "stone1_3"
LINE, MARKER, WALL, SKY = "tlight11", "cop1_1", "wbrick1_5", "sky4"
NEEDED = {LANE, INFIELD, OUTSIDE, LINE, MARKER, WALL, SKY}

# ---------------------------------------------------------------- geometry

HALF_STRAIGHT = 1661          # 3322 / 2: the bend centres sit at x = +-1661
R_IN = 1437                   # lane 1's inner edge
LANES, LANE_W = 8, 48
R_OUT = R_IN + LANES * LANE_W # 1821: lane 8's outer edge
SEGS = 16                     # brush segments per semicircle (11.25 deg each)
LINE_W, LINE_H = 4, 2         # lane lines: 4 wide, 2 proud of the floor
START_W = 8                   # the start/finish line is twice a lane line

# Enclosure. Inner faces at +-XW / +-YW, floor top at z = 0, sky at ZC. The
# outermost brush face is at XW + 32 = 4064, inside the +-4096 BSP29 limit.
XW, YW, ZC = 4032, 3072, 1024

# Where the oval starts: the bottom straight (y < 0) runs +X, so the bends
# are left turns, as on a real track. The start/finish line is at the start
# of that straight; the player stands one hull-width past it in lane 1.
START_X = -HALF_STRAIGHT
LANE1_Y = -(R_IN + LANE_W // 2)             # -1461
PLAYER_START = (START_X + 24, LANE1_Y, 32)  # (-1637, -1461, 32)

FACE_TAIL = "0 0 0 1 1"


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
    hx, c = HALF_STRAIGHT, HALF_STRAIGHT
    bends = [Bend(c, +1), Bend(-c, -1)]
    world, detail = [], []

    # Structural shell: a slab under everything, four walls, a sky lid. This
    # is all qbsp has to seal and vis has to portal; the floor tiling, the
    # lines and the markers below are func_detail and cannot leak.
    fx, fy = XW + 32, YW + 32
    world.append(box(-fx, -fy, -32, fx, fy, -16, OUTSIDE))
    world.append(box(-fx, -fy, ZC, fx, fy, ZC + 16, SKY))
    world.append(box(-fx, -fy, -16, -XW, fy, ZC, WALL))
    world.append(box(XW, -fy, -16, fx, fy, ZC, WALL))
    world.append(box(-fx, -fy, -16, fx, -YW, ZC, WALL))
    world.append(box(-fx, YW, -16, fx, fy, ZC, WALL))

    # Floor: one flat plane at z = 0, tiled by region so each gets its own
    # texture with no overlaps. Straights and infield are axial boxes; each
    # bend is a half-disc of infield, 16 lane sectors, and 16 outer wedges
    # that reach the walls.
    detail.append(box(-hx, -R_IN, -16, hx, R_IN, 0, INFIELD))
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
            detail.append(box(-hx, y - LINE_W / 2, 0, hx, y + LINE_W / 2, LINE_H, LINE))
        for bend in bends:
            for i in range(SEGS):
                detail.append(bend.sector(i, r - LINE_W / 2, r + LINE_W / 2, 0, LINE_H, LINE))

    # Start/finish line across all eight lanes at the start of the +X straight.
    detail.append(box(START_X - START_W / 2, -R_OUT, 0, START_X + START_W / 2, -R_IN, LINE_H, LINE))

    # Cone stand-ins where each straight meets a bend, just outside lane 8.
    for x in (-hx, hx):
        for y in (R_OUT + 20, -(R_OUT + 20)):
            detail.append(box(x - 8, y - 8, 0, x + 8, y + 8, 48, MARKER))

    # Lighting as the range does it: the whole floor is under the sky lid, so
    # the sun reaches all of it and minlight lifts the wall shadows.
    keys = ['"classname" "worldspawn"', '"wad" "track.wad"',
            '"message" "quake-avp track"',
            '"_sunlight" "180"', '"_sun_mangle" "30 -70 0"',
            '"_minlight" "40"']
    ents = ["{\n" + "\n".join(keys) + "\n" + "".join(world) + "}\n"]
    ents.append("{\n" + '"classname" "func_detail"' + "\n" + "".join(detail) + "}\n")
    ents.append(entity("info_player_start", PLAYER_START, 0))
    return "".join(ents), len(world) + len(detail)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    id1, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    extract_wad(id1, out, NEEDED, "track.wad")
    text, nbrushes = build_map()
    (out / "track.map").write_text(text)
    print(f"wrote {out}/track.map ({nbrushes} brushes) and {out}/track.wad")


if __name__ == "__main__":
    main()
