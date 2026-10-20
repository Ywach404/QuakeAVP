/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * room_align_test.c -- the weighted circular mean and the 90-degree
 * reduction behind room alignment. The cases that matter are the ones where
 * the right answer is to do NOTHING: a round room, two directions of equal
 * strength, no evidence at all. A wrong turn here is a 45-degree lurch in a
 * headset.
 */
#include "align_math.h"
#include <stdio.h>
#include <math.h>

static int failures;
#define CHECK(cond, ...) do { \
	if (cond) printf ("ok    " __VA_ARGS__); \
	else { printf ("FAIL  " __VA_ARGS__); failures++; } \
	printf ("\n"); } while (0)

static int near (float a, float b, float tol)
{
	return fabsf (a - b) <= tol;
}

/* Same direction modulo 90, so 2 and 92 are one answer, not two. */
static int near90 (float a, float b, float tol)
{
	float d = fmodf (a - b, 90.f);
	if (d > 45.f) d -= 90.f;
	if (d < -45.f) d += 90.f;
	return fabsf (d) <= tol;
}

int main (void)
{
	float deg, conf;

	/* A clean rectangle: four walls, two directions 90 apart. At 4x angle
	   they coincide, so this is the fully-confident case -- a naive bin
	   would split it in half and refuse. */
	{
		align_dir_t room[4] = {
			{  0.f, 6.f }, { 90.f, 4.f }, { 180.f, 6.f }, { 270.f, 4.f },
		};
		CHECK (Align_Dominant (room, 4, &deg, &conf), "a rectangle has a direction");
		CHECK (near90 (deg, 0.f, 0.5f), "...and it is the wall direction (got %.2f)", deg);
		CHECK (near (conf, 1.f, 0.01f), "...at full confidence (got %.3f)", conf);
	}

	/* The same rectangle turned 20 degrees. */
	{
		align_dir_t room[4] = {
			{ 20.f, 6.f }, { 110.f, 4.f }, { 200.f, 6.f }, { 290.f, 4.f },
		};
		CHECK (Align_Dominant (room, 4, &deg, &conf)
		       && near90 (deg, 20.f, 0.5f),
		       "a rectangle at 20 degrees reads 20 (got %.2f)", deg);
		CHECK (near (conf, 1.f, 0.01f), "...still fully confident (got %.3f)", conf);
	}

	/* The answer is always reported in [0, 90). */
	{
		align_dir_t room[2] = { { 183.f, 5.f }, { 273.f, 5.f } };
		CHECK (Align_Dominant (room, 2, &deg, &conf)
		       && deg >= 0.f && deg < 90.f && near (deg, 3.f, 0.5f),
		       "the result is folded into [0,90) (got %.2f)", deg);
	}

	/* One dominant wall and three small ones at a different angle: the big
	   wall wins, which is the whole reason weight is area and not count. */
	{
		align_dir_t room[4] = {
			{  0.f, 12.f }, { 30.f, 1.f }, { 31.f, 1.f }, { 29.f, 1.f },
		};
		CHECK (Align_Dominant (room, 4, &deg, &conf)
		       && near90 (deg, 0.f, 8.f),
		       "one dominant wall outvotes three small ones (got %.2f)", deg);
		CHECK (conf > 0.5f, "...with confidence left over (got %.3f)", conf);
	}

	/* Two directions of equal weight 45 degrees apart: there is no answer,
	   and the confidence has to say so. */
	{
		align_dir_t room[2] = { { 0.f, 5.f }, { 45.f, 5.f } };
		Align_Dominant (room, 2, &deg, &conf);
		CHECK (near (conf, 0.f, 0.01f),
		       "two equal directions 45 apart cancel (conf %.3f)", conf);
	}

	/* A round room: normals spread evenly all the way round. */
	{
		align_dir_t room[12];
		int i;
		for (i = 0; i < 12; i++)
		{
			room[i].degrees = i * 30.f;
			room[i].weight = 2.f;
		}
		Align_Dominant (room, 12, &deg, &conf);
		CHECK (conf < 0.2f, "a round room has no direction (conf %.3f)", conf);
	}

	/* Nothing to go on. */
	CHECK (!Align_Dominant (NULL, 0, &deg, &conf), "no walls is a refusal");
	{
		align_dir_t none[2] = { { 10.f, 0.f }, { 40.f, -3.f } };
		CHECK (!Align_Dominant (none, 2, &deg, &conf),
		       "zero and negative weights are a refusal");
	}

	/* A single wall is a direction, fully confident. */
	{
		align_dir_t one[1] = { { 37.f, 3.f } };
		CHECK (Align_Dominant (one, 1, &deg, &conf)
		       && near90 (deg, 37.f, 0.5f) && near (conf, 1.f, 0.01f),
		       "a single wall answers with full confidence (got %.2f conf %.3f)",
		       deg, conf);
	}

	/* The reduction: the short way round, and the boundary resolved up. */
	CHECK (near (Align_Reduce90 (0.f), 0.f, 0.001f), "0 reduces to 0");
	CHECK (near (Align_Reduce90 (10.f), 10.f, 0.001f), "10 reduces to 10");
	CHECK (near (Align_Reduce90 (46.f), -44.f, 0.001f),
	       "46 reduces the short way to -44 (got %.2f)", Align_Reduce90 (46.f));
	CHECK (near (Align_Reduce90 (-46.f), 44.f, 0.001f),
	       "-46 reduces to +44 (got %.2f)", Align_Reduce90 (-46.f));
	CHECK (near (Align_Reduce90 (45.f), 45.f, 0.001f), "45 stays 45");
	CHECK (near (Align_Reduce90 (-45.f), 45.f, 0.001f),
	       "-45 resolves to +45 (got %.2f)", Align_Reduce90 (-45.f));
	CHECK (near (Align_Reduce90 (90.f), 0.f, 0.001f), "90 is no turn at all");
	CHECK (near (Align_Reduce90 (-350.f), 10.f, 0.001f),
	       "-350 reduces to 10 (got %.2f)", Align_Reduce90 (-350.f));
	CHECK (fabsf (Align_Reduce90 (1234.5f)) <= 45.f,
	       "any input lands inside the band (got %.2f)", Align_Reduce90 (1234.5f));

	printf ("%s: room_align_test, %d failure(s)\n", failures ? "FAIL" : "ok  ", failures);
	return failures ? 1 : 0;
}
