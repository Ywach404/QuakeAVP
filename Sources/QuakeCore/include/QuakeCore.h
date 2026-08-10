/*
 * QuakeCore.h -- the entire C surface Swift is allowed to touch.
 *
 * Everything else in this library is QuakeSpasm internals. Keep this header
 * free of quakedef.h so the bridging header stays cheap and Swift never sees
 * `byte`, `qboolean`, or a 400-symbol namespace.
 */

#ifndef QUAKECORE_H
#define QUAKECORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Engine stdout/stderr. Called on whatever thread the host loop runs on. */
typedef void (*qc_log_fn)(void *ctx, const char *text);

/* Fatal error, or NULL for a clean Sys_Quit. The process exits right after
   this returns, so hand the text off; do not try to resume. */
typedef void (*qc_error_fn)(void *ctx, const char *error_or_null);

void QC_SetCallbacks (qc_log_fn log, qc_error_fn err, void *ctx);

/*
 * basedir  -- directory containing id1/ (the app bundle's Resources, or a
 *             user-picked folder holding pak0.pak).
 * userdir  -- writable directory for config.cfg and savegames
 *             (Application Support/QuakeAVP).
 * Must be called before QC_Init.
 */
void QC_SetPaths (const char *basedir, const char *userdir);

/*
 * Boot the engine. argv is a Quake-style command line, e.g.
 * {"-basedir", "...", "+map", "start"}. Returns false if init bailed.
 */
bool QC_Init (int argc, const char * const *argv);

/* Advance the simulation by `dt` seconds. Safe to call at display rate. */
void QC_Frame (double dt);

void QC_Shutdown (void);

/* Push a console command, e.g. "map e1m1\n". */
void QC_ExecuteCommand (const char *text);

/* True once Host_Init has completed successfully. */
bool QC_IsRunning (void);

/* Engine version string, for the about pane. */
const char *QC_VersionString (void);

/*
 * ---------------------------------------------------------------------------
 * Renderer bridge (produced by Sources/QuakeRenderer/bridge/qr_bridge.c).
 *
 * The engine thread produces; exactly one render thread consumes. Every
 * Acquire below takes an internal lock or transfers ownership; the engine is
 * never blocked on the GPU -- the only contention windows are pointer swaps,
 * plus a one-per-map geometry copy. All Acquire/Release pairs must be called
 * from the same (render) thread and must not nest with themselves.
 * ---------------------------------------------------------------------------
 */

/* Texture upload records. Pixels are always RGBA8. */
enum {
	QC_TEXFLAG_MIPMAP  = 1 << 0,	/* generate a mip chain after upload */
	QC_TEXFLAG_NEAREST = 1 << 1,	/* nearest-neighbour filtering */
	QC_TEXFLAG_CLAMP   = 1 << 2	/* clamp-to-edge (default is repeat) */
};

typedef struct qc_texture_upload_s {
	uint32_t	texnum;		/* engine-side handle, never 0 */
	uint32_t	width, height;
	uint32_t	flags;		/* QC_TEXFLAG_* */
	const void	*rgba;		/* width*height*4 bytes */
} qc_texture_upload_t;

/* Takes ownership of everything queued since the last acquire; returns the
   count and points *out at an array valid until the matching Release, which
   frees the pixel data. Returns 0 (and *out = NULL) when nothing is queued. */
int  QC_RendererAcquireUploads (const qc_texture_upload_t **out);
void QC_RendererReleaseUploads (void);

/* Texture handles the engine has freed; drop the GPU objects. Same
   ownership-transfer contract as the upload queue. */
int  QC_RendererAcquireTextureFrees (const uint32_t **out);
void QC_RendererReleaseTextureFrees (void);

/* Static world geometry, rebuilt at map load. Layout matches World.metal.
   Acquire returns the map generation (0 = no map) and holds the geometry
   lock until Release, so copy into a GPU buffer and get out quickly --
   a map load on the engine thread blocks on this lock. */
typedef struct qc_world_vertex_s {
	float	xyz[3];
	float	st[2];		/* diffuse texcoords (wrapping) */
	float	lm_st[2];	/* lightmap atlas texcoords */
} qc_world_vertex_t;

uint32_t QC_RendererAcquireGeometry (const qc_world_vertex_t **verts,
				     uint32_t *count);
void QC_RendererReleaseGeometry (void);

/* One draw batch: a run of triangle-list indices sharing textures. */
typedef struct qc_draw_batch_s {
	uint32_t	texnum;		/* diffuse texture handle */
	uint32_t	lightmap;	/* lightmap texture handle, 0 = fullbright */
	uint32_t	first_index;
	uint32_t	index_count;
} qc_draw_batch_t;

typedef struct qc_frame_s {
	uint32_t	generation;	/* must match AcquireGeometry's result */
	float		viewproj[16];	/* column-major, Metal depth range */
	float		clear_color[4];
	uint32_t	num_indices;
	const uint32_t	*indices;	/* into the geometry vertex array */
	uint32_t	num_batches;
	const qc_draw_batch_t *batches;
} qc_frame_t;

/* Latest published frame, or NULL if none is newer than the last acquire.
   The slot stays locked against reuse until Release. */
const qc_frame_t *QC_RendererAcquireFrame (void);
void QC_RendererReleaseFrame (void);

/* Report the drawable size in pixels. Callable from any thread; the engine
   picks it up at the next frame and recalculates the refdef. */
void QC_RendererSetDrawableSize (int width, int height);

#ifdef __cplusplus
}
#endif

#endif /* QUAKECORE_H */
