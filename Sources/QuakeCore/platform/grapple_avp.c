/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * grapple_avp.c -- reaching rogue's own grappling hook.
 *
 * Dissolution of Eternity ships a complete grappling hook in its compiled
 * progs: W_FireGrapple spawns it, GrappleAnchor sticks it, GrappleService
 * pulls the player along it at 1000 units a second, GrappleTrail draws the
 * rope. None of that needed writing. It is simply UNREACHABLE, because every
 * path that hands you the weapon is gated on `deathmatch && teamplay >= 4`
 * and this engine never writes the teamplay progs global, so the condition
 * cannot become true by any cvar. Verified by sweeping impulses 1 through 50
 * with every item already granted: none of them reaches it, and `impulse 9`
 * does not either.
 *
 * So the whole feature is a weapon write. Nothing downstream of
 * `weapon == IT_GRAPPLE` is gated at all -- there is not one deathmatch or
 * teamplay reference in any of the six grapple functions.
 *
 * Two things this file does NOT have to do, and both were surprises:
 *
 *   - It never touches .items. sv_main.c ORs items2 << 23 into the published
 *     items word for a progs that defines items2, which rogue does, so bit 23
 *     reads as green armour on the client and the statusbar would grow a
 *     pickup that is not there. The bit is not needed: the only reader is
 *     W_ChangeWeapon's `items & fl` test, and setting .weapon directly
 *     bypasses that. The whole lifecycle was run with .items left clear and
 *     behaved identically.
 *   - It does no renderer work. The hook spawns at the player's HAND for
 *     free, because W_FireGrapple places it with setorigin and the pr_cmds.c
 *     hunk routes that through QR_MuzzleSpawn; and the rope STARTS at the
 *     hand for free, because the cl_tent.c hunk sits in the generic
 *     `b->entity == cl.viewentity` branch rather than a lightning-specific
 *     one, and GrappleTrail names the player as its beam entity. Both hunks
 *     were already paid for by the missile and lightning work. There is no
 *     seventh hunk here and there should never need to be one: the gate is a
 *     progs field, and platform code can write those.
 */

#include "quakedef.h"
#include "QuakeCore.h"	/* QC_PAD_* bits */
#include "grapple_avp.h"

/* rogue's IT_GRAPPLE. A constant rather than a lookup because pr_globaldefs
   is file-local to pr_edict.c and there is no public accessor for a progs
   global by name, so this cannot be read the way the per-game weapon bits
   were. It is safe anyway for a reason worth writing down: this pak's item
   flags are NOT the published rogue numbers (every weapon and ammo bit is
   shifted down one slot, so the axe is 2048 here where vanilla has 4096),
   and the grapple survived that shift untouched because it sits at the top
   of the word. The engine's own quakedef.h agrees at RIT_ARMOR1, which is
   the same bit seen from the items2 side. Belt and braces: nothing below
   runs unless this progs actually carries rogue's grapple functions AND its
   grapple fields, so a mod with a different layout is refused rather than
   poked into nonsense. */
#define GRAPPLE_ITEM_BIT	(1 << 23)

static cvar_t	vr_grapple = {"vr_grapple", "0", CVAR_ARCHIVE};

/* Resolved once per progs load. Keyed on the CRC, not on the progs pointer,
   and that distinction is a crash: SV_SpawnServer reloads progs at the SAME
   hunk address, so a pointer key never changes across a `game` switch and the
   cache is never rebuilt. Measured -- rogue and id1 both land on one address
   with CRCs 54347 and 24778. Holding the grip after switching away from rogue
   then read rogue's field offsets out of an id1 edict, built an edict pointer
   out of whatever was there and dereferenced it: SIGSEGV. The reverse order
   left the feature silently dead instead. The pointer is kept alongside so a
   reload that DOES move also re-resolves; the CRC alone is what makes this
   correct. admin_avp.c keys on the pointer and has the same latent bug. */
static dprograms_t	*grapple_progs_key;
static unsigned short	grapple_crc_key;
static qboolean		grapple_resolved;
static func_t		grapple_setammo;	/* W_SetCurrentAmmo */
static func_t		grapple_reset;		/* GrappleReset      */
static qboolean		grapple_supported;	/* this progs has the hook */
static int		grapple_ofs_hook_out;	/* float offsets, -1 = absent */
static int		grapple_ofs_on_hook;
static int		grapple_ofs_hook;

/* Live state. qr_grapple_key mirrors the trigger layer's qr_rt_down idiom:
   the press is OURS to raise and retract, so a forced release (the ring
   opening) cannot leave attack stuck down with the bit still held. */
static qboolean		qr_grapple_key;		/* we are holding the bind */
static qboolean		qr_grapple_engaged;	/* we swapped the weapon    */
static float		qr_grapple_prev_weapon;	/* what to put back         */

/* Set whenever a swing ends for any reason OTHER than the player letting go,
   and cleared only when the grip actually comes up. Without it a cancel
   re-arms under a still-held grip: closing the weapon ring fired a fresh
   hook on the next tick, and a weapon stolen mid-swing was stolen straight
   back and recorded as the thing to restore. A cancelled swing should wait
   for a new press. */
static qboolean		qr_grapple_locked;

static int Grapple_FieldOfs (const char *name)
{
	edict_t	*world;
	eval_t	*val;

	world = EDICT_NUM (0);
	val = GetEdictFieldValue (world, name);
	if (!val)
		return -1;
	return (int) ((float *) val - (float *) &world->v);
}

static func_t Grapple_FuncByName (const char *name)
{
	int i;

	for (i = 1; i < progs->numfunctions; i++)
	{
		if (!strcmp (PR_GetString (pr_functions[i].s_name), name))
			return (func_t) i;
	}
	return 0;
}

static void Grapple_ResolveProgs (void)
{
	if (grapple_resolved && progs == grapple_progs_key
	    && pr_crc == grapple_crc_key)
		return;
	grapple_progs_key = progs;
	grapple_crc_key = pr_crc;
	grapple_resolved = true;
	grapple_supported = false;
	grapple_setammo = 0;
	grapple_reset = 0;
	grapple_ofs_hook_out = grapple_ofs_on_hook = grapple_ofs_hook = -1;
	qr_grapple_engaged = false;	/* the edict it referred to is gone */
	qr_grapple_locked = false;
	if (!progs)
		return;

	grapple_setammo = Grapple_FuncByName ("W_SetCurrentAmmo");
	grapple_reset = Grapple_FuncByName ("GrappleReset");
	grapple_ofs_hook_out = Grapple_FieldOfs ("hook_out");
	grapple_ofs_on_hook = Grapple_FieldOfs ("on_hook");
	grapple_ofs_hook = Grapple_FieldOfs ("hook");

	/* W_FireGrapple is the one that proves the weapon is implemented;
	   the rest proves we can drive and unwind it. All or nothing. */
	grapple_supported = Grapple_FuncByName ("W_FireGrapple") != 0
			 && grapple_setammo != 0
			 && grapple_reset != 0
			 && grapple_ofs_hook_out >= 0
			 && grapple_ofs_on_hook >= 0
			 && grapple_ofs_hook >= 0;
}

#define GRAPPLE_FLOAT(e,ofs)	(*((float *) &(e)->v + (ofs)))
#define GRAPPLE_EDICT(e,ofs)	(*((int *) ((float *) &(e)->v + (ofs))))

/* One owner for K_RSHOULDER. The bind on it is +attack, and the engine's
   kbutton keeps two holder slots, which is the whole reason this goes through
   a key rather than writing in_attack directly: a player holding the fire
   trigger at the same time must not have their attack cancelled when this
   one lets go. */
static void Grapple_SetKey (qboolean down)
{
	if (down == qr_grapple_key)
		return;
	qr_grapple_key = down;
	Key_Event (K_RSHOULDER, down);
}

static edict_t *Grapple_Player (void)
{
	if (!sv.active || !svs.clients || !svs.clients[0].active)
		return NULL;
	return svs.clients[0].edict;
}

/* Run a progs function with `self` pointed somewhere else, saving and
   restoring what was there. IN_Commands runs inside Host_Frame's error
   frame, so a QuakeC runaway in here unwinds exactly as a think would --
   the same argument admin_avp.c makes for its FoundTarget call. */
static void Grapple_Call (func_t fn, edict_t *self)
{
	int	saved_self;

	if (!fn || !self)
		return;
	saved_self = pr_global_struct->self;
	pr_global_struct->self = EDICT_TO_PROG (self);
	PR_ExecuteProgram (fn);
	pr_global_struct->self = saved_self;
}

/*
Let go of the hook and put the player's weapon back.

The ordering here is the whole reason this file is a state machine rather
than two lines, and it was settled by measurement.

GrappleService only releases when `!button0 && weapon == IT_GRAPPLE`, and
GrappleAnchor does not check the weapon AT ALL -- the hook will stick to a
wall perfectly happily with the axe selected. So the hazard is not "restore
the weapon too early", it is wider than that: ANY moment with the hook out
and attack still held, while the weapon is something other than the grapple,
ends with the player pinned the instant attack drops. Measured: 400 frames,
13 seconds of server time, far past the hook's own two-second self-timeout,
with hook_out and on_hook both stuck at 1 and `+forward` moving the player
0.0 units. Genuinely immobilised, not a stale flag.

Which is why this calls GrappleReset directly, with `self` set to the HOOK
edict, instead of relying on dropping attack before writing the weapon back.
Ordering alone works today and breaks the first time anything else takes the
weapon mid-swing -- and the weapon ring does exactly that. Resetting
explicitly was verified to recover from the stuck state with the wrong
weapon still selected, after which the player moved 257 units.
*/
static void Grapple_Disengage (edict_t *player)
{
	edict_t	*hook;
	int	hook_prog;

	Grapple_SetKey (false);
	if (!qr_grapple_engaged)
		return;
	qr_grapple_engaged = false;
	if (!player)
		return;

	if (GRAPPLE_FLOAT (player, grapple_ofs_hook_out))
	{
		hook_prog = GRAPPLE_EDICT (player, grapple_ofs_hook);
		hook = hook_prog ? PROG_TO_EDICT (hook_prog) : NULL;
		if (hook && !hook->free)
			Grapple_Call (grapple_reset, hook);
	}

	player->v.weapon = qr_grapple_prev_weapon;
	Grapple_Call (grapple_setammo, player);
}

static void Grapple_Engage (edict_t *player)
{
	qr_grapple_prev_weapon = player->v.weapon;
	qr_grapple_engaged = true;
	player->v.weapon = GRAPPLE_ITEM_BIT;
	/* W_SetCurrentAmmo is what makes the drawn gun v_grpple.mdl and zeroes
	   currentammo; without it the weapon is swapped but the player is
	   still holding the old model. */
	Grapple_Call (grapple_setammo, player);

	Grapple_SetKey (true);
}

void Grapple_Frame (uint32_t padbits, int wheel_open)
{
	edict_t		*player;
	qboolean	held, want, usable;

	Grapple_ResolveProgs ();
	player = Grapple_Player ();
	held = (padbits & QC_PAD_RSHOULDER) != 0;

	/* A cancelled swing waits for a NEW press, never for the grip simply
	   still being down. */
	if (!held)
		qr_grapple_locked = false;

	usable = player && grapple_supported && vr_grapple.value != 0;

	if (!usable)
	{
		/* No player, no hook in this progs, or the feature switched
		   off. Unwind anything held rather than leaving a key down
		   across a map change, then hand the button back: this layer
		   took QC_PAD_RSHOULDER out of the generic pad table, so
		   swallowing it here would make the button do nothing at all
		   in every game but rogue, which is not ours to decide. */
		if (qr_grapple_engaged)
			Grapple_Disengage (player);
		Grapple_SetKey (held);
		return;
	}

	/* key_dest gates the PRESS, because the key event is what makes the
	   attack bind fire and a menu or the console eats it. Without this the
	   grip swapped the weapon, drew the grapple in the player's hand and
	   never threw anything -- a dead feature wearing the right model. The
	   press is raised on the engage transition only, so it cannot be
	   recovered by closing the menu later either. */
	want = held
	    && !qr_grapple_locked
	    && !wheel_open
	    && key_dest == key_game;

	if (want && !qr_grapple_engaged)
	{
		Grapple_Engage (player);
	}
	else if (!want && qr_grapple_engaged)
	{
		/* Ending a swing the player did not end: make them re-press.
		   The ring is the case that matters, and cancelling beats
		   fighting it for the weapon. */
		if (held)
			qr_grapple_locked = true;
		Grapple_Disengage (player);
	}
	else if (qr_grapple_engaged
		 && player->v.weapon != (float) GRAPPLE_ITEM_BIT)
	{
		/* Something else wrote the weapon while we were out -- a
		   console impulse, a pickup, a mod. That is the stranding
		   state, so let go now rather than when the player releases
		   and finds they cannot move. What took the weapon KEEPS it:
		   restoring over it would be this module stealing it back,
		   and the lock stops the next tick re-engaging and recording
		   the stolen weapon as the thing to restore. */
		qr_grapple_prev_weapon = player->v.weapon;
		if (held)
			qr_grapple_locked = true;
		Grapple_Disengage (player);
	}
	else if (!qr_grapple_engaged)
	{
		/* Idle and usable: the button is still the grapple's, so it
		   must not leak a stale press into the attack bind. */
		Grapple_SetKey (false);
	}
}

int Grapple_Active (void)
{
	return qr_grapple_engaged ? 1 : 0;
}

void Grapple_Init (void)
{
	Cvar_RegisterVariable (&vr_grapple);
}
