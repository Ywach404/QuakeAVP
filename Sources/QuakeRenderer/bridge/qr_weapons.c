/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * qr_weapons.c -- 17 weapon identities, and one bit map per game.
 *
 * Every bit below was read out of the game's own compiled progs.dat, not out
 * of the engine's IT_/HIT_/RIT_ defines. The defines say what upstream
 * expects; the progs say what a game ships, and where they disagree the progs
 * win. This matters more than it looks because a wrong bit does not error: it
 * silently draws the wrong gun under the wrong label, and a wrong model name
 * silently drops a weapon out of the ring.
 *
 * The games covered are id1, dopa, mg1, mg3, hipnotic and rogue. ctf is out
 * of scope by A.'s decision; the name list below is where its row would go.
 */

#include "quakedef.h"
#include "QuakeCore.h"
#include "qr_weapons.h"

/* ========================================================================
 * The identity table
 * ====================================================================== */

/* An identity owns a LIST of acceptable view models, not one name, because a
   game may dress the same weapon differently: mg3 swaps v_shot.mdl for
   v_bloodshot.mdl under its bloody-nightmare mode and also ships
   v_hammer_glow.mdl. Those are the same weapons wearing another model, so
   they alias to one identity and keep A.'s tuning. Separate identities would
   split that tuning in half. */
static const char *const qr_models_axe[]	= { "progs/v_axe.mdl", NULL };
static const char *const qr_models_shot[]	= { "progs/v_shot.mdl", "progs/v_bloodshot.mdl", NULL };
static const char *const qr_models_shot2[]	= { "progs/v_shot2.mdl", "progs/v_bloodshot2.mdl", NULL };
static const char *const qr_models_nail[]	= { "progs/v_nail.mdl", NULL };
static const char *const qr_models_nail2[]	= { "progs/v_nail2.mdl", NULL };
static const char *const qr_models_rock[]	= { "progs/v_rock.mdl", NULL };
static const char *const qr_models_rock2[]	= { "progs/v_rock2.mdl", NULL };
static const char *const qr_models_light[]	= { "progs/v_light.mdl", NULL };
static const char *const qr_models_laserg[]	= { "progs/v_laserg.mdl", NULL };
static const char *const qr_models_hammer[]	= { "progs/v_hammer.mdl", "progs/v_hammer_glow.mdl", NULL };
static const char *const qr_models_prox[]	= { "progs/v_prox.mdl", NULL };
static const char *const qr_models_lava[]	= { "progs/v_lava.mdl", NULL };
static const char *const qr_models_lava2[]	= { "progs/v_lava2.mdl", NULL };
static const char *const qr_models_multi[]	= { "progs/v_multi.mdl", NULL };
static const char *const qr_models_multi2[]	= { "progs/v_multi2.mdl", NULL };
static const char *const qr_models_plasma[]	= { "progs/v_plasma.mdl", NULL };
static const char *const qr_models_grpple[]	= { "progs/v_grpple.mdl", NULL };

typedef struct {
	const char		*label;
	const char *const	*view_models;
	const char		*pickup_model;	/* NULL where the game ships none */
	int			rear_clip;
	float			ring_roll;	/* degrees, about the model's own
						   forward axis, on the wheel only */
} qr_weapon_info_t;

/* Indexed by qc_weapon_identity_t, so the order here is the ABI's order and
   not a preference.

   The first eight labels are byte-identical to the strings the wheel shipped
   with, so nothing on screen changes for vanilla.

   rear_clip trims a view model's rear vertices, which is only ever wanted for
   a model that bakes a loaded round into its mesh. The axe and the thunderbolt
   load nothing and their rear IS real geometry, so they are 0 -- that
   preserves exactly what the old raw-index test (i != 0 && i != 7) did.

   The nine the packs add DO bake a round, confirmed on device 2026-11-05: with
   the clip off they each hang a bright projectile quad in the air beside the
   gun. So the flag is 1 for all of them. What is wrong is not whether to trim
   but HOW MUCH: vanilla's vr_wheelclip keeps 0.79, and at that depth rogue's
   models lose their grips, triggers and handles along with the projectile.
   The packs therefore clip on their own fraction, vr_wheelclippack, which is
   tuned to take the round and leave the handle.

   Vanilla hides all of this because the ring draws clean g_ pickup models for
   six of its eight weapons, and those are never clipped at all. Rogue ships no
   pickup models, so every weapon it owns goes through this path.

   ring_roll exists because a view model is authored to sit in a hand, not to
   hang on a ring, and nothing makes the packs agree with id1 about which way
   is up. The Mjolnir came out inverted on device, so it carries 180. The
   vanilla eight are 0 and must stay 0: they looked right before this field
   existed. This is the wheel only; the held weapon is placed by its own
   table. Confirmed by eye, not measured, so a model that still reads wrong
   is a number to change here and nothing more. */
static const qr_weapon_info_t qr_weapons[QC_WEAPON_IDENTITIES] = {
	{ "AXE",		qr_models_axe,	  NULL,			0,   0.f },
	{ "SHOTGUN",		qr_models_shot,	  NULL,			1,   0.f },
	{ "SUPER SHOTGUN",	qr_models_shot2,  "progs/g_shot.mdl",	1,   0.f },
	{ "NAILGUN",		qr_models_nail,	  "progs/g_nail.mdl",	1,   0.f },
	{ "SUPER NAILGUN",	qr_models_nail2,  "progs/g_nail2.mdl",	1,   0.f },
	{ "GRENADE LAUNCHER",	qr_models_rock,	  "progs/g_rock.mdl",	1,   0.f },
	{ "ROCKET LAUNCHER",	qr_models_rock2,  "progs/g_rock2.mdl",	1,   0.f },
	{ "THUNDERBOLT",	qr_models_light,  "progs/g_light.mdl",	0,   0.f },
	{ "LASER CANNON",	qr_models_laserg, "progs/g_laserg.mdl",	1,   0.f },
	{ "MJOLNIR",		qr_models_hammer, "progs/g_hammer.mdl",	1, 180.f },
	{ "PROXIMITY GUN",	qr_models_prox,	  "progs/g_prox.mdl",	1,   0.f },
	/* Rogue ships no g_* weapon models at all, so its six fall back to
	   their view models. */
	{ "LAVA NAILGUN",	qr_models_lava,	  NULL,			1,   0.f },
	{ "LAVA SUPER NAILGUN",	qr_models_lava2,  NULL,			1,   0.f },
	{ "MULTI GRENADE",	qr_models_multi,  NULL,			1,   0.f },
	{ "MULTI ROCKET",	qr_models_multi2, NULL,			1,   0.f },
	{ "PLASMA GUN",		qr_models_plasma, NULL,			1,   0.f },
	{ "GRAPPLE",		qr_models_grpple, NULL,			1,   0.f },
};

/* The consumer's bridging turns a NULL into a crash rather than a blank
   label, so an out-of-range identity yields the placeholder the bridge's
   weapon-name diagnostic already prints. */
static const char *qr_weapon_unknown = "(none)";

const char *QR_WeaponLabel (int identity)
{
	if (identity < 0 || identity >= QC_WEAPON_IDENTITIES)
		return qr_weapon_unknown;
	return qr_weapons[identity].label;
}

/* The ABI spelling of the same table. Declared in QuakeCore.h and defined
   here rather than beside the setter in in_null.c, because a second label
   table is a second thing to drift. */
const char *QC_WeaponLabel (int identity)
{
	return QR_WeaponLabel (identity);
}

const char *const *QR_WeaponViewModels (int identity)
{
	static const char *const none[] = { NULL };

	if (identity < 0 || identity >= QC_WEAPON_IDENTITIES)
		return none;
	return qr_weapons[identity].view_models;
}

const char *QR_WeaponPickupModel (int identity)
{
	if (identity < 0 || identity >= QC_WEAPON_IDENTITIES)
		return NULL;
	return qr_weapons[identity].pickup_model;
}

int QR_WeaponRearClip (int identity)
{
	if (identity < 0 || identity >= QC_WEAPON_IDENTITIES)
		return 0;
	return qr_weapons[identity].rear_clip;
}

float QR_WeaponRingRoll (int identity)
{
	if (identity < 0 || identity >= QC_WEAPON_IDENTITIES)
		return 0.f;
	return qr_weapons[identity].ring_roll;
}

/* ========================================================================
 * The per-game bit maps
 * ====================================================================== */

/* The vanilla eight carry impulses 1 through 8 as direct selections. Those
   eight numbers are the only measured ones in this file: they are what the
   shipped wheel's `impulse slot + 1` already sends, so they are established
   by behaviour rather than assumed. They are the same in every row.

   Rogue's row is also measured end to end, on device 2026-11-05: its axe
   keeps impulse 1 despite moving to its own bit, and all five powered-up
   weapons are TOGGLES sharing their base gun's number rather than having one
   of their own. That shape is why this table stores a kind beside the number:
   an integer alone would have been the wrong model, not merely a blank one.

   Hipnotic's three and mg3's two are still 0, meaning UNMEASURED, awaiting a
   headset. Where the impulse is 0 the kind carries no claim either: it is the
   zero value because the struct needs one, and a weapon whose impulse is
   unmeasured has an unmeasured kind by definition. Read the pair together. */
static const qr_weapon_entry_t qr_row_vanilla[] = {
	{ 1u<<12, QC_WEAPON_AXE,		1, QR_SELECT_DIRECT },
	{ 1u<<0,  QC_WEAPON_SHOTGUN,		2, QR_SELECT_DIRECT },
	{ 1u<<1,  QC_WEAPON_SUPER_SHOTGUN,	3, QR_SELECT_DIRECT },
	{ 1u<<2,  QC_WEAPON_NAILGUN,		4, QR_SELECT_DIRECT },
	{ 1u<<3,  QC_WEAPON_SUPER_NAILGUN,	5, QR_SELECT_DIRECT },
	{ 1u<<4,  QC_WEAPON_GRENADE_LAUNCHER,	6, QR_SELECT_DIRECT },
	{ 1u<<5,  QC_WEAPON_ROCKET_LAUNCHER,	7, QR_SELECT_DIRECT },
	{ 1u<<6,  QC_WEAPON_THUNDERBOLT,	8, QR_SELECT_DIRECT },
	{ 0, 0, 0, 0 }
};

/* mg3 is a standard_quake game with a non-vanilla arsenal, which is the whole
   reason the selector needs the game directory and not just the engine's
   flags. Its Mjolnir sits on 1<<7, which is IT_SUPER_LIGHTNING in vanilla:
   select on the flags alone and vanilla grows a phantom Mjolnir. It has no
   proximity gun. */
static const qr_weapon_entry_t qr_row_mg3[] = {
	{ 1u<<12, QC_WEAPON_AXE,		1, QR_SELECT_DIRECT },
	{ 1u<<0,  QC_WEAPON_SHOTGUN,		2, QR_SELECT_DIRECT },
	{ 1u<<1,  QC_WEAPON_SUPER_SHOTGUN,	3, QR_SELECT_DIRECT },
	{ 1u<<2,  QC_WEAPON_NAILGUN,		4, QR_SELECT_DIRECT },
	{ 1u<<3,  QC_WEAPON_SUPER_NAILGUN,	5, QR_SELECT_DIRECT },
	{ 1u<<4,  QC_WEAPON_GRENADE_LAUNCHER,	6, QR_SELECT_DIRECT },
	{ 1u<<5,  QC_WEAPON_ROCKET_LAUNCHER,	7, QR_SELECT_DIRECT },
	{ 1u<<6,  QC_WEAPON_THUNDERBOLT,	8, QR_SELECT_DIRECT },
	/* Same inference as hipnotic's row above, same safety net. */
	{ 1u<<7,  QC_WEAPON_MJOLNIR,		1, QR_SELECT_TOGGLE },
	{ 1u<<23, QC_WEAPON_LASER_CANNON,	8, QR_SELECT_TOGGLE },
	{ 0, 0, 0, 0 }
};

/* Also covers Quoth, which both COM_InitArgv and COM_Game_f fold into
   hipnotic. */
static const qr_weapon_entry_t qr_row_hipnotic[] = {
	{ 1u<<12, QC_WEAPON_AXE,		1, QR_SELECT_DIRECT },
	{ 1u<<0,  QC_WEAPON_SHOTGUN,		2, QR_SELECT_DIRECT },
	{ 1u<<1,  QC_WEAPON_SUPER_SHOTGUN,	3, QR_SELECT_DIRECT },
	{ 1u<<2,  QC_WEAPON_NAILGUN,		4, QR_SELECT_DIRECT },
	{ 1u<<3,  QC_WEAPON_SUPER_NAILGUN,	5, QR_SELECT_DIRECT },
	{ 1u<<4,  QC_WEAPON_GRENADE_LAUNCHER,	6, QR_SELECT_DIRECT },
	{ 1u<<5,  QC_WEAPON_ROCKET_LAUNCHER,	7, QR_SELECT_DIRECT },
	{ 1u<<6,  QC_WEAPON_THUNDERBOLT,	8, QR_SELECT_DIRECT },
	/* INFERRED from rogue's measured shape, not yet seen here. Rogue's extra
	   weapons proved to share their base gun's impulse and toggle with it,
	   and the same pairing argument applies: the Mjolnir is the other melee
	   weapon, the proximity gun is a grenade launcher variant whose HUD cell
	   upstream literally shares with the GL, and the laser cannon is a cells
	   weapon like the thunderbolt.

	   Safe to infer for the same reason it was in rogue: the toggle commit
	   stops on the DRAWN MODEL matching, so a wrong pairing cannot hand over
	   the wrong gun. It prints "could not reach it" and the number changes
	   here. Confirm each by holding the base weapon and pressing its number
	   again. */
	{ 1u<<7,  QC_WEAPON_MJOLNIR,		1, QR_SELECT_TOGGLE },
	{ 1u<<16, QC_WEAPON_PROXIMITY_GUN,	6, QR_SELECT_TOGGLE },
	{ 1u<<23, QC_WEAPON_LASER_CANNON,	8, QR_SELECT_TOGGLE },
	{ 0, 0, 0, 0 }
};

/* Rogue is NOT the vanilla eight plus extras: it RENUMBERS. Its axe is 1<<11
   and 1<<12, vanilla's axe bit, is its lava nailgun. That single collision is
   the bug this table exists to fix, so read the first and the ninth entries
   together before changing either.
   Rogue's axe keeps impulse 0: it sits on a different bit from vanilla's, and
   nothing shipped has ever established that impulse 1 still reaches it. One
   to confirm, not one to commit.
   The row STOPS at 1<<16, and the missing bit-23 entry is deliberate, not an
   omission to helpfully fill in. Rogue's progs do define a grapple there and
   it does ship progs/v_grpple.mdl, but sv_main.c:883 ORs items2 << 23 into the
   published items word for any progs defining an items2 field, and rogue is
   that game: bit 23 arrives as items2 bit 0, which upstream's own statusbar
   reads as green armour. The grapple and green armour alias onto one published
   bit and cannot be told apart, so putting the grapple on the ring would grow
   a phantom weapon every time the player picks up armour. The grapple keeps an
   identity so it can be drawn and tuned when held; it has no ownership bit. */
static const qr_weapon_entry_t qr_row_rogue[] = {
	/* Measured on device 2026-11-05: impulse 1 still selects the axe here,
	   even though rogue moved its bit from 1<<12 to 1<<11. Worth having
	   waited for: the old wheel sent ring index plus one and got this right
	   by luck, which is not a reason to write a number down. */
	{ 1u<<11, QC_WEAPON_AXE,		1, QR_SELECT_DIRECT },
	{ 1u<<0,  QC_WEAPON_SHOTGUN,		2, QR_SELECT_DIRECT },
	{ 1u<<1,  QC_WEAPON_SUPER_SHOTGUN,	3, QR_SELECT_DIRECT },
	{ 1u<<2,  QC_WEAPON_NAILGUN,		4, QR_SELECT_DIRECT },
	{ 1u<<3,  QC_WEAPON_SUPER_NAILGUN,	5, QR_SELECT_DIRECT },
	{ 1u<<4,  QC_WEAPON_GRENADE_LAUNCHER,	6, QR_SELECT_DIRECT },
	{ 1u<<5,  QC_WEAPON_ROCKET_LAUNCHER,	7, QR_SELECT_DIRECT },
	{ 1u<<6,  QC_WEAPON_THUNDERBOLT,	8, QR_SELECT_DIRECT },
	/* Each powered-up weapon is the ammo-upgraded form of exactly one base
	   gun and shares that gun's impulse, swapping with it rather than
	   having a number of its own.

	   All four were inferred from the plasma gun's measurement and then
	   CONFIRMED on device 2026-11-05 by selecting each off the ring: the
	   toggle commit drove every one and arrived. Rogue's row carries no
	   guesses.

	   The reason inferring was tolerable here and would not have been in the
	   bit columns: the toggle commit is self-verifying. It re-sends the
	   impulse and stops only when the drawn model matches the weapon asked
	   for, bounded by the owned count, so a wrong pairing cannot hand the
	   player the wrong gun. It fails to arrive and says so. A wrong BIT has
	   no such backstop, which is why those were measured first. */
	{ 1u<<12, QC_WEAPON_LAVA_NAILGUN,	4, QR_SELECT_TOGGLE },	/* confirmed */
	{ 1u<<13, QC_WEAPON_LAVA_SUPER_NAILGUN,	5, QR_SELECT_TOGGLE },	/* confirmed */
	{ 1u<<14, QC_WEAPON_MULTI_GRENADE,	6, QR_SELECT_TOGGLE },	/* confirmed */
	{ 1u<<15, QC_WEAPON_MULTI_ROCKET,	7, QR_SELECT_TOGGLE },	/* confirmed */
	/* Measured 2026-11-05: holding the thunderbolt and sending 8 again gives
	   the plasma gun. Rogue's powered-up weapons have no impulse of their
	   own, they share the base weapon's and swap with it, which is why the
	   kind column exists at all. The other four pairings are the same ammo
	   relationship and almost certainly behave the same way, but almost
	   certainly is what this table refuses to record, so they stay at 0
	   until each is seen. */
	{ 1u<<16, QC_WEAPON_PLASMA_GUN,		8, QR_SELECT_TOGGLE },
	{ 0, 0, 0, 0 }
};

/* Only the standard_quake games need naming: a bare `game rogue` or `game
   hipnotic` does set the engine's flags through QuakeSpasm's -missionpack
   extension. The list is a property of the shipped games rather than
   configuration, which is why it lives here beside the rows. */
typedef struct {
	const char			*dir;
	const qr_weapon_entry_t		*row;
	const char			*name;
} qr_game_row_t;

static const qr_game_row_t qr_named_rows[] = {
	{ "mg3", qr_row_mg3, "mg3" },
};

/* The resolved row, plus what it was resolved FOR. The gamedir is compared by
   CONTENT and not by pointer: com_gamedir is a fixed buffer that COM_Game_f
   rewrites in place, so its address is identical across a game switch. That is
   the same trap as the wheel's model cache, where Mod_ResetAll hands the next
   world back the same qmodel_t address. The two flags ride in the key as well,
   because `game rogue` and `game rogue -rogue` are one string with different
   flags. */
static const qr_weapon_entry_t	*qr_row_cached;
static const char		*qr_row_name = "vanilla";
static char			qr_row_gamedir[MAX_OSPATH];
static int			qr_row_flags = -1;
static uint32_t			qr_row_generation;

static void QR_ResolveWeaponRow (void)
{
	const char	*dir;
	size_t		i;

	dir = COM_SkipPath (com_gamedir);

	qr_row_cached = qr_row_vanilla;
	qr_row_name = "vanilla";

	if (rogue)
	{
		qr_row_cached = qr_row_rogue;
		qr_row_name = "rogue";
	}
	else if (hipnotic)
	{
		qr_row_cached = qr_row_hipnotic;
		qr_row_name = "hipnotic";
	}
	else
	{
		/* Case-insensitively, because COM_Game_f matches that way and a
		   directory typed as MG3 is the same game. */
		for (i = 0; i < sizeof qr_named_rows / sizeof qr_named_rows[0]; i++)
			if (!q_strcasecmp (dir, qr_named_rows[i].dir))
			{
				qr_row_cached = qr_named_rows[i].row;
				qr_row_name = qr_named_rows[i].name;
				break;
			}
	}

	q_strlcpy (qr_row_gamedir, com_gamedir, sizeof qr_row_gamedir);
	qr_row_flags = (rogue ? 1 : 0) | (hipnotic ? 2 : 0);
	qr_row_generation++;
}

const qr_weapon_entry_t *QR_WeaponRow (void)
{
	int	flags = (rogue ? 1 : 0) | (hipnotic ? 2 : 0);

	if (!qr_row_cached || flags != qr_row_flags
	    || strcmp (qr_row_gamedir, com_gamedir))
		QR_ResolveWeaponRow ();

	return qr_row_cached;
}

uint32_t QR_WeaponGameKey (void)
{
	QR_WeaponRow ();
	return qr_row_generation;
}

/* The reverse lookup, and the one every consumer of a SELECTION goes through:
   whoever knows the identity gets the bit, the impulse and the kind together,
   from the row, rather than deriving a number from a ring position the way
   both sides of the boundary used to. */
const qr_weapon_entry_t *QR_WeaponEntry (int identity)
{
	const qr_weapon_entry_t	*row;

	if (identity < 0)
		return NULL;
	for (row = QR_WeaponRow (); row->bit; row++)
		if ((int) row->identity == identity)
			return row;
	return NULL;
}

int QR_WeaponIdentityForBit (uint32_t bit)
{
	const qr_weapon_entry_t	*row;

	if (!bit)
		return -1;
	for (row = QR_WeaponRow (); row->bit; row++)
		if (row->bit == bit)
			return (int) row->identity;
	return -1;
}

/* ========================================================================
 * weapontable -- the instrument
 * ====================================================================== */

/* Deliberately an INDEPENDENT check rather than a read of the wheel's own
   resolution statics: the whole point of the command is to measure what the
   ring should contain without trusting the ring's arithmetic. It mirrors the
   wheel's rule exactly -- a pickup model counts when the server precached it
   or the file is on the search path, a view model counts only when precached
   -- and it loads nothing, because an instrument that changes the thing it
   measures is worse than no instrument. */
static int QR_WeaponModelResolved (int identity)
{
	const char *const	*names;
	const char		*pickup;
	int			m, i;

	pickup = QR_WeaponPickupModel (identity);
	if (pickup)
	{
		for (m = 1; m < MAX_MODELS && cl.model_precache[m]; m++)
			if (!strcmp (cl.model_precache[m]->name, pickup))
				return 1;
		if (COM_FileExists (pickup, NULL))
			return 1;
	}

	names = QR_WeaponViewModels (identity);
	for (i = 0; names[i]; i++)
		for (m = 1; m < MAX_MODELS && cl.model_precache[m]; m++)
			if (!strcmp (cl.model_precache[m]->name, names[i]))
				return 1;

	return 0;
}

static const char *QR_SelectKindName (int kind)
{
	switch (kind)
	{
	case QR_SELECT_DIRECT:	return "direct";
	case QR_SELECT_TOGGLE:	return "toggle";
	case QR_SELECT_CYCLE:	return "cycle";
	default:		return "?";
	}
}

/* Every open question in this work is answered by reading this output back
   off a headset, so it is laid out to be read ALOUD: one weapon per line, the
   columns named in a header, yes/no rather than a flag column, and the two
   counts spelled out at the end. The entry count is what confirms the right
   row was selected; the drawable count is the ring the player will see, which
   is lower whenever a bit is clear or a model is missing. */
void QR_WeaponTablePrint (void)
{
	int	id, entries = 0, drawable = 0, ring = 0;

	Con_Printf ("weapontable: game \"%s\", row %s\n",
		    COM_SkipPath (com_gamedir), qr_row_name);
	Con_Printf ("ring  id  label                      bit  have  model  impulse\n");

	/* Walked in ASCENDING IDENTITY, which is how the ring is laid out and
	   how the selection commit counts, NOT in row order. Printing the row's
	   own order numbered these lines differently from the slots they
	   describe, in the one place the two are read side by side. The ring
	   column is the slot a weapon actually occupies, so an impulse measured
	   against it can be written down against the right weapon. */
	for (id = 0; id < QC_WEAPON_IDENTITIES; id++)
	{
		const qr_weapon_entry_t	*e = QR_WeaponEntry (id);
		char			slot[8];
		int			have, model;

		if (!e)
			continue;

		have = (cl.items & e->bit) ? 1 : 0;
		model = QR_WeaponModelResolved (id);
		entries++;

		/* Only a weapon that is owned AND whose model resolved is on the
		   ring, so only those take a slot number. The rest print a dash
		   rather than a misleading index. */
		if (have && model)
		{
			q_snprintf (slot, sizeof (slot), "%d", ring++);
			drawable++;
		}
		else
			q_strlcpy (slot, "-", sizeof (slot));

		/* An unmeasured impulse prints as a word rather than as "0
		   direct", because a kind read aloud beside a zero is a claim
		   nobody made. */
		if (e->impulse)
			Con_Printf ("%4s  %2d  %-18s %9u  %-4s  %-5s  %d %s\n",
				    slot, id, QR_WeaponLabel (id),
				    (unsigned) e->bit, have ? "yes" : "no",
				    model ? "yes" : "no", (int) e->impulse,
				    QR_SelectKindName ((int) e->kind));
		else
			Con_Printf ("%4s  %2d  %-18s %9u  %-4s  %-5s  unmeasured\n",
				    slot, id, QR_WeaponLabel (id),
				    (unsigned) e->bit, have ? "yes" : "no",
				    model ? "yes" : "no");
	}

	Con_Printf ("row %s: %d entries, %d drawable (bit set and model resolved)\n",
		    qr_row_name, entries, drawable);
}

void QR_Weapons_Init (void)
{
	Cmd_AddCommand ("weapontable", QR_WeaponTablePrint);
}
