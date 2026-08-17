#!/usr/bin/env python3
"""
genrange.py -- generate range.map + range.wad, the input/weapons test arena.

The range exists to exercise every M4/M5 system in one room:

  - open floor          stick locomotion, snap turn, room-scale head follow
  - freestanding wall   lean-through refusal, phase ghost-depth occlusion
  - stairs + platform   step-up/step-down during artificial and real motion
  - crates              jump
  - pillars             phase occlusion, monster cover
  - wading pool         liquid rendering, wading
  - weapon rack         all seven weapons + ammo: the wheel offers everything
  - firing line         grunts and dogs at known positions: live targets

Textures are extracted from the user's own pak0.pak into range.wad -- id's
assets are not redistributable, so neither the wad nor the compiled bsp is
committed; only this generator is. Build:

  python3 tools/range/genrange.py <path-to-id1> <outdir>
  qbsp <outdir>/range.map && light <outdir>/range.bsp   (tyrutils-ericw)

then stage range.bsp as Documents/id1/maps/range.bsp and `map range`.
"""

import struct
import sys
from pathlib import Path

# ---------------------------------------------------------------- textures

FLOOR, WALL, PILLAR = "ground1_6", "tech01_1", "metal1_4"
STAIR, PLAT, SKY = "sfloor4_2", "plat_top1", "sky4"
CRATES, CRATET, WATER = "crate0_side", "crate0_top", "*water1"
LEANWALL = "twall1_1"

NEEDED = {FLOOR, WALL, PILLAR, STAIR, PLAT, SKY, CRATES, CRATET, WATER, LEANWALL}


def extract_wad(id1: Path, out: Path) -> None:
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


def build_map() -> str:
    b = []
    # shell: floor, sky ceiling, four walls (inner space x -896..896, y -640..640, z 0..320)
    b.append(box(-928, -672, -16, 928, 672, 0, FLOOR))
    b.append(box(-928, -672, 320, 928, 672, 336, SKY))
    b.append(box(-928, -672, 0, -896, 672, 320, WALL))
    b.append(box(896, -672, 0, 928, 672, 320, WALL))
    b.append(box(-928, -672, 0, 928, -640, 320, WALL))
    b.append(box(-928, 640, 0, 928, 672, 320, WALL))

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

    # wading pool: rimmed basin, water inside
    b.append(box(512, -352, 0, 768, -344, 24, PILLAR))
    b.append(box(512, -136, 0, 768, -128, 24, PILLAR))
    b.append(box(512, -344, 0, 520, -136, 24, PILLAR))
    b.append(box(760, -344, 0, 768, -136, 24, PILLAR))
    b.append(box(520, -344, 0, 760, -136, 20, WATER))

    world = ['"classname" "worldspawn"', '"wad" "range.wad"',
             '"message" "quake-avp input range"',
             '"_sunlight" "180"', '"_sun_mangle" "30 -70 0"',
             '"_minlight" "40"']
    ents = ["{\n" + "\n".join(world) + "\n" + "".join(b) + "}\n"]

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

    # the firing line
    for i in range(5):
        ents.append(entity("monster_army", (-256 + i * 128, 480, 24), 270))
    ents.append(entity("monster_dog", (-384, 400, 24), 270))
    ents.append(entity("monster_dog", (384, 400, 24), 270))

    # light grid: dense enough that the whole floor is walkable-bright,
    # since the range is for reading movement, not atmosphere
    for x in (-640, -320, 0, 320, 640):
        for y in (-448, -160, 160, 448):
            ents.append(entity("light", (x, y, 260), light=320))

    return "".join(ents)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    id1, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    extract_wad(id1, out)
    (out / "range.map").write_text(build_map())
    print(f"wrote {out}/range.map and {out}/range.wad")


if __name__ == "__main__":
    main()
