/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * screen2d_test.c -- the menu/console half of the 2D layer: the CANVAS_MENU
 * and CANVAS_CONSOLE affines, the Draw_CachePic wrapper cache, and
 * QR_EmitScreen2D's overlay vertex range.
 *
 * The affine checks are pure (globals in, four floats out). The cache and
 * range checks go through the QAVP_HOSTCHECK hooks, which drive the real
 * code paths -- see QR_TestCachePicSlot / QR_TestEmitScreen2DInto in
 * qr_bridge.c for what they do and do not fake.
 */
#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)
#define FEQ(a,b) (fabsf((float)(a)-(float)(b)) < 1e-4f)

/* ------------------------------------------------------------------ affines
 * CANVAS_MENU is the identity: menu.c already draws in the overlay plane's
 * own 320x200 coordinates. CANVAS_CONSOLE scales vid.conwidth/conheight onto
 * that plane and carries upstream's console SLIDE offset, which is what puts
 * Con_DrawNotify's lines (drawn at y = vid.conheight) at the TOP of the
 * panel while the console itself is down.
 */
static void test_affines (void)
{
	float	xf[4], buf[6 * 9];

	/* Unchanged canvases first: the existing HUD path must not move. */
	QR_CanvasXform (CANVAS_SBAR, xf);
	CHECK (FEQ(xf[0],0) && FEQ(xf[1],152) && FEQ(xf[2],1) && FEQ(xf[3],1),
	       "CANVAS_SBAR affine still {0,152,1,1}");
	QR_CanvasXform (CANVAS_DEFAULT, xf);
	CHECK (FEQ(xf[0],0) && FEQ(xf[1],0) && FEQ(xf[2],1) && FEQ(xf[3],1),
	       "CANVAS_DEFAULT affine still {0,0,1,1}");

	QR_CanvasXform (CANVAS_MENU, xf);
	CHECK (FEQ(xf[0],0) && FEQ(xf[1],0) && FEQ(xf[2],1) && FEQ(xf[3],1),
	       "CANVAS_MENU affine = identity (menu.c draws in 320x200)");

	/* The shipped console canvas: 640x400 -> 320x200, an exact half. */
	vid.conwidth = 640;
	vid.conheight = 400;
	glheight = 720;

	scr_con_current = (float) glheight;	/* console fully down */
	QR_CanvasXform (CANVAS_CONSOLE, xf);
	CHECK (FEQ(xf[2],0.5f) && FEQ(xf[3],0.5f),
	       "CANVAS_CONSOLE scales 640x400 by 0.5");
	CHECK (FEQ(xf[0],0) && FEQ(xf[1],0),
	       "CANVAS_CONSOLE full-down slide offset = 0");

	scr_con_current = 0.f;			/* console up: notify lines only */
	QR_CanvasXform (CANVAS_CONSOLE, xf);
	CHECK (FEQ(xf[1],-200),
	       "CANVAS_CONSOLE slide offset = -200 with the console up");
	/* The property that offset exists for: Con_DrawNotify's first line sits
	   at y == vid.conheight, which must land on the panel's TOP edge. */
	{
		float	uv[4] = {0,0,1,1}, col[4] = {1,1,1,1};

		QR_PicVerts (buf, 0, vid.conheight, 8, 8, uv, col, xf);
		CHECK (FEQ(buf[1],0),
		       "notify line at y=conheight lands at panel y=0");
	}

	/* Computed from vid.conwidth, never a literal: the same function has to
	   follow the canvas if the nominal console size ever changes. */
	vid.conwidth = 1280;
	vid.conheight = 720;
	scr_con_current = (float) glheight;
	QR_CanvasXform (CANVAS_CONSOLE, xf);
	CHECK (FEQ(xf[2],320.f/1280.f) && FEQ(xf[3],200.f/720.f),
	       "CANVAS_CONSOLE scale tracks vid.conwidth/conheight (1280x720)");

	/* A zero glheight must not divide by zero. */
	glheight = 0;
	scr_con_current = 0.f;
	QR_CanvasXform (CANVAS_CONSOLE, xf);
	CHECK (isfinite (xf[0]) && isfinite (xf[1]) && isfinite (xf[2]) && isfinite (xf[3]),
	       "CANVAS_CONSOLE survives glheight 0 (no divide by zero)");

	glheight = 720;
	vid.conwidth = 640;
	vid.conheight = 400;
}

/* --------------------------------------------------------- emitted range
 * QR_EmitScreen2D appends to the SAME overlay buffer the HUD emitters have
 * already filled, and publishes the sub-range it wrote so the HUD consumers
 * can leave it alone. The hook below drives the real emitter over a test
 * slot, after laying down a known prefix of fills to stand in for the HUD.
 */
extern void QR_TestEmitScreen2DInto (int kdest, int prefix_quads, int prefix_x,
				     uint32_t *first, uint32_t *count,
				     uint32_t *total, float *prefix_first_x);

static void test_range (void)
{
	uint32_t	first, count, total;
	float		prefix_x;

	/* key_game, nothing pending: the emitter runs (notify lines) but has
	   nothing to say, so the range is empty and sits at the end. */
	QR_TestEmitScreen2DInto (key_game, 3, 7, &first, &count, &total, &prefix_x);
	CHECK (count == 0, "key_game with no notify lines emits no screen2d verts");
	CHECK (first == 18, "empty range still starts past the 3-quad prefix");
	CHECK (total == 18, "empty emit leaves the overlay buffer at the prefix");

	/* key_menu: M_Draw runs. The host fixture has no filesystem, so every
	   Draw_CachePic misses and the menu's art emits nothing -- the one
	   thing that does draw is Draw_FadeScreen's single quad, which is
	   exactly the "now real" body this round added. Six verts, therefore,
	   and the assertion is deterministic for that reason. */
	QR_TestEmitScreen2DInto (key_menu, 3, 7, &first, &count, &total, &prefix_x);
	CHECK (first == 18, "screen2d range starts after the HUD prefix");
	CHECK (count == 6, "menu emit = Draw_FadeScreen's one quad (no art in the fixture)");
	CHECK (first + count == total, "range ends at the end of the overlay buffer");
	CHECK (FEQ(prefix_x, 7), "the HUD prefix's verts are untouched by the emit");

	/* No prefix at all -- the no-world frame, where V_RenderView returned
	   before any HUD emitter ran. The range must start at zero, not at
	   whatever the last frame left behind. */
	QR_TestEmitScreen2DInto (key_menu, 0, 0, &first, &count, &total, &prefix_x);
	CHECK (first == 0 && count == 6, "no-world frame emits from vert 0");

	/* scr_con_current must be back at 0 when the emitter returns. It is
	   live only for the draws inside it, and the reader that matters is in
	   the engine: sbar.c's Sbar_Draw opens with
	   `if (scr_con_current == vid.height) return;`, which has never fired
	   in this port and must not start -- it compares against vid.height
	   (pinned 720) while the emitter writes glheight (the live drawable),
	   so a leaked value would blank the vr_hud 1/2 status bar on exactly
	   the configurations where those two numbers coincide. */
	scr_con_current = 12345.f;
	QR_TestEmitScreen2DInto (key_console, 0, 0, &first, &count, &total, &prefix_x);
	CHECK (FEQ(scr_con_current, 0),
	       "the emitter leaves scr_con_current at 0 (Sbar_Draw's guard stays dormant)");
}

/* ------------------------------------------------------------- pic cache
 * Draw_CachePic's wrapper cache. The host fixture has no filesystem, so the
 * load always fails; what is under test is the bookkeeping around it and the
 * storage's lifetime, which is the reason this cache exists at all.
 */
extern const void *QR_TestCachePicSlot (const char *path, int *is_new);
extern qpic_t *QR_TestCachePicPut (const char *path, int w, int h);
extern int QR_TestCachePicCount (void);

static void test_cache (void)
{
	const void	*a, *b;
	int		is_new;
	qpic_t		*pic, *again;

	QR_DrawNewGame ();		/* empty cache */
	CHECK (QR_TestCachePicCount () == 0, "QR_DrawNewGame empties the cache");

	a = QR_TestCachePicSlot ("gfx/qplaque.lmp", &is_new);
	CHECK (is_new == 1, "first lookup of a name inserts");
	b = QR_TestCachePicSlot ("gfx/qplaque.lmp", &is_new);
	CHECK (is_new == 0 && a == b, "repeat name returns the same slot, no insert");
	b = QR_TestCachePicSlot ("gfx/ttl_main.lmp", &is_new);
	CHECK (is_new == 1 && a != b, "a different name gets its own slot");
	CHECK (QR_TestCachePicCount () == 2, "two names, two entries");

	/* A name that cannot load is remembered as a miss, so the complaint is
	   printed once rather than once per frame for the rest of the session. */
	QR_DrawNewGame ();
	CHECK (QR_DrawCachePic ("gfx/absent.lmp") == NULL, "missing art returns NULL");
	CHECK (QR_TestCachePicCount () == 1, "a failed load still takes an entry");
	CHECK (QR_DrawCachePic ("gfx/absent.lmp") == NULL, "missing art stays NULL");
	CHECK (QR_TestCachePicCount () == 1, "the second miss does not re-insert");

	/* The bound is upstream's. Fill it exactly; the overflow leg beyond it
	   is upstream's Sys_Error and so is not exercised here. */
	QR_DrawNewGame ();
	{
		int	i;
		char	name[64];

		for (i = 0; i < 128; i++)
		{
			snprintf (name, sizeof (name), "gfx/fill%d.lmp", i);
			QR_TestCachePicSlot (name, &is_new);
		}
		CHECK (QR_TestCachePicCount () == 128, "cache fills to 128 entries");
		QR_TestCachePicSlot ("gfx/fill0.lmp", &is_new);
		CHECK (is_new == 0, "an early name still hits at full capacity");
	}

	/* The lifetime property, and the point of the whole cache: the wrapper
	   must survive the hunk being thrown away on a map change. Simulated by
	   its operative step -- Hunk_FreeToLowMark, which is what
	   Host_ClearMemory does to everything Hunk_Alloc handed out -- followed
	   by a fresh allocation, since Hunk_Alloc zeroes what it hands back and
	   would therefore blank a wrapper living in the reused space.
	   Runs LAST in this file: it leaves the hunk wiped. */
	QR_DrawNewGame ();
	pic = QR_TestCachePicPut ("gfx/sp_menu.lmp", 232, 112);
	CHECK (pic && pic->width == 232 && pic->height == 112, "a loaded entry reads back");

	/* The fresh allocation starts at the bottom of the now-empty low hunk,
	   i.e. over the first thing the engine ever Hunk_Alloc'd, and
	   Hunk_AllocName zeroes what it returns -- so a wrapper that had been
	   living on the hunk reads back as 0x0 here. */
	Hunk_FreeToLowMark (0);
	(void) Hunk_Alloc (128 * 1024);

	CHECK (pic->width == 232 && pic->height == 112,
	       "the cached wrapper survives a hunk wipe");
	again = QR_DrawCachePic ("gfx/sp_menu.lmp");
	CHECK (again == pic, "the same wrapper is still served after the wipe");
}

int main (void)
{
	test_affines ();
	test_range ();
	test_cache ();

	printf ("\n%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
	return failures ? 1 : 0;
}
