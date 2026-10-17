/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * player_skin_test.c -- colormapped player skins. QR_TexMgr_ReloadImage
 * must remap the shirt and trouser ranges the way upstream's
 * TexMgr_ReloadImage does (forward for palette rows below 128, reversed
 * above), keep the colours sticky for a (-1,-1) reload, and enqueue a
 * fresh upload for the SAME texnum every time -- the loader's CRC cache
 * would otherwise swallow a colours-only change, since the CRC is taken
 * over the untranslated indices. QR_PlayerSkinTexture is upstream's
 * draw-time rule: only a player entity with its own translation table,
 * and only while gl_nocolors is off. QR_NewGame drops the pointers the
 * texture manager has already freed, and QR_FreeTexture drops them on
 * the paths that never reach R_NewGame (cache flush, owner free).
 *
 * Two sources are exercised. The in-memory one is the simplest way to
 * check the arithmetic. The lump-inside-a-pak one is the branch both
 * real callers take -- player_N inherits its .mdl offset from skin 0,
 * and the setup menu's preview carries its .lmp header offset -- so a
 * tiny pak is staged in a temporary basedir and the reload has to seek
 * RELATIVE to where COM_FOpenFile left the member, not from the start
 * of the pak. A seek from the file start would read the pak header.
 *
 * The palette is synthetic: entry i encodes i in its low byte, so an
 * uploaded RGBA texel reads straight back as the palette index it came
 * from. No game assets are needed.
 */
#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <unistd.h>

void QR_TestTexMgrBoot (void);
extern cvar_t gl_nocolors;

static int failures;

#define CHECK(cond, ...) do { \
	if (cond) printf ("ok    " __VA_ARGS__); \
	else { printf ("FAIL  " __VA_ARGS__); failures++; } \
	printf ("\n"); } while (0)

/* Drain the upload queue into out[] (at most max), return the count. */
static int DrainUploads (qc_texture_upload_t *out, int max)
{
	const qc_texture_upload_t *ups;
	int n, i;

	n = QC_RendererAcquireUploads (&ups);
	for (i = 0; i < n && i < max; i++)
		out[i] = ups[i];
	/* keep the pixel copies alive past Release for inspection */
	for (i = 0; i < n && i < max; i++)
	{
		size_t bytes = (size_t) out[i].width * out[i].height * 4;
		void *copy = malloc (bytes);
		memcpy (copy, out[i].rgba, bytes);
		out[i].rgba = copy;
	}
	QC_RendererReleaseUploads ();
	return n;
}

static int Index (const qc_texture_upload_t *up, int x)
{
	return (int) (((const unsigned char *) up->rgba)[x * 4]);
}

/* 1 if texels [0,16) read back as row a.. and [16,32) as row b.. (forward),
   or reversed when the row is at or above 128, as the translation does. */
static int RowsAre (const qc_texture_upload_t *up, int shirtrow, int pantsrow)
{
	int i;
	for (i = 0; i < 16; i++)
	{
		int want_s = shirtrow < 128 ? shirtrow + i : shirtrow + 15 - i;
		int want_p = pantsrow < 128 ? pantsrow + i : pantsrow + 15 - i;
		if (Index (up, i) != want_s || Index (up, 16 + i) != want_p)
			return 0;
	}
	return 1;
}

/* The 32x1 test skin: the shirt row then the trouser row, in palette order. */
static void FillSkin (byte *pixels)
{
	int i;
	for (i = 0; i < 16; i++)
	{
		pixels[i] = TOP_RANGE + i;
		pixels[16 + i] = BOTTOM_RANGE + i;
	}
}

/* A two-member pak. The skin member is header filler then the pixels, the
   filler standing in for a .mdl or .lmp header in front of them. The other
   member is gfx/pop.lmp: a pak the engine does not recognise marks the game
   as modified, and a modified game without the registered-version marker is
   a fatal error in COM_CheckRegistered, so the marker rides along. Its
   bytes are the table COM_CheckRegistered compares against, big-endian. */
#define PAK_MEMBER	"progs/skintest.bin"
#define PAK_SKIN_OFS	8

static const unsigned short pop_table[128] =
{
	0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,
	0x0000,0x0000,0x6600,0x0000,0x0000,0x0000,0x6600,0x0000,
	0x0000,0x0066,0x0000,0x0000,0x0000,0x0000,0x0067,0x0000,
	0x0000,0x6665,0x0000,0x0000,0x0000,0x0000,0x0065,0x6600,
	0x0063,0x6561,0x0000,0x0000,0x0000,0x0000,0x0061,0x6563,
	0x0064,0x6561,0x0000,0x0000,0x0000,0x0000,0x0061,0x6564,
	0x0064,0x6564,0x0000,0x6469,0x6969,0x6400,0x0064,0x6564,
	0x0063,0x6568,0x6200,0x0064,0x6864,0x0000,0x6268,0x6563,
	0x0000,0x6567,0x6963,0x0064,0x6764,0x0063,0x6967,0x6500,
	0x0000,0x6266,0x6769,0x6a68,0x6768,0x6a69,0x6766,0x6200,
	0x0000,0x0062,0x6566,0x6666,0x6666,0x6666,0x6562,0x0000,
	0x0000,0x0000,0x0062,0x6364,0x6664,0x6362,0x0000,0x0000,
	0x0000,0x0000,0x0000,0x0062,0x6662,0x0000,0x0000,0x0000,
	0x0000,0x0000,0x0000,0x0061,0x6661,0x0000,0x0000,0x0000,
	0x0000,0x0000,0x0000,0x0000,0x6500,0x0000,0x0000,0x0000,
	0x0000,0x0000,0x0000,0x0000,0x6400,0x0000,0x0000,0x0000
};

static void WriteEntry (FILE *f, const char *member, int filepos, int filelen)
{
	char	name[56];
	memset (name, 0, sizeof name);
	strcpy (name, member);
	fwrite (name, 1, sizeof name, f);
	fwrite (&filepos, 4, 1, f);
	fwrite (&filelen, 4, 1, f);
}

static int WritePak (const char *path)
{
	FILE	*f = fopen (path, "wb");
	byte	skin[32], filler[PAK_SKIN_OFS], pop[256];
	int	i, dirofs, dirlen = 2 * 64;
	int	pop_pos = 12, pop_len = (int) sizeof pop;
	int	skin_pos = pop_pos + pop_len, skin_len = PAK_SKIN_OFS + 32;

	if (!f)
		return 0;
	for (i = 0; i < 128; i++)
	{
		pop[i * 2] = (byte) (pop_table[i] >> 8);
		pop[i * 2 + 1] = (byte) (pop_table[i] & 0xff);
	}
	memset (filler, 0xEE, sizeof filler);
	FillSkin (skin);
	dirofs = skin_pos + skin_len;
	fwrite ("PACK", 1, 4, f);
	fwrite (&dirofs, 4, 1, f);
	fwrite (&dirlen, 4, 1, f);
	fwrite (pop, 1, sizeof pop, f);
	fwrite (filler, 1, sizeof filler, f);
	fwrite (skin, 1, sizeof skin, f);
	WriteEntry (f, "gfx/pop.lmp", pop_pos, pop_len);
	WriteEntry (f, PAK_MEMBER, skin_pos, skin_len);
	fclose (f);
	return 1;
}

static char		test_basedir[MAX_OSPATH];
static quakeparms_t	test_parms;

/* Stage <tmp>/id1/pak0.pak and bring the search path up over it. The
   texture manager is already booted (hunk, zone, byte order); this adds
   the pieces COM_InitFilesystem needs. Mirrors bgm_codec_test. */
static int BootFilesystem (void)
{
	static char	tmpl[] = "/tmp/quakeavp-skintest-XXXXXX";
	static char	*argv[3];
	char		path[MAX_OSPATH];
	const char	*dir = mkdtemp (tmpl);

	if (!dir)
		return 0;
	q_strlcpy (test_basedir, dir, sizeof test_basedir);
	q_snprintf (path, sizeof path, "%s/id1", test_basedir);
	if (mkdir (path, 0755) != 0)
		return 0;
	q_snprintf (path, sizeof path, "%s/id1/pak0.pak", test_basedir);
	if (!WritePak (path))
		return 0;

	argv[0] = (char *) "player_skin_test";
	argv[1] = (char *) "-basedir";
	argv[2] = test_basedir;
	host_parms = &test_parms;
	test_parms.basedir = test_basedir;
	test_parms.userdir = test_basedir;
	test_parms.argc = 3;
	test_parms.argv = argv;
	COM_InitArgv (3, argv);
	Cbuf_Init ();
	Cmd_Init ();
	Cvar_Init ();
	COM_InitFilesystem ();
	return 1;
}

static void Cleanup (void)
{
	char	path[MAX_OSPATH];
	if (!test_basedir[0])
		return;
	q_snprintf (path, sizeof path, "%s/id1/pak0.pak", test_basedir);
	remove (path);
	q_snprintf (path, sizeof path, "%s/id1", test_basedir);
	rmdir (path);
	rmdir (test_basedir);
}

int main (void)
{
	static byte		pixels[32];
	static entity_t		ents[4];
	static byte		fake_colormap[4], own_table[4];
	static gltexture_t	model_skin;
	static qmodel_t		owner_model;
	qc_texture_upload_t	ups[4];
	gltexture_t		*glt, *glt2, *pakglt;
	int			i, n;

	QR_TestTexMgrBoot ();
	(void) DrainUploads (ups, 4);	/* the fixture's own pics */
	for (i = 0; i < 256; i++)
		d_8to24table[i] = 0xff000000u | (unsigned) i;
	FillSkin (pixels);

	/* ---- source in memory: empty source_file, offset IS the pointer */
	glt = QR_TexMgr_LoadImage (NULL, "player_0", 32, 1, SRC_INDEXED, pixels,
				   "", (src_offset_t) pixels,
				   TEXPREF_PAD | TEXPREF_OVERWRITE);
	n = DrainUploads (ups, 4);
	CHECK (glt && n == 1 && ups[0].texnum == glt->texnum,
	       "initial load enqueues one upload for its texnum");
	CHECK (glt && glt->shirt == -1 && glt->pants == -1,
	       "a fresh texture has never been colormapped");

	/* shirt 3 -> row 48 (forward), pants 12 -> row 192 (reversed) */
	QR_TexMgr_ReloadImage (glt, 3, 12);
	n = DrainUploads (ups, 4);
	CHECK (n == 1 && ups[0].texnum == glt->texnum && ups[0].width == 32,
	       "reload enqueues one upload for the same texnum");
	CHECK (n == 1 && RowsAre (&ups[0], 48, 192),
	       "shirt row below 128 maps forward, trouser row above maps reversed");
	CHECK (glt->shirt == 3 && glt->pants == 12,
	       "the colours stick on the texture");

	/* shirt 12 -> row 192 (reversed), pants 2 -> row 32 (forward) */
	QR_TexMgr_ReloadImage (glt, 12, 2);
	n = DrainUploads (ups, 4);
	CHECK (n == 1 && RowsAre (&ups[0], 192, 32),
	       "shirt row above 128 maps reversed, trouser row below maps forward");

	/* (-1,-1) reuses the stored colours, as vid_restart's reload does */
	QR_TexMgr_ReloadImage (glt, -1, -1);
	n = DrainUploads (ups, 4);
	CHECK (n == 1 && ups[0].texnum == glt->texnum && RowsAre (&ups[0], 192, 32),
	       "a (-1,-1) reload re-applies the stored colours");

	/* two colour changes back to back: both must reach the consumer */
	QR_TexMgr_ReloadImage (glt, 2, 2);
	QR_TexMgr_ReloadImage (glt, 4, 4);
	n = DrainUploads (ups, 4);
	CHECK (n == 2 && ups[0].texnum == glt->texnum && ups[1].texnum == glt->texnum
	       && Index (&ups[0], 0) == 32 && Index (&ups[1], 0) == 64,
	       "successive colour changes each upload (no CRC short-circuit)");

	/* ---- source inside a pak member, at an offset past a header */
	CHECK (BootFilesystem (), "a temporary basedir with a two-member pak comes up");
	pakglt = QR_TexMgr_LoadImage (NULL, "player_pak", 32, 1, SRC_INDEXED, pixels,
				      PAK_MEMBER, PAK_SKIN_OFS, TEXPREF_OVERWRITE);
	(void) DrainUploads (ups, 4);
	QR_TexMgr_ReloadImage (pakglt, 5, 6);
	n = DrainUploads (ups, 4);
	CHECK (n == 1 && ups[0].texnum == pakglt->texnum,
	       "a pak-sourced texture re-uploads after a colour change");
	CHECK (n == 1 && RowsAre (&ups[0], 80, 96),
	       "the reload seeks past the member's own header, not the pak's");
	CHECK (n == 1 && Index (&ups[0], 0) != 0xEE,
	       "the filler in front of the pixels is never read as pixels");

	/* ---- draw-time rule. cl_entities[1..maxclients] are the players. */
	glt2 = QR_TexMgr_LoadImage (NULL, "player_1", 32, 1, SRC_INDEXED, pixels,
				    "", (src_offset_t) pixels,
				    TEXPREF_PAD | TEXPREF_OVERWRITE);
	(void) DrainUploads (ups, 4);
	cl_entities = ents;
	cl.maxclients = 2;
	vid.colormap = fake_colormap;
	playertextures[0] = glt;
	playertextures[1] = glt2;
	for (i = 0; i < 4; i++)
		ents[i].colormap = vid.colormap;
	ents[1].colormap = own_table;
	ents[2].colormap = own_table;
	ents[3].colormap = own_table;
	gl_nocolors.value = 0;

	CHECK (QR_PlayerSkinTexture (&ents[1], &model_skin) == glt,
	       "player 1 with its own translation gets playertextures[0]");
	CHECK (QR_PlayerSkinTexture (&ents[2], &model_skin) == glt2,
	       "the last player slot is inclusive: entity maxclients gets playertextures[maxclients-1]");
	CHECK (QR_PlayerSkinTexture (&ents[3], &model_skin) == &model_skin,
	       "an entity past maxclients is never a player");
	CHECK (QR_PlayerSkinTexture (&ents[0], &model_skin) == &model_skin,
	       "the world entity is never a player");
	ents[2].colormap = vid.colormap;
	CHECK (QR_PlayerSkinTexture (&ents[2], &model_skin) == &model_skin,
	       "a player still on the default colormap keeps the model skin");
	playertextures[1] = NULL;
	ents[2].colormap = own_table;
	CHECK (QR_PlayerSkinTexture (&ents[2], &model_skin) == &model_skin,
	       "a player whose texture is not built yet keeps the model skin");
	gl_nocolors.value = 1;
	CHECK (QR_PlayerSkinTexture (&ents[1], &model_skin) == &model_skin,
	       "gl_nocolors 1 keeps the model skin");
	gl_nocolors.value = 0;

	/* ---- the pointer goes when the texture goes, on every free path */
	glt2 = QR_TexMgr_LoadImage (&owner_model, "player_1", 32, 1, SRC_INDEXED, pixels,
				    "", (src_offset_t) pixels,
				    TEXPREF_PAD | TEXPREF_OVERWRITE);
	(void) DrainUploads (ups, 4);
	playertextures[1] = glt2;
	QR_TexMgr_FreeTexturesForOwner (&owner_model);
	CHECK (playertextures[1] == NULL,
	       "freeing the owning model's textures clears its player slot");
	CHECK (playertextures[0] == glt,
	       "another player's slot is untouched by that free");

	/* game switch: the texture manager freed them, the pointers go too */
	QR_NewGame ();
	CHECK (playertextures[0] == NULL, "QR_NewGame clears playertextures");

	Cleanup ();
	printf ("%s: player_skin_test, %d failure(s)\n", failures ? "FAIL" : "ok  ", failures);
	return failures ? 1 : 0;
}
