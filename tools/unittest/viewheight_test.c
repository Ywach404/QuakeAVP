/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * viewheight_test.c -- the packet carries cl.viewheight so the immersive
 * consumer can find the hull bottom from the eye, and the bridge holds
 * cl_bob at zero while the immersive space is up, restoring whatever it
 * found when the space closes. The saved value is captured once on entry:
 * a second omni frame must not overwrite it with the zero.
 */
#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>
#include <stddef.h>

extern cvar_t cl_bob;
void QR_TestBobGate (int omni);

static int failures;
#define CHECK(cond, ...) do { \
	if (cond) printf ("ok    " __VA_ARGS__); \
	else { printf ("FAIL  " __VA_ARGS__); failures++; } \
	printf ("\n"); } while (0)

_Static_assert (offsetof (qc_frame_t, viewheight) > offsetof (qc_frame_t, world_scale),
		"viewheight follows world_scale on the packet");

int main (void)
{
	cl_bob.value = 0.02f;

	QR_TestBobGate (1);
	CHECK (cl_bob.value == 0.f, "entering the immersive space zeroes cl_bob");
	QR_TestBobGate (1);
	CHECK (cl_bob.value == 0.f, "a second immersive frame keeps it at zero");
	QR_TestBobGate (0);
	CHECK (cl_bob.value == 0.02f, "leaving restores the value found on entry, not the zero");

	QR_TestBobGate (0);
	CHECK (cl_bob.value == 0.02f, "a second non-immersive frame leaves it alone");

	cl_bob.value = 0.05f;	/* an autoexec value */
	QR_TestBobGate (1);
	QR_TestBobGate (0);
	CHECK (cl_bob.value == 0.05f, "an autoexec value round-trips");

	printf ("%s: viewheight_test, %d failure(s)\n", failures ? "FAIL" : "ok  ", failures);
	return failures ? 1 : 0;
}
