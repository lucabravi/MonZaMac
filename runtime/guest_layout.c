// Where the guest's address space lives (runtime/rt.h): the low window at GUEST_LO and the alias region.
#include "platform.h"
#include "rt.h"

#define GIB (1ull << 30)

uint64_t g_alias_base = GUEST_LOW_END, g_alias_size = 16 * GIB;  // (defaults: the alias region right behind the low window)

// Claim both reservations, before anything else can map there. false: the low window is taken, or no hole below 2^39
// holds the alias region (the caller starts again: the system's own regions move at every launch).
bool guest_reserve(void) {
    if (!plat_reserve_guest(GUEST_LO, GUEST_LOW_END)) return false;
    // The SDK's virtual address memory takes 12 GB of the alias region; smaller sizes only when no 16 GB hole is left.
    static const uint64_t sizes[] = {16 * GIB, 14 * GIB, 13 * GIB};
    for (unsigned i = 0; i < sizeof sizes / sizeof *sizes; i++)
        for (uint64_t at = GUEST_LOW_END; at + sizes[i] <= GUEST_LIMIT; at += GIB)
            if (plat_reserve_guest(at, at + sizes[i])) {
                g_alias_base = at;
                g_alias_size = sizes[i];
                LOG("[mem] guest layout: low window %llx-%llx, alias region %llx+%llx%s\n", GUEST_LO, GUEST_LOW_END, at, sizes[i],
                    at == GUEST_LOW_END ? "" : " (in a hole: the address space behind the low window is not free)");
                return true;
            }
    return false;
}

// Fresh zero pages over both reservations (an in-place reboot).
bool guest_reset(void) {
    return plat_reset_guest(GUEST_LO, GUEST_LOW_END) && plat_reset_guest(g_alias_base, g_alias_base + g_alias_size);
}
