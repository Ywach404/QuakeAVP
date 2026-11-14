/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * gymtest.c -- boot the engine, load the swing gym, and throw the hook at
 * real geometry. Deviceless proof that the C-owned hook flies, stops where
 * the world stops it, and refuses to hang from sky. Link against
 * ${TMPDIR}/quakecore-hostbuild/[star].o minus hostmain.o (see
 * tools/range/README.md).
 *
 * Two maps on purpose, and the pairing is the point. The gym has a CONCRETE
 * ceiling, chosen so that an upward throw has something to catch
 * (gengym.py:16-21), so in the gym a throw straight up must anchor. The
 * range has a sky lid, so the same throw there must NOT anchor. One action,
 * two maps, opposite results: that is the sky rule proven against a real
 * world rather than against a hand-built trace, which grapple_anchor_test
 * already covers.
 *
 * Straight up rather than along the hall because the gym spawns the player
 * in a corner at (-2944, -2944) facing 45 degrees, which is pointing into
 * column (0,0)'s corner at point-blank range. Up is 3032 units of clear air
 * to a hookable surface, which is a flight worth measuring.
 */

#include "quakedef.h"
#include "QuakeCore.h"
#include "grapple_avp.h"
#include <stdio.h>
#include <math.h>

/* The audio sink is Swift and is not in the host objects; hostmain.c carries
 * the same four stand-ins for `make check`, and the unit harness gets them
 * from tools/unittest/support instead. Returning 0 from open leaves the
 * engine with no sound device, which is the right headless answer. */
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

/* grapple_avp.c's QAVP_HOSTCHECK seam. The hook is not wired into
   Grapple_Frame until Task 2, so the driver throws and advances it here. */
int  Grapple_TestState (float tip[3]);
void Grapple_TestThrow (void);
void Grapple_TestFlight (float dt);

/* gengym.py: HALF 3328, TOP 3072, SHELL 64, so the ceiling's underside. */
#define GYM_CEIL_Z	3072.f

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)
static void on_log (void *c, const char *t) { (void)c; fputs (t, stdout); }
static void on_error (void *c, const char *e) { (void)c; if (e) printf("FATAL: %s\n", e); }

/* One tick of engine plus one tick of hook. Grapple_Frame does not drive the
   flight yet, so the driver supplies the same dt the engine just ran. */
static void step (int n)
{
	int i;
	for (i = 0; i < n; i++)
	{
		QC_Frame (1.0/72.0);
		Grapple_TestFlight (1.f/72.f);
	}
}

/* Aim the player's weapon angles without going through the input layer,
   which would also move the body. v_angle is what a throw reads. */
static void aim (float pitch, float yaw)
{
	edict_t *p = svs.clients[0].edict;
	p->v.v_angle[PITCH] = pitch;
	p->v.v_angle[YAW] = yaw;
	p->v.v_angle[ROLL] = 0.f;
}

/*
Put the player somewhere and keep it there.

NOCLIP and a zeroed velocity, which matters more than it looks. The throw's
origin is the player's, so anything that moves the player between two throws
changes what the second one is testing -- and ordinary physics moves it a lot:
the first version of this driver let the player fall and slide for the ~32
frames a throw takes to settle, and the second throw then went out from
somewhere else entirely and anchored where the first had found sky.

The gym's own spawn cannot be used for a throw at all. info_player_start sits
at (-2944, -2944) and column (0,0) spans x and y from -2944, so the spawn is on
the column's corner plane and an upward trace from it reports startsolid. That
is the map's business, not the hook's, but it means a test must pick its own
ground.
*/
static void place (float x, float y, float z)
{
	edict_t *p = svs.clients[0].edict;

	p->v.movetype = MOVETYPE_NOCLIP;
	p->v.origin[0] = x;
	p->v.origin[1] = y;
	p->v.origin[2] = z;
	p->v.velocity[0] = p->v.velocity[1] = p->v.velocity[2] = 0.f;
	SV_LinkEdict (p, false);
}

/* Throw and run until the hook stops flying, or give up. Returns the state. */
static int throw_and_settle (int max_frames, vec3_t out_tip)
{
	int state, i;

	Grapple_TestThrow ();
	state = Grapple_TestState (out_tip);
	for (i = 0; i < max_frames && state == GRAPPLE_FLYING; i++)
	{
		step (1);
		state = Grapple_TestState (out_tip);
	}
	return state;
}

/* Find a spot in the current map from which straight up ends in sky. The
   range has a sky lid but it also has crossbeams and a coffer grid under it,
   so a hardcoded position would be asserting against today's layout. Search
   instead, and fail loudly if nothing is found rather than passing quietly. */
static int find_sky_spot (vec3_t out)
{
	edict_t	*p = svs.clients[0].edict;
	vec3_t	from, to;
	trace_t	tr;
	float	x, y;

	for (y = -2048.f; y <= 2048.f; y += 352.f)
	{
		for (x = -2048.f; x <= 2048.f; x += 352.f)
		{
			from[0] = to[0] = x;
			from[1] = to[1] = y;
			from[2] = 64.f;
			to[2] = 8192.f;
			tr = SV_Move (from, vec3_origin, vec3_origin, to, MOVE_MISSILE, p);
			if (tr.fraction < 1.f
			    && SV_PointContents (tr.endpos) == CONTENTS_SKY)
			{
				VectorCopy (from, out);
				return 1;
			}
		}
	}
	return 0;
}

int main (int argc, char **argv)
{
	vec3_t	tip, first_tip, hand, spot;
	int	state;
	float	travelled;

	if (argc < 2) return 2;
	QC_SetCallbacks (on_log, on_error, NULL);
	QC_SetPaths (argv[1], argv[1]);
	{ const char *a[2] = { "-basedir", argv[1] };
	  if (!QC_Init (2, a)) { printf ("init failed\n"); return 1; } }

	/* ---------------- the gym: a concrete ceiling, so up anchors -------- */

	QC_ExecuteCommand ("map gym\n");
	step (120);
	CHECK (sv.active && cls.signon == 4,
	       "gym.bsp loads and connects (signon=%d)", cls.signon);
	CHECK (cl.worldmodel && !strcmp (cl.worldmodel->name, "maps/gym.bsp"),
	       "worldmodel is the gym");

	/* A clear column of air to the ceiling. Columns sit on a 1408 grid at
	   multiples of 1408 with COL_HALF 128, and the two crossbeams under the
	   ceiling are only 96 either side of each axis, so the half-pitch point
	   (704, 704) has nothing between it and the ceiling. Picked by the
	   layout rather than by eye: gengym.py PITCH 1408, COL_HALF 128. */
	place (704.f, 704.f, 40.f);
	step (2);
	VectorCopy (svs.clients[0].edict->v.origin, hand);
	printf ("      (throwing from %.0f %.0f %.0f)\n", hand[0], hand[1], hand[2]);
	aim (-90.f, 0.f);			/* straight up */

	Grapple_TestThrow ();
	state = Grapple_TestState (first_tip);
	CHECK (state == GRAPPLE_FLYING, "a throw puts the hook in flight (state=%d)", state);

	step (1);
	Grapple_TestState (tip);
	travelled = fabsf (tip[2] - first_tip[2]);
	CHECK (travelled > 100.f,
	       "the hook travels (%.0f units in one frame)", travelled);

	state = GRAPPLE_FLYING;
	{
		int i;
		for (i = 0; i < 60 && state == GRAPPLE_FLYING; i++)
		{
			step (1);
			state = Grapple_TestState (tip);
		}
		CHECK (state == GRAPPLE_ANCHORED,
		       "the hook anchors on the ceiling within 60 frames (state=%d, %d frames)",
		       state, i);
	}
	CHECK (SV_PointContents (tip) != CONTENTS_SOLID,
	       "the anchor is not inside solid");
	CHECK (fabsf (tip[2] - GYM_CEIL_Z) < 8.f,
	       "the anchor sits on the ceiling underside (z=%.1f, expected %.0f)",
	       tip[2], GYM_CEIL_Z);
	CHECK (tip[2] > hand[2] + 1000.f,
	       "and it is a long way above the hand (%.0f units)", tip[2] - hand[2]);

	/* ---------------- the range: a sky lid, so up must NOT anchor ------- */

	QC_ExecuteCommand ("map range\n");
	step (120);
	CHECK (cl.worldmodel && !strcmp (cl.worldmodel->name, "maps/range.bsp"),
	       "worldmodel is the range");

	if (!find_sky_spot (spot))
	{
		failures++;
		printf ("FAIL: no spot in the range has sky straight up, so the sky "
			"rule cannot be tested here\n");
	}
	else
	{
		place (spot[0], spot[1], spot[2]);
		aim (-90.f, 0.f);
		printf ("      (sky spot %.0f %.0f %.0f)\n", spot[0], spot[1], spot[2]);

		state = throw_and_settle (200, tip);
		CHECK (state == GRAPPLE_IDLE,
		       "a throw at the sky lid never anchors (state=%d)", state);

		/* Put it back, because 200 frames of engine have run since. */
		place (spot[0], spot[1], spot[2]);
		aim (-90.f, 0.f);

		/* Re-arming: a sky miss must leave the module able to throw
		   again. Checked on the tick of the throw, because by the time
		   it has settled it is back to IDLE either way -- which is what
		   made the first version of this assertion vacuous. */
		Grapple_TestThrow ();
		state = Grapple_TestState (tip);
		CHECK (state == GRAPPLE_FLYING,
		       "a second throw after a sky miss flies again (state=%d)", state);

		{
			int i;
			for (i = 0; i < 200 && state == GRAPPLE_FLYING; i++)
			{
				step (1);
				state = Grapple_TestState (tip);
			}
		}
		CHECK (state == GRAPPLE_IDLE,
		       "and the sky refuses that one too (state=%d)", state);
	}

	printf (failures ? "\n%d FAILURES\n" : "\nall passed\n", failures);
	return failures ? 1 : 0;
}
