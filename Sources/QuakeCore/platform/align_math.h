/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * align_math.h -- the arithmetic behind room alignment, kept apart from the
 * input layer so the host check can exercise it without a server. Pure
 * functions over a set of weighted directions; no engine headers, no globals.
 */
#ifndef QAVP_ALIGN_MATH_H
#define QAVP_ALIGN_MATH_H

typedef struct {
	float	degrees;	/* direction of a wall's normal, any range */
	float	weight;		/* how much wall; negative is ignored */
} align_dir_t;

/*
 * The dominant direction of a set of walls, modulo 90 degrees.
 *
 * Walls are square to each other far more often than not, so a wall at 90
 * degrees is evidence for the SAME room direction as one at 0 -- which is
 * why this is a weighted circular mean taken at FOUR TIMES the angle. At 4x,
 * directions 90 degrees apart land on top of each other and reinforce, and a
 * perfect rectangle comes out fully confident rather than split between two
 * bins. Returns the mean in [0, 90) through `out_degrees`.
 *
 * `out_confidence` is the resultant's length over the total weight: 1 when
 * every wall agrees (modulo 90), 0 when the evidence cancels -- which is what
 * a round room or two equally strong directions 45 degrees apart look like.
 * Both are what a caller must refuse to act on, so the number matters as much
 * as the angle.
 *
 * Returns 0 and writes nothing when there is no usable weight at all.
 */
int Align_Dominant (const align_dir_t *dirs, int count,
		    float *out_degrees, float *out_confidence);

/*
 * A difference between two directions reduced into (-45, +45]. Beyond 45
 * degrees the next wall of a rectangular room is the better match, so the
 * short way round is the only turn worth making.
 */
float Align_Reduce90 (float degrees);

#endif	/* QAVP_ALIGN_MATH_H */
