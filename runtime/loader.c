// NSO loading, relocation, and symbol resolution.
#include <stdlib.h>
#include <string.h>

#include "rt.h"

Module g_modules[4];
int g_nmodules;

enum { DT_NULL = 0, DT_PLTRELSZ = 2, DT_HASH = 4, DT_STRTAB = 5, DT_SYMTAB = 6, DT_RELA = 7, DT_RELASZ = 8, DT_STRSZ = 10,
       DT_JMPREL = 23, DT_INIT_ARRAY = 25, DT_FINI_ARRAY = 26, DT_INIT_ARRAYSZ = 27, DT_FINI_ARRAYSZ = 28,
       DT_RELRSZ = 35, DT_RELR = 36 };
enum { R_ABS64 = 257, R_GLOB_DAT = 1025, R_JUMP_SLOT = 1026, R_RELATIVE = 1027 };

typedef struct { uint32_t name; uint8_t info, other; uint16_t shndx; uint64_t value, size; } Elf64Sym;
typedef struct { uint64_t off, info; int64_t addend; } Elf64Rela;

static size_t lz4_decompress(const uint8_t *src, size_t srclen, uint8_t *dst, size_t dstlen) {
    size_t s = 0, d = 0;
    while (s < srclen) {
        uint8_t tok = src[s++];
        size_t lit = tok >> 4;
        if (lit > dstlen - d) return SIZE_MAX;
        if (lit == 15) {
            uint8_t b;
            do {
                if (s == srclen) return SIZE_MAX;
                b = src[s++];
                if (b > dstlen - d - lit) return SIZE_MAX;
                lit += b;
            } while (b == 255);
        }
        if (lit > srclen - s) return SIZE_MAX;
        memcpy(dst + d, src + s, lit);
        d += lit; s += lit;
        if (s == srclen) return d;
        if (srclen - s < 2) return SIZE_MAX;
        size_t off = src[s] | (src[s + 1] << 8);
        s += 2;
        if (!off || off > d) return SIZE_MAX;
        size_t ml = (tok & 15) + 4;
        if (ml > dstlen - d) return SIZE_MAX;
        if ((tok & 15) == 15) {
            uint8_t b;
            do {
                if (s == srclen) return SIZE_MAX;
                b = src[s++];
                if (b > dstlen - d - ml) return SIZE_MAX;
                ml += b;
            } while (b == 255);
        }
        size_t m = d - off;
        while (ml--) dst[d++] = dst[m++];  // matches may overlap their source
    }
    return d;
}

static uint8_t *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END)) { fclose(f); return NULL; }
    long size = ftell(f);
    if (size < 0 || fseek(f, 0, SEEK_SET)) { fclose(f); return NULL; }
    *len = (size_t)size;
    uint8_t *p = malloc(*len ? *len : 1);
    if (!p || fread(p, 1, *len, f) != *len) { free(p); fclose(f); return NULL; }
    fclose(f);
    return p;
}

static bool fits(uint64_t off, uint64_t size, uint64_t limit) {
    return off <= limit && size <= limit - off;
}

static uint32_t word32(const void *p) { uint32_t v; memcpy(&v, p, sizeof v); return v; }

static void *module_range(Module *m, uint64_t off, uint64_t size, const char *what) {
    if (!fits(off, size, m->size)) FATAL("%s: %s outside NSO image\n", m->name, what);
    return (void *)(uintptr_t)(m->base + off);
}

static void *reloc_target(Module *m, uint64_t off) {
    return module_range(m, off, 8, "relocation target");
}

static void add_relative(Module *m, uint64_t off) {
    void *p = reloc_target(m, off);
    uint64_t v;
    memcpy(&v, p, sizeof v);
    v += m->base;
    memcpy(p, &v, sizeof v);
}

static uint64_t constructor(Module *m, uint64_t off) {
    if (!off) return 0;
    if ((off & 3) || off < m->text_off || !fits(off - m->text_off, 4, m->text_size))
        FATAL("%s: NSO constructor outside text\n", m->name);
    return m->base + off;
}

static void constructor_array(Module *m, uint64_t addr, uint64_t size) {
    if ((size & 7) || (!addr && size)) FATAL("%s: invalid NSO constructor array\n", m->name);
    if (!addr) return;
    if ((addr - m->base) & 7) FATAL("%s: unaligned NSO constructor array\n", m->name);
    module_range(m, addr - m->base, size, "constructor array");
}

static void load_nso(Module *m, const char *path, uint64_t base) {
    size_t len;
    uint8_t *raw = read_file(path, &len);
    if (!raw || len < 0x100 || memcmp(raw, "NSO0", 4)) FATAL("cannot load NSO header: %s\n", path);
    uint32_t flags = *(uint32_t *)(raw + 0xC);
    uint32_t seg[3][3];  // file_off, mem_off, size
    for (int i = 0; i < 3; i++) memcpy(seg[i], raw + 0x10 + i * 0x10, 12);
    uint32_t bss = *(uint32_t *)(raw + 0x3C);
    uint64_t end = (uint64_t)seg[2][1] + seg[2][2] + bss;
    uint64_t limit = base == MAIN_BASE ? SDK_BASE - MAIN_BASE : HLE_BASE - SDK_BASE;
    if (end > limit) FATAL("%s: NSO image exceeds its address window\n", path);
    uint64_t size = (end + 0x3FFF) & ~0x3FFFull;
    for (int i = 0; i < 3; i++) {
        uint32_t stored = flags & (1 << i) ? word32(raw + 0x60 + i * 4) : seg[i][2];
        if (!fits(seg[i][0], stored, len)) FATAL("%s: truncated NSO segment %d\n", path, i);
        if (i && seg[i][1] < (uint64_t)seg[i - 1][1] + seg[i - 1][2])
            FATAL("%s: overlapping NSO segment %d\n", path, i);
        if (!fits(seg[i][1], seg[i][2], size)) FATAL("%s: NSO segment %d outside image\n", path, i);
    }
    plat_commit(base, size);  // inside the guest window: zero-filled, read/write
    for (int i = 0; i < 3; i++) {
        uint32_t csize = *(uint32_t *)(raw + 0x60 + i * 4);
        uint8_t *dst = (uint8_t *)base + seg[i][1];
        if (flags & (1 << i)) {
            size_t got = lz4_decompress(raw + seg[i][0], csize, dst, seg[i][2]);
            if (got != seg[i][2]) FATAL("lz4 %s seg %d: %zu != %u\n", path, i, got, seg[i][2]);
        } else {
            memcpy(dst, raw + seg[i][0], seg[i][2]);
        }
    }
    free(raw);
    m->base = base;
    m->size = size;
    m->text_off = seg[0][1]; m->text_size = seg[0][2];
    m->ro_off = seg[1][1];   m->ro_size = seg[1][2];
    m->data_off = seg[2][1]; m->data_size = (uint64_t)seg[2][2] + bss;

    uint32_t mod0 = word32(module_range(m, 4, 4, "MOD0 offset"));
    uint8_t *mod = module_range(m, mod0, 28, "MOD0 header");
    if (memcmp(mod, "MOD0", 4)) FATAL("%s: invalid MOD0 header\n", path);
    int64_t dynoff = (int64_t)mod0 + (int32_t)word32(mod + 4);
    if (dynoff < 0 || (dynoff & 7)) FATAL("%s: invalid dynamic offset\n", path);
    m->dynamic = (uintptr_t)module_range(m, dynoff, 16, "dynamic table");
    m->symtab = m->strtab = m->nsyms = m->strtab_size = 0;
    m->init = m->fini = m->init_array = m->fini_array = m->init_array_sz = m->fini_array_sz = 0;
    bool has_strsize = false;
    for (uint64_t off = (uint64_t)dynoff;; off += 16) {
        uint64_t *d = module_range(m, off, 16, "dynamic table");
        if (d[0] == DT_NULL) break;
        switch (d[0]) {
        case DT_SYMTAB:
            if (d[1] & 7) FATAL("%s: unaligned symbol table\n", path);
            m->symtab = (uintptr_t)module_range(m, d[1], 0, "symbol table"); break;
        case DT_STRTAB: m->strtab = (uintptr_t)module_range(m, d[1], 0, "string table"); break;
        case DT_STRSZ: m->strtab_size = d[1]; has_strsize = true; break;
        case DT_HASH: m->nsyms = word32((uint8_t *)module_range(m, d[1], 8, "hash table") + 4); break;
        case 12: m->init = constructor(m, d[1]); break;  // DT_INIT
        case 13: m->fini = constructor(m, d[1]); break;  // DT_FINI
        case DT_INIT_ARRAY: m->init_array = (uintptr_t)module_range(m, d[1], 0, "init array"); break;
        case DT_INIT_ARRAYSZ: m->init_array_sz = d[1]; break;
        case DT_FINI_ARRAY: m->fini_array = (uintptr_t)module_range(m, d[1], 0, "fini array"); break;
        case DT_FINI_ARRAYSZ: m->fini_array_sz = d[1]; break;
        }
    }
    if (m->nsyms && !m->symtab) FATAL("%s: missing NSO symbol table\n", path);
    if (m->symtab) module_range(m, m->symtab - base, m->nsyms * sizeof(Elf64Sym), "symbol table");
    if (m->strtab) {
        if (!has_strsize) m->strtab_size = size - (m->strtab - base);
        module_range(m, m->strtab - base, m->strtab_size, "string table");
    } else if (m->nsyms || m->strtab_size) FATAL("%s: missing NSO string table\n", path);
    constructor_array(m, m->init_array, m->init_array_sz);
    constructor_array(m, m->fini_array, m->fini_array_sz);
    LOG("loaded %-5s at %llx size %llx syms %llu\n", m->name,
        (unsigned long long)base, (unsigned long long)size, (unsigned long long)m->nsyms);
}

static Elf64Sym *sym(Module *m, uint64_t i) {
    if (i >= m->nsyms) FATAL("%s: symbol index outside NSO table\n", m->name);
    return (Elf64Sym *)m->symtab + i;
}
static const char *symname(Module *m, Elf64Sym *s) {
    if (s->name >= m->strtab_size) FATAL("%s: invalid NSO symbol name\n", m->name);
    const char *name = (const char *)(m->strtab + s->name);
    if (!memchr(name, 0, m->strtab_size - s->name)) FATAL("%s: unterminated NSO symbol name\n", m->name);
    return name;
}

uint64_t loader_find_symbol(const char *name) {
    for (int mi = 0; mi < g_nmodules; mi++) {
        Module *m = &g_modules[mi];
        for (uint64_t i = 1; i < m->nsyms; i++) {
            Elf64Sym *s = sym(m, i);
            if (s->shndx && !strcmp(symname(m, s), name)) return m->base + s->value;
        }
    }
    return 0;
}

const char *loader_symbol_at(uint64_t addr, uint64_t *offset) {
    const char *best = NULL;
    uint64_t best_addr = 0;
    for (int mi = 0; mi < g_nmodules; mi++) {
        Module *m = &g_modules[mi];
        if (addr < m->base || addr >= m->base + m->size) continue;
        for (uint64_t i = 1; i < m->nsyms; i++) {
            Elf64Sym *s = sym(m, i);
            uint64_t a = m->base + s->value;
            if (s->shndx && (s->info & 0xF) == 2 && a <= addr && a > best_addr) {
                best = symname(m, s);
                best_addr = a;
            }
        }
    }
    if (offset) *offset = addr - best_addr;
    return best;
}

static uint64_t resolve(Module *m, uint32_t symidx) {
    Elf64Sym *s = sym(m, symidx);
    const char *name = symname(m, s);
    // host implementation wins over the guest SDK's (also for the SDK's calls to itself through its PLT: fibers)
    HostFn impl = hle_lookup_impl(name);
    if (impl) return hle_register(name, impl);
    if (s->shndx) return m->base + s->value;
    uint64_t a = loader_find_symbol(name);
    if (a) return a;
    if ((s->info >> 4) == 2) return 0;  // weak undefined
    if (getenv("LARECOMP_LOG_IMPORTS")) LOG("[loader] %s: no implementation for %s\n", m->name, name);
    return hle_register(name, NULL);
}

static void relocate(Module *m) {
    uint64_t rela = 0, relasz = 0, jmprel = 0, pltsz = 0, relr = 0, relrsz = 0;
    bool has_rela = false, has_jmprel = false, has_relr = false;
    for (uint64_t off = m->dynamic - m->base;; off += 16) {
        uint64_t *d = module_range(m, off, 16, "dynamic table");
        if (d[0] == DT_NULL) break;
        if (d[0] == DT_RELR) { relr = d[1]; has_relr = true; }
        if (d[0] == DT_RELRSZ) relrsz = d[1];
        if (d[0] == DT_RELA) { rela = d[1]; has_rela = true; }
        if (d[0] == DT_RELASZ) relasz = d[1];
        if (d[0] == DT_JMPREL) { jmprel = d[1]; has_jmprel = true; }
        if (d[0] == DT_PLTRELSZ) pltsz = d[1];
    }
    if ((relasz && !has_rela) || (pltsz && !has_jmprel) || (relrsz && !has_relr))
        FATAL("%s: NSO relocation table has no address\n", m->name);
    // RELR (newer SDKs, e.g. 19): packed relative relocations. An even entry is an address (relocated, then the
    // next word is the start of a bitmap run); an odd one a bitmap of the 63 words after that run's start.
    if ((relr & 7) || relrsz % 8) FATAL("%s: invalid RELR table\n", m->name);
    uint64_t *entries = module_range(m, relr, relrsz, "RELR table");
    uint64_t where = UINT64_MAX;
    for (uint64_t n = 0; n < relrsz / 8; n++) {
        uint64_t e = entries[n];
        if (!(e & 1)) {
            if (e & 7) FATAL("%s: unaligned RELR address\n", m->name);
            add_relative(m, e);
            where = e + 8;
            continue;
        }
        if (where == UINT64_MAX) FATAL("%s: RELR bitmap before address\n", m->name);
        for (int i = 1; i < 64; i++)
            if ((e >> i) & 1) add_relative(m, where + (i - 1) * 8);
        where += 63 * 8;
    }
    int unresolved = 0;
    for (int pass = 0; pass < 2; pass++) {
        uint64_t off = pass ? jmprel : rela, size = pass ? pltsz : relasz;
        if ((off & 7) || size % sizeof(Elf64Rela)) FATAL("%s: invalid RELA table\n", m->name);
        Elf64Rela *r = module_range(m, off, size, "RELA table");
        uint64_t n = size / sizeof(Elf64Rela);
        for (uint64_t i = 0; i < n; i++) {
            void *where = reloc_target(m, r[i].off);
            uint32_t type = (uint32_t)r[i].info, si = r[i].info >> 32;
            uint64_t value;
            switch (type) {
            case R_RELATIVE: value = m->base + r[i].addend; break;
            case R_ABS64:
            case R_GLOB_DAT:
            case R_JUMP_SLOT: {
                uint64_t s = resolve(m, si);
                value = s ? s + r[i].addend : 0;
                if (s >= HLE_BASE && s < HLE_BASE + HLE_SIZE) unresolved++;
                break;
            }
            default: FATAL("%s: reloc type %u\n", m->name, type);
            }
            memcpy(where, &value, sizeof value);  // RELA can target pointers in packed structures
        }
    }
    LOG("relocated %-5s (%d imports bound to host stubs)\n", m->name, unresolved);
}

void loader_load(const char *exefs) {
    char path[1024];
    static const struct { const char *name; uint64_t base; } mods[] = {{"main", MAIN_BASE}, {"sdk", SDK_BASE}};
    for (unsigned i = 0; i < 2; i++) {
        Module *m = &g_modules[g_nmodules++];
        m->name = mods[i].name;
        snprintf(path, sizeof path, "%s/%s", exefs, m->name);
        load_nso(m, path, mods[i].base);
    }
    for (int i = 0; i < g_nmodules; i++) relocate(&g_modules[i]);
}
