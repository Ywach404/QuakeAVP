/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * grapple_avp.h -- the grappling hook.
 *
 * Engine thread only. The hook writes the player's velocity and reads the
 * world, neither of which has any locking.
 */

#ifndef GRAPPLE_AVP_H
#define GRAPPLE_AVP_H

#include <stdint.h>

/* The head model's path, read by the renderer bridge to resolve and draw it.
   Owned here because every other vr_grapple_* cvar is. */
extern cvar_t	vr_grapple_headmodel;

/* Where this swing's hook is. Public rather than file-local because the frame
   packet carries exactly these three values to the renderer, and one enum with
   two definitions is the restatement this project keeps paying for. */
typedef enum
{
	GRAPPLE_IDLE = 0,		/* no hook in the world */
	GRAPPLE_FLYING = 1,		/* thrown, still travelling */
	GRAPPLE_ANCHORED = 2		/* stuck, and the rope is live */
} grapple_state_t;

void Grapple_Init (void);		/* register the cvar; after Cvar_Init */

/* Drive the hold from this tick's pad snapshot. Called from IN_Commands,
   one frame ahead of the server frame that integrates what it writes.
   `wheel_open` cancels an in-progress swing. */
void Grapple_Frame (uint32_t padbits, int wheel_open);

/* Where the hook is, for the frame packet. Returns the grapple_state_t and
   fills `tip` with the hook head's world position, which in GRAPPLE_ANCHORED
   is the anchor RESOLVED through its entity, so a rope tied to a moving
   platform follows it. `tip` is untouched and meaningless when the result is
   GRAPPLE_IDLE. Engine thread, called from the packet builder. */
int QR_GrappleState (float tip[3]);

/* The head's drawn pose, for the bridge to hang an alias model on. Returns 1
   when there is a head and fills `origin` (world units, the same point as the
   tip above), `angles` (pitch yaw roll, degrees) and `frame`. The frame is
   rogue's own choice, 1 in flight and 2 once stuck, and the angles are frozen
   at the bite rather than recomputed, because the velocity that put the hook
   in the wall is gone by then. Returns 0 and touches nothing when idle. */
int QR_GrappleHeadPose (float origin[3], float angles[3], int *frame);

#endif	/* GRAPPLE_AVP_H */
