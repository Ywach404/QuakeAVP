/*
 * fog_test.c -- Fog_Update/GetDensity/GetColor fade lerp, and Fog_Parse-
 * ServerMessage's svc_fog byte decode (density/255, rgb/255, short time/100).
 */
#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>
#include <math.h>

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)
#define FEQ(a,b) (fabs((a)-(b)) < 1e-4)

int main (void)
{
	float *c;

	/* instant set (time 0): density/color are exactly what was set */
	cl.time = 10.0;
	Fog_Update (0.5f, 0.2f, 0.3f, 0.4f, 0.0f);
	CHECK (FEQ(Fog_GetDensity(), 0.5f), "instant density");
	c = Fog_GetColor ();
	CHECK (FEQ(c[0],0.2f) && FEQ(c[1],0.3f) && FEQ(c[2],0.4f), "instant color");

	/* fade from 0.5 to 0.1 over 2s starting at t=10. Fog_GetDensity uses
	   f*old + (1-f)*new, f=(fade_done-cl.time)/fade_time. */
	Fog_Update (0.1f, 0.0f, 0.0f, 0.0f, 2.0f);
	cl.time = 10.0;  CHECK (FEQ(Fog_GetDensity(), 0.5f), "fade start -> old density");
	cl.time = 12.0;  CHECK (FEQ(Fog_GetDensity(), 0.1f), "fade end -> new density");
	cl.time = 11.0;  CHECK (FEQ(Fog_GetDensity(), 0.3f), "fade mid -> halfway density");
	cl.time = 99.0;  CHECK (FEQ(Fog_GetDensity(), 0.1f), "past fade -> new density");

	/* svc_fog decode via a crafted message buffer. */
	{
		static byte buf[16];
		int n = 0;
		buf[n++] = 128;			/* density -> 128/255 */
		buf[n++] = 255;			/* r -> 1.0 */
		buf[n++] = 0;			/* g -> 0.0 */
		buf[n++] = 64;			/* b -> 64/255 */
		buf[n++] = 100 & 0xff;		/* time short low (100 -> 1.0s) */
		buf[n++] = (100 >> 8) & 0xff;	/* time short high */
		net_message.data = buf;
		net_message.cursize = n;
		net_message.maxsize = sizeof(buf);
		MSG_BeginReading ();
		cl.time = 0.0;
		Fog_ParseServerMessage ();
		cl.time = 1.0;			/* past the 1s fade -> new values */
		CHECK (FEQ(Fog_GetDensity(), 128.0f/255.0f), "svc_fog density decode");
		c = Fog_GetColor ();
		CHECK (FEQ(c[0],1.0f) && FEQ(c[1],0.0f) && FEQ(c[2],64.0f/255.0f), "svc_fog color decode");
	}

	printf ("%s\n", failures ? "UNIT FAIL" : "UNIT PASS");
	return failures ? 1 : 0;
}
