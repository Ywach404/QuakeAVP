/*
 * r_null.c -- the refresh shim.
 *
 * At M0 this file stubbed, in one place, everything QuakeSpasm's OpenGL
 * renderer provided:
 *   gl_rmain.c gl_rmisc.c gl_screen.c gl_draw.c gl_texmgr.c
 *   gl_warp.c gl_sky.c gl_fog.c gl_mesh.c gl_rlight.c
 *   r_alias.c r_brush.c r_part.c r_sprite.c r_world.c
 *
 * Now the world renderer is real: the 3D path (R_*, TexMgr_*) forwards into
 * Sources/QuakeRenderer/bridge/qr_bridge.c, which builds frame packets the
 * Swift/Metal side consumes. This file keeps what upstream's renderer owned
 * that the rest of the engine reads: the cvars (defaults copied verbatim
 * from upstream 0.97 -- gameplay and config.cfg depend on them), the refresh
 * globals, and the screen-update flow.
 *
 * Still honestly stubbed, listed in README.md's roadmap: all 2D drawing
 * (Draw_*), entities (alias/brush/sprite), particles, dynamic light and
 * lightstyle updates, fog rendering. Sky and liquids are real now (ported
 * into the bridge; drawn via QC_BATCH_SKY/LIQUID). Fog_ParseServerMessage
 * and R_ParseParticleEffect still must consume their network bytes -- they
 * are stubs that have to be correct.
 *
 * The section headers below still map 1:1 onto the upstream files.
 */

#include "quakedef.h"
#include "qr_bridge.h"

/* ========================================================================
 * gl_rmain.c -- view state and cvars
 * ===================================================================== */

refdef_t	r_refdef;
vec3_t		r_origin, vpn, vright, vup;
int		r_framecount;
int		gl_warpimagesize;
qboolean	gl_glsl_gamma_able = false;

cvar_t	r_norefresh = {"r_norefresh","0",CVAR_NONE};
cvar_t	r_drawentities = {"r_drawentities","1",CVAR_NONE};
cvar_t	r_drawviewmodel = {"r_drawviewmodel","1",CVAR_NONE};
cvar_t	r_speeds = {"r_speeds","0",CVAR_NONE};
cvar_t	r_pos = {"r_pos","0",CVAR_NONE};
cvar_t	r_fullbright = {"r_fullbright","0",CVAR_NONE};
cvar_t	r_lightmap = {"r_lightmap","0",CVAR_NONE};
cvar_t	r_shadows = {"r_shadows","0",CVAR_ARCHIVE};
cvar_t	r_wateralpha = {"r_wateralpha","1",CVAR_ARCHIVE};
cvar_t	r_litwater = {"r_litwater","1",CVAR_NONE};
cvar_t	r_dynamic = {"r_dynamic","1",CVAR_ARCHIVE};
cvar_t	r_novis = {"r_novis","0",CVAR_ARCHIVE};

cvar_t	gl_finish = {"gl_finish","0",CVAR_NONE};
cvar_t	gl_clear = {"gl_clear","1",CVAR_NONE};
cvar_t	gl_cull = {"gl_cull","1",CVAR_NONE};
cvar_t	gl_smoothmodels = {"gl_smoothmodels","1",CVAR_NONE};
cvar_t	gl_affinemodels = {"gl_affinemodels","0",CVAR_NONE};
cvar_t	gl_polyblend = {"gl_polyblend","1",CVAR_NONE};
cvar_t	gl_flashblend = {"gl_flashblend","0",CVAR_ARCHIVE};
cvar_t	gl_playermip = {"gl_playermip","0",CVAR_NONE};
cvar_t	gl_nocolors = {"gl_nocolors","0",CVAR_NONE};

cvar_t	r_stereo = {"r_stereo","0",CVAR_NONE};
cvar_t	r_stereodepth = {"r_stereodepth","128",CVAR_NONE};
cvar_t	r_clearcolor = {"r_clearcolor","2",CVAR_ARCHIVE};
cvar_t	r_drawflat = {"r_drawflat","0",CVAR_NONE};
cvar_t	r_flatlightstyles = {"r_flatlightstyles", "0", CVAR_NONE};
cvar_t	gl_fullbrights = {"gl_fullbrights", "1", CVAR_ARCHIVE};
cvar_t	gl_farclip = {"gl_farclip", "65536", CVAR_ARCHIVE};
cvar_t	gl_overbright = {"gl_overbright", "1", CVAR_ARCHIVE};
cvar_t	gl_overbright_models = {"gl_overbright_models", "1", CVAR_ARCHIVE};
cvar_t	r_oldskyleaf = {"r_oldskyleaf", "0", CVAR_NONE};
cvar_t	r_drawworld = {"r_drawworld", "1", CVAR_NONE};
cvar_t	r_showtris = {"r_showtris", "0", CVAR_NONE};
cvar_t	r_showbboxes = {"r_showbboxes", "0", CVAR_NONE};
cvar_t	r_lerpmodels = {"r_lerpmodels", "1", CVAR_NONE};
cvar_t	r_lerpmove = {"r_lerpmove", "1", CVAR_NONE};
cvar_t	r_nolerp_list = {"r_nolerp_list", "progs/flame.mdl,progs/flame2.mdl,progs/braztall.mdl,progs/brazshrt.mdl,progs/longtrch.mdl,progs/flame_pyre.mdl,progs/v_saw.mdl,progs/v_xfist.mdl,progs/h2stuff/newfire.mdl", CVAR_NONE};
cvar_t	r_noshadow_list = {"r_noshadow_list", "progs/flame2.mdl,progs/flame.mdl,progs/bolt1.mdl,progs/bolt2.mdl,progs/bolt3.mdl,progs/laser.mdl", CVAR_NONE};

cvar_t	gl_zfix = {"gl_zfix", "0", CVAR_NONE}; // QuakeSpasm z-fighting fix

cvar_t	r_lavaalpha = {"r_lavaalpha","0",CVAR_NONE};
cvar_t	r_telealpha = {"r_telealpha","0",CVAR_NONE};
cvar_t	r_slimealpha = {"r_slimealpha","0",CVAR_NONE};

cvar_t	r_scale = {"r_scale", "1", CVAR_ARCHIVE};

/* M3: metres per Quake unit for the immersive renderer's matrix composition.
   The simulation stays in Quake units; qr_bridge.c clamps to 0.8x-1.2x of
   the 0.0254 default before publishing, so a config typo can't shrink the
   world to dollhouse scale. */
cvar_t	vr_worldscale = {"vr_worldscale", "0.0254", CVAR_ARCHIVE};

/* The phase effect's controls. A cvar named `phase` IS the console command:
   `phase 1` sets the target, bare `phase` prints it -- standard cvar
   semantics, driven from the command bar or the window's Phase button. */
cvar_t	phase = {"phase", "0", CVAR_NONE};
cvar_t	phase_time = {"phase_time", "2", CVAR_NONE};
/* Ember rim colour, linear "r g b" (values may exceed 1 for glow);
   the default is the molten orange. */
cvar_t	phase_color = {"phase_color", "1.5 0.93 0.27", CVAR_NONE};

/* Comfort vignette: periphery fade strength while artificial locomotion
   exceeds the threshold (Quake units/sec; walking is ~200). Zero disables. */
cvar_t	vr_vignette = {"vr_vignette", "0.6", CVAR_ARCHIVE};
cvar_t	vr_vignette_threshold = {"vr_vignette_threshold", "30", CVAR_ARCHIVE};

/* gl_rmisc.c */
cvar_t	r_lightmapwide = {"r_lightmapwide","0",CVAR_ROM};

/* gl_vidsdl.c owned the gamma cvars; view.c reads them every frame. */
cvar_t	vid_gamma		= {"gamma", "1", CVAR_ARCHIVE};
cvar_t	vid_contrast		= {"contrast", "1", CVAR_ARCHIVE};

/* defined in their own sections further down */
extern cvar_t r_oldwater, r_waterquality;
extern cvar_t r_fastsky, r_sky_quality, r_skyalpha, r_skyfog;

void R_Init (void)
{
	/* registration order matches upstream R_Init (gl_rmisc.c); the
	   timerefresh/pointfile commands and the cvar callbacks that poked
	   renderer internals are not ported */
	Cvar_RegisterVariable (&r_norefresh);
	Cvar_RegisterVariable (&r_lightmap);
	Cvar_RegisterVariable (&r_fullbright);
	Cvar_RegisterVariable (&r_drawentities);
	Cvar_RegisterVariable (&r_drawviewmodel);
	Cvar_RegisterVariable (&r_shadows);
	Cvar_RegisterVariable (&r_wateralpha);
	Cvar_SetCallback (&r_wateralpha, QR_SetWateralpha_f);
	Cvar_RegisterVariable (&r_litwater);
	Cvar_RegisterVariable (&r_dynamic);
	Cvar_RegisterVariable (&r_novis);
	Cvar_RegisterVariable (&r_speeds);
	Cvar_RegisterVariable (&r_pos);
	Cvar_RegisterVariable (&gl_finish);
	Cvar_RegisterVariable (&gl_clear);
	Cvar_RegisterVariable (&gl_cull);
	Cvar_RegisterVariable (&gl_smoothmodels);
	Cvar_RegisterVariable (&gl_affinemodels);
	Cvar_RegisterVariable (&gl_polyblend);
	Cvar_RegisterVariable (&gl_flashblend);
	Cvar_RegisterVariable (&gl_playermip);
	Cvar_RegisterVariable (&gl_nocolors);
	Cvar_RegisterVariable (&r_stereo);
	Cvar_RegisterVariable (&r_stereodepth);
	Cvar_RegisterVariable (&r_clearcolor);
	Cvar_RegisterVariable (&r_waterquality);
	Cvar_RegisterVariable (&r_oldwater);
	Cvar_RegisterVariable (&r_waterwarp);
	Cvar_RegisterVariable (&r_drawflat);
	Cvar_RegisterVariable (&r_flatlightstyles);
	Cvar_RegisterVariable (&r_oldskyleaf);
	Cvar_RegisterVariable (&r_drawworld);
	Cvar_RegisterVariable (&r_showtris);
	Cvar_RegisterVariable (&r_showbboxes);
	Cvar_RegisterVariable (&gl_farclip);
	Cvar_RegisterVariable (&gl_fullbrights);
	Cvar_RegisterVariable (&gl_overbright);
	Cvar_RegisterVariable (&gl_overbright_models);
	Cvar_RegisterVariable (&r_lerpmodels);
	Cvar_RegisterVariable (&r_lerpmove);
	Cvar_RegisterVariable (&r_nolerp_list);
	Cvar_RegisterVariable (&r_noshadow_list);
	Cvar_RegisterVariable (&r_lightmapwide);
	Cvar_RegisterVariable (&gl_zfix);
	Cvar_RegisterVariable (&r_lavaalpha);
	Cvar_SetCallback (&r_lavaalpha, QR_SetLavaalpha_f);
	Cvar_RegisterVariable (&r_telealpha);
	Cvar_SetCallback (&r_telealpha, QR_SetTelealpha_f);
	Cvar_RegisterVariable (&r_slimealpha);
	Cvar_SetCallback (&r_slimealpha, QR_SetSlimealpha_f);
	Cvar_RegisterVariable (&r_scale);
	Cvar_RegisterVariable (&vr_worldscale);
	Cvar_RegisterVariable (&phase);
	Cvar_RegisterVariable (&phase_time);
	Cvar_RegisterVariable (&phase_color);
	Cvar_RegisterVariable (&vr_vignette);
	Cvar_RegisterVariable (&vr_vignette_threshold);

	/* upstream Sky_Init (gl_sky.c) */
	Cvar_RegisterVariable (&r_fastsky);
	Cvar_RegisterVariable (&r_sky_quality);
	Cvar_RegisterVariable (&r_skyalpha);
	Cvar_RegisterVariable (&r_skyfog);
	Cvar_SetCallback (&r_skyfog, QR_SetSkyfog_f);
	Cmd_AddCommand ("sky", Sky_SkyCommand_f);

	Cvar_RegisterVariable (&vid_gamma);
	Cvar_RegisterVariable (&vid_contrast);

	QR_Init ();

	Con_Printf ("R_Init: Metal world renderer bridge\n");
}

void R_NewGame (void)
{
}

void R_NewMap (void)
{
	QR_NewMap ();
}

/* Defined in view.c with external linkage but never prototyped in a header
   (upstream only ever calls it from within view.c). Declared here rather than
   added to view.h, which would make a fourth patched hunk in the vendored tree
   for the sake of one line. */
void V_CalcRefdef (void);

/* Engine-thread head/body angles, owned by in_null.c and not declared in any
   header (same situation as V_CalcRefdef). Read here to aim the sound. */
extern float qr_head_yaw, qr_head_pitch, qr_body_yaw;

void R_RenderView (void)
{
	/* Upstream V_RenderView skips V_CalcRefdef entirely while cl.paused --
	   correct for a flat screen, where the frozen image is the point, and
	   wrong here. In VR the camera must keep being computed even with the
	   simulation stopped: without this r_refdef.vieworg holds whatever it had
	   when the pause landed, which on a freshly loaded map means the view sits
	   at the player entity's origin and you start the level buried in the
	   floor until you resume.

	   Done here rather than by patching view.c: the vendored tree's patched
	   hunks are counted in UPSTREAM.md and this does not need to join them.
	   V_RenderView has already decided to skip the calc by the time it calls
	   us, so doing it now lands in the same frame, before the bridge reads
	   the refdef.

	   Intermission keeps upstream's behaviour -- it has its own refdef calc and
	   a fixed camera, so recomputing would fight it. */
	if (cl.paused && !cl.intermission)
		V_CalcRefdef ();

	QR_RenderView ();

	/* Aim the LISTENER at the head, not the body.

	   host.c calls S_Update (r_origin, vpn, vright, vup) after this, and in
	   this port those vectors are the body/aim frame: the head pose is
	   late-latched render-side and the engine never sees it, so turning your
	   head would leave the whole sound field behind. Overwrite the basis here,
	   between the render that used it and the S_Update that is about to.

	   Done this way rather than by calling S_Update a second time with
	   corrected vectors: S_Update also runs S_UpdateAmbientSounds, which ramps
	   ambient volumes on host_frametime, so a second call would ramp them at
	   double rate. One call, correct arguments. */
	if (cls.signon == SIGNONS)
	{
		vec3_t	hang;

		hang[PITCH] = qr_head_pitch;
		hang[YAW] = qr_body_yaw + qr_head_yaw;
		hang[ROLL] = 0;
		AngleVectors (hang, vpn, vright, vup);
	}
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
 * gl_screen.c -- screen update flow and refdef calculation
 * ===================================================================== */

float		scr_con_current;
int		clearnotify;
int		scr_tileclear_updates = 0;
float		scr_centertime_off;
qboolean	scr_disabled_for_loading;
static float	scr_disabled_time;
static qboolean	scr_initialized;

cvar_t	scr_menuscale = {"scr_menuscale", "1", CVAR_ARCHIVE};
cvar_t	scr_sbarscale = {"scr_sbarscale", "1", CVAR_ARCHIVE};
cvar_t	scr_sbaralpha = {"scr_sbaralpha", "0.75", CVAR_ARCHIVE};
cvar_t	vr_hud = {"vr_hud", "3", CVAR_ARCHIVE};	/* 0 off, 1 wrist-preset, 2 float-preset, 3 modular tiles (default) */
cvar_t	vr_hud_bg = {"vr_hud_bg", "1", CVAR_ARCHIVE};	/* dark panel behind each modular tile, drawn consumer-side */

/* Modular HUD (Phase 1): per-tile placement. Default layout A --
   ammo pins to the gun, face and health/armor pin to the off-hand wrist.
   anchor: QC_HUD_ANCHOR_WRIST_OFF (0), QC_HUD_ANCHOR_WRIST_GUN (1),
   QC_HUD_ANCHOR_GUN (2), or QC_HUD_ANCHOR_FLOAT (3). slot/span_w/span_h
   place the tile on a wrist anchor's 2x2 grid (slot is the origin cell,
   span_w/span_h the footprint in cells); off_x/y/z are metres in the
   anchor frame; scale is a panel scale multiplier; show is a bool gate
   independent of anchor.
   The off_y/scale defaults below are device-tuned first guesses (M.
   reported tiles clumped on the wrist and read too small over the world):
   face sits above the wrist, health/armor below it, so the two wrist tiles
   don't overlap each other or the hand; all three tiles are scaled up for
   readability. Expect these to move once tried on device again. */
cvar_t	vr_hud_ammo_anchor        = {"vr_hud_ammo_anchor", "2", CVAR_ARCHIVE};	/* gun */
cvar_t	vr_hud_ammo_slot          = {"vr_hud_ammo_slot", "0", CVAR_ARCHIVE};
cvar_t	vr_hud_ammo_span_w        = {"vr_hud_ammo_span_w", "1", CVAR_ARCHIVE};
cvar_t	vr_hud_ammo_span_h        = {"vr_hud_ammo_span_h", "1", CVAR_ARCHIVE};
cvar_t	vr_hud_ammo_off_x         = {"vr_hud_ammo_off_x", "0", CVAR_ARCHIVE};
cvar_t	vr_hud_ammo_off_y         = {"vr_hud_ammo_off_y", "0", CVAR_ARCHIVE};
cvar_t	vr_hud_ammo_off_z         = {"vr_hud_ammo_off_z", "0", CVAR_ARCHIVE};
cvar_t	vr_hud_ammo_scale         = {"vr_hud_ammo_scale", "1.6", CVAR_ARCHIVE};
cvar_t	vr_hud_ammo_show          = {"vr_hud_ammo_show", "1", CVAR_ARCHIVE};

cvar_t	vr_hud_face_anchor        = {"vr_hud_face_anchor", "0", CVAR_ARCHIVE};	/* off-hand wrist */
cvar_t	vr_hud_face_slot          = {"vr_hud_face_slot", "0", CVAR_ARCHIVE};	/* top-left */
cvar_t	vr_hud_face_span_w        = {"vr_hud_face_span_w", "1", CVAR_ARCHIVE};
cvar_t	vr_hud_face_span_h        = {"vr_hud_face_span_h", "1", CVAR_ARCHIVE};
cvar_t	vr_hud_face_off_x         = {"vr_hud_face_off_x", "0", CVAR_ARCHIVE};
cvar_t	vr_hud_face_off_y         = {"vr_hud_face_off_y", "0.035", CVAR_ARCHIVE};	/* up: above the wrist */
cvar_t	vr_hud_face_off_z         = {"vr_hud_face_off_z", "0", CVAR_ARCHIVE};
cvar_t	vr_hud_face_scale         = {"vr_hud_face_scale", "1.0", CVAR_ARCHIVE};
cvar_t	vr_hud_face_show          = {"vr_hud_face_show", "1", CVAR_ARCHIVE};

cvar_t	vr_hud_healtharmor_anchor = {"vr_hud_healtharmor_anchor", "0", CVAR_ARCHIVE};	/* off-hand wrist */
cvar_t	vr_hud_healtharmor_slot   = {"vr_hud_healtharmor_slot", "3", CVAR_ARCHIVE};	/* bottom-left */
cvar_t	vr_hud_healtharmor_span_w = {"vr_hud_healtharmor_span_w", "1", CVAR_ARCHIVE};
cvar_t	vr_hud_healtharmor_span_h = {"vr_hud_healtharmor_span_h", "1", CVAR_ARCHIVE};
cvar_t	vr_hud_healtharmor_off_x  = {"vr_hud_healtharmor_off_x", "0", CVAR_ARCHIVE};
cvar_t	vr_hud_healtharmor_off_y  = {"vr_hud_healtharmor_off_y", "-0.035", CVAR_ARCHIVE};	/* down: below the wrist */
cvar_t	vr_hud_healtharmor_off_z  = {"vr_hud_healtharmor_off_z", "0", CVAR_ARCHIVE};
cvar_t	vr_hud_healtharmor_scale  = {"vr_hud_healtharmor_scale", "1.0", CVAR_ARCHIVE};
cvar_t	vr_hud_healtharmor_show   = {"vr_hud_healtharmor_show", "1", CVAR_ARCHIVE};

/* Wrist communicator (spy-watch action grid, seated below the HUD).
   Per side: an enable, and six {command,label} pairs for the 2x3 cells
   (row-major, 0 1 2 / 3 4 5). Commands are ordinary console strings and
   fully rebindable; defaults are vanilla cheats. The gun side ships
   disabled and unbound -- enabling it is how a second device appears. */
cvar_t	vr_wristcomm_off        = {"vr_wristcomm_off", "1", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_cmd0   = {"vr_wristcomm_off_cmd0", "god", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_cmd1   = {"vr_wristcomm_off_cmd1", "impulse 9", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_cmd2   = {"vr_wristcomm_off_cmd2", "noclip", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_cmd3   = {"vr_wristcomm_off_cmd3", "notarget", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_cmd4   = {"vr_wristcomm_off_cmd4", "fly", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_cmd5   = {"vr_wristcomm_off_cmd5", "impulse 255", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_label0 = {"vr_wristcomm_off_label0", "GOD", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_label1 = {"vr_wristcomm_off_label1", "GIVE", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_label2 = {"vr_wristcomm_off_label2", "NOCLIP", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_label3 = {"vr_wristcomm_off_label3", "NOTGT", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_label4 = {"vr_wristcomm_off_label4", "FLY", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_off_label5 = {"vr_wristcomm_off_label5", "QUAD", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun        = {"vr_wristcomm_gun", "0", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_cmd0   = {"vr_wristcomm_gun_cmd0", "", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_cmd1   = {"vr_wristcomm_gun_cmd1", "", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_cmd2   = {"vr_wristcomm_gun_cmd2", "", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_cmd3   = {"vr_wristcomm_gun_cmd3", "", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_cmd4   = {"vr_wristcomm_gun_cmd4", "", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_cmd5   = {"vr_wristcomm_gun_cmd5", "", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_label0 = {"vr_wristcomm_gun_label0", "", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_label1 = {"vr_wristcomm_gun_label1", "", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_label2 = {"vr_wristcomm_gun_label2", "", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_label3 = {"vr_wristcomm_gun_label3", "", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_label4 = {"vr_wristcomm_gun_label4", "", CVAR_ARCHIVE};
cvar_t	vr_wristcomm_gun_label5 = {"vr_wristcomm_gun_label5", "", CVAR_ARCHIVE};

cvar_t	scr_conwidth = {"scr_conwidth", "0", CVAR_ARCHIVE};
cvar_t	scr_conscale = {"scr_conscale", "1", CVAR_ARCHIVE};
cvar_t	scr_crosshairscale = {"scr_crosshairscale", "1", CVAR_ARCHIVE};
cvar_t	scr_showfps = {"scr_showfps", "0", CVAR_NONE};
cvar_t	scr_clock = {"scr_clock", "0", CVAR_NONE};
cvar_t	scr_usekfont = {"scr_usekfont", "0", CVAR_NONE}; // 2021 re-release
cvar_t	scr_viewsize = {"viewsize","100", CVAR_ARCHIVE};
cvar_t	scr_fov = {"fov","90",CVAR_NONE};	// 10 - 170
cvar_t	scr_fov_adapt = {"fov_adapt","1",CVAR_ARCHIVE};
cvar_t	scr_conspeed = {"scr_conspeed","500",CVAR_ARCHIVE};
cvar_t	scr_centertime = {"scr_centertime","2",CVAR_NONE};
cvar_t	scr_showturtle = {"showturtle","0",CVAR_NONE};
cvar_t	scr_showpause = {"showpause","1",CVAR_NONE};
cvar_t	scr_printspeed = {"scr_printspeed","8",CVAR_NONE};
cvar_t	gl_triplebuffer = {"gl_triplebuffer", "1", CVAR_ARCHIVE};
cvar_t	cl_gun_fovscale = {"cl_gun_fovscale","1",CVAR_ARCHIVE}; // Qrack

/* sys_avp.c would be the natural home, but upstream keeps it in the platform
   sys_*.c file and host.c registers it. Same thing. */
cvar_t	sys_throttle	= {"sys_throttle", "0.02", CVAR_ARCHIVE};

/*
====================
AdaptFovx -- adapt a 4:3 horizontal FOV to the current screen size ("Hor+")
====================
*/
static float AdaptFovx (float fov_x, float width, float height)
{
	float	a, x;

	if (fov_x < 1 || fov_x > 179)
		Sys_Error ("Bad fov: %f", fov_x);

	if (!scr_fov_adapt.value)
		return fov_x;
	if ((x = height / width) == 0.75)
		return fov_x;
	a = atan(0.75 / x * tan(fov_x / 360 * M_PI));
	a = a * 360 / M_PI;
	return a;
}

/*
====================
CalcFovy
====================
*/
static float CalcFovy (float fov_x, float width, float height)
{
	float	a, x;

	if (fov_x < 1 || fov_x > 179)
		Sys_Error ("Bad fov: %f", fov_x);

	x = width / tan(fov_x / 360 * M_PI);
	a = atan(height / x);
	a = a * 360 / M_PI;
	return a;
}

/*
=================
SCR_CalcRefdef -- port of upstream, minus the parts that size 2D overlays
=================
*/
static void SCR_CalcRefdef (void)
{
	float		size, scale;

	scr_tileclear_updates = 0;

// bound viewsize
	if (scr_viewsize.value < 30)
		Cvar_SetQuick (&scr_viewsize, "30");
	if (scr_viewsize.value > 120)
		Cvar_SetQuick (&scr_viewsize, "120");

// bound fov
	if (scr_fov.value < 10)
		Cvar_SetQuick (&scr_fov, "10");
	if (scr_fov.value > 170)
		Cvar_SetQuick (&scr_fov, "170");

	vid.recalc_refdef = 0;

	size = scr_viewsize.value;
	scale = CLAMP (1.0f, scr_sbarscale.value, (float)glwidth / 320.0f);

	if (size >= 120 || cl.intermission || scr_sbaralpha.value < 1)
		sb_lines = 0;
	else if (size >= 110)
		sb_lines = 24 * scale;
	else
		sb_lines = 48 * scale;

	size = q_min(scr_viewsize.value, 100.f) / 100;

	r_refdef.vrect.width = q_max(glwidth * size, 96.0f);
	r_refdef.vrect.height = q_min((int)(glheight * size), glheight - sb_lines);
	r_refdef.vrect.x = (glwidth - r_refdef.vrect.width)/2;
	r_refdef.vrect.y = (glheight - sb_lines - r_refdef.vrect.height)/2;

	r_refdef.fov_x = AdaptFovx(scr_fov.value, vid.width, vid.height);
	r_refdef.fov_y = CalcFovy (r_refdef.fov_x, r_refdef.vrect.width, r_refdef.vrect.height);
}

static void SCR_Callback_refdef (cvar_t *var)
{
	(void) var;
	vid.recalc_refdef = 1;
}

void SCR_Init (void)
{
	/* registration order matches upstream SCR_Init; screenshot and
	   sizeup/sizedown commands are not ported */
	Cvar_RegisterVariable (&scr_menuscale);
	Cvar_RegisterVariable (&scr_sbarscale);
	Cvar_SetCallback (&scr_sbaralpha, SCR_Callback_refdef);
	Cvar_RegisterVariable (&scr_sbaralpha);
	Cvar_RegisterVariable (&vr_hud);
	Cvar_RegisterVariable (&vr_hud_bg);
	Cvar_RegisterVariable (&vr_hud_ammo_anchor);
	Cvar_RegisterVariable (&vr_hud_ammo_slot);
	Cvar_RegisterVariable (&vr_hud_ammo_span_w);
	Cvar_RegisterVariable (&vr_hud_ammo_span_h);
	Cvar_RegisterVariable (&vr_hud_ammo_off_x);
	Cvar_RegisterVariable (&vr_hud_ammo_off_y);
	Cvar_RegisterVariable (&vr_hud_ammo_off_z);
	Cvar_RegisterVariable (&vr_hud_ammo_scale);
	Cvar_RegisterVariable (&vr_hud_ammo_show);
	Cvar_RegisterVariable (&vr_hud_face_anchor);
	Cvar_RegisterVariable (&vr_hud_face_slot);
	Cvar_RegisterVariable (&vr_hud_face_span_w);
	Cvar_RegisterVariable (&vr_hud_face_span_h);
	Cvar_RegisterVariable (&vr_hud_face_off_x);
	Cvar_RegisterVariable (&vr_hud_face_off_y);
	Cvar_RegisterVariable (&vr_hud_face_off_z);
	Cvar_RegisterVariable (&vr_hud_face_scale);
	Cvar_RegisterVariable (&vr_hud_face_show);
	Cvar_RegisterVariable (&vr_hud_healtharmor_anchor);
	Cvar_RegisterVariable (&vr_hud_healtharmor_slot);
	Cvar_RegisterVariable (&vr_hud_healtharmor_span_w);
	Cvar_RegisterVariable (&vr_hud_healtharmor_span_h);
	Cvar_RegisterVariable (&vr_hud_healtharmor_off_x);
	Cvar_RegisterVariable (&vr_hud_healtharmor_off_y);
	Cvar_RegisterVariable (&vr_hud_healtharmor_off_z);
	Cvar_RegisterVariable (&vr_hud_healtharmor_scale);
	Cvar_RegisterVariable (&vr_hud_healtharmor_show);
	Cvar_RegisterVariable (&vr_wristcomm_off);
	Cvar_RegisterVariable (&vr_wristcomm_off_cmd0);
	Cvar_RegisterVariable (&vr_wristcomm_off_cmd1);
	Cvar_RegisterVariable (&vr_wristcomm_off_cmd2);
	Cvar_RegisterVariable (&vr_wristcomm_off_cmd3);
	Cvar_RegisterVariable (&vr_wristcomm_off_cmd4);
	Cvar_RegisterVariable (&vr_wristcomm_off_cmd5);
	Cvar_RegisterVariable (&vr_wristcomm_off_label0);
	Cvar_RegisterVariable (&vr_wristcomm_off_label1);
	Cvar_RegisterVariable (&vr_wristcomm_off_label2);
	Cvar_RegisterVariable (&vr_wristcomm_off_label3);
	Cvar_RegisterVariable (&vr_wristcomm_off_label4);
	Cvar_RegisterVariable (&vr_wristcomm_off_label5);
	Cvar_RegisterVariable (&vr_wristcomm_gun);
	Cvar_RegisterVariable (&vr_wristcomm_gun_cmd0);
	Cvar_RegisterVariable (&vr_wristcomm_gun_cmd1);
	Cvar_RegisterVariable (&vr_wristcomm_gun_cmd2);
	Cvar_RegisterVariable (&vr_wristcomm_gun_cmd3);
	Cvar_RegisterVariable (&vr_wristcomm_gun_cmd4);
	Cvar_RegisterVariable (&vr_wristcomm_gun_cmd5);
	Cvar_RegisterVariable (&vr_wristcomm_gun_label0);
	Cvar_RegisterVariable (&vr_wristcomm_gun_label1);
	Cvar_RegisterVariable (&vr_wristcomm_gun_label2);
	Cvar_RegisterVariable (&vr_wristcomm_gun_label3);
	Cvar_RegisterVariable (&vr_wristcomm_gun_label4);
	Cvar_RegisterVariable (&vr_wristcomm_gun_label5);
	Cvar_RegisterVariable (&scr_conwidth);
	Cvar_RegisterVariable (&scr_conscale);
	Cvar_RegisterVariable (&scr_crosshairscale);
	Cvar_RegisterVariable (&scr_showfps);
	Cvar_RegisterVariable (&scr_clock);
	Cvar_RegisterVariable (&scr_usekfont);
	Cvar_SetCallback (&scr_fov, SCR_Callback_refdef);
	Cvar_SetCallback (&scr_fov_adapt, SCR_Callback_refdef);
	Cvar_SetCallback (&scr_viewsize, SCR_Callback_refdef);
	Cvar_RegisterVariable (&scr_fov);
	Cvar_RegisterVariable (&scr_fov_adapt);
	Cvar_RegisterVariable (&scr_viewsize);
	Cvar_RegisterVariable (&scr_conspeed);
	Cvar_RegisterVariable (&scr_showturtle);
	Cvar_RegisterVariable (&scr_showpause);
	Cvar_RegisterVariable (&scr_centertime);
	Cvar_RegisterVariable (&scr_printspeed);
	Cvar_RegisterVariable (&gl_triplebuffer);
	Cvar_RegisterVariable (&cl_gun_fovscale);

	scr_initialized = true;
}

void SCR_UpdateScreen (void)
{
	if (scr_disabled_for_loading)
	{
		if (realtime - scr_disabled_time > 60)
		{
			scr_disabled_for_loading = false;
			Con_Printf ("load failed.\n");
		}
		else
			return;
	}

	if (!scr_initialized || !con_initialized)
		return;

	GL_BeginRendering (&glx, &gly, &glwidth, &glheight);

	if (vid.recalc_refdef)
		SCR_CalcRefdef ();

	/* the live half of SCR_SetUpToDrawConsole: con_forcedup is what stops
	   V_RenderView calling into the renderer with no world loaded */
	con_forcedup = !cl.worldmodel || cls.signon != SIGNONS;

	V_RenderView ();

	/* 2D overlay drawing happened here upstream; still stubbed */

	/* upstream calls this from gl_screen.c after the view: computes the
	   polyblend colour AND decays the cshift percents. Without it the
	   damage flash never fades -- qr_bridge publishes that percent as the
	   haptics/adaptive-trigger output signal, so the decay must run. */
	V_UpdateBlend ();

	GL_EndRendering ();
}

/* Centerprint text captured for the renderer (head-locked HUD prompt, e.g. the
   hub's warp-gate instructions). Engine thread writes here; qr_bridge reads it
   while building the frame -- both engine-thread, so no lock. Upstream's HUD
   machinery is gone, so without this the string was logged and dropped. */
char	qr_centerstring[256];
double	qr_centertime_until;

void SCR_CenterPrint (const char *str)
{
	/* The message still belongs in the console log even with no HUD. */
	if (str && *str)
		Con_Printf ("%s\n", str);
	scr_centertime_off = 0;

	if (str && *str)
	{
		q_strlcpy (qr_centerstring, str, sizeof(qr_centerstring));
		/* Expiry on the monotonic WALL clock, NOT cl.time: cl.time resets to
		   ~0 on a changelevel, so a cl.time-based expiry from the old level
		   stayed in the future across the transition and the message hung on
		   the new level until the fresh cl.time slowly caught up (it "would
		   not go away"). realtime always advances past it within scr_centertime. */
		qr_centertime_until = realtime + scr_centertime.value;
	}
	else
	{
		qr_centerstring[0] = '\0';
	}
}

void SCR_BeginLoadingPlaque (void)
{
	scr_disabled_for_loading = true;
	scr_disabled_time = realtime;
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
 * gl_draw.c -- 2D drawing (still stubbed; M-next: HUD and console text)
 * ===================================================================== */

qpic_t	*draw_disc;
qpic_t	*pic_ovr, *pic_ins;

cvar_t	scr_conalpha = {"scr_conalpha", "0.5", CVAR_ARCHIVE};

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
	Cvar_RegisterVariable (&scr_conalpha);

	draw_disc = Draw_PicFromWad ("disc");
	pic_ovr = QAVP_DummyPic ();
	pic_ins = QAVP_DummyPic ();
}

void Draw_NewGame (void)
{
}

qpic_t *Draw_PicFromWad (const char *name)
{
	qpic_t *p = QR_DrawPicFromWad (name);
	return p ? p : QAVP_DummyPic ();
}

qpic_t *Draw_CachePic (const char *path)
{
	/* TODO(2D milestone): load the .lmp and cache it. Doing that properly
	   needs a cache whose lifetime survives Hunk_FreeToLowMark on map
	   change, which is renderer bookkeeping -- not worth building twice. */
	(void) path;
	return QAVP_DummyPic ();
}

void Draw_Character (int x, int y, int num)		{ QR_DrawCharacter (x, y, num); }
void Draw_DebugChar (char num)				{ (void)num; }
void Draw_Pic (int x, int y, qpic_t *pic)		{ QR_DrawPic (x, y, pic); }
void Draw_ConsoleBackground (void)			{ }
void Draw_TileClear (int x, int y, int w, int h)	{ (void)x; (void)y; (void)w; (void)h; }
void Draw_FadeScreen (void)				{ }
void Draw_String (int x, int y, const char *str)	{ QR_DrawString (x, y, str); }

void Draw_Fill (int x, int y, int w, int h, int c, float alpha)
{
	QR_DrawFill (x, y, w, h, c, alpha);
}

void Draw_TransPicTranslate (int x, int y, qpic_t *pic, int top, int bottom)
{
	(void)x; (void)y; (void)pic; (void)top; (void)bottom;
}

void GL_SetCanvas (canvastype newcanvas)
{
	QR_SetCanvas (newcanvas);
}

/* ========================================================================
 * gl_texmgr.c -- texture manager (real; forwards to the bridge uploader)
 * ===================================================================== */

static cvar_t	gl_texturemode = {"gl_texturemode", "", CVAR_ARCHIVE};
static cvar_t	gl_texture_anisotropy = {"gl_texture_anisotropy", "1", CVAR_ARCHIVE};
static cvar_t	gl_max_size = {"gl_max_size", "0", CVAR_NONE};
static cvar_t	gl_picmip = {"gl_picmip", "0", CVAR_NONE};

void TexMgr_Init (void)
{
	/* registered for config.cfg parity; filtering is fixed in the Metal
	   samplers for now, and Metal has no texture size limit worth
	   honouring at Quake scales */
	Cvar_RegisterVariable (&gl_max_size);
	Cvar_RegisterVariable (&gl_picmip);
	Cvar_RegisterVariable (&gl_texture_anisotropy);
	Cvar_RegisterVariable (&gl_texturemode);

	QR_TexMgr_Init ();
}

void TexMgr_NewGame (void)
{
	QR_TexMgr_NewGame ();
}

gltexture_t *TexMgr_NewTexture (void)
{
	return QR_TexMgr_NewTexture ();
}

gltexture_t *TexMgr_LoadImage (qmodel_t *owner, const char *name,
			       int width, int height, enum srcformat format,
			       byte *data, const char *source_file,
			       src_offset_t source_offset, unsigned flags)
{
	return QR_TexMgr_LoadImage (owner, name, width, height, format,
				    data, source_file, source_offset, flags);
}

void TexMgr_FreeTexturesForOwner (qmodel_t *owner)
{
	QR_TexMgr_FreeTexturesForOwner (owner);
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
   point), not a function. Left null; gl_model.c checks it to decide whether
   warpimages get TEXPREF_MIPMAP. */
QS_PFNGENERATEMIPMAP GL_GenerateMipmap;

/* ========================================================================
 * gl_mesh.c / gl_warp.c / gl_sky.c / gl_fog.c -- map + model registration
 * ===================================================================== */

/* gl_warp.c cvar definitions; gl_subdivide_size is registered by Mod_Init
   in vendored gl_model.c, the rest by R_Init above, as upstream does. */
cvar_t	r_oldwater = {"r_oldwater", "0", CVAR_ARCHIVE};
cvar_t	r_waterquality = {"r_waterquality", "8", CVAR_NONE};
cvar_t	r_waterwarp = {"r_waterwarp", "1", CVAR_NONE};
cvar_t	gl_subdivide_size = {"gl_subdivide_size", "128", CVAR_ARCHIVE};

/* gl_sky.c cvar definitions */
cvar_t	r_fastsky = {"r_fastsky", "0", CVAR_NONE};
cvar_t	r_sky_quality = {"r_sky_quality", "12", CVAR_NONE};
cvar_t	r_skyalpha = {"r_skyalpha", "1", CVAR_NONE};
cvar_t	r_skyfog = {"r_skyfog","0.5",CVAR_NONE};

/* GL_MakeAliasModelDisplayLists / GLMesh_DeleteVertexBuffers are real now,
   ported into qr_bridge.c's mesh section. */

void GL_SubdivideSurface (msurface_t *fa)
{
	(void) fa;
}

/* Sky_ClearAll / Sky_LoadTexture / Sky_LoadSkyBox / Sky_NewMap are real now,
   ported into qr_bridge.c. Only the Quake 64 variant remains stubbed: Q64
   BSPs aren't a target and their sky needs its own two-layer split. */
void Sky_LoadTextureQ64 (qmodel_t *m, texture_t *mt)	{ (void)m; (void)mt; }

/* Fog_ParseServerMessage moved to qr_bridge.c (gl_fog.c port) -- it now
   stores the fog instead of dropping it. */

/* ========================================================================
 * r_part.c -- particles
 * ===================================================================== */

/* The particle system (spawns, CL_RunParticles, R_ClearParticles) now lives
   in the renderer bridge (qr_bridge.c) -- it needs the packet and palette.
   R_ParseParticleEffect stays here: it consumes the svc_particle bytes and
   forwards them to the real R_RunParticleEffect. */
void R_ParseParticleEffect (void)
{
	vec3_t	org, dir;
	int	i, count, color;

	for (i = 0; i < 3; i++) org[i] = MSG_ReadCoord (cl.protocolflags);
	for (i = 0; i < 3; i++) dir[i] = MSG_ReadChar () * (1.0 / 16);
	count = MSG_ReadByte ();
	color = MSG_ReadByte ();
	if (count == 255)
		count = 1024;
	R_RunParticleEffect (org, dir, color, count);
}

/* ========================================================================
 * software-renderer surface cache (WinQuake leftovers host.c still calls)
 * ===================================================================== */

void D_FlushCaches (void)
{
}
