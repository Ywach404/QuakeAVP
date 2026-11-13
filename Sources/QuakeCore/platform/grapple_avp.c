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
 *   - It does no renderer work, because the existing hunks already carry the
 *     hook. W_FireGrapple places it with setorigin and the pr_cmds.c hunk
 *     routes that through QR_MuzzleSpawn; the rope is a TE_BEAM naming the
 *     PLAYER as its entity, so the cl_tent.c hunk moves its start, that hunk
 *     sitting in the generic `b->entity == cl.viewentity` branch rather than
 *     a lightning-specific one. Both were already paid for by the missile and
 *     lightning work.
 *
 *     BUT NEITHER IS UNCONDITIONAL, and an earlier version of this comment
 *     said they were. Both routes run through QR_HandOrigin, which returns 0
 *     whenever qr_aim_active is false, and then the hook spawns at the
 *     vanilla body offset and the rope starts at the chest. QR_MuzzleSpawn's
 *     reach gate rejects the same way. So "it comes out of your hand" is a
 *     property of the aim channel being live, not of this module, and it was
 *     measured wrong on device while reading correct here.
 *
 *     There is still no seventh hunk here and there should never need to be
 *     one: the gate is a progs field, and platform code can write those.
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

/* Rogue's own numbers, and why they are the defaults rather than constants.
   W_FireGrapple throws at 800 units/s and sets exactly one think two seconds
   out. There is no distance test anywhere in the weapon and the hook is
   MOVETYPE_FLYMISSILE, so no gravity: reach is speed times time and nothing
   else, 1600 units stock. On device that read as a chain that takes forever
   to go out and falls short of the far wall on a large map, which is one
   number, not two.

   Both knobs live on the hook edict, which this module already reaches
   through .hook, so changing them needs no progs patch and no engine hunk.
   They are cvars because the right values are a feel question that can only
   be answered in the headset, and the reticle arcs already taught this
   project what a rebuild per guess costs. The defaults are rogue's own, so
   installing this changes nothing until someone turns it up. */
static cvar_t	vr_grapple_speed = {"vr_grapple_speed", "800", CVAR_ARCHIVE};
static cvar_t	vr_grapple_range = {"vr_grapple_range", "1600", CVAR_ARCHIVE};

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

/* This swing's hook has been retuned. The throw is not visible on the tick
   the weapon is written: the attack bind fires during the server frame that
   follows, so hook_out rises a tick later and the edict does not exist until
   then. One shot per swing, because GrappleAnchor rewrites the think on
   contact and re-applying the range after that would re-arm the self-timeout
   under an attached hook. */
static qboolean		qr_grapple_thrown;

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

/* The attack bind on our key, re-asserted whenever the progs changes.
   IN_Init's queued defaults win at startup, but a `game` switch re-execs
   quake.rc and config.cfg and does NOT re-run IN_Init, so the key reverts to
   whatever the entered game's archived config says. On an upgrade that is the
   old "impulse 10", and the measured result was the worst kind of failure:
   the grip engaged, drew the grapple in the player's hand, and threw nothing,
   because the key event ran a weapon cycle. Peak speed 80 instead of 1000.
   The window's Game tab is exactly that in-session switch, so this would have
   bitten the first switch into rogue after installing.

   Asserted only when it differs, and only on a progs change, so it is not
   fighting the config every tick. It does override a player who deliberately
   rebound this key -- which costs nothing today, because IN_Init's block
   already discards saved rebinds of all ten controller keys on every launch.
   That is the real bug and it belongs with the bindings UI, not here. */
static void Grapple_AssertBind (void)
{
	const char	*cur = keybindings[K_RSHOULDER];

	if (cur && !strcmp (cur, "+attack"))
		return;
	Cbuf_AddText ("bind RSHOULDER +attack\n");
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
	qr_grapple_thrown = false;
	if (!progs)
		return;

	grapple_setammo = Grapple_FuncByName ("W_SetCurrentAmmo");
	grapple_reset = Grapple_FuncByName ("GrappleReset");
	grapple_ofs_hook_out = Grapple_FieldOfs ("hook_out");
	grapple_ofs_on_hook = Grapple_FieldOfs ("on_hook");
	grapple_ofs_hook = Grapple_FieldOfs ("hook");

	/* W_FireGrapple is the one that proves the weapon is implemented;
	   the rest proves we can drive and unwind it. All or nothing. */
	Grapple_AssertBind ();

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
	/* .spawned rather than .active: a client is active through a level
	   load, while its edict is being cleared. Engaging in that window
	   recorded prev_weapon = 0 off the cleared edict, then the clear
	   zeroed the grapple bit and the stolen branch locked the swing, so
	   holding the grip through a level transition left the hook locked
	   out until the player let go. Harmless but pointless. */
	if (!sv.active || !svs.clients || !svs.clients[0].active
	    || !svs.clients[0].spawned)
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

/*
Retune this swing's hook the tick it appears.

Direction is left exactly as W_FireGrapple aimed it -- only the magnitude is
rewritten -- so the muzzle fix's work and the shot's own aim survive. The
throw has already flown one server frame at rogue's 800 by the time hook_out
is visible, roughly eleven units at 90 Hz, which is inside the per-shot
residual the hand remap already carries and not worth chasing.

The think being GrappleReset is what makes nextthink the RANGE: the hook kills
itself when the timer fires, so range over speed is the time to allow.
GrappleAnchor overwrites both the think and nextthink on contact, so a hook
that lands is never cut off by this, however short the range is set.
*/
static void Grapple_TuneHook (edict_t *player)
{
	edict_t	*hook;
	int	hook_prog;
	float	speed, range, len;

	hook_prog = GRAPPLE_EDICT (player, grapple_ofs_hook);
	hook = hook_prog ? PROG_TO_EDICT (hook_prog) : NULL;
	if (!hook || hook->free)
		return;

	/* Clamped because these are player-facing cvars and both ends of each
	   are a real failure: a speed near zero is a hook that never arrives,
	   and a range past a map's own coordinate limit is a timer that cannot
	   expire before the hook leaves the world. */
	speed = vr_grapple_speed.value;
	if (speed < 100.f)
		speed = 100.f;
	else if (speed > 8000.f)
		speed = 8000.f;

	range = vr_grapple_range.value;
	if (range < 100.f)
		range = 100.f;
	else if (range > 16384.f)	/* Quake's own coordinate limit */
		range = 16384.f;

	len = VectorLength (hook->v.velocity);
	if (len > 0.f)
		VectorScale (hook->v.velocity, speed / len, hook->v.velocity);

	hook->v.nextthink = sv.time + range / speed;
}

static void Grapple_Engage (edict_t *player)
{
	qr_grapple_prev_weapon = player->v.weapon;
	qr_grapple_engaged = true;
	qr_grapple_thrown = false;
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
		   off: the button does NOTHING.
		   It used to pass through, on the principle that a layer which
		   claims a bit should not silently eat it. That was wrong here,
		   and measurably so. The bit's bind is +attack, and the Sense
		   hand that sets it is the one whose grip used to open the
		   weapon ring, so on the shipped vr_grapple 0 default a squeeze
		   fired the gun: 200 frames held burned seven shells. Doing
		   nothing is the lesser surprise by a wide margin, and the
		   input this was protecting is a classic gamepad shoulder,
		   which is not a shipping input. */
		if (qr_grapple_engaged)
			Grapple_Disengage (player);
		Grapple_SetKey (false);
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

	/* After the chain, not inside it: the engage tick cannot see its own
	   hook, and every branch above that gives up has already cleared
	   qr_grapple_engaged. */
	if (qr_grapple_engaged && !qr_grapple_thrown
	    && GRAPPLE_FLOAT (player, grapple_ofs_hook_out))
	{
		qr_grapple_thrown = true;
		Grapple_TuneHook (player);
	}
}

int Grapple_Active (void)
{
	return qr_grapple_engaged ? 1 : 0;
}

void Grapple_Init (void)
{
	Cvar_RegisterVariable (&vr_grapple);
	Cvar_RegisterVariable (&vr_grapple_speed);
	Cvar_RegisterVariable (&vr_grapple_range);
}
