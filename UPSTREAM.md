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
lightmap building and surface polygon lists (`r_brush.c`), PVS marking and
texture chains (`r_world.c`), frustum/view setup (`gl_rmain.c`), and the
refdef/fov math plus cvar tables into `platform/r_null.c` (`gl_screen.c`,
`gl_rmisc.c`). When merging a newer upstream, diff those upstream files too
and carry relevant fixes into the ports; cvar defaults must stay
byte-identical.
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

Kept to an absolute minimum so upstream merges stay cheap. Two files, three
hunks, all guarded by `#ifdef QAVP_PLATFORM`:

**`quakedef.h`** — the `#include <SDL.h>` / `<SDL_opengl.h>` block is swapped
for `gl_shim.h` + `sdl_rw_shim.h`. The original block is preserved in the
`#else`.

**`miniz.h`** — same treatment for its SDL include, plus `MINIZ_LITTLE_ENDIAN`
is derived from `__BYTE_ORDER__` instead of `SDL_BYTEORDER`.

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
2. Re-apply the `quakedef.h` and `miniz.h` hunks (search for `QAVP_PLATFORM`).
3. `make check` — a clean link means no new symbols escaped into the renderer
   boundary. New undefined symbols are new renderer entry points that need
   stubbing in `r_null.c`.
