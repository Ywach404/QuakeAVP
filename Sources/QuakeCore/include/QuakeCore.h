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

/*
 * Alias mesh uploads. Static per-model geometry built once at model load
 * (the GL_MakeAliasModelDisplayLists port) and handed over exactly like
 * texture pixels: the engine queues a private copy, the consumer acquires,
 * builds GPU buffers, releases. Per-frame packets then reference meshes by
 * handle — static mesh data never travels in the packet.
 *
 * Vertex layout matches upstream's meshxyz_t: positions are the MDL's raw
 * byte coordinates (the entity transform bakes scale/scale_origin), normals
 * are signed bytes in [-127, 127]. All poses are concatenated; texcoords
 * are shared across poses; indices are one triangle list.
 */
typedef struct qc_mesh_vertex_s {
	uint8_t		xyz[4];		/* w = 1, for 4-byte compression */
	int8_t		normal[4];	/* [-127..127]; w unused */
} qc_mesh_vertex_t;

typedef struct qc_mesh_upload_s {
	uint32_t	meshnum;	/* engine-side handle, never 0 */
	uint32_t	numposes;
	uint32_t	numverts;	/* vertices per pose */
	uint32_t	numindexes;
	const qc_mesh_vertex_t	*vertices;	/* numposes * numverts */
	const float		*st;		/* numverts * 2 */
	const uint16_t		*indexes;	/* numindexes */
} qc_mesh_upload_t;

int  QC_RendererAcquireMeshUploads (const qc_mesh_upload_t **out);
void QC_RendererReleaseMeshUploads (void);
int  QC_RendererAcquireMeshFrees (const uint32_t **out);
void QC_RendererReleaseMeshFrees (void);

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

/* Batch kinds select the consumer's pipeline. Batches arrive in upstream's
   draw order: sky (depth-writing, like Sky_DrawSky), opaque world, opaque
   entities, liquids, then translucent entities. */
enum {
	QC_BATCH_WORLD  = 0,	/* diffuse * lightmap */
	QC_BATCH_SKY    = 1,	/* scrolling cloud layers or skybox, projected
				   from vieworg; per-frame sky texnums below */
	QC_BATCH_LIQUID = 2,	/* unlit, UV-warped, alpha-blended */
	QC_BATCH_ALIAS  = 3	/* lerped alias mesh; geometry comes from the
				   entity's mesh handle, not the frame indices */
};

/* Batches that belong to an entity index into the frame's entity array;
   world batches use the sentinel and draw with the identity transform. */
#define QC_ENTITY_NONE	0xffffffffu

enum {
	/* The view weapon. View-locked, which is wrong in VR; the consumer
	   decides (window draws it depth-squished like upstream's
	   glDepthRange(0, 0.3), immersive skips it).
	   TODO(M4): decouple the weapon from the view instead. */
	QC_ENTFLAG_VIEWMODEL = 1 << 0
};

/*
 * Per-entity state, published once per frame in a side array so world
 * batches don't carry a transform each. Alias lighting follows upstream
 * R_SetupAliasLighting: light is lightcolor/200 with overbright-model
 * doubling pre-baked, shadevector the quantized yaw light direction the
 * shade-dot formula needs. Dynamic lights and lightstyle animation are
 * still stubbed, so both feed defaults and results differ from upstream
 * until those land.
 */
typedef struct qc_entity_s {
	float		transform[16];	/* column-major model->world, Quake units;
					   bakes origin/angles/scale and, for alias
					   models, scale_origin/scale */
	float		light[3];	/* alias vertex light color */
	float		shadevector[3];
	float		alpha;		/* ENTALPHA_DECODE'd */
	float		blend;		/* pose lerp factor, 0 = pose1 */
	uint32_t	meshnum;	/* alias mesh handle; 0 for brush entities */
	uint32_t	pose1, pose2;
	uint32_t	flags;		/* QC_ENTFLAG_* */
} qc_entity_t;

/* One draw batch: a run of triangle-list indices sharing textures. */
typedef struct qc_draw_batch_s {
	uint32_t	kind;		/* QC_BATCH_* */
	uint32_t	texnum;		/* diffuse texture handle (alias: skin) */
	uint32_t	lightmap;	/* lightmap texture handle, 0 = fullbright
					   (alias: fullbright mask, 0 = none) */
	uint32_t	first_index;
	uint32_t	index_count;	/* alias: index count within the mesh */
	uint32_t	entity;		/* index into entities, QC_ENTITY_NONE = world */
	float		alpha;		/* liquid: water/lava/slime/tele alpha;
					   sky: r_skyalpha; entity kinds: entity
					   alpha; world: 1 */
} qc_draw_batch_t;

/* There is no packet version field: both halves of this contract compile in
   the same build, so the structs *are* the protocol. */
typedef struct qc_frame_s {
	uint32_t	generation;	/* must match AcquireGeometry's result */
	float		viewproj[16];	/* column-major, Metal depth range */
	float		clear_color[4];	/* gl_clear / r_clearcolor; advisory:
					   the flat window honours it, the mixed-
					   immersion layer clears transparent so
					   passthrough shows wherever nothing is
					   drawn */
	float		time;		/* cl.time; drives warp + sky scroll.
					   Engine-thread clock -- the consumer
					   must not substitute its own. */

	/* The player's world->view basis, in Quake units/degrees. The immersive
	   consumer composes per-eye matrices from this *after* sampling the head
	   pose (late latch); building them engine-side would cost a frame of
	   head-tracking latency. viewproj above stays the mono/window path and
	   is derived from the same basis. */
	float		vieworg[3];	/* view origin; also the sky projection origin */
	float		viewangles[3];	/* pitch, yaw, roll -- Quake order, degrees */
	float		world_scale;	/* metres per Quake unit (vr_worldscale, clamped) */
	uint32_t	sky_solid_texnum;   /* classic sky back layer, 0 = none */
	uint32_t	sky_alpha_texnum;   /* classic sky cloud layer, 0 = none */
	uint32_t	skybox_texnums[6];  /* indexed by sky axis (upstream
					       skytexorder already applied);
					       [0] == 0 = no skybox */
	/* The phase effect: the world dissolves outward from the viewer's
	   head, revealing passthrough, while entities and liquids stay. The
	   ownership is split deliberately: the ENGINE owns the scalar -- it
	   has the clock and the cvars (`phase`, `phase_time`), eases toward
	   the target, and scales by the world's bounding diagonal -- and the
	   RENDERER supplies the sphere's origin from the same late-latched
	   head pose it builds the view matrices from, so the dissolve tracks
	   the head with no added latency. */
	float		phase;		/* eased 0..1; sky fades by 1 - phase */
	float		phase_radius;	/* dissolve sphere radius, Quake units */

	uint32_t	num_indices;
	const uint32_t	*indices;	/* into the geometry vertex array */
	uint32_t	num_batches;
	const qc_draw_batch_t *batches;
	uint32_t	num_entities;
	const qc_entity_t *entities;
} qc_frame_t;

/* Latest published frame, or NULL if none is newer than the last acquire.
   The slot stays locked against reuse until Release. */
const qc_frame_t *QC_RendererAcquireFrame (void);
void QC_RendererReleaseFrame (void);

/* Report the drawable size in pixels. Callable from any thread; the engine
   picks it up at the next frame and recalculates the refdef. */
void QC_RendererSetDrawableSize (int width, int height);

/* Report the field of view the consumer actually renders, in degrees --
   for the immersive path this is the merged binocular frustum of both eyes.
   The engine widens its culling frustum to cover it (plus a margin for one
   frame of head rotation) while the packet's mono viewproj keeps the refdef
   fov. Pass (0, 0) to clear the override when leaving immersive rendering.
   Callable from any thread. */
void QC_RendererSetCullingFov (float fovx_deg, float fovy_deg);

#ifdef __cplusplus
}
#endif

#endif /* QUAKECORE_H */
