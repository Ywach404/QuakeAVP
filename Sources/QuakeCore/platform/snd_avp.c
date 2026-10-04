/*
 * snd_avp.c -- audio output device, replacing snd_sdl.c (and the M0-M6
 * snd_null.c stub).
 *
 * snd_dma.c / snd_mix.c are the mixer and are untouched: they paint into the
 * dma_t ring this file hands them. Only the device lives here, and it lives in
 * Swift (App/Sources/AudioSink.swift) behind the QC_Audio* shim, the same shape
 * as the QC_Input* producers.
 *
 * Returning false from SNDDMA_Init still makes S_Init disable sound cleanly
 * rather than mixing into a buffer nobody reads.
 */

#include "quakedef.h"
#include "QuakeCore.h"

static qboolean	snd_open;

qboolean SNDDMA_Init (dma_t *dma)
{
	unsigned char	*buffer = NULL;
	int		mono_samples = 0;
	int		speed, channels, bits;

	/* Honour the existing cvar; snd_mix.c has a documented 11025->44100
	   upsample path, so the device may legitimately run faster. */
	speed = (int) sndspeed.value;
	if (speed <= 0)
		speed = 11025;
	channels = 2;
	bits = 16;

	if (!QC_AudioOpen (speed, channels, bits, &buffer, &mono_samples))
	{
		Con_Printf ("SNDDMA_Init: no audio device\n");
		return false;
	}

	memset (dma, 0, sizeof(*dma));
	dma->channels = channels;
	dma->samplebits = bits;
	dma->speed = speed;
	dma->samples = mono_samples;	/* MONO samples, power of two */
	dma->submission_chunk = 1;
	dma->samplepos = 0;
	dma->buffer = buffer;

	snd_open = true;
	return true;
}

int SNDDMA_GetDMAPos (void)
{
	if (!snd_open)
		return 0;
	return QC_AudioSamplePos ();
}

void SNDDMA_Shutdown (void)
{
	if (!snd_open)
		return;
	snd_open = false;
	QC_AudioClose ();
}

void SNDDMA_LockBuffer (void)
{
}

void SNDDMA_Submit (void)
{
}

void SNDDMA_BlockSound (void)
{
	if (snd_open)
		QC_AudioSetRunning (0);
}

void SNDDMA_UnblockSound (void)
{
	if (snd_open)
		QC_AudioSetRunning (1);
}
