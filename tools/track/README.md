# Running track

A rudimentary 400 m track-and-field oval, flat and empty, for turning
without a controller: two long straights to run, two wide constant-radius
bends to turn through, and lane lines to read your drift against. It is
also a candidate first level -- somewhere a player can settle on a turn
rate before the game asks anything else of them. No monsters, no items.

Built at true scale, 1 Quake unit = 1 inch, so a lap is a real 400 m:

- **straights** -- 84.39 m = 3322 units, along X, centred on the origin
- **bends** -- semicircles of radius 36.5 m = 1437 units to lane 1's inner
  edge, centred at x = +-1661; 16 brush segments each (11.25 deg)
- **8 lanes** of 1.22 m = 48 units; lane 8's outer edge is at 1821 units
- **lane lines** -- nine strips, kerbs included, 4 wide and 2 proud of the
  floor in a light texture
- **start/finish** -- an 8-wide strip across all lanes at the start of the
  bottom (+X) straight, x = -1661; the bends are left turns, as on a real
  track
- **markers** -- four 16x16x48 pillars (cone stand-ins) just outside lane 8
  where each straight meets a bend
- **floor** -- flat everywhere at z = 0: cinder-coloured lanes, a green
  infield, grey stone outside; a sky lid and brick walls well beyond the
  oval, lit by the same sunlight setup as the range

Everything sits inside +-4096 on every axis (the outermost wall face is at
4064), so it is a plain BSP29 map. `info_player_start` is in lane 1, one
hull-width past the start line, facing +X.

## Building it

As for the range: id's assets are not redistributable, so the compiled map,
its texture WAD and the pak are **not committed** -- only the generator is.
`gentrack.py` lifts its textures from your own `pak0.pak` through the range
generator's extractor, so the two maps share one copy of that code.

```sh
# 1. generate track.map + track.wad (textures lifted from your pak0)
python3 tools/track/gentrack.py <path-to>/id1 build/track

# 2. compile + light + vis (ericw-tools). qbsp finds track.wad beside the
#    .map; pass an explicit output path so the sidecar files land there too
qbsp  build/track/track.map build/track/track.bsp
light build/track/track.bsp
vis   build/track/track.bsp

# 3. pack it into the dev pak BESIDE the range: one pak2.pak carries both
#    maps plus gfx/pop.lmp (see tools/range/README.md for why)
python3 tools/range/genpop.py > build/pop.lmp
python3 tools/range/mkpak.py build/pak2.pak \
    gfx/pop.lmp=build/pop.lmp \
    maps/range.bsp=build/range/range.bsp \
    maps/track.bsp=build/track/track.bsp
```

Stage the result as `App/DevGameData/pak2.pak` (or `Documents/id1/pak2.pak`
on the device) and `map track` from the console. There is no Makefile
target for this step; the pak is personal data and is rebuilt by hand.

The generator prints the brush count (388 at the numbers above: 6
structural, the rest `func_detail`). Only the slab, four walls and sky lid
are structural, so qbsp has a box to seal and vis has eight portals to
flood; the floor tiling, the lines and the markers are detail and cannot
leak.

## Verifying without a headset

`tools/track/tracktest.c` boots the engine on the pak, loads the track, and
asserts the worldmodel is `maps/track.bsp`, the player stands in lane 1 at
the start line (within 48 units of the generator's `PLAYER_START`), and
that two seconds of `+forward` run down the straight without leaving the
lane. Same pattern as `rangetest.c`: compile with `make check`'s flags and
link against its objects minus `hostmain.o`:

```sh
make check                                    # populates the objects
O=${TMPDIR:-/tmp}/quakecore-hostbuild
cc -std=gnu99 -DQAVP_PLATFORM -DQAVP_HOSTCHECK -DUSE_CODEC_WAVE=1 -DUSE_CODEC_VORBIS=1 \
   -ISources/QuakeCore/engine -ISources/QuakeCore/platform \
   -ISources/QuakeCore/include -ISources/QuakeRenderer/bridge \
   -o build/tracktest tools/track/tracktest.c $(ls $O/*.o | grep -v hostmain.o) -lm
build/tracktest <basedir>                     # <basedir>/id1 holds pak0 + pak2
```

The basedir is the PARENT of `id1/`; symlinking your `pak0.pak` (and
`pak1.pak`) into a scratch `base/id1/` next to the freshly packed `pak2.pak`
is enough.
