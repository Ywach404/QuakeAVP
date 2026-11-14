/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * grapple_extract_test.c -- lifting one file out of a .pak onto disk.
 *
 * The hook head's model and its throw sound ship only with Dissolution of
 * Eternity, and `COM_Game_f` FREES a mission pack off the search path when
 * you switch to id1 (common.c:2347-2359), so those bytes are not merely
 * outranked while you play vanilla -- the pak's handle is closed and its
 * directory freed. The way the hook looks the same in all six games is
 * therefore to copy the player's own two files into id1, once, where id1's
 * directory element is on the path in every gamedir.
 *
 * That makes this code a parser for a file format that arrives from the
 * player's disk, which is why the refusals are tested as carefully as the
 * success: a directory entry claiming a length past the end of the file is
 * the whole reason this does not just seek and read.
 */
#include "quakedef.h"
#include "QuakeCore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The seam. grapple_avp.c keeps the extractor static and exposes it under
   QAVP_HOSTCHECK, the way it already does for the anchor decision. */
int Grapple_TestPakExtract (const char *pakpath, const char *inpak,
			    const char *outpath);

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

static char	scratch[1024];

/* The payload the fake pak carries. Deliberately not text, and deliberately
   long enough that a partial write would not compare equal by luck. */
#define PAYLOAD_LEN 777
static unsigned char	payload[PAYLOAD_LEN];

static void put_le32 (unsigned char *p, int v)
{
	p[0] = (unsigned char) (v & 0xff);
	p[1] = (unsigned char) ((v >> 8) & 0xff);
	p[2] = (unsigned char) ((v >> 16) & 0xff);
	p[3] = (unsigned char) ((v >> 24) & 0xff);
}

/*
 * Write a one-entry .pak. `claim_len` and `claim_ofs` are what the directory
 * ADVERTISES, which is the whole point: pass the real values for a good pak,
 * or a lie for the hostile cases.
 */
static void write_pak (const char *path, const char *entry,
		       int claim_ofs, int claim_len, const char *magic)
{
	unsigned char	hdr[12];
	unsigned char	dir[64];
	FILE		*f = fopen (path, "wb");

	if (!f) { printf ("FAIL: could not create %s\n", path); failures++; return; }

	/* header, then the payload at offset 12, then the directory */
	memcpy (hdr, magic, 4);
	put_le32 (hdr + 4, 12 + PAYLOAD_LEN);	/* dirofs */
	put_le32 (hdr + 8, 64);			/* dirlen: one entry */
	fwrite (hdr, 1, sizeof (hdr), f);
	fwrite (payload, 1, PAYLOAD_LEN, f);

	memset (dir, 0, sizeof (dir));
	strncpy ((char *) dir, entry, 55);
	put_le32 (dir + 56, claim_ofs);
	put_le32 (dir + 60, claim_len);
	fwrite (dir, 1, sizeof (dir), f);
	fclose (f);
}

static long file_size (const char *path)
{
	struct stat st;
	if (stat (path, &st) != 0)
		return -1;
	return (long) st.st_size;
}

static int file_matches_payload (const char *path)
{
	unsigned char	buf[PAYLOAD_LEN];
	FILE		*f = fopen (path, "rb");
	size_t		got;

	if (!f)
		return 0;
	got = fread (buf, 1, sizeof (buf), f);
	fclose (f);
	if (got != PAYLOAD_LEN)
		return 0;
	return memcmp (buf, payload, PAYLOAD_LEN) == 0;
}

int main (void)
{
	char		pak[1200], out[1200], nested[1200];
	const char	*tmp = getenv ("TMPDIR");
	int		i, rc;
	long		sz;

	for (i = 0; i < PAYLOAD_LEN; i++)
		payload[i] = (unsigned char) ((i * 31 + 7) & 0xff);

	q_snprintf (scratch, sizeof (scratch), "%s/qavp-extract-test",
		    (tmp && *tmp) ? tmp : "/tmp");
	Sys_mkdir (scratch);

	q_snprintf (pak, sizeof (pak), "%s/fake.pak", scratch);
	q_snprintf (out, sizeof (out), "%s/out.bin", scratch);
	unlink (out);

	/* ---- the good case ---- */
	write_pak (pak, "progs/hook.mdl", 12, PAYLOAD_LEN, "PACK");
	rc = Grapple_TestPakExtract (pak, "progs/hook.mdl", out);
	CHECK (rc == 1, "a named entry extracts (rc %d, want 1)", rc);
	CHECK (file_matches_payload (out), "the extracted bytes are the pak's bytes");

	/* ---- idempotent: the second run must not rewrite ---- */
	rc = Grapple_TestPakExtract (pak, "progs/hook.mdl", out);
	CHECK (rc == 0, "a second extract is a no-op (rc %d, want 0)", rc);
	CHECK (file_matches_payload (out), "the no-op left the file intact");

	/* ---- a stale/truncated file at the destination is replaced ---- */
	{
		FILE *f = fopen (out, "wb");
		if (f) { fwrite ("short", 1, 5, f); fclose (f); }
	}
	rc = Grapple_TestPakExtract (pak, "progs/hook.mdl", out);
	CHECK (rc == 1, "a wrong-sized destination is re-extracted (rc %d, want 1)", rc);
	CHECK (file_matches_payload (out), "the replacement is correct");

	/* ---- intermediate directories are created ---- */
	q_snprintf (nested, sizeof (nested), "%s/id1/sound/weapons/chain1.wav",
		    scratch);
	unlink (nested);
	rc = Grapple_TestPakExtract (pak, "progs/hook.mdl", nested);
	CHECK (rc == 1, "a nested destination path is created (rc %d, want 1)", rc);
	CHECK (file_matches_payload (nested), "the nested file has the right bytes");

	/* ---- refusals. Every one of these must leave no file behind. ---- */
	unlink (out);
	rc = Grapple_TestPakExtract (pak, "progs/notthere.mdl", out);
	CHECK (rc == -2, "a name not in the pak is reported absent (rc %d, want -2)", rc);
	CHECK (file_size (out) == -1, "the absent name wrote nothing");

	{
		char missing[1200];
		q_snprintf (missing, sizeof (missing), "%s/nosuch.pak", scratch);
		rc = Grapple_TestPakExtract (missing, "progs/hook.mdl", out);
		CHECK (rc == -1, "a missing pak is refused (rc %d, want -1)", rc);
		CHECK (file_size (out) == -1, "the missing pak wrote nothing");
	}

	write_pak (pak, "progs/hook.mdl", 12, PAYLOAD_LEN, "JUNK");
	rc = Grapple_TestPakExtract (pak, "progs/hook.mdl", out);
	CHECK (rc == -1, "a file that is not a pak is refused (rc %d, want -1)", rc);
	CHECK (file_size (out) == -1, "the non-pak wrote nothing");

	/* The hostile case this function exists to survive: the directory
	   claims more bytes than the file holds. Seek-and-read would hand
	   back a short buffer or garbage; this must refuse outright. */
	write_pak (pak, "progs/hook.mdl", 12, PAYLOAD_LEN + 4096, "PACK");
	rc = Grapple_TestPakExtract (pak, "progs/hook.mdl", out);
	CHECK (rc == -1, "an entry longer than the file is refused (rc %d, want -1)", rc);
	CHECK (file_size (out) == -1, "the over-long entry wrote nothing");

	/* Same lie, told with the offset instead. */
	write_pak (pak, "progs/hook.mdl", 1 << 28, PAYLOAD_LEN, "PACK");
	rc = Grapple_TestPakExtract (pak, "progs/hook.mdl", out);
	CHECK (rc == -1, "an entry starting past the file is refused (rc %d, want -1)", rc);
	CHECK (file_size (out) == -1, "the out-of-range offset wrote nothing");

	/* A negative length is the same class of lie and must not reach a
	   memcpy or a malloc. */
	write_pak (pak, "progs/hook.mdl", 12, -64, "PACK");
	rc = Grapple_TestPakExtract (pak, "progs/hook.mdl", out);
	CHECK (rc == -1, "a negative entry length is refused (rc %d, want -1)", rc);
	CHECK (file_size (out) == -1, "the negative length wrote nothing");

	sz = file_size (nested);
	CHECK (sz == PAYLOAD_LEN,
	       "the one good nested extraction survived every refusal (%ld bytes)", sz);

	printf ("%s: %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
	return failures ? 1 : 0;
}
