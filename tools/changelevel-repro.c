/*
 * changelevel-repro.c -- headless repro for the start-map -> episode crash.
 * Not part of the app. Boots the engine against a real basedir, loads the
 * `start` hub, then issues `changelevel e1m1` (the server-side path a slipgate
 * fires, including SV_SaveSpawnparms, which `map` skips). Run under ASan to
 * catch an engine/bridge memory crash off-device.
 */

#include "QuakeCore.h"

#include <stdio.h>
#include <string.h>

static void on_log (void *ctx, const char *text)
{
	(void) ctx;
	fputs (text, stdout);
}

static void on_error (void *ctx, const char *err)
{
	(void) ctx;
	fprintf (stderr, "\n[repro] fatal: %s\n", err ? err : "(clean quit)");
}

/* Audio sink lives in Swift; stub it so S_Init disables sound (headless). */
int QC_AudioOpen (int speed, int channels, int bits,
		  unsigned char **buffer, int *mono_samples)
{
	(void) speed; (void) channels; (void) bits;
	if (buffer) *buffer = NULL;
	if (mono_samples) *mono_samples = 0;
	return 0;
}
int  QC_AudioSamplePos (void) { return 0; }
void QC_AudioClose (void) { }
void QC_AudioSetRunning (int running) { (void) running; }

static void pump (int frames)
{
	int i;
	for (i = 0; i < frames; i++)
		QC_Frame (1.0 / 72.0);
}

int main (int argc, char **argv)
{
	const char *args[4];
	int n = 0;

	if (argc < 2) { fprintf (stderr, "usage: %s <basedir>\n", argv[0]); return 2; }

	QC_SetCallbacks (on_log, on_error, NULL);
	QC_SetPaths (argv[1], argv[1]);
	args[n++] = "-basedir";
	args[n++] = argv[1];

	if (!QC_Init (n, args)) { fprintf (stderr, "[repro] QC_Init failed\n"); return 1; }

	fprintf (stderr, "\n[repro] === map start ===\n");
	QC_ExecuteCommand ("map start\n");
	pump (90);

	fprintf (stderr, "\n[repro] === changelevel e1m1 (the slipgate path) ===\n");
	QC_ExecuteCommand ("changelevel e1m1\n");
	pump (180);

	fprintf (stderr, "\n[repro] survived the changelevel; no engine-side crash\n");
	QC_Shutdown ();
	return 0;
}
