/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
 * cfgtest.c -- boot the engine, call the REAL Host_WriteConfiguration, and
 * read the file it wrote. Deviceless proof that the 27 cvars the Swift input
 * profile owns get no second, per-game store, and that the writer still
 * records the knobs the engine does own. Link against
 * ${TMPDIR}/quakecore-hostbuild/[star].o minus hostmain.o (see
 * tools/range/README.md).
 *
 * tools/check-rig-store.sh already reads the declarations in in_null.c and
 * derives the owned list from the Swift sources, so it is the authority on
 * WHICH names are profile-owned and the one guard that can notice a 28th.
 * What it cannot see is the writer: CVAR_ARCHIVE is one of several conditions
 * on a name reaching config.cfg (Host_WriteConfiguration also wants
 * host_initialized, a writable com_gamedir, and a registered cvar), and a
 * declaration check proves none of them. This driver closes that gap from the
 * other end: it does not ask what the flags say, it asks what landed in the
 * file.
 *
 * The list of 27 is HARDCODED below rather than derived, which is the
 * opposite of the shell script's choice and for a reason the shell script
 * does not have: this driver is handed a basedir, not a checkout, so at run
 * time it has no path to App/Sources to derive from, and generating a header
 * would put a build step in front of a one-command test. The cost of a
 * hardcoded list is that a renamed or deleted cvar would be checked as a
 * ghost and pass, so every name is also looked up in the live registry and
 * must be found there. A name that stops existing fails loudly; a 28th name
 * that nobody adds here is what check-rig-store.sh is for.
 *
 * vr_movescale_air is the positive control. It is archived ON PURPOSE (the
 * player owns it, not the profile), so a run where the 27 are absent AND
 * vr_movescale_air is present cannot be a run where the file was empty, the
 * write silently failed, or the matcher broke. host_maxfps and
 * vr_movescale_hands are two more of the same, from two different files.
 *
 * Nothing is written into the basedir. The driver mkdtemp's its own tree and
 * symlinks the paks in, so the gamedir starts with NO config.cfg and the
 * absence can be asserted before the first write -- which matters, because
 * when fopen fails Host_WriteConfiguration only prints and returns, and a
 * stale file left in place would let every assertion below pass on a write
 * that never happened.
 */

#include "quakedef.h"
#include "QuakeCore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <dirent.h>

/* The audio sink is Swift and is not in the host objects; hostmain.c carries
 * the same four stand-ins for `make check`, and the unit harness gets them
 * from tools/unittest/support instead. Returning 0 from open leaves the
 * engine with no sound device, which is the right headless answer. */
int QC_AudioOpen (int speed, int channels, int bits, unsigned char **buffer, int *mono_samples)
{
	(void)speed; (void)channels; (void)bits;
	if (buffer) *buffer = NULL;
	if (mono_samples) *mono_samples = 0;
	return 0;
}
int  QC_AudioSamplePos (void) { return 0; }
void QC_AudioClose (void) { }
void QC_AudioSetRunning (int running) { (void)running; }

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

/* Swallowed on purpose. sys_avp.c's QAVP_Emit already mirrors every
   Con_Printf to stdout with a raw write(2) so a device run can be read over
   devicectl, so a gymtest-style fputs here would print the engine's whole
   boot twice and bury the pass/fail lines in it. */
static void on_log (void *c, const char *t) { (void)c; (void)t; }
static void on_error (void *c, const char *e) { (void)c; if (e) printf("FATAL: %s\n", e); }

/*
The cvars the Swift input profile pushes, from App/Sources/InputProfile.swift
and App/Sources/WeaponTrim.swift. Each one has a store on the Swift side, so
an archived copy per game pack is a second store that a `game` switch replays
over the live profile. See check-rig-store.sh's header for what that cost on
device.
*/
static const char * const owned[] = {
	"vr_aimpitch",
	"vr_aimyaw",
	"vr_laser",
	"vr_lasercolor",
	"vr_laserforward",
	"vr_laserpitch",
	"vr_laserside",
	"vr_laserup",
	"vr_laseryaw",
	"vr_reticle",
	"vr_reticle_arcs",
	"vr_reticlecolor",
	"vr_reticlestyle",
	"vr_weaponback",
	"vr_weaponclip",
	"vr_weaponclipback",
	"vr_weapongrip",
	"vr_weaponside",
	"vr_weaponup",
	"vr_wheelclip",
	"vr_wheelfwd",
	"vr_wheelpitch",
	"vr_wheelradius",
	"vr_wheelroll",
	"vr_wheelside",
	"vr_wheelup",
	"vr_wheelyaw"
};
#define OWNED_COUNT	((int)(sizeof(owned) / sizeof(owned[0])))

/* The written file, held whole so the matcher can run over it repeatedly. */
static char	cfg[256 * 1024];
static size_t	cfg_len;

static int read_cfg (const char *path)
{
	FILE	*f;

	cfg_len = 0;
	cfg[0] = 0;
	f = fopen (path, "r");
	if (!f)
		return 0;
	cfg_len = fread (cfg, 1, sizeof(cfg) - 1, f);
	cfg[cfg_len] = 0;
	fclose (f);
	return 1;
}

/*
The value config.cfg carries for `name`, or NULL when no line is for it.

Matched as the FIRST TOKEN of a line, never as a substring of the file, and
the reason is the names themselves: `vr_laser` is a prefix of six of its
neighbours and `vr_reticle` of two, so a substring hit would report
vr_reticle present whenever vr_reticlestyle was. A bind line is
`bind "KEY" "command"` and can carry a cvar name inside the command string,
which is a second way a substring match would name the wrong offender.
*/
static const char *cfg_value (const char *name, char *out, size_t outsz)
{
	const char	*line, *p;
	size_t		namelen = strlen (name);

	for (line = cfg; *line; )
	{
		const char	*eol = strchr (line, '\n');
		size_t		toklen;

		if (!eol)
			eol = line + strlen (line);

		for (p = line; p < eol && *p != ' ' && *p != '\t'; p++)
			;
		toklen = (size_t)(p - line);

		if (toklen == namelen && !memcmp (line, name, namelen))
		{
			size_t	n = 0;

			while (p < eol && (*p == ' ' || *p == '\t'))
				p++;
			if (p < eol && *p == '"')
			{
				p++;
				while (p < eol && *p != '"' && n + 1 < outsz)
					out[n++] = *p++;
			}
			else
			{
				while (p < eol && n + 1 < outsz)
					out[n++] = *p++;
			}
			out[n] = 0;
			return out;
		}

		line = (*eol == '\n') ? eol + 1 : eol;
	}
	return NULL;
}

/*
A gamedir of this driver's own, so the basedir it was pointed at is left
exactly as it was found.

The engine reads its data through the search path and writes only into
com_gamedir, so a tree of symlinks to the paks is a complete basedir as far
as this test is concerned, and starts with no config.cfg in it.
*/
static char	workdir[MAX_OSPATH];

static int make_workdir (const char *basedir)
{
	char		tmpl[MAX_OSPATH], src[MAX_OSPATH], dst[MAX_OSPATH];
	const char	*tmp = getenv ("TMPDIR");
	size_t		n;
	int		i, paks = 0;

	if (!tmp || !*tmp)
		tmp = "/tmp";
	q_strlcpy (tmpl, tmp, sizeof(tmpl));
	n = strlen (tmpl);
	while (n > 1 && tmpl[n - 1] == '/')
		tmpl[--n] = 0;
	q_strlcat (tmpl, "/cfgtest.XXXXXX", sizeof(tmpl));

	if (!mkdtemp (tmpl))
		return 0;
	q_strlcpy (workdir, tmpl, sizeof(workdir));

	q_snprintf (dst, sizeof(dst), "%s/id1", workdir);
	if (mkdir (dst, 0755) != 0)
		return 0;

	for (i = 0; i < 4; i++)
	{
		q_snprintf (src, sizeof(src), "%s/id1/pak%d.pak", basedir, i);
		if (access (src, R_OK) != 0)
			continue;
		q_snprintf (dst, sizeof(dst), "%s/id1/pak%d.pak", workdir, i);
		if (symlink (src, dst) == 0)
			paks++;
	}
	return paks > 0;
}

/* Best effort, one level down, which is as deep as this tree goes. */
static void remove_workdir (void)
{
	DIR		*d;
	struct dirent	*e;
	char		path[MAX_OSPATH], sub[MAX_OSPATH];

	q_snprintf (path, sizeof(path), "%s/id1", workdir);
	d = opendir (path);
	if (d)
	{
		while ((e = readdir (d)) != NULL)
		{
			if (!strcmp (e->d_name, ".") || !strcmp (e->d_name, ".."))
				continue;
			q_snprintf (sub, sizeof(sub), "%s/%s", path, e->d_name);
			unlink (sub);
		}
		closedir (d);
	}
	rmdir (path);

	d = opendir (workdir);
	if (d)
	{
		while ((e = readdir (d)) != NULL)
		{
			if (!strcmp (e->d_name, ".") || !strcmp (e->d_name, ".."))
				continue;
			q_snprintf (sub, sizeof(sub), "%s/%s", workdir, e->d_name);
			unlink (sub);
		}
		closedir (d);
	}
	rmdir (workdir);
}

int main (int argc, char **argv)
{
	char		path[MAX_OSPATH], val[256], second[256];
	const char	*written;
	cvar_t		*var;
	int		i;

	if (argc < 2)
	{
		printf ("usage: cfgtest <basedir>\n");
		return 2;
	}

	if (!make_workdir (argv[1]))
	{
		printf ("could not build a work basedir from %s/id1\n", argv[1]);
		return 2;
	}
	printf ("      (work basedir %s)\n", workdir);

	QC_SetCallbacks (on_log, on_error, NULL);
	QC_SetPaths (workdir, workdir);
	{ const char *a[2] = { "-basedir", workdir };
	  if (!QC_Init (2, a)) { printf ("init failed\n"); remove_workdir (); return 1; } }

	/* The boot chain (default.cfg, then any config.cfg) runs through the
	   command buffer, so the archived values are not live until some
	   frames have gone by. Write before that and the file would record
	   compiled-in defaults rather than what the engine is running on. */
	for (i = 0; i < 10; i++)
		QC_Frame (1.0 / 72.0);

	q_snprintf (path, sizeof(path), "%s/config.cfg", com_gamedir);
	printf ("      (com_gamedir %s)\n", com_gamedir);

	CHECK (access (path, F_OK) != 0,
	       "the gamedir holds no config.cfg before the first write");

	/* ---------------- the writer runs ---------------------------------- */

	Host_WriteConfiguration ();

	CHECK (read_cfg (path), "Host_WriteConfiguration wrote %s", path);
	CHECK (cfg_len > 0, "and the file is not empty (%zu bytes)", cfg_len);

	/* ---------------- the positive controls, first ---------------------
	   Before the absence check, because an absence proves nothing until
	   the file is known to be readable and the matcher known to find a
	   line that is really there. */

	written = cfg_value ("vr_movescale_air", val, sizeof(val));
	CHECK (written != NULL, "vr_movescale_air IS written, as it should be (%s)",
	       written ? written : "missing");

	written = cfg_value ("host_maxfps", val, sizeof(val));
	CHECK (written != NULL, "host_maxfps is written (%s)",
	       written ? written : "missing");

	written = cfg_value ("vr_movescale_hands", val, sizeof(val));
	CHECK (written != NULL, "vr_movescale_hands is written (%s)",
	       written ? written : "missing");

	/* ---------------- and none of the 27 ------------------------------- */

	for (i = 0; i < OWNED_COUNT; i++)
	{
		var = Cvar_FindVar (owned[i]);
		written = cfg_value (owned[i], val, sizeof(val));

		if (!var)
			CHECK (0, "%s is in this driver's list but no such cvar is "
			       "registered -- it was renamed or removed, and the "
			       "check above it was vacuous", owned[i]);
		else if (var->flags & CVAR_ARCHIVE)
			/* Both angles in one line: the declaration says it is
			   archived and the file says what that cost. */
			CHECK (0, "%s is declared CVAR_ARCHIVE, so every installed "
			       "pack keeps its own frozen copy of a profile value "
			       "(written config carries %s)", owned[i],
			       written ? written : "no line for it");
		else
			CHECK (written == NULL,
			       "%s is profile-owned and absent from the written "
			       "config%s%s", owned[i],
			       written ? ", but the file carries " : "",
			       written ? written : "");
	}

	/* ---------------- a changed value round-trips ----------------------
	   Through the console, which is the route the player and the Swift
	   side both take, and set as a STRING so the written line is not at
	   the mercy of float formatting. Removing the file first means the
	   second read cannot be satisfied by the first write. */

	QC_ExecuteCommand ("vr_movescale_air 0.37\n");
	QC_Frame (1.0 / 72.0);

	var = Cvar_FindVar ("vr_movescale_air");
	CHECK (var && !strcmp (var->string, "0.37"),
	       "the console sets vr_movescale_air live (value \"%s\")",
	       var ? var->string : "unregistered");

	unlink (path);
	Host_WriteConfiguration ();
	CHECK (read_cfg (path), "a second write re-creates the file");

	written = cfg_value ("vr_movescale_air", second, sizeof(second));
	CHECK (written && !strcmp (written, "0.37"),
	       "and it carries the changed value (\"%s\", expected \"0.37\")",
	       written ? written : "missing");

	/* No QC_Shutdown, on purpose, and not only because gymtest returns
	   straight from main too: Host_Shutdown writes the config one more
	   time, which would put the file back inside the tree this line is
	   about to remove. Everything the assertions read has been read by
	   now. */
	remove_workdir ();

	printf (failures ? "\n%d FAILURES\n" : "\nall passed\n", failures);
	return failures ? 1 : 0;
}
