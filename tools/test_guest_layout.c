// The guest reservations (runtime/guest_layout.c) with the address space of macOS 27 imitated: two ~12 GB blocks of the
// system at random places in 0x70_0000_0000..2^39. Every trial runs in a process of its own.
#include "platform.h"
#include "rt.h"
#include "kernel.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

#define GIB (1ull << 30)

static bool block(uint64_t at, uint64_t size) {
    mach_vm_address_t a = at;
    return mach_vm_allocate(mach_task_self(), &a, size, VM_FLAGS_FIXED) == KERN_SUCCESS;
}
static bool taken(uint64_t at, uint64_t size) {  // true when nothing of [at, at+size) can be claimed any more
    mach_vm_address_t a = at;
    if (mach_vm_allocate(mach_task_self(), &a, size, VM_FLAGS_FIXED) == KERN_SUCCESS) { mach_vm_deallocate(mach_task_self(), at, size); return false; }
    return true;
}

// 0: the layout holds and is consistent; 1: no layout (a start again would be asked for); 2: wrong
static int trial(const uint64_t *blocks, uint64_t *alias, uint64_t *size) {
    for (int i = 0; blocks[i]; i++) block(blocks[i], 12 * GIB);
    if (!guest_reserve()) return 1;
    *alias = g_alias_base; *size = g_alias_size;
    if (g_alias_base < GUEST_LOW_END || g_alias_base + g_alias_size > GUEST_LIMIT) return 2;
    if (g_alias_size != 16 * GIB && g_alias_size != 14 * GIB && g_alias_size != 13 * GIB) return 2;
    if (!taken(GUEST_LO, GUEST_LOW_END - GUEST_LO) || !taken(g_alias_base, g_alias_size)) return 2;  // both are ours
    volatile uint8_t *p = (volatile uint8_t *)(uintptr_t)GUEST_LO; p[0] = 1; p[GUEST_LOW_END - GUEST_LO - 1] = 1;
    p = (volatile uint8_t *)(uintptr_t)g_alias_base; p[0] = 1; p[g_alias_size - 1] = 1;
    if (!guest_contains(HEAP_BASE, HEAP_MAX) || !guest_contains(STACK_BASE, 0x40000000ull) || !guest_contains(g_alias_base, g_alias_size) ||
        guest_contains(GUEST_LOW_END, 1) == (g_alias_base != GUEST_LOW_END)) return 2;
    if (!guest_reset()) return 2;
    return 0;
}

static int run(const uint64_t *blocks, uint64_t *alias, uint64_t *size) {
    int fd[2]; if (pipe(fd)) return 2;
    pid_t pid = fork();
    if (!pid) {
        uint64_t r[2] = {0, 0}; int rc = trial(blocks, &r[0], &r[1]);
        if (write(fd[1], r, sizeof r) != (ssize_t)sizeof r) _exit(9);
        _exit(rc);
    }
    uint64_t r[2] = {0, 0}; if (read(fd[0], r, sizeof r) != (ssize_t)sizeof r) return 2;
    int st; waitpid(pid, &st, 0); close(fd[0]); close(fd[1]);
    *alias = r[0]; *size = r[1];
    return WIFEXITED(st) ? WEXITSTATUS(st) : 2;
}

int main(void) {
    uint64_t a, s;
    // free space: the alias region right behind the low window, whole
    const uint64_t none_[] = {0};
    if (run(none_, &a, &s) != 0 || a != GUEST_LOW_END || s != 16 * GIB) { printf("FAIL free space (%llx %llx)\n", (unsigned long long)a, (unsigned long long)s); return 1; }
    // a block right behind the low window: the alias region goes to the hole after it
    const uint64_t behind[] = {GUEST_LOW_END, 0};
    if (run(behind, &a, &s) != 0 || a != GUEST_LOW_END + 12 * GIB) { printf("FAIL hole after a block (%llx)\n", (unsigned long long)a); return 1; }
    // no 13 GB hole anywhere (four 12 GB blocks, 1 GB apart): no layout
    const uint64_t full[] = {GUEST_LOW_END, GUEST_LOW_END + 13 * GIB, GUEST_LOW_END + 26 * GIB, GUEST_LOW_END + 39 * GIB, 0};
    if (run(full, &a, &s) != 1) { printf("FAIL full\n"); return 1; }
    // the low window itself taken: no layout
    const uint64_t low[] = {GUEST_LO + 2 * GIB, 0};
    if (run(low, &a, &s) != 1) { printf("FAIL low window taken\n"); return 1; }
    // macOS 27, imitated: two 12 GB blocks at random 1 GiB places below 2^39
    srand(1);
    int ok = 0, none = 0, far = 0, n = 300;
    for (int i = 0; i < n; i++) {
        uint64_t b1 = GUEST_LO + (uint64_t)(rand() % 52) * GIB, b2 = GUEST_LO + (uint64_t)(rand() % 52) * GIB;
        const uint64_t two[] = {b1, b2 == b1 ? 0 : b2, 0};
        int rc = run(two, &a, &s);
        if (rc == 2) { printf("FAIL trial %d (blocks %llx %llx)\n", i, (unsigned long long)b1, (unsigned long long)b2); return 1; }
        rc ? none++ : ok++;
        if (!rc && a != GUEST_LOW_END) far++;
    }
    printf("PASS guest layout: %d of %d launches reserve it (%d with the alias region away from the low window); %d ask for a restart\n", ok, n, far, none);
    return 0;
}
