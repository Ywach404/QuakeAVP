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
extern cvar_t r_dynamic, r_flatlightstyles;	/* registered in r_null.c */
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
extern float qr_head_yaw, qr_head_pitch;	/* head gaze, for the full menu */
extern char qr_centerstring[256];	/* captured svc_centerprint (r_null.c) */
extern double qr_centertime_until;	/* cl.time expiry for the prompt */
extern float qr_body_yaw;		/* M6 body basis yaw; cl.viewangles is the aim */
extern float qr_aim_org[3];		/* M6 dominant-hand position, body frame */
extern int qr_aim_active;		/* M6 hand aim live: anchor the weapon at the hand */
extern int QR_HandOrigin (vec3_t out);	/* M6 hand position, world (in_null.c) */
extern cvar_t vr_laser;			/* M6 aiming laser toggle */
extern cvar_t vr_reticle;		/* aiming reticle toggle (alt/with the laser) */
extern cvar_t vr_reticlestyle;		/* reticle shape 0..4 */
extern cvar_t vr_reticlecolor;		/* reticle palette index */
extern cvar_t vr_lasercolor;		/* laser palette index */
extern cvar_t vr_wheelclip;		/* wheel-model front-trim keep fraction */
extern cvar_t vr_teleport;		/* teleport locomotion on */
extern cvar_t vr_teleportcolor;		/* tint the reticle cyan when landable */
extern int qr_tp_mark_state;		/* -1 hidden, 0 air, 1 blocked, 2 ok */
extern cvar_t vr_weapongrip;		/* M6 hand-weapon grip fraction */
extern cvar_t vr_weaponback, vr_weaponup, vr_weaponside;	/* M6 live position nudge */
/* The held gun's own placement, pulled from the table the UI publishes; 0
   means untuned and the cvars above are the answer (in_null.c). */
extern int QR_WeaponPlacement (int slot, float *back, float *up, float *side);
extern cvar_t vr_laserforward, vr_laserup, vr_laserside;	/* M6 laser start offset */
extern cvar_t vr_laserpitch, vr_laseryaw;			/* M6 laser beam tilt */
extern cvar_t vr_weapontint;					/* debug: green hand weapon */
extern cvar_t vr_pathdebug;					/* debug: enemy AI trails */
extern cvar_t vr_projdebug;					/* debug: projectile spawn offsets */
extern cvar_t vr_projhand;					/* draw my missiles from the hand */

/* Set only while emitting the view weapon at the hand, so QR_EmitAliasModel
   drops the VIEWMODEL flag (view-locked, which the immersive consumer skips)
   and the gun draws in the world like any other alias entity. */
static int qr_handweapon;
/* Set only while QR_EmitWheel emits its ring models, so the alias path knows to
   front-trim the baked muzzle round off wheel icons (vr_wheelclip) the way the
   hand weapon trims its own (vr_weaponclip). */
static int qr_wheelclip_on;

/* Visual weapon recoil: an eased 0..1 kick on the hand weapon, armed when the
   view weapon animates a new fire frame and decayed on the sim clock. */
static int qr_recoil_prevframe = -1;
static float qr_recoil;

/* Fire cadence for haptics: a monotonic counter bumped on each real shot,
   detected as the current weapon's ammo dropping while the weapon is
   unchanged. Lets the consumer kick on the refire rate, not on trigger spam. */
static uint32_t qr_weapon_fire_seq;
static int	qr_last_ammo = -1;	/* -1 = not yet known */
static uint32_t	qr_last_weapon;

/* Cap the hand weapon's longest model dimension, Quake units. View weapons
   run ~42 (shotgun) to ~95 (rocket launcher); at hand scale the long ones
   look oversized, so shrink anything past this uniformly. The shotgun and
   smaller are left at 1.0. */
#define QR_WEAPON_MAXLEN	45.f
extern cvar_t vr_fullmenu;		/* fixed gaze-selected panel vs wrist ring */
extern int qr_wheel_open;		/* held-open intent (release commits) */
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

/* World surfaces are grown this many Quake units outward in their own plane
   at load, so abutting brush faces overlap and T-junction cracks -- the
   sub-pixel seams that leak the level behind the stairs in VR -- are covered.
   Small enough that the texture overhang is imperceptible. */
#define QR_TJUNC_GROW		0.5f

/* Immersive only: surfaces whose plane passes within this many units of the
   eye are never back-face culled, so a stair tread the eye is grazing doesn't
   wink out and reveal the level behind it. Roughly a step and a quarter. */
#define QR_BACKFACE_KEEP	20.0f

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
	float		*particle_verts;	/* 7 floats/vert (xyz rgba) */
	uint32_t	particle_capacity;	/* in floats */
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

/* Export view-origin override (third-person cameras). Written by the export
   thread, read once per engine frame in QR_RenderView. */
static int		qr_exportcam_enabled_shared;
static vec3_t		qr_exportcam_org_shared;
static pthread_mutex_t	qr_exportcam_lock = PTHREAD_MUTEX_INITIALIZER;

void QC_ExportSetViewOrigin (int enabled, float x, float y, float z)
{
	pthread_mutex_lock (&qr_exportcam_lock);
	qr_exportcam_enabled_shared = enabled;
	qr_exportcam_org_shared[0] = x;
	qr_exportcam_org_shared[1] = y;
	qr_exportcam_org_shared[2] = z;
	pthread_mutex_unlock (&qr_exportcam_lock);
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
			{
				qc_world_vertex_t *vs = &varray[varray_index];
				int n = s->numedges, k;
				float cx = 0.f, cy = 0.f, cz = 0.f;

				memcpy (vs, s->polys->verts, n * sizeof(qc_world_vertex_t));

				/* Grow the polygon outward from its centroid. It is planar,
				   so this stays in-plane; neighbours overlap and cover the
				   T-junction cracks. UVs stay at the original verts, so the
				   overhang only stretches the texture a hair. */
				for (k = 0; k < n; k++)
				{
					cx += vs[k].xyz[0];
					cy += vs[k].xyz[1];
					cz += vs[k].xyz[2];
				}
				cx /= n; cy /= n; cz /= n;
				for (k = 0; k < n; k++)
				{
					float dx = vs[k].xyz[0] - cx;
					float dy = vs[k].xyz[1] - cy;
					float dz = vs[k].xyz[2] - cz;
					float len = sqrtf (dx * dx + dy * dy + dz * dz);
					if (len > 0.1f)
					{
						float g = QR_TJUNC_GROW / len;
						vs[k].xyz[0] += dx * g;
						vs[k].xyz[1] += dy * g;
						vs[k].xyz[2] += dz * g;
					}
				}
			}
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

	/* Near-grazing surfaces are KEPT (GPU culling is .none, so this actually
	   draws them). A stair tread the eye is nearly level with sits right at
	   its own plane (|dot| ~ 0); the plain back-face test culls it the instant
	   the eye dips below, and at the grazing angle its absence reveals the
	   level behind -- the seam that walks up the steps a few ahead of you.
	   Keeping the sliver (edge-on, invisible) fills the gap. Cheap: only
	   surfaces whose PLANE passes within QR_BACKFACE_KEEP of the eye. */
	if (qr_cull_omni && fabs (dot) < QR_BACKFACE_KEEP)
		return false;

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

/*
==================
R_AnimateLight -- drive d_lightstylevalue from the server's lightstyle
strings each frame. Port of gl_rlight.c; 'a'=0 (dark) .. 'm'=12 (normal)
.. 'z'=25, value is (map[i%len]-'a')*22. An empty style sits at 256 so an
unanimated world bakes at full base light rather than black.
==================
*/
void R_AnimateLight (void)
{
	int i,j,k;

	i = (int)(cl.time*10);
	for (j=0 ; j<MAX_LIGHTSTYLES ; j++)
	{
		if (!cl_lightstyle[j].length)
		{
			d_lightstylevalue[j] = 256;
			continue;
		}
		if (r_flatlightstyles.value == 2)
			k = cl_lightstyle[j].peak - 'a';
		else if (r_flatlightstyles.value == 1)
			k = cl_lightstyle[j].average - 'a';
		else
		{
			k = i % cl_lightstyle[j].length;
			k = cl_lightstyle[j].map[k] - 'a';
		}
		d_lightstylevalue[j] = k*22;
	}
}

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
QR_WeaponClip -- the byte-x plane forward of which the view weapon's geometry
is retracted to the muzzle, to hide the loaded round / nail the models bake
past the barrel. Auto-detecting a projectile from a thin barrel proved
unreliable (a launcher's barrel looks the same as a nail in the vertex data),
so it's a manual knob: vr_weaponclip is the fraction of the model's forward
span to KEEP (1 = keep all / off, lower = cut more off the front). Tune it live
per weapon in the Weapon menu -- you can see the model, the math can't.
=================
*/
extern cvar_t vr_weaponclip, vr_weaponclipback;
extern cvar_t vr_wheelpitch, vr_wheelyaw, vr_wheelroll, vr_wheelradius;
extern cvar_t vr_wheelfwd, vr_wheelup, vr_wheelside;	/* ring fine-placement, body frame */

static void QR_WeaponClipF (aliashdr_t *h, float ff, float fb, float out[4])
{
	int		i, nv, minb = 255, maxb = 0, front, rear, nb = 0;
	trivertx_t	*v;
	double		sy = 0, sz = 0;

	ff = CLAMP (0.3f, ff, 1.f);       /* keep from rear */
	fb = CLAMP (0.3f, fb, 1.f);       /* keep from front */

	/* disabled: front plane above every byte, rear plane below every byte */
	out[0] = 255.f; out[1] = -1.f; out[2] = out[3] = 128.f;
	if (ff >= 0.999f && fb >= 0.999f) return;

	nv = h->numverts_vbo;
	v = (trivertx_t *)((byte *)h + h->vertexes) + h->frames[0].firstpose * nv;
	for (i = 0; i < nv; i++)
	{
		int x = v[i].v[0];
		if (x < minb) minb = x;
		if (x > maxb) maxb = x;
	}
	front = minb + (int)((maxb - minb) * ff);          /* clip verts above this */
	rear  = minb + (int)((maxb - minb) * (1.f - fb));  /* clip verts below this */

	/* collapse centre = mean y,z of the body that survives both planes */
	for (i = 0; i < nv; i++)
		if (v[i].v[0] <= front && v[i].v[0] >= rear) { sy += v[i].v[1]; sz += v[i].v[2]; nb++; }
	out[0] = (ff  >= 0.999f) ? 255.f : (float) front;
	out[1] = (fb  >= 0.999f) ? -1.f  : (float) rear;
	out[2] = nb ? (float)(sy / nb) : 128.f;
	out[3] = nb ? (float)(sz / nb) : 128.f;
}

/* The held weapon's clip, driven by the two trim cvars. */
static void QR_WeaponClip (aliashdr_t *h, float out[4])
{
	QR_WeaponClipF (h, vr_weaponclip.value, vr_weaponclipback.value, out);
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
	if (e == &cl.viewent && !qr_handweapon)
		rec.flags |= QC_ENTFLAG_VIEWMODEL;

	/* Clip disabled by default (255 = no byte-x exceeds it). Only the
	   hand-held weapon retracts its baked-in projectile spike. */
	rec.clip[0] = 255.f;
	rec.clip[1] = rec.clip[2] = rec.clip[3] = 0.f;
	if (qr_handweapon)
	{
		QR_WeaponClip (paliashdr, rec.clip);
		if (vr_weapontint.value)
			rec.dbg[0] = 1.f;   /* debug: paint the hand weapon green */
	}
	else if (qr_wheelclip_on && vr_wheelclip.value < 0.999f)
		/* Trim the REAR only (ff = 1), exactly like the hand weapon's
		   vr_weaponclipback: the baked round sits near the grip, NOT at the
		   muzzle, so front-trimming (what the first pass did) chopped the
		   barrels to stubs. Keep the whole barrel, retract the rear round. */
		QR_WeaponClipF (paliashdr, 1.f, vr_wheelclip.value, rec.clip);

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
Particles -- a faithful port of Quake's classic particle system (gl_rpart.c
minus the GL draw). The spawn functions (R_ParticleExplosion, R_RocketTrail,
...) are engine entry points, stubbed no-ops before this. CL_RunParticles
ages and moves them once per host frame (host.c calls it); QR_EmitParticles
billboards the live set into the packet as colour quads, drawn depth-tested
with the wheel-guide pipeline. Dynamic lights already flashed on explosions;
this is the missing visual body.
================
*/
#define QR_MAX_PARTICLES	8192
#define QR_PARTICLE_SIZE	1.3f

extern cvar_t		sv_gravity;

static particle_t	qr_particles[QR_MAX_PARTICLES];
static particle_t	*qr_active_particles, *qr_free_particles;
static int		qr_particles_inited;

static const int	qr_ramp1[8] = {0x6f, 0x6d, 0x6b, 0x69, 0x67, 0x65, 0x63, 0x61};
static const int	qr_ramp2[8] = {0x6f, 0x6e, 0x6d, 0x6c, 0x6b, 0x6a, 0x68, 0x66};
static const int	qr_ramp3[8] = {0x6d, 0x6b, 0x06, 0x05, 0x04, 0x03, 0x00, 0x00};

void R_ClearParticles (void)
{
	int i;

	qr_free_particles = &qr_particles[0];
	qr_active_particles = NULL;
	for (i = 0; i < QR_MAX_PARTICLES - 1; i++)
		qr_particles[i].next = &qr_particles[i + 1];
	qr_particles[QR_MAX_PARTICLES - 1].next = NULL;
	qr_particles_inited = 1;
}

static particle_t *QR_AllocParticle (void)
{
	particle_t *p;

	if (!qr_particles_inited)
		R_ClearParticles ();
	if (!qr_free_particles)
		return NULL;
	p = qr_free_particles;
	qr_free_particles = p->next;
	p->next = qr_active_particles;
	qr_active_particles = p;
	return p;
}

void R_ParticleExplosion (vec3_t org)
{
	int		i, j;
	particle_t	*p;

	for (i = 0; i < 1024; i++)
	{
		if (!(p = QR_AllocParticle ()))
			return;
		p->die = cl.time + 5;
		p->color = qr_ramp1[0];
		p->ramp = rand () & 3;
		p->type = (i & 1) ? pt_explode : pt_explode2;
		for (j = 0; j < 3; j++)
		{
			p->org[j] = org[j] + ((rand () % 32) - 16);
			p->vel[j] = (rand () % 512) - 256;
		}
	}
}

void R_ParticleExplosion2 (vec3_t org, int colorStart, int colorLength)
{
	int		i, j, colorMod = 0;
	particle_t	*p;

	for (i = 0; i < 512; i++)
	{
		if (!(p = QR_AllocParticle ()))
			return;
		p->die = cl.time + 0.3f;
		p->color = colorStart + (colorMod % colorLength);
		colorMod++;
		p->type = pt_blob;
		for (j = 0; j < 3; j++)
		{
			p->org[j] = org[j] + ((rand () % 32) - 16);
			p->vel[j] = (rand () % 512) - 256;
		}
	}
}

void R_BlobExplosion (vec3_t org)
{
	int		i, j;
	particle_t	*p;

	for (i = 0; i < 1024; i++)
	{
		if (!(p = QR_AllocParticle ()))
			return;
		p->die = cl.time + 1 + (rand () & 8) * 0.05f;
		if (i & 1)
		{
			p->type = pt_blob;
			p->color = 66 + rand () % 6;
		}
		else
		{
			p->type = pt_blob2;
			p->color = 150 + rand () % 6;
		}
		for (j = 0; j < 3; j++)
		{
			p->org[j] = org[j] + ((rand () % 32) - 16);
			p->vel[j] = (rand () % 512) - 256;
		}
	}
}

void R_RunParticleEffect (vec3_t org, vec3_t dir, int color, int count)
{
	int		i, j;
	particle_t	*p;

	for (i = 0; i < count; i++)
	{
		if (!(p = QR_AllocParticle ()))
			return;
		p->die = cl.time + 0.1f * (rand () % 5);
		p->color = (color & ~7) + (rand () & 7);
		p->type = pt_slowgrav;
		for (j = 0; j < 3; j++)
		{
			p->org[j] = org[j] + ((rand () & 15) - 8);
			p->vel[j] = dir[j] * 15;
		}
	}
}

void R_LavaSplash (vec3_t org)
{
	int		i, j, k;
	particle_t	*p;
	float		vel;
	vec3_t		dir;

	for (i = -16; i < 16; i++)
		for (j = -16; j < 16; j++)
			for (k = 0; k < 1; k++)
			{
				if (!(p = QR_AllocParticle ()))
					return;
				p->die = cl.time + 2 + (rand () & 31) * 0.02f;
				p->color = 224 + (rand () & 7);
				p->type = pt_slowgrav;
				dir[0] = j * 8 + (rand () & 7);
				dir[1] = i * 8 + (rand () & 7);
				dir[2] = 256;
				p->org[0] = org[0] + dir[0];
				p->org[1] = org[1] + dir[1];
				p->org[2] = org[2] + (rand () & 63);
				VectorNormalize (dir);
				vel = 50 + (rand () & 63);
				VectorScale (dir, vel, p->vel);
			}
}

void R_TeleportSplash (vec3_t org)
{
	int		i, j, k;
	particle_t	*p;
	float		vel;
	vec3_t		dir;

	for (i = -16; i < 16; i += 4)
		for (j = -16; j < 16; j += 4)
			for (k = -24; k < 32; k += 4)
			{
				if (!(p = QR_AllocParticle ()))
					return;
				p->die = cl.time + 0.2f + (rand () & 7) * 0.02f;
				p->color = 7 + (rand () & 7);
				p->type = pt_slowgrav;
				dir[0] = j * 8;
				dir[1] = i * 8;
				dir[2] = k * 8;
				p->org[0] = org[0] + i + (rand () & 3);
				p->org[1] = org[1] + j + (rand () & 3);
				p->org[2] = org[2] + k + (rand () & 3);
				VectorNormalize (dir);
				vel = 50 + (rand () & 63);
				VectorScale (dir, vel, p->vel);
			}
}

void R_RocketTrail (vec3_t start, vec3_t end, int type)
{
	vec3_t		vec;
	float		len;
	int		j, dec;
	particle_t	*p;
	static int	tracercount;

	VectorSubtract (end, start, vec);
	len = VectorNormalize (vec);
	dec = (type < 128) ? 3 : (type -= 128, 1);

	while (len > 0)
	{
		len -= dec;
		if (!(p = QR_AllocParticle ()))
			return;
		VectorCopy (vec3_origin, p->vel);
		p->die = cl.time + 2;
		switch (type)
		{
		case 0:		/* rocket trail */
			p->ramp = rand () & 3;
			p->color = qr_ramp3[(int) p->ramp];
			p->type = pt_fire;
			for (j = 0; j < 3; j++)
				p->org[j] = start[j] + ((rand () % 6) - 3);
			break;
		case 1:		/* smoke smoke */
			p->ramp = (rand () & 3) + 2;
			p->color = qr_ramp3[(int) p->ramp];
			p->type = pt_fire;
			for (j = 0; j < 3; j++)
				p->org[j] = start[j] + ((rand () % 6) - 3);
			break;
		case 2:		/* blood */
			p->type = pt_grav;
			p->color = 67 + (rand () & 3);
			for (j = 0; j < 3; j++)
				p->org[j] = start[j] + ((rand () % 6) - 3);
			break;
		case 3:
		case 5:		/* tracer */
			p->die = cl.time + 0.5f;
			p->type = pt_static;
			p->color = (type == 3) ? 52 + ((tracercount & 4) << 1)
					       : 230 + ((tracercount & 4) << 1);
			tracercount++;
			VectorCopy (start, p->org);
			if (tracercount & 1)
			{
				p->vel[0] = 30 * vec[1];
				p->vel[1] = 30 * -vec[0];
			}
			else
			{
				p->vel[0] = 30 * -vec[1];
				p->vel[1] = 30 * vec[0];
			}
			break;
		case 4:		/* slight blood */
			p->type = pt_grav;
			p->color = 67 + (rand () & 3);
			for (j = 0; j < 3; j++)
				p->org[j] = start[j] + ((rand () % 6) - 3);
			len -= 3;
			break;
		case 6:		/* voor trail */
			p->color = 9 * 16 + 8 + (rand () & 3);
			p->type = pt_static;
			p->die = cl.time + 0.3f;
			for (j = 0; j < 3; j++)
				p->org[j] = start[j] + ((rand () & 15) - 8);
			break;
		}
		VectorAdd (start, vec, start);
	}
}

void R_EntityParticles (entity_t *ent)
{
	(void) ent;	/* the spawn-effect shell: rare, skip for now */
}

void CL_RunParticles (void)
{
	particle_t	*p, *kill;
	int		i;
	float		grav, dvel, time1, time2, time3, frametime;
	static double	lasttime;

	if (!qr_particles_inited)
		R_ClearParticles ();

	frametime = (float) (cl.time - lasttime);
	lasttime = cl.time;
	if (frametime < 0)		/* map change / demo restart */
	{
		R_ClearParticles ();
		frametime = 0;
	}
	else if (frametime > 0.1f)
		frametime = 0.1f;

	time3 = frametime * 15;
	time2 = frametime * 10;
	time1 = frametime * 5;
	grav = frametime * sv_gravity.value * 0.05f;
	dvel = 4 * frametime;

	for ( ; ; )	/* reap dead at the head */
	{
		kill = qr_active_particles;
		if (kill && kill->die < cl.time)
		{
			qr_active_particles = kill->next;
			kill->next = qr_free_particles;
			qr_free_particles = kill;
			continue;
		}
		break;
	}

	for (p = qr_active_particles; p; p = p->next)
	{
		for ( ; ; )	/* reap dead mid-list */
		{
			kill = p->next;
			if (kill && kill->die < cl.time)
			{
				p->next = kill->next;
				kill->next = qr_free_particles;
				qr_free_particles = kill;
				continue;
			}
			break;
		}

		p->org[0] += p->vel[0] * frametime;
		p->org[1] += p->vel[1] * frametime;
		p->org[2] += p->vel[2] * frametime;

		switch (p->type)
		{
		case pt_fire:
			p->ramp += time1;
			if (p->ramp >= 6)
				p->die = -1;
			else
				p->color = qr_ramp3[(int) p->ramp];
			p->vel[2] += grav;
			break;
		case pt_explode:
			p->ramp += time2;
			if (p->ramp >= 8)
				p->die = -1;
			else
				p->color = qr_ramp1[(int) p->ramp];
			for (i = 0; i < 3; i++)
				p->vel[i] += p->vel[i] * dvel;
			p->vel[2] -= grav;
			break;
		case pt_explode2:
			p->ramp += time3;
			if (p->ramp >= 8)
				p->die = -1;
			else
				p->color = qr_ramp2[(int) p->ramp];
			for (i = 0; i < 3; i++)
				p->vel[i] -= p->vel[i] * frametime;
			p->vel[2] -= grav;
			break;
		case pt_blob:
			for (i = 0; i < 3; i++)
				p->vel[i] += p->vel[i] * dvel;
			p->vel[2] -= grav;
			break;
		case pt_blob2:
			for (i = 0; i < 2; i++)
				p->vel[i] -= p->vel[i] * dvel;
			p->vel[2] -= grav;
			break;
		case pt_grav:
		case pt_slowgrav:
			p->vel[2] -= grav;
			break;
		case pt_static:
		default:
			break;
		}
	}
}

static void QR_ParticleVert (qr_frame_slot_t *slot, const vec3_t p,
			     float r, float g, float b)
{
	uint32_t	n = slot->frame.num_particle_verts;
	float		*o;

	if ((n + 1) * 7 > slot->particle_capacity)
	{
		slot->particle_capacity = slot->particle_capacity ? slot->particle_capacity * 2 : 8192;
		slot->particle_verts = (float *) realloc (slot->particle_verts,
				slot->particle_capacity * sizeof(float));
	}
	o = slot->particle_verts + n * 7;
	o[0] = p[0]; o[1] = p[1]; o[2] = p[2];
	o[3] = r; o[4] = g; o[5] = b; o[6] = 1.f;
	slot->frame.num_particle_verts = n + 1;
}

/*
================
QR_EmitLaser -- an aiming laser from the muzzle down the aim (vr_laser). A
thin view-facing quad appended to the particle channel, which is depth-tested
against the world with no write -- so the beam clips exactly where the shot
would hit, no trace needed. `angles` is cl.viewangles, the fired aim, so the
line lands where the bullets do.
================
*/
/* Shared reticle/laser colour palette. Index set by vr_lasercolor /
   vr_reticlecolor; the laser default (0) is the historical red, the reticle
   default (3) the historical amber. */
#define QR_VRCOLORS	9
static void QR_VrColor (int idx, float *r, float *g, float *b)
{
	static const float pal[QR_VRCOLORS][3] = {
		{1.00f, 0.15f, 0.12f},	/* 0 red        */
		{0.20f, 1.00f, 0.30f},	/* 1 green      */
		{0.20f, 0.90f, 1.00f},	/* 2 cyan       */
		{1.00f, 0.85f, 0.20f},	/* 3 amber      */
		{1.00f, 1.00f, 1.00f},	/* 4 white      */
		{1.00f, 0.25f, 0.90f},	/* 5 magenta    */
		{1.00f, 0.95f, 0.20f},	/* 6 yellow     */
		{0.35f, 0.55f, 1.00f},	/* 7 blue       */
		{0.82f, 0.66f, 0.46f},	/* 8 Quake beige -- the status-bar tan */
	};
	if (idx < 0 || idx >= QR_VRCOLORS) idx = 0;
	*r = pal[idx][0]; *g = pal[idx][1]; *b = pal[idx][2];
}

static void QR_EmitLaser (qr_frame_slot_t *slot, const vec3_t start,
			  const vec3_t angles)
{
	vec3_t	fwd, right, up, end, look, perp;
	vec3_t	a0, a1, b0, b1;
	float	hw = 0.35f;	/* half width, Quake units */
	float	cr, cg, cb;
	int	k;

	QR_VrColor ((int) vr_lasercolor.value, &cr, &cg, &cb);
	AngleVectors (angles, fwd, right, up);
	VectorMA (start, 4096.f, fwd, end);
	/* Face the eye from the START, not the beam midpoint. The midpoint sits
	   ~2000 units down the aim, so eye->midpoint is almost antiparallel to
	   fwd and fwd x that collapses to zero -- the width axis then fell back to
	   world-X and the beam showed edge-on at most view angles. From the start
	   (right by the gun) the view direction is well clear of fwd. */
	VectorSubtract (r_origin, start, look);
	CrossProduct (fwd, look, perp);
	if (VectorNormalize (perp) < 0.01f)
	{
		/* aiming straight at/away from the eye: any axis normal to fwd */
		CrossProduct (fwd, up, perp);
		if (VectorNormalize (perp) < 0.01f)
		{
			perp[0] = 1.f; perp[1] = 0.f; perp[2] = 0.f;
		}
	}
	for (k = 0; k < 3; k++)
	{
		a0[k] = start[k] - perp[k] * hw;
		a1[k] = start[k] + perp[k] * hw;
		b0[k] = end[k] - perp[k] * hw;
		b1[k] = end[k] + perp[k] * hw;
	}
	QR_ParticleVert (slot, a0, cr, cg, cb);
	QR_ParticleVert (slot, a1, cr, cg, cb);
	QR_ParticleVert (slot, b1, cr, cg, cb);
	QR_ParticleVert (slot, a0, cr, cg, cb);
	QR_ParticleVert (slot, b1, cr, cg, cb);
	QR_ParticleVert (slot, b0, cr, cg, cb);
}

/* --- reticle primitives, all billboarded in the (bx,by) plane at centre c --- */
#define QR_RET_SEGS	18

/* A filled rectangle, half-extents hx along bx and hy along by. */
static void QR_RetQuad (qr_frame_slot_t *slot, const vec3_t c,
			const vec3_t bx, const vec3_t by, float hx, float hy,
			float r, float g, float b)
{
	vec3_t	p0, p1, p2, p3;
	int	k;
	for (k = 0; k < 3; k++)
	{
		p0[k] = c[k] - bx[k]*hx - by[k]*hy;
		p1[k] = c[k] + bx[k]*hx - by[k]*hy;
		p2[k] = c[k] + bx[k]*hx + by[k]*hy;
		p3[k] = c[k] - bx[k]*hx + by[k]*hy;
	}
	QR_ParticleVert (slot, p0, r, g, b); QR_ParticleVert (slot, p1, r, g, b);
	QR_ParticleVert (slot, p2, r, g, b); QR_ParticleVert (slot, p0, r, g, b);
	QR_ParticleVert (slot, p2, r, g, b); QR_ParticleVert (slot, p3, r, g, b);
}

/* A filled disc of radius rad (triangle fan). */
static void QR_RetDisc (qr_frame_slot_t *slot, const vec3_t c,
			const vec3_t bx, const vec3_t by, float rad,
			float r, float g, float b)
{
	vec3_t	p0, p1;
	int	i, k;
	for (i = 0; i < QR_RET_SEGS; i++)
	{
		float a0 = 2.f*(float)M_PI*i/QR_RET_SEGS;
		float a1 = 2.f*(float)M_PI*(i+1)/QR_RET_SEGS;
		for (k = 0; k < 3; k++)
		{
			p0[k] = c[k] + rad*(bx[k]*cosf(a0) + by[k]*sinf(a0));
			p1[k] = c[k] + rad*(bx[k]*cosf(a1) + by[k]*sinf(a1));
		}
		QR_ParticleVert (slot, c, r, g, b);
		QR_ParticleVert (slot, p0, r, g, b);
		QR_ParticleVert (slot, p1, r, g, b);
	}
}

/* An annulus between rin and rout (a drawn circle outline). */
static void QR_RetRing (qr_frame_slot_t *slot, const vec3_t c,
			const vec3_t bx, const vec3_t by, float rin, float rout,
			float r, float g, float b)
{
	vec3_t	i0, i1, o0, o1;
	int	i, k;
	for (i = 0; i < QR_RET_SEGS; i++)
	{
		float a0 = 2.f*(float)M_PI*i/QR_RET_SEGS;
		float a1 = 2.f*(float)M_PI*(i+1)/QR_RET_SEGS;
		for (k = 0; k < 3; k++)
		{
			i0[k] = c[k] + rin *(bx[k]*cosf(a0) + by[k]*sinf(a0));
			i1[k] = c[k] + rin *(bx[k]*cosf(a1) + by[k]*sinf(a1));
			o0[k] = c[k] + rout*(bx[k]*cosf(a0) + by[k]*sinf(a0));
			o1[k] = c[k] + rout*(bx[k]*cosf(a1) + by[k]*sinf(a1));
		}
		QR_ParticleVert (slot, i0, r, g, b); QR_ParticleVert (slot, o0, r, g, b);
		QR_ParticleVert (slot, o1, r, g, b); QR_ParticleVert (slot, i0, r, g, b);
		QR_ParticleVert (slot, o1, r, g, b); QR_ParticleVert (slot, i1, r, g, b);
	}
}

/*
================
QR_TraceSurface -- like TraceLine (chase.c) but also returns the hit plane's
normal, which the ground-decal reticle needs. Returns true on a real hit.
================
*/
static qboolean QR_TraceSurface (const vec3_t start, const vec3_t end,
				 vec3_t impact, vec3_t normal)
{
	trace_t	trace;

	memset (&trace, 0, sizeof(trace));
	if (!cl.worldmodel)
	{
		VectorCopy (end, impact);
		normal[0] = normal[1] = normal[2] = 0.f;
		return false;
	}
	SV_RecursiveHullCheck (cl.worldmodel->hulls, 0, 0, 1,
			       (float *) start, (float *) end, &trace);
	VectorCopy (trace.endpos, impact);
	VectorCopy (trace.plane.normal, normal);
	return trace.fraction < 1.f;
}

/*
================
QR_NearestEntityHit -- the nearest visible entity the ray start+t*dir enters,
within maxdist, by ray/AABB against each visedict's model bounds (a touch
inflated so hovering reads generously). The world trace ignores monsters and
movers, so without this the reticle sails through an enemy onto the wall. dir
must be unit length. Returns the entry distance in *outt.
================
*/
static qboolean QR_NearestEntityHit (const vec3_t start, const vec3_t dir,
				     float maxdist, float *outt)
{
	int		i, a;
	qboolean	found = false;
	float		best = maxdist;

	for (i = 0; i < cl_numvisedicts; i++)
	{
		entity_t	*e = cl_visedicts[i];
		vec3_t		amin, amax, lo, hi;
		float		tmin = 1.f, tmax = best, t1, t2;
		qboolean	miss = false;

		if (!e->model)
			continue;
		if (e->model->type != mod_alias && e->model->type != mod_brush)
			continue;
		/* Skip things the shot passes through, so the reticle does too:
		   gibs and gibbed heads (non-solid), and -- the spazzing bug -- the
		   player's OWN in-flight projectiles, which fly straight down the aim
		   line and would snatch the reticle off into the air. */
		{
			const char *mn = e->model->name;
			if (strstr (mn, "gib") || !strncmp (mn, "progs/h_", 8) ||
			    strstr (mn, "spike")   || strstr (mn, "grenade") ||
			    strstr (mn, "missile") || strstr (mn, "lavaball") ||
			    strstr (mn, "laser"))
				continue;
		}

		/* Bounds. For an alias model use the CURRENT FRAME's bbox, not the
		   all-frames union: a corpse in a death frame is flat and near the
		   floor, where the union box would stand tall and leave the reticle
		   hanging in the air above it. */
		if (e->model->type == mod_alias)
		{
			aliashdr_t	*ah = (aliashdr_t *) Mod_Extradata (e->model);
			int		fr = e->frame;

			if (fr < 0 || fr >= ah->numframes) fr = 0;
			for (a = 0; a < 3; a++)
			{
				lo[a] = ah->frames[fr].bboxmin.v[a] * ah->scale[a] + ah->scale_origin[a];
				hi[a] = ah->frames[fr].bboxmax.v[a] * ah->scale[a] + ah->scale_origin[a];
			}
		}
		else
		{
			VectorCopy (e->model->mins, lo);
			VectorCopy (e->model->maxs, hi);
		}
		for (a = 0; a < 3; a++)
		{
			amin[a] = e->origin[a] + lo[a] - 2.f;
			amax[a] = e->origin[a] + hi[a] + 2.f;
			if (fabsf (dir[a]) < 1e-5f)
			{
				if (start[a] < amin[a] || start[a] > amax[a]) { miss = true; break; }
				continue;
			}
			t1 = (amin[a] - start[a]) / dir[a];
			t2 = (amax[a] - start[a]) / dir[a];
			if (t1 > t2) { float tmp = t1; t1 = t2; t2 = tmp; }
			if (t1 > tmin) tmin = t1;
			if (t2 < tmax) tmax = t2;
			if (tmin > tmax) { miss = true; break; }
		}
		if (miss)
			continue;
		if (tmin < best)
		{
			best = tmin;
			found = true;
		}
	}
	*outt = best;
	return found;
}

/*
================
QR_EmitReticle -- an aim mark where the shot lands, in the depth-tested
particle channel. It lies FLAT ON THE HIT SURFACE (a decal oriented to the
surface normal), lifted a hair toward the eye -- so on a wall it faces you and
on the floor it lies flat like a teleport marker, and it no longer clips into
the geometry when you aim down. In open air (no hit) it billboards to face the
eye at a fixed throw. Shape is vr_reticlestyle (cross / circle+dot / dot /
circle), colour vr_reticlecolor.
================
*/
static void QR_EmitReticle (qr_frame_slot_t *slot, const vec3_t start,
			    const vec3_t angles)
{
	vec3_t	fwd, rv, uv, far, hit, n, bx, by, look, ref;
	vec3_t	wup = { 0.f, 0.f, 1.f };
	float	dist, sz, hw, cr, cg, cb, raydist, entt;
	int	style = (int) vr_reticlestyle.value;
	int	hitsurf, flat, k;

	QR_VrColor ((int) vr_reticlecolor.value, &cr, &cg, &cb);
	/* Teleport feedback on the ONE reticle: tint it cyan when the spot you're
	   aiming at is a valid landing (qr_tp_mark_state 2). No second ring. */
	if (vr_teleport.value && vr_teleportcolor.value && qr_tp_mark_state == 2)
	{
		cr = 0.25f; cg = 0.95f; cb = 1.00f;
	}
	AngleVectors (angles, fwd, rv, uv);
	VectorMA (start, 4096.f, fwd, far);
	hitsurf = QR_TraceSurface (start, far, hit, n);
	/* how far down the aim the world hit is (fwd is unit length) */
	raydist = hitsurf
		? (hit[0]-start[0])*fwd[0] + (hit[1]-start[1])*fwd[1] + (hit[2]-start[2])*fwd[2]
		: 4096.f;

	if (QR_NearestEntityHit (start, fwd, raydist, &entt))
	{
		/* An enemy/mover is nearer than the wall: stop ON it, facing the eye
		   (a decal makes no sense on a monster). This is why the reticle no
		   longer phases through things you aim at. */
		VectorMA (start, entt, fwd, hit);
		flat = 0;
	}
	else if (hitsurf && VectorLength (n) > 0.1f)
	{
		flat = 1;	/* world surface: lie flat as a decal */
	}
	else
	{
		VectorMA (start, 1000.f, fwd, hit);	/* open air: a fixed throw */
		flat = 0;
	}

	VectorSubtract (hit, r_origin, look);
	dist = VectorLength (look);
	if (dist < 1.f)
		return;

	if (flat)
	{
		/* Decal: orient to the surface plane. A reference axis not parallel
		   to the normal spans the plane with two tangents -- world forward
		   for a near-horizontal surface (floor/ceiling), world up otherwise. */
		float	lift, toeye;

		if (fabsf (n[2]) > 0.9f) { ref[0] = 1.f; ref[1] = 0.f; ref[2] = 0.f; }
		else                     { ref[0] = 0.f; ref[1] = 0.f; ref[2] = 1.f; }
		CrossProduct (ref, n, bx);
		if (VectorNormalize (bx) < 0.01f) { bx[0] = 1.f; bx[1] = 0.f; bx[2] = 0.f; }
		CrossProduct (n, bx, by);
		VectorNormalize (by);

		/* Lift a hair off the surface toward the eye so the decal doesn't
		   z-fight the wall/floor it sits on. Along the normal, flipped if the
		   normal faces away from us. */
		toeye = -DotProduct (look, n);		/* >0 when n points at the eye */
		lift = 1.5f;
		for (k = 0; k < 3; k++)
			hit[k] += n[k] * (toeye >= 0.f ? lift : -lift);
		/* the lift moved the point; refresh the view distance */
		VectorSubtract (hit, r_origin, look);
		dist = VectorLength (look);
		if (dist < 1.f)
			return;
	}
	else
	{
		/* Billboard facing the eye (entity hit or open air). */
		CrossProduct (look, wup, bx);
		if (VectorNormalize (bx) < 0.01f) { bx[0] = 1.f; bx[1] = 0.f; bx[2] = 0.f; }
		CrossProduct (bx, look, by);
		VectorNormalize (by);
	}

	sz = dist * 0.011f;	/* mark half-size; constant angular size */
	hw = sz * 0.16f;	/* bar half-thickness */

	switch (style)
	{
	case 1:	/* circle + centre dot (Wii-style) */
		QR_RetRing (slot, hit, bx, by, sz*0.72f, sz*0.92f, cr, cg, cb);
		QR_RetDisc (slot, hit, bx, by, sz*0.26f, cr, cg, cb);
		break;
	case 2:	/* dot */
		QR_RetDisc (slot, hit, bx, by, sz*0.30f, cr, cg, cb);
		break;
	case 3:	/* circle */
		QR_RetRing (slot, hit, bx, by, sz*0.72f, sz*0.92f, cr, cg, cb);
		break;
	default:	/* 0: cross */
		QR_RetQuad (slot, hit, bx, by, sz, hw, cr, cg, cb);
		QR_RetQuad (slot, hit, bx, by, hw, sz, cr, cg, cb);
		break;
	}
}

/*
================
QR_EmitDebugLine -- a coloured world-space line between two points, as a thin
view-facing quad in the particle channel (foveation forbids GL_LINES on
device). Depth-tested against the world, so a segment behind a wall is hidden.
================
*/
static void QR_EmitDebugLine (qr_frame_slot_t *slot, const vec3_t a, const vec3_t b,
			      float r, float g, float bl, float hw)
{
	vec3_t	dir, mid, look, perp, a0, a1, b0, b1;
	int	k;

	VectorSubtract (b, a, dir);
	if (VectorNormalize (dir) < 0.01f)
		return;
	for (k = 0; k < 3; k++)
		mid[k] = 0.5f * (a[k] + b[k]);
	VectorSubtract (r_origin, mid, look);
	CrossProduct (dir, look, perp);
	if (VectorNormalize (perp) < 0.01f)
	{
		perp[0] = 0.f; perp[1] = 0.f; perp[2] = 1.f;
	}
	for (k = 0; k < 3; k++)
	{
		a0[k] = a[k] - perp[k] * hw;
		a1[k] = a[k] + perp[k] * hw;
		b0[k] = b[k] - perp[k] * hw;
		b1[k] = b[k] + perp[k] * hw;
	}
	QR_ParticleVert (slot, a0, r, g, bl);
	QR_ParticleVert (slot, a1, r, g, bl);
	QR_ParticleVert (slot, b1, r, g, bl);
	QR_ParticleVert (slot, a0, r, g, bl);
	QR_ParticleVert (slot, b1, r, g, bl);
	QR_ParticleVert (slot, b0, r, g, bl);
}

/*
================
QR_EmitDebugDashes -- QR_EmitDebugLine broken into a marching-ants dashed line.
`runlen` accumulates arc length across the whole polyline so dashes stay
continuous over breadcrumb joints; `phase` (advanced from cl.time by the caller)
crawls the ants along the trail. Quake units.
================
*/
#define QR_DASH_ON	7.f		/* dash length */
#define QR_DASH_OFF	7.f		/* gap length */
#define QR_DASH_SPEED	28.f		/* units/sec the ants march */

static void QR_EmitDebugDashes (qr_frame_slot_t *slot, const vec3_t a, const vec3_t b,
				float r, float g, float bl, float hw,
				float *runlen, float phase)
{
	vec3_t	dir, pa, pb;
	float	seglen, period, g0, g1, ds, de, cs, ce;
	int	k;

	VectorSubtract (b, a, dir);
	seglen = VectorNormalize (dir);
	if (seglen < 0.01f)
		return;

	period = QR_DASH_ON + QR_DASH_OFF;
	g0 = *runlen;
	g1 = *runlen + seglen;
	/* first dash whose start is at or before g0, in global arc coords */
	ds = floorf ((g0 + phase) / period) * period - phase;
	for (; ds < g1; ds += period)
	{
		de = ds + QR_DASH_ON;
		cs = ds > g0 ? ds : g0;			/* clip the dash to this segment */
		ce = de < g1 ? de : g1;
		if (ce <= cs)
			continue;
		for (k = 0; k < 3; k++)
		{
			pa[k] = a[k] + dir[k] * (cs - g0);
			pb[k] = a[k] + dir[k] * (ce - g0);
		}
		QR_EmitDebugLine (slot, pa, pb, r, g, bl, hw);
	}
	*runlen = g1;
}

/*
================
QR_EmitPathDebug -- the enemy AI overlay (vr_pathdebug). Quake AI is greedy
(SV_MoveToGoal steps toward the goal each think, no planned path), so there is
no route to draw. Instead, per live monster: a BREADCRUMB trail of where it has
actually walked (recorded when it travels past QR_PATH_MINDIST), plus an INTENT
line to its current target (enemy, else goalentity). Coloured per monster by
edict number. Server-side data, single-player only.
================
*/
#define QR_PATH_SLOTS	64
#define QR_PATH_CRUMBS	16
#define QR_PATH_MINDIST	24.f

typedef struct {
	int	ednum;			/* 0 = free slot */
	int	count;
	int	head;			/* next write into the ring */
	vec3_t	pts[QR_PATH_CRUMBS];
} qr_path_t;

static qr_path_t	qr_paths[QR_PATH_SLOTS];
static qmodel_t		*qr_path_worldkey;

static void QR_PathColor (int ednum, float *r, float *g, float *b)
{
	/* spread hues around the wheel by edict number (HSV, s=v=1) */
	float	h = (float)((ednum * 47) % 360);
	float	c = 1.f, x = c * (1.f - fabsf (fmodf (h / 60.f, 2.f) - 1.f));

	if (h < 60)	{ *r = c; *g = x; *b = 0; }
	else if (h < 120) { *r = x; *g = c; *b = 0; }
	else if (h < 180) { *r = 0; *g = c; *b = x; }
	else if (h < 240) { *r = 0; *g = x; *b = c; }
	else if (h < 300) { *r = x; *g = 0; *b = c; }
	else		{ *r = c; *g = 0; *b = x; }
}

static qr_path_t *QR_PathSlot (int ednum)
{
	int	i, free = -1;

	for (i = 0; i < QR_PATH_SLOTS; i++)
	{
		if (qr_paths[i].ednum == ednum)
			return &qr_paths[i];
		if (free < 0 && qr_paths[i].ednum == 0)
			free = i;
	}
	if (free < 0)
		return NULL;		/* pool full: skip the trail (intent still drawn) */
	qr_paths[free].ednum = ednum;
	qr_paths[free].count = 0;
	qr_paths[free].head = 0;
	return &qr_paths[free];
}

static void QR_EmitPathDebug (qr_frame_slot_t *slot)
{
	int	e, i;

	if (!vr_pathdebug.value || !sv.active)
		return;

	/* clear the pool across map loads (edict numbers are reused) */
	if (qr_path_worldkey != cl.worldmodel)
	{
		qr_path_worldkey = cl.worldmodel;
		memset (qr_paths, 0, sizeof qr_paths);
	}

	/* release slots whose monster died or freed */
	for (i = 0; i < QR_PATH_SLOTS; i++)
	{
		edict_t *m;
		if (!qr_paths[i].ednum)
			continue;
		m = EDICT_NUM (qr_paths[i].ednum);
		if (m->free || !((int)m->v.flags & FL_MONSTER) || m->v.health <= 0)
			qr_paths[i].ednum = 0;
	}

	for (e = 1; e < sv.num_edicts; e++)
	{
		edict_t		*ent = EDICT_NUM (e);
		edict_t		*goal;
		qr_path_t	*p;
		vec3_t		org, tgt;
		float		cr, cg, cb;

		if (ent->free || !((int)ent->v.flags & FL_MONSTER) || ent->v.health <= 0)
			continue;

		org[0] = ent->v.origin[0];
		org[1] = ent->v.origin[1];
		org[2] = ent->v.origin[2] + ent->v.mins[2] + 2.f;	/* on the floor */
		/* colour by monster TYPE (shared model), not per edict, so every
		   grunt reads the same hue as every other grunt */
		QR_PathColor ((int)ent->v.modelindex, &cr, &cg, &cb);

		/* breadcrumb trail */
		p = QR_PathSlot (e);
		if (p)
		{
			int	last = (p->head - 1 + QR_PATH_CRUMBS) % QR_PATH_CRUMBS;
			int	moved = 1, n, j, first, have = 0;
			vec3_t	prev;

			if (p->count > 0)
			{
				vec3_t d;
				VectorSubtract (org, p->pts[last], d);
				moved = (VectorLength (d) > QR_PATH_MINDIST);
			}
			if (moved)
			{
				VectorCopy (org, p->pts[p->head]);
				p->head = (p->head + 1) % QR_PATH_CRUMBS;
				if (p->count < QR_PATH_CRUMBS)
					p->count++;
			}
			n = p->count;
			first = (p->head - n + QR_PATH_CRUMBS) % QR_PATH_CRUMBS;
			{
				/* marching ants: dashes crawl toward the monster's
				   current position, continuous across crumb joints */
				float	period = QR_DASH_ON + QR_DASH_OFF;
				float	phase = fmodf ((float)cl.time * QR_DASH_SPEED, period);
				float	runlen = 0.f;

				for (j = 0; j < n; j++)
				{
					int idx = (first + j) % QR_PATH_CRUMBS;
					if (have)
						QR_EmitDebugDashes (slot, prev, p->pts[idx],
								    cr * 0.55f, cg * 0.55f, cb * 0.55f, 0.7f,
								    &runlen, phase);
					VectorCopy (p->pts[idx], prev);
					have = 1;
				}
				if (have)
					QR_EmitDebugDashes (slot, prev, org,
							    cr * 0.55f, cg * 0.55f, cb * 0.55f, 0.7f,
							    &runlen, phase);
			}
		}

		/* intent line: what it is chasing, brighter and thicker */
		goal = NULL;
		if (ent->v.enemy)
		{
			edict_t *en = PROG_TO_EDICT (ent->v.enemy);
			if (!en->free)
				goal = en;
		}
		if (!goal && ent->v.goalentity)
		{
			edict_t *g = PROG_TO_EDICT (ent->v.goalentity);
			if (!g->free)
				goal = g;
		}
		if (goal)
		{
			/* the "path to me": a marching-ants trail along the FLOOR to the
			   target, not a solid bar at chest height */
			float	period = QR_DASH_ON + QR_DASH_OFF;
			float	phase = fmodf ((float)cl.time * QR_DASH_SPEED, period);
			float	runlen = 0.f;

			tgt[0] = goal->v.origin[0];
			tgt[1] = goal->v.origin[1];
			tgt[2] = goal->v.origin[2] + goal->v.mins[2] + 2.f;
			QR_EmitDebugDashes (slot, org, tgt, cr, cg, cb, 1.2f, &runlen, phase);
		}
	}
}

static void QR_EmitParticles (qr_frame_slot_t *slot)
{
	particle_t	*p;
	vec3_t		worldup = {0.f, 0.f, 1.f};
	float		s = QR_PARTICLE_SIZE;

	for (p = qr_active_particles; p; p = p->next)
	{
		unsigned int	c = d_8to24table[(int) p->color & 255];
		float		r = (c & 0xff) / 255.f;
		float		g = ((c >> 8) & 0xff) / 255.f;
		float		b = ((c >> 16) & 0xff) / 255.f;
		vec3_t		look, rt, up, c0, c1, c2, c3;
		int		k;

		VectorSubtract (r_origin, p->org, look);
		if (VectorNormalize (look) < 0.01f)
			continue;
		CrossProduct (look, worldup, rt);
		if (VectorNormalize (rt) < 0.01f)
		{
			rt[0] = 1.f; rt[1] = 0.f; rt[2] = 0.f;
		}
		CrossProduct (rt, look, up);	/* unit: rt and look are orthonormal */

		for (k = 0; k < 3; k++)
		{
			c0[k] = p->org[k] - rt[k] * s - up[k] * s;
			c1[k] = p->org[k] + rt[k] * s - up[k] * s;
			c2[k] = p->org[k] + rt[k] * s + up[k] * s;
			c3[k] = p->org[k] - rt[k] * s + up[k] * s;
		}
		QR_ParticleVert (slot, c0, r, g, b);
		QR_ParticleVert (slot, c1, r, g, b);
		QR_ParticleVert (slot, c2, r, g, b);
		QR_ParticleVert (slot, c0, r, g, b);
		QR_ParticleVert (slot, c2, r, g, b);
		QR_ParticleVert (slot, c3, r, g, b);
	}
}

/*
================
QR_ProjDebug -- where do my own projectiles actually appear? (vr_projdebug)

The lightning beam was visibly rooted in the player's chest because the
CLIENT positions it, so it could simply be moved. Projectiles are server
entities: the client draws where it is told, and vanilla spawns each
weapon's missile at its own offset from the player origin -- the rocket a
little forward and up, the grenade (going by vanilla QuakeC, which this
tree cannot read: progs.dat is compiled) at the origin itself. Which of
them actually reads wrong in a headset is a measurement, not an argument.

One line per projectile, the first frame it exists -- which is the first
frame it can be drawn, so this measures what you see rather than the
setorigin position, which is never visible. The offset from the hand is
split along the aim, where it is legitimate travel (a rocket covers ~11
units in one 90 Hz frame), and perpendicular to it, which is the part that
reads as the shot not leaving the barrel. perp is the number that matters.

Server-side, single player, and silent without a tracked hand -- there is
nothing to measure the offset against. The axe, both shotguns and the
lightning gun spawn no entity and so say nothing here, which is the
expected result and not a failure to detect them.
================
*/
#define QR_PROJ_SLOTS	48

static int	qr_proj_seen[QR_PROJ_SLOTS];	/* edict numbers already reported */
static qmodel_t	*qr_proj_worldkey;

/* One of MY missiles? Exact, not guessed: the local server is in-process, so
   v.owner settles it with no model-name or proximity heuristic. FLYMISSILE is
   rockets, nails and spikes; BOUNCE is grenades. */
static qboolean QR_MyMissile (int ednum)
{
	edict_t	*ent;
	int	mt;

	if (ednum < 1 || ednum >= sv.num_edicts)
		return false;
	ent = EDICT_NUM (ednum);
	if (ent->free)
		return false;
	if (PROG_TO_EDICT (ent->v.owner) != svs.clients[0].edict)
		return false;
	mt = (int) ent->v.movetype;
	return mt == MOVETYPE_FLYMISSILE || mt == MOVETYPE_BOUNCE;
}

static const char *QR_WeaponName (int bit)
{
	switch (bit)
	{
	case IT_AXE:			return "axe";
	case IT_SHOTGUN:		return "shotgun";
	case IT_SUPER_SHOTGUN:		return "super shotgun";
	case IT_NAILGUN:		return "nailgun";
	case IT_SUPER_NAILGUN:		return "super nailgun";
	case IT_GRENADE_LAUNCHER:	return "grenade launcher";
	case IT_ROCKET_LAUNCHER:	return "rocket launcher";
	case IT_LIGHTNING:		return "lightning gun";
	default:			return "(none)";
	}
}

static void QR_ProjDebug (void)
{
	int	e, i, slot;
	edict_t	*player;
	vec3_t	hand, fwd, right, up;

	if (!vr_projdebug.value || !sv.active)
		return;
	if (!svs.clients || !svs.clients[0].active)
		return;

	player = svs.clients[0].edict;

	/* Clear across map loads: SV_SpawnServer memsets sv and may reallocate
	   the edict array smaller, so a number held from the last map is not
	   merely stale but potentially out of bounds. */
	if (qr_proj_worldkey != cl.worldmodel)
	{
		qr_proj_worldkey = cl.worldmodel;
		memset (qr_proj_seen, 0, sizeof qr_proj_seen);
	}

	/* Release slots whose projectile is gone. Edict numbers are reused, so
	   without this the next missile to land in a retired number would be
	   taken for one already reported and silently skipped. */
	for (i = 0; i < QR_PROJ_SLOTS; i++)
	{
		edict_t *p;

		if (!qr_proj_seen[i])
			continue;
		if (!QR_MyMissile (qr_proj_seen[i]))
			qr_proj_seen[i] = 0;
	}

	if (!QR_HandOrigin (hand))
		return;

	/* cl.viewangles IS the aim since M6, so this is the ray the shot used. */
	AngleVectors (cl.viewangles, fwd, right, up);

	for (e = 1; e < sv.num_edicts; e++)
	{
		edict_t	*ent = EDICT_NUM (e);
		vec3_t	d, perp;
		float	along;

		if (!QR_MyMissile (e))
			continue;

		slot = -1;
		for (i = 0; i < QR_PROJ_SLOTS; i++)
		{
			if (qr_proj_seen[i] == e)
				break;
			if (slot < 0 && !qr_proj_seen[i])
				slot = i;
		}
		if (i < QR_PROJ_SLOTS)
			continue;		/* already reported */
		if (slot < 0)
			continue;		/* table full: a burst outran it */
		qr_proj_seen[slot] = e;

		VectorSubtract (ent->v.origin, hand, d);
		along = DotProduct (d, fwd);
		VectorMA (d, -along, fwd, perp);

		Con_Printf ("[proj] %-16s perp %5.1f along %5.1f (right %5.1f up %5.1f)\n",
			    QR_WeaponName ((int) cl.stats[STAT_ACTIVEWEAPON]),
			    VectorLength (perp), along,
			    DotProduct (d, right), DotProduct (d, up));
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
/* IT_* bit to wheel slot, or -1. Shared by the wheel and by the view
   weapon's placement lookup, so the two cannot disagree about ordering. */
static int QR_WheelSlot (uint32_t bit)
{
	int	i;

	for (i = 0; i < 8; i++)
		if (qr_wheel_bits[i] == bit)
			return i;
	return -1;
}

static const char *qr_wheel_modelnames[8] = {
	"progs/v_axe.mdl", "progs/v_shot.mdl", "progs/v_shot2.mdl",
	"progs/v_nail.mdl", "progs/v_nail2.mdl", "progs/v_rock.mdl",
	"progs/v_rock2.mdl", "progs/v_light.mdl",
};
/* Clean pickup models, preferred over the viewmodels above. Axe and single
   shotgun are start weapons with no pickup model -- their viewmodels carry no
   projectile anyway, so NULL falls straight through. */
#define QR_MENU_SPACING	6.0f	/* full-menu row pitch, Quake units */

static const char *qr_wheel_pickupnames[8] = {
	NULL, NULL, "progs/g_shot.mdl",
	"progs/g_nail.mdl", "progs/g_nail2.mdl", "progs/g_rock.mdl",
	"progs/g_rock2.mdl", "progs/g_light.mdl",
};
static const char *qr_wheel_labels[8] = {
	"AXE", "SHOTGUN", "SUPER SHOTGUN", "NAILGUN",
	"SUPER NAILGUN", "GRENADE LAUNCHER", "ROCKET LAUNCHER", "THUNDERBOLT",
};

/*
================
QR_ActiveWeaponBit -- the held weapon as an IT_ bit, which the protocol
cannot be trusted to deliver.

sv_main.c writes ent->v.weapon with MSG_WriteByte, and IT_AXE is 4096, so it
arrives as 0: cl.stats[STAT_ACTIVEWEAPON] reads zero for the entire time you
are holding the axe. Upstream only uses that stat to light a statusbar icon,
and the axe's icon is driven from cl.items instead, so the truncation never
mattered there.

It matters for anything keyed to the held weapon. Resolve it from the VIEW
MODEL actually being drawn -- which is the thing whose placement and trim we
are deciding, so it is the more direct answer anyway -- and fall back to the
stat for a weapon outside the wheel table (a mod's extra weapon).
================
*/
static uint32_t QR_ActiveWeaponBit (void)
{
	int	i;

	if (cl.viewent.model && cl.viewent.model->name[0])
		for (i = 0; i < 8; i++)
			if (!strcmp (cl.viewent.model->name, qr_wheel_modelnames[i]))
				return qr_wheel_bits[i];

	return (uint32_t) cl.stats[STAT_ACTIVEWEAPON];
}

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

/*
================
QR_EmitCenterPrint -- the engine's svc_centerprint text as a head-locked HUD
prompt (e.g. the hub warp-gate instructions). Reuses the conchars text pipeline
QR_EmitText already drives for the wheel labels; no new shader or packet field.
Placed a fixed distance ahead of the eye, facing where the head looks (body yaw
+ head yaw, level -- no pitch so it stays readable), multi-line split on '\n'.
The 90/26-unit offsets and 8-unit cell are a first pass; tune on device.
================
*/
#define QR_CP_MAXLINES	12
#define QR_CP_MAXCOL	16	/* wrap width in chars -- keeps it well off the edges */
static void QR_EmitCenterPrint (qr_frame_slot_t *slot)
{
	vec3_t	bang, bf, br, bu, base, rightv, upv;
	float	col[4] = { 1.f, 1.f, 1.f, 1.f };
	const float	cw = 5.f;
	const float	lineStep = cw * 1.4f;
	char	buf[256];
	char	lines[QR_CP_MAXLINES][64];
	int	nlines = 0, li;
	char	*src, *save;

	if (!qr_centerstring[0] || cl.time >= qr_centertime_until)
		return;
	QR_EnsureConchars ();
	if (!qr_conchars_texnum)
		return;

	/* Split on newlines, then WORD-WRAP each piece to QR_CP_MAXCOL so a long
	   message becomes a few short centred lines instead of one that spans the
	   whole headset view (the first cut was legible but far too wide/long). */
	q_strlcpy (buf, qr_centerstring, sizeof(buf));
	for (src = strtok_r (buf, "\n", &save); src && nlines < QR_CP_MAXLINES;
	     src = strtok_r (NULL, "\n", &save))
	{
		char	*word, *wsave;
		char	cur[64];
		cur[0] = '\0';
		for (word = strtok_r (src, " ", &wsave); word && nlines < QR_CP_MAXLINES;
		     word = strtok_r (NULL, " ", &wsave))
		{
			int	clen = (int) strlen (cur), wlen = (int) strlen (word);
			if (clen == 0)
				q_strlcpy (cur, word, sizeof(cur));
			else if (clen + 1 + wlen <= QR_CP_MAXCOL)
			{
				q_strlcat (cur, " ", sizeof(cur));
				q_strlcat (cur, word, sizeof(cur));
			}
			else
			{
				q_strlcpy (lines[nlines++], cur, sizeof(lines[0]));
				q_strlcpy (cur, word, sizeof(cur));
			}
		}
		if (cur[0] && nlines < QR_CP_MAXLINES)
			q_strlcpy (lines[nlines++], cur, sizeof(lines[0]));
	}
	if (nlines == 0)
		return;

	bang[0] = 0; bang[1] = qr_body_yaw + qr_head_yaw; bang[2] = 0;
	AngleVectors (bang, bf, br, bu);
	VectorMA (r_refdef.vieworg, 120.f, bf, base);	/* further = smaller in view */
	base[2] += qr_height_trim + 2.f;         /* near the sightline, not up top */
	base[2] += (nlines - 1) * 0.5f * lineStep;	/* centre the stack vertically */
	rightv[0] = br[0]; rightv[1] = br[1]; rightv[2] = br[2];
	upv[0] = 0.f; upv[1] = 0.f; upv[2] = 1.f;

	for (li = 0; li < nlines; li++)
	{
		vec3_t	org;
		VectorMA (base, -(float) li * lineStep, upv, org);
		QR_EmitText (slot, lines[li], org, rightv, upv, cw, col);
	}
}

static void QR_EmitWheel (qr_frame_slot_t *slot)
{
	static qmodel_t	*models[8];
	static int	models_isview[8];	/* slot fell back to the v_ viewmodel */
	static qmodel_t	*cachekey;
	/* full-menu gaze state, function scope so a close can reset it. The menu
	   commits on RELEASE: you hold to open, look at a weapon, let go to pick. */
	static int	menu_held = -1, menu_open_prev;
	float		frac, radius, step, theta, spin;
	vec3_t		fwdv, rightv, upv, angles, center;
	vec3_t		bfwd, bright, bup, bangles;	/* untilted placement basis */
	int		i, owned, k;

	if (qr_wheel_frac <= 0.01f || cls.signon != SIGNONS || !cl.worldmodel)
	{
		menu_open_prev = 0;
		menu_held = -1;
		return;
	}

	/* Resolve each slot's model once per worldmodel. Prefer the clean PICKUP
	   model (g_*.mdl) -- the weapon as it sits on the ground, no held nail or
	   rocket poking out -- and fall back to the first-person viewmodel
	   (v_*.mdl, always precached) when the map didn't precache the pickup. */
	if (cachekey != cl.worldmodel)
	{
		cachekey = cl.worldmodel;
		for (i = 0; i < 8; i++)
		{
			int m;
			models[i] = NULL;
			models_isview[i] = 0;
			if (qr_wheel_pickupnames[i])
				for (m = 1; m < MAX_MODELS && cl.model_precache[m]; m++)
					if (!strcmp (cl.model_precache[m]->name, qr_wheel_pickupnames[i]))
					{
						models[i] = cl.model_precache[m];
						break;
					}
			if (!models[i])
				for (m = 1; m < MAX_MODELS && cl.model_precache[m]; m++)
					if (!strcmp (cl.model_precache[m]->name, qr_wheel_modelnames[i]))
					{
						models[i] = cl.model_precache[m];
						models_isview[i] = 1;	/* viewmodel: may bake a round */
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
	   selection gesture, not a cramped finger flick. Grow the radius with the
	   owned count so 8 weapons don't overlap on a fixed ring (selection is
	   angle-based, so a wider ring doesn't change how far the wrist travels). */
	radius = (9.f + 2.1f * owned) * frac * CLAMP (0.4f, vr_wheelradius.value, 2.5f);
	spin = (float) fmod (realtime * 30.0, 360.0);

	/* Ring plane = the body basis, tilted by the vr_wheel* trims. WheelState
	   .swift applies the same three angles to its own axes when it turns a
	   pointer ray into a highlighted sector; they are a shared contract and
	   must move together or the highlight and the models disagree. */
	/* TWO bases, and keeping them apart is the point.

	   PLACEMENT (bfwd/bright): the plain body basis. Where the ring sits
	   relative to the wrist must NOT depend on the tilt trims -- they share
	   one basis and panning the wheel swings it bodily around you instead of
	   turning it on the spot, which at a large pan parks it behind your head.

	   GUIDE RING (rightv/upv): the body basis tilted by the vr_wheel* trims,
	   published in the packet and used for NOTHING else. The weapons, their
	   labels and the selection maths all stay on the untilted basis, so the
	   trims aim the drawn circle without moving anything you point at. */
	bangles[0] = 0;
	bangles[1] = qr_body_yaw;	/* body frame, not the aim: the ring hangs
					   off the wrist and must not swing with
					   the gun */
	bangles[2] = 0;
	AngleVectors (bangles, bfwd, bright, bup);

	angles[0] = vr_wheelpitch.value;
	angles[1] = qr_body_yaw + vr_wheelyaw.value;
	angles[2] = vr_wheelroll.value;
	AngleVectors (angles, fwdv, rightv, upv);
	if (vr_fullmenu.value)
	{
		/* Full menu: a fixed panel a comfortable stride ahead of the view,
		   selected by looking at a weapon (below) -- no wrist, no pointer,
		   so it works no matter where in the level you've walked. */
		VectorMA (r_refdef.vieworg, 40.f, bfwd, center);
		center[2] += qr_height_trim - 2.f;
	}
	else if (qr_wheel_has_anchor)
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
		VectorMA (r_refdef.vieworg, ax, bfwd, center);
		VectorMA (center, ay, bright, center);
		/* rise with the height-trimmed camera so the ring does not sink
		   out of view as the eye-height slider raises the viewpoint */
		center[2] += az + qr_height_trim;
	}
	else
	{
		/* no wrist (flat window): fixed offset ahead of the view */
		VectorMA (r_refdef.vieworg, 36.f, bfwd, center);
		center[2] -= 2.f;
	}

	/* User fine-placement nudge (Comfort sliders), body frame -- the same
	   axes the wrist anchor uses, applied after every placement branch so it
	   works with the wrist, the full menu and the flat window alike, and
	   independent of the gyro tilt which only aims the drawn ring. */
	VectorMA (center, vr_wheelfwd.value, bfwd, center);
	VectorMA (center, vr_wheelside.value, bright, center);
	center[2] += vr_wheelup.value;

	/* The ring FOLLOWS the player: center is rebuilt each frame from the
	   current vieworg and the body-frame anchor WheelState froze at open
	   (qr_wheel_anchor), so walking or falling off a cliff carries the ring
	   with you instead of stranding it where you opened it. It still doesn't
	   chase the live wrist -- the anchor is frozen consumer-side, and the
	   highlight comes from how far the wrist has since travelled from it. */

	step = 360.f / owned;

	/* Full menu selects by GAZE, engine-side: cast the head-forward ray
	   (body yaw + head yaw, head pitch) onto the ring plane and pick the
	   nearest slot; resting on one for a beat commits it. This has to live
	   here -- only the engine knows the eye position and the panel's world
	   pose, so the consumer's wrist-frame pointer can't do it once you move.
	   It overrides the fed highlight and drives the impulse itself. */
	if (vr_fullmenu.value)
	{
		vec3_t		gaze_ang, gf, gr, gu, toplane, hit, rel;
		int		gsel = -1;
		float		denom;

		gaze_ang[0] = qr_head_pitch;
		gaze_ang[1] = qr_body_yaw + qr_head_yaw;	/* body + head, not the aim */
		gaze_ang[2] = 0;
		AngleVectors (gaze_ang, gf, gr, gu);
		denom = DotProduct (gf, fwdv);
		if (fabsf (denom) > 0.001f)
		{
			float t;
			VectorSubtract (center, r_refdef.vieworg, toplane);
			t = DotProduct (toplane, fwdv) / denom;
			if (t > 0.f)
			{
				float hr, hu;
				VectorMA (r_refdef.vieworg, t, gf, hit);
				VectorSubtract (hit, center, rel);
				hr = DotProduct (rel, rightv);
				hu = rel[2];
				/* Vertical list: weapon k sits QR_MENU_SPACING below the
				   one above -- weapon order already puts each super under
				   its base. Gaze HEIGHT picks the row; looking off to the
				   side of the column picks nothing. */
				{
					float top = (owned - 1) * 0.5f * QR_MENU_SPACING;
					gsel = (int) floorf ((top - hu) / QR_MENU_SPACING + 0.5f);
					if (fabsf (hr) > 11.f || gsel < 0 || gsel >= owned)
						gsel = -1;
				}
			}
		}

		/* Commit on RELEASE. While the grip is held, track and show the
		   gazed row; when it lets go, fire the impulse for whatever was
		   highlighted. Freeze the highlight during the close ramp so a
		   glance away as you release can't change the pick. */
		if (qr_wheel_open)
		{
			menu_held = gsel;
			qr_wheel_highlight = gsel;
		}
		else
			qr_wheel_highlight = menu_held;

		if (menu_open_prev && !qr_wheel_open && menu_held >= 0)
		{
			int b, seen = 0;
			for (b = 0; b < 8; b++)
				if (cl.items & qr_wheel_bits[b])
				{
					if (seen == menu_held)
					{
						Cbuf_AddText (va ("impulse %d\n", b + 1));
						break;
					}
					seen++;
				}
		}
		menu_open_prev = qr_wheel_open;
	}

	/* publish the guide ring so the consumer can draw the wireframe circle
	   and highlight marker in the same plane the models sit in */
	slot->frame.wheel_center[0] = center[0];
	slot->frame.wheel_center[1] = center[1];
	slot->frame.wheel_center[2] = center[2];
	/* Full menu draws no ring (it's a list): negative radius tells the
	   consumer to skip the wireframe circle. */
	slot->frame.wheel_radius = vr_fullmenu.value ? -1.f : radius;
	/* The plane the ring is laid out in, so the guide wireframe and the
	   models cannot disagree once the vr_wheel* trims tilt it. */
	slot->frame.wheel_right[0] = rightv[0];
	slot->frame.wheel_right[1] = rightv[1];
	slot->frame.wheel_right[2] = rightv[2];
	slot->frame.wheel_up[0] = upv[0];
	slot->frame.wheel_up[1] = upv[1];
	slot->frame.wheel_up[2] = upv[2];
	slot->frame.wheel_frac = frac;
	slot->frame.wheel_count = owned;
	slot->frame.wheel_highlight = qr_wheel_highlight;
	k = 0;
	for (i = 0; i < 8; i++)
	{
		entity_t	e;
		qc_entity_t	*rec;
		uint32_t	before;
		int		highlighted;
		int		c;
		vec3_t		slotpos;	/* the ring slot the model must sit ON */

		if (!(cl.items & qr_wheel_bits[i]) || !models[i])
			continue;

		highlighted = (k == qr_wheel_highlight);
		theta = (90.f - k * step) * M_PI / 180.f;

		memset (&e, 0, sizeof(e));
		e.model = models[i];
		if (vr_fullmenu.value)
		{
			/* vertical list, weapon order (super under base) */
			float top = (owned - 1) * 0.5f * QR_MENU_SPACING;
			VectorCopy (center, slotpos);
			slotpos[2] += top - k * QR_MENU_SPACING;
		}
		else
		{
			/* Untilted basis: the slots -- and so the guns and labels on
			   them -- stay exactly where they have always been. Only the
			   guide ring drawn around them answers to the trims. */
			VectorMA (center, radius * cosf (theta), bright, slotpos);
			slotpos[2] += radius * sinf (theta);
		}
		/* Untouched by the vr_wheel* trims on purpose: those aim the GUIDE
		   RING only. The weapons and their labels keep the placement and
		   spin they always had. */
		e.angles[0] = 0;
		e.angles[1] = spin + k * 45.f;
		e.angles[2] = 0;
		e.frame = 0;
		e.skinnum = 0;
		e.scale = (unsigned char)(highlighted ? 8 : 5);	/* /16; smaller to fit the tight ring */
		e.lerpflags = LERP_RESETANIM | LERP_RESETMOVE;

		/* Sit the model's VISUAL CENTRE on the slot, not its origin. The view
		   models' origin is at a rear grip with the body offset forward, so
		   placing e.origin on the slot floated the model off its labelled
		   position. Subtract the rotated frame-0 bbox centre (same fix as the
		   hand weapon) so each model is centred on its spoke and label. */
		{
			aliashdr_t	*mh = (aliashdr_t *) Mod_Extradata (e.model);
			float		sfc = ENTSCALE_DECODE (e.scale);
			vec3_t		mc, ef, er, eu, rad;
			int		a;

			for (a = 0; a < 3; a++)
				mc[a] = 0.5f * (mh->frames[0].bboxmin.v[a] + mh->frames[0].bboxmax.v[a])
					* mh->scale[a] + mh->scale_origin[a];
			AngleVectors (e.angles, ef, er, eu);
			for (a = 0; a < 3; a++)
				e.origin[a] = slotpos[a] - sfc * (ef[a]*mc[0] - er[a]*mc[1] + eu[a]*mc[2]);

			/* Push every model OUTWARD by the same fraction of the ring
			   radius, so the guns sit clear of the spoke notch with a real
			   gap, not crowding it. A FIXED offset, not the model's own
			   extent: the models spin, so an extent-based push changed every
			   frame and flung long models (the axe's arm bbox) out at
			   scattered distances. */
			VectorSubtract (slotpos, center, rad);
			if (VectorNormalize (rad) > 0.01f)
				VectorMA (e.origin, radius * 0.58f, rad, e.origin);
		}

		before = slot->frame.num_entities;
		/* Only trim a slot that fell back to the viewmodel (clean pickup
		   models need none), and never the axe (0) or lightning (7), which
		   load no round and whose rear is real geometry. */
		qr_wheelclip_on = (models_isview[i] && i != 0 && i != 7) ? 1 : 0;
		QR_EmitAliasModel (slot, &e);
		qr_wheelclip_on = 0;
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
			vec3_t	labelorg, worldup = {0.f, 0.f, 1.f}, lrad;
			float	lcol[4];

			if (!vr_fullmenu.value)
			{
				/* Out at the GUN'S radius (pushed with it), then DROPPED
				   below the barrel. Radial-only placement put the side
				   labels right alongside the horizontal guns and they
				   collided; a vertical drop lands each name beneath its gun
				   instead. The old -4.5 offset dragged them toward centre. */
				VectorSubtract (slotpos, center, lrad);
				if (VectorNormalize (lrad) > 0.01f)
					VectorMA (slotpos, radius * 0.58f, lrad, labelorg);
				else
					VectorCopy (slotpos, labelorg);
				labelorg[2] -= radius * 0.22f;
			}
			else
			{
				/* vertical list: name just under the model */
				VectorCopy (slotpos, labelorg);
				labelorg[2] -= 4.5f;
			}
			lcol[0] = lcol[1] = lcol[2] = highlighted ? 1.f : 0.7f;
			lcol[3] = 1.f;
			{
				const char	*lbl = qr_wheel_labels[i];
				const char	*sp = strchr (lbl, ' ');
				const float	lcw = 1.6f;

				if (sp && !vr_fullmenu.value)
				{
					/* Stack a two-word name ("Super Shotgun") on two lines
					   so it doesn't run sideways into its neighbours. */
					char	w1[32], w2[32];
					vec3_t	l1, l2;
					size_t	n1 = (size_t) (sp - lbl);

					if (n1 >= sizeof(w1)) n1 = sizeof(w1) - 1;
					memcpy (w1, lbl, n1); w1[n1] = 0;
					q_strlcpy (w2, sp + 1, sizeof(w2));
					VectorCopy (labelorg, l1); l1[2] += lcw * 0.6f;
					VectorCopy (labelorg, l2); l2[2] -= lcw * 0.6f;
					QR_EmitText (slot, w1, l1, rightv, worldup, lcw, lcol);
					QR_EmitText (slot, w2, l2, rightv, worldup, lcw, lcol);
				}
				else
					QR_EmitText (slot, lbl, labelorg, rightv, worldup, lcw, lcol);
			}
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

	/* The view weapon, last, like upstream R_DrawViewModel. M6: with a live
	   hand aim (qr_aim_active) draw it AT THE HAND, oriented along the aim
	   the engine actually fired with (cl.viewangles) -- what you see is what
	   shoots, no late-latch, one frame of lag accepted. Emitted through the
	   ordinary alias path with the VIEWMODEL flag suppressed so the immersive
	   consumer draws it in the world. Without a hand it stays the body-locked
	   view model (flag and all, window-only), exactly as before. */
	if (r_drawviewmodel.value && r_drawentities.value && !chase_active.value
	    && !(cl.items & IT_INVISIBILITY) && cl.stats[STAT_HEALTH] > 0
	    && cl.viewent.model && cl.viewent.model->type == mod_alias)
	{
		if (qr_aim_active)
		{
			vec3_t	fwdv, rightv, upv, ba, handpos, cf, cr, cu;
			float	ax, ay, az, cx, cy, cz, mx, my, mz, maxdim, sf;
			float	pback, pup, pside;
			float	bmin[3], bmax[3];
			aliashdr_t *ah;
			int	k;

			/* Body frame (not the aim): the hand position in the world, the
			   same eye + (wrist - head) reconstruction the wheel uses. */
			ba[0] = 0; ba[1] = qr_body_yaw; ba[2] = 0;
			AngleVectors (ba, fwdv, rightv, upv);
			ax = qr_aim_org[0] - qr_head[0];
			ay = qr_aim_org[1] - qr_head[1];
			az = qr_aim_org[2] - qr_head[2];
			VectorMA (r_refdef.vieworg, ax, fwdv, handpos);
			VectorMA (handpos, ay, rightv, handpos);
			handpos[2] += az + qr_height_trim;

			/* Point the gun down the aim the shot used. The pitch is
			   NEGATED against the shot: QR_EntityMatrix rotates a world
			   model by Ry(-pitch), so the barrel (+X) ends up at world-z
			   sin(angles[0]) while the shot's forward is -sin(pitch) --
			   opposite. Feed -pitch and the barrel points where it fires. */
			cl.viewent.angles[0] = -cl.viewangles[0];
			cl.viewent.angles[1] = cl.viewangles[1];
			cl.viewent.angles[2] = cl.viewangles[2];

			/* Grip the gun IN the hand. View-weapon MDLs are authored offset
			   from their origin (so they sit low-right of the screen when
			   view-locked), and they extend forward (+X) from a grip near the
			   rear. Anchoring the origin at the hand floats the gun ahead of
			   it; anchoring the bbox CENTRE straddles the hand. Anchor a GRIP
			   point instead -- rear third along the barrel, laterally and
			   vertically centred -- so the grip sits at the wrist and the
			   barrel extends forward, held rather than hovering. Model maps
			   +X->forward, +Y->left, +Z->up.

			   Bounds from the IDLE frame (frame 0), NOT model->mins/maxs: the
			   latter is the union over ALL frames, and the FIRE frames model
			   the loaded round / muzzle flash sticking out past the barrel
			   (grenade +12, super-nail +15, ... verified). Sizing and the muzzle
			   off that union shrank the gun and threw the laser start out past
			   the real barrel. Frame 0 is the clean held gun. */
			ah = (aliashdr_t *) Mod_Extradata (cl.viewent.model);
			for (k = 0; k < 3; k++)
			{
				bmin[k] = ah->frames[0].bboxmin.v[k] * ah->scale[k] + ah->scale_origin[k];
				bmax[k] = ah->frames[0].bboxmax.v[k] * ah->scale[k] + ah->scale_origin[k];
			}
			/* RE-SEAT: the trim planes that hide the baked round also drive the
			   grip bounds, so trimming the rear pulls the gun back onto the hand
			   instead of the round's tail shoving the whole model forward. The
			   grip and size below use the TRIMMED body, not the full bbox. */
			{
				float wc[4];
				QR_WeaponClip (ah, wc);
				if (wc[1] >= 0.f)
				{
					float rx = wc[1] * ah->scale[0] + ah->scale_origin[0];
					if (rx > bmin[0]) bmin[0] = rx;
				}
				if (wc[0] < 255.f)
				{
					float fx = wc[0] * ah->scale[0] + ah->scale_origin[0];
					if (fx < bmax[0]) bmax[0] = fx;
				}
			}
			mx = bmax[0] - bmin[0];
			my = bmax[1] - bmin[1];
			mz = bmax[2] - bmin[2];
			maxdim = q_max (mx, q_max (my, mz));
			sf = (maxdim > QR_WEAPON_MAXLEN) ? QR_WEAPON_MAXLEN / maxdim : 1.f;
			cl.viewent.scale = (unsigned char) ENTSCALE_ENCODE (sf);

			/* Each gun's origin sits at a different point in its own model,
			   so one placement cannot fit all of them. Take the held gun's
			   own values if the UI has tuned it, and the cvars otherwise --
			   read here, at draw time, from the weapon actually being drawn.
			   The cvars alone used to carry this, rewritten on every weapon
			   switch, so the new gun wore the old gun's placement until the
			   console command landed and kept it forever if one was dropped. */
			pback = vr_weaponback.value;
			pup   = vr_weaponup.value;
			pside = vr_weaponside.value;
			{
				int	wslot = QR_WheelSlot (QR_ActiveWeaponBit ());

				if (wslot >= 0)
					QR_WeaponPlacement (wslot, &pback, &pup, &pside);
			}

			/* Grip stays GLOBAL. It is a fraction of the trimmed length, so it
			   already adapts to each model's size and re-seats when the trim
			   moves -- which is why one value fits every gun. It also slides the
			   model along the same axis as vr_weaponback, so per-weapon grip was
			   a second knob over one degree of freedom: tuning all eight left it
			   at the default on every one while back ranged over 3 to 18 units. */
			cx = bmin[0] + CLAMP (0.f, vr_weapongrip.value, 1.f) * mx;
			cy = 0.5f * (bmin[1] + bmax[1]);
			cz = 0.5f * (bmin[2] + bmax[2]);
			/* Place in the SHOT frame -- NOT AngleVectors(viewent.angles).
			   QR_EntityMatrix draws the negated-pitch model so its barrel
			   points where the shot goes, i.e. the model's drawn basis IS the
			   shot frame; AngleVectors(viewent.angles) is pitch-inverted against
			   it and only agrees at level aim, which is why the gun (and the
			   laser welded to it below) drifted apart when pitched up or down. */
			AngleVectors (cl.viewangles, cf, cr, cu);
			/* The transform scales the whole model, offset included, so scale
			   the grip offset by sf too or the shrunk gun drifts off hand.
			   Then the live nudge along the aim axes (vr_weapon{back,up,side}),
			   Quake units: back toward the player, up raise, side to the right. */
			for (k = 0; k < 3; k++)
				cl.viewent.origin[k] = handpos[k]
					- sf * (cf[k]*cx - cr[k]*cy + cu[k]*cz)
					- pback * cf[k]
					+ pup   * cu[k]
					+ pside * cr[k];

			/* Aiming laser, WELDED to the gun at the MUZZLE: it starts at the
			   model's forward-face centre (maxs[0] along the barrel, laterally
			   and vertically centred) carried through the gun's own drawn frame
			   (cf/cr/cu, the shot frame), so with the sliders at zero the beam
			   already emits from the barrel tip and rides it at every aim angle.
			   The vr_laser{forward,up,side} offsets are then just fine-tune. */
			if (vr_laser.value || vr_reticle.value)
			{
				vec3_t	lstart, langles;
				float	lx = bmax[0];   /* idle-frame muzzle, along barrel */

				for (k = 0; k < 3; k++)
					lstart[k] = cl.viewent.origin[k]
						+ sf * (cf[k]*lx - cr[k]*cy + cu[k]*cz)
						+ vr_laserforward.value * cf[k]
						+ vr_laserup.value      * cu[k]
						+ vr_laserside.value    * cr[k];
				/* DIRECTION tilted off the shot so the beam lines up with the
				   barrel (vr_laserpitch/yaw); the shot itself is unchanged. */
				langles[0] = cl.viewangles[0] + vr_laserpitch.value;
				langles[1] = cl.viewangles[1] + vr_laseryaw.value;
				langles[2] = cl.viewangles[2];
				if (vr_laser.value)
					QR_EmitLaser (slot, lstart, langles);
				/* Reticle marks where the SHOT lands (cl.viewangles, not the
				   laser's barrel-aligned tilt), from the same muzzle. */
				if (vr_reticle.value)
					QR_EmitReticle (slot, lstart, cl.viewangles);
			}

			/* Visual recoil, purely cosmetic (the shot already left with
			   cl.viewangles). The view weapon idles at frame 0 and steps
			   through its fire poses when shooting, so the ENTER of a fire
			   sequence -- idle(0) to the first nonzero pose -- is the shot:
			   arm the kick once there and let it decay across the rest of the
			   animation. Arming on every frame STEP (the old test) re-pinned
			   it to full for the whole multi-frame sequence once the real
			   animation was restored, which read as a sustained shake. It
			   decays on the sim clock, so it eases in bullet-time too. */
			{
				vec3_t	gf, gr, gu;

				if (qr_recoil_prevframe == 0 && cl.viewent.frame != 0)
					qr_recoil = 1.f;
				qr_recoil_prevframe = cl.viewent.frame;

				if (qr_recoil > 0.f)
				{
					AngleVectors (cl.viewangles, gf, gr, gu);	/* shot frame = barrel */
					VectorMA (cl.viewent.origin, -qr_recoil * 2.5f, gf,
						  cl.viewent.origin);
					cl.viewent.origin[2] += qr_recoil * 0.6f;
					cl.viewent.angles[0] += qr_recoil * 6.f;   /* muzzle rises (negated model pitch) */
					qr_recoil -= (float) host_frametime * 5.f;
					if (qr_recoil < 0.f)
						qr_recoil = 0.f;
				}
			}

			/* Real weapon animation restored: the view weapon plays its fire
			   frames (cl.viewent.frame = STAT_WEAPONFRAME, set by V_CalcRefdef).
			   It was pinned to frame 0 to hide the loaded round / muzzle flash
			   the fire frames model, but at idle STAT_WEAPONFRAME is 0 anyway,
			   so re-enabling only ADDS the firing animation -- and the synthetic
			   recoil above still complements it. Per-weapon clip trims hide any
			   baked round at the muzzle for guns that need it. */

			qr_handweapon = 1;
			QR_EmitAliasModel (slot, &cl.viewent);
			qr_handweapon = 0;
		}
		else
			QR_EmitAliasModel (slot, &cl.viewent);
	}

	QR_EmitParticles (slot);
	QR_EmitPathDebug (slot);
	QR_ProjDebug ();
	QR_EmitWheel (slot);
	QR_EmitCenterPrint (slot);
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
	slot->frame.num_particle_verts = 0;

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
	/* monotonic -- publish the live counter, never reset it to 0, or the
	   consumer would read the wrap-back as a fresh shot */
	slot->frame.weapon_fire_seq = qr_weapon_fire_seq;
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
	slot->frame.body_yaw = 0;
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

	R_AnimateLight ();	/* refresh d_lightstylevalue before the surface walk */

	/* Export third-person cameras: the exporter asks for a world position;
	   trace from the player's eye so the camera stops at walls (chase.c
	   does the same), then pull back 8 units so it never sits in one. */
	{
		int	enabled;
		vec3_t	want;
		pthread_mutex_lock (&qr_exportcam_lock);
		enabled = qr_exportcam_enabled_shared;
		VectorCopy (qr_exportcam_org_shared, want);
		pthread_mutex_unlock (&qr_exportcam_lock);
		if (enabled && cl.worldmodel)
		{
			vec3_t	eye, impact, back;
			VectorCopy (cl_entities[cl.viewentity].origin, eye);
			eye[2] += 16.f;
			TraceLine (eye, want, impact);
			if (VectorLength (impact) != 0)
			{
				VectorSubtract (eye, impact, back);
				VectorNormalize (back);
				VectorMA (impact, 8.f, back, want);
			}
			VectorCopy (want, r_refdef.vieworg);
		}
	}
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
	/* The body basis, published apart from viewangles (the aim): the
	   immersive camera and head-follow frame by this so pointing the gun
	   never steers the eye. See qc_frame_t.body_yaw. */
	slot->frame.body_yaw = qr_body_yaw;
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

		/* Turning the effect OFF is INSTANT -- no lingering melt sphere to
		   dissolve the stairs you're standing on for a couple of seconds
		   after `phase 0`. Melting IN still eases for the cinematic sweep. */
		if (target <= 0.f)
			qr_phase_value = 0.f;
		else if (qr_phase_value < target)
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
	/* NOT cl.stats[STAT_ACTIVEWEAPON] -- the protocol truncates it to a byte
	   and the axe (IT_AXE, 4096) arrives as 0. See QR_ActiveWeaponBit. */
	slot->frame.active_weapon = QR_ActiveWeaponBit ();
	slot->frame.items = cl.items;

	/* A shot fired iff the held weapon's ammo dropped while the weapon stayed
	   the same. A weapon switch also changes STAT_AMMO, so gate on the weapon
	   being unchanged; and reset across a map load so the new map's ammo does
	   not read as a shot. The axe spends no ammo, so axe swings do not kick --
	   acceptable for now. */
	{
		static qmodel_t	*fire_worldkey;
		int		ammo = cl.stats[STAT_AMMO];
		uint32_t	wpn = (uint32_t) cl.stats[STAT_ACTIVEWEAPON];

		if (fire_worldkey != cl.worldmodel)
		{
			fire_worldkey = cl.worldmodel;
			qr_last_ammo = -1;
		}
		if (qr_last_ammo >= 0 && wpn == qr_last_weapon && ammo < qr_last_ammo)
			qr_weapon_fire_seq++;
		qr_last_ammo = ammo;
		qr_last_weapon = wpn;
	}
	slot->frame.weapon_fire_seq = qr_weapon_fire_seq;

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
	slot->frame.demo_playing = cls.demoplayback ? 1 : 0;
	/* The export HUD draws conchars text render-side; make sure the atlas
	   is up as soon as there is a world, not only once the wheel first
	   emits a label (a demo export never opens the wheel). */
	if (cl.worldmodel)
		QR_EnsureConchars ();
	if (cl.worldmodel && cl.viewentity > 0 && cl.viewentity < cl.num_entities)
	{
		entity_t *pl = &cl_entities[cl.viewentity];
		VectorCopy (pl->origin, slot->frame.player_org);
		VectorCopy (pl->angles, slot->frame.player_angles);
	}
	else
	{
		memset (slot->frame.player_org, 0, sizeof slot->frame.player_org);
		memset (slot->frame.player_angles, 0, sizeof slot->frame.player_angles);
	}
	for (i = 0; i < 16; i++)
		slot->frame.stats[i] = cl.stats[i];
	slot->frame.indices = slot->indices;
	slot->frame.batches = slot->batches;
	slot->frame.entities = slot->entities;
	slot->frame.text_verts = slot->text_verts;
	slot->frame.conchars_texnum = qr_conchars_texnum;
	slot->frame.particle_verts = slot->particle_verts;

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
	slot->frame.frame_seq = slot->seq;
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
