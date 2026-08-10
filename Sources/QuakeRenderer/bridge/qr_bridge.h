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

/* Texture manager -- real implementations behind the TexMgr_* shims. */
void QR_TexMgr_Init (void);
void QR_TexMgr_NewGame (void);
gltexture_t *QR_TexMgr_NewTexture (void);
gltexture_t *QR_TexMgr_LoadImage (qmodel_t *owner, const char *name,
				  int width, int height, enum srcformat format,
				  byte *data, const char *source_file,
				  src_offset_t source_offset, unsigned flags);
void QR_TexMgr_FreeTexturesForOwner (qmodel_t *owner);

#endif /* QR_BRIDGE_H */
