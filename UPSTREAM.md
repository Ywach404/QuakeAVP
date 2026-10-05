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
| `gl_vidsdl.c` `main_sdl.c` `in_sdl.c` `snd_sdl.c` `cd_sdl.c` `sys_sdl_unix.c` `sys_sdl_win.c` | SDL platform layer. Replaced by `platform/`. |
| `net_win.c` `net_wins.c` `net_wipx.c` `pl_win.c` | Windows-only. |
| `pl_linux.c` | X11 clipboard/icon. Replaced by `platform/pl_null.c`. |
| `pl_osx.m` | AppKit. Not applicable to visionOS, but worth re-reading when the clipboard is wired up. |
| `snd_flac.c` `snd_mikmod.c` `snd_modplug.c` `snd_mp3.c` `snd_mp3tag.c` `snd_mpg123.c` `snd_opus.c` `snd_umx.c` `snd_vorbis.c` `snd_xmp.c` | Optional codecs, all needing third-party libs. `snd_wave.c` is kept. |

Two files kept despite their misleading names: **`gl_model.c`** (BSP/MDL/SPR
parsing — the server needs it for collision hulls) and **`gl_refrag.c`**
(efrag list management — pure logic).

`lodepng.c` is present but **not compiled as its own translation unit** — it is
`#include`d by `image.c`, exactly as upstream does it. It's excluded in both
`project.yml` and `tools/check-core.sh`; keep those in sync.

## Patches applied to vendored files

Kept to an absolute minimum so upstream merges stay cheap. Four files, five
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
chest — while the gun is in my hand. This builtin is where that position is
decided, before `SV_LinkEdict` and before any physics, so correcting it here is
what makes the shot genuinely leave the barrel: the trail starts there, the
model is drawn there, and the missile flies a true path from there, with
nothing to fold away afterwards. `QR_MuzzleSpawn` declines for anything that is
not a launch (not a player-owned missile, not the first placement after
`ED_ClearEdict`, not near the player, no tracked hand, muzzle implausibly far,
or the short trace out to it blocked), so the fallback *is* the normal case. It
does move where a shot comes from for collision, not only for the eye —
intended, for a port where you aim with your arm.

This replaced a client-side version in `cl_main.c` that could only shift what
was drawn, and so had to fold the shift away again over the first ~96 units;
the fold was visible as the projectile sliding back to the body line. Doing it
at the source removed that hunk, two cvars and about 170 lines.

Everything else that would have needed a patch is instead absorbed by shims in
`Sources/QuakeCore/platform/`:

- **`gl_shim.h`** supplies GL scalar typedefs so `glquake.h` / `gl_texmgr.h` /
  `gl_model.h` parse without OpenGL. It also declares the eleven GL1
  immediate-mode calls that `sbar.c` and `view.c` make directly;
  `gl_stubs.c` no-ops them. That pair is the M2 to-do list.
- **`sdl_rw_shim.h/.c`** reimplements the six `SDL_RWops` calls `common.c`
  makes to read `quakespasm.pak` (a zip) through miniz. It defines `USE_SDL2`
  so `common.c` takes the SDL2 branch, which matches what the shim implements.

## Merging a newer upstream

1. Diff the new upstream against `.upstream-rev` for the 45 vendored `.c` files
   and 72 headers; copy over.
2. Re-apply the `quakedef.h`, `miniz.h`, `cl_tent.c` and `pr_cmds.c` hunks
   (search for `QAVP_PLATFORM`).
3. `make check` — a clean link means no new symbols escaped into the renderer
   boundary. New undefined symbols are new renderer entry points that need
   stubbing in `r_null.c`.
