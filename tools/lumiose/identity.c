// Compiled into each local prepared library; the runtime rejects mismatched pairs.
#include "gamelib.h"
#ifndef LUMIOSE_BUILD_ID
#error LUMIOSE_BUILD_ID must identify the original user-supplied module
#endif
GAMELIB_EXPORT const char *monzamac_lumiose_build_id(void) { return LUMIOSE_BUILD_ID; }
