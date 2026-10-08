/*
 * sprite_axes_test.c -- QR_SpriteBillboardAxes yields the upstream up/right
 * billboard basis per SPR_* type, against the view globals. Pure, map-free.
 */
#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>
#include <math.h>

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)
#define VEQ(v,x,y,z) (fabs((v)[0]-(x))<1e-4 && fabs((v)[1]-(y))<1e-4 && fabs((v)[2]-(z))<1e-4)

int main (void)
{
	static entity_t e;
	vec3_t up, right;

	/* a simple view basis: looking +x, right = -y, up = +z */
	vpn[0]=1; vpn[1]=0; vpn[2]=0;
	vright[0]=0; vright[1]=-1; vright[2]=0;
	vup[0]=0; vup[1]=0; vup[2]=1;
	r_refdef.vieworg[0]=r_refdef.vieworg[1]=r_refdef.vieworg[2]=0;

	/* VP_PARALLEL: up=vup, right=vright */
	QR_SpriteBillboardAxes (SPR_VP_PARALLEL, &e, up, right);
	CHECK (VEQ(up,0,0,1) && VEQ(right,0,-1,0), "VP_PARALLEL -> vup/vright");

	/* VP_PARALLEL_UPRIGHT: up=world z, right=vright */
	QR_SpriteBillboardAxes (SPR_VP_PARALLEL_UPRIGHT, &e, up, right);
	CHECK (VEQ(up,0,0,1) && VEQ(right,0,-1,0), "VP_PARALLEL_UPRIGHT -> worldup/vright");

	/* FACING_UPRIGHT: entity at (10,0,0), view at origin -> forward=(1,0,0),
	   right=(forward.y,-forward.x,0)=(0,-1,0), up=worldz */
	e.origin[0]=10; e.origin[1]=0; e.origin[2]=0;
	QR_SpriteBillboardAxes (SPR_FACING_UPRIGHT, &e, up, right);
	CHECK (VEQ(up,0,0,1) && VEQ(right,0,-1,0), "FACING_UPRIGHT -> horizontal facing");

	/* ORIENTED: angles all 0 -> AngleVectors gives forward=(1,0,0),
	   right=(0,-1,0), up=(0,0,1) */
	e.angles[0]=e.angles[1]=e.angles[2]=0;
	QR_SpriteBillboardAxes (SPR_ORIENTED, &e, up, right);
	CHECK (VEQ(up,0,0,1) && VEQ(right,0,-1,0), "ORIENTED angles 0 -> axis basis");

	/* VP_PARALLEL_ORIENTED, roll 0 -> same as VP_PARALLEL */
	e.angles[2] = 0;
	QR_SpriteBillboardAxes (SPR_VP_PARALLEL_ORIENTED, &e, up, right);
	CHECK (VEQ(up,0,0,1) && VEQ(right,0,-1,0), "VP_PARALLEL_ORIENTED roll 0 -> vup/vright");

	/* VP_PARALLEL_ORIENTED, roll 90deg -> right and up rotate in the view plane:
	   right = vright*cos90 + vup*sin90 = vup = (0,0,1);
	   up    = -vright*sin90 + vup*cos90 = -vright = (0,1,0) */
	e.angles[2] = 90;
	QR_SpriteBillboardAxes (SPR_VP_PARALLEL_ORIENTED, &e, up, right);
	CHECK (VEQ(right,0,0,1) && VEQ(up,0,1,0), "VP_PARALLEL_ORIENTED roll 90 -> rolled basis");

	printf ("%s\n", failures ? "UNIT FAIL" : "UNIT PASS");
	return failures ? 1 : 0;
}
