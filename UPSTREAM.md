# Upstream provenance and patches

## Source

QuakeSpasm, vendored (not a submodule) from `github.com/sezero/quakespasm`.

- Version: **0.97.0**
- Commit: `d27b64cf6c1aae84405918c75de13d2346d3008f` (also recorded in
  `Sources/QuakeCore/engine/.upstream-rev`)
- Licence: GPL-2.0-or-later — see `LICENSE.txt`

Vendored rather than submoduled because the renderer and platform layers are
being replaced wholesale; a submodule would fight every change and buy nothing.

## What was taken

All 72 headers, plus 45 `.c` files: the simulation, game, networking, and
common layers. Also `progdefs.q1` (`#include`d by `progdefs.h`) and
`quakespasm.pak` (QuakeSpasm's own resource pak, now in `App/Resources`).

## What was left behind, and why

| Files | Reason |
|---|---|
| `gl_draw.c` `gl_fog.c` `gl_mesh.c` `gl_rlight.c` `gl_rmain.c` `gl_rmisc.c` `gl_screen.c` `gl_sky.c` `gl_texmgr.c` `gl_warp.c` | OpenGL renderer. No GL on visionOS. Replaced by `platform/r_null.c` + the Metal renderer (see below). |
| `r_alias.c` `r_brush.c` `r_part.c` `r_sprite.c` `r_world.c` | Ditto — these are GL despite the `r_` prefix. |

Although those files are not vendored, substantial logic from them *was
ported* (at the same commit) into `Sources/QuakeRenderer/bridge/qr_bridge.c`
with the GL calls replaced: the texture manager and palettes (`gl_texmgr.c`),
lightmap building and surface polygon lists (`r_brush.c`), PVS marking,
texture chains, and the liquid draw order (`r_world.c`), frustum/view setup
and entity culling (`gl_rmain.c`), sky texture/skybox loading and the
worldspawn sky keys (`gl_sky.c`), the water alpha plumbing incl. worldspawn
overrides (`gl_rmisc.c`), brush entity drawing (`r_brush.c`'s
`R_DrawBrushModel` and the entity halves of `r_world.c`), the alias mesh
build (`gl_mesh.c`, the indexed-VBO half only — the GL1 strip/fan command
lists serve no purpose here), alias lerp/lighting/draw (`r_alias.c`, whose
GLSL two-pose vertex path became `Shaders/Alias.metal`), point lighting
(`gl_rlight.c`'s `R_LightPoint`), and the refdef/fov math plus cvar tables
into `platform/r_null.c` (`gl_screen.c`, `gl_rmisc.c`). The *draw-time* halves of
`gl_warp.c` and `gl_sky.c` were not ported line-for-line: their warp
(`WARPCALC`/`turbsin`) and cloud-projection (`Sky_GetTexCoord`,
`Sky_ProjectPoly`) math is evaluated per fragment in
`Sources/QuakeRenderer/Shaders/World.metal` — the render-to-warpimage scheme
and the far-quad GEQUAL sky trick existed only to work around GL1.

One deliberate structural departure from upstream: the world is drawn as a
**depth prepass plus an equal-depth colour pass** rather than upstream's
single pass. Upstream never needed the split — GL Quake never makes walls
transparent while keeping their occlusion — but the phase effect does:
occlusion must come from geometry whose colour has been dissolved away, so
depth and colour are decided in separate passes and only the colour pass
ever changes with phase. When merging upstream world-drawing changes, apply
them to both passes. When
merging a newer upstream, diff those upstream files too and carry relevant
fixes into the ports (including the shader constants); cvar defaults must
stay byte-identical.
| `gl_vidsdl.c` `main_sdl.c` `in_sdl.c` `snd_sdl.c` `cd_sdl.c` `sys_sdl_unix.c` `sys_sdl_win.c` | SDL platform layer. Replaced by `platform/` — except `platform/cd_null.c`, which is not a replacement: it is upstream's own null CD-audio driver (`Quake/cd_null.c`), carried into `platform/` verbatim apart from a header note recording that provenance. (Taken the same way `stb_vorbis.c` below is: placed in `platform/` rather than `engine/`, so it is not one of the "45 `.c` files" counted under **What was taken** above.) |
| `net_win.c` `net_wins.c` `net_wipx.c` `pl_win.c` | Windows-only. |
| `pl_linux.c` | X11 clipboard/icon. Replaced by `platform/pl_null.c`. |
| `pl_osx.m` | AppKit. Not applicable to visionOS, but worth re-reading when the clipboard is wired up. |
| `snd_flac.c` `snd_mikmod.c` `snd_modplug.c` `snd_mp3.c` `snd_mp3tag.c` `snd_mpg123.c` `snd_opus.c` `snd_umx.c` `snd_vorbis.c` `snd_xmp.c` | Optional codecs, all needing third-party libs. `snd_wave.c` is kept, and **vorbis is supplied instead by `platform/snd_vorbis_avp.c`** on the vendored stb_vorbis (below) — same `vorbis_codec` vtable, no libvorbisfile. The headers (`snd_vorbis.h` et al.) *are* vendored; they only declare the vtable symbol. |

Both kept codecs are switched on by `USE_CODEC_WAVE=1 USE_CODEC_VORBIS=1`, which
`snd_codec.c`'s `S_CodecInit` tests before registering anything. The pair is
defined in three places that must stay in sync: `project.yml`'s
`GCC_PREPROCESSOR_DEFINITIONS`, `tools/check-core.sh` and `tools/check-unit.sh`.
With neither defined the entire BGM chain still compiles and simply plays
nothing, which is how it shipped until the soundtrack round.

Two files kept despite their misleading names: **`gl_model.c`** (BSP/MDL/SPR
parsing — the server needs it for collision hulls) and **`gl_refrag.c`**
(efrag list management — pure logic).

`lodepng.c` is present but **not compiled as its own translation unit** — it is
`#include`d by `image.c`, exactly as upstream does it. It's excluded in both
`project.yml` and `tools/check-core.sh`; keep those in sync.

## Other third-party sources

Single-file libraries vendored verbatim. Never hand-edit one: re-download at a
newer commit and record it here.

| File | Source | Pinned at |
|---|---|---|
| `Sources/QuakeCore/engine/miniz.h` / `.c` | came with QuakeSpasm, MIT licence (Rich Geldreich, RAD Game Tools and Valve) | the QuakeSpasm commit above (`.h` patched, see below) |
| `Sources/QuakeCore/engine/lodepng.c` / `.h` | came with QuakeSpasm, zlib licence (Lode Vandevenne) | the QuakeSpasm commit above |
| `Sources/QuakeCore/engine/stb_image_write.h` | came with QuakeSpasm (trimmed to the JPEG writer only); `github.com/nothings/stb`, dual-licensed MIT / public domain (Sean Barrett), with Jon Olick's public-domain `jo_jpeg.cpp` JPEG writer folded in — see the file's own licence block | the QuakeSpasm commit above |
| `Sources/QuakeCore/platform/stb_vorbis.c` | `github.com/nothings/stb`, public domain / MIT | last commit touching the file: `1ee679ca2ef753a528db5ba6801e1067b40481b8` (repo master `2c980bb59875b0d32144a71867fbdebb2f77cd20` when taken). SHA-256 `4c7cb2ff1f7011e9d67950446b7eb9ca044f2e464d76bfbb0b84dd2e23e65636` |

Unlike `lodepng.c`, `stb_vorbis.c` **is** its own translation unit: the codec in
`platform/snd_vorbis_avp.c` includes it a second time under
`STB_VORBIS_HEADER_ONLY` for the declarations only, which is stb's documented
two-TU arrangement. `STB_VORBIS_NO_STDIO` is deliberately *not* defined —
`stb_vorbis_open_file_section` is the whole reason it was chosen, because a
pak-embedded `music/trackNN.ogg` is a window into a much larger file. It is
also the one file compiled with an extra `-Wno-tautological-compare`, scoped to
it alone in `project.yml` and in `tools/check-core.sh`'s `extra_cflags`.

A gotcha worth knowing before chasing a silent soundtrack: `common.c`'s
loose-file branch (the `registered.value` test in `COM_FindFile`) skips any
filename containing a `/` when `registered` is 0. Music lives at
`music/trackNN.ogg`, so with shareware-only data a loose music folder is
invisible no matter what the codecs say. A dev build seeds a local `pak1`
placed in `App/DevGameData` (gitignored, never committed), so `registered`
is 1 there and loose music plays. A release build ships no game data at all:
`registered` is whatever the player's own paks make it, so a player running
shareware `pak0` alone gets `registered` 0 and will not see a loose `music/`
folder — their soundtrack has to be inside a pak, or they need the registered
data.

## Patches applied to vendored files

Kept to an absolute minimum so upstream merges stay cheap. Five files, six
hunks, all guarded by `#ifdef QAVP_PLATFORM`:

**`quakedef.h`** — the `#include <SDL.h>` / `<SDL_opengl.h>` block is swapped
for `gl_shim.h` + `sdl_rw_shim.h`. The original block is preserved in the
`#else`.

**`miniz.h`** — same treatment for its SDL include, plus `MINIZ_LITTLE_ENDIAN`
is derived from `__BYTE_ORDER__` instead of `SDL_BYTEORDER`.

**`cl_tent.c`** — `CL_UpdateTEnts` forces the player's own lightning beam to
start at `cl_entities[cl.viewentity].origin`, i.e. the middle of the player
model. On a headset the gun is in your hand, so the bolt has to start there;
the hunk calls `QR_HandOrigin` (in `platform/in_null.c`) and falls back to
upstream's origin whenever the hand aim isn't live. This one could not be
absorbed by a shim: the override runs unconditionally inside the beam loop,
and the beam segments it feeds are ordinary `bolt.mdl` entities with nothing
to distinguish them downstream.

**`pr_cmds.c`** — `PF_setorigin` calls `QR_MuzzleSpawn` (in
`platform/in_null.c`) before writing the origin. Vanilla spawns each weapon's
missile at a per-weapon offset from the player *origin* — the middle of the
chest — while the gun is in the player's hand. This builtin is where that
position is decided, before `SV_LinkEdict` and before any physics, so
correcting it here is what makes the shot genuinely leave the barrel: the
trail starts there, the model is drawn there, and the missile flies a true
path from there, with
nothing to fold away afterwards. `QR_MuzzleSpawn` declines for anything that is
not a launch (not a player-owned missile, not the first placement after
`ED_ClearEdict`, not near the player, no tracked hand, muzzle implausibly far,
or the short trace out to it blocked), so the fallback *is* the normal case. It
does move where a shot comes from for collision, not only for the eye —
intended, for a port where you aim with your arm.

It replaces only the part of vanilla's spawn offset that centres the missile on
the body. The component along the aim's *horizontal right* vector is carried
over untouched, because that is the weapon's own firing pattern: the nailgun
alternates `v_right*±4` between its two attack frames, which is what makes it
fire two streams rather than one. `'0 0 16'` is vertical and `v_forward*8` lies
in the vertical plane through the aim, so neither contributes to that term —
the split is exact.

This replaced a client-side version in `cl_main.c` that could only shift what
was drawn, and so had to fold the shift away again over the first ~96 units;
the fold was visible as the projectile sliding back to the body line. Doing it
at the source removed that hunk, two cvars and about 170 lines.

**`net_dgrm.c`** — `_Datagram_SearchForHosts` fills the host cache from
`CCREP_SERVER_INFO` replies with `Q_strcpy`, which is unbounded
(`common.c`: `while (*src) *dest++ = *src++;`), out of `MSG_ReadString`'s
2048-byte buffer and into `hostcache_t`'s 16-byte `name` and `map` and
32-byte `cname`. A long server name on the LAN therefore runs through the
rest of the entry and on past `hostcache[7]`. The hunk makes the three
reply-derived copies `q_strlcpy` with the destination's own size; the
version-mismatch rebuild just below needs no guard, because upstream's
`cname[14] = 0` already caps it once `name` is bounded.

It earns a hunk on all three of the usual tests: the corruption happens at
its *source* inside packet handling, where no `platform/` shim can reach or
intercept it; the code runs unconditionally on every reply; and a bounded
copy is indistinguishable downstream, since every consumer already treats
those fields as 16 and 32 bytes and only a reply that would have overrun
behaves differently. What moved it from latent to worth patching is that
`slist` is no longer a console command nobody types — the window's Game tab
makes it a button in the product's main menu, so in a release build any
machine on the same Wi-Fi can reach the line on demand.

Everything else that would have needed a patch is instead absorbed by shims in
`Sources/QuakeCore/platform/`:

- **`gl_shim.h`** supplies GL scalar typedefs so `glquake.h` / `gl_texmgr.h` /
  `gl_model.h` parse without OpenGL. It also declares the eleven GL1
  immediate-mode calls that `sbar.c` and `view.c` make directly;
  `gl_stubs.c` no-ops them. That pair is the M2 to-do list.
- **`sdl_rw_shim.h/.c`** reimplements the six `SDL_RWops` calls `common.c`
  makes, over stdio. They are not for `quakespasm.pak` — that is a classic
  `PACK` archive (`App/Resources/quakespasm.pak` begins with the magic) read
  by `COM_LoadPackFile` through ordinary file I/O. The RWops calls are
  `LOC_LoadFile`'s, which reads the rerelease localization file either loose
  or out of `QuakeEX.kpf`, a real zip, through miniz — and miniz needs to seek
  inside it. The shim defines `USE_SDL2` so `common.c` takes the SDL2 branch,
  which matches what the shim implements.

## Merging a newer upstream

1. Diff the new upstream against `.upstream-rev` for the 45 vendored `.c` files
   and 72 headers; copy over.
2. Re-apply the `quakedef.h`, `miniz.h`, `cl_tent.c`, `pr_cmds.c` and
   `net_dgrm.c` hunks (search for `QAVP_PLATFORM`). Check the `net_dgrm.c`
   one against upstream first: if a newer QuakeSpasm has bounded those
   host-cache copies itself, drop the hunk rather than re-applying it.
3. `make check` — a clean link means no new symbols escaped into the renderer
   boundary. New undefined symbols are new renderer entry points that need
   stubbing in `r_null.c`.
