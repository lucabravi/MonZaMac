#pragma once
#include <stdint.h>
#include <string.h>

typedef struct { uint64_t key; void *value; } NvnCacheEntry;

// Render-thread-only, non-owning fast index. count is a power of two, key is nonzero, and start is below count.
// The dictionary retains the objects: a full-table miss can clear this index and refill it through the slow path.
static inline uint32_t nvn_cache_probe(NvnCacheEntry *tab, uint32_t count, uint64_t key, uint32_t start) {
    uint32_t slot = start;
    for (uint32_t n = 0; n < count; n++) {
        if (!tab[slot].key || tab[slot].key == key) return slot;
        slot = (slot + 1) & (count - 1);
    }
    memset(tab, 0, (size_t)count * sizeof *tab);
    return start;
}
