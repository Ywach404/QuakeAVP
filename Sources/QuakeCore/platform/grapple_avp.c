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

static cvar_t	vr_grapple = {"vr_grapple", "1", CVAR_NONE};

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
   project what a rebuild per guess costs.

   The defaults are NO LONGER rogue's 800 and 1600, and they are not close.
   Those were kept as the stock numbers so that installing the feature
   changed nothing, and then every device session began by typing the same
   four lines, which is its own kind of wrong. 9000 and 24000 are where
   tuning in the headset landed, after 3000 and 8000 still read as slow and
   short. Rogue's own feel is one line away and nobody has ever wanted it.

   24000 is far larger than any Quake map: coordinates cap at +-4096, so the
   longest possible sight line is about 11600 units. That is the point. Range
   only sets the hook's self-destruct timer, so a range past the map's
   diagonal means a thrown hook flies until it hits something rather than
   dying in mid air, which is what "it doesn't reach" actually meant.

   One ceiling worth knowing about, because the cvar would otherwise lie:
   SV_CheckVelocity clamps every entity's velocity PER COMPONENT at
   sv_maxvelocity (2000 stock), and it runs on the hook before anything
   reads it, so a requested 3000 measured as 2061 on an axis-aligned throw.
   Grapple_TuneHook lifts sv_maxvelocity to match rather than silently
   capping -- see the note there. */
static cvar_t	vr_grapple_speed = {"vr_grapple_speed", "9000", CVAR_NONE};
static cvar_t	vr_grapple_range = {"vr_grapple_range", "24000", CVAR_NONE};

/* The swing.
   
   Rogue's pull is rails: GrappleService runs from PlayerPreThink every frame
   while on_hook and does `self.velocity = normalize(hook - me) * 1000`. An
   assignment, so gravity is irrelevant, the player's own input is computed by
   SV_RunClients and then thrown away, and any sideways motion (which is what
   a swing IS) cannot survive a single frame. Every hook in this lineage does
   the same one-liner, QuakeWorld's Threewave included, because rogue's hook
   IS that code. So there is nothing to borrow and no number to tune: a
   pendulum is a different model.

   This is the 1997 swinging-hook model instead. Never assign velocity, only
   modify it: remove the component along the rope, leave everything
   perpendicular alone, and let gravity and air control keep running. That one
   subtraction is the entire pendulum. The rope also only acts when taut, so a
   slack rope is an ordinary fall, which is where falling under your own
   control comes from.

   Off by default, because the rails version works and is shipped, and because
   having both on one install means the two can be compared in one session
   rather than across a rebuild. */
static cvar_t	vr_grapple_swing = {"vr_grapple_swing", "1", CVAR_NONE};

/* Inward speed gained per unit of overstretch, per second. The original added
   3 per TICK at 10 Hz, which is 30 per second; copying its 3 unscaled at 90 Hz
   would be seven times as stiff, which is a rope made of steel. Scaled by
   frametime here so the feel does not change with the framerate. */
static cvar_t	vr_grapple_stiff = {"vr_grapple_stiff", "30", CVAR_NONE};

/* Rope shortening, units per second, applied ONLY while the rope is taut.
   A pure pendulum conserves energy and so can never climb; the original made
   the player pump the rope by hand to gain height. Reeling only under load is
   that pump rather than a winch: slack time no longer eats rope, so a fall
   costs nothing and the rope shortens when the swing is actually pulling.
   0 is a pure pendulum, which climbs never.

   THIS IS THE CLIMB RATE, which was not obvious and cost a round of tuning
   the wrong knob. Because the reel only runs while taut, the rope's own
   shortening sets a ceiling on sustained inward speed: move in faster than
   the rope is being wound and the overstretch closes, the rope goes slack,
   and the pull stops until gravity tensions it again. So vr_grapple_haul
   cannot be exceeded by the player but it also cannot be REACHED while the
   reel is lower, and raising haul alone does nothing at all. They move
   together.

   Earlier values and what they produced: 200 was imperceptible ("it doesn't
   pull me up in any way possible"), and an overhead rope here is about 2770
   units, so 200 a second is fourteen seconds of hanging. 1500 was fast
   enough to feel but left the device verdict "really hard to get to any of
   the higher platforms", because from standing the reel IS the only way up:
   a pendulum conserves energy and cannot climb, so without a wall to kick
   off there is no momentum to convert. */
static cvar_t	vr_grapple_reel = {"vr_grapple_reel", "3200", CVAR_NONE};
static cvar_t	vr_grapple_ropemin = {"vr_grapple_ropemin", "64", CVAR_NONE};

/* COMFORT, and the two numbers that decide whether anyone but A. can use
   this. The throw being fast is exciting; being accelerated hard is what
   makes people ill, and those are separate knobs that the spring model had
   welded together.

   vr_grapple_haul is the fastest the rope may ever pull you ALONG itself.
   vr_grapple_accel is how fast that inward speed may change, in units per
   second per second, which is the jolt.

   Before these existed the measured peak inward speed was exactly TWICE the
   reel rate, every single time, because an undamped spring impulse
   overshoots its own target: at reel 1500 the arrival was ~2500 u/s, moving
   27 to 33 units in an 11 ms frame, about half a metre per frame. Lowering
   the reel does not fix that, it just scales it, and reel laws that taper
   with rope length were measured to change the timing while leaving the
   arrival exactly as hard (a rate wound down to 327 u/s still arrived at
   7104). The arrival is the thing, so the arrival is what this bounds. */
static cvar_t	vr_grapple_haul = {"vr_grapple_haul", "3200", CVAR_NONE};
static cvar_t	vr_grapple_accel = {"vr_grapple_accel", "1500", CVAR_NONE};

/*
The pull is scaled by HOW LONG THE ROPE IS, and that came from the device.

Flat acceleration is wrong at both ends of the range and it took two opposite
complaints to see why. A long throw across the hall, or up at a high anchor
while falling, had "no pickup": the rope caught and then took over a second
to do anything, and the ground arrived first. The same number on a grab at
arm's length was "too fast right away", a yank rather than a swing. Both are
true, because one acceleration cannot serve a 3000-unit rope and a 300-unit
one -- the long rope has distance to spend getting up to speed and the short
rope has none, so the same ramp reads as sluggish in one and violent in the
other.

accelref is the rope length that earns the WHOLE of vr_grapple_accel.
Shorter ropes get the same fraction of it as they are of accelref, down to
accelmin, so the pull softens as you close on the anchor rather than driving
into it at full rate. dist and not qr_grapple_rope on purpose: the distance
still to cover is the thing that decides how hard the rope may haul, and
using it means the ease-off is continuous and needs no separate arrival case.

Gravity compensation below is deliberately NOT scaled. It is not part of the
pull, it is the correction that stops gravity being quietly charged to this
knob, so a short overhead rope still nets the softened acceleration upward
instead of sinking because its budget no longer covers the fall.
*/
static cvar_t	vr_grapple_accelref = {"vr_grapple_accelref", "1536", CVAR_NONE};
static cvar_t	vr_grapple_accelmin = {"vr_grapple_accelmin", "0.2", CVAR_NONE};

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
/* Optional, and deliberately NOT part of grapple_supported: rogue's own
   teleport release lives inside the on_hook branch of GrappleService, which
   the swing takes out of circuit, so the swing has to notice a teleport
   itself. A progs without the field just does not get that release rather
   than losing the whole feature. */
static int		grapple_ofs_tptime;

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

/* True while THIS module owns the player's velocity instead of rogue's pull.
   Latched at the anchor and held for the rest of the swing even if the cvar
   is turned off underneath it: with on_hook cleared, rogue will not resume
   pulling, so handing the swing back mid-flight would leave the player
   hanging on a rope that nothing is simulating. */
static qboolean		qr_grapple_swinging;
static float		qr_grapple_rope;	/* rest length, units */

/* sv_friction as it was before a swing borrowed it, or -1 for "not held".
   Explicitly -1: a bare static is 0, which this code would read as "borrowed,
   and the old value was 0", so the first progs change of the session would
   have handed sv_friction a permanent zero with no swing involved.
   See Grapple_HoldFriction. */
static float		qr_grapple_friction = -1.f;

/*
Borrow sv_friction for the duration of a swing, and give it back.

This replaces clearing FL_ONGROUND every frame, which worked and cost the
player their jump. Quake's PlayerJump requires FL_ONGROUND, so a flag cleared
every frame is a jump that can never fire -- and jumping off a rope pulled
taut along the ground is a real technique, not an edge case. It was reported
from the headset as exactly that.

Friction is what the flag was being cleared to avoid, so suppress the cause
instead of the symptom. SV_UserFriction scales ALL THREE velocity components
by a factor derived from the HORIZONTAL speed, so it eats a vertical haul as
readily as a horizontal one, and it is gated on FL_ONGROUND -- which is why
the flag was the lever that happened to work. With friction out of the way
the flag can stay, SV_WalkMove goes back to owning it (it clears the flag at
the start of every move and SV_FlyMove re-sets it on landing), and jump
behaves normally throughout.

It is a global, so it is saved and restored rather than written blind, and
every path that ends a swing goes through Grapple_Disengage, which is the one
place that gives it back. Re-asserted each frame so a console `sv_friction`
mid-swing cannot strand the value either.
*/
static void Grapple_HoldFriction (void)
{
	cvar_t	*fr = Cvar_FindVar ("sv_friction");

	if (!fr)
		return;
	if (qr_grapple_friction < 0.f)
		qr_grapple_friction = fr->value;
	if (fr->value != 0.f)
		Cvar_SetValueQuick (fr, 0.f);
}

static void Grapple_ReleaseFriction (void)
{
	cvar_t	*fr;

	if (qr_grapple_friction < 0.f)
		return;
	fr = Cvar_FindVar ("sv_friction");
	if (fr)
		Cvar_SetValueQuick (fr, qr_grapple_friction);
	qr_grapple_friction = -1.f;
}

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
	grapple_ofs_tptime = -1;
	qr_grapple_swinging = false;
	qr_grapple_engaged = false;	/* the edict it referred to is gone */
	qr_grapple_locked = false;
	qr_grapple_thrown = false;
	Grapple_ReleaseFriction ();	/* a game switch skips Disengage */
	if (!progs)
		return;

	grapple_setammo = Grapple_FuncByName ("W_SetCurrentAmmo");
	grapple_reset = Grapple_FuncByName ("GrappleReset");
	grapple_ofs_hook_out = Grapple_FieldOfs ("hook_out");
	grapple_ofs_on_hook = Grapple_FieldOfs ("on_hook");
	grapple_ofs_hook = Grapple_FieldOfs ("hook");
	grapple_ofs_tptime = Grapple_FieldOfs ("teleport_time");

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

/* The hook edict this swing owns, or NULL. .hook is a progs entity field, so
   it is an offset into the edict rather than a named member. */
static edict_t *Grapple_Hook (edict_t *player)
{
	edict_t	*hook;
	int	hook_prog;

	hook_prog = GRAPPLE_EDICT (player, grapple_ofs_hook);
	hook = hook_prog ? PROG_TO_EDICT (hook_prog) : NULL;
	if (!hook || hook->free)
		return NULL;
	return hook;
}


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

	Grapple_SetKey (false);
	qr_grapple_swinging = false;
	Grapple_ReleaseFriction ();
	if (!qr_grapple_engaged)
		return;
	qr_grapple_engaged = false;
	if (!player)
		return;

	if (GRAPPLE_FLOAT (player, grapple_ofs_hook_out))
	{
		hook = Grapple_Hook (player);
		if (hook)
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
	cvar_t	*mv;
	float	speed, range, len;

	hook = Grapple_Hook (player);
	if (!hook)
		return;

	/* Clamped because these are player-facing cvars and both ends of each
	   are a real failure: a speed near zero is a hook that never arrives,
	   and a range past a map's own coordinate limit is a timer that cannot
	   expire before the hook leaves the world. */
	/* The ceilings are high because the defaults went up and a clamp that
	   silently caps a player-facing cvar is worse than no clamp. They exist
	   to stop a typo being a crash, not to express an opinion: the hook is
	   MOVETYPE_FLYMISSILE, and SV_FlyMove traces the whole step, so even
	   100 units of travel per frame cannot tunnel through a wall. */
	speed = vr_grapple_speed.value;
	if (speed < 100.f)
		speed = 100.f;
	else if (speed > 30000.f)
		speed = 30000.f;

	range = vr_grapple_range.value;
	if (range < 100.f)
		range = 100.f;
	else if (range > 65536.f)
		range = 65536.f;

	/* SV_CheckVelocity clamps PER COMPONENT at sv_maxvelocity and runs on
	   the hook before anything reads it, so without this a requested 3000
	   arrives as 2061 on an axis-aligned throw AND the direction bends,
	   because clipping one axis of a vector rotates it. Measured: an aim
	   pitch of -20 came out at -22.3. Raising the ceiling instead of
	   capping the request keeps the cvar honest about what it does.

	   This is a global physics knob and it is being written from a weapon,
	   which deserves the flinch it gets. Raised only, never lowered, and
	   only to what was actually asked for: the only other things in Quake
	   that approach 2000 are a long fall and a rocket jump, and both are
	   improved by not being clipped mid-swing -- the player's OWN velocity
	   goes through the same clamp, so a fast swing was being flattened by
	   it too. */
	mv = Cvar_FindVar ("sv_maxvelocity");
	if (mv && mv->value < speed)
		Cvar_SetValueQuick (mv, speed);

	len = VectorLength (hook->v.velocity);
	if (len > 0.f)
		VectorScale (hook->v.velocity, speed / len, hook->v.velocity);

	hook->v.nextthink = sv.time + range / speed;
}

/* Rogue measures the rope from roughly the chest, not from the origin. */
#define GRAPPLE_ROPE_UP		16.f
/* Far enough out that SV_RunThink never reaches it, re-asserted every tick. */
#define GRAPPLE_THINK_PARK	1000.f
/* Pretension in the rope at the anchor, so the swing cannot start deadlocked
   exactly taut. See Grapple_TakeOver. */
#define GRAPPLE_SEED_SLACK	64.f
/* How far past its rest length the rope may ever be stretched. See the reel. */
#define GRAPPLE_MAX_STRETCH	256.f

/*
Take rogue's pull out of circuit and own the velocity for this swing.

Three writes, each load bearing.

on_hook cleared is what stops GrappleService assigning velocity every frame.
It does NOT stop the chain being drawn: the !on_hook branch of that same
function is precisely the draw-the-trail branch, so the rope keeps rendering
for free. That is the one part of this that would otherwise have needed
renderer work.

The hook's own think has to be parked, because GrappleTrack opens by
resetting the whole hook whenever its owner is not on_hook -- so clearing the
flag alone would delete the hook a tenth of a second later. Parked rather
than replaced: nextthink is pushed past anything SV_RunThink will reach, and
GrappleReset still removes the hook on release, because that call does not go
through the think.

FL_ONGROUND cleared because ground friction eats a swing launched from
standing. Every hook in the family does this, for the same reason.
*/
static void Grapple_TakeOver (edict_t *player, edict_t *hook)
{
	vec3_t	rope;
	float	rmin;

	VectorSubtract (hook->v.origin, player->v.origin, rope);
	rope[2] -= GRAPPLE_ROPE_UP;
	qr_grapple_rope = VectorLength (rope);

	/* SEED IT SHORT. The rope must start with tension, and the reason is a
	   deadlock measured on the host: 130 frames in which not one bit of
	   state changed, from a throw made while standing still.

	   The rest length used to be exactly the distance at the anchor, which
	   means the rope starts precisely taut. SwingFrame returns early on
	   `dist <= rope`, which is correct and is what makes a slack rope feel
	   like a rope -- but it returns BEFORE the reel, so the rope cannot
	   shorten. And nothing can make the distance grow either: a player
	   standing on a floor has gravity clipped away against the floor plane
	   every frame, so the origin never moves. Never slack, never taut,
	   never anything. The earlier code reeled while slack too, which is
	   what accidentally broke that tie.

	   GRAPPLE_SEED_SLACK of pretension costs nothing anywhere else and
	   bootstraps the whole thing: the spring lifts the player off the
	   floor, the fall tensions the rope, the reel starts, and from there
	   it runs. Measured after one unit of slack was introduced by hand, a
	   2878-unit haul completed in 1.26 s. The haul was never slow. It
	   never started. */
	qr_grapple_rope -= GRAPPLE_SEED_SLACK;

	rmin = vr_grapple_ropemin.value;
	if (rmin < 8.f)
		rmin = 8.f;
	if (qr_grapple_rope < rmin)
		qr_grapple_rope = rmin;

	GRAPPLE_FLOAT (player, grapple_ofs_on_hook) = 0.f;
	hook->v.nextthink = (float) (sv.time + GRAPPLE_THINK_PARK);
	Grapple_HoldFriction ();
	qr_grapple_swinging = true;
}

/*
One tick of rope physics.

The model, and why it is not rogue's:

  - the component of velocity ALONG the rope is removed and nothing else is
    touched, so sideways motion survives, and that is the pendulum;
  - only the OUTWARD component goes. The 1997 original subtracted the whole
    projection, which also ate a deliberate reel-in, and it is the one place
    worth departing from it;
  - overstretch is corrected with a spring toward the anchor rather than by
    moving the player, so the rope gives slightly instead of snapping the
    view;
  - a slack rope does nothing at all, which is what makes a held hook feel
    like a rope instead of a rail, and is where falling under your own
    control comes from;
  - velocity is never assigned, so SV_AddGravity and the player's own air
    acceleration both still run. The speed a swing builds IS gravity doing
    work along the arc, and the steering is ordinary Quake air control.

This runs from IN_Commands, one frame ahead of the server frame that
integrates it (host.c runs IN_Commands, then Host_ServerFrame). That lag is
exactly why the correction is a spring: a hard positional constraint applied
a frame stale would jitter visibly, while a spring sags a little and
recovers.
*/
/* Read, not reimplemented: this is the same cvar SV_AddGravity spends, and
   the swing has to know what the next physics frame is about to take. */
extern cvar_t	sv_gravity;

static void Grapple_SwingFrame (edict_t *player, edict_t *hook)
{
	vec3_t	rope, dir;
	float	dist, radial, pull, dt, rmin, reel, stiff, smax;
	float	haul, accel, want, amax, grav, ref, frac, lo;
	eval_t	*val;

	dt = (float) host_frametime;
	if (dt <= 0.f)
		return;

	hook->v.nextthink = (float) (sv.time + GRAPPLE_THINK_PARK);

	/* EVERY frame, because this is what a swing was losing to the floor.
	   Measured with friction running: velocity exactly 0.0 for the first 8
	   frames of a swing and under 100 u/s for 25, against rails' 994 on
	   frame 0, because friction takes about 4.5 percent per frame and a
	   starting swing has less than that to give. */
	Grapple_HoldFriction ();

	VectorSubtract (hook->v.origin, player->v.origin, rope);
	rope[2] -= GRAPPLE_ROPE_UP;
	dist = VectorLength (rope);
	if (dist < 1.f)
		return;
	VectorScale (rope, 1.f / dist, dir);	/* unit, player -> anchor */

	/* The pump. A pendulum conserves energy and so can never climb; the
	   original made the player shorten the rope by hand to gain height.
	   A steady reel is that pump without a new binding. */
	rmin = vr_grapple_ropemin.value;
	if (rmin < 8.f)
		rmin = 8.f;

	if (dist <= qr_grapple_rope)
		return;			/* slack rope: an ordinary fall */

	/* The pump reels only UNDER LOAD, so hanging slack costs no rope and
	   the shortening happens where it adds energy to the swing. */
	reel = vr_grapple_reel.value;
	if (reel < 0.f)
		reel = 0.f;		/* a negative reel is not a feature */
	qr_grapple_rope -= reel * dt;
	if (qr_grapple_rope < rmin)
		qr_grapple_rope = rmin;

	/* The reel must not outrun the player. With the haul speed bounded, a
	   reel faster than the haul would wind the rope all the way to its
	   minimum while the player was still far away, leaving a permanently
	   overstretched rope: the pull would saturate and the whole thing would
	   be a constant-speed winch again, with the pendulum gone. Capping the
	   overstretch keeps the rope a rope. */
	if (dist - qr_grapple_rope > GRAPPLE_MAX_STRETCH)
		qr_grapple_rope = dist - GRAPPLE_MAX_STRETCH;

	/* dir points AT the anchor, so a negative dot is motion away from it,
	   and that is the only part the rope is allowed to cancel. Everything
	   perpendicular survives untouched, which is the pendulum. */
	radial = DotProduct (player->v.velocity, dir);
	if (radial < 0.f)
	{
		VectorMA (player->v.velocity, -radial, dir, player->v.velocity);
		radial = 0.f;
	}

	/* The pull is a TARGET SPEED approached at a bounded rate, not a force.

	   It was a force, and a force is what made this sickening: an impulse
	   proportional to overstretch has nothing telling it when to stop, so
	   it sails past the speed that would have closed the gap and the
	   measured arrival came in at twice the reel rate. Steering a velocity
	   instead means the stiffness still decides how URGENTLY the rope
	   responds, while haul decides how fast it is ever allowed to move you
	   and accel decides how hard that change is allowed to feel. Those are
	   three different questions and they now have three different answers.

	   Stiffness is still clamped against the timestep, because this is
	   explicit integration and sqrt(stiff) * dt reaching 2 diverges: half
	   that bound, which leaves margin for a hitch. The frame CAN get long,
	   both QC_Frame and Host_FilterTime permit 0.1 s, and at stiff 2000
	   with a frame that long the old impulse became a two-frame limit cycle
	   flipping between 0 and 1785 u/s with the player teleporting 76 to 131
	   units every frame. A negative stiffness was a repulsor that shoved
	   the player into geometry, so the floor is zero. */
	stiff = vr_grapple_stiff.value;
	smax = 1.f / (dt * dt);
	if (stiff < 0.f)
		stiff = 0.f;
	else if (stiff > smax)
		stiff = smax;

	haul = vr_grapple_haul.value;
	if (haul < 0.f)
		haul = 0.f;
	accel = vr_grapple_accel.value;
	if (accel < 1.f)
		accel = 1.f;

	/* Scale by rope length: see the note on vr_grapple_accelref. */
	ref = vr_grapple_accelref.value;
	if (ref < 1.f)
		ref = 1.f;
	lo = vr_grapple_accelmin.value;
	if (lo < 0.f)
		lo = 0.f;
	else if (lo > 1.f)
		lo = 1.f;
	frac = dist / ref;
	if (frac < lo)
		frac = lo;
	else if (frac > 1.f)
		frac = 1.f;
	accel *= frac;

	want = (dist - qr_grapple_rope) * stiff;
	if (want > haul)
		want = haul;

	/* Gravity comes out of the SAME budget, so accel has to be net of it or
	   the knob means a different thing depending on where you aimed.

	   The next physics frame subtracts ent_gravity * sv_gravity * dt from
	   velocity[2], and the part of that lying along the rope is
	   grav * dt * dir[2]. With the anchor overhead dir[2] is near 1, so
	   gravity takes 800 of the 1500 this frame was allowed to add and the
	   felt climb is 700 -- while the same knob on a level haul delivers the
	   whole 1500. That is what "the rope has no pickup when I'm falling
	   fast" is: aiming UP more than halves the acceleration, and the number
	   that was tuned for comfort was tuned on a level shot.

	   Paying gravity from its own line makes accel the acceleration the
	   player actually gets, whatever the angle. Only an UPWARD rope is
	   compensated: hauling downward already has gravity helping and must
	   not be handed the budget as well, or a downward pull would hit twice
	   as hard as the knob says. */
	grav = sv_gravity.value;
	val = GetEdictFieldValue (player, "gravity");
	if (val && val->_float)
		grav *= val->_float;

	pull = want - radial;		/* the change this frame asks for */
	amax = accel * dt;		/* and the most it may have */
	if (dir[2] > 0.f)
		amax += grav * dt * dir[2];
	if (pull > amax)
		pull = amax;
	else if (pull < -amax)
		pull = -amax;
	if (pull > 0.f)
		VectorMA (player->v.velocity, pull, dir, player->v.velocity);
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
		/* And make it wait for a new press. Grapple_Player returns NULL
		   for the whole of a level load, so without this the first
		   spawned frame sees the grip still down and `want` true again:
		   measured, the weapon was rewritten on frame 0 of the new map,
		   the hook was out by frame 2, and the player was dragged across
		   a level they had just arrived in, having pressed nothing. A
		   death and restart did the same. Every other cancel the player
		   did not ask for already takes this lock; this path was the one
		   that did not, and it mattered less when the hook was a winch
		   than it does now that it hands out a swing. */
		if (held)
			qr_grapple_locked = true;
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
	if (qr_grapple_engaged)
	{
		edict_t	*hook;

		hook = GRAPPLE_FLOAT (player, grapple_ofs_hook_out)
		     ? Grapple_Hook (player) : NULL;

		if (!hook)
		{
			/* No hook in the world: either the throw has not left
			   yet, or it timed out or hit sky. Rogue re-fires on
			   its own while attack stays held, which IS the
			   chained-swing rhythm, so this does not end the
			   engagement -- it re-arms so the next throw is tuned
			   too, and stops simulating a rope that is gone. */
			qr_grapple_swinging = false;
			qr_grapple_thrown = false;
		}
		else if (!qr_grapple_thrown)
		{
			qr_grapple_thrown = true;
			Grapple_TuneHook (player);
		}
		else if (qr_grapple_swinging)
		{
			/* Rogue's own teleport release sits inside the on_hook
			   branch that the swing disabled, so it has to happen
			   here or a teleport leaves the player on the rope.
			   Locked like every other cancel the player did not
			   ask for, so a held grip does not re-throw into the
			   teleporter three times on the way through. */
			if (grapple_ofs_tptime >= 0
			    && GRAPPLE_FLOAT (player, grapple_ofs_tptime) > sv.time)
			{
				if (held)
					qr_grapple_locked = true;
				Grapple_Disengage (player);
			}
			else if (!sv.paused)
			{
				/* PAUSED IS NOT A SMALL CASE. IN_Commands keeps
				   running while SV_Physics does not, so every
				   paused frame would add a spring impulse that
				   nothing integrates away and nothing clamps,
				   on a frozen sv.time. Measured before this
				   guard: 2 seconds of pause took the player
				   from 393 to 7036 units/s, and unpausing fired
				   them across the room at the velocity ceiling.
				   It scales with pause length, so a backgrounded
				   app was a catapult. The shipped pause happens
				   to zero the pad and disengage first, which hid
				   it; a `pause` from anywhere that does not is
				   the one that would have found it. */
				Grapple_SwingFrame (player, hook);
			}
		}
		else if (vr_grapple_swing.value != 0
			 && GRAPPLE_FLOAT (player, grapple_ofs_on_hook))
		{
			Grapple_TakeOver (player, hook);
		}
	}
}

int Grapple_Active (void)
{
	return qr_grapple_engaged ? 1 : 0;
}

/*
Force this module's defaults past any config.cfg that already names them.

NOT ARCHIVED, and then forced on top, which is two belts for one pair of
trousers. The reason is a day of tuning thrown away, and it is worth writing
down because nothing announced it.

CVAR_ARCHIVE means a value is WRITTEN to config.cfg. It does not control
whether one is READ: a cvar line in config.cfg sets the cvar whatever its
flags say. So eight sessions of tuning the defaults in this file reached a
device whose Library/Application Support/QuakeAVP/id1/config.cfg had been
written before any of them existed, and quake.rc exec'd it over the top on
every single launch. The measured state on device was speed 800, range 1600,
swing 0 -- rogue's untouched originals with the pendulum off -- while the
source said 9000, 24000 and on. Every install restarted the app and silently
reverted a value that had just been typed by hand, so the feature appeared to
ignore three consecutive rounds of being made faster.

Dropping CVAR_ARCHIVE stops the file growing new lines. This clears the lines
already in it. Cbuf_AddText APPENDS while Cmd_Exec_f uses Cbuf_InsertText,
which PREPENDS, so text queued here during IN_Init runs AFTER quake.rc and
every config it execs -- the same ordering in_null.c's bind block relies on,
and the same reason that block clobbers saved rebinds (see the bindings UI
work). Clobbering is the intent here: while these numbers are being tuned,
the build's value has to be the one that runs.

This comes OUT when the numbers settle, at which point the cvars go back to
CVAR_ARCHIVE and the player's own tuning is theirs to keep.
*/
static void Grapple_ForceDefaults (void)
{
	Cbuf_AddText ("vr_grapple 1\n");
	Cbuf_AddText ("vr_grapple_speed 9000\n");
	Cbuf_AddText ("vr_grapple_range 24000\n");
	Cbuf_AddText ("vr_grapple_swing 1\n");
	Cbuf_AddText ("vr_grapple_stiff 30\n");
	Cbuf_AddText ("vr_grapple_reel 3200\n");
	Cbuf_AddText ("vr_grapple_ropemin 64\n");
	Cbuf_AddText ("vr_grapple_haul 3200\n");
	Cbuf_AddText ("vr_grapple_accel 1500\n");
	Cbuf_AddText ("vr_grapple_accelref 1536\n");
	Cbuf_AddText ("vr_grapple_accelmin 0.2\n");
}

void Grapple_Init (void)
{
	Cvar_RegisterVariable (&vr_grapple);
	Cvar_RegisterVariable (&vr_grapple_speed);
	Cvar_RegisterVariable (&vr_grapple_range);
	Cvar_RegisterVariable (&vr_grapple_swing);
	Cvar_RegisterVariable (&vr_grapple_stiff);
	Cvar_RegisterVariable (&vr_grapple_reel);
	Cvar_RegisterVariable (&vr_grapple_ropemin);
	Cvar_RegisterVariable (&vr_grapple_haul);
	Cvar_RegisterVariable (&vr_grapple_accel);
	Cvar_RegisterVariable (&vr_grapple_accelref);
	Cvar_RegisterVariable (&vr_grapple_accelmin);
	Grapple_ForceDefaults ();
}
