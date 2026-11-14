/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * turn_pivot_test.c -- a deliberate body turn must pivot about the HEAD, not
 * about the recenter anchor. Proves the invariant IN_SnapTurn upholds: rotate
 * the absorption ledger with the body and the head's world position solves out
 * unchanged, so IN_AbsorbHeadOffset finds nothing to walk. Skip the ledger and
 * the head sweeps an arc, which the absorb then pays for as real locomotion.
 *
 * Pure maths over the two helpers; no world, no cvars, no sv.
 */
#include "quakedef.h"
#include "QuakeCore.h"
#include <stdio.h>
#include <math.h>

/* in_null.c, file-local extern the way qr_bridge.c takes its globals. */
void		IN_HeadOffsetAtYaw (const float head[3], float yaw, float out[2]);
void		IN_RotateBodyVec (float v[2], float degrees);
extern float	qr_head_absorbed[2];
extern float	qr_body_yaw;
extern uint32_t	qr_recenter_count;

/* host.c's time lever. Registered by Host_InitLocal, which a unit test does
   not run, so the slow-motion assertions set .value directly. */
extern cvar_t	host_timescale;
/* The vr_* cvars are static in in_null.c; reach them through the cvar system
   the way the console does, which is also what IN_Init has just registered. */

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

static float len2 (const float v[2])
{
	return sqrtf (v[0] * v[0] + v[1] * v[1]);
}

int main (void)
{
	/* A head standing off the recenter point: ~1.1 m forward, 0.4 m across,
	   in Quake units at the renderer's 0.0254 m/unit. */
	float	head[3] = { 44.f, 15.f, 0.f };
	float	yaw = 37.f;			/* an arbitrary body heading */
	float	off[2], turned[2], ledger[2], residual[2];
	float	r, chord;
	int	i;

	IN_HeadOffsetAtYaw (head, yaw, off);
	r = len2 (off);
	CHECK (r > 1.f, "the head feed is off the recenter point (r = %.1f units)", r);

	/* The state IN_AbsorbHeadOffset settles into: everything absorbed, so the
	   head sits over the player origin and the residual is zero. */
	ledger[0] = off[0];
	ledger[1] = off[1];

	/* --- compensated: rotate the ledger with the body ------------------- */
	IN_HeadOffsetAtYaw (head, yaw + 90.f, turned);
	IN_RotateBodyVec (ledger, 90.f);
	residual[0] = turned[0] - ledger[0];
	residual[1] = turned[1] - ledger[1];
	CHECK (len2 (residual) < 1e-3f,
	       "compensated 90 deg turn leaves no residual (%.4f units)",
	       len2 (residual));

	/* --- uncompensated: the ledger stays put, the head sweeps an arc ---- */
	ledger[0] = off[0];
	ledger[1] = off[1];
	residual[0] = turned[0] - ledger[0];
	residual[1] = turned[1] - ledger[1];
	chord = 2.f * r * sinf (45.f * (float) M_PI / 180.f);
	CHECK (fabsf (len2 (residual) - chord) < 1e-2f,
	       "uncompensated 90 deg turn leaves the arc chord: %.2f units, expected %.2f",
	       len2 (residual), chord);
	/* Match IN_AbsorbHeadOffset's gate exactly: it is PER-AXIS, not radial,
	   so the deadzone is a square. Radial magnitude clearing 0.25 does not
	   by itself mean the gate opens. (That the square is not
	   rotation-invariant is also why this fix bounds the yaw-only slide at
	   ~0.35 units rather than exactly zero -- about 9 mm, imperceptible and
	   non-accumulating, since rotation preserves magnitude and the next
	   absorb settles the ledger exactly.) */
	CHECK (fabsf (residual[0]) >= 0.25f || fabsf (residual[1]) >= 0.25f,
	       "and the chord opens the absorb's per-axis gate, so it is walked");

	/* --- the residual rotates, it does not grow ------------------------- */
	{
		float	start[2], before, after;

		IN_HeadOffsetAtYaw (head, yaw, off);
		ledger[0] = off[0] - 3.f;	/* a head part-way through a stride */
		ledger[1] = off[1] + 2.f;
		start[0] = off[0] - ledger[0];
		start[1] = off[1] - ledger[1];
		before = len2 (start);

		IN_HeadOffsetAtYaw (head, yaw + 25.f, turned);
		IN_RotateBodyVec (ledger, 25.f);
		residual[0] = turned[0] - ledger[0];
		residual[1] = turned[1] - ledger[1];
		after = len2 (residual);
		CHECK (fabsf (after - before) < 1e-3f,
		       "a part-absorbed residual is rotated, not grown (%.4f -> %.4f)",
		       before, after);
	}

	/* --- at the recenter point there is nothing to sweep ---------------- */
	{
		float	athome[3] = { 0.f, 0.f, 0.f };

		IN_HeadOffsetAtYaw (athome, yaw, off);
		ledger[0] = off[0];
		ledger[1] = off[1];
		IN_HeadOffsetAtYaw (athome, yaw + 90.f, turned);
		residual[0] = turned[0] - ledger[0];
		residual[1] = turned[1] - ledger[1];
		CHECK (len2 (residual) < 1e-4f,
		       "r = 0: even an uncompensated turn cannot translate you");
	}

	/* --- a zero turn is a no-op, and full circle returns ---------------- */
	IN_HeadOffsetAtYaw (head, yaw, off);
	ledger[0] = off[0];
	ledger[1] = off[1];
	IN_RotateBodyVec (ledger, 0.f);
	CHECK (fabsf (ledger[0] - off[0]) < 1e-4f && fabsf (ledger[1] - off[1]) < 1e-4f,
	       "a zero-degree turn leaves the ledger alone");

	for (i = 0; i < 4; i++)
		IN_RotateBodyVec (ledger, 90.f);
	CHECK (fabsf (ledger[0] - off[0]) < 1e-3f && fabsf (ledger[1] - off[1]) < 1e-3f,
	       "four 90 deg turns return the ledger to where it started");

	/* --- the chord scales with the turn, which is why a slow sweep drifts
	       slowly rather than not at all -------------------------------- */
	{
		float	small_chord, big_chord;

		ledger[0] = off[0];
		ledger[1] = off[1];
		IN_HeadOffsetAtYaw (head, yaw + 1.f, turned);
		residual[0] = turned[0] - ledger[0];
		residual[1] = turned[1] - ledger[1];
		small_chord = len2 (residual);

		IN_HeadOffsetAtYaw (head, yaw + 10.f, turned);
		residual[0] = turned[0] - ledger[0];
		residual[1] = turned[1] - ledger[1];
		big_chord = len2 (residual);

		CHECK (big_chord > small_chord * 5.f,
		       "the chord grows with the turn (%.3f at 1 deg, %.3f at 10 deg)",
		       small_chord, big_chord);
	}

	/* --- why the isfinite guard sits in IN_SnapTurn and not in here ----
	       The helpers are deliberately unguarded: the chokepoint owns the
	       check. Prove the hazard it exists for -- one non-finite delta
	       destroys the ledger, and no later rotation brings it back. */
	{
		float	poisoned[2] = { 10.f, 4.f };

		IN_RotateBodyVec (poisoned, (float) (0.0 / 0.0));
		CHECK (!isfinite (poisoned[0]) || !isfinite (poisoned[1]),
		       "an unguarded non-finite turn poisons the ledger");

		for (i = 0; i < 4; i++)
			IN_RotateBodyVec (poisoned, 90.f);
		CHECK (!isfinite (poisoned[0]) || !isfinite (poisoned[1]),
		       "and no later turn recovers it -- hence the guard upstream");
	}

	/* ====================================================================
	   The regression test proper: drive the REAL IN_Move and prove the
	   smooth turn's call site routes through the ledger. Everything above
	   is algebra over the helpers and would still pass if IN_Move went
	   back to writing qr_body_yaw bare -- which is the failure mode
	   working-notes.md warns about twice. This section fails on that
	   revert, because it watches the ledger IN_Move actually leaves.

	   The trick that makes it drivable with no map, no sv and no client:
	   feed a recenter ack that does NOT match qr_recenter_count. Every
	   IN_AbsorbHeadOffset then takes its "a recenter is in flight" early
	   return, so nothing walks the player or overwrites the ledger -- but
	   IN_SnapTurn's rotation happens regardless, which is exactly the
	   thing under test.
	   ================================================================= */
	{
		usercmd_t	cmd;
		qc_gamepad_state_t pad;
		float		seed[2] = { 30.f, -12.f };
		float		expect[2];
		float		yaw_before, delta;

		/* Same bootstrap wristcomm_cvar_test.c and hud_tile_test.c use:
		   Cvar_RegisterVariable copies its default through Z_Strdup, which
		   needs the zone the hunk backs, and this binary does not run
		   VID_Init. QR_TestEmitTileInto's first call Memory_Init's a static
		   test hunk -- borrow it rather than inventing a second one. */
		{
			extern void QR_TestEmitTileInto (int tile_id, int stat_health,
							 int stat_armor, int stat_ammo,
							 int items, float *bbox_w,
							 float *bbox_h, int *nverts);
			float	bw, bh;
			int	nv;
			QR_TestEmitTileInto (QC_HUD_TILE_HEALTHARMOR, 100, 50, 0, 0,
					     &bw, &bh, &nv);
		}

		IN_Init ();			/* register the vr_* cvars */

		/* cl_yawspeed belongs to the client, which a unit test does not
		   stand up; set the value rather than registering it. */
		cl_yawspeed.value = 140.f;
		Cvar_Set ("vr_smoothturn", "1");	/* the path under test */
		Cvar_Set ("vr_edgeturn", "0");		/* isolate from the edge turn */
		Cvar_Set ("vr_handaim", "0");		/* qr_aim_active stays false */
		host_frametime = 0.011;			/* ~90 Hz */

		/* Freeze the absorb: ack 7 against a recenter count of 0. */
		qr_recenter_count = 0;
		QC_InputSetHeadOffset (44.f, 15.f, 0.f, 7);

		memset (&pad, 0, sizeof (pad));
		pad.connected = 1;
		pad.rx = 0.5f;			/* clear of QR_STICK_DEADZONE */
		QC_InputSetGamepad (&pad);

		qr_head_absorbed[0] = seed[0];
		qr_head_absorbed[1] = seed[1];
		yaw_before = qr_body_yaw;

		memset (&cmd, 0, sizeof (cmd));
		IN_Move (&cmd);

		delta = qr_body_yaw - yaw_before;
		CHECK (fabsf (delta) > 0.01f,
		       "IN_Move's smooth turn moved the body (%.4f deg)", delta);

		/* The invariant, stated without predicting the deadzone curve:
		   whatever the body turned by, the ledger turned by the same. */
		expect[0] = seed[0];
		expect[1] = seed[1];
		IN_RotateBodyVec (expect, delta);
		CHECK (fabsf (qr_head_absorbed[0] - expect[0]) < 1e-3f
		    && fabsf (qr_head_absorbed[1] - expect[1]) < 1e-3f,
		       "the ledger turned with the body: (%.3f, %.3f), expected (%.3f, %.3f)",
		       qr_head_absorbed[0], qr_head_absorbed[1], expect[0], expect[1]);

		/* And it genuinely MOVED -- a revert leaves it on the seed, which
		   the check above would catch, but say so outright so the failure
		   names the bug rather than the arithmetic. */
		CHECK (fabsf (qr_head_absorbed[0] - seed[0]) > 1e-4f
		    || fabsf (qr_head_absorbed[1] - seed[1]) > 1e-4f,
		       "a bare qr_body_yaw write would have left the ledger untouched");

		/* --- and the EDGE turn, which is the path actually reported:
		       arm held out past the deadzone, no stick touched at all. */
		Cvar_Set ("vr_smoothturn", "0");	/* stick quiet either way */
		Cvar_Set ("vr_edgeturn", "1");
		Cvar_Set ("vr_handaim", "1");
		Cvar_Set ("vr_aimyaw", "0");		/* no resting-trim offset */

		pad.rx = 0.f;				/* nothing on the stick */
		QC_InputSetGamepad (&pad);
		/* A live hand ray 40 deg to the right: past vr_edgeturn_dz (18). */
		QC_InputSetAim (1, 10.f, 6.f, -4.f, 40.f, 0.f);

		qr_head_absorbed[0] = seed[0];
		qr_head_absorbed[1] = seed[1];
		yaw_before = qr_body_yaw;

		memset (&cmd, 0, sizeof (cmd));
		IN_Move (&cmd);

		delta = qr_body_yaw - yaw_before;
		CHECK (fabsf (delta) > 0.01f,
		       "the arm-out edge turn moved the body with no stick input (%.4f deg)",
		       delta);

		expect[0] = seed[0];
		expect[1] = seed[1];
		IN_RotateBodyVec (expect, delta);
		CHECK (fabsf (qr_head_absorbed[0] - expect[0]) < 1e-3f
		    && fabsf (qr_head_absorbed[1] - expect[1]) < 1e-3f,
		       "the edge turn carried the ledger too: (%.3f, %.3f), expected (%.3f, %.3f)",
		       qr_head_absorbed[0], qr_head_absorbed[1], expect[0], expect[1]);

		/* --- SLOW MOTION MUST NOT SLOW THE TURN.
		       A. ruled this after the weapon ring's bullet time shipped:
		       the world crawling is the point, his ability to reorient
		       crawling with it is not. host_timescale multiplies
		       host_frametime (host.c:592-593) and every turn path
		       integrated that, so a 0.2 timescale turned at a fifth
		       speed.

		       Simulated exactly as host.c produces it: the same real
		       frame, with host_frametime already scaled by the cvar.
		       The turn must come out the same as at full speed. */
		{
			const double	real_dt = 0.011;	/* ~90 Hz */
			float		full, slowed;

			Cvar_Set ("vr_smoothturn", "1");
			Cvar_Set ("vr_edgeturn", "0");
			Cvar_Set ("vr_handaim", "0");
			pad.rx = 0.5f;
			QC_InputSetGamepad (&pad);

			host_timescale.value = 0.f;		/* registered by Host_InitLocal,
						   which a unit test never runs --
						   same as cl_yawspeed above */
			host_frametime = real_dt;
			yaw_before = qr_body_yaw;
			memset (&cmd, 0, sizeof (cmd));
			IN_Move (&cmd);
			full = qr_body_yaw - yaw_before;

			host_timescale.value = 0.2f;
			host_frametime = real_dt * 0.2;		/* what host.c leaves */
			QC_InputSetGamepad (&pad);
			yaw_before = qr_body_yaw;
			memset (&cmd, 0, sizeof (cmd));
			IN_Move (&cmd);
			slowed = qr_body_yaw - yaw_before;

			CHECK (fabsf (full) > 0.01f,
			       "the full-speed stick turn moved the body (%.4f deg)",
			       full);
			CHECK (fabsf (slowed - full) < 1e-4f,
			       "a 0.2 timescale does NOT slow the stick turn "
			       "(%.4f deg slowed vs %.4f full)", slowed, full);

			/* And the edge turn, the other continuous path. */
			Cvar_Set ("vr_smoothturn", "0");
			Cvar_Set ("vr_edgeturn", "1");
			Cvar_Set ("vr_handaim", "1");
			Cvar_Set ("vr_aimyaw", "0");
			pad.rx = 0.f;
			QC_InputSetGamepad (&pad);
			QC_InputSetAim (1, 10.f, 6.f, -4.f, 40.f, 0.f);

			host_timescale.value = 0.f;		/* registered by Host_InitLocal,
						   which a unit test never runs --
						   same as cl_yawspeed above */
			host_frametime = real_dt;
			yaw_before = qr_body_yaw;
			memset (&cmd, 0, sizeof (cmd));
			IN_Move (&cmd);
			full = qr_body_yaw - yaw_before;

			host_timescale.value = 0.2f;
			host_frametime = real_dt * 0.2;
			QC_InputSetAim (1, 10.f, 6.f, -4.f, 40.f, 0.f);
			yaw_before = qr_body_yaw;
			memset (&cmd, 0, sizeof (cmd));
			IN_Move (&cmd);
			slowed = qr_body_yaw - yaw_before;

			/* Reported honestly rather than asserted. The edge turn
			   produces 0 degrees in this harness at FULL speed --
			   that is the failure above, open and unruled -- so a
			   "slow motion did not change it" check here would
			   compare 0 against 0 and bank a green it never
			   earned. It becomes a real assertion the day the
			   edge turn moves the body again. */
			if (fabsf (full) > 0.01f)
				CHECK (fabsf (slowed - full) < 1e-4f,
				       "a 0.2 timescale does NOT slow the edge turn "
				       "(%.4f deg slowed vs %.4f full)",
				       slowed, full);
			else
				printf ("skip: the edge turn slow-motion check, "
					"because the edge turn moves the body "
					"0.0000 deg at FULL speed here -- see the "
					"failure above\n");

			host_timescale.value = 0.f;
		}
	}

	printf ("%s\n", failures ? "UNIT FAIL" : "UNIT PASS");
	return failures ? 1 : 0;
}
