/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * hostmain.c -- host-side driver for tools/check-core.sh. Not part of the app.
 *
 * Exists so the check script can link a real *executable*: shared libraries
 * happily tolerate undefined symbols, executables do not. Linking this proves
 * the platform stub layer covers every symbol the engine core references.
 *
 * If a basedir containing id1/pak0.pak is passed, it also boots the engine for
 * a few frames, which exercises COM_InitFilesystem, the zone allocator, PR
 * loading, and the server -- i.e. most of what M0 claims to have working.
 */

#include "QuakeCore.h"

#include <stdio.h>
#include <string.h>

static void on_log (void *ctx, const char *text)
{
	(void) ctx;
	fputs (text, stdout);
}

/*
 * The audio sink lives in Swift (App/Sources/AudioSink.swift), which this host
 * build does not compile. Stand in for its shim so the link still proves the
 * platform layer is complete. Returning 0 from open makes snd_avp.c report "no
 * audio device" and S_Init disable sound, which is the correct headless
 * behaviour anyway.
 */
int QC_AudioOpen (int speed, int channels, int bits,
		  unsigned char **buffer, int *mono_samples)
{
	(void) speed; (void) channels; (void) bits;
	if (buffer) *buffer = NULL;
	if (mono_samples) *mono_samples = 0;
	return 0;
}

int  QC_AudioSamplePos (void) { return 0; }
void QC_AudioClose (void) { }
void QC_AudioSetRunning (int running) { (void) running; }

static void on_error (void *ctx, const char *err)
{
	(void) ctx;
	if (err)
		fprintf (stderr, "\n[host] fatal: %s\n", err);
	else
		fprintf (stderr, "\n[host] clean quit\n");
}

int main (int argc, char **argv)
{
	const char *args[8];
	int n = 0, i;

	QC_SetCallbacks (on_log, on_error, NULL);

	printf ("[host] QuakeCore linked. engine version %s\n", QC_VersionString());

	if (argc < 2 || !argv[1][0])
	{
		printf ("[host] link check only (pass a basedir to boot)\n");
		return 0;
	}

	QC_SetPaths (argv[1], argv[1]);

	args[n++] = "-basedir";
	args[n++] = argv[1];

	if (!QC_Init (n, args))
	{
		fprintf (stderr, "[host] QC_Init failed\n");
		return 1;
	}

	for (i = 0; i < 10; i++)
		QC_Frame (1.0 / 60.0);

	QC_Shutdown ();
	printf ("[host] ran 10 frames and shut down cleanly\n");
	return 0;
}
