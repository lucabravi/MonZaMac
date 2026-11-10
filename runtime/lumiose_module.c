// Support for an Exlaunch mod (Lumiose Online's subsdk9) loaded next to main and sdk, enabled by LUMIOSE_TEST_MODULE.
// The mod does not patch game code in place: it maps a private copy of it (svcMapProcessMemory), writes its hooks there
// and runs from it. Here the copy is a plain memory region, and the writes the mod's translated code makes to it are
// mirrored into the image the rest of the game runs (lumiose_test_store), so the patches can be seen and, later, translated.
#include <dlfcn.h>
#include <stdio.h>
#include <pthread.h>
#include <string.h>
#include "rt.h"
#include "hle.h"
#include "lumiose_rtld.h"

int lumiose_test_initializing;  // while the module's own initialization runs (kernel.c logs queries then)

typedef struct { uint64_t dst, src, size; } Alias;
static Alias aliases[64];
static unsigned alias_count;

static pthread_mutex_t alias_lock = PTHREAD_MUTEX_INITIALIZER;

// The formatter and parser share Newlib's decimal conversion scratch storage.
void lumiose_decimal_call(Cpu *c, uint64_t target) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&lock);
    c->pc = target;
    rt_dispatch(c);
    pthread_mutex_unlock(&lock);
}

// caller holds alias_lock
static void mirror(uint64_t original, const void *value, unsigned size) {
    memcpy((void *)(uintptr_t)original, value, size);
    for (unsigned j = 0; j < alias_count; j++) {
        Alias *o = &aliases[j];
        if (original >= o->src && original - o->src < o->size && size <= o->size - (original - o->src))
            memcpy((void *)(uintptr_t)(o->dst + original - o->src), value, size);
    }
}

// Native SDK copies do not pass through translated stores. Commit those differences before releasing an alias.
static unsigned alias_copyback(const Alias *a) {
    unsigned changed = 0;
    for (uint64_t off = 0; off < a->size;) {
        unsigned n = a->size - off < 8 ? (unsigned)(a->size - off) : 8;
        uint8_t value[8], original[8];
        memcpy(value, (void *)(uintptr_t)(a->dst + off), n);
        memcpy(original, (void *)(uintptr_t)(a->src + off), n);
        for (unsigned j = 0; j < n;) {
            if (value[j] == original[j]) { j++; continue; }
            unsigned start = j++;
            while (j < n && value[j] != original[j]) j++;
            // Preserve pending writes to adjacent bytes in another writable alias.
            mirror(a->src + off + start, value + start, j - start);
            changed += j - start;
        }
        off += n;
    }
    return changed;
}

bool lumiose_alias_add(uint64_t dst, uint64_t src, uint64_t size) {
    pthread_mutex_lock(&alias_lock);
    if (alias_count == 64) { pthread_mutex_unlock(&alias_lock); return false; }
    plat_commit(dst, size);
    memcpy((void *)(uintptr_t)dst, (void *)(uintptr_t)src, size);
    aliases[alias_count++] = (Alias){dst, src, size};
    pthread_mutex_unlock(&alias_lock);
    return true;
}

bool lumiose_alias_remove(uint64_t dst, uint64_t src, uint64_t size) {
    pthread_mutex_lock(&alias_lock);
    for (unsigned i = 0; i < alias_count; i++)
        if (aliases[i].dst == dst && aliases[i].src == src && aliases[i].size == size) {
            alias_copyback(&aliases[i]);
            if (!hle_guest_code_commit(src, size)) { pthread_mutex_unlock(&alias_lock); return false; }
            memmove(&aliases[i], &aliases[i + 1], (alias_count - i - 1) * sizeof *aliases);
            alias_count--;
            pthread_mutex_unlock(&alias_lock);
            return true;
        }
    pthread_mutex_unlock(&alias_lock);
    return false;
}

RT_ON_RESET(lumiose_module_reset) {
    pthread_mutex_lock(&alias_lock);
    alias_count = 0; lumiose_test_initializing = 0;
    pthread_mutex_unlock(&alias_lock);
}

void lumiose_test_store(uint64_t addr, uint64_t value, unsigned size) {
    addr = LUMIOSE_SHIFT(addr);
    pthread_mutex_lock(&alias_lock);
    uint64_t original = addr;
    bool copied = false;
    for (unsigned i = 0; i < alias_count; i++) {
        Alias *a = &aliases[i];
        if (addr >= a->dst && addr - a->dst < a->size && size <= a->size - (addr - a->dst)) {
            original = a->src + (addr - a->dst);
            copied = true;
            break;
        }
    }
    mirror(original, &value, size);
    pthread_mutex_unlock(&alias_lock);
    if (copied) LOG("[lumiose patch] %llx size %u value %llx\n", (unsigned long long)original, size, (unsigned long long)value);
}

// After the module's initialization: patches written some other way than by a store of its translated code (a library
// copy, an exclusive store) show as a difference between a copy and its original. LUMIOSE_TEST_DUMP=<dir> also writes
// the three modules' images there, to be compared with the unpatched ones.
void lumiose_test_snapshot(void) {
    pthread_mutex_lock(&alias_lock);
    unsigned found = 0;
    for (unsigned i = 0; i < alias_count; i++) found += alias_copyback(&aliases[i]);
    if (g_nmodules > 2 && !hle_guest_code_commit(HLE_CODE_BASE, HLE_CODE_SIZE))
        FATAL("unsupported guest HLE patch at initialization\n");
    LOG("[lumiose] %u aliases, %u bytes committed from writable copies\n", alias_count, found);
    pthread_mutex_unlock(&alias_lock);
    const char *dir = getenv("LUMIOSE_TEST_DUMP");
    if (!dir || !*dir) return;
    for (int i = 0; i < g_nmodules; i++) {
        char path[1100];
        snprintf(path, sizeof path, "%s/%s.image", dir, g_modules[i].name);
        FILE *f = fopen(path, "wb");
        if (!f || fwrite((void *)(uintptr_t)g_modules[i].base, 1, g_modules[i].size, f) != g_modules[i].size)
            FATAL("cannot write the Lumiose snapshot %s\n", path);
        fclose(f);
    }
    LOG("[lumiose] wrote the module images to %s\n", dir);
}

// A computed jump in the module's translated code that no table listed: tells where, instead of silently dispatching.
void lumiose_test_branch(Cpu *c, uint64_t entry, uint64_t end) {
    static int logged;
    if (!dispatch_lookup(c->pc) && logged++ < 50)
        LOG("[lumiose branch] %llx in %llx..%llx\n", (unsigned long long)c->pc, (unsigned long long)entry, (unsigned long long)end);
}

// Both local libraries carry the original NSO build ID, independently of the generator ABI stamp.
bool lumiose_library_matches(void *lib) {
    const char *path = getenv("LUMIOSE_TEST_MODULE");
    const char *(*identity)(void) = (const char *(*)(void))dlsym(lib, "monzamac_lumiose_build_id");
    if (!path || !identity) return false;
    FILE *f = fopen(path, "rb");
    unsigned char header[0x60];
    if (!f) return false;
    bool ok = fread(header, 1, sizeof header, f) == sizeof header && !memcmp(header, "NSO0", 4);
    fclose(f);
    if (!ok) return false;
    char id[65];
    for (unsigned i = 0; i < 32; i++) snprintf(id + i * 2, 3, "%02x", header[0x40 + i]);
    const char *compiled = identity();
    return compiled && !strcmp(compiled, id);
}

bool lumiose_capture_only(void) {
    const char *value = getenv("LUMIOSE_TEST_CAPTURE_ONLY");
    return value && !strcmp(value, "1");
}

// The module's translated functions, from the library LUMIOSE_TEST_LIBRARY names (tools/lumiose_test_entry.c).
bool lumiose_load_table(uint64_t base, uint64_t text_size, const uint64_t **addrs, const GuestFn **fns, uint64_t *count) {
    typedef struct { const uint64_t *addrs; const GuestFn *fns; uint64_t count; } Table;
    const char *path = getenv("LUMIOSE_TEST_LIBRARY");
    if (!path || !*path) return false;
    void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) { LOG("[lumiose] %s\n", dlerror()); return false; }
    if (!lumiose_library_matches(lib)) { dlclose(lib); return false; }
    const Table *(*entry)(void) = (const Table *(*)(void))dlsym(lib, "lumiose_test_table");
    const Table *t = entry ? entry() : NULL;
    if (!t || !t->count || t->addrs[0] < base || t->addrs[t->count - 1] >= base + text_size) return false;
    *addrs = t->addrs, *fns = t->fns, *count = t->count;
    LOG("[lumiose] %llu translated functions\n", (unsigned long long)t->count);
    return true;
}

// Exlaunch finds the modules by walking QueryMemory from address 0 and expects rtld first, then main, and it reads rtld's
// bytes. macOS gives this process no address below main (the range under 0x7000000000 is a no-access reservation), so rtld
// is loaded at LUMIOSE_RTLD_REAL and shown to the module at LUMIOSE_RTLD_SEEN: QueryMemory reports the regions there, and
// the module's own loads and stores are shifted (runtime/lumiose_cpu.h, lumiose_test_store). Only the module's code sees it.
static const Module *rtld;
void lumiose_set_rtld(const Module *m) { rtld = m; }

void lumiose_add_rtld_regions(void (*add)(uint64_t, uint64_t, uint32_t, uint32_t)) {
    if (g_nmodules <= 2 || !rtld) return;
    uint64_t delta = LUMIOSE_RTLD_SEEN - LUMIOSE_RTLD_REAL;
    add(rtld->base + rtld->text_off + delta, rtld->ro_off - rtld->text_off, 3, 5);
    add(rtld->base + rtld->ro_off + delta, rtld->data_off - rtld->ro_off, 3, 1);
    add(rtld->base + rtld->data_off + delta, rtld->size - rtld->data_off, 4, 3);
}
