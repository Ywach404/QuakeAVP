/*
 * sdl_rw_shim.h -- the 6 SDL_RWops calls common.c makes, over stdio.
 *
 * LOC_LoadFile reads the rerelease localization file through SDL_RWops so
 * miniz can seek inside QuakeEX.kpf, which is a zip. (quakespasm.pak is NOT:
 * it is a classic PACK archive and COM_LoadPackFile reads it over plain
 * stdio.) Those six calls are the only SDL dependency left anywhere in the
 * vendored core -- everything else was in the SDL video/audio/input drivers
 * we dropped.
 * Rather than patch common.c (and re-patch it on every upstream merge), this
 * reimplements the tiny slice of the RWops API it touches.
 *
 * Not a general SDL_RWops: no memory RWops, no writing, no refcounting.
 */

#ifndef QAVP_SDL_RW_SHIM_H
#define QAVP_SDL_RW_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef int64_t	Sint64;
typedef int32_t	Sint32;

#ifndef SDLCALL
#define SDLCALL
#endif

/*
 * common.c has two `#ifdef USE_SDL2` branches around the RWops calls: the
 * SDL-1.2 path rolls its own SDL_RWsize() and treats SDL_RWread()'s return as
 * signed. This shim implements the SDL2 spellings, so declare that dialect.
 * The other two USE_SDL2 sites (quakedef.h, miniz.h) are already inside
 * QAVP_PLATFORM guards and never see it.
 */
#ifndef USE_SDL2
#define USE_SDL2 1
#endif

#define RW_SEEK_SET	0
#define RW_SEEK_CUR	1
#define RW_SEEK_END	2

/* common.c only ever holds this as an opaque pointer. */
typedef struct SDL_RWops
{
	FILE *fp;
} SDL_RWops;

SDL_RWops *SDL_RWFromFile (const char *file, const char *mode);
Sint64	SDL_RWsize (SDL_RWops *rw);
Sint64	SDL_RWseek (SDL_RWops *rw, Sint64 offset, int whence);
Sint64	SDL_RWtell (SDL_RWops *rw);
size_t	SDL_RWread (SDL_RWops *rw, void *ptr, size_t size, size_t maxnum);
int	SDL_RWclose (SDL_RWops *rw);

#endif /* QAVP_SDL_RW_SHIM_H */
