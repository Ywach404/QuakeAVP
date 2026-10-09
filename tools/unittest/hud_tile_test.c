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

	printf ("\n%s (%d failures)\n", failures?"FAILED":"PASSED", failures);
	return failures?1:0;
}
