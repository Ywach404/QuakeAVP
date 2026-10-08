/*
 * relight_predicate_test.c -- QR_SurfaceNeedsRelight encodes upstream
 * R_RenderDynamicLightmaps's rebuild decision: rebuild iff
 * (a lightstyle value drifted from cache OR a dlight touches the surface)
 * AND r_dynamic is on. r_dynamic 0 freezes the lightmap entirely, matching
 * QuakeSpasm 0.97 (the goto lands inside the r_dynamic gate).
 */
#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

static msurface_t mksurf (void)
{
	msurface_t s; int i;
	memset (&s, 0, sizeof (s));
	for (i = 0; i < MAXLIGHTMAPS; i++) { s.styles[i] = 255; s.cached_light[i] = 0; }
	return s;
}

int main (void)
{
	msurface_t s;
	int fc = 10;

	for (int i = 0; i < 256; i++) d_lightstylevalue[i] = 256;

	/* a static, cached, un-dlit surface does NOT rebuild */
	s = mksurf ();
	s.styles[0] = 0; s.cached_light[0] = 256;
	CHECK (!QR_SurfaceNeedsRelight (&s, fc, 1), "static cached surface: no relight");

	/* a style whose value drifted from the cache DOES rebuild */
	d_lightstylevalue[0] = 128;
	CHECK (QR_SurfaceNeedsRelight (&s, fc, 1), "changed style value: relight");
	d_lightstylevalue[0] = 256;

	/* dlit this frame: relight */
	s = mksurf (); s.styles[0] = 0; s.cached_light[0] = 256;
	s.dlightframe = fc;
	CHECK (QR_SurfaceNeedsRelight (&s, fc, 1), "dlit this frame: relight");

	/* dlit last frame, not now: relight once to clear the dlight */
	s.dlightframe = fc - 1; s.cached_dlight = true;
	CHECK (QR_SurfaceNeedsRelight (&s, fc, 1), "dlight just left: relight to clear");

	/* r_dynamic 0 freezes the lightmap: neither dlights NOR style changes
	   relight (upstream goto lands inside the r_dynamic gate). */
	s = mksurf (); s.styles[0] = 0; s.cached_light[0] = 256; s.dlightframe = fc;
	CHECK (!QR_SurfaceNeedsRelight (&s, fc, 0), "r_dynamic 0: dlight frozen");
	d_lightstylevalue[0] = 100;
	CHECK (!QR_SurfaceNeedsRelight (&s, fc, 0), "r_dynamic 0: style change frozen too");
	d_lightstylevalue[0] = 256;

	/* style-255 sentinel: a surface with only sentinel styles never relights
	   off a style value */
	s = mksurf ();	/* all styles 255 */
	d_lightstylevalue[255] = 1;	/* even if slot 255 drifts, sentinel stops the scan */
	CHECK (!QR_SurfaceNeedsRelight (&s, fc, 1), "style sentinel stops the scan");
	d_lightstylevalue[255] = 256;

	printf ("%s\n", failures ? "UNIT FAIL" : "UNIT PASS");
	return failures ? 1 : 0;
}
