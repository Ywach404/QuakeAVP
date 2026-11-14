/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * grapple_anchor_test.c -- the hook's anchor decision, over a hand-built
 * trace. Proves the one invariant the flight step depends on and cannot
 * check for itself: a trace that STOPPED tells you nothing on its own about
 * whether the rope may be tied there.
 *
 * Three ways a stop is not an anchor, and each has cost something somewhere:
 * a trace that began inside solid reports fraction 0, which reads exactly
 * like a legitimate point-blank hit; an all-solid trace has no valid plane;
 * and sky is a surface the hook must fall through rather than hang from,
 * because a rope tied to the sky is a rope tied to the edge of the map.
 *
 * Pure decisions over a struct. No world, no sv, no cvars, which is the
 * whole reason this is a separate function from the flight step.
 */
#include "quakedef.h"
#include "QuakeCore.h"
#include <stdio.h>

/* grapple_avp.c keeps the decision static and exposes this wrapper under
   QAVP_HOSTCHECK, the way qr_bridge.c exposes QR_TestCachePic* . */
int Grapple_TestAnchorFromTrace (const trace_t *tr, int contents);

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

/* Somewhere for trace_t.ent to point. The decision must never dereference it
   -- resolving the anchor's entity is the caller's job -- and a stack edict
   with no world behind it is how that gets proven rather than assumed. */
static edict_t	dummy_ent;

static void clear (trace_t *tr)
{
	memset (tr, 0, sizeof (*tr));
	tr->fraction = 1.f;
	tr->allsolid = false;
	tr->startsolid = false;
	tr->ent = NULL;
}

int main (void)
{
	trace_t	tr;

	/* A clear trace: nothing was hit, so keep flying. */
	clear (&tr);
	CHECK (Grapple_TestAnchorFromTrace (&tr, CONTENTS_EMPTY) == 0,
	       "a clear trace keeps flying");

	/* Stopped short on the world: anchor. */
	clear (&tr);
	tr.fraction = 0.4f;
	tr.ent = &dummy_ent;
	CHECK (Grapple_TestAnchorFromTrace (&tr, CONTENTS_SOLID) == 1,
	       "a world hit anchors");

	/* Stopped short with no entity at all still anchors: the world edict is
	   a legitimate NULL in some trace paths and a wall is a wall. */
	clear (&tr);
	tr.fraction = 0.4f;
	CHECK (Grapple_TestAnchorFromTrace (&tr, CONTENTS_SOLID) == 1,
	       "a hit with no entity still anchors");

	/* Stopped short, but the surface is sky: abandon the throw. */
	clear (&tr);
	tr.fraction = 0.4f;
	tr.ent = &dummy_ent;
	CHECK (Grapple_TestAnchorFromTrace (&tr, CONTENTS_SKY) == -1,
	       "a sky hit is abandoned, not anchored");

	/* Started inside solid: abandon rather than tie the rope inside a wall.
	   Checked BEFORE fraction, because this case reports fraction 0. */
	clear (&tr);
	tr.startsolid = true;
	tr.fraction = 0.f;
	tr.ent = &dummy_ent;
	CHECK (Grapple_TestAnchorFromTrace (&tr, CONTENTS_SOLID) == -1,
	       "a throw from inside solid is abandoned");

	/* All solid: no valid plane, so there is nothing to anchor to. */
	clear (&tr);
	tr.allsolid = true;
	tr.fraction = 0.f;
	tr.ent = &dummy_ent;
	CHECK (Grapple_TestAnchorFromTrace (&tr, CONTENTS_SOLID) == -1,
	       "an all-solid trace is abandoned");

	/* Water is not sky and not solid: a hook that reaches a wall through
	   water still anchors on the wall. The contents argument is about the
	   surface the hook STOPPED on, so a liquid endpos must not veto it. */
	clear (&tr);
	tr.fraction = 0.6f;
	tr.ent = &dummy_ent;
	CHECK (Grapple_TestAnchorFromTrace (&tr, CONTENTS_WATER) == 1,
	       "a hit reached through water still anchors");

	printf (failures ? "FAILED (%d)\n" : "passed\n", failures);
	return failures ? 1 : 0;
}
