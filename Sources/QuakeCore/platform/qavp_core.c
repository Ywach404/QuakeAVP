/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * qavp_core.c -- implementation of QuakeCore.h.
 *
 * Replaces main_sdl.c. The critical difference: upstream owns the process and
 * spins `while (1) { Host_Frame(); }`. Here the *host* is visionOS, and frames
 * are pulled by whoever calls QC_Frame() -- a Timer today, the
 * CompositorServices LayerRenderer at M3. The engine never blocks.
 */

#include "quakedef.h"
#include "QuakeCore.h"
#include "admin_avp.h"
#include "session_avp.h"

#include <stdlib.h>
#include <string.h>

#define QAVP_MAX_ARGS	64

/* Upstream keeps this in main_sdl.c, which we don't compile. It is a single
   up-front malloc for the zone allocator, not resident memory: untouched
   pages are never faulted in, so the cost of a generous number is address
   space rather than RAM.
   
   Was 384 MB, QuakeSpasm's 64-bit default, on the reasoning that Quake never
   comes close to touching it all. That stopped being true the moment this
   engine was pointed at modern community content: Brutalist Jam III ships
   levels of 99, 101 and 123 MB, and a BSP is loaded whole into the hunk
   before its lightmaps and surfaces are built on top. 384 MB cannot hold
   that, and the failure is a hard Hunk_Alloc error rather than a degraded
   frame.
   
   1 GB on a device with 16 GB of RAM, where the old number was chosen for
   desktops of a different era. Still override with -heapsize (in KB). */
#define QAVP_DEFAULT_MEMORY	(1024 * 1024 * 1024)

static quakeparms_t	qavp_parms;
static char		*qavp_argv[QAVP_MAX_ARGS];
static int		qavp_argc;
static char		qavp_basedir[MAX_OSPATH];
static char		qavp_userdir[MAX_OSPATH];
static qboolean		qavp_running;

void QC_SetPaths (const char *basedir, const char *userdir)
{
	if (basedir)
		q_strlcpy (qavp_basedir, basedir, sizeof(qavp_basedir));
	if (userdir)
		q_strlcpy (qavp_userdir, userdir, sizeof(qavp_userdir));
}

/* Sys_GetUserdir equivalent -- common.c asks for this via host_parms->userdir. */
static void QAVP_BuildArgs (int argc, const char * const *argv)
{
	int i;

	/* argv[0] is conventionally the program name and COM_CheckParm skips it. */
	qavp_argv[0] = (char *) "quake";
	qavp_argc = 1;

	for (i = 0; i < argc && qavp_argc < QAVP_MAX_ARGS - 1; i++)
		qavp_argv[qavp_argc++] = (char *) argv[i];

	qavp_argv[qavp_argc] = NULL;
}

bool QC_Init (int argc, const char * const *argv)
{
	if (qavp_running)
		return true;

	QAVP_BuildArgs (argc, argv);

	memset (&qavp_parms, 0, sizeof(qavp_parms));
	host_parms = &qavp_parms;

	qavp_parms.basedir = qavp_basedir[0] ? qavp_basedir : ".";
	qavp_parms.userdir = qavp_userdir[0] ? qavp_userdir : qavp_parms.basedir;
	qavp_parms.argc = qavp_argc;
	qavp_parms.argv = qavp_argv;
	qavp_parms.errstate = 0;

	COM_InitArgv (qavp_parms.argc, qavp_parms.argv);

	isDedicated = false;

	Sys_Init ();
	Sys_Printf ("Initializing QuakeSpasm v%s (visionOS)\n", QUAKESPASM_VER_STRING);

	qavp_parms.memsize = QAVP_DEFAULT_MEMORY;
	if (COM_CheckParm("-heapsize"))
	{
		int t = COM_CheckParm("-heapsize") + 1;
		if (t < com_argc)
			qavp_parms.memsize = Q_atoi(com_argv[t]) * 1024;
	}

	qavp_parms.membase = malloc (qavp_parms.memsize);
	if (!qavp_parms.membase)
	{
		Sys_Printf ("Not enough memory free; check disk space\n");
		return false;
	}

	Sys_Printf ("Host_Init\n");
	Host_Init ();

	qavp_running = true;
	return true;
}

void QC_Frame (double dt)
{
	if (!qavp_running)
		return;

	/* Clamp: a long pause (immersive space dismissed, app backgrounded) must
	   not hand the sim a multi-second tick and teleport everything. */
	if (dt < 0.0)
		dt = 0.0;
	if (dt > 0.1)
		dt = 0.1;

	Host_Frame ((float) dt);
	/* After the tick, outside Host_Frame's error frame: it only touches
	   server state and never calls into progs. */
	Admin_Frame ();
	/* Same slot, same reason: both read server/client state and neither
	   enters progs. Host_Frame has just run NET_Poll, so a server search
	   in flight is as current here as it ever gets. */
	Session_Frame ();
}

void QC_Shutdown (void)
{
	if (!qavp_running)
		return;

	qavp_running = false;
	Host_Shutdown ();

	if (qavp_parms.membase)
	{
		free (qavp_parms.membase);
		qavp_parms.membase = NULL;
	}
}

void QC_ExecuteCommand (const char *text)
{
	if (!qavp_running || !text)
		return;

	Cbuf_AddText (text);
}

bool QC_IsRunning (void)
{
	return qavp_running ? true : false;
}

const char *QC_VersionString (void)
{
	return QUAKESPASM_VER_STRING;
}
