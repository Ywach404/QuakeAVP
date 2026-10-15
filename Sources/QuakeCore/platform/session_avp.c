/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * session_avp.c -- engine side of the window's Game tab (save/load and
 * multiplayer).
 *
 * The SwiftUI window is the product's whole out-of-game surface now, so it
 * needs the facts the engine menu used to read straight off the globals:
 * whether `save` would be accepted, where saves live, whether we are
 * connected, and what `slist` found. None of those globals may be touched
 * from the window's thread -- sv/svs/cl/cls and the network layer's
 * hostcache[] have no locking and the host loop rewrites them mid-frame.
 *
 * So this is the admin roster's twin (admin_avp.c): assemble a plain-value
 * snapshot HERE, on the engine thread inside QC_Frame, publish it under a
 * mutex, and let any thread copy it. Nothing in this file writes engine
 * state; the window's commands go back the ordinary way, through
 * QC_ExecuteCommand.
 *
 * Two departures from the roster's shape, both deliberate:
 *
 *   - `save_block` is computed here rather than left to the UI to infer, in
 *     Host_Savegame_f's own guard order. The refusal reasons are engine
 *     truth and there should be exactly one statement of them; a window that
 *     re-derived "can I save?" from active/maxclients/intermission would be a
 *     second opinion that drifts the first time upstream adds a guard.
 *
 *   - the refresh runs EVERY frame while a server search is in flight.
 *     NET_Slist_f is asynchronous -- Slist_Poll re-schedules itself for ~1.5
 *     seconds, adding hosts to hostcache[] as their replies arrive -- and a
 *     quarter-second snapshot would make the list appear in visible steps.
 *     Idle, it falls back to the roster's cadence.
 */

#include "q_stdinc.h"
#include "arch_def.h"
#include "net_sys.h"
#include "quakedef.h"
#include "net_defs.h"
#include "QuakeCore.h"
#include "session_avp.h"

#include <pthread.h>

#define SESSION_PERIOD	0.25	/* seconds of realtime between idle refreshes */

static pthread_mutex_t		qc_session_lock = PTHREAD_MUTEX_INITIALIZER;
/* Blocked before the first Session_Frame, not QC_SAVE_OK. A zeroed struct
   would answer "save is fine" with an empty gamedir, and the window is open
   and asking before the engine's first frame -- the permissive value must
   never be the one you get by default. */
static qc_session_state_t	qc_session_shared = { .save_block = QC_SAVE_NO_LOCAL_GAME };
static double			qc_session_next_refresh;

/*
 * Copy one fixed-width hostcache field without assuming it is terminated.
 *
 * The destination is the SAME width as the source (QC_SERVER_*_LEN are
 * hostcache_t's own widths), so a fixed-length memcpy plus an explicit NUL
 * is correct whatever the driver left there, and cannot read past the
 * source field. q_strlcpy would be wrong for exactly that reason: on
 * truncation it walks the source for a terminator, which an edge-to-edge
 * field does not have.
 *
 * Do not read this as "upstream terminates these". It did not: net_dgrm.c
 * filled them with an unbounded Q_strcpy out of a network reply, which is
 * the overrun the sixth QAVP_PLATFORM hunk now closes (see UPSTREAM.md).
 * With that hunk the source is bounded and terminated as well, so this
 * function is belt and braces -- kept, because it is the last thing
 * standing between a network buffer and the window if the hunk is ever
 * dropped on an upstream merge.
 */
static void Session_CopyField (char *dst, const char *src, size_t len)
{
	memcpy (dst, src, len - 1);
	dst[len - 1] = '\0';
}

/*
===============
Session_SaveBlock

Why `save` would be refused, in Host_Savegame_f's guard order (host_cmd.c):
sv.active, sv.nomonsters, cl.intermission, svs.maxclients, then a dead
client. The cmd_source and Cmd_Argc guards above them are not reachable from
the window -- it always sends `save <name>` from a console command source --
and the ".." check is the caller's, since the name is the caller's.
===============
*/
static int Session_SaveBlock (void)
{
	int	i;

	if (!sv.active)
		return QC_SAVE_NO_LOCAL_GAME;
	if (sv.nomonsters)
		return QC_SAVE_NOMONSTERS;
	if (cl.intermission)
		return QC_SAVE_INTERMISSION;
	if (svs.maxclients != 1)
		return QC_SAVE_MULTIPLAYER;

	/* svs.clients is NULL until Host_InitLocal has allocated it; sv.active
	   implies it exists, but the loop is bounded by maxclients either way. */
	if (svs.clients)
		for (i = 0; i < svs.maxclients; i++)
			if (svs.clients[i].active && svs.clients[i].edict->v.health <= 0)
				return QC_SAVE_PLAYER_DEAD;

	return QC_SAVE_OK;
}

static void Session_Refresh (void)
{
	qc_session_state_t	st;
	int			n;

	memset (&st, 0, sizeof st);

	st.connected = (cls.state == ca_connected) ? 1 : 0;
	st.level_loaded = sv.active ? 1 : 0;
	st.save_block = Session_SaveBlock ();
	st.slist_in_progress = slistInProgress ? 1 : 0;

	q_strlcpy (st.gamedir, com_gamedir, sizeof st.gamedir);

	n = hostCacheCount;
	if (n > QC_SERVER_MAX)
		n = QC_SERVER_MAX;
	for (st.server_count = 0; st.server_count < n; st.server_count++)
	{
		const hostcache_t	*h = &hostcache[st.server_count];
		qc_server_t		*s = &st.servers[st.server_count];

		Session_CopyField (s->name, h->name, sizeof s->name);
		Session_CopyField (s->map, h->map, sizeof s->map);
		Session_CopyField (s->cname, h->cname, sizeof s->cname);
		s->users = h->users;
		s->maxusers = h->maxusers;
	}

	pthread_mutex_lock (&qc_session_lock);
	qc_session_shared = st;
	pthread_mutex_unlock (&qc_session_lock);
}

void QC_SessionCopyState (qc_session_state_t *out)
{
	pthread_mutex_lock (&qc_session_lock);
	*out = qc_session_shared;
	pthread_mutex_unlock (&qc_session_lock);
}

int QC_ServerListCopy (qc_server_t *out, int max)
{
	int	n;

	if (!out || max <= 0)
		return 0;

	pthread_mutex_lock (&qc_session_lock);
	n = qc_session_shared.server_count;
	if (n > max)
		n = max;
	if (n > 0)
		memcpy (out, qc_session_shared.servers, (size_t) n * sizeof (qc_server_t));
	pthread_mutex_unlock (&qc_session_lock);

	return n;
}

void Session_Frame (void)
{
	/* Every frame while a search is polling (see the file comment), the
	   roster's cadence otherwise. */
	if (slistInProgress || realtime >= qc_session_next_refresh)
	{
		qc_session_next_refresh = realtime + SESSION_PERIOD;
		Session_Refresh ();
	}
}
