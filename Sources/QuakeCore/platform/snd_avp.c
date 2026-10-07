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

	/* TEMP crash-locator: synchronous stderr (shows in `make run --console`
	   immediately, unlike Con_Printf which is async and may not flush before a
	   crash). Brackets the audio init so the last [snd] line before a signal 11
	   pins where it dies. Remove once the crash is found. */
	fprintf (stderr, "[snd] SNDDMA_Init: enter\n");

	/* snd_mixspeed is the DEVICE rate (default 44100); sndspeed describes the
	   source material (default 11025). Driving the device from sndspeed made
	   the two always equal, which makes snd_mix.c:415's 11025->44100 lowpass
	   unreachable by construction and silently ignores snd_mixspeed -- and
	   snd_mem.c resamples every loaded sound to shm->speed, so the whole game
	   would have mixed at 11025 with no upsample and no filter. */
	speed = (int) snd_mixspeed.value;
	if (speed <= 0)
		speed = 44100;
	channels = 2;
	bits = 16;

	fprintf (stderr, "[snd] SNDDMA_Init: calling QC_AudioOpen\n");
	if (!QC_AudioOpen (speed, channels, bits, &buffer, &mono_samples))
	{
		fprintf (stderr, "[snd] SNDDMA_Init: QC_AudioOpen declined\n");
		Con_Printf ("SNDDMA_Init: no audio device\n");
		return false;
	}
	fprintf (stderr, "[snd] SNDDMA_Init: QC_AudioOpen ok, %d mono samples, buffer %p\n",
			mono_samples, (void *) buffer);

	/* Point the engine's global mixer handle at this dma. Upstream's
	   SNDDMA_Init does `shm = dma` first thing; ours never did, so shm stayed
	   NULL and the very next line in S_Startup -- Con_Printf("Audio: ...",
	   shm->samplebits, ...) -- dereferenced NULL and crashed with signal 11 the
	   instant the sound subsystem went active. Everything in snd_mix.c /
	   snd_dma.c reads shm, so this one assignment is what makes the whole mixer
	   usable, not just that Con_Printf. */
	shm = dma;

	memset (dma, 0, sizeof(*dma));
	dma->channels = channels;
	dma->samplebits = bits;
	dma->speed = speed;
	dma->samples = mono_samples;	/* MONO samples, power of two */
	dma->submission_chunk = 1;
	dma->samplepos = 0;
	dma->buffer = buffer;

	snd_open = true;
	fprintf (stderr, "[snd] SNDDMA_Init: returning true (sound subsystem now active)\n");
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
