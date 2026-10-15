/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * snd_vorbis_avp.c -- Ogg Vorbis streaming music, on stb_vorbis.
 *
 * Upstream's snd_vorbis.c wants libvorbisfile or libtremor; neither is worth
 * carrying onto visionOS for one decoder, so this supplies the same
 * `vorbis_codec` vtable that snd_codec.c registers under USE_CODEC_VORBIS and
 * backs it with the single-file stb_vorbis vendored next door (see
 * UPSTREAM.md). snd_wave.c is the shape this follows -- same ordering, same
 * ownership rules, same registration block at the bottom.
 *
 * THREADING: everything here runs on the engine thread. Host_Frame calls
 * BGM_Update, BGM_Update pumps BGM_UpdateStream, and that is the only caller
 * of codec_read/rewind. Decoded PCM leaves through S_RawSamples into
 * s_rawsamples, which snd_mix.c sums into the paint buffer. This file never
 * touches the dma ring, AudioSink's render block, or anything the renderer
 * owns, and nothing off the engine thread may call into it.
 *
 * A NOTE ON WHERE THE FILES LIVE: BGM_PlayCDtrack looks for music/trackNN.ogg
 * through the ordinary Quake filesystem, so the files may sit in a pak or
 * loose in id1/music. Loose ones are only visible when `registered` is 1 --
 * common.c refuses any loose path containing a '/' for shareware data. Dev
 * and release builds both ship pak1, so registered is 1 and the loose
 * id1/music folder is found.
 */

#include "quakedef.h"

#if defined(USE_CODEC_VORBIS)
#include "snd_codec.h"
#include "snd_codeci.h"
#include "snd_vorbis.h"

#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"

/*
 * Why an explicit arena rather than NULL:
 *
 * with alloc_buffer == NULL stb_vorbis takes the malloc()/alloca() path, and
 * the alloca() half parks per-packet temporaries -- tens of kilobytes, more
 * for a wide setup -- on whatever stack it is called from. That stack is the
 * engine thread's (QuakeEngineHost.swift sets it to 4 MB), and
 * BGM_UpdateStream has already put a 16 KB scratch buffer on it before
 * calling in. 4 MB is comfortable today, but the failure mode if it ever is
 * not is a smashed stack in the middle of a level, in a headset, which is
 * about the worst thing to debug. With an arena, stb allocates from this
 * block only and fails with VORBIS_outofmem -- deterministic, printed, and
 * survivable.
 *
 * Once alloc_buffer is non-NULL this block is the decoder's ENTIRE budget:
 * the stb_vorbis struct itself (vorbis_alloc -> setup_malloc), the codebooks,
 * and the per-frame temporaries (temp_alloc -> setup_temp_malloc) all come
 * out of it. Nothing falls back to malloc behind our back.
 *
 * Measured against ten 44.1 kHz stereo soundtrack tracks encoded the way a
 * CD transfer produces them: setup (codebooks) 217,880 bytes at worst,
 * temporaries 4,096. 512 KB is about 2.3x that, which leaves room for a
 * denser codebook than those use without leaving room for the whole file.
 */
#define VORBIS_ARENA_SIZE	(512 * 1024)

typedef struct
{
	stb_vorbis		*vf;
	stb_vorbis_alloc	arena;
	/* The arena bytes follow this header inside the same allocation: one
	   malloc, one free, and the header's own alignment carries to the
	   buffer, which stb's 8-byte-rounded sub-allocator needs. */
} vorbis_priv_t;

/*
=================
S_VORBIS_CodecOpenStream

S_CodecUtilOpen has already opened the file and recorded the window it
occupies -- a pak-embedded track is a slice of a much larger file, which is
exactly what stb_vorbis_open_file_section takes a length for.
=================
*/
static qboolean S_VORBIS_CodecOpenStream (snd_stream_t *stream)
{
	vorbis_priv_t	*priv;
	stb_vorbis_info	info;
	int		err = VORBIS__no_error;

	priv = (vorbis_priv_t *) malloc (sizeof(vorbis_priv_t) + VORBIS_ARENA_SIZE);
	if (!priv)
	{
		Con_Printf ("%s: out of memory for the vorbis arena\n", stream->name);
		return false;
	}
	priv->vf = NULL;
	priv->arena.alloc_buffer = (char *) (priv + 1);
	priv->arena.alloc_buffer_length_in_bytes = VORBIS_ARENA_SIZE;

	if (fseek (stream->fh.file, stream->fh.start, SEEK_SET) != 0)
	{
		Con_Printf ("%s: couldn't seek to the start of the stream\n", stream->name);
		free (priv);
		return false;
	}

	/* 0 == do not close the handle: S_CodecUtilClose owns the FILE*. */
	priv->vf = stb_vorbis_open_file_section (stream->fh.file, 0, &err,
						 &priv->arena,
						 (unsigned int) stream->fh.length);
	if (!priv->vf)
	{
		/* The code matters: a silent "no music" on a headset is
		   undiagnosable, and VORBIS_outofmem vs VORBIS_invalid_first_page
		   point at completely different problems. */
		Con_Printf ("%s: stb_vorbis error %d, not played\n", stream->name, err);
		free (priv);
		return false;
	}

	info = stb_vorbis_get_info (priv->vf);

	/*
	 * Mono or stereo only, the same restriction snd_wave.c:171-176 puts on a
	 * WAV. It is not a taste question: S_RawSamples (snd_dma.c:702-761) is
	 * four hardcoded (channels, width) branches with NO else, and s_rawend++
	 * lives only inside them. Hand it six channels and it paints nothing and
	 * advances nothing, so BGM_UpdateStream's `while (s_rawend < paintedtime
	 * + MAX_RAW_SAMPLES)` (bgmusic.c:394) never terminates -- and the
	 * did_rewind latch cannot save it, because every read after the rewind
	 * returns > 0 and clears the latch again. The engine thread, which also
	 * runs the simulation, spins forever: in a headset that reads as the app
	 * freezing on level load.
	 *
	 * Reachable by an ordinary user, not just by a malformed file:
	 * UIFileSharingEnabled lets anyone drop a 5.1 track in as
	 * Documents/id1/music/track02.ogg, and the seeder deliberately leaves
	 * user-supplied tracks alone. Refusing it costs the music and nothing
	 * else.
	 */
	if (info.channels != 1 && info.channels != 2)
	{
		Con_Printf ("%s: unsupported channel count %d (mono or stereo only)\n",
			    stream->name, info.channels);
		stb_vorbis_close (priv->vf);
		free (priv);
		return false;
	}

	stream->info.rate = info.sample_rate;
	stream->info.channels = info.channels;
	stream->info.bits = 16;
	stream->info.width = 2;	/* get_samples_short_interleaved's unit */
	stream->priv = priv;

	Con_Printf ("Vorbis: %s, %d Hz, %d channel(s)\n",
		    stream->name, info.sample_rate, info.channels);

	return true;
}

/*
=================
S_VORBIS_CodecReadStream

The vtable counts BYTES; stb counts samples per channel for its return and
total shorts for its buffer argument. Getting either conversion wrong is off
by a factor of channels, which on a stereo track sounds like the right music
at the wrong speed rather than like a bug.
=================
*/
static int S_VORBIS_CodecReadStream (snd_stream_t *stream, int bytes, void *buffer)
{
	vorbis_priv_t	*priv = (vorbis_priv_t *) stream->priv;
	int		frames, got, err;

	frames = bytes / (stream->info.channels * 2);
	if (frames <= 0)
		return 0;

	got = stb_vorbis_get_samples_short_interleaved (priv->vf,
							stream->info.channels,
							(short *) buffer,
							frames * stream->info.channels);
	if (got > 0)
		return got * stream->info.channels * 2;

	/*
	 * stb never returns a negative count: its inner loop breaks on EOF and on
	 * a decode error alike and hands back whatever it managed, so a zero is
	 * ambiguous on its own. Asking stb_vorbis_get_error separates them, and
	 * the distinction is the difference between two very different
	 * behaviours in BGM_UpdateStream: a 0 return rewinds and plays on
	 * (bgmusic.c:449), a negative one prints "Stream read error" and stops
	 * (bgmusic.c:455-459). Without this, a corrupt packet mid-track looks
	 * exactly like the end of the song -- the track silently restarts from
	 * the top at the same spot every time, forever, with nothing in the
	 * console. That is the failure this file's header argues against.
	 *
	 * Measured on a deliberately corrupted 44.1 kHz rip: stb sets
	 * VORBIS_missing_capture_pattern (30) on the read that stops short, and
	 * sets nothing at all across 3146 clean reads to a true EOF -- so this
	 * cannot misreport the end of a good file. VORBIS_need_more_data is
	 * excluded because stb itself labels it "not a real error".
	 *
	 * get_error clears the flag as it reads it, which is what we want: one
	 * report per fault.
	 */
	err = stb_vorbis_get_error (priv->vf);
	if (err != VORBIS__no_error && err != VORBIS_need_more_data)
	{
		Con_Printf ("%s: stb_vorbis decode error %d\n", stream->name, err);
		return -1;
	}

	/* 0 is the EOF signal BGM_UpdateStream rewinds on. */
	return 0;
}

/*
=================
S_VORBIS_CodecRewindStream
=================
*/
static int S_VORBIS_CodecRewindStream (snd_stream_t *stream)
{
	vorbis_priv_t	*priv = (vorbis_priv_t *) stream->priv;

	/* stb returns NONZERO for success; BGM_UpdateStream reads a nonzero
	   return as a seek error and stops the music. Passing stb's value
	   through unchanged would kill the track at every loop point. */
	return stb_vorbis_seek_start (priv->vf) ? 0 : -1;
}

/*
=================
S_VORBIS_CodecCloseStream

stb first (it reads the decoder, which lives inside the arena), then the
arena, then S_CodecUtilClose -- which fcloses the handle stb was told not to
touch, so it is closed exactly once.
=================
*/
static void S_VORBIS_CodecCloseStream (snd_stream_t *stream)
{
	vorbis_priv_t	*priv = (vorbis_priv_t *) stream->priv;

	if (priv)
	{
		if (priv->vf)
			stb_vorbis_close (priv->vf);
		stream->priv = NULL;
		free (priv);
	}
	S_CodecUtilClose (&stream);
}

static qboolean S_VORBIS_CodecInitialize (void)
{
	return true;
}

static void S_VORBIS_CodecShutdown (void)
{
}

snd_codec_t vorbis_codec =
{
	CODECTYPE_VORBIS,
	true,	/* always available: stb_vorbis is compiled in, not dlopened. */
	"ogg",
	S_VORBIS_CodecInitialize,
	S_VORBIS_CodecShutdown,
	S_VORBIS_CodecOpenStream,
	S_VORBIS_CodecReadStream,
	S_VORBIS_CodecRewindStream,
	NULL, /* jump -- S_CodecJumpToOrder returns -1 for a NULL here, which is
		 the unimplemented answer; snd_wave.c does the same. */
	S_VORBIS_CodecCloseStream,
	NULL
};

#endif	/* USE_CODEC_VORBIS */
