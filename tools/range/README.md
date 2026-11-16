# Input test range

A purpose-built arena for exercising every M4/M5 input and locomotion
system in one room, instead of hunting for the right spot in e1m1:

- **open floor** — stick locomotion, snap turn, room-scale head follow
- **freestanding lean wall** — head-through-wall refusal, phase occlusion
- **stairs → raised platform** — step up/down under real and slowed motion
- **crates** — two jump heights
- **four pillars** — phase ghost-depth occlusion, monster cover
- **wading pool** — liquid rendering and wading; underwater (blue) polyblend
- **lava + slime pools** — CONTENTS_LAVA / CONTENTS_SLIME polyblend tints
  (orange / green); a biosuit sits beside each so you can stand in them
- **powerups** — Quad (blue) and Pentagram (red) screen tints; pick up any
  item (rack) for the bonus flash, take a hit from the firing line for the
  damage flash
- **weapon rack** — all seven weapons + ammo, so the wheel offers everything
- **firing line** — five grunts and two dogs at known positions, live
- **running track** — an oval ringing the arena, for turning without a
  controller

## The track

The track rings the arena rather than living in a second map: the arena
sits in the oval's infield, and you walk off its floor straight onto the
lanes. It is sized to the **arena**, not to a real track. A true-scale
400 m oval — which is what this was at first — puts lane 1 some 760 units
clear of the arena on the straights and about 2170 clear at the bend apexes,
and in the headset that reads as a huge empty field with a small room in the
middle of it. So the bends are folded in until the lanes hug the arena:

- **straights** — 47.14 m = 1856 units, the arena's own length, along X,
  centred on the origin
- **bends** — semicircles of radius 18.29 m = 720 units to lane 1's inner
  edge (the arena's 672 half-depth plus 48 of clearance), centred on the
  arena's own x = ±928; 16 brush segments each (11.25°)
- **8 lanes** of 1.22 m = 48 units; lane 8's outer edge is at 1104 units, so
  the whole footprint is x ±2032 / y ±1104
- **lane lines** — nine strips, kerbs included, 4 wide and 2 proud of the
  floor in a light texture
- **start/finish** — an 8-wide strip across all lanes at the start of the
  bottom (+X) straight, x = -928; the bends are left turns, as on a real
  track
- **markers** — four 16×16×48 pillars (cone stand-ins) just outside lane 8
  where each straight meets a bend
- **floor** — flat everywhere at z = 0. The arena keeps its own floor brush
  and the infield is tiled *around* that 1856 × 1344 footprint in
  `wswamp1_4`, so no two brushes share the z = 0 surface; cinder-coloured
  lanes, grey stone on the apron outside lane 8

**A lap is 213 m, not 400**, and that is the point rather than something
hidden: 8387 units round lane 1's centre line (2 × 1856 of straight plus a
circle of radius 744), which at 1 unit = 1 inch is 213.0 m. Only the
proportions of the oval are gone; the lanes are still a real 1.22 m wide, so
drift still reads against them at the right scale. Measured the way a real
track is, on the 30 cm line out from the kerb, the same lap is 211 m — the
number above is the centre line because that is the path you actually walk.

Since the bend centres now sit exactly on the arena's half-length, the two
infield strips that used to fill between the arena and the bends are
zero-width and the generator skips them (`if hx > AX`); the arena floor
reaches the bends by itself. The enclosure walls and the sky lid ring the
track snugly instead of fencing a field: inner faces at ±2304 / ±1408 — the
64-unit grid everything else here is on, which leaves about 272 (X) and 304
(Y) units of apron outside lane 8 — floor top at z = 0, sky lid at z = 1024.
The outermost wall face is at 2336, well inside the ±4096 BSP29 limit, so
the map is still plain BSP29. The light grid over the arena is unchanged;
the track beyond it is under the open sky lid and lit by the same sun.

Only the slab, the four walls and the sky lid are structural — qbsp has a
box to seal and vis a handful of portals to flood. The track's floor
tiling, lines and markers are `func_detail` and cannot leak.

## Building it

id's assets are not redistributable, so the compiled map, its texture WAD,
and the pak are **not committed** — only the generators are. Rebuild from
your own `pak0.pak`:

```sh
# 1. generate range.map + range.wad (textures lifted from your pak0)
python3 tools/range/genrange.py <path-to>/id1 build/range

# 2. compile + light + vis  (tyrutils-ericw; the pre-2018 C tags build
#    with a plain `make`, the modern CMake tree needs the embree backend).
#    qbsp finds range.wad beside the .map; pass an explicit output path so
#    the sidecar files land there too.
#
#    -subdivide 480 is not cosmetic. The immersive renderer has neither a
#    frustum nor a PVS while the immersive space is open, so it draws every
#    front-facing surface in the level every frame and face count is the
#    bill. Measured on the gym, this generator's other map: 6231 faces at
#    qbsp's default 240, and 1943 for identical geometry at 480 (gengym.py's
#    docstring keeps the numbers). At swing speed the larger faces cannot be
#    told apart, so they are free.
#
#    It does nothing for LIGHTDATA, which is the lump with no headroom in
#    this map. That scales with surface area, so no amount of subdividing
#    moves it and only less geometry can; genrange.py's enclosure note has
#    the measurement. The range's own 3804-face figure predates the flag, so
#    it should come down, and nobody has re-measured it.
qbsp  -subdivide 480 build/range/range.map build/range/range.bsp
light build/range/range.bsp
vis   build/range/range.bsp

# 3. pack it. gfx/pop.lmp is the 256-byte table QuakeSpasm itself carries
#    in common.c's `pop[]` under the GPL; genpop.py regenerates it from
#    that source so the test range loads without any id asset being
#    copied. Shareware data skips loose files in subdirectories, so the
#    map has to travel in a pak alongside it.
python3 tools/range/genpop.py > build/pop.lmp
python3 tools/range/mkpak.py build/range/pak2.pak \
    gfx/pop.lmp=build/pop.lmp \
    maps/range.bsp=build/range/range.bsp
```

`mkpak.py`'s first argument is the OUTPUT path -- it must never point at a
real pak inside your `<path-to>/id1`, or it overwrites id's own file. Stage
the result as `App/DevGameData/pak2.pak` for a dev build to bundle, or as
`Documents/id1/pak2.pak` on the device beside `pak0.pak` (and `pak1.pak`, if
you have the registered game): `pak2` is the app's own slot for a generated
range, so it never collides with anything id shipped. If you only have the
shareware `pak0.pak` and no real `pak1.pak` exists, staging the generated pak
as `Documents/id1/pak1.pak` instead is also fine -- but never do that once a
real `pak1.pak` is present. There is no Makefile target for the pak and none
is wanted; it is personal data, rebuilt by hand.

The generator prints the brush count (421 at the numbers above: 38
structural — the shell plus the arena's own brushes — and 383 `func_detail`).

## Launching it

`map range` from the console, or pick **Test range** from the window's
episode dropdown, below the console: it is the last entry after Deathmatch,
and it appears only when the build actually carried `pak2.pak` (the same
`QuakePaths.hasBundledRangePak` gate the dev auto-`map range` reads, so a
public checkout never offers a map it does not have).

## Verifying without a headset

`tools/range/rangetest.c` boots the engine on the pak, loads the range, and
asserts the firing line and rack are present, the player spawns on the
floor, the weapon wheel rings all eight weapons over it, a lane line stands
proud at lane 1's inner edge with the lane itself open and floored beside
it, and that holding `+back` from the spawn walks the player off the arena
floor and out into lane 1. Compile it with `make check`'s flags and link
against its objects minus `hostmain.o`:

```sh
make check                                    # populates the objects
O=${TMPDIR:-/tmp}/quakecore-hostbuild
cc -std=gnu99 -DQAVP_PLATFORM -DQAVP_HOSTCHECK -DUSE_CODEC_WAVE=1 -DUSE_CODEC_VORBIS=1 \
   -ISources/QuakeCore/engine -ISources/QuakeCore/platform \
   -ISources/QuakeCore/include -ISources/QuakeRenderer/bridge \
   -o build/rangetest tools/range/rangetest.c \
   $(ls $O/*.o | grep -v -e hostmain.o -e '/unit_') -lm
build/rangetest <basedir>                     # <basedir>/id1 holds pak0 + pak2
```

The basedir is the PARENT of `id1/`; symlinking your `pak0.pak` (and
`pak1.pak`) into a scratch `base/id1/` next to the freshly packed `pak2.pak`
is enough.

**Both patterns in that `grep -v` are load-bearing.** `tools/check-unit.sh`
builds into the same `$O` directory and names its objects `unit_*.o`, and one
of them, `unit_support.o`, defines the four `QC_Audio*` stand-ins that
`rangetest.c` and `gymtest.c` each define for themselves. Glob the directory
after running the unit suite and the link fails on duplicate symbols, with
nothing to suggest that a different test run is what put them there.

`tools/range/gymtest.c` is the hook's driver and links exactly the same way,
substituting its own name. It boots the engine on the pak, loads `gym` and
then `range`, and asserts the grappling hook end to end: the throw, the
anchor, sky refusal, the swing's velocity budget, that an anchor entity dying
falls back to a world anchor, that the player's weapon is untouched for a
whole engagement, that hooking a monster hurts it once rather than every
frame, and that the capability line naming the game's `T_Damage` is printed
once per progs and not once per throw. It takes the same basedir, and it
wants `pak2.pak` for the range half.
