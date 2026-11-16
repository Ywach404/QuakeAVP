/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * turntest.c -- the two bare-hands turn engines measured against each other
 * on the host, with no headset and no hands.
 *
 * THE REPORT. Turn left or right while running and, after the initial turn
 * lands, the body shifts the OTHER way while the hand comes back.
 *
 * Bare hands drive ONE hand on ONE axis into TWO turn engines that do not
 * know about each other:
 *
 *   VELOCITY (quick whip), Swift side, HandInput.swift. A wrist speed past
 *   flickFloor 1.60 m/s fires once and publishes rx = +-1 for flickPulse
 *   0.09 s (HandInput.swift:55-58, `slice.rx = flickDir`, dir = +1 for
 *   body-RIGHT). It is then disarmed by a 0.35 s cooldown AND a re-arm that
 *   wants the wrist under flickReset 0.35 m/s for flickDwell 0.12 s. The
 *   engine integrates that pulse as a SMOOTH turn (vr_smoothturn defaults 1):
 *   turn -= rx * cl_yawspeed 140 * dt. So one whip commands 140 * 0.09 =
 *   12.6 degrees, once, and then it is over.
 *
 *   POSITION (edge turn), engine side, in_null.c's IN_Move. Continuous, no
 *   arming, no cooldown, no memory: it recomputes from the instantaneous
 *   arm-versus-gaze angle every frame. Gated by vr_edgeturn && qr_aim_active
 *   && !qr_turn_hold && !qr_pad.connected && fabsf (rx) < 0.2f, so the whip's
 *   own pulse suppresses it while the pulse is live and NOTHING suppresses it
 *   afterwards. It turns at up to vr_edgeturn_speed 90 deg/s past the
 *   vr_edgeturn_dz 18 degree deadzone, ramping to full over the 40 degrees
 *   past it, measured as a = aim_yaw_rel - qr_head_yaw.
 *
 * So the defect is a fixed, commanded 12.6 degrees against an uncapped,
 * uncommanded amount over the return stroke, and the measurement that
 * matters is those two numbers side by side. A real hand does not whip out
 * and stop dead at centre on the way back: it swings back through centre,
 * overshoots to the far side of the gaze, parks there for a moment, and then
 * settles. Everything past the deadzone on that far side drags the body the
 * other way at up to 90 deg/s with the flick already disarmed.
 *
 * THE FIX, AND WHERE ITS OTHER HALF LIVES. The two engines are reconciled on
 * the SWIFT side, in App/Sources/HandInput.swift: the hold published through
 * QC_InputSetTurnHold is now (turnHold || !flickArmed), so the edge turn is
 * stood down from the moment a whip fires until the whip's own re-arm test
 * passes again (the wrist under flickReset 0.35 m/s for flickDwell 0.12 s).
 * SETTLED, not merely back inside the deadzone. A host driver cannot see
 * Swift state, so this file asserts the ENGINE's half of that contract:
 *
 *   CASE 1, 2   the two engines in isolation, each doing what it says.
 *   CASE 3, 3b  the defect, measured with nothing holding. These do NOT
 *               assert a sign: with no hold the engine is behaving exactly
 *               as designed and merely uninformed, so what is invariant is
 *               that the hand's return turns the body on its own, that the
 *               amount grows with the overshoot, and that the net's sign
 *               flips somewhere in the sweep.
 *   CASE 4      the fix's guard: hold until SETTLED leaves the commanded
 *               turn and nothing else. This is the contract.
 *   CASE 4R     the REJECTED release condition, kept as an assertion so
 *               nobody adopts it later because it reads simpler.
 *   CASE 5, 6   a turn must not translate the player; the error is linear
 *               in the number of turns rather than compounding.
 *
 * SIGNS, because the whole reading hangs on them. Quake yaw is CCW and
 * left-positive. A hand to the RIGHT has aim_yaw_rel < 0, so the edge turn's
 * `a` is negative and it adds a NEGATIVE turn: right. rx = +1 (a whip to the
 * right) gives turn -= 140 * dt, also negative: right. So while the hand is
 * still RIGHT of centre on its way back the edge turn HELPS the whip, and
 * only the part of the stroke past the deadzone on the LEFT opposes it. Every
 * net printed below is signed in Quake's sense: negative is to the right,
 * which is this gesture's commanded direction throughout.
 *
 * FRAMES. One QC_Frame per tick at FRAME_DT 0.015 s, which is safely over
 * Host_FilterTime's 1/72 gate so no call is ever swallowed (the aliasing
 * trap: a dt under the gate leaks its time into the next tick and the
 * accounting silently moves). 6 frames is 0.090 s, which is the flick pulse
 * exactly. host_framecount is read either side of every phase and reported,
 * so the wall time each phase claims is measured rather than asserted.
 *
 * WHAT A HOST RUN CANNOT SHOW. Nothing here is a picture. It measures
 * qr_body_yaw, which is the number the immersive camera and the head follow
 * read, and the player origin. Whether the resulting motion reads as
 * sickening in the headset is device-only.
 *
 * Link against ${TMPDIR}/quakecore-hostbuild/[star].o minus hostmain.o and
 * the unit objects, exactly as gymtest.c does (tools/range/README.md):
 *
 *   make check
 *   O=${TMPDIR:-/tmp}/quakecore-hostbuild
 *   rm -f build/turntest
 *   cc -std=gnu99 -DQAVP_PLATFORM -DQAVP_HOSTCHECK -DUSE_CODEC_WAVE=1 \
 *      -DUSE_CODEC_VORBIS=1 \
 *      -ISources/QuakeCore/engine -ISources/QuakeCore/platform \
 *      -ISources/QuakeCore/include -ISources/QuakeRenderer/bridge \
 *      -o build/turntest tools/range/turntest.c \
 *      $(ls $O/[star].o | grep -v -e hostmain.o -e '/unit_') -lm
 *   build/turntest <basedir>
 *
 * The rm is load-bearing: a chain that breaks before cc leaves the previous
 * binary in place, and it will happily report a pass for a test that was
 * just written to fail.
 */

#include "quakedef.h"
#include "QuakeCore.h"
#include <stdio.h>
#include <math.h>
#include <string.h>

/* The audio sink is Swift and is not in the host objects. Same four stand-ins
   gymtest.c and hostmain.c each carry for themselves; returning 0 from open
   leaves the engine with no sound device, which is the right headless
   answer. */
int QC_AudioOpen (int speed, int channels, int bits, unsigned char **buffer, int *mono_samples)
{
	(void)speed; (void)channels; (void)bits;
	if (buffer) *buffer = NULL;
	if (mono_samples) *mono_samples = 0;
	return 0;
}
int  QC_AudioSamplePos (void) { return 0; }
void QC_AudioClose (void) { }
void QC_AudioSetRunning (int running) { (void)running; }

/* in_null.c. The BODY heading, which is what every turn path writes and what
   the immersive camera and the head follow read, and the one gate that says
   the hand aim is live this tick. qr_pad and qr_paused are static in that
   file and cannot be read from here; see the preconditions below for how
   each is established instead. */
extern float	qr_body_yaw;
extern int	qr_aim_active;

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

/* COUNT IN CODE, NEVER IN THE LOG. Every line this driver prints appears on
   stdout TWICE: sys_avp.c's QAVP_Emit mirrors it with a raw write(2) so a
   device run can be read back, and then hands it to this callback, which
   prints it again. Nothing below is measured by grepping output. */
static void on_log (void *c, const char *t) { (void)c; fputs (t, stdout); }
static void on_error (void *c, const char *e) { (void)c; if (e) printf("FATAL: %s\n", e); }

/* ======================================================================
 * the clock and the gesture
 * =================================================================== */

/* Seconds per QC_Frame. Over Host_FilterTime's 1/72 = 0.01389 s gate, so
   every call ticks and the sum of the phase times is the wall time of the
   gesture. 6 frames = 0.090 s = HandInput's flickPulse. */
#define FRAME_DT	0.015

/* The arm the stated hand speeds are reckoned at: shoulder to wrist, metres.
   Only used to convert a hand ANGULAR rate into the m/s that HandInput's
   flickFloor/flickReset thresholds are written in, so a reader can tell
   whether a modelled stroke is a whip, a settle, or neither. */
#define ARM_RADIUS	0.55

/* The hand's position in the BODY frame (fwd/right/up from the recenter
   origin, Quake units), which is where the view weapon is drawn. It has no
   part in either turn engine -- both read only the ray's YAW -- but the aim
   channel carries it and a plausible value keeps the packet honest. */
#define HAND_FWD	16.f
#define HAND_RIGHT	8.f
#define HAND_UP		40.f

static float	g_aim_yaw;	/* this frame's hand ray yaw, room-relative deg */
static float	g_rx;		/* this frame's published flick pulse */
static int	g_hold;		/* this frame's QC_InputSetTurnHold */
static int	g_ticks;	/* engine ticks the last phase actually ran */

static float Norm180 (float d)
{
	while (d >  180.f) d -= 360.f;
	while (d < -180.f) d += 360.f;
	return d;
}

/*
Push one frame's worth of input through the real any-thread setters.

The head yaw is held at 0 for every case: the player stands still and does
not turn his real body, so his head keeps looking down room forward. That is
also why the edge turn does not self-terminate -- the aim and the head are
both fixed in the ROOM while the body rotates underneath them, which is the
frame ImmersiveRenderer feeds (originFromDevice is the device pose in the
tracking origin, and the body yaw is applied to the WORLD, not to that pose).

connected = 0 because these are bare hands. A hand publishes pad state for
the ring and the grapple, so the field means "a real spatial controller",
and the edge turn is gated on it.
*/
static void Push (void)
{
	qc_gamepad_state_t pad;

	memset (&pad, 0, sizeof (pad));
	pad.rx = g_rx;
	pad.connected = 0u;
	QC_InputSetGamepad (&pad);
	QC_InputSetHeadYaw (0.f);
	QC_InputSetTurnHold (g_hold);
	QC_InputSetAim (1, HAND_FWD, HAND_RIGHT, HAND_UP, g_aim_yaw, 0.f);
}

/*
Sweep the hand ray from `from` to `to` over `frames` ticks and return the
signed body yaw the engine turned over that phase.

Sampled at each frame's MIDPOINT, so a linear stroke integrates as a
trapezoid rather than leading or lagging the engine by half a frame.
*/
static float Sweep (float from, float to, int frames, float rx, int hold)
{
	float	start = qr_body_yaw;
	int	i, fc0 = host_framecount;

	g_rx = rx;
	g_hold = hold;
	for (i = 0; i < frames; i++)
	{
		g_aim_yaw = from + (to - from)
			  * (((float) i + 0.5f) / (float) frames);
		Push ();
		QC_Frame (FRAME_DT);
	}
	g_ticks = host_framecount - fc0;
	return Norm180 (qr_body_yaw - start);
}

/* Hold the hand still at one yaw. */
static float Hold (float at, int frames, float rx, int hold)
{
	return Sweep (at, at, frames, rx, hold);
}

/* Hand centred, nothing published, nothing should move. Returns the drift so
   a caller can assert on it. */
static float Settle (int frames)
{
	return Sweep (0.f, 0.f, frames, 0.f, 0);
}

/*
Put the player somewhere quiet and keep him there, the idiom gymtest.c uses
for the same reason.

The range is a LIVE arena: five grunts, two dogs and a weapon rack, all
within a few hundred units of the spawn. Measured there, the player picked up
half the rack during the run and carried about 42 units/s of velocity every
tick with no input published at all, which is CASE 5's guard measuring the
fight instead of the turn. `god` and `notarget` stop him dying and they do
not stop that: vanilla T_Damage adds its knockback to a MOVETYPE_WALK target
BEFORE it checks FL_GODMODE, so an invulnerable player is still shoved by
every bite. That ordering is also why NOCLIP cures it and god mode alone
does not.

NOCLIP with a zeroed velocity, on the track apron outside lane 8 and clear
of everything the generator puts in the infield. Neither turn engine reads
the movetype -- both write qr_body_yaw, and the head-follow absorb writes the
origin directly -- so nothing under test is switched off by this.
*/
#define QUIET_X		0.f
#define QUIET_Y		-1250.f
#define QUIET_Z		40.f

static void Place (float x, float y, float z)
{
	edict_t *p = svs.clients[0].edict;

	p->v.movetype = MOVETYPE_NOCLIP;
	p->v.origin[0] = x;
	p->v.origin[1] = y;
	p->v.origin[2] = z;
	p->v.velocity[0] = p->v.velocity[1] = p->v.velocity[2] = 0.f;
	SV_LinkEdict (p, false);
}

/* A hand angular rate as the wrist speed HandInput's thresholds are in. */
static float WristSpeed (float deg_per_s)
{
	return (float) (deg_per_s * M_PI / 180.0 * ARM_RADIUS);
}

static float RateOf (float degrees, int frames)
{
	return (float) (degrees / (frames * FRAME_DT));
}

/* ======================================================================
 * ONE deliberate turn, and the hand coming back from it
 * =================================================================== */

/*
The gesture, built literally from the report: turn once, then let the hand
come home the way a hand actually does.

  A  WHIP       hand 0 -> -40 deg (right), 6 frames, 0.090 s.
                rx = +1 for the whole phase, which is flickPulse exactly.
                444 deg/s, 4.3 m/s at the wrist -- well past flickFloor
                1.60, and faster than a flick strictly needs to be. The
                edge turn is suppressed throughout by fabsf (rx) < 0.2f.
                This is the only COMMANDED turn in the whole gesture.
  B1 RETURN,    hand -40 -> -18 deg at `rate`. Under flickFloor so it cannot
     near side  fire a second flick, over flickReset 0.35 m/s so the flick
                cannot even RE-ARM. The edge turn is live again the instant
                the pulse ends, and the hand is still right of the gaze, so
                this phase turns RIGHT: it ADDS to the whip.
  B2 RETURN,    hand -18 -> +overshoot at `rate`. Crosses the gaze. Past
     far side   +18 the edge turn turns LEFT, AGAINST the whip.
  D  DWELL      hand parked at +overshoot for `dwell` seconds. The arm has
                finished its movement and the player is doing nothing; the
                edge turn keeps turning him anyway, at
                90 * (overshoot - 18) / 40 deg/s.
  E  SETTLE     hand +overshoot -> 0 at `rate`. The far side of the deadzone
                is therefore crossed twice and the near side once.

`hold_mode` drives QC_InputSetTurnHold:

  0  never asserted.
  1  over B1 only, which is what "from the end of the rx pulse until the
     hand is back inside the deadzone, released after" literally names: the
     hand re-enters |a| < 18 at the END of B1, coming back from the right.
     So this hold covers the stroke that HELPS the whip and releases before
     the overshoot that opposes it.
  2  over the whole return, B1 through E, released once the hand is home.
     The tail of E is inside the deadzone and contributes nothing either
     way, so this is "held until the hand has SETTLED" rather than until it
     first re-enters the deadzone.

Mode 2 is what HandInput.swift publishes now, through (turnHold ||
!flickArmed): the flick does not re-arm until the wrist has been under
flickReset for flickDwell, which is "the hand has settled" expressed in the
only terms the Swift side can measure. Mode 1 is the reading that looks
simpler and is wrong; CASE 4R keeps it measured.

Phase deltas land in out[0..4] in that order, so a caller can report the
whip's own 12.6 degrees separately from everything the hand did afterwards,
which is the actual claim.
*/
#define WHIP_FRAMES	6
#define WHIP_TO		-40.f
#define EDGE_DZ		18.f

static int FramesFor (float degrees, float rate)
{
	int n = (int) (fabs (degrees) / rate / FRAME_DT + 0.5);
	return n < 1 ? 1 : n;
}

static float Gesture (float overshoot, float rate, float dwell_s, int hold_mode,
		      float out[5], int frames[5])
{
	int	nb1 = FramesFor (WHIP_TO + EDGE_DZ, rate);
	int	nb2 = FramesFor (overshoot + EDGE_DZ, rate);
	int	nd  = (int) (dwell_s / FRAME_DT + 0.5);
	int	ne  = FramesFor (overshoot, rate);
	int	rest = (hold_mode == 2);

	frames[0] = WHIP_FRAMES;
	out[0] = Sweep (0.f, WHIP_TO, WHIP_FRAMES, 1.f, 0);
	frames[1] = nb1;
	out[1] = Sweep (WHIP_TO, -EDGE_DZ, nb1, 0.f, hold_mode ? 1 : 0);
	frames[2] = nb2;
	out[2] = Sweep (-EDGE_DZ, overshoot, nb2, 0.f, rest);
	frames[3] = nd;
	out[3] = nd > 0 ? Hold (overshoot, nd, 0.f, rest) : 0.f;
	frames[4] = ne;
	out[4] = Sweep (overshoot, 0.f, ne, 0.f, rest);

	return out[0] + out[1] + out[2] + out[3] + out[4];
}

/* Everything the body did AFTER the commanded pulse ended. */
static float AfterPulse (const float out[5])
{
	return out[1] + out[2] + out[3] + out[4];
}

/* The primary gesture's shape. One point out of the table below, named here
   so CASE 3, CASE 4 and the repeat case are all the same gesture:
   a 30 degree overshoot past the gaze, a 60 deg/s (0.58 m/s) return, and
   0.30 s parked at the far side before settling. */
#define PRIMARY_OVERSHOOT	30.f
#define PRIMARY_RATE		60.f
#define PRIMARY_DWELL		0.30

/* ======================================================================
 * the overshoot sweep, which is where the defect's shape lives
 * =================================================================== */

/*
  Every row is run and printed, so this is a parameter study and not a
  gesture hunted for until it failed. The whip is fixed at 0 -> -40 over the
  0.090 s pulse in every row and the return rate is fixed at 60 deg/s; what
  moves is how far past the gaze the hand overshoots and how long it parks
  there.

  Why those two. The edge turn's contribution over a stroke at rate w is
  (90/80w) * (|a| - 18)^2 integrated over the part past the deadzone, so the
  SWEEP terms of one gesture come to

      far side  2 * (V - 18)^2    (crossed going out and coming back)
    - near side     (40 - 18)^2   (the return's near half, crossed once)

  all times 90/80w, with V the overshoot. Both scale the same way with w, so
  the return rate moves the magnitude and not the sign OF THE EDGE TURN'S OWN
  TOTAL. It does move the sign of the NET, because the whip it is weighed
  against is a fixed 12.6 degrees: with no dwell the break-even overshoot is
  around 42 degrees at a 60 deg/s return and lower at a slower one. The DWELL
  is the other way in and does not care about w at all: parked at V the body
  turns at a flat 90 * (V - 18) / 40 deg/s for as long as the hand sits
  there, which is 90 deg/s once V is past 58 and the ramp caps.

  So each overshoot gets a zero-dwell row first, and the break-even dwell is
  derived from THAT net and the measured parked rate, not from the whip
  alone: the sweep strokes are already on the board before the hand stops
  moving, with both signs in them.
*/
#define SWEEP_OVERS	4
#define SWEEP_DWELLS	4

static const float	sweep_over[SWEEP_OVERS]   = { 10.f, 20.f, 30.f, 45.f };
static const float	sweep_dwell[SWEEP_DWELLS] = { 0.00f, 0.10f, 0.30f, 0.60f };

/* Filled by RunSweep so CASE 3 can assert over the whole table rather than
   over one cell: the net, the uncommanded term, and the parked rate measured
   at each overshoot. */
static float	sweep_net[SWEEP_OVERS][SWEEP_DWELLS];
static float	sweep_unc[SWEEP_OVERS][SWEEP_DWELLS];
static float	sweep_held[SWEEP_OVERS];

static void RunSweep (float whip_deg)
{
	int	o, w;

	printf ("      return rate 60 deg/s, whip fixed at 0 -> -40 deg over "
		"0.090 s (%+.2f deg)\n", whip_deg);
	printf ("      over  parked  dwell |  commanded  uncommanded      NET"
		"  the net is\n");
	printf ("      shoot   deg/s      s |\n");
	for (o = 0; o < SWEEP_OVERS; o++)
	{
		float	d[5];
		int	fr[5];

		/* The parked rate MEASURED at that overshoot rather than taken
		   from the cvar, so the break-even below is a measurement and
		   not a restatement of the ramp. */
		sweep_held[o] = Hold (sweep_over[o], 67, 0.f, 0)
			      / (float) (67 * FRAME_DT);
		Settle (40);

		for (w = 0; w < SWEEP_DWELLS; w++)
		{
			sweep_net[o][w] = Gesture (sweep_over[o], 60.f,
						   sweep_dwell[w], 0, d, fr);
			sweep_unc[o][w] = AfterPulse (d);
			printf ("      %5.0f %7.2f %6.2f | %+10.3f %+12.3f "
				"%+8.3f  %s\n",
				sweep_over[o], sweep_held[o], sweep_dwell[w],
				d[0], sweep_unc[o][w], sweep_net[o][w],
				sweep_net[o][w] < 0.f ? "the turn's way"
						      : "AGAINST the turn");
			Settle (40);
		}

		/* Break even is where the DWELL finishes off whatever the sweep
		   strokes left, so it is measured from the zero-dwell net and
		   not from the whip. */
		if (sweep_net[o][0] > 0.f)
			printf ("            break even: already reversed with "
				"no dwell at all (%+.3f deg)\n",
				sweep_net[o][0]);
		else if (fabsf (sweep_held[o]) > 0.01f)
			printf ("            break even: %.3f s parked at %.0f "
				"deg (the zero-dwell net is %+.3f, the parked "
				"rate %.2f deg/s)\n",
				fabsf (sweep_net[o][0]) / fabsf (sweep_held[o]),
				sweep_over[o], sweep_net[o][0], sweep_held[o]);
		else
			printf ("            break even: never, %.0f deg is "
				"inside the 18 deg deadzone, so parking there "
				"turns nothing\n", sweep_over[o]);
	}
}

int main (int argc, char **argv)
{
	float	net, net4, drift, phase[5], c4[5];
	int	nf[5], nf4[5];
	vec3_t	org0, org1;
	float	fwd_yaw, dx, dy, lateral, along;
	float	r28, r48, r68, ramp_sweeps = 0.f;
	int	i;

	if (argc < 2)
	{
		printf ("usage: turntest <basedir>\n");
		return 2;
	}
	QC_SetCallbacks (on_log, on_error, NULL);
	QC_SetPaths (argv[1], argv[1]);
	{ const char *a[2] = { "-basedir", argv[1] };
	  if (!QC_Init (2, a)) { printf ("init failed\n"); return 1; } }

	/* The range, because it has an open floor and a known spawn and the
	   player can turn through a full circle without walking into anything.
	   A basedir whose autoexec.cfg switches `game` mid-run would stomp this
	   map, so the worldmodel is checked rather than assumed. */
	QC_ExecuteCommand ("map range\n");
	for (i = 0; i < 120; i++)
		QC_Frame (FRAME_DT);
	/* AFTER the connect, not before it. Both are src_command cheats, so
	   Host_God_f forwards them to the server over the loopback, and a
	   forward issued while the client is still signing on is sent to
	   nobody: the first attempt put these two lines straight after `map`
	   and a dog killed the player anyway, mid-run. */
	QC_ExecuteCommand ("god\n");
	QC_ExecuteCommand ("notarget\n");
	for (i = 0; i < 10; i++)
		QC_Frame (FRAME_DT);

	printf ("\n--- preconditions ------------------------------------------\n");
	CHECK (sv.active && cls.signon == 4,
	       "range.bsp loads and connects (signon=%d)", cls.signon);
	CHECK (cl.worldmodel && !strcmp (cl.worldmodel->name, "maps/range.bsp"),
	       "worldmodel is the range (%s)",
	       cl.worldmodel ? cl.worldmodel->name : "none");
	/* IN_Move returns early on anything but key_game, so a menu left up
	   would make every case below pass by doing nothing. */
	CHECK (key_dest == key_game, "the input is in the game (key_dest=%d)",
	       (int) key_dest);
	CHECK (svs.clients[0].edict->v.health > 0.f,
	       "the player is alive (health=%.0f)",
	       svs.clients[0].edict->v.health);

	/* The cvars are CHECKED, not set. Setting them would mask a default
	   that had drifted, and these numbers are what the claim is arithmetic
	   over. */
	CHECK (Cvar_VariableValue ("vr_edgeturn") == 1.f,
	       "vr_edgeturn %.0f (want 1)", Cvar_VariableValue ("vr_edgeturn"));
	CHECK (Cvar_VariableValue ("vr_edgeturn_dz") == 18.f,
	       "vr_edgeturn_dz %.0f (want 18)", Cvar_VariableValue ("vr_edgeturn_dz"));
	CHECK (Cvar_VariableValue ("vr_edgeturn_speed") == 90.f,
	       "vr_edgeturn_speed %.0f (want 90)", Cvar_VariableValue ("vr_edgeturn_speed"));
	CHECK (Cvar_VariableValue ("vr_edgeturn_head") == 1.f,
	       "vr_edgeturn_head %.0f (want 1)", Cvar_VariableValue ("vr_edgeturn_head"));
	CHECK (Cvar_VariableValue ("vr_smoothturn") == 1.f,
	       "vr_smoothturn %.0f (want 1, so the pulse integrates)",
	       Cvar_VariableValue ("vr_smoothturn"));
	CHECK (Cvar_VariableValue ("vr_handaim") == 1.f,
	       "vr_handaim %.0f (want 1)", Cvar_VariableValue ("vr_handaim"));
	CHECK (Cvar_VariableValue ("cl_yawspeed") == 140.f,
	       "cl_yawspeed %.0f (want 140)", Cvar_VariableValue ("cl_yawspeed"));
	CHECK (Cvar_VariableValue ("vr_aimyaw") == 0.f,
	       "vr_aimyaw %.0f (no forearm trim in the way)",
	       Cvar_VariableValue ("vr_aimyaw"));

	Place (QUIET_X, QUIET_Y, QUIET_Z);
	Settle (2);
	CHECK (SV_PointContents (svs.clients[0].edict->v.origin) == CONTENTS_EMPTY,
	       "the player is parked in clear air at %.0f %.0f %.0f (contents %d)",
	       svs.clients[0].edict->v.origin[0], svs.clients[0].edict->v.origin[1],
	       svs.clients[0].edict->v.origin[2],
	       SV_PointContents (svs.clients[0].edict->v.origin));

	/* One frame of aim, then the gate the shot, the move compensation and
	   the weapon anchor all read. */
	Settle (2);
	CHECK (qr_aim_active == 1, "the hand aim is live (qr_aim_active=%d)",
	       qr_aim_active);

	/* qr_pad and qr_paused are static in in_null.c. connected = 0 is
	   established by CASE 2 instead: the edge turn is gated on
	   !qr_pad.connected, so if the driver's pad read as connected that
	   case would measure zero. Likewise qr_paused: the whole turn block
	   is inside `if (!qr_paused || vr_turn_while_paused.value)`, so case 1
	   turning at all is the proof the sim is not paused. */
	drift = Settle (40);
	CHECK (fabsf (drift) < 0.01f,
	       "a centred hand turns nothing (%.4f deg of drift over 40 frames, "
	       "%d ticks)", drift, g_ticks);

	/* And nothing moves the player either, which is CASE 5's premise. */
	VectorCopy (svs.clients[0].edict->v.origin, org0);
	Settle (40);
	VectorCopy (svs.clients[0].edict->v.origin, org1);
	CHECK (fabsf (org1[0] - org0[0]) < 0.01f && fabsf (org1[1] - org0[1]) < 0.01f,
	       "an idle hand moves the player nowhere (%.4f units over 40 frames)",
	       sqrtf ((org1[0] - org0[0]) * (org1[0] - org0[0])
		      + (org1[1] - org0[1]) * (org1[1] - org0[1])));

	printf ("\n--- CASE 1: one whip, hand home inside the deadzone --------\n");
	/*
	  A  WHIP    hand 0 -> -15 deg, 6 frames, 0.090 s = flickPulse, rx = +1.
	             167 deg/s, 1.60 m/s at the wrist, which is flickFloor
	             exactly: the slowest stroke that fires at all.
	  B  HOME    hand -15 -> 0, 15 frames, 0.225 s, 67 deg/s.
	  The hand never clears the 18 degree deadzone, so the edge turn
	  contributes nothing and what is left is the whip alone.
	*/
	printf ("      whip   0 -> -15 deg over 6 frames (0.090 s, %.0f deg/s, "
		"%.2f m/s)\n", RateOf (15.f, 6), WristSpeed (RateOf (15.f, 6)));
	printf ("      home -15 ->   0 deg over 15 frames (0.225 s, %.0f deg/s, "
		"%.2f m/s)\n", RateOf (15.f, 15), WristSpeed (RateOf (15.f, 15)));
	phase[0] = Sweep (0.f, -15.f, WHIP_FRAMES, 1.f, 0);
	nf[0] = g_ticks;
	phase[1] = Sweep (-15.f, 0.f, 15, 0.f, 0);
	nf[1] = g_ticks;
	net = phase[0] + phase[1];
	printf ("      whip phase %+8.3f deg (%d ticks), home phase %+8.3f deg "
		"(%d ticks)\n", phase[0], nf[0], phase[1], nf[1]);
	printf ("      NET %+8.3f deg\n", net);
	CHECK (net < 0.f && fabsf (net) > 12.f && fabsf (net) < 13.f,
	       "CASE 1: one whip turns %+.3f deg, the whip's own way, 12 to 13 "
	       "deg of it", net);

	Settle (40);

	printf ("\n--- CASE 2: hand held out, no flick, rate ramps ------------\n");
	/* Held 1.005 s (67 frames) at each offset. The hand is fixed in the
	   ROOM, so `a` does not shrink as the body comes round and the rate is
	   steady: predicted 90 * (|a| - 18) / 40, capped at 90. */
	r28 = Hold (-28.f, 67, 0.f, 0) / (float) (67 * FRAME_DT);
	r48 = Hold (-48.f, 67, 0.f, 0) / (float) (67 * FRAME_DT);
	r68 = Hold (-68.f, 67, 0.f, 0) / (float) (67 * FRAME_DT);
	printf ("      held at -28 deg (10 past dz): %+8.3f deg/s (want -22.5)\n", r28);
	printf ("      held at -48 deg (30 past dz): %+8.3f deg/s (want -67.5)\n", r48);
	printf ("      held at -68 deg (50 past dz): %+8.3f deg/s (want -90.0, "
		"ramp capped)\n", r68);
	CHECK (r28 < 0.f && r48 < 0.f && r68 < 0.f,
	       "CASE 2: a held hand turns toward the side it is held on");
	CHECK (fabsf (r48) > fabsf (r28) && fabsf (r68) > fabsf (r48),
	       "CASE 2: and the rate ramps with the offset (%.1f < %.1f < %.1f "
		"deg/s)", fabsf (r28), fabsf (r48), fabsf (r68));
	CHECK (fabsf (r28 + 22.5f) < 0.5f && fabsf (r48 + 67.5f) < 0.5f
	       && fabsf (r68 + 90.0f) < 0.5f,
	       "CASE 2: at the documented rates (%.2f / %.2f / %.2f)", r28, r48, r68);

	Settle (40);

	printf ("\n--- CASE 3: the DEFECT, one turn with nothing holding -----\n");
	net = Gesture (PRIMARY_OVERSHOOT, PRIMARY_RATE, PRIMARY_DWELL, 0, phase, nf);
	printf ("      A  whip      0 -> -40 deg, %2d ticks, %.3f s, %3.0f deg/s, "
		"%.2f m/s, rx=+1\n", nf[0], nf[0] * FRAME_DT,
		RateOf (40.f, nf[0]), WristSpeed (RateOf (40.f, nf[0])));
	printf ("      B1 return  -40 -> -18 deg, %2d ticks, %.3f s, %3.0f deg/s, "
		"%.2f m/s\n", nf[1], nf[1] * FRAME_DT,
		RateOf (22.f, nf[1]), WristSpeed (RateOf (22.f, nf[1])));
	printf ("      B2 return  -18 -> +%2.0f deg, %2d ticks, %.3f s, %3.0f deg/s, "
		"%.2f m/s\n", PRIMARY_OVERSHOOT, nf[2], nf[2] * FRAME_DT,
		RateOf (PRIMARY_OVERSHOOT + EDGE_DZ, nf[2]),
		WristSpeed (RateOf (PRIMARY_OVERSHOOT + EDGE_DZ, nf[2])));
	printf ("      D  dwell   parked at +%2.0f deg, %2d ticks, %.3f s\n",
		PRIMARY_OVERSHOOT, nf[3], nf[3] * FRAME_DT);
	printf ("      E  settle  +%2.0f ->   0 deg, %2d ticks, %.3f s, %3.0f deg/s, "
		"%.2f m/s\n", PRIMARY_OVERSHOOT, nf[4], nf[4] * FRAME_DT,
		RateOf (PRIMARY_OVERSHOOT, nf[4]),
		WristSpeed (RateOf (PRIMARY_OVERSHOOT, nf[4])));
	printf ("      phases: A %+8.3f  B1 %+8.3f  B2 %+8.3f  D %+8.3f  "
		"E %+8.3f\n", phase[0], phase[1], phase[2], phase[3], phase[4]);
	printf ("      COMMANDED (the whip, rx live) %+8.3f deg\n", phase[0]);
	printf ("      UNCOMMANDED (after the pulse) %+8.3f deg\n", AfterPulse (phase));
	printf ("      NET %+8.3f deg over %.3f s (negative is the turn's own way)\n",
		net, (nf[0] + nf[1] + nf[2] + nf[3] + nf[4]) * FRAME_DT);

	/* NOT an assertion on the net's sign. With nothing holding, the engine
	   is doing exactly what the edge turn says on the tin and is merely
	   uninformed about the whip, so asserting the turn's sign here would be
	   asserting that the engine is broken when the missing piece is the
	   hold. What IS invariant with no hold, and what the fix has to kill,
	   is that the hand's return turns the body on its own at all. The
	   amount is a function of the gesture, which is what the sweep is for,
	   and the one number that is not a matter of amplitude is zero. */
	CHECK (AfterPulse (phase) != 0.f,
	       "CASE 3: with nothing holding, the hand's return turns the body "
	       "on its own (%+.3f deg uncommanded against %+.3f commanded)",
	       AfterPulse (phase), phase[0]);

	Settle (40);
	RunSweep (phase[0]);

	/* Three invariants over the whole table, which together are the defect:
	   the return always turns the body, it turns it more the further the
	   hand goes past the gaze, and somewhere in the range of ordinary hand
	   motion it turns it further than the whip asked for and the net comes
	   out the other way. None of the three depends on which cell anyone
	   picks as representative. */
	{
		int	o, w, nonzero = 1, grows = 1, neg = 0, pos = 0;

		for (o = 0; o < SWEEP_OVERS; o++)
			for (w = 0; w < SWEEP_DWELLS; w++)
			{
				if (sweep_unc[o][w] == 0.f)
					nonzero = 0;
				if (sweep_net[o][w] < 0.f)
					neg++;
				else
					pos++;
				/* Signed, not absolute: the near-side stroke
				   ADDS to the whip, so the uncommanded term
				   starts negative and climbs through zero. */
				if (o > 0 && sweep_unc[o][w] <= sweep_unc[o - 1][w])
					grows = 0;
			}

		CHECK (nonzero,
		       "CASE 3: every cell of the sweep turns the body after the "
		       "pulse ended (%d cells)", SWEEP_OVERS * SWEEP_DWELLS);
		CHECK (grows,
		       "CASE 3: and the uncommanded turn grows with the overshoot "
		       "at every dwell (%+.3f -> %+.3f -> %+.3f -> %+.3f at "
		       "%.2f s)", sweep_unc[0][2], sweep_unc[1][2],
		       sweep_unc[2][2], sweep_unc[3][2], sweep_dwell[2]);
		CHECK (neg > 0 && pos > 0,
		       "CASE 3: and the net's sign FLIPS inside the sweep (%d "
		       "cells the turn's way, %d against it)", neg, pos);
	}

	Settle (40);

	printf ("\n--- CASE 3b: the DEFECT at its worst, past the RAMP --------\n");
	/* A.'s estimate read off the code was that about 0.14 s of hand held
	   past the ramp cancels the whip. Past the ramp means past dz + 40 =
	   58 degrees from the gaze, where the edge turn is capped at the full
	   vr_edgeturn_speed. So this is the same gesture with the overshoot at
	   60 degrees and the hand parked there for 0.15 s: his geometry, not a
	   geometry hunted for. It is a LARGE cross-body overshoot -- a right
	   hand ending up 60 degrees left of where the player is looking -- and
	   whether a hand really goes that far is a device question. What this
	   case settles is only whether the arithmetic he predicted holds. */
	{
		float	d[5];
		int	fr[5];
		float	n = Gesture (60.f, PRIMARY_RATE, 0.15, 0, d, fr);

		printf ("      overshoot +60 deg, parked %.3f s (%d ticks)\n",
			fr[3] * FRAME_DT, fr[3]);
		printf ("      phases: A %+8.3f  B1 %+8.3f  B2 %+8.3f  D %+8.3f  "
			"E %+8.3f\n", d[0], d[1], d[2], d[3], d[4]);
		printf ("      COMMANDED %+8.3f, UNCOMMANDED %+8.3f\n",
			d[0], AfterPulse (d));
		printf ("      NET %+8.3f deg\n", n);
		/* The two sweep strokes alone: what the hand spent getting out
		   there and back, before it ever stopped moving. */
		ramp_sweeps = d[2] + d[4];
		/* Again not a sign assertion. The invariant worth holding here
		   is the SIZE of what nobody asked for: once the hand reaches
		   past the ramp, the uncommanded turn is larger than the whole
		   commanded turn, so no amount of tuning the deadzone or the
		   ramp rescues this gesture and the hold is the only answer. */
		CHECK (fabsf (AfterPulse (d)) > fabsf (d[0]),
		       "CASE 3b: past the ramp the uncommanded turn (%+.3f) is "
		       "bigger than the whole commanded one (%+.3f)",
		       AfterPulse (d), d[0]);
	}

	/* The estimate A. read off the code, corrected by the measurement. The
	   0.140 s is real but it is a RATE floor, not the gesture's break even:
	   by the time a hand has swung far enough out for the ramp to be
	   capped, the sweep out and back has already paid more than the whip
	   was worth, so the reversal happens before the hand ever parks. */
	printf ("\n      past the ramp (held at -68 deg) CASE 2 measured %.1f "
		"deg/s, so %.3f s of\n      parked hand is worth one whip. "
		"That is a floor on the DWELL only: CASE 3b\n      swept out to "
		"60 deg and home at 60 deg/s and spent %+.1f deg on the two\n"
		"      sweeps alone, against the whip's %.1f, so a hand that "
		"reaches past the\n      ramp has already reversed the turn "
		"before it stops moving.\n",
		fabsf (r68), fabsf (phase[0]) / fabsf (r68), ramp_sweeps,
		fabsf (phase[0]));

	Settle (40);

	printf ("\n--- CASE 4: the fix's guard, hold until SETTLED ------------\n");
	/*
	  THE CONTRACT. This is the engine's half of what HandInput.swift now
	  publishes as (turnHold || !flickArmed): the hold stays asserted from
	  the end of the rx pulse until the whip's own re-arm test passes, which
	  is the hand being inside the deadzone AND slow, not merely inside it.

	  Both assertions matter and for different reasons. The net says the
	  player got the turn he asked for. The uncommanded term being EXACTLY
	  zero is the one that catches a partial suppression: a hold that
	  covered most of the return would still leave a net near the whip and
	  look fine, and the drift A. reported is precisely a small residue
	  that nobody can see in a single number.
	*/
	net4 = Gesture (PRIMARY_OVERSHOOT, PRIMARY_RATE, PRIMARY_DWELL, 2, c4, nf4);
	printf ("      hold asserted over B1, B2, the dwell and the way home; "
		"the tail of E is\n      inside the deadzone and contributes "
		"nothing either way.\n");
	printf ("      phases: A %+8.3f  B1 %+8.3f  B2 %+8.3f  D %+8.3f  "
		"E %+8.3f\n", c4[0], c4[1], c4[2], c4[3], c4[4]);
	printf ("      COMMANDED %+8.3f, UNCOMMANDED %+8.3f\n",
		c4[0], AfterPulse (c4));
	printf ("      NET %+8.3f deg (CASE 3, nothing holding, was %+8.3f)\n",
		net4, net);
	CHECK (AfterPulse (c4) == 0.f,
	       "CASE 4: the uncommanded turn is EXACTLY zero (%+.4f deg over "
	       "B1+B2+dwell+E)", AfterPulse (c4));
	CHECK (fabsf (net4 - phase[0]) < 0.01f && fabsf (net4 + 12.6f) < 0.05f,
	       "CASE 4: and the net is the whip and nothing but the whip "
	       "(%+.3f deg against the whip's %+.3f)", net4, phase[0]);

	Settle (40);

	printf ("\n--- CASE 4R: the REJECTED release condition ----------------\n");
	/*
	  Kept, and asserted, because it is the trap. Releasing the hold the
	  moment the hand is back inside the deadzone reads simpler than waiting
	  for it to settle, needs no re-arm state, and is the obvious thing to
	  write -- and it measures WORSE THAN NO FIX AT ALL, because the stroke
	  it suppresses (B1, the near side of the return) is the one that was
	  ADDING to the whip, while the overshoot that opposes the whip happens
	  entirely after the release.

	  So this case asserts the BAD outcome on purpose. If someone later
	  simplifies the Swift side to release on first re-entry, this is the
	  assertion that stops it: the day it starts passing for the right
	  reason, CASE 4's numbers will say so and this case should be deleted
	  in the same commit.
	*/
	{
		float	d[5];
		int	fr[5];
		float	n = Gesture (PRIMARY_OVERSHOOT, PRIMARY_RATE,
				     PRIMARY_DWELL, 1, d, fr);

		printf ("      hold released at -18 deg, coming back from the "
			"whip's side\n");
		printf ("      phases: A %+8.3f  B1 %+8.3f  B2 %+8.3f  D %+8.3f  "
			"E %+8.3f\n", d[0], d[1], d[2], d[3], d[4]);
		printf ("      COMMANDED %+8.3f, UNCOMMANDED %+8.3f\n",
			d[0], AfterPulse (d));
		printf ("      NET %+8.3f deg (CASE 3 %+8.3f, CASE 4 %+8.3f)\n",
			n, net, net4);
		CHECK (d[1] == 0.f,
		       "CASE 4R: it suppresses the stroke that HELPED the whip "
		       "(%+.4f deg, against %+.4f with no hold)", d[1], phase[1]);
		CHECK (n > 0.f,
		       "CASE 4R: and so it REVERSES the turn (%+.3f deg), which "
		       "is worse than holding nothing at all (%+.3f)", n, net);
		CHECK (n > net,
		       "CASE 4R: strictly worse than no fix, which is why this "
		       "release condition is rejected (%+.3f vs %+.3f)", n, net);
	}

	Settle (40);

	printf ("\n--- CASE 5: a pure turn must not translate the player ------\n");
	/* The already-fixed invariant: every deliberate heading goes through
	   IN_SnapTurn, which settles the body under the head and rotates the
	   absorption ledger with it, instead of writing qr_body_yaw bare and
	   pivoting about the recenter anchor. No head offset is fed here, so
	   this exercises the ZERO-LEDGER path only: it is a guard against a
	   turn path that translates unconditionally, not against the chord that
	   a non-zero ledger used to pay for. ly = 0, nothing but the turn. */
	VectorCopy (svs.clients[0].edict->v.origin, org0);
	fwd_yaw = qr_body_yaw;
	drift = Hold (-48.f, 67, 0.f, 0);
	VectorCopy (svs.clients[0].edict->v.origin, org1);
	dx = org1[0] - org0[0];
	dy = org1[1] - org0[1];
	along   = (float) (dx * cos (fwd_yaw * M_PI / 180.0)
			 + dy * sin (fwd_yaw * M_PI / 180.0));
	lateral = (float) (-dx * sin (fwd_yaw * M_PI / 180.0)
			 + dy * cos (fwd_yaw * M_PI / 180.0));
	printf ("      turned %+.3f deg with no movement input\n", drift);
	printf ("      origin moved %.4f along / %.4f lateral (%.4f total, "
		"Quake units)\n", along, lateral, sqrtf (dx*dx + dy*dy));
	CHECK (fabsf (drift) > 10.f, "CASE 5: the turn actually happened (%+.2f deg)",
	       drift);
	CHECK (sqrtf (dx*dx + dy*dy) < 1.f,
	       "CASE 5: and the player stayed put (%.4f units)",
	       sqrtf (dx*dx + dy*dy));
	/* The origin above means nothing if it belongs to a corpse or to a
	   respawn, so prove it is the same live player the run started with. */
	CHECK (svs.clients[0].edict->v.health > 0.f,
	       "CASE 5: and it is still the same live player (health=%.0f)",
	       svs.clients[0].edict->v.health);

	Settle (40);

	printf ("\n--- CASE 6: does it compound over repeated turns? ----------\n");
	/* Secondary. Three of CASE 3's gesture back to back, with 0.6 s of
	   parked hand between them -- past HandInput's flickDwell 0.12 s under
	   flickReset, so the flick RE-ARMS and each turn gets its own pulse,
	   which is what three deliberate turns in a row actually look like. */
	{
		float	total = 0.f, after = 0.f, d[5];
		int	fr[5], k;

		for (k = 0; k < 3; k++)
		{
			float n = Gesture (PRIMARY_OVERSHOOT, PRIMARY_RATE,
					   PRIMARY_DWELL, 0, d, fr);
			total += n;
			after += AfterPulse (d);
			printf ("      turn %d: commanded %+8.3f, uncommanded "
				"%+8.3f, net %+8.3f\n", k + 1, d[0],
				AfterPulse (d), n);
			Settle (40);
		}
		printf ("      3 turns: commanded %+8.3f, uncommanded %+8.3f, "
			"NET %+8.3f\n", total - after, after, total);
		printf ("      (CASE 3 alone was %+8.3f, so 3x would be %+8.3f)\n",
			net, 3.f * net);
		CHECK (total < 0.f,
		       "CASE 6: three turns in a row net %+.3f deg, still the "
		       "whip's way", total);
		/* The invariant, as opposed to that sign: the error does not
		   feed back. Each turn starts from a centred hand, so each one
		   pays the same uncommanded term and three turns cost three
		   times one turn rather than growing. That is worth pinning,
		   because a drift that compounded would be a different and much
		   worse bug than the one measured here. The sign above inherits
		   the primary point's amplitude; this does not. */
		CHECK (fabsf (total - 3.f * net) < 0.01f,
		       "CASE 6: and it is LINEAR, not compounding (%+.3f against "
		       "3 x %+.3f = %+.3f)", total, net, 3.f * net);
	}

	printf ("\n%s (%d failure%s)\n", failures ? "FAILURES" : "all passed",
		failures, failures == 1 ? "" : "s");
	QC_Shutdown ();
	return failures ? 1 : 0;
}
