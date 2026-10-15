/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 A. Cervantez
 *
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

float	qr_draw_color[4] = {1.f, 1.f, 1.f, 1.f};	/* read by the ported Draw_* */

void glColor4f (GLfloat r, GLfloat g, GLfloat b, GLfloat a)
{
	qr_draw_color[0] = r; qr_draw_color[1] = g;
	qr_draw_color[2] = b; qr_draw_color[3] = a;
}
void glColor4fv (const GLfloat *v)
{
	qr_draw_color[0] = v[0]; qr_draw_color[1] = v[1];
	qr_draw_color[2] = v[2]; qr_draw_color[3] = v[3];
}
void glMatrixMode (GLenum mode)			{ (void)mode; }
void glLoadIdentity (void)			{ }
void glOrtho (GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f)
						{ (void)l; (void)r; (void)b; (void)t; (void)n; (void)f; }
void glScissor (GLint x, GLint y, GLsizei w, GLsizei h)
						{ (void)x; (void)y; (void)w; (void)h; }
