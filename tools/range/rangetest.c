/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * rangetest.c -- boot the engine against the make-check objects, load the
 * range, and assert it exercises what it was built to. Deviceless proof
 * the arena is wired: link against ${TMPDIR}/quakecore-hostbuild/[star].o minus
 * hostmain.o (see tools/range/README.md).
 */

#include "quakedef.h"
#include "QuakeCore.h"
#include <stdio.h>

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

/* Mirrors the track constants in tools/range/genrange.py: lane 1's inner
 * edge, a lane's width, and how far the lane lines stand proud of the floor.
 * Change both or neither. */
#define R_IN	1437.0f
#define LANE_W	48.0f
#define LINE_H	2.0f
#define LANE1_Y	(-(R_IN + LANE_W / 2))

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)
static void on_log (void *c, const char *t) { (void)c; fputs (t, stdout); }
static void on_error (void *c, const char *e) { (void)c; if (e) printf("FATAL: %s\n", e); }
static void frames (int n) { int i; for (i = 0; i < n; i++) QC_Frame (1.0/72.0); }
static int alias_batches (void)
{
	const qc_frame_t *f = QC_RendererAcquireFrame ();
	int n = 0; unsigned i;
	if (!f) return -1;
	for (i = 0; i < f->num_batches; i++)
		if (f->batches[i].kind == QC_BATCH_ALIAS) n++;
	QC_RendererReleaseFrame ();
	return n;
}
int main (int argc, char **argv)
{
	int base, wheel, i, reached;
	vec3_t pos;
	if (argc < 2) return 2;
	QC_SetCallbacks (on_log, on_error, NULL);
	QC_SetPaths (argv[1], argv[1]);
	{ const char *a[2] = { "-basedir", argv[1] };
	  if (!QC_Init (2, a)) { printf ("init failed\n"); return 1; } }
	QC_ExecuteCommand ("map range\n");
	frames (120);
	CHECK (sv.active && cls.signon == 4, "range.bsp loads and connects (signon=%d)", cls.signon);
	CHECK (cl.worldmodel && !strcmp (cl.worldmodel->name, "maps/range.bsp"),
	       "worldmodel is the range");
	QC_ExecuteCommand ("notarget\n");
	frames (30);
	base = alias_batches ();
	CHECK (base >= 7, "firing line + rack visible (%d alias batches: 7 monsters + pickups)", base);
	{
		vec3_t org; VectorCopy (svs.clients[0].edict->v.origin, org);
		CHECK (org[2] > 0 && org[2] < 64, "player stands on the floor (z=%.0f)", org[2]);
	}
	QC_ExecuteCommand ("impulse 9\n");
	frames (5);
	QC_ExecuteCommand ("+wheel\n");
	frames (40);
	wheel = alias_batches ();
	CHECK (wheel == base + 8, "wheel rings all 8 over the range (%d -> %d)", base, wheel);
	QC_ExecuteCommand ("-wheel\n");
	frames (40);

	/* The track around the arena, read through the collision hulls rather
	 * than the renderer: the inner kerb is a line brush standing LINE_H
	 * proud at exactly R_IN, and the middle of lane 1 just outside it is
	 * open above its floor. A bend written with slivers, or a lane surface
	 * laid over the arena's own floor, shows up here as the wrong contents. */
	pos[0] = 0; pos[1] = -R_IN; pos[2] = LINE_H / 2;
	CHECK (SV_PointContents (pos) == CONTENTS_SOLID,
	       "a lane line stands proud at lane 1's inner edge (y=%.0f)", pos[1]);
	pos[1] = LANE1_Y; pos[2] = 1;
	CHECK (SV_PointContents (pos) == CONTENTS_EMPTY,
	       "lane 1 itself is open (y=%.0f)", pos[1]);
	pos[2] = -1;
	CHECK (SV_PointContents (pos) == CONTENTS_SOLID, "and floored");

	/* Walkable all the way out: the spawn faces +Y, so holding +back walks
	 * the player south off the arena floor, across the infield, over the
	 * inner kerb and into lane 1 -- about 1000 units. Polled rather than
	 * timed, because host_timescale is still easing back up from the wheel;
	 * the budget is roughly four times the walk at the server's 320 ups cap.
	 * Nothing may block the way, so the infield tiling has to meet the
	 * arena floor flush and the kerb has to be a step, not a wall. */
	QC_ExecuteCommand ("cl_backspeed 400\n");
	QC_ExecuteCommand ("+back\n");
	reached = 0;
	for (i = 0; i < 600 && !reached; i++)
	{
		QC_Frame (1.0/72.0);
		VectorCopy (svs.clients[0].edict->v.origin, pos);
		if (pos[1] <= LANE1_Y)
			reached = 1;
	}
	QC_ExecuteCommand ("-back\n");
	CHECK (reached, "walked out of the arena into lane 1 (y=%.0f after %d frames)",
	       pos[1], i);
	CHECK (pos[2] > 0 && pos[2] < 64, "and is still on the floor out there (z=%.0f)",
	       pos[2]);
	printf (failures ? "\n%d FAILURES\n" : "\nall passed\n", failures);
	return failures ? 1 : 0;
}
