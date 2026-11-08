// Where rtld really is, and where the Lumiose module sees it (lumiose_module.c).
#pragma once
#define LUMIOSE_RTLD_REAL 0x7007f00000ull  // the end of main's window
#define LUMIOSE_RTLD_SEEN 0x6ffff00000ull  // just below main, as on a Switch
#define LUMIOSE_SHIFT(a) ((a) - LUMIOSE_RTLD_SEEN < 0x100000ull ? (a) + (LUMIOSE_RTLD_REAL - LUMIOSE_RTLD_SEEN) : (a))
