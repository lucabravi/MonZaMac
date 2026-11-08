// Entry of the library with a mod's translated code (the --lumiose build in tools/lumiose_build.sh): the function table.
#include "gamelib.h"

extern const uint64_t lumiose_fn_addrs[], lumiose_fn_count;
extern const GuestFn lumiose_fn_ptrs[];

typedef struct { const uint64_t *addrs; const GuestFn *fns; uint64_t count; } LumioseTable;

GAMELIB_EXPORT const LumioseTable *lumiose_test_table(void) {
    static LumioseTable t;
    t.addrs = lumiose_fn_addrs, t.fns = lumiose_fn_ptrs, t.count = lumiose_fn_count;
    return &t;
}
