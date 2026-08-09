/*
 * in_null.c -- input stub, replacing in_sdl.c.
 *
 * M4 replaces this with GameController (gamepad) and ARKit HandTrackingProvider
 * (aim ray + pinch). The engine-facing contract stays exactly this small:
 * push key events with Key_Event(), and fill usercmd_t in IN_Move().
 */

#include "quakedef.h"

void IN_Init (void)
{
}

void IN_Shutdown (void)
{
}

void IN_Commands (void)
{
	/* Joystick/controller button -> Key_Event translation goes here. */
}

void IN_MouseMotion (int dx, int dy)
{
	(void) dx;
	(void) dy;
}

void IN_SendKeyEvents (void)
{
	/* Upstream pumps SDL's event queue here. visionOS delivers input on the
	   main actor, so the Swift layer enqueues events and this drains them.
	   Nothing to drain yet. */
}

void IN_UpdateInputMode (void)
{
}

void IN_Move (usercmd_t *cmd)
{
	(void) cmd;
}

void IN_ClearStates (void)
{
}

void IN_Activate (void)
{
}

void IN_Deactivate (qboolean free_cursor)
{
	(void) free_cursor;
}
