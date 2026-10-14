/*
 * session_snapshot_test.c -- the window's Game-tab snapshot (session_avp.c).
 *
 * The engine globals this reads -- sv, svs, cl, cls, hostcache[],
 * hostCacheCount, slistInProgress, realtime, com_gamedir -- are plain
 * objects linked into every host-check binary, so the states the UI cares
 * about CAN be synthesized here without a server or a network: fill them in,
 * run Session_Frame() (the engine-thread half), then read back through the
 * any-thread copiers and check that what crossed is what was set.
 *
 * What this does NOT cover: that a real `slist` fills hostcache at all (that
 * is net_dgrm.c over a LAN), and that the refusal reasons stay in step with
 * Host_Savegame_f if upstream adds a guard. The order below is copied from
 * host_cmd.c and has to be re-checked on an upstream merge.
 */
#include "q_stdinc.h"
#include "arch_def.h"
#include "net_sys.h"
#include "quakedef.h"
#include "net_defs.h"
#include "QuakeCore.h"
#include "session_avp.h"

#include <string.h>
#include <stdio.h>

static int failures;
#define CHECK(c,...) do{ if(!(c)){failures++;printf("FAIL: "__VA_ARGS__);printf("\n");}else{printf("ok:   "__VA_ARGS__);printf("\n");} }while(0)

/* One client's worth of server state, enough for the save guards. */
static client_t	test_clients[4];
static edict_t	test_edicts[4];

static void reset_world (void)
{
	memset (&sv, 0, sizeof sv);
	memset (&svs, 0, sizeof svs);
	memset (&cl, 0, sizeof cl);
	memset (&cls, 0, sizeof cls);
	memset (test_clients, 0, sizeof test_clients);
	memset (test_edicts, 0, sizeof test_edicts);
	svs.clients = test_clients;
	hostCacheCount = 0;
	memset (hostcache, 0, sizeof hostcache);
	slistInProgress = false;
}

/* Session_Frame only refreshes on its own cadence; jump realtime past it. */
static void refresh (void)
{
	realtime += 10.0;
	Session_Frame ();
}

static void live_single_player (void)
{
	sv.active = true;
	sv.nomonsters = false;
	cl.intermission = 0;
	svs.maxclients = 1;
	svs.clients[0].active = true;
	svs.clients[0].edict = &test_edicts[0];
	test_edicts[0].v.health = 100;
}

int main (void)
{
	qc_session_state_t	st;
	qc_server_t		rows[QC_SERVER_MAX];
	int			n;

	/* ---- save guards, in Host_Savegame_f's order ---- */

	reset_world ();
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (st.save_block == QC_SAVE_NO_LOCAL_GAME, "no server: save blocked as 'not playing a local game'");
	CHECK (st.level_loaded == 0, "no server: level_loaded clear");

	reset_world ();
	live_single_player ();
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (st.save_block == QC_SAVE_OK, "live single player: save allowed");
	CHECK (st.level_loaded == 1, "live single player: level_loaded set");

	reset_world ();
	live_single_player ();
	sv.nomonsters = true;
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (st.save_block == QC_SAVE_NOMONSTERS, "nomonsters blocks the save");

	reset_world ();
	live_single_player ();
	cl.intermission = 1;
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (st.save_block == QC_SAVE_INTERMISSION, "intermission blocks the save");

	reset_world ();
	live_single_player ();
	svs.maxclients = 4;
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (st.save_block == QC_SAVE_MULTIPLAYER, "multiplayer blocks the save");

	reset_world ();
	live_single_player ();
	test_edicts[0].v.health = 0;
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (st.save_block == QC_SAVE_PLAYER_DEAD, "a dead player blocks the save");

	/* nomonsters is checked BEFORE intermission, so both set reports
	   nomonsters -- the same line the console would print. */
	reset_world ();
	live_single_player ();
	sv.nomonsters = true;
	cl.intermission = 1;
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (st.save_block == QC_SAVE_NOMONSTERS, "guard order: nomonsters wins over intermission");

	/* ---- connection state ---- */

	reset_world ();
	cls.state = ca_disconnected;
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (st.connected == 0, "ca_disconnected reads as not connected");

	reset_world ();
	cls.state = ca_connected;
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (st.connected == 1, "ca_connected reads as connected");

	/* ---- the save directory is com_gamedir, not a path rebuilt in Swift ---- */

	reset_world ();
	q_strlcpy (com_gamedir, "/tmp/quakeavp-test/id1", sizeof com_gamedir);
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (!strcmp (st.gamedir, "/tmp/quakeavp-test/id1"), "gamedir crosses as com_gamedir");

	/* ---- the server browser ---- */

	reset_world ();
	hostCacheCount = 2;
	q_strlcpy (hostcache[0].name, "basement", sizeof hostcache[0].name);
	q_strlcpy (hostcache[0].map, "e1m1", sizeof hostcache[0].map);
	q_strlcpy (hostcache[0].cname, "192.168.1.9:26000", sizeof hostcache[0].cname);
	hostcache[0].users = 2;
	hostcache[0].maxusers = 8;
	q_strlcpy (hostcache[1].name, "local", sizeof hostcache[1].name);
	q_strlcpy (hostcache[1].map, "start", sizeof hostcache[1].map);
	q_strlcpy (hostcache[1].cname, "local", sizeof hostcache[1].cname);
	slistInProgress = true;
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (st.server_count == 2, "two hosts in the cache cross as two rows");
	CHECK (st.slist_in_progress == 1, "a search in flight is reported");
	CHECK (!strcmp (st.servers[0].name, "basement"), "row 0 name");
	CHECK (!strcmp (st.servers[0].map, "e1m1"), "row 0 map");
	CHECK (!strcmp (st.servers[0].cname, "192.168.1.9:26000"), "row 0 connect address");
	CHECK (st.servers[0].users == 2 && st.servers[0].maxusers == 8, "row 0 player counts");
	CHECK (!strcmp (st.servers[1].cname, "local"), "row 1 is the loopback host, listed honestly");

	n = QC_ServerListCopy (rows, QC_SERVER_MAX);
	CHECK (n == 2, "QC_ServerListCopy returns the row count");
	CHECK (!strcmp (rows[0].cname, "192.168.1.9:26000"), "QC_ServerListCopy copies the same rows");

	n = QC_ServerListCopy (rows, 1);
	CHECK (n == 1, "QC_ServerListCopy clamps to the caller's buffer");

	/* A cache fuller than the snapshot cannot overrun it. HOSTCACHESIZE and
	   QC_SERVER_MAX are both 8 today, so push the count past both. */
	reset_world ();
	hostCacheCount = HOSTCACHESIZE + 4;
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (st.server_count == QC_SERVER_MAX, "an over-full cache clamps to QC_SERVER_MAX");

	/* A field filled edge to edge still crosses NUL-terminated. */
	reset_world ();
	hostCacheCount = 1;
	memset (hostcache[0].name, 'A', sizeof hostcache[0].name);
	refresh ();
	QC_SessionCopyState (&st);
	CHECK (strlen (st.servers[0].name) == QC_SERVER_NAME_LEN - 1,
	       "an unterminated host name is truncated, not overread");

	/* ---- a search in flight refreshes every frame, not on the cadence ---- */

	reset_world ();
	refresh ();			/* publish an empty list, arm the cadence */
	hostCacheCount = 1;
	q_strlcpy (hostcache[0].cname, "10.0.0.2:26000", sizeof hostcache[0].cname);
	Session_Frame ();		/* no realtime jump: cadence not due */
	QC_SessionCopyState (&st);
	CHECK (st.server_count == 0, "idle: a late reply waits for the next cadence tick");
	slistInProgress = true;
	Session_Frame ();		/* still no jump, but a search is live */
	QC_SessionCopyState (&st);
	CHECK (st.server_count == 1, "searching: replies cross on the very next frame");

	printf (failures ? "FAILED (%d)\n" : "PASSED (0 failures)\n", failures);
	return failures != 0;
}
