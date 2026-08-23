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
static uint32_t			qc_head_ack;		/* recenter echo */
static int			qc_wheel_open_shared;
static int			qc_wheel_anchor_shared;
static float			qc_wheel_pos_shared[3];
static int			qc_wheel_highlight_shared;
static float			qc_head_yaw_shared;
static float			qc_head_pitch_shared;
static int			qc_slowmo_shared;	/* raw L3 button */
static float			qc_height_trim_shared;
static int			qc_aim_valid_shared;	/* dominant-hand aim live? */
static float			qc_aim_org_shared[3];	/* body frame fwd,right,up */
static float			qc_aim_yaw_shared;	/* room-relative, Quake deg */
static float			qc_aim_pitch_shared;

void QC_InputSetGamepad (const qc_gamepad_state_t *state)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_pad_shared = *state;
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

static int			qr_slowmo_raw;		/* drained L3 button */
static int			qr_slowmo_active;	/* toggled bullet-time */
static uint32_t			qr_head_ack_seen;

static cvar_t	vr_snapturn = {"vr_snapturn", "45", CVAR_ARCHIVE};
static cvar_t	vr_smoothturn = {"vr_smoothturn", "0", CVAR_ARCHIVE};
static cvar_t	vr_moverelative = {"vr_moverelative", "1", CVAR_ARCHIVE};
static cvar_t	vr_headaim = {"vr_headaim", "1", CVAR_ARCHIVE};
/* M6: aim from the dominant hand/controller ray. 1 = the gun lives in your
   hand and shots go where you point; 0 = body-anchored aim (the M5 feel,
   head-pitch elevation) -- the A/B for judging feel, one cvar to flip. */
static cvar_t	vr_handaim = {"vr_handaim", "1", CVAR_ARCHIVE};
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

static void IN_SnapshotInputs (void)
{
	pthread_mutex_lock (&qc_input_lock);
	qr_pad = qc_pad_shared;
	qr_head[0] = qc_head_shared[0];
	qr_head[1] = qc_head_shared[1];
	qr_head[2] = qc_head_shared[2];
	qr_head_yaw = qc_head_yaw_shared;
	qr_head_pitch = qc_head_pitch_shared;
	qr_slowmo_raw = qc_slowmo_shared;
	qr_aim_valid = qc_aim_valid_shared;
	qr_aim_org[0] = qc_aim_org_shared[0];
	qr_aim_org[1] = qc_aim_org_shared[1];
	qr_aim_org[2] = qc_aim_org_shared[2];
	qr_aim_yaw = qc_aim_yaw_shared;
	qr_aim_pitch = qc_aim_pitch_shared;
	qr_head_ack_seen = qc_head_ack;
	qr_wheel_open = qc_wheel_open_shared || qr_wheel_console_open;
	qr_wheel_has_anchor = qc_wheel_anchor_shared;
	qr_wheel_anchor[0] = qc_wheel_pos_shared[0];
	qr_wheel_anchor[1] = qc_wheel_pos_shared[1];
	qr_wheel_anchor[2] = qc_wheel_pos_shared[2];
	qr_wheel_highlight = qc_wheel_highlight_shared;
	qr_height_trim = qc_height_trim_shared;
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

	/* One source of truth for "the gun is in the hand this tick": the aim
	   feeds a ray AND vr_handaim allows it. The shot, the move compensation,
	   and the weapon anchor (qr_bridge) all read it, so they can't disagree.
	   The hand ray's room-relative yaw is added to the body yaw for the shot,
	   and subtracted from the move pre-rotation so the stick still walks the
	   body while the gun points elsewhere. */
	qr_aim_active = (vr_handaim.value && qr_aim_valid);
	aim_yaw_rel = qr_aim_active ? qr_aim_yaw : 0.f;

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
		/* Negate: the fed ray pitch is +up in the tracking frame, Quake pitch
		   is positive-DOWN. Point the hand down and the shot goes down. */
		cl.viewangles[PITCH] = CLAMP (cl_minpitch.value, -qr_aim_pitch,
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
	Cvar_RegisterVariable (&vr_moverelative);
	Cvar_RegisterVariable (&vr_headaim);
	Cvar_RegisterVariable (&vr_handaim);
	Cvar_RegisterVariable (&vr_slowmo);
	Cvar_RegisterVariable (&vr_fullmenu);
	Cvar_RegisterVariable (&vr_lean_limit);
	Cvar_RegisterVariable (&wheel_timescale);
	Cmd_AddCommand ("vr_recenter", IN_Recenter_f);
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
