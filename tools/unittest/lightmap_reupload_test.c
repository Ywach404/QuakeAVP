/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * lightmap_reupload_test.c -- QR_FlushDirtyLightmaps enqueues an upload for
 * each dirty atlas. Map-free guard: with no map (lightmap_count == 0) it
 * enqueues nothing and must not touch the empty atlas array. The
 * "a dirty atlas actually uploads" path needs a loaded BSP and is covered on
 * device.
 */
#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>

extern int QR_FlushDirtyLightmaps (void);
extern int lightmap_count;

int main (void)
{
	int n;

	lightmap_count = 0;
	n = QR_FlushDirtyLightmaps ();
	printf ("%s: flush with no map enqueued %d\n", n == 0 ? "ok  " : "FAIL", n);
	return n == 0 ? 0 : 1;
}
