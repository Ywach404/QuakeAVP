/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * grapple_capability_test.c -- how the hook classifies a game's T_Damage,
 * which is the whole content of the capability line it prints on the first
 * engage after a progs change.
 *
 * Three states, not two, and that is the point. `grapple_damage` is a single
 * func_t that is 0 both for "this progs has no T_Damage at all" and for "it
 * has one whose arguments are not the four we would pass", because the arity
 * guard deliberately treats an unexpected signature as a missing function
 * rather than calling it. Those are a game that simply does not support the
 * feature and a mod that would be dangerous to call, and in the headset they
 * are told apart by exactly one thing: this classification.
 *
 * Only the resolved branch is reachable from any game data this project can
 * test against -- every pack here is id1-derived and every one of them
 * defines T_Damage with four parameters -- so the other two branches have no
 * coverage anywhere except here. That is the reason this file exists.
 *
 * Pure: an int in, a state out. No progs, no world, no cvars.
 */
#include "quakedef.h"
#include "QuakeCore.h"
#include <stdio.h>

/* grapple_avp.c keeps the classifier static and exposes this wrapper under
   QAVP_HOSTCHECK, the way it already exposes Grapple_TestAnchorFromTrace. */
int Grapple_TestDamageState (int parms);

/* The grapple_damage_state_t ordering, which the wrapper returns as an int. */
#define STATE_OK	0
#define STATE_ABSENT	1
#define STATE_ARITY	2

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

int main (void)
{
	/* The one the five shipping packs all land in. */
	CHECK (Grapple_TestDamageState (4) == STATE_OK,
	       "four arguments is the T_Damage we can call");

	/* -1 is what the resolver leaves behind when the name is not in the
	   progs at all, and it must not read as an arity complaint: a game
	   without the function is not a broken game. */
	CHECK (Grapple_TestDamageState (-1) == STATE_ABSENT,
	       "a progs with no T_Damage reads as absent, not as wrong arity");

	/* The case the whole three-way split exists for. A mod whose T_Damage
	   takes a fifth deathtype argument would have it read out of whatever
	   OFS_PARM4 happened to hold, so the hook declines to call it -- and
	   must say something different from "this game has no T_Damage",
	   because here the function is right there and is being refused. */
	CHECK (Grapple_TestDamageState (5) == STATE_ARITY,
	       "a five-argument T_Damage reads as wrong arity, not as absent");
	CHECK (Grapple_TestDamageState (3) == STATE_ARITY,
	       "and so does a three-argument one");

	/* Zero parameters is a real dfunction_t value and is not the same
	   thing as the -1 the resolver uses for "never found", so the two must
	   not collapse: the boundary is between negative and non-negative, not
	   between zero and non-zero. A sign test written as a truth test would
	   call this one absent. */
	CHECK (Grapple_TestDamageState (0) == STATE_ARITY,
	       "a T_Damage taking nothing is present and refused, not absent");

	printf (failures ? "\n%d FAILURES\n" : "\nall passed\n", failures);
	return failures ? 1 : 0;
}
