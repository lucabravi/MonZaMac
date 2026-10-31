// Asset-free test of the crash explainer's wording (runtime/crash_explain.c): each known cause gets its own headline.
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "../runtime/rt.h"

const char *rt_host_fn_name(uint64_t pc, uint64_t *offset) { (void)offset; return pc == 0x1234 ? "f_1234" : NULL; }
bool plat_module_name(uint64_t pc, char *out, size_t n) {
    if (pc != 0x9999) return false;
    snprintf(out, n, "/System/Library/Extensions/AGXMetalG14X.bundle/AGXMetalG14X");
    return true;
}
void rt_fatal_trace(void) { abort(); }

// One cause per process: the explainer keeps only the first fatal line (argv[1] picks it, argv[2] the expected headline)
int main(int argc, char **argv) {
    char out[1600];
    assert(argc == 3);
    if (!strcmp(argv[1], "svcbreak")) rt_fatal_msg("svcBreak(reason=0, info=0, size=4) at 70\n");
    else if (!strcmp(argv[1], "terminate")) rt_fatal_msg("no function at 0 (lr=1 _ZSt13get_terminatev+20)\n");
    else if (!strcmp(argv[1], "font")) rt_fatal_msg("no usable system font substitute\n");
    else if (!strcmp(argv[1], "gpu")) rt_crash_fault("signal 11", 0x10, 0x9999);
    else if (!strcmp(argv[1], "game")) rt_crash_fault("signal 11", 0x10, 0x1234);
    else assert(!strcmp(argv[1], "other"));
    rt_crash_explain(out, sizeof out, "/x/play.log");
    assert(strstr(out, argv[2]) == out && strstr(out, "Log file:\n/x/play.log"));
    rt_crash_explain(out, sizeof out, "");
    assert(!strstr(out, "Log file"));
    return 0;
}
