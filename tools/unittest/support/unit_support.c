/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * unit_support.c -- app-side stubs the host unit tests need but that live in
 * Swift (AudioSink) at runtime. hostmain.c carries the same four for the link
 * check; the unit harness excludes hostmain.o (for its main) and links this
 * instead. Keep in sync with tools/hostmain.c.
 */
#include "QuakeCore.h"

int QC_AudioOpen (int speed, int channels, int bits,
		  unsigned char **buffer, int *mono_samples)
{
	(void) speed; (void) channels; (void) bits;
	if (buffer) *buffer = 0;
	if (mono_samples) *mono_samples = 0;
	return 0;
}
int  QC_AudioSamplePos (void) { return 0; }
void QC_AudioClose (void) { }
void QC_AudioSetRunning (int running) { (void) running; }
