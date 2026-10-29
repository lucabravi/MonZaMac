// Run with tools/test_za_npc_capacity.sh. No game files are needed.
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

uint8_t g_game_build[8] = {0xb1, 0xf1, 0x2f, 0xd9, 0x19, 0xea, 0xe8, 0x6a};
void rt_za_npc_capacity(void);

int main(int argc, char **argv) {
    assert(argc == 2);
    if (!strcmp(argv[1], "unknown")) {
        g_game_build[0] = 0;
        rt_za_npc_capacity(); // Must not touch any guest address for other builds.
        return 0;
    }
    uint64_t base = 0x7006100000ull, selector = 0x7440000000ull;
    assert(mmap((void *)base, 0x10000, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0) == (void *)base);
    assert(mmap((void *)selector, 0x4000, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0) == (void *)selector);
    uint32_t *logical = (void *)0x700610b878ull;
    uint64_t *slot = (void *)0x700610b858ull;
    uint32_t *selection = (void *)(selector + 0x310);
    logical[1] = 0x428c0000; // Adjacent float, not part of the limit.
    selection[1] = 1;       // Adjacent flag, not part of the limit.
    if (!strcmp(argv[1], "disabled")) {
        setenv("LARECOMP_NPC_CAPACITY_FIX", "0", 1);
        *logical = 20; *slot = selector; *selection = 25;
        rt_za_npc_capacity();
        assert(*logical == 20 && *selection == 25);
        return 0;
    }
    unsetenv("LARECOMP_NPC_CAPACITY_FIX");
    rt_za_npc_capacity(); // Not initialized yet.
    assert(*logical == 0);
    *logical = 20;
    rt_za_npc_capacity(); // No selector yet: don't change either limit.
    assert(*logical == 20);
    *slot = selector + 1; // Misaligned pointers must be rejected.
    rt_za_npc_capacity();
    assert(*logical == 20);
    *slot = selector; *selection = 9;
    rt_za_npc_capacity(); // Unexpected configuration must stay untouched.
    assert(*logical == 20 && *selection == 9);
    *selection = 25;
    rt_za_npc_capacity();
    assert(*logical == 64 && *selection == 64);
    assert(logical[1] == 0x428c0000 && selection[1] == 1);
    rt_za_npc_capacity(); // Repeated frames are safe.
    assert(*logical == 64 && *selection == 64);
    *logical = 20; *selection = 25; // Scene/boot reconstruction.
    rt_za_npc_capacity();
    assert(*logical == 64 && *selection == 64);
    return 0;
}
