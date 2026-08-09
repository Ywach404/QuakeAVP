/*
 * sys_avp.c -- system layer for visionOS / Apple platforms.
 *
 * Replaces QuakeSpasm's sys_sdl_unix.c. Plain POSIX where possible; the parts
 * that differ from a desktop UNIX are:
 *   - No stdin console. Sys_ConsoleInput() always returns NULL.
 *   - Sys_Error()/Sys_Quit() must not longjmp out of the host loop from a
 *     background thread, so they route through a host-owned error hook that
 *     the Swift side can surface as UI. See QuakeCore.h.
 *   - The base directory is the app bundle; the userdir is Application Support.
 *     Both are handed in from Swift via QC_SetPaths() before QC_Init().
 */

#include "quakedef.h"
#include "QuakeCore.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

qboolean		isDedicated = false;

/* Set by QC_SetLogHandler(); nil means fall back to fputs(stderr). */
static qc_log_fn	qavp_log_fn;
static qc_error_fn	qavp_error_fn;
static void		*qavp_cb_ctx;

void QC_SetCallbacks (qc_log_fn log, qc_error_fn err, void *ctx)
{
	qavp_log_fn = log;
	qavp_error_fn = err;
	qavp_cb_ctx = ctx;
}

static void QAVP_Emit (const char *text)
{
	if (qavp_log_fn)
		qavp_log_fn (qavp_cb_ctx, text);
	else
		fputs (text, stderr);
}

/* ------------------------------------------------------------------ files
 *
 * Quake's file handles are small ints into a fixed table -- a 1996 API that
 * survives because savegames and demos use it. Straight POSIX underneath.
 */

#define MAX_HANDLES	32	/* johnfitz -- was 10 */
static FILE	*sys_handles[MAX_HANDLES];

static int filelength (FILE *f)
{
	long pos, end;

	pos = ftell (f);
	fseek (f, 0, SEEK_END);
	end = ftell (f);
	fseek (f, pos, SEEK_SET);

	return (int) end;
}

static int findhandle (void)
{
	int i;

	for (i = 1; i < MAX_HANDLES; i++)
	{
		if (!sys_handles[i])
			return i;
	}
	Sys_Error ("out of handles");
	return -1;
}

int Sys_FileOpenRead (const char *path, int *hndl)
{
	FILE	*f;
	int	i, retval;

	i = findhandle ();
	f = fopen (path, "rb");

	if (!f)
	{
		*hndl = -1;
		retval = -1;
	}
	else
	{
		sys_handles[i] = f;
		*hndl = i;
		retval = filelength (f);
	}

	return retval;
}

int Sys_FileOpenWrite (const char *path)
{
	FILE	*f;
	int	i;

	i = findhandle ();
	f = fopen (path, "wb");

	if (!f)
		Sys_Error ("Error opening %s: %s", path, strerror(errno));

	sys_handles[i] = f;
	return i;
}

void Sys_FileClose (int handle)
{
	if (handle >= 0 && handle < MAX_HANDLES && sys_handles[handle])
	{
		fclose (sys_handles[handle]);
		sys_handles[handle] = NULL;
	}
}

void Sys_FileSeek (int handle, int position)
{
	if (handle >= 0 && handle < MAX_HANDLES && sys_handles[handle])
		fseek (sys_handles[handle], position, SEEK_SET);
}

int Sys_FileRead (int handle, void *dest, int count)
{
	unsigned char	*buf;
	size_t		bytes;

	if (handle < 0 || handle >= MAX_HANDLES || !sys_handles[handle])
		return 0;

	buf = (unsigned char *) dest;
	bytes = fread (buf, 1, (size_t)count, sys_handles[handle]);

	if (bytes < (size_t)count && ferror(sys_handles[handle]))
		return -1;

	return (int) bytes;
}

int Sys_FileWrite (int handle, const void *data, int count)
{
	size_t bytes;

	if (handle < 0 || handle >= MAX_HANDLES || !sys_handles[handle])
		return 0;

	bytes = fwrite (data, 1, (size_t)count, sys_handles[handle]);

	if (bytes < (size_t)count && ferror(sys_handles[handle]))
		return -1;

	return (int) bytes;
}

int Sys_FileType (const char *path)
{
	struct stat st;

	if (stat(path, &st) != 0)
		return FS_ENT_NONE;
	if (S_ISDIR(st.st_mode))
		return FS_ENT_DIRECTORY;
	if (S_ISREG(st.st_mode))
		return FS_ENT_FILE;
	return FS_ENT_NONE;
}

void Sys_mkdir (const char *path)
{
	int rc = mkdir (path, 0777);

	if (rc != 0 && errno == EEXIST)
	{
		struct stat st;
		if (stat(path, &st) == 0 && S_ISDIR(st.st_mode))
			rc = 0;
	}
	if (rc != 0)
	{
		rc = errno;
		Sys_Error ("Unable to create directory %s: %s", path, strerror(rc));
	}
}

/* ------------------------------------------------------------- lifecycle */

void Sys_Init (void)
{
	/* Nothing to do: no signal handlers, no console allocation, no timer
	   subsystem. Frame timing comes from CompositorServices later on; for
	   now Sys_DoubleTime() is a monotonic clock. */
}

void Sys_Printf (const char *fmt, ...)
{
	va_list	argptr;
	char	text[1024];

	va_start (argptr, fmt);
	q_vsnprintf (text, sizeof(text), fmt, argptr);
	va_end (argptr);

	QAVP_Emit (text);
}

void Sys_Quit (void)
{
	Host_Shutdown ();
	if (qavp_error_fn)
		qavp_error_fn (qavp_cb_ctx, NULL);	/* NULL == clean exit */
	exit (0);
}

void Sys_Error (const char *error, ...)
{
	va_list	argptr;
	char	text[1024];

	va_start (argptr, error);
	q_vsnprintf (text, sizeof(text), error, argptr);
	va_end (argptr);

	QAVP_Emit ("\nQuake Error: ");
	QAVP_Emit (text);
	QAVP_Emit ("\n");

	Host_Shutdown ();

	if (qavp_error_fn)
		qavp_error_fn (qavp_cb_ctx, text);

	exit (1);
}

double Sys_DoubleTime (void)
{
	struct timespec ts;

	clock_gettime (CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1.0e9;
}

const char *Sys_ConsoleInput (void)
{
	/* No stdin on device. Commands arrive from the Swift shell via
	   QC_ExecuteCommand() -> Cbuf_AddText(). */
	return NULL;
}

void Sys_Sleep (unsigned long msecs)
{
	usleep (msecs * 1000);
}

void Sys_SendKeyEvents (void)
{
	IN_SendKeyEvents ();
}
