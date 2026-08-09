/*
 * r_null.c -- the refresh stub. This file IS the M2 work item.
 *
 * It replaces, in one place, everything QuakeSpasm's OpenGL renderer provided:
 *   gl_rmain.c gl_rmisc.c gl_screen.c gl_draw.c gl_texmgr.c
 *   gl_warp.c gl_sky.c gl_fog.c gl_mesh.c gl_rlight.c
 *   r_alias.c r_brush.c r_part.c r_sprite.c r_world.c
 *
 * The contract those files satisfy is: own the cvars and globals the rest of
 * the engine reads, accept geometry/texture registration at map load, and draw
 * when asked. Here everything draws nothing -- but the *state* is real, because
 * the sim, the menu, the console, and host_cmd all read these cvars and would
 * misbehave against zeroes. Defaults below are copied verbatim from upstream.
 *
 * What this proves at M0: the engine boots, loads a BSP, runs the server and
 * client, and ticks -- with no renderer at all. What it does not do: pixels.
 *
 * When the Metal renderer lands, delete this file and bring back real
 * implementations one section at a time; the section headers map 1:1 onto the
 * upstream files listed above.
 */

#include "quakedef.h"

/* ========================================================================
 * gl_rmain.c -- view state and cvars
 * ===================================================================== */

refdef_t	r_refdef;
vec3_t		r_origin, vpn, vright, vup;
int		r_framecount;
int		gl_warpimagesize;
qboolean	gl_glsl_gamma_able = false;

cvar_t	gl_clear		= {"gl_clear", "1", CVAR_NONE};
cvar_t	gl_polyblend		= {"gl_polyblend", "1", CVAR_NONE};
cvar_t	gl_subdivide_size	= {"gl_subdivide_size", "128", CVAR_ARCHIVE};

cvar_t	r_lerpmodels		= {"r_lerpmodels", "1", CVAR_NONE};
cvar_t	r_lerpmove		= {"r_lerpmove", "1", CVAR_NONE};
cvar_t	r_nolerp_list		= {"r_nolerp_list",
	"progs/flame.mdl,progs/flame2.mdl,progs/braztall.mdl,progs/brazshrt.mdl,"
	"progs/longtrch.mdl,progs/flame_pyre.mdl,progs/v_saw.mdl,progs/v_xfist.mdl,"
	"progs/h2stuff/newfire.mdl", CVAR_NONE};
cvar_t	r_noshadow_list		= {"r_noshadow_list",
	"progs/flame2.mdl,progs/flame.mdl,progs/bolt1.mdl,progs/bolt2.mdl,"
	"progs/bolt3.mdl,progs/laser.mdl", CVAR_NONE};

/* gl_vidsdl.c owned the gamma cvars; view.c reads them every frame. */
cvar_t	vid_gamma		= {"gamma", "1", CVAR_ARCHIVE};
cvar_t	vid_contrast		= {"contrast", "1", CVAR_ARCHIVE};

void R_Init (void)
{
	Cvar_RegisterVariable (&gl_clear);
	Cvar_RegisterVariable (&gl_polyblend);
	Cvar_RegisterVariable (&gl_subdivide_size);
	Cvar_RegisterVariable (&r_lerpmodels);
	Cvar_RegisterVariable (&r_lerpmove);
	Cvar_RegisterVariable (&r_nolerp_list);
	Cvar_RegisterVariable (&r_noshadow_list);
	Cvar_RegisterVariable (&vid_gamma);
	Cvar_RegisterVariable (&vid_contrast);

	Con_Printf ("R_Init: null refresh (Metal renderer lands at M2)\n");
}

void R_NewGame (void)
{
}

void R_NewMap (void)
{
	r_framecount = 0;
}

void R_RenderView (void)
{
}

void R_TranslatePlayerSkin (int playernum)
{
	(void) playernum;
}

void R_TranslateNewPlayerSkin (int playernum)
{
	(void) playernum;
}

/* ========================================================================
 * gl_screen.c -- 2D screen state
 * ===================================================================== */

float		scr_con_current;
int		clearnotify;
int		scr_tileclear_updates = 0;
float		scr_centertime_off;
qboolean	scr_disabled_for_loading;

cvar_t	scr_viewsize	= {"viewsize", "100", CVAR_ARCHIVE};
cvar_t	scr_sbaralpha	= {"scr_sbaralpha", "0.75", CVAR_ARCHIVE};
cvar_t	scr_sbarscale	= {"scr_sbarscale", "1", CVAR_ARCHIVE};
cvar_t	scr_conscale	= {"scr_conscale", "1", CVAR_ARCHIVE};

/* sys_avp.c would be the natural home, but upstream keeps it in the platform
   sys_*.c file and host.c registers it. Same thing. */
cvar_t	sys_throttle	= {"sys_throttle", "0.02", CVAR_ARCHIVE};

void SCR_Init (void)
{
	Cvar_RegisterVariable (&scr_viewsize);
	Cvar_RegisterVariable (&scr_sbaralpha);
	Cvar_RegisterVariable (&scr_sbarscale);
	Cvar_RegisterVariable (&scr_conscale);
}

void SCR_UpdateScreen (void)
{
}

void SCR_CenterPrint (const char *str)
{
	/* The message still belongs in the console log even with no HUD --
	   this is how you can tell the sim is alive at M0. */
	if (str && *str)
		Con_Printf ("%s\n", str);
	scr_centertime_off = 0;
}

void SCR_BeginLoadingPlaque (void)
{
	scr_disabled_for_loading = true;
}

void SCR_EndLoadingPlaque (void)
{
	scr_disabled_for_loading = false;
	Con_ClearNotify ();
}

int SCR_ModalMessage (const char *text, float timeout)
{
	/* Used for "are you sure you want to quit". No UI to answer with, so
	   answer yes -- the Swift shell owns confirmation dialogs. */
	(void) timeout;
	if (text)
		Con_Printf ("%s", text);
	return true;
}

/* ========================================================================
 * gl_draw.c -- 2D drawing
 * ===================================================================== */

qpic_t	*draw_disc;
qpic_t	*pic_ovr, *pic_ins;

/* A pic every caller can safely read width/height off and index into. 16x16
   keeps any (w/2) centring math from collapsing to zero. */
static struct {
	int	width, height;
	byte	data[16 * 16];
} qavp_dummypic = { 16, 16, {0} };

static qpic_t *QAVP_DummyPic (void)
{
	return (qpic_t *) &qavp_dummypic;
}

void Draw_Init (void)
{
	draw_disc = Draw_PicFromWad ("disc");
	pic_ovr = QAVP_DummyPic ();
	pic_ins = QAVP_DummyPic ();
}

void Draw_NewGame (void)
{
}

qpic_t *Draw_PicFromWad (const char *name)
{
	/* Honest implementation: gfx.wad is already resident and the lump is a
	   qpic_t. Returning it gives correct dimensions for free and exercises
	   the WAD path at M0, which is worth having tested. */
	qpic_t *p = (qpic_t *) W_GetLumpName (name);

	if (!p)
		return QAVP_DummyPic ();

	p->width = LittleLong (p->width);
	p->height = LittleLong (p->height);
	return p;
}

qpic_t *Draw_CachePic (const char *path)
{
	/* TODO(M2): load the .lmp and cache it. Doing that properly needs a
	   cache whose lifetime survives Hunk_FreeToLowMark on map change, which
	   is renderer bookkeeping -- not worth building twice. */
	(void) path;
	return QAVP_DummyPic ();
}

void Draw_Character (int x, int y, int num)			{ (void)x; (void)y; (void)num; }
void Draw_DebugChar (char num)					{ (void)num; }
void Draw_Pic (int x, int y, qpic_t *pic)			{ (void)x; (void)y; (void)pic; }
void Draw_ConsoleBackground (void)				{ }
void Draw_TileClear (int x, int y, int w, int h)		{ (void)x; (void)y; (void)w; (void)h; }
void Draw_FadeScreen (void)					{ }
void Draw_String (int x, int y, const char *str)		{ (void)x; (void)y; (void)str; }

void Draw_Fill (int x, int y, int w, int h, int c, float alpha)
{
	(void)x; (void)y; (void)w; (void)h; (void)c; (void)alpha;
}

void Draw_TransPicTranslate (int x, int y, qpic_t *pic, int top, int bottom)
{
	(void)x; (void)y; (void)pic; (void)top; (void)bottom;
}

void GL_SetCanvas (canvastype newcanvas)
{
	(void) newcanvas;
}

/* ========================================================================
 * gl_texmgr.c -- texture manager
 * ===================================================================== */

unsigned int	d_8to24table[256];
unsigned int	d_8to24table_fbright[256];
unsigned int	d_8to24table_fbright_fence[256];
unsigned int	d_8to24table_nobright[256];
unsigned int	d_8to24table_nobright_fence[256];
unsigned int	d_8to24table_conchars[256];

gltexture_t	*notexture;
gltexture_t	*nulltexture;

/*
 * Model loading calls TexMgr_LoadImage for every wall texture, skin and
 * sprite frame, and stores the returned pointer in the model. So this cannot
 * return NULL -- but it also must not upload anything. It hands back a record
 * of what *would* have been uploaded.
 *
 * At M2 this becomes the Metal texture atlas: the source_file/source_offset
 * fields upstream already tracks are exactly what a deferred/streaming
 * uploader needs, so the shape of this struct survives.
 */
#define QAVP_MAX_TEXTURES	4096
static gltexture_t	qavp_textures[QAVP_MAX_TEXTURES];
static int		qavp_numtextures;

void TexMgr_Init (void)
{
	qavp_numtextures = 0;
	notexture = TexMgr_NewTexture ();
	nulltexture = TexMgr_NewTexture ();
	q_strlcpy (notexture->name, "notexture", sizeof(notexture->name));
	q_strlcpy (nulltexture->name, "nulltexture", sizeof(nulltexture->name));
	notexture->width = notexture->height = 16;
	nulltexture->width = nulltexture->height = 16;
}

void TexMgr_NewGame (void)
{
}

gltexture_t *TexMgr_NewTexture (void)
{
	if (qavp_numtextures >= QAVP_MAX_TEXTURES)
		Sys_Error ("TexMgr_NewTexture: overflow (%d)", QAVP_MAX_TEXTURES);

	return &qavp_textures[qavp_numtextures++];
}

gltexture_t *TexMgr_LoadImage (qmodel_t *owner, const char *name,
			       int width, int height, enum srcformat format,
			       byte *data, const char *source_file,
			       src_offset_t source_offset, unsigned flags)
{
	gltexture_t *glt;

	(void) data;
	(void) flags;

	glt = TexMgr_NewTexture ();
	glt->owner = owner;
	q_strlcpy (glt->name, name ? name : "", sizeof(glt->name));
	glt->width = (unsigned) width;
	glt->height = (unsigned) height;
	glt->source_width = (unsigned) width;
	glt->source_height = (unsigned) height;
	glt->source_format = format;
	glt->source_offset = source_offset;
	glt->shirt = -1;
	glt->pants = -1;
	q_strlcpy (glt->source_file, source_file ? source_file : "",
		   sizeof(glt->source_file));

	return glt;
}

void TexMgr_FreeTexturesForOwner (qmodel_t *owner)
{
	(void) owner;
	/* No GPU objects to release yet; the arena is reset by TexMgr_Init. */
}

int TexMgr_PadConditional (int s)
{
	/* Metal has no power-of-two requirement, so never pad. */
	return s;
}

void GL_DisableMultitexture (void)
{
}

/* glquake.h declares this as a function *pointer* (a GL extension entry
   point), not a function. Left null; nothing calls through it here. */
QS_PFNGENERATEMIPMAP GL_GenerateMipmap;

/* ========================================================================
 * gl_mesh.c / gl_warp.c / gl_sky.c / gl_fog.c -- map + model registration
 * ===================================================================== */

void GL_MakeAliasModelDisplayLists (qmodel_t *m, aliashdr_t *hdr)
{
	(void) m; (void) hdr;
}

void GLMesh_DeleteVertexBuffers (void)
{
}

void GL_SubdivideSurface (msurface_t *fa)
{
	(void) fa;
}

void Sky_ClearAll (void)			{ }
void Sky_LoadTexture (qmodel_t *m, texture_t *mt)	{ (void)m; (void)mt; }
void Sky_LoadTextureQ64 (qmodel_t *m, texture_t *mt)	{ (void)m; (void)mt; }
void Sky_LoadSkyBox (const char *name)		{ (void)name; }

void Fog_ParseServerMessage (void)
{
	/* svc_fog carries 5 bytes: density + rgb + time. They must be consumed
	   or the rest of the message stream desyncs. This is a stub that still
	   has to be correct. */
	MSG_ReadByte ();	/* density */
	MSG_ReadByte ();	/* red */
	MSG_ReadByte ();	/* green */
	MSG_ReadByte ();	/* blue */
	MSG_ReadShort ();	/* time */
}

/* ========================================================================
 * r_part.c -- particles
 * ===================================================================== */

void CL_RunParticles (void)			{ }
void R_ParseParticleEffect (void)
{
	/* Same hazard as Fog_ParseServerMessage: svc_particle is 3 coords,
	   3 signed chars of direction, a count and a color. Read them all. */
	int i;
	for (i = 0; i < 3; i++) MSG_ReadCoord (cl.protocolflags);
	for (i = 0; i < 3; i++) MSG_ReadChar ();
	MSG_ReadByte ();	/* count */
	MSG_ReadByte ();	/* color */
}

void R_RunParticleEffect (vec3_t org, vec3_t dir, int color, int count)
{
	(void)org; (void)dir; (void)color; (void)count;
}
void R_RocketTrail (vec3_t start, vec3_t end, int type)	{ (void)start; (void)end; (void)type; }
void R_EntityParticles (entity_t *ent)		{ (void)ent; }
void R_BlobExplosion (vec3_t org)		{ (void)org; }
void R_ParticleExplosion (vec3_t org)		{ (void)org; }
void R_ParticleExplosion2 (vec3_t org, int colorStart, int colorLength)
{
	(void)org; (void)colorStart; (void)colorLength;
}
void R_LavaSplash (vec3_t org)			{ (void)org; }
void R_TeleportSplash (vec3_t org)		{ (void)org; }

/* ========================================================================
 * software-renderer surface cache (WinQuake leftovers host.c still calls)
 * ===================================================================== */

void D_FlushCaches (void)
{
}
