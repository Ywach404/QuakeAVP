/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * world_only_test.c -- the contract a world-only render pass depends on.
 *
 * A save's cover is a re-render of the WORLD, with nothing of the player's
 * own kit in it: no view weapon, no aiming laser, no reticle or arc gauges,
 * no wheel labels or centerprints, no ground grid. The renderer skips those
 * by reading flags and vertex ranges off the frame packet, so what is tested
 * here is that those markers exist, do not collide, and mean nothing when a
 * frame never set them.
 *
 * Pure header arithmetic over a zeroed packet. No engine, no map.
 */
#include "quakedef.h"
#include "QuakeCore.h"
#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

int main (void)
{
	qc_frame_t	frame;
	qc_entity_t	ent;

	/* The hand weapon needs a flag of its own because it cannot be told
	   apart any other way: it goes through the ordinary alias path, and
	   qr_bridge deliberately SUPPRESSES QC_ENTFLAG_VIEWMODEL on it (the
	   immersive path draws the gun on the hand, not view-locked), so the
	   consumer's existing drawsViewmodel=false does not skip it. */
	CHECK (QC_ENTFLAG_HANDWEAPON != 0, "the hand weapon has a flag bit");
	CHECK ((QC_ENTFLAG_HANDWEAPON & QC_ENTFLAG_VIEWMODEL) == 0,
	       "it does not collide with the viewmodel flag");
	CHECK ((QC_ENTFLAG_HANDWEAPON & QC_ENTFLAG_PHASED) == 0,
	       "nor with the phased flag");
	/* A single bit, so it can be cleared without touching its neighbours. */
	CHECK ((QC_ENTFLAG_HANDWEAPON & (QC_ENTFLAG_HANDWEAPON - 1)) == 0,
	       "and it is one bit, not a mask");

	memset (&ent, 0, sizeof (ent));
	CHECK ((ent.flags & QC_ENTFLAG_HANDWEAPON) == 0,
	       "an entity that set nothing is not a hand weapon");
	ent.flags |= QC_ENTFLAG_HANDWEAPON;
	CHECK ((ent.flags & QC_ENTFLAG_VIEWMODEL) == 0,
	       "setting it leaves the viewmodel flag alone");

	/* The aiming laser is particle verts with no published range, so a
	   world-only pass had no way to leave it out. It gets its own pair
	   rather than being folded into the reticle's: that range is drawn
	   with the depth test OFF, and widening it would change how the LIVE
	   laser draws. */
	memset (&frame, 0, sizeof (frame));
	CHECK (frame.laser_vert_count == 0,
	       "a frame that emitted no laser skips nothing");
	CHECK (frame.reticle_vert_count == 0 && frame.ground_vert_count == 0,
	       "and the ranges it shares a run with are likewise empty");

	/* The ranges are independent: a frame can carry a laser and no
	   reticle, which is what happens while the gun is pointed at nothing
	   the trace can land on. */
	frame.laser_first_vert = 12;
	frame.laser_vert_count = 6;
	CHECK (frame.reticle_vert_count == 0,
	       "a laser range does not imply a reticle range");
	CHECK (frame.laser_first_vert + frame.laser_vert_count == 18,
	       "the laser range is a first/count pair like its neighbours");

	printf ("%s\n", failures ? "UNIT FAIL" : "UNIT PASS");
	return failures ? 1 : 0;
}
