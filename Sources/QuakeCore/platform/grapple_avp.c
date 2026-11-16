/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * grapple_avp.c -- the grappling hook.
 *
 * The hook is this file's, start to finish: a position and a velocity traced
 * forward by SV_Move each tick, an anchor latched where the world stops it,
 * and a pendulum that writes the player's velocity. It is not an entity, it
 * is not networked, and it asks the loaded progs for nothing.
 *
 * It was not always. The first version was a DRIVER for rogue's compiled
 * QuakeC, which ships a complete hook that is simply unreachable: every path
 * that hands you the weapon is gated on `deathmatch && teamplay >= 4`, and
 * this engine never writes the teamplay progs global, so the condition cannot
 * become true by any cvar. Verified by sweeping impulses 1 through 50 with
 * every item granted; none of them reaches it, and `impulse 9` does not
 * either. Reaching it meant writing `.weapon = 1<<23` and raising a synthetic
 * held `+attack` so rogue's W_FireGrapple would run.
 *
 * Three things were wrong with that, and all three were the same thing. The
 * hook could not move to the off hand, because while it was out the player's
 * .weapon WAS the grapple and there was no gun left to hold. It could not
 * exist in id1, hipnotic, dopa, mg1 or mg3, because none of them ships
 * W_FireGrapple or the hook fields. And `1<<23` is HIT_LASER_CANNON under
 * hipnotic and mg3, so the write was a landmine waiting on the day its
 * capability gate loosened.
 *
 * What stayed is the part that was always ours: the pendulum below, which is
 * the 1997 swinging-hook model and not rogue's rails, and every number in it.
 *
 * No seventh engine hunk, and none needed. The two existing hunks that carry
 * a shot from the hand (cl_tent.c for the lightning beam, pr_cmds.c for
 * missiles) are untouched by this and no longer involved: this hook does not
 * go through setorigin and its rope is not a TE_BEAM. Both of those used to
 * matter here, and the note they produced is worth keeping because it was
 * measured wrong on device while reading correct in source -- neither route
 * was unconditional, because both ran through QR_HandOrigin, which returns 0
 * whenever qr_aim_active is false, and then the hook came out of the player's
 * chest. The throw below still calls QR_HandOrigin and still degrades the
 * same way, deliberately.
 */

#include "quakedef.h"
#include "QuakeCore.h"	/* QC_PAD_* bits */
#include "grapple_avp.h"

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

   A ceiling that used to make this cvar lie, and no longer does, kept
   because it explains an absence. SV_CheckVelocity clamps every EDICT's
   velocity per component at sv_maxvelocity (2000 stock) before anything reads
   it, so a requested 3000 measured 2061 on an axis-aligned throw, and the
   direction bent as well as the speed: clipping one axis of a vector rotates
   it, and an aim pitch of -20 came out at -22.3. The old code answered that
   by RAISING sv_maxvelocity, a global physics knob written from a weapon,
   which deserved the flinch it got. A hook owned by this file is not an edict
   and never meets SV_CheckVelocity, so that write is gone and the knob is
   left alone. */
static cvar_t	vr_grapple_speed = {"vr_grapple_speed", "9000", CVAR_NONE};
static cvar_t	vr_grapple_range = {"vr_grapple_range", "24000", CVAR_NONE};

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

/* What a hooked monster loses. 10 is rogue's own hook damage per hit, so this
   is the value that changes nothing for a player who already knows the
   weapon. Applied once per throw, not per frame: a rope that keeps hurting
   what it is tied to is a different weapon and nobody asked for one. */
static cvar_t	vr_grapple_damage = {"vr_grapple_damage", "10", CVAR_NONE};

/* The head's model. A cvar rather than a literal for two reasons: it is the
   only way to point the hook at something else from the console without a
   rebuild, and it is what makes BOTH branches of the bridge's resolve
   testable on the host, where no basedir has rogue's pak and only the
   fallback would ever run. Not static: the bridge reads it to draw, the way
   it reads vr_worldscale out of r_null.c. */
cvar_t	vr_grapple_headmodel = {"vr_grapple_headmodel", "progs/hook.mdl", CVAR_NONE};

/* in_null.c, file-local extern the way qr_bridge.c takes the same symbol at
   qr_bridge.c:76. Returns 0 when the aim channel is not live. */
extern int	QR_HandOrigin (vec3_t out);
/* The OFF hand: where the rope leaves from. Returns 0 when that channel is
   not live, which is what drives the fallback chain in Grapple_Throw. */
extern int	QR_OffHandOrigin (vec3_t out);

static grapple_state_t	qr_grapple_state;
static vec3_t		qr_grapple_tip;		/* the head, in world space */
static vec3_t		qr_grapple_fly_vel;
/* The head's drawn orientation. Tracked from the velocity each flight frame
   and then LEFT ALONE once the hook bites: at the bite the velocity that put
   it in the wall is gone, so a pose recomputed from the live velocity would
   snap the head flat on the frame it lands. Frozen is also what rogue does,
   by accident of the hook being an edict that simply stops. */
static vec3_t		qr_grapple_head_angles;
static float		qr_grapple_fly_ttl;	/* seconds of flight left */

/* The anchor, stored RELATIVE to what it stuck to, so a moving platform
   carries the rope's far end with it. Entity 0 is the world, whose origin is
   always zero, so the offset is then simply the absolute position and needs no
   special case anywhere. */
/* The player is holding the grip and this module owns a throw. Distinct
   from the hook's own state: an engagement outlives a miss, which is what
   makes the chained re-throw possible. */
static qboolean		qr_grapple_engaged;

static int		qr_grapple_anchor_num;
static vec3_t		qr_grapple_anchor_ofs;

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

/* T_Damage, or 0. The ONE thing this module asks of a game's progs, and it is
   optional in the strongest sense: a progs without it gets a hook that
   anchors and swings and simply does not hurt what it catches. It can never
   gate whether the hook works.
   It is affordable where rogue's six symbols were not, because T_Damage is
   defined in id1's own combat.qc and every game here is id1-derived, so
   unlike W_FireGrapple it is expected everywhere rather than in one pack. */
static func_t		grapple_damage;

/* T_Damage's declared arity as the lookup found it, or -1 for absent. Kept
   alongside grapple_damage because that one cannot tell its two failures
   apart: it is 0 both for "this progs has no T_Damage" and for "it has one
   whose arguments are not the four we would pass", and those are a game
   without the feature and a mod to be suspicious of. The announcement below
   exists to separate exactly those two, so collapsing them here would defeat
   it before it was written. */
static int		grapple_damage_parms = -1;

/* Armed by a resolve that actually saw a progs, consumed by the next engage.
   The two have nothing in common today: the resolver is the only code that
   knows the progs changed, and the engage is the first moment a player could
   care. Keyed on the RESOLVE and not on the load, which is what makes the
   cadence right -- walking e1m1 to e1m2 reloads progs with the same CRC and
   stays quiet, while a `game` switch speaks once. */
static qboolean		grapple_announce;


/* Set whenever a swing ends for any reason OTHER than the player letting go,
   and cleared only when the grip actually comes up. Without it a cancel
   re-arms under a still-held grip: closing the weapon ring fired a fresh
   hook on the next tick, and a weapon stolen mid-swing was stolen straight
   back and recorded as the thing to restore. A cancelled swing should wait
   for a new press. */
static qboolean		qr_grapple_locked;


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

	/* A swing cannot survive the progs changing under it: the anchor it is
	   pulling against belonged to a world that has just been replaced. This
	   is also the only place a game switch gets to give sv_friction back,
	   because COM_Game_f re-execs quake.rc without going anywhere near this
	   module's disengage path. */
	qr_grapple_state = GRAPPLE_IDLE;
	qr_grapple_anchor_num = 0;
	qr_grapple_swinging = false;
	qr_grapple_engaged = false;
	qr_grapple_locked = false;
	Grapple_ReleaseFriction ();
	grapple_damage = 0;
	grapple_damage_parms = -1;
	if (!progs)
		return;

	/* The arity check is the guard, not a formality. PR_EnterFunction copies
	   arguments out of OFS_PARM0 + i*3 + j for i < f->numparms, so it is the
	   CALLEE's declared arity that decides what gets read: a mod whose
	   T_Damage takes a fifth deathtype parameter would have it read out of
	   whatever OFS_PARM4 happened to hold. An unexpected arity is therefore
	   treated exactly as a missing function. */
	grapple_damage = Grapple_FuncByName ("T_Damage");
	if (grapple_damage)
		grapple_damage_parms = pr_functions[grapple_damage].numparms;
	if (grapple_damage && pr_functions[grapple_damage].numparms != 4)
		grapple_damage = 0;

	/* Armed here, below the progs guard rather than above it: a resolve
	   with no progs loaded is every frame of the menu and has nothing to
	   announce. Nothing is lost by arming late, because the pointer key
	   flips from NULL when a map finally arrives and the resolve runs
	   again. */
	grapple_announce = true;
}

/* Which of the three states the lookup landed in. Split out and handed its
   argument instead of reading the static, so the classification is one
   expression a host test can drive through every branch without a progs --
   which matters because only the resolved branch is reachable from any game
   data this project has to test against. */
typedef enum
{
	GRAPPLE_DAMAGE_OK = 0,
	GRAPPLE_DAMAGE_ABSENT,
	GRAPPLE_DAMAGE_ARITY
} grapple_damage_state_t;

static grapple_damage_state_t Grapple_DamageState (int parms)
{
	if (parms < 0)
		return GRAPPLE_DAMAGE_ABSENT;
	if (parms != 4)
		return GRAPPLE_DAMAGE_ARITY;
	return GRAPPLE_DAMAGE_OK;
}

/* Say once per progs what this game's hook can do, naming the game so a pass
   over six of them reads back as six lines. Each line states the CONSEQUENCE
   rather than the symbol's fate, because the question being answered in the
   headset is never "did a lookup succeed", it is "is this hook doing no
   damage because this game cannot, or because I have broken it". */
static void Grapple_Announce (void)
{
	const char *game = COM_SkipPath (com_gamedir);

	switch (Grapple_DamageState (grapple_damage_parms))
	{
	case GRAPPLE_DAMAGE_OK:
		Con_Printf ("[grapple] %s: T_Damage resolved, the hook hurts "
			    "what it catches\n", game);
		break;
	case GRAPPLE_DAMAGE_ABSENT:
		Con_Printf ("[grapple] %s: no T_Damage in this progs, so the "
			    "hook anchors and swings but does no damage\n",
			    game);
		break;
	case GRAPPLE_DAMAGE_ARITY:
		Con_Printf ("[grapple] %s: T_Damage takes %d arguments, not 4, "
			    "so it is left alone and the hook does no "
			    "damage\n", game, grapple_damage_parms);
		break;
	}
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
Let go of the rope.

This used to be the most delicate function in the file and is now four
assignments, which is the clearest measure of what moving the hook into C
bought. The old version had to call rogue's GrappleReset with `self` pointed at
the hook edict and then put the player's weapon back, in that order, because
GrappleService only released on `!button0 && weapon == IT_GRAPPLE` while
GrappleAnchor did not check the weapon at all. Any moment with the hook out and
attack held while the weapon was something else ended with the player pinned:
measured at 400 frames, 13 seconds of server time, past the hook's own
self-timeout, with `+forward` moving the player 0.0 units. Genuinely
immobilised.

None of that can happen any more. There is no weapon write to undo, no
synthetic attack to drop, and no progs state to unwind -- so there is no
ordering to get wrong, and the weapon ring can no longer strand anybody.

Friction is the one thing that must still be given back, because it is a
global this module borrows (see Grapple_HoldFriction), and every path that
ends a swing comes through here.
*/
static void Grapple_Disengage (void)
{
	qr_grapple_state = GRAPPLE_IDLE;
	qr_grapple_anchor_num = 0;
	qr_grapple_swinging = false;
	qr_grapple_engaged = false;
	Grapple_ReleaseFriction ();
}

/*
May the rope be tied where this trace stopped?

Separated from the flight step and kept pure over the trace, because a stop is
not an anchor and the three ways it is not are each worth refusing by name.

A trace that began inside solid reports fraction 0, which is indistinguishable
from a legitimate point-blank hit, so the degenerate cases are refused before
the distance is looked at. An all-solid trace has no valid plane to hang from.
And sky is a surface the hook must fall through rather than stick to: a rope
tied to the sky is a rope tied to the edge of the map, and the hook's own range
timer is what ends such a throw.

`contents` is what the world holds just past the impact, which the caller reads
with SV_PointContents. It is passed in rather than read here so that this stays
a decision over its arguments and can be tested without a world.
*/
static int Grapple_AnchorFromTrace (const trace_t *tr, int contents)
{
	if (tr->allsolid || tr->startsolid)
		return -1;
	if (tr->fraction >= 1.f)
		return 0;		/* nothing in the way: keep flying */
	if (contents == CONTENTS_SKY)
		return -1;
	return 1;
}

/*
The hook's own state, which used to be an edict and is now five statics.

Nothing here is networked and nothing is precached. That is the whole reason
this works in every game rather than only in rogue: a hook that asks the map
for a model cannot exist in a map that never precached one, and
PF_precache_model refuses outside ss_loading, so there is no way to add one at
fire time. The renderer draws the head and the rope from qr_grapple_tip
instead, client side, out of models it loads for itself.
*/

/*
Hurt what the hook caught.

T_Damage (entity targ, entity inflictor, entity attacker, float damage), so
four parameters, and this is the first place in platform/ that passes any. The
three existing callers of PR_ExecuteProgram pass state only through
pr_global_struct->self, so there was no pattern to copy: arguments go in
OFS_PARM0 upward, three floats apart, and PR_EnterFunction copies them into the
callee's locals on entry.

self and other are both saved and restored, on the model of admin_avp.c's
FoundTarget call, because IN_Commands runs inside Host_Frame's error frame and
a QuakeC runaway in here has to unwind exactly as a think would.

The player is both inflictor and attacker: the rope is not a separate entity
any more, so there is nothing else it could honestly be, and it means a hooked
monster blames the player, which is what you want.
*/
static void Grapple_Damage (edict_t *player, edict_t *targ, float damage)
{
	int	saved_self, saved_other;

	if (!grapple_damage || !player || !targ || targ->free)
		return;
	if (targ->v.takedamage == 0.f || damage <= 0.f)
		return;

	saved_self = pr_global_struct->self;
	saved_other = pr_global_struct->other;

	G_INT (OFS_PARM0) = EDICT_TO_PROG (targ);
	G_INT (OFS_PARM1) = EDICT_TO_PROG (player);
	G_INT (OFS_PARM2) = EDICT_TO_PROG (player);
	G_FLOAT (OFS_PARM3) = damage;

	pr_global_struct->self = EDICT_TO_PROG (targ);
	pr_global_struct->other = EDICT_TO_PROG (player);
	PR_ExecuteProgram (grapple_damage);

	pr_global_struct->self = saved_self;
	pr_global_struct->other = saved_other;
}

/*
Resolve the anchor to world space, and survive its entity dying.

A hooked monster can be gibbed, and a gib is a freed edict whose origin is
whatever the next spawn writes there. Reading it would move the rope's far end
to an unrelated place, or to garbage. So a freed anchor is converted, once, to
a static anchor at the last position it was actually seen in, and the swing
carries on from there -- the rope goes slack-ish and behaves, rather than the
player being snapped across the map or the engine reading a dead edict.

The residual risk is named rather than hidden: an edict number freed AND reused
inside one swing would move the anchor onto the new occupant. That is a rope
following the wrong thing for a few seconds, not a crash, and every cheaper
guard than a per-edict serial costs a field in a struct this module does not
own.
*/
static void Grapple_AnchorOrigin (vec3_t out)
{
	edict_t	*ed;

	if (qr_grapple_anchor_num <= 0)
	{
		VectorCopy (qr_grapple_anchor_ofs, out);
		return;
	}

	ed = EDICT_NUM (qr_grapple_anchor_num);
	if (!ed || ed->free)
	{
		/* Freeze it where it was last seen and stop asking. */
		VectorCopy (qr_grapple_tip, qr_grapple_anchor_ofs);
		qr_grapple_anchor_num = 0;
		VectorCopy (qr_grapple_anchor_ofs, out);
		return;
	}

	VectorAdd (ed->v.origin, qr_grapple_anchor_ofs, out);
}

/*
Throw the hook from the OFF hand, along the AIM.

Origin and direction come from different hands on purpose, and the v_angle
paragraph below is the one that governs: the off hand is where the rope leaves
from, the reticle is where it goes. What the off hand buys is the gun, which
stays drawn and keeps firing for the length of a swing while the rope comes
out of the other fist.

This header used to say direction came from the off hand too, which is what
the plan ordered and what shipped for eight commits before device evidence
overruled it. The sentence is called out rather than merely deleted because
anyone arriving here to give the rope its own aim will arrive at this comment
first, and a stale comment promising a ray that nothing reads is the exact
defect this file was audited for once already.

The fallback chain, for the ORIGIN only, is off hand, then gun hand, then the
body at eye height.
Each step is a real session: the off hand is missing whenever the bare-hands
fist is not tracked or the off controller drops, the gun hand is missing when
vr_handaim is off, and the body is what everything else in this engine degrades
to. A throw that did nothing instead would read on device as a hook that
sometimes just does not fire, which is a far worse bug than one that comes from
the wrong place.

Direction from v_angle, which is the AIM -- the reticle, the same ray the gun
fires along -- exactly as rogue's W_FireGrapple used it.

It is worth saying why this is not the off hand, because taking it from there
is the obvious symmetry and it was tried: a Sense controller held in a natural
grip points its forward axis roughly UP, so a rope aimed by the hand holding
it fired at the sky and could not be pointed at the floor at all. The hand
that holds the rope is not the hand that points it. Origin and direction come
from different places on purpose.

Speed is clamped for the same reason it always was: both ends of the cvar are a
real failure, and a clamp that stops a typo being a crash is worth more than a
clamp that expresses an opinion. sv_maxvelocity is deliberately NOT touched any
more. That write existed only because SV_CheckVelocity clamps an EDICT's
velocity per component, which bent the throw's direction as well as its speed
(a requested 3000 measured 2061, an aim pitch of -20 came out at -22.3). A hook
owned by this file never goes through SV_CheckVelocity, so the global physics
knob it used to reach into can be left alone.
*/
static void Grapple_Throw (edict_t *player)
{
	vec3_t	fwd, right, up;
	float	speed, range;

	if (!QR_OffHandOrigin (qr_grapple_tip)
	    && !QR_HandOrigin (qr_grapple_tip))
	{
		VectorCopy (player->v.origin, qr_grapple_tip);
		qr_grapple_tip[2] += player->v.view_ofs[2];
	}

	/* All three outputs are passed because AngleVectors writes all three
	   unconditionally (mathlib.c:198); a NULL there is a segfault, not an
	   opt-out. right and up are unused. */
	AngleVectors (player->v.v_angle, fwd, right, up);

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

	VectorScale (fwd, speed, qr_grapple_fly_vel);
	VectorAngles (qr_grapple_fly_vel, qr_grapple_head_angles);

	/* Range over speed is the time to allow, which is the same arithmetic
	   that used to go into the hook edict's nextthink, so vr_grapple_range
	   still means exactly what its comment block says it means. */
	qr_grapple_fly_ttl = range / speed;
	qr_grapple_anchor_num = 0;
	qr_grapple_state = GRAPPLE_FLYING;
}

/*
One tick of flight.

The WHOLE step is traced, start to end, which is why no frame length can
tunnel the hook through a wall however long the frame got -- and both QC_Frame
and Host_FilterTime permit 0.1 s, so frames do get long. That is the same
property SV_FlyMove gave the old hook edict for free, kept deliberately rather
than inherited.

MOVE_MISSILE, not MOVE_NORMAL: SV_PushEntity uses MOVE_MISSILE for a
MOVETYPE_FLYMISSILE entity, so this is the trace the rogue hook actually flew
with, and it is the type that clips against monsters, which is what makes a
hook you can stick in a shambler possible at all. A point hull matches the
hook's own zero-size bbox.
*/
static void Grapple_FlightFrame (edict_t *player, float dt)
{
	vec3_t	end;
	trace_t	tr;
	int	verdict;

	if (qr_grapple_state != GRAPPLE_FLYING || dt <= 0.f)
		return;

	VectorAngles (qr_grapple_fly_vel, qr_grapple_head_angles);
	VectorMA (qr_grapple_tip, dt, qr_grapple_fly_vel, end);
	tr = SV_Move (qr_grapple_tip, vec3_origin, vec3_origin, end,
		      MOVE_MISSILE, player);

	verdict = Grapple_AnchorFromTrace (&tr, SV_PointContents (tr.endpos));

	if (verdict < 0)
	{
		qr_grapple_state = GRAPPLE_IDLE;
		return;
	}

	VectorCopy (tr.endpos, qr_grapple_tip);

	if (verdict > 0)
	{
		/* Braces on both arms: VectorSubtract and VectorCopy are
		   brace macros, so an unbraced if/else orphans the else. */
		qr_grapple_anchor_num = tr.ent ? NUM_FOR_EDICT (tr.ent) : 0;
		if (qr_grapple_anchor_num > 0)
		{
			VectorSubtract (tr.endpos, tr.ent->v.origin,
					qr_grapple_anchor_ofs);
		}
		else
		{
			VectorCopy (tr.endpos, qr_grapple_anchor_ofs);
		}
		qr_grapple_state = GRAPPLE_ANCHORED;

		/* Once, here, on the bite. Not in the swing frame, which runs
		   every tick. */
		if (qr_grapple_anchor_num > 0)
			Grapple_Damage (player, tr.ent, vr_grapple_damage.value);
		return;
	}

	/* Still flying. The timer is what ends a throw that hits nothing, and
	   it is the only thing vr_grapple_range controls. */
	qr_grapple_fly_ttl -= dt;
	if (qr_grapple_fly_ttl <= 0.f)
		qr_grapple_state = GRAPPLE_IDLE;
}


/* Rogue measures the rope from roughly the chest, not from the origin. */
#define GRAPPLE_ROPE_UP		16.f
/* Pretension in the rope at the anchor, so the swing cannot start deadlocked
   exactly taut. See Grapple_TakeOver. */
#define GRAPPLE_SEED_SLACK	64.f
/* How far past its rest length the rope may ever be stretched. See the reel. */
#define GRAPPLE_MAX_STRETCH	256.f

/*
Measure the rope at the moment the hook bites, and start the swing.

This used to be three writes into rogue's progs state: clearing `on_hook` so
GrappleService stopped assigning velocity every frame, parking the hook edict's
think so GrappleTrack would not delete the hook a tenth of a second later, and
borrowing friction. The first two described a fight with code that no longer
runs. Only the friction borrow and the rope measurement were ever about the
swing itself, so only they are left.
*/
static void Grapple_TakeOver (edict_t *player)
{
	vec3_t	rope, anchor;
	float	rmin;

	Grapple_AnchorOrigin (anchor);
	VectorSubtract (anchor, player->v.origin, rope);
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

static void Grapple_SwingFrame (edict_t *player)
{
	vec3_t	rope, dir, anchor;
	float	dist, radial, pull, dt, rmin, reel, stiff, smax;
	float	haul, accel, want, amax, grav, ref, frac, lo;
	eval_t	*val;

	dt = (float) host_frametime;
	if (dt <= 0.f)
		return;

	/* EVERY frame, because this is what a swing was losing to the floor.
	   Measured with friction running: velocity exactly 0.0 for the first 8
	   frames of a swing and under 100 u/s for 25, against rails' 994 on
	   frame 0, because friction takes about 4.5 percent per frame and a
	   starting swing has less than that to give. */
	Grapple_HoldFriction ();

	/* The anchor, not a hook edict. This one line is the whole of what the
	   rewrite changed about the swing: everything below it is the shipped
	   pendulum, untouched, because the feel IS this code. */
	Grapple_AnchorOrigin (anchor);
	VectorSubtract (anchor, player->v.origin, rope);
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
	if (grapple_announce)
	{
		grapple_announce = false;
		Grapple_Announce ();
	}
	qr_grapple_engaged = true;
	Grapple_Throw (player);
}

/*
One tick of the hold.

Called from IN_Commands with this tick's pad snapshot. What is NOT here any
more is the whole reason this work was done: no weapon is written, no synthetic
attack is raised, and nothing is asked of the loaded progs. The player keeps
the gun they were holding for the entire engagement, which is what lets the
rope leave one hand while the other one keeps firing.
*/
void Grapple_Frame (uint32_t padbits, int wheel_open)
{
	edict_t		*player;
	qboolean	held, want, usable;
	eval_t		*tp;

	Grapple_ResolveProgs ();
	player = Grapple_Player ();
	held = (padbits & QC_PAD_RSHOULDER) != 0;

	/* A cancelled swing waits for a NEW press, never for the grip simply
	   still being down. */
	if (!held)
		qr_grapple_locked = false;

	/* DEATH IS A CANCEL, and it has to be said out loud now. The old
	   progs-driven version got this for free and by accident: dying runs
	   PutClientInServer, which rewrites .weapon, which tripped the
	   "something else took the weapon" branch and disengaged. That branch
	   is gone with the weapon write, and so was the protection -- a grip
	   held through death re-threw on the first frame of the new life, which
	   is the player being yanked by a hook they never threw. Caught by the
	   respawn assertion in gymtest, not by reading.

	   health rather than deadflag because it is the field that is already
	   zero on the frame the player dies, before the progs has run its own
	   death think, and a cancel owes the player promptness. */
	usable = player && vr_grapple.value != 0 && player->v.health > 0.f;

	if (!usable)
	{
		/* No player, dead, or the feature switched off: the button does
		   NOTHING. It used to pass through, on the principle that a
		   layer which claims a bit should not silently eat it. That was
		   measurably wrong: the bit's bind was +attack, and the Sense
		   hand that sets it is the one whose grip used to open the
		   weapon ring, so on the shipped vr_grapple 0 default a squeeze
		   fired the gun and 200 frames held burned seven shells. The
		   bind is gone now, but eating the bit is still the lesser
		   surprise. */
		if (qr_grapple_engaged)
			Grapple_Disengage ();
		/* And make it wait for a new press. Grapple_Player returns NULL
		   for the whole of a level load, so without this the first
		   spawned frame sees the grip still down and `want` true again:
		   measured, the hook was out by frame 2 and the player was
		   dragged across a level they had just arrived in, having
		   pressed nothing. A death and restart did the same. */
		if (held)
			qr_grapple_locked = true;
		return;
	}

	/* key_dest gates the PRESS, because a menu or the console owns the
	   input while it is up and a throw started from there is one the player
	   did not ask for. Gated on the transition only, so it cannot be
	   recovered by closing the menu later either. */
	want = held
	    && !qr_grapple_locked
	    && key_dest == key_game;

	/* THE RING OPENS AND THE ROPE HOLDS. `wheel_open` used to sit in the
	   expression above, which made opening the ring mid-swing a CANCEL:
	   A. hit that on device and ruled it the wrong way round. The gate read
	   that way at c42711a too, so this is not a regression in the C hook --
	   what changed is that the hook is now ours. The old cancel went
	   through rogue's progs and only reset the hook when its hook_out field
	   was set, and rogue's pull is not weapon gated, so a swing could
	   survive the ring by accident rather than by design.

	   HOLD, NOT SCALE, and the reason is the same one the sv.paused guard
	   below gives. The ring's time dilation eases host_frametime, every
	   number in the pendulum was tuned at full rate, and a spring impulse
	   on a slowed frame is the near neighbour of the measured pause
	   catapult. Bullet-time swinging was considered and rejected as a
	   separate tuning problem; it was not missed. */
	if (wheel_open)
	{
		/* A press made while the ring is up is the player choosing a
		   weapon, not throwing a hook. Locked so it cannot fire the
		   instant the ring closes, which is the rule every other edge
		   the player did not ask for already gets. */
		if (held && !qr_grapple_engaged)
			qr_grapple_locked = true;

		/* Returning here is the whole hold: the anchor, the rope's rest
		   length and the player's velocity are all left exactly as they
		   were, and no throw, flight step or swing step runs. A release
		   made while the ring is up lets go on the frame it closes,
		   where `want` is false and the branch below sees it. */
		return;
	}

	if (want && !qr_grapple_engaged)
	{
		Grapple_Engage (player);
	}
	else if (!want && qr_grapple_engaged)
	{
		/* Ending a swing the player did not end: make them re-press. */
		if (held)
			qr_grapple_locked = true;
		Grapple_Disengage ();
	}

	if (!qr_grapple_engaged)
		return;

	/* Rogue's own teleport release lived inside the on_hook branch that
	   this module took out of circuit, so the release has to happen here or
	   a teleport leaves the player on the rope. Read by name rather than
	   cached, because it is optional: a progs without the field just does
	   not get the release. Locked like every other cancel the player did
	   not ask for, so a held grip does not re-throw into the teleporter
	   three times on the way through. */
	tp = GetEdictFieldValue (player, "teleport_time");
	if (tp && tp->_float > sv.time)
	{
		if (held)
			qr_grapple_locked = true;
		Grapple_Disengage ();
		return;
	}

	/* PAUSED IS NOT A SMALL CASE, and it is wider than it was. IN_Commands
	   keeps running while SV_Physics does not, so a paused frame would both
	   advance the flight trace and add a spring impulse that nothing
	   integrates away and nothing clamps, on a frozen sv.time. Measured
	   before this guard existed: 2 seconds of pause took the player from
	   393 to 7036 units/s, and unpausing fired them across the room at the
	   velocity ceiling. It scales with pause length, so a backgrounded app
	   was a catapult. */
	if (sv.paused)
		return;

	switch (qr_grapple_state)
	{
	case GRAPPLE_FLYING:
		Grapple_FlightFrame (player, (float) host_frametime);
		/* A bite this frame measures its rope this frame, so the first
		   swing frame already has a rest length to work from. */
		if (qr_grapple_state == GRAPPLE_ANCHORED)
			Grapple_TakeOver (player);
		break;

	case GRAPPLE_ANCHORED:
		Grapple_SwingFrame (player);
		break;

	case GRAPPLE_IDLE:
		/* THE CHAINED-SWING RHYTHM, and it has to be written out now.
		   It used to happen by itself: rogue's W_FireGrapple re-fired
		   on its own while attack stayed held, so a miss or a timeout
		   under a still-held grip threw again with nothing in this file
		   asking for it. With the progs path gone that behaviour would
		   have disappeared silently, and it is part of how the weapon
		   feels to use -- you hold the grip and keep throwing until
		   something catches. */
		Grapple_Throw (player);
		break;
	}
}

/*
Where the hook is, for the renderer.

The anchored case must resolve the anchor rather than hand back the latch
position, or a rope tied to a rising platform would stay pinned to where that
platform used to be. Grapple_AnchorOrigin is also what notices a freed anchor
entity, so asking it here keeps that one piece of bookkeeping in one place.
*/
int QR_GrappleState (float tip[3])
{
	if (tip && qr_grapple_state == GRAPPLE_ANCHORED)
		Grapple_AnchorOrigin (tip);
	else if (tip && qr_grapple_state == GRAPPLE_FLYING)
		VectorCopy (qr_grapple_tip, tip);
	return (int) qr_grapple_state;
}

/*
 * The head's drawn pose, for the renderer bridge to hang an alias model on.
 *
 * Returns 1 when there is a head to draw, 0 when the hook is idle. The frame
 * numbers are rogue's own: W_FireGrapple sets .frame 1 for the flight and
 * GrappleAnchor sets 2 once it is stuck, so hook.mdl visibly changes pose on
 * the bite. hook01 is never selected by rogue either.
 */
int QR_GrappleHeadPose (float origin[3], float angles[3], int *frame)
{
	if (qr_grapple_state == GRAPPLE_IDLE)
		return 0;

	if (origin)
	{
		if (qr_grapple_state == GRAPPLE_ANCHORED)
			Grapple_AnchorOrigin (origin);
		else
			VectorCopy (qr_grapple_tip, origin);
	}
	if (angles)
		VectorCopy (qr_grapple_head_angles, angles);
	if (frame)
		*frame = (qr_grapple_state == GRAPPLE_ANCHORED) ? 2 : 1;
	return 1;
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
	Cbuf_AddText ("vr_grapple_stiff 30\n");
	Cbuf_AddText ("vr_grapple_reel 3200\n");
	Cbuf_AddText ("vr_grapple_ropemin 64\n");
	Cbuf_AddText ("vr_grapple_haul 3200\n");
	Cbuf_AddText ("vr_grapple_accel 1500\n");
	Cbuf_AddText ("vr_grapple_accelref 1536\n");
	Cbuf_AddText ("vr_grapple_accelmin 0.2\n");
	Cbuf_AddText ("vr_grapple_damage 10\n");
}

/*
==============================================================================

	THE HOOK'S OWN ASSETS

	The head model and the throw sound ship only with Dissolution of
	Eternity. They cannot be reached from id1 by any amount of care with
	the search path, because COM_Game_f does not merely outrank a mission
	pack when you switch away from it -- it CLOSES the pak's handle and
	frees its directory (common.c:2347-2359), so by the time you are in
	vanilla those bytes are off the list entirely.

	So the player's own two files are copied into id1 once, at startup,
	where id1's directory element sits on the search path in every gamedir.
	Nothing ships: a player who does not own the pack gets the fallback and
	the three sounds the hook borrows from id1, which is most of it.

	This parses a file format that arrives from the player's disk, so the
	refusals matter more than the success. A pak directory is 64 bytes per
	entry claiming an offset and a length, and nothing but this code stops
	a corrupt or hostile one from naming a range outside the file.

==============================================================================
*/

/* Big enough that the two real files move in a handful of passes, small
   enough to sit in the platform's BSS without thought. Deliberately not a
   Z_Malloc: this runs inside Grapple_Init, before the game has a heap worth
   fragmenting, and a fixed buffer cannot fail. */
static byte	grapple_copybuf[64 * 1024];

static int Grapple_LE32 (const byte *p)
{
	/* The pak format is little-endian on every platform that has ever
	   written one, so this does not go through the engine's LittleLong
	   function pointer -- which is not yet installed when a host test
	   calls straight in here. */
	return (int) ((unsigned int) p[0]
		      | ((unsigned int) p[1] << 8)
		      | ((unsigned int) p[2] << 16)
		      | ((unsigned int) p[3] << 24));
}

/*
 * mkdir every prefix of `path`'s directory part. Sys_mkdir is a plain
 * mkdir that forgives EEXIST, so the levels have to be walked by hand.
 */
static void Grapple_MkdirP (const char *path)
{
	char	work[MAX_OSPATH];
	char	*s;

	if (q_strlcpy (work, path, sizeof (work)) >= sizeof (work))
		return;

	/* Walk forward, truncating at each separator in turn. Skips a leading
	   slash so an absolute path does not try to mkdir "". */
	for (s = work + 1; *s; s++)
	{
		if (*s != '/')
			continue;
		*s = 0;
		Sys_mkdir (work);
		*s = '/';
	}
	/* The last component is the file itself, so nothing after the loop. */
}

static long Grapple_FileLength (const char *path)
{
	FILE	*f = fopen (path, "rb");
	long	len;

	if (!f)
		return -1;
	if (fseek (f, 0, SEEK_END) != 0)
	{
		fclose (f);
		return -1;
	}
	len = ftell (f);
	fclose (f);
	return len;
}

/*
 * Copy one archived file out of `pakpath` to `outpath`.
 *
 *   1  extracted
 *   0  already there at the right size, nothing written
 *  -1  the pak is missing, is not a pak, or the entry's claimed range does
 *      not fit inside it
 *  -2  the pak is fine and has no such entry
 *  -3  the destination could not be written (and no partial file is left)
 */
static int Grapple_PakExtract (const char *pakpath, const char *inpak,
			       const char *outpath)
{
	byte	hdr[12];
	byte	ent[64];
	FILE	*in, *out;
	long	paklen;
	int	dirofs, dirlen, count, i;
	int	filepos = 0, filelen = 0;
	int	found = 0;
	int	remaining;

	paklen = Grapple_FileLength (pakpath);
	if (paklen < (long) sizeof (hdr))
		return -1;

	in = fopen (pakpath, "rb");
	if (!in)
		return -1;

	if (fread (hdr, 1, sizeof (hdr), in) != sizeof (hdr)
	    || memcmp (hdr, "PACK", 4) != 0)
	{
		fclose (in);
		return -1;
	}

	dirofs = Grapple_LE32 (hdr + 4);
	dirlen = Grapple_LE32 (hdr + 8);

	/* The directory itself has to fit, and has to be a whole number of
	   entries. Checked before the offset arithmetic below so a negative
	   dirlen cannot become a huge count. */
	if (dirofs < 0 || dirlen < 0 || (dirlen % 64) != 0
	    || (long) dirofs + (long) dirlen > paklen)
	{
		fclose (in);
		return -1;
	}

	count = dirlen / 64;
	if (fseek (in, dirofs, SEEK_SET) != 0)
	{
		fclose (in);
		return -1;
	}

	for (i = 0; i < count; i++)
	{
		char	name[57];

		if (fread (ent, 1, sizeof (ent), in) != sizeof (ent))
		{
			fclose (in);
			return -1;
		}
		memcpy (name, ent, 56);
		name[56] = 0;
		/* Case-insensitive on purpose. COM_FindFile is exact because it
		   must match what a map precached; this is our own lookup for
		   two known names, and a pack written on a case-preserving
		   filesystem is the player's problem to not have. */
		if (q_strcasecmp (name, inpak) != 0)
			continue;
		filepos = Grapple_LE32 (ent + 56);
		filelen = Grapple_LE32 (ent + 60);
		found = 1;
		break;
	}

	if (!found)
	{
		fclose (in);
		return -2;
	}

	/* The entry is in the directory. Whether it is in the FILE is a
	   separate question, and the only one that can hurt us. */
	if (filepos < 0 || filelen < 0
	    || (long) filepos + (long) filelen > paklen)
	{
		fclose (in);
		return -1;
	}

	if (Grapple_FileLength (outpath) == (long) filelen)
	{
		fclose (in);
		return 0;		/* already seeded */
	}

	if (fseek (in, filepos, SEEK_SET) != 0)
	{
		fclose (in);
		return -1;
	}

	Grapple_MkdirP (outpath);
	out = fopen (outpath, "wb");
	if (!out)
	{
		fclose (in);
		return -3;
	}

	remaining = filelen;
	while (remaining > 0)
	{
		int	chunk = remaining;
		size_t	got;

		if (chunk > (int) sizeof (grapple_copybuf))
			chunk = (int) sizeof (grapple_copybuf);
		got = fread (grapple_copybuf, 1, (size_t) chunk, in);
		if (got != (size_t) chunk
		    || fwrite (grapple_copybuf, 1, got, out) != got)
		{
			fclose (out);
			fclose (in);
			remove (outpath);	/* never leave a partial */
			return -3;
		}
		remaining -= chunk;
	}

	fclose (out);
	fclose (in);
	return 1;
}

/* What the hook wants, and where it has to land to be reachable from every
   gamedir. The in-pak path and the id1 path are the same string because
   nothing is being renamed: hook.mdl stays hook.mdl, so a player who later
   installs the pack properly sees one file, not two. */
static const char * const grapple_assets[] = {
	"progs/hook.mdl",
	"sound/weapons/chain1.wav"
};

/*
 * Lift the hook's assets out of the player's own mission pack, once.
 *
 * Silent when the pack is not installed, which is the common case and not an
 * error: QR_GrappleHeadModel falls back and the throw simply has no sound.
 */
static void Grapple_SeedAssets (void)
{
	const char	*roots[2];
	int		nroots = 1;
	size_t		i;
	int		r;

	/* NOT every caller of Grapple_Init has booted the engine. The host unit
	   drivers register cvars and then poke one subsystem, so com_basedir
	   can be empty and host_parms can be NULL -- and the first version of
	   this dereferenced host_parms unconditionally and turned
	   turn_pivot_test from a documented FAIL into a SIGSEGV, which the
	   gate read as the failure having been fixed. There is nothing to seed
	   without a basedir anyway. */
	if (!com_basedir[0])
		return;

	roots[0] = com_basedir;
	/* On a platform where the two differ, a pack dropped in through the
	   Files app can be under either, exactly as COM_AddGameDirectory
	   treats them (common.c:2263-2269). */
	if (host_parms && host_parms->userdir && *host_parms->userdir
	    && strcmp (host_parms->userdir, com_basedir) != 0)
		roots[nroots++] = host_parms->userdir;

	for (i = 0; i < sizeof (grapple_assets) / sizeof (grapple_assets[0]); i++)
	{
		char	dst[MAX_OSPATH];
		int	root;

		q_snprintf (dst, sizeof (dst), "%s/%s/%s",
			    com_basedir, GAMENAME, grapple_assets[i]);

		for (root = 0; root < nroots; root++)
		{
			char	pak[MAX_OSPATH];

			q_snprintf (pak, sizeof (pak), "%s/rogue/pak0.pak",
				    roots[root]);
			r = Grapple_PakExtract (pak, grapple_assets[i], dst);
			if (r == 1)
			{
				Con_Printf ("[grapple] seeded %s from rogue\n",
					    grapple_assets[i]);
				break;
			}
			if (r == 0)
				break;		/* already there */
			if (r == -3)
			{
				Con_Printf ("[grapple] could not write %s\n", dst);
				break;
			}
			/* -1 and -2 fall through to the next root, then out:
			   not owning the pack is the normal case. */
		}
	}
}

void Grapple_Init (void)
{
	Cvar_RegisterVariable (&vr_grapple);
	Cvar_RegisterVariable (&vr_grapple_speed);
	Cvar_RegisterVariable (&vr_grapple_range);
	Cvar_RegisterVariable (&vr_grapple_stiff);
	Cvar_RegisterVariable (&vr_grapple_reel);
	Cvar_RegisterVariable (&vr_grapple_ropemin);
	Cvar_RegisterVariable (&vr_grapple_haul);
	Cvar_RegisterVariable (&vr_grapple_accel);
	Cvar_RegisterVariable (&vr_grapple_accelref);
	Cvar_RegisterVariable (&vr_grapple_accelmin);
	Cvar_RegisterVariable (&vr_grapple_damage);
	Cvar_RegisterVariable (&vr_grapple_headmodel);
	Grapple_ForceDefaults ();
	/* After COM_InitFilesystem (host.c:66) and before S_Init
	   (host.c:100), which is why this copies files and precaches
	   nothing: there is no sound system yet to precache into. */
	Grapple_SeedAssets ();
}

#ifdef QAVP_HOSTCHECK
/* The host drivers' way in, on the QR_TestCachePic* pattern: the real
   functions stay static and the tests get wrappers rather than the qualifier
   moving. gymtest drives the throw and the flight directly because
   Grapple_Frame does not own them until Task 2. */
int Grapple_TestAnchorFromTrace (const trace_t *tr, int contents)
{
	return Grapple_AnchorFromTrace (tr, contents);
}

int Grapple_TestDamageState (int parms)
{
	return (int) Grapple_DamageState (parms);
}

int Grapple_TestState (float tip[3])
{
	if (tip)
	{
		if (qr_grapple_state == GRAPPLE_ANCHORED)
		{
			Grapple_AnchorOrigin (tip);
		}
		else
		{
			VectorCopy (qr_grapple_tip, tip);
		}
	}
	return (int) qr_grapple_state;
}

void Grapple_TestThrow (void)
{
	edict_t	*player = Grapple_Player ();

	if (player)
		Grapple_Throw (player);
}

void Grapple_TestFlight (float dt)
{
	edict_t	*player = Grapple_Player ();

	if (player)
		Grapple_FlightFrame (player, dt);
}

/* Hang an anchor with a chosen rest length, so the pendulum's numbers can be
   measured against a known rope instead of whatever a throw happened to find. */
void Grapple_TestSetAnchor (const float anchor[3], float rope_len)
{
	VectorCopy (anchor, qr_grapple_anchor_ofs);
	VectorCopy (anchor, qr_grapple_tip);
	qr_grapple_anchor_num = 0;
	qr_grapple_rope = rope_len;
	qr_grapple_state = GRAPPLE_ANCHORED;
	qr_grapple_swinging = true;
}

void Grapple_TestSetAnchorEnt (int entnum, const float ofs[3])
{
	VectorCopy (ofs, qr_grapple_anchor_ofs);
	qr_grapple_anchor_num = entnum;
	qr_grapple_state = GRAPPLE_ANCHORED;
	qr_grapple_swinging = true;
	Grapple_AnchorOrigin (qr_grapple_tip);
	qr_grapple_rope = 256.f;
}

int Grapple_TestAnchorNum (void)
{
	return qr_grapple_anchor_num;
}

void Grapple_TestSwing (void)
{
	edict_t	*player = Grapple_Player ();

	if (player)
		Grapple_SwingFrame (player);
}
int Grapple_TestPakExtract (const char *pakpath, const char *inpak,
			    const char *outpath)
{
	return Grapple_PakExtract (pakpath, inpak, outpath);
}
/* Put the hook away without going through a grip release: Grapple_Frame is
   inert while nothing engaged it, so a driver that threw directly has no
   other way back to idle. */
void Grapple_TestDisengage (void)
{
	Grapple_Disengage ();
}
/* The rope's rest length, so a test can prove the ring froze it rather than
   merely that the hook survived. */
float Grapple_TestRope (void)
{
	return qr_grapple_rope;
}
#endif	/* QAVP_HOSTCHECK */
