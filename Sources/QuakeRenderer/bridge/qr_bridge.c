/*
 * qr_bridge.c -- engine-side half of the Metal world renderer.
 *
 * This file is the C producer the Swift/Metal consumer in Sources/QuakeRenderer
 * feeds from. It ports the load-time and per-frame world logic from upstream
 * QuakeSpasm 0.97 (gl_texmgr.c, r_brush.c, r_world.c, gl_rmain.c, gl_rlight.c
 * at commit d27b64cf) with the GL calls replaced by three lock-guarded
 * handoff structures declared in QuakeCore.h:
 *
 *   - a texture upload queue (RGBA pixels, ownership transfers on acquire)
 *   - a static world vertex array, rebuilt per map under a geometry lock
 *   - triple-buffered frame packets: view-projection matrix + triangle-list
 *     indices + draw batches, one slot filled per engine frame
 *
 * Threading contract: everything here except the QC_Renderer* consumer API
 * runs on the engine thread. The consumer (one render thread) never blocks
 * the engine except for pointer-swap-length critical sections, plus the
 * geometry lock which it holds for one buffer copy per map load. The engine
 * never waits on the GPU: if the consumer is slow, publishing a new packet
 * simply retires the previous unconsumed one.
 *
 * Deliberately pure C, no Metal: `make check` compiles and links this on any
 * host, which keeps the renderer boundary honest (see tools/check-core.sh).
 */

#include "quakedef.h"
#include "QuakeCore.h"
#include "qr_bridge.h"

#include <pthread.h>
#include <stdlib.h>

/* upstream keeps this in r_brush.c, not a header */
#define MAX_SANITY_LIGHTMAPS (1u<<20)

/* renderer-owned cvars glquake.h doesn't extern; defined in r_null.c */
extern cvar_t gl_fullbrights, gl_overbright, r_oldskyleaf, r_clearcolor, gl_farclip;
extern cvar_t r_skyalpha, r_skyfog, vr_worldscale;
extern cvar_t r_lerpmodels, r_lerpmove, gl_overbright_models;
extern cvar_t phase, phase_time, phase_color;
extern cvar_t vr_vignette, vr_vignette_threshold;

/* head-follow ledger, owned by in_null.c on the engine thread */
extern float qr_head_absorbed[2];
extern uint32_t qr_recenter_count;
extern cvar_t vr_lean_limit;

/* weapon-wheel state, owned by in_null.c on the engine thread */
extern float qr_wheel_frac;
extern int qr_wheel_has_anchor;
extern float qr_wheel_anchor[3];
extern int qr_wheel_highlight;
extern float qr_head[3];		/* body-frame head offset from recenter */
extern float qr_height_trim;		/* eye-height trim, Quake units */

/* vr_worldscale's default and clamp range: ~1 inch per Quake unit, and the
   0.8x-1.2x band the comfort theory-craft allows before the world reads as
   miniature or gigantic. The sim stays in Quake units; only the consumer's
   matrix composition scales. */
#define QR_WORLDSCALE_DEFAULT	0.0254f
#define QR_WORLDSCALE_MIN	(0.8f * QR_WORLDSCALE_DEFAULT)
#define QR_WORLDSCALE_MAX	(1.2f * QR_WORLDSCALE_DEFAULT)

/* Extra culling fov on top of what the consumer reports, covering one frame
   of head rotation before the engine sees the new pose. A fast head turn is
   ~300 deg/s; at 90 Hz that is ~3.3 deg, so 10 gives margin to spare. */
#define QR_CULL_FOV_MARGIN	10.0f

/* The dissolve radius at the bottom of the phase range: arm's reach, in
   Quake units (~0.8 m). The sweep grows exponentially from here to the
   world diagonal -- see the phase block in QR_RenderView. */
#define QR_PHASE_NEAR_RADIUS	32.0f

/* ========================================================================
 * globals the engine headers declare and upstream's renderer defined
 * ===================================================================== */

mleaf_t		*r_viewleaf, *r_oldviewleaf;
int		r_visframecount;
int		d_lightstylevalue[256];	/* 8.8 fraction of base light value */
mplane_t	frustum[4];

texture_t	*r_notexture_mip, *r_notexture_mip2; /* set by gl_model.c */

unsigned int	d_8to24table[256];
unsigned int	d_8to24table_fbright[256];
unsigned int	d_8to24table_fbright_fence[256];
unsigned int	d_8to24table_nobright[256];
unsigned int	d_8to24table_nobright_fence[256];
unsigned int	d_8to24table_conchars[256];

gltexture_t	*notexture;
gltexture_t	*nulltexture;

static float	r_fovx, r_fovy;

/* ========================================================================
 * handoff structures -- the only state both threads touch
 * ===================================================================== */

typedef struct qr_upload_queue_s {
	qc_texture_upload_t	*items;
	int			count, capacity;
} qr_upload_queue_t;

static qr_upload_queue_t	qr_pending_uploads;	/* engine appends */
static qr_upload_queue_t	qr_held_uploads;	/* consumer holds */
static pthread_mutex_t		qr_upload_lock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t		*qr_pending_frees;
static int		qr_pending_frees_count, qr_pending_frees_capacity;
static uint32_t		*qr_held_frees;
static int		qr_held_frees_count;
static pthread_mutex_t	qr_free_lock = PTHREAD_MUTEX_INITIALIZER;

/* Alias mesh handoff: same ownership-transfer idiom as the texture queues.
   The engine queues malloc'd copies at model load; the consumer acquires,
   builds MTLBuffers, releases (which frees the copies). */
typedef struct qr_mesh_queue_s {
	qc_mesh_upload_t	*items;
	int			count, capacity;
} qr_mesh_queue_t;

static qr_mesh_queue_t	qr_pending_meshes;	/* engine appends */
static qr_mesh_queue_t	qr_held_meshes;		/* consumer holds */
static uint32_t		*qr_pending_mesh_frees;
static int		qr_pending_mesh_frees_count, qr_pending_mesh_frees_capacity;
static uint32_t		*qr_held_mesh_frees;
static int		qr_held_mesh_frees_count;
static pthread_mutex_t	qr_mesh_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t		qr_next_meshnum = 1;

/* World geometry. The lock is held by the consumer only for its once-per-map
   copy into an MTLBuffer, and by the engine while rebuilding at map load. */
static qc_world_vertex_t	*qr_world_verts;
static uint32_t			qr_world_numverts;
static uint32_t			qr_map_generation;
static pthread_mutex_t		qr_geometry_lock = PTHREAD_MUTEX_INITIALIZER;

/* Frame packets. Three slots suffice: the consumer holds at most one INUSE
   and releasing parks it back in READY (a consumer ticking faster than the
   engine re-renders the latest packet rather than presenting nothing -- the
   compositor can run at 120 Hz against the engine's 90), so at most two
   slots are READY+INUSE and a FREE slot always exists when BeginFrame
   looks. `seq` orders READY slots so latest still wins. */
enum { QR_SLOT_FREE, QR_SLOT_BUILDING, QR_SLOT_READY, QR_SLOT_INUSE };

typedef struct qr_frame_slot_s {
	qc_frame_t	frame;
	uint32_t	*indices;
	uint32_t	index_capacity;
	qc_draw_batch_t	*batches;
	uint32_t	batch_capacity;
	qc_entity_t	*entities;
	uint32_t	entity_capacity;
	float		*text_verts;		/* 9 floats/vert, grown as needed */
	uint32_t	text_capacity;		/* in floats */
	int		state;
	uint64_t	seq;
} qr_frame_slot_t;

static qr_frame_slot_t	qr_slots[3];
static int		qr_building = -1;
static uint64_t		qr_frame_seq;
static pthread_mutex_t	qr_frame_lock = PTHREAD_MUTEX_INITIALIZER;

/* Worst-case index count for the current world, computed at map load so
   BeginFrame can size a slot without mid-frame reallocation. */
static uint32_t		qr_index_worst_case;

/* Phase effect state: the linear progress the easing runs on, and the
   world's bounding diagonal (the radius that dissolves everything from any
   head position on the map). */
static float		qr_phase_value;
static float		qr_world_diagonal;

/* Submodels owned by func_door_secret entities, parsed from the entities
   lump at map load. Brush entities using one get QC_ENTFLAG_PHASED and
   dissolve with the world: a secret door hanging in the air after the wall
   around it melts would give the secret away. */
#define QR_MAX_SECRET_SUBMODELS	256
static int		qr_secret_submodels[QR_MAX_SECRET_SUBMODELS];
static int		qr_secret_submodel_count;

static int		qr_pending_drawable_w, qr_pending_drawable_h;
static qboolean		qr_drawable_dirty;
static pthread_mutex_t	qr_drawable_lock = PTHREAD_MUTEX_INITIALIZER;

/* Culling fov override, degrees; 0 = none (refdef fov applies). Written by
   the consumer when the immersive layer knows its merged binocular frustum,
   read once per engine frame. */
static float		qr_cull_fovx, qr_cull_fovy;
static int		qr_cull_omni;	/* PVS-only, no frustum (immersive) */
static pthread_mutex_t	qr_cullfov_lock = PTHREAD_MUTEX_INITIALIZER;

void QC_RendererSetDrawableSize (int width, int height)
{
	pthread_mutex_lock (&qr_drawable_lock);
	if (width > 0 && height > 0 &&
	    (width != qr_pending_drawable_w || height != qr_pending_drawable_h))
	{
		qr_pending_drawable_w = width;
		qr_pending_drawable_h = height;
		qr_drawable_dirty = true;
	}
	pthread_mutex_unlock (&qr_drawable_lock);
}

void QC_RendererSetCullingFov (float fovx_deg, float fovy_deg)
{
	pthread_mutex_lock (&qr_cullfov_lock);
	qr_cull_fovx = fovx_deg;
	qr_cull_fovy = fovy_deg;
	pthread_mutex_unlock (&qr_cullfov_lock);
}

qboolean QR_ConsumePendingDrawableSize (int *width, int *height)
{
	qboolean dirty;

	pthread_mutex_lock (&qr_drawable_lock);
	dirty = qr_drawable_dirty;
	if (dirty)
	{
		*width = qr_pending_drawable_w;
		*height = qr_pending_drawable_h;
		qr_drawable_dirty = false;
	}
	pthread_mutex_unlock (&qr_drawable_lock);
	return dirty;
}

/* ========================================================================
 * gl_texmgr.c -- texture manager
 *
 * Ported minus everything that existed to appease GL1 hardware: no
 * power-of-two resampling, no picmip, no gl_max_size clamping, no CPU
 * mipmap generation (the consumer builds mip chains on the GPU). Textures
 * upload at source size, which Metal is happy with.
 *
 * One MTLTexture per Quake texture rather than an atlas: world textures
 * need wrapping samplers, which an atlas can't provide without moving the
 * wrap into the shader, and a few hundred textures is nothing to Metal.
 * The gltexture_t source_file/source_offset bookkeeping is preserved so a
 * streaming/deferred uploader can replace the eager malloc copies later
 * without touching callers.
 * ===================================================================== */

#define QR_MAX_GLTEXTURES	4096
static gltexture_t	qr_gltextures[QR_MAX_GLTEXTURES];
static gltexture_t	*active_gltextures, *free_gltextures;
static int		numgltextures;
static uint32_t		qr_next_texnum = 1;

/*
================
QR_EnqueueUpload -- hand finished RGBA pixels to the consumer.

Takes a private copy: the source is hunk memory that TexMgr_LoadImage frees
on return. Zero-sized images (warpimages while gl_warpimagesize is 0) are
recorded engine-side but never uploaded.
================
*/
static void QR_EnqueueUpload (gltexture_t *glt, const unsigned *rgba)
{
	qc_texture_upload_t *up;
	size_t bytes;
	void *copy;

	if (!glt->width || !glt->height || !rgba)
		return;

	bytes = (size_t)glt->width * glt->height * 4;
	copy = malloc (bytes);
	if (!copy)
		Sys_Error ("QR_EnqueueUpload: out of memory (%u x %u)",
			   glt->width, glt->height);
	memcpy (copy, rgba, bytes);

	pthread_mutex_lock (&qr_upload_lock);
	if (qr_pending_uploads.count == qr_pending_uploads.capacity)
	{
		qr_pending_uploads.capacity = qr_pending_uploads.capacity ?
					      qr_pending_uploads.capacity * 2 : 64;
		qr_pending_uploads.items = (qc_texture_upload_t *)
			realloc (qr_pending_uploads.items,
				 qr_pending_uploads.capacity * sizeof(qc_texture_upload_t));
	}
	up = &qr_pending_uploads.items[qr_pending_uploads.count++];
	up->texnum = glt->texnum;
	up->width = glt->width;
	up->height = glt->height;
	up->rgba = copy;
	up->flags = 0;
	if (glt->flags & TEXPREF_MIPMAP)
		up->flags |= QC_TEXFLAG_MIPMAP;
	if (glt->flags & TEXPREF_NEAREST)
		up->flags |= QC_TEXFLAG_NEAREST;
	if (glt->source_format == SRC_LIGHTMAP)
		up->flags |= QC_TEXFLAG_CLAMP;
	pthread_mutex_unlock (&qr_upload_lock);
}

static void QR_EnqueueFree (uint32_t texnum)
{
	pthread_mutex_lock (&qr_free_lock);
	if (qr_pending_frees_count == qr_pending_frees_capacity)
	{
		qr_pending_frees_capacity = qr_pending_frees_capacity ?
					    qr_pending_frees_capacity * 2 : 64;
		qr_pending_frees = (uint32_t *)
			realloc (qr_pending_frees,
				 qr_pending_frees_capacity * sizeof(uint32_t));
	}
	qr_pending_frees[qr_pending_frees_count++] = texnum;
	pthread_mutex_unlock (&qr_free_lock);
}

int QC_RendererAcquireUploads (const qc_texture_upload_t **out)
{
	pthread_mutex_lock (&qr_upload_lock);
	qr_held_uploads = qr_pending_uploads;
	memset (&qr_pending_uploads, 0, sizeof(qr_pending_uploads));
	pthread_mutex_unlock (&qr_upload_lock);

	*out = qr_held_uploads.count ? qr_held_uploads.items : NULL;
	return qr_held_uploads.count;
}

void QC_RendererReleaseUploads (void)
{
	int i;

	for (i = 0; i < qr_held_uploads.count; i++)
		free ((void *)qr_held_uploads.items[i].rgba);
	free (qr_held_uploads.items);
	memset (&qr_held_uploads, 0, sizeof(qr_held_uploads));
}

/*
================
QR_EnqueueMeshUpload -- hand a built alias mesh to the consumer.

Takes ownership of the three malloc'd arrays; they are freed on the
consumer's Release. Returns the mesh handle.
================
*/
static uint32_t QR_EnqueueMeshUpload (uint32_t numposes, uint32_t numverts,
				      uint32_t numindexes,
				      qc_mesh_vertex_t *vertices, float *st,
				      uint16_t *indexes)
{
	qc_mesh_upload_t *up;
	uint32_t meshnum;

	pthread_mutex_lock (&qr_mesh_lock);
	if (qr_pending_meshes.count == qr_pending_meshes.capacity)
	{
		qr_pending_meshes.capacity = qr_pending_meshes.capacity ?
					     qr_pending_meshes.capacity * 2 : 16;
		qr_pending_meshes.items = (qc_mesh_upload_t *)
			realloc (qr_pending_meshes.items,
				 qr_pending_meshes.capacity * sizeof(qc_mesh_upload_t));
	}
	meshnum = qr_next_meshnum++;
	up = &qr_pending_meshes.items[qr_pending_meshes.count++];
	up->meshnum = meshnum;
	up->numposes = numposes;
	up->numverts = numverts;
	up->numindexes = numindexes;
	up->vertices = vertices;
	up->st = st;
	up->indexes = indexes;
	pthread_mutex_unlock (&qr_mesh_lock);
	return meshnum;
}

static void QR_EnqueueMeshFree (uint32_t meshnum)
{
	if (!meshnum)
		return;
	pthread_mutex_lock (&qr_mesh_lock);
	if (qr_pending_mesh_frees_count == qr_pending_mesh_frees_capacity)
	{
		qr_pending_mesh_frees_capacity = qr_pending_mesh_frees_capacity ?
						 qr_pending_mesh_frees_capacity * 2 : 16;
		qr_pending_mesh_frees = (uint32_t *)
			realloc (qr_pending_mesh_frees,
				 qr_pending_mesh_frees_capacity * sizeof(uint32_t));
	}
	qr_pending_mesh_frees[qr_pending_mesh_frees_count++] = meshnum;
	pthread_mutex_unlock (&qr_mesh_lock);
}

int QC_RendererAcquireMeshUploads (const qc_mesh_upload_t **out)
{
	pthread_mutex_lock (&qr_mesh_lock);
	qr_held_meshes = qr_pending_meshes;
	memset (&qr_pending_meshes, 0, sizeof(qr_pending_meshes));
	pthread_mutex_unlock (&qr_mesh_lock);

	*out = qr_held_meshes.count ? qr_held_meshes.items : NULL;
	return qr_held_meshes.count;
}

void QC_RendererReleaseMeshUploads (void)
{
	int i;

	for (i = 0; i < qr_held_meshes.count; i++)
	{
		free ((void *)qr_held_meshes.items[i].vertices);
		free ((void *)qr_held_meshes.items[i].st);
		free ((void *)qr_held_meshes.items[i].indexes);
	}
	free (qr_held_meshes.items);
	memset (&qr_held_meshes, 0, sizeof(qr_held_meshes));
}

int QC_RendererAcquireMeshFrees (const uint32_t **out)
{
	pthread_mutex_lock (&qr_mesh_lock);
	qr_held_mesh_frees = qr_pending_mesh_frees;
	qr_held_mesh_frees_count = qr_pending_mesh_frees_count;
	qr_pending_mesh_frees = NULL;
	qr_pending_mesh_frees_count = qr_pending_mesh_frees_capacity = 0;
	pthread_mutex_unlock (&qr_mesh_lock);

	*out = qr_held_mesh_frees_count ? qr_held_mesh_frees : NULL;
	return qr_held_mesh_frees_count;
}

void QC_RendererReleaseMeshFrees (void)
{
	free (qr_held_mesh_frees);
	qr_held_mesh_frees = NULL;
	qr_held_mesh_frees_count = 0;
}

int QC_RendererAcquireTextureFrees (const uint32_t **out)
{
	pthread_mutex_lock (&qr_free_lock);
	qr_held_frees = qr_pending_frees;
	qr_held_frees_count = qr_pending_frees_count;
	qr_pending_frees = NULL;
	qr_pending_frees_count = qr_pending_frees_capacity = 0;
	pthread_mutex_unlock (&qr_free_lock);

	*out = qr_held_frees_count ? qr_held_frees : NULL;
	return qr_held_frees_count;
}

void QC_RendererReleaseTextureFrees (void)
{
	free (qr_held_frees);
	qr_held_frees = NULL;
	qr_held_frees_count = 0;
}

/*
=================
TexMgr_LoadPalette -- port of upstream; fills the six derived palettes
=================
*/
static void QR_LoadPalette (void)
{
	byte *pal, *src, *dst;
	int i, mark;
	FILE *f;

	COM_FOpenFile ("gfx/palette.lmp", &f, NULL);
	if (!f)
		Sys_Error ("Couldn't load gfx/palette.lmp");

	mark = Hunk_LowMark ();
	pal = (byte *) Hunk_Alloc (768);
	if (!fread(pal, 768, 1, f))
		Sys_Error ("Failed reading gfx/palette.lmp");
	fclose(f);

	/* standard palette, 255 is transparent */
	dst = (byte *)d_8to24table;
	src = pal;
	for (i = 0; i < 256; i++)
	{
		*dst++ = *src++;
		*dst++ = *src++;
		*dst++ = *src++;
		*dst++ = 255;
	}
	((byte *) &d_8to24table[255]) [3] = 0;

	/* fullbright palette, 0-223 are black (for additive blending) */
	src = pal + 224*3;
	dst = (byte *) &d_8to24table_fbright[224];
	for (i = 224; i < 256; i++)
	{
		*dst++ = *src++;
		*dst++ = *src++;
		*dst++ = *src++;
		*dst++ = 255;
	}
	for (i = 0; i < 224; i++)
	{
		dst = (byte *) &d_8to24table_fbright[i];
		dst[3] = 255;
		dst[2] = dst[1] = dst[0] = 0;
	}

	/* nobright palette, 224-255 are black (for additive blending) */
	dst = (byte *)d_8to24table_nobright;
	src = pal;
	for (i = 0; i < 256; i++)
	{
		*dst++ = *src++;
		*dst++ = *src++;
		*dst++ = *src++;
		*dst++ = 255;
	}
	for (i = 224; i < 256; i++)
	{
		dst = (byte *) &d_8to24table_nobright[i];
		dst[3] = 255;
		dst[2] = dst[1] = dst[0] = 0;
	}

	/* fullbright palette, for fence textures */
	memcpy(d_8to24table_fbright_fence, d_8to24table_fbright, 256*4);
	d_8to24table_fbright_fence[255] = 0; /* Alpha of zero. */

	/* nobright palette, for fence textures */
	memcpy(d_8to24table_nobright_fence, d_8to24table_nobright, 256*4);
	d_8to24table_nobright_fence[255] = 0; /* Alpha of zero. */

	/* conchars palette, 0 and 255 are transparent */
	memcpy(d_8to24table_conchars, d_8to24table, 256*4);
	((byte *) &d_8to24table_conchars[0]) [3] = 0;

	Hunk_FreeToLowMark (mark);
}

gltexture_t *QR_TexMgr_NewTexture (void)
{
	gltexture_t *glt;

	if (!free_gltextures)
		Sys_Error ("QR_TexMgr_NewTexture: cache full, max is %d textures",
			   QR_MAX_GLTEXTURES);

	glt = free_gltextures;
	free_gltextures = glt->next;
	glt->next = active_gltextures;
	active_gltextures = glt;

	glt->texnum = qr_next_texnum++;
	numgltextures++;
	return glt;
}

static gltexture_t *QR_FindTexture (qmodel_t *owner, const char *name)
{
	gltexture_t *glt;

	if (name)
	{
		for (glt = active_gltextures; glt; glt = glt->next)
		{
			if (glt->owner == owner && !strcmp (glt->name, name))
				return glt;
		}
	}
	return NULL;
}

static void QR_FreeTexture (gltexture_t *kill)
{
	gltexture_t *glt;

	if (kill == NULL)
	{
		Con_Printf ("QR_FreeTexture: NULL texture\n");
		return;
	}

	if (active_gltextures == kill)
	{
		active_gltextures = kill->next;
		kill->next = free_gltextures;
		free_gltextures = kill;
		QR_EnqueueFree (kill->texnum);
		numgltextures--;
		return;
	}

	for (glt = active_gltextures; glt; glt = glt->next)
	{
		if (glt->next == kill)
		{
			glt->next = kill->next;
			kill->next = free_gltextures;
			free_gltextures = kill;
			QR_EnqueueFree (kill->texnum);
			numgltextures--;
			return;
		}
	}

	Con_Printf ("QR_FreeTexture: not found\n");
}

static void QR_FreeTextures (unsigned int flags, unsigned int mask)
{
	gltexture_t *glt, *next;

	for (glt = active_gltextures; glt; glt = next)
	{
		next = glt->next;
		if ((glt->flags & mask) == (flags & mask))
			QR_FreeTexture (glt);
	}
}

void QR_TexMgr_FreeTexturesForOwner (qmodel_t *owner)
{
	gltexture_t *glt, *next;

	for (glt = active_gltextures; glt; glt = next)
	{
		next = glt->next;
		if (glt && glt->owner == owner)
			QR_FreeTexture (glt);
	}
}

void QR_TexMgr_NewGame (void)
{
	QR_FreeTextures (0, TEXPREF_PERSIST);
	QR_LoadPalette ();
}

/*
================
QR_8to32
================
*/
static unsigned *QR_8to32 (byte *in, int pixels, unsigned int *usepal)
{
	int i;
	unsigned *out, *data;

	out = data = (unsigned *) Hunk_Alloc (pixels*4);
	for (i = 0; i < pixels; i++)
		*out++ = usepal[*in++];
	return data;
}

/*
===============
QR_AlphaEdgeFix -- port of TexMgr_AlphaEdgeFix

eliminate pink edges on sprites, etc.
operates in place on 32bit data
===============
*/
static void QR_AlphaEdgeFix (byte *data, int width, int height)
{
	int i, j, n = 0, b, c[3] = {0,0,0},
		lastrow, thisrow, nextrow,
		lastpix, thispix, nextpix;
	byte *dest = data;

	for (i = 0; i < height; i++)
	{
		lastrow = (i == 0) ? height-1 : i-1;
		thisrow = i;
		nextrow = (i == height-1) ? 0 : i+1;

		for (j = 0; j < width; j++, dest += 4)
		{
			if (dest[3]) /* not transparent */
				continue;

			lastpix = (j == 0) ? width-1 : j-1;
			thispix = j;
			nextpix = (j == width-1) ? 0 : j+1;

			b = (lastrow*width+lastpix)*4; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
			b = (thisrow*width+lastpix)*4; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
			b = (nextrow*width+lastpix)*4; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
			b = (lastrow*width+thispix)*4; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
			b = (nextrow*width+thispix)*4; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
			b = (lastrow*width+nextpix)*4; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
			b = (thisrow*width+nextpix)*4; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
			b = (nextrow*width+nextpix)*4; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}

			/* average all non-transparent neighbors */
			if (n)
			{
				dest[0] = (byte)(c[0]/n);
				dest[1] = (byte)(c[1]/n);
				dest[2] = (byte)(c[2]/n);

				n = c[0] = c[1] = c[2] = 0;
			}
		}
	}
}

/*
=================
QR_LoadMiptexPalette -- port of TexMgr_LoadMiptexPalette
=================
*/
static void QR_LoadMiptexPalette (byte *in, byte *out, int colors, unsigned flags)
{
	int i;

	for (i = 0; i < colors; i++)
	{
		*out++ = *in++;
		*out++ = *in++;
		*out++ = *in++;
		if (i == 255 && flags & TEXPREF_ALPHA)
			*out++ = 0;
		else
			*out++ = 255;
	}
}

/*
================
QR_LoadImage8 -- handles 8bit source data; port of TexMgr_LoadImage8
minus the power-of-two padding, which Metal doesn't need
================
*/
static void QR_LoadImage8 (gltexture_t *glt, byte *data, unsigned int *usepal)
{
	int i;

	/* HACK HACK HACK -- taken from tomazquake */
	if (strstr(glt->name, "shot1sid") &&
	    glt->width == 32 && glt->height == 32 &&
	    CRC_Block(data, 1024) == 65393)
	{
		/* This texture in b_shell1.bsp has some of the first 32 pixels painted white.
		   They are invisible in software, but look really ugly in GL. So we just copy
		   32 pixels from the bottom to make it look nice. */
		memcpy (data, data + 32*31, 32);
	}

	/* detect false alpha cases */
	if (glt->flags & TEXPREF_ALPHA && !(glt->flags & TEXPREF_CONCHARS))
	{
		for (i = 0; i < (int) (glt->width * glt->height); i++)
			if (data[i] == 255) /* transparent index */
				break;
		if (i == (int) (glt->width * glt->height))
			glt->flags -= TEXPREF_ALPHA;
	}

	/* choose palette */
	if (!usepal)
	{
		if (glt->flags & TEXPREF_FULLBRIGHT)
		{
			if (glt->flags & TEXPREF_ALPHA)
				usepal = d_8to24table_fbright_fence;
			else
				usepal = d_8to24table_fbright;
		}
		else if (glt->flags & TEXPREF_NOBRIGHT && gl_fullbrights.value)
		{
			if (glt->flags & TEXPREF_ALPHA)
				usepal = d_8to24table_nobright_fence;
			else
				usepal = d_8to24table_nobright;
		}
		else if (glt->flags & TEXPREF_CONCHARS)
		{
			usepal = d_8to24table_conchars;
		}
		else
		{
			usepal = d_8to24table;
		}
	}

	/* convert to 32bit */
	data = (byte *) QR_8to32 (data, glt->width * glt->height, usepal);

	/* fix edges */
	if (glt->flags & TEXPREF_ALPHA)
		QR_AlphaEdgeFix (data, glt->width, glt->height);

	QR_EnqueueUpload (glt, (unsigned *)data);
}

/*
================
QR_LoadImage8Valve -- port of TexMgr_LoadImage8Valve
================
*/
static void QR_LoadImage8Valve (gltexture_t *glt, byte *data)
{
	byte *in, *usepal;
	unsigned short colors;

	in = data + glt->source_width * glt->source_height;

	memcpy (&colors, in, 2);
	colors = LittleShort (colors);

	usepal = (byte *)Hunk_Alloc (colors * 4);
	QR_LoadMiptexPalette (in + 2, usepal, colors, glt->flags);
	QR_LoadImage8 (glt, data, (unsigned *)usepal);
}

/*
================
QR_TexMgr_LoadImage -- the one entry point for loading all textures;
port of TexMgr_LoadImage with the upload replaced by the queue
================
*/
gltexture_t *QR_TexMgr_LoadImage (qmodel_t *owner, const char *name,
				  int width, int height, enum srcformat format,
				  byte *data, const char *source_file,
				  src_offset_t source_offset, unsigned flags)
{
	unsigned short crc;
	gltexture_t *glt;
	int mark;

	if (isDedicated)
		return NULL;

	/* cache check */
	if (width > 0 && height > 0)
	{
		switch (format)
		{
		case SRC_INDEXED:
		case SRC_INDEXED_PALETTE:
			crc = CRC_Block(data, width * height);
			break;
		case SRC_LIGHTMAP:
			crc = CRC_Block(data, width * height * 4);
			break;
		case SRC_RGBA:
			crc = CRC_Block(data, width * height * 4);
			break;
		default: /* not reachable but avoids compiler warnings */
			crc = 0;
		}
	}
	else
		crc = 0;

	if ((flags & TEXPREF_OVERWRITE) && (glt = QR_FindTexture (owner, name)))
	{
		if (glt->source_crc == crc)
			return glt;
	}
	else
		glt = QR_TexMgr_NewTexture ();

	/* copy data */
	glt->owner = owner;
	q_strlcpy (glt->name, name ? name : "", sizeof(glt->name));
	glt->width = width;
	glt->height = height;
	glt->flags = flags;
	glt->shirt = -1;
	glt->pants = -1;
	q_strlcpy (glt->source_file, source_file ? source_file : "",
		   sizeof(glt->source_file));
	glt->source_offset = source_offset;
	glt->source_format = format;
	glt->source_width = width;
	glt->source_height = height;
	glt->source_crc = crc;

	/* convert and hand to the consumer */
	mark = Hunk_LowMark();

	if (width > 0 && height > 0)
	{
		switch (glt->source_format)
		{
		case SRC_INDEXED:
			QR_LoadImage8 (glt, data, NULL);
			break;
		case SRC_LIGHTMAP:
		case SRC_RGBA:
			QR_EnqueueUpload (glt, (unsigned *)data);
			break;
		case SRC_INDEXED_PALETTE:
			QR_LoadImage8Valve (glt, data);
			break;
		}
	}

	Hunk_FreeToLowMark(mark);

	return glt;
}

void QR_TexMgr_Init (void)
{
	int i;
	static byte notexture_data[16] = {159,91,83,255,0,0,0,255,0,0,0,255,159,91,83,255}; /* black and pink checker */
	static byte nulltexture_data[16] = {127,191,255,255,0,0,0,255,0,0,0,255,127,191,255,255}; /* black and blue checker */

	/* init texture list */
	free_gltextures = &qr_gltextures[0];
	active_gltextures = NULL;
	for (i = 0; i < QR_MAX_GLTEXTURES - 1; i++)
		qr_gltextures[i].next = &qr_gltextures[i+1];
	qr_gltextures[i].next = NULL;
	numgltextures = 0;

	QR_LoadPalette ();

	/* upstream's 2x2 checker patterns, so broken texture lookups are
	   loudly visible instead of invisible */
	notexture = QR_TexMgr_LoadImage (NULL, "notexture", 2, 2, SRC_RGBA,
		notexture_data, "", (src_offset_t)notexture_data,
		TEXPREF_NEAREST | TEXPREF_PERSIST | TEXPREF_NOPICMIP);
	nulltexture = QR_TexMgr_LoadImage (NULL, "nulltexture", 2, 2, SRC_RGBA,
		nulltexture_data, "", (src_offset_t)nulltexture_data,
		TEXPREF_NEAREST | TEXPREF_PERSIST | TEXPREF_NOPICMIP);
}

/* ========================================================================
 * r_brush.c -- lightmap atlases and surface polygon lists (map load)
 * ===================================================================== */

struct lightmap_s	*lightmaps;
int			lightmap_count;
int			gl_lightmap_format = 0, lightmap_bytes = 4;

static int	allocated[LMBLOCK_WIDTH];
static int	last_lightmap_allocated;

static unsigned	blocklights[LMBLOCK_WIDTH*LMBLOCK_HEIGHT*3];

static mvertex_t	*r_pcurrentvertbase;
static qmodel_t		*currentmodel;

/*
================
R_TextureAnimation -- returns the proper texture for a given time and base
================
*/
texture_t *R_TextureAnimation (texture_t *base, int frame)
{
	int	relative;
	int	count;

	if (frame)
		if (base->alternate_anims)
			base = base->alternate_anims;

	if (!base->anim_total)
		return base;

	relative = (int)(cl.time*10) % base->anim_total;

	count = 0;
	while (base->anim_min > relative || base->anim_max <= relative)
	{
		base = base->anim_next;
		if (!base)
			Sys_Error ("R_TextureAnimation: broken cycle");
		if (++count > 100)
			Sys_Error ("R_TextureAnimation: infinite cycle");
	}

	return base;
}

/*
========================
AllocBlock -- returns a texture number and the position inside it
========================
*/
static int AllocBlock (int w, int h, int *x, int *y)
{
	int		i, j;
	int		best, best2;
	int		texnum;

	for (texnum = last_lightmap_allocated; texnum < MAX_SANITY_LIGHTMAPS; texnum++)
	{
		if (texnum == lightmap_count)
		{
			lightmap_count++;
			lightmaps = (struct lightmap_s *) realloc (lightmaps,
					sizeof(*lightmaps)*lightmap_count);
			memset (&lightmaps[texnum], 0, sizeof(lightmaps[texnum]));
			lightmaps[texnum].data = (byte *) calloc (1,
					4*LMBLOCK_WIDTH*LMBLOCK_HEIGHT);
			/* as we're only tracking one texture, we don't need
			   multiple copies of allocated any more */
			memset (allocated, 0, sizeof(allocated));
		}
		best = LMBLOCK_HEIGHT;

		for (i = 0; i < LMBLOCK_WIDTH-w; i++)
		{
			best2 = 0;

			for (j = 0; j < w; j++)
			{
				if (allocated[i+j] >= best)
					break;
				if (allocated[i+j] > best2)
					best2 = allocated[i+j];
			}
			if (j == w)
			{	/* this is a valid spot */
				*x = i;
				*y = best = best2;
			}
		}

		if (best + h > LMBLOCK_HEIGHT)
			continue;

		for (i = 0; i < w; i++)
			allocated[*x + i] = best + h;

		last_lightmap_allocated = texnum;
		return texnum;
	}

	Sys_Error ("AllocBlock: full");
	return 0;
}

/*
===============
R_BuildLightMap -- combine and scale multiple lightmaps into RGBA

Ported minus dynamic lights and the 10-bit path. Because there is no
runtime lightmap re-upload yet, styled lights bake at their default value
(d_lightstylevalue 256); see the roadmap.
===============
*/
void R_BuildLightMap (msurface_t *surf, byte *dest, int stride)
{
	const int overbright = !!gl_overbright.value;

	int		smax, tmax;
	unsigned	r, g, b;
	int		i, j, size;
	byte		*lightmap;
	unsigned	scale;
	int		maps;
	unsigned	*bl;

	smax = (surf->extents[0]>>4)+1;
	tmax = (surf->extents[1]>>4)+1;
	size = smax*tmax;
	lightmap = surf->samples;

	if (cl.worldmodel->lightdata)
	{
	/* clear to no light */
		memset (&blocklights[0], 0, size * 3 * sizeof (unsigned int));

	/* add all the lightmaps */
		if (lightmap)
		{
			for (maps = 0; maps < MAXLIGHTMAPS && surf->styles[maps] != 255; maps++)
			{
				scale = d_lightstylevalue[surf->styles[maps]];
				surf->cached_light[maps] = scale;	/* 8.8 fraction */
				bl = blocklights;
				for (i = 0; i < size; i++)
				{
					*bl++ += *lightmap++ * scale;
					*bl++ += *lightmap++ * scale;
					*bl++ += *lightmap++ * scale;
				}
			}
		}
	}
	else
	{
	/* set to full bright if no light data */
		memset (&blocklights[0], 255, size * 3 * sizeof (unsigned int));
	}

/* bound, invert, and shift */
	stride -= smax * 4;
	bl = blocklights;
	for (i = 0; i < tmax; i++, dest += stride)
	{
		for (j = 0; j < smax; j++)
		{
			if (overbright)
			{
				r = *bl++ >> 8;
				g = *bl++ >> 8;
				b = *bl++ >> 8;
			}
			else
			{
				r = *bl++ >> 7;
				g = *bl++ >> 7;
				b = *bl++ >> 7;
			}
			*dest++ = (r > 255)? 255 : r;
			*dest++ = (g > 255)? 255 : g;
			*dest++ = (b > 255)? 255 : b;
			*dest++ = 255;
		}
	}
}

/*
========================
GL_CreateSurfaceLightmap
========================
*/
static void GL_CreateSurfaceLightmap (msurface_t *surf)
{
	int		smax, tmax;
	byte	*base;

	if (surf->flags & SURF_DRAWTILED)
	{
		surf->lightmaptexturenum = -1;
		return;
	}

	smax = (surf->extents[0]>>4)+1;
	tmax = (surf->extents[1]>>4)+1;

	surf->lightmaptexturenum = AllocBlock (smax, tmax, &surf->light_s, &surf->light_t);
	base = lightmaps[surf->lightmaptexturenum].data;
	base += (surf->light_t * LMBLOCK_WIDTH + surf->light_s) * lightmap_bytes;
	R_BuildLightMap (surf, base, LMBLOCK_WIDTH*lightmap_bytes);
}

/*
================
BuildSurfaceDisplayList -- called at level load time
================
*/
static void BuildSurfaceDisplayList (msurface_t *fa)
{
	int			i, lindex, lnumverts;
	medge_t		*pedges, *r_pedge;
	float		*vec;
	float		s, t, s0, t0, sdiv, tdiv;
	glpoly_t	*poly;

/* reconstruct the polygon */
	pedges = currentmodel->edges;
	lnumverts = fa->numedges;

	poly = (glpoly_t *) Hunk_Alloc (sizeof(glpoly_t) + (lnumverts-4) * VERTEXSIZE*sizeof(float));
	poly->next = fa->polys;
	fa->polys = poly;
	poly->numverts = lnumverts;

	if (fa->flags & SURF_DRAWTURB)
	{
		/* match Mod_PolyForUnlitSurface */
		s0 = t0 = 0.f;
		sdiv = tdiv = 128.f;
	}
	else
	{
		s0 = fa->texinfo->vecs[0][3];
		t0 = fa->texinfo->vecs[1][3];
		sdiv = fa->texinfo->texture->width;
		tdiv = fa->texinfo->texture->height;
	}

	for (i = 0; i < lnumverts; i++)
	{
		lindex = currentmodel->surfedges[fa->firstedge + i];

		if (lindex > 0)
		{
			r_pedge = &pedges[lindex];
			vec = r_pcurrentvertbase[r_pedge->v[0]].position;
		}
		else
		{
			r_pedge = &pedges[-lindex];
			vec = r_pcurrentvertbase[r_pedge->v[1]].position;
		}
		s = DotProduct (vec, fa->texinfo->vecs[0]) + s0;
		s /= sdiv;

		t = DotProduct (vec, fa->texinfo->vecs[1]) + t0;
		t /= tdiv;

		VectorCopy (vec, poly->verts[i]);
		poly->verts[i][3] = s;
		poly->verts[i][4] = t;

		/* Q64 RERELEASE texture shift */
		if (fa->texinfo->texture->shift > 0)
		{
			poly->verts[i][3] /= ( 2 * fa->texinfo->texture->shift);
			poly->verts[i][4] /= ( 2 * fa->texinfo->texture->shift);
		}

		/* lightmap texture coordinates */
		s = DotProduct (vec, fa->texinfo->vecs[0]) + fa->texinfo->vecs[0][3];
		s -= fa->texturemins[0];
		s += fa->light_s*16;
		s += 8;
		s /= LMBLOCK_WIDTH*16;

		t = DotProduct (vec, fa->texinfo->vecs[1]) + fa->texinfo->vecs[1][3];
		t -= fa->texturemins[1];
		t += fa->light_t*16;
		t += 8;
		t /= LMBLOCK_HEIGHT*16;

		poly->verts[i][5] = s;
		poly->verts[i][6] = t;
	}

	poly->numverts = lnumverts;
}

/*
==================
GL_BuildLightmaps -- called at level load time; builds the lightmap
atlases for all surfaces from all brush models
==================
*/
void GL_BuildLightmaps (void)
{
	char	name[24];
	int		i, j;
	struct lightmap_s *lm;
	qmodel_t	*m;

	r_framecount = 1; /* no dlightcache */

	/* wipe out all the lightmap data (the gltexture objects were already
	   freed by Mod_ClearAll) */
	for (i = 0; i < lightmap_count; i++)
		free (lightmaps[i].data);
	free (lightmaps);
	lightmaps = NULL;
	last_lightmap_allocated = 0;
	lightmap_count = 0;

	for (j = 1; j < MAX_MODELS; j++)
	{
		m = cl.model_precache[j];
		if (!m)
			break;
		if (m->name[0] == '*')
			continue;
		r_pcurrentvertbase = m->vertexes;
		currentmodel = m;
		for (i = 0; i < m->numsurfaces; i++)
		{
			if (m->surfaces[i].flags & SURF_DRAWTILED)
				continue;
			GL_CreateSurfaceLightmap (m->surfaces + i);
			BuildSurfaceDisplayList (m->surfaces + i);
		}
	}

	/* upload all lightmaps that were filled */
	for (i = 0; i < lightmap_count; i++)
	{
		lm = &lightmaps[i];
		lm->modified = false;
		lm->rectchange.l = LMBLOCK_WIDTH;
		lm->rectchange.t = LMBLOCK_HEIGHT;
		lm->rectchange.w = 0;
		lm->rectchange.h = 0;

		sprintf (name, "lightmap%07i", i);
		lm->texture = QR_TexMgr_LoadImage (cl.worldmodel, name,
				LMBLOCK_WIDTH, LMBLOCK_HEIGHT, SRC_LIGHTMAP,
				lm->data, "", (src_offset_t)lm->data,
				TEXPREF_LINEAR | TEXPREF_NOPICMIP);
	}
}

/*
==================
QR_BuildWorldVertexArray -- flatten every surface polygon into the shared
vertex array the consumer copies into an MTLBuffer; port of
GL_BuildBModelVertexBuffer. glpoly verts are 7 floats (xyz s1t1 s2t2),
which is exactly qc_world_vertex_t, so surfaces copy wholesale.
==================
*/
static void QR_BuildWorldVertexArray (void)
{
	unsigned int	numverts, varray_index;
	int		i, j;
	qmodel_t	*m;
	qc_world_vertex_t *varray;

	numverts = 0;
	for (j = 1; j < MAX_MODELS; j++)
	{
		m = cl.model_precache[j];
		if (!m || m->name[0] == '*' || m->type != mod_brush)
			continue;
		for (i = 0; i < m->numsurfaces; i++)
			numverts += m->surfaces[i].numedges;
	}

	varray = (qc_world_vertex_t *) malloc (numverts * sizeof(qc_world_vertex_t));
	if (!varray && numverts)
		Sys_Error ("QR_BuildWorldVertexArray: out of memory (%u verts)", numverts);
	varray_index = 0;

	for (j = 1; j < MAX_MODELS; j++)
	{
		m = cl.model_precache[j];
		if (!m || m->name[0] == '*' || m->type != mod_brush)
			continue;
		for (i = 0; i < m->numsurfaces; i++)
		{
			msurface_t *s = &m->surfaces[i];
			s->vbo_firstvert = varray_index;
			if (s->polys)
				memcpy (&varray[varray_index], s->polys->verts,
					s->numedges * sizeof(qc_world_vertex_t));
			varray_index += s->numedges;
		}
	}

	pthread_mutex_lock (&qr_geometry_lock);
	free (qr_world_verts);
	qr_world_verts = varray;
	qr_world_numverts = varray_index;
	qr_map_generation++;
	pthread_mutex_unlock (&qr_geometry_lock);
}

uint32_t QC_RendererAcquireGeometry (const qc_world_vertex_t **verts, uint32_t *count)
{
	pthread_mutex_lock (&qr_geometry_lock);
	*verts = qr_world_verts;
	*count = qr_world_numverts;
	return qr_map_generation;
}

void QC_RendererReleaseGeometry (void)
{
	pthread_mutex_unlock (&qr_geometry_lock);
}

/* ========================================================================
 * gl_sky.c -- sky texture loading and skybox state
 *
 * The load-time half of upstream gl_sky.c, ported as-is. The draw-time
 * half (Sky_DrawSky's flat pass + far-quad GEQUAL trick) is not: those
 * existed because GL1 couldn't project cloud UVs per pixel. Here sky
 * surfaces are emitted as QC_BATCH_SKY geometry and World.metal computes
 * Sky_GetTexCoord's projection per fragment, which keeps sky at the sky
 * surfaces' real depth -- same occlusion behaviour, no depth trickery.
 * ===================================================================== */

static gltexture_t	*solidskytexture, *alphaskytexture;
static gltexture_t	*skybox_textures[6];
static char		skybox_name[1024];	/* "" = no skybox */
static float		skyflatcolor[3];	/* for r_fastsky, unported */
static float		skyfog;

static const int	skytexorder[6] = {0,2,1,3,4,5};

/*
=============
Sky_LoadTexture

A sky texture is 256*128, with the left side being a masked overlay
==============
*/
void Sky_LoadTexture (qmodel_t *mod, texture_t *mt)
{
	char		texturename[64];
	unsigned	x, y, p, r, g, b, count, halfwidth, *rgba;
	byte		*src, *front_data, *back_data;

	if (mt->width != 256 || mt->height != 128)
	{
		Con_Warning ("Sky texture %s is %d x %d, expected 256 x 128\n", mt->name, mt->width, mt->height);
		if (mt->width < 2 || mt->height < 1)
			return;
	}

	halfwidth = mt->width / 2;
	back_data = (byte *) Hunk_AllocName (halfwidth*mt->height*2, "skytex");
	front_data = back_data + halfwidth*mt->height;
	src = (byte *)(mt + 1);

// extract back layer and upload
	for (y=0 ; y<mt->height ; y++)
		memcpy (back_data + y*halfwidth, src + halfwidth + y*mt->width, halfwidth);

	q_snprintf(texturename, sizeof(texturename), "%s:%s_back", mod->name, mt->name);
	solidskytexture = QR_TexMgr_LoadImage (mod, texturename, halfwidth, mt->height, SRC_INDEXED, back_data, "", (src_offset_t)back_data, TEXPREF_NONE);

// extract front layer and upload
	r = g = b = count = 0;
	for (y=0 ; y<mt->height ; src+=mt->width, front_data+=halfwidth, y++)
	{
		for (x=0 ; x<halfwidth ; x++)
		{
			p = src[x];
			if (p == 0)
				p = 255;
			else
			{
				rgba = &d_8to24table[p];
				r += ((byte *)rgba)[0];
				g += ((byte *)rgba)[1];
				b += ((byte *)rgba)[2];
				count++;
			}
			front_data[x] = p;
		}
	}

	front_data = back_data + halfwidth*mt->height;
	q_snprintf(texturename, sizeof(texturename), "%s:%s_front", mod->name, mt->name);
	alphaskytexture = QR_TexMgr_LoadImage (mod, texturename, halfwidth, mt->height, SRC_INDEXED, front_data, "", (src_offset_t)front_data, TEXPREF_ALPHA);

// calculate r_fastsky color based on average of all opaque foreground colors
	skyflatcolor[0] = (float)r/(count*255);
	skyflatcolor[1] = (float)g/(count*255);
	skyflatcolor[2] = (float)b/(count*255);
}

/*
==================
Sky_LoadSkyBox
==================
*/
static const char *suf[6] = {"rt", "bk", "lf", "ft", "up", "dn"};
void Sky_LoadSkyBox (const char *name)
{
	int		i, mark, width, height;
	char	filename[MAX_OSPATH];
	byte	*data;
	qboolean nonefound = true;

	if (strcmp(skybox_name, name) == 0)
		return; //no change

	//purge old textures
	for (i=0; i<6; i++)
	{
		if (skybox_textures[i] && skybox_textures[i] != notexture)
			QR_FreeTexture (skybox_textures[i]);
		skybox_textures[i] = NULL;
	}

	//turn off skybox if sky is set to ""
	if (name[0] == 0)
	{
		skybox_name[0] = 0;
		return;
	}

	//load textures
	for (i=0; i<6; i++)
	{
		mark = Hunk_LowMark ();
		q_snprintf (filename, sizeof(filename), "gfx/env/%s%s", name, suf[i]);
		data = Image_LoadImage (filename, &width, &height);
		if (data)
		{
			skybox_textures[i] = QR_TexMgr_LoadImage (cl.worldmodel, filename, width, height, SRC_RGBA, data, filename, 0, TEXPREF_NONE);
			nonefound = false;
		}
		else
		{
			Con_Printf ("Couldn't load %s\n", filename);
			skybox_textures[i] = notexture;
		}
		Hunk_FreeToLowMark (mark);
	}

	if (nonefound) // go back to scrolling sky if skybox is totally missing
	{
		for (i=0; i<6; i++)
		{
			if (skybox_textures[i] && skybox_textures[i] != notexture)
				QR_FreeTexture (skybox_textures[i]);
			skybox_textures[i] = NULL;
		}
		skybox_name[0] = 0;
		return;
	}

	q_strlcpy(skybox_name, name, sizeof(skybox_name));
}

/*
=================
Sky_ClearAll

Called on map unload/game change to avoid keeping pointers to freed data
=================
*/
void Sky_ClearAll (void)
{
	int i;

	skybox_name[0] = 0;
	for (i=0; i<6; i++)
		skybox_textures[i] = NULL;
	solidskytexture = NULL;
	alphaskytexture = NULL;
	Cvar_SetQuick (&r_skyfog, r_skyfog.default_string);
}

/*
=================
Sky_NewMap
=================
*/
void Sky_NewMap (void)
{
	char	key[128], value[4096];
	const char	*data;

	skyfog = r_skyfog.value;

	//
	// read worldspawn (this is so ugly, and shouldn't it be done on the server?)
	//
	data = cl.worldmodel->entities;
	if (!data)
		return; //FIXME: how could this possibly ever happen? -- if there's no
	// worldspawn then the sever wouldn't send the loadmap message to the client

	data = COM_Parse(data);
	if (!data) //should never happen
		return; // error
	if (com_token[0] != '{') //should never happen
		return; // error
	while (1)
	{
		data = COM_Parse(data);
		if (!data)
			return; // error
		if (com_token[0] == '}')
			break; // end of worldspawn
		if (com_token[0] == '_')
			q_strlcpy(key, com_token + 1, sizeof(key));
		else
			q_strlcpy(key, com_token, sizeof(key));
		while (key[0] && key[strlen(key)-1] == ' ') // remove trailing spaces
			key[strlen(key)-1] = 0;
		data = COM_ParseEx(data, CPE_ALLOWTRUNC);
		if (!data)
			return; // error
		q_strlcpy(value, com_token, sizeof(value));

		if (!strcmp("sky", key))
			Sky_LoadSkyBox(value);

		if (!strcmp("skyfog", key))
			skyfog = atof(value);
#if 1 /* also accept non-standard keys */
		else if (!strcmp("skyname", key)) //half-life
			Sky_LoadSkyBox(value);
		else if (!strcmp("qlsky", key)) //quake lives
			Sky_LoadSkyBox(value);
#endif
	}
}

/*
=================
Sky_SkyCommand_f
=================
*/
void Sky_SkyCommand_f (void)
{
	switch (Cmd_Argc())
	{
	case 1:
		Con_Printf("\"sky\" is \"%s\"\n", skybox_name);
		break;
	case 2:
		Sky_LoadSkyBox(Cmd_Argv(1));
		break;
	default:
		Con_Printf("usage: sky <skyname>\n");
	}
}

/*
====================
QR_SetSkyfog_f -- ericw (upstream R_SetSkyfog_f)
====================
*/
void QR_SetSkyfog_f (cvar_t *var)
{
// clear any skyfog setting from worldspawn
	skyfog = var->value;
}

/* ========================================================================
 * gl_rmisc.c -- water alpha plumbing
 *
 * map_* mirror the cvars but can be overridden per map by worldspawn keys;
 * the cvar callbacks (registered in r_null.c's R_Init) keep them in sync
 * when the user changes a cvar mid-map. Straight port.
 * ===================================================================== */

float	map_wateralpha, map_lavaalpha, map_telealpha, map_slimealpha;

void QR_SetWateralpha_f (cvar_t *var)	{ map_wateralpha = var->value; }
void QR_SetLavaalpha_f (cvar_t *var)	{ map_lavaalpha = var->value; }
void QR_SetTelealpha_f (cvar_t *var)	{ map_telealpha = var->value; }
void QR_SetSlimealpha_f (cvar_t *var)	{ map_slimealpha = var->value; }

/*
====================
GL_WaterAlphaForSurface -- ericw
====================
*/
float GL_WaterAlphaForSurface (msurface_t *fa)
{
	if (fa->flags & SURF_DRAWLAVA)
		return map_lavaalpha > 0 ? map_lavaalpha : map_wateralpha;
	else if (fa->flags & SURF_DRAWTELE)
		return map_telealpha > 0 ? map_telealpha : map_wateralpha;
	else if (fa->flags & SURF_DRAWSLIME)
		return map_slimealpha > 0 ? map_slimealpha : map_wateralpha;
	else
		return map_wateralpha;
}

/*
=============
QR_ParseWorldspawn -- upstream R_ParseWorldspawn, called at map load
=============
*/
/*
================
QR_ParseSecretSubmodels -- collect the '*N' submodels owned by
func_door_secret entities. Classnames live server-side; the entities lump
is the one place the renderer can learn which doors are secrets, and it
is authoritative for the local games this app runs.
================
*/
static void QR_ParseSecretSubmodels (void)
{
	char		key[128];
	char		classname[64], model[64];
	const char	*data;

	qr_secret_submodel_count = 0;

	data = cl.worldmodel->entities;
	while (data && (data = COM_Parse (data)) != NULL)
	{
		if (com_token[0] != '{')
			break;
		classname[0] = model[0] = 0;
		while (1)
		{
			data = COM_Parse (data);
			if (!data)
				return;
			if (com_token[0] == '}')
				break;
			q_strlcpy (key, com_token, sizeof(key));
			data = COM_ParseEx (data, CPE_ALLOWTRUNC);
			if (!data)
				return;
			if (!strcmp (key, "classname"))
				q_strlcpy (classname, com_token, sizeof(classname));
			else if (!strcmp (key, "model"))
				q_strlcpy (model, com_token, sizeof(model));
		}
		if (!strcmp (classname, "func_door_secret") && model[0] == '*' &&
		    qr_secret_submodel_count < QR_MAX_SECRET_SUBMODELS)
			qr_secret_submodels[qr_secret_submodel_count++] = atoi (model + 1);
	}
}

static void QR_ParseWorldspawn (void)
{
	char key[128], value[4096];
	const char *data;

	map_wateralpha = r_wateralpha.value;
	map_lavaalpha = r_lavaalpha.value;
	map_telealpha = r_telealpha.value;
	map_slimealpha = r_slimealpha.value;

	data = COM_Parse(cl.worldmodel->entities);
	if (!data)
		return; // error
	if (com_token[0] != '{')
		return; // error

	while (1)
	{
		data = COM_Parse(data);
		if (!data)
			return; // error
		if (com_token[0] == '}')
			break; // end of worldspawn
		if (com_token[0] == '_')
			q_strlcpy(key, com_token + 1, sizeof(key));
		else
			q_strlcpy(key, com_token, sizeof(key));
		while (key[0] && key[strlen(key)-1] == ' ') // remove trailing spaces
			key[strlen(key)-1] = 0;
		data = COM_ParseEx(data, CPE_ALLOWTRUNC);
		if (!data)
			return; // error
		q_strlcpy(value, com_token, sizeof(value));

		if (!strcmp("wateralpha", key))
			map_wateralpha = atof(value);

		if (!strcmp("lavaalpha", key))
			map_lavaalpha = atof(value);

		if (!strcmp("telealpha", key))
			map_telealpha = atof(value);

		if (!strcmp("slimealpha", key))
			map_slimealpha = atof(value);
	}
}

/* ========================================================================
 * gl_rmain.c / r_world.c -- per-frame view setup, PVS marking, culling
 * ===================================================================== */

byte *SV_FatPVS (vec3_t org, qmodel_t *worldmodel);

static int SignbitsForPlane (mplane_t *out)
{
	int	bits, j;

	/* for fast box on planeside test */
	bits = 0;
	for (j = 0; j < 3; j++)
	{
		if (out->normal[j] < 0)
			bits |= 1<<j;
	}
	return bits;
}

/*
===============
TurnVector -- turn forward towards side on the plane defined by forward and side
===============
*/
void TurnVector (vec3_t out, const vec3_t forward, const vec3_t side, float angle)
{
	float scale_forward, scale_side;

	scale_forward = cos( DEG2RAD( angle ) );
	scale_side = sin( DEG2RAD( angle ) );

	out[0] = scale_forward*forward[0] + scale_side*side[0];
	out[1] = scale_forward*forward[1] + scale_side*side[1];
	out[2] = scale_forward*forward[2] + scale_side*side[2];
}

static void R_SetFrustum (float fovx, float fovy)
{
	int		i;

	TurnVector(frustum[0].normal, vpn, vright, fovx/2 - 90); /* left plane */
	TurnVector(frustum[1].normal, vpn, vright, 90 - fovx/2); /* right plane */
	TurnVector(frustum[2].normal, vpn, vup, 90 - fovy/2); /* bottom plane */
	TurnVector(frustum[3].normal, vpn, vup, fovy/2 - 90); /* top plane */

	for (i = 0; i < 4; i++)
	{
		frustum[i].type = PLANE_ANYZ;
		frustum[i].dist = DotProduct (r_origin, frustum[i].normal);
		frustum[i].signbits = SignbitsForPlane (&frustum[i]);
	}
}

qboolean R_CullBox (vec3_t emins, vec3_t emaxs)
{
	int i;
	mplane_t *p;
	/* Omnidirectional pass (immersive): the head looks anywhere the moment
	   after we cull, so a body-forward frustum would wrongly discard
	   everything behind the gaze -- the world "falls out" as you turn. Cull
	   by PVS alone; over-drawing the potentially-visible set is cheap. */
	if (qr_cull_omni)
		return false;
	for (i = 0; i < 4; i++)
	{
		p = frustum + i;
		switch (p->signbits)
		{
		default:
		case 0: if (p->normal[0]*emaxs[0] + p->normal[1]*emaxs[1] + p->normal[2]*emaxs[2] < p->dist) return true; break;
		case 1: if (p->normal[0]*emins[0] + p->normal[1]*emaxs[1] + p->normal[2]*emaxs[2] < p->dist) return true; break;
		case 2: if (p->normal[0]*emaxs[0] + p->normal[1]*emins[1] + p->normal[2]*emaxs[2] < p->dist) return true; break;
		case 3: if (p->normal[0]*emins[0] + p->normal[1]*emins[1] + p->normal[2]*emaxs[2] < p->dist) return true; break;
		case 4: if (p->normal[0]*emaxs[0] + p->normal[1]*emaxs[1] + p->normal[2]*emins[2] < p->dist) return true; break;
		case 5: if (p->normal[0]*emins[0] + p->normal[1]*emaxs[1] + p->normal[2]*emins[2] < p->dist) return true; break;
		case 6: if (p->normal[0]*emaxs[0] + p->normal[1]*emins[1] + p->normal[2]*emins[2] < p->dist) return true; break;
		case 7: if (p->normal[0]*emins[0] + p->normal[1]*emins[1] + p->normal[2]*emins[2] < p->dist) return true; break;
		}
	}
	return false;
}

/*
================
R_BackFaceCull -- returns true if the surface is facing away from vieworg
================
*/
static qboolean R_BackFaceCull (msurface_t *surf)
{
	double dot;

	if (surf->plane->type < 3)
		dot = r_refdef.vieworg[surf->plane->type] - surf->plane->dist;
	else
		dot = DotProduct (r_refdef.vieworg, surf->plane->normal) - surf->plane->dist;

	if ((dot < 0) ^ !!(surf->flags & SURF_PLANEBACK))
		return true;

	return false;
}

/*
===============
R_MarkSurfaces -- mark surfaces based on PVS and rebuild texture chains

Port of r_world.c minus efrags (no entities drawn yet), dynamic lightmap
updates, and warp texture bookkeeping.
===============
*/
void R_MarkSurfaces (void)
{
	byte		*vis;
	mleaf_t		*leaf;
	msurface_t	*surf, **mark;
	int			i, j;
	qboolean	nearwaterportal;

	/* check this leaf for water portals */
	nearwaterportal = false;
	for (i = 0, mark = r_viewleaf->firstmarksurface; i < r_viewleaf->nummarksurfaces; i++, mark++)
		if ((*mark)->flags & SURF_DRAWTURB)
			nearwaterportal = true;

	/* choose vis data. Omnidirectional (immersive) renders the WHOLE level,
	   not the current leaf's PVS: the head translates freely as it turns and
	   climbs, so a position-based visibility set pops and rebuilds as the eye
	   crosses leaves, and drops the floor beneath you when you stand on a box
	   (its PVS was baked without that vantage). Drawing every leaf is cheap
	   for Quake maps and the only thing that holds the world together when you
	   can look anywhere from anywhere. */
	if (r_novis.value || qr_cull_omni || r_viewleaf->contents == CONTENTS_SOLID || r_viewleaf->contents == CONTENTS_SKY)
		vis = Mod_NoVisPVS (cl.worldmodel);
	else if (nearwaterportal)
		vis = SV_FatPVS (r_origin, cl.worldmodel);
	else
		vis = Mod_LeafPVS (r_viewleaf, cl.worldmodel);

	r_visframecount++;

	/* set all chains to null */
	for (i = 0; i < cl.worldmodel->numtextures; i++)
		if (cl.worldmodel->textures[i])
			cl.worldmodel->textures[i]->texturechains[chain_world] = NULL;

	/* iterate through leaves, marking surfaces */
	leaf = &cl.worldmodel->leafs[1];
	for (i = 0; i < cl.worldmodel->numleafs; i++, leaf++)
	{
		if (vis[i>>3] & (1<<(i&7)))
		{
			if (R_CullBox(leaf->minmaxs, leaf->minmaxs + 3))
				continue;

			if (r_oldskyleaf.value || leaf->contents != CONTENTS_SKY)
				for (j = 0, mark = leaf->firstmarksurface; j < leaf->nummarksurfaces; j++, mark++)
				{
					surf = *mark;
					if (surf->visframe != r_visframecount)
					{
						surf->visframe = r_visframecount;
						if (!R_CullBox(surf->mins, surf->maxs) && !R_BackFaceCull (surf))
						{
							surf->texturechain = surf->texinfo->texture->texturechains[chain_world];
							surf->texinfo->texture->texturechains[chain_world] = surf;
						}
					}
				}

			/* static entities (torches, flames) ride efrags into
			   cl_visedicts, exactly upstream r_world.c */
			if (leaf->efrags)
				R_StoreEfrags (&leaf->efrags);
		}
	}
}

/* ========================================================================
 * frame packet construction
 * ===================================================================== */

/* Column-major 4x4 helpers; just enough to replace the GL matrix stack. */

static void Mat4_Multiply (float out[16], const float a[16], const float b[16])
{
	float tmp[16];
	int row, col, k;

	for (col = 0; col < 4; col++)
		for (row = 0; row < 4; row++)
		{
			float sum = 0;
			for (k = 0; k < 4; k++)
				sum += a[k*4 + row] * b[col*4 + k];
			tmp[col*4 + row] = sum;
		}
	memcpy (out, tmp, sizeof(tmp));
}

static void Mat4_RotateAxis (float m[16], float deg, int axis)
{
	float c = cos (DEG2RAD (deg));
	float s = sin (DEG2RAD (deg));

	memset (m, 0, 16*sizeof(float));
	m[15] = 1;
	switch (axis)
	{
	case 0:	/* x */
		m[0] = 1;
		m[5] = c;  m[6] = s;
		m[9] = -s; m[10] = c;
		break;
	case 1:	/* y */
		m[5] = 1;
		m[0] = c;  m[2] = -s;
		m[8] = s;  m[10] = c;
		break;
	case 2:	/* z */
		m[10] = 1;
		m[0] = c;  m[1] = s;
		m[4] = -s; m[5] = c;
		break;
	}
}

#define NEARCLIP 4

/*
================
QR_BuildViewProj -- replaces R_SetupGL's matrix stack.

Same rotations as upstream (put Quake's z-up, x-forward world into eye
space, then apply viewangles and origin), but the projection maps depth to
Metal's [0,1] instead of GL's [-1,1].
================
*/
static void QR_BuildViewProj (float out[16])
{
	float proj[16], rot[16];
	float xmax, ymax, n, f;

	n = NEARCLIP;
	f = gl_farclip.value;
	xmax = n * tan( r_fovx * M_PI / 360.0 );
	ymax = n * tan( r_fovy * M_PI / 360.0 );

	memset (proj, 0, sizeof(proj));
	proj[0] = n / xmax;
	proj[5] = n / ymax;
	proj[10] = f / (n - f);
	proj[11] = -1;
	proj[14] = n * f / (n - f);

	Mat4_RotateAxis (rot, -90, 0);	/* put Z going up */
	Mat4_Multiply (out, proj, rot);
	Mat4_RotateAxis (rot, 90, 2);	/* put Z going up */
	Mat4_Multiply (out, out, rot);
	Mat4_RotateAxis (rot, -r_refdef.viewangles[2], 0);
	Mat4_Multiply (out, out, rot);
	Mat4_RotateAxis (rot, -r_refdef.viewangles[0], 1);
	Mat4_Multiply (out, out, rot);
	Mat4_RotateAxis (rot, -r_refdef.viewangles[1], 2);
	Mat4_Multiply (out, out, rot);

	/* glTranslatef(-vieworg): fold into the last column directly */
	{
		float t[16];
		memset (t, 0, sizeof(t));
		t[0] = t[5] = t[10] = t[15] = 1;
		t[12] = -r_refdef.vieworg[0];
		t[13] = -r_refdef.vieworg[1];
		t[14] = -r_refdef.vieworg[2];
		Mat4_Multiply (out, out, t);
	}
}

static void QR_EnsureBatchCapacity (qr_frame_slot_t *slot)
{
	if (slot->frame.num_batches < slot->batch_capacity)
		return;
	slot->batch_capacity = slot->batch_capacity ? slot->batch_capacity * 2 : 128;
	slot->batches = (qc_draw_batch_t *) realloc (slot->batches,
			slot->batch_capacity * sizeof(qc_draw_batch_t));
}

static void QR_AppendBatch (qr_frame_slot_t *slot, uint32_t kind,
			    uint32_t texnum, uint32_t lightmap,
			    uint32_t first_index, float alpha,
			    uint32_t entity)
{
	qc_draw_batch_t *b;

	if (slot->frame.num_indices == first_index)
		return;		/* nothing was emitted */

	QR_EnsureBatchCapacity (slot);
	b = &slot->batches[slot->frame.num_batches++];
	b->kind = kind;
	b->texnum = texnum;
	b->lightmap = lightmap;
	b->first_index = first_index;
	b->index_count = slot->frame.num_indices - first_index;
	b->entity = entity;
	b->alpha = alpha;
}

/*
================
QR_AppendEntity -- add a per-entity record, returning its index
================
*/
static uint32_t QR_AppendEntity (qr_frame_slot_t *slot, const qc_entity_t *ent)
{
	if (slot->frame.num_entities == slot->entity_capacity)
	{
		slot->entity_capacity = slot->entity_capacity ? slot->entity_capacity * 2 : 64;
		slot->entities = (qc_entity_t *) realloc (slot->entities,
				slot->entity_capacity * sizeof(qc_entity_t));
	}
	slot->entities[slot->frame.num_entities] = *ent;
	return slot->frame.num_entities++;
}

/*
================
QR_EmitSurface -- append one surface's triangle fan as a triangle list

Grows the slot's index array on demand: with brush entities the per-frame
bound is dynamic (instanced bmodels re-emit their surfaces per entity), so
the load-time worst case is only a starting size.
================
*/
static void QR_EmitSurface (qr_frame_slot_t *slot, msurface_t *surf)
{
	uint32_t base = (uint32_t) surf->vbo_firstvert;
	uint32_t needed = slot->frame.num_indices + 3 * (surf->numedges - 2);
	uint32_t *dst;
	int i;

	if (needed > slot->index_capacity)
	{
		slot->index_capacity = slot->index_capacity ? slot->index_capacity * 2 : 4096;
		if (slot->index_capacity < needed)
			slot->index_capacity = needed;
		slot->indices = (uint32_t *) realloc (slot->indices,
				slot->index_capacity * sizeof(uint32_t));
	}

	dst = slot->indices + slot->frame.num_indices;
	for (i = 2; i < surf->numedges; i++)
	{
		*dst++ = base;
		*dst++ = base + i - 1;
		*dst++ = base + i;
	}
	slot->frame.num_indices = needed;
}

/*
================
QR_EmitTextureChains -- flatten one model's texture chains into batches.

The shared core of the world and brush-entity paths: walks `chain`,
emitting sky, opaque, then liquid batches for whatever R_MarkSurfaces or
QR_EmitBrushModel chained. `entity` is QC_ENTITY_NONE for the world;
`entalpha`/`frame` come from the entity (1.0 / 0 for the world).
Liquids take upstream's unlit path (the lit-water path needs the GLSL
renderer upstream too); their alpha comes from GL_WaterAlphaForSurface
with the entity override, exactly GL_WaterAlphaForEntitySurface.
================
*/
#define QR_PHASE_SKY	(1 << 0)
#define QR_PHASE_OPAQUE	(1 << 1)
#define QR_PHASE_LIQUID	(1 << 2)
#define QR_PHASE_ALL	(QR_PHASE_SKY | QR_PHASE_OPAQUE | QR_PHASE_LIQUID)

static void QR_EmitTextureChains (qr_frame_slot_t *slot, qmodel_t *model,
				  texchain_t chain, uint32_t entity,
				  float entalpha, int entframe, int phases)
{
	static byte	*lm_emitted;		/* scratch, sized lightmap_count */
	static int	lm_emitted_size;
	texture_t	*t, *anim;
	msurface_t	*s, *s2;
	int		i, lm;
	uint32_t	texnum, start;
	float		alpha;

	if (lm_emitted_size < lightmap_count)
	{
		lm_emitted_size = lightmap_count;
		lm_emitted = (byte *) realloc (lm_emitted, lm_emitted_size);
	}

	/* sky chains -- drawn first, writing depth, as upstream Sky_DrawSky */
	for (i = 0; (phases & QR_PHASE_SKY) && i < model->numtextures; i++)
	{
		t = model->textures[i];
		if (!t || !t->texturechains[chain])
			continue;
		if (!(t->texturechains[chain]->flags & SURF_DRAWSKY))
			continue;

		start = slot->frame.num_indices;
		for (s = t->texturechains[chain]; s; s = s->texturechain)
			QR_EmitSurface (slot, s);
		QR_AppendBatch (slot, QC_BATCH_SKY, 0, 0, start, r_skyalpha.value,
				entity);
	}

	/* opaque chains */
	for (i = 0; (phases & QR_PHASE_OPAQUE) && i < model->numtextures; i++)
	{
		t = model->textures[i];
		if (!t || !t->texturechains[chain])
			continue;
		if (t->texturechains[chain]->flags & (SURF_DRAWTURB | SURF_DRAWSKY))
			continue;

		anim = R_TextureAnimation (t, entframe);
		texnum = (anim->gltexture) ? anim->gltexture->texnum : notexture->texnum;

		if (lightmap_count)
			memset (lm_emitted, 0, lightmap_count);

		/* one batch per distinct lightmap in this chain */
		for (s = t->texturechains[chain]; s; s = s->texturechain)
		{
			lm = s->lightmaptexturenum;
			if (lm < 0 || (lm < lightmap_count && lm_emitted[lm]))
				continue;
			if (lm < lightmap_count)
				lm_emitted[lm] = 1;

			start = slot->frame.num_indices;
			for (s2 = s; s2; s2 = s2->texturechain)
				if (s2->lightmaptexturenum == lm)
					QR_EmitSurface (slot, s2);

			QR_AppendBatch (slot, QC_BATCH_WORLD, texnum,
					(lm < lightmap_count && lightmaps[lm].texture) ?
						lightmaps[lm].texture->texnum : 0,
					start, entalpha, entity);
		}
	}

	/* liquid chains -- after the model's opaque, like
	   R_DrawTextureChains_Water */
	for (i = 0; (phases & QR_PHASE_LIQUID) && i < model->numtextures; i++)
	{
		t = model->textures[i];
		if (!t || !t->texturechains[chain])
			continue;
		if (!(t->texturechains[chain]->flags & SURF_DRAWTURB))
			continue;

		texnum = (t->gltexture) ? t->gltexture->texnum : notexture->texnum;
		/* GL_WaterAlphaForEntitySurface: explicit entity alpha wins,
		   default falls through to the per-surface water alpha */
		if (entity != QC_ENTITY_NONE && entalpha < 1.0f)
			alpha = entalpha;
		else
			alpha = GL_WaterAlphaForSurface (t->texturechains[chain]);

		start = slot->frame.num_indices;
		for (s = t->texturechains[chain]; s; s = s->texturechain)
			QR_EmitSurface (slot, s);
		QR_AppendBatch (slot, QC_BATCH_LIQUID, texnum, 0, start, alpha,
				entity);
	}
}

/* r_brush.c: R_ClearTextureChains / R_ChainSurface -- declared in glquake.h */
void R_ClearTextureChains (qmodel_t *mod, texchain_t chain)
{
	int i;

	for (i = 0; i < mod->numtextures; i++)
		if (mod->textures[i])
			mod->textures[i]->texturechains[chain] = NULL;
}

void R_ChainSurface (msurface_t *surf, texchain_t chain)
{
	surf->texturechain = surf->texinfo->texture->texturechains[chain];
	surf->texinfo->texture->texturechains[chain] = surf;
}

/*
=============
R_CullModelForEntity -- port of gl_rmain.c; uses the (widened) frustum
=============
*/
qboolean R_CullModelForEntity (entity_t *e)
{
	vec3_t mins, maxs;
	vec_t scalefactor, *minbounds, *maxbounds;

	if (e->angles[0] || e->angles[2])	/* pitch or roll */
	{
		minbounds = e->model->rmins;
		maxbounds = e->model->rmaxs;
	}
	else if (e->angles[1])			/* yaw */
	{
		minbounds = e->model->ymins;
		maxbounds = e->model->ymaxs;
	}
	else					/* no rotation */
	{
		minbounds = e->model->mins;
		maxbounds = e->model->maxs;
	}

	scalefactor = ENTSCALE_DECODE(e->scale);
	if (scalefactor != 1.0f)
	{
		VectorMA (e->origin, scalefactor, minbounds, mins);
		VectorMA (e->origin, scalefactor, maxbounds, maxs);
	}
	else
	{
		VectorAdd (e->origin, minbounds, mins);
		VectorAdd (e->origin, maxbounds, maxs);
	}

	return R_CullBox (mins, maxs);
}

/*
================
QR_EntityMatrix -- the matrix R_RotateForEntity built on the GL stack:
T(origin) . Rz(yaw) . Ry(-pitch) . Rx(roll) . S(entity scale)
================
*/
static void QR_EntityMatrix (float out[16], const vec3_t origin,
			     const vec3_t angles, unsigned char scale)
{
	float rot[16], t[16];
	float scalefactor = ENTSCALE_DECODE(scale);
	int i;

	memset (t, 0, sizeof(t));
	t[0] = t[5] = t[10] = t[15] = 1;
	t[12] = origin[0];
	t[13] = origin[1];
	t[14] = origin[2];

	Mat4_RotateAxis (rot, angles[1], 2);
	Mat4_Multiply (out, t, rot);
	Mat4_RotateAxis (rot, -angles[0], 1);
	Mat4_Multiply (out, out, rot);
	Mat4_RotateAxis (rot, angles[2], 0);
	Mat4_Multiply (out, out, rot);

	if (scalefactor != 1.0f)
		for (i = 0; i < 12; i++)
			out[i] *= scalefactor;
}

/*
================
QR_EmitBrushModel -- port of R_DrawBrushModel, emitting batches.

Chains the visible submodel faces exactly as upstream (backface test
against the entity-space view origin), then reuses the shared chain
flattener with this entity's transform. Dynamic light marking
(R_MarkLights) and R_RenderDynamicLightmaps are still stubbed with the
rest of the dynamic-light path.
================
*/
static void QR_EmitBrushModel (qr_frame_slot_t *slot, entity_t *e)
{
	int		i;
	msurface_t	*psurf;
	float		dot;
	mplane_t	*pplane;
	qmodel_t	*clmodel = e->model;
	vec3_t		modelorg, temp;
	vec3_t		angles;
	qc_entity_t	rec;
	uint32_t	entity;

	if (R_CullModelForEntity (e))
		return;

	VectorSubtract (r_refdef.vieworg, e->origin, modelorg);
	if (e->angles[0] || e->angles[1] || e->angles[2])
	{
		vec3_t	forward, right, up;

		VectorCopy (modelorg, temp);
		AngleVectors (e->angles, forward, right, up);
		modelorg[0] = DotProduct (temp, forward);
		modelorg[1] = -DotProduct (temp, right);
		modelorg[2] = DotProduct (temp, up);
	}

	R_ClearTextureChains (clmodel, chain_model);
	psurf = &clmodel->surfaces[clmodel->firstmodelsurface];
	for (i = 0; i < clmodel->nummodelsurfaces; i++, psurf++)
	{
		pplane = psurf->plane;
		dot = DotProduct (modelorg, pplane->normal) - pplane->dist;
		if (((psurf->flags & SURF_PLANEBACK) && (dot < -BACKFACE_EPSILON)) ||
		    (!(psurf->flags & SURF_PLANEBACK) && (dot > BACKFACE_EPSILON)))
			R_ChainSurface (psurf, chain_model);
	}

	memset (&rec, 0, sizeof(rec));
	VectorCopy (e->angles, angles);
	angles[0] = -angles[0];		/* stupid quake bug */
	QR_EntityMatrix (rec.transform, e->origin, angles, e->scale);
	rec.alpha = ENTALPHA_DECODE(e->alpha);
	if (clmodel->name[0] == '*')
	{
		int submodel = atoi (clmodel->name + 1);
		for (i = 0; i < qr_secret_submodel_count; i++)
		{
			if (qr_secret_submodels[i] == submodel)
			{
				rec.flags |= QC_ENTFLAG_PHASED;
				break;
			}
		}
	}
	entity = QR_AppendEntity (slot, &rec);

	QR_EmitTextureChains (slot, clmodel, chain_model, entity,
			      rec.alpha, e->frame, QR_PHASE_ALL);
}

/* ========================================================================
 * gl_mesh.c -- alias model mesh building (VBO path only)
 *
 * Upstream builds two representations: the strip/fan command lists for the
 * GL1 immediate-mode path and a deduped indexed mesh for the GLSL path.
 * Only the indexed mesh is ported; the command lists existed for hardware
 * this renderer never runs on.
 * ===================================================================== */

const float r_avertexnormals[NUMVERTEXNORMALS][3] = {
#include "anorms.h"
};

/*
================
GL_MakeAliasModelDisplayLists -- port of the _VBO half of gl_mesh.c.

Dedupes verts (each source vert can appear twice: once with original UVs
and once seam-adjusted for backfacing tris), then packs every pose as
byte positions + signed-byte normals and hands the mesh to the consumer
through the mesh queue. The handle lives in qmodel_t's meshvbo field --
the same slot upstream kept its GL buffer name in -- so cache eviction
and reload just replaces the mesh like upstream replaced the VBO.
================
*/
void GL_MakeAliasModelDisplayLists (qmodel_t *m, aliashdr_t *hdr)
{
	int		i, j, mark;
	unsigned short	*remap;
	aliasmesh_t	*desc;
	unsigned short	*indexes;
	qc_mesh_vertex_t *verts;
	float		*st;
	uint16_t	*idx_copy;
	int		numindexes, numverts_vbo;
	float		hscale, vscale;

	mark = Hunk_LowMark ();

	desc = (aliasmesh_t *) Hunk_Alloc (sizeof(aliasmesh_t) * hdr->numverts * 2);
	indexes = (unsigned short *) Hunk_Alloc (sizeof(unsigned short) * hdr->numtris * 3);
	remap = (unsigned short *) Hunk_Alloc (hdr->numverts * 2 * sizeof(remap[0]));

	numindexes = 0;
	numverts_vbo = 0;

	for (i = 0; i < hdr->numtris; i++)
	{
		for (j = 0; j < 3; j++)
		{
			unsigned short vertindex = triangles[i].vertindex[j];
			int v = vertindex * 2;

			/* check for back side */
			if (!triangles[i].facesfront && stverts[vertindex].onseam)
				v++;

			if (!remap[v])
			{
				int s = stverts[vertindex].s;
				int t = stverts[vertindex].t;

				if (v & 1)
					s += hdr->skinwidth / 2;

				desc[numverts_vbo].vertindex = vertindex;
				desc[numverts_vbo].st[0] = s;
				desc[numverts_vbo].st[1] = t;
				remap[v] = ++numverts_vbo;
			}

			indexes[numindexes++] = remap[v] - 1;
		}
	}

	hdr->numindexes = numindexes;
	hdr->numverts_vbo = numverts_vbo;

	/* pack the upload: all poses' verts, shared st, indices */
	verts = (qc_mesh_vertex_t *) malloc ((size_t)hdr->numposes * numverts_vbo
					     * sizeof(qc_mesh_vertex_t));
	st = (float *) malloc ((size_t)numverts_vbo * 2 * sizeof(float));
	idx_copy = (uint16_t *) malloc ((size_t)numindexes * sizeof(uint16_t));
	if (!verts || !st || !idx_copy)
		Sys_Error ("GL_MakeAliasModelDisplayLists: out of memory");

	for (i = 0; i < hdr->numposes; i++)
	{
		const trivertx_t *tv = poseverts[i];
		qc_mesh_vertex_t *out = verts + (size_t)i * numverts_vbo;

		for (j = 0; j < numverts_vbo; j++)
		{
			trivertx_t trivert = tv[desc[j].vertindex];

			out[j].xyz[0] = trivert.v[0];
			out[j].xyz[1] = trivert.v[1];
			out[j].xyz[2] = trivert.v[2];
			out[j].xyz[3] = 1;
			/* map [-1..1] normals to [-127..127] signed bytes; the
			   error (< 0.004) is far below the source table's own
			   coarseness */
			out[j].normal[0] = 127 * r_avertexnormals[trivert.lightnormalindex][0];
			out[j].normal[1] = 127 * r_avertexnormals[trivert.lightnormalindex][1];
			out[j].normal[2] = 127 * r_avertexnormals[trivert.lightnormalindex][2];
			out[j].normal[3] = 0;
		}
	}

	hscale = 1.0f / (float)hdr->skinwidth;
	vscale = 1.0f / (float)hdr->skinheight;
	for (j = 0; j < numverts_vbo; j++)
	{
		st[j*2+0] = hscale * ((float)desc[j].st[0] + 0.5f);
		st[j*2+1] = vscale * ((float)desc[j].st[1] + 0.5f);
	}

	memcpy (idx_copy, indexes, numindexes * sizeof(uint16_t));

	Hunk_FreeToLowMark (mark);

	if (m->meshvbo)
		QR_EnqueueMeshFree (m->meshvbo);
	m->meshvbo = QR_EnqueueMeshUpload (hdr->numposes, numverts_vbo,
					   numindexes, verts, st, idx_copy);
}

/*
================
GLMesh_DeleteVertexBuffers -- called by Mod_ClearAll on map/game change
================
*/
void GLMesh_DeleteVertexBuffers (void)
{
	int j;
	qmodel_t *m;

	for (j = 1; j < MAX_MODELS; j++)
	{
		if (!(m = cl.model_precache[j]))
			break;
		if (m->type != mod_alias || !m->meshvbo)
			continue;
		QR_EnqueueMeshFree (m->meshvbo);
		m->meshvbo = 0;
	}
}

/* ========================================================================
 * gl_rlight.c -- R_LightPoint, for alias entity lighting
 * ===================================================================== */

static vec3_t	lightspot;
static vec3_t	lightcolor;

static int RecursiveLightPoint (vec3_t color, mnode_t *node, vec3_t rayorg,
				vec3_t start, vec3_t end, float *maxdist)
{
	float		front, back, frac;
	vec3_t		mid;

loc0:
	if (node->contents < 0)
		return false;		/* didn't hit anything */

/* calculate mid point */
	if (node->plane->type < 3)
	{
		front = start[node->plane->type] - node->plane->dist;
		back = end[node->plane->type] - node->plane->dist;
	}
	else
	{
		front = DotProduct(start, node->plane->normal) - node->plane->dist;
		back = DotProduct(end, node->plane->normal) - node->plane->dist;
	}

	/* LordHavoc: optimized recursion */
	if ((back < 0) == (front < 0))
	{
		node = node->children[front < 0];
		goto loc0;
	}

	frac = front / (front-back);
	mid[0] = start[0] + (end[0] - start[0])*frac;
	mid[1] = start[1] + (end[1] - start[1])*frac;
	mid[2] = start[2] + (end[2] - start[2])*frac;

/* go down front side */
	if (RecursiveLightPoint (color, node->children[front < 0], rayorg, start, mid, maxdist))
		return true;	/* hit something */
	else
	{
		int i, ds, dt;
		msurface_t *surf;

	/* check for impact on this node */
		VectorCopy (mid, lightspot);

		surf = cl.worldmodel->surfaces + node->firstsurface;
		for (i = 0; i < node->numsurfaces; i++, surf++)
		{
			float sfront, sback, dist;
			vec3_t raydelta;

			if (surf->flags & SURF_DRAWTILED)
				continue;	/* no lightmaps */

		/* ericw -- double casts for 64-bit precision (SSE builds lit
		   the jam3_ericw zombie wrongly without them) */
			ds = (int) ((double) DoublePrecisionDotProduct (mid, surf->texinfo->vecs[0]) + surf->texinfo->vecs[0][3]);
			dt = (int) ((double) DoublePrecisionDotProduct (mid, surf->texinfo->vecs[1]) + surf->texinfo->vecs[1][3]);

			if (ds < surf->texturemins[0] || dt < surf->texturemins[1])
				continue;

			ds -= surf->texturemins[0];
			dt -= surf->texturemins[1];

			if (ds > surf->extents[0] || dt > surf->extents[1])
				continue;

			if (surf->plane->type < 3)
			{
				sfront = rayorg[surf->plane->type] - surf->plane->dist;
				sback = end[surf->plane->type] - surf->plane->dist;
			}
			else
			{
				sfront = DotProduct(rayorg, surf->plane->normal) - surf->plane->dist;
				sback = DotProduct(end, surf->plane->normal) - surf->plane->dist;
			}
			VectorSubtract(end, rayorg, raydelta);
			dist = sfront / (sfront - sback) * VectorLength(raydelta);

			if (!surf->samples)
			{
				/* lightmapped flag but no data: keep looking
				   nearby instead of going black (DOTM overlap
				   fix) */
				const float nearby = 8.f;
				dist += nearby;
				*maxdist = q_min(*maxdist, dist);
				continue;
			}

			if (dist < *maxdist)
			{
				/* LordHavoc: interpolated sampling. Lightstyles
				   feed in via d_lightstylevalue, which is pinned
				   to the default until lightstyle animation
				   lands. */
				byte *lightmap;
				int maps, line3, dsfrac = ds & 15, dtfrac = dt & 15, r00 = 0, g00 = 0, b00 = 0, r01 = 0, g01 = 0, b01 = 0, r10 = 0, g10 = 0, b10 = 0, r11 = 0, g11 = 0, b11 = 0;
				float scale;
				line3 = ((surf->extents[0]>>4)+1)*3;

				lightmap = surf->samples + ((dt>>4) * ((surf->extents[0]>>4)+1) + (ds>>4))*3;

				for (maps = 0; maps < MAXLIGHTMAPS && surf->styles[maps] != 255; maps++)
				{
					scale = (float) d_lightstylevalue[surf->styles[maps]] * 1.0 / 256.0;
					r00 += (float) lightmap[      0] * scale;g00 += (float) lightmap[      1] * scale;b00 += (float) lightmap[2] * scale;
					r01 += (float) lightmap[      3] * scale;g01 += (float) lightmap[      4] * scale;b01 += (float) lightmap[5] * scale;
					r10 += (float) lightmap[line3+0] * scale;g10 += (float) lightmap[line3+1] * scale;b10 += (float) lightmap[line3+2] * scale;
					r11 += (float) lightmap[line3+3] * scale;g11 += (float) lightmap[line3+4] * scale;b11 += (float) lightmap[line3+5] * scale;
					lightmap += ((surf->extents[0]>>4)+1) * ((surf->extents[1]>>4)+1)*3;
				}

				color[0] += (float) ((int) ((((((((r11-r10) * dsfrac) >> 4) + r10)-((((r01-r00) * dsfrac) >> 4) + r00)) * dtfrac) >> 4) + ((((r01-r00) * dsfrac) >> 4) + r00)));
				color[1] += (float) ((int) ((((((((g11-g10) * dsfrac) >> 4) + g10)-((((g01-g00) * dsfrac) >> 4) + g00)) * dtfrac) >> 4) + ((((g01-g00) * dsfrac) >> 4) + g00)));
				color[2] += (float) ((int) ((((((((b11-b10) * dsfrac) >> 4) + b10)-((((b01-b00) * dsfrac) >> 4) + b00)) * dtfrac) >> 4) + ((((b01-b00) * dsfrac) >> 4) + b00)));
			}
			return true;
		}

	/* go down back side */
		return RecursiveLightPoint (color, node->children[front >= 0], rayorg, mid, end, maxdist);
	}
}

int R_LightPoint (vec3_t p)
{
	vec3_t		end;
	float		maxdist = 8192.f;

	if (!cl.worldmodel->lightdata)
	{
		lightcolor[0] = lightcolor[1] = lightcolor[2] = 255;
		return 255;
	}

	end[0] = p[0];
	end[1] = p[1];
	end[2] = p[2] - maxdist;

	lightcolor[0] = lightcolor[1] = lightcolor[2] = 0;
	RecursiveLightPoint (lightcolor, cl.worldmodel->nodes, p, p, end, &maxdist);
	return ((lightcolor[0] + lightcolor[1] + lightcolor[2]) * (1.0f / 3.0f));
}

/* ========================================================================
 * r_alias.c -- alias model lerp setup, lighting, and batch emission
 * ===================================================================== */

typedef struct {
	short pose1;
	short pose2;
	float blend;
	vec3_t origin;
	vec3_t angles;
} lerpdata_t;

/*
=================
R_SetupAliasFrame -- straight port; mutates the entity's lerp state
=================
*/
static void QR_SetupAliasFrame (entity_t *e, aliashdr_t *paliashdr, int frame,
				lerpdata_t *lerpdata)
{
	int	posenum, numposes;

	if ((frame >= paliashdr->numframes) || (frame < 0))
	{
		Con_DPrintf ("R_AliasSetupFrame: no such frame %d for '%s'\n", frame, e->model->name);
		frame = 0;
	}

	posenum = paliashdr->frames[frame].firstpose;
	numposes = paliashdr->frames[frame].numposes;

	if (numposes > 1)
	{
		e->lerptime = paliashdr->frames[frame].interval;
		posenum += (int)(cl.time / e->lerptime) % numposes;
	}
	else
		e->lerptime = 0.1;

	if (e->lerpflags & LERP_RESETANIM)	/* kill any lerp in progress */
	{
		e->lerpstart = 0;
		e->previouspose = posenum;
		e->currentpose = posenum;
		e->lerpflags -= LERP_RESETANIM;
	}
	else if (e->currentpose != posenum)	/* pose changed, start new lerp */
	{
		if (e->lerpflags & LERP_RESETANIM2)	/* defer lerping one more time */
		{
			e->lerpstart = 0;
			e->previouspose = posenum;
			e->currentpose = posenum;
			e->lerpflags -= LERP_RESETANIM2;
		}
		else
		{
			e->lerpstart = cl.time;
			e->previouspose = e->currentpose;
			e->currentpose = posenum;
		}
	}

	if (r_lerpmodels.value && !(e->model->flags & MOD_NOLERP && r_lerpmodels.value != 2))
	{
		if (e->lerpflags & LERP_FINISH && numposes == 1)
			lerpdata->blend = CLAMP (0.0f, (float)(cl.time - e->lerpstart) / (e->lerpfinish - e->lerpstart), 1.0f);
		else
			lerpdata->blend = CLAMP (0.0f, (float)(cl.time - e->lerpstart) / e->lerptime, 1.0f);
		if (lerpdata->blend == 1.0f)
			e->previouspose = e->currentpose;
		lerpdata->pose1 = e->previouspose;
		lerpdata->pose2 = e->currentpose;
	}
	else	/* don't lerp */
	{
		lerpdata->blend = 1;
		lerpdata->pose1 = posenum;
		lerpdata->pose2 = posenum;
	}
}

/*
=================
R_SetupEntityTransform -- straight port
=================
*/
static void QR_SetupEntityTransform (entity_t *e, lerpdata_t *lerpdata)
{
	float blend;
	vec3_t d;
	int i;

	if (e->lerpflags & LERP_RESETMOVE)
	{
		e->movelerpstart = 0;
		VectorCopy (e->origin, e->previousorigin);
		VectorCopy (e->origin, e->currentorigin);
		VectorCopy (e->angles, e->previousangles);
		VectorCopy (e->angles, e->currentangles);
		e->lerpflags -= LERP_RESETMOVE;
	}
	else if (!VectorCompare (e->origin, e->currentorigin) || !VectorCompare (e->angles, e->currentangles))
	{
		e->movelerpstart = cl.time;
		VectorCopy (e->currentorigin, e->previousorigin);
		VectorCopy (e->origin,  e->currentorigin);
		VectorCopy (e->currentangles, e->previousangles);
		VectorCopy (e->angles,  e->currentangles);
	}

	if (r_lerpmove.value && e != &cl.viewent && e->lerpflags & LERP_MOVESTEP)
	{
		if (e->lerpflags & LERP_FINISH)
			blend = CLAMP (0.0f, (float)(cl.time - e->movelerpstart) / (e->lerpfinish - e->movelerpstart), 1.0f);
		else
			blend = CLAMP (0.0f, (float)(cl.time - e->movelerpstart) / 0.1f, 1.0f);

		VectorSubtract (e->currentorigin, e->previousorigin, d);
		lerpdata->origin[0] = e->previousorigin[0] + d[0] * blend;
		lerpdata->origin[1] = e->previousorigin[1] + d[1] * blend;
		lerpdata->origin[2] = e->previousorigin[2] + d[2] * blend;

		VectorSubtract (e->currentangles, e->previousangles, d);
		for (i = 0; i < 3; i++)
		{
			if (d[i] > 180)  d[i] -= 360;
			if (d[i] < -180) d[i] += 360;
		}
		lerpdata->angles[0] = e->previousangles[0] + d[0] * blend;
		lerpdata->angles[1] = e->previousangles[1] + d[1] * blend;
		lerpdata->angles[2] = e->previousangles[2] + d[2] * blend;
	}
	else
	{
		VectorCopy (e->origin, lerpdata->origin);
		VectorCopy (e->angles, lerpdata->angles);
	}
}

/*
=================
R_SetupAliasLighting -- straight port minus the CPU shadedots table (the
shade-dot quantisation moves into the vertex shader via shadevector).
Dynamic lights DO contribute here (cl_dlights is engine state, muzzle
flashes and explosions set it), but surface dlights and lightstyle
animation are still stubbed, so overall lighting differs from upstream
until those land.
=================
*/
static void QR_SetupAliasLighting (entity_t *e, vec3_t shadevector_out)
{
	vec3_t		dist;
	float		add;
	int		i;
	int		quantizedangle;
	float		radiansangle;

	/* black initial trace: retry from mid-height (candles-below-floor fix) */
	if (!R_LightPoint (e->origin))
	{
		vec3_t lpos;
		VectorCopy (e->origin, lpos);
		lpos[2] += e->model->maxs[2] * 0.5f;
		R_LightPoint (lpos);
	}

	for (i = 0; i < MAX_DLIGHTS; i++)
	{
		if (cl_dlights[i].die >= cl.time)
		{
			VectorSubtract (e->origin, cl_dlights[i].origin, dist);
			add = cl_dlights[i].radius - VectorLength(dist);
			if (add > 0)
				VectorMA (lightcolor, add, cl_dlights[i].color, lightcolor);
		}
	}

	/* minimum light value on gun (24) */
	if (e == &cl.viewent)
	{
		add = 72.0f - (lightcolor[0] + lightcolor[1] + lightcolor[2]);
		if (add > 0.0f)
		{
			lightcolor[0] += add / 3.0f;
			lightcolor[1] += add / 3.0f;
			lightcolor[2] += add / 3.0f;
		}
	}

	/* minimum light value on players (8) */
	if (e > cl_entities && e <= cl_entities + cl.maxclients)
	{
		add = 24.0f - (lightcolor[0] + lightcolor[1] + lightcolor[2]);
		if (add > 0.0f)
		{
			lightcolor[0] += add / 3.0f;
			lightcolor[1] += add / 3.0f;
			lightcolor[2] += add / 3.0f;
		}
	}

	/* clamp lighting so it doesn't overbright as much (96) */
	if (gl_overbright_models.value)
	{
		add = 288.0f / (lightcolor[0] + lightcolor[1] + lightcolor[2]);
		if (add < 1.0f)
			VectorScale(lightcolor, add, lightcolor);
	}

	/* hack up the brightness when fullbrights but no overbrights (256) */
	if (gl_fullbrights.value && !gl_overbright_models.value)
		if (e->model->flags & MOD_FBRIGHTHACK)
		{
			lightcolor[0] = 256.0f;
			lightcolor[1] = 256.0f;
			lightcolor[2] = 256.0f;
		}

	quantizedangle = ((int)(e->angles[1] * (16.0 / 360.0))) & 15;
	radiansangle = (quantizedangle / 16.0) * 2.0 * 3.14159;
	shadevector_out[0] = cos(-radiansangle);
	shadevector_out[1] = sin(-radiansangle);
	shadevector_out[2] = 1;
	VectorNormalize(shadevector_out);

	VectorScale (lightcolor, 1.0f / 200.0f, lightcolor);
}

/*
=================
QR_EmitAliasModel -- port of R_DrawAliasModel, emitting an entity record
and one QC_BATCH_ALIAS batch instead of GL state and a draw.
=================
*/
static void QR_EmitAliasModel (qr_frame_slot_t *slot, entity_t *e)
{
	aliashdr_t	*paliashdr;
	int		anim, skinnum;
	gltexture_t	*tx, *fb;
	lerpdata_t	lerpdata;
	qc_entity_t	rec;
	uint32_t	entity;
	float		entalpha;
	float		t[16], s[16];
	int		i;

	/* pose/lerp state first so culling can't starve lerp updates */
	paliashdr = (aliashdr_t *)Mod_Extradata (e->model);
	QR_SetupAliasFrame (e, paliashdr, e->frame, &lerpdata);
	QR_SetupEntityTransform (e, &lerpdata);

	if (e != &cl.viewent && R_CullModelForEntity (e))
		return;
	if (!e->model->meshvbo || !paliashdr->numindexes)
		return;

	entalpha = ENTALPHA_DECODE(e->alpha);
	if (entalpha == 0)
		return;

	memset (&rec, 0, sizeof(rec));

	/* R_RotateForEntity, then the scale_origin translate and scale that
	   upstream pushed after it -- the mesh stores raw byte positions */
	QR_EntityMatrix (rec.transform, lerpdata.origin, lerpdata.angles, e->scale);
	memset (t, 0, sizeof(t));
	t[0] = t[5] = t[10] = t[15] = 1;
	t[12] = paliashdr->scale_origin[0];
	t[13] = paliashdr->scale_origin[1];
	t[14] = paliashdr->scale_origin[2];
	Mat4_Multiply (rec.transform, rec.transform, t);
	memset (s, 0, sizeof(s));
	s[0] = paliashdr->scale[0];
	s[5] = paliashdr->scale[1];
	s[10] = paliashdr->scale[2];
	s[15] = 1;
	Mat4_Multiply (rec.transform, rec.transform, s);

	QR_SetupAliasLighting (e, rec.shadevector);

	/* overbright-model doubling folds into the light color: the shader
	   computes tex*light + fullbright and 2*(tex*light) == tex*(2*light) */
	for (i = 0; i < 3; i++)
		rec.light[i] = lightcolor[i] * (gl_overbright_models.value ? 2.0f : 1.0f);

	anim = (int)(cl.time*10) & 3;
	skinnum = e->skinnum;
	if ((skinnum >= paliashdr->numskins) || (skinnum < 0))
	{
		Con_DPrintf ("QR_EmitAliasModel: no such skin # %d for '%s'\n", skinnum, e->model->name);
		skinnum = 0;
	}
	tx = paliashdr->gltextures[skinnum][anim];
	fb = paliashdr->fbtextures[skinnum][anim];
	if (!gl_fullbrights.value)
		fb = NULL;
	/* TODO: colormapped player skins (playertextures / gl_nocolors) */

	rec.alpha = entalpha;
	rec.blend = (lerpdata.pose1 != lerpdata.pose2) ? lerpdata.blend : 0;
	rec.meshnum = e->model->meshvbo;
	rec.pose1 = lerpdata.pose1;
	rec.pose2 = lerpdata.pose2;
	if (e == &cl.viewent)
		rec.flags |= QC_ENTFLAG_VIEWMODEL;

	entity = QR_AppendEntity (slot, &rec);

	QR_EnsureBatchCapacity (slot);
	{
		qc_draw_batch_t *b = &slot->batches[slot->frame.num_batches++];
		b->kind = QC_BATCH_ALIAS;
		b->texnum = tx ? tx->texnum : notexture->texnum;
		b->lightmap = fb ? fb->texnum : 0;
		b->first_index = 0;
		b->index_count = paliashdr->numindexes;
		b->entity = entity;
		b->alpha = entalpha;
	}
}

/*
================
QR_EmitWheel -- the weapon wheel: the player's OWNED view-weapon models as
a ring of synthetic alias entities around the off-hand wrist.

Real models in world space, not an overlay: emitting through the ordinary
entity side array buys lighting, lerp and stereo amplification for free,
and a ring of floating shotguns reads far better in a headset than a flat
radial menu. Unowned weapons are absent -- the wheel never offers a
selection that would silently fail. The ring's radius follows the open
fraction and the items spin on `realtime`, the WALL clock: the wheel moves
at full speed while the weapons' own idle lerp (cl.time-driven) crawls
with the world. That contrast is the effect.
================
*/
static const uint32_t qr_wheel_bits[8] = {
	IT_AXE, IT_SHOTGUN, IT_SUPER_SHOTGUN, IT_NAILGUN,
	IT_SUPER_NAILGUN, IT_GRENADE_LAUNCHER, IT_ROCKET_LAUNCHER,
	IT_LIGHTNING,
};
static const char *qr_wheel_modelnames[8] = {
	"progs/v_axe.mdl", "progs/v_shot.mdl", "progs/v_shot2.mdl",
	"progs/v_nail.mdl", "progs/v_nail2.mdl", "progs/v_rock.mdl",
	"progs/v_rock2.mdl", "progs/v_light.mdl",
};
static const char *qr_wheel_labels[8] = {
	"AXE", "SHOTGUN", "SUPER SHOTGUN", "NAILGUN",
	"SUPER NAILGUN", "GRENADES", "ROCKETS", "THUNDERBOLT",
};

/*
================
2D text as billboarded glyph quads from Quake's conchars atlas -- the
foundation for wheel labels, the item selector and the HUD. conchars is a
128x128 8bpp lump living in the already-resident gfx.wad; index 0 and 255
are transparent under TEXPREF_CONCHARS. Uploaded once, lazily, through the
same queue every other texture uses. Each glyph is an 8x8 cell in a 16x16
grid; character c sits at column (c & 15), row (c >> 4).
================
*/
uint32_t	qr_conchars_texnum;		/* atlas handle; 0 until loaded */

static void QR_EnsureConchars (void)
{
	byte		*data;
	gltexture_t	*glt;

	if (qr_conchars_texnum)
		return;
	data = (byte *) W_GetLumpName ("conchars");
	if (!data)
		return;
	glt = QR_TexMgr_LoadImage (NULL, "conchars", 128, 128, SRC_INDEXED,
			data, WADFILENAME, (src_offset_t) data,
			TEXPREF_ALPHA | TEXPREF_NEAREST | TEXPREF_CONCHARS);
	if (glt)
		qr_conchars_texnum = glt->texnum;
}

static void QR_TextVert (qr_frame_slot_t *slot, const vec3_t p,
			 float u, float v, const float col[4])
{
	uint32_t	n = slot->frame.num_text_verts;
	float		*o;

	if ((n + 1) * 9 > slot->text_capacity)
	{
		slot->text_capacity = slot->text_capacity ? slot->text_capacity * 2 : 4096;
		slot->text_verts = (float *) realloc (slot->text_verts,
				slot->text_capacity * sizeof(float));
	}
	o = slot->text_verts + n * 9;
	o[0] = p[0]; o[1] = p[1]; o[2] = p[2];
	o[3] = u;    o[4] = v;
	o[5] = col[0]; o[6] = col[1]; o[7] = col[2]; o[8] = col[3];
	slot->frame.num_text_verts = n + 1;
}

/* Lay a string out centred on `org`, glyphs advancing along `right` and
   standing `up`, each cell `cw` units square. Billboarding is the caller's
   job: pass a (right, up) basis that faces the eye. */
static void QR_EmitText (qr_frame_slot_t *slot, const char *s, const vec3_t org,
			 const vec3_t right, const vec3_t up, float cw,
			 const float col[4])
{
	int	len = (int) strlen (s);
	float	half = len * cw * 0.5f;
	float	top = cw * 0.5f, bot = -cw * 0.5f;
	int	i, a;

	for (i = 0; i < len; i++)
	{
		int	ch = (unsigned char) s[i];
		int	cxi = ch & 15, cyi = ch >> 4;
		float	u0 = cxi / 16.f, u1 = u0 + 1.f / 16.f;
		float	v0 = cyi / 16.f, v1 = v0 + 1.f / 16.f;
		float	x0 = -half + i * cw, x1 = x0 + cw;
		vec3_t	tl, tr, bl, br;

		if (ch == ' ')
			continue;	/* blank cell: skip the six wasted verts */
		for (a = 0; a < 3; a++)
		{
			tl[a] = org[a] + right[a] * x0 + up[a] * top;
			tr[a] = org[a] + right[a] * x1 + up[a] * top;
			bl[a] = org[a] + right[a] * x0 + up[a] * bot;
			br[a] = org[a] + right[a] * x1 + up[a] * bot;
		}
		QR_TextVert (slot, tl, u0, v0, col);
		QR_TextVert (slot, tr, u1, v0, col);
		QR_TextVert (slot, bl, u0, v1, col);
		QR_TextVert (slot, tr, u1, v0, col);
		QR_TextVert (slot, br, u1, v1, col);
		QR_TextVert (slot, bl, u0, v1, col);
	}
}

static void QR_EmitWheel (qr_frame_slot_t *slot)
{
	static qmodel_t	*models[8];
	static qmodel_t	*cachekey;
	/* the ring locks in world space the instant it opens: you reach INTO a
	   fixed ring, not one that chases your wrist. Cleared when it closes. */
	static int	locked;
	static vec3_t	lock_center;
	float		frac, radius, step, theta, spin;
	vec3_t		fwdv, rightv, upv, angles, center;
	int		i, owned, k;

	if (qr_wheel_frac <= 0.01f || cls.signon != SIGNONS || !cl.worldmodel)
	{
		locked = 0;
		return;
	}

	/* v_*.mdl are precached by progs on every map; resolve names to
	   models once per worldmodel */
	if (cachekey != cl.worldmodel)
	{
		cachekey = cl.worldmodel;
		for (i = 0; i < 8; i++)
		{
			int m;
			models[i] = NULL;
			for (m = 1; m < MAX_MODELS && cl.model_precache[m]; m++)
				if (!strcmp (cl.model_precache[m]->name, qr_wheel_modelnames[i]))
				{
					models[i] = cl.model_precache[m];
					break;
				}
		}
	}

	owned = 0;
	for (i = 0; i < 8; i++)
		if ((cl.items & qr_wheel_bits[i]) && models[i])
			owned++;
	if (!owned)
		return;

	QR_EnsureConchars ();

	frac = qr_wheel_frac * qr_wheel_frac * (3.f - 2.f * qr_wheel_frac);
	/* A wide ring the wrist sits inside, Skyrim-VR style: it stands off the
	   wrist far enough that moving the whole hand toward a weapon is the
	   selection gesture, not a cramped finger flick. */
	radius = 14.f * frac;
	spin = (float) fmod (realtime * 30.0, 360.0);

	angles[0] = 0;
	angles[1] = cl.viewangles[YAW];
	angles[2] = 0;
	AngleVectors (angles, fwdv, rightv, upv);
	/* AngleVectors' right points right; keep the ring plane spanned by
	   (rightv, world up), facing the player */
	if (qr_wheel_has_anchor)
	{
		/* Both the wrist anchor and the head offset are body-frame Quake
		   units from the same recenter origin, so their difference is the
		   wrist RELATIVE TO THE HEAD -- add that to the eye and the ring
		   sits on the wrist no matter where the player has walked. Adding
		   the raw anchor (as before) pinned it to the recenter origin, so
		   it drifted off the wrist the moment you moved. */
		float ax = qr_wheel_anchor[0] - qr_head[0];
		float ay = qr_wheel_anchor[1] - qr_head[1];
		float az = qr_wheel_anchor[2] - qr_head[2];
		VectorMA (r_refdef.vieworg, ax, fwdv, center);
		VectorMA (center, ay, rightv, center);
		/* rise with the height-trimmed camera so the ring does not sink
		   out of view as the eye-height slider raises the viewpoint */
		center[2] += az + qr_height_trim;
	}
	else
	{
		/* no wrist (flat window): fixed offset ahead of the view */
		VectorMA (r_refdef.vieworg, 36.f, fwdv, center);
		center[2] -= 2.f;
	}

	/* Freeze the ring at the pose it opened with. After this the wrist is
	   free to move toward a slot without dragging the ring along; the
	   consumer turns that wrist travel into the highlight. */
	if (!locked)
	{
		VectorCopy (center, lock_center);
		locked = 1;
	}
	VectorCopy (lock_center, center);

	/* publish the guide ring so the consumer can draw the wireframe circle
	   and highlight marker in the same plane the models sit in */
	slot->frame.wheel_center[0] = center[0];
	slot->frame.wheel_center[1] = center[1];
	slot->frame.wheel_center[2] = center[2];
	slot->frame.wheel_radius = radius;
	slot->frame.wheel_frac = frac;
	slot->frame.wheel_count = owned;
	slot->frame.wheel_highlight = qr_wheel_highlight;

	step = 360.f / owned;
	k = 0;
	for (i = 0; i < 8; i++)
	{
		entity_t	e;
		qc_entity_t	*rec;
		uint32_t	before;
		int		highlighted;
		int		c;

		if (!(cl.items & qr_wheel_bits[i]) || !models[i])
			continue;

		highlighted = (k == qr_wheel_highlight);
		theta = (90.f - k * step) * M_PI / 180.f;

		memset (&e, 0, sizeof(e));
		e.model = models[i];
		VectorMA (center, radius * cosf (theta), rightv, e.origin);
		e.origin[2] += radius * sinf (theta);
		e.angles[0] = 0;
		e.angles[1] = spin + k * 45.f;
		e.angles[2] = 0;
		e.frame = 0;
		e.skinnum = 0;
		e.scale = (unsigned char)(highlighted ? 8 : 5);	/* /16; smaller to fit the tight ring */
		e.lerpflags = LERP_RESETANIM | LERP_RESETMOVE;

		before = slot->frame.num_entities;
		QR_EmitAliasModel (slot, &e);
		if (slot->frame.num_entities > before)
		{
			/* room lighting is right in spirit but a wheel item
			   must never be unreadable in a dark corridor: floor
			   it, and let the highlight glow */
			rec = &slot->entities[slot->frame.num_entities - 1];
			for (c = 0; c < 3; c++)
			{
				rec->light[c] = q_max (rec->light[c], 0.45f);
				if (highlighted)
					rec->light[c] = q_min (rec->light[c] * 1.7f, 2.f);
			}
		}

		/* the weapon's name below its model, billboarded in the ring plane
		   (body-right, world-up) so it faces the player. The highlighted
		   slot's label glows white; the rest are dimmer. */
		if (qr_conchars_texnum)
		{
			vec3_t	labelorg, worldup = {0.f, 0.f, 1.f};
			float	lcol[4];

			VectorCopy (e.origin, labelorg);
			labelorg[2] -= 4.5f;
			lcol[0] = lcol[1] = lcol[2] = highlighted ? 1.f : 0.7f;
			lcol[3] = 1.f;
			QR_EmitText (slot, qr_wheel_labels[i], labelorg, rightv,
				     worldup, 1.6f, lcol);
		}
		k++;
	}
}

/*
================
QR_BuildFramePacket -- flatten this frame into typed batches, in upstream
R_RenderScene order: sky, opaque world, opaque entities, world liquids,
translucent entities. Runs where upstream issued the GL draws; instead it
records index ranges, entity records, and texture handles for the
consumer.
================
*/
static void QR_BuildFramePacket (qr_frame_slot_t *slot)
{
	int i;

	QR_EmitTextureChains (slot, cl.worldmodel, chain_world, QC_ENTITY_NONE,
			      1.0f, 0, QR_PHASE_SKY | QR_PHASE_OPAQUE);

	/* opaque entities between the opaque world and its liquids,
	   translucent entities after both -- upstream's R_RenderScene order
	   (two R_DrawEntitiesOnList passes around R_DrawWorld_Water) */
	if (r_drawentities.value)
		for (i = 0; i < cl_numvisedicts; i++)
		{
			entity_t *e = cl_visedicts[i];
			if (ENTALPHA_DECODE(e->alpha) < 1)
				continue;
			if (e->model->type == mod_brush)
				QR_EmitBrushModel (slot, e);
			else if (e->model->type == mod_alias)
				QR_EmitAliasModel (slot, e);
			/* mod_sprite: not rendered yet (needs per-frame quads) */
		}

	QR_EmitTextureChains (slot, cl.worldmodel, chain_world, QC_ENTITY_NONE,
			      1.0f, 0, QR_PHASE_LIQUID);

	if (r_drawentities.value)
		for (i = 0; i < cl_numvisedicts; i++)
		{
			entity_t *e = cl_visedicts[i];
			float a = ENTALPHA_DECODE(e->alpha);
			if (a == 1 || a == 0)
				continue;
			if (e->model->type == mod_brush)
				QR_EmitBrushModel (slot, e);
			else if (e->model->type == mod_alias)
				QR_EmitAliasModel (slot, e);
		}

	/* the view weapon, last, like upstream R_DrawViewModel; the consumer
	   decides whether to draw it (window yes, immersive no) */
	if (r_drawviewmodel.value && r_drawentities.value && !chase_active.value
	    && !(cl.items & IT_INVISIBILITY) && cl.stats[STAT_HEALTH] > 0
	    && cl.viewent.model && cl.viewent.model->type == mod_alias)
		QR_EmitAliasModel (slot, &cl.viewent);

	QR_EmitWheel (slot);
}

/* ========================================================================
 * frame lifecycle -- QR_BeginFrame / QR_RenderView / QR_PublishFrame
 * ===================================================================== */

void QR_BeginFrame (void)
{
	int i;
	qr_frame_slot_t *slot;

	pthread_mutex_lock (&qr_frame_lock);
	qr_building = -1;
	for (i = 0; i < 3; i++)
	{
		if (qr_slots[i].state == QR_SLOT_FREE)
		{
			qr_slots[i].state = QR_SLOT_BUILDING;
			qr_building = i;
			break;
		}
	}
	pthread_mutex_unlock (&qr_frame_lock);

	if (qr_building < 0)
		return;		/* can't happen with 3 slots; drop the frame if it does */

	slot = &qr_slots[qr_building];
	slot->frame.num_indices = 0;
	slot->frame.num_batches = 0;
	slot->frame.num_entities = 0;
	slot->frame.num_text_verts = 0;

	/* an empty packet (console up, no world) must not carry stale sky or
	   animation state from this slot's previous life */
	slot->frame.time = 0;
	slot->frame.phase = 0;
	slot->frame.phase_radius = 0;
	slot->frame.phase_color[0] = 1.5f;
	slot->frame.phase_color[1] = 0.93f;
	slot->frame.phase_color[2] = 0.27f;
	slot->frame.head_absorbed[0] = 0;
	slot->frame.head_absorbed[1] = 0;
	slot->frame.lean_limit = 12;
	slot->frame.vignette = 0;
	slot->frame.damage_flash = 0;
	slot->frame.active_weapon = 0;
	slot->frame.items = 0;
	slot->frame.wheel_frac = 0;
	slot->frame.wheel_radius = 0;
	slot->frame.wheel_count = 0;
	slot->frame.wheel_highlight = -1;
	memset (slot->frame.wheel_center, 0, sizeof(slot->frame.wheel_center));
	/* stays live even in empty packets so the consumer's recenter
	   handshake can't wedge at the console or during demos */
	slot->frame.recenter_count = qr_recenter_count;
	memset (slot->frame.vieworg, 0, sizeof(slot->frame.vieworg));
	memset (slot->frame.viewangles, 0, sizeof(slot->frame.viewangles));
	slot->frame.world_scale = QR_WORLDSCALE_DEFAULT;
	slot->frame.sky_solid_texnum = 0;
	slot->frame.sky_alpha_texnum = 0;
	memset (slot->frame.skybox_texnums, 0, sizeof(slot->frame.skybox_texnums));

	/* engine owns this slot: safe to (re)size outside the lock */
	if (slot->index_capacity < qr_index_worst_case)
	{
		slot->index_capacity = qr_index_worst_case;
		slot->indices = (uint32_t *) realloc (slot->indices,
				slot->index_capacity * sizeof(uint32_t));
	}
}

void QR_RenderView (void)
{
	qr_frame_slot_t *slot;

	if (r_norefresh.value)
		return;

	if (!cl.worldmodel)
		Sys_Error ("R_RenderView: NULL worldmodel");

	if (qr_building < 0)
		return;

	slot = &qr_slots[qr_building];

	r_framecount++;

	/* view setup -- port of R_SetupView */
	VectorCopy (r_refdef.vieworg, r_origin);
	AngleVectors (r_refdef.viewangles, vpn, vright, vup);

	r_oldviewleaf = r_viewleaf;
	r_viewleaf = Mod_PointInLeaf (r_origin, cl.worldmodel);

	/* no r_waterwarp underwater fov wobble yet (see roadmap) */
	r_fovx = r_refdef.fov_x;
	r_fovy = r_refdef.fov_y;

	/* Cull once with a frustum wide enough for whatever the consumer
	   renders. Immersive rendering reports the merged binocular fov and
	   late-latches the head pose, so widen by the reported fov plus a
	   rotation margin; the packet's mono viewproj keeps r_fovx/r_fovy.
	   Over-drawing is much cheaper than popping at the periphery. */
	{
		float cullx, cully;

		pthread_mutex_lock (&qr_cullfov_lock);
		cullx = qr_cull_fovx;
		cully = qr_cull_fovy;
		pthread_mutex_unlock (&qr_cullfov_lock);

		/* >= 360 requests omnidirectional (the head can face anywhere):
		   render the whole PVS, no frustum. Still build a valid frustum for
		   any consumer of the planes; R_CullBox short-circuits on the flag. */
		qr_cull_omni = (cullx >= 359.f || cully >= 359.f);
		if (qr_cull_omni)
		{
			/* keep the planes valid (R_CullBox ignores them anyway) */
			R_SetFrustum (r_fovx, r_fovy);
		}
		else
		{
			if (cullx > 0 && cully > 0)
			{
				cullx = q_min (cullx + QR_CULL_FOV_MARGIN, 170.f);
				cully = q_min (cully + QR_CULL_FOV_MARGIN, 170.f);
			}
			R_SetFrustum (q_max (r_fovx, cullx), q_max (r_fovy, cully));
		}
	}

	R_MarkSurfaces ();

	QR_BuildViewProj (slot->frame.viewproj);

	/* animation clock and sky state travel in the packet: the consumer
	   must never substitute its own clock or reach into engine globals */
	slot->frame.time = (float) cl.time;
	slot->frame.vieworg[0] = r_origin[0];
	slot->frame.vieworg[1] = r_origin[1];
	slot->frame.vieworg[2] = r_origin[2];
	slot->frame.viewangles[0] = r_refdef.viewangles[0];
	slot->frame.viewangles[1] = r_refdef.viewangles[1];
	slot->frame.viewangles[2] = r_refdef.viewangles[2];
	slot->frame.world_scale = CLAMP (QR_WORLDSCALE_MIN, vr_worldscale.value,
					 QR_WORLDSCALE_MAX);

	/* phase: ease the published scalar toward the cvar target. The engine
	   owns this clock; the renderer only supplies the sphere origin. */
	{
		static double	qr_phase_lasttime;
		float		target = CLAMP (0.f, phase.value, 1.f);
		float		ptime = q_max (phase_time.value, 0.01f);
		double		dt = cl.time - qr_phase_lasttime;
		float		eased;

		if (dt < 0 || dt > 1)	/* map change / demo restart */
			dt = 0;
		qr_phase_lasttime = cl.time;

		if (qr_phase_value < target)
			qr_phase_value = q_min (qr_phase_value + (float)dt / ptime, target);
		else if (qr_phase_value > target)
			qr_phase_value = q_max (qr_phase_value - (float)dt / ptime, target);

		/* smoothstep on the linear progress = the ~2s eased sweep */
		eased = qr_phase_value * qr_phase_value * (3.f - 2.f * qr_phase_value);
		slot->frame.phase = eased;

		/* Perceptually even melt. Scaling the radius linearly in the
		   diagonal spends every visible surface in the first ~15% of
		   the range, because the diagonal dwarfs room scale -- the
		   dial felt like a 0/1 toggle. Exponential growth from arm's
		   reach gives each increment the same multiplicative bite:
		   half phase is a room-sized bubble, full phase still clears
		   the map. The +60 keeps the far corners inside the noise
		   band's reach at full phase. */
		if (eased <= 0.f)
			slot->frame.phase_radius = 0.f;
		else
			slot->frame.phase_radius = QR_PHASE_NEAR_RADIUS *
				powf ((qr_world_diagonal + 60.f) / QR_PHASE_NEAR_RADIUS,
				      eased);

		/* rim colour from the cvar string; malformed input keeps the
		   molten-orange default rather than going black */
		slot->frame.phase_color[0] = 1.5f;
		slot->frame.phase_color[1] = 0.93f;
		slot->frame.phase_color[2] = 0.27f;
		if (phase_color.string)
			sscanf (phase_color.string, "%f %f %f",
				&slot->frame.phase_color[0],
				&slot->frame.phase_color[1],
				&slot->frame.phase_color[2]);
	}
	/* comfort vignette: strength while ARTIFICIAL locomotion is fast.
	   Player velocity only -- the head-follow absorb writes the origin
	   directly and never touches velocity, so room-scale walking cannot
	   trip this. Ease quickly (~120 ms) so it reads as a response, not an
	   effect of its own. */
	{
		static float	qr_vignette_value;
		static double	qr_vignette_lasttime;
		float		target = 0.f;
		double		dt = cl.time - qr_vignette_lasttime;

		if (dt < 0 || dt > 1)
			dt = 0;
		qr_vignette_lasttime = cl.time;

		if (vr_vignette.value > 0 && sv.active && svs.clients &&
		    svs.clients[0].active)
		{
			edict_t *pl = svs.clients[0].edict;
			if (VectorLength (pl->v.velocity) > vr_vignette_threshold.value)
				target = CLAMP (0.f, vr_vignette.value, 1.f);
		}

		if (qr_vignette_value < target)
			qr_vignette_value = q_min (qr_vignette_value + (float)dt / 0.12f, target);
		else if (qr_vignette_value > target)
			qr_vignette_value = q_max (qr_vignette_value - (float)dt / 0.12f, target);
		slot->frame.vignette = qr_vignette_value;
	}

	/* output channel: the damage cshift percent (V_ParseDamage raises it,
	   V_UpdateBlend decays it) and the held weapon's IT_ bit, for haptic
	   pulses and per-weapon trigger feel on the consumer side */
	slot->frame.damage_flash = cl.cshifts[CSHIFT_DAMAGE].percent;
	slot->frame.active_weapon = (uint32_t) cl.stats[STAT_ACTIVEWEAPON];
	slot->frame.items = cl.items;

	/* room-scale head follow: what IN_AbsorbHeadOffset already walked the
	   player after, and the lean allowance for the remainder */
	slot->frame.head_absorbed[0] = qr_head_absorbed[0];
	slot->frame.head_absorbed[1] = qr_head_absorbed[1];
	slot->frame.lean_limit = q_max (vr_lean_limit.value, 0.f);
	slot->frame.recenter_count = qr_recenter_count;

	slot->frame.sky_solid_texnum = solidskytexture ? solidskytexture->texnum : 0;
	slot->frame.sky_alpha_texnum = alphaskytexture ? alphaskytexture->texnum : 0;
	if (skybox_name[0])
	{
		int axis;
		for (axis = 0; axis < 6; axis++)
			slot->frame.skybox_texnums[axis] =
				skybox_textures[skytexorder[axis]] ?
					skybox_textures[skytexorder[axis]]->texnum : 0;
	}

	QR_BuildFramePacket (slot);

	if (r_pos.value)
		Con_Printf ("x %i y %i z %i (pitch %i yaw %i roll %i)\n",
			    (int)cl_entities[cl.viewentity].origin[0],
			    (int)cl_entities[cl.viewentity].origin[1],
			    (int)cl_entities[cl.viewentity].origin[2],
			    (int)cl.viewangles[PITCH],
			    (int)cl.viewangles[YAW],
			    (int)cl.viewangles[ROLL]);
}

void QR_PublishFrame (void)
{
	qr_frame_slot_t *slot;
	byte *rgb;
	int i;

	if (qr_building < 0)
		return;

	slot = &qr_slots[qr_building];
	slot->frame.generation = qr_map_generation;
	slot->frame.indices = slot->indices;
	slot->frame.batches = slot->batches;
	slot->frame.entities = slot->entities;
	slot->frame.text_verts = slot->text_verts;
	slot->frame.conchars_texnum = qr_conchars_texnum;

	/* upstream R_Clear clears to r_clearcolor (a palette index) when
	   gl_clear is set; keep that, else clear to black */
	if (gl_clear.value)
	{
		rgb = (byte *) &d_8to24table_nobright[(int)r_clearcolor.value & 0xff];
		slot->frame.clear_color[0] = rgb[0] / 255.0f;
		slot->frame.clear_color[1] = rgb[1] / 255.0f;
		slot->frame.clear_color[2] = rgb[2] / 255.0f;
	}
	else
	{
		slot->frame.clear_color[0] = 0;
		slot->frame.clear_color[1] = 0;
		slot->frame.clear_color[2] = 0;
	}
	slot->frame.clear_color[3] = 1;

	pthread_mutex_lock (&qr_frame_lock);
	/* retire any unconsumed previous frame; latest wins */
	for (i = 0; i < 3; i++)
		if (qr_slots[i].state == QR_SLOT_READY)
			qr_slots[i].state = QR_SLOT_FREE;
	slot->seq = ++qr_frame_seq;
	slot->state = QR_SLOT_READY;
	pthread_mutex_unlock (&qr_frame_lock);

	qr_building = -1;
}

const qc_frame_t *QC_RendererAcquireFrame (void)
{
	const qc_frame_t *frame = NULL;
	int i, newest = -1;

	pthread_mutex_lock (&qr_frame_lock);
	for (i = 0; i < 3; i++)
	{
		if (qr_slots[i].state == QR_SLOT_READY &&
		    (newest < 0 || qr_slots[i].seq > qr_slots[newest].seq))
			newest = i;
	}
	if (newest >= 0)
	{
		/* a released slot may still sit READY next to a fresher publish;
		   retire it so only the packet being handed out survives */
		for (i = 0; i < 3; i++)
			if (i != newest && qr_slots[i].state == QR_SLOT_READY)
				qr_slots[i].state = QR_SLOT_FREE;
		qr_slots[newest].state = QR_SLOT_INUSE;
		frame = &qr_slots[newest].frame;
	}
	pthread_mutex_unlock (&qr_frame_lock);
	return frame;
}

void QC_RendererReleaseFrame (void)
{
	int i;

	pthread_mutex_lock (&qr_frame_lock);
	/* back to READY, not FREE: the consumer may tick faster than the
	   engine publishes, and re-rendering the latest packet beats
	   presenting an empty frame (a 120 Hz compositor against the 90 Hz
	   engine pacer flickered 30 times a second). PublishFrame retires
	   it the moment something newer exists. */
	for (i = 0; i < 3; i++)
		if (qr_slots[i].state == QR_SLOT_INUSE)
			qr_slots[i].state = QR_SLOT_READY;
	pthread_mutex_unlock (&qr_frame_lock);
}

/* ========================================================================
 * init / map load
 * ===================================================================== */

void QR_Init (void)
{
	int i;

	/* Lightmaps bake once at load with no runtime style animation yet, so
	   every style must sit at its default 'm' (256) -- zeros would bake
	   the world black. */
	for (i = 0; i < 256; i++)
		d_lightstylevalue[i] = 256;
}

void QR_NewMap (void)
{
	int i;
	msurface_t *s;

	r_viewleaf = r_oldviewleaf = NULL;
	r_framecount = 0;
	r_visframecount = 0;

	/* clear out efrags in case the level hasn't been reloaded */
	for (i = 0; i < cl.worldmodel->numleafs; i++)
		cl.worldmodel->leafs[i].efrags = NULL;

	GL_BuildLightmaps ();
	QR_BuildWorldVertexArray ();

	Sky_NewMap ();		/* worldspawn sky + skyfog keys */
	QR_ParseWorldspawn ();	/* worldspawn wateralpha overrides */
	QR_ParseSecretSubmodels ();

	{
		vec3_t size;
		VectorSubtract (cl.worldmodel->maxs, cl.worldmodel->mins, size);
		qr_world_diagonal = VectorLength (size);
	}
	qr_phase_value = CLAMP (0.f, phase.value, 1.f);	/* no sweep on map load */

	/* worst-case index count: every world surface visible */
	qr_index_worst_case = 0;
	for (i = 0, s = cl.worldmodel->surfaces; i < cl.worldmodel->numsurfaces; i++, s++)
		if (s->numedges >= 3)
			qr_index_worst_case += 3 * (s->numedges - 2);
}
