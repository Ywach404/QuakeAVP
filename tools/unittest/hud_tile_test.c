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

	/* defaults (layout A): ammo->gun, face+healtharmor->off-hand wrist */
	extern cvar_t vr_hud_ammo_anchor, vr_hud_face_anchor, vr_hud_healtharmor_anchor;
	vr_hud_ammo_anchor.value = QC_HUD_ANCHOR_GUN;
	vr_hud_face_anchor.value = QC_HUD_ANCHOR_WRIST_OFF;
	vr_hud_healtharmor_anchor.value = QC_HUD_ANCHOR_WRIST_OFF;
	QR_ResolveHudLayout (t);
	CHECK (t[QC_HUD_TILE_AMMO].anchor == QC_HUD_ANCHOR_GUN, "ammo default anchor = gun");
	CHECK (t[QC_HUD_TILE_FACE].anchor == QC_HUD_ANCHOR_WRIST_OFF, "face default anchor = wrist");

	/* out-of-range anchor clamps to WRIST_OFF, not a wild value */
	vr_hud_ammo_anchor.value = 7;
	QR_ResolveHudLayout (t);
	CHECK (t[QC_HUD_TILE_AMMO].anchor == QC_HUD_ANCHOR_WRIST_OFF, "anchor 7 clamps to wrist");

	/* FLOAT anchor resolves without clamping */
	vr_hud_ammo_anchor.value = QC_HUD_ANCHOR_FLOAT;   /* 3 */
	QR_ResolveHudLayout (t);
	CHECK (t[QC_HUD_TILE_AMMO].anchor == QC_HUD_ANCHOR_FLOAT, "anchor 3 resolves to FLOAT, not clamped to wrist");

	/* scale floor: a zero/negative scale cvar resolves to a sane positive */
	extern cvar_t vr_hud_ammo_scale;
	vr_hud_ammo_scale.value = 0.f;
	QR_ResolveHudLayout (t);
	CHECK (t[QC_HUD_TILE_AMMO].scale > 0.01f, "scale 0 clamps to a positive floor");

	/* wrist-grid footprint clamp: span_w/span_h must not run the tile off
	   the 3x2 grid from its slot's origin cell. */
	{
		extern cvar_t vr_hud_ammo_slot, vr_hud_ammo_span_w, vr_hud_ammo_span_h;

		/* slot 5 (bottom-right) has no room to grow right or down */
		vr_hud_ammo_slot.value = 5;
		vr_hud_ammo_span_w.value = 2;
		vr_hud_ammo_span_h.value = 2;
		QR_ResolveHudLayout (t);
		CHECK (t[QC_HUD_TILE_AMMO].span_w == 1 && t[QC_HUD_TILE_AMMO].span_h == 1,
		       "slot 5 (BR) clamps span_w/span_h to 1x1");

		/* slot 0 (top-left) has room for a 2x2 footprint */
		vr_hud_ammo_slot.value = 0;
		vr_hud_ammo_span_w.value = 2;
		vr_hud_ammo_span_h.value = 2;
		QR_ResolveHudLayout (t);
		CHECK (t[QC_HUD_TILE_AMMO].span_w == 2 && t[QC_HUD_TILE_AMMO].span_h == 2,
		       "slot 0 (TL) keeps a 2x2 footprint");

		/* slot 0 (top-left) has the full grid available */
		vr_hud_ammo_slot.value = 0;
		vr_hud_ammo_span_w.value = 3;
		vr_hud_ammo_span_h.value = 2;
		QR_ResolveHudLayout (t);
		CHECK (t[QC_HUD_TILE_AMMO].span_w == 3 && t[QC_HUD_TILE_AMMO].span_h == 2,
		       "slot 0 (TL) keeps the full 3x2 footprint");
	}

	/* Task 2: the compact tile emitters, driven through the real
	   Draw_PicFromWad -> QR_TexMgr_LoadImage path (see QR_TestEnsureFixtures
	   in qr_bridge.c for how the host test gets real, non-dummy pics without
	   any game assets on disk). */
	{
		extern void QR_TestEmitTileInto (int tile_id, int stat_health, int stat_armor,
						 int stat_ammo, int items,
						 float *bbox_w, float *bbox_h, int *nverts);
		float	bw, bh;
		int	nv, nv0;

		/* With health=100, the HEALTHARMOR tile emits >0 verts and a bbox ~72x48. */
		QR_TestEmitTileInto (QC_HUD_TILE_HEALTHARMOR, 100, 50, 0, 0, &bw, &bh, &nv);
		CHECK (nv > 0, "healtharmor tile emits verts for health 100");
		CHECK (FEQ(bw,72) && FEQ(bh,48), "healtharmor bbox is the fixed 72x48");

		/* health=9/armor=0 are both <=25, so Sbar_Draw's own color picker
		   routes both Sbar_DrawNum calls to color 1 (anum_* lumps, also in
		   the fixture) -- this still draws real (1-digit) glyphs, not the
		   dummy, so it actually proves "fewer digits, same fixed bbox"
		   rather than just reusing the hardcoded-bbox path the FACE
		   missing-pic case already covers. Review Focus #1. */
		QR_TestEmitTileInto (QC_HUD_TILE_HEALTHARMOR, 9, 0, 0, 0, &bw, &bh, &nv);
		CHECK (nv > 0, "healtharmor tile still emits verts at 1 digit (color 1 lumps resolve too)");
		CHECK (FEQ(bw,72) && FEQ(bh,48), "bbox fixed regardless of digit count");

		/* AMMO: the active-weapon ammo count, right-aligned in a fixed field,
		   with the ammo-type emblem to its left. items=0 (e.g. the axe, no
		   ammo type) draws the count alone, and the reserved bbox is the same
		   either way so switching to a weapon with no ammo does not resize the
		   tile. */
		QR_TestEmitTileInto (QC_HUD_TILE_AMMO, 0, 0, 7, 0, &bw, &bh, &nv);
		CHECK (nv > 0, "ammo tile emits verts for a 1-digit value");
		CHECK (FEQ(bw,96) && FEQ(bh,24), "ammo bbox is the fixed 96x24 (24 emblem slot + 72 digits)");
		nv0 = nv;

		/* With shells held, the shells emblem is drawn to the left of the
		   count: exactly one extra pic == 6 more verts than the count alone.
		   This proves the emblem is actually EMITTED, not merely reserved in
		   the bbox (a bbox-only check would pass on a blank tile). */
		QR_TestEmitTileInto (QC_HUD_TILE_AMMO, 0, 0, 7, IT_SHELLS, &bw, &bh, &nv);
		CHECK (nv == nv0 + 6, "ammo emblem adds one pic (6 verts) when shells are held");
		CHECK (FEQ(bw,96) && FEQ(bh,24), "ammo bbox unchanged by the emblem");

		/* Missing-pic safety (Review Focus #3): the test fixture's synthetic WAD
		   only carries num_0..num_9/anum_0..anum_9, so FACE's pics are absent and
		   every one of Sbar_DrawFace's Sbar_DrawPic calls resolves to the dummy
		   pic (texnum 0).
		   QR_DrawPic's existing texnum-0 skip must no-op safely, not crash --
		   and the tile's bbox still reports its fixed reservation even though
		   nothing was actually drawn. */
		QR_TestEmitTileInto (QC_HUD_TILE_FACE, 100, 50, 0, 0, &bw, &bh, &nv);
		CHECK (nv == 0, "face tile with a wad-missing pic emits no verts (dummy, texnum 0), no crash");
		CHECK (FEQ(bw,24) && FEQ(bh,24), "face bbox stays fixed 24x24 even with nothing drawn");
	}

	/* Finding 1 fix: QC_CvarValue is the enter()-time cvar read-back that
	   closes the relaunch re-commit-clobber gap. A registered cvar returns
	   its live value; an unknown name returns 0 rather than crashing.
	   Cvar_RegisterVariable is idempotent (it no-ops with a console print
	   if already registered), so calling it here is safe regardless of
	   whether r_null.c's own VID_Init-time registration ran in this
	   host-check binary. */
	{
		extern float QC_CvarValue (const char *name);
		Cvar_RegisterVariable (&vr_hud_ammo_anchor);
		vr_hud_ammo_anchor.value = QC_HUD_ANCHOR_GUN;	/* registered default, "2" */
		CHECK (FEQ (QC_CvarValue ("vr_hud_ammo_anchor"), (float) QC_HUD_ANCHOR_GUN), "QC_CvarValue reads the registered default");
		CHECK (FEQ (QC_CvarValue ("vr_hud_does_not_exist"), 0.f), "QC_CvarValue on an unknown name returns 0");
	}

	printf ("\n%s (%d failures)\n", failures?"FAILED":"PASSED", failures);
	return failures?1:0;
}
