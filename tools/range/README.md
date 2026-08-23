# Input test range

A purpose-built arena for exercising every M4/M5 input and locomotion
system in one room, instead of hunting for the right spot in e1m1:

- **open floor** — stick locomotion, snap turn, room-scale head follow
- **freestanding lean wall** — head-through-wall refusal, phase occlusion
- **stairs → raised platform** — step up/down under real and slowed motion
- **crates** — two jump heights
- **four pillars** — phase ghost-depth occlusion, monster cover
- **wading pool** — liquid rendering and wading
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

# 3. pack it. Shareware Quake skips loose files in subdirectories and
#    locks out extra/modified paks unless it sees the "registered" token
#    gfx/pop.lmp -- whose 256-byte content is published in the engine
#    source (common.c `pop[]`). mkpak bundles a synthesized pop.lmp so a
#    custom map loads on shareware data without shipping any id asset.
python3 tools/range/genpop.py > build/pop.lmp
python3 tools/range/mkpak.py <path-to>/id1/pak1.pak \
    gfx/pop.lmp=build/pop.lmp \
    maps/range.bsp=build/range/range.bsp
```

Stage `pak1.pak` beside `pak0.pak` in the app's `Documents/id1/`, then
`map range` from the console.

## Verifying without a headset

`tools/range/rangetest.c` (pattern: link against the `make check` objects
minus `hostmain.o`) boots the engine, loads the range, and asserts the
firing line and rack are present, the player spawns on the floor, and the
weapon wheel rings all eight weapons over it.
