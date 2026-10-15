/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * qr_bridge.h -- engine-side interface to the Metal world renderer.
 *
 * Included by platform/r_null.c and platform/vid_null.c *after* quakedef.h
 * (the signatures below use engine types). Everything declared here must be
 * called on the engine thread; the Swift-facing consumer API lives in
 * QuakeCore.h and is what the render thread uses.
 *
 * The bridge is deliberately pure C with no Metal in it, so `make check`
 * compiles and links it on any host. It produces three things the Swift
 * renderer consumes: a texture upload queue, a static world vertex array,
 * and per-frame draw packets. See qr_bridge.c for the handoff contract.
 */

#ifndef QR_BRIDGE_H
#define QR_BRIDGE_H

/* For qc_hud_tile_t / QC_HUD_* below only -- QuakeCore.h is quakedef.h-free,
   so this doesn't drag engine internals in ahead of their normal include. */
#include "QuakeCore.h"

void QR_Init (void);
void QR_NewMap (void);

/* Frame lifecycle, driven by SCR_UpdateScreen via GL_Begin/EndRendering:
   BeginFrame claims a free packet slot, RenderView fills it (PVS walk +
   batch build), PublishFrame hands it to the render thread. A frame where
   RenderView never ran (console up, no world) publishes an empty packet,
   which the renderer draws as a plain clear. */
void QR_BeginFrame (void);
void QR_RenderView (void);
void QR_PublishFrame (void);

/* Returns true and writes the new size when the Swift side reported a
   drawable resize since the last call. vid_null.c feeds the result into
   glwidth/glheight + vid.recalc_refdef. */
qboolean QR_ConsumePendingDrawableSize (int *width, int *height);

/* Cvar callbacks and the "sky" console command, wired up by r_null.c's
   R_Init exactly where upstream's gl_rmisc.c / gl_sky.c registered them.
   (The Sky_* entry points themselves are declared in glquake.h.) */
void QR_SetWateralpha_f (cvar_t *var);
void QR_SetLavaalpha_f (cvar_t *var);
void QR_SetTelealpha_f (cvar_t *var);
void QR_SetSlimealpha_f (cvar_t *var);
void QR_SetSkyfog_f (cvar_t *var);
void Sky_SkyCommand_f (void);

/* Texture manager -- real implementations behind the TexMgr_* shims. */
void QR_TexMgr_Init (void);
void QR_TexMgr_NewGame (void);
gltexture_t *QR_TexMgr_NewTexture (void);
gltexture_t *QR_TexMgr_LoadImage (qmodel_t *owner, const char *name,
				  int width, int height, enum srcformat format,
				  byte *data, const char *source_file,
				  src_offset_t source_offset, unsigned flags);
void QR_TexMgr_FreeTexturesForOwner (qmodel_t *owner);

/* Runtime lighting (gl_rlight.c / gl_rsurf.c ports). */
extern int d_lightstylevalue[256];	/* 8.8 fraction; defined in qr_bridge.c */
void R_AnimateLight (void);

/* Global exp2 fog (gl_fog.c port). Fog_Init/GetDensity/GetColor/
   ParseServerMessage are declared in glquake.h; only Fog_Update is new. */
void Fog_Update (float density, float red, float green, float blue, float time);
void R_PushDlights (void);
void QR_DlightMarkOrigin (dlight_t *dl, vec3_t out);
qboolean QR_SurfaceNeedsRelight (msurface_t *surf, int framecount, int dynamic_on);
void R_RenderDynamicLightmaps (msurface_t *surf);
int  QR_FlushDirtyLightmaps (void);	/* re-upload dirty atlases; returns count */

/* Sprite models (gl_sprite.c ports). */
mspriteframe_t *QR_SpriteFrameSelect (msprite_t *psprite, int frame, float time);
mspriteframe_t *QR_SpriteFrame (entity_t *e);
void QR_SpriteBillboardAxes (int type, entity_t *e, vec3_t up, vec3_t right);

/* 2D HUD overlay geometry (pure quad layout; see qr_bridge.c). */
#define QR_OVERLAY_FLOATS_PER_VERT 9
void QR_CanvasXform (canvastype canvas, float out[4]);
void QR_GlyphCell (int ch, float uv[4]);
int  QR_FillVerts (float *out, int x, int y, int w, int h, const float col[4], const float xform[4]);
int  QR_PicVerts (float *out, int x, int y, int w, int h, const float uv[4], const float col[4], const float xform[4]);
int  QR_StringVerts (float *out, int x, int y, const char *s, const float col[4], const float xform[4]);

/* Draw_* backing -- appends to the building frame's overlay buffer; see
   qr_bridge.c. qr_draw_color is defined in gl_stubs.c (glColor4f/4fv). */
extern float qr_draw_color[4];
void QR_SetCanvas (canvastype canvas);
qpic_t *QR_DrawPicFromWad (const char *name);
void QR_DrawPic (int x, int y, qpic_t *pic);
void QR_DrawCharacter (int x, int y, int num);
void QR_DrawString (int x, int y, const char *str);
void QR_DrawFill (int x, int y, int w, int h, int c, float alpha);

/* Draw_CachePic's backing: the menu/console .lmp art, cached by name in
   storage that outlives Host_ClearMemory (see qr_bridge.c). Returns NULL for
   art that will not load -- r_null.c substitutes its dummy pic -- and
   complains once per name, not once per frame. QR_DrawNewGame empties the
   cache on a gamedir change, as upstream Draw_NewGame does. */
qpic_t *QR_DrawCachePic (const char *path);
void QR_DrawNewGame (void);

/* The remaining two real Draw_* bodies: the menu's half-black wash over the
   whole plane, and one pic stretched to an explicit size at a flat alpha
   (what Draw_ConsoleBackground needs, without mutating the cache entry). */
void QR_DrawFadeScreen (void);
void QR_DrawPicStretch (int x, int y, int w, int h, qpic_t *pic, float alpha);

/* Modular HUD (Phase 1): turns the vr_hud_<tile>_* cvars into per-tile
   placement. Pure except for the cvar reads; fills tile_id/anchor/offset/
   scale and clamps out-of-range anchor/scale, but leaves first_vert/
   vert_count/bbox_w/bbox_h at 0 -- QR_EmitHud (or its successors) sets
   those from the emitted overlay range. Visibility (vr_hud_<tile>_show) is
   NOT carried in qc_hud_tile_t -- see qr_hud_tile_visible, since
   vert_count == 0 is ambiguous between "hidden" and "nothing to draw this
   frame" (e.g. full ammo/health). */
void QR_ResolveHudLayout (qc_hud_tile_t t[QC_HUD_TILE_COUNT]);

/* The rest of the 2D layer -- menu, console, intermission scoreboards, notify
   lines -- appended to the building frame's overlay buffer as one tracked
   range (qc_frame_t.screen2d_first_vert/vert_count). Called from
   SCR_UpdateScreen's 2D point, after V_RenderView and before V_UpdateBlend,
   so it also runs on frames with no world where V_RenderView returns early
   and no HUD emitter runs at all. Engine thread, inside the engine's own
   frame: M_Draw and Con_DrawConsole are engine entry points and this is
   where upstream's gl_screen.c calls them. */
void QR_EmitScreen2D (void);

/* The per-tile emitter (QR_EmitTile, Phase 1 Task 2) stays file-static in
   qr_bridge.c: it takes the file-local qr_frame_slot_t, and its only
   callers -- QR_EmitModularHud (Task 3) and the QAVP_HOSTCHECK test hook
   QR_TestEmitTileInto -- live in that file too. It reuses the engine's own
   Sbar_DrawNum/Sbar_DrawFace (declared extern in qr_bridge.c; sbar.h only
   exposes the whole-bar entry points) under a tile-local canvas offset so
   each tile's authentic art lands at local (0,0). */

#endif /* QR_BRIDGE_H */
