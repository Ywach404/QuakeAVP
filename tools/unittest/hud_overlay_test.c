/*
 * hud_overlay_test.c -- the pure 2D HUD geometry: canvas affine, glyph-cell
 * mapping, and fill/string/pic quad layout. No slot, no textures.
 */
#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)
#define FEQ(a,b) (fabsf((float)(a)-(float)(b)) < 1e-4f)

int main (void)
{
	float	xf[4], uv[4], col[4] = {1,1,1,1};
	float	buf[6 * 9 * 64];
	int	n;

	/* SBAR canvas offsets to the bottom strip; DEFAULT is identity. */
	QR_CanvasXform (CANVAS_SBAR, xf);
	CHECK (FEQ(xf[0],0) && FEQ(xf[1],152) && FEQ(xf[2],1) && FEQ(xf[3],1),
	       "CANVAS_SBAR affine = {0,152,1,1}");
	QR_CanvasXform (CANVAS_DEFAULT, xf);
	CHECK (FEQ(xf[0],0) && FEQ(xf[1],0) && FEQ(xf[2],1) && FEQ(xf[3],1),
	       "CANVAS_DEFAULT affine = {0,0,1,1}");

	/* 'A' == 65 -> col 1, row 4 */
	QR_GlyphCell ('A', uv);
	CHECK (FEQ(uv[0],1.f/16) && FEQ(uv[1],4.f/16) && FEQ(uv[2],2.f/16) && FEQ(uv[3],5.f/16),
	       "glyph 'A' -> cell (1,4)");

	/* Fill at (10,20) 30x40 under SBAR (oy=152): first vertex top-left. */
	QR_CanvasXform (CANVAS_SBAR, xf);
	n = QR_FillVerts (buf, 10, 20, 30, 40, col, xf);
	CHECK (n == 6, "fill = 6 verts");
	CHECK (FEQ(buf[0],10) && FEQ(buf[1],172), "fill TL at (10, 20+152)");
	CHECK (FEQ(buf[9*1+0],40) && FEQ(buf[9*1+1],172), "fill TR x = 10+30");
	CHECK (FEQ(buf[9*2+1],212), "fill BL y = 172+40");

	/* String advances 8 px/char; space emits nothing. */
	QR_CanvasXform (CANVAS_DEFAULT, xf);
	n = QR_StringVerts (buf, 0, 0, "A B", col, xf);	/* 'A', space, 'B' */
	CHECK (n == 12, "\"A B\" -> 2 glyphs * 6 verts (space skipped)");
	CHECK (FEQ(buf[0],0), "first glyph x0 = 0");
	CHECK (FEQ(buf[9*6+0],16), "second glyph x0 = 16 (2 cells advanced)");

	printf ("\n%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
	return failures ? 1 : 0;
}
