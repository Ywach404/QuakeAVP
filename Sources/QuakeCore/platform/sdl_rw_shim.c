// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez

/* sdl_rw_shim.c -- see sdl_rw_shim.h */

#include "sdl_rw_shim.h"

#include <stdlib.h>

SDL_RWops *SDL_RWFromFile (const char *file, const char *mode)
{
	SDL_RWops	*rw;
	FILE		*fp;

	if (!file || !mode)
		return NULL;

	fp = fopen (file, mode);
	if (!fp)
		return NULL;

	rw = (SDL_RWops *) malloc (sizeof(SDL_RWops));
	if (!rw)
	{
		fclose (fp);
		return NULL;
	}

	rw->fp = fp;
	return rw;
}

Sint64 SDL_RWsize (SDL_RWops *rw)
{
	long pos, size;

	if (!rw || !rw->fp)
		return -1;

	pos = ftell (rw->fp);
	if (pos < 0)
		return -1;
	if (fseek (rw->fp, 0, SEEK_END) != 0)
		return -1;
	size = ftell (rw->fp);
	if (fseek (rw->fp, pos, SEEK_SET) != 0)
		return -1;

	return (Sint64) size;
}

Sint64 SDL_RWseek (SDL_RWops *rw, Sint64 offset, int whence)
{
	int stdio_whence;

	if (!rw || !rw->fp)
		return -1;

	switch (whence)
	{
	case RW_SEEK_SET: stdio_whence = SEEK_SET; break;
	case RW_SEEK_CUR: stdio_whence = SEEK_CUR; break;
	case RW_SEEK_END: stdio_whence = SEEK_END; break;
	default: return -1;
	}

	if (fseek (rw->fp, (long) offset, stdio_whence) != 0)
		return -1;

	return (Sint64) ftell (rw->fp);
}

Sint64 SDL_RWtell (SDL_RWops *rw)
{
	if (!rw || !rw->fp)
		return -1;
	return (Sint64) ftell (rw->fp);
}

size_t SDL_RWread (SDL_RWops *rw, void *ptr, size_t size, size_t maxnum)
{
	if (!rw || !rw->fp || size == 0)
		return 0;
	return fread (ptr, size, maxnum, rw->fp);
}

int SDL_RWclose (SDL_RWops *rw)
{
	int rc = 0;

	if (!rw)
		return -1;
	if (rw->fp)
		rc = fclose (rw->fp);
	free (rw);
	return rc;
}
