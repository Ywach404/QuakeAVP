/*
 * gl_stubs.c -- TEMPORARY. Delete at M2.
 *
 * No-op bodies for the GL1 immediate-mode calls that sbar.c and view.c make
 * directly. See the comment block at the bottom of gl_shim.h for why these
 * exist and what replaces them.
 *
 * Consequences today: the status bar renders without its scissor clip, and
 * V_PolyBlend() (the red/underwater screen tint) does nothing. Neither is
 * visible at M0 because nothing draws at all.
 */

#include "quakedef.h"

void glEnable (GLenum cap)			{ (void)cap; }
void glDisable (GLenum cap)			{ (void)cap; }
void glBegin (GLenum mode)			{ (void)mode; }
void glEnd (void)				{ }
void glVertex2f (GLfloat x, GLfloat y)		{ (void)x; (void)y; }
void glColor4f (GLfloat r, GLfloat g, GLfloat b, GLfloat a)
						{ (void)r; (void)g; (void)b; (void)a; }
void glColor4fv (const GLfloat *v)		{ (void)v; }
void glMatrixMode (GLenum mode)			{ (void)mode; }
void glLoadIdentity (void)			{ }
void glOrtho (GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f)
						{ (void)l; (void)r; (void)b; (void)t; (void)n; (void)f; }
void glScissor (GLint x, GLint y, GLsizei w, GLsizei h)
						{ (void)x; (void)y; (void)w; (void)h; }
