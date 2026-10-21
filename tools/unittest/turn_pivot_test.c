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
#include <stdio.h>
#include <math.h>

/* in_null.c, file-local extern the way qr_bridge.c takes its globals. */
void	IN_HeadOffsetAtYaw (const float head[3], float yaw, float out[2]);
void	IN_RotateBodyVec (float v[2], float degrees);

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
	CHECK (len2 (residual) > 0.25f,
	       "and the chord clears the absorb deadzone, so it is walked as movement");

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

	printf ("%s\n", failures ? "UNIT FAIL" : "UNIT PASS");
	return failures ? 1 : 0;
}
