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
	QC_ENTFLAG_VIEWMODEL = 1 << 0,

	/* Dissolves with the world in the phase effect. Set on brush entities
	   whose submodel belongs to a func_door_secret: a secret door that
	   hangs in the air after the wall around it melts is a spoiler, so
	   secrets go out with the architecture they hide in. */
	QC_ENTFLAG_PHASED = 1 << 1
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
	/* Vertex forward-clip in MODEL BYTE space, for the hand weapon: any vertex
	   with byte-x > clip[0] is collapsed to (clip[0], clip[1], clip[2]) in the
	   shader, retracting the loaded round / nail the view models bake into
	   their geometry. clip[0] >= 255 disables it (every other entity). */
	float		clip[4];
	/* Debug: dbg[0] > 0.5 draws this entity solid green (vr_weapontint on the
	   hand weapon) to identify it on screen. 0 for everything else. */
	float		dbg[4];
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
	   is derived from the same basis.

	   M6 aim/body split: viewangles is now the AIM (the hand/controller ray,
	   what cl.viewangles became so shots leave the server going where you
	   point) and stays the mono/window camera and the fired-shot direction.
	   The immersive camera and room-scale head-follow must NOT track the aim
	   -- looking or pointing may never steer the eye -- so they read body_yaw
	   below instead. The two are equal only when no hand aims (body-anchored
	   fallback). Keep them named apart so the distinction can't be misread. */
	float		vieworg[3];	/* view origin; also the sky projection origin */
	float		viewangles[3];	/* AIM: pitch, yaw, roll -- Quake order, degrees */
	float		body_yaw;	/* BODY basis yaw (deg): the immersive camera and
					   head-follow frame. Movement is the body basis
					   too, applied server-side; the aim (viewangles)
					   is pre-compensated in IN_Move so the stick still
					   walks along the body, not the hand. */
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
	float		phase_color[3];	/* ember rim, linear rgb (may exceed 1
					   for glow); the `phase_color` cvar */

	/* Room-scale head follow. The engine walks the player box after the
	   offset fed through QC_InputSetHeadOffset (traced, so walls refuse
	   it) and reports here how much of that offset vieworg has already
	   absorbed, world-frame XY Quake units. The immersive consumer
	   anchors its camera at vieworg minus this, so absorption never
	   moves the rendered eye; the un-absorbed remainder is the lean,
	   clamped to lean_limit so a head cannot pass through the wall that
	   refused the box. recenter_count bumps when `vr_recenter` runs: the
	   consumer re-zeroes its pose correction against the current head
	   pose and echoes the count back through QC_InputSetHeadOffset. */
	float		head_absorbed[2];
	float		lean_limit;	/* vr_lean_limit, Quake units */
	uint32_t	recenter_count;

	/* Weapon-wheel guide, drawn by the consumer as a wireframe ring in
	   world space so the radial layout is legible: wheel_center is the
	   ring centre (Quake units, the off-hand wrist), wheel_radius its
	   radius, wheel_frac the eased open amount (0 = draw nothing),
	   wheel_count the number of owned slots, wheel_highlight the selected
	   slot (-1 none). The ring plane is spanned by body-right and world
	   up, matching where QR_EmitWheel places the models. */
	float		wheel_center[3];
	float		wheel_radius;
	/* The ring plane's axes (unit, world frame). The body basis tilted by
	   vr_wheelpitch/yaw/roll; the consumer draws the guide circle in this
	   plane rather than re-deriving it from body_yaw, which would ignore
	   the tilt. */
	float		wheel_right[3];
	float		wheel_up[3];
	float		wheel_frac;
	int32_t		wheel_count;
	int32_t		wheel_highlight;

	/* Comfort vignette, eased 0..1 on the engine clock: vr_vignette
	   strength while ARTIFICIAL locomotion exceeds vr_vignette_threshold,
	   zero at rest. Physical (room-scale) walking never trips it -- real
	   motion needs no comfort aid. The consumer draws a periphery fade at
	   this strength; 0 draws nothing. */
	float		vignette;

	/* Output channel for controller haptics and (when visionOS exposes
	   them) adaptive triggers. damage_flash is the engine's damage cshift
	   percent, rising on hits and decaying through V_UpdateBlend -- the
	   consumer pulses haptics on rises. active_weapon is the IT_* bit of
	   the held weapon (cl.stats[STAT_ACTIVEWEAPON]) for per-weapon trigger
	   feel. */
	float		damage_flash;
	uint32_t	active_weapon;
	uint32_t	items;		/* cl.items: owned-weapon IT_* bits,
					   the wheel's source of truth for
					   what may be offered */
	/* Monotonic counter the engine bumps each time the held weapon ACTUALLY
	   fires (ammo spent, weapon unchanged), so the consumer pulses the fire
	   haptic on the real shot cadence -- respecting a weapon's refire delay
	   -- instead of on every trigger pull, which buzzed through the cooldown.
	   Consumer fires a kick whenever this increases. */
	uint32_t	weapon_fire_seq;

	/* Export support. frame_seq is the bridge's publish counter (+1 per
	   packet) so a lock-stepped consumer can assert it got exactly one new
	   packet per engine step. demo_playing mirrors cls.demoplayback so the
	   consumer learns when a played-back demo has ended. */
	uint32_t	frame_seq;
	uint32_t	demo_playing;
	/* The player entity (cl_entities[cl.viewentity]) and the status-bar
	   stats (cl.stats[0..15]: health, frags, weapon, ammo, armor, ...,
	   shells, nails, rockets, cells, active weapon, total secrets, total
	   monsters, secrets, monsters) for third-person export cameras and the
	   export HUD. player_org is the entity origin, not the eye. */
	float		player_org[3];
	float		player_angles[3];
	int32_t		stats[16];

	uint32_t	num_indices;
	const uint32_t	*indices;	/* into the geometry vertex array */
	uint32_t	num_batches;
	const qc_draw_batch_t *batches;
	uint32_t	num_entities;
	const qc_entity_t *entities;

	/* 2D text as billboarded glyph quads from the conchars atlas. All text
	   this frame -- weapon-wheel labels, HUD, the item selector -- shares
	   one atlas and one flat vertex run, drawn in a single overlay pass.
	   Nine floats per vertex: xyz position (Quake units), uv into the
	   atlas, rgba premultiply-ready colour; six vertices per glyph quad.
	   conchars_texnum is the atlas handle (0 until it uploads). */
	uint32_t	conchars_texnum;
	uint32_t	num_text_verts;
	const float	*text_verts;

	/* Particles as billboarded colour quads (explosions, gunshots, rocket
	   trails). Seven floats per vertex: xyz position (Quake units) and rgba,
	   six vertices per quad -- the same layout the wheel-guide pipeline
	   draws, so no new shader. Depth-tested against the world, no write. */
	uint32_t	num_particle_verts;
	const float	*particle_verts;
} qc_frame_t;

/* Latest published frame, or NULL only if nothing has been published yet
   (or the engine retired everything at teardown). Release parks the packet
   back in the ready state rather than freeing it, so a consumer ticking
   faster than the engine re-acquires the same packet and re-renders it --
   never present an empty frame just because Acquire lagged a publish. The
   slot stays locked against engine reuse from Acquire to Release. */
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

/* ========================================================================
 * Input -- any-thread producers, drained on the engine thread.
 *
 * GameController handlers fire on their own queue and the compositor's
 * render thread owns the head pose; neither may touch engine state. Both
 * cross into the engine the same way the drawable size does: a lock-guarded
 * latest-state snapshot the engine thread reads inside IN_Commands/IN_Move.
 * ===================================================================== */

enum {
	QC_PAD_A		= 1 << 0,
	QC_PAD_B		= 1 << 1,
	QC_PAD_X		= 1 << 2,
	QC_PAD_Y		= 1 << 3,
	QC_PAD_LSHOULDER	= 1 << 4,
	QC_PAD_RSHOULDER	= 1 << 5,
	QC_PAD_MENU		= 1 << 6,
	QC_PAD_OPTIONS		= 1 << 7,
	QC_PAD_LTHUMB		= 1 << 8,
	QC_PAD_RTHUMB		= 1 << 9
};

typedef struct qc_gamepad_state_s {
	float		lx, ly;		/* left stick, -1..1, +y forward */
	float		rx, ry;		/* right stick, -1..1, +y up */
	float		lt, rt;		/* triggers, 0..1 */
	uint32_t	buttons;	/* QC_PAD_* bits */
	uint32_t	connected;	/* 0 = no controller attached */
} qc_gamepad_state_t;

/* Latest whole-pad snapshot; the engine diffs consecutive snapshots for
   button edges. Callable from any thread. */
void QC_InputSetGamepad (const qc_gamepad_state_t *state);

/* Weapon-wheel state, fed by whichever input source owns the gesture
   (palm-up hands, a held Sense face button, the +wheel console command
   engine-side). While open the engine ramps host_timescale down toward
   wheel_timescale -- simulation time slows, the tick and packet rate do
   not -- blocks locomotion and fire, and emits the owned view-weapon
   models as a ring of alias entities anchored at `anchor` (body frame,
   Quake units: fwd/right/up from the eye). has_anchor 0 means no wrist to
   anchor to (flat window): the ring sits at a fixed offset ahead of the
   view. highlight is the index into the OWNED-weapon ring (impulse
   order), -1 for none; committing the selection is the caller's job via
   QC_ExecuteCommand("impulse N"). Callable from any thread. */
void QC_InputSetWheel (int open, int has_anchor,
		       float fwd, float right, float up, int highlight);

/* Slow-motion TOGGLE from a controller button (L3), independent of the
   weapon wheel. Pass the raw button state; the engine flips bullet-time on
   the rising edge. host_timescale takes the DEEPER of this and the wheel's
   slowdown, so opening the wheel during a slow-mo hold never speeds up.
   Callable from any thread. */
void QC_InputSetSlowmo (int pressed);

/* The head's yaw relative to the body, degrees, Quake sense (CCW/left
   positive), fed by the render thread from the same pose it draws with.
   Look-relative locomotion (vr_moverelative) rotates the movement stick by
   this so "forward" tracks where the head looks; body-relative locomotion
   ignores it. Callable from any thread. */
/* Freeze/unfreeze the simulation (sv.paused). An explicit SET rather than
   Quake's "pause" toggle, so the caller's intent cannot be inverted by anything
   else. Applied on the engine thread; single-player only. The render thread and
   head tracking keep running, so a paused world is still look-around-able.
   Callable from any thread. */
void QC_SetPaused (int paused);

void QC_InputSetHeadYaw (float yaw_deg);

/* The head's pitch, degrees, Quake sense (positive looks DOWN), fed by the
   render thread from the pose it draws with. With vr_headaim on (default) the
   shot pitches to where you look -- head aim replaces the old right-stick
   pitch, which had no head coupling and drifted. Feed 0 when head tracking
   stops so a later flat-window session starts level. Callable from any
   thread. */
void QC_InputSetHeadPitch (float pitch_deg);

/* The dominant hand's aim, M6. `valid` 0 releases it and the shot falls back
   to the body-anchored aim (vr_handaim 0, or no hand this frame). The
   direction is the aim ray RELATIVE to the recenter-neutral (room forward),
   Quake degrees: yaw CCW/left-positive, pitch positive-down. The engine adds
   the body yaw, so snap turns rotate the aim with the body. org_* is the
   hand's position in the BODY frame (fwd/right/up from the recenter origin,
   Quake units) -- the same convention as the wheel anchor -- where the
   view-weapon entity is drawn. The engine writes cl.viewangles from this, so
   the server fires along the ray with no engine surgery. Callable from any
   thread. */
void QC_InputSetAim (int valid, float org_fwd, float org_right, float org_up,
		     float yaw_deg, float pitch_deg);

/* Point-and-blink teleport. The OFF hand aims a destination in the same
   body-frame ray form as the aim above (org = fwd/right/up offset from the
   recenter origin, yaw/pitch room-relative). `active` while the gesture is
   held (drives the on-floor landing marker); `commit` once on release to
   jump the player there. Any-thread. */
void QC_InputSetTeleport (int active, int commit, float org_fwd, float org_right,
			  float org_up, float yaw_deg, float pitch_deg);

/* Per-weapon gun placement, one entry per weapon slot in wheel order:
   axe, shotgun, super shotgun, nailgun, super nailgun, grenade launcher,
   rocket launcher, lightning gun. Quake units, in the gun's own drawn frame:
   `back` toward the player along the barrel, `up` raises, `side` moves right.

   NOT grip. Grip is the 0..1 point along the trimmed barrel that sits in the
   hand, and it moves the gun along the SAME axis as `back` -- two knobs over
   one degree of freedom. Tuning all eight weapons left grip at its default on
   every one of them while `back` ranged over 3 to 18 units, so grip is now a
   single global (vr_weapongrip) rather than per-weapon.

   `custom` == 0 means that weapon was never tuned, and the renderer falls
   back to the vr_weapon{back,up,side} cvars -- which remain the global
   setting and the console's way in.

   PULLED, not pushed: the renderer reads the entry for whichever gun it is
   drawing, every frame. Placement used to be four global cvars rewritten on
   each weapon switch, which meant the new gun wore the old gun's placement
   until the console command landed a few frames later, and meant a command
   dropped before the engine was running left that weapon permanently wrong.
   Handing over the whole table removes both: there is no switch event to
   miss and nothing to go stale.

   Callable from any thread. */
typedef struct {
	float	back, up, side;
	int	custom;			/* 0 = never tuned, use the cvars */
} qc_weapon_placement_t;

#define QC_WEAPON_SLOTS	8

void QC_SetWeaponPlacement (const qc_weapon_placement_t *slots);

/* The eye-height trim (vr comfort slider) in QUAKE UNITS, fed by the render
   thread which applies the same trim to the camera. Head/wrist-locked
   overlays -- the weapon wheel -- add it so they rise with the raised
   camera instead of sinking out of view. Callable from any thread. */
void QC_InputSetHeightTrim (float units);

/* The head's offset from the tracking origin in BODY frame, Quake units
   (+fwd along body forward, +right along body right, +up), sampled by the
   render thread from the same late-latched pose it draws with. The engine
   walks the player box after this offset (traced, so walls refuse it) and
   publishes what it absorbed in qc_frame_t.head_absorbed. `recenter_ack`
   echoes the packet's recenter_count the pose was corrected against; the
   engine ignores stale feeds while a recenter is in flight. Callable from
   any thread. */
void QC_InputSetHeadOffset (float fwd, float right, float up,
			    uint32_t recenter_ack);

/*
 * ---------------------------------------------------------------------------
 * Admin panel (produced by Sources/QuakeCore/platform/admin_avp.c).
 *
 * A latest-state snapshot of the server's monster roster for the window's
 * Admin tab, refreshed on the engine thread a few times a second and copied
 * out under a lock -- the consumer-side mirror of the QC_Input* producers.
 * The commands the tab issues in return (`sv_killai`, `ai_target`) go through
 * QC_ExecuteCommand like everything else; this is read-only.
 * ---------------------------------------------------------------------------
 */

#define QC_ADMIN_MAX_MONSTERS	128
#define QC_ADMIN_CLASSNAME_LEN	24

typedef struct {
	int32_t		edict;		/* server edict number; the ai_target handle */
	int32_t		enemy;		/* edict it is hunting, 0 = none; compare
					   against player_edict to say "you" */
	float		health;
	float		distance;	/* to the player, Quake units */
	char		classname[QC_ADMIN_CLASSNAME_LEN];	/* "monster_army" */
} qc_monster_t;

typedef struct {
	int32_t		active;		/* a level is loaded (sv.active) */
	int32_t		killai;		/* sv_killai as the engine sees it */
	int32_t		player_edict;
	int32_t		count;		/* live monsters, capped at the array */
	qc_monster_t	monsters[QC_ADMIN_MAX_MONSTERS];
} qc_admin_state_t;

/* Copy the latest roster snapshot. Callable from any thread. */
void QC_AdminCopyState (qc_admin_state_t *out);
/* Export only. During demo playback IN_Move still runs and re-derives the
   body yaw from the demo's viewangles (the aim), so the hand weapon would be
   placed from the wrong body frame. With `override` set, the engine pins
   qr_body_yaw to yaw_deg every IN_Move; pass 0 to release. Callable from
   any thread. */
void QC_ExportSetBodyYaw (int override, float yaw_deg);

/* Export only: park the engine's view origin (the PVS/culling viewpoint)
   at a world position for third-person cameras. The bridge traces from the
   player to it so it stops at walls, then publishes the resulting position
   as the packet's vieworg. `enabled` 0 releases it. Callable from any
   thread. */
void QC_ExportSetViewOrigin (int enabled, float x, float y, float z);

/*
 * ---------------------------------------------------------------------------
 * Audio sink (implemented in Swift, App/Sources/AudioSink.swift).
 *
 * Quake's mixer is unchanged and still owns the ring; this is only the device
 * that plays it, the mirror of the QC_Input* producers. snd_avp.c calls these
 * from the engine thread; the audio render thread touches nothing but the ring
 * and the cursor.
 * ---------------------------------------------------------------------------
 */

/* Allocate the ring and start the device. Returns 1 on success and fills
   *buffer / *mono_samples; 0 means no audio, and S_Init disables sound
   cleanly. mono_samples is a POWER OF TWO -- snd_mix.c masks with it. */
int  QC_AudioOpen (int speed, int channels, int bits,
		   unsigned char **buffer, int *mono_samples);

/* Play cursor in mono samples. Drives how far ahead snd_mix paints. */
int  QC_AudioSamplePos (void);

/* Stop the device and release the ring. Stops the node before freeing. */
void QC_AudioClose (void);

/* Pause/resume the device without releasing the ring (SNDDMA_BlockSound). */
void QC_AudioSetRunning (int running);

#ifdef __cplusplus
}
#endif

#endif /* QUAKECORE_H */
