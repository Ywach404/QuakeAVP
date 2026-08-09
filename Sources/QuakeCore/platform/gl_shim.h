/*
 * gl_shim.h -- QuakeSpasm-on-visionOS
 *
 * visionOS ships no OpenGL and no SDL. QuakeSpasm's headers (glquake.h,
 * gl_texmgr.h, gl_model.h) are woven through the engine core and reference GL
 * scalar types, so ripping them out would mean touching nearly every file.
 *
 * Instead this header supplies exactly the GL typedefs and enum constants the
 * headers need in order to *parse*. No GL entry points are declared and none
 * exist at link time -- anything that actually tried to call OpenGL lives in
 * the gl_*.c renderer files, which are not part of this target.
 *
 * When the Metal renderer lands (M2), the `GLuint texnum` fields in
 * gltexture_t become opaque Metal texture handles and this file shrinks.
 */

#ifndef QAVP_GL_SHIM_H
#define QAVP_GL_SHIM_H

#include <stdint.h>
#include <stddef.h>

typedef unsigned int	GLenum;
typedef unsigned char	GLboolean;
typedef unsigned int	GLbitfield;
typedef void		GLvoid;
typedef signed char	GLbyte;
typedef short		GLshort;
typedef int		GLint;
typedef unsigned char	GLubyte;
typedef unsigned short	GLushort;
typedef unsigned int	GLuint;
typedef int		GLsizei;
typedef float		GLfloat;
typedef float		GLclampf;
typedef double		GLdouble;
typedef double		GLclampd;
typedef char		GLchar;
typedef ptrdiff_t	GLintptr;
typedef ptrdiff_t	GLsizeiptr;

/* ARB_vertex_buffer_object spellings used by glquake.h */
typedef ptrdiff_t	GLintptrARB;
typedef ptrdiff_t	GLsizeiptrARB;
typedef char		GLcharARB;
typedef unsigned int	GLhandleARB;

#ifndef APIENTRY
#define APIENTRY
#endif
#ifndef APIENTRYP
#define APIENTRYP APIENTRY *
#endif
#ifndef GLAPIENTRY
#define GLAPIENTRY APIENTRY
#endif

/* glquake.h declares extern PFNGL*ARBPROC function pointers for the VBO path.
   They are never assigned (gl_vidsdl.c did that) but the types must exist. */
typedef void  (APIENTRYP PFNGLBINDBUFFERARBPROC)     (GLenum target, GLuint buffer);
typedef void  (APIENTRYP PFNGLBUFFERDATAARBPROC)     (GLenum target, GLsizeiptrARB size, const GLvoid *data, GLenum usage);
typedef void  (APIENTRYP PFNGLBUFFERSUBDATAARBPROC)  (GLenum target, GLintptrARB offset, GLsizeiptrARB size, const GLvoid *data);
typedef void  (APIENTRYP PFNGLDELETEBUFFERSARBPROC)  (GLsizei n, const GLuint *buffers);
typedef void  (APIENTRYP PFNGLGENBUFFERSARBPROC)     (GLsizei n, GLuint *buffers);
typedef void  (APIENTRYP PFNGLMULTITEXCOORD2FARBPROC)(GLenum target, GLfloat s, GLfloat t);
typedef void  (APIENTRYP PFNGLACTIVETEXTUREARBPROC)  (GLenum texture);
typedef void  (APIENTRYP PFNGLCLIENTACTIVETEXTUREARBPROC)(GLenum texture);

/* The handful of enum values QuakeSpasm's headers reference by name. */
#ifndef GL_FALSE
#define GL_FALSE			0
#define GL_TRUE				1
#endif
#ifndef GL_TEXTURE0_ARB
#define GL_TEXTURE0_ARB			0x84C0
#define GL_TEXTURE1_ARB			0x84C1
#endif
#ifndef GL_ARRAY_BUFFER_ARB
#define GL_ARRAY_BUFFER_ARB		0x8892
#define GL_ELEMENT_ARRAY_BUFFER_ARB	0x8893
#define GL_STATIC_DRAW_ARB		0x88E4
#endif

/*
 * ---------------------------------------------------------------------------
 * Immediate-mode leakage.
 *
 * Two "core" files -- sbar.c and view.c -- reach past the renderer and issue
 * raw GL1 calls to draw the sbar scissor box and the fullscreen polyblend.
 * That is the only place the engine/renderer split is genuinely violated.
 *
 * Rather than patch upstream now, the calls are declared here and defined as
 * no-ops in gl_stubs.c. They are the M2 to-do list: when the Metal renderer
 * lands, sbar.c and view.c get patched to call an R2D_* abstraction and this
 * whole block, plus gl_stubs.c, is deleted.
 * ---------------------------------------------------------------------------
 */
#define GL_ALPHA_TEST			0x0BC0
#define GL_BLEND			0x0BE2
#define GL_DEPTH_TEST			0x0B71
#define GL_SCISSOR_TEST			0x0C11
#define GL_TEXTURE_2D			0x0DE1
#define GL_PROJECTION			0x1701
#define GL_MODELVIEW			0x1700
#define GL_QUADS			0x0007

void glEnable (GLenum cap);
void glDisable (GLenum cap);
void glBegin (GLenum mode);
void glEnd (void);
void glVertex2f (GLfloat x, GLfloat y);
void glColor4f (GLfloat r, GLfloat g, GLfloat b, GLfloat a);
void glColor4fv (const GLfloat *v);
void glMatrixMode (GLenum mode);
void glLoadIdentity (void);
void glOrtho (GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f);
void glScissor (GLint x, GLint y, GLsizei w, GLsizei h);

#endif /* QAVP_GL_SHIM_H */
