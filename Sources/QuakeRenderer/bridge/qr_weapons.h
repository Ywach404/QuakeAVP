/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * qr_weapons.h -- the weapon identity table and the per-game bit maps.
 *
 * One cl.items word means different things in different games: rogue moves
 * the axe and renumbers five more weapons, hipnotic and mg3 add their own.
 * Reading that word correctly is the only reason this file exists, and it is
 * the SOLE owner of every per-game weapon fact -- the bits, the labels, the
 * model names, the selection impulses. Nothing on either side of the C/Swift
 * boundary restates them; the consumer pulls what it needs, the same way the
 * placement table is pulled rather than pushed.
 *
 * Identity is the weapon's VIEW MODEL, not a bit and not a ring position,
 * because that is what A.'s tuning is physically about: he tuned where
 * progs/v_shot.mdl sits in his hand, and that stays true in every game
 * whichever bit happens to carry it.
 *
 * Included after quakedef.h (the console command reads cl.items and
 * com_gamedir). Engine thread, except QR_WeaponLabel and the QC_WeaponLabel
 * forwarder over it, which read immutable static data.
 */

#ifndef QR_WEAPONS_H
#define QR_WEAPONS_H

#include <stdint.h>

/* How a per-game entry is selected once the player picks it off the ring.
   TOGGLE and CYCLE exist because a mission pack's extra weapons have no
   impulse of their own: mg3's own help strings stop at "impulse 1-8 changes
   weapons", so its tenth weapon is reachable only by cycling, or by an
   impulse it shares with another weapon. A toggle is not a selector -- sending
   impulse 1 while holding the Mjolnir hands you the axe -- so the kind has to
   ride along with the number rather than be inferred from it. */
typedef enum {
	QR_SELECT_DIRECT = 0,	/* impulse N selects it outright */
	QR_SELECT_TOGGLE,	/* shares an impulse with another identity */
	QR_SELECT_CYCLE		/* reachable only through impulse 10 */
} qr_select_kind_t;

/* `impulse` 0 means UNMEASURED, not "no impulse". Only a number read off the
   headset goes in this column, because a wrong one fires a guess at the
   server and hands the player the wrong gun. */
typedef struct {
	uint32_t	bit;		/* the cl.items bit in THIS game */
	uint8_t		identity;	/* qc_weapon_identity_t */
	uint8_t		impulse;
	uint8_t		kind;		/* qr_select_kind_t */
} qr_weapon_entry_t;

/* The row for the current game, zero-bit terminated. Never NULL: an
   unrecognised game directory falls through to vanilla rather than to an
   empty ring. */
const qr_weapon_entry_t *QR_WeaponRow (void);

/* A cheap token that CHANGES whenever the selected game changes, for use in
   cache keys that must notice a `game` switch. Not a row id: id1, dopa and
   mg1 all select the vanilla row while precaching different models, so a
   token that only named the row would compare equal across exactly the
   switches a model cache has to invalidate on. */
uint32_t QR_WeaponGameKey (void);

/* Per-identity facts, game-independent by construction. */
const char *QR_WeaponLabel (int identity);
const char *const *QR_WeaponViewModels (int identity);	/* NULL-terminated */
const char *QR_WeaponPickupModel (int identity);	/* NULL: none shipped */
int QR_WeaponRearClip (int identity);

/* Degrees of roll to apply to this weapon ON THE RING, about the model's own
   forward axis. A view model is authored to sit in a hand and the packs do not
   agree with id1 about which way is up, so one of them hangs inverted. 0 for
   everything that already looked right. */
float QR_WeaponRingRoll (int identity);

/* Dump the resolved row: ring slot, identity, bit, ownership, whether a model
   resolved, impulse and kind. Also the `weapontable` console command. Public
   because vr_weapontrace fires it on its own when the owned set changes, which
   is the only way the table reaches a development machine without somebody in
   the headset typing it: the window pauses the simulation while it is open, so
   a script cannot grant weapons and read them back in one sitting. */
void QR_WeaponTablePrint (void);

/* The identity carrying `bit` in the current game, or -1. */
int QR_WeaponIdentityForBit (uint32_t bit);

/* The current game's entry for `identity`, or NULL where this game does not
   carry that weapon. The bit, the impulse and the selection kind all live
   there, so no caller keeps a second copy of any of them. It was a file-local
   helper in qr_bridge.c until two translation units wanted it: the frame
   build, to read a bit back out of the identity it is drawing, and the input
   drain, to turn a released ring slot into a selection. */
const qr_weapon_entry_t *QR_WeaponEntry (int identity);

/* The resolved owned set from the renderer bridge's last frame build: bit N
   set means identity N is owned AND its model resolved. Declared here rather
   than as a bare extern at its consumer because the input drain's weapon
   selection reads it, and the ring, the commit and the count must enumerate
   one set. STATE, not a per-game fact, so it is defined in qr_bridge.c beside
   the model resolution it comes out of. Engine thread. */
uint32_t QR_OwnedIdentities (void);

/* The identity of the weapon currently HELD, or -1 for none, resolved from
   the drawn view model because the protocol cannot be trusted to deliver it
   (the definition in qr_bridge.c carries the argument). Declared here for the
   same reason as QR_OwnedIdentities: the input drain's cycle has to know when
   it has arrived at the weapon it was asked for.

   ENGINE THREAD ONLY. It reads cl.viewent and cl.stats, and Quake's client
   globals have no locking. */
int QR_ActiveIdentity (void);

/* Registers `weapontable`. Called from R_Init, beside the renderer's other
   console commands. */
void QR_Weapons_Init (void);

#endif	/* QR_WEAPONS_H */
