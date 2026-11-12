/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * grapple_avp.h -- reaching rogue's own grappling hook.
 *
 * Engine thread only. Everything here pokes progs state or raises key
 * events, neither of which has any locking.
 */

#ifndef GRAPPLE_AVP_H
#define GRAPPLE_AVP_H

#include <stdint.h>

void Grapple_Init (void);		/* register the cvar; after Cvar_Init */

/* Drive the hold from this tick's pad snapshot. Called from IN_Commands
   AFTER the generic pad-to-key diff, so the attack bind this raises is
   settled in the same tick as the weapon write that has to accompany it.
   `wheel_open` cancels an in-progress swing: the ring takes the weapon, and
   a hook left out while attack is still held is the one state that can
   strand the player (see the .c). */
void Grapple_Frame (uint32_t padbits, int wheel_open);

/* True while this module is holding the player on rogue's hook, i.e. the
   weapon was swapped out from under the player and owes a restore. Lets the
   rest of the platform layer leave the weapon alone for the duration. */
int Grapple_Active (void);

#endif	/* GRAPPLE_AVP_H */
