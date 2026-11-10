// What the guest reservations meet on a given macOS. Not a test: run it many times, each start is a new layout.
//   clang -O1 -Iruntime tools/guest_layout_probe.c runtime/guest_layout.c runtime/platform/macos.c -Wl,-dead_strip -o probe
//   for i in $(seq 300); do PROBE_MODE=new ./probe; done | sort | uniq -c        (the layout of runtime/guest_layout.c)
//   for i in $(seq 300); do PROBE_MODE=old ./probe; done | sort | uniq -c        (one 32 GB window at 0x70_0000_0000, as before)
//   for i in $(seq 100); do PROBE_MODE=app ./probe; done | sed 's/darwin [0-9.]*  //' | sort | uniq -c   (with the restarts of runtime/main.c)
//   ./probe map                                                       (what is mapped between 0x10_0000_0000 and 2^39)
#include "platform.h"
#include "rt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/utsname.h>
#include <unistd.h>

static const char *mode;
static int result;  // 0 free 1 failed
// as the app does it: a constructor, after libSystem started and before main
__attribute__((constructor(101))) static void reserve(void) {
    mode = getenv("PROBE_MODE");
    if (!mode) return;
    if (!strcmp(mode, "new")) result = guest_reserve() ? 0 : 1;
    else if (!strcmp(mode, "old")) result = plat_reserve_guest(GUEST_LO, 0x7800000000ull) ? 0 : 1;
    else if (!strcmp(mode, "app")) {  // what runtime/main.c does: start again for a new layout, up to 60 times
        if (guest_reserve()) return;
        const char *tries = getenv("LARECOMP_REEXEC");
        int n = tries ? atoi(tries) : 0;
        if (n >= 60) { printf("app: FATAL after %d restarts\n", n); exit(1); }
        char buf[16]; snprintf(buf, sizeof buf, "%d", n + 1);
        setenv("LARECOMP_REEXEC", buf, 1);
        plat_exec(NULL);
        perror("re-exec"); exit(1);
    }
}

int main(int argc, char **argv) {
    struct utsname u; uname(&u);
    if (argc > 1 && !strcmp(argv[1], "map")) {
        mach_vm_address_t a = 0x1000000000ull; mach_vm_size_t last = 0;
        printf("darwin %s\n", u.release);
        while (a < GUEST_LIMIT) {
            mach_vm_size_t sz = 0; vm_region_basic_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t obj;
            if (mach_vm_region(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS || a >= GUEST_LIMIT) break;
            printf("  %#llx-%#llx  %6.2f GB  prot %d\n", (unsigned long long)a, (unsigned long long)(a + sz), sz / 1073741824.0, info.protection);
            a += sz; last = sz;
        }
        (void)last;
        return 0;
    }
    if (!mode) { fprintf(stderr, "usage: PROBE_MODE=new|old ./probe   or   ./probe map\n"); return 2; }
    if (!strcmp(mode, "app")) { const char *t = getenv("LARECOMP_REEXEC"); printf("darwin %s  app: reserved after %s restart(s)\n", u.release, t ? t : "0"); return 0; }
    printf("darwin %s  %s: %s", u.release, mode, result ? "FAILED" : "reserved");
    if (!result && !strcmp(mode, "new")) printf(g_alias_base == GUEST_LOW_END ? " (alias region behind the low window)" : " (alias region in a hole)");
    printf("\n");
    return 0;
}
