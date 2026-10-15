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

## Building it

id's assets are not redistributable, so the compiled map, its texture WAD,
and the pak are **not committed** — only the generators are. Rebuild from
your own `pak0.pak`:

```sh
# 1. generate range.map + range.wad (textures lifted from your pak0)
python3 tools/range/genrange.py <path-to>/id1 build/range

# 2. compile + light + vis  (tyrutils-ericw; the pre-2018 C tags build
#    with a plain `make`, the modern CMake tree needs the embree backend)
qbsp build/range/range.map
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
the result as `Documents/id1/pak2.pak` beside `pak0.pak` (and `pak1.pak`, if
you have the registered game): `pak2` is the app's own slot for a generated
range, so it never collides with anything id shipped. If you only have the
shareware `pak0.pak` and no real `pak1.pak` exists, staging the generated pak
as `Documents/id1/pak1.pak` instead is also fine -- but never do that once a
real `pak1.pak` is present. Then `map range` from the console.

## Verifying without a headset

`tools/range/rangetest.c` (pattern: link against the `make check` objects
minus `hostmain.o`) boots the engine, loads the range, and asserts the
firing line and rack are present, the player spawns on the floor, and the
weapon wheel rings all eight weapons over it.
