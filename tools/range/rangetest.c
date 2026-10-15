/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * rangetest.c -- boot the engine against the make-check objects, load the
 * range, and assert it exercises what it was built to. Deviceless proof
 * the arena is wired: link against ${TMPDIR}/quakecore-hostbuild/*.o minus
 * hostmain.o (see tools/range/README.md).
 */

#include "quakedef.h"
#include "QuakeCore.h"
#include <stdio.h>
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
	int base, wheel;
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
	printf (failures ? "\n%d FAILURES\n" : "\nall passed\n", failures);
	return failures ? 1 : 0;
}
