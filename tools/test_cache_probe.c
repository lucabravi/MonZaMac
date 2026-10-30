// Fast cache indices do not own values. A saturated miss must return to the authoritative cache, not spin.
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "../runtime/nvn/cache_probe.h"

static void check(uint32_t cap) {
    NvnCacheEntry *tab = calloc(cap, sizeof *tab); assert(tab);
    uint64_t *owned = malloc((cap + 64) * sizeof *owned); assert(owned);
    for (uint32_t i = 0; i < cap + 64; i++) owned[i] = 0x1234000000000000ull + i;
    // Every key deliberately has the same starting slot, exercising the complete collision chain and wraparound.
    uint32_t start = cap - 3;
    for (uint32_t k = 1; k <= cap; k++) {
        uint32_t i = nvn_cache_probe(tab, cap, k, start);
        assert(i < cap && !tab[i].key);
        tab[i] = (NvnCacheEntry){k, &owned[k - 1]};
    }
    // A full table still contains valid hits, including the last entry of the probe chain.
    for (uint32_t k = 1; k <= cap; k++) {
        uint32_t i = nvn_cache_probe(tab, cap, k, start);
        assert(tab[i].key == k && tab[i].value == &owned[k - 1]);
    }
    uint32_t i = nvn_cache_probe(tab, cap, cap + 1, start);
    assert(i == start);
    for (uint32_t k = 0; k < cap; k++) assert(!tab[k].key && !tab[k].value);
    // The owner kept every value. A slow-cache hit can repopulate an entry after the index was emptied.
    for (uint32_t k = 0; k < cap + 64; k++) assert(owned[k] == 0x1234000000000000ull + k);
    for (int round = 0; round < 3; round++) {
        for (uint32_t k = 1; k <= cap + 64; k++) {
            uint32_t slot = nvn_cache_probe(tab, cap, k, start);
            if (!tab[slot].key) tab[slot] = (NvnCacheEntry){k, &owned[k - 1]};
            assert(tab[slot].key == k);
            assert(*(uint64_t *)tab[slot].value == 0x1234000000000000ull + k - 1);
        }
    }
    memset(tab, 0, cap * sizeof *tab);
    assert(nvn_cache_probe(tab, cap, 1, 0) == 0);
    free(owned); free(tab);
    printf("PASS %u-entry cache: saturation, collisions, existing hits and repeated repopulation\n", cap);
}

int main(void) { check(4096); check(8192); return 0; }
