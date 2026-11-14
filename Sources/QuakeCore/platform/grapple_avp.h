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

#endif	/* GRAPPLE_AVP_H */
