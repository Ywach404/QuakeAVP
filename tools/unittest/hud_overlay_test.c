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

	/* String advances 8 px/char; space emits nothing. Buffer is sized to
	   EXACTLY strlen("A B")*6*9 floats and pre-seeded with NaN, so a
	   regression that leaves a gap for the space (e.g. indexing by
	   character instead of by emitted-vertex count) either lands a NaN
	   inside [0, n*9) or overflows the buffer -- it can't silently pass
	   by landing in untouched stack margin. */
	{
		const char	*str = "A B";
		float		sbuf[strlen("A B") * 6 * 9];
		size_t		i;

		for (i = 0; i < sizeof(sbuf) / sizeof(sbuf[0]); i++)
			sbuf[i] = NAN;

		QR_CanvasXform (CANVAS_DEFAULT, xf);
		n = QR_StringVerts (sbuf, 0, 0, str, col, xf);	/* 'A', space, 'B' */
		CHECK (n == 12, "\"A B\" -> 2 glyphs * 6 verts (space skipped)");

		{
			int	all_finite = 1;
			for (i = 0; i < (size_t) n * 9; i++)
				if (isnan(sbuf[i]))
					all_finite = 0;
			CHECK (all_finite, "\"A B\" output is tightly packed (no NaN gap in [0, n*9))");
		}

		CHECK (FEQ(sbuf[0],0), "first glyph x0 = 0");
		CHECK (FEQ(sbuf[9*6+0],16), "second glyph x0 = 16 (2 cells advanced)");
	}

	printf ("\n%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
	return failures ? 1 : 0;
}
