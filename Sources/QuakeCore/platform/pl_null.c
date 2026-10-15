/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * pl_null.c -- platform.h services, replacing pl_linux.c (X11) / pl_win.c.
 */

#include "quakedef.h"

void PL_SetWindowIcon (void)
{
	/* The app icon comes from the asset catalog. */
}

void PL_VID_Shutdown (void)
{
}

char *PL_GetClipboardData (void)
{
	/* UIPasteboard is main-actor-only; route through Swift if the console
	   ever needs paste. */
	return NULL;
}

void PL_ErrorDialog (const char *text)
{
	/* Sys_Error already forwarded this to the Swift error callback, which
	   owns presenting it. */
	(void) text;
}
