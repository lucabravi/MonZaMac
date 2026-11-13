#include "../nvn/shader_trace.h"
// fsp-srv: RomFS as a raw storage image, save data and SD card backed by host directories.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../hle.h"
#include "../platform.h"
#include "../ipc.h"

#ifndef O_BINARY
#define O_BINARY 0
#endif
#define FS_PATH_NOT_FOUND MAKE_RESULT(2, 1)
#define FS_PATH_EXISTS MAKE_RESULT(2, 2)
#define FS_TARGET_LOCKED MAKE_RESULT(2, 7)
#define FS_NOT_EMPTY MAKE_RESULT(2, 8)

const char *g_save_dir = "save";
static int romfs_fd = -1;
static bool replay_prepared;
static const char *replay_save_dir;

// ------------------------------------------------------------------ RomFS file index (offset -> path)
typedef struct { uint64_t start, size; char *path; int fd; const uint8_t *mem; } Overlay;
// in-image patches (copies of RomFS tables with changes): header, dir meta, file hash, file meta
typedef struct { uint64_t off, size; uint8_t *data; } Patch;
// A few slots are always reserved for the file/dir/hash/header overlays appended after prompt patches.
#define FS_PATCH_CAPACITY 256
#define FS_PATCH_RESERVED 4
static Patch patches[FS_PATCH_CAPACITY];
static int npatches;
static Overlay *ov;
static int ov_n, ov_cap;
static uint8_t *ov_meta;
static uint64_t ov_meta_off, ov_meta_size, ov_end;
// Lets the runtime see which game files are being streamed (e.g. which level is loading).
typedef struct { uint64_t off, size; char *path; uint32_t meta; } RomFile;
static RomFile *rom_files;
static int rom_nfiles;
static uint64_t rom_data_off;

// Reboot: the next seed builds its own index / overlay when the game opens the RomFS again.
RT_ON_RESET(fs_reset) {
    for (int i = 0; i < ov_n; i++) {
        if (ov[i].fd >= 0) close(ov[i].fd);
        free(ov[i].path);
        free((void *)ov[i].mem);  // extended tables and unlisted TRPFD bytes are owned by overlays
    }
    for (int i = 0; i < npatches; i++) free(patches[i].data);  // patched header/hash/metadata copies
    for (int i = 0; i < rom_nfiles; i++) free(rom_files[i].path);
    free(ov), free(rom_files);
    ov = NULL, ov_n = ov_cap = 0;
    ov_meta = NULL, ov_meta_off = ov_meta_size = ov_end = 0;
    npatches = 0;
    rom_files = NULL, rom_nfiles = 0, rom_data_off = 0;
    if (romfs_fd >= 0) close(romfs_fd);
    romfs_fd = -1;
    g_save_dir = "save";
    replay_prepared = false;
    replay_save_dir = NULL;
}

static int rom_cmp(const void *a, const void *b) {
    const RomFile *x = a, *y = b;
    return x->off < y->off ? -1 : x->off > y->off;
}

// Return false for an invalid parent chain instead of reading outside a damaged RomFS table.
static bool rom_dir_path(const uint8_t *dmeta, uint32_t dsize, uint32_t dir, char *out, size_t cap) {
    char parts[64][256];
    uint32_t visited[64];
    int n = 0;
    while (dir != 0) {  // root (offset 0) has an empty name
        if (n == 64 || dir > dsize || dsize - dir < 0x18) return false;
        for (int i = 0; i < n; i++) if (visited[i] == dir) return false;
        visited[n] = dir;
        uint32_t parent, namelen;
        memcpy(&parent, dmeta + dir, 4);
        memcpy(&namelen, dmeta + dir + 0x14, 4);
        if (!namelen || namelen > 255 || namelen > dsize - dir - 0x18) return false;
        memcpy(parts[n], dmeta + dir + 0x18, namelen);
        parts[n][namelen] = 0;
        if (strlen(parts[n]) != namelen || strchr(parts[n], '/') || strchr(parts[n], '\\') ||
            !strcmp(parts[n], ".") || !strcmp(parts[n], "..")) return false;
        n++;
        dir = parent;
    }
    out[0] = 0;
    for (int i = n - 1; i >= 0; i--) {
        if (strlcat(out, parts[i], cap) >= cap || strlcat(out, "/", cap) >= cap) return false;
    }
    return true;
}

// ---- layered files: each mods/<name>/romfs folder in name order (a folder
// whose name starts with '_' or '.' is off); the first layer with a file wins. A file the game's RomFS has is
// replaced (rom_index: its file-meta entry pointed at data past the image's end); a new one is added
// (add_new_files), with any directories it needs.
// Pokémon Z-A keeps its files in packs (arc/data.trpfs) listed by arc/data.trpfd, and reads a file from the RomFS
// only when the list doesn't have it: so the game's data.trpfd is served without the layered files' entries
// (trpfd_unlist). A mod's own data.trpfd is never used (it's made for the mod's game version).
static char layer_root[16][1100];
static int nlayers = -1;
static bool trinity;  // the RomFS has arc/data.trpfd
RT_ON_RESET(layer_reset) { nlayers = -1; trinity = false; }

static int name_cmp(const void *a, const void *b) { return strcmp((const char *)a, (const char *)b); }

static void layer_init(void) {
    if (nlayers >= 0) return;
    nlayers = 0;
    DIR *d = opendir("mods");
    if (!d) return;
    char names[15][256];
    int n = 0;
    for (struct dirent *e; (e = readdir(d)) && n < 15;) {
        if (e->d_name[0] == '.' || e->d_name[0] == '_') continue;
        char p[1100];
        struct stat sb;
        int written = snprintf(p, sizeof p, "mods/%s/romfs", e->d_name);
        if (written > 0 && (size_t)written < sizeof p && strlen(e->d_name) < sizeof *names &&
            !stat(p, &sb) && S_ISDIR(sb.st_mode))
            strlcpy(names[n++], e->d_name, sizeof *names);
    }
    closedir(d);
    qsort(names, n, sizeof *names, name_cmp);
    for (int i = 0; i < n; i++) {
        snprintf(layer_root[nlayers++], sizeof *layer_root, "mods/%s/romfs", names[i]);
        LOG("[fs] mod: %s\n", names[i]);
    }
}

static bool layer_file(const char *path, char *out, size_t cap) {
    layer_init();
    if (trinity && !strcmp(path, "arc/data.trpfd")) return false;
    for (int i = 0; i < nlayers; i++) {
        int written = snprintf(out, cap, "%s/%s", layer_root[i], path);
        struct stat sb;
        if (written > 0 && (size_t)written < cap && !lstat(out, &sb) && S_ISREG(sb.st_mode)) return true;
    }
    return false;
}

static uint32_t romfs_hash(uint32_t parent, const char *name, uint32_t len) {
    uint32_t hash = parent ^ 123456789;
    for (uint32_t i = 0; i < len; i++) { hash = (hash >> 5) | (hash << 27); hash ^= (uint8_t)name[i]; }
    return hash;
}

static int path_cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

typedef struct { char rel[1024]; char host[1200]; uint64_t size; uint32_t dir; } NewFile;

// the files under root/rel not in `known` (sorted; NULL: all of them)
static void walk_new(const char *root, const char *rel, char **known, int nknown, NewFile **out, int *n, int *cap) {
    char dirp[1200];
    int written = snprintf(dirp, sizeof dirp, "%s/%s", root, rel);
    if (written < 0 || (size_t)written >= sizeof dirp) return;
    DIR *d = opendir(dirp);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char r2[1024], h2[1200];
        int rn = snprintf(r2, sizeof r2, "%s%s%s", rel, rel[0] ? "/" : "", e->d_name);
        if (rn < 0 || (size_t)rn >= sizeof r2) continue;
        int hn = snprintf(h2, sizeof h2, "%s/%s", root, r2);
        if (hn < 0 || (size_t)hn >= sizeof h2) continue;
        struct stat sb;
        if (lstat(h2, &sb)) continue;  // never recurse into symlink loops or index files outside a mod
        if (S_ISDIR(sb.st_mode)) { walk_new(root, r2, known, nknown, out, n, cap); continue; }
        if (!S_ISREG(sb.st_mode)) continue;
        const char *key = r2;
        if (known && bsearch(&key, known, nknown, sizeof *known, path_cmp)) continue;  // replaces an existing file
        if (*n == *cap) {
            int next_cap = *cap ? *cap * 2 : 64;
            if (next_cap <= *cap) break;
            NewFile *grown = realloc(*out, sizeof **out * (size_t)next_cap);
            if (!grown) break;
            *out = grown;
            *cap = next_cap;
        }
        strlcpy((*out)[*n].rel, r2, sizeof (*out)[*n].rel);
        strlcpy((*out)[*n].host, h2, sizeof (*out)[*n].host);
        (*out)[*n].size = (uint64_t)sb.st_size;
        (*n)++;
    }
    closedir(d);
}

// directory entry offset for "a/b/c", created (with its parents) when missing: entries appended to dm (room
// reserved by the caller), linked into their parent's list and the directory hash table dh
static int64_t ensure_dir(uint8_t *dm, uint64_t *dsz, uint8_t *dh, uint32_t dnb, const char *path, int *created) {
    uint32_t cur = 0;
    char buf[1024];
    strlcpy(buf, path, sizeof buf);
    for (char *tok = strtok(buf, "/"); tok; tok = strtok(NULL, "/")) {
        uint32_t nl = (uint32_t)strlen(tok), child;
        memcpy(&child, dm + cur + 8, 4);
        while (child != 0xFFFFFFFFu && child + 0x18 <= *dsz) {
            uint32_t cl;
            memcpy(&cl, dm + child + 0x14, 4);
            if (cl == nl && !memcmp(dm + child + 0x18, tok, nl)) break;
            memcpy(&child, dm + child + 4, 4);
        }
        if (child == 0xFFFFFFFFu || child + 0x18 > *dsz) {
            uint32_t at = (uint32_t)*dsz, none = 0xFFFFFFFFu, first, prev, bucket = romfs_hash(cur, tok, nl) % dnb;
            memcpy(&first, dm + cur + 8, 4);
            memcpy(&prev, dh + 4 * bucket, 4);
            uint32_t e[6] = {cur, first, none, none, prev, nl};
            memcpy(dm + at, e, sizeof e);
            memset(dm + at + 0x18, 0, (nl + 3) & ~3u);
            memcpy(dm + at + 0x18, tok, nl);
            memcpy(dm + cur + 8, &at, 4);
            memcpy(dh + 4 * bucket, &at, 4);
            *dsz += 0x18 + ((nl + 3) & ~3u);
            (*created)++;
            child = at;
        }
        cur = child;
    }
    return cur;
}

// New files (names the game's RomFS doesn't have: a seed's generated dungeon cells, a mod's loose files...). The game
// parses the RomFS tables itself, so they're extended: copies of the file-meta table (and with new directories, of
// the directory table) with the new entries appended, linked into their directory's lists and the name hash buckets,
// are placed past the end of the image; the header and hash tables are patched to match.
static void add_new_files(int fd, const uint64_t *h, const uint8_t *dmeta, uint64_t dsz, uint64_t fsz) {
    layer_init();
    if (!nlayers) return;
    char **known = malloc(sizeof *known * rom_nfiles);
    for (int i = 0; i < rom_nfiles; i++) known[i] = rom_files[i].path;
    qsort(known, rom_nfiles, sizeof *known, path_cmp);
    NewFile *nf = NULL;
    int n = 0, cap = 0;
    for (int r = 0; r < nlayers; r++) {
        int before = n;
        walk_new(layer_root[r], "", known, rom_nfiles, &nf, &n, &cap);
        if (r) {  // (a file an earlier layer has already: that one wins)
            int k = before;
            for (int i = before; i < n; i++) {
                bool dup = false;
                for (int j = 0; j < before && !dup; j++) dup = !strcmp(nf[j].rel, nf[i].rel);
                if (!dup) nf[k++] = nf[i];
            }
            n = k;
        }
    }
    free(known);
    if (!n) return;
    rom_files = realloc(rom_files, sizeof(RomFile) * (rom_nfiles + n));
    uint64_t hoff = h[5], hsz = h[6], dhoff = h[1], dhsz = h[2];
    uint64_t dcap = dsz;
    for (int i = 0; i < n; i++) dcap += 0x1C * 16 + strlen(nf[i].rel);  // (room for every directory it could need)
    uint8_t *dcopy = malloc(dcap), *hcopy = malloc(hsz), *dhcopy = malloc(dhsz), *head = malloc(0x50);
    memcpy(dcopy, dmeta, dsz);
    if (pread(fd, hcopy, hsz, (off_t)hoff) != (ssize_t)hsz || pread(fd, dhcopy, dhsz, (off_t)dhoff) != (ssize_t)dhsz ||
        pread(fd, head, 0x50, 0) != 0x50)
        return;
    // directories first (the new file entries name them), then the file-meta table to extend: the override-patched
    // copy if there is one
    uint64_t dnow = dsz;
    int dirs = 0;
    for (int i = 0; i < n; i++) {
        char dirp[1024];
        strlcpy(dirp, nf[i].rel, sizeof dirp);
        char *slash = strrchr(dirp, '/');
        if (slash) *slash = 0; else dirp[0] = 0;
        nf[i].dir = (uint32_t)ensure_dir(dcopy, &dnow, dhcopy, (uint32_t)(dhsz / 4), dirp, &dirs);
    }
    const uint8_t *base_meta = ov_meta;
    uint8_t *tmp = NULL;
    if (!base_meta) { tmp = malloc(fsz); pread(fd, tmp, fsz, (off_t)h[7]); base_meta = tmp; }
    uint64_t extra = 0;
    for (int i = 0; i < n; i++) {
        const char *name = strrchr(nf[i].rel, '/');
        name = name ? name + 1 : nf[i].rel;
        extra += 0x20 + ((strlen(name) + 3) & ~3u);
    }
    uint64_t nsz = fsz + extra;
    uint8_t *meta = calloc(1, nsz);
    memcpy(meta, base_meta, fsz);
    free(tmp);
    if (!ov_end) {
        struct stat rs;
        fstat(fd, &rs);
        ov_end = (rs.st_size + 0xF) & ~0xFull;
    }
    uint64_t meta_at = ov_end;  // the new tables first, then the new files' data
    uint64_t dmeta_at = (meta_at + nsz + 0xF) & ~0xFull;
    uint64_t data_at = dirs ? (dmeta_at + dnow + 0xF) & ~0xFull : dmeta_at;
    uint32_t nb = (uint32_t)(hsz / 4);
    uint64_t o = fsz;
    int added = 0;
    for (int i = 0; i < n; i++) {
        const char *name = strrchr(nf[i].rel, '/');
        name = name ? name + 1 : nf[i].rel;
        uint32_t nl = (uint32_t)strlen(name), d32 = nf[i].dir, entry = (uint32_t)o, child;
        memcpy(&child, dcopy + d32 + 0xC, 4);  // dir's first file -> becomes our sibling
        uint64_t rel = data_at - rom_data_off, size = nf[i].size;
        uint32_t bucket = romfs_hash(d32, name, nl) % nb, prev;
        memcpy(&prev, hcopy + 4 * bucket, 4);
        memcpy(meta + o, &d32, 4);
        memcpy(meta + o + 4, &child, 4);
        memcpy(meta + o + 8, &rel, 8);
        memcpy(meta + o + 0x10, &size, 8);
        memcpy(meta + o + 0x18, &prev, 4);
        memcpy(meta + o + 0x1C, &nl, 4);
        memcpy(meta + o + 0x20, name, nl);
        memcpy(dcopy + d32 + 0xC, &entry, 4);
        memcpy(hcopy + 4 * bucket, &entry, 4);
        o += 0x20 + ((nl + 3) & ~3u);
        if (ov_n == ov_cap) { ov_cap = ov_cap ? ov_cap * 2 : 256; ov = realloc(ov, sizeof *ov * ov_cap); }
        ov[ov_n++] = (Overlay){data_at, size, strdup(nf[i].host), -1, NULL};
        rom_files[rom_nfiles++] = (RomFile){data_at, size, strdup(nf[i].rel), entry};
        data_at = (data_at + size + 0xF) & ~0xFull;
        added++;
    }
    // the new tables go before the new data (keep the overlay list sorted by start)
    int tables = dirs ? 2 : 1;
    if (ov_n + tables > ov_cap) { ov_cap = ov_n + tables + 256; ov = realloc(ov, sizeof *ov * ov_cap); }
    memmove(ov + (ov_n - added) + tables, ov + (ov_n - added), sizeof *ov * added);
    ov[ov_n - added] = (Overlay){meta_at, nsz, NULL, -1, meta};
    if (dirs) ov[ov_n - added + 1] = (Overlay){dmeta_at, dnow, NULL, -1, dcopy};
    ov_n += tables;
    ov_end = data_at;
    uint64_t fmeta_off = meta_at, fmeta_size = o;
    memcpy(head + 7 * 8, &fmeta_off, 8);
    memcpy(head + 8 * 8, &fmeta_size, 8);
    if (dirs) {
        memcpy(head + 3 * 8, &dmeta_at, 8);
        memcpy(head + 4 * 8, &dnow, 8);
        patches[npatches++] = (Patch){dhoff, dhsz, dhcopy};
    } else {
        patches[npatches++] = (Patch){h[3], dsz, dcopy};
        free(dhcopy);
    }
    patches[npatches++] = (Patch){0, 0x50, head};
    patches[npatches++] = (Patch){hoff, hsz, hcopy};
    LOG("[fs] %d new romfs files, %d new directories\n", added, dirs);
    free(nf);
}

static int u64_cmp(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }
static bool rom_span(uint64_t total, uint64_t off, uint64_t size) {
    return off <= total && size <= total - off;
}

// Pokémon Z-A: the game's arc/data.trpfd without the layered files (their FNV-1a 64 path hashes) - field 0 of its
// root table is the files' hashes, field 2 their pack entries (in step) - served in its place
static void trpfd_unlist(int fd, const uint8_t *fmeta, uint64_t foff, uint64_t fsz) {
    RomFile *rf = NULL;
    for (int i = 0; i < rom_nfiles && !rf; i++) if (!strcmp(rom_files[i].path, "arc/data.trpfd")) rf = &rom_files[i];
    trinity = rf != NULL;
    layer_init();
    if (!rf || !nlayers) return;
    NewFile *all = NULL;
    int n = 0, cap = 0;
    for (int r = 0; r < nlayers; r++) walk_new(layer_root[r], "", NULL, 0, &all, &n, &cap);
    if (!n || rf->size < 16 || rf->size > (256ull << 20)) { free(all); return; }
    uint64_t *hs = malloc(sizeof *hs * (size_t)n);
    if (!hs) { free(all); return; }
    for (int i = 0; i < n; i++) {
        uint64_t x = 0xCBF29CE484222645ull;
        for (const char *p = all[i].rel; *p; p++) x = (x ^ (uint8_t)*p) * 0x100000001B3ull;
        hs[i] = x;
    }
    free(all);
    qsort(hs, n, sizeof *hs, u64_cmp);
    uint8_t *d = malloc((size_t)rf->size);
    if (!d) { free(hs); return; }
    if (pread(fd, d, (size_t)rf->size, (off_t)rf->off) != (ssize_t)rf->size) goto malformed;
    uint64_t length = rf->size;
    uint32_t root, f0, f2, n0, n2;
    int32_t so;
    memcpy(&root, d, 4);
    if (!rom_span(length, root, 4)) goto malformed;
    memcpy(&so, d + root, 4);
    if (so <= 0 || (uint32_t)so > root) goto malformed;
    uint64_t vt = root - (uint32_t)so;
    if (!rom_span(length, vt, 10)) goto malformed;
    uint16_t fo0, fo2;
    memcpy(&fo0, d + vt + 4, 2);
    memcpy(&fo2, d + vt + 8, 2);
    if (!fo0 || !fo2 || !rom_span(length, (uint64_t)root + fo0, 4) ||
        !rom_span(length, (uint64_t)root + fo2, 4)) goto malformed;
    memcpy(&f0, d + root + fo0, 4);
    memcpy(&f2, d + root + fo2, 4);
    uint64_t v0 = (uint64_t)root + fo0 + f0, v2 = (uint64_t)root + fo2 + f2;
    if (!rom_span(length, v0, 4) || !rom_span(length, v2, 4)) goto malformed;
    memcpy(&n0, d + v0, 4);
    memcpy(&n2, d + v2, 4);
    if (n0 != n2) { LOG("[fs] arc/data.trpfd: unexpected layout\n"); goto malformed; }
    if (!rom_span(length, v0 + 4, (uint64_t)n0 * 8) ||
        !rom_span(length, v2 + 4, (uint64_t)n2 * 4)) goto malformed;
    uint32_t k = 0;
    for (uint32_t i = 0; i < n0; i++) {
        uint64_t x;
        memcpy(&x, d + v0 + 4 + 8 * i, 8);
        if (n && bsearch(&x, hs, n, sizeof *hs, u64_cmp)) continue;
        uint32_t e;
        memcpy(&e, d + v2 + 4 + 4 * i, 4);
        e += 4 * (i - k);  // (the entry moves 4 * (i - k) bytes closer: same target)
        memcpy(d + v0 + 4 + 8 * k, &x, 8);
        memcpy(d + v2 + 4 + 4 * k, &e, 4);
        k++;
    }
    free(hs);
    if (k == n0) { free(d); return; }
    memcpy(d + v0, &k, 4);
    memcpy(d + v2, &k, 4);
    if (!ov_meta) {
        ov_meta = malloc(fsz);
        memcpy(ov_meta, fmeta, fsz);
        ov_meta_off = foff;
        ov_meta_size = fsz;
    }
    if (!ov_end) {
        struct stat rs;
        fstat(fd, &rs);
        ov_end = (rs.st_size + 0xF) & ~0xFull;
    }
    uint64_t rel = ov_end - rom_data_off;
    memcpy(ov_meta + rf->meta + 8, &rel, 8);
    if (ov_n == ov_cap) { ov_cap = ov_cap ? ov_cap * 2 : 256; ov = realloc(ov, sizeof *ov * ov_cap); }
    ov[ov_n++] = (Overlay){ov_end, rf->size, NULL, -1, d};
    ov_end = (ov_end + rf->size + 0xF) & ~0xFull;
    LOG("[fs] arc/data.trpfd: %u files the mods have taken out of the packs' list\n", n0 - k);
    return;

malformed:
    LOG("[fs] arc/data.trpfd: malformed pack index; leaving original unchanged\n");
    free(d);
    free(hs);
}

// Button prompts (runtime/hle/pl.c pl_prompt_set): textures/prompts/<style>/romfs.patch, made by
// tools/za/prompt_textures.py - Pokémon Z-A's icon fonts relabelled, in their pack rebuilt to the same size. "ZAROMFS2",
// a u32 count, then records (u8 kind = 0, u16 path length, path, u64 offset, u64 length, u64 FNV-1a 64 of the bytes
// replaced, data): the bytes replace those at that offset in that RomFS file - only when the file has the bytes the
// record was made for (one patch file covers several game versions; another version's records are left out).
static void prompt_patch(int fd) {
    extern const char *pl_prompt_set(void);
    const char *set = pl_prompt_set();
    if (!set) return;
    char path[128];
    snprintf(path, sizeof path, "textures/prompts/%s/romfs.patch", set);
    FILE *f = fopen(path, "rb");
    if (!f) return;
    // Mod-supplied patch files are not trusted: never allocate from an unchecked file length.
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return; }
    long len = ftell(f);
    if (len <= 12 || (uint64_t)len > (64ull << 20) || fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        LOG("[fs] %s: invalid patch size\n", path);
        return;
    }
    uint8_t *d = malloc((size_t)len);
    if (!d) { fclose(f); return; }
    bool ok = fread(d, 1, (size_t)len, f) == (size_t)len && !memcmp(d, "ZAROMFS2", 8);
    fclose(f);
    if (!ok) { LOG("[fs] %s: not a patch file\n", path); free(d); return; }
    uint32_t n;
    memcpy(&n, d + 8, 4);
    uint64_t p = 12;
    int applied = 0;
    for (uint32_t r = 0; r < n && (uint64_t)len - p >= 27; r++) {
        uint16_t pl;
        memcpy(&pl, d + p + 1, 2);
        // 27 fixed bytes + the path precede the replacement bytes. Validate before reading any of them.
        if (pl > 255 || pl > (uint64_t)len - p - 27) break;
        char name[256];
        memcpy(name, d + p + 3, pl);
        name[pl] = 0;
        uint64_t off, size, want;
        memcpy(&off, d + p + 3 + pl, 8);
        memcpy(&size, d + p + 11 + pl, 8);
        memcpy(&want, d + p + 19 + pl, 8);
        if (size > (uint64_t)len - p - 27 - pl) break;
        const uint8_t *data = d + p + 27 + pl;
        uint8_t kind = d[p];
        p += 27 + pl + size;
        RomFile *rf = NULL;
        for (int i = 0; i < rom_nfiles && !rf; i++) if (!strcmp(rom_files[i].path, name)) rf = &rom_files[i];
        if (kind || !rf || !size || off > rf->size || size > rf->size - off ||
            npatches >= FS_PATCH_CAPACITY - FS_PATCH_RESERVED) {
            LOG("[fs] %s: %s not patched\n", path, name);
            continue;
        }
        uint8_t *copy = malloc((size_t)size);
        if (!copy) break;
        uint64_t have = 0xCBF29CE484222645ull;
        if (pread(fd, copy, size, (off_t)(rf->off + off)) == (ssize_t)size)
            for (uint64_t i = 0; i < size; i++) have = (have ^ copy[i]) * 0x100000001B3ull;
        if (have != want) { free(copy); continue; }  // (another game version's)
        memcpy(copy, data, size);
        patches[npatches++] = (Patch){rf->off + off, size, copy};
        applied++;
    }
    free(d);
    LOG("[fs] button prompts: %d patches from %s\n", applied, path);
}

static void rom_index(int fd) {
    uint64_t h[10];
    struct stat sb;
    if (fstat(fd, &sb) || sb.st_size < (off_t)sizeof h ||
        pread(fd, h, sizeof h, 0) != (ssize_t)sizeof h) return;
    // header: size, dir hash (off,size), dir meta (off,size), file hash (off,size), file meta (off,size), data off
    uint64_t length = (uint64_t)sb.st_size;
    uint64_t doff = h[3], dsz = h[4], foff = h[7], fsz = h[8];
    // File metadata offsets are stored in u32 fields; reject invalid or oversized input tables before allocating.
    const uint64_t max_table = 256ull << 20;
    if (h[0] < sizeof h || dsz < 0x18 || dsz > max_table || fsz > max_table ||
        h[9] > length ||
        doff > length || dsz > length - doff || foff > length || fsz > length - foff ||
        !h[2] || !h[6] || (h[2] & 3) || (h[6] & 3) ||
        h[1] > length || h[2] > length - h[1] ||
        h[5] > length || h[6] > length - h[5]) {
        LOG("[fs] invalid RomFS table bounds\n");
        return;
    }
    uint8_t *dmeta = malloc((size_t)dsz), *fmeta = malloc((size_t)(fsz ? fsz : 1));
    if (!dmeta || !fmeta) { free(dmeta); free(fmeta); return; }
    if (pread(fd, dmeta, (size_t)dsz, (off_t)doff) != (ssize_t)dsz ||
        pread(fd, fmeta, (size_t)fsz, (off_t)foff) != (ssize_t)fsz) {
        free(dmeta); free(fmeta); return;
    }
    int cap = 4096;
    rom_files = malloc(sizeof(RomFile) * (size_t)cap);
    if (!rom_files) { free(dmeta); free(fmeta); return; }
    rom_data_off = h[9];
    for (uint64_t o = 0; o < fsz;) {
        if (fsz - o < 0x20) goto invalid_metadata;
        uint32_t parent, namelen;
        uint64_t data, size;
        memcpy(&parent, fmeta + o, 4);
        memcpy(&data, fmeta + o + 8, 8);
        memcpy(&size, fmeta + o + 0x10, 8);
        memcpy(&namelen, fmeta + o + 0x1C, 4);
        if (!namelen || namelen > 255 || namelen > fsz - o - 0x20 ||
            data > length - rom_data_off || size > length - rom_data_off - data) goto invalid_metadata;
        uint64_t entry_size = 0x20 + (((uint64_t)namelen + 3) & ~3ull);
        if (entry_size > fsz - o) goto invalid_metadata;
        char dir[1024], name[256];
        if (!rom_dir_path(dmeta, (uint32_t)dsz, parent, dir, sizeof dir)) goto invalid_metadata;
        memcpy(name, fmeta + o + 0x20, namelen);
        name[namelen] = 0;
        if (strlen(name) != namelen || strchr(name, '/') || strchr(name, '\\') ||
            !strcmp(name, ".") || !strcmp(name, "..")) goto invalid_metadata;
        if (rom_nfiles == cap) {
            if (cap > INT32_MAX / 2) goto invalid_metadata;
            cap *= 2;
            RomFile *next = realloc(rom_files, sizeof(RomFile) * (size_t)cap);
            if (!next) goto invalid_metadata;
            rom_files = next;
        }
        char *path = malloc(strlen(dir) + namelen + 1);
        if (!path) goto invalid_metadata;
        strcpy(path, dir);
        strcat(path, name);
        rom_files[rom_nfiles++] = (RomFile){rom_data_off + data, size, path, (uint32_t)o};
        o += entry_size;
    }
    // Layered files (mods): replacements are served from their folders. The file-meta table is patched
    // (in a copy) to point them at data appended past the end of the image; reads there go to host files.
    trpfd_unlist(fd, fmeta, foff, fsz);
    for (int i = 0; i < rom_nfiles; i++) {
        char host[1200];
        if (!layer_file(rom_files[i].path, host, sizeof host)) continue;
        struct stat sb;
        if (stat(host, &sb)) continue;
        if (!ov_meta) {
            ov_meta = malloc(fsz);
            memcpy(ov_meta, fmeta, fsz);
            ov_meta_off = foff;
            ov_meta_size = fsz;
            struct stat rs;
            fstat(fd, &rs);
            ov_end = (rs.st_size + 0xF) & ~0xFull;
        }
        uint64_t rel = ov_end - rom_data_off, size = (uint64_t)sb.st_size;
        memcpy(ov_meta + rom_files[i].meta + 8, &rel, 8);
        memcpy(ov_meta + rom_files[i].meta + 0x10, &size, 8);
        if (ov_n == ov_cap) { ov_cap = ov_cap ? ov_cap * 2 : 256; ov = realloc(ov, sizeof *ov * ov_cap); }
        ov[ov_n].start = ov_end;
        ov[ov_n].size = size;
        ov[ov_n].path = strdup(host);
        ov[ov_n].fd = -1;
        ov[ov_n].mem = NULL;
        ov_n++;
        ov_end = (ov_end + size + 0xF) & ~0xFull;
    }
    if (ov_n) LOG("[fs] %d romfs files replaced (mods)\n", ov_n);
    prompt_patch(fd);
    if (ov_meta) { patches[npatches++] = (Patch){ov_meta_off, ov_meta_size, ov_meta}; }
    add_new_files(fd, h, dmeta, dsz, fsz);
    qsort(rom_files, rom_nfiles, sizeof *rom_files, rom_cmp);
    free(dmeta);
    free(fmeta);
    LOG("[fs] romfs index: %d files\n", rom_nfiles);
    return;

invalid_metadata:
    LOG("[fs] malformed RomFS file metadata; overlay indexing skipped\n");
    for (int i = 0; i < rom_nfiles; i++) free(rom_files[i].path);
    free(rom_files); rom_files = NULL; rom_nfiles = 0; rom_data_off = 0;
    free(dmeta);
    free(fmeta);

}

// Virtual RomFS image read: original bytes, with the patched file table and appended replacement files.
static ssize_t romfs_read(int fd, uint8_t *dst, uint64_t size, uint64_t off) {
    if (!ov_n && !npatches) return pread(fd, dst, size, (off_t)off);
    uint64_t done = 0;
    while (done < size) {
        uint64_t o = off + done, n = size - done;
        if (ov_n && o >= ov[0].start) {  // appended region
            int i = 0;
            while (i < ov_n && !(o >= ov[i].start && o < ov[i].start + ((ov[i].size + 0xF) & ~0xFull))) i++;
            if (i == ov_n) { memset(dst + done, 0, n); done += n; break; }
            uint64_t in = o - ov[i].start, avail = ((ov[i].size + 0xF) & ~0xFull) - in;
            if (n > avail) n = avail;
            ssize_t r;
            if (ov[i].mem) {  // in-memory blob (the extended file table)
                r = in < ov[i].size ? (ssize_t)(n < ov[i].size - in ? n : ov[i].size - in) : 0;
                memcpy(dst + done, ov[i].mem + in, (size_t)r);
            } else {
                if (ov[i].fd < 0) ov[i].fd = open(ov[i].path, O_RDONLY);
                r = in < ov[i].size ? pread(ov[i].fd, dst + done, n < ov[i].size - in ? n : ov[i].size - in, (off_t)in) : 0;
            }
            if (r < 0) r = 0;
            if ((uint64_t)r < n) memset(dst + done + r, 0, n - r);
        } else {
            if (ov_n && o + n > ov[0].start) n = ov[0].start - o;
            ssize_t r = pread(fd, dst + done, n, (off_t)o);
            if (r < 0) r = 0;
            if ((uint64_t)r < n) memset(dst + done + r, 0, n - r);
            // overlay the patched tables (file meta, and with added files: header, dir meta, file hash)
            for (int k = 0; k < npatches; k++) {
                uint64_t a = o > patches[k].off ? o : patches[k].off;
                uint64_t b = o + n < patches[k].off + patches[k].size ? o + n : patches[k].off + patches[k].size;
                if (a < b) memcpy(dst + done + (a - o), patches[k].data + (a - patches[k].off), b - a);
            }
        }
        done += n;
    }
    return (ssize_t)done;
}

// Path of the RomFS file containing image offset `off` (NULL if none).
// the RomFS file holding image offset `off` (NULL: none), *base its start (optional)
static const char *romfs_file_base(uint64_t off, uint64_t *base) {
    int lo = 0, hi = rom_nfiles - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (off < rom_files[mid].off) hi = mid - 1;
        else if (off >= rom_files[mid].off + rom_files[mid].size) lo = mid + 1;
        else { if (base) *base = rom_files[mid].off; return rom_files[mid].path; }
    }
    return NULL;
}
const char *romfs_file_at(uint64_t off) { return romfs_file_base(off, NULL); }


// ------------------------------------------------------------------ IStorage (raw RomFS image)
typedef struct { int fd; uint64_t size; } Storage;

static void storage(Service *s, IpcReq *req, IpcResp *resp) {
    Storage *st = s->state;
    switch (req->cmd) {
    case 0: {  // Read(offset, size) -> B buffer
        uint64_t off = IN(uint64_t, 0), size = IN(uint64_t, 8);
        IpcBuf *b = out_buf(req, 0);
        if (!b) { resp->result = MAKE_RESULT(2, 6001); break; }
        if (size > b->size) size = b->size;
        ssize_t n = romfs_read(st->fd, (uint8_t *)(uintptr_t)b->addr, size, off);
        if (n > 0 && shader_trace_enabled()) {
            uint64_t base = 0;
            const char *path = romfs_file_base(off, &base);
            const char *last = romfs_file_at(off + (uint64_t)n - 1);
            bool one_file = path && path == last;
            shader_trace_read(one_file ? path : "<romfs-image>", one_file ? off - base : off, b->addr, (size_t)n);
        }
        if (n < 0) LOG("[fs] storage read failed at %llx: %s\n", off, strerror(errno));
        {   // (debug) LARECOMP_LOG_READS=<file>: every read as "<RomFS path> <offset in the file> <size>"
            static FILE *rf;
            static int on = -1;
            if (on < 0) { const char *e = getenv("LARECOMP_LOG_READS"); on = e && (rf = fopen(e, "w")) != NULL; }
            if (on) {
                uint64_t base = 0;
                const char *path = romfs_file_base(off, &base);
                fprintf(rf, "%s %llx %llx\n", path ? path : "?", (unsigned long long)(off - base), (unsigned long long)size);
                fflush(rf);
            }
        }
        {
            const char *path = romfs_file_at(off);
            static const char *last;
            if (path && path != last) {
                last = path;
                if (getenv("LARECOMP_LOG_FILES")) LOG("[fs] read %s\n", path);
            }
        }
        static uint64_t reads, bytes;
        reads++;
        bytes += size;
        if ((reads & (reads - 1)) == 0) LOG("[fs] romfs reads: %llu (%llu KB)\n", reads, bytes >> 10);
        break;
    }
    case 4: OUT(uint64_t, 0) = ov_n ? ov_end : st->size; resp_size(resp, 8); break;  // GetSize
    default: LOG("[fs] IStorage cmd %u (ok)\n", req->cmd);
    }
}

// a plain storage: a host file's bytes (add-on content)
static void plain_storage_close(Service *s) {
    Storage *st = s->state;
    if (!st) return;
    close(st->fd);
    free(st);
    s->state = NULL;
}

static void plain_storage(Service *s, IpcReq *req, IpcResp *resp) {
    Storage *st = s->state;
    switch (req->cmd) {
    case 0: {  // Read(offset, size) -> B buffer
        uint64_t off = IN(uint64_t, 0), size = IN(uint64_t, 8);
        IpcBuf *b = out_buf(req, 0);
        if (!b) { resp->result = MAKE_RESULT(2, 6001); break; }
        if (size > b->size) size = b->size;
        ssize_t n = pread(st->fd, (uint8_t *)(uintptr_t)b->addr, size, (off_t)off);
        if (n > 0 && shader_trace_enabled()) shader_trace_read("<add-on-storage>", off, b->addr, (size_t)n);
        if (n < 0) n = 0;
        if ((uint64_t)n < size) memset((uint8_t *)(uintptr_t)b->addr + n, 0, size - n);
        break;
    }
    case 4: OUT(uint64_t, 0) = st->size; resp_size(resp, 8); break;  // GetSize
    default: LOG("[fs] IStorage(aoc) cmd %u (ok)\n", req->cmd);
    }
}

static Service *open_romfs_storage(void) {
    if (romfs_fd < 0) {
        char path[1024];
        snprintf(path, sizeof path, "%s.bin", g_romfs_dir);  // extracted/romfs.bin
        romfs_fd = open(path, O_RDONLY);
        if (romfs_fd < 0) FATAL("cannot open %s (set up the game files on the start screen)\n", path);
        rom_index(romfs_fd);
    }
    Storage *st = calloc(1, sizeof *st);
    st->fd = romfs_fd;
    struct stat sb;
    fstat(romfs_fd, &sb);
    st->size = sb.st_size;
    return service_new("IStorage(romfs)", storage, st);
}

// ------------------------------------------------------------------ host-directory filesystem
typedef struct { char root[1024]; } HostFs;
typedef struct { int fd; char path[1100]; } HostFile;
typedef struct { DIR *d; char path[1024]; int mode; } HostDir;

static void file_close(Service *s) {
    HostFile *f = s->state;
    if (!f) return;
    close(f->fd);
    free(f);
    s->state = NULL;
}

static void directory_close(Service *s) {
    HostDir *d = s->state;
    if (!d) return;
    closedir(d->d);
    free(d);
    s->state = NULL;
}

static const char *in_path(IpcReq *req, int i) {
    if (i < req->nx) return (const char *)(uintptr_t)req->x[i].addr;
    if (i < req->na) return (const char *)(uintptr_t)req->a[i].addr;
    return "";
}

// The configured root may be a link; descendants must be ordinary game-created files and directories.
// This rejects existing links and traversal, but does not guard against concurrent host-side path replacement.
static bool host_path(HostFs *fs, const char *p, char *out, size_t n) {
    for (const char *c = p; *c; ) {
        const char *e = c + strcspn(c, "/");
        if (e - c == 2 && c[0] == '.' && c[1] == '.') return false;
        c = *e ? e + 1 : e;
    }
    int len = snprintf(out, n, "%s%s%s", fs->root, p[0] == '/' ? "" : "/", p);
    if (len < 0 || (size_t)len >= n) return false;
    char *part = out + strlen(fs->root);
    while (*part) {
        if (*part == '/') { part++; continue; }
        char *end = part + strcspn(part, "/"), next = *end;
        *end = 0;
        struct stat st;
        int r = lstat(out, &st), error = errno;
        *end = next;
        if ((!r && S_ISLNK(st.st_mode)) || (r && error != ENOENT)) return false;
        part = next ? end + 1 : end;
    }
    return true;
}

static uint32_t errno_result(void) {
    if (errno == ENOENT || errno == ENOTDIR) return FS_PATH_NOT_FOUND;
    if (errno == EEXIST) return FS_PATH_EXISTS;
    if (errno == ENOTEMPTY) return FS_NOT_EMPTY;
    LOG("[fs] host error %d (%s): result 2002-4000\n", errno, strerror(errno));  // (the game aborts on it)
    return MAKE_RESULT(2, 4000);
}

static void file(Service *s, IpcReq *req, IpcResp *resp) {
    HostFile *f = s->state;
    switch (req->cmd) {
    case 0: {  // Read(option, offset, size) -> B
        int64_t off = IN(int64_t, 8), size = IN(int64_t, 16);
        IpcBuf *b = out_buf(req, 0);
        if (!b || off < 0 || size < 0 || size > INT64_MAX - off) {
            resp->result = MAKE_RESULT(2, 6001); break;
        }
        if ((uint64_t)size > b->size) size = (int64_t)b->size;
        ssize_t n;
        do { n = pread(f->fd, (void *)(uintptr_t)b->addr, (size_t)size, off); } while (n < 0 && errno == EINTR);
        if (n > 0 && shader_trace_enabled()) shader_trace_read(f->path, (uint64_t)off, b->addr, (size_t)n);
        if (n < 0) resp->result = errno_result();
        if (strstr(f->path, "savedata")) {
            LOG("[save] read %s off %lld size %lld -> guest %llx\n", f->path, (long long)off, (long long)size, (unsigned long long)b->addr);
        }
        OUT(int64_t, 0) = n < 0 ? 0 : n;
        resp_size(resp, 8);
        break;
    }
    case 1: {  // Write(option, offset, size) <- A
        int64_t off = IN(int64_t, 8), size = IN(int64_t, 16);
        IpcBuf *a = in_buf(req, 0);
        if (!a || off < 0 || size < 0 || size > INT64_MAX - off || (uint64_t)size > a->size) {
            resp->result = MAKE_RESULT(2, 6001); break;
        }
        if (strstr(f->path, "savedata"))
            LOG("[save] write %s off %lld size %lld <- guest %llx\n", f->path, (long long)off, (long long)size, (unsigned long long)a->addr);
        // A successful short write is not a complete save. Continue at its end, and never hide a later failure.
        for (int64_t done = 0; done < size;) {
            ssize_t n = pwrite(f->fd, (void *)(uintptr_t)(a->addr + done), (size_t)(size - done), off + done);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) {
                if (!n) errno = EIO;
                resp->result = errno_result(); break;
            }
            done += n;
        }
        break;
    }
    case 2: {
        int r;
        do { r = fsync(f->fd); } while (r < 0 && errno == EINTR);
        if (r < 0) resp->result = errno_result();
        break;
    }
    case 3: if (ftruncate(f->fd, IN(int64_t, 0))) resp->result = errno_result(); break;
    case 4: {
        struct stat sb;
        if (fstat(f->fd, &sb)) { resp->result = errno_result(); break; }
        OUT(int64_t, 0) = sb.st_size;
        resp_size(resp, 8);
        break;
    }
    default: LOG("[fs] IFile cmd %u (ok)\n", req->cmd);
    }
}

static void directory(Service *s, IpcReq *req, IpcResp *resp) {
    HostDir *d = s->state;
    switch (req->cmd) {
    case 0: {  // Read -> B buffer of 0x310-byte entries
        IpcBuf *b = out_buf(req, 0);
        uint8_t *out = (uint8_t *)(uintptr_t)b->addr;
        int64_t max = (int64_t)(b->size / 0x310), n = 0;
        struct dirent *e;
        while (n < max && (e = readdir(d->d))) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
#ifdef _WIN32  // no d_type
            char full[2048];
            struct stat es;
            snprintf(full, sizeof full, "%s/%s", d->path, e->d_name);
            bool isdir = !stat(full, &es) && S_ISDIR(es.st_mode);
#else
            bool isdir = e->d_type == DT_DIR;
#endif
            if ((isdir && !(d->mode & 1)) || (!isdir && !(d->mode & 2))) continue;
            uint8_t *ent = out + n * 0x310;
            memset(ent, 0, 0x310);
            strncpy((char *)ent, e->d_name, 0x300);
            ent[0x304] = isdir ? 0 : 1;
            if (!isdir) {
                char p[2048];
                struct stat sb;
                snprintf(p, sizeof p, "%s/%s", d->path, e->d_name);
                if (!stat(p, &sb)) *(int64_t *)(ent + 0x308) = sb.st_size;
            }
            n++;
        }
        OUT(int64_t, 0) = n;
        resp_size(resp, 8);
        break;
    }
    case 1: {  // GetEntryCount
        long pos = telldir(d->d);
        rewinddir(d->d);
        int64_t n = 0;
        struct dirent *e;
        while ((e = readdir(d->d)))
            if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) n++;
        seekdir(d->d, pos);
        OUT(int64_t, 0) = n;
        resp_size(resp, 8);
        break;
    }
    }
}

static int rm_rf(const char *p, bool keep_root) {
    struct stat st;
    if (lstat(p, &st)) return -1;
    if (!S_ISDIR(st.st_mode)) return unlink(p);  // remove a link itself, never recurse through its target
    DIR *d = opendir(p);
    if (!d) return -1;
    int error = 0;
    for (;;) {
        errno = 0;
        struct dirent *e = readdir(d);
        if (!e) { error = errno; break; }
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char c[2048];
        int n = snprintf(c, sizeof c, "%s/%s", p, e->d_name);
        if (n < 0 || (size_t)n >= sizeof c) { error = ENAMETOOLONG; break; }
        if (rm_rf(c, false)) { error = errno; break; }
    }
    int closed = closedir(d);
    if (error) { errno = error; return -1; }
    if (closed) return -1;
    return keep_root ? 0 : rmdir(p);
}

static void filesystem(Service *s, IpcReq *req, IpcResp *resp) {
    HostFs *fs = s->state;
    char p[2048], p2[2048];
    if (!host_path(fs, in_path(req, 0), p, sizeof p)) { resp->result = FS_PATH_NOT_FOUND; return; }
    switch (req->cmd) {
    case 0: {  // CreateFile(option, size)
        int fd = plat_open_file(p, O_CREAT | O_EXCL | O_RDWR);
        if (fd < 0) { resp->result = errno_result(); break; }
        if (ftruncate(fd, IN(int64_t, 8))) resp->result = errno_result();
        close(fd);
        break;
    }
    case 1: if (unlink(p)) resp->result = errno_result(); break;
    case 2: if (mkdir(p, 0755)) resp->result = errno_result(); break;
    case 3: if (rmdir(p)) resp->result = errno_result(); break;
    case 4: if (rm_rf(p, false)) resp->result = errno_result(); break;
    case 5: case 6:
        if (!host_path(fs, in_path(req, 1), p2, sizeof p2)) { resp->result = FS_PATH_NOT_FOUND; break; }
        if (plat_rename(p, p2)) resp->result = errno_result();
        break;
    case 7: {  // GetEntryType
        struct stat sb;
        if (stat(p, &sb)) { resp->result = FS_PATH_NOT_FOUND; break; }
        OUT(uint32_t, 0) = S_ISDIR(sb.st_mode) ? 0 : 1;
        resp_size(resp, 4);
        break;
    }
    case 8: {  // OpenFile(mode)
        uint32_t mode = IN(uint32_t, 0);
        int fd = plat_open_file(p, (mode & 2) ? O_RDWR : O_RDONLY);  // (renamable / deletable while open, as on the console)
        if (fd < 0) { resp->result = errno_result(); break; }
        HostFile *f = calloc(1, sizeof *f);
        f->fd = fd;
        strlcpy(f->path, p, sizeof f->path);
        Service *obj = service_new("IFile", file, f);
        obj->on_close = file_close;
        ipc_return_object(resp, obj);
        break;
    }
    case 9: {  // OpenDirectory(mode)
        DIR *d = opendir(p);
        if (!d) { resp->result = errno_result(); break; }
        HostDir *hd = calloc(1, sizeof *hd);
        hd->d = d;
        hd->mode = (int)IN(uint32_t, 0);
        snprintf(hd->path, sizeof hd->path, "%s", p);
        Service *obj = service_new("IDirectory", directory, hd);
        obj->on_close = directory_close;
        ipc_return_object(resp, obj);
        break;
    }
    case 10: break;  // Commit
    case 11: case 12: OUT(int64_t, 0) = 0x40000000; resp_size(resp, 8); break;
    case 13: if (rm_rf(p, true)) resp->result = errno_result(); break;
    case 14: memset(resp->data, 0, 0x20); resp_size(resp, 0x20); break;
    default: LOG("[fs] IFileSystem cmd %u (ok)\n", req->cmd);
    }
}

// Lumiose Online draws its chat and lists into the game's own image, so at 1080p its text is small and grainy: the first
// time (no text_size in its settings file yet) it starts at 120%. What the player sets afterwards is kept.
static void lumiose_default_text_size(const char *sdcard) {
    char path[1300], line[256];
    snprintf(path, sizeof path, "%s/lumiose_settings.txt", sdcard);
    bool has = false, newline = true;
    FILE *f = fopen(path, "rb");
    if (f) {
        while (fgets(line, sizeof line, f)) {
            has |= !strncmp(line, "text_size", 9);
            newline = strchr(line, '\n') != NULL;
        }
        fclose(f);
    }
    if (has) return;
    f = fopen(path, "ab");
    if (f) {
        fputs(newline ? "text_size=120\n" : "\ntext_size=120\n", f);
        fclose(f);
    }
}

static Service *open_host_fs(const char *sub) {
    HostFs *fs = calloc(1, sizeof *fs);
    if (getenv("LARECOMP_SAVE_DIR")) g_save_dir = getenv("LARECOMP_SAVE_DIR");  // test runs use a scratch copy
    const char *route = getenv("LARECOMP_ROUTE");
    if (route) {  // one fresh copy per game session; mounting sdcard must not reset an already running replay
        extern const char *saves_route_replay_dir(const char *);
        if (!replay_prepared) {
            replay_save_dir = saves_route_replay_dir(route);
            replay_prepared = true;
        }
        if (replay_save_dir) g_save_dir = replay_save_dir;
    }
    snprintf(fs->root, sizeof fs->root, "%s/%s", g_save_dir, sub);
    char cmd[1200];
    snprintf(cmd, sizeof cmd, "%s", fs->root);
    for (char *q = cmd + 1; *q; q++)
        if (*q == '/') { *q = 0; mkdir(cmd, 0755); *q = '/'; }
    mkdir(cmd, 0755);
    if (!strcmp(sub, "sdcard") && getenv("LUMIOSE_TEST_MODULE")) lumiose_default_text_size(fs->root);
    LOG("[fs] mounted host directory %s\n", fs->root);
    return service_new("IFileSystem", filesystem, fs);
}

// ------------------------------------------------------------------ fsp-srv
SERVICE("fsp-srv", fsp_srv) {
    (void)s;
    switch (req->cmd) {
    case 1: break;  // SetCurrentProcess
    case 18: ipc_return_object(resp, open_host_fs("sdcard")); break;
    case 22: break;  // CreateSaveDataFileSystem
    case 51: case 53: {  // OpenSaveDataFileSystem(space, attribute)
        uint8_t type = IN(uint8_t, 0x8 + 0x18);  // attribute.type
        char sub[64];
        snprintf(sub, sizeof sub, "save_%u", type);
        ipc_return_object(resp, open_host_fs(sub));
        break;
    }
    case 200: ipc_return_object(resp, open_romfs_storage()); break;  // OpenDataStorageByCurrentProcess
    case 202: {  // OpenDataStorageByDataId: add-on content (the game root's aoc/<id>.bin, services/misc.c), no system data
        uint64_t id = IN(uint64_t, 8);
        char path[1100];
        snprintf(path, sizeof path, "%s", g_romfs_dir);
        char *slash = strrchr(path, '/');
        snprintf(slash ? slash + 1 : path, sizeof path - (slash ? (size_t)(slash + 1 - path) : 0), "aoc/%016llx.bin",
                 (unsigned long long)id);
        int fd = open(path, O_RDONLY | O_BINARY);
        if (fd < 0) {
            LOG("[fs] OpenDataStorageByDataId %llx (not available)\n", (unsigned long long)id);
            resp->result = MAKE_RESULT(2, 1001);
            break;
        }
        Storage *st = calloc(1, sizeof *st);
        st->fd = fd;
        struct stat sb;
        fstat(fd, &sb);
        st->size = sb.st_size;
        LOG("[fs] add-on content %016llx: %s\n", (unsigned long long)id, path);
        Service *obj = service_new("IStorage(aoc)", plain_storage, st);
        obj->on_close = plain_storage_close;
        ipc_return_object(resp, obj);
        break;
    }
    case 1005: OUT(uint32_t, 0) = 0; resp_size(resp, 4); break;  // GetGlobalAccessLogMode
    case 1003: case 1004: case 1006: break;
    case 1011: memset(resp->data, 0, 0x10); resp_size(resp, 0x10); break;
    default: LOG("[fs] fsp-srv cmd %u (ok)\n", req->cmd);
    }
}
