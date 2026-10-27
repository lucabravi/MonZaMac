// Applet manager (appletOE), apm, and lm.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// The mode the game is told it runs in: docked or handheld.
bool am_handheld(void);
// Change the game's mode while it runs, notifying it of the switch-mode events.
void am_set_handheld(bool on);

#ifdef __cplusplus
}
#endif
