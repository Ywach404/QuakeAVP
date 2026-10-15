/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * dlight_shim_test.c -- QR_DlightMarkOrigin relocates the local player's
 * dlight (muzzle flash) to the hand under hand aim; everything else is marked
 * from its own origin. Map-free: QR_HandOrigin works off zeroed view state.
 */
#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>
#include <string.h>

extern int qr_aim_active;		/* in_null.c */
extern int QR_HandOrigin (vec3_t out);	/* in_null.c */

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

int main (void)
{
	dlight_t dl;
	vec3_t out;

	cl.viewentity = 1;

	/* a world dlight (not the player) is always marked from its own origin */
	memset (&dl, 0, sizeof (dl));
	dl.key = 7; dl.origin[0] = 100; dl.origin[1] = 200; dl.origin[2] = 300;
	qr_aim_active = 1;
	QR_DlightMarkOrigin (&dl, out);
	CHECK (out[0] == 100 && out[1] == 200 && out[2] == 300, "world dlight keeps its origin");

	/* the player-keyed dlight with aim OFF keeps its (chest) origin */
	dl.key = cl.viewentity;
	qr_aim_active = 0;
	QR_DlightMarkOrigin (&dl, out);
	CHECK (out[0] == 100 && out[1] == 200 && out[2] == 300, "player dlight, aim off -> chest origin");

	/* the player-keyed dlight with aim ON is relocated (no longer the chest).
	   Exact hand origin depends on the view basis; assert only that the shim
	   fired, i.e. the origin changed, OR the hand was unavailable. */
	qr_aim_active = 1;
	QR_DlightMarkOrigin (&dl, out);
	CHECK (!(out[0] == 100 && out[1] == 200 && out[2] == 300) || QR_HandOrigin (out) == 0,
	       "player dlight, aim on -> relocated to hand");

	/* a keyless dlight (key 0 -- explosions, temp-entity lights) must NOT
	   relocate even if cl.viewentity is 0 (before connect / between maps).
	   Otherwise every explosion snaps to the hand. */
	cl.viewentity = 0;
	dl.key = 0; dl.origin[0] = 100; dl.origin[1] = 200; dl.origin[2] = 300;
	qr_aim_active = 1;
	QR_DlightMarkOrigin (&dl, out);
	CHECK (out[0] == 100 && out[1] == 200 && out[2] == 300,
	       "keyless dlight with viewentity 0 -> NOT relocated");

	printf ("%s\n", failures ? "UNIT FAIL" : "UNIT PASS");
	return failures ? 1 : 0;
}
