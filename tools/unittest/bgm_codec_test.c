/*
 * bgm_codec_test.c -- the background-music codec chain, end to end.
 *
 * The engine's whole BGM path (bgmusic.c -> snd_codec.c -> a codec vtable ->
 * S_RawSamples) was already vendored and wired; what was missing was a codec
 * to register. This test pins the part of that chain that can be proven on a
 * host: the registry really hands out the vorbis and wave codecs, and a real
 * Ogg Vorbis file opened through the real filesystem path decodes to the
 * samples it was encoded from.
 *
 * It is NOT sufficient. Nothing here proves audible music in the headset --
 * see the repo's standing rule about green suites hiding live failures. The
 * device checklist lives in the soundtrack report.
 *
 * The fixture: tools/unittest/fixtures/sine.ogg, ours, regenerate with
 *
 *   ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=11025" \
 *          -af volume=7 -ac 2 -c:a vorbis -strict -2 -b:a 48k \
 *          tools/unittest/fixtures/sine.ogg
 *
 * Stereo rather than mono because ffmpeg's *native* vorbis encoder is the only
 * one available here (no --enable-libvorbis in the Homebrew build) and it
 * rejects mono input. 11025 Hz on purpose: it differs from the mixer's rate,
 * so BGM_UpdateStream's resampling arithmetic is exercised by a real file
 * rather than by a happy-path 44.1 kHz one. The volume filter is there
 * because lavfi's sine generator peaks near -18 dBFS; without it a decode
 * that silently lost 20 dB would still look "nonzero".
 */

#include "quakedef.h"
#include "snd_codec.h"
#include "QuakeCore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef UNIT_FIXTURE_DIR
#define UNIT_FIXTURE_DIR	"tools/unittest/fixtures"
#endif

static int	failures;
#define CHECK(c,...) do{ if(!(c)){failures++;printf("FAIL: "__VA_ARGS__);printf("\n");}else{printf("ok:   "__VA_ARGS__);printf("\n");} }while(0)

/* The fixture's own parameters, and what 0.5 s of it should decode to. */
#define FIX_RATE	11025
#define FIX_CHANNELS	2
#define FIX_FRAMES	5513			/* 0.5 s, rounded up */
#define FIX_BYTES	(FIX_FRAMES * FIX_CHANNELS * 2)

/* The WAV the test synthesizes for itself: mono, so the two codecs disagree
   about every field and a mix-up cannot pass by coincidence. */
#define WAV_RATE	11025
#define WAV_FRAMES	2205			/* 0.2 s */

/* A second synthesized WAV, six channels, for the channel-count guard. */
#define WAV6_CHANNELS	6
#define WAV6_FRAMES	64

static short	wav_expect[WAV_FRAMES];

/* Log sink used to silence (and count) the codec's per-open line during the
   churn loop. Installed through the same QC_SetCallbacks the app uses; with
   no callback set, sys_avp.c's QAVP_Emit falls back to stderr. */
static int	log_lines;
static void BGMTest_CountLog (void *ctx, const char *text)
{
	(void) ctx; (void) text;
	log_lines++;
}

static byte		bgm_test_hunk[8 * 1024 * 1024];
static quakeparms_t	bgm_test_parms;
static char		bgm_test_basedir[MAX_OSPATH];

/*
=================
BGMTest_WriteLE
=================
*/
static void BGMTest_WriteLE (FILE *f, unsigned int v, int bytes)
{
	int	i;

	for (i = 0; i < bytes; i++)
		fputc ((v >> (8 * i)) & 0xff, f);
}

/*
=================
BGMTest_WriteWav

A 16-bit mono PCM RIFF written by hand, so the expected samples are known
exactly and the wave codec's output can be compared against them rather than
against a tolerance.
=================
*/
static qboolean BGMTest_WriteWav (const char *path)
{
	FILE	*f;
	int	i;

	f = fopen (path, "wb");
	if (!f)
		return false;

	for (i = 0; i < WAV_FRAMES; i++)
		wav_expect[i] = (short) (10000.0 * sin (2.0 * M_PI * 440.0 * i / WAV_RATE));

	fwrite ("RIFF", 1, 4, f);
	BGMTest_WriteLE (f, 36 + WAV_FRAMES * 2, 4);	/* chunk size */
	fwrite ("WAVE", 1, 4, f);
	fwrite ("fmt ", 1, 4, f);
	BGMTest_WriteLE (f, 16, 4);			/* fmt chunk length */
	BGMTest_WriteLE (f, 1, 2);			/* WAV_FORMAT_PCM */
	BGMTest_WriteLE (f, 1, 2);			/* channels */
	BGMTest_WriteLE (f, WAV_RATE, 4);
	BGMTest_WriteLE (f, WAV_RATE * 2, 4);		/* byte rate */
	BGMTest_WriteLE (f, 2, 2);			/* block align */
	BGMTest_WriteLE (f, 16, 2);			/* bits */
	fwrite ("data", 1, 4, f);
	BGMTest_WriteLE (f, WAV_FRAMES * 2, 4);
	for (i = 0; i < WAV_FRAMES; i++)
		BGMTest_WriteLE (f, (unsigned short) wav_expect[i], 2);

	fclose (f);
	return true;
}

/*
=================
BGMTest_WriteWav6

Six channels, otherwise a perfectly valid 16-bit PCM RIFF. This exists to
exercise the hazard that motivates the vorbis codec's own channel guard:
S_RawSamples only knows the four (channels, width) combinations of mono/stereo
by 8/16-bit, has no fallback branch, and advances s_rawend only inside them --
so a >2-channel stream would leave BGM_UpdateStream's while loop spinning on
the engine thread forever. snd_wave.c refuses such a file at open, and the
vorbis codec now does the same.

No Ogg equivalent is possible here: ffmpeg's native vorbis encoder (the only
one on this machine -- no libvorbis, no libsndfile) accepts stereo input and
nothing else, and the brief forbids downloading a fixture. So this covers the
mechanism and the in-tree template's discipline; the vorbis guard's own reject
branch is reviewed, not executed. Said plainly rather than papered over.
=================
*/
static qboolean BGMTest_WriteWav6 (const char *path)
{
	FILE	*f;
	int	i, c;

	f = fopen (path, "wb");
	if (!f)
		return false;

	fwrite ("RIFF", 1, 4, f);
	BGMTest_WriteLE (f, 36 + WAV6_FRAMES * WAV6_CHANNELS * 2, 4);
	fwrite ("WAVE", 1, 4, f);
	fwrite ("fmt ", 1, 4, f);
	BGMTest_WriteLE (f, 16, 4);
	BGMTest_WriteLE (f, 1, 2);				/* WAV_FORMAT_PCM */
	BGMTest_WriteLE (f, WAV6_CHANNELS, 2);
	BGMTest_WriteLE (f, WAV_RATE, 4);
	BGMTest_WriteLE (f, WAV_RATE * WAV6_CHANNELS * 2, 4);
	BGMTest_WriteLE (f, WAV6_CHANNELS * 2, 2);		/* block align */
	BGMTest_WriteLE (f, 16, 2);				/* bits */
	fwrite ("data", 1, 4, f);
	BGMTest_WriteLE (f, WAV6_FRAMES * WAV6_CHANNELS * 2, 4);
	for (i = 0; i < WAV6_FRAMES; i++)
		for (c = 0; c < WAV6_CHANNELS; c++)
			BGMTest_WriteLE (f, (unsigned short) (short) (i * 16), 2);

	fclose (f);
	return true;
}

/*
=================
BGMTest_CopyFile
=================
*/
static qboolean BGMTest_CopyFile (const char *src, const char *dst)
{
	FILE	*in, *out;
	char	buf[4096];
	size_t	n;

	in = fopen (src, "rb");
	if (!in)
		return false;
	out = fopen (dst, "wb");
	if (!out)
	{
		fclose (in);
		return false;
	}
	while ((n = fread (buf, 1, sizeof(buf), in)) > 0)
		fwrite (buf, 1, n, out);
	fclose (in);
	fclose (out);
	return true;
}

/*
=================
BGMTest_BootFilesystem

The real COM_FOpenFile path, not a hand-built fshandle_t: music/ lookups are
exactly where the pak-vs-loose-file and shareware rules bite, and a synthetic
stream would skip both. Mirrors QC_Init's order (COM_InitArgv before the
memory bootstrap, as qavp_core.c does it) and then Host_Init's.
=================
*/
static qboolean BGMTest_BootFilesystem (void)
{
	static char	tmpl[] = "/tmp/quakeavp-bgmtest-XXXXXX";
	static char	*argv[3];
	char		path[MAX_OSPATH];
	const char	*dir;

	dir = mkdtemp (tmpl);
	if (!dir)
		return false;
	q_strlcpy (bgm_test_basedir, dir, sizeof(bgm_test_basedir));

	q_snprintf (path, sizeof(path), "%s/id1", bgm_test_basedir);
	if (mkdir (path, 0755) != 0)
		return false;
	q_snprintf (path, sizeof(path), "%s/id1/music", bgm_test_basedir);
	if (mkdir (path, 0755) != 0)
		return false;

	q_snprintf (path, sizeof(path), "%s/id1/music/sine.ogg", bgm_test_basedir);
	if (!BGMTest_CopyFile (UNIT_FIXTURE_DIR "/sine.ogg", path))
	{
		printf ("FAIL: couldn't stage %s from " UNIT_FIXTURE_DIR "\n", path);
		return false;
	}
	q_snprintf (path, sizeof(path), "%s/id1/music/tone.wav", bgm_test_basedir);
	if (!BGMTest_WriteWav (path))
		return false;
	q_snprintf (path, sizeof(path), "%s/id1/music/six.wav", bgm_test_basedir);
	if (!BGMTest_WriteWav6 (path))
		return false;

	argv[0] = (char *) "bgm_codec_test";
	argv[1] = (char *) "-basedir";
	argv[2] = bgm_test_basedir;

	host_parms = &bgm_test_parms;
	bgm_test_parms.basedir = bgm_test_basedir;
	bgm_test_parms.userdir = bgm_test_basedir;
	bgm_test_parms.argc = 3;
	bgm_test_parms.argv = argv;

	COM_InitArgv (3, argv);
	Memory_Init (bgm_test_hunk, sizeof(bgm_test_hunk));
	Cbuf_Init ();
	Cmd_Init ();
	Cvar_Init ();
	COM_Init ();
	COM_InitFilesystem ();

	/* COM_CheckRegistered leaves this at 0 without gfx/pop.lmp, and
	   common.c's loose-file branch then refuses any name containing a
	   '/' -- which is every music/ path. Dev and release builds both ship
	   pak1, so registered is 1 there; force it rather than fabricate a
	   pak just to get past the shareware gate. CVAR_ROM, so poke the
	   struct directly. */
	registered.value = 1;

	S_CodecInit ();
	return true;
}

/*
=================
BGMTest_Cleanup

check-unit.sh is run dozens of times a day and this is the only test that puts
anything in /tmp; without this they pile up one basedir per run. Best effort
and order-dependent (files before their directories), and deliberately only
the paths this test created -- no recursive delete of a path built from a
template.
=================
*/
static void BGMTest_Cleanup (void)
{
	static const char *leaves[] = {
		"id1/music/sine.ogg", "id1/music/tone.wav", "id1/music/six.wav",
		"config.cfg"	/* COM_InitFilesystem's userdir side, if it appears */
	};
	static const char *dirs[] = { "id1/music", "id1" };
	char	path[MAX_OSPATH];
	size_t	i;

	if (!bgm_test_basedir[0])
		return;

	for (i = 0; i < sizeof(leaves) / sizeof(leaves[0]); i++)
	{
		q_snprintf (path, sizeof(path), "%s/%s", bgm_test_basedir, leaves[i]);
		unlink (path);
	}
	for (i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++)
	{
		q_snprintf (path, sizeof(path), "%s/%s", bgm_test_basedir, dirs[i]);
		rmdir (path);
	}
	rmdir (bgm_test_basedir);
}

/*
=================
BGMTest_Vorbis
=================
*/
static void BGMTest_Vorbis (void)
{
	snd_stream_t	*stream;
	byte		first[1024];
	byte		again[1024];
	byte		buf[4096];
	int		res, total, i, peak, mag, nonzero;
	short		s;

	stream = S_CodecOpenStreamType ("music/sine.ogg", CODECTYPE_VORBIS, false);
	CHECK (stream != NULL, "ogg fixture opens through S_CodecOpenStreamType");
	if (!stream)
		return;

	CHECK (stream->info.rate == FIX_RATE, "ogg rate is %d (got %d)", FIX_RATE, stream->info.rate);
	CHECK (stream->info.channels == FIX_CHANNELS, "ogg channels is %d (got %d)", FIX_CHANNELS, stream->info.channels);
	CHECK (stream->info.width == 2, "ogg width is 2 (got %d)", stream->info.width);

	total = 0;
	peak = 0;
	nonzero = 0;
	memset (first, 0, sizeof(first));
	while ((res = S_CodecReadStream (stream, sizeof(buf), buf)) > 0)
	{
		if (total == 0 && res >= (int) sizeof(first))
			memcpy (first, buf, sizeof(first));
		for (i = 0; i + 1 < res; i += 2)
		{
			memcpy (&s, buf + i, 2);
			if (s)
				nonzero++;
			/* Through int, so SHRT_MIN's magnitude is representable. */
			mag = (s < 0) ? -(int) s : (int) s;
			if (mag > peak)
				peak = mag;
		}
		total += res;
	}
	CHECK (res == 0, "decode ends on the EOF signal 0, not an error (got %d)", res);
	/* Vorbis is lossy and the encoder pads; a tenth either way is slack
	   enough for that and tight enough to catch a per-channel/per-byte
	   mix-up, which would be off by a factor of two. */
	CHECK (total > FIX_BYTES * 9 / 10 && total < FIX_BYTES * 11 / 10,
	       "decoded %d bytes, expected about %d", total, FIX_BYTES);
	CHECK (nonzero > total / 8, "decoded samples are not silence (%d nonzero)", nonzero);
	/* The fixture is encoded near full scale (see the header), and 48 kb/s
	   vorbis gives back about -4 dBFS. Half scale is the floor: it clears
	   a correct decode by a wide margin and fails anything that has lost
	   a channel, a shift, or the top byte of every sample. */
	CHECK (peak > 16000 && peak <= 32767, "peak sample %d is a plausible full-scale sine", peak);

	res = S_CodecRewindStream (stream);
	CHECK (res == 0, "rewind reports success as 0 the way BGM_UpdateStream reads it (got %d)", res);

	res = S_CodecReadStream (stream, sizeof(again), again);
	CHECK (res == (int) sizeof(again), "re-read after rewind returns a full buffer (got %d)", res);
	CHECK (res == (int) sizeof(again) && !memcmp (first, again, sizeof(again)),
	       "re-read after rewind matches the first read byte for byte");

	S_CodecCloseStream (stream);

	/* A WAV handed to the vorbis codec must be refused, not guessed at. */
	stream = S_CodecOpenStreamType ("music/tone.wav", CODECTYPE_VORBIS, false);
	CHECK (stream == NULL, "vorbis codec refuses a WAV file");
	if (stream)
		S_CodecCloseStream (stream);

	/* Open/close churn: stb_vorbis holds a malloc'd arena per stream, and
	   a leak or a double free shows up here rather than an hour into a
	   level. Worth the hundred iterations; the fixture is 5 KB.

	   The codec logs one line per successful open, which at a hundred
	   iterations buried this test's own twenty-odd result lines in the
	   suite output. Swapping the engine's log sink for a counter silences
	   them without shortening the loop -- and the count is then a stronger
	   assertion than the loop index alone, because it proves each
	   iteration really reached codec_open rather than being skipped. */
	log_lines = 0;
	QC_SetCallbacks (BGMTest_CountLog, NULL, NULL);
	for (i = 0; i < 100; i++)
	{
		stream = S_CodecOpenStreamType ("music/sine.ogg", CODECTYPE_VORBIS, false);
		if (!stream)
			break;
		if (S_CodecReadStream (stream, sizeof(buf), buf) <= 0)
		{
			S_CodecCloseStream (stream);
			stream = NULL;
			break;
		}
		S_CodecCloseStream (stream);
	}
	QC_SetCallbacks (NULL, NULL, NULL);
	CHECK (i == 100, "100 open/read/close cycles survive (reached %d)", i);
	CHECK (log_lines == 100, "each cycle really opened the codec (%d open lines)", log_lines);
}

/*
=================
BGMTest_Wave
=================
*/
static void BGMTest_Wave (void)
{
	snd_stream_t	*stream;
	byte		buf[4096];
	short		got[WAV_FRAMES];
	int		res, total, mismatch, i;

	stream = S_CodecOpenStreamType ("music/tone.wav", CODECTYPE_WAV, false);
	CHECK (stream != NULL, "wav fixture opens through S_CodecOpenStreamType");
	if (!stream)
		return;

	CHECK (stream->info.rate == WAV_RATE, "wav rate is %d (got %d)", WAV_RATE, stream->info.rate);
	CHECK (stream->info.channels == 1, "wav channels is 1 (got %d)", stream->info.channels);
	CHECK (stream->info.width == 2, "wav width is 2 (got %d)", stream->info.width);

	total = 0;
	while ((res = S_CodecReadStream (stream, sizeof(buf), buf)) > 0)
	{
		if (total + res > (int) sizeof(got))
			break;
		memcpy ((byte *)got + total, buf, res);
		total += res;
	}
	CHECK (total == WAV_FRAMES * 2, "wav decodes %d bytes (got %d)", WAV_FRAMES * 2, total);

	mismatch = 0;
	for (i = 0; i < WAV_FRAMES && total == WAV_FRAMES * 2; i++)
		if (got[i] != wav_expect[i])
			mismatch++;
	CHECK (mismatch == 0, "wav roundtrip is sample-exact (%d mismatches)", mismatch);

	S_CodecCloseStream (stream);

	/* And the mirror of the vorbis cross-feed check. */
	stream = S_CodecOpenStreamType ("music/sine.ogg", CODECTYPE_WAV, false);
	CHECK (stream == NULL, "wave codec refuses an Ogg file");
	if (stream)
		S_CodecCloseStream (stream);

	/* The channel-count hazard, through the codec that can be fed a
	   >2-channel file here. A stream that reaches S_RawSamples with six
	   channels would hang the engine thread (see BGMTest_WriteWav6); the
	   only safe answer is a refusal at open. */
	stream = S_CodecOpenStreamType ("music/six.wav", CODECTYPE_WAV, false);
	CHECK (stream == NULL, "a 6-channel WAV is refused at open, not handed to S_RawSamples");
	if (stream)
		S_CodecCloseStream (stream);
}

int main (void)
{
	if (!BGMTest_BootFilesystem ())
	{
		printf ("FAIL: filesystem bootstrap failed\n");
		BGMTest_Cleanup ();	/* best effort: whatever got as far as staging */
		return 1;
	}

	CHECK (S_CodecIsAvailable (CODECTYPE_VORBIS) != -1, "vorbis codec is registered");
	CHECK (S_CodecIsAvailable (CODECTYPE_WAV) != -1, "wave codec is registered");

	if (S_CodecIsAvailable (CODECTYPE_VORBIS) != -1)
		BGMTest_Vorbis ();
	if (S_CodecIsAvailable (CODECTYPE_WAV) != -1)
		BGMTest_Wave ();

	S_CodecShutdown ();
	BGMTest_Cleanup ();

	printf ("%s\n", failures ? "FAILED" : "all good");
	return failures ? 1 : 0;
}
