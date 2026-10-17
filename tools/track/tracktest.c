/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * tracktest.c -- boot the engine against the make-check objects, load the
 * track, and assert the oval is where the generator says it is. Deviceless
 * proof the map is in the pak and walkable: link against
 * ${TMPDIR}/quakecore-hostbuild/[star].o minus hostmain.o (tools/track/README.md).
 */

#include "quakedef.h"
#include "QuakeCore.h"
#include <stdio.h>

/* Mirrors PLAYER_START in tools/track/gentrack.py: one hull-width past the
 * start line, in the middle of lane 1, standing (origin z = 24 on a z = 0
 * floor). Change both or neither. */
#define START_X  (-1637.0f)
#define START_Y  (-1461.0f)
#define START_Z  24.0f
#define START_TOL 48.0f

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)
static void on_log (void *c, const char *t) { (void)c; fputs (t, stdout); }
static void on_error (void *c, const char *e) { (void)c; if (e) printf("FATAL: %s\n", e); }
static void frames (int n) { int i; for (i = 0; i < n; i++) QC_Frame (1.0/72.0); }

/* The audio sink is Swift and is not in the host objects; hostmain.c carries
 * the same four stand-ins for `make check`. Returning 0 from open leaves the
 * engine with no sound device, which is the right headless answer. */
int QC_AudioOpen (int speed, int channels, int bits, unsigned char **buffer, int *mono_samples)
{
	(void)speed; (void)channels; (void)bits;
	if (buffer) *buffer = NULL;
	if (mono_samples) *mono_samples = 0;
	return 0;
}
int  QC_AudioSamplePos (void) { return 0; }
void QC_AudioClose (void) { }
void QC_AudioSetRunning (int running) { (void)running; }

int main (int argc, char **argv)
{
	vec3_t org, after;
	if (argc < 2) return 2;
	QC_SetCallbacks (on_log, on_error, NULL);
	QC_SetPaths (argv[1], argv[1]);
	{ const char *a[2] = { "-basedir", argv[1] };
	  if (!QC_Init (2, a)) { printf ("init failed\n"); return 1; } }
	QC_ExecuteCommand ("map track\n");
	frames (120);
	CHECK (sv.active && cls.signon == 4, "track.bsp loads and connects (signon=%d)", cls.signon);
	CHECK (cl.worldmodel && !strcmp (cl.worldmodel->name, "maps/track.bsp"),
	       "worldmodel is the track");
	VectorCopy (svs.clients[0].edict->v.origin, org);
	CHECK (fabs (org[0] - START_X) < START_TOL && fabs (org[1] - START_Y) < START_TOL
	       && fabs (org[2] - START_Z) < START_TOL,
	       "player starts in lane 1 on the start line (%.0f %.0f %.0f)", org[0], org[1], org[2]);
	CHECK (org[2] > 0 && org[2] < 64, "player stands on the floor (z=%.0f)", org[2]);

	/* The straight ahead is open and the lane runs +X: two seconds of
	 * forward hold should cover a few hundred units and drift nowhere. */
	QC_ExecuteCommand ("+forward\n");
	frames (144);
	QC_ExecuteCommand ("-forward\n");
	VectorCopy (svs.clients[0].edict->v.origin, after);
	CHECK (after[0] - org[0] > 200, "running +X down the straight (x %.0f -> %.0f)", org[0], after[0]);
	CHECK (fabs (after[1] - START_Y) < 24, "and staying in lane 1 (y=%.0f)", after[1]);
	printf (failures ? "\n%d FAILURES\n" : "\nall passed\n", failures);
	return failures ? 1 : 0;
}
