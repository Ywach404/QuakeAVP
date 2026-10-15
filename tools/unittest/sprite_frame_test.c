/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * sprite_frame_test.c -- QR_SpriteFrameSelect picks the mspriteframe for a
 * frame index, resolving animated groups by time. Pure (no Mod_Extradata /
 * cache), so a hand-rolled msprite_t is safe here.
 */
#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

int main (void)
{
	static mspriteframe_t fa, fb0, fb1;
	static float ivals[2] = { 0.1f, 0.2f };
	/* mspritegroup_t has frames[1]; make room for frames[2]. */
	static char gbuf[sizeof(mspritegroup_t) + sizeof(mspriteframe_t *)];
	mspritegroup_t *grp = (mspritegroup_t *)gbuf;
	/* msprite_t has frames[1]; make room for frames[2]. */
	static char sbuf[sizeof(msprite_t) + sizeof(mspriteframedesc_t)];
	msprite_t *ps = (msprite_t *)sbuf;
	mspriteframe_t *got;

	grp->numframes = 2;
	grp->intervals = ivals;
	grp->frames[0] = &fb0;
	grp->frames[1] = &fb1;

	ps->type = SPR_VP_PARALLEL;
	ps->numframes = 2;
	ps->frames[0].type = SPR_SINGLE;
	ps->frames[0].frameptr = &fa;
	ps->frames[1].type = SPR_GROUP;
	ps->frames[1].frameptr = (mspriteframe_t *)grp;

	/* out-of-range frame clamps to frame 0 (SINGLE fa) */
	got = QR_SpriteFrameSelect (ps, 99, 0.f);
	CHECK (got == &fa, "out-of-range frame clamps to frame 0");

	/* SINGLE frame returns its frameptr */
	got = QR_SpriteFrameSelect (ps, 0, 0.f);
	CHECK (got == &fa, "SINGLE frame -> frameptr");

	/* GROUP: targettime < 0.1 selects subframe 0 */
	got = QR_SpriteFrameSelect (ps, 1, 0.05f);
	CHECK (got == &fb0, "group @t0.05 -> subframe 0");

	/* GROUP: 0.1 <= targettime < 0.2 selects subframe 1 */
	got = QR_SpriteFrameSelect (ps, 1, 0.15f);
	CHECK (got == &fb1, "group @t0.15 -> subframe 1");

	/* GROUP wraps on the full interval: t = 0.2 + 0.05 -> subframe 0 again */
	got = QR_SpriteFrameSelect (ps, 1, 0.25f);
	CHECK (got == &fb0, "group @t0.25 wraps -> subframe 0");

	/* REGRESSION: QR_SpriteFrame must read model->cache.data DIRECTLY, not via
	   Mod_Extradata. Sprite extradata is a plain Hunk pointer in cache.data;
	   Mod_Extradata would run Cache_Check, which walks a bogus cache header in
	   front of it and CRASHES. This test reproduces that path -- it crashed the
	   process before the fix, and must now return the frame cleanly. */
	{
		static qmodel_t mdl;
		static entity_t e;
		mdl.cache.data = ps;		/* plain pointer, NOT a Cache_Alloc entry */
		strcpy (mdl.name, "progs/s_explod.spr");
		e.model = &mdl;
		e.frame = 0;
		e.syncbase = 0;
		cl.time = 0;
		got = QR_SpriteFrame (&e);	/* crashed here before the fix */
		CHECK (got == &fa, "QR_SpriteFrame reads cache.data directly (no Mod_Extradata)");
	}

	printf ("%s\n", failures ? "UNIT FAIL" : "UNIT PASS");
	return failures ? 1 : 0;
}
