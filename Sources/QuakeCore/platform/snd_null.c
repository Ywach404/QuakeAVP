/*
 * snd_null.c -- audio output stub, replacing snd_sdl.c.
 *
 * snd_dma.c / snd_mix.c (the actual Quake mixer) are compiled in and fully
 * functional; only the device sink is missing. M5 swaps this for an
 * AVAudioEngine source node feeding an AVAudioEnvironmentNode for HRTF.
 *
 * Returning false from SNDDMA_Init() makes S_Init() disable sound cleanly
 * rather than mixing into a buffer nobody reads.
 */

#include "quakedef.h"

qboolean SNDDMA_Init (dma_t *dma)
{
	(void) dma;
	Con_Printf ("SNDDMA_Init: no audio backend yet (M5)\n");
	return false;
}

int SNDDMA_GetDMAPos (void)
{
	return 0;
}

void SNDDMA_Shutdown (void)
{
}

void SNDDMA_LockBuffer (void)
{
}

void SNDDMA_Submit (void)
{
}

void SNDDMA_BlockSound (void)
{
}

void SNDDMA_UnblockSound (void)
{
}
