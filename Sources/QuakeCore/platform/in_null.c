/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
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
#include "grapple_avp.h"
#include "align_math.h"
/* The weapon rows: the drain turns a released ring slot into a selection and
   the row is the only place the impulse and the selection kind live. */
#include "qr_weapons.h"

#include <pthread.h>

/* defined in cl_main.c; upstream externs them file-locally in cl_input.c */
extern cvar_t cl_maxpitch, cl_minpitch;
/* defined in host.c; no header declares it */
extern cvar_t host_timescale;
extern cvar_t phase;		/* the melt, r_null.c -- room alignment rides its edge */

/* ========================================================================
 * any-thread producers
 * ===================================================================== */

static pthread_mutex_t		qc_input_lock = PTHREAD_MUTEX_INITIALIZER;
static qc_gamepad_state_t	qc_pad_shared;
static float			qc_head_shared[3];	/* fwd, right, up */
/* Gun placement, one entry per weapon IDENTITY rather than per ring slot, so
   one tuned shotgun serves every game that draws the shotgun's model. Written
   by the UI from any thread, read on the engine thread by QR_WeaponPlacement
   while the renderer builds the frame -- so a weapon switch needs no console
   round trip and cannot be left stale by a dropped command. See
   QC_SetWeaponPlacement in QuakeCore.h. */
static pthread_mutex_t		qc_place_lock = PTHREAD_MUTEX_INITIALIZER;
static qc_weapon_placement_t	qc_place_shared[QC_WEAPON_SLOTS];

/* Room walls, same idiom: whole table under a lock, replaced outright. */
static pthread_mutex_t		qc_walls_lock = PTHREAD_MUTEX_INITIALIZER;
static qc_wall_dir_t		qc_walls_shared[QC_MAX_WALL_DIRS];
static int			qc_walls_count_shared;

/* The measured floor's boundary, same idiom again. */
static pthread_mutex_t		qc_floor_lock = PTHREAD_MUTEX_INITIALIZER;
static qc_floor_bounds_t	qc_floor_shared;
static int			qc_floor_valid_shared;
static uint32_t			qc_head_ack;		/* recenter echo */
static int			qc_wheel_open_shared;
static int			qc_wheel_anchor_shared;
static float			qc_wheel_pos_shared[3];
static int			qc_wheel_highlight_shared;
/* The consumer's CLOSING edge, latched with the highlight it held at that
   instant, and drained in IN_Commands -- the same idiom and the same reason
   as qc_tp_commit_shared. The wheel can be opened and let go again entirely
   between two drains, and a drain that only sampled qc_wheel_open_shared
   would read it closed both times and commit nothing. The selection this
   replaces was made synchronously by the consumer and could not miss. */
static int			qc_wheel_release_shared;
static int			qc_wheel_release_hl_shared = -1;
static float			qc_head_yaw_shared;
static float			qc_head_pitch_shared;
static int			qc_paused_shared;	/* console pause request */
static int			qc_slowmo_shared;	/* raw L3 button */
static float			qc_height_trim_shared;
static int			qc_aim_valid_shared;	/* dominant-hand aim live? */
static float			qc_aim_org_shared[3];	/* body frame fwd,right,up */
static float			qc_aim_yaw_shared;	/* room-relative, Quake deg */
static float			qc_aim_pitch_shared;
/* The OFF hand's POSITION, same form and same lock. The grapple leaves this
   hand, which is what lets the gun stay drawn and firing through a swing.

   Position only, and no ray: the rope is AIMED by the reticle, like every
   other shot. Taking the direction from this hand as well was the first
   version of the feature and it was wrong in the headset -- a Sense
   controller held in a natural grip points its forward axis roughly upward,
   so the rope fired at the sky and could not be aimed at the floor. The hand
   that holds the rope is not the hand that points it. A yaw and pitch were
   dropped from this channel rather than left unread, because this file has
   three comments elsewhere promising a ray that nothing consumes and that is
   exactly the sentence a later change trusts.

   A channel of its own rather than the teleport org/yaw/pitch fields below,
   which were named for this: those are live plumbing for the teleport commit,
   and a feature that reads half of a struct another feature writes is a
   coupling this file has already paid for once. */
static int			qc_offhand_valid_shared;
static float			qc_offhand_org_shared[3];/* body frame fwd,right,up */
/* Teleport: the OFF hand arms a destination (same body-frame ray form as the
   aim). `commit` is latched here and drained engine-side so a release edge
   between ticks is never lost. */
static int			qc_tp_active_shared;	/* off-hand aiming a teleport */
static int			qc_tp_commit_shared;	/* release -> do the jump */
static float			qc_tp_org_shared[3];	/* body frame fwd,right,up */
static float			qc_tp_yaw_shared;	/* room-relative, Quake deg */
static float			qc_tp_pitch_shared;

/* UI turn hold: set while a hand reaching across for a UI interaction (the
   wrist communicator) must not also edge-turn the body. See QC_InputSetTurnHold
   in QuakeCore.h. */
static int			qc_turn_hold_shared;

/* One-shot recenter request from the renderer (a rebuilt ARKit world-tracking
   provider). Drained in IN_Commands, NOT in IN_SnapshotInputs -- that runs
   from both IN_Commands and IN_Move, and the second call would swallow the
   latch before the first acted on it, the same trap qc_tp_commit_shared
   documents. See QC_InputRequestRecenter in QuakeCore.h. */
static int			qc_recenter_req_shared;

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
	/* The pin assigns qr_body_yaw directly, so it is the one deliberate
	   heading that does NOT pass IN_SnapTurn's finite guard -- and its value
	   comes off disk, from a .vrtrack the user can replace, decoded with
	   Float(bitPattern:) that validates nothing. A non-finite yaw here is
	   the unrecoverable case: IN_Move's adopt guard compares against what it
	   last wrote, a NaN fails that compare forever, and no spawn, teleport or
	   recenter gets the view back. Refuse it at the door instead. */
	if (override && !isfinite (yaw_deg))
		return;

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

void QC_InputRequestRecenter (void)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_recenter_req_shared = 1;
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

void QC_SetRoomWalls (const qc_wall_dir_t *dirs, int count)
{
	if (count < 0)
		count = 0;
	if (count > QC_MAX_WALL_DIRS)
		count = QC_MAX_WALL_DIRS;
	pthread_mutex_lock (&qc_walls_lock);
	if (dirs && count > 0)
		memcpy (qc_walls_shared, dirs, count * sizeof (qc_wall_dir_t));
	qc_walls_count_shared = dirs ? count : 0;
	pthread_mutex_unlock (&qc_walls_lock);
}

void QC_SetFloorBounds (const qc_floor_bounds_t *bounds)
{
	pthread_mutex_lock (&qc_floor_lock);
	if (bounds)
		qc_floor_shared = *bounds;
	qc_floor_valid_shared = bounds ? 1 : 0;
	pthread_mutex_unlock (&qc_floor_lock);
}

/* Engine thread. Copy under the lock into the caller's local, the mirror
   of the setter above. */
int QR_FloorBounds (qc_floor_bounds_t *out)
{
	int valid;

	pthread_mutex_lock (&qc_floor_lock);
	valid = qc_floor_valid_shared;
	if (valid)
		*out = qc_floor_shared;
	pthread_mutex_unlock (&qc_floor_lock);
	return valid;
}

void QC_SetWeaponPlacement (const qc_weapon_placement_t *slots, int count)
{
	int	n;

	if (!slots)
		return;

	n = count < 0 ? 0 : count;
	if (n > QC_WEAPON_SLOTS)
		n = QC_WEAPON_SLOTS;

	pthread_mutex_lock (&qc_place_lock);
	/* The caller's count, never sizeof qc_place_shared: sizing the copy off
	   the DESTINATION reads past the end of a shorter caller's array, which
	   is latent only while the two widths agree. Zeroing the tail rather
	   than leaving it is what makes a short publish correct, since custom
	   == 0 already means "never tuned, use the cvars". */
	memcpy (qc_place_shared, slots, (size_t) n * sizeof *slots);
	if (n < QC_WEAPON_SLOTS)
		memset (qc_place_shared + n, 0,
			(size_t) (QC_WEAPON_SLOTS - n) * sizeof *qc_place_shared);
	pthread_mutex_unlock (&qc_place_lock);
}

/*
================
QR_WeaponPlacement -- the drawn gun's own placement, or 0 if it has none.

Engine thread, called while the renderer places the view weapon, keyed on the
identity of the model it is drawing. Returns 0 for a weapon the UI never
tuned, and the caller uses the vr_weapon* cvars -- still the global setting,
and still what the console sets.
================
*/
int QR_WeaponPlacement (int identity, float *back, float *up, float *side)
{
	qc_weapon_placement_t	p;

	if (identity < 0 || identity >= QC_WEAPON_SLOTS)
		return 0;

	pthread_mutex_lock (&qc_place_lock);
	p = qc_place_shared[identity];
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

void QC_InputSetOffHand (int valid, float org_fwd, float org_right,
			 float org_up)
{
	/* Non-finite in, nothing out. This origin becomes the hook's spawn
	   point and the rope's near end, and a NaN there reaches a trace and
	   then the swing's rest length, which never recovers from one.
	   QC_ExportSetBodyYaw refuses the same way, for the same reason.

	   Refused as NOT LIVE rather than by returning early, which is the one
	   departure from that idiom: a bare return latches the last good pose,
	   so a fault that keeps producing NaN would hold the rope at a point
	   the hand has left -- the stuck-then-snap the dominant aim path had
	   until the lost-ray release landed. Dropping to invalid degrades to
	   the documented fallback (the gun hand, then the body) instead. */
	if (valid && (!isfinite (org_fwd) || !isfinite (org_right)
		      || !isfinite (org_up)))
		valid = 0;

	pthread_mutex_lock (&qc_input_lock);
	qc_offhand_valid_shared = valid ? 1 : 0;
	if (valid)
	{
		qc_offhand_org_shared[0] = org_fwd;
		qc_offhand_org_shared[1] = org_right;
		qc_offhand_org_shared[2] = org_up;
	}
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

/* Hold the aim-hand EDGE TURN (vr_edgeturn, below) without touching
   movement, aim, fire, or the smooth/snap turn paths Swift already holds
   itself -- see IN_Move's turn-lock block. Any thread; staged and drained
   like every other setter here. */
void QC_InputSetTurnHold (int hold)
{
	pthread_mutex_lock (&qc_input_lock);
	qc_turn_hold_shared = hold ? 1 : 0;
	pthread_mutex_unlock (&qc_input_lock);
}

void QC_InputSetWheel (int open, int has_anchor,
		       float fwd, float right, float up, int highlight)
{
	pthread_mutex_lock (&qc_input_lock);
	/* Latch the release here, where the highlight that goes with it is still
	   the one the hand had: see qc_wheel_release_shared. */
	if (qc_wheel_open_shared && !open)
	{
		qc_wheel_release_shared = 1;
		qc_wheel_release_hl_shared = highlight;
	}
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
/* The off hand, engine-thread. Read outside this file (grapple_avp.c throws
   from there), so not static, exactly as qr_aim_org and qr_aim_active are
   not. */
float				qr_offhand_org[3];	/* off hand, body frame */
int				qr_offhand_active;	/* live (vr_handaim && valid) */
static int			qr_offhand_valid;
/* Drained from qc_turn_hold_shared; gates the edge-turn block only (see
   QC_InputSetTurnHold). */
static int			qr_turn_hold;
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
static int			qr_slowmo_active;	/* toggled bullet-time */
static uint32_t			qr_head_ack_seen;

static cvar_t	vr_snapturn = {"vr_snapturn", "45", CVAR_ARCHIVE};
/* Smooth turning is the default now. Hands (controllerless) are forced smooth
   by the Swift side (snap isn't offered there); a controller can still pick
   snap from the Comfort picker. */
static cvar_t	vr_smoothturn = {"vr_smoothturn", "1", CVAR_ARCHIVE};
/* Metroid Prime Hunters edge turn: aim the gun past a yaw DEADZONE (deg) to a
   side and the body follows at up to SPEED (deg/s), ramping over the 40deg past
   the deadzone. The aim yaw is room-relative so it stays at the edge while the
   body sweeps -- continuous while held. */
static cvar_t	vr_edgeturn = {"vr_edgeturn", "1", CVAR_ARCHIVE};
static cvar_t	vr_edgeturn_dz = {"vr_edgeturn_dz", "18", CVAR_ARCHIVE};
static cvar_t	vr_edgeturn_speed = {"vr_edgeturn_speed", "90", CVAR_ARCHIVE};
/* Measure the edge-turn gesture from where the player is FACING rather
   than from the room. 0 restores the room-relative reading, which spins
   forever the moment you turn your real body. See IN_Move. */
static cvar_t	vr_edgeturn_head = {"vr_edgeturn_head", "1", CVAR_ARCHIVE};
/* Freeze body turning while the sim is paused (i.e. the console is up). The
   summon pauses the game and head tracking keeps running, so the aim-hand edge
   turn would otherwise whip the view as you reach for a parked console. Default
   on (turning frozen while paused); set 1 to allow turning with the console
   open. */
static cvar_t	vr_turn_while_paused = {"vr_turn_while_paused", "0", CVAR_ARCHIVE};
static cvar_t	vr_moverelative = {"vr_moverelative", "1", CVAR_ARCHIVE};
/* Movement speed, ONE KNOB PER INPUT, because the two inputs do not express
   the same thing. A thumbstick is proportional, so a player modulates speed
   with their thumb; hands drive the move with pinches, which are binary, full
   deflection or nothing. At a shared top speed the hands read as having no
   control rather than as being fast, and the only way to give that control
   back is to lower what full deflection asks for.

   The hands default started measured and was then tuned by play. A. found
   0.5 by accident (a controller set down on its trigger latched +speed, the
   walk modifier, through the detach bug fixed in 5ee1506), liked it enough to
   ask for it, then played it and called it a little slow, so it is 0.75: 300
   out of the 400 a run requests. Both numbers are his, and the second one
   wins because it came from playing rather than from noticing.

   Note the ratio is not what the slider says. sv_maxspeed caps the request at
   320, so 0.75 asks for 300 and 1.0 asks for 400 but delivers 320: the felt
   difference between the ends of the knob is 300 against 320, not 300
   against 400. Anything below about 0.8 is the only part of the range that
   does much, which is worth knowing before tuning it again.

   The stick defaults to 1, untouched: A. calls its tuning perfect. It gets a
   knob anyway so the two are adjustable independently, and so nothing about
   this split is special-cased for one input. 1 is the ceiling for both,
   because full deflection already asks for more than sv_maxspeed allows and a
   value above 1 would silently do nothing.

   Which knob applies is decided by qr_pad.connected, this file's idiom for "a
   real spatial controller, not bare hands publishing pad state"
   (QuakeCore.h), and the field the edge turn already gates on. */
static cvar_t	vr_movescale_hands = {"vr_movescale_hands", "0.75", CVAR_ARCHIVE};
static cvar_t	vr_movescale_pad = {"vr_movescale_pad", "1", CVAR_ARCHIVE};
static cvar_t	vr_headaim = {"vr_headaim", "1", CVAR_ARCHIVE};
/* M6: aim from the dominant hand/controller ray. 1 = the gun lives in your
   hand and shots go where you point; 0 = body-anchored aim (the M5 feel,
   head-pitch elevation) -- the A/B for judging feel, one cvar to flip. */
static cvar_t	vr_handaim = {"vr_handaim", "1", CVAR_ARCHIVE};
/* THE RIG CVARS BELOW ARE CVAR_NONE ON PURPOSE, AND IT IS NOT AN OVERSIGHT.
   Everything from here to vr_weaponclipback describes the PLAYER -- where his
   forearm points, where he wants the ring, how his gun sits in his hand -- and
   the persistent store for all of it is the input profile on the Swift side,
   which keeps one set per input (hands, controllers) and pushes the whole rig
   through ProfileStore.applyRig once the engine reports running.

   CVAR_ARCHIVE would give each of them a SECOND store, and not one store per
   player but one per GAME: Host_WriteConfiguration writes config.cfg into
   com_gamedir, so every installed pack keeps its own frozen copy, and a `game`
   switch re-execs that pack's chain and overwrites the profile with whatever
   was live the last time that directory happened to be archived. It cannot be
   papered over by re-pushing after the switch, either: COM_Game_f appends
   `exec quake.rc` while Cmd_Exec_f INSERTS the file at the front of the
   buffer, so a push queued beside the `game` command runs BEFORE the config
   and loses. Queued first means run last here (the same ordering that makes
   this file's bind block outrank a player's rebinds).

   It is not hypothetical. Six packs on one headset held eleven of these at two
   different values: id1 and rogue carried the CONTROLLER profile's numbers and
   the other four the hands profile's, so playing bare hands in those two games
   aimed the gun 26 degrees high, swung it 29 degrees across, and tilted the
   weapon ring onto a plane the Swift-side selection math no longer agreed
   with. Nobody saw it for a year because the file is only re-read on a `game`
   switch, and a normal session never switches.

   What this costs: a value typed at the console is now session-only. That is
   the right trade, because the console is the TUNING path and the Weapon,
   Laser and Comfort tabs are the one that persists -- and because a knob that
   survived a restart but not a game switch was never really persistent. */
/* M6: THE pitch trim for the hand aim, degrees, positive = aim LOWER. Corrects
   a systematic high/low bias from how the forearm rests when pointing; applies
   to the shot and the gun model together. Tune live against the laser.
   The default carries the 8 degrees that used to be a second, hidden constant
   in HandInput.feedAim -- one visible number rather than two stacked knobs. */
static cvar_t	vr_aimpitch = {"vr_aimpitch", "8", CVAR_NONE};
/* The lateral half of the same trim, degrees, positive = aim further RIGHT.
   Pitch alone could correct "shoots high" but not "shoots left", which a
   forearm-only aim needs: the elbow->wrist line points slightly across the
   body. Default 0 -- the bias is per-person, unlike the vertical one. */
static cvar_t	vr_aimyaw = {"vr_aimyaw", "0", CVAR_NONE};
/* M6: a laser line from the muzzle down the aim, an aiming aid. Read by
   qr_bridge; non-static so it externs cleanly like the other vr_ cvars. */
/* Weapon-wheel ring plane, degrees off the body basis, and a scale on its
   radius. Pitch/yaw/roll tilt the plane the weapons ring in; the selection
   math in WheelState.swift applies the IDENTICAL rotation to its own axes, so
   these three numbers are a shared contract -- change the meaning here and the
   highlight points at a different weapon than the one under your hand. The
   radius scale is safe to change alone: selection is angle-only. */
cvar_t		vr_wheelpitch  = {"vr_wheelpitch",  "0", CVAR_NONE};
cvar_t		vr_wheelyaw    = {"vr_wheelyaw",    "0", CVAR_NONE};
cvar_t		vr_wheelroll   = {"vr_wheelroll",   "0", CVAR_NONE};
cvar_t		vr_wheelradius = {"vr_wheelradius", "1", CVAR_NONE};
/* Print the weapon table whenever the owned set changes. Off by default: it is
   a measuring tool, not a diagnostic. It exists because the window pauses the
   simulation while it is open, so nobody can grant weapons and read the result
   back without closing the console in between, and a script cannot do it at
   all. With this on, switching game and letting the world run prints the table
   by itself. */
cvar_t		vr_weapontrace = {"vr_weapontrace", "0", CVAR_ARCHIVE};
/* Front keep-fraction for a VIEW model on the ring, muzzle end. Default 1,
   meaning no trim, because an earlier pass trimmed the front globally and
   chopped the barrels to stubs. It exists because the packs made the problem
   unavoidable: rogue ships no pickup models at all, so every one of its
   weapons hangs its v_ model on the ring complete with the muzzle flash and
   projectile polys that model bakes in, where vanilla mostly shows clean g_
   models instead. Tune it on device and bake the value that works. */
cvar_t		vr_wheelclipfront = {"vr_wheelclipfront", "1", CVAR_ARCHIVE};
/* Rear keep-fraction for the PACKS' weapons on the ring, separate from
   vanilla's vr_wheelclip. They need their own because the two are being asked
   for different things at the same depth: vanilla's 0.79 takes the baked round
   out of a shotgun, and at 0.79 rogue's models lose their grips, triggers and
   handles with it. Higher keeps more of the gun. Tune until the floating
   projectile quad is gone and the handle is still there, then bake the number
   here. */
cvar_t		vr_wheelclippack = {"vr_wheelclippack", "0.88", CVAR_ARCHIVE};
cvar_t		vr_wheelfwd  = {"vr_wheelfwd",  "0", CVAR_NONE};
cvar_t		vr_wheelup   = {"vr_wheelup",   "0", CVAR_NONE};
cvar_t		vr_wheelside = {"vr_wheelside", "0", CVAR_NONE};
/* Rear keep-fraction for a WHEEL model that fell back to the viewmodel (1 =
   whole model). Those bake a loaded round near the GRIP -- same place the hand
   weapon's vr_weaponclipback (0.79) trims -- so the wheel retracts the rear the
   same way. Clean pickup models, the axe and the lightning gun are never
   trimmed (see QR_EmitWheel). */
cvar_t		vr_wheelclip = {"vr_wheelclip", "0.79", CVAR_NONE};
cvar_t		vr_laser = {"vr_laser", "0", CVAR_NONE};
cvar_t		vr_reticle = {"vr_reticle", "0", CVAR_NONE};
/* Reticle shape (0 cross, 1 circle+dot, 2 dot, 3 circle, 4 cross+dot) and the
   colour indices into the shared palette for the reticle and the laser (see
   QR_VrColor in qr_bridge.c). Laser defaults to red, reticle to amber. */
cvar_t		vr_reticlestyle = {"vr_reticlestyle", "0", CVAR_NONE};
cvar_t		vr_reticlecolor = {"vr_reticlecolor", "3", CVAR_NONE};
/* HL2-style curved gauges flanking the reticle: health left, ammo right.
   Independent of vr_reticle/vr_reticlestyle -- on with any reticle shape, or
   standalone with no shape at all. */
cvar_t		vr_reticle_arcs = {"vr_reticle_arcs", "0", CVAR_NONE};
cvar_t		vr_lasercolor   = {"vr_lasercolor",   "0", CVAR_NONE};
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
cvar_t		vr_weapongrip = {"vr_weapongrip", "0.15", CVAR_NONE};
/* M6: live positional nudge of the hand weapon, Quake units, along the AIM
   axes -- back = toward the player, up = raise, side = to the player's right.
   Default 0; tune in the headset so placement never needs a recompile. */
cvar_t		vr_weaponback = {"vr_weaponback", "0", CVAR_NONE};
cvar_t		vr_weaponup   = {"vr_weaponup",   "0", CVAR_NONE};
cvar_t		vr_weaponside = {"vr_weaponside", "0", CVAR_NONE};
/* M6: how much of the hand weapon to KEEP, from each end (1 = whole model,
   lower retracts baked-in geometry -- a nail out the barrel, or a round behind
   the receiver). vr_weaponclip trims the BARREL end, vr_weaponclipback the
   ARM end. Manual, because projectile-vs-gun can't be told from geometry. */
cvar_t		vr_weaponclip     = {"vr_weaponclip",     "1", CVAR_NONE};
/* 0.79 default: the view models bake a round/nail into the rear ~21% of the
   model (near the hand); clipping it there clears it on every weapon (found
   on device). Barrel end is left whole. */
cvar_t		vr_weaponclipback = {"vr_weaponclipback", "0.79", CVAR_NONE};
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
cvar_t		vr_laserforward = {"vr_laserforward", "0", CVAR_NONE};
cvar_t		vr_laserup      = {"vr_laserup",      "0", CVAR_NONE};
cvar_t		vr_laserside    = {"vr_laserside",    "0", CVAR_NONE};
/* M6: laser beam TILT, degrees, off the shot direction so the beam lines up
   with the barrel visually. pitch positive = tilt down, yaw positive = left.
   NB this makes the beam diverge slightly from the true bullet path -- a
   visual-alignment nudge, keep it small. */
cvar_t		vr_laserpitch   = {"vr_laserpitch",   "0", CVAR_NONE};
cvar_t		vr_laseryaw     = {"vr_laseryaw",     "0", CVAR_NONE};
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
	qr_aim_valid = qc_aim_valid_shared;
	qr_aim_org[0] = qc_aim_org_shared[0];
	qr_aim_org[1] = qc_aim_org_shared[1];
	qr_aim_org[2] = qc_aim_org_shared[2];
	qr_aim_yaw = qc_aim_yaw_shared;
	qr_aim_pitch = qc_aim_pitch_shared;
	qr_offhand_valid = qc_offhand_valid_shared;
	qr_offhand_org[0] = qc_offhand_org_shared[0];
	qr_offhand_org[1] = qc_offhand_org_shared[1];
	qr_offhand_org[2] = qc_offhand_org_shared[2];
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
	qr_turn_hold = qc_turn_hold_shared;
	pthread_mutex_unlock (&qc_input_lock);
}

/*
================
IN_TurnFrametime -- the dt a TURN integrates, which is real time even while
the world is in slow motion.

Turning is a CONTROL, not part of the scene. host_timescale multiplies
host_frametime (host.c:592-593) so the simulation crawls, and every
continuous turn path integrated that same number, so bullet time turned the
player at a fifth speed along with the monsters. A. ruled that the world
slowing down is the point and his ability to reorient slowing with it is not.

The scale is divided back out rather than switching to `realtime`, for two
reasons. It recovers exactly the `realtime - oldrealtime` that host.c
multiplied, so at timescale 0 this returns host_frametime unchanged and the
feel at full speed is bit-identical. And host_frametime stays the single
input, so a unit test can still drive a turn by setting it; keying off
`realtime` would have made every existing turn assertion unreachable without
advancing a clock the harness does not own.

Clamped at 0.1 s because the timescale branch in Host_FilterTime SKIPS the
clamp the ordinary path applies, and an unclamped long frame recovered after
a hitch is a whip of the whole view.
================
*/
static double IN_TurnFrametime (void)
{
	double	dt = host_frametime;

	if (host_timescale.value > 0.f)
		dt /= host_timescale.value;
	if (dt > 0.1)
		dt = 0.1;
	return dt;
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

/* ========================================================================
 * the weapon wheel's selection
 * ===================================================================== */

/* A selection the player has made and the engine has not yet arrived at:
   the identity being cycled toward, and how many more cycle steps may be
   spent reaching it. The bound is what stops a weapon the cycle cannot
   reach from spinning forever, which with the ring already closed would be
   an invisible loop. */
static int	qr_wheel_target = -1;
static int	qr_wheel_tries;

static int IN_WheelOwnedCount (void)
{
	uint32_t	owned = QR_OwnedIdentities ();
	int		i, n = 0;

	for (i = 0; i < QC_WEAPON_IDENTITIES; i++)
		if (owned & (1u << i))
			n++;
	return n;
}

/* The identity drawn at ring index `index`, or -1 if the ring is shorter
   than that.

   ASCENDING IDENTITY order, which is the order the frame build's own two
   walks of this mask use -- the owned count and the emit loop. It is a
   shared contract, not a detail: walk it any other way and the slot the
   player let go on names a different weapon than the ring drew under it.

   The MASK, never cl.items. The mask is the bit AND a resolved model; a
   weapon whose model is missing is counted by cl.items but is not on the
   ring, and from that row down a walk of the raw bits fires at the pick's
   neighbour. */
static int IN_WheelIdentityForIndex (int index)
{
	uint32_t	owned = QR_OwnedIdentities ();
	int		i, seen = 0;

	if (index < 0)
		return -1;
	for (i = 0; i < QC_WEAPON_IDENTITIES; i++)
	{
		if (!(owned & (1u << i)))
			continue;
		if (seen == index)
			return i;
		seen++;
	}
	return -1;
}

/* Issue the selection for a released ring slot. */
static void IN_WheelSelect (int index)
{
	const qr_weapon_entry_t	*ent;
	int			identity = IN_WheelIdentityForIndex (index);

	qr_wheel_target = -1;		/* a new pick abandons an unfinished one */

	if (identity < 0)
		return;
	ent = QR_WeaponEntry (identity);
	if (!ent)
		return;

	/* UNMEASURED, and that is the whole of what a zero here says: the kind
	   beside it is the struct's zero value and carries no claim either, so
	   neither column may be acted on. Name what was picked and send
	   nothing. A guessed number hands the player the wrong gun, and
	   impulse 9 is `give all`. */
	if (!ent->impulse)
	{
		QR_QuietPrintf ("%s: impulse not measured yet, not selected\n",
			    QR_WeaponLabel (identity));
		return;
	}

	if (ent->kind == QR_SELECT_DIRECT)
	{
		Cbuf_AddText (va ("impulse %d\n", (int) ent->impulse));
		return;
	}

	/* A toggle is NOT a selector: its number is shared with another weapon,
	   so sending it from the wrong one hands you that other weapon. Cycle
	   instead, and stop when the drawn view model says we arrived -- which
	   is checkable only because the target is an identity. The cycle is
	   upstream's impulse 10 rather than the entry's own number, for the same
	   reason: the entry's number is the shared one. */
	qr_wheel_target = identity;
	qr_wheel_tries = IN_WheelOwnedCount ();
}

/* One cycle step per drain, re-checked against the weapon actually drawn.
   Called every IN_Commands so a pick that needs several steps finishes
   whether or not the ring is still open. */
static void IN_WheelCycle (void)
{
	if (qr_wheel_target < 0)
		return;

	/* Arrived. Checked before anything is spent, so a target the player
	   already holds costs no impulse at all. */
	if (QR_ActiveIdentity () == qr_wheel_target)
	{
		qr_wheel_target = -1;
		return;
	}

	/* Spend nothing while the world is stopped. The window pauses the
	   simulation whenever the console is open, so an impulse sent now is
	   never processed and the weapon never changes: counting those as failed
	   attempts burned the whole budget and reported "could not reach it" for
	   a weapon that was perfectly reachable. Waiting costs nothing, because
	   the target is cleared when the world goes away. */
	if (sv.active && sv.paused)
		return;

	if (qr_wheel_tries <= 0)
	{
		QR_QuietPrintf ("%s: could not reach it\n",
			    QR_WeaponLabel (qr_wheel_target));
		qr_wheel_target = -1;
		return;
	}

	/* A TOGGLE re-sends its OWN impulse; only a CYCLE walks with 10.
	   Measured under Dissolution of Eternity: its powered-up weapons have no
	   number of their own, they share the base weapon's and swap with it, so
	   holding the thunderbolt and sending 8 again gives the plasma gun. From
	   anything else the first 8 lands on the thunderbolt and the second on
	   the plasma gun, which is why re-sending converges either way. Sending
	   10 here would have walked straight past the weapon that was asked
	   for. */
	{
		const qr_weapon_entry_t	*e = QR_WeaponEntry (qr_wheel_target);

		if (e && e->kind == QR_SELECT_TOGGLE && e->impulse)
			Cbuf_AddText (va ("impulse %d\n", (int) e->impulse));
		else
			Cbuf_AddText ("impulse 10\n");
	}
	qr_wheel_tries--;
}

/*
================
IN_WheelCommit -- turn a released ring slot into a weapon selection.

Engine thread, once per IN_Commands. It lives here rather than in the frame
build because a selection the player has already made must not be able to
go missing: the build is gated on a free frame slot, on cls.signon, on
cl.worldmodel and on the open fraction, and none of those are reasons to
drop a release.

It depends on one thing the build owns: QR_OwnedIdentities, which is zeroed
only when the world is gone and deliberately NOT when the wheel closes,
because the release that picks a weapon lands during the close ramp.

TWO triggers, because either alone misses a case. The sampled EDGE is how
the console's +wheel/-wheel and the full menu's gaze pick are seen at all,
since neither goes near the consumer's latch. The LATCH closes the hole the
other way: an open-and-release that lands entirely between two drains shows
no open to sample. Both reduce to "not open, and either we saw the hold or
a release was latched", so exactly one commit comes out.

Runs BEFORE IN_SnapshotInputs on purpose. qr_wheel_highlight is the merged
highlight, and the snapshot overwrites it with the consumer's value, so the
full menu's engine-side gaze pick -- written by the frame build, which knows
nothing of the latch -- exists in it only between that build and the next
snapshot. Reading it here is what lets one drain commit whichever source
owned the highlight.
================
*/
static void IN_WheelCommit (void)
{
	static int	open_prev;
	static int	held = -1;	/* the highlight while the hold lasted */
	static int	rel_seen;	/* the consumer let go during this hold */
	static int	rel_hl = -1;	/* ...and this is what it held then */
	int		pick;

	pthread_mutex_lock (&qc_input_lock);
	if (qc_wheel_release_shared)
	{
		qc_wheel_release_shared = 0;
		rel_hl = qc_wheel_release_hl_shared;
		rel_seen = 1;
	}
	pthread_mutex_unlock (&qc_input_lock);

	/* A set resolved against a world that is gone names nothing, and the
	   identity may not even exist in the next game. Forget the hold rather
	   than commit into it. */
	if (cls.signon != SIGNONS || !cl.worldmodel)
	{
		open_prev = 0;
		held = -1;
		rel_seen = 0;
		rel_hl = -1;
		qr_wheel_target = -1;
		return;
	}

	if (qr_wheel_open)
		held = qr_wheel_highlight;

	if (!qr_wheel_open && (open_prev || rel_seen))
	{
		/* The latched highlight is the consumer's own, taken at the
		   instant it let go, so it is the truer value wherever the
		   consumer owns the highlight at all. In the full menu it does
		   not: the pick there is the gaze the frame build tracked, and a
		   release with no frame built between has nothing to commit. */
		pick = held;
		if (!vr_fullmenu.value && rel_seen && rel_hl >= 0)
			pick = rel_hl;
		if (pick >= 0)
			IN_WheelSelect (pick);
		held = -1;
		rel_seen = 0;
		rel_hl = -1;
	}
	open_prev = qr_wheel_open;

	IN_WheelCycle ();
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
	/* QC_PAD_RSHOULDER is deliberately absent: it is the grapple's bit and
	   grapple_avp.c reads it straight off the pad snapshot. It used to raise
	   K_RSHOULDER so a +attack bind would fire rogue's hook; the hook is
	   native C now and raises no key, and the bind is gone with it, so
	   letting this table claim the bit would hand a grip squeeze to
	   whatever the key happens to be bound to. */
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

/* ========================================================================
 * menu navigation -- stick and dpad as arrow keys
 * ===================================================================== */

/* Upstream in_sdl.c's joystick menu emulation, timing included: an event on
   the press, the first repeat after a delay, then a faster cadence while
   held. Without the repeat, walking the options list costs one stick flick
   per row. */
#define QR_MENUKEY_DELAY	0.5	/* before the first repeat */
#define QR_MENUKEY_REPEAT	0.1	/* between repeats after that */
#define QR_MENUKEY_PUSH		0.5f	/* stick deflection that counts as held */

static void IN_MenuKeyEdge (int wasdown, int isdown, int key, double *timer)
{
	if (!wasdown && isdown)
	{
		Key_Event (key, true);
		*timer = realtime + QR_MENUKEY_DELAY;
	}
	else if (wasdown && isdown)
	{
		if (realtime >= *timer)
		{
			Key_Event (key, true);
			*timer = realtime + QR_MENUKEY_REPEAT;
		}
	}
	else if (wasdown && !isdown)
	{
		Key_Event (key, false);
		*timer = 0;
	}
}

/*
================
IN_MenuKeys -- give the menu the arrow keys a keyboard would send, from the
left stick and the dpad.

The console gets them too, where keys.c maps up/down to command HISTORY
(keys.c's Key_Console). It does NOT get scrollback: con_backscroll is written
only by K_PGUP/K_PGDN, K_HOME/K_END and the mouse wheel, none of which the
pad produces -- so the boot console panel shows the tail of the buffer and
there is no controller path back up through it. Mapping the shoulders to
PGUP/PGDN would fix that and is left for the round that does menu
interaction properly; it is on the remaining-work list in README.md.

The held state is recomputed EVERY tick, not only while a menu is up: it has
to fall to false the moment key_dest returns to key_game, or the release
event never fires and keys.c is left holding the arrow down -- leave a menu
with B while still pushing the stick and the next menu you open scrolls by
itself.

Gated on key_dest so the sticks never reach the console's own arrow bindings
during play, and so this cannot collide with locomotion: with no world loaded
key_dest is key_game and K_UPARROW is a console history key.

A and B are deliberately NOT remapped to ENTER/ESCAPE: menu.c handles
K_ABUTTON and K_BBUTTON natively in every one of its key handlers (12 of 12
that take ENTER also take A; 13 of 13 that take ESCAPE also take B), and the
qr_padkeys table above already delivers both, so a remap would run each menu
action twice.
================
*/
static void IN_MenuKeys (void)
{
	static const int	keys[4] = { K_UPARROW, K_DOWNARROW, K_LEFTARROW, K_RIGHTARROW };
	static int		down[4];
	static double		timer[4];
	int			now[4];
	int			menu = (key_dest != key_game);
	int			i;

	/* Stick Y is +up -- GameController's convention, the same sign IN_Move
	   reads as forward -- so pushing up is a positive deflection. */
	now[0] = menu && (qr_pad.ly >  QR_MENUKEY_PUSH || (qr_pad.buttons & QC_PAD_DPAD_UP));
	now[1] = menu && (qr_pad.ly < -QR_MENUKEY_PUSH || (qr_pad.buttons & QC_PAD_DPAD_DOWN));
	now[2] = menu && (qr_pad.lx < -QR_MENUKEY_PUSH || (qr_pad.buttons & QC_PAD_DPAD_LEFT));
	now[3] = menu && (qr_pad.lx >  QR_MENUKEY_PUSH || (qr_pad.buttons & QC_PAD_DPAD_RIGHT));

	for (i = 0; i < 4; i++)
	{
		IN_MenuKeyEdge (down[i], now[i], keys[i], &timer[i]);
		down[i] = now[i];
	}
}


/*
================
Impulse scan -- find which impulse selects which weapon, by trying them.

Two of the five games' extra weapons were given INFERRED impulses, reasoning
from the shape rogue's row proved, and the inference was wrong. Guessing a
second time is not better than guessing once, and a person reading results
back out of a headset one console round trip at a time is slow enough that it
does not get finished.

So the engine tries them itself. Each impulse is sent TWICE with a settle
between, because a mission pack's extra weapon shares its base gun's number
and swaps with it: one press shows only the first of the pair, and the second
press is the whole point.

Runs on the engine thread off the same drain as the wheel commit, and spends
no step while the world is paused, for the reason given there: the console
pauses the simulation, so a step taken then would report nothing changing and
blame the impulse.
================
*/
static int	qr_scan_active;		/* a scan is running */
static int	qr_scan_impulse;	/* 0 = grant phase, else the impulse under test */
static int	qr_scan_press;		/* 1 or 2 */
static int	qr_scan_settle;
static int	qr_scan_first;		/* identity after press 1 */

static void IN_ImpulseScan_f (void)
{
	if (!sv.active)
	{
		Con_Printf ("impulsescan: no map loaded\n");
		return;
	}
	Con_Printf ("impulsescan: granting, then trying 1..12 twice each."
		    " CLOSE THE CONSOLE so the world runs.\n");
	qr_scan_impulse = 0;		/* 0 = grant phase, see the tick */
	qr_scan_press = 1;
	qr_scan_settle = 0;
	qr_scan_first = -1;
	qr_scan_active = 1;
}

static void IN_ImpulseScanTick (void)
{
	int	held;

	if (!qr_scan_active)
		return;
	if (!sv.active || sv.paused)
		return;

	/* Grant everything FIRST, as part of the scan rather than as a thing the
	   player had to remember to do beforehand. The previous version depended
	   on a separate `impulse 9` having already landed, which it could not
	   have: that impulse needs an unpaused frame too, and the scan began the
	   moment the console closed. The result was a clean run reporting that
	   every impulse selects the shotgun, which is exactly what you see when
	   nothing else is owned. A tool that silently needs a prior step is a
	   tool that reports confident nonsense. */
	if (qr_scan_impulse == 0)
	{
		if (qr_scan_settle == 0)
		{
			Cbuf_AddText ("impulse 9\n");
			qr_scan_settle = 30;
			return;
		}
		if (--qr_scan_settle > 0)
			return;
		/* Dump what the grant actually produced before trying anything.
		   Without it, "impulse N did nothing" cannot be told apart from
		   "that weapon was never owned", and the first scan wasted a
		   round trip on exactly that ambiguity. */
		QR_WeaponTablePrint ();
		qr_scan_impulse = 1;
		qr_scan_press = 1;
		return;
	}

	if (qr_scan_settle > 0)
	{
		qr_scan_settle--;
		return;
	}

	held = QR_ActiveIdentity ();

	if (qr_scan_press == 1)
	{
		qr_scan_first = held;
		Cbuf_AddText (va ("impulse %d\n", qr_scan_impulse));
		qr_scan_press = 2;
		qr_scan_settle = 12;
		return;
	}

	if (qr_scan_press == 2)
	{
		qr_scan_first = held;
		Cbuf_AddText (va ("impulse %d\n", qr_scan_impulse));
		qr_scan_press = 3;
		qr_scan_settle = 12;
		return;
	}

	/* Both presses done: report what each landed on. */
	Con_Printf ("impulse %d:  first %s   again %s\n", qr_scan_impulse,
		    QR_WeaponLabel (qr_scan_first), QR_WeaponLabel (held));

	qr_scan_impulse++;
	qr_scan_press = 1;
	qr_scan_settle = 12;
	/* Past 8 because Scourge's Mjolnir and laser cannon are on neither 1..8
	   nor any impulse this project had guessed. 10 and 12 are documented as
	   cycle keys, so the pair they land on is informative either way. */
	if (qr_scan_impulse > 12)
	{
		Con_Printf ("impulsescan: done\n");
		qr_scan_impulse = 0;
		qr_scan_active = 0;
	}
}

void IN_Commands (void)
{
	size_t i;
	uint32_t changed;

	/* Before the snapshot, and the comment on IN_WheelCommit says why. */
	IN_WheelCommit ();
	IN_ImpulseScanTick ();

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

	/* After the diff above on purpose: the grapple's weapon write and the
	   attack press it depends on have to land in one tick. */
	Grapple_Frame (qr_pad.buttons, qr_wheel_open);

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

	/* Same command, raised by the renderer instead of a thumb: a rebuilt
	   ARKit world-tracking provider brings a new tracking origin, and
	   without a recenter the head feed reads as the player having walked
	   to it. Drained HERE, the only consumer, for the reason
	   qc_recenter_req_shared is declared with. */
	{
		int recenter_req;

		pthread_mutex_lock (&qc_input_lock);
		recenter_req = qc_recenter_req_shared;
		qc_recenter_req_shared = 0;
		pthread_mutex_unlock (&qc_input_lock);
		if (recenter_req)
			Cbuf_AddText ("vr_recenter\n");
	}

	if (!qr_wheel_open)
		IN_TriggerEdge (qr_pad.rt, &qr_rt_down, K_RTRIGGER);
	IN_TriggerEdge (qr_pad.lt, &qr_lt_down, K_LTRIGGER);

	/* After the button edges above, so a MENU press and the first arrow it
	   could produce land in the engine's own order. */
	IN_MenuKeys ();

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

/* The world-space head offset a body-frame feed has at a given body yaw.
   Split out of IN_HeadOffsetWorld so the turn-pivot invariant below is
   provable on the host, with no world, no cvars and no sv to stand up. */
void IN_HeadOffsetAtYaw (const float head[3], float yaw, float out[2])
{
	vec3_t fwd, right;

	IN_YawVectors (yaw, fwd, right);
	out[0] = head[0] * fwd[0] + head[1] * right[0];
	out[1] = head[0] * fwd[1] + head[1] * right[1];
}

/* Rotate a world-space horizontal vector by a body-yaw delta, in place. The
   absorption ledger lives in world space, so a deliberate turn has to carry
   it round with the body; leave it behind and the head's world position moves
   by the arc chord instead of solving out. */
void IN_RotateBodyVec (float v[2], float degrees)
{
	float rad = degrees * (float) M_PI / 180.f;
	float c = cosf (rad), s = sinf (rad);
	float x = v[0], y = v[1];

	v[0] = c * x - s * y;
	v[1] = s * x + c * y;
}

/* The head's offset from the camera anchor, world frame, from the latest feed
   rotated by the CURRENT body yaw. The body basis, not the aim: the feed is
   body-frame exactly so a turn rotates it for free, never with the hand. */
static void IN_HeadOffsetWorld (float out[2])
{
	IN_HeadOffsetAtYaw (qr_head, qr_body_yaw, out);
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
static int IN_HandOriginFrom (const float org[3], int active, vec3_t out)
{
	vec3_t	fwd, right;
	float	ax, ay, az;

	if (!active)
		return 0;

	IN_YawVectors (qr_body_yaw, fwd, right);
	ax = org[0] - qr_head[0];
	ay = org[1] - qr_head[1];
	az = org[2] - qr_head[2];

	out[0] = r_refdef.vieworg[0] + ax * fwd[0] + ay * right[0];
	out[1] = r_refdef.vieworg[1] + ax * fwd[1] + ay * right[1];
	out[2] = r_refdef.vieworg[2] + az + qr_height_trim;
	return 1;
}

int QR_HandOrigin (vec3_t out)
{
	return IN_HandOriginFrom (qr_aim_org, qr_aim_active, out);
}

/*
================
QR_OffHandOrigin -- the same point for the OFF hand, which is where the
grapple leaves from.

Shares IN_HandOriginFrom with the gun hand deliberately. The two differ only
in which pair of staging variables they read, and a second hand-written copy
of that arithmetic is the likeliest thing here to drift: the rope would leave
a point an inch from where the hook spawns, and no assertion would say so
because each half would be self-consistent.

Returns 0 when the off hand is not live, and the throw then falls back to the
gun hand and finally to the body. Engine thread.
================
*/
int QR_OffHandOrigin (vec3_t out)
{
	return IN_HandOriginFrom (qr_offhand_org, qr_offhand_active, out);
}

/*
================
QR_EyeOrigin -- where the RENDERED eye actually is, in world space.

Reconstructs what the immersive consumer draws from, and has to match it or
the fade that reads this would darken at the wrong moment. The consumer
anchors its camera at vieworg minus what the absorb already walked, then the
head offset is applied by the view matrix and the leftover lean is clamped to
lean_limit (ImmersiveRenderer.swift). Net: vieworg plus the clamped lean,
with the vertical taken from the height trim, which is the only channel that
carries where the eye sits above vieworg.

This is one frame stale, like every other engine-side eye reconstruction here
(see IN_HandOriginFrom): a unit or two of head motion. That is immaterial to a
fade whose onset is a dozen units, and it is the reason the fade ramps rather
than switching.

Engine thread.
================
*/
int QR_EyeOrigin (vec3_t out)
{
	float	offset[2], lean[2], limit, len;

	IN_HeadOffsetWorld (offset);
	lean[0] = offset[0] - qr_head_absorbed[0];
	lean[1] = offset[1] - qr_head_absorbed[1];

	/* The same clamp the consumer applies, for the same reason: the box
	   refused this much, so the eye is not allowed all of it. */
	limit = q_max (vr_lean_limit.value, 0.f);
	len = sqrtf (lean[0] * lean[0] + lean[1] * lean[1]);
	if (len > limit && len > 0.f)
	{
		lean[0] *= limit / len;
		lean[1] *= limit / len;
	}

	out[0] = r_refdef.vieworg[0] + lean[0];
	out[1] = r_refdef.vieworg[1] + lean[1];
	out[2] = r_refdef.vieworg[2] + qr_height_trim;
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
	   manage. Only this channel's `commit` (the ring-finger pinch) is read
	   here; its org/yaw/pitch fields are always zero and nothing reads them.
	   They used to be described as kept in the pipe for a future dual-wield,
	   which is no longer where the off hand lives: the off-hand ray has its
	   own channel now (QC_InputSetOffHand), with a real consumer in the
	   grapple. The landing marker is gated renderer-side by vr_teleportmarker
	   so it can be hidden; the gun reticle alone then shows the spot. */
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
IN_SnapTurn -- body rotation about the HEAD, not the anchor.

Settle the body under the head first (a full absorb), rotate the absorbed
offset with the body, then yaw. The head's world position solves out
invariant, which is what "the world stays put under you" means.

The one sanctioned writer of a deliberate body heading. Named for the stick
snap it was written for, but every turn path goes through it now -- smooth
and the edge turn call it once per frame with that frame's delta, which is
the same arithmetic a snap does, just smaller. Write qr_body_yaw directly
and the turn pivots about the recenter anchor instead; see the note at the
call in IN_Move for what that looked like. Not for the server-angle adopt,
which is a teleport moving the origin anyway, nor the demo-export pin.
================
*/
static void IN_SnapTurn (float degrees)
{
	/* The chokepoint for every deliberate turn, so the one guard that cannot
	   be skipped lives here. A non-finite angle written into qr_body_yaw is
	   not a glitch to ride out: the adopt guard in IN_Move compares the yaw
	   against what it last wrote, and a NaN fails that compare forever, so
	   neither a spawn, a teleport nor a recenter gets the view back --
	   relaunching is the only way out. It matters more now that the
	   continuous paths route through here, because the rotation below would
	   also take the absorption ledger with it, and a poisoned ledger is what
	   every later absorb walks against. */
	if (!isfinite (degrees))
		return;

	IN_AbsorbHeadOffset ();
	IN_RotateBodyVec (qr_head_absorbed, degrees);

	/* Turn the BODY. cl.viewangles[YAW] (the aim) is recomposed from
	   qr_body_yaw + the hand ray at the end of IN_Move, so it turns too. */
	qr_body_yaw += degrees;
}

/*
================
Room alignment -- turn the player until the level's local walls run the way
the real room's walls do, so a melted world reads as mapped onto the room
instead of lying across it at a random angle.

Rotation only, and deliberately so. Matching a wall's POSITION means moving
the player, which is a teleport chosen by a heuristic, and cannot succeed
anyway because a Quake room dwarfs a living room. Matching SCALE needs far
more than the twenty percent vr_worldscale allows. See
docs/designs/2026-10-20-room-alignment.md.

The turn goes through IN_SnapTurn, which is the one sanctioned writer of a
deliberate body heading: it settles the body under the head and rotates the
absorption ledger with it. Writing qr_body_yaw directly would either be
mistaken for a server setangle by IN_Move's adopt guard or desynchronise
that ledger.
================
*/
/* NOT archived, deliberately. The window has no way to read a cvar back,
   so a toggle there can only mirror the cvar's DEFAULT -- and an archived
   cvar that came back on would leave the panel showing off while melts
   turned the player, with no way to switch it off but flicking it on
   first. An experiment with a known exit can afford to be asked for each
   session; `vr_align_room 1` in an autoexec is the way to make it stick. */
cvar_t		vr_align_room  = {"vr_align_room",  "0", CVAR_NONE};
cvar_t		vr_align_debug = {"vr_align_debug", "0", 0};

/* 24 rays at 15 degrees. Enough that a long wall is hit by several and
   outvotes a short one by hit count alone, which is why the level side
   needs no area term. */
#define QR_ALIGN_RAYS		24
/* ~13 m at an inch per unit. Four metres sounded like "the room you are
   standing in" and is not: a Quake room runs 300 to 1000 units across, so
   a 160-unit fan finds nothing but corridors and the feature reads as
   doing nothing at all in every arena. The distance weighting below is
   what keeps this from becoming "the level's far side" instead. */
#define QR_ALIGN_RANGE		512.f
#define QR_ALIGN_MIN_HITS	6
/* Square metres of detected wall, and how many separate planes it took.
   The area alone cannot refuse furniture: one 2 m2 wardrobe front standing
   off-square is a single direction, and a single direction's circular mean
   is fully confident by construction, so the confidence gate never sees
   it. Two planes is the cheapest thing that means "a room" and not "a
   thing in a room". */
#define QR_ALIGN_MIN_AREA	2.f
#define QR_ALIGN_MIN_WALLS	2
/* Below this the evidence is cancelling itself -- a round room, or two
   directions of equal strength 45 degrees apart. Both mean: do nothing. */
#define QR_ALIGN_MIN_CONF	0.5f

/* The room's dominant wall direction, as a Quake world yaw. The published
   angles are anchor-frame (see QC_SetRoomWalls), so the body heading is the
   whole conversion; because that is a rotation it commutes with the mean,
   and taking it once after is the same answer as rotating every wall. */
static int IN_RoomWallYaw (float *out_yaw, float *out_conf, float *out_area,
			   int *out_count, float *out_anchor_yaw)
{
	qc_wall_dir_t	walls[QC_MAX_WALL_DIRS];
	align_dir_t	dirs[QC_MAX_WALL_DIRS];
	int		count, i;
	float		area = 0.f;

	pthread_mutex_lock (&qc_walls_lock);
	count = qc_walls_count_shared;
	if (count > 0)
		memcpy (walls, qc_walls_shared, count * sizeof (qc_wall_dir_t));
	pthread_mutex_unlock (&qc_walls_lock);

	for (i = 0; i < count; i++)
	{
		dirs[i].degrees = walls[i].degrees;
		dirs[i].weight = walls[i].weight;
		if (walls[i].weight > 0.f)
			area += walls[i].weight;
	}
	*out_area = area;
	*out_count = count;
	*out_conf = 0.f;
	*out_anchor_yaw = 0.f;
	if (!Align_Dominant (dirs, count, out_anchor_yaw, out_conf))
		return 0;
	/* The ANCHOR-frame mean is reported separately because it is the one
	   number that checks the whole consumer chain on its own: recentre
	   square to a real wall and it reads zero modulo 90, whatever level
	   you are standing in and whether or not the level side can be
	   called. Without it a refusal on the level side teaches nothing
	   about whether the walls arriving are right. */
	*out_yaw = *out_anchor_yaw + qr_body_yaw;
	return 1;
}

/* The level's dominant wall direction around the player, from a fan of
   world-only traces. Upright surfaces only: a ramp, a stair riser's lip or
   a sloped ceiling all have normals that are not a wall's, and left in they
   drag the mean somewhere no wall is. */
static int IN_LevelWallYaw (float *out_yaw, float *out_conf, int *out_hits)
{
	align_dir_t	dirs[QR_ALIGN_RAYS];
	edict_t		*player;
	vec3_t		start, end;
	trace_t		tr;
	float		horizontal;
	int		i, n = 0;

	*out_hits = 0;
	/* `spawned`, not `active`: between SV_SpawnServer and PutClientInServer
	   the client is active with an origin still at the map's zero, and the
	   fan would read whatever geometry happens to surround that point. The
	   teleport path settles for `active` because it needs a deliberate
	   gesture to reach; this fires on its own. */
	if (!sv.active || !svs.clients || !svs.clients[0].active
	    || !svs.clients[0].spawned)
		return 0;
	player = svs.clients[0].edict;

	VectorCopy (player->v.origin, start);
	/* Mid-torso rather than the origin: low enough to stay under a
	   railing, high enough that a step riser is not the nearest thing in
	   every direction. */
	start[2] += 16.f;

	for (i = 0; i < QR_ALIGN_RAYS; i++)
	{
		float a = (float) i * (360.f / QR_ALIGN_RAYS) * M_PI / 180.f;

		end[0] = start[0] + QR_ALIGN_RANGE * cosf (a);
		end[1] = start[1] + QR_ALIGN_RANGE * sinf (a);
		end[2] = start[2];

		tr = SV_Move (start, vec3_origin, vec3_origin, end,
			      MOVE_NOMONSTERS, player);
		if (tr.startsolid || tr.allsolid || tr.fraction >= 1.f)
			continue;
		/* Against the horizontal magnitude, not the raw component, so
		   this is the same rule as FloorMath.maximumWallTilt on the
		   room side rather than one that merely looks like it. */
		horizontal = sqrtf (tr.plane.normal[0] * tr.plane.normal[0]
				  + tr.plane.normal[1] * tr.plane.normal[1]);
		if (horizontal < 1e-5f
		    || fabsf (tr.plane.normal[2]) > 0.3f * horizontal)
			continue;

		dirs[n].degrees = atan2f (tr.plane.normal[1],
					  tr.plane.normal[0]) * 180.f / M_PI;
		/* Weighted by DISTANCE, not one vote per ray. A fixed angular
		   fan gives a near surface more rays than a far one -- a crate
		   two metres away subtends more of the circle than the walls
		   behind it -- so counting hits steers the level by the
		   nearest clutter. The wall length a ray stands for grows with
		   its distance, which is exactly tr.fraction here, so this
		   weights each hit by how much wall it is evidence of. */
		dirs[n].weight = tr.fraction;
		n++;
	}

	*out_hits = n;
	if (n < QR_ALIGN_MIN_HITS)
		return 0;
	return Align_Dominant (dirs, n, out_yaw, out_conf);
}

/* `loud` reports a refusal; the automatic path stays quiet unless
   vr_align_debug is on, because a refusal every melt is the normal case in
   a round room and nobody needs it printed. */
static void IN_AlignRoom (int loud)
{
	float	room_yaw = 0.f, room_conf = 0.f, room_area = 0.f, room_anchor = 0.f;
	float	lvl_yaw, lvl_conf;
	float	turn;
	int	hits = 0, room_count = 0;
	int	have_room;

	loud = loud || vr_align_debug.value != 0.f;

	have_room = IN_RoomWallYaw (&room_yaw, &room_conf, &room_area,
				    &room_count, &room_anchor);

	/* The room's side, printed BEFORE anything can refuse. This is the
	   check that needs no level: recentre square to a real wall and the
	   anchor figure reads zero modulo 90; recentre off square and it
	   reads the angle you turned, with left and right giving different
	   signs. An inverted convention anywhere in the consumer chain swaps
	   those two, and nothing downstream can tell.

	   Printed whenever anyone is listening, not only under the debug
	   cvar. Detecting the room and turning the player are two different
	   things and the first one succeeding says nothing about the second;
	   with only this line to go on, a refusal further down reads as "it
	   detected the room" and the absence of a turn reads as a bug. */
	if (loud)
		Con_Printf ("align: room %d wall%s, %.1f m2, anchor %.1f, "
			    "world %.1f, conf %.2f (body %.1f)\n",
			    room_count, room_count == 1 ? "" : "s", room_area,
			    room_anchor, room_yaw, room_conf, qr_body_yaw);

	if (!have_room)
	{
		if (loud)
			Con_Printf ("align: no room walls detected\n");
		return;
	}
	if (room_count < QR_ALIGN_MIN_WALLS || room_area < QR_ALIGN_MIN_AREA
	    || room_conf < QR_ALIGN_MIN_CONF)
	{
		if (loud)
			Con_Printf ("align: room unclear (%d wall%s, %.1f m2, "
				    "conf %.2f)\n", room_count,
				    room_count == 1 ? "" : "s", room_area,
				    room_conf);
		return;
	}
	if (!IN_LevelWallYaw (&lvl_yaw, &lvl_conf, &hits))
	{
		if (loud)
			Con_Printf ("align: no level walls here (%d hit%s)\n",
				    hits, hits == 1 ? "" : "s");
		return;
	}
	if (lvl_conf < QR_ALIGN_MIN_CONF)
	{
		if (loud)
			Con_Printf ("align: level unclear (%d hits, conf %.2f)\n",
				    hits, lvl_conf);
		return;
	}

	/* The level is fixed in the world; the room is fixed in the tracking
	   frame; body_yaw is the hinge between them (world = anchor + body).
	   A level wall's direction as SEEN IN THE ROOM is lvl_yaw - body_yaw,
	   and we want that to read as the real wall's anchor-frame direction,
	   so the body must end up at lvl_yaw - room_anchor -- which is a turn
	   of lvl_yaw - room_yaw. Derived, not guessed: the reduction mod 90
	   makes an inverted sign agree at exactly 0 and 45 degrees and be
	   wrong by twice the angle everywhere else, so it cannot be found by
	   trying it in a square room. */
	turn = Align_Reduce90 (lvl_yaw - room_yaw);
	if (!isfinite (turn))
	{
		if (loud)
			Con_Printf ("align: refused, the numbers are not finite\n");
		return;
	}
	if (loud)
		Con_Printf ("align: level %.1f (%d hits, conf %.2f)\n",
			    lvl_yaw, hits, lvl_conf);

	/* One line that says what HAPPENED, always. Every path out of this
	   function now ends in a sentence about the turn, because the only
	   question anyone has when they press the button is whether they
	   were turned, and silence answered it wrong in both directions. */
	if (fabsf (turn) < 0.5f)
	{
		if (loud)
			Con_Printf ("align: already aligned, no turn needed "
				    "(%+.1f)\n", turn);
		return;
	}
	IN_SnapTurn (turn);
	if (loud)
		Con_Printf ("align: TURNED %+.1f degrees\n", turn);
}

static void IN_AlignRoom_f (void)
{
	IN_AlignRoom (1);
	/* The button aligns once, here and now. Whether the MELT will do it
	   on its own is a separate switch, and conflating the two is the
	   easiest mistake to make with this feature -- so say which one you
	   just used. */
	if (!vr_align_room.value)
		Con_Printf ("align: (vr_align_room is 0 -- phasing out will "
			    "not do this on its own)\n");
}

/* The melt's rising edge is the only moment to spend a turn this large.
   Outside it the player turns in the game and drifts back out of alignment
   within seconds, and correcting that continuously spins the room
   underfoot, which is worse than no alignment at all. Rephasing does not
   turn you back -- the alignment is a turn like any other.

   The edge is SWALLOWED, not deferred, when the input is somewhere a
   deliberate turn would not be allowed: a menu, the console, the weapon
   wheel, or a pause without vr_turn_while_paused. Those are the same
   conditions that gate the stick's own turning, and the edge has to be
   read every frame rather than from behind their early returns -- a melt
   begun with the menu open and acted on when it closes is a hard body
   snap with the dissolve long finished, which is precisely the motion
   sickness this feature is not allowed to cause.

   Seeded from the live value on the first call so a melt already running
   is not read as an edge. `phase` is not archived, so that is the window
   having set it (ContentView sends `phase <level>` itself), never a config
   restoring it. */
static void IN_AlignEdge (void)
{
	static float	prev;
	static int	seeded;
	float		now = phase.value;

	if (!seeded)
	{
		seeded = 1;
		prev = now;
		return;
	}
	if (now > 0.01f && prev <= 0.01f && vr_align_room.value)
	{
		if (key_dest == key_game && !qr_wheel_open
		    && (!qr_paused || vr_turn_while_paused.value))
			IN_AlignRoom (0);
		else if (vr_align_debug.value)
			Con_Printf ("align: the melt began with the input "
				    "elsewhere -- skipped, not deferred\n");
	}
	prev = now;
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
	{
		/* Only a REAL server setangle (spawn/teleport) should move the body.
		   CL_AdjustAngles anglemod's cl.viewangles[YAW] back into [0,360) every
		   frame AFTER we compose it, while qr_expected_yaw is the raw value we
		   wrote -- so when the composed yaw crosses a 0/360 wrap during a turn
		   the two differ by ~360 and a RAW compare fired a phantom adopt. That
		   baked the aim offset into the body (cl.viewangles here is body+aim,
		   not a clean server angle) and the compose re-added it: a ~aim-sized
		   view snap. Compare the SHORTEST-path delta: a pure wrap is a multiple
		   of 360 and normalizes to ~0 (ignored); a genuine setangle keeps its
		   real delta. */
		float d = cl.viewangles[YAW] - qr_expected_yaw;
		while (d >  180.f) d -= 360.f;
		while (d < -180.f) d += 360.f;
		if (fabsf (d) > 0.01f)
			qr_body_yaw = cl.viewangles[YAW];
	}

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

	/* Room alignment rides the melt's edge. Here, not in the tail, because
	   everything below can return early -- the wheel gate, the menu gate --
	   and the edge must be observed every frame whether or not it may be
	   acted on. IN_AlignEdge does its own gating. */
	IN_AlignEdge ();

	/* One source of truth for "the gun is in the hand this tick": the aim
	   feeds a ray AND vr_handaim allows it. The shot, the move compensation,
	   and the weapon anchor (qr_bridge) all read it, so they can't disagree.
	   The hand ray's room-relative yaw is added to the body yaw for the shot,
	   and subtracted from the move pre-rotation so the stick still walks the
	   body while the gun points elsewhere. */
	qr_aim_active = (vr_handaim.value && qr_aim_valid);
	/* The off hand takes the SAME gate. vr_handaim 0 means "aim from the
	   body, not the hands", and a session in that mode has no business
	   reconstructing a hand position from qr_head and qr_body_yaw for one
	   hand and not the other: the hook then falls back to the gun hand and
	   then to the chest, which is the degradation every other shot in this
	   file already takes. */
	qr_offhand_active = (vr_handaim.value && qr_offhand_valid);
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

	/* A menu or the console has the input: the left stick is walking the
	   menu (IN_MenuKeys), not walking the player. Same shape and the same
	   absorb as the wheel gate above -- physically walking is real motion
	   and stays honoured. This did nothing visible until the 2D layer
	   landed, because nothing drew the menu; now that it is on screen, without
	   this the stick that scrolls the options list also walks you off
	   whatever ledge the panel is floating over. */
	if (key_dest != key_game)
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

	/* Each input's own ceiling (see vr_movescale_hands). Applied to `speed`
	   rather than to lx/ly so it stays DOWNSTREAM of the radial deadzone:
	   the rescale at the top of this block is nonlinear below full
	   deflection, so scaling the stick would make the knob mean something
	   other than what it says. Clamped because these are archived and
	   reachable from the console, and both ends of a typo are a real
	   failure -- a crawl, or a negative that walks you backwards. */
	speed *= CLAMP (0.1f, qr_pad.connected ? vr_movescale_pad.value
						: vr_movescale_hands.value, 1.f);

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
		/* Real time, like the two yaw paths below. A. named left and right;
		   stick pitch is the same control surface and slowing one axis but
		   not the other is a bug someone finds later. */
		cl.viewangles[PITCH] -= ry * cl_pitchspeed.value
					 * (float) IN_TurnFrametime ();
		cl.viewangles[PITCH] = CLAMP (cl_minpitch.value,
					      cl.viewangles[PITCH],
					      cl_maxpitch.value);
	}

	/* Turn lock while paused (the console is up): swallow EVERY turn path --
	   stick/flick snap, opt-in smooth, and the aim-hand edge turn -- so
	   reaching for a parked console doesn't spin the view. The sim is frozen
	   but head tracking and input keep running, so the edge turn would
	   otherwise whip from the aim hand drifting to a side. The aim compose
	   below still runs, so you can still point; only body rotation is frozen.
	   vr_turn_while_paused opts out. */
	if (!qr_paused || vr_turn_while_paused.value)
	{
	float turn = 0.f;	/* this frame's deliberate body heading, degrees */

	/* Right stick X turns the BODY (snap, or smooth for those who opt in). */
	if (vr_smoothturn.value)
	{
		turn -= rx * cl_yawspeed.value * (float) IN_TurnFrametime ();
	}
	else
	{
		if (qr_snap_armed && fabsf (rx) > QR_SNAP_PRESS)
		{
			qr_snap_armed = false;
			turn += (rx > 0.f ? -1.f : 1.f)
				* q_max (vr_snapturn.value, 1.f);
		}
		else if (!qr_snap_armed && fabsf (rx) < QR_SNAP_RELEASE)
			qr_snap_armed = true;
	}

	/* Metroid Prime Hunters edge turn: hold the gun AIM past a yaw deadzone to a
	   side and the body follows continuously. aim_yaw_rel is room-relative, so
	   it stays at the edge while the body sweeps under it -- continuous while
	   held, stops when you bring the aim back to centre.

	   BARE HANDS ONLY, which is what the comfort panel has always claimed and
	   what the code did not do. The aim channel carries a Sense controller's
	   ray exactly as it carries a hand's, by design, and this gesture measures
	   the aim against the HEAD: a controller resting at your side clears the
	   18 degree deadzone permanently, so it turned the player continuously
	   while they held a stick that was already the turn input. Measured on
	   device as unintentional turning, and given that an unwanted turn source
	   also translates the player (see IN_SnapTurn's ledger), this one is worth
	   gating rather than tuning.

	   `connected` is a real spatial controller, not merely a live pad snapshot:
	   hands publish pad state too, for the ring and the grapple, so a check
	   for "any pad input" would switch the gesture off for the one input it
	   exists for. Yielding to an explicit stick/flick (rx) stays, so a
	   deliberate flick still wins wherever the gesture does apply. */
	if (vr_edgeturn.value && qr_aim_active && !qr_turn_hold
	    && !qr_pad.connected && fabsf (rx) < 0.2f)
	{
		/* Measured from the HEAD, not from the room.

		   aim_yaw_rel is the hand ray's yaw in the room, and the body
		   frame's zero is the room direction you last recentred to, so
		   a room-relative reading is also the gun's offset from the
		   body -- which is exactly what this gesture wants while the
		   player's real body stays put. It does not stay put. Turn
		   your real body 20 degrees and your arm goes with it: the
		   offset is past the deadzone with no gesture made, nothing
		   brings it back, and the body sweeps at vr_edgeturn_speed
		   until you physically turn back. The feature is on by
		   default, so this was every player who turned around.

		   Subtracting the head yaw makes it the arm's offset from
		   where you are LOOKING, which is what "hold your arm out to
		   a side" means and is invariant to turning your whole body,
		   because the head turns with it. It also matches the frame
		   movement already uses a few lines below (qr_head_yaw), so
		   walking and turning finally agree about which way is
		   forward. What it gives up is sweeping the body toward an
		   off-axis target you are both pointing at and looking at --
		   there the arm is along the gaze and the offset is zero. The
		   gun aims independently of the body anyway, so nothing stops
		   you shooting there; the body just will not follow. */
		float a = aim_yaw_rel, dz = vr_edgeturn_dz.value;
		if (vr_edgeturn_head.value)
		{
			a -= qr_head_yaw;
			while (a >  180.f) a -= 360.f;
			while (a < -180.f) a += 360.f;
		}
		if (fabsf (a) > dz)
		{
			float frac = (fabsf (a) - dz) / 40.f;	/* ramp to full over 40 deg */
			if (frac > 1.f) frac = 1.f;
			turn += (a > 0.f ? 1.f : -1.f)
			      * vr_edgeturn_speed.value * frac
			      * (float) IN_TurnFrametime ();
		}
	}

	/* One writer, one pivot. Every deliberate heading change this frame --
	   stick snap, opt-in smooth, aim-hand edge turn, or a smooth and an edge
	   turn together -- goes through IN_SnapTurn, which settles the body under
	   the head and carries the absorption ledger round with it. The two
	   continuous paths used to write qr_body_yaw bare, which pivoted the turn
	   about the RECENTER ANCHOR instead: the head swept an arc, and the absorb
	   at the end of IN_Move paid for the arc as real locomotion. You slid
	   sideways when you turned, by the chord, perpendicular to the way you had
	   walked and growing with how far from the recenter point you stood -- so
	   it was invisible until room-scale walking made that radius non-zero. */
	if (turn != 0.f)
		IN_SnapTurn (turn);
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
	Cvar_RegisterVariable (&vr_edgeturn_head);
	Cvar_RegisterVariable (&vr_turn_while_paused);
	Cvar_RegisterVariable (&vr_moverelative);
	Cvar_RegisterVariable (&vr_movescale_hands);
	Cvar_RegisterVariable (&vr_movescale_pad);
	Cvar_RegisterVariable (&vr_headaim);
	Cvar_RegisterVariable (&vr_handaim);
	Cvar_RegisterVariable (&vr_aimpitch);
	Cvar_RegisterVariable (&vr_aimyaw);
	Cvar_RegisterVariable (&vr_wheelpitch);
	Cvar_RegisterVariable (&vr_wheelyaw);
	Cvar_RegisterVariable (&vr_wheelroll);
	Cvar_RegisterVariable (&vr_wheelradius);
	Cvar_RegisterVariable (&vr_weapontrace);
	Cvar_RegisterVariable (&vr_wheelclipfront);
	Cvar_RegisterVariable (&vr_wheelclippack);
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
	Cvar_RegisterVariable (&vr_align_room);
	Cvar_RegisterVariable (&vr_align_debug);
	Cvar_RegisterVariable (&wheel_timescale);
	Cmd_AddCommand ("vr_recenter", IN_Recenter_f);
	/* Align on demand, so the turn can be tried and the refusals read
	   without phasing in and out to provoke an edge. */
	Cmd_AddCommand ("align_room", IN_AlignRoom_f);
	Cmd_AddCommand ("impulsescan", IN_ImpulseScan_f);
	Admin_Init ();
	Grapple_Init ();
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
		/* RSHOULDER is deliberately UNBOUND. It used to be +attack,
		   because the grapple reached rogue's weapon by raising
		   K_RSHOULDER and letting the bind fire the attack. The hook is
		   native C now and raises no key at all, so a bind here would
		   be a grip squeeze that shoots: exactly the failure that
		   burned seven shells in 200 held frames when the feature was
		   switched off. grapple_avp.c reads the pad bit directly. */
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
