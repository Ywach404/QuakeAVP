#include "quakedef.h"
#include "qr_bridge.h"
#include <stdio.h>
#include <math.h>
static int failures;
#define CHECK(c,...) do{ if(!(c)){failures++;printf("FAIL: "__VA_ARGS__);printf("\n");}else{printf("ok:   "__VA_ARGS__);printf("\n");} }while(0)
#define FEQ(a,b) (fabsf((float)(a)-(float)(b))<1e-4f)

int main (void)
{
	qc_hud_tile_t t[3];

	/* defaults (layout A): ammo->gun, face+healtharmor->offwrist */
	extern cvar_t vr_hud_ammo_anchor, vr_hud_face_anchor, vr_hud_healtharmor_anchor;
	vr_hud_ammo_anchor.value = QC_HUD_ANCHOR_GUN;
	vr_hud_face_anchor.value = QC_HUD_ANCHOR_OFFWRIST;
	vr_hud_healtharmor_anchor.value = QC_HUD_ANCHOR_OFFWRIST;
	QR_ResolveHudLayout (t);
	CHECK (t[QC_HUD_TILE_AMMO].anchor == QC_HUD_ANCHOR_GUN, "ammo default anchor = gun");
	CHECK (t[QC_HUD_TILE_FACE].anchor == QC_HUD_ANCHOR_OFFWRIST, "face default anchor = wrist");

	/* out-of-range anchor clamps to OFFWRIST, not a wild value */
	vr_hud_ammo_anchor.value = 7;
	QR_ResolveHudLayout (t);
	CHECK (t[QC_HUD_TILE_AMMO].anchor == QC_HUD_ANCHOR_OFFWRIST, "anchor 7 clamps to wrist");

	/* scale floor: a zero/negative scale cvar resolves to a sane positive */
	extern cvar_t vr_hud_ammo_scale;
	vr_hud_ammo_scale.value = 0.f;
	QR_ResolveHudLayout (t);
	CHECK (t[QC_HUD_TILE_AMMO].scale > 0.01f, "scale 0 clamps to a positive floor");

	/* Task 2: the compact tile emitters, driven through the real
	   Draw_PicFromWad -> QR_TexMgr_LoadImage path (see QR_TestEnsureFixtures
	   in qr_bridge.c for how the host test gets real, non-dummy pics without
	   any game assets on disk). */
	{
		extern void QR_TestEmitTileInto (int tile_id, int stat_health, int stat_armor,
						 int stat_ammo, float *bbox_w, float *bbox_h, int *nverts);
		float	bw, bh;
		int	nv;

		/* With health=100, the HEALTHARMOR tile emits >0 verts and a bbox ~72x48. */
		QR_TestEmitTileInto (QC_HUD_TILE_HEALTHARMOR, 100, 50, 0, &bw, &bh, &nv);
		CHECK (nv > 0, "healtharmor tile emits verts for health 100");
		CHECK (FEQ(bw,72) && FEQ(bh,48), "healtharmor bbox is the fixed 72x48");

		/* health=9/armor=0 are both <=25, so Sbar_Draw's own color picker
		   routes both Sbar_DrawNum calls to color 1 (anum_* lumps, also in
		   the fixture) -- this still draws real (1-digit) glyphs, not the
		   dummy, so it actually proves "fewer digits, same fixed bbox"
		   rather than just reusing the hardcoded-bbox path the FACE
		   missing-pic case already covers. Review Focus #1. */
		QR_TestEmitTileInto (QC_HUD_TILE_HEALTHARMOR, 9, 0, 0, &bw, &bh, &nv);
		CHECK (nv > 0, "healtharmor tile still emits verts at 1 digit (color 1 lumps resolve too)");
		CHECK (FEQ(bw,72) && FEQ(bh,48), "bbox fixed regardless of digit count");

		/* AMMO draws from the same fixture digits; same right-aligned, fixed-bbox deal. */
		QR_TestEmitTileInto (QC_HUD_TILE_AMMO, 0, 0, 7, &bw, &bh, &nv);
		CHECK (nv > 0, "ammo tile emits verts for a 1-digit value");
		CHECK (FEQ(bw,72) && FEQ(bh,24), "ammo bbox is the fixed 72x24");

		/* Missing-pic safety (Review Focus #3): the test fixture's synthetic WAD
		   only carries num_0..num_9/anum_0..anum_9, so FACE's pics are absent and
		   every one of Sbar_DrawFace's Sbar_DrawPic calls resolves to the dummy
		   pic (texnum 0).
		   QR_DrawPic's existing texnum-0 skip must no-op safely, not crash --
		   and the tile's bbox still reports its fixed reservation even though
		   nothing was actually drawn. */
		QR_TestEmitTileInto (QC_HUD_TILE_FACE, 100, 50, 0, &bw, &bh, &nv);
		CHECK (nv == 0, "face tile with a wad-missing pic emits no verts (dummy, texnum 0), no crash");
		CHECK (FEQ(bw,24) && FEQ(bh,24), "face bbox stays fixed 24x24 even with nothing drawn");
	}

	printf ("\n%s (%d failures)\n", failures?"FAILED":"PASSED", failures);
	return failures?1:0;
}
