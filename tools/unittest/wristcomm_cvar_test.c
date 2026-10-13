#include "quakedef.h"
#include "qr_bridge.h"
#include <string.h>
#include <stdio.h>
static int failures;
#define CHECK(c,...) do{ if(!(c)){failures++;printf("FAIL: "__VA_ARGS__);printf("\n");}else{printf("ok:   "__VA_ARGS__);printf("\n");} }while(0)

int main (void)
{
	/* same cvar-registration bootstrap hud_tile_test.c uses: the cvars are
	   statically defined in r_null.c, but this host-check binary doesn't
	   necessarily run VID_Init, so register them here too -- idempotent,
	   and safe if r_null.c's own registration already ran.

	   Cvar_RegisterVariable copies the default string through Z_Strdup,
	   which needs the zone the hunk backs -- QR_TestEmitTileInto's first
	   call runs QR_TestEnsureFixtures, which Memory_Init's a static test
	   hunk (see qr_bridge.c). hud_tile_test.c gets this for free because
	   its own QR_TestEmitTileInto calls happen to run first; call it here
	   too rather than inventing a second memory bootstrap. */
	{
		extern void QR_TestEmitTileInto (int tile_id, int stat_health, int stat_armor,
						 int stat_ammo, int items,
						 float *bbox_w, float *bbox_h, int *nverts);
		float	bw, bh;
		int	nv;
		QR_TestEmitTileInto (QC_HUD_TILE_HEALTHARMOR, 100, 50, 0, 0, &bw, &bh, &nv);
	}

	extern cvar_t vr_wristcomm_off, vr_wristcomm_off_cmd0, vr_wristcomm_off_cmd1,
		vr_wristcomm_off_cmd2, vr_wristcomm_off_cmd3, vr_wristcomm_off_cmd4, vr_wristcomm_off_cmd5,
		vr_wristcomm_off_label0, vr_wristcomm_off_label1, vr_wristcomm_off_label2,
		vr_wristcomm_off_label3, vr_wristcomm_off_label4, vr_wristcomm_off_label5,
		vr_wristcomm_gun, vr_wristcomm_gun_cmd0, vr_wristcomm_gun_cmd1,
		vr_wristcomm_gun_cmd2, vr_wristcomm_gun_cmd3, vr_wristcomm_gun_cmd4, vr_wristcomm_gun_cmd5,
		vr_wristcomm_gun_label0, vr_wristcomm_gun_label1, vr_wristcomm_gun_label2,
		vr_wristcomm_gun_label3, vr_wristcomm_gun_label4, vr_wristcomm_gun_label5;

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

	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_cmd0"), "god"), "off cmd0 defaults to god");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_cmd1"), "impulse 9"), "off cmd1 defaults to impulse 9");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_cmd2"), "noclip"), "off cmd2 defaults to noclip");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_cmd3"), "notarget"), "off cmd3 defaults to notarget");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_cmd4"), "fly"), "off cmd4 defaults to fly");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_cmd5"), "impulse 255"), "off cmd5 defaults to impulse 255");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_label0"), "GOD"), "off label0 defaults to GOD");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_label1"), "GIVE"), "off label1 defaults to GIVE");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_label2"), "NOCLIP"), "off label2 defaults to NOCLIP");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_label3"), "NOTGT"), "off label3 defaults to NOTGT");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_label4"), "FLY"), "off label4 defaults to FLY");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_off_label5"), "QUAD"), "off label5 defaults to QUAD");

	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_cmd0"), ""), "gun cmd0 defaults empty");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_cmd1"), ""), "gun cmd1 defaults empty");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_cmd2"), ""), "gun cmd2 defaults empty");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_cmd3"), ""), "gun cmd3 defaults empty");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_cmd4"), ""), "gun cmd4 defaults empty");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_cmd5"), ""), "gun cmd5 defaults empty");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_label0"), ""), "gun label0 defaults empty");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_label1"), ""), "gun label1 defaults empty");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_label2"), ""), "gun label2 defaults empty");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_label3"), ""), "gun label3 defaults empty");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_label4"), ""), "gun label4 defaults empty");
	CHECK (!strcmp (QC_CvarString ("vr_wristcomm_gun_label5"), ""), "gun label5 defaults empty");

	CHECK (!strcmp (QC_CvarString ("no_such_cvar_xyz"), ""), "missing cvar reads as empty string");
	CHECK (QC_CvarValue ("vr_wristcomm_off") == 1.0f && QC_CvarValue ("vr_wristcomm_gun") == 0.0f,
	       "off enabled, gun disabled by default");

	printf (failures ? "FAILED (%d)\n" : "PASSED (0 failures)\n", failures);
	return failures != 0;
}
