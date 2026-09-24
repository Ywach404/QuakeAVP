/*
 * admin_avp.h -- the window's Admin tab, engine side. See admin_avp.c.
 */

#ifndef ADMIN_AVP_H
#define ADMIN_AVP_H

void Admin_Init (void);		/* register cvars/commands; after Cvar_Init */
void Admin_Frame (void);	/* once per QC_Frame, after Host_Frame */

#endif
