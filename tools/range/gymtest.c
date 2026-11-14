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
#include <string.h>

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
void Grapple_TestSetAnchor (const float anchor[3], float rope_len);
void Grapple_TestSetAnchorEnt (int entnum, const float ofs[3]);
int  Grapple_TestAnchorNum (void);
void Grapple_TestSwing (void);
void Grapple_TestDisengage (void);

/* The head's drawn pose: 1 when there is a head, with the origin, the
   angles and rogue's own frame choice (1 flying, 2 stuck). */
int  QR_GrappleHeadPose (float origin[3], float angles[3], int *frame);

/* host.c's frame length, which Grapple_SwingFrame reads as its dt. Set
   directly so a long frame can be tested without waiting for one. */
extern double	host_frametime;

/* gengym.py: HALF 3328, TOP 3072, SHELL 64, so the ceiling's underside. */
#define GYM_CEIL_Z	3072.f

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)
static void on_log (void *c, const char *t) { (void)c; fputs (t, stdout); }
static void on_error (void *c, const char *e) { (void)c; if (e) printf("FATAL: %s\n", e); }

/*
One tick of engine, and one of hook where the engine does not do it.

Grapple_Frame now drives the flight itself whenever an engagement is live, so
the extra Grapple_TestFlight call would DOUBLE the hook's speed if it ran then.
It is still needed for the seam-driven throws, which have no engagement behind
them, so it runs only when the state machine is not already doing it.
*/
static int	grip_held;

static void step (int n)
{
	int i;
	for (i = 0; i < n; i++)
	{
		QC_Frame (1.0/72.0);
		if (!grip_held)
			Grapple_TestFlight (1.f/72.f);
	}
}

/* Point v_angle at a world position. Quake's pitch is negative upward, which
   is why the vertical term is negated. */
static void aim_at (const vec3_t target)
{
	edict_t	*p = svs.clients[0].edict;
	float	dx, dy, dz, horiz;

	dx = target[0] - p->v.origin[0];
	dy = target[1] - p->v.origin[1];
	dz = target[2] - (p->v.origin[2] + 16.f);
	horiz = sqrtf (dx*dx + dy*dy);

	p->v.v_angle[YAW] = (float) (atan2 (dy, dx) * 180.0 / M_PI);
	p->v.v_angle[PITCH] = (float) (-atan2 (dz, horiz) * 180.0 / M_PI);
	p->v.v_angle[ROLL] = 0.f;
}

/* The player's grip, through the front door. */
static void grip (int down)
{
	qc_gamepad_state_t pad;

	memset (&pad, 0, sizeof (pad));
	pad.buttons = down ? QC_PAD_RSHOULDER : 0u;
	pad.connected = 1;
	grip_held = down;
	QC_InputSetGamepad (&pad);
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

/*
One frame of rope, measured.

Hangs an anchor at `off` from wherever the player is, with a rest length of
`rope_len`, zeroes the player's velocity, runs exactly one swing frame, and
returns the acceleration the rope applied along its own direction: the velocity
it added, divided by the frame it had to add it in.

That number is the feel. Every assertion built on it is checking that the
rewrite moved WHERE the anchor comes from without changing what the rope then
does with it.
*/
static float measure_pull (float ox, float oy, float oz, float rope_len, double dt)
{
	edict_t	*p = svs.clients[0].edict;
	vec3_t	anchor, dir, before, after;
	float	dist, dv;

	anchor[0] = p->v.origin[0] + ox;
	anchor[1] = p->v.origin[1] + oy;
	anchor[2] = p->v.origin[2] + oz;

	/* The rope is measured from roughly the chest (GRAPPLE_ROPE_UP 16), so
	   the direction the pull lands along is the anchor minus that, not the
	   anchor minus the origin. */
	dir[0] = ox;
	dir[1] = oy;
	dir[2] = oz - 16.f;
	dist = sqrtf (dir[0]*dir[0] + dir[1]*dir[1] + dir[2]*dir[2]);
	if (dist < 1.f)
		return 0.f;
	dir[0] /= dist; dir[1] /= dist; dir[2] /= dist;

	p->v.velocity[0] = p->v.velocity[1] = p->v.velocity[2] = 0.f;
	VectorCopy (p->v.velocity, before);

	Grapple_TestSetAnchor (anchor, rope_len);
	host_frametime = dt;
	Grapple_TestSwing ();

	VectorCopy (p->v.velocity, after);
	dv = (after[0] - before[0]) * dir[0]
	   + (after[1] - before[1]) * dir[1]
	   + (after[2] - before[2]) * dir[2];
	return dv / (float) dt;
}

int main (int argc, char **argv)
{
	vec3_t	tip, first_tip, hand, spot;
	int	state;
	float	travelled, got, dv;

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

	/* ---------------- the hook reaches the frame packet ----------------- */

	/* The renderer draws the rope and the head from these two fields, so
	   the plumbing is worth a numeric check even though what it looks like
	   is device-only. The tip must be the RESOLVED anchor, not the latch
	   position, or a rope tied to a moving platform would stay behind. */
	{
		const qc_frame_t *f;

		/* One more frame first. The loop above advanced the flight
		   through the test seam AFTER each QC_Frame, so the packet the
		   engine built on the frame the hook bit still held the frame
		   before it: FLYING, ten units short of the ceiling. Nothing is
		   wrong with the publish -- the shipped path runs the hook from
		   IN_Commands inside the frame, so it is in phase -- but the
		   driver has to let one more frame be built to see it. */
		step (1);
		f = QC_RendererAcquireFrame ();
		CHECK (f != NULL, "a frame packet is available");
		if (f)
		{
			CHECK (f->grapple_state == GRAPPLE_ANCHORED,
			       "the packet carries the anchored state (%d)",
			       f->grapple_state);
			CHECK (fabsf (f->grapple_tip[2] - GYM_CEIL_Z) < 8.f,
			       "and the hook tip (%.1f %.1f %.1f)",
			       f->grapple_tip[0], f->grapple_tip[1],
			       f->grapple_tip[2]);
			QC_RendererReleaseFrame ();
		}
	}

	/* ---------------- the hook head: pose, frame and model ------------- */

	/* A. asked for Dissolution of Eternity's own hook poly on the end of
	   the rope. The head is a WORLD object -- it flies, then it sits on a
	   wall -- and never welded to the hand the way the rope's near end is,
	   so it goes through the engine's ordinary alias path and gets real
	   lighting, depth and culling rather than being drawn Swift-side.
	   What is checkable here is the pose it is drawn with and whether the
	   model resolved; what it LOOKS like is device-only.

	   rogue's own QuakeC picks frame 1 in flight and frame 2 once stuck
	   (W_FireGrapple sets .frame 1, GrappleAnchor sets 2), so the hook
	   visibly changes pose when it bites. That is worth keeping. */
	{
		vec3_t	horigin, hangles, frozen;
		int	hframe = -1, drawn, i;

		place (704.f, 704.f, 40.f);
		step (2);
		aim (-90.f, 0.f);			/* straight up */
		Grapple_TestThrow ();

		drawn = QR_GrappleHeadPose (horigin, hangles, &hframe);
		Grapple_TestState (tip);
		CHECK (drawn == 1, "a hook in flight has a head to draw (%d)", drawn);
		CHECK (hframe == 1, "and it is on the flight frame (%d, want 1)", hframe);
		CHECK (fabsf (horigin[0] - tip[0]) < 0.01f
		       && fabsf (horigin[1] - tip[1]) < 0.01f
		       && fabsf (horigin[2] - tip[2]) < 0.01f,
		       "the head sits exactly on the rope's far end");
		/* VectorAngles puts straight up at pitch -90 (mathlib.c:193),
		   which is what orients an engine missile along its velocity. */
		CHECK (fabsf (hangles[0] + 90.f) < 1.f,
		       "a hook thrown straight up points straight up (pitch %.1f, want -90)",
		       hangles[0]);

		for (i = 0; i < 60 && Grapple_TestState (tip) == GRAPPLE_FLYING; i++)
			step (1);
		drawn = QR_GrappleHeadPose (horigin, hangles, &hframe);
		CHECK (Grapple_TestState (tip) == GRAPPLE_ANCHORED && drawn == 1,
		       "an anchored hook still has a head to draw (%d)", drawn);
		CHECK (hframe == 2, "and it is on the stuck frame (%d, want 2)", hframe);

		/* Frozen, not recomputed: once it is in the wall the velocity
		   that put it there is gone, so a pose derived from the live
		   velocity would snap to zero on the bite. */
		VectorCopy (hangles, frozen);
		step (5);
		QR_GrappleHeadPose (horigin, hangles, &hframe);
		CHECK (fabsf (hangles[0] - frozen[0]) < 0.01f
		       && fabsf (hangles[1] - frozen[1]) < 0.01f,
		       "the stuck hook's angles are frozen, not recomputed "
		       "(%.2f %.2f vs %.2f %.2f)",
		       hangles[0], hangles[1], frozen[0], frozen[1]);

		/* An idle hook has no head at all. */
		Grapple_TestDisengage ();
		drawn = QR_GrappleHeadPose (horigin, hangles, &hframe);
		CHECK (drawn == 0, "an idle hook has no head to draw (%d)", drawn);
	}

	/* ---------------- the head model resolves, or honestly does not ---- */

	/* The gym's basedir has no rogue pak, so hook.mdl is absent here and
	   only the FALLBACK branch would ever run. vr_grapple_headmodel is
	   what makes both branches testable on the host, and it doubles as
	   A.'s console knob. progs/spike.mdl is in id1's pak0 on every
	   install, so it stands in for the real head.

	   The anchor is PARKED rather than thrown: this is about the model and
	   the packet, and a parked anchor holds still across the frames the
	   comparison needs. */
	{
		const qc_frame_t	*f;
		uint32_t		with_model = 0, without_model = 0;
		int			head_with = -1, head_without = -1;
		vec3_t			park;

		place (704.f, 704.f, 40.f);
		step (2);
		/* IN VIEW, along the render forward. The head is a world
		   entity and is frustum culled like any other, so a point
		   straight up over a level view is not a place a drawn-entity
		   count can be measured: that is exactly how the first version
		   of this read as "the model did not resolve". */
		{
			vec3_t	fwd, rt, up;

			/* All three out-params, because AngleVectors writes
			   every one of them unconditionally and a NULL is a
			   segfault, not an opt-out (mathlib.c:198). */
			AngleVectors (r_refdef.viewangles, fwd, rt, up);
			VectorMA (r_refdef.vieworg, 256.f, fwd, park);
		}

		Cvar_Set ("vr_grapple_headmodel", "progs/spike.mdl");
		Grapple_TestSetAnchor (park, 512.f);
		step (1);
		f = QC_RendererAcquireFrame ();
		if (f)
		{
			with_model = f->num_entities;
			head_with = f->grapple_head;
			QC_RendererReleaseFrame ();
		}
		CHECK (head_with == 1,
		       "a resolvable head model is reported drawn (%d)", head_with);

		/* Same anchor, a model that cannot exist. The cache key has to
		   include the cvar or this keeps the old pointer and the check
		   passes for the wrong reason. */
		Cvar_Set ("vr_grapple_headmodel", "progs/qavp_no_such_model.mdl");
		Grapple_TestSetAnchor (park, 512.f);
		step (1);
		f = QC_RendererAcquireFrame ();
		if (f)
		{
			without_model = f->num_entities;
			head_without = f->grapple_head;
			QC_RendererReleaseFrame ();
		}
		CHECK (head_without == 0,
		       "an absent head model is reported NOT drawn (%d)", head_without);
		CHECK (with_model == without_model + 1,
		       "the head is exactly one alias entity (%u with, %u without)",
		       with_model, without_model);

		/* And an idle hook draws no head even with a good model. */
		Cvar_Set ("vr_grapple_headmodel", "progs/spike.mdl");
		Grapple_TestDisengage ();
		step (1);
		f = QC_RendererAcquireFrame ();
		if (f)
		{
			head_without = f->grapple_head;
			CHECK (f->num_entities == without_model,
			       "an idle hook adds no entity (%u, want %u)",
			       f->num_entities, without_model);
			QC_RendererReleaseFrame ();
		}
		CHECK (head_without == 0,
		       "an idle hook reports no head (%d)", head_without);

		Cvar_Set ("vr_grapple_headmodel", "progs/hook.mdl");
	}

	/* ---------------- the pendulum, on the C anchor --------------------- */

	/* These are the feel, and they are the reason the rewrite is allowed to
	   touch the anchor and nothing else. Every number is what the shipped
	   build produces: accel 1500, accelref 1536, accelmin 0.2, haul 3200,
	   reel 3200, stiff 30, ropemin 64, sv_gravity 800.
	   A rest length 256 short of the distance saturates the spring, so the
	   acceleration clamp is what is being measured rather than the spring. */

	place (704.f, 704.f, 1000.f);		/* air, so nothing interferes */
	step (2);

	/* An OVERHEAD rope nets the whole accel. The frame's budget is
	   accel + gravity, because the next physics frame will spend gravity
	   out of the same velocity, so the measured pull is 2300 and the felt
	   climb is 1500. This is the identity the gravity compensation exists
	   to hold, and it is what "the rope has no pickup when I'm falling"
	   turned out to be. */
	got = measure_pull (0.f, 0.f, 1552.f, 1280.f, 1.0/72.0);
	CHECK (fabsf (got - 800.f - 1500.f) < 1.f,
	       "an overhead rope delivers the whole accel (%.2f measured, "
	       "1500 after gravity takes 800)", got - 800.f);

	/* A LEVEL rope gets no compensation, because gravity does no work
	   along it, so the same knob reads 1500 directly. The two together are
	   the point: one number, same meaning, whatever the angle. */
	got = measure_pull (1536.f, 0.f, 16.f, 1280.f, 1.0/72.0);
	CHECK (fabsf (got - 1500.f) < 1.f,
	       "a level rope delivers the same accel with no compensation (%.2f)", got);

	/* Rope-length scaling: accelref earns all of it, a third of accelref
	   earns a third. */
	CHECK (fabsf (measure_pull (1536.f, 0.f, 16.f, 1280.f, 1.0/72.0) - 1500.f) < 1.f,
	       "accelref earns the whole accel");
	got = measure_pull (512.f, 0.f, 16.f, 256.f, 1.0/72.0);
	CHECK (fabsf (got - 500.f) < 1.f,
	       "a third of accelref earns a third of the accel (%.2f)", got);

	/* accelmin is a FLOOR, not a scale: a rope far shorter than accelref
	   still gets 0.2 of it, so closing on an anchor eases off instead of
	   stopping dead. Needs ropemin out of the way, since the shipped 64 is
	   longer than the rope under test. */
	QC_ExecuteCommand ("vr_grapple_ropemin 8\n");
	step (1);
	got = measure_pull (16.f, 0.f, 16.f, 8.f, 1.0/72.0);
	CHECK (fabsf (got - 300.f) < 1.f,
	       "accelmin floors the short-rope pull at 0.2 (%.2f)", got);
	QC_ExecuteCommand ("vr_grapple_ropemin 64\n");
	step (1);

	/* A SLACK rope does nothing at all. This is what makes a held hook
	   feel like a rope rather than a rail, and where falling under your own
	   control comes from. */
	{
		edict_t *p = svs.clients[0].edict;
		vec3_t	anchor;
		anchor[0] = p->v.origin[0] + 100.f;
		anchor[1] = p->v.origin[1];
		anchor[2] = p->v.origin[2] + 16.f;
		p->v.velocity[0] = p->v.velocity[1] = p->v.velocity[2] = 0.f;
		Grapple_TestSetAnchor (anchor, 500.f);
		host_frametime = 1.0/72.0;
		Grapple_TestSwing ();
		CHECK (p->v.velocity[0] == 0.f && p->v.velocity[1] == 0.f
		       && p->v.velocity[2] == 0.f,
		       "a slack rope is an ordinary fall (velocity untouched)");
	}

	/* A LONG FRAME cannot outrun the budget. Both QC_Frame and
	   Host_FilterTime permit 0.1 s, and an explicit spring integrated over
	   a frame that long is where the old impulse version became a two-frame
	   limit cycle. The per-frame delta must still be accel * dt. */
	dv = measure_pull (1536.f, 0.f, 16.f, 1280.f, 0.1) * 0.1f;
	CHECK (dv < 1500.f * 0.1f + 1.f,
	       "a 0.1 s frame still spends only accel * dt (%.1f u/s added, "
	       "budget %.1f)", dv, 1500.f * 0.1f);
	host_frametime = 1.0/72.0;

	/* The anchor's ENTITY dying mid-swing must not take the swing with it,
	   and must not read a freed edict. A gibbed monster is exactly this. */
	{
		edict_t	*victim = NULL;
		vec3_t	ofs;
		int	i;

		for (i = 1; i < sv.num_edicts; i++)
		{
			edict_t *e = EDICT_NUM (i);
			if (!e->free && e->v.classname
			    && strstr (PR_GetString (e->v.classname), "weapon_"))
			{
				victim = e;
				break;
			}
		}
		if (!victim)
		{
			failures++;
			printf ("FAIL: no pickup entity in the gym to anchor to\n");
		}
		else
		{
			ofs[0] = 0.f; ofs[1] = 0.f; ofs[2] = 0.f;
			Grapple_TestSetAnchorEnt (NUM_FOR_EDICT (victim), ofs);
			CHECK (Grapple_TestAnchorNum () > 0,
			       "the anchor can be an entity (edict %d)",
			       Grapple_TestAnchorNum ());

			ED_Free (victim);
			Grapple_TestSwing ();
			CHECK (Grapple_TestAnchorNum () == 0,
			       "a freed anchor entity falls back to a world anchor");
			CHECK (Grapple_TestState (tip) == GRAPPLE_ANCHORED,
			       "and the swing survives its anchor dying");
		}
	}

	/* ---------------- the real grip, through Grapple_Frame -------------- */

	/* Everything above drove the hook through the test seam. From here the
	   pad goes in the front door, which is what the player's grip does, so
	   the state machine's own gates are under test and not bypassed. */

	place (704.f, 704.f, 1000.f);
	aim (-90.f, 0.f);
	grip (1);
	step (3);
	CHECK (Grapple_TestState (tip) != GRAPPLE_IDLE,
	       "a held grip throws the hook through Grapple_Frame (state=%d)",
	       Grapple_TestState (tip));

	step (40);
	CHECK (Grapple_TestState (tip) == GRAPPLE_ANCHORED,
	       "and it anchors (state=%d)", Grapple_TestState (tip));

	/* The headline of the whole rewrite: the gun is untouched throughout. */
	{
		edict_t *p = svs.clients[0].edict;
		float	weapon_before = p->v.weapon;
		int	i, changed = 0;

		for (i = 0; i < 30; i++)
		{
			step (1);
			if (p->v.weapon != weapon_before)
				changed = 1;
		}
		CHECK (!changed,
		       "the player's weapon is untouched for a whole engagement "
		       "(%.0f throughout)", weapon_before);
	}

	grip (0);
	step (3);
	CHECK (Grapple_TestState (tip) == GRAPPLE_IDLE,
	       "releasing the grip lets go (state=%d)", Grapple_TestState (tip));

	/* RESPAWN. A grip still held through death must not throw on the first
	   spawned frame. Measured historically as the player being dragged
	   across a level they had just arrived in, having pressed nothing. */
	place (704.f, 704.f, 1000.f);
	grip (1);
	step (5);
	CHECK (Grapple_TestState (tip) != GRAPPLE_IDLE,
	       "a hook is out before the player dies");
	QC_ExecuteCommand ("kill\n");
	{
		int i, threw = 0, cancelled = 0;

		/* Death must cancel the live hook. */
		for (i = 0; i < 30 && !cancelled; i++)
		{
			step (1);
			if (Grapple_TestState (tip) == GRAPPLE_IDLE)
				cancelled = 1;
		}
		CHECK (cancelled, "dying cancels the hook (%d frames)", i);

		/* And then the still-held grip must stay refused. Single player
		   does not respawn in place -- PlayerDeathThink waits for a
		   button and restarts the level -- so what is observable here is
		   the lock holding for as long as the player is down, which is
		   the half this fix owns. The level-restart half is the map
		   change asserted below. */
		for (i = 0; i < 60; i++)
		{
			step (1);
			if (Grapple_TestState (tip) != GRAPPLE_IDLE)
				threw = 1;
		}
		CHECK (!threw,
		       "and a grip still held while down never throws again");
	}
	grip (0);
	step (3);
	/* Off the respawn point before pressing again: the gym's
	   info_player_start is on column (0,0)'s corner plane, so a throw from
	   there is refused for starting inside solid, which would make this
	   assertion fail for a reason that has nothing to do with the lock. */
	place (704.f, 704.f, 1000.f);
	aim (-90.f, 0.f);
	grip (1);
	step (3);
	CHECK (Grapple_TestState (tip) != GRAPPLE_IDLE,
	       "and a fresh press after the respawn does throw (state=%d)",
	       Grapple_TestState (tip));
	grip (0);
	step (2);

	/* A GAME SWITCH mid-swing must give sv_friction back. Nothing else
	   does: COM_Game_f re-execs quake.rc without going near the disengage
	   path, which is why Grapple_ResolveProgs releases it. */
	{
		cvar_t	*fr = Cvar_FindVar ("sv_friction");
		float	before = fr ? fr->value : -1.f;

		place (704.f, 704.f, 1000.f);
		aim (-90.f, 0.f);
		grip (1);
		step (40);
		CHECK (Grapple_TestState (tip) == GRAPPLE_ANCHORED,
		       "a swing is live before the map change (state=%d)",
		       Grapple_TestState (tip));
		CHECK (fr && fr->value == 0.f,
		       "and friction is borrowed while it swings (%.2f)",
		       fr ? fr->value : -1.f);

		QC_ExecuteCommand ("map gym\n");
		step (120);
		CHECK (fr && fr->value == before,
		       "a map change gives sv_friction back (%.2f, was %.2f)",
		       fr ? fr->value : -1.f, before);
		CHECK (Grapple_TestState (tip) == GRAPPLE_IDLE,
		       "and leaves no swing behind (state=%d)",
		       Grapple_TestState (tip));
		grip (0);
		step (2);
	}

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

	/* ---------------- hooking a monster hurts it ------------------------ */

	/* The range has a firing line of monsters, which is why this half lives
	   here and not in the gym. Nothing is hardcoded about where they are:
	   the driver finds one, then tries a few directions until a throw
	   actually anchors ON it, and says so if none does. */
	{
		edict_t	*mob = NULL;
		int	i, anchored_on_mob = 0;
		float	health_before = 0.f;
		static const float dirs[4][2] = {
			{ -400.f, 0.f }, { 400.f, 0.f }, { 0.f, -400.f }, { 0.f, 400.f }
		};

		QC_ExecuteCommand ("notarget\n");
		step (10);

		/* Skipping the player matters: edict 1 IS the player, and a
		   player is damageable and SOLID_SLIDEBOX like any monster, so
		   a search on those two facts alone finds the thrower. It did,
		   and the throws then anchored on the world behind it. */
		for (i = 1; i < sv.num_edicts; i++)
		{
			edict_t *e = EDICT_NUM (i);
			if (e->free || e == svs.clients[0].edict)
				continue;
			if (e->v.takedamage != 0.f && e->v.health > 0.f
			    && e->v.solid == SOLID_SLIDEBOX
			    && e->v.classname
			    && strstr (PR_GetString (e->v.classname), "monster"))
			{
				/* And it must be a monster whose health is
				   ALREADY stable. The first candidate was
				   losing 8 health over 30 frames to something
				   in the map, which would have made "hurt once,
				   not every frame" fail for a reason that has
				   nothing to do with the hook. */
				float h = e->v.health;
				step (20);
				if (e->free || e->v.health != h)
					continue;
				mob = e;
				break;
			}
		}
		CHECK (mob != NULL, "the range has a damageable monster to hook");

		for (i = 0; mob && i < 4 && !anchored_on_mob; i++)
		{
			vec3_t	target;

			target[0] = mob->v.origin[0];
			target[1] = mob->v.origin[1];
			target[2] = mob->v.origin[2] + 16.f;

			place (mob->v.origin[0] + dirs[i][0],
			       mob->v.origin[1] + dirs[i][1],
			       mob->v.origin[2] + 24.f);
			step (2);
			aim_at (target);
			health_before = mob->v.health;

			state = throw_and_settle (60, tip);
			printf ("      (try %d from %+.0f %+.0f: state=%d anchor=%d "
				"want=%d tip %.0f %.0f %.0f)\n",
				i, dirs[i][0], dirs[i][1], state,
				Grapple_TestAnchorNum (), NUM_FOR_EDICT (mob),
				tip[0], tip[1], tip[2]);
			if (state == GRAPPLE_ANCHORED
			    && Grapple_TestAnchorNum () == NUM_FOR_EDICT (mob))
				anchored_on_mob = 1;
		}

		CHECK (anchored_on_mob,
		       "a throw at a monster anchors on the monster itself");
		if (anchored_on_mob)
		{
			CHECK (mob->v.health == health_before - 10.f,
			       "and hooking it costs it vr_grapple_damage "
			       "(%.0f -> %.0f, expected %.0f)",
			       health_before, mob->v.health, health_before - 10.f);

			/* Once per throw, not per frame. A rope that keeps
			   hurting what it is tied to is a different weapon. */
			health_before = mob->v.health;
			step (30);
			CHECK (mob->v.health == health_before,
			       "and it is hurt once, not every frame (%.0f)",
			       mob->v.health);
		}
	}

	printf (failures ? "\n%d FAILURES\n" : "\nall passed\n", failures);
	return failures ? 1 : 0;
}
