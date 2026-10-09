/*
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

#endif /* QR_BRIDGE_H */
