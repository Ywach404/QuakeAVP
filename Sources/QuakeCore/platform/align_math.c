/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * align_math.c -- see align_math.h. Deliberately free of engine headers so
 * the host check can link it on its own and so nothing here can reach into
 * engine state; the input layer passes it numbers and acts on what it says.
 */
#include "align_math.h"

#include <math.h>

#ifndef M_PI
#define M_PI	3.14159265358979323846
#endif

int Align_Dominant (const align_dir_t *dirs, int count,
		    float *out_degrees, float *out_confidence)
{
	double	sx = 0.0, sy = 0.0, total = 0.0;
	double	mag, mean;
	int	i;

	if (!dirs || count <= 0)
		return 0;

	for (i = 0; i < count; i++)
	{
		double w = dirs[i].weight;
		double a;

		/* Nothing that is not a finite positive number gets a vote.
		   This is a public C API (QC_SetRoomWalls) and every gate
		   downstream is a `less than a threshold` compare, which a NaN
		   passes -- and the end of that road is a NaN written into the
		   body heading, where it is unrecoverable because the guard
		   that adopts a server setangle compares against it too. An
		   infinity is just as bad: it makes the resultant and the total
		   both infinite and their ratio a NaN. */
		if (!(w > 0.0) || !isfinite (w) || !isfinite (dirs[i].degrees))
			continue;
		/* FOUR times the angle: the period of "which way does this
		   room run" is 90 degrees, not 360, and quadrupling turns that
		   into a full circle where the ordinary circular mean works. */
		a = 4.0 * (double) dirs[i].degrees * M_PI / 180.0;
		sx += w * cos (a);
		sy += w * sin (a);
		total += w;
	}

	if (total <= 0.0)
		return 0;

	mag = sqrt (sx * sx + sy * sy);
	if (out_confidence)
		*out_confidence = (float) (mag / total);

	/* With the evidence fully cancelled there is no mean to report. The
	   confidence above already says so; the angle is returned as zero so a
	   caller that ignores it is not handed a number made of rounding. */
	if (mag <= 1e-9)
	{
		if (out_degrees)
			*out_degrees = 0.f;
		return 1;
	}

	mean = atan2 (sy, sx) * 180.0 / M_PI / 4.0;	/* back down from 4x */
	mean = fmod (mean, 90.0);
	if (mean < 0.0)
		mean += 90.0;
	if (mean >= 90.0)		/* fmod of a value just under 90 */
		mean = 0.0;
	if (out_degrees)
		*out_degrees = (float) mean;
	return 1;
}

float Align_Reduce90 (float degrees)
{
	float r = fmodf (degrees, 90.f);

	if (r > 45.f)
		r -= 90.f;
	else if (r <= -45.f)
		r += 90.f;
	return r;
}
