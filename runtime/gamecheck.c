#include "gamecheck.h"
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "rt.h"

#include "gamecheck_table.h"

static _Atomic unsigned g_damaged;
unsigned gamecheck_damaged(void) { return g_damaged; }

static uint32_t rd32(const uint8_t *m, uint64_t p) { uint32_t v; memcpy(&v, m + p, 4); return v; }
static uint64_t rd64(const uint8_t *m, uint64_t p) { uint64_t v; memcpy(&v, m + p, 8); return v; }

// data.trpfs: "ONEPACK\0", the root's position, and a flatbuffer table holding a vector of the packs' hashes and one of
// their positions. A pack runs to the next position (the last one to the table, or the end of the file). Anything
// outside the file: not a data.trpfs.
static const uint64_t *g_sort_starts;  // (qsort has no context argument; the check runs on one thread at a time)
static int cmp_start(const void *a, const void *b) {
    uint64_t x = g_sort_starts[*(const unsigned *)a], y = g_sort_starts[*(const unsigned *)b];
    return x < y ? -1 : x > y;
}

static bool pack_list(const uint8_t *m, uint64_t size, unsigned *n, uint64_t **hashes, uint64_t **starts, uint64_t **ends) {
    *hashes = *starts = *ends = NULL;
    if (size < 64 || memcmp(m, "ONEPACK\0", 8)) return false;
    uint64_t root = rd64(m, 8);
    if (root + 4 > size) return false;
    uint64_t t = root + rd32(m, root);
    if (t + 4 > size) return false;
    int64_t vt = (int64_t)t - (int32_t)rd32(m, t);
    if (vt < 0 || (uint64_t)vt + 8 > size) return false;
    uint16_t f_hash, f_off;
    memcpy(&f_hash, m + vt + 4, 2);
    memcpy(&f_off, m + vt + 6, 2);
    uint64_t hv = t + f_hash, ov = t + f_off;
    if (!f_hash || !f_off || hv + 4 > size || ov + 4 > size) return false;
    hv += rd32(m, hv);
    ov += rd32(m, ov);
    if (hv + 4 > size || ov + 4 > size) return false;
    unsigned count = rd32(m, hv);
    if (count != rd32(m, ov) || !count || hv + 4 + 8ull * count > size || ov + 4 + 8ull * count > size) return false;
    uint64_t *h = malloc(count * sizeof *h), *s = malloc(count * sizeof *s), *e = malloc(count * sizeof *e);
    if (!h || !s || !e) { free(h); free(s); free(e); return false; }
    uint64_t top = 0;
    for (unsigned i = 0; i < count; i++) {
        h[i] = rd64(m, hv + 4 + 8ull * i);
        s[i] = rd64(m, ov + 4 + 8ull * i);
        if (s[i] >= size) { free(h); free(s); free(e); return false; }
        if (s[i] > top) top = s[i];
    }
    uint64_t table_end = root > top ? root : size;
    unsigned *order = malloc(count * sizeof *order);
    if (!order) { free(h); free(s); free(e); return false; }
    for (unsigned i = 0; i < count; i++) order[i] = i;
    g_sort_starts = s;
    qsort(order, count, sizeof *order, cmp_start);
    for (unsigned k = 0; k < count; k++) {  // (the next start above this one: packs sharing a start share its end)
        unsigned j = k + 1;
        while (j < count && s[order[j]] == s[order[k]]) j++;
        e[order[k]] = j < count ? s[order[j]] : table_end;
    }
    free(order);
        *n = count, *hashes = h, *starts = s, *ends = e;
    return true;
}

bool gamecheck_run(const char *trpfs, GameCheck *r) {
    memset(r, 0, sizeof *r);
    int fd = open(trpfs, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) || st.st_size < 64) { if (fd >= 0) close(fd); return false; }
    uint64_t size = (uint64_t)st.st_size;
    const uint8_t *m = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return false;
    madvise((void *)m, size, MADV_SEQUENTIAL);
    unsigned n = 0;
    uint64_t *hashes, *starts, *ends;
    bool ok = pack_list(m, size, &n, &hashes, &starts, &ends);
    if (ok) {
        r->packs = n;
        for (size_t v = 0; v < sizeof gc_versions / sizeof *gc_versions; v++) {
            if (gc_versions[v].size != size) continue;
            r->known = true;
            if (gc_versions[v].count != n) {  // (the same file size, another pack list: the list itself is wrong)
                r->damaged = n;
                break;
            }
            for (unsigned i = 0; i < n; i++) {
                CC_SHA256_CTX c;
                uint8_t d[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256_Init(&c);
                for (uint64_t p = starts[i]; p < ends[i];) {  // (the update takes a 32-bit length)
                    uint64_t k = ends[i] - p < (1u << 28) ? ends[i] - p : (1u << 28);
                    CC_SHA256_Update(&c, m + p, (CC_LONG)k);
                    p += k;
                }
                CC_SHA256_Final(d, &c);
                uint32_t got = (uint32_t)d[0] << 24 | (uint32_t)d[1] << 16 | (uint32_t)d[2] << 8 | d[3];
                if (got != gc_versions[v].digests[i]) {
                    if (r->damaged < GAMECHECK_IDS) r->ids[r->damaged] = hashes[i];
                    r->damaged++;
                }
            }
            break;
        }
    }
    free(hashes), free(starts), free(ends);
    munmap((void *)m, size);
    return ok;
}

// <game_dir>/.packcheck: "<size> <mtime> <known> <packs> <damaged> <id>...": for this data.trpfs, not another one
static void result_path(const char *game_dir, char *out, size_t n) { snprintf(out, n, "%s/.packcheck", game_dir); }

static bool load_kept(const char *game_dir, const struct stat *st, GameCheck *r) {
    char p[1100];
    result_path(game_dir, p, sizeof p);
    FILE *f = fopen(p, "r");
    if (!f) return false;
    long long size, mtime;
    int known;
    unsigned packs, damaged;
    bool ok = fscanf(f, "%lld %lld %d %u %u", &size, &mtime, &known, &packs, &damaged) == 5 &&
              size == (long long)st->st_size && mtime == (long long)st->st_mtime;
    memset(r, 0, sizeof *r);
    if (ok) {
        r->known = known, r->packs = packs, r->damaged = damaged;
        for (unsigned i = 0; i < damaged && i < GAMECHECK_IDS; i++) {
            unsigned long long id;
            if (fscanf(f, "%llx", &id) != 1) { ok = false; break; }
            r->ids[i] = id;
        }
    }
    fclose(f);
    return ok;
}

static void keep(const char *game_dir, const struct stat *st, const GameCheck *r) {
    char p[1100];
    result_path(game_dir, p, sizeof p);
    FILE *f = fopen(p, "w");
    if (!f) return;
    fprintf(f, "%lld %lld %d %u %u", (long long)st->st_size, (long long)st->st_mtime, r->known, r->packs, r->damaged);
    for (unsigned i = 0; i < r->damaged && i < GAMECHECK_IDS; i++) fprintf(f, " %llx", (unsigned long long)r->ids[i]);
    fputc('\n', f);
    fclose(f);
}

bool gamecheck_ensure(const char *game_dir, GameCheck *r, bool *fresh) {
    char trpfs[1100];
    struct stat st;
    snprintf(trpfs, sizeof trpfs, "%s/romfs/arc/data.trpfs", game_dir);
    if (fresh) *fresh = false;
    if (stat(trpfs, &st)) return false;
    if (!load_kept(game_dir, &st, r)) {
        if (!gamecheck_run(trpfs, r)) return false;
        keep(game_dir, &st, r);
        if (fresh) *fresh = true;
    }
    g_damaged = r->known ? r->damaged : 0;
    return true;
}

void gamecheck_load_and_log(const char *game_dir) {
    char trpfs[1100];
    struct stat st;
    GameCheck r;
    snprintf(trpfs, sizeof trpfs, "%s/romfs/arc/data.trpfs", game_dir);
    if (stat(trpfs, &st) || !load_kept(game_dir, &st, &r)) return;  // (never checked here: nothing to say)
    g_damaged = r.known ? r.damaged : 0;
    if (!r.known) LOG("[files] data.trpfs is not a version with a clean copy to compare with: not checked\n");
    else if (!r.damaged) LOG("[files] data.trpfs: all %u packs match the clean copy\n", r.packs);
    else {
        LOG("[files] data.trpfs: %u of %u packs DIFFER from the clean copy (damaged game files):\n", r.damaged, r.packs);
        for (unsigned i = 0; i < r.damaged && i < GAMECHECK_IDS; i++) LOG("[files]   pack %016llx\n", (unsigned long long)r.ids[i]);
    }
}
