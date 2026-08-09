/*
 * vid_null.c -- video mode stub, replacing gl_vidsdl.c.
 *
 * On visionOS there is no "video mode": the drawable geometry is dictated by
 * CompositorServices. This file keeps `vid` populated with a plausible 2D
 * canvas size so the console, menu, and status bar can lay themselves out,
 * and no-ops everything to do with mode switching, gamma ramps, and window
 * management.
 *
 * At M3 the immersive layer will call QAVP_VID_SetDrawableSize() once per
 * configuration change instead of any of this.
 */

#include "quakedef.h"

viddef_t	vid;			/* global video state */
modestate_t	modestate = MS_UNINIT;

/* vid_menudrawfn / vid_menukeyfn / vid_menucmdfn live in menu.c, not here --
   upstream defines them in gl_vidsdl.c *and* menu.c only gets away with it
   because of common-symbol merging. Don't re-add them. */

/* glquake.h expects these; the Metal renderer will drive them from the
   LayerRenderer drawable's viewport. */
int	glx, gly, glwidth = 1280, glheight = 720;

/* Nominal 2D canvas. Deliberately not the physical panel size -- Quake's HUD
   is authored for a 320-wide-ish virtual canvas and scr_conscale handles the
   rest. */
#define QAVP_VID_WIDTH	1280
#define QAVP_VID_HEIGHT	720

void VID_Init (void)
{
	vid.width	= QAVP_VID_WIDTH;
	vid.height	= QAVP_VID_HEIGHT;
	vid.conwidth	= QAVP_VID_WIDTH;
	vid.conheight	= QAVP_VID_HEIGHT;
	vid.rowbytes	= QAVP_VID_WIDTH;
	vid.conrowbytes	= QAVP_VID_WIDTH;
	vid.aspect	= (float)QAVP_VID_WIDTH / (float)QAVP_VID_HEIGHT;
	vid.numpages	= 1;
	vid.recalc_refdef = 1;

	glwidth  = QAVP_VID_WIDTH;
	glheight = QAVP_VID_HEIGHT;

	modestate = MS_FULLSCREEN;

	Con_Printf ("VID_Init: null driver, %dx%d virtual canvas\n",
		    vid.width, vid.height);
}

void VID_Shutdown (void)
{
	modestate = MS_UNINIT;
}

void VID_Update (vrect_t *rects)
{
	(void) rects;
}

void VID_SyncCvars (void)
{
}

void VID_Toggle (void)
{
	/* No windowed/fullscreen distinction on visionOS. */
}

void VID_Lock (void)
{
}

void *VID_GetWindow (void)
{
	return NULL;
}

qboolean VID_HasMouseOrInputFocus (void)
{
	/* The engine uses this to decide whether to throttle. The immersive
	   space owns focus policy; always claim focus and let the app layer
	   simply stop calling QC_Frame() when it should idle. */
	return true;
}

qboolean VID_IsMinimized (void)
{
	return false;
}

/* --------------------------------------------------------- GL entry points
 * glquake.h declares these; the software/Metal path will own them later.
 */

void GL_BeginRendering (int *x, int *y, int *width, int *height)
{
	*x = *y = 0;
	*width  = glwidth;
	*height = glheight;
}

void GL_EndRendering (void)
{
}

void GL_Set2D (void)
{
}
