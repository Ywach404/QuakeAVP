/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * lightstyle_test.c -- R_AnimateLight maps cl_lightstyle strings onto
 * d_lightstylevalue. Pure, map-free: set the style and cl.time, call, assert.
 */
#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

/* 'a'=0 (dark) .. 'm'=12 (normal) .. 'z'=25; value is (map[i%len]-'a')*22. */
int main (void)
{
	int j;

	/* empty style stays at default 256 (zeros would bake the world black) */
	memset (cl_lightstyle, 0, sizeof (cl_lightstyle));
	for (j = 0; j < MAX_LIGHTSTYLES; j++) d_lightstylevalue[j] = -1;
	cl.time = 0;
	R_AnimateLight ();
	CHECK (d_lightstylevalue[0] == 256, "empty style -> 256");

	/* a steady 'm' style resolves to normal (12*22 = 264) at any time */
	cl_lightstyle[1].length = 1; cl_lightstyle[1].map[0] = 'm';
	cl.time = 3.7;
	R_AnimateLight ();
	CHECK (d_lightstylevalue[1] == 12 * 22, "steady 'm' -> 264");

	/* a two-frame style 'a''z' alternates on the cl.time*10 clock */
	cl_lightstyle[2].length = 2; cl_lightstyle[2].map[0] = 'a'; cl_lightstyle[2].map[1] = 'z';
	cl.time = 0.0;   R_AnimateLight (); CHECK (d_lightstylevalue[2] == 0,        "'az' @t0 -> 'a'(0)");
	cl.time = 0.1;   R_AnimateLight (); CHECK (d_lightstylevalue[2] == 25 * 22,  "'az' @t0.1 -> 'z'(550)");

	printf ("%s\n", failures ? "UNIT FAIL" : "UNIT PASS");
	return failures ? 1 : 0;
}
