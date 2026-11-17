// Asset-free test of the online environment guard (runtime/online_env.c): the debug variables go, the supported ones stay.
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "../runtime/online_env.h"

int main(void) {
    setenv("LARECOMP_INPUT", "1:A:5", 1);
    setenv("LARECOMP_PLACE", "x", 1);
    setenv("LARECOMP_ROUTE", "r", 1);
    setenv("LARECOMP_DATA_ROOT", "/data", 1);
    setenv("LARECOMP_GAME_LIB", "/lib", 1);
    setenv("LARECOMP_PLAY_SAVE", "slot", 1);
    setenv("LARECOMP_NULL_GETTER", "0", 1);
    setenv("OTHER_VARIABLE", "kept", 1);

    rt_online_env_sanitize();  // (not online: nothing changes)
    assert(getenv("LARECOMP_INPUT") && getenv("LARECOMP_PLACE") && getenv("LARECOMP_ROUTE"));

    setenv("LUMIOSE_TEST_MODULE", "/module", 1);
    rt_online_env_sanitize();
    assert(!getenv("LARECOMP_INPUT") && !getenv("LARECOMP_PLACE") && !getenv("LARECOMP_ROUTE"));
    assert(!strcmp(getenv("LARECOMP_DATA_ROOT"), "/data") && !strcmp(getenv("LARECOMP_GAME_LIB"), "/lib"));
    assert(!strcmp(getenv("LARECOMP_PLAY_SAVE"), "slot") && !strcmp(getenv("LARECOMP_NULL_GETTER"), "0"));
    assert(!strcmp(getenv("OTHER_VARIABLE"), "kept") && !strcmp(getenv("LUMIOSE_TEST_MODULE"), "/module"));

    rt_online_env_sanitize();  // (again: nothing more happens, and the removed ones are still kept)
    setenv("LARECOMP_PLACE", "set again", 1);
    rt_online_env_restore();
    assert(!strcmp(getenv("LARECOMP_INPUT"), "1:A:5") && !strcmp(getenv("LARECOMP_ROUTE"), "r"));
    assert(!strcmp(getenv("LARECOMP_PLACE"), "set again"));  // (one set again since is not overwritten)
    return 0;
}
