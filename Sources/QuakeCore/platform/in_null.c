/*
 * in_null.c -- GameController input, replacing in_sdl.c.
 *
 * The Swift layer pushes whole-pad snapshots through QC_InputSetGamepad from
 * GameController's handler queue, and the immersive render thread pushes the
 * head's body-frame offset through QC_InputSetHeadOffset; both are any-thread
 * lock-guarded latest-state handoffs, mirroring QC_RendererSetDrawableSize.
 * Everything engine-facing -- Key_Event, cl.viewangles, usercmd_t, the player
 * edict -- happens on the engine thread inside IN_Commands / IN_Move.
 *
 * Buttons become Key_Event presses of the SDL2 controller keycodes upstream
 * already names (K_ABUTTON...), with gameplay defaults bound at IN_Init
 * before quake.rc executes, so config.cfg/autoexec.cfg can rebind them.
 *
 * The engine-facing contract is upstream in_sdl.c's: push key events, fill
 * usercmd_t in IN_Move. The locomotion model is QuakeQuest's conclusions,
 * hand tracking (M5) pending: movement and aim follow BODY yaw, never the
 * head -- the render thread composes head pose on top of the body basis, so
 * looking around neither steers nor drags the weapon.
 */

#include "quakedef.h"
#include "QuakeCore.h"
#include "admin_avp.h"

#include <pthread.h>

/* defined in cl_main.c; upstream externs them file-locally in cl_input.c */
extern cvar_t cl_maxpitch, cl_minpitch;
/* defined in host.c; no header declares it */
extern cvar_t host_timescale;

/* ========================================================================
 * any-thread producers
 * ===================================================================== */

static pthread_mutex_t		qc_input_lock = PTHREAD_MUTEX_INITIALIZER;
static qc_gamepad_state_t	qc_pad_shared;
static float			qc_head_shared[3];	/* fwd, right, up */
/* Per-weapon gun placement. Written by the UI from any thread, read on the
   engine thread by QR_WeaponPlacement while the renderer builds the frame --
   so a weapon switch needs no console round trip and cannot be left stale by
   a dropped command. See QC_SetWeaponPlacement in QuakeCore.h. */
static pthread_mutex_t		qc_place_lock = PTHREAD_MUTEX_INITIALIZER;
static qc_weapon_placement_t	qc_place_shared[QC_WEAPON_SLOTS];
static uint32_t			qc_head_ack;		/* recenter echo */
static int			qc_wheel_open_shared;
static int			qc_wheel_anchor_shared;
static float			qc_wheel_pos_shared[3];
static int			qc_wheel_highlight_shared;
static float			qc_head_yaw_shared;
static float			qc_head_pitch_shared;
static int			qc_paused_shared;	/* console pause request */
static int			qc_slowmo_shared;	/* raw L3 button */
static int			qc_turnlock_shared;	/* hands: pause turning while console open */
static float			qc_height_trim_shared;
static int			qc_aim_valid_shared;	/* dominant-hand aim live? */
static float			qc_aim_org_shared[3];	/* body frame fwd,right,up */
static float			qc_aim_yaw_shared;	/* room-relative, Quake deg */
static float			qc_aim_pitch_shared;
/* Teleport: the OFF hand arms a destination (same body-frame ray form as the
   aim). `commit` is latched here and drained engine-side so a release edge
   between ticks is never lost. */
static int			qc_tp_active_shared;	/* off-hand aiming a teleport */
static int			qc_tp_commit_shared;	/* release -> do the jump */
static float			qc_tp_org_shared[3];	/* body frame fwd,right,up */
static float			qc_tp_yaw_shared;	/* room-relative, Quake deg */
static float			qc_tp_pitch_shared;

void QC_InputSetGamepad (const qc_gamepad_state_t *state)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_pad_shared = *state;
	pthread_mutex_unlock (&qc_input_lock);
}

static int			qc_bodyyaw_override_shared;
static float			qc_bodyyaw_shared;
static int			qr_bodyyaw_override;	/* engine-thread mirrors */
static float			qr_bodyyaw_pinned;

void QC_ExportSetBodyYaw (int override, float yaw_deg)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_bodyyaw_override_shared = override;
	qc_bodyyaw_shared = yaw_deg;
	pthread_mutex_unlock (&qc_input_lock);
}

void QC_InputSetHeadOffset (float fwd, float right, float up,
			    uint32_t recenter_ack)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_head_shared[0] = fwd;
	qc_head_shared[1] = right;
	qc_head_shared[2] = up;
	qc_head_ack = recenter_ack;
	pthread_mutex_unlock (&qc_input_lock);
}

/* Freeze/unfreeze the simulation. An explicit SET, not Quake's "pause" toggle,
   so the caller's intent survives anything else touching it. Applied on the
   engine thread by IN_ApplyPause. Callable from any thread. */
void QC_SetPaused (int paused)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_paused_shared = paused ? 1 : 0;
	pthread_mutex_unlock (&qc_input_lock);
}

void QC_InputSetHeadYaw (float yaw_deg)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_head_yaw_shared = yaw_deg;
	pthread_mutex_unlock (&qc_input_lock);
}

void QC_InputSetHeadPitch (float pitch_deg)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_head_pitch_shared = pitch_deg;
	pthread_mutex_unlock (&qc_input_lock);
}

void QC_InputSetSlowmo (int pressed)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_slowmo_shared = pressed ? 1 : 0;
	pthread_mutex_unlock (&qc_input_lock);
}

/* Hands-mode turn pause: Swift sets this while the console window is open (and
   the comfort opt-out is off) so reaching for a parked console doesn't turn
   the body -- via the aim-hand drifting to a side, which is the ENGINE-side
   edge turn, not anything the Swift slice can cancel. Gates every turn path in
   IN_Move at once. */
void QC_InputSetTurnLock (int locked)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_turnlock_shared = locked ? 1 : 0;
	pthread_mutex_unlock (&qc_input_lock);
}

void QC_SetWeaponPlacement (const qc_weapon_placement_t *slots)
{
	if (!slots)
		return;
	pthread_mutex_lock (&qc_place_lock);
	memcpy (qc_place_shared, slots, sizeof qc_place_shared);
	pthread_mutex_unlock (&qc_place_lock);
}

/*
================
QR_WeaponPlacement -- the held gun's own placement, or 0 if it has none.

Engine thread, called while the renderer places the view weapon. Returns 0
for a weapon the UI never tuned, and the caller uses the vr_weapon* cvars --
still the global setting, and still what the console sets.
================
*/
int QR_WeaponPlacement (int slot, float *back, float *up, float *side)
{
	qc_weapon_placement_t	p;

	if (slot < 0 || slot >= QC_WEAPON_SLOTS)
		return 0;

	pthread_mutex_lock (&qc_place_lock);
	p = qc_place_shared[slot];
	pthread_mutex_unlock (&qc_place_lock);

	if (!p.custom)
		return 0;

	*back = p.back;
	*up   = p.up;
	*side = p.side;
	return 1;
}

void QC_InputSetHeightTrim (float units)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_height_trim_shared = units;
	pthread_mutex_unlock (&qc_input_lock);
}

void QC_InputSetAim (int valid, float org_fwd, float org_right, float org_up,
		     float yaw_deg, float pitch_deg)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_aim_valid_shared = valid ? 1 : 0;
	qc_aim_org_shared[0] = org_fwd;
	qc_aim_org_shared[1] = org_right;
	qc_aim_org_shared[2] = org_up;
	qc_aim_yaw_shared = yaw_deg;
	qc_aim_pitch_shared = pitch_deg;
	pthread_mutex_unlock (&qc_input_lock);
}

void QC_InputSetTeleport (int active, int commit, float org_fwd, float org_right,
			  float org_up, float yaw_deg, float pitch_deg)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_tp_active_shared = active ? 1 : 0;
	if (commit)
		qc_tp_commit_shared = 1;	/* latched; drained on the engine thread */
	qc_tp_org_shared[0] = org_fwd;
	qc_tp_org_shared[1] = org_right;
	qc_tp_org_shared[2] = org_up;
	qc_tp_yaw_shared = yaw_deg;
	qc_tp_pitch_shared = pitch_deg;
	pthread_mutex_unlock (&qc_input_lock);
}

void QC_InputSetWheel (int open, int has_anchor,
		       float fwd, float right, float up, int highlight)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_wheel_open_shared = open;
	qc_wheel_anchor_shared = has_anchor;
	qc_wheel_pos_shared[0] = fwd;
	qc_wheel_pos_shared[1] = right;
	qc_wheel_pos_shared[2] = up;
	qc_wheel_highlight_shared = highlight;
	pthread_mutex_unlock (&qc_input_lock);
}

/* ========================================================================
 * engine-thread state
 * ===================================================================== */

/* Head-follow bookkeeping, read by qr_bridge.c into the frame packet: the
   world-frame XY displacement already absorbed into the player origin, and
   the recenter generation the renderer re-zeroes its pose against. */
float		qr_head_absorbed[2];
uint32_t	qr_recenter_count;

/* Weapon-wheel state, read by qr_bridge.c for the ring emission. The open
   FRACTION eases on REAL time (the wheel must open at full speed while the
   world it slows crawls -- that contrast is the whole effect), and the
   same fraction drives host_timescale, so the two can never disagree. */
float		qr_wheel_frac;			/* eased 0..1 */
int		qr_wheel_open;			/* merged intent, this frame */
int		qr_wheel_has_anchor;
float		qr_wheel_anchor[3];		/* body frame: fwd, right, up */
int		qr_wheel_highlight = -1;	/* owned-ring index, -1 none */
float		qr_height_trim;			/* eye-height trim, Quake units */

static int	qr_wheel_console_open;		/* +wheel / -wheel */
static cvar_t	wheel_timescale = {"wheel_timescale", "0.2", CVAR_ARCHIVE};

#define QR_WHEEL_RAMP_TIME	0.25

static qc_gamepad_state_t	qr_pad, qr_pad_prev;
float				qr_head[3];	/* body-frame head offset, read by qr_bridge.c */
float				qr_head_yaw;	/* read by qr_bridge (full menu) */
float				qr_head_pitch;

/* M6 aim/body split. The body yaw is the movement + immersive-camera frame;
   it lives here now instead of in cl.viewangles[YAW], which carries the AIM
   (body yaw + the hand ray) so the server fires where you point. Both are
   read by qr_bridge.c: qr_body_yaw into the packet, the aim rides
   cl.viewangles. qr_expected_yaw is what IN_Move last wrote to
   cl.viewangles[YAW]; a mismatch next frame means the server set the angle
   (spawn, teleport svc_setangle) and the body must adopt it. */
float				qr_body_yaw;
float				qr_aim_org[3];		/* dominant hand, body frame */
int				qr_aim_active;		/* hand aim live (vr_handaim &&
							   valid); read by qr_bridge to
							   anchor the weapon at the hand */
static int			qr_aim_valid;
static float			qr_aim_yaw;		/* room-relative, Quake deg */
static float			qr_aim_pitch;
static float			qr_expected_yaw;

/* Teleport, engine-thread. qr_tp_valid/qr_tp_dest are read by qr_bridge.c to
   draw the landing marker; the rest is the off-hand ray this tick. */
int				qr_tp_mark_state;	/* -1 hidden, 0 air/red, 1 blocked/yellow, 2 ok/cyan */
vec3_t				qr_tp_dest;		/* world marker point */
static int			qr_tp_aiming;		/* off-hand arming this tick */
static float			qr_tp_org[3];		/* off-hand, body frame */
static float			qr_tp_yaw, qr_tp_pitch;	/* room-relative, Quake deg */

static int			qr_paused;		/* drained console pause */
static int			qr_slowmo_raw;		/* drained L3 button */
static int			qr_turn_locked;		/* drained turn-lock request */
static int			qr_slowmo_active;	/* toggled bullet-time */
static uint32_t			qr_head_ack_seen;

static cvar_t	vr_snapturn = {"vr_snapturn", "45", CVAR_ARCHIVE};
static cvar_t	vr_smoothturn = {"vr_smoothturn", "0", CVAR_ARCHIVE};
/* Metroid Prime Hunters edge turn: aim the gun past a yaw DEADZONE (deg) to a
   side and the body follows at up to SPEED (deg/s), ramping over the 40deg past
   the deadzone. The aim yaw is room-relative so it stays at the edge while the
   body sweeps -- continuous while held. */
static cvar_t	vr_edgeturn = {"vr_edgeturn", "1", CVAR_ARCHIVE};
static cvar_t	vr_edgeturn_dz = {"vr_edgeturn_dz", "18", CVAR_ARCHIVE};
static cvar_t	vr_edgeturn_speed = {"vr_edgeturn_speed", "90", CVAR_ARCHIVE};
static cvar_t	vr_moverelative = {"vr_moverelative", "1", CVAR_ARCHIVE};
static cvar_t	vr_headaim = {"vr_headaim", "1", CVAR_ARCHIVE};
/* M6: aim from the dominant hand/controller ray. 1 = the gun lives in your
   hand and shots go where you point; 0 = body-anchored aim (the M5 feel,
   head-pitch elevation) -- the A/B for judging feel, one cvar to flip. */
static cvar_t	vr_handaim = {"vr_handaim", "1", CVAR_ARCHIVE};
/* M6: THE pitch trim for the hand aim, degrees, positive = aim LOWER. Corrects
   a systematic high/low bias from how the forearm rests when pointing; applies
   to the shot and the gun model together. Tune live against the laser.
   The default carries the 8 degrees that used to be a second, hidden constant
   in HandInput.feedAim -- one visible number rather than two stacked knobs. */
static cvar_t	vr_aimpitch = {"vr_aimpitch", "8", CVAR_ARCHIVE};
/* The lateral half of the same trim, degrees, positive = aim further RIGHT.
   Pitch alone could correct "shoots high" but not "shoots left", which a
   forearm-only aim needs: the elbow->wrist line points slightly across the
   body. Default 0 -- the bias is per-person, unlike the vertical one. */
static cvar_t	vr_aimyaw = {"vr_aimyaw", "0", CVAR_ARCHIVE};
/* M6: a laser line from the muzzle down the aim, an aiming aid. Read by
   qr_bridge; non-static so it externs cleanly like the other vr_ cvars. */
/* Weapon-wheel ring plane, degrees off the body basis, and a scale on its
   radius. Pitch/yaw/roll tilt the plane the weapons ring in; the selection
   math in WheelState.swift applies the IDENTICAL rotation to its own axes, so
   these three numbers are a shared contract -- change the meaning here and the
   highlight points at a different weapon than the one under your hand. The
   radius scale is safe to change alone: selection is angle-only. */
cvar_t		vr_wheelpitch  = {"vr_wheelpitch",  "0", CVAR_ARCHIVE};
cvar_t		vr_wheelyaw    = {"vr_wheelyaw",    "0", CVAR_ARCHIVE};
cvar_t		vr_wheelroll   = {"vr_wheelroll",   "0", CVAR_ARCHIVE};
cvar_t		vr_wheelradius = {"vr_wheelradius", "1", CVAR_ARCHIVE};
cvar_t		vr_wheelfwd  = {"vr_wheelfwd",  "0", CVAR_ARCHIVE};
cvar_t		vr_wheelup   = {"vr_wheelup",   "0", CVAR_ARCHIVE};
cvar_t		vr_wheelside = {"vr_wheelside", "0", CVAR_ARCHIVE};
/* Rear keep-fraction for a WHEEL model that fell back to the viewmodel (1 =
   whole model). Those bake a loaded round near the GRIP -- same place the hand
   weapon's vr_weaponclipback (0.79) trims -- so the wheel retracts the rear the
   same way. Clean pickup models, the axe and the lightning gun are never
   trimmed (see QR_EmitWheel). */
cvar_t		vr_wheelclip = {"vr_wheelclip", "0.79", CVAR_ARCHIVE};
cvar_t		vr_laser = {"vr_laser", "0", CVAR_ARCHIVE};
cvar_t		vr_reticle = {"vr_reticle", "0", CVAR_ARCHIVE};
/* Reticle shape (0 cross, 1 circle+dot, 2 dot, 3 circle, 4 cross+dot) and the
   colour indices into the shared palette for the reticle and the laser (see
   QR_VrColor in qr_bridge.c). Laser defaults to red, reticle to amber. */
cvar_t		vr_reticlestyle = {"vr_reticlestyle", "0", CVAR_ARCHIVE};
cvar_t		vr_reticlecolor = {"vr_reticlecolor", "3", CVAR_ARCHIVE};
/* HL2-style curved gauges flanking the reticle: health left, ammo right.
   Independent of vr_reticle/vr_reticlestyle -- on with any reticle shape, or
   standalone with no shape at all. */
cvar_t		vr_reticle_arcs = {"vr_reticle_arcs", "0", CVAR_ARCHIVE};
cvar_t		vr_lasercolor   = {"vr_lasercolor",   "0", CVAR_ARCHIVE};
/* Point-and-blink teleport locomotion: aim with the gun reticle, ring-pinch to
   blink. vr_teleportcolor tints the GUN RETICLE cyan when the spot is a valid
   landing (one reticle, no second ring); turn it off to keep the reticle's
   normal colour. */
cvar_t		vr_teleport     = {"vr_teleport",     "1", CVAR_ARCHIVE};
cvar_t		vr_teleportcolor = {"vr_teleportcolor", "1", CVAR_ARCHIVE};
cvar_t		vr_teleportsound = {"vr_teleportsound", "1", CVAR_ARCHIVE};
cvar_t		vr_teleportfx    = {"vr_teleportfx",    "1", CVAR_ARCHIVE};	/* particle splash */
cvar_t		vr_telefrag      = {"vr_telefrag",      "1", CVAR_ARCHIVE};	/* gib what you land on */
/* M6: where along the hand weapon the wrist grips, 0 (rear/stock) .. 1
   (muzzle). Low values push the barrel forward off the hand -- megaman
   arm-cannon. Read by qr_bridge; tune live on device. */
cvar_t		vr_weapongrip = {"vr_weapongrip", "0.15", CVAR_ARCHIVE};
/* M6: live positional nudge of the hand weapon, Quake units, along the AIM
   axes -- back = toward the player, up = raise, side = to the player's right.
   Default 0; tune in the headset so placement never needs a recompile. */
cvar_t		vr_weaponback = {"vr_weaponback", "0", CVAR_ARCHIVE};
cvar_t		vr_weaponup   = {"vr_weaponup",   "0", CVAR_ARCHIVE};
cvar_t		vr_weaponside = {"vr_weaponside", "0", CVAR_ARCHIVE};
/* M6: how much of the hand weapon to KEEP, from each end (1 = whole model,
   lower retracts baked-in geometry -- a nail out the barrel, or a round behind
   the receiver). vr_weaponclip trims the BARREL end, vr_weaponclipback the
   ARM end. Manual, because projectile-vs-gun can't be told from geometry. */
cvar_t		vr_weaponclip     = {"vr_weaponclip",     "1", CVAR_ARCHIVE};
/* 0.79 default: the view models bake a round/nail into the rear ~21% of the
   model (near the hand); clipping it there clears it on every weapon (found
   on device). Barrel end is left whole. */
cvar_t		vr_weaponclipback = {"vr_weaponclipback", "0.79", CVAR_ARCHIVE};
/* Debug: 1 draws the hand weapon SOLID GREEN, to identify it on screen. */
cvar_t		vr_weapontint = {"vr_weapontint", "0", 0};
/* Debug: 1 draws enemy AI overlay -- each live monster's traveled trail
   (breadcrumbs) and its intent line to its target. Quake AI is greedy (no
   planned path), so this shows where each monster HAS walked and what it is
   chasing, coloured per monster. */
cvar_t		vr_pathdebug = {"vr_pathdebug", "0", 0};
cvar_t		vr_projdebug = {"vr_projdebug", "0", 0};
cvar_t		vr_projhand = {"vr_projhand", "1", 0};
/* M6: where the aiming laser STARTS, Quake units along the aim axes from the
   wrist -- forward reaches the muzzle so the beam emits from the barrel tip
   instead of behind the gun, up/side fine-tune to the barrel line. */
cvar_t		vr_laserforward = {"vr_laserforward", "0", CVAR_ARCHIVE};
cvar_t		vr_laserup      = {"vr_laserup",      "0", CVAR_ARCHIVE};
cvar_t		vr_laserside    = {"vr_laserside",    "0", CVAR_ARCHIVE};
/* M6: laser beam TILT, degrees, off the shot direction so the beam lines up
   with the barrel visually. pitch positive = tilt down, yaw positive = left.
   NB this makes the beam diverge slightly from the true bullet path -- a
   visual-alignment nudge, keep it small. */
cvar_t		vr_laserpitch   = {"vr_laserpitch",   "0", CVAR_ARCHIVE};
cvar_t		vr_laseryaw     = {"vr_laseryaw",     "0", CVAR_ARCHIVE};
static cvar_t	vr_slowmo = {"vr_slowmo", "0.3", CVAR_ARCHIVE};	/* L3 bullet-time scale */
cvar_t		vr_fullmenu = {"vr_fullmenu", "0", CVAR_ARCHIVE};	/* fixed panel vs wrist ring */
cvar_t	vr_lean_limit = {"vr_lean_limit", "12", CVAR_ARCHIVE};	/* read by qr_bridge.c */

/* Stick response: radial deadzone, then rescale so the curve still reaches
   1.0 at full deflection. */
#define QR_STICK_DEADZONE	0.15f

static float IN_DeadZone (float value)
{
	float mag = fabsf (value);

	if (mag < QR_STICK_DEADZONE)
		return 0.f;
	mag = (mag - QR_STICK_DEADZONE) / (1.f - QR_STICK_DEADZONE);
	return (value < 0.f) ? -mag : mag;
}

/*
================
IN_ApplyPause -- mirror QC_SetPaused onto sv.paused, on the engine thread.

Quake only exposes pausing as a TOGGLE ("pause"), which desyncs the moment
anything else touches it, so the console-pause drives an explicit SET instead.
This does what Host_Pause_f does minus the chat broadcast: flip sv.paused and
tell the clients, so the local client's cl.paused matches and prediction stops.

Single-player only, like every other server-state feature here. Pausing
freezes the SIM only -- the render thread and head tracking keep running, so
you can still look around a stopped world.
================
*/
static void IN_ApplyPause (void)
{
	static int	applied = 0;

	/* No server yet: leave the request PENDING rather than consuming it. The
	   app asks to pause at launch, before any map exists, and that intent has
	   to survive until one does -- otherwise the first level starts running
	   under a console the player is still reading. */
	if (!sv.active)
		return;

	if (qr_paused != applied)
	{
		applied = qr_paused;
		sv.paused = qr_paused ? 1 : 0;
		MSG_WriteByte (&sv.reliable_datagram, svc_setpause);
		MSG_WriteByte (&sv.reliable_datagram, sv.paused);
		return;
	}

	/* Intent unchanged, but SV_SpawnServer memsets sv, so loading a map clears
	   sv.paused underneath us and the world would run while the app still
	   believes it is stopped. Re-assert. Only in this direction: if the player
	   types "pause" in the console while we are NOT pausing, that is theirs to
	   keep. */
	if (applied && !sv.paused)
	{
		/* ...but NOT before the client has spawned. Pausing during the signon
		   stops the server before it sends the first clientdata, which is what
		   sets cl.viewheight -- it stays 0, the camera sits at the player
		   entity's ORIGIN instead of eye level, and the level starts with your
		   head in the floor. It un-sinks the moment the sim runs, which is
		   exactly the tell. Let the spawn complete, then freeze. */
		if (cls.signon != SIGNONS || cl.viewheight == 0)
			return;

		sv.paused = 1;
		MSG_WriteByte (&sv.reliable_datagram, svc_setpause);
		MSG_WriteByte (&sv.reliable_datagram, sv.paused);
	}
}

static void IN_SnapshotInputs (void)
{
	pthread_mutex_lock (&qc_input_lock);
	qr_paused = qc_paused_shared;
	qr_pad = qc_pad_shared;
	qr_head[0] = qc_head_shared[0];
	qr_head[1] = qc_head_shared[1];
	qr_head[2] = qc_head_shared[2];
	qr_head_yaw = qc_head_yaw_shared;
	qr_head_pitch = qc_head_pitch_shared;
	qr_slowmo_raw = qc_slowmo_shared;
	qr_turn_locked = qc_turnlock_shared;
	qr_aim_valid = qc_aim_valid_shared;
	qr_aim_org[0] = qc_aim_org_shared[0];
	qr_aim_org[1] = qc_aim_org_shared[1];
	qr_aim_org[2] = qc_aim_org_shared[2];
	qr_aim_yaw = qc_aim_yaw_shared;
	qr_aim_pitch = qc_aim_pitch_shared;
	qr_tp_aiming = qc_tp_active_shared;
	/* NOTE: the one-shot commit latch (qc_tp_commit_shared) is drained in
	   IN_Teleport, NOT here -- SnapshotInputs runs from BOTH IN_Commands and
	   IN_Move, so draining it here let the first call eat the commit before
	   IN_Teleport (in the second) ever saw it. */
	qr_tp_org[0] = qc_tp_org_shared[0];
	qr_tp_org[1] = qc_tp_org_shared[1];
	qr_tp_org[2] = qc_tp_org_shared[2];
	qr_tp_yaw = qc_tp_yaw_shared;
	qr_tp_pitch = qc_tp_pitch_shared;
	qr_head_ack_seen = qc_head_ack;
	qr_wheel_open = qc_wheel_open_shared || qr_wheel_console_open;
	qr_wheel_has_anchor = qc_wheel_anchor_shared;
	qr_wheel_anchor[0] = qc_wheel_pos_shared[0];
	qr_wheel_anchor[1] = qc_wheel_pos_shared[1];
	qr_wheel_anchor[2] = qc_wheel_pos_shared[2];
	qr_wheel_highlight = qc_wheel_highlight_shared;
	qr_height_trim = qc_height_trim_shared;
	qr_bodyyaw_override = qc_bodyyaw_override_shared;
	qr_bodyyaw_pinned = qc_bodyyaw_shared;
	pthread_mutex_unlock (&qc_input_lock);
}

/*
================
IN_WheelRamp -- ease the open fraction on REAL time and drive
host_timescale from it.

Runs every IN_Commands, i.e. once per engine tick. The clock is the
engine's `realtime`, which accumulates the unscaled dt QC_Frame feeds --
the same clock Host_FilterTime paces ticks (and therefore packets) with,
and the one clock host_timescale can never slow. That is also why
host_timescale is the right lever: it multiplies only host_frametime, the
simulation's dt, so the tick and packet rate stay at full speed while the
world crawls. Scaling the QC_Frame dt at the boundary instead would
starve the pacer and drop the packet rate with it.
================
*/
static void IN_WheelRamp (void)
{
	static double	lasttime;
	static float	qr_slowmo_frac;		/* eased 0..1 */
	static int	slowmo_prev_raw;
	double		dt = realtime - lasttime;
	float		wtarget = qr_wheel_open ? 1.f : 0.f;
	float		starget, we, se, ts_wheel, ts_slow, ts;

	if (dt < 0 || dt > 1)
		dt = 0;
	lasttime = realtime;

	/* L3 is a TOGGLE: flip bullet-time on the button's rising edge. */
	if (qr_slowmo_raw && !slowmo_prev_raw)
		qr_slowmo_active = !qr_slowmo_active;
	slowmo_prev_raw = qr_slowmo_raw;
	starget = qr_slowmo_active ? 1.f : 0.f;

	if (qr_wheel_frac < wtarget)
		qr_wheel_frac = q_min (qr_wheel_frac + (float)(dt / QR_WHEEL_RAMP_TIME), wtarget);
	else if (qr_wheel_frac > wtarget)
		qr_wheel_frac = q_max (qr_wheel_frac - (float)(dt / QR_WHEEL_RAMP_TIME), wtarget);

	if (qr_slowmo_frac < starget)
		qr_slowmo_frac = q_min (qr_slowmo_frac + (float)(dt / QR_WHEEL_RAMP_TIME), starget);
	else if (qr_slowmo_frac > starget)
		qr_slowmo_frac = q_max (qr_slowmo_frac - (float)(dt / QR_WHEEL_RAMP_TIME), starget);

	if (qr_wheel_frac <= 0.f && qr_slowmo_frac <= 0.f)
	{
		/* nothing slowing time: hand the cvar back to its upstream meaning
		   (0 = disabled) so console slow-mo experiments still work */
		if (host_timescale.value != 0.f)
			Cvar_SetValueQuick (&host_timescale, 0.f);
		return;
	}

	/* The deeper slowdown wins, so opening the wheel mid-slowmo (or vice
	   versa) never speeds the world back up. */
	we = qr_wheel_frac * qr_wheel_frac * (3.f - 2.f * qr_wheel_frac);
	se = qr_slowmo_frac * qr_slowmo_frac * (3.f - 2.f * qr_slowmo_frac);
	ts_wheel = 1.f + we * (CLAMP (0.05f, wheel_timescale.value, 1.f) - 1.f);
	ts_slow  = 1.f + se * (CLAMP (0.05f, vr_slowmo.value, 1.f) - 1.f);
	ts = q_min (ts_wheel, ts_slow);
	Cvar_SetValueQuick (&host_timescale, ts);
}

static void IN_WheelDown_f (void) { qr_wheel_console_open = 1; }
static void IN_WheelUp_f (void) { qr_wheel_console_open = 0; }

/* ========================================================================
 * buttons -> Key_Event
 * ===================================================================== */

typedef struct qr_padkey_s {
	uint32_t	bit;
	int		key;
} qr_padkey_t;

static const qr_padkey_t qr_padkeys[] = {
	{ QC_PAD_A,		K_ABUTTON },
	{ QC_PAD_B,		K_BBUTTON },
	{ QC_PAD_X,		K_XBUTTON },
	{ QC_PAD_Y,		K_YBUTTON },
	{ QC_PAD_LSHOULDER,	K_LSHOULDER },
	{ QC_PAD_RSHOULDER,	K_RSHOULDER },
	{ QC_PAD_LTHUMB,	K_LTHUMB },
	{ QC_PAD_RTHUMB,	K_RTHUMB },
};

/* Triggers are analog; treat as buttons with hysteresis so a resting
   trigger can't flutter the attack state. */
#define QR_TRIGGER_PRESS	0.35f
#define QR_TRIGGER_RELEASE	0.20f

static qboolean	qr_lt_down, qr_rt_down;

static void IN_TriggerEdge (float value, qboolean *down, int key)
{
	if (!*down && value > QR_TRIGGER_PRESS)
	{
		*down = true;
		Key_Event (key, true);
	}
	else if (*down && value < QR_TRIGGER_RELEASE)
	{
		*down = false;
		Key_Event (key, false);
	}
}

void IN_Commands (void)
{
	size_t i;
	uint32_t changed;

	IN_SnapshotInputs ();
	IN_ApplyPause ();
	IN_WheelRamp ();

	/* While the wheel is open the trigger picks weapons, not fights:
	   release a held attack and swallow new edges. */
	if (qr_wheel_open)
	{
		if (qr_rt_down)
		{
			qr_rt_down = false;
			Key_Event (K_RTRIGGER, false);
		}
	}

	changed = qr_pad.buttons ^ qr_pad_prev.buttons;
	for (i = 0; i < sizeof(qr_padkeys) / sizeof(qr_padkeys[0]); i++)
	{
		if (changed & qr_padkeys[i].bit)
			Key_Event (qr_padkeys[i].key,
				   (qr_pad.buttons & qr_padkeys[i].bit) != 0);
	}

	/* Menu (pause) opens the game menu; options (view) recenters. Both
	   act directly rather than through bindings so they work even with a
	   wiped config. */
	if ((changed & QC_PAD_MENU) && (qr_pad.buttons & QC_PAD_MENU))
	{
		Key_Event (K_ESCAPE, true);
		Key_Event (K_ESCAPE, false);
	}
	if ((changed & QC_PAD_OPTIONS) && (qr_pad.buttons & QC_PAD_OPTIONS))
		Cbuf_AddText ("vr_recenter\n");

	if (!qr_wheel_open)
		IN_TriggerEdge (qr_pad.rt, &qr_rt_down, K_RTRIGGER);
	IN_TriggerEdge (qr_pad.lt, &qr_lt_down, K_LTRIGGER);

	qr_pad_prev = qr_pad;
}

/* ========================================================================
 * head follow, snap turn, movement
 * ===================================================================== */

static void IN_YawVectors (float yaw, vec3_t fwd, vec3_t right)
{
	float rad = yaw * M_PI / 180.f;

	fwd[0] = cosf (rad);
	fwd[1] = sinf (rad);
	fwd[2] = 0.f;
	right[0] = sinf (rad);
	right[1] = -cosf (rad);
	right[2] = 0.f;
}

/* The head's offset from the camera anchor, world frame, from the latest
   feed rotated by the CURRENT body yaw (the feed is body-frame exactly so
   snap turn rotates it for free). */
static void IN_HeadOffsetWorld (float out[2])
{
	vec3_t fwd, right;

	/* The body basis, not the aim: the head offset is a body-frame feed, so
	   snap turn rotates it with the body (qr_body_yaw), never with the hand. */
	IN_YawVectors (qr_body_yaw, fwd, right);
	out[0] = qr_head[0] * fwd[0] + qr_head[1] * right[0];
	out[1] = qr_head[0] * fwd[1] + qr_head[1] * right[1];
}

/*
================
QR_HandOrigin -- where the held gun actually is, in world space.

The same reconstruction qr_bridge.c uses to anchor the view weapon at the
hand: the eye, plus the hand's body-frame offset from the head, rotated into
the world by the body yaw. Kept here rather than in the bridge because every
term is an in_null.c global; the bridge and this must stay in step, or the
bolt and the gun that fires it part company.

Returns 0 and leaves out alone when the hand aim is not live -- gamepad or
keyboard play, or tracking lost -- so callers fall back to upstream's body
origin. qr_aim_active is the same gate the shot, the move compensation and
the hand-anchored weapon read.

Engine thread. Callers that run before V_CalcRefdef (CL_UpdateTEnts does)
see last frame's r_refdef.vieworg: one frame of head motion, a unit or two,
against the ~24 units the body origin is wrong by.
================
*/
int QR_HandOrigin (vec3_t out)
{
	vec3_t	fwd, right;
	float	ax, ay, az;

	if (!qr_aim_active)
		return 0;

	IN_YawVectors (qr_body_yaw, fwd, right);
	ax = qr_aim_org[0] - qr_head[0];
	ay = qr_aim_org[1] - qr_head[1];
	az = qr_aim_org[2] - qr_head[2];

	out[0] = r_refdef.vieworg[0] + ax * fwd[0] + ay * right[0];
	out[1] = r_refdef.vieworg[1] + ax * fwd[1] + ay * right[1];
	out[2] = r_refdef.vieworg[2] + az + qr_height_trim;
	return 1;
}

/*
================
QR_MuzzleSpawn -- start my own missiles at the gun, not at my navel.

Vanilla spawns each weapon's missile at a per-weapon offset from the player
ORIGIN, which on a flat screen is right under the camera and in a headset is
the middle of your chest while the gun is in your hand. Correcting it where
the position is DECIDED -- before SV_LinkEdict, before any physics -- is what
makes the shot genuinely leave the barrel: the trail starts there, the model
is drawn there, and the thing flies a true path from there. The client-side
version of this could only shift what was drawn, so it had to fold the shift
away again and the fold was visible.

Returns 1 having written e->v.origin itself; 0 means PF_setorigin should do
what upstream does. It declines unless all of these hold, so the fallback is
the normal case and not an error path:

  - the edict is a missile owned by the player (movetype FLYMISSILE for
    rockets, nails and spikes; BOUNCE for grenades)
  - its origin is still zero, i.e. this is the first placement after
    ED_ClearEdict and not a later setorigin -- a teleporter moving a live
    grenade must be left alone
  - the requested position is near the player, so a first placement that is
    really a teleport destination cannot be captured either
  - a hand is actually tracked; on a gamepad the body origin is the honest
    answer and upstream's is already correct

Those gates are also why getting vanilla's QuakeC wrong is safe: if owner or
movetype are not yet set when setorigin runs, this declines and nothing
changes.

This DOES move where the shot comes from for collision, not just for the
eye -- a rocket can clear a ledge your body cannot, and a gun poked through
a wall fires on the far side. That is the intended behaviour for a port
where you aim with your arm, and the trace below is what keeps it honest: a
missile may never be placed inside geometry.

Engine thread, inside the server's own think. Single player.
================
*/
#define QR_MUZZLE_MAXDIST	64.f	/* how far from the player a placement
					   may be and still be a launch */
#define QR_MUZZLE_REACH		72.f	/* furthest a hand can credibly be from the
					   body: beyond this the pose is stale or
					   garbage, not a reach */

int QR_MuzzleSpawn (edict_t *e, const float *org)
{
	edict_t		*player;
	vec3_t		start, muzzle, want, back, rel, fwd, right;
	trace_t		tr;
	int		mt;

	if (!vr_projhand.value || !sv.active)
		return 0;
	if (!svs.clients || !svs.clients[0].active)
		return 0;

	player = svs.clients[0].edict;
	if (e == player || PROG_TO_EDICT (e->v.owner) != player)
		return 0;

	mt = (int) e->v.movetype;
	if (mt != MOVETYPE_FLYMISSILE && mt != MOVETYPE_BOUNCE)
		return 0;

	/* first placement only -- ED_ClearEdict zeroed this */
	if (e->v.origin[0] || e->v.origin[1] || e->v.origin[2])
		return 0;

	start[0] = org[0]; start[1] = org[1]; start[2] = org[2];
	VectorSubtract (start, player->v.origin, back);
	if (VectorLength (back) > QR_MUZZLE_MAXDIST)
		return 0;

	if (!QR_HandOrigin (muzzle))
		return 0;

	/* QR_HandOrigin is built on r_refdef.vieworg, which holds nothing
	   meaningful until the first frame of a map has been rendered. The trace
	   below stops a bad muzzle from landing inside geometry but not from
	   landing a hundred units away in open air, so bound it: a hand cannot
	   be further from the body than an arm plus a head. */
	VectorSubtract (muzzle, player->v.origin, back);
	if (VectorLength (back) > QR_MUZZLE_REACH)
		return 0;

	/* Vanilla's spawn offset carries two different things, and only one of
	   them is ours to replace. Part of it merely lifts the missile to chest
	   height and stands it off in front of the body ('0 0 16', v_forward*8),
	   which is exactly what the muzzle already accounts for. The rest is the
	   weapon's own firing PATTERN: the nailgun alternates v_right*+-4
	   between its two attack frames, and that is the whole reason it fires
	   two streams instead of one. Replacing the position outright threw it
	   away and turned the nailgun into a single stream.

	   The aim's HORIZONTAL right vector separates them exactly. '0 0 16' is
	   vertical and v_forward lies in the vertical plane through the aim, so
	   neither has any component along it; whatever does is the pattern. Use
	   the yaw alone rather than AngleVectors on the full v_angle, so pitch
	   and any roll cannot leak the chest lift into the lateral term. */
	IN_YawVectors (player->v.v_angle[YAW], fwd, right);
	VectorSubtract (start, player->v.origin, rel);
	VectorMA (muzzle, DotProduct (rel, right), right, want);

	/* The short hop from the body spawn point out to the gun, so a missile
	   is never placed inside a wall. The missile's owner is the player, so
	   SV_Move skips the player's own box (world.c's "don't clip against
	   owner"); nothing else here is ours to pass through. */
	tr = SV_Move (start, vec3_origin, vec3_origin, want, MOVE_NORMAL, e);
	if (tr.allsolid || tr.startsolid)
		return 0;		/* body spawn point is already in solid:
					   leave upstream's answer alone */

	if (tr.fraction < 1.f)
	{
		/* Stop short of the plane rather than on it, or the missile
		   detonates against a surface it was only passing. */
		VectorSubtract (start, tr.endpos, back);
		if (VectorNormalize (back) == 0.f)
			return 0;
		VectorMA (tr.endpos, 2.f, back, e->v.origin);
	}
	else
		VectorCopy (want, e->v.origin);

	return 1;
}

/*
================
IN_AbsorbHeadOffset -- room-scale walking becomes player movement.

The render thread feeds where the head is; the engine walks the player box
after it with a real trace, so collision still means something -- without
this you can lean your head through a wall, which is exactly the failure
the phase effect cannot afford. The camera anchor is vieworg minus the
absorbed total, so rendering stays continuous whether or not the box could
follow; the renderer clamps the leftover lean to vr_lean_limit.
================
*/
static void IN_AbsorbHeadOffset (void)
{
	float offset[2], residual[2];
	edict_t *player;
	trace_t trace;
	vec3_t start, end;

	/* A recenter is in flight until the renderer echoes the new count:
	   the last feed still uses the old pose, and absorbing it would walk
	   the body toward a head position that is about to become zero. */
	if (qr_head_ack_seen != qr_recenter_count)
		return;

	IN_HeadOffsetWorld (offset);
	residual[0] = offset[0] - qr_head_absorbed[0];
	residual[1] = offset[1] - qr_head_absorbed[1];
	if (fabsf (residual[0]) < 0.25f && fabsf (residual[1]) < 0.25f)
		return;

	if (!sv.active || !svs.clients || !svs.clients[0].active)
	{
		/* No world to collide with (console, demos): keep the camera
		   anchored to the view by treating everything as absorbed. */
		qr_head_absorbed[0] = offset[0];
		qr_head_absorbed[1] = offset[1];
		return;
	}

	player = svs.clients[0].edict;
	VectorCopy (player->v.origin, start);
	end[0] = start[0] + residual[0];
	end[1] = start[1] + residual[1];
	end[2] = start[2];

	trace = SV_Move (start, player->v.mins, player->v.maxs, end,
			 MOVE_NORMAL, player);
	VectorCopy (trace.endpos, player->v.origin);
	SV_LinkEdict (player, true);

	qr_head_absorbed[0] += trace.endpos[0] - start[0];
	qr_head_absorbed[1] += trace.endpos[1] - start[1];
}

/*
================
IN_Teleport -- point-and-blink locomotion. The OFF hand arms a destination
(QC_InputSetTeleport feeds the ray in the same body-frame form as the aim);
this traces it to a floor, validates it, publishes the landing point for the
marker (qr_tp_dest / qr_tp_valid), and on the release edge jumps the player
there. Collision-checked: the box must fit, and the floor must be walkable and
not lava/slime/sky, so you can't blink into a wall or out of the world. The
move itself is the IN_AbsorbHeadOffset pattern -- set origin, relink.
================
*/
static vec3_t	qr_tp_cached;		/* last valid dest while aiming */
static int	qr_tp_cached_valid;

static void IN_Teleport (void)
{
	vec3_t		right, up, org, dir, end, feet;
	trace_t		tr, fit;
	edict_t		*player;
	int		contents, can, commit;

	/* Drain the one-shot commit latch HERE -- the only consumer -- so neither
	   IN_Commands' nor IN_Move's SnapshotInputs can swallow it first. */
	pthread_mutex_lock (&qc_input_lock);
	commit = qc_tp_commit_shared;
	qc_tp_commit_shared = 0;
	pthread_mutex_unlock (&qc_input_lock);

	qr_tp_mark_state = -1;		/* hidden unless we find a destination */
	qr_tp_cached_valid = 0;
	can = vr_teleport.value && sv.active && svs.clients && svs.clients[0].active;
	player = can ? svs.clients[0].edict : NULL;

	/* ONE reticle: the teleport lands where the GUN is already aimed (the same
	   ray the aiming reticle traces), so there's no second off-hand aim to
	   manage. The off-hand teleport feed (QC_InputSetTeleport org/yaw/pitch) is
	   kept in the pipe for a future PSVR dual-wield, but is not read here --
	   only its `commit` (the ring-finger pinch) is. The landing marker is
	   gated renderer-side by vr_teleportmarker so it can be hidden; the gun
	   reticle alone then shows the spot. */
	if (can)
	{
		if (!QR_HandOrigin (org))		/* gun muzzle; eye if no hand aim */
			VectorCopy (r_refdef.vieworg, org);
		AngleVectors (cl.viewangles, dir, right, up);	/* the shot direction */
		VectorMA (org, 8192.f, dir, end);

		tr = SV_Move (org, vec3_origin, vec3_origin, end, MOVE_NOMONSTERS, player);
		if (tr.allsolid || tr.fraction >= 1.f)
		{
			VectorMA (org, 200.f, dir, qr_tp_dest);
			qr_tp_mark_state = 0;			/* red: open air */
		}
		else
		{
			VectorCopy (tr.endpos, qr_tp_dest);
			qr_tp_mark_state = 1;			/* yellow: can't stand */
			if (tr.plane.normal[2] >= 0.7f)		/* walkable floor */
			{
				VectorCopy (tr.endpos, feet);
				feet[2] += -player->v.mins[2] + 1.f;
				/* With telefrag on, ignore monsters for the fit test so you
				   CAN land on one (and gib it below); the world must still be
				   clear either way. */
				fit = SV_Move (feet, player->v.mins, player->v.maxs, feet,
					       vr_telefrag.value ? MOVE_NOMONSTERS : MOVE_NORMAL,
					       player);
				contents = SV_PointContents (feet);
				if (!fit.startsolid && !fit.allsolid
				    && contents != CONTENTS_LAVA && contents != CONTENTS_SLIME
				    && contents != CONTENTS_SKY)
				{
					qr_tp_mark_state = 2;		/* cyan: landable */
					VectorCopy (feet, qr_tp_cached);
					qr_tp_cached_valid = 1;
				}
			}
		}
	}

	/* Ring-pinch commit: blink to the current landable spot. The gun aim is
	   stable under an off-hand pinch, so this frame's destination is good. */
	if (commit && qr_tp_cached_valid)
	{
		vec3_t	oldorg, pmin, pmax;
		int	a;

		VectorCopy (player->v.origin, oldorg);		/* departure, for the FX */
		VectorCopy (qr_tp_cached, player->v.origin);
		player->v.velocity[0] = player->v.velocity[1] = player->v.velocity[2] = 0.f;
		SV_LinkEdict (player, true);

		/* Telefrag: gib any LIVE monster whose box overlaps where you landed,
		   the way a trigger_teleport does. Drive each victim's own th_die with
		   lethal health so it gibs; save/restore the QuakeC `self`. */
		if (vr_telefrag.value && sv.active)
		{
			int	e, saved = pr_global_struct->self;

			for (a = 0; a < 3; a++)
			{
				pmin[a] = player->v.origin[a] + player->v.mins[a];
				pmax[a] = player->v.origin[a] + player->v.maxs[a];
			}
			for (e = 1; e < sv.num_edicts; e++)
			{
				edict_t *victim = EDICT_NUM (e);
				eval_t	*die;

				if (victim == player || victim->free)
					continue;
				if (victim->v.solid != SOLID_SLIDEBOX || victim->v.health <= 0.f)
					continue;	/* live monsters only */
				if (victim->v.absmin[0] > pmax[0] || victim->v.absmax[0] < pmin[0]
				 || victim->v.absmin[1] > pmax[1] || victim->v.absmax[1] < pmin[1]
				 || victim->v.absmin[2] > pmax[2] || victim->v.absmax[2] < pmin[2])
					continue;
				/* th_die is a QuakeC field, not in entvars_t -- look it up. */
				die = GetEdictFieldValue (victim, "th_die");
				victim->v.health = -999.f;
				pr_global_struct->self = EDICT_TO_PROG (victim);
				if (die && die->function)
					PR_ExecuteProgram (die->function);
			}
			pr_global_struct->self = saved;
		}

		if (vr_teleportfx.value)
		{
			R_TeleportSplash (oldorg);
			R_TeleportSplash (player->v.origin);
		}
		if (vr_teleportsound.value)
			S_LocalSound ("misc/r_tele1.wav");
	}
}

/*
================
IN_SnapTurn -- instant body rotation about the HEAD, not the anchor.

Settle the body under the head first (a full absorb), rotate the absorbed
offset with the body, then yaw. The head's world position solves out
invariant, which is what "the world stays put under you" means; the whole
point of snap over smooth is that there is nothing to interpolate.
================
*/
static void IN_SnapTurn (float degrees)
{
	float rad, c, s, ax, ay;

	IN_AbsorbHeadOffset ();

	rad = degrees * M_PI / 180.f;
	c = cosf (rad);
	s = sinf (rad);
	ax = qr_head_absorbed[0];
	ay = qr_head_absorbed[1];
	qr_head_absorbed[0] = c * ax - s * ay;
	qr_head_absorbed[1] = s * ax + c * ay;

	/* Turn the BODY. cl.viewangles[YAW] (the aim) is recomposed from
	   qr_body_yaw + the hand ray at the end of IN_Move, so it turns too. */
	qr_body_yaw += degrees;
}

/* vr_recenter: current head pose becomes neutral. Absorb what we can so
   the body is under the head, zero the ledger, and bump the generation;
   the renderer captures a correction that zeroes the pose against it and
   echoes the count, unfreezing IN_AbsorbHeadOffset. */
static void IN_Recenter_f (void)
{
	IN_AbsorbHeadOffset ();
	qr_head_absorbed[0] = 0.f;
	qr_head_absorbed[1] = 0.f;
	/* Level the aim too: the body pitch is stick-driven (head supplies the
	   view pitch), so a drifting stick can rack it up to the clamp with no
	   easy way back. Recenter is the recovery -- it puts the shot level. */
	cl.viewangles[PITCH] = 0.f;
	qr_recenter_count++;
}

/* Snap fires crossing the press threshold and rearms below the release
   one; no repeat while held. */
#define QR_SNAP_PRESS	0.65f
#define QR_SNAP_RELEASE	0.30f

static qboolean	qr_snap_armed = true;

void IN_Move (usercmd_t *cmd)
{
	float speed, lx, ly, rx, ry, aim_yaw_rel;

	IN_SnapshotInputs ();

	/* Adopt server-driven angle changes into the body yaw. cl.viewangles
	   [YAW] is written only here (qr_body_yaw + the aim ray) and by the
	   server (spawn, teleport svc_setangle); if it no longer matches what we
	   last wrote, the server moved it and the body must face the new way --
	   the aim re-adds below. Also seeds the body yaw from the spawn angle on
	   the first tick, when qr_expected_yaw is still zero. */
	if (fabsf (cl.viewangles[YAW] - qr_expected_yaw) > 0.01f)
		qr_body_yaw = cl.viewangles[YAW];

	/* Export pin: demo playback rewrites cl.viewangles every frame (the
	   recorded AIM), which the adopt above would take for a teleport and
	   make the body face the gun. The sidecar's body yaw wins instead, so
	   the hand weapon is rebuilt in the frame it was recorded in. */
	if (qr_bodyyaw_override)
		qr_body_yaw = qr_bodyyaw_pinned;

	/* Point-and-blink teleport off the off hand. Runs before the wheel gate
	   and the stick movement so it works whatever else is happening; the
	   consumer only arms it when the off hand makes the teleport gesture. */
	IN_Teleport ();

	/* One source of truth for "the gun is in the hand this tick": the aim
	   feeds a ray AND vr_handaim allows it. The shot, the move compensation,
	   and the weapon anchor (qr_bridge) all read it, so they can't disagree.
	   The hand ray's room-relative yaw is added to the body yaw for the shot,
	   and subtracted from the move pre-rotation so the stick still walks the
	   body while the gun points elsewhere. */
	qr_aim_active = (vr_handaim.value && qr_aim_valid);
	/* vr_aimyaw is the lateral half of the resting-forearm trim, symmetric
	   with vr_aimpitch: the elbow->wrist line sits a little across the body
	   as well as above the sightline. Applied HERE, on the room-relative
	   yaw, so the shot and the move compensation and the weapon anchor all
	   see the same corrected ray -- the single source of truth this block
	   exists to maintain. Positive = aim further right. */
	aim_yaw_rel = qr_aim_active ? (qr_aim_yaw + vr_aimyaw.value) : 0.f;

	/* Choosing a weapon, not moving: sticks go quiet while the wheel is
	   open (stick locomotion through a time-scaled world is a comfort
	   risk). The head-follow absorb below still runs -- physically
	   walking is real motion and stays honoured. */
	if (qr_wheel_open)
	{
		IN_AbsorbHeadOffset ();
		return;
	}

	/* Radial deadzone on the left stick so a diagonal push keeps its
	   direction -- a per-axis deadzone clips the corners and makes
	   diagonals feel unreachable. The right stick stays per-axis: its
	   axes are independent (X snaps, Y pitches). */
	{
		float mag = sqrtf (qr_pad.lx * qr_pad.lx + qr_pad.ly * qr_pad.ly);
		if (mag > QR_STICK_DEADZONE)
		{
			float scale = (mag - QR_STICK_DEADZONE)
				    / ((1.f - QR_STICK_DEADZONE) * mag);
			lx = qr_pad.lx * scale;
			ly = qr_pad.ly * scale;
		}
		else
			lx = ly = 0.f;
	}
	rx = IN_DeadZone (qr_pad.rx);
	ry = IN_DeadZone (qr_pad.ry);

	/* Full speed by DEFAULT. Upstream walks at cl_forwardspeed 200 while the
	   server cap is 320 and strafe is 350, so forward crawls and strafe is
	   already maxed -- asymmetric and sluggish on a single stick. Invert it:
	   run by default, and +speed (the left trigger) becomes a WALK modifier
	   for precision. cl_alwaysrun flips back to upstream walk-by-default. */
	if ((in_speed.state & 1) ^ (cl_alwaysrun.value != 0.f))
		speed = 1.f;
	else
		speed = cl_movespeedkey.value;

	/* Look-relative locomotion: rotate the stick by the head's yaw so
	   "forward" is where you look, not where the body last snapped to.
	   The server applies the usercmd along cl.viewangles[YAW], which is now
	   the AIM (body yaw + hand ray), so ALSO subtract the hand ray here --
	   the two rotations cancel it back to the body and the stick walks the
	   body no matter where the gun points. With no hand aim aim_yaw_rel is
	   zero and this is exactly the M4 look-relative pre-rotation.
	   vr_moverelative 0 drops the head term for body-relative movement. */
	{
		float hy = ((vr_moverelative.value ? qr_head_yaw : 0.f)
			    - aim_yaw_rel) * M_PI / 180.f;
		float c = cosf (hy), s = sinf (hy);
		/* stick as a body-frame vector (X forward, Y left): forward
		   is +X, a right push is -Y */
		float vx = ly, vy = -lx;
		float rxv = vx * c - vy * s;	/* rotate CCW */
		float ryv = vx * s + vy * c;
		cmd->forwardmove += cl_forwardspeed.value * speed * rxv;
		cmd->sidemove += cl_sidespeed.value * speed * (-ryv);
	}

	/* AIM pitch. With a live hand (vr_handaim) the shot pitches along the
	   hand ray -- point down, shoot down. Otherwise the M5 body-anchored
	   feel: head-pitch elevation (vr_headaim), or the right-stick rate
	   control (also the flat debug window, which has no head or hand). */
	if (qr_aim_active)
	{
		V_StopPitchDrift ();
		/* The feeder already emits Quake's sense (positive-DOWN): point the
		   hand down, qr_aim_pitch goes positive, the shot goes down. The gun
		   MODEL takes the opposite sign in qr_bridge (QR_EntityMatrix pitches
		   a world model the other way), so the two are decoupled on purpose.
		   vr_aimpitch trims a resting-forearm bias (positive = aim lower). */
		cl.viewangles[PITCH] = CLAMP (cl_minpitch.value,
					      qr_aim_pitch + vr_aimpitch.value,
					      cl_maxpitch.value);
	}
	else if (vr_headaim.value)
	{
		V_StopPitchDrift ();
		cl.viewangles[PITCH] = CLAMP (cl_minpitch.value, qr_head_pitch,
					      cl_maxpitch.value);
	}
	else if (ry != 0.f)
	{
		V_StopPitchDrift ();
		cl.viewangles[PITCH] -= ry * cl_pitchspeed.value * host_frametime;
		cl.viewangles[PITCH] = CLAMP (cl_minpitch.value,
					      cl.viewangles[PITCH],
					      cl_maxpitch.value);
	}

	/* Turn lock (hands, console open): swallow EVERY turn path -- stick/flick
	   snap, opt-in smooth, and the aim-hand edge turn -- so reaching for a
	   parked console doesn't spin the view. The aim compose below still runs,
	   so you can still point; only body rotation is frozen. Keep rx handling
	   armed-state consistent by simply skipping the whole block. */
	if (!qr_turn_locked)
	{
	/* Right stick X turns the BODY (snap, or smooth for those who opt in). */
	if (vr_smoothturn.value)
	{
		qr_body_yaw -= rx * cl_yawspeed.value * host_frametime;
	}
	else
	{
		if (qr_snap_armed && fabsf (rx) > QR_SNAP_PRESS)
		{
			qr_snap_armed = false;
			IN_SnapTurn ((rx > 0.f ? -1.f : 1.f)
				     * q_max (vr_snapturn.value, 1.f));
		}
		else if (!qr_snap_armed && fabsf (rx) < QR_SNAP_RELEASE)
			qr_snap_armed = true;
	}

	/* Metroid Prime Hunters edge turn: hold the gun AIM past a yaw deadzone to a
	   side and the body follows continuously. aim_yaw_rel is room-relative, so
	   it stays at the edge while the body sweeps under it -- continuous while
	   held, stops when you bring the aim back to centre. Yields to an explicit
	   stick/flick (rx), so a controller's right stick still wins. */
	if (vr_edgeturn.value && qr_aim_active && fabsf (rx) < 0.2f)
	{
		float a = aim_yaw_rel, dz = vr_edgeturn_dz.value;
		if (fabsf (a) > dz)
		{
			float frac = (fabsf (a) - dz) / 40.f;	/* ramp to full over 40 deg */
			if (frac > 1.f) frac = 1.f;
			qr_body_yaw += (a > 0.f ? 1.f : -1.f)
				     * vr_edgeturn_speed.value * frac * (float) host_frametime;
		}
	}
	}

	/* Compose the aim yaw from the (possibly just-turned) body plus the hand
	   ray, and remember it so next frame's adopt-guard can tell a server
	   setangle from our own write. */
	cl.viewangles[YAW] = qr_body_yaw + aim_yaw_rel;
	cl.viewangles[ROLL] = 0.f;
	qr_expected_yaw = cl.viewangles[YAW];

	IN_AbsorbHeadOffset ();
}

/* ========================================================================
 * lifecycle
 * ===================================================================== */

void IN_Init (void)
{
	Cvar_RegisterVariable (&vr_snapturn);
	Cvar_RegisterVariable (&vr_smoothturn);
	Cvar_RegisterVariable (&vr_edgeturn);
	Cvar_RegisterVariable (&vr_edgeturn_dz);
	Cvar_RegisterVariable (&vr_edgeturn_speed);
	Cvar_RegisterVariable (&vr_moverelative);
	Cvar_RegisterVariable (&vr_headaim);
	Cvar_RegisterVariable (&vr_handaim);
	Cvar_RegisterVariable (&vr_aimpitch);
	Cvar_RegisterVariable (&vr_aimyaw);
	Cvar_RegisterVariable (&vr_wheelpitch);
	Cvar_RegisterVariable (&vr_wheelyaw);
	Cvar_RegisterVariable (&vr_wheelroll);
	Cvar_RegisterVariable (&vr_wheelradius);
	Cvar_RegisterVariable (&vr_wheelfwd);
	Cvar_RegisterVariable (&vr_wheelup);
	Cvar_RegisterVariable (&vr_wheelside);
	Cvar_RegisterVariable (&vr_wheelclip);
	Cvar_RegisterVariable (&vr_laser);
	Cvar_RegisterVariable (&vr_reticle);
	Cvar_RegisterVariable (&vr_reticlestyle);
	Cvar_RegisterVariable (&vr_reticlecolor);
	Cvar_RegisterVariable (&vr_reticle_arcs);
	Cvar_RegisterVariable (&vr_lasercolor);
	Cvar_RegisterVariable (&vr_teleport);
	Cvar_RegisterVariable (&vr_teleportcolor);
	Cvar_RegisterVariable (&vr_teleportsound);
	Cvar_RegisterVariable (&vr_teleportfx);
	Cvar_RegisterVariable (&vr_telefrag);
	Cvar_RegisterVariable (&vr_weapongrip);
	Cvar_RegisterVariable (&vr_weaponback);
	Cvar_RegisterVariable (&vr_weaponup);
	Cvar_RegisterVariable (&vr_weaponside);
	Cvar_RegisterVariable (&vr_weaponclip);
	Cvar_RegisterVariable (&vr_weaponclipback);
	Cvar_RegisterVariable (&vr_weapontint);
	Cvar_RegisterVariable (&vr_pathdebug);
	Cvar_RegisterVariable (&vr_projdebug);
	Cvar_RegisterVariable (&vr_projhand);
	Cvar_RegisterVariable (&vr_laserforward);
	Cvar_RegisterVariable (&vr_laserup);
	Cvar_RegisterVariable (&vr_laserside);
	Cvar_RegisterVariable (&vr_laserpitch);
	Cvar_RegisterVariable (&vr_laseryaw);
	Cvar_RegisterVariable (&vr_slowmo);
	Cvar_RegisterVariable (&vr_fullmenu);
	Cvar_RegisterVariable (&vr_lean_limit);
	Cvar_RegisterVariable (&wheel_timescale);
	Cmd_AddCommand ("vr_recenter", IN_Recenter_f);
	Admin_Init ();
	Cmd_AddCommand ("+wheel", IN_WheelDown_f);
	Cmd_AddCommand ("-wheel", IN_WheelUp_f);

	/* Gameplay defaults for the controller keys. Queued before quake.rc
	   executes, so config.cfg and autoexec.cfg can rebind them. */
	Cbuf_AddText (
		"bind ABUTTON +jump\n"
		"bind BBUTTON +use\n"
		"bind XBUTTON \"impulse 12\"\n"
		"bind YBUTTON \"impulse 10\"\n"
		"bind LSHOULDER \"impulse 12\"\n"
		"bind RSHOULDER \"impulse 10\"\n"
		"bind RTRIGGER +attack\n"
		"bind LTRIGGER +speed\n"
		"bind LTHUMB +movedown\n"	/* hands crouch (thumb+pinky) */
		"bind RTHUMB vr_recenter\n");
}

void IN_Shutdown (void)
{
}

void IN_MouseMotion (int dx, int dy)
{
	(void) dx;
	(void) dy;
}

void IN_SendKeyEvents (void)
{
	/* Key events originate in IN_Commands' snapshot diff; there is no
	   separate event queue to pump. */
}

void IN_UpdateInputMode (void)
{
}

void IN_ClearStates (void)
{
	memset (&qr_pad_prev, 0, sizeof(qr_pad_prev));
	qr_lt_down = qr_rt_down = false;
}

void IN_Activate (void)
{
}

void IN_Deactivate (qboolean free_cursor)
{
	(void) free_cursor;
}
