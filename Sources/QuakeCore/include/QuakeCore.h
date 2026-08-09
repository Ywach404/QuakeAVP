/*
 * QuakeCore.h -- the entire C surface Swift is allowed to touch.
 *
 * Everything else in this library is QuakeSpasm internals. Keep this header
 * free of quakedef.h so the bridging header stays cheap and Swift never sees
 * `byte`, `qboolean`, or a 400-symbol namespace.
 */

#ifndef QUAKECORE_H
#define QUAKECORE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Engine stdout/stderr. Called on whatever thread the host loop runs on. */
typedef void (*qc_log_fn)(void *ctx, const char *text);

/* Fatal error, or NULL for a clean Sys_Quit. The process exits right after
   this returns, so hand the text off; do not try to resume. */
typedef void (*qc_error_fn)(void *ctx, const char *error_or_null);

void QC_SetCallbacks (qc_log_fn log, qc_error_fn err, void *ctx);

/*
 * basedir  -- directory containing id1/ (the app bundle's Resources, or a
 *             user-picked folder holding pak0.pak).
 * userdir  -- writable directory for config.cfg and savegames
 *             (Application Support/QuakeAVP).
 * Must be called before QC_Init.
 */
void QC_SetPaths (const char *basedir, const char *userdir);

/*
 * Boot the engine. argv is a Quake-style command line, e.g.
 * {"-basedir", "...", "+map", "start"}. Returns false if init bailed.
 */
bool QC_Init (int argc, const char * const *argv);

/* Advance the simulation by `dt` seconds. Safe to call at display rate. */
void QC_Frame (double dt);

void QC_Shutdown (void);

/* Push a console command, e.g. "map e1m1\n". */
void QC_ExecuteCommand (const char *text);

/* True once Host_Init has completed successfully. */
bool QC_IsRunning (void);

/* Engine version string, for the about pane. */
const char *QC_VersionString (void);

#ifdef __cplusplus
}
#endif

#endif /* QUAKECORE_H */
