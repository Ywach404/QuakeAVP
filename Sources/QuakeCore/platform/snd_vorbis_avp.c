/*
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
 * Measured against the ten 44.1 kHz stereo CD rips this port ships with:
 * setup (codebooks) 217,880 bytes at worst, temporaries 4,096. 512 KB is
 * about 2.3x that, which leaves room for a denser codebook than id's rips
 * use without leaving room for the whole file.
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
	int		frames, got;

	frames = bytes / (stream->info.channels * 2);
	if (frames <= 0)
		return 0;

	got = stb_vorbis_get_samples_short_interleaved (priv->vf,
							stream->info.channels,
							(short *) buffer,
							frames * stream->info.channels);
	if (got < 0)
		return -1;

	/* 0 is the EOF signal BGM_UpdateStream rewinds on. */
	return got * stream->info.channels * 2;
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
