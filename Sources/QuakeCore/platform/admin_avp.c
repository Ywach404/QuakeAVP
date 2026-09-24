/*
 * admin_avp.c -- engine side of the window's Admin tab.
 *
 * Two single-player cheats that upstream has no console equivalent for, plus
 * the monster roster the tab needs to drive them:
 *
 *   sv_killai 0|1     Enemies never target the player. Upstream `notarget`
 *                     only stops FindTarget acquiring you; a monster already
 *                     hunting you keeps coming, and combat.qc's damage
 *                     retaliation ignores FL_NOTARGET entirely, so shooting a
 *                     monster with notarget on still turns it on you. While
 *                     this is on the engine re-applies FL_NOTARGET and clears
 *                     any monster's enemy/oldenemy that points at a client
 *                     EVERY tick. ai_run sees enemy == world and drops the
 *                     monster back to its stand/walk think, exactly the path
 *                     it takes when the player dies -- no QuakeC surgery.
 *
 *   ai_target A T     Monster A (edict number) goes hostile toward monster T.
 *                     Sets A.enemy and runs progs' own FoundTarget with self
 *                     = A, so the sight sound, HuntTarget and the think chain
 *                     are upstream behaviour. `ai_target list` prints the
 *                     roster. T's retaliation is combat.qc's business and it
 *                     refuses same-classname infighting, so the UI sends the
 *                     reverse pair when it wants both ways.
 *
 * The roster snapshot is the any-thread half: refreshed here on the engine
 * thread, copied out by QC_AdminCopyState under a mutex.
 */

#include "quakedef.h"
#include "QuakeCore.h"
#include "admin_avp.h"

#include <pthread.h>

static cvar_t	sv_killai = {"sv_killai", "0", CVAR_NONE};

#define ADMIN_ROSTER_PERIOD	0.25	/* seconds of realtime between refreshes */

static pthread_mutex_t		qc_admin_lock = PTHREAD_MUTEX_INITIALIZER;
static qc_admin_state_t		qc_admin_shared;
static double			qc_admin_next_refresh;

/* Cached per progs load: the QuakeC-only .oldenemy field (not in entvars_t)
   and FoundTarget. Keyed on the progs pointer so a map change re-resolves. */
static dprograms_t	*admin_progs_key;
static int		admin_oldenemy_ofs;	/* float offset, -1 = no such field */
static func_t		admin_foundtarget;	/* 0 = no such function */

static void Admin_ResolveProgs (void)
{
	int	i;

	if (progs == admin_progs_key)
		return;
	admin_progs_key = progs;
	admin_oldenemy_ofs = -1;
	admin_foundtarget = 0;
	if (!progs)
		return;

	/* the field defs are file-local to pr_edict.c; resolve through the
	   public lookup once here rather than per monster per tick, which
	   would thrash its two-entry cache under SV_AddGravity's feet */
	{
		edict_t	*world = EDICT_NUM (0);
		eval_t	*val = GetEdictFieldValue (world, "oldenemy");
		if (val)
			admin_oldenemy_ofs = (int)((float *)val - (float *)&world->v);
	}
	for (i = 1; i < progs->numfunctions; i++)
		if (!strcmp (PR_GetString (pr_functions[i].s_name), "FoundTarget"))
		{
			admin_foundtarget = i;
			break;
		}
}

static qboolean Admin_IsLiveMonster (edict_t *ent)
{
	return !ent->free && ((int)ent->v.flags & FL_MONSTER) && ent->v.health > 0;
}

static qboolean Admin_IsClient (int prog)
{
	edict_t *e;

	if (!prog)
		return false;
	e = PROG_TO_EDICT (prog);
	return !e->free && ((int)e->v.flags & FL_CLIENT);
}

static edict_t *Admin_LocalPlayer (void)
{
	if (!sv.active || svs.maxclients < 1 || !svs.clients[0].active)
		return NULL;
	return svs.clients[0].edict;
}

/* ========================================================================
 * sv_killai
 * ===================================================================== */

static void Admin_KillAI (qboolean on)
{
	static qboolean	was_on;
	int		i, e;

	if (!sv.active)
	{
		was_on = false;
		return;
	}

	if (!on)
	{
		if (was_on)
			for (i = 0; i < svs.maxclients; i++)
				if (svs.clients[i].active)
					svs.clients[i].edict->v.flags =
						(int)svs.clients[i].edict->v.flags & ~FL_NOTARGET;
		was_on = false;
		return;
	}
	was_on = true;

	for (i = 0; i < svs.maxclients; i++)
		if (svs.clients[i].active)
			svs.clients[i].edict->v.flags =
				(int)svs.clients[i].edict->v.flags | FL_NOTARGET;

	Admin_ResolveProgs ();
	for (e = svs.maxclients + 1; e < sv.num_edicts; e++)
	{
		edict_t *ent = EDICT_NUM (e);

		if (!Admin_IsLiveMonster (ent))
			continue;
		if (Admin_IsClient (ent->v.enemy))
			ent->v.enemy = 0;
		if (admin_oldenemy_ofs >= 0)
		{
			int *oldenemy = (int *)((float *)&ent->v + admin_oldenemy_ofs);
			if (Admin_IsClient (*oldenemy))
				*oldenemy = 0;
		}
	}
}

/* ========================================================================
 * ai_target
 * ===================================================================== */

static void Admin_PrintRoster (void)
{
	edict_t	*player = Admin_LocalPlayer ();
	int	e, n = 0;

	for (e = 1; e < sv.num_edicts; e++)
	{
		edict_t	*ent = EDICT_NUM (e);
		char	enemy[32];

		if (!Admin_IsLiveMonster (ent))
			continue;
		if (!ent->v.enemy)
			q_strlcpy (enemy, "-", sizeof enemy);
		else if (Admin_IsClient (ent->v.enemy))
			q_strlcpy (enemy, "you", sizeof enemy);
		else
			q_snprintf (enemy, sizeof enemy, "%d",
				    (int)NUM_FOR_EDICT (PROG_TO_EDICT (ent->v.enemy)));
		Con_Printf ("%4d  %-20s hp %4.0f  enemy %s", e,
			    PR_GetString (ent->v.classname), ent->v.health, enemy);
		if (player)
		{
			vec3_t d;
			VectorSubtract (ent->v.origin, player->v.origin, d);
			Con_Printf ("  %5.0f units", VectorLength (d));
		}
		Con_Printf ("\n");
		n++;
	}
	Con_Printf ("%d live monster%s\n", n, n == 1 ? "" : "s");
}

static edict_t *Admin_MonsterArg (const char *arg)
{
	int	e = atoi (arg);
	edict_t	*ent;

	if (e <= 0 || e >= sv.num_edicts)
	{
		Con_Printf ("ai_target: no edict %s\n", arg);
		return NULL;
	}
	ent = EDICT_NUM (e);
	if (!Admin_IsLiveMonster (ent))
	{
		Con_Printf ("ai_target: edict %d is not a live monster\n", e);
		return NULL;
	}
	return ent;
}

static void Admin_Target_f (void)
{
	edict_t	*attacker, *target;
	int	saved_self, saved_other;

	if (!sv.active)
	{
		Con_Printf ("ai_target: no level loaded\n");
		return;
	}
	if (Cmd_Argc () == 2 && !strcmp (Cmd_Argv (1), "list"))
	{
		Admin_PrintRoster ();
		return;
	}
	if (Cmd_Argc () != 3)
	{
		Con_Printf ("ai_target <attacker> <target> : monster <attacker> hunts monster <target>\n"
			    "ai_target list                : live monsters by edict number\n");
		return;
	}

	attacker = Admin_MonsterArg (Cmd_Argv (1));
	target = Admin_MonsterArg (Cmd_Argv (2));
	if (!attacker || !target)
		return;
	if (attacker == target)
	{
		Con_Printf ("ai_target: a monster cannot hunt itself\n");
		return;
	}

	Admin_ResolveProgs ();

	/* mirror combat.qc: remember the player so the monster comes back to
	   you once the fight is over (sv_killai clears that too) */
	if (admin_oldenemy_ofs >= 0 && Admin_IsClient (attacker->v.enemy))
		*(int *)((float *)&attacker->v + admin_oldenemy_ofs) = attacker->v.enemy;
	attacker->v.enemy = EDICT_TO_PROG (target);

	if (admin_foundtarget)
	{
		/* Console commands run inside Host_Frame's error frame, so a
		   QuakeC runaway here unwinds the same way a think would. */
		saved_self = pr_global_struct->self;
		saved_other = pr_global_struct->other;
		pr_global_struct->self = EDICT_TO_PROG (attacker);
		PR_ExecuteProgram (admin_foundtarget);
		pr_global_struct->self = saved_self;
		pr_global_struct->other = saved_other;
	}
	else
	{
		/* a progs without FoundTarget (a mod): point the goal and let the
		   monster's next run think pick it up */
		attacker->v.goalentity = attacker->v.enemy;
		Con_Printf ("ai_target: progs has no FoundTarget; set enemy only\n");
	}

	Con_Printf ("ai_target: %d (%s) now hunts %d (%s)\n",
		    (int)NUM_FOR_EDICT (attacker), PR_GetString (attacker->v.classname),
		    (int)NUM_FOR_EDICT (target), PR_GetString (target->v.classname));
}

/* ========================================================================
 * roster snapshot
 * ===================================================================== */

static void Admin_RefreshRoster (void)
{
	qc_admin_state_t	st;
	edict_t			*player = Admin_LocalPlayer ();
	int			e;

	memset (&st, 0, sizeof st);
	st.active = sv.active ? 1 : 0;
	st.killai = sv_killai.value != 0;
	st.player_edict = player ? (int)NUM_FOR_EDICT (player) : 0;

	if (sv.active)
		for (e = 1; e < sv.num_edicts && st.count < QC_ADMIN_MAX_MONSTERS; e++)
		{
			edict_t		*ent = EDICT_NUM (e);
			qc_monster_t	*m;

			if (!Admin_IsLiveMonster (ent))
				continue;
			m = &st.monsters[st.count++];
			m->edict = e;
			m->health = ent->v.health;
			m->enemy = ent->v.enemy
				? (int)NUM_FOR_EDICT (PROG_TO_EDICT (ent->v.enemy)) : 0;
			q_strlcpy (m->classname, PR_GetString (ent->v.classname),
				   sizeof m->classname);
			if (player)
			{
				vec3_t d;
				VectorSubtract (ent->v.origin, player->v.origin, d);
				m->distance = VectorLength (d);
			}
		}

	pthread_mutex_lock (&qc_admin_lock);
	qc_admin_shared = st;
	pthread_mutex_unlock (&qc_admin_lock);
}

void QC_AdminCopyState (qc_admin_state_t *out)
{
	pthread_mutex_lock (&qc_admin_lock);
	*out = qc_admin_shared;
	pthread_mutex_unlock (&qc_admin_lock);
}

/* ========================================================================
 * lifecycle
 * ===================================================================== */

void Admin_Init (void)
{
	Cvar_RegisterVariable (&sv_killai);
	Cmd_AddCommand ("ai_target", Admin_Target_f);
}

void Admin_Frame (void)
{
	Admin_KillAI (sv_killai.value != 0);

	if (realtime >= qc_admin_next_refresh)
	{
		qc_admin_next_refresh = realtime + ADMIN_ROSTER_PERIOD;
		Admin_RefreshRoster ();
	}
}
